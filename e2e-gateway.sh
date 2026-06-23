#!/usr/bin/env bash
# Hermetic gateway/hosting end-to-end test: proves the ce-net.com dogfood path — a static site
# served straight out of CE content-addressed blobs through the ce-storage S3-subset gateway, with
# end-to-end content integrity (the bytes that come back are byte-identical / sha256-identical to
# what was put in, proving chunk split -> blob store -> reassembly -> hash verification round-trips).
#
# Components: one ephemeral local CE node (CE_BIN) + ce-storage (CE_STORAGE_BIN, built with
# --features gateway). The CLI and the gateway share the node's bucket index (--index) and both talk
# to the node at 127.0.0.1:$API. Loopback only, high ports, no autobootstrap — never touches the mesh.
set -u
export CE_NO_AUTOBOOTSTRAP=1
export CE_API_TOKEN="${CE_API_TOKEN:-e2e-shared-token}"

CE=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
STORAGE=${CE_STORAGE_BIN:-$HOME/ce-net/ce-storage/target/release/ce-storage}
ROOT=/tmp/ce-e2e-gateway
DATA=$ROOT/data
SRC=$ROOT/src
GOT=$ROOT/got
INDEX=$ROOT/buckets.json
# The ce-storage CLI/gateway always talk to the node on the default API port (127.0.0.1:8844).
P2P=4191; API=8844; GW=19000
BUCKET=site
PIDS=()
PASS=0; FAIL=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# sha256 of a file -> bare hex (shasum on macOS, sha256sum on Linux, python3 as a fallback).
sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  fi
}

# Skip cleanly (exit 0) if a required binary is missing — the harness treats this as "not applicable"
# rather than a failure, mirroring the build-gated suites.
[ -x "$CE" ]      || { echo "SKIP: ce binary not found at $CE (set CE_BIN)"; exit 0; }
[ -x "$STORAGE" ] || { echo "SKIP: ce-storage binary not found at $STORAGE (set CE_STORAGE_BIN; build with --features gateway)"; exit 0; }

rm -rf "$ROOT"; mkdir -p "$DATA" "$SRC" "$GOT" "$(dirname "$INDEX")"

say "start ephemeral CE node (no mesh, no mining)"
"$CE" --data-dir "$DATA" start --ephemeral --no-mdns --no-mine --port $P2P --api-port $API >"$ROOT/node.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$API/status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$API/status" >/dev/null 2>&1 && ok "node up on 127.0.0.1:$API" || { bad "node failed to start"; cat "$ROOT/node.log"; exit 1; }

say "create the test site (known HTML/JS + a 256KB random blob)"
printf '<!doctype html><html><head><title>CE</title></head><body><h1>Hosted on CE</h1><script src="app.js"></script></body></html>' > "$SRC/index.html"
printf 'console.log("served from content-addressed CE blobs");\n' > "$SRC/app.js"
head -c 262144 /dev/urandom > "$SRC/blob.bin"
[ -s "$SRC/index.html" ] && [ -s "$SRC/app.js" ] && [ "$(wc -c < "$SRC/blob.bin")" -eq 262144 ] \
  && ok "source files created (index.html, app.js, blob.bin=256KB)" || { bad "failed to create source files"; exit 1; }
BLOB_SHA=$(sha "$SRC/blob.bin")
echo "blob.bin sha256=$BLOB_SHA"

say "make a bucket and put each file as a content-addressed object"
"$STORAGE" --index "$INDEX" mb "$BUCKET" >"$ROOT/storage.log" 2>&1 \
  && ok "made bucket $BUCKET" || { bad "mb failed"; cat "$ROOT/storage.log"; exit 1; }

put_ok=1
"$STORAGE" --index "$INDEX" put "$BUCKET/index.html" "$SRC/index.html" --content-type "text/html"               >>"$ROOT/storage.log" 2>&1 || put_ok=0
"$STORAGE" --index "$INDEX" put "$BUCKET/app.js"     "$SRC/app.js"     --content-type "application/javascript"  >>"$ROOT/storage.log" 2>&1 || put_ok=0
"$STORAGE" --index "$INDEX" put "$BUCKET/blob.bin"   "$SRC/blob.bin"   --content-type "application/octet-stream" >>"$ROOT/storage.log" 2>&1 || put_ok=0
[ "$put_ok" -eq 1 ] && ok "put index.html, app.js, blob.bin" || { bad "one or more puts failed"; tail -20 "$ROOT/storage.log"; }

