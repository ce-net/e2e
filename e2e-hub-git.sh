#!/usr/bin/env bash
# E2E for the hub.ce-net.com git layer (web/ce-hub).
#
# Drives a LOCALLY running ce-hub binary against a throwaway CE_HUB_DATA dir and a real
# `git` client. It exercises the whole git lifecycle the contract (PLAN/hub-git-contract.md)
# specifies: create a repo via the signed JSON API, clone the empty repo over smart-HTTP,
# commit, push (authorized by a short-lived signed capability over HTTP Basic), read the tree
# /commit back through the gix read API, open + merge a PR via the API, and confirm the
# instances view responds.
#
# Self-contained: it builds an Ed25519 keypair and signs every mutating request in pure Node
# (the canonical string ce-hub verifies is in web/ce-hub/src/main.rs:
#   METHOD"\n"+PATH"\n"+ts"\n"+nonce"\n"+sha256(body)-hex
# signed with the node key; x-ce-id = pubkey hex; owner id = sha256(pubkey)[..16] hex).
#
# Skips gracefully (prints SKIP + the build command) when the hub binary, git, or node are
# absent, so it stays green on a partial checkout. Mirrors the style of the other e2e-*.sh.
#
# Usage:
#   bash e2e/e2e-hub-git.sh
# Overrides:
#   CE_HUB_BIN   path to the ce-hub binary (default: web/ce-hub/target/release/ce-hub)
#   CE_HUB_PORT  port the hub binds (default: an ephemeral high port)
#   NODE_BIN     node binary (default: node)
set -euo pipefail
export CE_NO_AUTOBOOTSTRAP=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_SRC="$(cd "$HERE/../web/ce-hub" 2>/dev/null && pwd || true)"
CE_HUB_BIN="${CE_HUB_BIN:-$HUB_SRC/target/release/ce-hub}"
NODE="${NODE_BIN:-node}"
PORT="${CE_HUB_PORT:-$(( (RANDOM % 2000) + 18970 ))}"
BASE="http://127.0.0.1:$PORT"

OWNER="alice"
REPO="spacegame"

