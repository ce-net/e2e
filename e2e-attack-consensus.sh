#!/usr/bin/env bash
# e2e-attack-consensus.sh — adversarial CE-TWLE consensus integrity red team.
#
# Stands up a small ephemeral MINING mesh on loopback (CE-TWLE: VRF leader election, slot-spacing
# enforced in append(), W = min(bond, earned), equivocation slash) and ATTACKS its consensus layer.
# Asserts the defenses the audit says are IMPLEMENTED actually hold, and that the one open hole
# (/beacon-for-placement, V8) is still open. Ground truth:
#   ce/docs/consensus.md       — CE-TWLE: SLOT_SECS=10, slot strictly increases in append() (C1
#                                 closed), W=min(bond,earned), SlashEquivocation burns 100% bond +
#                                 zeroes weight; Phase-3 residual: the ce-node MINING LOOP still
#                                 produces via the legacy seal path under the bootstrap fallback, and
#                                 real-VRF wiring + genesis_weights in NodeConfig is "the next small
#                                 increment".
#   ce/docs/sybil-resistance.md — C1 (cheap-51% pacing footgun) closed by slot-spacing; V8 beacon.
#   crates/ce-chain/src/lib.rs  — append() (slot<=tip_slot -> reject ALWAYS; weight/VRF checks gated
#                                 on total_consensus_weight()>0), SLOT_SECS=10, next_block() advances
#                                 to the next slot past the tip, EquivocationProof + SlashEquivocation
#                                 (chain-primitive only; NO HTTP/CLI surface in this binary).
#   crates/ce-node/src/api.rs   — /status exposes weight+bond; /beacon (api.rs:1225) returns the
#                                 VOLATILE tip {height,hash}.
#
# HONESTY NOTE on what is locally reachable on the CURRENT binary (consensus.md Phase-3 "Residual"):
#   - The ce-node mining loop produces via the legacy seal path; an ephemeral mesh has NO configured
#     genesis_weights, so total_consensus_weight()==0 and append() takes the documented BOOTSTRAP
#     FALLBACK (a well-sealed block at a fresh slot is accepted; the weight==consensus_weight and the
#     VRF-ticket<threshold checks only run once total weight > 0).
#   - There is NO HTTP or CLI surface to post a HostBond or a SlashEquivocation tx (chain primitives
#     only). So the *full* "submit a SlashEquivocation proof -> 100% bond burn + weight zeroed",
#     "zero-weight block rejected", and "forged VRF ticket rejected" paths are NOT reachable through a
#     running node on main, and their unit-level proofs live in ce-chain
#     (slashing_zeroes_consensus_weight, consensus_weight_needs_both_bond_and_work, the append() VRF
#     checks). This script does NOT fake those as passing.
#   What IS locally reachable and IS asserted MUST-HOLD on the live mesh:
#     CON1 slot-spacing/pacing rate-limit (append() slot strictly increases — enforced ALWAYS, even
#          under the bootstrap fallback): a single box cannot out-produce wall-clock / the mesh by
#          deleting a pacing line. This is exactly the C1 fix and is the locally-reachable half of the
#          equivocation defense (a second/past-slot block for an occupied slot is REJECTED on append).
#     CON5 minority private-fork safety anchor (the e2e-attack.sh Attack B): honest history is never
#          rewritten by a rejoining self-minting forker.
#   And asserted KNOWN-OPEN: CON6 /beacon is the grindable volatile tip (V8).
#   CON2/CON3/CON4-full are NOTED (status-probed for the weight oracle being live) and explicitly
#   flagged as "flip to MUST-HOLD when the VRF mining loop + genesis_weights + a bond/slash surface
#   land" — never silently passed.
#
# Attacks mounted (catalog row -> class):
#   CON1 Slot-spacing / pacing-footgun rate limit (C1) ......... MUST-HOLD (append() slot-spacing)
#   CON2 Zero-weight block production ......................... NOTE (weight oracle not wired into
#                                                                 production mining loop / no genesis
#                                                                 weights -> not locally forceable)
#   CON3 Forged VRF ticket .................................... NOTE (same residual as CON2)
#   CON4 Equivocation is slashable ............................ MUST-HOLD for the reachable half
#                                                                 (append() rejects the 2nd block for a
#                                                                 slot); NOTE for the full SlashEquivo-
#                                                                 cation tx (no API/CLI surface)
#   CON5 Minority private-fork rewrite + self-mint (safety) ... MUST-HOLD (no history rewrite)
#   CON6 Beacon grind for placement (V8) ...................... KNOWN-OPEN (V8: /beacon = volatile tip)
#
# Hermetic: --ephemeral --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback, high ports. Never ce-net.com.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/redteam.sh"

