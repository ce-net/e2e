# CE adversarial e2e — the red-team attack catalog

Status: living security ledger, 2026-06-24. This is the architecture for the `e2e-attack-*.sh`
suite: a set of hermetic scripts that stand up **real ephemeral CE nodes** on loopback and **attack
them**, asserting the defenses the audit says exist actually hold — and that the holes the audit
says are open are *still* open (so the day they close, the test flips red and we notice).

Read these first; every attack below is grounded in them, not invented:
- `../e2e-attack.sh`, `../e2e-local.sh`, `../e2e-replicate.sh` — the existing idiom + attacks.
- `ce/docs/threat-model.md` — the mint -> pay -> authorize -> execute -> contain framing, Paths 0/A/B/C/D.
- `ce/docs/sybil-resistance.md` — the verified findings catalog (C1, E1-E6, N1-N8, D1-D5) and which are FIXED.
- `ce/docs/consensus.md` — CE-TWLE: VRF leader election, slot-spacing in `append()`, equivocation slash, `W=min(bond,earned)`.
- `ce/docs/capabilities.md` — ce-cap attenuating chains, on-chain `RevokeCapability`, `audience==requester`.
- `ce/docs/api.md` — the HTTP surface.
- `PLAN/compute-donation-sybil-security.md` — the live max-security design (V1-V8 vectors, layers a-f).

## The current chain is CE-TWLE (not PoW)

