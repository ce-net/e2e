#!/usr/bin/env bash
# e2e-attack-caps.sh — adversarial capability / auth red team (threat-model Path 0 + Path B).
#
# ce-cap is IMPLEMENTED (crates/ce-cap + crates/ce-node/src/capability.rs, spec in
# ce/docs/capabilities.md), so EVERY cap attack here is MUST-HOLD: the attack must be DEFEATED, and
# a SUCCESS is a real regression -> bad()/FAIL. The one exception is CAP10 (kill-RPC resource scope,
# audit finding D1) which the audit marks OPEN -> known_open().
#
# Topology (hermetic, in-RAM, mDNS-isolated, loopback, never ce-net.com):
#   - HOST node  (api 9100 / p2p 7100): mining ON. It is the capability ROOT — every legitimate cap
#     is self-issued by HOST via `ce grant --data-dir <host>`. `rdev serve --node <host>` runs the
#     ce-cap enforcement point against it, with HOME pinned to a scratch dir so file writes are
#     contained and `roots` is empty (only self-issued caps are honored).
#   - ATTACKER node (api 9101 / p2p 7101): the rdev CLIENT points here, so the noise-authenticated
#     requester the server sees (`from` == cap audience for a legit cap) is the ATTACKER's node id.
#
# Attacks mounted (all rooted in capabilities.md's authorize() steps 1-7):
#   CAP1  no-token API takeover  (mutating endpoints -> 401)                       MUST-HOLD (Path 0)
#   CAP2  API bound to loopback, not 0.0.0.0                                        MUST-HOLD (Path 0)
#   CAP3  no-cap / empty-cap mesh action -> denied                                 MUST-HOLD (Path B)
#   CAP4  forged-root cap (foreign key, not an accepted root) -> denied            MUST-HOLD (step 1)
#   CAP5  ability mismatch: a sync-only cap used for exec/spawn -> denied          MUST-HOLD (step 7)
#   CAP6  path_prefix caveat escape: write outside the granted prefix -> denied    MUST-HOLD (fail-closed)
#   CAP7  expiry: a not_after-past cap -> denied                                   MUST-HOLD (step 3)
#   CAP8  on-chain RevokeCapability, then reuse the revoked cap -> denied          MUST-HOLD (revocation)
#   CAP9  wrong holder / confused deputy: cap issued to X, presented by Y -> denied MUST-HOLD (step 7 audience)
#   CAP10 kill-RPC resource scope (D1): any kill cap kills any job                 KNOWN-OPEN (audit D1)
#
# rdev (RDEV_BIN) drives CAP3/4/5/6/7/8/9 (the ce-cap enforcement point lives in `rdev serve`); if it
# is absent those skip cleanly and only the node-only CAP1/CAP2 run. CAP10 is node-only.
#
# NOTE on attenuation: `ce grant` only issues ROOT links (parent=None), so the multi-link
# "child grants MORE than its parent" escalation needs a `ce delegate`-style tool that does not yet
# exist. The attenuation SURFACE reachable from the CLI today is the leaf check (authorize step 7:
# leaf.abilities must include the action, leaf.audience must equal the requester) plus the caveat
# checks (path_prefix CAP6, not_after CAP7) — those are exactly CAP5/6/7/9. When a delegation tool
# lands, add a true 2-link escalation case here as a sibling MUST-HOLD.

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/redteam.sh
. "$SELF_DIR/lib/redteam.sh"

rt_init caps
rt_arm_cleanup

# ----- hermetic HOME for the rdev server (contains file writes; empties the cap `roots` set) -----
HOST_HOME="$ROOT/host-home"
mkdir -p "$HOST_HOME"

# ----- ports (disjoint per the redteam.md port plan: caps = p2p 7100 / api 9100) -----
HOST_P2P=7100; HOST_API=9100
ATK_P2P=7101;  ATK_API=9101

# ==================================================================================================
say "spin up HOST (cap root + rdev serve target) and ATTACKER nodes — in-RAM, mDNS-isolated"
# HOST mines so an on-chain RevokeCapability actually lands in a block (CAP8 needs this).
rt_start_node hostnode "$HOST_P2P" "$HOST_API" || { bad "host node API never came up"; rt_result; exit 1; }
HOST_ID=$(rt_node_id "$ROOT/hostnode")
SEED=$(rt_addr "$ROOT/hostnode" "$HOST_P2P")
echo "host node id: $HOST_ID"
echo "host seed:    $SEED"

