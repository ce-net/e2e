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

## trana + ce-gke (added 2026-06-26)

Three layered tests verify the trana distributed backend works inside the whole CE ecosystem and is
fault-tolerant when nodes fail randomly — ordered by how much infra they need:

1. `ce-gke/tests/trana_e2e.rs` — **runs anywhere, deterministic** (no mesh, no VMs). Drives the real
   ce-gke Controller + daemon reconcile against the `FakeDriver` with a trana Deployment, injecting
   random replica crashes, whole-node loss, and deploy-rejecting hosts. Asserts ce-gke heals back to
   the desired replica count every time and keeps trana discoverable. Run: `cargo test -p ce-gke
   --test trana_e2e` (or `tools/remote-test.sh ce-gke`). 4/4 green.
2. `e2e-trana.sh` — **hermetic local mesh** (loopback, ephemeral nodes; needs the `ce` + `trana`
   binaries built). Stands up an N-node CE mesh, runs two trana-node instances, and proves: a thread
   and a media object written on T1 replicate to T0 (gossip + object replication), karma fuses social
   + on-chain compute trust, and content survives a trana node being killed + a CE node being killed
   (mesh re-converges, killed node rejoins). Skips cleanly if binaries are absent.
3. `e2e-trana-gke.sh` — **live ce-gke deploy** (needs the `ce-gke` binary, a CE node with
   docker-capable peers, and a published `ghcr.io/ce-net/trana` image). `ce-gke apply -f
   trana/deploy/trana.gke.yaml`, converge to N/N, then mesh-kill a replica and assert ce-gke heals it
   back. Point it at the relay, a VM pool, or `relay-e2e.sh` containers via `CE_NODE=`.

**Real-VM path:** the same `e2e-trana-gke.sh` is the VM test — provision VMs exactly as `vm-e2e.sh`
does (Hetzner cx23), install `ce` + `ce-gke`, start a node on each, then run `e2e-trana-gke.sh
CE_NODE=http://<one-vm>:8844`. Still gated on the Hetzner server-limit (currently 1) and on a
published trana container image. To chaos-test at the VM layer, `DELETE` a random VM mid-run and
assert ce-gke re-places trana onto the survivors (the heal logic is already pinned by test #1).

**CI wiring (pending):** add `e2e-trana.sh` to the `adversarial` job once `ce-net/trana` and
`ce-net/ce-gke` are pushed (checkout both beside `ce`, build the trana workspace, then
`./e2e-trana.sh`). The script self-skips, so it is safe to add the moment the repos exist.

## Findings (this run)
1. PORTABILITY BUG: relay-built binaries need glibc 2.39 + libssl3 → will NOT run on Debian-12-class
   machines (glibc 2.36). This is why the Debian "ce update" failed. Binaries for ce-hub distribution
   MUST be built on old glibc or static/musl, per platform.
2. SYNC FLAKINESS: two identical container nodes — one synced to tip (h=3495), the other stuck at
   genesis (h=1). Non-deterministic mesh sync; a real reliability bug to fix in ce-mesh.