`ce` on `main` runs the consensus phases of `consensus.md`: PoW is gone; blocks are produced by VRF
leader election with **slot-spacing enforced in `append()`** (slot must strictly increase — the
correct, non-deletable place for the rate limit, which already kills the old cheap-51% pacing
footgun C1). `W = min(active_bond, earned_work_score)` is implemented; `SlashEquivocation` (100%
bond burn, `SLASH_REPORTER_BPS` reporter cut) is implemented; the settlement burn is implemented.
The scripts use the **current binary's flags** (`--ephemeral --no-mdns --no-mine --bootstrap
--api-port --port`), never PoW-era ones.

## The honesty rule (why this is a ledger, not a rubber stamp)

Each assertion is classified, and the classification is load-bearing:

- **MUST-HOLD** — the audit says the defense is IMPLEMENTED. The attack MUST be defeated. If it
  *succeeds*, that is a real regression: the script calls `bad()` and the suite goes RED. A held
  defense is reported via `xfail()` ("defense held") which counts as a pass.
- **KNOWN-OPEN** — the audit says the defense is OPEN/PARTIAL. The attack is EXPECTED to succeed.
  The script asserts it succeeds and calls `known_open("audit Ex: <what got through>")`, which
  prints a loud KNOWN-OPEN banner and is tallied **separately** — it does **not** fail the suite.
  When that defense lands, the test is flipped to MUST-HOLD so the closing is verified and never
  silently regresses.

A test that "passes" by not really attacking is forbidden. Every KNOWN-OPEN must demonstrate the
hole is genuinely reachable (the bad thing actually happened), not merely assert a TODO.

## Helper API (`lib/redteam.sh`)

All eight scripts source `lib/redteam.sh` and stay short. The API:

| Helper | Purpose |
|---|---|
| `say "msg"` | section header |
| `ok "msg"` / `bad "msg"` | pass / fail (FAIL>0 reddens the suite) |
| `xfail "msg"` | a MUST-HOLD defense held (the attack was defeated) — counts as pass |
| `known_open "audit Ex: ..."` | a KNOWN-OPEN attack succeeded as expected — loud banner, tallied separately, never fails |
| `skip "msg"` | optional dependency missing |
| `rt_init <name>` | pick/clean `$ROOT`, export `CE_NO_AUTOBOOTSTRAP=1` + per-suite `CE_API_TOKEN`, skip-exit if `ce` missing |
| `rt_arm_cleanup` | install the EXIT trap (kills `${PIDS[@]}` + stragglers under `$ROOT`) |
| `rt_need_bin <path> <label>` | skip-exit(0) if an optional binary (`RDEV_BIN`, `EXPOSE_BIN`) is absent |
| `rt_node_id <dir>` / `rt_peer_id <dir>` / `rt_addr <dir> <port>` | identity / dialable multiaddr |
| `rt_start_node <name> <p2p> <api> [extra...]` | one ephemeral mDNS-isolated node; appends PID; waits for API |
| `rt_start_mesh <N> <p2p0> <api0> [extra...]` | N-node MINING mesh; sets `RT_SEED`/`RT_N`/`RT_API0` |
| `rt_wait_api <api> [tries]` / `rt_field <api> <key>` / `rt_json <url>` / `rt_code <curl...>` | API readiness / status field / read / status code |
| `rt_mesh_heights` / `rt_mesh_converged <drift> <num> <den>` | substrate health (echoes `min max alive`) |
| `rt_forge <METHOD> <api> <path> <json> [curl...]` | crafted request -> status code (NO auth by default) |
| `rt_forge_body ...` | same -> response body |
| `rt_alive <pid>` | process still up? (panic-resistance) |
| `rt_result` | prints `PASS=/FAIL=/KNOWN_OPEN=` and returns non-zero iff `FAIL>0` |

Hermetic invariants enforced everywhere: `--ephemeral` (in-RAM), `--no-mdns`, `CE_NO_AUTOBOOTSTRAP=1`,
loopback only, high non-conflicting ports. The suite owns `CE_API_TOKEN` so it can drive mutating
endpoints; attack probes deliberately omit it to prove the gate. **Never touches ce-net.com.**

## Port plan (disjoint, so the eight scripts can run in parallel)

| Script | p2p base | api base |
|---|---|---|
| caps | 7100 | 9100 |
| economy | 7200 | 9200 |
| sybil-capacity | 7300 | 9300 |
| consensus | 7400 | 9400 |
| transport | 7500 | 9500 |
| ingress | 7600 | 9600 |
| eclipse | 7700 | 9700 |
| data-job | 7800 | 9800 |

---

## The eight scripts and their DISJOINT attack ownership

### 1. `e2e-attack-caps.sh` — capability / auth bypass (threat-model Path 0 + Path B; capabilities.md)

Stands up a 2-3 node mesh + (if present) `rdev serve`. All MUST-HOLD: the ce-cap model is implemented.

| Attack | Vector & steps | Expected defense | Assertion | Class |
|---|---|---|---|---|
| CAP1 No-token API takeover | POST `/transfer`, `/capabilities/revoke`, `/jobs/bid`, `/mesh-deploy`, `/mesh-kill`, `/channels/open` with no `Authorization` | every mutating (non-GET) endpoint requires Bearer token (`require_api_token`, api.rs:147) | each -> **401** | MUST-HOLD (Path 0) |
| CAP2 API not loopback-exposed | grep node log for the API bind line | binds `127.0.0.1` by default | log shows `127.0.0.1`, no `0.0.0.0` | MUST-HOLD (Path 0) |
| CAP3 No-cap mesh action | `rdev push` with NO `--cap` to a peer | ce-cap: every action needs a chain rooted at an accepted root | file never written on target | MUST-HOLD (Path B) |
| CAP4 Forged-root cap | mint a fresh unrelated key, self-issue a cap from it, present it to the target | chain root must be the target's own key or a configured root; foreign root rejected | action denied | MUST-HOLD |
| CAP5 Attenuation escalation | hold a `sync`-only cap; attempt `spawn`/`exec`/`delete` with it | abilities subset-checked per link; cannot amplify | spawn/exec denied (no `BOOT_OK`) | MUST-HOLD |
| CAP6 Path-caveat escape | hold a cap scoped to prefix `e2e`; push to `other/escape.txt` | `path_prefix` enforced by sync/delete (fail-closed) | write outside prefix denied | MUST-HOLD |
| CAP7 Expiry | issue a cap with `--expires` ~2s; sleep; use it | `not_after` enforced by `authorize` | expired cap denied | MUST-HOLD |
| CAP8 On-chain revocation | issue a cap, mine, `POST /capabilities/revoke {issuer,nonce}` (authed), wait for `/capabilities/revoked`, reuse the cap | `RevokeCapability` adds `(issuer,nonce)`; `authorize` consults `is_revoked`; subtree-killing | revoked cap denied | MUST-HOLD |
| CAP9 Confused-deputy (audience) | present a valid chain whose leaf `audience != requester` (replay someone else's cap) | leaf `audience == requester` (noise-authenticated `from_node`) | mismatched-holder cap denied | MUST-HOLD |
| CAP10 Kill-RPC resource scope | hold ANY "kill" cap; `mesh-kill` a job you do not own | **D1**: kill should bind to the job's `payer`/owner | if the kill succeeds on a non-owned job -> `known_open("audit D1: any kill cap kills any job")` | **KNOWN-OPEN (D1)** |

`rdev` (`RDEV_BIN`) is optional: CAP3/5/6 skip cleanly if absent; CAP1/2/4/7/8/9 are node-only and
always run. CAP10 owns D1 (kill-RPC authz); no other script touches kill-cap scoping.

### 2. `e2e-attack-economy.sh` — economy / double-spend / self-mint (threat-model Path A/C; E3/E5/E6)

A small mining mesh so credits exist. Mix of MUST-HOLD (the FIXED double-spend/drain bugs) and
KNOWN-OPEN (wash-trade, off-chain receipt reuse).

| Attack | Vector & steps | Expected defense | Assertion | Class |
|---|---|---|---|---|
| ECON1 Negative / overflow transfer | authed `POST /transfer` with `amount` `-1`, `0`, a >u128 string, non-numeric | amount parsed as u128 base-unit string; balance-checked | rejected (4xx), balance unchanged, node alive | MUST-HOLD |
| ECON2 Overdraw transfer | transfer more than the free balance | debit balance-checked against free (not total) balance | rejected; recipient not credited | MUST-HOLD |
| ECON3 Self-mint via API | try to credit yourself (no endpoint should mint; only `UptimeReward` does, on-chain) | no API path mints credits | balance only grows via mining, never via a crafted call | MUST-HOLD |
| ECON4 Heartbeat-without-bid drain (E3) | as a host, attempt to bill a cell with a `Heartbeat` naming no OPEN `JobBid` whose payer==cell | **E3 FIXED**: heartbeat valid only against an open bid the payer signed | the unconsented drain is rejected | **MUST-HOLD (E3, FIXED — regression guard)** |
| ECON5 Heartbeat beyond escrow (E3/E6) | bill cumulative heartbeat cost exceeding the bid's locked escrow | cumulative cost bounded by bid escrow; `JobSettle.cost <= remaining escrow` | over-escrow billing rejected | **MUST-HOLD (E3/E6, FIXED)** |
| ECON6 Cross-type double-spend (E6) | lock the whole balance in a `JobBid`/bond, then try to spend the same credits via heartbeat/transfer | free-balance subtracts `locked_balance` on every debit path | locked funds cannot be double-spent | **MUST-HOLD (E6, FIXED)** |
| ECON7 Wash-traded reputation (E4) | run payer-A + host-B (both yours); self-settle `JobSettle` with payer co-sig, no work done; read `/history/B` | `JobSettle` never verifies work was executed | `/history` reputation is fabricated -> `known_open("audit E4: JobSettle fabricates /history without work")` | **KNOWN-OPEN (E4)** |
| ECON8 Settlement burn present | observe `circulating_supply`/`burned_total` on `/status` across a wash cycle | settlement burn destroys a fraction each `JobSettle`/`Heartbeat` | `burned_total` increases each cycle (the wash is LOSSY, the implemented economic floor) | MUST-HOLD (burn implemented) |
| ECON9 Off-chain receipt reuse (E5) | open a channel, sign a receipt for `cumulative=X`, close; restart host; replay the same receipt | served-state should persist across restart | replay redeems again -> `known_open("audit E5: channel receipt replays across host restart")` | **KNOWN-OPEN (E5)** |

Owns ALL chain-economy attacks (transfer/bid/heartbeat/channel/settle). Sybil reward concentration
(E1) lives in script 3, not here. ECON4/5/6 are the FIXED-bug regression guards — if any *succeeds*
it is a loud `bad()` (a fix silently reverted).

### 3. `e2e-attack-sybil-capacity.sh` — Sybil + fake-capacity + reward concentration (Path C; E1/E2/V3)

The defenses here (HostBond gate, capacity audit, verification dial) are PLANNED/PARTIAL, so this
script is mostly KNOWN-OPEN — the point is to prove each hole is genuinely reachable today so it
flips red the day the bond gate / capacity audit lands.

| Attack | Vector & steps | Expected defense (when it lands) | Assertion | Class |
|---|---|---|---|---|
| SYB1 Free identities | mint 50 fresh node ids with `ce id` (no cost, no bond) | identities free is by design; *marketplace weight* should need a bond | identities mint at ~0 cost (baseline fact) -> `known_open("audit V1/E1: marketplace identities are free")` | **KNOWN-OPEN (V1/E1)** |
| SYB2 Sybil reward concentration (E1) | run K Sybil miners on one host in the mesh; sum their balances vs one honest miner | bond should gate `UptimeReward` eligibility | K identities split a machine's rewards into K streams -> `known_open("audit E1: UptimeReward not bond-gated")` | **KNOWN-OPEN (E1)** |
| SYB3 Fake capacity ad (E2/V3) | `POST /signals/send` (authed) advertising `cpu=1000`, `mem_mb`=huge, `tag:gpu` the host does not have; read `/atlas` | capacity values should be bond-and-challenge verified | the atlas accepts unverified capacity -> `known_open("audit E2/V3: capacity ads unverified, atlas poisoned")` | **KNOWN-OPEN (E2/V3)** |
| SYB4 Capacity-ad authorship is signed | replay another node's capacity signal claiming to be a different signer | ad authorship IS signed (refuted finding) | a forged-author capacity ad is rejected (the signature part holds) | MUST-HOLD (authorship signed) |
| SYB5 HostBond gate absent | attempt to publish a capacity ad / earn reward with **zero bond** | bond should be required for the marketplace role | unbonded host fully participates -> `known_open("audit: HostBond gate not wired (sybil-resistance.md §4.1 / PLAN §3)")` | **KNOWN-OPEN (bond gate)** |

Owns Sybil economics + capacity truth (E1/E2/V1/V3). SYB4 is the one MUST-HOLD (the *signature* on
capacity ads is real; only the *value-truth* is open — exactly the audit's E2 framing). Does not
touch consensus weight (script 4) or wash-trade (script 2).

### 4. `e2e-attack-consensus.sh` — consensus integrity (Path A; CE-TWLE; C1)

CE-TWLE consensus is implemented, so the core is MUST-HOLD. The classic minority-private-fork test
(already in `e2e-attack.sh`) is reused as the safety anchor.

| Attack | Vector & steps | Expected defense | Assertion | Class |
|---|---|---|---|---|
| CON1 Slot-spacing / pacing-footgun (C1) | run an unthrottled node; measure block rate vs the honest mesh | slot-spacing enforced in `append()` (slot strictly increases) — the 52x footgun is closed at validation | a single box CANNOT out-produce the mesh by removing a pacing line | **MUST-HOLD (C1 closed by CE-TWLE)** |
| CON2 Zero-weight block production | a fresh, unbonded, no-history node (`W=0`) tries to produce/seal a block the mesh accepts | `append()` requires `block.weight == consensus_weight(miner)` and `W>0` | a `W=0` node's block is not adopted by the honest mesh | MUST-HOLD |
| CON3 Forged VRF ticket | craft/replay a block whose `vrf_proof` does not verify or whose `ticket >= threshold*W` | `append()` verifies the VRF proof + ticket inequality + leader eligibility | forged/over-threshold ticket rejected | MUST-HOLD |
| CON4 Equivocation is slashable | produce two valid blocks for one slot under one key; submit `SlashEquivocation` evidence | `SlashEquivocation`: two conflicting signed statements for one `(domain,epoch)` burns 100% bond | the double-sign proof is accepted and slashes (or, if mesh placement can't be forced locally, assert the validation rejects the second block for the slot) | MUST-HOLD |
| CON5 Minority private-fork rewrite + self-mint | attacker mines a private chain, self-mints, rejoins (the existing `e2e-attack.sh` Attack B) | heaviest-weight suffix fork choice; honest history never rewritten | honest chain never regresses; attacker's self-minted fork not imposed on the majority | MUST-HOLD (safety anchor) |
| CON6 Beacon grind for placement (V8) | read `/beacon`; show it returns the **volatile tip**, not a confirmed-depth / VDF-delayed value | placement beacon should be confirmed-depth + VDF-delayed + windowed | `/beacon` exposes the grindable tip height/hash -> `known_open("audit V8: /beacon is the grindable tip, not a placement-safe beacon")` | **KNOWN-OPEN (V8)** |

Owns block production, VRF, slot-spacing, equivocation, fork choice, beacon-for-placement. CON4/CON6
are the only places equivocation-slash and beacon-grind are tested.

### 5. `e2e-attack-transport.sh` — mesh transport & RPC abuse (Path B/D; N1/N2/N7; refuted spoofing)

Mixes MUST-HOLD (noise sender-auth, gossip envelope signing, panic-resistance) with KNOWN-OPEN
(no peer scoring / rate limits N1, in-payload node_id N2, nonce replay N7).

| Attack | Vector & steps | Expected defense | Assertion | Class |
|---|---|---|---|---|
| TR1 Node-id spoof | submit a mesh RPC / signed message claiming `from_node` != the noise-authenticated peer | `peer_id_from_node_id(from_node)==from_peer` checked on inbound RPC | spoofed-author RPC rejected (or, locally, the published author binds to the peer) | **MUST-HOLD (refuted spoofing)** |
| TR2 Unauthorized mesh-exec/deploy | `POST /mesh-deploy` / `/mesh-exec` to a peer with no capability | deploy/kill require a cap + consult on-chain revocation | unauthorized deploy/exec denied | MUST-HOLD (Path B) |
| TR3 Malformed-payload panic-resistance | flood `/signals/send`, `/jobs/bid`, `/transfer`, `/mesh-deploy`, blob upload with truncated/garbage/oversized JSON & bodies | robust decode; never panics | every probe returns a 4xx/5xx (not a hang) and **the node process stays alive** (`rt_alive`) | MUST-HOLD |
| TR4 Gossip envelope signing | (read-side) confirm gossip is Strict+Signed by checking a forged unsigned/foreign-signed signal is not accepted into `/signals` | gossipsub `ValidationMode::Strict` + `Signed` | a signal whose claimed author != signer is not surfaced | MUST-HOLD |
| TR5 CellSignal nonce replay (N7) | send a valid signed signal; restart the victim node; replay the exact same signal | per-sender `last_nonce` should persist across restart | the replayed signal is re-accepted after restart -> `known_open("audit N7: CellSignal nonce replay after restart")` | **KNOWN-OPEN (N7)** |
| TR6 Unauthenticated in-payload node_id (N2) | publish a `ce-heights`/sync message whose in-payload `node_id` names a *different* node than the signer | payload node_id should be cross-checked against the authenticated publisher | the mismatched-payload claim is acted on -> `known_open("audit N2: in-payload node_id not cross-checked")` | **KNOWN-OPEN (N2)** |
| TR7 Gossip flood / no rate limit (N1) | one node blasts a high rate of valid signals/txs; observe no scoring/rate-limit kicks in | gossipsub v1.1 peer scoring + rate limits | the flood is absorbed with no graylisting/rate-limit (scoring is OFF) -> `known_open("audit N1: no peer scoring / no rate limits")` | **KNOWN-OPEN (N1)** |

Owns transport-layer RPC/gossip + node-id spoof + malformed-payload + N1/N2/N7. Eclipse/peer-table
(N3/N4/N5) live in script 7; ingress HTTP lives in script 6.

### 6. `e2e-attack-ingress.sh` — public HTTP ingress front door (ce-expose; threat-model Path 0 at the edge)

Requires `EXPOSE_BIN` built `--features ingress`; **skips cleanly** otherwise. This is the
adversarial counterpart to the functional `e2e-ingress.sh` — it reuses that topology but leads with
the attacks. All MUST-HOLD: the ingress exists *to provide* these invariants.

| Attack | Vector & steps | Expected defense | Assertion | Class |
|---|---|---|---|---|
| ING1 Default-deny bypass | request an unregistered `Host:` name | only allowlisted routes reachable | unregistered name -> **404** | MUST-HOLD |
| ING2 Host-header spoof / wrong owner | request a registered name but the on-chain owner != the configured owner (name-claim hijack) | ingress pins name->NodeId to the operator-approved owner | a hijacked name -> **502** (refuses to bridge) | MUST-HOLD |
| ING3 Private-route cap bypass | request a `private` route with no `X-CE-Cap`, and with a *wrong-root* cap | private routes need a valid `expose:dial` chain rooted at `dial_cap_root` | no cap / wrong-root -> **401/403**; valid chain -> 200 | MUST-HOLD |
| ING4 Kill switch | `touch` the kill-file; request any route; `rm` it | kill-file disables all ingress without restart | killed -> **503**; revived -> **200** | MUST-HOLD |
| ING5 Rate limit | fast burst over a route's configured `rps` | per-endpoint token bucket | some requests -> **429** | MUST-HOLD |
| ING6 SSRF / path smuggling | request paths like `/../`, `@internal`, `http://169.254.169.254/`, absolute-URI request targets, header-injected Host | ingress only bridges to the pinned origin over the mesh; no arbitrary upstream | smuggled targets do not reach an unintended upstream (404/400/502, never a metadata-endpoint body) | MUST-HOLD |
| ING7 Private-cap on public bypass | present a valid public-route cap on a *different* private route | per-route `dial_cap_root` scoping | a cap for route X does not authorize route Y | MUST-HOLD |