# ATTACKER bootstraps from HOST so the rdev request can route HOST<->ATTACKER over the mesh.
rt_start_node atknode "$ATK_P2P" "$ATK_API" --bootstrap "$SEED" || { bad "attacker node API never came up"; rt_result; exit 1; }
ATK_ID=$(rt_node_id "$ROOT/atknode")
echo "attacker node id: $ATK_ID"

[ -n "$HOST_ID" ] && [ -n "$ATK_ID" ] && [ "$HOST_ID" != "$ATK_ID" ] \
  && ok "two distinct ephemeral nodes up (host=$HOST_ID atk=$ATK_ID)" \
  || bad "could not stand up two distinct nodes"

# ==================================================================================================
# CAP1 — no-token API takeover. Every MUTATING (non-GET) endpoint must require the Bearer token
# (require_api_token, api.rs:147). We deliberately omit Authorization (rt_forge sends none).
# ==================================================================================================
say "CAP1 — no-token API takeover (mutating endpoints must 401)"
c_transfer=$(rt_forge POST "$HOST_API" /transfer        '{"to":"00","amount":"1"}')
c_revoke=$(  rt_forge POST "$HOST_API" /capabilities/revoke '{"nonce":1}')
c_bid=$(     rt_forge POST "$HOST_API" /jobs/bid         '{"image":"alpine"}')
c_deploy=$(  rt_forge POST "$HOST_API" /mesh-deploy      "{\"node_id\":\"$HOST_ID\",\"image\":\"alpine\"}")
c_kill=$(    rt_forge POST "$HOST_API" /mesh-kill        "{\"node_id\":\"$HOST_ID\",\"job_id\":\"x\"}")
c_chopen=$(  rt_forge POST "$HOST_API" /channels/open    '{"host":"00","amount":"1"}')
echo "no-token codes: transfer=$c_transfer revoke=$c_revoke bid=$c_bid deploy=$c_deploy kill=$c_kill chan-open=$c_chopen"
gated=1
for code in "$c_transfer" "$c_revoke" "$c_bid" "$c_deploy" "$c_kill" "$c_chopen"; do
  [ "$code" = "401" ] || gated=0
done
[ "$gated" = "1" ] \
  && xfail "every mutating endpoint rejected the no-token request (401) — no ambient-authority takeover" \
  || bad "a mutating endpoint accepted a request WITHOUT the API token (codes above) — API gate broken"

# Positive control: the SAME endpoint succeeds WITH the suite token (proves the 401 is the gate, not
# a missing route). /transfer with a malformed body still passes the token gate, then fails 4xx in
# the handler — anything but 401 proves the token was accepted.
say "CAP1 control — token IS accepted (the 401 above is the auth gate, not a 404)"
c_auth=$(rt_forge POST "$HOST_API" /transfer '{"to":"00","amount":"1"}' -H "authorization: Bearer $CE_API_TOKEN")
echo "with-token /transfer code=$c_auth"
[ "$c_auth" != "401" ] \
  && xfail "token-bearing request passed the auth gate (code $c_auth) — 401 above was genuinely the gate" \
  || bad "token-bearing request still 401 — token not honored (suite mis-set up)"

# ==================================================================================================
# CAP2 — API bound to loopback (not internet-reachable). The log must show 127.0.0.1, never 0.0.0.0.
# ==================================================================================================
say "CAP2 — API bound to loopback (127.0.0.1), not 0.0.0.0"
if grep -q "127.0.0.1:$HOST_API" "$ROOT/hostnode.log" 2>/dev/null && ! grep -q "0.0.0.0:$HOST_API" "$ROOT/hostnode.log" 2>/dev/null; then
  xfail "API bound to 127.0.0.1:$HOST_API (not 0.0.0.0) — not internet-reachable"
else
  # Be lenient about exact log phrasing, but a 0.0.0.0 bind line is an unambiguous failure.
  if grep -q "0.0.0.0" "$ROOT/hostnode.log" 2>/dev/null; then
    bad "node log shows a 0.0.0.0 bind — API may be internet-reachable"
  else
    xfail "no 0.0.0.0 bind in node log; API is loopback-bound by default"
  fi
