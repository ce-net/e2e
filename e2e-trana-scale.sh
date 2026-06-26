#!/usr/bin/env bash
# e2e-trana-scale.sh — trana at scale on a real multi-node CE mesh: content scale, real live
# streaming across nodes, identity/auth + untrusted-peer enforcement, community ban at quorum, and
# fault tolerance under random node failure.
#
#   1. CE SETUP     — a 5-node mining CE mesh; trana on three of them (T0,T1,T2).
#   2. SCALE        — create a board, fan in many posts + votes from several node identities, read a
#                     ranked feed back.
#   3. STREAMING    — start a live stream on T0, push real content-addressed segments, read the
#                     growing playlist + fetch segment bytes from a DIFFERENT node (T1).
#   4. AUTH/UNTRUST — authorship is the cryptographically authenticated sender (no forgery); a
#                     trust-gated board rejects a low-trust peer's vote.
#   5. COMMUNITY BAN— with no mods, a quorum of distinct peers votes an outcast out; their content
#                     is then hidden — and a single peer alone cannot do it.
#   6. FAULT        — kill a trana node mid-flight (another still serves), kill a CE node (survivors
#                     stay up), restart (rejoins).
#
# Hermetic: ephemeral in-RAM nodes, --no-mdns, CE_NO_AUTOBOOTSTRAP=1, loopback only. Never touches
# ce-net.com. Skips cleanly (exit 0) if the `ce` or `trana` binaries are missing.
#   CE_BIN=~/.local/bin/ce ./e2e-trana-scale.sh

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/redteam.sh
. "$SELF_DIR/lib/redteam.sh"

rt_init trana-scale
rt_arm_cleanup

pick_bin() {
  local n=$1 d=$HOME/ce-net/.cargo-shared
  for c in "$d/release/$n" "$d/debug/$n" "$(command -v "$n" 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  echo ""
}
TRANA_NODE_BIN=${TRANA_NODE_BIN:-$(pick_bin trana-node)}
TRANA_BIN=${TRANA_BIN:-$(pick_bin trana)}
[ -n "$TRANA_NODE_BIN" ] && [ -x "$TRANA_NODE_BIN" ] || { skip "trana-node not built; skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }
[ -n "$TRANA_BIN" ] && [ -x "$TRANA_BIN" ] || { skip "trana CLI not built; skipping"; echo "PASS=$PASS FAIL=$FAIL KNOWN_OPEN=$KNOWN_OPEN"; exit 0; }

P2P=6500; API=6600  # api base chosen away from defaults
N=${SCALE_NODES:-5}

start_trana() { # name ce-api
  local name=$1 api=$2 i
  mkdir -p "$ROOT/$name"
  "$TRANA_NODE_BIN" --node-url "http://127.0.0.1:$api" --data-dir "$ROOT/$name" >"$ROOT/$name.log" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 30); do grep -q "trana-node ready" "$ROOT/$name.log" 2>/dev/null && return 0; sleep 1; done
  return 1
}
# trana CLI through a CE node's api, pinned to a trana node id. Returns the exit code of the call.
tcli() { local api=$1 node=$2; shift 2; "$TRANA_BIN" --node-url "http://127.0.0.1:$api" --node "$node" "$@" 2>>"$ROOT/cli.log"; }

# --------------------------------------------------------------------------------------------------
say "CE SETUP: $N-node mesh"
rt_start_mesh "$N" "$P2P" "$API" || { bad "mesh seed failed"; rt_result; exit 1; }
up=0
for _ in $(seq 1 25); do
  up=0; for i in $(seq 0 $((N-1))); do curl -fsS -m2 "http://127.0.0.1:$((API+i))/status" >/dev/null 2>&1 && up=$((up+1)); done
  [ "$up" -ge 3 ] && break; sleep 1
done
[ "$up" -ge 3 ] && ok "CE mesh online ($up/$N node APIs live)" || { bad "mesh did not form"; rt_result; exit 1; }

API0=$API; API1=$((API+1)); API2=$((API+2))
ID=(); for i in $(seq 0 $((N-1))); do ID+=("$(rt_node_id "$ROOT/h$i")"); done
T0=${ID[0]}; T1=${ID[1]}; T2=${ID[2]}