Owns the entire public-ingress edge (default-deny, host-spoof, rate-limit, kill-switch, SSRF,
private-cap scoping). No other script touches `ce-expose`.

### 7. `e2e-attack-eclipse.sh` — eclipse / peer-table / IP-diversity (Path D; N3/N4/N5/N6/N8)

The libp2p hardening (scoring, conn limits, /24 diversity, `allowed_peers` enforcement) is design-
only, so this script is predominantly KNOWN-OPEN. It demonstrates the *reachability* of each gap on
a local loopback mesh (where it can, given loopback has no real IP diversity).

| Attack | Vector & steps | Expected defense (when it lands) | Assertion | Class |
|---|---|---|---|---|
| ECL1 Peer-table flood | spin up many Sybil nodes that all bootstrap from / dial one victim; observe no connection cap | `libp2p-connection-limits` (max_established_incoming) | the victim accepts unbounded Sybil connections -> `known_open("audit N1/N5: no connection limits")` | **KNOWN-OPEN (N1/N5)** |
| ECL2 No IP-diversity cap (N3) | many Sybil peers from the same loopback "address space" populate the victim's peer set | Kademlia /24 diversity cap (max 1/24 per bucket) | all same-origin Sybils admitted to the table -> `known_open("audit N3: no Kademlia IP-diversity cap")` | **KNOWN-OPEN (N3)** |
| ECL3 `allowed_peers` is dead code (N4) | confirm a peer NOT in any allowlist still connects/stays | doc claims non-members disconnected | non-member peer is not disconnected -> `known_open("audit N4: allowed_peers not enforced")` | **KNOWN-OPEN (N4)** |
| ECL4 synced-flag race (N6) | bring up a victim, feed it a single peer-height at/below its own, observe it clears the sync gate and mines on a stale tip | require real block delivery / a quorum before clearing the gate | victim mines on a stale tip after one height -> `known_open("audit N6: synced flag clears on one peer-height")` | **KNOWN-OPEN (N6)** |
| ECL5 Safety under eclipse (anchor) | even fully surrounded by Sybils that feed a bogus heavier-looking fork, the victim must not adopt forged/invalid blocks | `append()` validation (VRF/weight/tx rules) is local & offline | a forged fork from Sybil peers is still REJECTED (validation is not a network vote) | **MUST-HOLD (validation is local)** |