PASS=0; FAIL=0
HUB_PID=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ce-hub-git.XXXXXX")"

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; }
cleanup() {
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null || true
  [ -n "${CE_HUB_KEEP_LOG:-}" ] && cp "$TMP/hub.log" "$CE_HUB_KEEP_LOG" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# --- preflight: skip (not fail) when prerequisites are missing --------------------------
if ! command -v "$NODE" >/dev/null 2>&1; then
  skip "node not found (needed to sign requests). Install Node, then re-run."
  echo "PASS=0  FAIL=0"; exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  skip "git not found (needed for clone/push). Install git, then re-run."
  echo "PASS=0  FAIL=0"; exit 0
fi
if [ ! -x "$CE_HUB_BIN" ]; then
  skip "ce-hub binary not built at $CE_HUB_BIN"
  echo "      build it on the relay:   bash web/deploy/ce-build.sh hub"
  echo "      or locally (disk permitting):   (cd web/ce-hub && cargo build --release)"
  echo "PASS=0  FAIL=0"; exit 0
fi

# --- key material + a tiny signer/credential-helper in node -----------------------------
# We generate one Ed25519 identity. The same key:
#   - signs the JSON API writes (x-ce-id / x-ce-sig / x-ce-ts / x-ce-nonce headers), and
#   - mints the short-lived git push capability token used as the HTTP Basic password.
mkdir -p "$TMP/keys"
"$NODE" - "$TMP/keys" <<'NODE_KEYGEN'
const crypto = require('crypto');
const fs = require('fs');
const dir = process.argv[2];
// Ed25519 keypair; export raw 32-byte public key (the format x-ce-id expects: pubkey hex).
const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const spki = publicKey.export({ type: 'spki', format: 'der' });
const rawPub = spki.subarray(spki.length - 32);     // last 32 bytes of SPKI = raw key
const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' });
fs.writeFileSync(dir + '/pub.hex', rawPub.toString('hex'));
fs.writeFileSync(dir + '/priv.der', pkcs8);
const owner = crypto.createHash('sha256').update(rawPub).digest('hex').slice(0, 32);
fs.writeFileSync(dir + '/owner.hex', owner);
console.log('owner=' + owner);
NODE_KEYGEN

PUBHEX="$(cat "$TMP/keys/pub.hex")"
OWNER_ID="$(cat "$TMP/keys/owner.hex")"

# signed_curl METHOD PATH [JSON_BODY] — emits the canonical-string signature headers and
# performs the request, printing "<http_code>\n<body>".
signed_curl() {
  local method="$1" path="$2" body="${3:-}"
  local hdrs
  hdrs="$("$NODE" - "$TMP/keys" "$method" "$path" "$body" <<'NODE_SIGN'
const crypto = require('crypto');
const fs = require('fs');
const [dir, method, path, body] = process.argv.slice(2);
const pkcs8 = fs.readFileSync(dir + '/priv.der');
const key = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
const pub = fs.readFileSync(dir + '/pub.hex', 'utf8').trim();
const ts = Math.floor(Date.now() / 1000).toString();
const nonce = crypto.randomBytes(12).toString('hex');
const bodyHash = crypto.createHash('sha256').update(Buffer.from(body || '', 'utf8')).digest('hex');
const canonical = [method, path, ts, nonce, bodyHash].join('\n');
const sig = crypto.sign(null, Buffer.from(canonical, 'utf8'), key).toString('hex');
// one header per line, "Name: value"
process.stdout.write(
  'x-ce-id: ' + pub + '\n' +
  'x-ce-sig: ' + sig + '\n' +
  'x-ce-ts: ' + ts + '\n' +
  'x-ce-nonce: ' + nonce + '\n'
);
NODE_SIGN
)"
  local args=(-s -o "$TMP/body.out" -w '%{http_code}' -X "$method" "$BASE$path")
  while IFS= read -r line; do [ -n "$line" ] && args+=(-H "$line"); done <<<"$hdrs"
  if [ -n "$body" ]; then args+=(-H 'content-type: application/json' --data-binary "$body"); fi
  local code; code="$(curl "${args[@]}")"
  printf '%s\n' "$code"
  cat "$TMP/body.out"
}

# mint_push_token — short-lived signed capability the cehub credential helper uses as the
# HTTP Basic password (username = owner id hex). ce-hub verifies the signature before invoking
# git-receive-pack. Format documented in web/ce-hub/GIT.md.
mint_push_token() {
  "$NODE" - "$TMP/keys" "$OWNER" "$REPO" <<'NODE_TOKEN'
const crypto = require('crypto');
const fs = require('fs');
const [dir, owner, repo] = process.argv.slice(2);
const pkcs8 = fs.readFileSync(dir + '/priv.der');
const key = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
const pub = fs.readFileSync(dir + '/pub.hex', 'utf8').trim();
// Token format is defined by the server (web/ce-hub/src/git_http.rs verify_cap_token) and the
// ce-hub CLI: base64(JSON {id,sig,ts,exp,nonce,repo}); canonical signed string is
//   "git-push\n<owner>/<repo>\n<ts>\n<exp>\n<nonce>" ; id/sig are hex; exp-ts <= 600s.
const ts = Math.floor(Date.now() / 1000);
const exp = ts + 300;
const nonce = crypto.randomBytes(16).toString('hex');
const scope = owner + '/' + repo;
const canon = `git-push\n${scope}\n${ts}\n${exp}\n${nonce}`;
const sig = crypto.sign(null, Buffer.from(canon, 'utf8'), key).toString('hex');
const tok = { id: pub, sig, ts, exp, nonce, repo: scope };
process.stdout.write(Buffer.from(JSON.stringify(tok), 'utf8').toString('base64url'));
NODE_TOKEN
}

# --- launch the hub against a throwaway data dir ----------------------------------------
say "boot ce-hub on :$PORT (CE_HUB_DATA=$TMP/data)"
mkdir -p "$TMP/data"
CE_HUB_PORT="$PORT" \
CE_HUB_DATA="$TMP/data" \
CE_HUB_MODULES="$HUB_SRC/modules" \
CE_HUB_ADMIN_OWNER="$OWNER_ID" \
CE_HUB_MAX_GIT_BYTES="${CE_HUB_MAX_GIT_BYTES:-104857600}" \
  "$CE_HUB_BIN" >"$TMP/hub.log" 2>&1 &
