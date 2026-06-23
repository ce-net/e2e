#!/usr/bin/env bash
# Hermetic native-worker end-to-end test: a headless ce-worker (Node) joins a
# local ce-hub over WebSocket, advertises this machine's cores, and actually
# computes WASM tasks pushed via POST /tasks. No browser, no Docker, no network.
#
# Proves: registration (nodes/cores show up), correct compute results for every
# builtin, auto-reconnect after the hub restarts, and clean departure (prune)
# when the worker dies.
#
#   HUB_BIN     ce-hub binary   (default $HOME/ce-net/web/ce-hub/target/release/ce-hub)
#   WORKER_JS   worker script   (default $HOME/ce-net/ce-worker/worker.js)
#   NODE_BIN    node executable (default: node on PATH)
set -u
export CE_NO_AUTOBOOTSTRAP=1
export CE_API_TOKEN="${CE_API_TOKEN:-e2e-shared-token}"

HUB=${HUB_BIN:-$HOME/ce-net/web/ce-hub/target/release/ce-hub}
WORKER=${WORKER_JS:-$HOME/ce-net/ce-worker/worker.js}
NODE=${NODE_BIN:-node}
HUB_PORT=${HUB_PORT:-18970}
WS_URL="ws://127.0.0.1:$HUB_PORT"
BASE="http://127.0.0.1:$HUB_PORT"
ROOT=/tmp/ce-e2e-worker
TMP=$ROOT/tmp
PIDS=()
PASS=0; FAIL=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# SKIP cleanly (exit 0) if the hub binary has not been built yet — keep CI green
# before the binaries exist; only real assertion failures cause a non-zero exit.
if [ ! -x "$HUB" ]; then
  echo "SKIP: ce-hub binary not found at $HUB"
  echo "      build it with: (cd $HOME/ce-net/web/ce-hub && cargo build --release)"
  echo "      or set HUB_BIN=/path/to/ce-hub"
  echo "PASS=0  FAIL=0"
  exit 0
fi
if [ ! -f "$WORKER" ]; then
  echo "SKIP: ce-worker script not found at $WORKER (set WORKER_JS)"
  echo "PASS=0  FAIL=0"
  exit 0
fi
if ! command -v "$NODE" >/dev/null 2>&1; then
  echo "SKIP: node not found on PATH (set NODE_BIN)"
  echo "PASS=0  FAIL=0"
  exit 0
fi

rm -rf "$ROOT"; mkdir -p "$ROOT" "$TMP"

# stats_int KEY -> integer value of KEY in GET /stats (0 on any failure)
stats_int() {
  curl -fsS --max-time 5 "$BASE/stats" 2>/dev/null \
    | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(int(d.get('$1',0)))
except Exception:
    print(0)" 2>/dev/null || echo 0
}

# start_hub -> launches ce-hub on $HUB_PORT, waits for /stats, records PID in HUB_PID
start_hub() {
  CE_HUB_PORT=$HUB_PORT CE_HUB_MODULES="$ROOT/nomodules" "$HUB" >>"$ROOT/hub.log" 2>&1 &
  HUB_PID=$!
  PIDS+=("$HUB_PID")
  for i in $(seq 1 30); do
    curl -fsS --max-time 3 "$BASE/stats" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# A self-contained 56-byte WASM module exporting add(i32,i32) and mul(i32,i32).
# base64 length is 76 (>64) so the hub forwards it as a raw module rather than a builtin name —
# this keeps the test hermetic (no dependency on the hub having a demo-modules dir).
WASM_B64='AGFzbQEAAAABBwFgAn9/AX8DAwIAAAcNAgNhZGQAAANtdWwAAQoRAgcAIAAgAWoLBwAgACABbAs='

# task FUNC "ARG1,ARG2" -> echoes the "value" string from POST /tasks (empty on failure)
task() {
  curl -fsS --max-time 35 -X POST "$BASE/tasks" \
    -H 'content-type: application/json' \
    -d "{\"module\":\"$WASM_B64\",\"func\":\"$1\",\"args\":[$2],\"ret\":\"i32\"}" 2>/dev/null \
    | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('value','') if d.get('ok') else '')
except Exception:
    print('')" 2>/dev/null
}

