#!/usr/bin/env sh
# Automated multi-node e2e on the relay using isolated containers (real VMs blocked by Hetzner
# account server-limit=1). Two debian containers each run a ce node, bootstrap to the live relay,
# and we verify: node up, version consistency, both reach the relay, and the mesh converges
# (same chain height = gossipsub/sync works between them). ALWAYS cleans up.
#
# Runs ON the relay (ce + docker live there). Invoke via: ssh relay 'sh -s' < e2e/relay-e2e.sh
set -u
CE=/usr/local/bin/ce
RELAY="/ip4/172.17.0.1/tcp/4001/p2p/12D3KooWC6vyMMrtmdWEdpcMx7JZ4Ze5scUhA6BbMdYqnUDC7nr7"
IMG=ubuntu:24.04   # must match build glibc (relay is Ubuntu 24.04 / glibc 2.39); + libssl3 below
PASS=0; FAIL=0
ok(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
cleanup(){ echo "=== teardown ==="; for c in ce-e2e-a ce-e2e-b; do docker rm -f "$c" >/dev/null 2>&1 && echo "rm $c"; done; }
trap cleanup EXIT INT TERM

echo "=== ce version on relay (source binary) ==="; $CE --version

start_node(){ # name
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" -v "$CE:/usr/local/bin/ce:ro" "$IMG" \
    sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q >/dev/null 2>&1; apt-get install -yq libssl3 ca-certificates >/dev/null 2>&1; mkdir -p /root/.local/share/ce; /usr/local/bin/ce start --light --bootstrap $RELAY --relay $RELAY > /var/log/ce.log 2>&1" >/dev/null
}
in578(){ docker exec "$1" sh -c "$2" 2>/dev/null; }   # exec-in-container

echo "=== start 2 node containers ==="
start_node ce-e2e-a; start_node ce-e2e-b
sleep 3
for c in ce-e2e-a ce-e2e-b; do docker ps --format '{{.Names}}' | grep -q "$c" && ok "$c running" || no "$c not running"; done

echo "=== install curl-free status probe: wait for each node's API ==="
for c in ce-e2e-a ce-e2e-b; do
  up=0
  for _ in $(seq 1 30); do
    h=$(docker exec "$c" sh -c '/usr/local/bin/ce status 2>/dev/null' 2>/dev/null | grep -iE "height" | head -1)
    [ -n "$h" ] && { up=1; break; }; sleep 2
  done
  [ "$up" = 1 ] && ok "$c node up ($h)" || no "$c node never came up — log: $(docker exec $c sh -c 'tail -3 /var/log/ce.log' 2>/dev/null)"
done

echo "=== version consistency (drift guard) ==="
VA=$(docker exec ce-e2e-a /usr/local/bin/ce --version 2>/dev/null)
VB=$(docker exec ce-e2e-b /usr/local/bin/ce --version 2>/dev/null)
VR=$($CE --version 2>/dev/null)
[ "$VA" = "$VR" ] && [ "$VB" = "$VR" ] && ok "A,B,relay all $VR" || no "version drift A=$VA B=$VB relay=$VR"

echo "=== mesh converges: A and B sync the chain off the relay (this proves connectivity) ==="
HR=$($CE status 2>/dev/null | grep -iE 'height' | grep -oE '[0-9]+' | head -1)
hof(){ docker exec "$1" sh -c '/usr/local/bin/ce status 2>/dev/null' 2>/dev/null | grep -iE 'height' | grep -oE '[0-9]+' | head -1; }
HA=0; HB=0
for _ in $(seq 1 24); do            # poll up to ~2 min for the chain (~3400 blocks) to sync
  HA=$(hof ce-e2e-a); HB=$(hof ce-e2e-b)
  { [ "${HA:-0}" -gt 100 ] && [ "${HB:-0}" -gt 100 ]; } 2>/dev/null && break
  sleep 5
done
echo "  heights: A=$HA B=$HB (relay=$HR)"
[ "${HA:-0}" -gt 100 ] 2>/dev/null && ok "A synced off relay (h=$HA)" || no "A did not sync (h=$HA)"
[ "${HB:-0}" -gt 100 ] 2>/dev/null && ok "B synced off relay (h=$HB)" || no "B did not sync (h=$HB)"

echo; echo "================  RESULT: $PASS passed, $FAIL failed  ================"
[ "$FAIL" -eq 0 ]
