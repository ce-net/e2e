#!/usr/bin/env bash
# ce-appmgr ("ce app") end-to-end: spins up a REAL local ce node and exercises the install/setup APIs
# exactly as a user would, validating the "shared computer" surface:
#   1. ONE OS service          — `ce start` runs the app supervisor in-process (no separate unit)
#   2. local-source install    — `ce app install <dir>` builds-and-installs from a working tree
#   3. capability advertise     — a daemon's `[app].provides` shows up in the node's <data>/extra-capabilities
#   4. oci: source              — `ce app install oci:<image>` records any container/system as a ceapp
#   5. one repo -> many ceapps  — `ce app publish --repo <dir>` discovers + publishes every ceapp.toml
# Docker-free (oci/publish validate the record + manifest paths, not a pull). Mirrors e2e-local.sh style.
# The remote-install-over-mesh keystone runs on real VMs in vm-e2e.sh.
set -u
export CE_NO_AUTOBOOTSTRAP=1
export CE_API_TOKEN="${CE_API_TOKEN:-e2e-appmgr-token}"

CE=${CE_BIN:-$HOME/ce-net/ce/target/release/ce}
ROOT=/tmp/ce-appmgr-e2e
A_DATA=$ROOT/A
A_P2P=4131; A_API=8931
REG=$ROOT/registry
PIDS=()
PASS=0; FAIL=0
say(){ printf '\n=== %s ===\n' "$1"; }
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
[ -x "$CE" ] || { echo "ce binary not found at $CE (set CE_BIN)"; exit 1; }
rm -rf "$ROOT"; mkdir -p "$A_DATA" "$REG"

# ---- build a tiny native test ceapp that is also a daemon advertising a capability ----------------
say "build a tiny test ceapp (a daemon that provides 'test-cap')"
APPDIR=$ROOT/hello; mkdir -p "$APPDIR/src"
cat > "$APPDIR/Cargo.toml" <<'EOF'
[package]
name = "hello"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "hello"
path = "src/main.rs"
EOF
cat > "$APPDIR/src/main.rs" <<'EOF'
fn main() { loop { std::thread::sleep(std::time::Duration::from_secs(3600)); } }
EOF
cat > "$APPDIR/ceapp.toml" <<'EOF'
[app]
name = "hello"
version = "0.1.0"
runtime = "native"
provides = ["test-cap"]
[native]
bin = "hello"
[sandbox]
tier = "none"
net  = "none"
[daemon]
enabled = true
restart = "on-failure"
EOF
( cd "$APPDIR" && cargo build --release >/dev/null 2>&1 ) && ok "test app built" || { bad "test app build"; exit 1; }

# ---- 1. ONE OS service: node runs the app supervisor in-process ----------------------------------
say "start node A (one service = node + in-process app supervisor)"
"$CE" --data-dir "$A_DATA" start --no-mdns --port $A_P2P --api-port $A_API --no-mine >"$ROOT/A.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 40); do curl -fsS "http://127.0.0.1:$A_API/status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$A_API/status" >/dev/null 2>&1 && ok "node A up" || { bad "node A start"; cat "$ROOT/A.log"; exit 1; }
grep -q "App supervisor running in-process" "$ROOT/A.log" && ok "supervisor runs in-process (one service)" || bad "supervisor not in-process"

# ---- 2. local-source install ---------------------------------------------------------------------
say "ce app install <dir> (local source) + it becomes a supervised daemon"
"$CE" --data-dir "$A_DATA" app install "$APPDIR" >"$ROOT/install-local.log" 2>&1 && ok "local install ok" || { bad "local install"; cat "$ROOT/install-local.log"; }
"$CE" --data-dir "$A_DATA" app ls 2>/dev/null | grep -q hello && ok "hello listed installed" || bad "hello not installed"

# ---- 3. capability advertisement: the supervisor publishes the daemon's provides -----------------
say "supervisor advertises the daemon's [app].provides -> <data>/extra-capabilities"
for i in $(seq 1 12); do grep -q "test-cap" "$A_DATA/extra-capabilities" 2>/dev/null && break; sleep 1; done
grep -q "test-cap" "$A_DATA/extra-capabilities" 2>/dev/null && ok "provided capability advertised by node" || { bad "provides not advertised"; ls -la "$A_DATA"; }

# ---- 4. oci: source (install any container/system) -----------------------------------------------
say "ce app install oci:alpine:3 (records app; lazy pull)"
"$CE" --data-dir "$A_DATA" app install oci:alpine:3 >"$ROOT/oci.log" 2>&1 && ok "oci install recorded" || { bad "oci install"; cat "$ROOT/oci.log"; }
"$CE" --data-dir "$A_DATA" app ls 2>/dev/null | grep -q alpine && ok "alpine listed" || bad "alpine not listed"

# ---- 5. one repo, many ceapps: publish --repo ----------------------------------------------------
say "ce app publish --repo (one repo -> many ceapps)"
mkdir -p "$ROOT/multirepo/apps/a" "$ROOT/multirepo/apps/b" "$ROOT/multirepo/target"
echo 'junk' > "$ROOT/multirepo/target/ceapp.toml"   # must be SKIPPED (build dir)
for n in a b; do cat > "$ROOT/multirepo/apps/$n/ceapp.toml" <<EOF
[app]
name = "multi-$n"
version = "0.1.0"
runtime = "oci"
[oci]
image = "alpine:3"
EOF
done
"$CE" --data-dir "$A_DATA" app publish --repo "$ROOT/multirepo" --out "$REG" >"$ROOT/publish.log" 2>&1
if [ -f "$REG/apps/multi-a/ceapp.toml" ] && [ -f "$REG/apps/multi-b/ceapp.toml" ] && [ ! -d "$REG/apps/" -o -z "$(ls "$REG/apps" 2>/dev/null | grep -i junk)" ]; then
  ok "publish --repo published both ceapps (and skipped target/)"
else
  bad "publish --repo"; cat "$ROOT/publish.log"; ls -R "$REG" 2>/dev/null
fi

echo; echo "==== ce-appmgr e2e: $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
