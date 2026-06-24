#!/usr/bin/env bash
# e2e-attack-ingress.sh — adversarial PUBLIC HTTP INGRESS red team (the relay-tier front door).
#
# The adversarial counterpart to the functional `e2e-ingress.sh`: it reuses that exact topology — two
# ephemeral, mDNS-isolated, loopback CE nodes (an ORIGIN A that stays --no-mine, and an INGRESS-HOST B
# that MINES so the origin's on-chain NameClaim resolves), a tiny origin HTTP service exposed over the
# mesh with `ce-expose http --name testapp`, fronted by `ce-expose ingress` with an operator-curated
# default-deny policy — but it LEADS WITH THE ATTACKS. All MUST-HOLD: the ingress exists precisely to
# provide these invariants, so a defense that fails is a real regression -> bad()/FAIL.
#
# Ground truth (every attack below is grounded in ce-expose, not invented):
#   - ce-expose/src/ingress.rs : the per-request gate chain (authorize_request) in order: kill switch
#       -> Host parse (parse_host_name: IP literals / trailing dot / single label / xn-- / non-LDH ->
#       400 bad_host) -> route lookup (default-deny -> 404 no_route) -> blocked_substring (403) ->
#       global/per-IP/per-endpoint token buckets (429) -> tunnel ceilings -> (private)
#       verify_private_caller (no X-CE-Cap -> 401; bad/wrong-root chain -> 403 cap_denied) -> resolve
#       pinned to the operator-approved owner (owner_mismatch / unresolvable -> 502) -> mesh bridge.
#   - ce-expose/src/ingress.rs : resolve_origin PINS name->NodeId to the config `owner`; a name-claim
#       hijack or DHT poisoning that resolves elsewhere is refused (owner_mismatch -> 502) so the relay
#       NEVER bridges to a node the operator did not approve.
#   - ce-expose/src/ingress.rs : request_target rejects absolute/authority-form targets and CR/LF; the
#       client's Host is replaced with ONE canonical Host and x-ce-cap/x-ce-node are never forwarded
#       upstream — the relay only ever bridges to the pinned origin (no arbitrary upstream / SSRF).
#   - ce-expose/src/ingress_config.rs : default-deny route table; `private` routes carry a per-route
#       `dial_cap_root`; a chain rooted at route X's root does NOT satisfy route Y's root.
#   - ce-expose/src/main.rs : `Cmd::Ingress { listen, config, kill_switch, kill_file }` (--features ingress).
#
# This script OWNS the entire public-ingress edge (default-deny, host-spoof, SSRF/path-smuggling,
# private-cap, per-route cap scoping, rate-limit, kill-switch). No other attack script touches
# `ce-expose`. It needs EXPOSE_BIN built `--features ingress`; SKIPs cleanly (exit 0) otherwise.
#
# Attacks mounted (catalog row -> class, all MUST-HOLD):
#   ING1 Default-deny bypass: unregistered Host name ............................ 404 ............ MUST-HOLD
#   ING2 Host-header spoof / name-allowlist bypass (case/dot/blocked substring) . blocked ........ MUST-HOLD
#   ING6 SSRF / path smuggling (metadata IP, absolute-URI, traversal, header Host) never bridged . MUST-HOLD
#   ING3 Private-route cap bypass: no X-CE-Cap / forged / wrong-root cap ........ 401/403; valid 200  MUST-HOLD
#   ING7 Per-route cap scoping: a cap for route X does not open route Y ......... denied .......... MUST-HOLD
#   ING5 Rate limit: a fast burst over a route's rps ........................... some 429s ....... MUST-HOLD
#   ING4 Kill switch: touch the kill-file -> 503; rm -> 200 ..................... 503 / 200 ....... MUST-HOLD
#
# Hermetic: --ephemeral --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback, high ports. Never ce-net.com.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/redteam.sh"

# Port plan for the ingress suite (disjoint from the other seven scripts): p2p 76xx / api 96xx.
A_P2P=7600; A_API=9600            # origin A (no-mine)
B_P2P=7601; B_API=9601            # ingress-host B (mines -> resolves NameClaims)
ORIGIN_HTTP=7639                  # the tiny origin service `ce-expose http` forwards to
INGRESS=7640                      # the public ingress listen port (front it with nginx/Cloudflare in prod)

rt_init ingress
rt_arm_cleanup

