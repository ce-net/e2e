#!/usr/bin/env bash
# Cross-repo app smoke test: runs each CE app's own offline selftest — the checks a
# developer/CI should always be able to reproduce on any machine with just Node.
# Node-only, no Rust build, no Docker, no network. Each repo block SKIPs (does not FAIL)
# if its directory is absent, so this stays green on a partial checkout.
#
# Repo locations are overridable; defaults sit beside this repo under ~/ce-net/<repo>.
#   WORKER_DIR  ce-worker   TABNET_DIR  ce-tabnet   BENCH_DIR  ce-bench
#   GOV_DIR     ce-gov      SCHED_DIR   ce-sched
set -u
export CE_NO_AUTOBOOTSTRAP=1

NODE=${NODE_BIN:-node}
WORKER_DIR=${WORKER_DIR:-$HOME/ce-net/ce-worker}
GOV_DIR=${GOV_DIR:-$HOME/ce-net/ce-gov}
TABNET_DIR=${TABNET_DIR:-$HOME/ce-net/ce-tabnet}
SCHED_DIR=${SCHED_DIR:-$HOME/ce-net/ce-sched}
BENCH_DIR=${BENCH_DIR:-$HOME/ce-net/ce-bench}
PIDS=()
PASS=0; FAIL=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; }
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# check_all DIR GLOB LABEL — `node --check` every file matching DIR/GLOB (node --check
# only accepts one file at a time, so we loop). Asserts the whole set parses.
check_all() {
  local dir=$1 glob=$2 label=$3 f n=0
  for f in "$dir"/$glob; do
    [ -e "$f" ] || continue
    n=$((n+1))
    if ! "$NODE" --check "$f" 2>/dev/null; then
      bad "$label: $f failed to parse"; return 1
    fi
  done
  [ "$n" -gt 0 ] && ok "$label: $n file(s) parse cleanly" || bad "$label: no files matched $glob"
}

# ----------------------------------------------------------------------------
say "ce-worker — syntax check of the headless worker"
if [ -d "$WORKER_DIR" ]; then
  if "$NODE" --check "$WORKER_DIR/worker.js" 2>/dev/null; then
    ok "ce-worker: worker.js parses cleanly"
  else
    bad "ce-worker: worker.js failed node --check"
  fi
else
  skip "ce-worker not present at $WORKER_DIR"
fi

# ----------------------------------------------------------------------------
say "ce-gov — syntax check src + examples, then run the offline demos"
if [ -d "$GOV_DIR" ]; then
  check_all "$GOV_DIR" "src/*.js"      "ce-gov src"
  check_all "$GOV_DIR" "examples/*.js" "ce-gov examples"
  for demo in scan-demo tally-demo monitor-demo; do
    out=$(cd "$GOV_DIR" && "$NODE" "examples/$demo.js" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^OK:'; then
      ok "ce-gov: $demo printed its OK: line"
    else
      bad "ce-gov: $demo (rc=$rc, last: $(printf '%s\n' "$out" | tail -1))"
    fi
  done
else
  skip "ce-gov not present at $GOV_DIR"
fi

# ----------------------------------------------------------------------------
say "ce-tabnet — pipeline-parallel inference selftest"
if [ -d "$TABNET_DIR" ]; then
  out=$(cd "$TABNET_DIR" && "$NODE" dev/serve.js --selftest 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'SELFTEST PASSED'; then
    ok "ce-tabnet: selftest reported SELFTEST PASSED"
  else
    bad "ce-tabnet: selftest (rc=$rc, last: $(printf '%s\n' "$out" | tail -1))"
  fi
else
  skip "ce-tabnet not present at $TABNET_DIR"
fi

# ----------------------------------------------------------------------------
say "ce-sched — syntax check src + resolve the package entry point"
if [ -d "$SCHED_DIR" ]; then
  check_all "$SCHED_DIR" "src/*.js" "ce-sched src"
  out=$(cd "$SCHED_DIR" && "$NODE" -e "import('./src/index.js').then(()=>console.log('IMPORT OK')).catch(e=>{console.error(e&&e.stack||e);process.exit(1)})" 2>&1)
  if [ $? -eq 0 ] && printf '%s\n' "$out" | grep -q 'IMPORT OK'; then
    ok "ce-sched: import('./src/index.js') resolved"
  else
    bad "ce-sched: index import failed ($(printf '%s\n' "$out" | tail -1))"
  fi
else
  skip "ce-sched not present at $SCHED_DIR"
fi

# ----------------------------------------------------------------------------
say "ce-bench — syntax check src + resolve the package entry point"
if [ -d "$BENCH_DIR" ]; then
  check_all "$BENCH_DIR" "src/*.js" "ce-bench src"
  out=$(cd "$BENCH_DIR" && "$NODE" -e "import('./src/index.js').then(()=>console.log('IMPORT OK')).catch(e=>{console.error(e&&e.stack||e);process.exit(1)})" 2>&1)
  if [ $? -eq 0 ] && printf '%s\n' "$out" | grep -q 'IMPORT OK'; then
    ok "ce-bench: import('./src/index.js') resolved"
  else
    bad "ce-bench: index import failed ($(printf '%s\n' "$out" | tail -1))"
  fi
else
  skip "ce-bench not present at $BENCH_DIR"
fi

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