say "start the ce-storage gateway (shares the same bucket index)"
"$STORAGE" --index "$INDEX" gateway --bind "127.0.0.1:$GW" >"$ROOT/gateway.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:$GW/" && break; sleep 1; done
curl -fsS -o /dev/null "http://127.0.0.1:$GW/" && ok "gateway up on 127.0.0.1:$GW" || { bad "gateway failed to start"; cat "$ROOT/gateway.log"; exit 1; }

GWURL="http://127.0.0.1:$GW"

# Fetch bucket/key over the gateway into $GOT/<name>, returning status code + the Content-Type header.
fetch() { # fetch <key> <outfile>  -> sets CODE and CT
  CODE=$(curl -s -o "$2" -D "$2.hdr" -w '%{http_code}' --max-time 30 "$GWURL/$BUCKET/$1")
  CT=$(tr -d '\r' < "$2.hdr" | awk -F': ' 'tolower($1)=="content-type"{print $2}' | tail -1)
}

say "INTEGRITY: index.html served verbatim with the right content type"
fetch index.html "$GOT/index.html"
if [ "$CODE" = 200 ] && echo "$CT" | grep -qi 'text/html' && cmp -s "$SRC/index.html" "$GOT/index.html"; then
  ok "GET /$BUCKET/index.html -> 200 text/html, bytes identical to source"
else
  bad "index.html mismatch (code=$CODE ct=$CT cmp=$(cmp -s "$SRC/index.html" "$GOT/index.html" && echo same || echo diff))"
fi

say "INTEGRITY: app.js served verbatim with the right content type"
fetch app.js "$GOT/app.js"
if [ "$CODE" = 200 ] && echo "$CT" | grep -qi 'javascript' && cmp -s "$SRC/app.js" "$GOT/app.js"; then
  ok "GET /$BUCKET/app.js -> 200 application/javascript, bytes identical to source"
else
  bad "app.js mismatch (code=$CODE ct=$CT cmp=$(cmp -s "$SRC/app.js" "$GOT/app.js" && echo same || echo diff))"
fi

say "CONTENT-ADDRESSED INTEGRITY: 256KB blob round-trips with an identical sha256"
fetch blob.bin "$GOT/blob.bin"
GOT_SHA=$(sha "$GOT/blob.bin")
echo "served blob.bin sha256=$GOT_SHA"
if [ "$CODE" = 200 ] && [ "$GOT_SHA" = "$BLOB_SHA" ]; then
  ok "GET /$BUCKET/blob.bin -> 200, sha256 matches (chunk split + reassembly + verification holds)"
else
  bad "blob.bin sha256 mismatch (code=$CODE want=$BLOB_SHA got=$GOT_SHA)"
fi

say "RANGE: a ranged GET returns 206 with exactly the requested bytes"
RCODE=$(curl -s -o "$GOT/range.part" -w '%{http_code}' --max-time 30 -H 'Range: bytes=0-99' "$GWURL/$BUCKET/blob.bin")
RLEN=$(wc -c < "$GOT/range.part" | tr -d ' ')
if [ "$RCODE" = 206 ] && [ "$RLEN" = 100 ]; then
  ok "Range bytes=0-99 -> 206 with 100 bytes"
else
  bad "range request wrong (code=$RCODE len=$RLEN, expected 206/100)"
fi
# The ranged bytes must also match the head of the source (integrity of the windowed read).
if head -c 100 "$SRC/blob.bin" | cmp -s - "$GOT/range.part"; then
  ok "ranged bytes match the first 100 bytes of the source"
else
  bad "ranged bytes differ from the source window"
fi

say "404: unknown key and unknown bucket are both not found (default-deny)"
MK=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$GWURL/$BUCKET/missing.key")
[ "$MK" = 404 ] && ok "GET /$BUCKET/missing.key -> 404" || bad "missing key returned $MK (expected 404)"
NB=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$GWURL/nope-bucket/x")
[ "$NB" = 404 ] && ok "GET /nope-bucket/x -> 404" || bad "unknown bucket returned $NB (expected 404)"

say "RESULT"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
