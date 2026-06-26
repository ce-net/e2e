#!/usr/bin/env bash
# spacegame VM e2e — provision FRESH Hetzner VMs, install + run ce from scratch, host the spacegame
# galaxy across them, and prove every system works together over the real mesh: distribution,
# seamless cross-sector transit (infinite map), live hot-reload, rigid-body combat, and — the
# headline — replica fault tolerance when a whole machine vanishes. ALWAYS tears the VMs down (trap).
#
#   e2e/spacegame-vm-e2e.sh
#   KEEP=1 e2e/spacegame-vm-e2e.sh                 # leave VMs up for debugging
#   SPACEGAME_BIN=/path/to/linux/spacegame e2e/spacegame-vm-e2e.sh   # scp a locally/relay-built binary
#   SPACEGAME_URL=https://.../spacegame e2e/spacegame-vm-e2e.sh      # or fetch it on each VM
#
# Requirements: HETZNER_API_TOKEN in ce/.env, the ce-laptop SSH key, and a linux `spacegame` binary
# (via SPACEGAME_BIN or SPACEGAME_URL) built for the VM image's glibc (use ubuntu-24.04 to match the
# relay build — see e2e/VM-E2E.md findings). `ce` itself is installed via the real install.sh path.
#
# GATING: needs the Hetzner server limit raised above 1 (currently only the relay fits). Until then
# this self-reports the block and exits non-zero after provisioning attempts; the assertions are ready.
set -uo pipefail
cd "$(dirname "$0")/.."

