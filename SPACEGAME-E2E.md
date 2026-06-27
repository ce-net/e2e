# spacegame end-to-end tests (real VMs + mobile/WASM browser)

These harnesses validate the whole spacegame stack working **together on fresh machines**, over the
real CE mesh — native nodes on freshly provisioned VMs, and the game running on a **phone in the
browser** through a WASM-only node, sharing the same world. Built 2026-06-26.

| File | What it is |
|---|---|
| `spacegame-bot.py` | A headless native client that speaks the exact game wire (`/mesh/subscribe`, `/mesh/publish`, `/mesh/messages/stream`, payloads as `payload_hex`). Joins a sector, plays, and prints a JSON summary the shell asserts on. Stdlib-only — runs on a bare VM. |
| `spacegame-vm-e2e.sh` | Provisions **3 fresh Hetzner VMs**, installs `ce` via the real `install.sh`, ships the `spacegame` binary, hosts the galaxy across them, and asserts the systems below. Self-cleaning (deletes VMs on exit). |
| `browser/spacegame-browser-e2e.mjs` | Playwright test on a **mobile-emulated** browser (phone viewport + touch). Loads the frontend, connects through the WASM/same-origin node, and asserts join + play + the same-origin invariant + (optional) native↔browser interop. |
| `spacegame-e2e.sh` | Orchestrator: runs the native VM leg, then the mobile/WASM browser leg, and reports a combined result. |

## What is covered (systems × test)

| System (where it lives) | Covered by |
|---|---|
| Fresh install of `ce` on a clean machine (`install.sh`) | `spacegame-vm-e2e.sh` (install leg, with pinned-binary fallback) |
| Node joins the mesh / relay circuit | `spacegame-vm-e2e.sh` (node-up assertions) |
| **Distribution** — sectors hosted on different nodes (`shard.rs`, `director`) | `spacegame-vm-e2e.sh` (`nearest`/`shard`, A=0_0, B=1_0) |
| **Join + realtime** over the mesh (`wire.rs`, SSE) | bot `present`; browser `/mesh/messages/stream` |
| **Weapons / combat / physics** (`sim.rs`, `physics.rs`) | bot `saw_bullets` (blaster); debris on kills exercised by adversarial bots |
| **Infinite map** — cross-sector transit (`sim::take_transits`, `director::publish_transit`) | bot `--behavior east --watch-sector 1_0` ⇒ `transited_to=1_0` |
| **Hot reload** — live ruleset push (`ruleset.rs`, `director::publish_ruleset`) | `spacegame ruleset push` ⇒ bot reports `ruleset>=2` |
| **Fault tolerance** — replica takeover after total host loss (`replication.rs`, `snapshot.rs`) | DELETE VM A ⇒ C adopts the replicated 0_0 snapshot ⇒ sector resumes |
| **Autoscale** — pre-warm neighbours (`director::prewarm_neighbors`) | A hosts `--autoscale`; observable as neighbour placement under load |
| **Always-alive faction + NPC fleet under command** (`faction.rs`, `sim.rs`) | bot reads `FactionView` on the wire: `factions_tracked`, `my_faction.power`, `my_fleet_alive`, `npc_ships_seen` |
| **Mobile-in-browser** — phone profile, touch controls | `browser/...mjs` (mobile device, canvas, touch+key ⇒ input publish) |
| **WASM-only peer** — in-browser node, nothing leaves the origin | `browser/...mjs` (`window.__ceNode` check + same-origin invariant) |
| **Native ↔ browser interop** — both share a sector | `browser/...mjs` with `NATIVE_PEER=1` while the VM bots are live |

> Faction tracking: faction state IS now on the snapshot wire (`FactionView` — economy, roster, live
> fleet count, standing order), and fleet units are real NPC ships carrying `owner`/`role`. The bot
> asserts factions are tracked and that your faction fields NPC ships under command. To assert "kept
> building while you were away" specifically, run a bot, leave, and re-read the faction `power` after a
> delay — the autonomy advances it every tick regardless of presence.

## Running

