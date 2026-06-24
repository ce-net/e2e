# ce-net/e2e — live end-to-end + adversarial tests for CE

Cross-repo integration tests that stand up **real CE nodes** (and the `rdev` / `replicator` apps)
on one machine and verify the network's behaviour and **security properties** end to end — the
things unit tests can't fully cover: actual mesh peering, gossip, sync, mining, and live attacks.

These run on the **stock binaries** and demonstrate that the defences hold. They are meant to be
reproducible by anyone: clone the repos, build, run.

> The deterministic security tests (proof-of-work rejection, work-based reorg, two-miner
> convergence, capability attenuation, spawn auth, …) live as Rust tests in each crate and run in
> that crate's own CI (`cargo test`). This repo is the **live multi-process** layer on top.

## The tests

| Script | What it proves |
|---|---|
| `e2e-local.sh` | Two nodes peer over the mesh; `ce grant` issues a capability; `rdev push`/`rm` move files over the mesh; **ce-cap enforces** auth (no-cap rejected, path-caveat blocks escapes). |
| `e2e-replicate.sh` | A 3-node fleet with a shared **org root**; a seed **delegates an attenuated capability** down the tree and `rdev/spawn`s a host process on each hop — recursive self-replication, rooted and attenuating. A `sync`-only cap is **denied** spawn. |
| `e2e-attack.sh` | Stands up an in-RAM mining mesh and attacks it: **API takeover** (mutating calls without the token → 401, loopback-bound), **minority private-fork rewrite + self-mint** (rejected by work-based fork choice; honest chain never regresses), and on-demand **chain dump** to disk. |
| `e2e-worker.sh` | The **native headless worker** (`ce-worker`, no browser) connects to `ce-hub`, advertises its cores, **executes a pushed WASM module** (exact results), **auto-reconnects** after a hub restart, and is **pruned** from the live stats on disconnect. |
| `e2e-gateway.sh` | The **ce-net.com hosting dogfood**: a site served straight from **content-addressed CE blobs** via the `ce-storage` gateway — byte-exact integrity (incl. a 256 KB binary round-trip through chunk split/reassembly), `Range` (206), correct content-types, and **default-deny 404** for unknown bucket/key. |
| `e2e-ingress.sh` | The **ce-expose public ingress** front door (`ce-expose ingress`, built `--features ingress`): a tiny origin HTTP service exposed over the mesh and fronted by the relay-tier ingress. Asserts the security invariants: **default-deny** (unregistered Host → 404), a registered **public** route → 200 with byte-exact origin body, a **private** route denied without `X-CE-Cap` (401/403) and served with a valid `expose:dial` chain, the **kill switch** (`touch` the kill-file → 503, `rm` → 200), and the per-endpoint **rate limit** (burst over `rps` → 429s). |
| `e2e-apps.sh` | Fast cross-repo smoke: every CE app's own offline selftest (`ce-worker`, `ce-gov` demos, `ce-tabnet` pipeline selftest, `ce-sched`/`ce-bench` import + parse). Node-only, no network. |
| `e2e-prod.sh` | **Live** smoke + **security invariants** against the real relay (`ce-net.com`): public pages serve; the value/write API is **not** internet-exposed; node/hub/gateway ports (8844/8970/9000) are **not reachable** (only 80/4001); the site is served through the storage gateway with a **zero-downtime static fallback**; and the mesh actually computes a pushed task. *(Hits production — runs on schedule/dispatch, not on every push.)* |

All hermetic tests run with `CE_NO_AUTOBOOTSTRAP=1`, `--no-mdns`, and (where relevant) `--ephemeral`
(in-RAM), on loopback only — they never touch the live `ce-net.com` network or your disk. Every
suite skips cleanly (exit 0) when an optional binary (`HUB_BIN`, `CE_STORAGE_BIN`, …) is absent.

## Run it

Clone the repos as siblings and build the release binaries:

```bash
mkdir -p ~/ce-net && cd ~/ce-net
git clone https://github.com/ce-net/ce
git clone https://github.com/ce-net/rdev
git clone https://github.com/ce-net/replicator
git clone https://github.com/ce-net/e2e
(cd ce && cargo build --release -p ce)
(cd rdev && cargo build --release)
(cd replicator && cargo build --release)
cd e2e
./e2e-local.sh
./e2e-replicate.sh
./e2e-attack.sh        # args: <honest-nodes> <warmup-s> <attacker-headstart-s>
```

The binary locations are overridable for non-default layouts:

```bash
CE_BIN=/path/to/ce RDEV_BIN=/path/to/rdev REPL_BIN=/path/to/replicator ./e2e-local.sh
```

Requirements: a Linux/macOS host, `bash`, `curl`, `python3`. No Docker needed (the Docker-`exec`
path is covered by `rdev`'s own tests).

## CI

`.github/workflows/e2e.yml` checks out `ce` + `rdev` + `replicator`, builds them, and runs all
three scripts on every push, on a weekly schedule, and on manual dispatch. A red run means the live
network's behaviour or a security property regressed.

## Scope / honesty

- Node counts here are modest (single-machine). True 1000-node + real-geography behaviour needs a
  multi-host harness — these tests target correctness and the security properties, not raw scale.
- PoW security scales with honest hashrate; on a tiny test mesh the retarget keeps difficulty low,
  so don't read the attack tests as a statement about mainnet hashrate decentralisation — only
  about the protocol's resistance to forged work, forged identities, and unauthorised control.

MIT licensed.
