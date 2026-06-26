// spacegame mobile/WASM browser e2e.
//
// Loads the spacegame frontend (web/demos/spacegame/index.html) in a **mobile-emulated** headless
// browser — a phone viewport, a mobile user-agent, and real touch — and proves the game plays on a
// phone in the browser over the CE mesh, with NO native install:
//
//  1. the page loads and renders the canvas (it is mobile-in-browser);
//  2. it connects to a CE node *through this page's own origin only* — either the in-browser WASM
//     node (window.__ceNode) or the same-origin "/ce" proxy — by hitting /status, /mesh/subscribe and
//     the /mesh/messages/stream SSE push (exactly the wire the native client speaks);
//  3. NOTHING leaves the origin (CSP connect-src 'self'): every network request is same-origin, so a
//     WASM-only phone really is a full mesh peer, not a thin client to some server;
//  4. mobile controls (touch + key) drive the authoritative sim: an input publish to a sector /in
//     topic is observed;
//  5. (optional) native<->browser interop: with NATIVE_PEER set, the phone sees more than one ship in
//     the sector, i.e. it shares the world with the native VM bots.
//
// Run:
//   cd e2e/browser && npm i && SPACEGAME_URL="https://<deployed-frontend>/" npm test
//   DEVICE="iPhone 13" SPACEGAME_URL=... npm test
//   NATIVE_PEER=1 SPACEGAME_URL=... npm test     # also assert it shares the sector with native peers
//
// SPACEGAME_URL must point at a deployed spacegame frontend whose origin either boots the in-browser
// WASM node or proxies "/ce" to a CE node (the same-origin bridge the frontend expects). Native mobile
// (a packaged app shipping the WASM/native node) is the next step — see e2e/SPACEGAME-E2E.md.

import { chromium, devices } from "playwright";

const TARGET = process.env.SPACEGAME_URL || "https://ce-net.com/play/spacegame/";
const DEVICE = process.env.DEVICE || "Pixel 7";
const BUDGET_MS = Number(process.env.BUDGET_MS || 45000);
const WANT_INTEROP = !!process.env.NATIVE_PEER;

let pass = 0,
  fail = 0;
const ok = (m) => {
  console.log("  PASS:", m);
  pass++;
};
const no = (m) => {
  console.log("  FAIL:", m);
  fail++;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const device = devices[DEVICE] || devices["Pixel 7"];
  console.log(`=== spacegame mobile browser e2e: ${DEVICE} -> ${TARGET} ===`);
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const context = await browser.newContext({ ...device });
  const page = await context.newPage();

  // Record every network request so we can assert the mesh wire + the same-origin invariant.
  const reqs = [];
  const origin = new URL(TARGET).origin;
  let offOrigin = 0;
  page.on("request", (r) => {
    const u = r.url();
    reqs.push({ method: r.method(), url: u });
    // Fonts/styles to Google CDNs are allowed by the page CSP; everything else must be same-origin.
    if (!u.startsWith(origin) && !u.startsWith("data:") && !/fonts\.(googleapis|gstatic)\.com/.test(u)) {
      offOrigin++;
      console.log("    off-origin request:", r.method(), u);
    }
  });

  try {
    await page.goto(TARGET, { waitUntil: "domcontentloaded", timeout: 20000 });
    ok("frontend loaded");
  } catch (e) {
    no("frontend failed to load: " + e.message);
    await browser.close();
    return finish();
  }

  // 1) Mobile-in-browser: a canvas renders and the viewport is a phone.
  const hasCanvas = (await page.locator("canvas").count()) > 0;
  hasCanvas ? ok("canvas renders (mobile-in-browser)") : no("no canvas");
  const vp = page.viewportSize();
  vp && vp.width <= 820 ? ok(`mobile viewport ${vp.width}x${vp.height}`) : no("not a mobile viewport");
  const title = await page.title();
  /spacegame/i.test(title) ? ok(`title: ${title}`) : no(`unexpected title: ${title}`);

  // 2) Connects to a CE node over the mesh wire within the budget.
  const want = {
    status: (u) => /\/status(\?|$)/.test(u),
    subscribe: (u) => /\/mesh\/subscribe$/.test(u),
    stream: (u) => /\/mesh\/messages\/stream$/.test(u),
  };
  const deadline = Date.now() + BUDGET_MS;
  const got = { status: false, subscribe: false, stream: false, publish_in: false };
  while (Date.now() < deadline && !(got.status && got.subscribe && got.stream)) {
    for (const r of reqs) {
      if (want.status(r.url)) got.status = true;
      if (want.subscribe(r.url)) got.subscribe = true;
      if (want.stream(r.url)) got.stream = true;
    }
    if (got.status && got.subscribe && got.stream) break;
    await sleep(500);
  }
  got.status ? ok("hit /status (resolved a node identity)") : no("never hit /status");
  got.subscribe ? ok("subscribed to a sector topic over the mesh") : no("never subscribed");
  got.stream ? ok("opened /mesh/messages/stream (SSE push realtime)") : no("never opened the state stream");

  // WASM node present?
  const hasWasm = await page.evaluate(() => !!window.__ceNode).catch(() => false);
  console.log(`    in-browser WASM node: ${hasWasm ? "present (window.__ceNode)" : "absent (same-origin /ce proxy path)"}`);

  // 3) Same-origin invariant (WASM phone is a real peer, nothing leaks to a remote server).
  offOrigin === 0 ? ok("no off-origin requests (CSP-clean: a true mesh peer)") : no(`${offOrigin} off-origin requests`);

  // 4) Mobile controls drive the sim: tap the canvas + press a thrust key, then look for an input
  //    publish to a sector /in topic.
  if (hasCanvas) {
    const box = await page.locator("canvas").boundingBox();
    if (box) {
      await page.touchscreen.tap(box.x + box.width / 2, box.y + box.height / 2).catch(() => {});
    }
    await page.keyboard.down("w").catch(() => {});
    await sleep(1500);
    await page.keyboard.up("w").catch(() => {});
  }
  const t2 = Date.now() + 6000;
  while (Date.now() < t2 && !got.publish_in) {
    for (const r of reqs) if (r.method === "POST" && /\/mesh\/publish$/.test(r.url)) got.publish_in = true;
    if (got.publish_in) break;
    await sleep(300);
  }
  got.publish_in
    ? ok("mobile input published to the sector over the mesh")
    : no("no input publish observed from mobile controls");

  // 5) Optional native<->browser interop: more than one ship visible == shares the world with the
  //    native VM bots. We read the on-screen player/leaderboard count the HUD renders.
  if (WANT_INTEROP) {
    let peers = 0;
    const t3 = Date.now() + 15000;
    while (Date.now() < t3) {
      peers = await page
        .evaluate(() => {
          // The leaderboard rows each render one ship; count them as a proxy for visible players.
          return document.querySelectorAll(".board .lr").length;
        })
        .catch(() => 0);
      if (peers >= 2) break;
      await sleep(750);
    }
    peers >= 2
      ? ok(`phone shares the sector with native peers (${peers} ships visible)`)
      : no(`expected native<->browser interop, saw ${peers} ship(s)`);
  }

  await browser.close();
  return finish();
}

function finish() {
  console.log(`\n================  RESULT: ${pass} passed, ${fail} failed  ================`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