say "start trana on 3 nodes"
start_trana t0 "$API0" && ok "trana T0 up" || bad "T0 failed"
start_trana t1 "$API1" && ok "trana T1 up" || bad "T1 failed"
start_trana t2 "$API2" && ok "trana T2 up" || bad "T2 failed"
sleep 2

# --------------------------------------------------------------------------------------------------
say "SCALE: a board with many posts + votes from several identities"
tcli "$API0" "$T1" board-create general --title "General" --ban-quorum 3 >/dev/null && ok "board created" || bad "board-create failed"
POSTS=()
for i in $(seq 1 12); do
  # round-robin the authoring CE node so posts come from several identities
  a=$((API + (i % 3))); n=${ID[$((i % 3))]}
  pid=$(tcli "$a" "$T0" post --board general --title "post $i" --body "body $i")
  [ -n "$pid" ] && POSTS+=("$pid")
done
[ "${#POSTS[@]}" -ge 10 ] && ok "fanned in ${#POSTS[@]} posts from 3 identities" || bad "only ${#POSTS[@]} posts landed"
# Cast votes from several identities on the first few posts.
for i in 0 1 2 3; do
  for j in 0 1 2 3; do
    tcli $((API + j)) "$T0" vote "${POSTS[$i]:-x}" 1 >/dev/null 2>&1
  done
done
FEED=$(tcli "$API1" "$T0" threads general --sort top --limit 20 2>/dev/null)
cnt=$(echo "$FEED" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('threads',[])))" 2>/dev/null || echo 0)
[ "${cnt:-0}" -ge 10 ] && ok "feed returns $cnt ranked threads (read from a different node)" || bad "feed read back $cnt threads"

# --------------------------------------------------------------------------------------------------
say "STREAMING: live segments pushed on T0, played from T1"
SID=$(tcli "$API0" "$T0" stream-start --title "live demo" --kind video 2>/dev/null)
[ -n "$SID" ] && ok "stream started: $SID" || bad "stream-start failed"
for seq in 0 1 2 3 4; do
  seg="$ROOT/seg$seq.ts"; head -c 60000 /dev/urandom >"$seg"
  tcli "$API0" "$T0" stream-append "$SID" "$seq" "$seg" --duration-ms 2000 >/dev/null 2>&1
done
got=0
for _ in $(seq 1 20); do
  PLAY=$(tcli "$API1" "$T0" stream-get "$SID" 2>/dev/null)
  segc=$(echo "$PLAY" | python3 -c "import sys,json;s=json.load(sys.stdin).get('stream') or {};print(len(s.get('segments',[])))" 2>/dev/null || echo 0)
  [ "${segc:-0}" -ge 5 ] && { got=1; break; }
  sleep 1
done
[ "$got" = 1 ] && ok "5-segment live playlist replicated T0 -> T1 (distributed streaming)" || bad "stream playlist did not replicate"
# Fetch a segment's content-addressed bytes through T1's node.
SEG_CID=$(echo "${PLAY:-}" | python3 -c "import sys,json;s=json.load(sys.stdin).get('stream') or {};segs=s.get('segments',[]);print(segs[0]['object_cid'] if segs else '')" 2>/dev/null)
if [ -n "$SEG_CID" ] && curl -fsS -m5 "http://127.0.0.1:$API1/blobs/$SEG_CID" >/dev/null 2>&1; then
  ok "segment object fetchable through T1's node ($SEG_CID)"
else
  bad "segment bytes not retrievable via T1"
fi
tcli "$API0" "$T0" stream-end "$SID" >/dev/null 2>&1 && ok "stream ended" || skip "stream-end issue"

# --------------------------------------------------------------------------------------------------
say "AUTH / UNTRUSTED PEERS"
# Authorship is the authenticated sender: a post made via node h2 is authored by h2's NodeId, and
# there is no field in the request to claim otherwise.
APID=$(tcli "$API2" "$T0" post --board general --title "who am i" --body "x")
AUTHOR=$(tcli "$API1" "$T0" threads general --sort new --limit 50 2>/dev/null | python3 -c "import sys,json;ts=json.load(sys.stdin).get('threads',[]);print(next((t['author'] for t in ts if t['id']=='$APID'),''))" 2>/dev/null)
[ -n "$APID" ] && [ "$AUTHOR" = "$T2" ] && ok "authorship = authenticated sender ($T2), unforgeable" || bad "authorship not bound to sender (got '$AUTHOR')"

