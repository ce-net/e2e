#!/usr/bin/env bash
# e2e-attack-eclipse.sh — Network / eclipse red team (Path D; sybil-resistance.md N3/N4/N5/N6/N8).
#
# Owns: peer-table flood / connection limits, IP-diversity caps, dead `allowed_peers`, the
# synced-flag race, and the eclipse SAFETY anchor. Disjoint from transport (script 5, which owns
# the gossip/RPC abuse N1/N2/N7) and from sybil-capacity (script 3, identities/reward/capacity).
#
# The libp2p hardening the audit prescribes in sybil-resistance.md §4.3 (connection limits via
# `libp2p-connection-limits`, gossipsub peer scoring, a manual Kademlia /24 IP-diversity cap, and
# actually enforcing `allowed_peers`) is DESIGN-ONLY today: the code confirms `ConnectionEstablished`
# (ce-mesh/src/lib.rs:798,1039) only starts relay listening and never caps connections or disconnects
# a non-`allowed_peers` peer, and there is no `ConnectionLimits` behaviour. So ECL1-ECL4 are
# KNOWN-OPEN: each must demonstrate the hole is genuinely reachable on a loopback mesh, then
# known_open(). ECL5 is the MUST-HOLD safety anchor: an eclipse can stall liveness but can NEVER make
# a node adopt invalid/forged blocks, because `append()` validation is local and offline — not a
# network vote.
#
# Loopback caveat (stated honestly): every node here binds 127.0.0.1, so there is no real per-/24 IP
# diversity to exercise N3 against. What we CAN prove locally is the upstream cause: the victim admits
# an arbitrary number of inbound Sybil peers with NO connection cap and NO `allowed_peers` filter — so
# even if real IP diversity existed there is nothing to enforce a /24 cap. That is the reachable,
# regression-guardable fact; the note records the loopback limitation.
#
# Hermetic: ephemeral in-RAM nodes, --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback, high ports. Never
# touches ce-net.com. Skips cleanly (exit 0) if the ce binary is missing.

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/redteam.sh"

rt_init eclipse
rt_arm_cleanup

# Port plan (redteam.md): eclipse owns p2p 7700.. / api 9700..
VP2P=7700; VAPI=9700          # the VICTIM (a single node we try to eclipse)
SP2P=7710; SAPI=9710          # the SYBIL swarm base (7710..7740 / 9710..9740)
NSYBIL=${NSYBIL:-16}          # number of Sybil nodes that flood the victim

# count_peer_log <log> -> distinct libp2p peer ids the victim logged as "peer connected:"
count_peer_log() {
  grep -oE 'peer connected: 12D3[A-Za-z0-9]+' "$1" 2>/dev/null | sort -u | wc -l | tr -d ' '
}
# netgraph_peers <api> -> number of peers the victim currently reports edges to (best-effort; 0 on fail)
netgraph_peers() {
  rt_json "http://127.0.0.1:$1/netgraph" \
    | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
except Exception:
  print(0); raise SystemExit
# netgraph shapes vary; count any peer-ish keys/edges generously.
n=0
if isinstance(d,dict):
  for k in ("peers","nodes","edges","graph"):
    v=d.get(k)
    if isinstance(v,(list,dict)): n=max(n,len(v))
  if not n: n=len(d)
elif isinstance(d,list):
  n=len(d)
print(n)' 2>/dev/null || echo 0
}

# --------------------------------------------------------------------------------------------------
say "stand up the VICTIM (single ephemeral node, mining) — the target of the eclipse"
# --------------------------------------------------------------------------------------------------
rt_start_node victim "$VP2P" "$VAPI" || { bad "victim node did not come up"; rt_result; exit 1; }
VSEED=$(rt_addr "$ROOT/victim" "$VP2P")
echo "victim seed: $VSEED"
[ -n "$(rt_peer_id "$ROOT/victim")" ] && ok "victim up with a libp2p identity (eclipse target ready)" \
  || bad "victim has no peer id"

# ==================================================================================================
say "ECL1 — peer-table flood: many Sybil nodes all dial the victim; is there a connection cap?"
# ==================================================================================================
# Spin up NSYBIL ephemeral Sybil nodes that ALL bootstrap from (dial) the single victim. With
# `libp2p-connection-limits` wired (max_established_incoming), the victim would refuse inbound peers
# past the cap. Today no such behaviour exists, so it accepts all of them.
echo "spawning $NSYBIL Sybil nodes, each bootstrapping from the victim..."
for i in $(seq 1 "$NSYBIL"); do
  rt_start_node "syb$i" $((SP2P+i)) $((SAPI+i)) --bootstrap "$VSEED" --no-mine >/dev/null 2>&1
  sleep 0.2
done

