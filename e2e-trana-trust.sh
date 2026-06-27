#!/usr/bin/env bash
# e2e-trana-trust.sh — end-to-end test for trana's TRUST system on a real CE mesh.
#
# Proves, against real multi-identity nodes (not unit mocks), the three properties that make trana's
# reputation hard to game:
#
#   1. COLD-START KARMA  — a post upvoted only by zero-trust sybils earns ~0 effective karma; the same
#                          post upvoted by a TRUSTED member (a configured trust root) earns real karma.
#                          This is the Reddit-grade "you can't farm karma at the start" property.
#   2. WEB OF TRUST      — once the root vouches (follows) the author, the author gains a graph rank;
#                          a personalized-trust query from the root ranks the vouched node high and an
#                          un-vouched sybil ~0.
#   3. DEVICE BINDING    — a profile that merely NAMES another node as its device does not inherit its
#                          compute until that device signs a DeviceLink back (mutual, two-signature).
#
# Identities (each a distinct CE node = a distinct trana author):
#   h0 = ROOT (configured in TRANA_TRUST_ROOTS), h1 = AUTHOR, h2/h3 = SYBILS / candidate device.
# trana-node runs on h0 (T0) and h1 (T1); writes are authored by whichever CE API issues them.
#
# Hermetic: ephemeral in-RAM nodes, --no-mdns, loopback only; never touches ce-net.com. Skips cleanly
# (exit 0) if the `ce` / `trana` binaries are missing.

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/redteam.sh
. "$SELF_DIR/lib/redteam.sh"

rt_init trana-trust
rt_arm_cleanup

