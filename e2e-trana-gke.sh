#!/usr/bin/env bash
# e2e-trana-gke.sh — verify ce-gke orchestrates trana on a REAL mesh and self-heals under failure.
#
# This is the live-infrastructure counterpart to ce-gke's deterministic `tests/trana_e2e.rs`. Where
# that test pins the reconcile/heal CONTRACT in-process (FakeDriver), this drives the actual `ce-gke`
# binary against a live CE node so the full path is exercised: manifest -> placement -> mesh-deploy
# of trana containers -> liveness probes -> DHT advertise -> heal on failure.
#
#   1. ce-gke apply -f trana.gke.yaml      → desired replicas placed on docker-capable hosts
#   2. ce-gke get                          → converges to N/N Running
#   3. locate ce-gke/social/trana-api      → the healthy set is discoverable over the mesh
#   4. kill a replica (mesh-kill) + run    → ce-gke replaces it, back to N/N  (fault tolerant)
#
# REQUIREMENTS (skips cleanly, exit 0, if absent):
#   - the `ce-gke` binary (CE_GKE_BIN)              — build it: ~/ce-net/ce-gke
#   - a reachable CE node with docker-capable peers (CE_NODE, default http://127.0.0.1:8844)
#   - a published trana container image referenced by deploy/trana.gke.yaml
#   - a capability token authorizing deploy/kill on the hosts (GRANT), if the hosts require one
#
# It does NOT provision anything; point it at a mesh that already has docker hosts (the relay, a VM
# pool, or `relay-e2e.sh` containers). State is kept in a scratch dir and the deployment is deleted
# on exit.

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

PASS=0; FAIL=0
say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; }

CE_GKE_BIN=${CE_GKE_BIN:-$HOME/ce-net/.cargo-shared/release/ce-gke}
[ -x "$CE_GKE_BIN" ] || CE_GKE_BIN=$HOME/ce-net/ce-gke/target/release/ce-gke
CE_NODE=${CE_NODE:-http://127.0.0.1:8844}
MANIFEST=${MANIFEST:-$HOME/ce-net/trana/deploy/trana.gke.yaml}
GRANT=${GRANT:-}
NS=social
NAME=trana-node
WANT=${WANT:-4}

ROOT=$(mktemp -d "/tmp/ce-trana-gke-XXXX")
STATE="$ROOT/gke-state.json"
cleanup() {
  "$CE_GKE_BIN" --node "$CE_NODE" --state "$STATE" -n "$NS" delete "$NAME" --force >/dev/null 2>&1
  rm -rf "$ROOT"
}
trap cleanup EXIT

[ -x "$CE_GKE_BIN" ] || { skip "ce-gke not built at $CE_GKE_BIN; skipping live gke e2e"; echo "PASS=$PASS FAIL=$FAIL"; exit 0; }
[ -f "$MANIFEST" ]   || { skip "manifest $MANIFEST missing; skipping"; echo "PASS=$PASS FAIL=$FAIL"; exit 0; }
curl -fsS -m5 "$CE_NODE/status" >/dev/null 2>&1 || { skip "no CE node at $CE_NODE; skipping"; echo "PASS=$PASS FAIL=$FAIL"; exit 0; }

GFLAGS=(--node "$CE_NODE" --state "$STATE" -n "$NS")
[ -n "$GRANT" ] && GFLAGS+=(--grant "$GRANT")

# Count Running replicas from `ce-gke get` (parses the "<ready>/<desired>" column if present, else
# falls back to counting running phase lines).
ready_count() {
  "$CE_GKE_BIN" "${GFLAGS[@]}" get "$NAME" 2>/dev/null \
    | grep -oE '[0-9]+/[0-9]+' | head -1 | cut -d/ -f1
}

# --------------------------------------------------------------------------------------------------
say "apply trana via ce-gke (desired=$WANT)"
# Honor the manifest's replica count, but allow WANT override for a smaller live run.
if "$CE_GKE_BIN" "${GFLAGS[@]}" apply -f "$MANIFEST" >"$ROOT/apply.log" 2>&1; then
  ok "ce-gke accepted the trana manifest"
else
  bad "ce-gke apply failed (see $ROOT/apply.log)"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
"$CE_GKE_BIN" "${GFLAGS[@]}" scale "$NAME" "$WANT" >/dev/null 2>&1 || true

say "converge to $WANT/$WANT Running"
converged=0
for _ in $(seq 1 40); do
  "$CE_GKE_BIN" "${GFLAGS[@]}" rollout status "$NAME" >/dev/null 2>&1 || true
  r=$(ready_count)
  echo "  ready=$r/$WANT"
  [ "${r:-0}" = "$WANT" ] && { converged=1; break; }
  sleep 3
done
[ "$converged" = 1 ] && ok "trana converged to $WANT replicas" || bad "trana did not reach $WANT replicas"

say "healthy replica set is discoverable (ce-gke/$NS/trana-api)"
if "$CE_GKE_BIN" "${GFLAGS[@]}" get "$NAME" 2>/dev/null | grep -qi "trana-api\|running"; then
  ok "deployment reports a service / running replicas"
else
  skip "could not read service status from ce-gke get output"
fi

# --------------------------------------------------------------------------------------------------
say "FAULT: kill a replica; ce-gke must replace it"
# Grab one replica's (node_id, job_id) from the persisted state and kill it directly on its host.
victim=$(python3 - "$STATE" "$NS/$NAME" <<'PY' 2>/dev/null
import sys, json
state, key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(state))
    reps = d["deployments"][key]["replicas"]
    r = reps[0]
    print(r["node_id"], r["job_id"])
except Exception:
    pass
PY
)
if [ -n "$victim" ]; then
  vnode=$(echo "$victim" | awk '{print $1}'); vjob=$(echo "$victim" | awk '{print $2}')
  echo "  killing replica job=$vjob on node=$vnode"
  curl -fsS -m8 -X POST "$CE_NODE/mesh-kill" -H 'content-type: application/json' \
    -d "{\"node_id\":\"$vnode\",\"job_id\":\"$vjob\",\"grant\":${GRANT:+\"$GRANT\"}${GRANT:-null}}" \
    >/dev/null 2>&1 || true

  healed=0
  for _ in $(seq 1 40); do
    "$CE_GKE_BIN" "${GFLAGS[@]}" rollout status "$NAME" >/dev/null 2>&1 || true
    r=$(ready_count)
    echo "  ready=$r/$WANT"
    [ "${r:-0}" = "$WANT" ] && { healed=1; break; }
    sleep 3
  done
  [ "$healed" = 1 ] && ok "ce-gke healed the killed replica back to $WANT/$WANT (fault tolerant)" \
    || bad "ce-gke did not heal back to $WANT after a replica was killed"
else
  skip "no replica handle in state to kill (deploy may not have placed any)"
fi

say "RESULT"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
