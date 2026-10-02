# Performance audit, round 3: the next 30 improvements (2026-10-02)

Owner topic t1 `396fe7e5`: "are we finnished with those improvements, if yes
we ned 30 more". Round 2 (`db-payload-audit-round2-2026-10-02.md`) put the
hub and the DB at about 1 % of time-to-Flow and said the seconds are in the
WUI. This round looks for them in the web app's first load, the network, and
warm loads.

This lane measures and proposes. It changes no product code. Each accepted
item becomes its own lane. §5 groups them so CLE-001 can run disjoint lanes
in parallel.

## 1. Answer

1. **We are not finished.** The biggest remaining cost is **latency, not
   bytes**. The signed-in first screen is a waterfall of about 6 import waves
   (entry -> page -> 30 small chunks -> locale -> layout CSS -> layout ->
   rail chunks). At 150 ms RTT that waterfall alone puts the rail at
   **2.27 s** with no hub involved. Declaring the pre-rail chunks up front
   (**P3-01**) cut that to **1.33 s** in a local A/B (n=5 interleaved,
   desktop and phone both about **-0.95 s**), with no regression unthrottled.
2. **A signed-out visitor boots the app twice.** `/` loads, probes the
   session (401), then hard-navigates to `/login`. That hop costs **301 ms
   desktop / 919 ms phone** (n=10, dev) and **1.29 s / 1.75 s on fast 4G**
   (n=5). Each visit also prefetches **98 app chunks (313 KB)** it cannot use
   yet. P3-02 and P3-04 fix both.
3. **On a phone the main thread is the rest.** In mock mode (no network
   cost), the rail takes **1.73 s at CPU 4x, with TBT 963 ms in 3 long
   tasks** (n=10). Profiling names a few concrete costs: forced layouts in the
   tenant label measure and the rail strip, the i18n catalogue deep copy, a
   `localeCompare` sort, and Vue render work for 917 DOM nodes (686 on
   desktop).
4. **The network edge is healthy.** Brotli, h2/h3, immutable `/_nuxt/**`,
   304 revalidation in ~20 ms and no web fonts. The two network gaps found
   are the edge cache MISS on the first fetch after a deploy, and one API
   call that goes through the hosting rewrite at 5x the direct latency.

## 2. How it was measured

- **Where:** the satellite (16 vCPU, load average 0.2..1.4 during every
  timed run, so these numbers are much less noisy than box-desk's load 70..100
  runs). Chrome 154 headless via puppeteer-core, `/usr/bin/google-chrome`.
  No Lighthouse: it is not installed. The rig is plain CDP; the scripts are
  in `perf-audit-round3-2026-10-02.harness.txt`.
- **Dev, deployed, read only, signed out** (`fl.mjs`). Profiles d1440 (no
  throttle) and m390 (CPU 4x, DPR 3). Caches: cold (cleared) and warm (same
  browser context, first round discarded). n=10 per profile x cache, plus
  fast 4G (150 ms RTT, 9 Mbit/s) n=5. Dev deployed
  **v6.6.7 `914d523a`** at 13:50Z, during the Chrome runs;
  bytes per load stayed 609..610 KB in every cold round. 1 of 41 rounds hit
  the 30 s navigation timeout (`m390 warm 0`, discarded).
- **Why not signed in on dev:** the first-load harnesses
  (`do_spl_wui_perf_first_load[_net]`) need the dev m3-e2e credential. The
  satellite does not hold it, and minting one would mutate dev (same as
  round 2).