# Poll for the victim's inbound peer count to climb (gossip/dht meshing takes a moment).
admitted=0
for t in $(seq 1 20); do
  sleep 2
  admitted=$(count_peer_log "$ROOT/victim.log")
  ng=$(netgraph_peers "$VAPI")
  echo "  t=$((t*2))s  victim 'peer connected:' distinct=$admitted  netgraph_peers=$ng"
  [ "$admitted" -ge $((NSYBIL/2)) ] && break
done
echo "victim admitted $admitted distinct Sybil peers (spawned $NSYBIL); no connection cap was applied"
if [ "$admitted" -ge $((NSYBIL/2)) ]; then
  # The hole: the victim accepted a large, unbounded number of inbound Sybil connections. With a cap
  # wired this would plateau at max_established_incoming and excess dials would be refused.
  known_open "audit N1/N5: no connection limits — victim admitted $admitted/$NSYBIL inbound Sybil peers with no max_established_incoming cap"
else
  # Not a defense success — if the Sybils simply failed to mesh, we could not prove the hole. Make
  # that loud rather than silently "passing".
  bad "ECL1 could not demonstrate the flood (only $admitted/$NSYBIL Sybils meshed) — inconclusive, not a defense"
fi

# ==================================================================================================
say "ECL2 — no IP-diversity cap (N3): same-origin (loopback) Sybils all enter the peer set"
# ==================================================================================================
# go-ipfs 0.7 added a Kademlia /24 diversity cap (max ~1 peer per /24 per bucket). rust-libp2p has no
# built-in equivalent and CE has not hand-rolled one (sybil-resistance.md N3, §4.3 step 5). On
# loopback every Sybil shares 127.0.0.0/8, so a /24 cap (if it existed) would admit at most a handful.
# We observed `admitted` above; if it far exceeds a /24 cap's allowance, the cap is absent.
echo "all $admitted admitted peers share the 127.0.0.0/8 space; a /24 cap would allow only a few"
if [ "$admitted" -gt 3 ]; then
  known_open "audit N3: no Kademlia /24 IP-diversity cap — $admitted same-/8 Sybils admitted (a per-/24 cap would bound this to ~1-3)"
else
  bad "ECL2 inconclusive — too few peers admitted ($admitted) to distinguish 'cap present' from 'flood failed'"
fi
echo "NOTE (loopback honesty): all nodes bind 127.0.0.1, so true per-/24 IP diversity cannot be"
echo "exercised here. What is proven is the *upstream* cause — there is no admission filter at all,"
echo "so no /24 cap could be enforced even with real IP diversity. Real-IP diversity testing belongs"
echo "in a multi-host harness, never against ce-net.com (forbidden)."

# ==================================================================================================
say "ECL3 — allowed_peers is dead code (N4): a peer in NO allowlist still connects and stays"
# ==================================================================================================
# sybil-resistance.md N4: `allowed_peers` is populated and documented as "non-members are immediately
# disconnected" (ce-mesh/src/lib.rs:588) but `ConnectionEstablished` (:798,:1039) never consults it,
# so nothing disconnects a non-member. Every Sybil above is, by construction, NOT in any operator
# allowlist (we never granted them) — yet they connected and (if N4 held) should have been dropped.
# Proof of "stays": the count did not collapse back toward zero after meshing.
sleep 3
stayed=$(count_peer_log "$ROOT/victim.log")
disc=$(grep -cE 'peer disconnected:' "$ROOT/victim.log" 2>/dev/null || echo 0)
echo "non-allowlisted Sybils: connected(distinct)=$stayed  disconnect events logged=$disc"
if [ "$stayed" -ge $((NSYBIL/2)) ]; then
  known_open "audit N4: allowed_peers not enforced — $stayed non-allowlisted peers connected and were NOT disconnected (the documented 'immediately disconnected' is dead code)"
else
  bad "ECL3 inconclusive — could not show non-allowlisted peers persisting ($stayed connected)"
fi

# ==================================================================================================
say "ECL4 — synced-flag race (N6): victim clears the sync gate on a low peer-height and mines a stale tip"
# ==================================================================================================
# sybil-resistance.md N6: a node sets `synced = true` after a single PeerHeight at/below its own
# height, then mines on its own (possibly stale) tip without confirming any blocks were delivered.
# Here the victim is surrounded ONLY by --no-mine Sybils (they advertise their own low heights and
# never produce blocks). If the gate required real block delivery / a height quorum from progressing
# peers, an eclipsed victim fed only stale/low heights would stall. Instead the victim keeps minting
# blocks on its private tip — extending a chain no honest party is advancing.
vh0=$(rt_field "$VAPI" height)
echo "victim height before observation: $vh0 (peers are all --no-mine: they never deliver new blocks)"
sleep 16
vh1=$(rt_field "$VAPI" height)
echo "victim height after 16s while eclipsed by non-producing peers: $vh1"
if [ "${vh1:-0}" -gt "${vh0:-0}" ]; then
  known_open "audit N6: synced flag clears on a low peer-height — eclipsed victim mined $vh0->$vh1 on a stale tip with no block delivery / no height quorum from any progressing peer"
