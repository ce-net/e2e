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

### Adversarial "compromise the mesh" suite (`e2e-attack-*.sh`)

These stand up **real ephemeral CE nodes** (CE-TWLE main) and **attack** them, asserting the defenses hold. They share `lib/redteam.sh` (the `say`/`ok`/`bad`/`xfail`/`known_open` accounting and hermetic node spin-up). **Read the honesty note below** — each attack is tagged MUST-HOLD or KNOWN-OPEN against the live security audit.

| Script | What it attacks (MUST-HOLD held / KNOWN-OPEN flagged) |
|---|---|
| `e2e-attack-caps.sh` | **Capability / auth** (threat-model Path 0 + B). MUST-HOLD: no-token API takeover → 401; API bound to loopback; no-cap / forged-root / ability-mismatch / path-caveat-escape / expired / **on-chain-revoked** / wrong-holder cap → denied (ce-cap `authorize()` steps 1-7). KNOWN-OPEN: CAP10 kill-RPC resource scope (audit **D1** — any kill cap kills any job). Drives `rdev serve` as the enforcement point; degrades to node-only CAP1/CAP2/CAP10 if `rdev` is absent. |
| `e2e-attack-transport.sh` | **Transport / RPC** (Path B/D). MUST-HOLD: libp2p-noise binds NodeId↔PeerId (sender-mismatch dropped); API token gate; `/mesh-deploy`+`/mesh-kill` need a cap chain; signal author binds to the node; malformed/oversized payload floods → no panic/crash. KNOWN-OPEN: **N7** nonce replay, **N2** in-payload node_id not cross-checked, **N1** gossip flood / no peer scoring. |
| `e2e-attack-economy.sh` | **Economy / double-spend / self-mint** (Path A/C). MUST-HOLD: negative/overflow/non-numeric & overdraw transfer rejected; no mint endpoint; heartbeat-without-bid & heartbeat/settle-beyond-escrow (**E3**) and cross-type double-spend of locked funds (**E6**) rejected; settle needs payer co-sig; forged/oversized channel receipt rejected. KNOWN-OPEN: **E4** wash-traded reputation (the 80% settlement burn makes it lossy, a real partial mitigation that MUST hold), **E5** off-chain receipt reuse across restart. |
| `e2e-attack-consensus.sh` | **CE-TWLE consensus integrity**. MUST-HOLD: slot strictly increases in `append()` (**C1** cheap-51%-pacing footgun closed — a stale/replayed slot is rejected ALWAYS); offline local block validation. KNOWN-OPEN: **V8** `/beacon`-for-placement. (Honesty note in-file: on an ephemeral mesh `total_consensus_weight()==0`, so `append()` takes the documented bootstrap fallback; HostBond/SlashEquivocation are chain primitives with no HTTP/CLI surface in this binary.) |
| `e2e-attack-sybil-capacity.sh` | **Sybil economics + capacity truth**. MUST-HOLD: capacity-ad **authorship is signed** (only the *values* can lie, not the *signer*); the 80% settlement burn makes wash-trade **lossy**. KNOWN-OPEN: **V1/E1** free identities, **E1** Sybil reward concentration (UptimeReward not bond-gated), **E2/V3** unverified capacity ads, **E4** wash-traded `/history`, absent **HostBond** gate. |
| `e2e-attack-eclipse.sh` | **Network / eclipse** (Path D). MUST-HOLD (**ECL5** safety anchor): an eclipse can stall liveness but can **never** make a node adopt invalid/forged blocks (`append()` validation is local & offline, not a network vote). KNOWN-OPEN: **N3-N6/N8** — no connection limits, no /24 IP-diversity cap, dead `allowed_peers`, synced-flag race (libp2p hardening is design-only today; loopback caveat stated in-file). |
| `e2e-attack-data-job.sh` | **Data + job integrity**. MUST-HOLD: blob poisoning defeated by content-addressing (re-hash mismatch dropped); CID format / path-traversal rejected; CID immutability; unbounded-body → no panic/OOM. KNOWN-OPEN: **V4/E4** fake-work / no-execution settle (no proof-of-execution), **guardian** cryptominer screen not wired (`AllowAllGuardian` default). |
| `e2e-attack-ingress.sh` | **Public HTTP ingress edge** (`ce-expose ingress`, built `--features ingress`; skips cleanly otherwise). All MUST-HOLD: **default-deny** (unregistered Host → 404); **host-spoof / name-allowlist bypass** (case/trailing-dot/blocked-substring/IP-literal all blocked at parse/allowlist, never bridged); **SSRF / path smuggling** (metadata IP/name, absolute-URI target, traversal never reach an unintended upstream — the relay only bridges the pinned origin); **private-route cap** (no `X-CE-Cap` → 401, forged/expired/wrong-root → denied, valid `expose:dial` chain → 200); **per-route cap scoping** (a cap rooted at route X's `dial_cap_root` does not open route Y); per-endpoint **rate limit** (burst over `rps` → 429s); **kill switch** (`touch` → 503, `rm` → 200). |
| `e2e-prod.sh` | **Live** smoke + **security invariants** against the real relay (`ce-net.com`): public pages serve; the value/write API is **not** internet-exposed; node/hub/gateway ports (8844/8970/9000) are **not reachable** (only 80/4001); the site is served through the storage gateway with a **zero-downtime static fallback**; and the mesh actually computes a pushed task. *(Hits production — runs on schedule/dispatch, not on every push.)* |

All hermetic tests run with `CE_NO_AUTOBOOTSTRAP=1`, `--no-mdns`, and (where relevant) `--ephemeral`
(in-RAM), on loopback only — they never touch the live `ce-net.com` network or your disk. Every
suite skips cleanly (exit 0) when an optional binary (`HUB_BIN`, `CE_STORAGE_BIN`, `RDEV_BIN`, …) is
absent.

### MUST-HOLD vs KNOWN-OPEN (the honesty rule)

The adversarial suite is a **living security ledger**, not a rubber stamp. Every attack is tagged
against the real audit (`ce/docs/threat-model.md`, `sybil-resistance.md`, `consensus.md`,
`capabilities.md`, `PLAN/compute-donation-sybil-security.md`):

- **MUST-HOLD** — the audit says the defense is **implemented** (equivocation slash, slot-spacing,
  API-token auth, ce-cap auth/attenuation/on-chain revocation, double-spend of locked funds E6,
  heartbeat-beyond-escrow E3, content-address/blob verify, peer-id-binds-payload-author). The attack
  **must be defeated**. A success is a **real regression** → the test calls `bad()` and the run
  **FAILS** (it shows as `XFAIL (defense held)` when the defense correctly defeats the attack).
- **KNOWN-OPEN** — the audit marks the defense **OPEN/PARTIAL** (E1 Sybil UptimeReward, E2 unverified
  capacity ads, E4 wash-traded reputation, E5 receipt replay, eclipse / IP-diversity N-findings,
  guardian-not-wired, V4 no proof-of-execution, V8 beacon, D1 kill-scope). The attack is **expected
  to succeed**; the test asserts it succeeds and calls `known_open("audit Ex: …")`, which prints a
  loud, greppable `KNOWN-OPEN` line and is **tallied separately** — it does **not** fail the run.
  **When that defense lands, the test flips to MUST-HOLD** (`xfail`/`bad`), so the hole silently
  reopening — or the fix silently not landing — is caught. No test passes by not really attacking.

The final line of every script is `PASS=<n> FAIL=<n> KNOWN_OPEN=<n>`; the suite's exit code is
non-zero iff `FAIL>0`.

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

`.github/workflows/e2e.yml` checks out `ce` + `rdev` + `replicator` (and the app/fabric siblings),
builds them, and runs the suites on every push, on a weekly schedule, and on manual dispatch. A red
run means the live network's behaviour or a security property regressed. Four jobs, isolated so a
ce-side regression in one cannot mask the others:

- `apps-fabric` — worker / gateway / ingress / app selftests.
- `adversarial` — the original consensus + capability live suite (`e2e-local`, `e2e-replicate`, `e2e-attack`).
- `redteam` — the **compromise-the-mesh** suite: every `e2e-attack-*.sh` as its own `if: always()`
  step (one red MUST-HOLD defense never masks the others). KNOWN-OPEN holes print loudly but do not
  fail the job; a defeated MUST-HOLD defense fails it.
- `prod-smoke` — live invariants against the real relay (schedule / dispatch only).

## Scope / honesty

- Node counts here are modest (single-machine). True 1000-node + real-geography behaviour needs a
  multi-host harness — these tests target correctness and the security properties, not raw scale.
- PoW security scales with honest hashrate; on a tiny test mesh the retarget keeps difficulty low,
  so don't read the attack tests as a statement about mainnet hashrate decentralisation — only
  about the protocol's resistance to forged work, forged identities, and unauthorised control.

MIT licensed.
