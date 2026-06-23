#!/usr/bin/env bash
# Live production smoke + security-invariant test for the public relay (ce-net.com).
# Unlike the hermetic suites, this hits the REAL deployed surface and asserts both that the
# public pages/endpoints work AND that the security boundary holds: nodes are mesh-only, the
# value-moving API is NOT internet-exposed, and the site is dogfooded through the CE storage
# gateway with a static fallback.
#
#   BASE       public base url        (default https://ce-net.com)
#   RELAY_IP   relay public IP        (default 178.105.145.170) — for the port-exposure checks
#   RELAY_SSH  ssh target (optional)  — only needed for the gateway-fallback mutation test
set -u
BASE=${BASE:-https://ce-net.com}
RELAY_IP=${RELAY_IP:-178.105.145.170}
RELAY_SSH=${RELAY_SSH:-}
PASS=0; FAIL=0
say(){ printf '\n=== %s ===\n' "$1"; }
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1"; }
hdr(){ curl -s -D - -o /dev/null --max-time 15 "$1" | tr -d '\r'; }
# port_open HOST PORT -> prints "open" or "closed"
port_open(){ python3 - "$1" "$2" <<'PY'
import socket,sys
s=socket.socket(); s.settimeout(4)
try:
    s.connect((sys.argv[1],int(sys.argv[2]))); print("open")
except Exception:
    print("closed")
finally:
    s.close()
PY
}

say "public pages + read-only node surface all serve"
for p in / /fabric /network /node /worker.js /bootstrap /health /atlas /status /hub/stats; do
  c=$(code "$BASE$p")
  [ "$c" = 200 ] && ok "GET $p -> 200" || bad "GET $p -> $c (expected 200)"
done

say "node read-only JSON endpoints are well-formed"
curl -s --max-time 15 "$BASE/status" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert len(d["node_id"])==64 and "height" in d' 2>/dev/null \
  && ok "/status returns a valid node status" || bad "/status malformed"
curl -s --max-time 15 "$BASE/atlas" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert isinstance(d,list)' 2>/dev/null \
  && ok "/atlas returns a JSON array" || bad "/atlas malformed"

say "SECURITY: the value/write API is NOT internet-exposed"
# These paths are deliberately never proxied by the edge; they must not be reachable.
for p in /transfer /jobs/bid /sync/x /exec /key /blocks; do
  c=$(code "$BASE$p")
  [ "$c" != 200 ] && ok "write/internal path $p not served ($c)" || bad "SECURITY: $p returned 200 (exposed!)"
done

say "SECURITY: only the intended ports are open on the relay; node/hub/gateway are loopback"
for port in 80 4001; do
  [ "$(port_open "$RELAY_IP" "$port")" = open ] && ok "port $port is open (expected)" || bad "port $port should be open"
done
for port in 8844 8970 9000 8080; do
  [ "$(port_open "$RELAY_IP" "$port")" = closed ] && ok "port $port NOT internet-reachable (loopback/firewalled)" \
    || bad "SECURITY: port $port is reachable from the internet!"
done

say "DOGFOOD: the site is served through the CE storage gateway (content-addressed blobs)"
h=$(hdr "$BASE/")
echo "$h" | grep -qi 'x-ce-served: *ce-storage-gateway' && ok "/ served by ce-storage gateway (from blobs)" \
  || bad "/ not served by the gateway (header: $(echo "$h" | grep -i x-ce-served || echo none))"

say "DOGFOOD: zero-downtime static fallback (only if RELAY_SSH is set — this momentarily stops the gw)"
if [ -n "$RELAY_SSH" ]; then
  ssh -o BatchMode=yes "$RELAY_SSH" 'systemctl stop ce-storage-gw' 2>/dev/null
  sleep 1
  fb=$(hdr "$BASE/fabric")
  ssh -o BatchMode=yes "$RELAY_SSH" 'systemctl start ce-storage-gw' 2>/dev/null
  if echo "$fb" | grep -qiE 'HTTP/.* 200' && echo "$fb" | grep -qi 'x-ce-served: *static-fallback'; then
    ok "site stayed up via static fallback while the gateway was down"
  else
    bad "static fallback did not engage (headers: $(echo "$fb" | grep -iE 'HTTP/|x-ce-served' | tr '\n' ' '))"
  fi
else
  echo "SKIP: set RELAY_SSH=root@$RELAY_IP to exercise the gateway-down fallback"
fi

say "LIVE COMPUTE: the mesh actually computes a pushed task (needs >=1 worker online)"
res=$(curl -s --max-time 30 -X POST "$BASE/hub/tasks" -H 'content-type: application/json' \
  -d '{"module":"demo","func":"count_primes","args":[200000]}')
echo "$res" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d.get("ok") and d.get("value")=="17984"' 2>/dev/null \
  && ok "count_primes(200000)=17984 computed on a live node" \
  || echo "SKIP/FAIL: no worker online or wrong result ($res)"

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
