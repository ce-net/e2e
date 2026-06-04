#!/usr/bin/env bash
# Live recursive self-replication over the CE mesh, Docker-free.
#
# Topology: a shared org root R; seed A; replicas B and C. Every rdev serve lists R as an accepted
# root (RDEV_ROOTS), so a chain rooted at R is honored fleet-wide.
#
#   R --grant[sync,spawn]--> A
#   A --replicator seed--> B : push boot.sh + delegate [R->A,A->B] + rdev/spawn 'sh boot.sh'
#   B --replicator seed--> C : using its DELEGATED cap [R->A,A->B] (proves the recursion hop)
#
# Asserts: files land, host processes actually run (BOOT_OK markers), the delegated cap authorizes
# the next tier, and a sync-only cap is DENIED spawn.
set -u
export CE_NO_AUTOBOOTSTRAP=1

CE=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
RDEV=${RDEV_BIN:-$HOME/ce-net/rdev/target/release/rdev}
REPL=${REPL_BIN:-$HOME/ce-net/replicator/target/release/replicator}
BOOT=${BOOT_SH:-$(dirname "$0")/repl-boot.sh}
ROOT=/tmp/ce-repl
PIDS=(); PASS=0; FAIL=0

say(){ printf '\n=== %s ===\n' "$1"; }
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

rm -rf "$ROOT"; mkdir -p "$ROOT"/{R,A,B,C,Bhome,Chome}

