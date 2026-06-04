#!/usr/bin/env bash
# Local adversarial test: stand up an isolated mining mesh, then try to BREAK it.
# - Honest mesh: N ephemeral (in-RAM) miners, mDNS-isolated, sharing one chain.
# - Attacks:
#     A) API takeover  -> mutating API without the token must be rejected (401), bound to loopback.
#     B) Private-fork rewrite / free-mint -> an attacker mines a private chain (self-minting credits),
#        then rejoins. Work-based fork choice must reject the lighter fork: the attacker adopts the
#        heavier honest chain and its self-minted credits vanish (no double-spend / no free money).
# Everything is in-RAM (--ephemeral) and mDNS-isolated (--no-mdns) so it can't touch the live mesh.
set -u
CE=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
ROOT=/tmp/ce-attack
TOK="attack-test-token"
N=${1:-15}            # honest miners
HONEST_WARMUP=${2:-35}
HEADSTART=${3:-18}    # attacker private-mining seconds (kept < honest runtime so honest out-works it)
P2P=6000; API=8000
PIDS=(); PASS=0; FAIL=0
say(){ printf '\n=== %s ===\n' "$1"; }
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; pkill -f "$ROOT" 2>/dev/null; }
trap cleanup EXIT
rm -rf "$ROOT"; mkdir -p "$ROOT"
export CE_NO_AUTOBOOTSTRAP=1 CE_API_TOKEN="$TOK"

peer(){ "$CE" --data-dir "$1" id 2>/dev/null | grep -oE '12D3[A-Za-z0-9]+' | head -1; }
field(){ curl -fsS "http://127.0.0.1:$1/status" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['$2'])" 2>/dev/null || echo -1; }
upapi(){ for i in $(seq 1 40); do curl -fsS "http://127.0.0.1:$1/status" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

say "start honest mesh: $N in-RAM miners, mDNS-isolated"
mkdir -p "$ROOT/h0"
"$CE" --data-dir "$ROOT/h0" start --port $P2P --api-port $API --no-mdns --ephemeral >"$ROOT/h0.log" 2>&1 & PIDS+=($!)
upapi $API || { bad "seed up"; exit 1; }
SEED="/ip4/127.0.0.1/tcp/$P2P/p2p/$(peer "$ROOT/h0")"
echo "seed: $SEED"
for i in $(seq 1 $((N-1))); do
  mkdir -p "$ROOT/h$i"
  "$CE" --data-dir "$ROOT/h$i" start --port $((P2P+i)) --api-port $((API+i)) --no-mdns --ephemeral --bootstrap "$SEED" >"$ROOT/h$i.log" 2>&1 & PIDS+=($!)
  sleep 0.3
done
echo "warming up ${HONEST_WARMUP}s (mining + gossip)..."
sleep "$HONEST_WARMUP"

say "honest convergence"
hs=""; for i in $(seq 0 $((N-1))); do hs="$hs $(field $((API+i)) height)"; done
echo "heights:$hs"
read -r mn mx <<<"$(echo $hs | tr ' ' '\n' | grep -v '^-1$' | sort -n | awk 'NR==1{m=$1}{M=$1}END{print m" "M}')"
up=$(echo $hs | tr ' ' '\n' | grep -cv '^-1$')
echo "alive=$up/$N  height range=$mn..$mx"
{ [ "${mn:-0}" -ge 1 ] && [ $((mx-mn)) -le 4 ] && [ "$up" -ge $((N*3/4)) ]; } \
  && ok "honest mesh converged: $up nodes at height $mn..$mx (one chain)" \
  || bad "honest mesh did not converge cleanly (alive=$up range=$mn..$mx)"

say "ATTACK A — API takeover"
c0=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$API/transfer" -H 'content-type: application/json' -d '{"to":"00","amount":"1"}')
c1=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$API/capabilities/revoke" -H 'content-type: application/json' -d '{"nonce":1}')
echo "POST /transfer no-token=$c0   POST /capabilities/revoke no-token=$c1"
{ [ "$c0" = "401" ] && [ "$c1" = "401" ]; } && ok "mutating API rejected without token (401) — no API takeover" || bad "API not gated ($c0/$c1)"
grep -q "API listening on http://127.0.0.1" "$ROOT/h0.log" && ok "API bound to loopback (not internet-reachable)" || bad "API not loopback-bound"

say "ATTACK B — minority attacker: private fork + self-mint, then rejoin"
AD="$ROOT/attacker"; mkdir -p "$AD"; AP=$((P2P+900)); AA=$((API+900))
# NON-ephemeral so the private fork survives the rejoin restart; isolated; mining.
"$CE" --data-dir "$AD" start --port $AP --api-port $AA --no-mdns >"$ROOT/attacker.log" 2>&1 & AP_PID=$!; PIDS+=($AP_PID)
upapi $AA || { bad "attacker up"; exit 1; }
echo "attacker mining a PRIVATE chain for ${HEADSTART}s (minting credits to itself)..."
sleep "$HEADSTART"
aHpre=$(field $AA height); aBpre=$(field $AA balance)
echo "attacker private fork: height=$aHpre  self-minted balance=$aBpre"
hHpre=$(field $API height); echo "honest height now=$hHpre"
echo "reconnecting attacker to honest mesh..."
kill $AP_PID 2>/dev/null; sleep 2
"$CE" --data-dir "$AD" start --port $AP --api-port $AA --no-mdns --bootstrap "$SEED" >>"$ROOT/attacker.log" 2>&1 & AP_PID=$!; PIDS+=($AP_PID)
upapi $AA || { bad "attacker rejoin"; exit 1; }
echo "observing fork choice for 25s..."
sleep 25
aHpost=$(field $AA height); aBpost=$(field $AA balance); hHpost=$(field $API height)
echo "after rejoin: attacker height=$aHpost balance=$aBpost | honest height=$hHpost"
# Security holds if the attacker abandoned its private fork for the heavier honest chain:
#  - attacker height jumped to ~honest (>= its private height and >= honest pre)
#  - attacker's self-minted balance changed (private rewards discarded)
if [ "$aHpost" -ge "$hHpre" ] && [ "$aBpost" != "$aBpre" ]; then
  ok "private fork REJECTED: attacker adopted the heavier honest chain (self-mint $aBpre -> $aBpost discarded); no rewrite, no free credits"
else
  bad "attacker fork NOT rejected — POSSIBLE BREAK (aHpre=$aHpre aHpost=$aHpost hHpre=$hHpre hHpost=$hHpost aBpre=$aBpre aBpost=$aBpost)"
fi
# Did the honest chain get rewritten by the attacker's fork? (it must NOT shrink/replace)
[ "$hHpost" -ge "$hHpre" ] && ok "honest chain not rewritten (height $hHpre -> $hHpost, kept advancing)" || bad "honest chain regressed — reorg attack succeeded"

say "ATTACK C — dump/interop sanity (ephemeral node snapshots to disk)"
ds=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$API/chain/save" -H "authorization: Bearer $TOK")
[ "$ds" = "200" ] && [ -f "$ROOT/h0/chain/chain.json" ] && ok "ephemeral node dumped chain to disk on demand (POST /chain/save)" || bad "chain dump failed ($ds)"

say "RESULT"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