HUB_PID=$!

# wait for liveness
up=0
for _ in $(seq 1 50); do
  if curl -s -o /dev/null "$BASE/stats" 2>/dev/null; then up=1; break; fi
  if ! kill -0 "$HUB_PID" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ "$up" -ne 1 ]; then
  bad "ce-hub did not come up on :$PORT (last log lines below)"
  tail -20 "$TMP/hub.log" 2>/dev/null || true
  echo; echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi
ok "ce-hub is live on :$PORT"

# --- claim the owner slug (repo owner must hold the <owner> slug) ------------------------
say "claim the '$OWNER' slug for this identity"
out="$(signed_curl POST /slugs/claim "{\"slug\":\"$OWNER\",\"app_id\":\"$OWNER-$REPO\"}")"
code="$(printf '%s' "$out" | head -1)"
if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "409" ]; then
  ok "slug claim accepted (code=$code)"
else
  # not fatal for the rest of the flow if repo create allows creator-ownership, but record it
  skip "slug claim returned code=$code (continuing; repo create may still bind ownership to creator)"
fi

# --- 1. create the repo via the signed API ----------------------------------------------
say "create repo $OWNER/$REPO via POST /repos (signed)"
out="$(signed_curl POST /repos "{\"owner\":\"$OWNER\",\"name\":\"$REPO\",\"desc\":\"e2e test repo\"}")"
code="$(printf '%s' "$out" | head -1)"
if [ "$code" = "200" ] || [ "$code" = "201" ]; then
  ok "repo created (code=$code)"
else
  bad "repo create returned code=$code body=$(printf '%s' "$out" | tail -1)"
  echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# --- 2. clone the empty repo over smart-HTTP --------------------------------------------
say "git clone the empty repo over smart-HTTP"
CLONE_URL="$BASE/git/$OWNER/$REPO.git"
# A fresh repo with no commits clones as an empty repo (git warns; that is success).
if git -c http.sslVerify=false clone "$CLONE_URL" "$TMP/work" >"$TMP/clone.log" 2>&1; then
  ok "git clone succeeded (empty repo)"
elif grep -qiE 'empty repository|cloned an empty' "$TMP/clone.log"; then
  ok "git clone succeeded (server reported empty repository)"
else
  bad "git clone failed: $(tail -1 "$TMP/clone.log")"
  echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# --- 3. make a commit -------------------------------------------------------------------
say "create a commit in the working copy"
git -C "$TMP/work" config user.email "alice@example.com"
git -C "$TMP/work" config user.name  "alice"
git -C "$TMP/work" config commit.gpgsign false
git -C "$TMP/work" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
printf '# spacegame\n\nbuilt for mankind on ce-net.\n' > "$TMP/work/README.md"
git -C "$TMP/work" add README.md
if git -C "$TMP/work" commit -m "initial commit" >"$TMP/commit.log" 2>&1; then
  ok "commit created on main"
else
  bad "commit failed: $(tail -1 "$TMP/commit.log")"
  echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi
HEAD_SHA="$(git -C "$TMP/work" rev-parse HEAD)"

# --- 4. git push with HTTP Basic (username = owner id, password = signed token) ----------
say "git push to main with a signed push capability over HTTP Basic"
TOKEN="$(mint_push_token)"
# URL-encode-free: owner id is hex, token is base64url (both safe in a URL userinfo field).
PUSH_URL="http://$OWNER_ID:$TOKEN@127.0.0.1:$PORT/git/$OWNER/$REPO.git"
git -C "$TMP/work" remote set-url origin "$PUSH_URL"
if git -C "$TMP/work" -c http.sslVerify=false push origin main >"$TMP/push.log" 2>&1; then
  ok "git push (authorized receive-pack) succeeded"
else
  bad "git push failed: $(tail -3 "$TMP/push.log" | tr '\n' ' ')"
  echo "PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# negative check: an anonymous receive-pack (no Basic auth) must be rejected.
