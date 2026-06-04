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

All tests are **hermetic**: nodes run with `CE_NO_AUTOBOOTSTRAP=1`, `--no-mdns`, and (where
relevant) `--ephemeral` (in-RAM), so they never touch the live `ce-net.com` network or your disk.

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