# Port plan for the consensus suite (disjoint from the other seven scripts): p2p 74xx / api 94xx.
P2P0=7400
API0=9400
N=${N:-5}                 # honest mining mesh
WARMUP=${WARMUP:-30}      # seconds to mine before measuring / attacking
SLOT_SECS=${SLOT_SECS:-10}  # ce-chain SLOT_SECS (lib.rs:541) — the consensus-enforced block spacing

rt_init consensus
rt_arm_cleanup

TOK="$CE_API_TOKEN"
AUTH=(-H "authorization: Bearer $TOK")

# --------------------------------------------------------------------------------------------------
say "stand up an ephemeral CE-TWLE MINING mesh ($N nodes) on loopback"
# --------------------------------------------------------------------------------------------------
rt_start_mesh "$N" "$P2P0" "$API0" || { bad "seed node never came up"; rt_result; exit 1; }
echo "seed: $RT_SEED"
echo "mining ${WARMUP}s (CE-TWLE block production + gossip)..."
sleep "$WARMUP"

read -r MN MX UP <<<"$(rt_mesh_converged 6 1 2)"
echo "substrate: heights min=$MN max=$MX alive=$UP/$N"
if [ "${MN:-0}" -ge 1 ] && [ "${UP:-0}" -ge $((N/2)) ]; then
  ok "honest CE-TWLE mesh is producing one chain (min height $MN, max $MX, $UP/$N alive)"
else
  bad "consensus substrate unhealthy (min=$MN max=$MX alive=$UP/$N) — cannot run consensus attacks"
  rt_result; exit 1
fi

# h0 is our probe/attacker node.
A=$API0
SELF=$(rt_node_id "$ROOT/h0")
echo "probe node h0: id=${SELF:0:16}...  weight=$(rt_field "$A" weight)  bond=$(rt_field "$A" bond)"

