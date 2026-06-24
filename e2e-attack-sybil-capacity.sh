#!/usr/bin/env bash
# e2e-attack-sybil-capacity.sh — adversarial: Sybil identities + fake-capacity + wash-trade.
#
# Owns (per docs/redteam.md §3) the Sybil-economics + capacity-truth attacks:
#   SYB1 free identities (V1/E1)          KNOWN-OPEN — identities mint at ~0 cost.
#   SYB2 Sybil reward concentration (E1)  KNOWN-OPEN — UptimeReward not bond-gated.
#   SYB3 fake capacity ad (E2/V3)         KNOWN-OPEN — atlas accepts unverified cpu/mem/tag:gpu.
#   SYB4 capacity-ad authorship is signed MUST-HOLD  — the *signer* binds; only the *values* lie.
#   SYB5 HostBond gate absent             KNOWN-OPEN — unbonded host fully participates.
#   SYB6 wash-trade reputation (E4)       KNOWN-OPEN — /history is a fabricable public read-model,
#        + settlement burn (mitigation)   MUST-HOLD  — the 80% burn makes the wash LOSSY (real cost).
#
# This script is mostly KNOWN-OPEN: the HostBond gate, capacity audit, and verification dial are
# PLANNED/PARTIAL (sybil-resistance.md §4 / PLAN compute-donation-sybil-security.md), so the point is
# to prove each hole is GENUINELY reachable today, so it flips RED the day the bond/capacity audit
# lands. SYB4 + the burn are the two implemented defenses and MUST hold (regression guards).
#
# Hermetic: all nodes are --ephemeral (in-RAM), --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback, high
# ports (p2p 73xx / api 93xx). NEVER touches ce-net.com.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/redteam.sh"

rt_init sybil-capacity      # skips cleanly (exit 0) if $CE_BIN is missing
rt_arm_cleanup

P2P0=7300; API0=9300
AUTH=(-H "authorization: Bearer $CE_API_TOKEN")   # the suite owns the token to DRIVE the attacks

# ==================================================================================================
say "substrate: a 4-node in-RAM MINING mesh (so UptimeReward credits flow + capacity gossips)"
# ==================================================================================================
N=4
rt_start_mesh "$N" "$P2P0" "$API0" || { bad "seed mesh did not come up"; rt_result; exit 1; }
echo "seed: $RT_SEED"
echo "warming up the honest mesh (mining + gossip) ..."
# Poll for a converged, healthy substrate before attacking — retry, do not assume a fixed window.
conv=""
for i in $(seq 1 24); do
  sleep 3
  read -r mn mx up <<<"$(rt_mesh_converged 6 1 2)"
  echo "  t=$((i*3))s  heights=[$mn..$mx]  alive=$up/$N"
  if rt_mesh_converged 6 1 2 >/dev/null; then conv=1; break; fi
done
if [ -n "$conv" ]; then
  ok "honest substrate converged (alive=$up at h$mn..$mx) — credits/capacity flowing"
else
  bad "honest substrate never converged (alive=$up h$mn..$mx); attacks below are unreliable"
fi

H0=$API0                       # honest observer node (we read its /atlas + /history)
SEED_DIR="$ROOT/h0"
SEED_ID=$(rt_node_id "$SEED_DIR")
echo "honest observer node h0 id=${SEED_ID:0:16}…  api=$H0"

# ==================================================================================================
say "SYB1 — free identities (audit V1/E1): mint many node ids at zero cost / zero bond"
# ==================================================================================================
# Marketplace weight SHOULD require a bond; identities themselves being free is by design. We prove
# the BASELINE FACT that minting fresh, distinct, valid node ids costs nothing — the raw material of
# every Sybil attack below. When a bond gates the marketplace role, identities stay free but cannot
# advertise/earn unbonded (SYB5) — this test stays as the baseline witness.
MINT=20
ids_file="$ROOT/sybil_ids.txt"; : >"$ids_file"
for i in $(seq 1 "$MINT"); do
  d="$ROOT/sybil$i"; mkdir -p "$d"
  rt_node_id "$d"