id_of(){ "$CE" --data-dir "$1" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1; }
peer_of(){ "$CE" --data-dir "$1" id 2>/dev/null | grep -oE '12D3[A-Za-z0-9]+' | head -1; }
up(){ for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$1/status" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

say "identities + shared root file"
R_ID=$(id_of "$ROOT/R"); A_ID=$(id_of "$ROOT/A"); B_ID=$(id_of "$ROOT/B"); C_ID=$(id_of "$ROOT/C")
A_PEER=$(peer_of "$ROOT/A")
echo "$R_ID  # org root R" > "$ROOT/roots"
[ ${#R_ID} -eq 64 ] && [ ${#A_ID} -eq 64 ] && [ ${#B_ID} -eq 64 ] && [ ${#C_ID} -eq 64 ] && ok "R,A,B,C identities" || { bad "identities"; exit 1; }

say "start nodes A,B,C (B,C bootstrap from A)"
A_ADDR="/ip4/127.0.0.1/tcp/4101/p2p/$A_PEER"
"$CE" --data-dir "$ROOT/A" start --no-mdns --port 4101 --api-port 8901 --no-mine >"$ROOT/A.log" 2>&1 & PIDS+=($!)
up 8901 || { bad "node A up"; cat "$ROOT/A.log"; exit 1; }
"$CE" --data-dir "$ROOT/B" start --no-mdns --port 4102 --api-port 8902 --no-mine --bootstrap "$A_ADDR" >"$ROOT/B.log" 2>&1 & PIDS+=($!)
"$CE" --data-dir "$ROOT/C" start --no-mdns --port 4103 --api-port 8903 --no-mine --bootstrap "$A_ADDR" >"$ROOT/C.log" 2>&1 & PIDS+=($!)
up 8902 && up 8903 && ok "nodes A,B,C up" || { bad "nodes up"; exit 1; }

say "rdev serve on B and C (accepting org root R)"
HOME="$ROOT/Bhome" RDEV_ROOTS="$ROOT/roots" "$RDEV" --node http://127.0.0.1:8902 serve >"$ROOT/rdevB.log" 2>&1 & PIDS+=($!)
HOME="$ROOT/Chome" RDEV_ROOTS="$ROOT/roots" "$RDEV" --node http://127.0.0.1:8903 serve >"$ROOT/rdevC.log" 2>&1 & PIDS+=($!)
sleep 2
grep -q "1 configured root" "$ROOT/rdevB.log" && grep -q "1 configured root" "$ROOT/rdevC.log" && ok "rdev serve loaded the org root on B and C" || bad "rdev serve root load"

say "R grants A a root cap (sync,spawn over the whole fleet)"
TOKEN_RA=$("$CE" --data-dir "$ROOT/R" grant "$A_ID" --can sync,spawn --resource any --expires 1h 2>/dev/null | tr -d '[:space:]')
[ ${#TOKEN_RA} -gt 20 ] && ok "root cap R->A issued" || bad "root grant"

say "A replicates onto B (push boot.sh, delegate, spawn) — retry until mesh routes"
DONE=""
for i in $(seq 1 20); do
  "$REPL" --node http://127.0.0.1:8901 --data-dir "$ROOT/A" seed "$B_ID" \
     --cap "$TOKEN_RA" --depth 2 --ttl-secs 1800 \
     --bin boot.sh="$BOOT" --boot "sh boot.sh" --cwd repl >"$ROOT/seedB.log" 2>&1
  [ -f "$ROOT/Bhome/repl/boot.sh" ] && { DONE=1; break; }
  sleep 2
done
[ -n "$DONE" ] && ok "binary pushed to B over the mesh" || { bad "push to B"; tail -5 "$ROOT/seedB.log"; tail -5 "$ROOT/rdevB.log"; }
[ -f "$ROOT/Bhome/repl/replicator.cap" ] && ok "delegated cap delivered to B" || bad "delegated cap not delivered"
B_OK=""; for i in $(seq 1 15); do [ -f "$ROOT/Bhome/repl/BOOT_OK" ] && { B_OK=1; break; }; sleep 1; done
[ -n "$B_OK" ] && ok "host process ran on B (BOOT_OK present)" || bad "spawn on B did not run"

say "B replicates onto C using its DELEGATED cap (the recursion hop)"
TOKEN_AB=$(cat "$ROOT/Bhome/repl/replicator.cap" 2>/dev/null | tr -d '[:space:]')
echo "delegated chain length (bytes): ${#TOKEN_AB}"
DONE=""
for i in $(seq 1 20); do
  "$REPL" --node http://127.0.0.1:8902 --data-dir "$ROOT/B" seed "$C_ID" \
     --cap "$TOKEN_AB" --depth 1 \
     --bin boot.sh="$BOOT" --boot "sh boot.sh" --cwd repl >"$ROOT/seedC.log" 2>&1
  [ -f "$ROOT/Chome/repl/boot.sh" ] && { DONE=1; break; }
  sleep 2
done
[ -n "$DONE" ] && ok "B->C push via delegated cap" || { bad "B->C push"; tail -5 "$ROOT/seedC.log"; tail -5 "$ROOT/rdevC.log"; }
C_OK=""; for i in $(seq 1 15); do [ -f "$ROOT/Chome/repl/BOOT_OK" ] && { C_OK=1; break; }; sleep 1; done
[ -n "$C_OK" ] && ok "host process ran on C via the delegation chain (BOOT_OK present)" || bad "spawn on C did not run"

say "NEGATIVE: a sync-only cap is DENIED spawn"
TOKEN_SYNC=$("$CE" --data-dir "$ROOT/R" grant "$A_ID" --can sync --resource any --expires 1h 2>/dev/null | tr -d '[:space:]')
"$REPL" --node http://127.0.0.1:8901 --data-dir "$ROOT/A" seed "$B_ID" \
   --cap "$TOKEN_SYNC" --depth 1 \
   --bin boot.sh="$BOOT" --boot "sh boot.sh" --cwd replneg >"$ROOT/seedNeg.log" 2>&1
sleep 3
if [ -f "$ROOT/Bhome/replneg/boot.sh" ] && [ ! -f "$ROOT/Bhome/replneg/BOOT_OK" ]; then
  ok "sync worked but spawn was denied (no BOOT_OK)"
else
  bad "spawn gating failed (BOOT_OK should be absent under a sync-only cap)"
fi

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