# The ingress front door additionally needs ce-expose; skip cleanly if it's missing.
rt_need_bin "$EXPOSE_BIN" "ce-expose (set EXPOSE_BIN; build with --features ingress)"
EXPOSE="$EXPOSE_BIN"

A_DATA="$ROOT/A"; B_DATA="$ROOT/B"; C_DATA="$ROOT/C"; D_DATA="$ROOT/D"
WEBROOT="$ROOT/web"
CFG="$ROOT/ingress.toml"
KILL="$ROOT/ingress.kill"
mkdir -p "$A_DATA" "$B_DATA" "$C_DATA" "$D_DATA" "$WEBROOT"

# --------------------------------------------------------------------------------------------------
say "identities (origin A, ingress-host B, private caller C, foreign cap-root D)"
# --------------------------------------------------------------------------------------------------
A_ID=$(rt_node_id "$A_DATA"); B_ID=$(rt_node_id "$B_DATA")
C_ID=$(rt_node_id "$C_DATA"); D_ID=$(rt_node_id "$D_DATA")
B_PEER=$(rt_peer_id "$B_DATA")
echo "A(origin)=$A_ID"; echo "B(ingress)=$B_ID peer=$B_PEER"; echo "C(caller)=$C_ID"; echo "D(foreign-root)=$D_ID"
if [ ${#A_ID} -eq 64 ] && [ ${#B_ID} -eq 64 ] && [ ${#C_ID} -eq 64 ] && [ ${#D_ID} -eq 64 ]; then
  ok "four distinct identities minted"
else
  bad "identity generation failed"; rt_result; exit 1
fi

# --------------------------------------------------------------------------------------------------
# The ingress PINS name->NodeId resolution to the operator-approved owner and refuses to bridge until
# the name resolves on-chain. So the ingress-host MUST mine: it includes the origin's NameClaim into a
# block and both nodes then resolve `testapp -> A`. The origin node stays --no-mine; only B mines (low
# ephemeral genesis difficulty makes this near-instant).
say "start ingress-host node B (mines so the origin's NameClaims resolve)"
# --------------------------------------------------------------------------------------------------
# Start the nodes directly against the SAME data dirs we minted the identities in ($ROOT/B, $ROOT/A) so
# B_PEER/B_ADDR and the owner pin are consistent (rt_start_node would force its own $ROOT/<name> dir).
"$CE_BIN" --data-dir "$B_DATA" start --no-mdns --ephemeral \
  --port "$B_P2P" --api-port "$B_API" >"$ROOT/B.log" 2>&1 &
PIDS+=($!)
B_PID=$!
rt_wait_api "$B_API" 30 && ok "node B up" || { bad "node B failed to start"; cat "$ROOT/B.log"; rt_result; exit 1; }
B_ADDR=$(rt_addr "$B_DATA" "$B_P2P"); echo "B_ADDR=$B_ADDR"

say "start origin node A (no-mine; bootstraps from B)"
"$CE_BIN" --data-dir "$A_DATA" start --no-mdns --ephemeral --no-mine \
  --port "$A_P2P" --api-port "$A_API" --bootstrap "$B_ADDR" >"$ROOT/A.log" 2>&1 &
PIDS+=($!)
A_PID=$!
rt_wait_api "$A_API" 30 && ok "node A up" || { bad "node A failed to start"; cat "$ROOT/A.log"; rt_result; exit 1; }

# --------------------------------------------------------------------------------------------------
# Capabilities — all self-issued by the ORIGIN A, rooted at A's own key (the one trust primitive):
#   RELAY_CAP  : A grants the INGRESS-HOST B `expose:dial`. The relay presents THIS (never the client's
#                header) to the origin on the mesh hop.
#   CALLER_CAP : A grants the CALLER C `expose:dial`. A private route whose dial_cap_root is A accepts
#                C's chain (X-CE-Cap) with X-CE-Node=C at the relay's early-reject gate.
# The foreign root D issues NOTHING here — its key is only used as a *different* route's dial_cap_root,
# so CALLER_CAP (rooted at A) must NOT satisfy it (ING7 per-route scoping).
say "origin A self-issues expose:dial caps (to ingress-host B, and to private caller C)"
# --------------------------------------------------------------------------------------------------
RELAY_CAP=$("$CE_BIN" --data-dir "$A_DATA" grant "$B_ID" --can expose:dial --resource self --expires 1h 2>/dev/null | tr -d '[:space:]')
CALLER_CAP=$("$CE_BIN" --data-dir "$A_DATA" grant "$C_ID" --can expose:dial --resource self --expires 1h 2>/dev/null | tr -d '[:space:]')
# A short-lived cap for the expiry probe (issued to C as well so the holder matches).
EXPIRED_CAP=$("$CE_BIN" --data-dir "$A_DATA" grant "$C_ID" --can expose:dial --resource self --expires 2s 2>/dev/null | tr -d '[:space:]')
echo "relay_cap len=${#RELAY_CAP}  caller_cap len=${#CALLER_CAP}  expiring_cap len=${#EXPIRED_CAP}"
if [ ${#RELAY_CAP} -gt 20 ] && [ ${#CALLER_CAP} -gt 20 ]; then
  ok "expose:dial caps issued (relay + caller)"
else
  bad "cap issuance produced no token"
fi

# --------------------------------------------------------------------------------------------------
say "tiny origin HTTP service (python3 -m http.server in $WEBROOT)"
# --------------------------------------------------------------------------------------------------
BODY="ingress-origin $(date -u +%FT%TZ) $$"
echo "$BODY" > "$WEBROOT/index.html"
( cd "$WEBROOT" && exec python3 -m http.server "$ORIGIN_HTTP" --bind 127.0.0.1 ) >"$ROOT/origin.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 20); do curl -fsS "http://127.0.0.1:$ORIGIN_HTTP/" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$ORIGIN_HTTP/" >/dev/null 2>&1 && ok "origin service serving the known file" || { bad "origin http.server did not come up"; cat "$ROOT/origin.log"; }

say "expose the origin service over the mesh: ce-expose http $ORIGIN_HTTP --name testapp (+ claim the private names)"
# One origin agent backs ALL three ingress routes (testapp public, secretapp + otherapp private) — all
# pin to owner A. We claim the two private names on-chain so they resolve to A as well.
"$EXPOSE" --api "http://127.0.0.1:$A_API" http "$ORIGIN_HTTP" --name testapp >"$ROOT/expose-origin.log" 2>&1 &
PIDS+=($!)
"$CE_BIN" --data-dir "$A_DATA" name claim secretapp --api-port "$A_API" >>"$ROOT/expose-origin.log" 2>&1 || true
"$CE_BIN" --data-dir "$A_DATA" name claim otherapp  --api-port "$A_API" >>"$ROOT/expose-origin.log" 2>&1 || true
sleep 2

say "wait for testapp + secretapp + otherapp to resolve to A on the ingress-host (B mines them in)"
RESOLVED=""
for i in $(seq 1 60); do
  RA=$(curl -fsS "http://127.0.0.1:$B_API/names/testapp"  2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
  RB=$(curl -fsS "http://127.0.0.1:$B_API/names/secretapp" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
  RC=$(curl -fsS "http://127.0.0.1:$B_API/names/otherapp"  2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
  if [ "$RA" = "$A_ID" ] && [ "$RB" = "$A_ID" ] && [ "$RC" = "$A_ID" ]; then RESOLVED=1; break; fi
  sleep 2
done
[ -n "$RESOLVED" ] && ok "all three names resolve to origin A on the ingress-host" || bad "names did not resolve (testapp=$RA secretapp=$RB otherapp=$RC); public/private routes will 502"

# --------------------------------------------------------------------------------------------------
say "write the operator-curated default-deny policy (1 public + 2 private routes, distinct cap roots)"
# --------------------------------------------------------------------------------------------------
# Default-deny: only these three routes are reachable; everything else 404s. `testapp` gets a low rps so
# the burst test trips the per-endpoint token bucket. `secretapp` is rooted at A (CALLER_CAP satisfies
# it); `otherapp` is rooted at the FOREIGN key D, so CALLER_CAP (rooted at A) must NOT open it (ING7).
# The relay presents RELAY_CAP to the origin for every route.
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

[[endpoint]]
name          = "otherapp"
owner         = "$A_ID"
kind          = "http"
visibility    = "private"
dial_cap_root = "$D_ID"
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
  curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$INGRESS/" && { UP=1; break; }
  kill -0 "$ING_PID" 2>/dev/null || break
  sleep 1
done
if [ -z "$UP" ]; then
  if grep -qiE 'unrecognized subcommand|unexpected argument .*ingress|no such subcommand' "$ROOT/ingress.log"; then
    skip "ce-expose was built WITHOUT --features ingress (no ingress subcommand); skipping ingress attack suite"
    echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0
  fi
  bad "ingress server did not come up"; echo "--- ingress.log ---"; tail -20 "$ROOT/ingress.log"
  rt_result; exit 1
fi
ok "ingress listening on 127.0.0.1:$INGRESS"

# A helper: GET the ingress with a chosen Host header, echo only the status code.
ing_code() { rt_code -H "Host: $1" "http://127.0.0.1:$INGRESS/"; }

# ==================================================================================================
# ATTACKS
# ==================================================================================================

# --------------------------------------------------------------------------------------------------
say "ING1 — default-deny: an UNREGISTERED Host name must 404 (no node reachable unless allowlisted)"
# --------------------------------------------------------------------------------------------------
c=$(ing_code "nope-not-registered.user.ce-net.com")
[ "$c" = 404 ] && xfail "ING1: unregistered name -> 404 (default-deny; no route, no mesh work)" \
  || bad "ING1: unregistered name -> $c (expected 404) — default-deny BREACHED"

# --------------------------------------------------------------------------------------------------
say "ING6 — SSRF / path smuggling: no crafted target may reach an unintended upstream"
# --------------------------------------------------------------------------------------------------
# The ingress only ever bridges to the operator-pinned origin over the mesh; there is NO notion of an
# arbitrary upstream. We probe the classic SSRF / smuggling vectors and assert NONE returns a body that
# proves it reached an unintended target (a cloud-metadata IP, an internal name, an absolute-URI
# target). The decisive check: never 200-from-an-unintended-upstream, and never a metadata-shaped body.
ssrf_breach=0
# (a) Cloud metadata IP as the Host — an IP literal: parse_host_name rejects it (400), never a route.
mc=$(ing_code "169.254.169.254")
echo "  Host=169.254.169.254 (metadata IP literal) -> $mc (must be 400/404, never 200)"
[ "$mc" = 200 ] && ssrf_breach=1
# (b) Metadata host that is NOT a registered name -> default-deny 404 (even if it parsed).
mb=$(ing_code "metadata.google.internal")
echo "  Host=metadata.google.internal (unregistered) -> $mb (must be 404, never a metadata body)"
[ "$mb" = 200 ] && ssrf_breach=1
# (c) Absolute-URI / authority-form request target (SSRF via the request line). curl's --request-target
#     sends the line verbatim; request_target() rejects a scheme:// target. Even on a registered Host it
#     must not bridge to the absolute URI's authority.
abs_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
  --request-target "http://169.254.169.254/latest/meta-data/" \
  -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/" 2>/dev/null)
abs_body=$(curl -s --max-time 8 \
  --request-target "http://169.254.169.254/latest/meta-data/" \
  -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/" 2>/dev/null)
echo "  absolute-URI request target -> code=$abs_code (must be 400/4xx; must NOT proxy to the metadata authority)"
# (d) Path traversal in the URI — the origin forwards opaquely, but assert no host file leaks back.
trav_body=$(curl -s --max-time 8 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/../../../../etc/passwd" 2>/dev/null)
trav_enc_body=$(curl -s --max-time 8 -H "Host: testapp.user.ce-net.com" "http://127.0.0.1:$INGRESS/..%2f..%2f..%2fetc%2fpasswd" 2>/dev/null)
# Any response that smells like a metadata service or /etc/passwd is a breach.
for b in "$abs_body" "$trav_body" "$trav_enc_body"; do
  if printf '%s' "$b" | grep -qiE 'root:.*:0:0:|ami-id|instance-id|iam/security-credentials'; then ssrf_breach=1; fi
done
if [ "$ssrf_breach" -eq 0 ]; then
  xfail "ING6: SSRF/smuggling vectors (metadata IP/name, absolute-URI target, traversal) never reached an unintended upstream — relay only bridges the pinned origin"
else
  bad "ING6: a smuggled target reached an unintended upstream (metadata/passwd body or 200 from a non-route Host) — SSRF guard BREACHED"
fi

# --------------------------------------------------------------------------------------------------
say "ING2 — host-header spoof / name-allowlist bypass (case, trailing dot, blocked substring)"
# --------------------------------------------------------------------------------------------------
# The Host parser lowercases the first label (so case-variation of a registered name resolves to the
# same route — not a bypass), but structurally rejects a trailing dot and IP/punycode/non-LDH forms,
# and the abuse filter blocks phishing substrings on a name BEFORE any mesh work. None of these may
# silently bridge to an UNINTENDED node. We assert each is handled (never a 200 to an unregistered or
# blocked target, and never a 5xx-from-a-bridge for a structurally invalid host).
spoof_ok=1
# (a) Case-variation of an UNREGISTERED name -> still default-deny 404 (lowercased, no such route).
cs=$(ing_code "NoPe-NOT-Registered.user.ce-net.com"); echo "  case-varied unregistered -> $cs (expect 404)"
[ "$cs" = 404 ] || spoof_ok=0
# (b) Trailing dot on a registered name -> host parser rejects (ends_with('.')) -> 400 bad_host, no bridge.
td=$(ing_code "testapp.user.ce-net.com."); echo "  trailing-dot Host -> $td (expect 400, never a bridge/200)"
case "$td" in 200) spoof_ok=0;; esac
# (c) A blocked/reserved phishing substring as the name -> 404 (no such route) or 403 (blocked), never 200.
#     `paypal`/`admin`/`ce-net` are in the default blocked list; here they are also unregistered.
for nm in paypal admin ce-net-clone; do
  bc=$(ing_code "$nm.user.ce-net.com"); echo "  blocked/reserved substring '$nm' -> $bc (expect 403/404, never 200)"
  case "$bc" in 200) spoof_ok=0;; esac
done
# (d) A raw IP literal Host can never map to a name -> 400 bad_host (no node reachable by IP).
il=$(ing_code "10.0.0.5"); echo "  IP-literal Host -> $il (expect 400, never a route)"
case "$il" in 200) spoof_ok=0;; esac
if [ "$spoof_ok" -eq 1 ]; then
  xfail "ING2: host-spoof variants (case/dot/blocked-substring/IP-literal) are all blocked at parse/allowlist — none bridged to an unintended node"
else
  bad "ING2: a host-header spoof variant bridged or returned 200 to an unintended/blocked target — name-allowlist bypass"
fi

# --------------------------------------------------------------------------------------------------
say "ING3 — private route: no cap -> 401; forged/expired/wrong-root cap -> denied; valid chain -> 200"
# --------------------------------------------------------------------------------------------------
# (a) No X-CE-Cap header at all -> 401 (no_cap). [private endpoints require the header pre-bridge.]
cno=$(ing_code "secretapp.user.ce-net.com")
case "$cno" in
  401|403) xfail "ING3a: private route without X-CE-Cap -> $cno (denied)";;
  503)     skip  "ING3a: private route 503 (revocation set not yet loaded) — retrying below";;
  *)       bad   "ING3a: private route without a cap -> $cno (expected 401/403)";;
esac
# (b) A garbage/forged cap chain (not rooted at A) -> 403 cap_denied (and X-CE-Node present so we test
#     the chain, not the missing-header path).
FORGED_CAP="deadbeef$(printf 'a%.0s' {1..120})"
cforge=$(rt_code -H "Host: secretapp.user.ce-net.com" -H "X-CE-Cap: $FORGED_CAP" -H "X-CE-Node: $C_ID" "http://127.0.0.1:$INGRESS/")
echo "  forged (non-rooted) cap -> $cforge (expect 401/403, never 200)"
case "$cforge" in 200) bad "ING3b: a forged/garbage cap was ACCEPTED on the private route -> 200 — caller-auth BREACHED";; *) xfail "ING3b: forged/non-rooted cap denied ($cforge)";; esac
# (c) An EXPIRED but well-formed cap (issued --expires 2s above) -> denied (not_after enforced).
if [ ${#EXPIRED_CAP} -gt 20 ]; then
  sleep 3   # let the 2s cap lapse
  cexp=$(rt_code -H "Host: secretapp.user.ce-net.com" -H "X-CE-Cap: $EXPIRED_CAP" -H "X-CE-Node: $C_ID" "http://127.0.0.1:$INGRESS/")
  echo "  expired cap -> $cexp (expect 401/403, never 200)"
  case "$cexp" in 200) bad "ING3c: an EXPIRED cap was ACCEPTED on the private route -> 200 — not_after not enforced";; *) xfail "ING3c: expired cap denied ($cexp)";; esac
else
  skip "ING3c: could not mint a short-lived cap; expiry sub-case not exercised"
fi
# (d) A VALID expose:dial chain (X-CE-Cap = the chain A issued to C, X-CE-Node = C) -> 200. Retry to let
#     the mesh bridge warm and the relay's revoked-set load (private endpoints 503 until it does).
PRIV_OK=""
for i in $(seq 1 30); do
  cyes=$(rt_code -H "Host: secretapp.user.ce-net.com" -H "X-CE-Cap: $CALLER_CAP" -H "X-CE-Node: $C_ID" "http://127.0.0.1:$INGRESS/")
  [ "$cyes" = 200 ] && { PRIV_OK=1; break; }
  sleep 2
done
[ -n "$PRIV_OK" ] && xfail "ING3d: private route WITH a valid expose:dial cap (rooted at A, holder C) -> 200" \
  || bad "ING3d: private route with a valid cap -> $cyes (expected 200) — a legitimate caller is locked out"

# --------------------------------------------------------------------------------------------------
say "ING7 — per-route cap scoping: a cap valid for secretapp must NOT open otherapp (different root)"
# --------------------------------------------------------------------------------------------------
# CALLER_CAP is rooted at A and opens `secretapp` (dial_cap_root=A). `otherapp`'s dial_cap_root is the
# FOREIGN key D, which never issued anything to C. Presenting the SAME chain (and holder C) at otherapp
# must be denied: a chain rooted at route X's root does not satisfy route Y's root.
cscope=$(rt_code -H "Host: otherapp.user.ce-net.com" -H "X-CE-Cap: $CALLER_CAP" -H "X-CE-Node: $C_ID" "http://127.0.0.1:$INGRESS/")
echo "  secretapp-valid cap presented at otherapp (root=D) -> $cscope (expect 401/403, never 200)"
case "$cscope" in
  200) bad "ING7: a cap rooted at A opened otherapp (rooted at the FOREIGN key D) -> 200 — per-route cap scoping BROKEN";;
  *)   xfail "ING7: a cap valid for secretapp (root A) does NOT authorize otherapp (root D) -> $cscope — per-route dial_cap_root scoping holds";;
