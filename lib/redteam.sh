# shellcheck shell=bash
# lib/redteam.sh — shared helpers for the adversarial ("compromise the mesh") e2e suite.
#
# SOURCE THIS, do not execute it. Every e2e-attack-*.sh sources this once near the top:
#
#     SELF_DIR=$(cd "$(dirname "$0")" && pwd)
#     . "$SELF_DIR/lib/redteam.sh"
#
# It provides: the say/ok/bad/xfail/known_open accounting helpers, a uniform cleanup trap,
# ephemeral-node spin-up (single node + an N-node mining mesh), API readiness waits, status-field
# probing, identity/peer extraction, a forged-payload curl helper, and the final result line.
#
# HERMETIC INVARIANTS (every helper here enforces or assumes them — never weaken these):
#   - nodes are ephemeral (in-RAM: --ephemeral) and mDNS-isolated (--no-mdns)
#   - CE_NO_AUTOBOOTSTRAP=1 is exported so a node NEVER dials ce-net.com
#   - everything binds loopback (127.0.0.1) on high, non-conflicting ports
#   - a per-suite CE_API_TOKEN is set so the suite itself can drive mutating endpoints, while the
#     ATTACK probes deliberately omit it to prove the gate holds
#
# This file does NOT set `set -u` / `set -e` (the sourcing script owns shell options) and does NOT
# install the trap by itself — the sourcing script calls `rt_init`/`rt_arm_cleanup`. That keeps the
# library inert until the script opts in, which is what makes it safe to `bash -n` and to source.

# --------------------------------------------------------------------------------------------------
# Binaries (env-overridable; defaults sit beside this repo under ~/ce-net/<repo>).
# --------------------------------------------------------------------------------------------------
CE_BIN=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
RDEV_BIN=${RDEV_BIN:-$HOME/ce-net/rdev/target/release/rdev}
EXPOSE_BIN=${EXPOSE_BIN:-$HOME/ce-net/ce-expose/target/release/ce-expose}
# Back-compat alias: existing scripts read $CE.
CE=${CE:-$CE_BIN}

# --------------------------------------------------------------------------------------------------
# Accounting. PASS/FAIL gate the suite; KNOWN_OPEN is tallied separately and never fails the run.
# XFAIL is an expected-negative that PASSED (the defense held) — counts as a pass.
# --------------------------------------------------------------------------------------------------
PASS=${PASS:-0}
FAIL=${FAIL:-0}
KNOWN_OPEN=${KNOWN_OPEN:-0}

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; }

# xfail(): the attack was mounted and the defense DEFEATED it (the expected, healthy outcome for a
# MUST-HOLD defense). Counts as a pass; phrased as "attack failed, as it must".
xfail() { echo "XFAIL (defense held): $1"; PASS=$((PASS+1)); }

# known_open("audit Ex: <what got through>"): the attack SUCCEEDED against a defense the audit marks
# OPEN/PARTIAL. This is EXPECTED today and prints a loud, greppable line. It is tallied separately
# and does NOT fail the suite. When the defense lands, flip the test to xfail()/bad() so a
# regression (the hole silently reopening, or the fix silently not landing) is caught.
known_open() {
  echo "############################################################"
  echo "## KNOWN-OPEN (audit): $1"
  echo "## -> attack succeeded as EXPECTED; defense is OPEN/PARTIAL per the audit."
  echo "## -> when the defense lands, flip this assertion to must-hold (xfail/bad)."
  echo "############################################################"
  KNOWN_OPEN=$((KNOWN_OPEN+1))
}

# --------------------------------------------------------------------------------------------------
# Lifecycle. ROOT is a per-suite scratch dir; PIDS collects every spawned process.
# --------------------------------------------------------------------------------------------------
PIDS=()
ROOT=${ROOT:-}

# rt_init <suite-name>: pick a unique scratch ROOT (if unset), wipe it, export the hermetic env, and
# require the ce binary (skip the whole suite cleanly if missing). Call once near the top.
rt_init() {
  local name=${1:-redteam}
  ROOT=${ROOT:-/tmp/ce-redteam-$name-$$}
  export CE_NO_AUTOBOOTSTRAP=1
  export CE_API_TOKEN="${CE_API_TOKEN:-redteam-$name-token}"
  rm -rf "$ROOT"; mkdir -p "$ROOT"
  if [ ! -x "$CE_BIN" ]; then
    skip "ce not found at $CE_BIN (set CE_BIN); skipping $name attack suite"
    echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"
    exit 0
  fi
}

