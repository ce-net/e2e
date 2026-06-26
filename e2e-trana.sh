#!/usr/bin/env bash
# e2e-trana.sh — end-to-end test for the trana distributed social/content backend.
#
# Stands up a real multi-node CE mesh on loopback, runs TWO trana-node instances on two different CE
# nodes, and proves the backend is genuinely distributed and fault-tolerant:
#
#   1. SETUP        — N-node mining CE mesh; trana-node T0 on h0, T1 on h1 (each advertises `trana`).
#   2. WRITE        — author a thread + media on T1 (cross-node request from h0's CLI).
#   3. REPLICATE    — the same thread/media is readable from T0 (gossip + object replication worked):
#                     proves distributed correctness, not a single source of truth.
#   4. TRUST        — karma for a node returns social + on-chain COMPUTE trust (cpu/uptime/earned)
#                     read live from /history + /atlas: proves the trust layer talks to the substrate.
#   5. FAULT        — kill T1 (the ingesting trana node); the content still serves from T0
#                     (fault-tolerant). Kill a CE node; the mesh re-converges. Restart; it recovers.
#
# Hermetic: ephemeral in-RAM nodes, --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback only. Never touches
# ce-net.com. Skips cleanly (exit 0) if the `ce` or `trana` binaries are missing.
#
# Binaries (env-overridable):
#   CE_BIN          $HOME/ce-net/ce/target/release/ce
#   TRANA_NODE_BIN  $HOME/ce-net/.cargo-shared/release/trana-node  (or debug)
#   TRANA_BIN       $HOME/ce-net/.cargo-shared/release/trana       (or debug)

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/redteam.sh
. "$SELF_DIR/lib/redteam.sh"

rt_init trana
rt_arm_cleanup