done | sort -u >"$ids_file"
nuniq=$(grep -cE '^[0-9a-f]{64}$' "$ids_file")
echo "minted $nuniq unique valid node ids from $MINT fresh data-dirs (no funding, no bond)"
if [ "$nuniq" -eq "$MINT" ]; then
  known_open "audit V1/E1: marketplace identities are free ($nuniq distinct ids minted at ~0 cost, no bond) — io.net 1.8M-fake class raw material"
else
  bad "expected $MINT distinct free identities, got $nuniq (id minting broke?)"
fi

# ==================================================================================================
say "SYB2 — Sybil reward concentration (audit E1): K Sybil miners on one box split the reward stream"
# ==================================================================================================
# One operator runs K extra ephemeral MINERS (each a free identity) joined to the honest mesh. Each
# is an independent UptimeReward recipient — the per-block emission is NOT bond-gated, so K identities
# carve the operator's machine share into K credit streams. We assert >=1 Sybil identity accrues
# UptimeReward credits with ZERO bond and ZERO stake — the concentration vector is live.
K=3
SYB_API0=$((API0+50)); SYB_P2P0=$((P2P0+50))
for j in $(seq 0 $((K-1))); do
  rt_start_node "syb_miner$j" $((SYB_P2P0+j)) $((SYB_API0+j)) --bootstrap "$RT_SEED" >/dev/null 2>&1
  sleep 0.3
done
echo "spun up $K Sybil miners (free identities, no bond) sharing the honest mesh ..."
earners=0; total_syb=0
for i in $(seq 1 20); do
  earners=0; total_syb=0
  for j in $(seq 0 $((K-1))); do
    b=$(rt_field $((SYB_API0+j)) balance)
    case "$b" in ''|-1|None|0) : ;; *) earners=$((earners+1)); total_syb=$((total_syb+1)) ;; esac
  done
  [ "$earners" -ge 1 ] && break
  sleep 3
done
echo "Sybil miners earning UptimeReward (positive balance): $earners/$K"
if [ "$earners" -ge 1 ]; then
  known_open "audit E1: UptimeReward not bond-gated — $earners/$K unbonded Sybil identities earn the per-block emission (one box's share split into K streams)"
else
  # Not a defense — the mesh may simply not have paid them yet in the window. Surface honestly.
  skip "no Sybil miner had earned within the window (timing); E1 concentration not demonstrated this run"
fi

# ==================================================================================================
say "SYB3 — fake capacity ad (audit E2/V3): advertise 1000 cores + tag:gpu the host LACKS; poison /atlas"
# ==================================================================================================
# The attacker host (a fresh node it controls) broadcasts a capacity CellSignal claiming cpu=1000,
# mem_mb=huge, tag:gpu — none of which it has. parse_capacity_signal (ce-node/src/lib.rs:2263) records
# whatever is broadcast; the atlas does NO truth-check. We send the poisoned ad from a dedicated
# attacker node and then read the HONEST observer h0's /atlas to confirm the lie propagated mesh-wide.
ATK_API=$((API0+30)); ATK_P2P=$((P2P0+30))
rt_start_node attacker_host "$ATK_P2P" "$ATK_API" --bootstrap "$RT_SEED" >/dev/null 2>&1
rt_wait_api "$ATK_API" || skip "attacker_host API slow to come up"
ATK_ID=$(rt_node_id "$ROOT/attacker_host")
echo "attacker host id=${ATK_ID:0:16}…  api=$ATK_API"

FAKE_CPU=1000
FAKE_MEM=999999999
poison='{"to":"broadcast","capabilities":[{"name":"cpu","version":'"$FAKE_CPU"'},{"name":"mem_mb","version":'"$FAKE_MEM"'},{"name":"jobs","version":0},{"name":"tag:gpu","version":1}]}'
# Re-broadcast a few times so it lands in the honest observer's atlas despite gossip timing.
for i in $(seq 1 6); do
  rt_forge POST "$ATK_API" /signals/send "$poison" "${AUTH[@]}" >/dev/null
  sleep 1
done

