#!/usr/bin/env bash
# spacegame full-stack e2e orchestrator — runs the native multi-VM test and the mobile/WASM browser
# test, then reports a combined result. Each leg is independently runnable; this just ties them and
# asserts the two worlds meet (native VMs and a phone-in-browser share the same mesh).
#
#   e2e/spacegame-e2e.sh
#   SPACEGAME_BIN=/path/to/linux/spacegame SPACEGAME_URL=https://<frontend>/ e2e/spacegame-e2e.sh
#
# Legs:
#   1. spacegame-vm-e2e.sh   — fresh Hetzner VMs: install ce, host the galaxy, prove distribution,
#                              transit (infinite map), hot reload, combat, and replica failover.
#   2. browser/...mjs        — a phone-emulated browser joins the SAME live mesh over the WASM/same-
#                              origin node; with NATIVE_PEER it asserts it shares a sector with natives.
set -uo pipefail
cd "$(dirname "$0")"

RC=0

echo "########################################################################"
echo "# LEG 1/2: native multi-VM e2e (real machines, fresh install)"
echo "########################################################################"
if ./spacegame-vm-e2e.sh; then
  echo "LEG 1: native VM e2e PASSED"
else
  echo "LEG 1: native VM e2e FAILED (or gated on Hetzner server limit)"
  RC=1
fi

echo
echo "########################################################################"
echo "# LEG 2/2: mobile / WASM browser e2e (phone in browser, no install)"
echo "########################################################################"
if [ -z "${SPACEGAME_URL:-}" ]; then
  echo "SKIP: set SPACEGAME_URL to a deployed spacegame frontend to run the browser leg."
else
  if (cd browser && npm ci --silent >/dev/null 2>&1 || npm install --silent >/dev/null 2>&1; \
       NATIVE_PEER="${NATIVE_PEER:-}" DEVICE="${DEVICE:-Pixel 7}" SPACEGAME_URL="$SPACEGAME_URL" node spacegame-browser-e2e.mjs); then
    echo "LEG 2: mobile/WASM browser e2e PASSED"
  else
    echo "LEG 2: mobile/WASM browser e2e FAILED"
    RC=1
  fi
fi

echo
echo "########################################################################"
[ "$RC" -eq 0 ] && echo "# spacegame e2e: ALL LEGS PASSED" || echo "# spacegame e2e: FAILURES (see above)"
echo "########################################################################"
exit "$RC"