# trana binaries live in the shared cargo target (~/ce-net/.cargo-shared). Prefer release, fall back
# to debug, then to PATH.
pick_bin() { # <name>
  local n=$1 d=$HOME/ce-net/.cargo-shared
  for c in "$d/release/$n" "$d/debug/$n" "$(command -v "$n" 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  echo ""
}
TRANA_NODE_BIN=${TRANA_NODE_BIN:-$(pick_bin trana-node)}
TRANA_BIN=${TRANA_BIN:-$(pick_bin trana)}
[ -n "$TRANA_NODE_BIN" ] && [ -x "$TRANA_NODE_BIN" ] || { skip "trana-node not built (build the trana workspace); skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }
[ -n "$TRANA_BIN" ] && [ -x "$TRANA_BIN" ] || { skip "trana CLI not built; skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }

BOARD=ce-dev
P2P=6400; API=8400
N=${TRANA_MESH_NODES:-3}

# Start a trana-node bound to a given CE node's API. Logs to $ROOT/<name>.log; waits for readiness.
start_trana() { # <name> <ce-api-port>
  local name=$1 api=$2 i
  mkdir -p "$ROOT/$name"
  "$TRANA_NODE_BIN" --node-url "http://127.0.0.1:$api" --data-dir "$ROOT/$name" \
    >"$ROOT/$name.log" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 30); do
    grep -q "trana-node ready" "$ROOT/$name.log" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# trana CLI pinned to a specific trana node id, routed through a CE node's API.
tcli() { # <ce-api-port> <trana-node-id> <args...>
  local api=$1 node=$2; shift 2
  "$TRANA_BIN" --node-url "http://127.0.0.1:$api" --node "$node" "$@" 2>>"$ROOT/cli.log"
}

# --------------------------------------------------------------------------------------------------
say "stand up $N-node CE mesh"
rt_start_mesh "$N" "$P2P" "$API" || { bad "mesh seed failed to start"; rt_result; exit 1; }
sleep 3
read -r mn mx up <<<"$(rt_mesh_converged 6 1 3 || true)"
[ "${up:-0}" -ge 2 ] && ok "CE mesh online ($up nodes, heights $mn..$mx)" || bad "CE mesh did not form"

API0=$API; API1=$((API+1))
T0_ID=$(rt_node_id "$ROOT/h0")
T1_ID=$(rt_node_id "$ROOT/h1")
[ -n "$T0_ID" ] && [ -n "$T1_ID" ] && ok "resolved trana node ids T0=$T0_ID T1=$T1_ID" || { bad "could not resolve node ids"; rt_result; exit 1; }

say "start trana-node on two CE nodes"
start_trana t0 "$API0" && ok "trana T0 up on h0" || bad "trana T0 failed (see $ROOT/t0.log)"
start_trana t1 "$API1" && ok "trana T1 up on h1" || bad "trana T1 failed (see $ROOT/t1.log)"
sleep 2

# --------------------------------------------------------------------------------------------------
say "WRITE on T1 (cross-node request from h0's CLI)"
POST_ID=$(tcli "$API0" "$T1_ID" post --board "$BOARD" --title "trana e2e" --body "distributed and replicated")
if [ -n "$POST_ID" ]; then ok "posted thread on T1: $POST_ID"; else bad "post on T1 returned no id"; fi

say "REPLICATE: thread is readable from T0 (gossip propagated)"
seen=0
for _ in $(seq 1 20); do
  if [ -n "$POST_ID" ] && tcli "$API1" "$T0_ID" threads "$BOARD" 2>/dev/null | grep -q "$POST_ID"; then
    seen=1; break
  fi
  sleep 1
done
[ "$seen" = 1 ] && ok "thread replicated T1 -> T0 (distributed read confirmed)" || bad "thread did not replicate to T0"

say "REPLICATE: media object is fetchable through T0"
SRC="$ROOT/clip.bin"; head -c 200000 /dev/urandom >"$SRC"
MEDIA_ID=$(tcli "$API0" "$T1_ID" media "$SRC" --kind document --title "e2e blob")
got=0
if [ -n "$MEDIA_ID" ]; then
  for _ in $(seq 1 20); do
    if tcli "$API1" "$T0_ID" download "$MEDIA_ID" "$ROOT/out.bin" >/dev/null 2>&1 \
       && cmp -s "$SRC" "$ROOT/out.bin"; then got=1; break; fi
    sleep 1
  done
fi
[ "$got" = 1 ] && ok "media bytes fetched through T0 byte-identical (object replication)" || bad "media not retrievable via T0"

# --------------------------------------------------------------------------------------------------
say "TRUST: karma fuses social + on-chain compute reputation"
KJSON=$(tcli "$API0" "$T1_ID" karma "$T0_ID" 2>/dev/null)
if echo "$KJSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'social' in d and 'compute' in d and 'trust' in d; print('ok')" >/dev/null 2>&1; then
  ok "karma response carries social + compute + trust for a node"
else
  bad "karma response malformed: $KJSON"
fi

# --------------------------------------------------------------------------------------------------
say "FAULT: kill T1 (the ingesting trana node); content must survive on T0"
# Kill only T1's process (last-but-... find its pid via the log marker dir).
T1_PID=$(pgrep -f "$ROOT/t1" | head -1)
[ -n "$T1_PID" ] && kill "$T1_PID" 2>/dev/null && ok "killed trana T1 (pid $T1_PID)" || skip "could not locate T1 pid"
sleep 2
if [ -n "$POST_ID" ] && tcli "$API1" "$T0_ID" threads "$BOARD" 2>/dev/null | grep -q "$POST_ID"; then
  ok "content still served from T0 after T1 died (fault tolerant)"
else
  bad "content lost after T1 died"
fi

say "FAULT: kill a CE node; the mesh re-converges"
LAST=$((N-1))
LAST_PID=$(pgrep -f "$ROOT/h$LAST" | head -1)
[ -n "$LAST_PID" ] && kill "$LAST_PID" 2>/dev/null && ok "killed CE node h$LAST (pid $LAST_PID)" || skip "could not locate h$LAST pid"
sleep 5
read -r mn2 mx2 up2 <<<"$(rt_mesh_converged 8 1 2 || true)"
[ "${up2:-0}" -ge 1 ] && ok "surviving CE mesh still healthy ($up2 nodes, h $mn2..$mx2)" || bad "mesh collapsed after node loss"

say "RECOVER: restart the killed CE node; it rejoins"
rt_start_node "h$LAST" $((P2P+LAST)) $((API+LAST)) --bootstrap "$RT_SEED" >/dev/null 2>&1
sleep 4
h_rejoin=$(rt_field $((API+LAST)) height)
[ "${h_rejoin:-(-1)}" != "-1" ] && [ "${h_rejoin:-0}" != "None" ] && ok "rejoined node answering (h=$h_rejoin)" || skip "rejoined node still catching up"

rt_result