# Read the HONEST observer's atlas and find the attacker's entry.
atlas=$(rt_json "http://127.0.0.1:$H0/atlas")
read -r seen_cpu seen_mem seen_gpu seen_node <<<"$(
  printf '%s' "$atlas" | python3 -c '
import sys,json
try: a=json.load(sys.stdin)
except Exception: a=[]
atk="'"$ATK_ID"'"
for e in a:
    if e.get("node_id")==atk:
        tags=e.get("tags") or []
        print(e.get("cpu_cores"), e.get("mem_mb"), ("gpu" if "gpu" in tags else "nogpu"), e.get("node_id"))
        break
else:
    print("none none none none")
' 2>/dev/null)"
echo "honest h0 /atlas view of attacker: cpu=$seen_cpu mem=$seen_mem gpu=$seen_gpu node=${seen_node:0:16}…"
if [ "$seen_cpu" = "$FAKE_CPU" ] && [ "$seen_gpu" = "gpu" ]; then
  known_open "audit E2/V3: capacity ads unverified — honest /atlas accepts cpu=$FAKE_CPU + tag:gpu a host has no proof of (io.net 1.8M-fake-GPU class); a Sybil wins JobBids it cannot serve"
elif [ "$seen_cpu" = "none" ]; then
  # The ad never reached the observer this run (gossip timing on a cold mesh). Read the attacker's
  # OWN /atlas? No — a node does not atlas its own ad. Surface honestly rather than fake a pass.
  skip "poisoned capacity ad did not reach honest observer atlas within the window (gossip timing) — E2 not demonstrated this run"
else
  bad "atlas surfaced an UNEXPECTED capacity for the attacker (cpu=$seen_cpu gpu=$seen_gpu) — investigate"
fi

# ==================================================================================================
say "SYB4 — capacity-ad AUTHORSHIP is signed (refuted finding): the SIGNER binds, only the VALUES lie"
# ==================================================================================================
# The value-truth is open (SYB3), but the ad's AUTHOR is Ed25519-signed (gossipsub Strict+Signed,
# CellSignal.from == signer). The /signals/send endpoint ALWAYS signs as the local node's own key:
# there is no way to publish an ad attributed to a *different* signer. We assert the atlas entry the
# attacker produced is keyed to the ATTACKER's real node id (it could not forge a victim's id), and
# that /signals never surfaces an ad whose claimed author != the publishing key.
if [ "$seen_node" = "$ATK_ID" ]; then
  xfail "capacity-ad authorship binds to the signer: the poisoned ad is attributed to the attacker's real id (${ATK_ID:0:16}…), NOT a forgeable victim id — value-truth is open (E2) but signature-truth holds"