Owns peer-table/eclipse/diversity/sync-race (N3/N4/N5/N6). ECL5 is the MUST-HOLD safety anchor: an
eclipse can stall liveness but cannot make a node accept invalid blocks — that is `append()`'s job,
not the network's. Single-relay chokepoint N8 is documented here as a note (not locally reproducible
without ce-net.com, which is forbidden).

### 8. `e2e-attack-data-job.sh` — data / job integrity (Path B/C execute+contain; blobs/guardian/V4)

| Attack | Vector & steps | Expected defense | Assertion | Class |
|---|---|---|---|---|
| DAT1 Blob poisoning (content-address) | `PUT /blobs` to get a CID; then request that CID but a poisoning provider returns different bytes (or `GET /blobs/<cid>` for a CID whose on-disk bytes were tampered) | content-addressing: bytes verified against the requested hash before serving (api.rs:1713, lib.rs:270) | mismatched bytes are NOT served under a CID; a tampered blob is rejected, not returned | **MUST-HOLD (content-address verify)** |
| DAT2 CID format / traversal | `GET /blobs/<non-hex>`, `/blobs/../etc/passwd`, 63/65-char hashes | hash must be 64 hex chars; no path traversal | malformed CID -> 400; traversal does not escape the blob dir | MUST-HOLD |
| DAT3 Blob immutability | upload bytes B1 -> CID; upload B2; confirm CID(B1) still returns B1 | CIDs are immutable & tamper-evident (sha256) | CID always maps to its exact bytes | MUST-HOLD |
| DAT4 Fake work / no-execution settle (V4/E4) | accept a job, settle without executing (the compute analog of E4) | `JobSettle` should be backed by a verification tier | settlement succeeds with no proof of execution -> `known_open("audit V4/E4: JobSettle accepts work that never ran")` | **KNOWN-OPEN (V4/E4)** |
| DAT5 Guardian / cryptominer bypass | (if a guardian is wired) submit a workload pattern the guardian should flag; else assert the guardian is not yet enforcing | guardian should flag abusive workloads (guardian.md) | if no guardian gate -> `known_open("audit: guardian/cryptominer detection not wired")`; if wired, the abusive pattern is flagged (MUST-HOLD) | **KNOWN-OPEN (guardian) / MUST-HOLD if wired** |
| DAT6 Resource-abuse / unbounded body | upload an oversized blob / fire many large bodies; confirm the node bounds memory and stays alive | size/resource bounds; no OOM panic | node stays alive (`rt_alive`), returns 4xx/413, no crash | MUST-HOLD (panic/OOM resistance) |

