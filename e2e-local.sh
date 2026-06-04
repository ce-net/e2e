#!/usr/bin/env bash
# Local two-node CE end-to-end test: mesh peering -> capability grant -> rdev
# sync/delete over the mesh, with ce-cap enforcement (positive + negative auth).
# Docker-free path (sync/delete). exec/swarm are covered by their unit tests.
set -u
export CE_NO_AUTOBOOTSTRAP=1
export CE_API_TOKEN="${CE_API_TOKEN:-e2e-shared-token}"

CE=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
RDEV=${RDEV_BIN:-$HOME/ce-net/rdev/target/release/rdev}
ROOT=/tmp/ce-e2e
A_DATA=$ROOT/A; B_DATA=$ROOT/B; B_HOME=$ROOT/Bhome
A_P2P=4101; A_API=8901; B_P2P=4102; B_API=8902
PIDS=()
PASS=0; FAIL=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

rm -rf "$ROOT"; mkdir -p "$A_DATA" "$B_DATA" "$B_HOME"

say "identities"
A_ID=$("$CE" --data-dir "$A_DATA" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
B_ID=$("$CE" --data-dir "$B_DATA" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
A_PEER=$("$CE" --data-dir "$A_DATA" id 2>/dev/null | grep -oE '12D3[A-Za-z0-9]+' | head -1)
echo "A=$A_ID  peer=$A_PEER"; echo "B=$B_ID"
[ ${#A_ID} -eq 64 ] && [ ${#B_ID} -eq 64 ] && ok "two distinct identities" || bad "identity generation"

say "start node A"
"$CE" --data-dir "$A_DATA" start --no-mdns --port $A_P2P --api-port $A_API --no-mine >"$ROOT/A.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$A_API/status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$A_API/status" >/dev/null 2>&1 && ok "node A up" || { bad "node A failed to start"; cat "$ROOT/A.log"; exit 1; }

# A's dialable multiaddr for B to bootstrap from, built directly from A's peer id
A_ADDR="/ip4/127.0.0.1/tcp/$A_P2P/p2p/$A_PEER"
echo "A_ADDR=$A_ADDR"

say "start node B (bootstraps from A)"
"$CE" --data-dir "$B_DATA" start --no-mdns --port $B_P2P --api-port $B_API --no-mine ${A_ADDR:+--bootstrap "$A_ADDR"} >"$ROOT/B.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$B_API/status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$B_API/status" >/dev/null 2>&1 && ok "node B up" || { bad "node B failed to start"; cat "$ROOT/B.log"; exit 1; }

say "capability grant: B authorizes A for sync,delete under prefix 'e2e'"
TOKEN=$("$CE" --data-dir "$B_DATA" grant "$A_ID" --can sync,delete --resource self --path e2e --expires 1h 2>/dev/null | tr -d '[:space:]')
echo "token length=${#TOKEN}"
[ ${#TOKEN} -gt 20 ] && ok "grant issued" || { bad "grant produced no token"; }

say "start rdev serve bound to node B (writes sandboxed to \$HOME=$B_HOME)"
HOME="$B_HOME" "$RDEV" --node "http://127.0.0.1:$B_API" serve >"$ROOT/rdev.log" 2>&1 &
PIDS+=($!)
sleep 2

echo "hello-from-A $(date -u +%FT%TZ)" > "$ROOT/hello.txt"

say "POSITIVE: A pushes a file into B:e2e/ (retry until mesh routes)"
PUSHED=""
for i in $(seq 1 20); do
  OUT=$("$RDEV" --node "http://127.0.0.1:$A_API" push "$ROOT/hello.txt" "$B_ID:e2e/hello.txt" --cap "$TOKEN" 2>&1)
  if [ -f "$B_HOME/e2e/hello.txt" ]; then PUSHED=1; break; fi
  sleep 2
done
if [ -n "$PUSHED" ] && diff -q "$ROOT/hello.txt" "$B_HOME/e2e/hello.txt" >/dev/null 2>&1; then
  ok "file synced over the mesh and contents match"
else
  bad "push did not land (last output: $OUT)"; echo "--- rdev.log ---"; tail -20 "$ROOT/rdev.log"
fi

say "NEGATIVE: push without a capability is denied"
NO_CAP=$("$RDEV" --node "http://127.0.0.1:$A_API" push "$ROOT/hello.txt" "$B_ID:e2e/nope.txt" 2>&1)
if [ ! -f "$B_HOME/e2e/nope.txt" ]; then ok "no-cap push rejected (no file written)"; else bad "no-cap push wrote a file"; fi

say "NEGATIVE: push outside the granted 'e2e' prefix is denied by the path caveat"
ESC=$("$RDEV" --node "http://127.0.0.1:$A_API" push "$ROOT/hello.txt" "$B_ID:other/escape.txt" --cap "$TOKEN" 2>&1)
if [ ! -f "$B_HOME/other/escape.txt" ]; then ok "path-caveat blocked write outside prefix"; else bad "path caveat NOT enforced"; fi

say "POSITIVE: A deletes the file it synced"
"$RDEV" --node "http://127.0.0.1:$A_API" rm "$B_ID:e2e/hello.txt" --cap "$TOKEN" >>"$ROOT/rdev.log" 2>&1
for i in $(seq 1 10); do [ -f "$B_HOME/e2e/hello.txt" ] || break; sleep 1; done
[ -f "$B_HOME/e2e/hello.txt" ] && bad "delete did not remove the file" || ok "file deleted over the mesh"

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
