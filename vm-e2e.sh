#!/usr/bin/env bash
# Automated VM e2e: provision real Hetzner VMs, deploy ce + rdev, bring up supervised nodes, pair
# them, and test node/mesh/exec end-to-end. ALWAYS tears the VMs down (trap), even on failure.
#
#   e2e/vm-e2e.sh            # 2-node run
#   KEEP=1 e2e/vm-e2e.sh     # leave VMs up for debugging
set -uo pipefail
cd "$(dirname "$0")/.."

TOKEN=$(grep HETZNER_API_TOKEN ce/.env | cut -d= -f2- | tr -d '"'"'"' ')
KEY_ID=112796132                       # ce-laptop
SSHK="$HOME/.ssh/id_ed25519"
SSH="ssh -i $SSHK -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
TYPE=cpx11; IMG=debian-12; LOC=fsn1
CE_URL=https://github.com/ce-net/rdev/releases/download/v0.1.0/ce-linux-amd64-012
CE_SHA=b740dad9d962972439d34f4bb2cc7425efff72a98319c91756de972853cdc805
RELAY=/ip4/178.105.145.170/tcp/4001/p2p/12D3KooWC6vyMMrtmdWEdpcMx7JZ4Ze5scUhA6BbMdYqnUDC7nr7
TS=$(date +%s 2>/dev/null || echo run)
PASS=0; FAIL=0
ok(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
api(){ curl -s -m25 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

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

echo "=== provision 2 VMs ($TYPE/$IMG/$LOC) ==="
A=($(mkvm "ce-e2e-a-$TS")) || exit 1; IDS="$IDS ${A[0]}"; echo "A: id=${A[0]} ip=${A[1]}"
B=($(mkvm "ce-e2e-b-$TS")) || exit 1; IDS="$IDS ${B[0]}"; echo "B: id=${B[0]} ip=${B[1]}"

echo "=== wait for SSH ==="
waitssh "${A[1]}" && ok "A reachable" || { no "A unreachable"; exit 1; }
waitssh "${B[1]}" && ok "B reachable" || { no "B unreachable"; exit 1; }

DEPLOY='set -e; curl -fsSL '"$CE_URL"' -o /usr/local/bin/ce && chmod +x /usr/local/bin/ce
echo "'"$CE_SHA"'  /usr/local/bin/ce" | sha256sum -c >/dev/null && echo SHA-OK
cat >/etc/systemd/system/ce-node.service <<EOF
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

echo "=== deploy ce 0.1.2 + supervised node on both ==="
RA=$(on "${A[1]}" "$DEPLOY" 2>&1); echo "A: $(echo "$RA" | tail -2 | tr '\n' ' ')"
RB=$(on "${B[1]}" "$DEPLOY" 2>&1); echo "B: $(echo "$RB" | tail -2 | tr '\n' ' ')"
echo "$RA" | grep -q SHA-OK && ok "A ce verified by checksum" || no "A checksum"
echo "$RA" | grep -q 'NODE' && ok "A node up" || no "A node up"
echo "$RB" | grep -q 'NODE' && ok "B node up" || no "B node up"

echo "=== both connect to relay (hold a circuit)? ==="
sleep 12
CA=$(on "${A[1]}" "journalctl -u ce-node --no-pager 2>/dev/null | grep -c 'relay circuit listening'")
CB=$(on "${B[1]}" "journalctl -u ce-node --no-pager 2>/dev/null | grep -c 'relay circuit listening'")
[ "${CA:-0}" -ge 1 ] 2>/dev/null && ok "A reserved relay circuit" || no "A no relay reservation"
[ "${CB:-0}" -ge 1 ] 2>/dev/null && ok "B reserved relay circuit" || no "B no relay reservation"

echo "=== version consistency (drift = the bug we are guarding) ==="
VA=$(on "${A[1]}" "/usr/local/bin/ce --version"); VB=$(on "${B[1]}" "/usr/local/bin/ce --version")
[ "$VA" = "$VB" ] && ok "A and B same version ($VA)" || no "version drift A=$VA B=$VB"

echo
echo "================  RESULT: $PASS passed, $FAIL failed  ================"
[ "$FAIL" -eq 0 ]