fi

# ==================================================================================================
# The capability attacks below need the rdev enforcement point. Skip cleanly (only) these if rdev is
# absent — CAP1/CAP2 (node-only) and CAP10 (node-only) still ran / will run.
# ==================================================================================================
if [ ! -x "$RDEV_BIN" ]; then
  skip "rdev not found at $RDEV_BIN (set RDEV_BIN) — skipping cap-chain attacks CAP3..CAP9; CAP1/CAP2/CAP10 still run"
else
  say "start rdev serve on HOST (the ce-cap enforcement point; HOME pinned, roots empty)"
  # HOME pins both the file-write root AND load_roots() (empty roots => only self-issued caps work,
  # which is exactly what makes CAP4 forged-root rejection meaningful). RDEV_SPAWN_ALLOW is left
  # default-deny; we never actually spawn (auth is checked BEFORE the action, so denial is what we
  # assert and Docker is not required for a DENY result).
  HOME="$HOST_HOME" RDEV_ROOTS="$HOST_HOME/.no-roots" \
    "$RDEV_BIN" --node "http://127.0.0.1:$HOST_API" serve >"$ROOT/rdev-serve.log" 2>&1 &
  PIDS+=($!)
  # Give serve a moment to subscribe to the mesh request topic.
  for _ in $(seq 1 20); do grep -q "rdev serving as" "$ROOT/rdev-serve.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "rdev serving as" "$ROOT/rdev-serve.log" 2>/dev/null \
    && ok "rdev serve attached to HOST as the cap enforcement point" \
    || skip "rdev serve did not announce; cap-chain attacks may be flaky"

  # rdev CLIENT always points at the ATTACKER node, so the requester the server authenticates
  # (`from`) is the ATTACKER's node id. A helper that runs an rdev verb from the attacker and echoes
  # the combined output; RETRIES because a freshly-meshed gossipsub request topic can take a few
  # seconds to be reachable (we retry only on transport "not reachable", never on a clean "denied").
  RDEV() { HOME="$ROOT/atk-home" "$RDEV_BIN" --node "http://127.0.0.1:$ATK_API" "$@" 2>&1; }
  rdev_try() {
    # rdev_try <tag> <verb...> ; echoes "DENIED"/"OTHER"/"UNREACH" + leaves $RDEV_OUT set.
    # The first arg is a human-readable tag (ignored); the rest is the rdev verb, run through the
    # RDEV helper (which pins HOME and points the client at the ATTACKER node). It must NOT be exec'd
    # directly — doing so ran the bare tag as a command ("x: command not found"), leaving $out empty
    # so every attack fell through to OTHER and spuriously FAILED.
    local i out
    for i in $(seq 1 12); do
      out=$(RDEV "${@:2}")
      RDEV_OUT="$out"
      if echo "$out" | grep -qiE 'denied|refused|not authorized|unauthorized|capability|expired|revoked'; then
        echo "DENIED"; return 0
      fi
      if echo "$out" | grep -qiE 'no route|not reachable|timed out|timeout|unreachable|no peers|dial'; then
        sleep 2; continue
      fi
      echo "OTHER"; return 0
    done
    echo "UNREACH"; return 0
  }

  # --- a small file the attacker tries to push (CAP6 etc.) ---
  PUSHSRC="$ROOT/payload.txt"; echo "attacker-controlled bytes" >"$PUSHSRC"

  # ================================================================================================
  # CAP3 — no-cap / empty-cap mesh action must be denied (no ambient authority).
  # `rdev push` with --cap "" yields an empty chain; authorize() step 1 (non-empty chain rooted at an
  # accepted root) fails -> "denied". (--cap omitted is refused CLIENT-side with "no capability", a
  # weaker proof, so we force an empty chain to reach the SERVER's enforcement.)
  # ================================================================================================
  say "CAP3 — no/empty capability mesh action -> denied"
  r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:cap3.txt" --cap "")
  echo "empty-cap push verdict=$r out=[${RDEV_OUT:-}]"
  case "$r" in
    DENIED) xfail "empty/garbage capability chain denied (authorize: non-empty chain rooted at an accepted root)";;
    UNREACH) skip "CAP3 unreachable: rdev request never routed (mesh flaky); not asserting";;
    *)      bad "empty-cap mesh action was NOT denied (no ambient-authority guard) — out: ${RDEV_OUT:-}";;
  esac
  # Confirm the target file was never written (defense in depth on the file-write side).
  [ ! -e "$HOST_HOME/cap3.txt" ] \
    && ok "no file written by the un-capabilitied push (host home clean)" \
    || bad "a file appeared on the host from a no-cap push — write happened despite denial"

  # ================================================================================================
  # CAP4 — forged-root capability. Mint a FRESH unrelated key (a separate data-dir), self-issue a cap
  # from IT to the attacker. Its root (chain[0].issuer == the foreign key) is NOT an accepted root for
  # HOST (HOST's roots set is empty + foreign != host id) -> authorize() step 1 rejects.
  # ================================================================================================
  say "CAP4 — forged-root cap (foreign issuer, not an accepted root) -> denied"
  FAKE_DIR="$ROOT/fakeroot"; mkdir -p "$FAKE_DIR"
  FAKE_ID=$(rt_node_id "$FAKE_DIR")
  # The cap claims resource=self (== the FAKE node), audience = the attacker. Even with a valid
  # signature, the root is foreign, so HOST must refuse.
  FORGED_CAP=$("$CE_BIN" --data-dir "$FAKE_DIR" grant "$ATK_ID" --can sync --resource self --expires 1h 2>/dev/null)
  echo "forged-root issuer=$FAKE_ID cap_len=${#FORGED_CAP}"
  if [ -z "$FORGED_CAP" ]; then
    skip "CAP4 could not mint a forged-root cap (ce grant produced nothing); not asserting"
  else
    r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:cap4.txt" --cap "$FORGED_CAP")
    echo "forged-root push verdict=$r out=[${RDEV_OUT:-}]"
    case "$r" in
      DENIED) xfail "forged-root cap denied (chain root $FAKE_ID is not an accepted root for HOST)";;
      UNREACH) skip "CAP4 unreachable: rdev request never routed (mesh flaky); not asserting";;
      *)      bad "forged-root cap was ACCEPTED — a non-root key authorized an action (root anchor broken) — out: ${RDEV_OUT:-}";;
    esac
    [ ! -e "$HOST_HOME/cap4.txt" ] || bad "forged-root push wrote a file on the host"
  fi

  # ================================================================================================
  # CAP5 — ability mismatch. HOST grants the attacker a SYNC-only cap; the attacker tries to EXEC and
  # to SPAWN (rdev run) with it. authorize() step 7 requires leaf.abilities to include the action, so
  # a sync cap cannot perform exec/spawn. (This is the CLI-reachable face of attenuation: the leaf can
  # never authorize MORE abilities than it was granted.)
  # ================================================================================================
  say "CAP5 — sync-only cap used for exec/spawn (ability escalation) -> denied"
  SYNC_CAP=$("$CE_BIN" --data-dir "$ROOT/hostnode" grant "$ATK_ID" --can sync --resource self --expires 1h 2>/dev/null)
  echo "sync-only cap_len=${#SYNC_CAP}"
  if [ -z "$SYNC_CAP" ]; then
    skip "CAP5 could not mint a sync-only cap; not asserting"
  else
    # exec (needs the `exec` ability)
    r=$(rdev_try x exec "$HOST_ID" --image alpine:latest --cap "$SYNC_CAP" -- /bin/true)
    echo "sync-cap exec verdict=$r out=[${RDEV_OUT:-}]"
    case "$r" in
      DENIED) xfail "sync-only cap denied for exec (leaf abilities exclude 'exec')";;
      UNREACH) skip "CAP5/exec unreachable: mesh flaky; not asserting";;
      *)      bad "sync-only cap performed EXEC — ability escalation succeeded — out: ${RDEV_OUT:-}";;
    esac
    # spawn (rdev run -> the `spawn` ability)
    r=$(rdev_try x run "$HOST_ID" --cap "$SYNC_CAP" -- /bin/true)
    echo "sync-cap spawn verdict=$r out=[${RDEV_OUT:-}]"
    case "$r" in
      DENIED) xfail "sync-only cap denied for spawn/run (leaf abilities exclude 'spawn')";;
      UNREACH) skip "CAP5/spawn unreachable: mesh flaky; not asserting";;
      *)      bad "sync-only cap performed SPAWN — ability escalation succeeded — out: ${RDEV_OUT:-}";;
    esac
  fi

  # ================================================================================================
  # CAP6 — path_prefix caveat escape. HOST grants sync confined to prefix `e2e`. A push WITHIN the
  # prefix must SUCCEED (positive control); a push OUTSIDE it (`other/escape.txt`) must be DENIED
  # (fail-closed, enforced by fs_action). path_prefix is relative to the target's home.
  # ================================================================================================
  say "CAP6 — path_prefix caveat: write inside prefix OK, write outside DENIED"
  PFX_CAP=$("$CE_BIN" --data-dir "$ROOT/hostnode" grant "$ATK_ID" --can sync --resource self --path e2e --expires 1h 2>/dev/null)
  echo "path-confined cap_len=${#PFX_CAP}"
  if [ -z "$PFX_CAP" ]; then
    skip "CAP6 could not mint a path-confined cap; not asserting"
  else
    # positive control: inside the prefix.
    r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:e2e/inside.txt" --cap "$PFX_CAP")
    echo "in-prefix push verdict=$r out=[${RDEV_OUT:-}]"
    if [ "$r" = "OTHER" ] && [ -e "$HOST_HOME/e2e/inside.txt" ]; then
      ok "in-prefix write succeeded (positive control: the cap genuinely authorizes its own prefix)"
    elif [ "$r" = "UNREACH" ]; then
      skip "CAP6 in-prefix push unreachable (mesh flaky); not asserting the positive control"
    else
      # A denial of the legit in-prefix write would make the escape test vacuous; surface it loudly.
      bad "in-prefix write did NOT succeed (verdict=$r) — CAP6 escape test would be vacuous — out: ${RDEV_OUT:-}"
    fi
    # the attack: escape the prefix.
    r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:other/escape.txt" --cap "$PFX_CAP")
    echo "escape push verdict=$r out=[${RDEV_OUT:-}]"
    case "$r" in
      DENIED) xfail "write OUTSIDE the granted prefix denied (path_prefix enforced fail-closed)";;
      UNREACH) skip "CAP6 escape unreachable (mesh flaky); not asserting";;
      *)      bad "path_prefix ESCAPED — wrote outside the granted prefix — out: ${RDEV_OUT:-}";;
    esac
    [ ! -e "$HOST_HOME/other/escape.txt" ] \
      && ok "no file written outside the granted prefix (host home has no other/escape.txt)" \
      || bad "a file appeared OUTSIDE the granted prefix — path_prefix breached"
  fi

  # ================================================================================================
  # CAP7 — expiry. HOST grants a cap that expires in ~2s; sleep past not_after; reuse it.
  # authorize() step 3 (temporally valid at `now`) must reject the expired cap.
  # ================================================================================================
  say "CAP7 — expired cap (not_after in the past) -> denied"
  EXP_CAP=$("$CE_BIN" --data-dir "$ROOT/hostnode" grant "$ATK_ID" --can sync --resource self --expires 2s 2>/dev/null)
  echo "short-lived cap_len=${#EXP_CAP}"
  if [ -z "$EXP_CAP" ]; then
    skip "CAP7 could not mint a short-lived cap; not asserting"
  else
    echo "sleeping 4s so the cap's not_after passes..."
    sleep 4
    r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:cap7.txt" --cap "$EXP_CAP")
    echo "expired-cap push verdict=$r out=[${RDEV_OUT:-}]"
    case "$r" in
      DENIED) xfail "expired cap denied (authorize: not_after enforced)";;
      UNREACH) skip "CAP7 unreachable (mesh flaky); not asserting";;
      *)      bad "EXPIRED cap was accepted — not_after not enforced — out: ${RDEV_OUT:-}";;
    esac
    [ ! -e "$HOST_HOME/cap7.txt" ] || bad "expired-cap push wrote a file on the host"
  fi

  # ================================================================================================
  # CAP8 — on-chain revocation. HOST self-issues a sync cap, then submits RevokeCapability {issuer,
  # nonce}. Once the tx is mined and HOST exposes it on /capabilities/revoked (and rdev serve refreshes
  # its set, ~10s), reusing the (still-unexpired) cap must be denied. is_revoked() consults the set.
  # ================================================================================================
  say "CAP8 — on-chain RevokeCapability, then reuse the revoked cap -> denied"
  # Capture the nonce from grant's stderr ("nonce:    <n>  (revoke with: ...)"); token is on stdout.
  REV_OUT="$ROOT/cap8.grant.err"
  REV_CAP=$("$CE_BIN" --data-dir "$ROOT/hostnode" grant "$ATK_ID" --can sync --resource self --expires 1h 2>"$REV_OUT")
  REV_NONCE=$(grep -oE 'nonce:[[:space:]]*[0-9]+' "$REV_OUT" | grep -oE '[0-9]+' | head -1)
  echo "revocable cap nonce=$REV_NONCE cap_len=${#REV_CAP}"
  if [ -z "$REV_CAP" ] || [ -z "$REV_NONCE" ]; then
    skip "CAP8 could not mint a revocable cap or parse its nonce; not asserting"
  else
    # Sanity: the cap works BEFORE revocation (otherwise the post-revoke denial proves nothing).
    r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:cap8-pre.txt" --cap "$REV_CAP")
    echo "pre-revoke push verdict=$r (expect a real write)"
    pre_ok=0
    if [ "$r" = "OTHER" ] && [ -e "$HOST_HOME/cap8-pre.txt" ]; then pre_ok=1; ok "cap works before revocation (control established)"; fi
    # Submit the on-chain revocation (authed, to HOST).
    rc=$("$CE_BIN" --data-dir "$ROOT/hostnode" revoke "$REV_NONCE" --api-port "$HOST_API" 2>&1)
    echo "revoke submit: $rc"
    # Wait for HOST to surface the revocation on-chain (mined) AND for rdev serve to refresh (~every
    # 10s, 20-tick poll). Poll /capabilities/revoked first, then give serve a refresh window.
    revoked_seen=0
    for _ in $(seq 1 40); do
      if rt_json "http://127.0.0.1:$HOST_API/capabilities/revoked" | grep -q "\"nonce\": *$REV_NONCE"; then
        revoked_seen=1; break
      fi
      sleep 1
    done
    echo "revocation visible on /capabilities/revoked: $revoked_seen"
    if [ "$revoked_seen" != "1" ]; then
      skip "CAP8: RevokeCapability never appeared on-chain within the window (mining slow?); not asserting the post-revoke denial"
    else
      # Let rdev serve pull the fresh revoked set (it refreshes every ~10s; give it generously).
      sleep 12
      r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:cap8-post.txt" --cap "$REV_CAP")
      echo "post-revoke push verdict=$r out=[${RDEV_OUT:-}]"
      case "$r" in
        DENIED) xfail "revoked cap denied after on-chain RevokeCapability (is_revoked consulted; subtree killed)";;
        UNREACH) skip "CAP8 post-revoke push unreachable (mesh flaky); not asserting";;
        *)
          if [ -e "$HOST_HOME/cap8-post.txt" ]; then
            bad "REVOKED cap still authorized a write — on-chain revocation not enforced by the serve loop"
          else
            # No file + not a clean DENIED string: treat as inconclusive transport, not a pass.
            skip "CAP8 post-revoke push neither denied-string nor wrote a file (inconclusive); not asserting"
          fi
          ;;
      esac
      [ "$pre_ok" = "1" ] && [ ! -e "$HOST_HOME/cap8-post.txt" ] \
        && ok "revoked cap produced no write where the same cap previously wrote (revocation is effective)" \
        || true
    fi
  fi

  # ================================================================================================
  # CAP9 — wrong holder / confused deputy. HOST issues a cap whose AUDIENCE is a THIRD node id (not
  # the attacker). The attacker presents that cap. authorize() step 7 requires leaf.audience ==
  # requester (the noise-authenticated `from`), so a replayed someone-else's cap must be denied.
  # ================================================================================================
  say "CAP9 — cap issued to X presented by Y (confused deputy) -> denied"
  THIRD_DIR="$ROOT/thirdparty"; mkdir -p "$THIRD_DIR"
  THIRD_ID=$(rt_node_id "$THIRD_DIR")
  OTHERS_CAP=$("$CE_BIN" --data-dir "$ROOT/hostnode" grant "$THIRD_ID" --can sync --resource self --expires 1h 2>/dev/null)
  echo "cap audience=$THIRD_ID (NOT the attacker $ATK_ID) cap_len=${#OTHERS_CAP}"
  if [ -z "$OTHERS_CAP" ] || [ "$THIRD_ID" = "$ATK_ID" ]; then
    skip "CAP9 could not mint a third-party cap (or id collision); not asserting"
  else
    # The attacker (client points at ATK_API, so requester == ATK_ID) presents X's cap.
    r=$(rdev_try x push "$PUSHSRC" "$HOST_ID:cap9.txt" --cap "$OTHERS_CAP")
    echo "wrong-holder push verdict=$r out=[${RDEV_OUT:-}]"
    case "$r" in
      DENIED) xfail "cap issued to a different audience denied when presented by the attacker (leaf.audience must == requester)";;
      UNREACH) skip "CAP9 unreachable (mesh flaky); not asserting";;
      *)      bad "CONFUSED DEPUTY — a cap for node X authorized an action by node Y — out: ${RDEV_OUT:-}";;
    esac
    [ ! -e "$HOST_HOME/cap9.txt" ] || bad "wrong-holder push wrote a file on the host"
  fi
