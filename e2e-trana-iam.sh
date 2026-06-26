#!/usr/bin/env bash
# e2e-trana-iam.sh — delegated identity ("act-as") via ce-iam / ce-cap capabilities.
#
# Proves the production auth flow: a user U can authorize another device D to act as U in trana by
# minting a ce-cap capability (`ce grant <D> --can trana:act`), and that this is UNFORGEABLE:
#   - D + a capability signed by U      -> content is authored by U.            (delegation works)
#   - D + a capability signed by someone else -> rejected.                       (no impersonation)
#   - D + a malformed capability        -> rejected.                             (no forgery)
#
# Hermetic: ephemeral in-RAM nodes, loopback, CE_NO_AUTOBOOTSTRAP=1. Skips cleanly if binaries absent.
#   CE_BIN=~/.local/bin/ce ./e2e-trana-iam.sh

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/redteam.sh
. "$SELF_DIR/lib/redteam.sh"

rt_init trana-iam
rt_arm_cleanup

pick_bin() {
  local n=$1 d=$HOME/ce-net/.cargo-shared
  for c in "$d/release/$n" "$d/debug/$n" "$(command -v "$n" 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  echo ""
}
TRANA_NODE_BIN=${TRANA_NODE_BIN:-$(pick_bin trana-node)}
TRANA_BIN=${TRANA_BIN:-$(pick_bin trana)}
[ -n "$TRANA_NODE_BIN" ] && [ -x "$TRANA_NODE_BIN" ] || { skip "trana-node not built; skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }
[ -n "$TRANA_BIN" ] && [ -x "$TRANA_BIN" ] || { skip "trana CLI not built; skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }

P2P=6700; API=6800; N=3
API_U=$API; API_D=$((API+1))

start_trana() { # name ce-api
  local name=$1 api=$2 i
  mkdir -p "$ROOT/$name"
  "$TRANA_NODE_BIN" --node-url "http://127.0.0.1:$api" --data-dir "$ROOT/$name" >"$ROOT/$name.log" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 30); do grep -q "trana-node ready" "$ROOT/$name.log" 2>/dev/null && return 0; sleep 1; done
  return 1
}

say "stand up mesh + trana service"
rt_start_mesh "$N" "$P2P" "$API" || { bad "mesh seed failed"; rt_result; exit 1; }
up=0
for _ in $(seq 1 25); do
  up=0; for i in 0 1 2; do curl -fsS -m2 "http://127.0.0.1:$((API+i))/status" >/dev/null 2>&1 && up=$((up+1)); done
  [ "$up" -ge 2 ] && break; sleep 1
done
[ "$up" -ge 2 ] && ok "CE mesh online ($up nodes)" || { bad "mesh did not form"; rt_result; exit 1; }
start_trana t0 "$API_U" && ok "trana service up" || { bad "trana failed"; rt_result; exit 1; }
sleep 2

U=$(rt_node_id "$ROOT/h0")   # the user identity (and the trana node)
D=$(rt_node_id "$ROOT/h1")   # the delegated device
X=$(rt_node_id "$ROOT/h2")   # an unrelated third party
T0=$U
BOARD=delegated

# Helper: D writes through h1's CE node, pinned to the trana service, with optional --as/--cap.
d_post() { # title cap...
  local title=$1; shift
  "$TRANA_BIN" --node-url "http://127.0.0.1:$API_D" --node "$T0" "$@" post --board "$BOARD" --title "$title" --body x 2>>"$ROOT/cli.log"
}

say "U mints a trana:act capability authorizing D"
TOK=$("$CE_BIN" --data-dir "$ROOT/h0" grant "$D" --can trana:act --resource self 2>>"$ROOT/grant.log")
if [ -n "$TOK" ]; then
  ok "U issued a trana:act capability to D"
else
  bad "ce grant produced no token (see $ROOT/grant.log) — cannot test delegation"
  rt_result; exit 1
fi

say "POSITIVE: D posts AS U with the capability -> authored by U"
PID=$(d_post "acting as U" --as "$U" --cap "$TOK")
AUTHOR=""
if [ -n "$PID" ]; then
  for _ in $(seq 1 10); do
    AUTHOR=$("$TRANA_BIN" --node-url "http://127.0.0.1:$API_D" --node "$T0" threads "$BOARD" --sort new --limit 20 2>/dev/null \
      | python3 -c "import sys,json;ts=json.load(sys.stdin).get('threads',[]);print(next((t['author'] for t in ts if t['id']=='$PID'),''))" 2>/dev/null)
    [ -n "$AUTHOR" ] && break; sleep 1
  done
fi
[ -n "$PID" ] && [ "$AUTHOR" = "$U" ] && ok "delegation works: D's post is authored by U" || bad "delegation failed (pid=$PID author=$AUTHOR want=$U)"

say "NEGATIVE: a capability signed by someone else (X) cannot impersonate U"
TOK_X=$("$CE_BIN" --data-dir "$ROOT/h2" grant "$D" --can trana:act --resource self 2>/dev/null)
if d_post "impersonation attempt" --as "$U" --cap "$TOK_X" >/dev/null 2>&1; then
  bad "D impersonated U with a capability NOT signed by U"
else
  xfail "capability from a different issuer cannot act as U"
fi

say "NEGATIVE: a malformed capability is rejected"
if d_post "garbage cap" --as "$U" --cap "deadbeefnotacap" >/dev/null 2>&1; then
  bad "malformed capability was accepted"
else
  xfail "malformed capability rejected"
fi

say "CONTROL: D posting as itself (no capability) still works, authored by D"
PID2=$(d_post "just me")
AUTH2=$("$TRANA_BIN" --node-url "http://127.0.0.1:$API_D" --node "$T0" threads "$BOARD" --sort new --limit 20 2>/dev/null \
  | python3 -c "import sys,json;ts=json.load(sys.stdin).get('threads',[]);print(next((t['author'] for t in ts if t['id']=='$PID2'),''))" 2>/dev/null)
[ -n "$PID2" ] && [ "$AUTH2" = "$D" ] && ok "without a capability, D is authored as D (no privilege)" || bad "self-authorship broken (author=$AUTH2 want=$D)"

rt_result