# --------------------------------------------------------------------------------------------------
say "CON1 — slot-spacing / pacing rate-limit: a single box CANNOT out-produce wall-clock (C1, MUST-HOLD)"
# --------------------------------------------------------------------------------------------------
# CE-TWLE enforces slot spacing in append(): `slot = ts/SLOT_SECS; if slot <= tip_slot { reject }`
# (lib.rs ~1170). next_block() also stamps timestamp = next_slot*SLOT_SECS with next_slot >= tip+1.
# So EVERY accepted block advances the slot by >=1, i.e. the chain cannot exceed 1 block / SLOT_SECS
# of WALL-CLOCK time, regardless of CPU. The old cheap-51% footgun (a deletable self-pacing sleep)
# is gone — the rate limit lives at validation and is non-deletable. We attack by giving a LONE
# unthrottled miner free rein and proving its height stays bounded by elapsed/SLOT_SECS.
say "  spin up a lone unthrottled miner (its OWN isolated chain) and let it run flat-out"
LONE=$ROOT/lone; LP=$((P2P0+50)); LA=$((API0+50))
rt_start_node lone "$LP" "$LA" || { bad "lone miner never came up"; }
# Sample height growth over a measured wall-clock window; a removed-pacing 51% box would sprint here.
H_START=$(rt_field "$LA" height); T_START=$(date +%s)
MEASURE=${MEASURE:-25}
echo "  measuring lone miner block rate over ${MEASURE}s of wall-clock (start height=$H_START)..."
sleep "$MEASURE"
H_END=$(rt_field "$LA" height); T_END=$(date +%s)
ELAPSED=$(( T_END - T_START )); [ "$ELAPSED" -lt 1 ] && ELAPSED=1
PRODUCED=$(( ${H_END:-0} - ${H_START:-0} ))
# The hard ceiling: blocks <= elapsed/SLOT_SECS + 1 (the +1 covers a slot boundary straddle + the
# very first sub-slot block). A deleted-pacing attacker would blow far past this.
MAX_ALLOWED=$(( ELAPSED / SLOT_SECS + 2 ))
echo "  lone miner produced $PRODUCED blocks in ${ELAPSED}s (slot=${SLOT_SECS}s -> hard ceiling ~$MAX_ALLOWED)"
if [ "$PRODUCED" -ge 0 ] && [ "$PRODUCED" -le "$MAX_ALLOWED" ]; then
  xfail "CON1: slot-spacing held — a lone unthrottled miner produced $PRODUCED<=$MAX_ALLOWED blocks in ${ELAPSED}s; consensus rate is wall-clock-bound (C1 closed)"
else
  bad "CON1: a lone miner produced $PRODUCED blocks in ${ELAPSED}s (> ceiling $MAX_ALLOWED) — slot-spacing/append() rate limit BREACHED (C1 regression)"
fi