# rt_arm_cleanup: install the EXIT trap that kills every spawned PID and any straggler under ROOT.
# Uses the empty-array guard so `set -u` does not trip on an empty PIDS.
rt_cleanup() {
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  [ -n "${ROOT:-}" ] && pkill -f "$ROOT" 2>/dev/null
  return 0
}
rt_arm_cleanup() { trap rt_cleanup EXIT; }

# rt_need_bin <path> <label>: skip the suite cleanly (exit 0) if an optional binary is absent.
rt_need_bin() {
  if [ ! -x "$1" ]; then
    skip "$2 not found at $1; skipping this attack suite"
    echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"
    exit 0
  fi
}

# --------------------------------------------------------------------------------------------------
# Identity / API helpers.
# --------------------------------------------------------------------------------------------------
# rt_node_id <data-dir>  -> 64-hex CE node id
rt_node_id() { "$CE_BIN" --data-dir "$1" id 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1; }
# rt_peer_id <data-dir>  -> 12D3Koo... libp2p peer id
rt_peer_id() { "$CE_BIN" --data-dir "$1" id 2>/dev/null | grep -oE '12D3[A-Za-z0-9]+' | head -1; }
# rt_addr <data-dir> <p2p-port>  -> dialable /ip4/127.0.0.1 multiaddr for bootstrapping
rt_addr() { echo "/ip4/127.0.0.1/tcp/$2/p2p/$(rt_peer_id "$1")"; }

# rt_wait_api <api-port> [tries]  -> 0 once GET /status answers, else 1. Default 40 tries (~40s).
rt_wait_api() {
  local port=$1 tries=${2:-40} i
  for i in $(seq 1 "$tries"); do
    curl -fsS "http://127.0.0.1:$port/status" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# rt_field <api-port> <json-key>  -> value of a top-level /status field (-1 on any failure).
rt_field() {
  curl -fsS "http://127.0.0.1:$1/status" 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('$2'))" 2>/dev/null \
    || echo -1
}

# rt_json <url>  -> raw body (curl GET, no auth, short timeout). For reading public read-only API.
rt_json() { curl -fsS --max-time 8 "$1" 2>/dev/null; }

# rt_code <curl-args...>  -> just the HTTP status code of a request (for "must be 401/404/..." asserts).
rt_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }

# --------------------------------------------------------------------------------------------------
# Node spin-up.
# --------------------------------------------------------------------------------------------------
# rt_start_node <name> <p2p-port> <api-port> [extra ce-start args...]
#   Starts ONE ephemeral, mDNS-isolated node with its data dir at $ROOT/<name>, log at
#   $ROOT/<name>.log, appends its PID to PIDS, and waits for the API. Returns 0/1 on readiness.
#   Pass extra flags through, e.g.:  rt_start_node h0 6000 8000 --no-mine
#                                    rt_start_node h1 6001 8001 --bootstrap "$SEED"
rt_start_node() {
  local name=$1 p2p=$2 api=$3; shift 3
  mkdir -p "$ROOT/$name"
  "$CE_BIN" --data-dir "$ROOT/$name" start \
    --port "$p2p" --api-port "$api" --no-mdns --ephemeral "$@" \
    >"$ROOT/$name.log" 2>&1 &
  PIDS+=($!)
  rt_wait_api "$api"
}