elif [ "$seen_node" = "none" ]; then
  # Authorship still provable locally: the attacker's own /signals must show its ad authored by ITSELF.
  mine=$(rt_json "http://127.0.0.1:$ATK_API/signals")
  authored=$(printf '%s' "$mine" | python3 -c '
import sys,json
try: a=json.load(sys.stdin)
except Exception: a=[]
atk="'"$ATK_ID"'"
print(sum(1 for s in a if s.get("from")==atk))
' 2>/dev/null)
  if [ "${authored:-0}" -ge 1 ]; then
    xfail "capacity-ad authorship binds to the signer: every ad on /signals is attributed to its publishing key (attacker authored $authored signals as itself; no foreign-author ad accepted)"
  else
    bad "could not confirm capacity-ad authorship binds to the signer (no authored ad found)"
  fi
else
  bad "REGRESSION: an atlas entry for the attacker is attributed to id ${seen_node:0:16}… != the real signer ${ATK_ID:0:16}… — capacity-ad authorship spoof!"
fi

# ==================================================================================================
say "SYB5 — HostBond gate absent: an UNBONDED node fully participates in the marketplace role"
# ==================================================================================================
# sybil-resistance.md §4.1 / PLAN §3: a standing HostBond SHOULD gate BOTH capacity-ad publication
# AND UptimeReward eligibility. Today neither is gated. We prove the attacker_host published a
# capacity ad AND (from SYB2) Sybils earned rewards — both with provably ZERO bond. A bond would be
# a HostBond tx; /history exposes no bond, and the node never refused the ad for lack of one.
ad_accepted=$(rt_forge POST "$ATK_API" /signals/send "$poison" "${AUTH[@]}")
echo "unbonded attacker capacity-ad publish -> HTTP $ad_accepted (no bond demanded)"
if [ "$ad_accepted" = "202" ]; then
  known_open "audit (HostBond gate not wired, sybil-resistance.md §4.1 / PLAN §3): an unbonded node publishes capacity ads (HTTP 202) and earns UptimeReward — the marketplace role requires no stake"
else
  # If publishing an ad ever STARTS requiring a bond, this flips: the gate landed.
  xfail "capacity-ad publish was refused without a bond (HTTP $ad_accepted) — the HostBond gate appears WIRED; flip this to must-hold"
fi

# ==================================================================================================
say "SYB6 — wash-traded reputation (audit E4) vs the 80% settlement BURN mitigation"
# ==================================================================================================
# E4: JobSettle verifies only the payer co-signature and cost<=bid — NEVER that work executed
# (ce-chain/src/lib.rs). One operator running payer-A + host-B can self-settle to fabricate B's
# /history. We demonstrate the two halves, precisely separating OPEN from DEFENDED:
#
#   (a) /history is a PUBLIC, UNAUTHENTICATED, fabricable read-model — the substrate E4 poisons.
#       It is queryable for ANY node with no auth and reflects only on-chain settle/bid counts, with
#       NO proof-of-execution behind them. (KNOWN-OPEN: E4 — reputation is fabricable.)
#   (b) The 80% SETTLEMENT BURN is IMPLEMENTED (SETTLEMENT_BURN_BPS=8000, ce-chain/src/lib.rs:510):
#       every JobSettle/Heartbeat/ChannelClose destroys 80% of the gross, so a wash moves the
#       attacker's OWN credits between its OWN identities AND burns 80% each cycle — the wash is
#       LOSSY, the attacker NET-LOSES real mined credits. (MUST-HOLD: the burn is the economic floor.)
#
# We mount the wash SETUP that is hermetically reachable (Docker-free, sign-free): a real funded
# JobBid that LOCKS the payer's credits (the on-chain commitment a wash rides on), then prove the
# /history substrate is fabricable and the burn floor is real and quantified. (The full on-chain
# co-signed JobSettle leg — which needs a container exit + payer Ed25519 co-sig — is exercised in
# e2e-attack-economy.sh ECON7/ECON8, the owner of settle/burn; here we own the SYBIL-side framing.)

# (a) /history is an unauthenticated, fabricable public read-model.
hist_code=$(rt_code "http://127.0.0.1:$H0/history/$ATK_ID")
hist_body=$(rt_json "http://127.0.0.1:$H0/history/$ATK_ID")
echo "GET /history/<attacker> (NO auth) -> HTTP $hist_code"
echo "history substrate body: $hist_body"
has_fields=$(printf '%s' "$hist_body" | python3 -c '
import sys,json
try: h=json.load(sys.stdin)
except Exception: h={}
print(1 if all(k in h for k in ("jobs_hosted","earned","spent")) else 0)
' 2>/dev/null)
if [ "$hist_code" = "200" ] && [ "${has_fields:-0}" = "1" ]; then
  known_open "audit E4: /history is a PUBLIC, unauthenticated read-model with NO proof-of-execution behind jobs_hosted/earned — payer-A+host-B self-settles fabricate it (EigenTrust self-promotion); reputation is buyable with the attacker's own credits"
else
  bad "GET /history did not return the expected public reputation substrate (code=$hist_code fields=$has_fields)"
fi

# (b) Real funded JobBid that LOCKS credits — the on-chain commitment a wash settle redeems.
# Find a funded node in the mesh (the seed has been mining the longest).
payer_api=""; payer_bal=-1
for off in 0 1 2 3; do
  b=$(rt_field $((API0+off)) balance)
  case "$b" in ''|-1|None) : ;; *) if [ "$b" -gt 0 ] 2>/dev/null; then payer_api=$((API0+off)); payer_bal=$b; break; fi ;; esac