- **Signed-in path in mock mode** (`mk.mjs`). `NUXT_PUBLIC_USE_MOCK=1 nuxt
  generate` on trunk `7155116a`, served by `tests/e2e/lib/serve-hosting-h2.mjs`
  (TLS + h2, Hosting's headers). Mock runs the real WUI code with in-browser
  data, so it isolates **JS + render + chunk loading** from the hub. Timed:
  navigation -> rail Flow tab visible -> first Flow entry visible after a
  click. n=10 cold per profile, plus fast 4G n=5. Mock caveats:
  `plugins/0.boot-early` returns early in mock mode, so mock fetches the
  default layout one wave later than live does. Chrome never HTTP-caches a
  self-signed origin, so mock "warm" equals cold and is not reported.
- **CPU profile** (`prof.mjs`): V8 sampling profiler, m390 CPU 4x, n=3.
  Positions are mapped through a sourcemapped build of the same tree (the
  vendor chunks hash identically).
- **Bundle** (`attr.cjs`): a live-config `nuxt generate` with
  `NUXT_CLIENT_SOURCEMAP=true` on `7155116a`; gzip -9 per file. Package-level
  bytes are reliable. Per-app-file bytes overcount sparse files, so only
  whole-chunk numbers are quoted for app code.
- **curl** for headers, compression and per-endpoint TTFB (n=10 each), and
  one pass over every `/_nuxt` asset the document names (n=99).

## 3. What a first load costs today

### 3.1 Dev, signed out (`/` -> `/login`), p50 / p90

| profile, cache | n | hop `/` -> `/login` ms | login visible ms | TBT ms | requests on the wire | KB on the wire | of which prefetch |
|---|---|---|---|---|---|---|---|
| d1440 cold | 10 | 301 / 310 | 475 / 506 | 8 / 12 | 165 / 172 | 609 / 611 | 98 req, 313 KB |
| d1440 warm | 10 | 227 / 246 | 427 / 462 | 0 / 4 | 31 / 36 | 2.6 | 0 |
| m390 cold (CPU 4x) | 10 | 919 / 1 019 | 1 293 / 1 411 | 299 / 317 | 137 | 609 / 610 | 98 req, 313 KB |
| m390 warm (CPU 4x) | 9 | 887 / 4 984 | 1 263 / 5 348 | 281 / 321 | 8 / 136 | 2.4 | 0 |
| d1440 cold, fast 4G | 5 | 1 290 / 3 340 | 1 673 / 3 736 | 2 / 4 | 134 | 609 | 98 req, 313 KB |
| d1440 warm, fast 4G | 5 | 478 / 490 | 795 / 834 | 1 / 3 | 5 | 2.6 | 0 |
| m390 cold, fast 4G | 5 | 1 747 / 1 813 | 2 214 / 2 269 | 299 / 359 | 134 | 609 | 98 req, 313 KB |
| m390 warm, fast 4G | 5 | 1 064 / 1 097 | 1 508 / 1 537 | 275 / 286 | 5 | 2.6 | 0 |

- "Login visible" = the hop + the LCP of the `/login` document. Every round
  loads **2 documents and probes `auth/session` twice** (2 x 401).
- The first `auth/session` probe starts **166..214 ms (desktop) and
  603..645 ms (phone) after navigation start**, p50 over n=10 warm/cold. That
  is the time to fetch, parse and run the entry chunk before
  `plugins/0.boot-early` can fire it.
- The warm network work: 2 documents answered 304 (~269 B each), 2 session
  401s, and `GET /api/v1/checkout/plan` (1.7 KB, `max-age=0`).

### 3.2 Mock (no hub), the signed-in first screen, p50 / p90

| profile | network | n | rail ms | Flow entry ms | TBT ms | long tasks | DOM nodes | requests / KB |
|---|---|---|---|---|---|---|---|---|
| d1440 | none | 10 | 421 / 429 | 490 / 497 | 75 / 82 | 2 | 686 | 225 / 602 |
| m390 CPU 4x | none | 10 | 1 733 / 1 851 | 1 995 / 2 115 | 963 / 1 021 | 3..4 | 917 | 229 / 612 |
| d1440 | fast 4G | 5 | 2 174 / 2 242 | 2 516 / 2 589 | 64 / 74 | 2 | 686 | 225 / 602 |
| m390 CPU 4x | fast 4G | 5 | 3 153 / 3 248 | 3 588 / 3 677 | 906 / 945 | 3..4 | 917 | 229 / 612 |

The 4G rail sits **1.75 s** behind the unthrottled one with no API call at
all. 602 KB at 9 Mbit/s is ~0.53 s, so most of the rest is round trips.
`crit.mjs` lists **99 non-prefetch JS/CSS requests before the rail** (60
scripts, the rest CSS), discovered in waves at 12, 77, 120, 165, 197,
232..250 and 259 ms on an unthrottled local load:

- 12 ms: the 3 entry chunks;
- 77 ms: the index page chunk + 8 component CSS;
- 120 ms: ~30 small shared chunks;
- 165 ms: the `en` catalogue (`DNmIDiBC.js`, 88 KB raw / 19.5 KB gzip);
  it is in neither the prefetch nor the modulepreload list;
- 232..239 ms: 12 layout/shell CSS files;
- 250 ms: the default layout chunk (38.7 KB gzip, prefetched at lowest
  priority but needed here);
- 259 ms: 24 more rail chunks.

The CLE-77934 dev numbers (rail 3.3 s / Flow 5.0 s desktop, n=10,
`22341ea9`) were taken at box load 71..100. This idle-box mock puts the
desktop rail at 0.42 s. Signed-in dev on an idle box (§6) is the number that
tells how much of the remaining gap is hub round trips and how much was box
load.

### 3.3 Where the phone's main thread goes (mock, m390 CPU 4x, n=3, self ms)

| where | self ms | source (via sourcemap) |
|---|---|---|
| Vue runtime (vendor chunk `CAS2KkcB`) | 650 | `callWithErrorHandling` 56, `renderComponentRoot` 29, reactivity get/set/`createReactiveObject`/`refreshComputed` ~82, vue-router matcher (`m` 22, `tokensToParser` 10) |
| native (style, layout, compile) | 564 | `(program)` |
| entry chunk `C_qNe62M` | 311 | `tenant-switcher.mjs:194 measureControlText` **38**, nuxt `pages/runtime/utils.js:18` (route key) 33, `live-follow.mjs:272` (DM row sort, `localeCompare`) 31 |
| i18n chunk `BDhL0fxz` | 108 | `@intlify/shared` `key` 29 + `deepCopy` 15, `translate` 9 |
| default layout `CllyqArx` | 105 | `topic-in.mjs:144` 36 (attributed), `useLoopStrip.ts:28 measure` 15 |

### 3.4 Bundle (live config, `7155116a`)

- **Initial JS:** 3 chunks, 443 KB raw / ~151 KB gzip (budget 155). By
  package: @vue/runtime-core 59 KB, nuxt 29, vue-router 27, `routes.mjs` 25,
  @nuxtjs/i18n 18, @vue/reactivity 18, runtime-dom 16, unhead 15,
  @intlify/core-base 15, vue-i18n 14; app code ~184 KB raw. A **live** build
  carries `src/utils/mock-data.mjs` in it, through the static `cloneMock`
  import in `utils/spool-client.mjs:3`.
- **Documents:** `index.html` 52.9 KB raw / 12.5 KB gzip (10.6 KB br on the
  wire). Of that: 35.7 KB inline `<style>`, 96 prefetch links (7.0 KB),
  39 hreflang alternates (1.9 KB) on a `noindex` app, 6.1 KB inline script.
- **`en` catalogue:** 1 271 messages, of which 1 123 have no placeholder.
  34 KB of text compiles to an 88 KB AST chunk (`{t:0,b:{t:2,i:[{t:3}],s:"…"}}`
  per message). The first-screen namespaces (common, sidebar, feed, composer,
  channels, notify) hold 408 of the 1 271 keys.
- **Largest lazy chunks:** markdown-it + `entities` + linkify-it 111 KB raw /
  49.0 KB gzip (already lazy, `utils/markdown.mjs`); default layout 38.7 KB
  gzip; @headlessui/vue + @tanstack/virtual-core 16.6 KB gzip.
- **No web fonts** (system stacks); **service worker** has no fetch handler
  (`src/public/sw.js`: notification click only, and it deletes every cache on
  activate).

### 3.5 Network edge (curl, n=10 per row unless noted)

| request | TTFB p50 / p90 ms | headers |
|---|---|---|
| document, edge HIT | 21 / 24 | br, `max-age=0, must-revalidate`, ETag; 304 in 20..22 ms (n=5) |
| document, edge MISS (first after deploy) | 222 (n=1) | `x-cache: MISS`, origin 194 ms |
| every `/_nuxt` asset, first fetch at this POP | 90 / 222, max 259 (n=99) | br, `max-age=31536000, immutable` |
| API host `auth/session` (401) | 24 / 28 | |
| API host `auth/providers` | 24 / 29 | `private, max-age=300` |
| API host `v1/wui/revision` | 25 / 27 | |
| WUI host `api/v1/checkout/plan` (hosting rewrite) | **120 / 144** | `max-age=0, must-revalidate`, edge MISS |
| WUI host `api/v1/auth/session` (hosting rewrite) | 112 / 138 | |
| CORS preflight to the API host | 23..26 (n=3) | `access-control-max-age: 7200` |

Caveat: from this satellite, ~9 of ~40 fresh TCP connects to the hosting edge
in one burst timed out at 10 s (and one curl hung 134 s). That is this VM's
path to the edge, not a product defect; the browser reuses one h2 connection.
It explains the long p90 tails in §3.1.

## 4. The 30 improvements, ranked

Not re-proposed (already landed): the prefetch removal and revert (CLE-77933
`f1f23689` / `94f46ac6`), no mock-module prefetch (`28e257b3`), the manifest
link after ready (`bfb770a6`), lazy rail tabs (CLE-77934 `0d43d7a8`), the
CLE-77925 initial-JS cuts, image formats (CLE-77966), and round 2's R2-1..R2-5.

**Top 10 in bold.** "Collides" names the items that edit the same file. Those
belong in one lane, or must run one after another.

| id | what | measured cost today (n) | expected gain | files | risk | collides |
|---|---|---|---|---|---|---|
| **P3-01** | **Declare the first screen's critical chunks up front**: from the build manifest, emit `modulepreload` for the scripts and `preload` for the CSS the first screen executes before the rail (the `en` catalogue and default layout included), per document, and stop prefetching those same files. Generate the list from the manifest, never hand-keep it | mock rail fast 4G **2 271 / 2 289 ms** desktop, **3 252 / 3 289** phone; 99 JS/CSS requests in ~6 waves before the rail (A/B, n=5 interleaved) | **rail -942 ms desktop, -959 ms phone on 4G** (A/B variant: 1 329 / 2 293 ms; Flow -944 / -945 ms); unthrottled -51 / -144 ms, no regression | `csi-spl-wui/nuxt.config.ts` (`build:manifest` / `render:html` hook), a unit test beside `tests/unit/prefetch-mock-modules*` | low-medium: a stale list over-fetches; the live gain is smaller by the layout wave `0.boot-early` already parallelises | P3-04, P3-22, P3-23, P3-24, P3-19, P3-21, P3-02, P3-03 (`nuxt.config.ts`) |
| **P3-02** | **Signed-out early redirect**: a non-HttpOnly hint cookie (set on sign-in, cleared on sign-out/401) read by an inline head script, like the root-locale one. No hint on a product screen -> `location.replace('/login?redirect=…')` before any JS loads. A stale hint falls back to today's path | hop `/`->`/login` **301 / 919 ms** (desktop / phone, n=10), **1 290 / 1 747 ms** fast 4G (n=5); 2 documents + 2 session probes per signed-out visit | login form **-0.3 s desktop, -0.9 s phone, -1.3..1.7 s on 4G**; one session probe and one app boot fewer | `nuxt.config.ts` (head script + CSP hash), `src/utils/signed-out-redirect.mjs`, `src/middleware/signed-out-redirect.global.ts`, `src/utils/auth-client.mjs` | medium: the hint must never send a signed-in reader to /login (fallback = today); CSP inline hash | P3-03, P3-17, P3-01 |
| **P3-03** | **Start the session probe from the document**: an inline head script fires `fetch(<api>/api/v1/auth/session, {credentials:'include'})` at parse time and parks the promise on `window`; `utils/early-session.mjs` adopts it instead of starting its own | first probe starts **166..214 ms desktop, 603..645 ms phone** after navigation (p50, n=10) | the signed-in chain (session -> route -> channels/roster -> Flow) starts **~0.2 s (desktop) / ~0.6 s (phone) earlier** | `nuxt.config.ts` (head), `src/utils/early-session.mjs`, `src/plugins/0.boot-early.client.ts` | low-medium: CSP connect-src already allows the API host; the tenant/API base must be baked per env (it already is via NUXT_PUBLIC_*) | P3-02, P3-17, P3-01 |
| **P3-04** | **No app prefetch on signed-out documents until the form is usable**: drop the 96 prefetch links from `/login` (and any doc that P3-02 sends there) and inject them on idle after the form renders, so a sign-in still finds a warm cache | signed-out cold: **98 prefetch requests / 313 KB** of 609 KB (n=10); cold-vs-warm hop on 4G 1 290 vs 478 ms (n=5), mostly download contention | login visible on cold 4G **up to ~-0.5 s** (estimate, A/B it); -313 KB before the form | `nuxt.config.ts` hook, a small idle-injector plugin (`src/plugins/`) | low | P3-01 |
| **P3-05** | **Break the phone's first-screen long tasks**: mount the rail's visible tab and the Flow panel first, then yield (`scheduler.yield` / rAF) before the rest of the frame (other sections, avatars, toasts, pane widths) | mock m390 CPU 4x: **TBT 963 / 1 021 ms, 3..4 long tasks**, rail 1 733 ms (n=10) | TBT **-40..60 %** on phone; rail paint earlier by the deferred part (target < 1.3 s mock) | `src/components/ChannelSidebar.vue`, `src/layouts/default.vue` | medium: e2e tests that read rail DOM at once (see `1b04caf7`) | P3-09, P3-11 |
| **P3-06** | **Split the `en` catalogue**: the first-screen namespaces (408 keys) load with the entry and the rest (settings, checkout, tenant_settings, users, issues*, search, help, …) with their pages, for all 19 locales | `en` 88 KB raw / 19.5 KB gzip, requested at wave 4 (165 ms local); i18n `deepCopy`+`key` 44 ms CPU 4x (n=3) | ~-12 KB gzip and ~-60 KB raw parse off the critical path; i18n CPU roughly x0.35 | `csi-spl-wui/i18n/locales/*.json` (19), `nuxt.config.ts` i18n block, a namespace loader | medium: a missed key renders as its key; needs a build-time check that every `t()` key is in a loaded namespace | P3-13, P3-20, P3-01 |
| **P3-07** | **Measure the tenant labels without forced layouts**: one canvas `measureText` with the computed font (or every label in one probe, one reflow) instead of a probe span + `getComputedStyle` per label | `measureControlText` **38 ms self CPU 4x** (n=3) plus the layouts it forces (counted in the 564 ms native) | ~-40..80 ms phone main thread at mount | `src/utils/tenant-switcher.mjs`, `src/components/TenantDropBox.vue` | low: canvas text width can differ by sub-pixels; keep the existing pad | — |
| **P3-08** | **Warm the edge after each deploy**: a named action fetches every new document and `/_nuxt` file once (br + gzip) right after the hosting deploy, for dev and prd | first fetch after deploy: document **222 ms MISS vs 21 ms HIT**; assets **90 / 222 ms** (n=99) | the first readers after a deploy skip ~0.1..0.2 s per wave. It warms only the POPs the runner reaches, so add a second warm-up from the satellite (same region as readers) | `.github/workflows/30_wui-build-deploy.yml`, new `csi-spl-iac/src/bash/run/warm-wui-edge.func.sh` + test | low | — |
| **P3-09** | **Do not mount phone-only hidden UI at first paint**: sheets, backdrops and mobile chrome render on first open | DOM **917 nodes phone vs 686 desktop** (mock, n=10); Vue runtime 650 ms self CPU 4x (n=3) | ~-25 % phone nodes; a share of the 650 ms | `src/layouts/default.vue` and the mobile sheet components it mounts | low-medium: an open-on-load route (`?sheet=`) must still work | P3-05 |
| **P3-10** | **Service worker app shell for warm loads**: cache the prerendered documents and the current build's entry chunks, answer navigations cache-first and revalidate in the background (navigation preload on), keyed by `build.json` so a deploy swaps the shell | warm hop/doc revalidation on 4G **478 ms** desktop, phone visible 1 508 ms (n=5); every warm load = 2 x document 304 | warm load **-1 RTT per document** (~-150..300 ms on 4G); offline shell | `src/public/sw.js`, `src/plugins/pwa.client.ts` | medium-high: a stale shell after deploy; the SW deliberately deletes caches today | P3-04 (plugin dir only) |
| P3-11 | `useLoopStrip.measure` reads `getBoundingClientRect` of every rail control during mount: run it in the next frame / from a ResizeObserver | 15 ms self CPU 4x + forced layout (n=3) | ~-15..30 ms phone | `src/composables/useLoopStrip.ts`, `src/components/ChannelSidebar.vue` | low | P3-05 |
| P3-12 | DM row sort with `a.label.localeCompare(b.label)`: one shared `Intl.Collator` (and the same for the other rail sorts) | 31 ms self CPU 4x attributed to `live-follow.mjs:272` (n=3) | ~-25 ms phone | `src/utils/live-follow.mjs` | low: collator options must equal today's order | — |
| P3-13 | vue-i18n deep-copies the catalogue on load: hand it the messages without the copy (`messages` at creation / a frozen object) | `@intlify/shared deepCopy` 15 + `key` 29 ms CPU 4x (n=3) | ~-30 ms phone; less after P3-06 | i18n options in `nuxt.config.ts` / the locale loader | low-medium | P3-06, P3-20 |
| P3-14 | Register the locale route copies for the ACTIVE locale only (and the rest on a locale switch), instead of rebuilding all 31 x 19 = 589 records at router creation (`expandLocaleRoutes`, `ab44e978`) | vue-router matcher build `m` 22 + `tokensToParser` 10 ms CPU 4x (n=3) | ~-25 ms phone at router creation | `src/app/router.options.ts`, `src/utils/locale-routes.mjs` | medium: hreflang/locale links to a not-yet-registered route | P3-16 |
| P3-15 | Take `mock-data.mjs` out of the live initial JS: the static `cloneMock` import in `spool-client.mjs:3` and `MOCK_LOBBY_TASK_ID` in `useLive.ts` become mock-mode dynamic imports (line 738 already does this for `MOCK_CLONES`) | in the live initial chunk (attributed 4.4 KB raw, n=1 build) | ~-1..1.5 KB gzip initial, headroom under the 155 KB budget | `src/utils/spool-client.mjs`, `src/composables/useLive.ts` | low | P3-30 |
| P3-16 | `routes.mjs` is 25 KB raw of the initial JS: move per-page meta that only the page needs into the page chunk, drop unused route names/aliases | 25 KB raw in initial (n=1 build) | ~-3..5 KB gzip initial | page `definePageMeta` blocks, `nuxt.config.ts` `localeRouteCopiesModule` | low-medium | P3-14, P3-01 |
| P3-17 | (only if P3-02 is not done) carry the signed-out 401 across the hard redirect in `sessionStorage` (30 s) so `/login` does not probe again | 2 session probes per signed-out visit (n=10, every round) | -1 API round trip (~24 ms + phone JS) | `src/utils/early-session.mjs`, `src/middleware/signed-out-redirect.global.ts` | low | P3-02, P3-03 |
| P3-18 | `GET /api/v1/checkout/plan` on the login page goes through the hosting rewrite and is uncached: serve it edge-cacheable (`public, s-maxage=300`) or call the API host directly | **120 / 144 ms** via the rewrite vs 24 ms direct for its neighbours (n=10); fetched on every login view, warm too | -~100 ms for the plan line; -1 origin hit per view | hub checkout handler (`csi-spl-api/.../hub/`), the WUI login page's caller | low: price changes reach readers up to 5 min later | — |
| P3-19 | markdown-it pulls the full `entities` table (21 KB raw): alias the entity decoder to a tiny DOM-based one in the browser build | markdown chunk **49.0 KB gzip** (n=1 build), loaded with the first message that has a block | ~-8 KB gzip on that chunk | `nuxt.config.ts` (vite alias), `src/utils/markdown.mjs` | low-medium: the node tests import markdown.mjs directly (keep the full decoder there) | P3-01 |
| P3-20 | Ship placeholder-free messages as plain strings instead of compiled AST (1 123 of 1 271) | 34 KB of text -> 88 KB AST chunk (n=1 build) | ~-30 KB raw / a few KB gzip per locale chunk, less parse | i18n build options (`nuxt.config.ts` i18n block) | medium: confirm the runtime-only vue-i18n resolves a plain string without the message compiler; if it needs the compiler, drop this item | P3-06, P3-13 |
| P3-21 | Vue compile-time flags: `__VUE_OPTIONS_API__: false` and `__VUE_PROD_HYDRATION_MISMATCH_DETAILS__: false` (no `export default {}` component found in `src/components`, `src/pages`, `src/layouts`) | runtime-core 59 KB raw in initial (n=1 build) | I believe, unchecked, ~-4..8 KB raw initial | `nuxt.config.ts` (`vite.define`) | medium: any dependency using the Options API (check vue-i18n legacy mode and @headlessui) breaks at runtime; e2e must cover it | P3-01 |
| P3-22 | Document head diet: drop the 39 hreflang alternates and the canonical link on a `noindex, nofollow` app | 1.9 KB raw per document (n=1 build), every document | ~-0.4 KB br per document | i18n SEO head options (`nuxt.config.ts` / `useLocaleHead`) | low | P3-01 |
| P3-23 | Merge the first screen's component CSS: 20 stylesheets are requested by JS before the rail, in 2 waves | 20 CSS requests before the rail (local load, n=1); `default.css` 6.7 KB gzip arrives at wave 6 | -~18 requests, CSS no longer gates the layout wave | `nuxt.config.ts` (CSS chunking for first-screen components) | low-medium: style order changes | P3-01, P3-24 |
| P3-24 | Group the ~30 tiny first-screen chunks of the 120 ms wave (most < 1 KB) into one `first-screen` manual chunk | 60 scripts before the rail, ~30 of them in one wave (n=1) | fewer module records + requests; on top of P3-01, ~-1 wave | `nuxt.config.ts` (`manualChunks`) | medium: a too-wide group pulls code into the first screen; watch ci_initial_gzip_kb | P3-01, P3-23 |
| P3-25 | V8 explicit compile hints for the entry chunks (`//# allFunctionsCalledOnLoad`), so Chrome compiles them eagerly on a background thread | native time 564 ms CPU 4x incl. compile; first plugin runs 603..645 ms after navigation on phone (n=10) | I believe, unchecked, -30..100 ms phone; A/B it | a rollup `banner`/`renderChunk` for the entry chunks in `nuxt.config.ts` | low: Chrome-only, ignored elsewhere | P3-01 |
| P3-26 | `topic-in.mjs` runs at mount (the composer parses its draft on render): defer parsing to the first input | 36 ms self CPU 4x attributed to `topic-in.mjs:144` (n=3; attribution only, confirm with a sourcemapped profile first) | ~-30 ms phone | `src/utils/topic-in.mjs`, `src/components/MessageComposer.vue` | low | — |
| P3-27 | Nuxt route-key generation shows 33 ms self (`nuxt/dist/pages/runtime/utils.js:18`, interpolatePath): give the first-screen pages a static `key` in `definePageMeta` | 33 ms self CPU 4x (n=3) | ~-25 ms phone | `src/pages/index.vue` (+ the other first-screen pages) | low-medium: a static key changes when a page re-mounts on param change | P3-16 |
| P3-28 | Root-locale redirect at the edge: a non-English browser on `/` takes a second document hop (`location.replace('/<locale>')` in the head). Hosting's i18n rewrites could serve the right prerendered document at once | not measured (headless runs are `en`); 1 extra document request per non-`en` first visit | -1 document RTT (~20..300 ms) for every non-English first visit | `csi-spl-wui/firebase.json` (rendered per env), `nuxt.config.ts` root-locale script | medium: the cookie choice must still win over Accept-Language | P3-01 |
| P3-29 | Move the notification / error-journal machinery out of the initial JS into `onNuxtReady` dynamic imports (`stores/notification.ts`, `utils/notify.mjs`, `composables/errorJournal.mjs` and their plugins) | in the initial chunk (attributed ~5..6 KB raw each, n=1 build) | ~-4..6 KB gzip initial | `src/plugins/notify.client.ts`, `src/plugins/error-journal.client.ts`, `src/stores/notification.ts` | medium: an error in the first 0.5 s must still be journaled (buffer it) | — |
| P3-30 | Finish the `spool-client.mjs` split CLE-77925 started: it is still the largest app module in the initial JS. Keep the first-screen reads, and move the writers/admin paths behind dynamic imports | largest app source in the initial chunk (attributed 34 KB raw, n=1 build) | ~-5..8 KB gzip initial | `src/utils/spool-client.mjs` + its importers | medium: every caller of a moved helper must await it | P3-15 |

## 5. Parallel lanes (files that do not overlap)

| lane | items, in order | shared file |
|---|---|---|
| A, document + build | P3-01, then P3-04, P3-23, P3-24, P3-22, P3-25, P3-19, P3-21 | `csi-spl-wui/nuxt.config.ts` |
| B, session and redirect | P3-03, then P3-02 (P3-17 only if P3-02 is dropped) | `nuxt.config.ts` head + `early-session.mjs`. Put the inline scripts in their own `src/utils/*-script.mjs`, so lane A's edit is a one-line import |
| C, i18n | P3-06, then P3-13, P3-20 | `i18n/locales/*`, the i18n block |
| D, rail runtime | P3-05, P3-09, P3-11 | `ChannelSidebar.vue`, `layouts/default.vue` |
| E, router | P3-14, P3-16, P3-27 | `router.options.ts`, page meta |
| F, initial-JS trims | P3-15, P3-30, P3-29 | `spool-client.mjs`, plugins |
| independent, one lane each | P3-07, P3-08, P3-10, P3-12, P3-18, P3-26, P3-28 | — |

Every WUI item re-checks `ci_initial_gzip_kb` (budget 155) and runs the WUI
gate (`pnpm run typecheck`, `BASE_URL=<bundle> pnpm run test:e2e`). P3-01,
P3-02, P3-03 and P3-04 each prove their gain with an A/B:
`do_spl_wui_perf_first_load` `LOCAL_MAP` / `LOCAL_MAP_B`, or this
round's `mk.mjs` / `fl.mjs`.

## 6. Not measured, and what it needs

- **Signed-in timings on dev on an idle box.** The satellite has no dev
  m3-e2e credential; minting one mutates dev. With it,
  `ENV=dev do_spl_wui_perf_first_load` here (load ~1) would show how much
  of CLE-77934's 3.3 s rail was box load. That number should come before
  P3-03's gain is quoted for live.
- **prd.** Every number here is dev or local. Prd t1 is refused by the
  harnesses by design; prd e2e needs the owner's go.
- **WS and live data after the Flow list** (CLE-77934's ~1.9 s of microtasks
  after Flow): mock mode shows 0 long-task ms after the Flow entry (n=10), so
  that cost is in live data handling and needs the signed-in run.