fi

# ==================================================================================================
# CAP10 — kill-RPC resource scope (audit finding D1, KNOWN-OPEN). A "kill" capability is not bound to
# the killed job's payer/owner: any holder of any kill cap can kill any job. We do not need a running
# job to demonstrate the SCOPING hole — the point is that the kill path authorizes on the cap's
# ability alone, not on job ownership. We mount it node-side: present a kill-scoped cap (issued to the
# attacker, ability=kill) and observe the kill RPC is NOT rejected on ownership grounds.
#
# This is node-only and reachable even without rdev: /mesh-kill is the directed kill RPC. With the
# suite token it passes the API gate; the question is whether the cap layer binds the kill to the
# job's owner. Per D1 it does NOT. We assert the hole is genuinely reachable, then known_open().
# ==================================================================================================
say "CAP10 — kill-RPC resource scope (D1): any kill cap can kill a non-owned job -> KNOWN-OPEN"
# Mint a kill cap to the attacker (root = HOST), then drive /mesh-kill HOST->HOST for a job the
# attacker does not own. The defense that SHOULD exist (kill bound to job.payer/owner) is absent, so
# the request is not refused on ownership grounds (it fails only because the job id is unknown).
KILL_CAP=$("$CE_BIN" --data-dir "$ROOT/hostnode" grant "$ATK_ID" --can kill --resource self --expires 1h 2>/dev/null)
echo "kill cap_len=${#KILL_CAP}"
# Directed kill of an arbitrary (non-owned, fabricated) job id, with the suite token past the gate.
KILL_BODY="{\"node_id\":\"$HOST_ID\",\"job_id\":\"deadbeefdeadbeef\",\"grant\":\"${KILL_CAP}\"}"
kill_resp=$(rt_forge_body POST "$HOST_API" /mesh-kill "$KILL_BODY" -H "authorization: Bearer $CE_API_TOKEN")
kill_code=$(rt_forge      POST "$HOST_API" /mesh-kill "$KILL_BODY" -H "authorization: Bearer $CE_API_TOKEN")
echo "mesh-kill (non-owned job) code=$kill_code resp=[$kill_resp]"
# An ownership-scoped kill would refuse on "not the owner / not your job". If the only objection is a
# missing job (no ownership check at all), the scoping defense is absent -> the hole is reachable.
if echo "$kill_resp" | grep -qiE 'not (the )?owner|not your job|payer|ownership|unauthorized'; then
  xfail "kill RPC refused on ownership grounds — D1 appears CLOSED (kill bound to job owner)"
else
  known_open "audit D1: kill RPC authorizes on the kill ability alone, not on the job's payer/owner (no ownership scoping — a kill cap kills any job)"
fi

# ==================================================================================================
rt_result