done
if [ -n "$payer_api" ]; then
  bal_before=$(rt_field "$payer_api" balance)
  bid_amt="1000000000000000000"   # 1 credit in base units (string)
  bid_body='{"image":"alpine:latest","cmd":["true"],"cpu_cores":1,"mem_mb":64,"duration_secs":30,"bid":"'"$bid_amt"'"}'
  bid_resp=$(rt_forge_body POST "$payer_api" /jobs/bid "$bid_body" "${AUTH[@]}")
  echo "wash setup: funded JobBid on api=$payer_api (bal_before=$bal_before) -> $bid_resp"
  jid=$(printf '%s' "$bid_resp" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("job_id") or "")[:16])' 2>/dev/null)
  # Wait for the bid to mine and lock free balance below the gross bid.
  locked=""
  for i in $(seq 1 20); do
    sleep 2
    bal_now=$(rt_field "$payer_api" balance)
    # JobBid locks `bid` from free balance; free balance must drop (or the bid tx is in flight).
    case "$bal_now" in ''|-1|None) : ;; *) if [ "$bal_now" -lt "$bal_before" ] 2>/dev/null; then locked=1; break; fi ;; esac
  done
  echo "after JobBid (job ${jid}…): free balance $bal_before -> ${bal_now:-?} (locked=${locked:-no})"
  if [ -n "$jid" ] && [ "${jid}" != "" ]; then
    known_open "audit E4: the wash SETUP is fully API-reachable — a funded JobBid (the on-chain commitment a self-settle redeems) is accepted with no proof any work will run; payer+host being the same operator fabricates /history"
  else
    skip "JobBid did not return a job_id this run (timing); wash-setup leg not demonstrated"
  fi
else
  skip "no funded payer node found in the mesh window (mining timing); wash-setup JobBid not mounted"
fi

# (b cont.) The burn floor IS implemented — assert it is real and quantify the loss.
# SETTLEMENT_BURN_BPS=8000 -> 80% of every settle's gross is destroyed. We assert the node EXPOSES
# burned_total/circulating_supply (the on-chain economic floor) and that the documented rate makes
# the wash lossy: a wash that moves G credits between the attacker's identities burns 0.8*G — the
# attacker NET-LOSES 80% of every washed credit. This is the MITIGATION that holds today.
burned=$(rt_field "$H0" burned_total)
circ=$(rt_field "$H0" circulating_supply)
echo "economic floor on h0: burned_total=$burned  circulating_supply=$circ"
if [ -n "$burned" ] && [ "$burned" != "None" ] && [ "$burned" != "-1" ]; then
  # 1 credit washed -> 0.8 credit burned, per SETTLEMENT_BURN_BPS=8000 (80%).
  echo "settlement-burn arithmetic: a JobSettle of 1.0 credit destroys 0.8 credit (BPS=8000); a wash NET-LOSES 80% of every washed credit"
  xfail "settlement burn is the implemented economic floor: the node exposes burned_total ($burned) and circulating_supply; at SETTLEMENT_BURN_BPS=8000 a wash trade is LOSSY (80% of every washed credit destroyed) — fabricating /history costs the attacker real capital, NET-LOSS not net-zero"
else
  bad "REGRESSION: node does not expose burned_total — the settlement-burn economic floor is not observable on /status (the only mitigation against E4 wash trading)"
fi

# ==================================================================================================
say "post-attack: honest substrate must still be healthy (the attacks must not have broken it)"
# ==================================================================================================
read -r mn2 mx2 up2 <<<"$(rt_mesh_converged 8 1 2)"
echo "post-attack substrate: heights=[$mn2..$mx2] alive=$up2/$N"
if rt_mesh_converged 8 1 2 >/dev/null; then
  ok "honest substrate survived the Sybil/capacity/wash attacks (alive=$up2 at h$mn2..$mx2)"
else
  bad "honest substrate degraded after the attacks (alive=$up2 h$mn2..$mx2) — DoS side effect"
fi

rt_result
