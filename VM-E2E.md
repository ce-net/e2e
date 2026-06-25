# VM / multi-node e2e

Two automated, self-cleaning harnesses to validate the CE fleet end-to-end (built 2026-06-26).

- `vm-e2e.sh` — provisions real Hetzner VMs (cx23/debian-12), deploys supervised `ce`, tests
  node-up + relay reservation + version consistency, tears down. **Blocked today**: the Hetzner
  account server-limit is 1 (only the relay) — raise it to run real VMs.
- `relay-e2e.sh` — runs N isolated container nodes on the relay (base `ubuntu:24.04` — must match the
  build glibc 2.39; bare debian:12 = glibc 2.36 can't run our binaries), each bootstraps to the live
  relay; asserts node-up, version-drift guard, and chain convergence. Run detached so an ssh drop
  doesn't orphan containers: `ssh relay 'setsid sh -s > /tmp/e2e.log 2>&1 < /dev/null &' < relay-e2e.sh`.
- `dbg.sh` — single-node connectivity/sync debug.

## Findings (this run)
1. PORTABILITY BUG: relay-built binaries need glibc 2.39 + libssl3 → will NOT run on Debian-12-class
   machines (glibc 2.36). This is why the Debian "ce update" failed. Binaries for ce-hub distribution
   MUST be built on old glibc or static/musl, per platform.
2. SYNC FLAKINESS: two identical container nodes — one synced to tip (h=3495), the other stuck at
   genesis (h=1). Non-deterministic mesh sync; a real reliability bug to fix in ce-mesh.