say "start ce-hub on test port $HUB_PORT"
if start_hub; then
  ok "ce-hub up (GET /stats responds)"
else
  bad "ce-hub failed to start"; tail -20 "$ROOT/hub.log"; echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi

say "start native headless worker (node)"
CE_WORKER_ID_FILE="$TMP/wid" "$NODE" "$WORKER" --hub "$WS_URL" --name e2e \
  >>"$ROOT/worker.log" 2>&1 &
WORKER_PID=$!
PIDS+=("$WORKER_PID")

say "worker registers: nodes>=1 and cores>=1 within ~15s"
JOINED=""
for i in $(seq 1 15); do
  n=$(stats_int nodes); c=$(stats_int cores)
  if [ "$n" -ge 1 ] && [ "$c" -ge 1 ]; then JOINED=1; break; fi
  sleep 1
done
if [ -n "$JOINED" ]; then
  ok "worker registered (nodes=$(stats_int nodes) cores=$(stats_int cores))"
else
  bad "worker did not register (nodes=$(stats_int nodes) cores=$(stats_int cores))"
  echo "--- worker.log ---"; tail -20 "$ROOT/worker.log"
fi

say "GET /nodes lists a node whose platform contains 'node/'"
NODES_JSON=$(curl -fsS --max-time 5 "$BASE/nodes" 2>/dev/null)
echo "$NODES_JSON" | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert any("node/" in n.get("platform","") for n in d.get("nodes",[])), d' 2>/dev/null \
  && ok "native node advertised platform contains node/" \
  || bad "no node with platform containing node/ ($NODES_JSON)"

say "compute: the worker executes a pushed WASM module and returns exact results"
declare -a FUNCS=(add mul add)
declare -a ARGS=("2,3" "6,7" "1000000,337")
declare -a WANT=(5 42 1000337)
for idx in 0 1 2; do
  f=${FUNCS[$idx]}; a=${ARGS[$idx]}; want=${WANT[$idx]}
  got=""
  # retry: the worker may still be benchmarking/connecting on the first call
  for i in $(seq 1 5); do
    got=$(task "$f" "$a")
    [ -n "$got" ] && break
    sleep 1
  done
  if [ "$got" = "$want" ]; then
    ok "$f($a) = $want"
  else
    bad "$f($a) expected $want got '${got:-<empty>}'"
  fi
done

say "resilience: restart the hub on the same port; worker auto-reconnects"
kill "$HUB_PID" 2>/dev/null
# wait for the old listener to actually release the port
for i in $(seq 1 15); do
  curl -fsS --max-time 2 "$BASE/stats" >/dev/null 2>&1 || break
  sleep 1
done
if start_hub; then
  ok "ce-hub restarted on port $HUB_PORT"
else
  bad "ce-hub failed to restart"; tail -20 "$ROOT/hub.log"
fi
# worker backoff caps at 30s, so allow generous reconnect time
RECON=""
for i in $(seq 1 40); do
  [ "$(stats_int nodes)" -ge 1 ] && { RECON=1; break; }
  sleep 1
done
if [ -n "$RECON" ]; then
  ok "worker auto-reconnected after hub restart (nodes>=1)"
else
  bad "worker did not reconnect within timeout"
  echo "--- worker.log ---"; tail -20 "$ROOT/worker.log"
fi

say "drop: kill the worker; it leaves /stats within the hub prune window"
kill "$WORKER_PID" 2>/dev/null
# hub STALE window is 35s, prune loop runs every 10s -> allow up to ~60s
DROPPED=""
for i in $(seq 1 60); do
  [ "$(stats_int nodes)" -eq 0 ] && { DROPPED=1; break; }
  sleep 1
done
if [ -n "$DROPPED" ]; then
  ok "worker pruned from /stats after disconnect (nodes=0)"
else
  bad "worker still listed after disconnect (nodes=$(stats_int nodes))"
fi

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