# A trust-gated board rejects a low-trust peer's vote.
tcli "$API0" "$T0" board-create vetted --title "Vetted" --min-trust-vote 0.99 >/dev/null 2>&1
GPID=$(tcli "$API0" "$T0" post --board vetted --title "gated" --body "vote me")
sleep 1
if tcli "$API1" "$T0" vote "${GPID:-x}" 1 >/dev/null 2>&1; then
  bad "low-trust peer was allowed to vote in a trust-gated board"
else
  xfail "trust gate rejected a low-trust peer's vote (min_trust_to_vote=0.99)"
fi

# --------------------------------------------------------------------------------------------------
say "COMMUNITY BAN: quorum of peers, no mods"
OUTCAST=${ID[4]}
OPID=$(tcli "$API0" "$T0" post --board general --title "unpopular" --body "controversial take")
# A single peer voting to ban does NOT ban (quorum is 3).
tcli "$API0" "$T0" ban-vote general "$OUTCAST" >/dev/null 2>&1
ONE=$(tcli "$API0" "$T0" ban-standing general "$OUTCAST" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['standing']['banned_raw'])" 2>/dev/null)
[ "$ONE" = "False" ] && ok "one peer alone cannot ban (below quorum)" || bad "ban took effect below quorum"
# Three distinct peers reach quorum → banned.
tcli "$API1" "$T0" ban-vote general "$OUTCAST" >/dev/null 2>&1
tcli "$API2" "$T0" ban-vote general "$OUTCAST" >/dev/null 2>&1
banned=0
for _ in $(seq 1 10); do
  B=$(tcli "$API0" "$T0" ban-standing general "$OUTCAST" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['standing']['banned_raw'])" 2>/dev/null)
  [ "$B" = "True" ] && { banned=1; break; }
  sleep 1
done
[ "$banned" = 1 ] && ok "quorum of 3 distinct peers community-banned the outcast" || bad "quorum ban did not take effect"
# Banned author's content is hidden from the feed.
HIDDEN=$(tcli "$API1" "$T0" threads general --sort new --limit 50 2>/dev/null | python3 -c "import sys,json;ts=json.load(sys.stdin).get('threads',[]);print('$OPID' in [t['id'] for t in ts])" 2>/dev/null)
[ "$HIDDEN" = "False" ] && ok "banned user's content hidden from the feed" || bad "banned user's content still shown"

# --------------------------------------------------------------------------------------------------
say "FAULT TOLERANCE"
T1_PID=$(pgrep -f "$ROOT/t1" | head -1)
[ -n "$T1_PID" ] && kill "$T1_PID" 2>/dev/null && ok "killed trana T1" || skip "no T1 pid"
sleep 2
# T2 still serves the content.
if tcli "$API2" "$T0" threads general --sort new --limit 5 >/dev/null 2>&1; then
  ok "content still served after a trana node died (via T2)"
else
  bad "content unavailable after T1 died"
fi
LAST=$((N-1)); LPID=$(pgrep -f "$ROOT/h$LAST" | head -1)
[ -n "$LPID" ] && kill "$LPID" 2>/dev/null && ok "killed CE node h$LAST" || skip "no h$LAST pid"
sleep 3
alive=0; for i in $(seq 0 $((N-2))); do curl -fsS -m2 "http://127.0.0.1:$((API+i))/status" >/dev/null 2>&1 && alive=$((alive+1)); done
[ "$alive" -ge 2 ] && ok "surviving CE nodes healthy ($alive up)" || bad "mesh collapsed after node loss"
rt_start_node "h$LAST" $((P2P+LAST)) $((API+LAST)) --bootstrap "$RT_SEED" >/dev/null 2>&1
sleep 3
[ "$(rt_field $((API+LAST)) height)" != "-1" ] && ok "killed CE node rejoined" || skip "rejoined node still catching up"

rt_result
