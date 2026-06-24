#!/usr/bin/env bash
# Public-ingress end-to-end test for ce-expose's relay-tier HTTP front door (`ce-expose ingress`).
# Stands up two ephemeral, mDNS-isolated CE nodes on loopback (an ORIGIN and an INGRESS-HOST), exposes
# a tiny origin HTTP server over the mesh with `ce-expose http`, fronts it with `ce-expose ingress`,
# and asserts the SECURITY invariants the feature exists to provide:
#   (a) DEFAULT-DENY  — an unregistered Host name -> 404 (no node is reachable unless allowlisted).
#   (b) PUBLIC route  — a registered public name -> 200 and the body matches the origin file.
#   (c) PRIVATE route — no X-CE-Cap -> 401/403; a valid expose:dial chain (+X-CE-Node) -> 200.
#   (d) KILL SWITCH   — touch the kill-file -> 503 for everything; rm it -> back to 200.
#   (e) RATE LIMIT    — a fast burst over the configured per-endpoint rps -> some 429s.
#
# The ingress binary is built with `cargo build --release --features ingress` (a normal node never
# pulls axum). Everything is in-RAM (--ephemeral) and mDNS-isolated (--no-mdns) on loopback only — it
# never touches the live ce-net.com mesh or your disk. SKIPs (exit 0) if a required binary is missing.
#
# Binaries are env-overridable; defaults sit beside this repo under ~/ce-net/<repo>:
#   CE_BIN      ce          (release `ce`)
#   EXPOSE_BIN  ce-expose   (release `ce-expose`, BUILT WITH `--features ingress`)
set -u
export CE_NO_AUTOBOOTSTRAP=1
export CE_API_TOKEN="${CE_API_TOKEN:-e2e-shared-token}"

CE=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
EXPOSE=${EXPOSE_BIN:-$HOME/ce-net/ce-expose/target/release/ce-expose}
ROOT=/tmp/ce-e2e-ingress
# Origin node A, ingress-host node B.
A_DATA=$ROOT/A; B_DATA=$ROOT/B; C_DATA=$ROOT/C
A_P2P=4131; A_API=8931; B_P2P=4132; B_API=8932
ORIGIN_HTTP=8939          # the tiny origin service `ce-expose http` forwards to
INGRESS=8940              # the public ingress listen port (front it with nginx/Cloudflare in prod)
WEBROOT=$ROOT/web
CFG=$ROOT/ingress.toml
KILL=$ROOT/ingress.kill
PIDS=()
PASS=0; FAIL=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; }
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# Skip cleanly (exit 0) unless both binaries are present. The ingress subcommand additionally needs
# the binary to have been built with `--features ingress`; we check for it at runtime below.
[ -x "$CE" ]     || { skip "ce not found at $CE (set CE_BIN); skipping ingress e2e"; exit 0; }
[ -x "$EXPOSE" ] || { skip "ce-expose not found at $EXPOSE (set EXPOSE_BIN; build with --features ingress); skipping ingress e2e"; exit 0; }

rm -rf "$ROOT"; mkdir -p "$A_DATA" "$B_DATA" "$C_DATA" "$WEBROOT"