TOKEN=$(grep HETZNER_API_TOKEN ce/.env | cut -d= -f2- | tr -d '"'"'"' ')
KEY_ID=112796132                       # ce-laptop
SSHK="$HOME/.ssh/id_ed25519"
SSH="ssh -i $SSHK -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SCP="scp -i $SSHK -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
TYPE=${TYPE:-cx23}; IMG=${IMG:-ubuntu-24.04}; LOC=${LOC:-fsn1}
RELAY=/ip4/178.105.145.170/tcp/4001/p2p/12D3KooWC6vyMMrtmdWEdpcMx7JZ4Ze5scUhA6BbMdYqnUDC7nr7
TS=$(date +%s 2>/dev/null || echo run)
PASS=0; FAIL=0
ok(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
api(){ curl -s -m25 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }   # jget "d['x']"

IDS=""
cleanup(){ [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1, leaving: $IDS"; return; }
  echo "=== teardown ==="; for id in $IDS; do api -X DELETE "https://api.hetzner.cloud/v1/servers/$id" >/dev/null && echo "deleted $id"; done; }
trap cleanup EXIT

mkvm(){ # name -> "id ip"
  api -X POST https://api.hetzner.cloud/v1/servers \
    -d "{\"name\":\"$1\",\"server_type\":\"$TYPE\",\"image\":\"$IMG\",\"location\":\"$LOC\",\"ssh_keys\":[$KEY_ID]}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);s=d.get('server');print(s['id'],s['public_net']['ipv4']['ip']) if s else sys.exit('create failed: '+json.dumps(d))"
}
waitssh(){ for _ in $(seq 1 40); do $SSH root@"$1" true 2>/dev/null && return 0; sleep 5; done; return 1; }
on(){ local ip=$1; shift; $SSH root@"$ip" "$@"; }

# ---- provision 3 fresh VMs (A: sector 0_0, B: sector 1_0, C: hot standby) ----
echo "=== provision 3 VMs ($TYPE/$IMG/$LOC) ==="
A=($(mkvm "spacegame-e2e-a-$TS")) || { no "could not create VM A (Hetzner server limit? raise it)"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; exit 1; }
IDS="$IDS ${A[0]}"; echo "A: id=${A[0]} ip=${A[1]}"
B=($(mkvm "spacegame-e2e-b-$TS")) || { no "could not create VM B"; exit 1; }
IDS="$IDS ${B[0]}"; echo "B: id=${B[0]} ip=${B[1]}"
C=($(mkvm "spacegame-e2e-c-$TS")) || { no "could not create VM C"; exit 1; }
IDS="$IDS ${C[0]}"; echo "C: id=${C[0]} ip=${C[1]}"

echo "=== wait for SSH ==="
for v in "${A[1]}" "${B[1]}" "${C[1]}"; do waitssh "$v" && ok "$v reachable" || { no "$v unreachable"; exit 1; }; done

# ---- install ce via the REAL install.sh path (the genuine fresh-machine experience) ----
INSTALL_CE='set -e
apt-get update -qq && apt-get install -y -qq curl python3 ca-certificates >/dev/null 2>&1 || true
# The real one-liner users run. If no GitHub release is tagged yet, fall back to a pinned binary.
if curl -sSL https://raw.githubusercontent.com/ce-net/ce/main/install.sh | bash >/tmp/install.log 2>&1; then
  echo INSTALL-OK
else
  echo "install.sh failed, falling back to pinned binary" >&2
  curl -fsSL https://github.com/ce-net/rdev/releases/download/v0.1.0/ce-linux-amd64-012 -o /usr/local/bin/ce && chmod +x /usr/local/bin/ce && echo INSTALL-FALLBACK
fi
command -v ce || ls -l /usr/local/bin/ce
ce --version || /usr/local/bin/ce --version'

NODE_UNIT='cat >/etc/systemd/system/ce-node.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/usr/local/bin/ce start --light --bootstrap '"$RELAY"' --relay '"$RELAY"'
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now ce-node
for i in $(seq 1 30); do curl -fsS -m3 http://127.0.0.1:8844/status >/dev/null 2>&1 && break; sleep 2; done
curl -s -m3 http://127.0.0.1:8844/status | python3 -c "import sys,json;d=json.load(sys.stdin);print(\"NODE\",d[\"node_id\"][:12],\"h\",d[\"height\"])"'

echo "=== install ce (fresh) + bring up node on all three ==="
for v in "${A[1]}" "${B[1]}" "${C[1]}"; do
  R=$(on "$v" "$INSTALL_CE" 2>&1) || true
  echo "$R" | grep -qE 'INSTALL-OK|INSTALL-FALLBACK' && ok "$v ce installed ($(echo "$R" | grep -oE 'INSTALL-OK|INSTALL-FALLBACK'))" || no "$v ce install"
  on "$v" "$NODE_UNIT" 2>&1 | tail -1 | grep -q NODE && ok "$v node up" || no "$v node up"
done

# ---- ship the spacegame binary + the test bot to every VM ----
if [ -n "${SPACEGAME_BIN:-}" ] && [ -f "$SPACEGAME_BIN" ]; then
  for v in "${A[1]}" "${B[1]}" "${C[1]}"; do $SCP "$SPACEGAME_BIN" root@"$v":/usr/local/bin/spacegame && on "$v" "chmod +x /usr/local/bin/spacegame"; done
  ok "spacegame binary uploaded to all VMs"
elif [ -n "${SPACEGAME_URL:-}" ]; then
  for v in "${A[1]}" "${B[1]}" "${C[1]}"; do on "$v" "curl -fsSL '$SPACEGAME_URL' -o /usr/local/bin/spacegame && chmod +x /usr/local/bin/spacegame"; done
  ok "spacegame binary fetched on all VMs"
else
  no "no spacegame binary (set SPACEGAME_BIN=/path or SPACEGAME_URL=...) — cannot host sectors"
  echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
for v in "${A[1]}" "${B[1]}" "${C[1]}"; do $SCP e2e/spacegame-bot.py root@"$v":/root/spacegame-bot.py; done

host_unit(){ # ip "sector args"
  local ip=$1 args=$2
  on "$ip" "cat >/etc/systemd/system/spacegame.service <<EOF
[Unit]
After=ce-node.service
[Service]
ExecStart=/usr/local/bin/spacegame host $args
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now spacegame && echo SPACEGAME-UP"
}

echo "=== host the galaxy: A=sector 0_0 (autoscale), B=sector 1_0, C=standby ==="
host_unit "${A[1]}" "--sector 0_0 --autoscale" | grep -q SPACEGAME-UP && ok "A hosting 0_0" || no "A host 0_0"
host_unit "${B[1]}" "--sector 1_0"             | grep -q SPACEGAME-UP && ok "B hosting 1_0" || no "B host 1_0"
sleep 10

# ---- DISTRIBUTION: sectors are discoverable and on different hosts ----
NA=$(on "${A[1]}" "/usr/local/bin/spacegame nearest --sector 0_0" 2>&1)
NB=$(on "${A[1]}" "/usr/local/bin/spacegame nearest --sector 1_0" 2>&1)
echo "$NA" | grep -q "live host" && ok "0_0 has a live host ($NA)" || no "0_0 no host"
echo "$NB" | grep -q "live host" && ok "1_0 has a live host ($NB)" || no "1_0 no host"

# ---- HOT RELOAD: push a v2 ruleset from B; every host must hot-apply it ----
echo "=== hot reload: push an edited ruleset live ==="
on "${B[1]}" "/usr/local/bin/spacegame ruleset init /root/live.json >/dev/null 2>&1
python3 - <<PY
import json
r=json.load(open('/root/live.json')); r['version']=2; r['label']='e2e buff'; r['weapons'][0]['damage']=99
json.dump(r,open('/root/live.json','w'))
PY
/usr/local/bin/spacegame ruleset push /root/live.json" 2>&1 | tail -1
sleep 4

# ---- GAMEPLAY + INFINITE MAP: a bot on A flies east out of 0_0 and must appear in 1_0 (on B) ----
echo "=== bot: play 0_0, fire, then transit east into 1_0 ==="
BOT_A=$(on "${A[1]}" "python3 /root/spacegame-bot.py --sector 0_0 --watch-sector 1_0 --behavior fire --secs 16 --name alpha" 2>/dev/null | tail -1)
echo "  bot A -> $BOT_A"
echo "$BOT_A" | jget "d['present']" 2>/dev/null | grep -qi true && ok "bot present in 0_0 (join+state over mesh)" || no "bot not present in 0_0"
echo "$BOT_A" | jget "d['saw_bullets']" 2>/dev/null | grep -qi true && ok "blaster fired (bullets in authoritative state)" || no "no bullets seen"
echo "$BOT_A" | jget "d.get('ruleset',0)" 2>/dev/null | awk '{exit !($1>=2)}' && ok "hot-reloaded ruleset is live (v$(echo "$BOT_A" | jget "d.get('ruleset',0)"))" || no "ruleset did not hot-apply"

# ---- FACTIONS: tracked on the wire, and fielded as NPC ships under your command ----
echo "$BOT_A" | jget "d.get('factions_tracked',0)" 2>/dev/null | awk '{exit !($1>=1)}' && ok "factions are tracked on the snapshot wire" || no "no factions tracked"
echo "$BOT_A" | jget "(d.get('my_faction') or {}).get('power',0)" 2>/dev/null | awk '{exit !($1>0)}' && ok "your faction has a live economy (power>0)" || no "no faction economy"
echo "$BOT_A" | jget "d.get('my_fleet_alive',0)" 2>/dev/null | awk '{exit !($1>=1)}' && ok "your faction fields NPC fleet ships under command" || no "no NPC fleet ships fielded"
echo "$BOT_A" | jget "d.get('npc_ships_seen',0)" 2>/dev/null | awk '{exit !($1>=1)}' && ok "NPC fleet ships are visible in the authoritative state" || no "no NPC ships in state"

BOT_T=$(on "${A[1]}" "python3 /root/spacegame-bot.py --sector 0_0 --watch-sector 1_0 --behavior east --secs 20 --name traveler" 2>/dev/null | tail -1)
echo "  bot transit -> $BOT_T"
echo "$BOT_T" | jget "d.get('transited_to')" 2>/dev/null | grep -q "1_0" && ok "ship transited 0_0 -> 1_0 across the mesh (infinite map)" || no "no cross-sector transit observed"

# ---- FAULT TOLERANCE: kill VM A; sector 0_0 must come back on the standby from a replica snapshot ----
echo "=== fault tolerance: hard-kill VM A (the 0_0 host) and recover on C ==="
PRE=$(on "${B[1]}" "python3 /root/spacegame-bot.py --sector 0_0 --behavior idle --secs 6 --name probe" 2>/dev/null | tail -1)
PRE_TICK=$(echo "$PRE" | jget "d.get('tick',0)" 2>/dev/null || echo 0)
echo "  0_0 tick before kill: ${PRE_TICK:-0}"
api -X DELETE "https://api.hetzner.cloud/v1/servers/${A[0]}" >/dev/null && IDS=$(echo "$IDS" | sed "s/${A[0]}//") && ok "deleted VM A (simulated total loss)" || no "could not delete A"

# C adopts 0_0 from the latest replicated snapshot (the high-precision map copied to the next best node).
host_unit "${C[1]}" "--sector 0_0" | grep -q SPACEGAME-UP && ok "C took over hosting 0_0" || no "C takeover host"
sleep 12
ADOPT=$(on "${C[1]}" "journalctl -u spacegame --no-pager 2>/dev/null | grep -c 'adopted replicated snapshot'")
[ "${ADOPT:-0}" -ge 1 ] 2>/dev/null && ok "C adopted the replicated 0_0 snapshot (failover, not an empty sector)" || no "C did not adopt a snapshot"
POST=$(on "${C[1]}" "python3 /root/spacegame-bot.py --sector 0_0 --behavior idle --secs 8 --name probe2" 2>/dev/null | tail -1)
echo "  0_0 after failover -> $POST"
echo "$POST" | jget "d.get('tick',0)" 2>/dev/null | awk '{exit !($1>0)}' && ok "sector 0_0 is live again on a new machine after the host vanished" || no "0_0 did not recover"

echo
echo "================  RESULT: $PASS passed, $FAIL failed  ================"
[ "$FAIL" -eq 0 ]