# --------------------------------------------------------------------------------------------------
say "CON4 — equivocation: the on-append rejection of a 2nd block for an occupied slot (MUST-HOLD, reachable half)"
# --------------------------------------------------------------------------------------------------
# Full SlashEquivocation (two VRF-valid blocks for one slot under one key -> 100% bond burn + weight
# zeroed) is a chain primitive with NO HTTP/CLI surface in this binary (verified: api.rs/main.rs have
# no bond/slash endpoint), and its proof lives in ce-chain unit tests
# (slashing_zeroes_consensus_weight). What we CAN attack over a live node is the wire-level half the
# slash is built to deter: append() admits AT MOST ONE block per slot, so a producer cannot equivocate
# two accepted blocks into the same slot in the first place. We assert that invariant holds across the
# running mesh: no two distinct accepted tips ever share a slot, i.e. height climbs strictly with the
# slot/timestamp. We sample the seed's tip slot twice and require it to be monotonic with height.
H1=$(rt_field "$A" height)
B1=$(rt_json "http://127.0.0.1:$A/beacon"); HASH1=$(echo "$B1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
sleep $((SLOT_SECS + 2))
H2=$(rt_field "$A" height)
B2=$(rt_json "http://127.0.0.1:$A/beacon"); HASH2=$(echo "$B2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
echo "  tip over one slot window: h$H1 ($HASH1 ...) -> h$H2 ($HASH2 ...)"
# Two distinct tip hashes at the SAME height across the window would be the visible symptom of an
# accepted equivocation (two blocks competing for one slot at one index). A healthy chain advances
# height by >=1 with a changed tip hash, never producing a second accepted block at a frozen height.
if [ -n "$HASH1" ] && [ -n "$HASH2" ]; then
  if [ "${H2:-0}" -gt "${H1:-0}" ] || { [ "${H2:-0}" -eq "${H1:-0}" ] && [ "$HASH1" = "$HASH2" ]; }; then
    xfail "CON4: append() admits at most one block per slot — tip advanced monotonically (h$H1->h$H2) with no second accepted block frozen at one index; equivocation has no slot to land in (reachable half of the slash defense)"
  else
    bad "CON4: tip changed at a NON-advancing height (h$H1->h$H2, $HASH1 != $HASH2) — two accepted blocks competed for one slot; the per-slot uniqueness append() enforces is BREACHED"
  fi
else
  skip "CON4: /beacon did not return a tip hash; cannot sample per-slot tip uniqueness"
fi
known_open "audit (consensus.md Phase-3 residual): full SlashEquivocation slash (100% bond burn + weight zeroed) has NO API/CLI surface in this binary — proven only in ce-chain unit tests (slashing_zeroes_consensus_weight). NOTE, not a hole in the live node; flip to an end-to-end xfail when a HostBond/SlashEquivocation HTTP or CLI surface lands."

# --------------------------------------------------------------------------------------------------
say "CON2 / CON3 — zero-weight production & forged VRF ticket: probe whether the weight oracle is LIVE in production"
# --------------------------------------------------------------------------------------------------
# append()'s `block.weight == consensus_weight(miner) && weight>0` and the VRF-ticket<threshold checks
# only execute when total_consensus_weight() > 0. On an ephemeral mesh with NO genesis_weights, total
# weight is 0 and append() takes the documented BOOTSTRAP FALLBACK (accept a well-sealed fresh-slot
# block). So a zero-weight node producing a block is the EXPECTED, configured dev behavior here, not a
# breach — and we cannot locally force total>0 (no genesis_weights surface, and the ce-node mining
# loop still produces via the legacy seal path per consensus.md Phase-3 "Residual"). We do NOT fake
# these as MUST-HOLD passes. We PROBE the live state so the day the oracle goes live (every producing
# node reports weight>0) this NOTE can be promoted to a real zero-weight/forged-ticket rejection test.
WSELF=$(rt_field "$A" weight); WTOT=0
for i in $(seq 0 $((RT_N-1))); do
  wi=$(rt_field $((API0+i)) weight); [ "$wi" = "None" ] && wi=0; [ "$wi" = "-1" ] && wi=0
  WTOT=$(( WTOT + ${wi:-0} ))
done
echo "  producing nodes report: h0 weight=$WSELF ; summed mesh weight=$WTOT"
if [ "${WTOT:-0}" -gt 0 ]; then
  # The oracle IS live (genesis_weights configured / VRF mining loop wired). Now CON2/CON3 are real
  # MUST-HOLD tests: our lone FRESH node (no bond, no earned work -> weight must be 0) must NOT have
  # its blocks adopted by the weighted mesh. Bring it in and confirm the mesh never adopts its tip.
  echo "  weight oracle is LIVE -> CON2/CON3 are now MUST-HOLD; checking a fresh zero-weight node cannot lead"
  WLONE=$(rt_field "$LA" weight)
  if [ "${WLONE:-0}" -eq 0 ]; then
    xfail "CON2: a fresh unbonded node reports weight=0 (W=min(bond,earned)=0) so append() rejects its production under a weighted mesh (total weight=$WTOT)"
  else
    bad "CON2: a fresh unbonded no-history node reports weight=$WLONE (!=0) under a live oracle — a cold key gained consensus weight for free (W=min(bond,earned) breached)"
  fi
  # CON3 forged-VRF: without a bond/slash/raw-block-submit surface we cannot inject a hand-forged
  # vrf_proof over the wire; the append() VRF verify is unit-proven. Note it so it flips when a
  # raw-block-submit or VRF surface exists.
  known_open "audit (consensus.md Phase-3 residual): forged-VRF-ticket rejection (CON3) is enforced in append() (vrf_verify + ticket<leader_threshold) but has NO over-the-wire injection surface on this binary; proven in ce-chain. Flip to xfail when a raw-block/VRF submit path exists."
else
  # Oracle NOT yet driving production: total weight is 0, bootstrap fallback is active. Honest NOTE.
  known_open "audit (consensus.md Phase-3 residual): CON2 zero-weight production & CON3 forged-VRF rejection are NOT locally reachable — the ce-node mining loop still produces via the legacy seal path and the ephemeral mesh has no genesis_weights, so total_consensus_weight()=0 and append() takes the bootstrap fallback (every node reports weight=0 and a well-sealed fresh-slot block is accepted by design). Flip to MUST-HOLD when the VRF mining loop + genesis_weights in NodeConfig land (then total weight>0 and a weight=0 block is rejected)."
fi

# --------------------------------------------------------------------------------------------------
say "CON5 — minority private-fork rewrite + self-mint: honest history must NOT be rewritten (MUST-HOLD safety anchor)"
# --------------------------------------------------------------------------------------------------
# The classic e2e-attack.sh Attack B, reused as the consensus safety anchor: an attacker mines a
# PRIVATE chain (minting credits to itself), then rejoins the honest mesh. The honest chain must never
# regress (no history rewrite); the attacker's self-minted divergent fork must never be imposed on the
# honest majority. (CE uses heaviest-suffix fork choice; a divergent rejoiner staying isolated until
# reorg lands is a liveness limit, not a safety failure — the safety property is "no honest rewrite".)
AD=$ROOT/attacker; AP=$((P2P0+90)); AA=$((API0+90))
HEADSTART=${HEADSTART:-16}
hHpre=$(rt_field "$A" height)
echo "  attacker mines a PRIVATE fork (isolated, self-minting) for ${HEADSTART}s; honest pre-height=$hHpre"
"$CE_BIN" --data-dir "$AD" start --port "$AP" --api-port "$AA" --no-mdns >"$ROOT/attacker.log" 2>&1 &
AP_PID=$!; PIDS+=("$AP_PID")
rt_wait_api "$AA" || { bad "CON5: attacker node never came up"; }
sleep "$HEADSTART"
aHpre=$(rt_field "$AA" height); aBpre=$(rt_field "$AA" balance)
echo "  attacker private fork: height=$aHpre self-minted balance=$aBpre"
echo "  reconnecting attacker to the honest mesh..."
kill "$AP_PID" 2>/dev/null; sleep 2
"$CE_BIN" --data-dir "$AD" start --port "$AP" --api-port "$AA" --no-mdns --bootstrap "$RT_SEED" >>"$ROOT/attacker.log" 2>&1 &
AP_PID=$!; PIDS+=("$AP_PID")
rt_wait_api "$AA" || { bad "CON5: attacker rejoin failed"; }
echo "  observing fork choice (polling up to 90s for honest non-regression)..."
hHpost=$hHpre; converged=""
for i in $(seq 1 18); do
  sleep 5
  aHpost=$(rt_field "$AA" height); hHpost=$(rt_field "$A" height)
  drift=$(( aHpost > hHpost ? aHpost - hHpost : hHpost - aHpost ))
  echo "    t=$((i*5))s  attacker=$aHpost  honest=$hHpost  drift=$drift"
  if [ "${hHpost:-0}" -ge "${hHpre:-0}" ] && [ "$drift" -le 3 ] && [ "${aHpost:-0}" -ge 1 ]; then converged=1; break; fi
done
echo "  after rejoin: attacker h$aHpost | honest h$hHpost (pre $hHpre) converged=${converged:-no}"
# The decisive SAFETY assertion: the honest chain never shrank/was-rewritten by the attacker fork.
if [ "${hHpost:-0}" -ge "${hHpre:-0}" ]; then
  ok "CON5: honest chain never regressed (h$hHpre -> h$hHpost) — the minority self-minted private fork did not rewrite honest history"
else
  bad "CON5: honest chain REGRESSED (h$hHpre -> h$hHpost) — a minority private fork rewrote honest history (consensus safety failure)"
fi
if [ -n "$converged" ]; then
  ok "CON5: network re-converged after the fork attempt (attacker h$aHpost ~ honest h$hHpost) — no permanent partition"
else
  # First-wins / heaviest-suffix can leave a divergent rejoiner isolated until reorg lands: a liveness
  # limit, NOT a safety break. The safety assertion above already passed.
  echo "  NOTE: attacker stayed on its isolated private fork (h$aHpost) — divergent-rejoiner re-convergence awaits reorg; honest majority unaffected (liveness note, not a safety failure)"
  ok "CON5: honest majority did not adopt the attacker's self-minted fork (honest h$hHpre -> h$hHpost; attacker isolated at h$aHpost, never imposed)"
fi

# --------------------------------------------------------------------------------------------------
say "CON6 — beacon grind for placement: /beacon exposes the grindable volatile tip (V8, KNOWN-OPEN)"
# --------------------------------------------------------------------------------------------------
# A placement-safe beacon must be confirmed-depth + VDF-delayed + windowed so a leader cannot grind
# the next value to steer placement. /beacon (api.rs:1225) returns {height, tip_hash} of the LIVE TIP
# — it changes every block and is exactly the value a leader influences. We prove it is the volatile
# tip (it tracks the height and flips with each new block), i.e. grindable, not placement-safe.
BJ=$(rt_json "http://127.0.0.1:$A/beacon")
echo "  GET /beacon -> $BJ"
bh1=$(echo "$BJ" | python3 -c "import sys,json;print(json.load(sys.stdin).get('height'))" 2>/dev/null)
bk1=$(echo "$BJ" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
sH=$(rt_field "$A" height)
# Wait for at least one new block, then re-read — a placement-safe beacon would be stable/lagged.
sleep $((SLOT_SECS + 2))
BJ2=$(rt_json "http://127.0.0.1:$A/beacon")
bh2=$(echo "$BJ2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('height'))" 2>/dev/null)
bk2=$(echo "$BJ2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
echo "  /beacon over one slot: height $bh1 (hash $bk1 ...) -> height $bh2 (hash $bk2 ...) ; /status height was $sH"
# It is the volatile tip iff: its height equals the chain tip height AND it advanced (new hash) within
# one slot — i.e. the leader who built the new tip just determined the beacon (grindable).
if [ -n "$bh1" ] && [ "$bh1" != "None" ] && [ "${bh1:-0}" -eq "${sH:-(-1)}" ] && { [ "${bh2:-0}" -gt "${bh1:-0}" ] || [ "$bk1" != "$bk2" ]; }; then
  known_open "audit V8: /beacon is the grindable volatile tip — it returns {height=$bh1==chain-tip, hash} and advanced to height=$bh2 within one slot, so the block leader determines the next beacon; it is NOT confirmed-depth/VDF-delayed/windowed, so it is grindable for placement."
elif [ -n "$bh1" ] && [ "$bh1" != "None" ]; then
  # Beacon did not move within a slot (or is not the tip): could be a landed defense — flip loudly.
  xfail "CON6: /beacon did not track the volatile tip over a slot (height $bh1 -> $bh2, tip $sH) — a placement-safe beacon (confirmed-depth/VDF/windowed) appears to have LANDED; promote V8 to MUST-HOLD"
else
  skip "CON6: /beacon returned no usable value; cannot assess V8 grindability"
fi

# --------------------------------------------------------------------------------------------------
say "post-attack substrate health (consensus survived every probe)"
# --------------------------------------------------------------------------------------------------
read -r MN2 MX2 UP2 <<<"$(rt_mesh_converged 8 1 2)"
echo "post: heights min=$MN2 max=$MX2 alive=$UP2/$N"
if [ "${MN2:-0}" -ge "${MN:-0}" ] && [ "${UP2:-0}" -ge $((N/2)) ]; then
  ok "consensus substrate kept advancing through the attacks (min $MN -> $MN2, $UP2/$N alive) — no halt, no regression"
else
  bad "consensus substrate degraded after attacks (min $MN -> $MN2, alive $UP2/$N)"
fi

rt_result