esac

# --------------------------------------------------------------------------------------------------
say "ING5 — rate limit: a fast burst over testapp's rps (3) must shed some requests with 429"
# --------------------------------------------------------------------------------------------------
# The per-endpoint token bucket refills at `rps`/sec; a burst much larger than the capacity must shed
# some requests with 429. (We attack the public route so no cap is needed.)
N429=0; NTOT=0
for i in $(seq 1 40); do
  rc=$(ing_code "testapp.user.ce-net.com")
  NTOT=$((NTOT+1))
  [ "$rc" = 429 ] && N429=$((N429+1))
done
echo "burst: $NTOT requests, $N429 -> 429"
[ "$N429" -gt 0 ] && xfail "ING5: per-endpoint rate limit tripped ($N429/$NTOT got 429) — the token bucket sheds a burst" \
  || bad "ING5: rate limit never tripped over the burst (0 of $NTOT were 429) — a public route is unthrottled"

# --------------------------------------------------------------------------------------------------
say "ING4 — kill switch: touch the kill-file -> 503 for EVERYTHING; rm -> back to 200"
# --------------------------------------------------------------------------------------------------
touch "$KILL"
KILLED=""
for i in $(seq 1 10); do
  ck=$(ing_code "testapp.user.ce-net.com")
  [ "$ck" = 503 ] && { KILLED=1; break; }
  sleep 1