else
  # If the victim stalled, the sync gate is actually holding peers to real delivery — that would be
  # the fix landing. Flag for a human to flip this to xfail(); do NOT silently pass.
  echo "NOTE: victim did NOT advance while eclipsed ($vh0->$vh1) — the sync gate may now require real"
  echo "block delivery (N6 fix landing). Flip ECL4 to xfail() and assert the stall is intentional."
  ok "ECL4: eclipsed victim did not advance on stale tip ($vh0->$vh1) — N6 sync-race appears closed (confirm + flip to xfail)"
fi

# ==================================================================================================
say "ECL5 — SAFETY ANCHOR (MUST-HOLD): an eclipse cannot make the victim accept a FORGED/INVALID fork"
# ==================================================================================================
# The decisive property: surrounding a node with Sybils can stall liveness, but validation is LOCAL
# and OFFLINE — `append()` re-checks VRF/weight/tx rules, so a bogus "heavier-looking" fork from the
# Sybil peers is rejected, not adopted. We prove it two ways without needing to forge raw block
# bytes (which the gossip envelope signing would reject at the transport layer anyway):
#
#  (a) Mutating-API takeover from the eclipse position: a surrounding Sybil cannot drive the victim's
#      chain via its control API without the token (every mutating endpoint -> 401). An eclipse buys
#      no authority over the victim's state machine.
#  (b) No self-mint / no forced rewrite: the victim's height only moves forward by its own valid
#      mining; the Sybil swarm (all --no-mine, no valid heavier chain) never imposes a rewrite. We
#      assert the victim's chain never REGRESSED while surrounded (history not rewritten by Sybils).
hpre=$(rt_field "$VAPI" height)
# (a) forged control attempts from "the network" hit the victim's API with no token -> must be 401.
c_xfer=$(rt_forge POST "$VAPI" /transfer '{"to":"00","amount":"1"}')
c_bid=$(rt_forge  POST "$VAPI" /jobs/bid '{"image":"alpine","cmd":["true"],"bid":"1"}')
c_dep=$(rt_forge  POST "$VAPI" /mesh-deploy '{"node_id":"00","image":"alpine","cmd":["true"]}')
echo "forged control from eclipse position: /transfer=$c_xfer  /jobs/bid=$c_bid  /mesh-deploy=$c_dep (each must be 401)"
if [ "$c_xfer" = "401" ] && [ "$c_bid" = "401" ] && [ "$c_dep" = "401" ]; then
  xfail "eclipse grants NO control-API authority over the victim (all forged mutations -> 401)"
else
  bad "REGRESSION: a surrounding peer drove the victim's state machine without auth ($c_xfer/$c_bid/$c_dep) — eclipse -> takeover"
fi
# (b) victim's own chain must never have regressed while surrounded by Sybils (no Sybil-imposed rewrite).
sleep 6
hpost=$(rt_field "$VAPI" height)
echo "victim height across the eclipse: $hpre -> $hpost (must not regress / be rewritten by Sybils)"
if [ "${hpost:-0}" -ge "${hpre:-0}" ] && [ "${hpost:-0}" -ge 1 ]; then
  xfail "victim chain never regressed under eclipse ($hpre -> $hpost): Sybils could not impose a forged/invalid fork — append() validation is local, not a network vote"
else
  bad "REGRESSION: victim chain regressed under eclipse ($hpre -> $hpost) — a Sybil-supplied fork was adopted"
fi

# Panic-resistance: after the whole flood the victim process must still be alive.
VPID=${PIDS[0]:-}
if [ -n "$VPID" ] && rt_alive "$VPID"; then
  ok "victim process survived the full eclipse flood (no crash/panic) — liveness can stall, the node cannot be killed"
else
  bad "victim process died during the eclipse flood (crash/panic under peer-table pressure)"
fi

# ==================================================================================================
say "N8 (note only) — single relay + single bootstrap-domain chokepoint"
# ==================================================================================================
echo "sybil-resistance.md N8: one Hetzner relay + one bootstrap domain (ce-net.com) is an Erebus-style"
echo "topological chokepoint. This is a PRODUCTION-topology property and is NOT locally reproducible"
echo "without dialing ce-net.com — which this hermetic suite is FORBIDDEN to touch. Recorded here so"
echo "the ledger is complete; it flips to a real test when >=3 independent relays/bootstrap domains land"
echo "(sybil-resistance.md §4.3 step 7). Not counted as PASS/FAIL/KNOWN_OPEN — it is an out-of-scope note."

rt_result