# rt_start_mesh <N> <p2p-base> <api-base> [extra ce-start args...]
#   Stands up an N-node MINING mesh: node h0 is the seed; h1..h(N-1) bootstrap from it. Each node
#   gets ports <base>+i. Mining is ON (no --no-mine) so blocks/credits flow — the substrate the
#   economy/consensus/sybil attacks run against. Sets the globals:
#       RT_SEED   = h0's dialable multiaddr (for an attacker to rejoin from)
#       RT_N      = N
#       RT_P2P0/RT_API0 = h0's ports (and api = api-base+i for node i)
#   Returns 0 if the seed came up, else 1.
rt_start_mesh() {
  local n=$1 p2p0=$2 api0=$3; shift 3
  RT_N=$n; RT_P2P0=$p2p0; RT_API0=$api0
  rt_start_node h0 "$p2p0" "$api0" "$@" || return 1
  RT_SEED=$(rt_addr "$ROOT/h0" "$p2p0")
  local i
  for i in $(seq 1 $((n-1))); do
    rt_start_node "h$i" $((p2p0+i)) $((api0+i)) --bootstrap "$RT_SEED" "$@" >/dev/null 2>&1
    sleep 0.3
  done
  return 0
}

# rt_mesh_heights  -> echoes the space-separated /status height of every mesh node h0..h(N-1).
rt_mesh_heights() {
  local i hs=""
  for i in $(seq 0 $((RT_N-1))); do hs="$hs $(rt_field $((RT_API0+i)) height)"; done
  echo "$hs"
}

# rt_mesh_converged <max-drift> <min-alive-frac-num> <min-alive-frac-den>
#   Echoes "min max alive" and returns 0 iff: min height >= 1, (max-min) <= max-drift, and the
#   number of alive nodes >= N*num/den. Used to assert the honest substrate is healthy before/after.
rt_mesh_converged() {
  local drift=${1:-4} num=${2:-3} den=${3:-4}
  local hs mn mx up
  hs=$(rt_mesh_heights)
  read -r mn mx <<<"$(echo "$hs" | tr ' ' '\n' | grep -v '^-1$' | grep -v '^None$' | sort -n | awk 'NR==1{m=$1}{M=$1}END{print m" "M}')"
  up=$(echo "$hs" | tr ' ' '\n' | grep -vc -e '^-1$' -e '^None$' -e '^$')
  echo "$mn $mx $up"
  [ "${mn:-0}" -ge 1 ] && [ $(( ${mx:-0} - ${mn:-0} )) -le "$drift" ] && [ "$up" -ge $((RT_N*num/den)) ]
}

# --------------------------------------------------------------------------------------------------
# Forged-payload helper.
# --------------------------------------------------------------------------------------------------
# rt_forge <method> <api-port> <path> <json-body> [extra curl args...]
#   Fire a crafted request at a node's HTTP API and echo ONLY the status code. By default it sends
#   NO Authorization header — that is the point of most attacks (prove the gate rejects). To attack
#   an endpoint WITH the suite token (e.g. to test resource-scoping bugs past the token gate) append
#   -H "authorization: Bearer $CE_API_TOKEN".
#
#   Examples:
#     rt_forge POST 8000 /transfer '{"to":"00","amount":"1"}'                  # expect 401
#     rt_forge POST 8000 /mesh-kill '{"node_id":"..","job_id":".."}'           # expect 401
#     rt_forge POST 8000 /jobs/bid '{...}' -H "authorization: Bearer $CE_API_TOKEN"
rt_forge() {
  local method=$1 api=$2 path=$3 body=$4; shift 4
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -X "$method" "http://127.0.0.1:$api$path" \
    -H 'content-type: application/json' \
    "$@" \
    -d "$body"
}

# rt_forge_body <method> <api-port> <path> <json-body> [extra curl args...]
#   Like rt_forge but echoes the RESPONSE BODY (for asserting an error message / a leaked field).
rt_forge_body() {
  local method=$1 api=$2 path=$3 body=$4; shift 4
  curl -s --max-time 8 \
    -X "$method" "http://127.0.0.1:$api$path" \
    -H 'content-type: application/json' \
    "$@" \
    -d "$body"
}

# rt_alive <pid>  -> 0 if the process is still running. Used to assert "no panic / no crash" after a
# malformed-payload flood (panic-resistance).
rt_alive() { kill -0 "$1" 2>/dev/null; }

# --------------------------------------------------------------------------------------------------
# Result line. Call at the very end; returns non-zero iff FAIL>0 (KNOWN_OPEN never fails the run).
# --------------------------------------------------------------------------------------------------
rt_result() {
  say "RESULT"
  echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"
  [ "$FAIL" -eq 0 ]
}