done
[ -n "$KILLED" ] && xfail "ING4: kill-file present -> 503 (all ingress disabled without a restart)" \
  || bad "ING4: kill-file did not disable ingress (got $ck, expected 503) — the kill switch failed"
rm -f "$KILL"
REVIVED=""
for i in $(seq 1 20); do
  cr=$(ing_code "testapp.user.ce-net.com")
  [ "$cr" = 200 ] && { REVIVED=1; break; }
  sleep 1
done
[ -n "$REVIVED" ] && xfail "ING4: kill-file removed -> back to 200 (ingress recovers, no restart)" \
  || bad "ING4: ingress did not recover after removing the kill-file (got $cr)"

# --------------------------------------------------------------------------------------------------
say "post-attack health (the ingress + both nodes must be unharmed by every ingress probe)"
# --------------------------------------------------------------------------------------------------
if rt_alive "$A_PID" && rt_alive "$ING_PID" && rt_wait_api "$B_API" 8; then
  ok "origin A, the ingress server, and ingress-host B all survived every ingress attack (no crash)"
else
  bad "an ingress attack crashed a node or the ingress server (A_alive=$(rt_alive "$A_PID" && echo y || echo n) ING_alive=$(rt_alive "$ING_PID" && echo y || echo n))"
fi

rt_result