```bash
# Native multi-VM (needs HETZNER_API_TOKEN in ce/.env, ce-laptop SSH key, and a linux spacegame binary)
SPACEGAME_BIN=/path/to/linux/spacegame  e2e/spacegame-vm-e2e.sh
KEEP=1 SPACEGAME_BIN=...                 e2e/spacegame-vm-e2e.sh   # keep VMs for debugging

# Mobile / WASM browser (needs a deployed frontend URL)
cd e2e/browser && npm i
SPACEGAME_URL="https://<deployed-frontend>/" DEVICE="iPhone 13" npm test

# Both, combined
SPACEGAME_BIN=... SPACEGAME_URL=... NATIVE_PEER=1 e2e/spacegame-e2e.sh
```

## Requirements & gating

- **Hetzner server limit.** The native test provisions 3 VMs. The account limit is currently **1**
  (only the relay fits) — raise it to run the VM leg. Until then the script self-reports the block.
- **glibc / image.** Use `ubuntu-24.04` VMs so relay-built binaries run (relay = glibc 2.39; debian-12
  = 2.36 cannot run them — see `VM-E2E.md`). `IMG=` overrides.
- **spacegame binary.** No public release yet, so pass `SPACEGAME_BIN` (a linux binary built on the
  relay / matching the VM glibc) or `SPACEGAME_URL`. `ce` itself comes from the real `install.sh`
  (with a pinned-binary fallback if no GitHub release is tagged).
- **Browser leg.** Needs Node + Playwright (`npm i` installs chromium) and a deployed frontend whose
  origin boots the WASM node or proxies `/ce` to a CE node.

## The gap these missed — and the deploy smoke gate (READ THIS)

Leif, verbatim: *"THE E2E TESTS SHOULD HAVE CAUGHT THIS WHY NOT?? FIX SO IT DOES."*

spa.ce-net.com shipped three **browser-only, deploy-only** regressions that every test above passed
through:

1. **wasm wouldn't boot** — recent `rust-lld` emits the function table with a fixed max (`min == max`), so
   wasm-bindgen's runtime `table.grow()` for closures failed. Invisible to `cargo test`; only fails when a
   browser instantiates the module.
2. **wasm crashed on a Retina canvas** — surface (2970 px) exceeded the WebGL2 max texture size (2048).
   Needs a real GPU; headless Playwright/CI has none.
3. **a joining player's ship never arrived** — the live SSE bridge through **nginx + Cloudflare** delivered
   nothing to the browser, while the node itself self-delivered fine. The whole *backend* was green.

Why the existing legs missed all three: the VM leg and the bot test against **fresh/local nodes**, never
the **deployed edge** (the real `spa.ce-net.com` → Cloudflare → nginx → hub → node). The Playwright leg
runs a **local build**, not the relay-built wasm, with **no GPU**, and — fatally — **none of it runs as a
deploy gate** (it needs Hetzner VMs and is manual; CI only runs `cargo test`).

**The fix:** [`spacegame/deploy/smoke.sh`](../spacegame/deploy/smoke.sh), wired as the **final, blocking
step of `deploy/deploy.sh`** (`all` runs it; or `deploy.sh smoke`). It asserts, against the **LIVE URL**:

1. the **served** wasm's function table is **growable** (catches regression 1, no browser needed);
2. the page + `/ce` bridge are reachable;
3. a **Join published through the public `/ce` bridge yields that node's ship back over the live SSE
   stream within ~12 s** (catches regression 3 — the exact "no ship" the player saw).

It runs **on the relay**, which can hold a streaming HTTP connection; a laptop/sandbox often buffers SSE
and would false-fail (that buffering is itself why the bug was hard to see locally). A red smoke gate
**fails the deploy** — so a broken browser path can never silently ship again. Regression 2 (GPU surface
size) is now guarded in code (`size_canvas` caps the drawing buffer at 2048); a true headless-GPU test is
the remaining nice-to-have.

## Mobile native (next)

The browser leg proves **mobile-in-browser** today. **Native mobile** (a packaged iOS/Android app that
ships the CE node — WASM via a webview node, or a native build of the node — and the spacegame client)
is the next step. When that exists, add a third leg that drives the packaged app on a device/emulator
(Appium or the platform UI-test runner) and reuses the same assertions: connect to the mesh, join a
sector, and interop with the native VMs and browser phones. The wire and the bot are already
device-agnostic, so only the app-launch shim is new.