# ---------------------------------------------------------------------------
say "identities (origin A, ingress-host B, private caller C)"
A_ID=$("$CE" --data-dir "$A_DATA" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
B_ID=$("$CE" --data-dir "$B_DATA" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
C_ID=$("$CE" --data-dir "$C_DATA" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
B_PEER=$("$CE" --data-dir "$B_DATA" id 2>/dev/null | grep -oE '12D3[A-Za-z0-9]+' | head -1)
echo "A(origin)=$A_ID"; echo "B(ingress)=$B_ID  peer=$B_PEER"; echo "C(caller)=$C_ID"
[ ${#A_ID} -eq 64 ] && [ ${#B_ID} -eq 64 ] && [ ${#C_ID} -eq 64 ] && ok "three distinct identities" || { bad "identity generation"; echo "PASS=$PASS  FAIL=$FAIL"; exit 1; }

# ---------------------------------------------------------------------------
# The ingress PINS name->NodeId resolution to the operator-approved owner and refuses to bridge until
# the name resolves on-chain (a name-claim hijack -> 502). So the ingress-host MUST mine: it includes
# the origin's NameClaim into a block and both nodes then resolve `testapp -> A`. The origin node stays
# --no-mine; only B mines (low ephemeral genesis difficulty makes this near-instant).
say "start ingress-host node B (mines so the origin's NameClaim resolves)"
"$CE" --data-dir "$B_DATA" start --no-mdns --ephemeral --port $B_P2P --api-port $B_API >"$ROOT/B.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$B_API/status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$B_API/status" >/dev/null 2>&1 && ok "node B up" || { bad "node B failed to start"; cat "$ROOT/B.log"; echo "PASS=$PASS  FAIL=$FAIL"; exit 1; }

B_ADDR="/ip4/127.0.0.1/tcp/$B_P2P/p2p/$B_PEER"
echo "B_ADDR=$B_ADDR"

say "start origin node A (no-mine; bootstraps from B)"
"$CE" --data-dir "$A_DATA" start --no-mdns --ephemeral --no-mine --port $A_P2P --api-port $A_API ${B_ADDR:+--bootstrap "$B_ADDR"} >"$ROOT/A.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$A_API/status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$A_API/status" >/dev/null 2>&1 && ok "node A up" || { bad "node A failed to start"; cat "$ROOT/A.log"; echo "PASS=$PASS  FAIL=$FAIL"; exit 1; }

# ---------------------------------------------------------------------------
# Capabilities (all self-issued by the ORIGIN A, rooted at A's own key — the one trust primitive):
#   - relay_cap: A grants the INGRESS-HOST B `expose:dial`. The relay presents THIS (never the client's
#     header) to the origin on the mesh hop; the origin authorizes it against its own key.
#   - caller cap: A grants the CALLER C `expose:dial`. The private route's `dial_cap_root` is A, so C's
#     chain (X-CE-Cap) with X-CE-Node=C is accepted by the relay's early-reject gate.
say "origin A self-issues expose:dial caps (to ingress-host B, and to private caller C)"
RELAY_CAP=$("$CE" --data-dir "$A_DATA" grant "$B_ID" --can expose:dial --resource self --expires 1h 2>/dev/null | tr -d '[:space:]')
CALLER_CAP=$("$CE" --data-dir "$A_DATA" grant "$C_ID" --can expose:dial --resource self --expires 1h 2>/dev/null | tr -d '[:space:]')
echo "relay_cap len=${#RELAY_CAP}  caller_cap len=${#CALLER_CAP}"
[ ${#RELAY_CAP} -gt 20 ] && [ ${#CALLER_CAP} -gt 20 ] && ok "both expose:dial caps issued" || bad "cap issuance produced no token"

# ---------------------------------------------------------------------------
say "tiny origin HTTP service (python3 -m http.server in $WEBROOT)"
BODY="ingress-origin $(date -u +%FT%TZ) $$"
echo "$BODY" > "$WEBROOT/index.html"
( cd "$WEBROOT" && exec python3 -m http.server "$ORIGIN_HTTP" --bind 127.0.0.1 ) >"$ROOT/origin.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 20); do curl -fsS "http://127.0.0.1:$ORIGIN_HTTP/" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$ORIGIN_HTTP/" >/dev/null 2>&1 && ok "origin service serving the known file" || { bad "origin http.server did not come up"; cat "$ROOT/origin.log"; }

say "expose the origin service over the mesh: ce-expose http $ORIGIN_HTTP --name testapp"
# The agent advertises + claims `testapp` on-chain (resolves once B mines it). It serves BOTH ingress
# routes (testapp public, secretapp private) — both pin to owner A, so one origin agent backs both.
"$EXPOSE" --api "http://127.0.0.1:$A_API" http "$ORIGIN_HTTP" --name testapp >"$ROOT/expose-origin.log" 2>&1 &
PIDS+=($!)
# Also claim the private route's name so it resolves to A as well.
"$CE" --data-dir "$A_DATA" name claim secretapp --api-port "$A_API" >>"$ROOT/expose-origin.log" 2>&1 || true
sleep 2

# Wait until BOTH names resolve to A on the ingress-host (i.e. B mined the NameClaims).
say "wait for testapp + secretapp to resolve to A on the ingress-host (B mines them in)"
RESOLVED=""
for i in $(seq 1 60); do
  RA=$(curl -fsS "http://127.0.0.1:$B_API/names/testapp" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
  RB=$(curl -fsS "http://127.0.0.1:$B_API/names/secretapp" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
  if [ "$RA" = "$A_ID" ] && [ "$RB" = "$A_ID" ]; then RESOLVED=1; break; fi
  sleep 2
done
[ -n "$RESOLVED" ] && ok "both names resolve to origin A on the ingress-host" || bad "names did not resolve (testapp=$RA secretapp=$RB); ingress public/private routes will 502"

# ---------------------------------------------------------------------------
say "write the operator-curated ingress policy (default-deny; one public + one private route)"
# Default-deny: only the two routes below are reachable; everything else 404s. `testapp` gets a low rps
# so the burst test can trip the per-endpoint token bucket. The relay presents RELAY_CAP to the origin.
cat > "$CFG" <<TOML
[global]
total_tunnel_ceiling = 64
global_rps           = 1000
per_ip_rps           = 1000
request_timeout_ms   = 8000
resolve_ttl_secs     = 5
trusted_proxy_cidr   = ["127.0.0.1/32", "::1/128"]

[[endpoint]]
name            = "testapp"
owner           = "$A_ID"
kind            = "http"
visibility      = "public"
approved        = true
rps             = 3
max_conns       = 16
byte_cap        = 0
idle_timeout_ms = 8000
relay_cap       = "$RELAY_CAP"

[[endpoint]]
name          = "secretapp"
owner         = "$A_ID"
kind          = "http"
visibility    = "private"
dial_cap_root = "$A_ID"
approved      = true
rps           = 200
max_conns     = 16
byte_cap      = 0
idle_timeout_ms = 8000
relay_cap     = "$RELAY_CAP"
TOML

say "start the public ingress: ce-expose ingress --listen 127.0.0.1:$INGRESS --config $CFG"
# Built with --features ingress; if this binary lacks the subcommand it exits non-zero immediately and
# we SKIP (the feature was not compiled in) rather than fail the whole suite.
"$EXPOSE" --api "http://127.0.0.1:$B_API" ingress --listen "127.0.0.1:$INGRESS" --config "$CFG" --kill-file "$KILL" >"$ROOT/ingress.log" 2>&1 &
ING_PID=$!
PIDS+=($!)
UP=""
for i in $(seq 1 20); do
  # Any answer on the listen port (even a 404) means the server is up.
  curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$INGRESS/" && { UP=1; break; }
  kill -0 "$ING_PID" 2>/dev/null || break
  sleep 1
done
if [ -z "$UP" ]; then
  if grep -qiE 'unrecognized subcommand|unexpected argument .*ingress|no such subcommand' "$ROOT/ingress.log"; then
    skip "ce-expose was built WITHOUT --features ingress (no ingress subcommand); skipping ingress e2e"
    echo "PASS=$PASS  FAIL=$FAIL"; exit 0
  fi
  bad "ingress server did not come up"; echo "--- ingress.log ---"; tail -20 "$ROOT/ingress.log"
  echo "PASS=$PASS  FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
ok "ingress listening on 127.0.0.1:$INGRESS"

# ===========================================================================
# SECURITY ASSERTIONS
# ===========================================================================

say "(a) DEFAULT-DENY: an UNREGISTERED Host name is 404 (no route, no mesh work)"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: nope-not-registered.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
[ "$c" = 404 ] && ok "unregistered name -> 404 (default-deny)" || bad "unregistered name -> $c (expected 404)"

say "(b) PUBLIC route: testapp -> 200 and body matches the origin file"
# The mesh bridge + on-chain resolve can lag a moment after startup; retry until the tunnel is warm.
PUB_OK=""; PUB_BODY=""
for i in $(seq 1 30); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
  if [ "$c" = 200 ]; then
    PUB_BODY=$(curl -s --max-time 8 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
    [ "$PUB_BODY" = "$BODY" ] && { PUB_OK=1; break; }
  fi
  sleep 2
done
if [ -n "$PUB_OK" ]; then
  ok "public route bridged the mesh -> 200 and body matches the origin file"
else
  bad "public route did not serve the origin file (last code=$c, body='$PUB_BODY' want '$BODY')"
  echo "--- ingress.log ---"; tail -25 "$ROOT/ingress.log"
  echo "--- expose-origin.log ---"; tail -15 "$ROOT/expose-origin.log"
fi

say "(c) PRIVATE route: no cap -> 401/403; a valid expose:dial chain -> 200"
cno=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: secretapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
case "$cno" in
  401|403) ok "private route without X-CE-Cap -> $cno (denied)";;
  *)       bad "private route without a cap -> $cno (expected 401/403)";;
esac
# With a valid caller cap (X-CE-Cap = the chain A issued to C, X-CE-Node = C). Retry to let the bridge warm.
PRIV_OK=""
for i in $(seq 1 30); do
  cyes=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Host: secretapp.user.ce-net.com" -H "X-CE-Cap: $CALLER_CAP" -H "X-CE-Node: $C_ID" \
    "http://127.0.0.1:$INGRESS/")
  [ "$cyes" = 200 ] && { PRIV_OK=1; break; }
  sleep 2
done
[ -n "$PRIV_OK" ] && ok "private route WITH a valid expose:dial cap -> 200" || bad "private route with a valid cap -> $cyes (expected 200)"

say "(d) KILL SWITCH: touch the kill-file -> 503; rm it -> back to 200"
touch "$KILL"
KILLED=""
for i in $(seq 1 10); do
  ck=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
  [ "$ck" = 503 ] && { KILLED=1; break; }
  sleep 1
done
[ -n "$KILLED" ] && ok "kill-file present -> 503 (all ingress disabled, no restart)" || bad "kill-file did not disable ingress (got $ck, expected 503)"
rm -f "$KILL"
REVIVED=""
for i in $(seq 1 20); do
  cr=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
  [ "$cr" = 200 ] && { REVIVED=1; break; }
  sleep 1
done
[ -n "$REVIVED" ] && ok "kill-file removed -> back to 200" || bad "ingress did not recover after removing the kill-file (got $cr)"

say "(e) RATE LIMIT: a fast burst over testapp's rps (3) returns some 429s"
# Fire a tight burst well over the per-endpoint token bucket and count the 429s. The bucket refills at
# `rps`/sec, so a burst much larger than the capacity must shed some requests with 429.
N429=0; NTOT=0
for i in $(seq 1 40); do
  rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/")
  NTOT=$((NTOT+1))
  [ "$rc" = 429 ] && N429=$((N429+1))
done
echo "burst: $NTOT requests, $N429 -> 429"
[ "$N429" -gt 0 ] && ok "per-endpoint rate limit tripped ($N429/$NTOT got 429)" || bad "rate limit never tripped over the burst (0 of $NTOT were 429)"

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