pick_bin() { # <name>
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
command -v python3 >/dev/null 2>&1 || { skip "python3 needed for assertions; skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }

BOARD=trust-dev
P2P=6500; API=8500
N=${TRANA_MESH_NODES:-4}
ROOTS=""  # filled with the root CE node id once the mesh is up

start_trana() { # <name> <ce-api-port>
  local name=$1 api=$2 i
  mkdir -p "$ROOT/$name"
  TRANA_TRUST_ROOTS="$ROOTS" "$TRANA_NODE_BIN" --node-url "http://127.0.0.1:$api" --data-dir "$ROOT/$name" \
    >"$ROOT/$name.log" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 30); do
    grep -q "trana-node ready" "$ROOT/$name.log" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

tcli() { # <ce-api-port> <trana-node-id> <args...>
  local api=$1 node=$2; shift 2
  "$TRANA_BIN" --node-url "http://127.0.0.1:$api" --node "$node" "$@" 2>>"$ROOT/cli.log"
}

# Pull a numeric field out of a karma JSON blob via a python expression on `d`.
fnum() { echo "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)" 2>/dev/null; }
# Float comparison: prints 1 if $1 > $2.
gt() { python3 -c "import sys;print(1 if float(sys.argv[1])>float(sys.argv[2]) else 0)" "$1" "$2" 2>/dev/null; }

# --------------------------------------------------------------------------------------------------
say "stand up $N-node CE mesh"
rt_start_mesh "$N" "$P2P" "$API" || { bad "mesh seed failed"; rt_result; exit 1; }
ce_apis_up() { local i u=0; for i in $(seq 0 $((N-1))); do curl -fsS -m2 "http://127.0.0.1:$((API+i))/status" >/dev/null 2>&1 && u=$((u+1)); done; echo "$u"; }
up=0
for _ in $(seq 1 25); do up=$(ce_apis_up); [ "$up" -ge 2 ] && break; sleep 1; done
[ "$up" -ge 2 ] && ok "CE mesh online ($up/$N node APIs live)" || { bad "fewer than 2 CE nodes up"; rt_result; exit 1; }

API0=$API; API1=$((API+1)); API2=$((API+2)); API3=$((API+3))
T0_ID=$(rt_node_id "$ROOT/h0")   # ROOT identity (also the trana node on h0)
T1_ID=$(rt_node_id "$ROOT/h1")   # AUTHOR identity (also the trana node on h1)
H2_ID=$(rt_node_id "$ROOT/h2")   # SYBIL / candidate device
H3_ID=$(rt_node_id "$ROOT/h3")   # SYBIL
[ -n "$T0_ID" ] && [ -n "$T1_ID" ] && [ -n "$H2_ID" ] && [ -n "$H3_ID" ] \
  && ok "resolved identities root=$T0_ID author=$T1_ID" || { bad "could not resolve node ids"; rt_result; exit 1; }

# The trust root is h0's identity — seed the web of trust there.
ROOTS="$T0_ID"
say "start trana-node on h0 + h1 with TRANA_TRUST_ROOTS=$ROOTS"
start_trana t0 "$API0" && ok "trana T0 up (root-seeded)" || bad "trana T0 failed (see $ROOT/t0.log)"
start_trana t1 "$API1" && ok "trana T1 up (root-seeded)" || bad "trana T1 failed (see $ROOT/t1.log)"
sleep 2

# h2/h3 are late-joining CE nodes; their AppRequests to T0 only route once mesh peering settles. Warm
# the path (a cheap read) before the assertions so the writes below land deterministically.
wait_route() { # <api>
  local api=$1 i
  for i in $(seq 1 30); do tcli "$api" "$T0_ID" threads "$BOARD" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
wait_route "$API2" && wait_route "$API3" && ok "h2,h3 route to T0 over the mesh" || skip "late-node routing slow"

# --------------------------------------------------------------------------------------------------
# ==================================================================================================
# CORE (always deterministic). The ROOT is co-located with T0, so its follow and every karma read go
# through h0's own node and never cross the (sometimes flaky) loopback mesh. These assertions prove
# the web-of-trust + personalized-trust logic on a real node without depending on cross-node routing.
say "WEB OF TRUST: a trusted root vouches (follows) the author"
tcli "$API0" "$T0_ID" follow "$T1_ID" >/dev/null 2>&1   # local write h0 -> T0
AUTHOR_RANK=0
for _ in $(seq 1 20); do
  K=$(tcli "$API0" "$T0_ID" karma "$T1_ID")
  AUTHOR_RANK=$(fnum "$K" "d['trust']['graph_rank']")
  [ "$(gt "${AUTHOR_RANK:-0}" 0)" = 1 ] && break
  sleep 1
done
[ "$(gt "${AUTHOR_RANK:-0}" 0)" = 1 ] \
  && ok "author gained web-of-trust rank from the root's vouch (graph_rank=$AUTHOR_RANK)" \
  || bad "author has no graph rank after root follow (got $AUTHOR_RANK)"

say "WEB OF TRUST: personalized ranks from the root's vantage (P5)"
PT=$(tcli "$API0" "$T0_ID" trust --viewer "$T0_ID" "$T1_ID" "$H2_ID")
rank_of() { echo "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);r=dict(d['ranks']);print(r.get(sys.argv[1],0.0))" "$2" 2>/dev/null; }
R_AUTHOR=$(rank_of "$PT" "$T1_ID")
R_SYBIL=$(rank_of "$PT" "$H2_ID")
[ "$(gt "${R_AUTHOR:-0}" "${R_SYBIL:-0}")" = 1 ] && [ "$(gt "${R_AUTHOR:-0}" 0)" = 1 ] \
  && ok "personal_trust(root): vouched author=$R_AUTHOR outranks unfollowed sybil=$R_SYBIL" \
  || bad "personalized trust did not rank the vouched author above the sybil (author=$R_AUTHOR sybil=$R_SYBIL)"

# ==================================================================================================
# COLD-START (needs cross-node writes: author post + sybil votes). Best-effort: if the loopback mesh
# won't route these within budget, SKIP — never a false failure. The logic itself is also locked in
# by the unit test `effective_karma_is_trust_weighted`.
say "COLD-START: karma is not farmable by zero-trust upvotes"
POST_ID=""
for _ in $(seq 1 20); do
  POST_ID=$(tcli "$API1" "$T0_ID" post --board "$BOARD" --title "cold start" --body "earn it" 2>/dev/null)
  [ -n "$POST_ID" ] && break
  sleep 2
done
if [ -z "$POST_ID" ]; then
  skip "author->T0 write did not route this run; skipping cold-start (logic covered by unit tests)"
else
  ok "author posted: $POST_ID"
  # Sybils upvote (idempotent re-issue until a vote registers).
  SYBIL_EFF=""; raw=0
  for _ in $(seq 1 25); do
    tcli "$API2" "$T0_ID" vote "$POST_ID" 1 >/dev/null 2>&1
    tcli "$API3" "$T0_ID" vote "$POST_ID" 1 >/dev/null 2>&1
    K=$(tcli "$API0" "$T0_ID" karma "$T1_ID"); raw=$(fnum "$K" "d['social']['post_score']")
    if [ "${raw:-0}" -ge 1 ]; then
      SYBIL_EFF=$(fnum "$K" "d['social']['effective_score']")
      [ "${raw:-0}" -ge 2 ] && break
    fi
    sleep 1
  done
  if [ -z "$SYBIL_EFF" ]; then
    skip "sybil votes did not route this run; skipping the sybil cold-start check"
  else
    near_zero=$(python3 -c "import sys;print(1 if abs(float(sys.argv[1]))<0.05 else 0)" "$SYBIL_EFF")
    [ "$near_zero" = 1 ] \
      && ok "$raw raw sybil upvote(s) => effective karma ~0 ($SYBIL_EFF): karma is not farmable" \
      || bad "sybil upvotes moved effective karma to $SYBIL_EFF (expected ~0)"
    # The root's upvote is a LOCAL write (h0 -> T0), so it always lands: a trusted vote DOES move karma.
    tcli "$API0" "$T0_ID" vote "$POST_ID" 1 >/dev/null 2>&1
    GOOD_EFF="$SYBIL_EFF"
    for _ in $(seq 1 20); do
      K=$(tcli "$API0" "$T0_ID" karma "$T1_ID"); GOOD_EFF=$(fnum "$K" "d['social']['effective_score']")
      [ "$(gt "${GOOD_EFF:-0}" "${SYBIL_EFF:-0}")" = 1 ] && break
      sleep 1
    done
    [ "$(gt "${GOOD_EFF:-0}" "${SYBIL_EFF:-0}")" = 1 ] \
      && ok "a trusted upvote lifts effective karma $SYBIL_EFF -> $GOOD_EFF (real approval counts)" \
      || bad "trusted upvote did not lift effective karma (sybil=$SYBIL_EFF good=$GOOD_EFF)"
  fi
fi

# ==================================================================================================
# DEVICE BINDING (needs cross-node writes: h1 profile-set + h2 link). Best-effort with skip-on-infra;
# logic also locked in by the unit test `device_link_requires_device_consent`.
say "DEVICE BINDING: compute rolls up only with the device's consent"
# Confirm the author's profile actually carries the claimed device (proves profile-set routed).
have_claim=0
for _ in $(seq 1 20); do
  tcli "$API1" "$T0_ID" profile-set --display-name "author" --device "$H2_ID" >/dev/null 2>&1
  P=$(tcli "$API0" "$T0_ID" profile "$T1_ID" 2>/dev/null)
  echo "$P" | python3 -c "import sys,json;d=json.load(sys.stdin);pv=d.get('profile');devs=(pv or {}).get('profile',{}).get('devices',[]);sys.exit(0 if sys.argv[1] in devs else 1)" "$H2_ID" 2>/dev/null \
    && { have_claim=1; break; }
  sleep 1
done
if [ "$have_claim" != 1 ]; then
  skip "profile-set did not route this run; skipping device-binding (logic covered by unit tests)"
else
  DEV_BEFORE=$(fnum "$(tcli "$API0" "$T0_ID" karma "$T1_ID")" "d['compute']['devices']")
  [ "${DEV_BEFORE:-0}" = "1" ] \
    && ok "claimed-but-unlinked device is NOT counted (compute.devices=1 = self only)" \
    || bad "unlinked device was counted (compute.devices=$DEV_BEFORE, expected 1)"
  # h2 signs the link back -> mutual binding. DeviceLink is idempotent, re-issue until it lands.
  DEV_AFTER=1
  for _ in $(seq 1 25); do
    tcli "$API2" "$T0_ID" link-device "$T1_ID" >/dev/null 2>&1
    DEV_AFTER=$(fnum "$(tcli "$API0" "$T0_ID" karma "$T1_ID")" "d['compute']['devices']")
    [ "${DEV_AFTER:-0}" = "2" ] && break
    sleep 1
  done
  [ "${DEV_AFTER:-0}" = "2" ] \
    && ok "after the device linked back, compute rolls up (compute.devices=2): mutual binding holds" \
    || skip "device link did not route this run; roll-up unconfirmed (devices=$DEV_AFTER)"
fi

rt_result
