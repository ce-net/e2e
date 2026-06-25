#!/usr/bin/env sh
set -u
RELAY="/ip4/172.17.0.1/tcp/4001/p2p/12D3KooWC6vyMMrtmdWEdpcMx7JZ4Ze5scUhA6BbMdYqnUDC7nr7"
docker rm -f ce-dbg >/dev/null 2>&1
docker run -d --name ce-dbg -v /usr/local/bin/ce:/usr/local/bin/ce:ro ubuntu:24.04 sh -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null 2>&1
  apt-get install -yq libssl3 ca-certificates netcat-openbsd >/dev/null 2>&1
  echo "reach relay bridge:"; nc -zv -w3 172.17.0.1 4001 2>&1 | tail -1
  /usr/local/bin/ce start --light --bootstrap '"$RELAY"' --relay '"$RELAY"' > /var/log/ce.log 2>&1
' >/dev/null
echo "container: $(docker ps --format '{{.Names}}' | grep -c ce-dbg) running"
sleep 35
echo "=== alive? ==="; docker ps --format '{{.Names}} {{.Status}}' | grep ce-dbg || echo "EXITED — last log:"; docker logs ce-dbg 2>&1 | tail -5
echo "=== ce.log: connection/sync ==="
docker exec ce-dbg sh -c 'cat /var/log/ce.log 2>/dev/null | grep -iE "connect|relay|circuit|sync|height|peer|error|bootstrap" | tail -15' 2>/dev/null
echo "=== status + height over 20s ==="
for i in 1 2; do docker exec ce-dbg sh -c '/usr/local/bin/ce status 2>/dev/null | grep -iE "height|peer id"' 2>/dev/null; sleep 10; done
docker rm -f ce-dbg >/dev/null 2>&1