say "anonymous push must be rejected"
ANON_URL="http://127.0.0.1:$PORT/git/$OWNER/$REPO.git"
if git -C "$TMP/work" -c http.sslVerify=false push "$ANON_URL" main >"$TMP/anon.log" 2>&1; then
  bad "anonymous push was accepted (should be rejected)"
else
  ok "anonymous push rejected as expected"
fi

# --- 5. read API returns the tree + commit ----------------------------------------------
say "read API returns the pushed tree and commit"
code="$(curl -s -o "$TMP/tree.out" -w '%{http_code}' "$BASE/repos/$OWNER/$REPO/tree/main")"
if [ "$code" = "200" ] && grep -q 'README.md' "$TMP/tree.out"; then
  ok "GET /tree/main lists README.md"
else
  bad "tree read code=$code body=$(head -c 200 "$TMP/tree.out")"
fi

code="$(curl -s -o "$TMP/commit.out" -w '%{http_code}' "$BASE/repos/$OWNER/$REPO/commit/$HEAD_SHA")"
if [ "$code" = "200" ] && grep -q "$HEAD_SHA" "$TMP/commit.out"; then
  ok "GET /commit/:sha returns the head commit"
else
  bad "commit read code=$code body=$(head -c 200 "$TMP/commit.out")"
fi

code="$(curl -s -o "$TMP/blob.out" -w '%{http_code}' "$BASE/repos/$OWNER/$REPO/blob/main/README.md")"
if [ "$code" = "200" ] && grep -q 'built for mankind' "$TMP/blob.out"; then
  ok "GET /blob/main/README.md returns file bytes"
else
  bad "blob read code=$code body=$(head -c 200 "$TMP/blob.out")"
fi

# --- 6. open + merge a PR via the API ----------------------------------------------------
say "open a branch + push it, then open and merge a PR"
git -C "$TMP/work" checkout -b feature/wave >"$TMP/branch.log" 2>&1
printf '\nwave 1.\n' >> "$TMP/work/README.md"
git -C "$TMP/work" commit -am "wave 1" >>"$TMP/commit.log" 2>&1
TOKEN="$(mint_push_token)"
git -C "$TMP/work" remote set-url origin "http://$OWNER_ID:$TOKEN@127.0.0.1:$PORT/git/$OWNER/$REPO.git"
if git -C "$TMP/work" -c http.sslVerify=false push origin feature/wave >"$TMP/push2.log" 2>&1; then
  ok "pushed feature/wave"
else
  bad "feature branch push failed: $(tail -1 "$TMP/push2.log")"
fi

out="$(signed_curl POST "/repos/$OWNER/$REPO/pulls" \
  "{\"title\":\"wave 1\",\"body\":\"adds wave note\",\"head_ref\":\"feature/wave\",\"base_ref\":\"main\"}")"
code="$(printf '%s' "$out" | head -1)"
PR_NUM="$(printf '%s' "$out" | tail -1 | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.number||j.n||j.id||1))}catch(e){process.stdout.write("1")}})' 2>/dev/null || echo 1)"
if [ "$code" = "200" ] || [ "$code" = "201" ]; then
  ok "PR #$PR_NUM opened"
else
  bad "PR open code=$code body=$(printf '%s' "$out" | tail -1)"
fi

say "merge PR #$PR_NUM (owner-signed)"
out="$(signed_curl POST "/repos/$OWNER/$REPO/pulls/$PR_NUM/merge" '{}')"
code="$(printf '%s' "$out" | head -1)"
if [ "$code" = "200" ]; then
  ok "PR #$PR_NUM merged"
else
  bad "PR merge code=$code body=$(printf '%s' "$out" | tail -1)"
fi

# --- 7. instances view responds ----------------------------------------------------------
say "instances view responds"
code="$(curl -s -o "$TMP/inst.out" -w '%{http_code}' "$BASE/repos/$OWNER/$REPO/instances")"
if [ "$code" = "200" ]; then
  ok "GET /repos/:owner/:repo/instances responds 200"
else
  bad "instances code=$code body=$(head -c 200 "$TMP/inst.out")"
fi

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