Owns blob/content-address integrity, job-result verification (V4), guardian, and data-layer
resource abuse. DAT1/DAT2/DAT3/DAT6 are MUST-HOLD (content-addressing is implemented and
self-verifying); DAT4 (V4) and DAT5 (guardian) are KNOWN-OPEN until the audit dial / guardian land.

---

## Disjointness summary (no attack is owned by two scripts)

| Domain | Owner |
|---|---|
| API token gate, ce-cap chain/attenuation/revocation/audience, kill-RPC scope (D1) | caps |
| transfer/bid/heartbeat/channel/settle, double-spend (E3/E5/E6), wash-trade (E4), burn | economy |
| Sybil identities/reward (E1), capacity-ad truth (E2/V3), HostBond gate | sybil-capacity |
| VRF/slot-spacing (C1)/zero-weight/forged-ticket/equivocation/fork-choice/beacon (V8) | consensus |
| node-id spoof, mesh-exec/deploy authz, malformed-payload panic, gossip sign, nonce replay (N7), in-payload node_id (N2), gossip flood (N1) | transport |
| public ingress: default-deny/host-spoof/rate-limit/kill-switch/SSRF/private-cap | ingress |
| eclipse/peer-table/IP-diversity/allowed_peers/sync-race (N3/N4/N5/N6), single-relay note (N8) | eclipse |
| blob content-address/immutability/traversal, fake-work (V4), guardian, data resource abuse | data-job |

## When a KNOWN-OPEN closes

The defense landing (e.g. the HostBond gate wires up, or `/beacon` becomes VDF-delayed) is the
trigger to edit exactly one assertion: change its `known_open(...)` to `xfail(...)` (now the attack
MUST be defeated) and keep the attack code identical. The git diff is the proof that the hole closed
and is now regression-guarded. Never delete the attack — the attack is the permanent witness.
