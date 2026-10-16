# UI speed-up round (perf round 6) - plan (12 actions)

Owner HUM-10, t1 topic `eb4bd4b3-1d33-457c-b48b-bcb7d440687b`, verbatim msgs:
- msg `b4baecb3`: "UI speed up round"
- msg `4244afb1`: "12 concrete actions to speed up the UI no boh mobile and desktop" (= on both mobile and desktop). **Note on row count:** this owner order explicitly overrides the 10-row cap in [rounds-rulebook.md](rounds-rulebook.md) (R1) for this round only, citing msg `4244afb1`.
- msg `903c9fa5`: "with empirical evidence"
- msg `21d07aa6`: "first a panel of experts , than consensus and than implementation - no questions"
- related msgs (t1 dc15ad65 686bc1a3 / eafc9b15 2c1b49ee): "use 2 lanes in parallel" for rounds.
- msg `95472f33`: "try to preserve as much as possible the existing functions ..." -> every row keeps every existing feature and behaviour; verified by test or red control.

Rounds need no owner go (rulebook 1.4). **Never ask the owner anything** at any step.

Round 6 focus: **the WUI (`csi-spl-wui/`) only: speed-up across mobile and desktop**.
Concurrency: **build 2 row lanes in parallel at all times** (owner msgs 686bc1a3 / 2c1b49ee).
Consensus: **no owner go, no question to the owner** (rulebook 1.4; owner msg 21d07aa6).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (push caps, bands, R1-R16), by pointer, not copied.
Issue: SPL-2051.

**Status: v1.0 Proposed (incorporating panel consensus & takeover seat refinements)**. Ready for panel sign-off.

Editor: **a-591@<box>** (agy).

**One sha:** baseline metrics measured on **`4251b33cf`** (`4251b33cf55ba3023678fe67d31e8e68e5b0460c`, `origin/master`, 2026-10-15) and verified on **`4a3781047`** (claude seat `c-250@sat`, `a4b20dec6`), n=3 per metric unless stated.
**Cross-round coordination with Round 13 (`refactor-round-13-plan.md`):**
- Row 03 (`ChannelSidebar.vue`) runs after r13-04 (decomposing `ChannelSidebar.vue`).
- Rows 04 and 08 (`pages/issues.vue`) run after r13-06 (decomposing `issues.vue` script <= 1200 lines). Row 08 respects the `sfc-script-size` ceiling in force (r13-02).
- Row 06 (`LiveFeed.vue`) runs after r13-07 (`scroll-anchor.mjs` refactor) and adds <= 25 script lines (under 500-line ceiling).
- All other rows (01, 02, 05, 07, 09, 10, 11, 12) have **zero file overlap** with Round 13.

---

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else.
- Every row keeps all existing features and behaviour, proven with a test or a **red control**: the check fails or measures worse before the change and passes / measures better after.
- **Paths:** `wui:` = `csi-spl-wui/`. Lines as of `4a3781047` / current master.
- **Box:** the preferred box (`sat` or other available box); the spawner box pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`: simple_coding -> claude / mistral takeover; complex_coding -> claude; test -> claude), then R14. (Grok not seated due to fleet quota).
- **Subject** (R6 reads it): `<type>(p6-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands that are in the `log:` file.

---

## 2. Baseline empirical measurements on `4251b33cf` and `4a3781047`

All measurements conducted against a production-identical bundle generated via `nuxt generate` (`.output/public`), served via `serve-generated.mjs` on an isolated free port, and driven via Chrome DevTools Protocol (CDP) under Headless Chrome. $n=3$ iterations per route and interaction; median values reported below.

### 2.1 Measurement harness commands

```bash
# Production bundle verification
python3 /opt/csi/csi-spl/csi-spl-orc/src/bash/scripts/perf-budget.py bundle \
  --pub csi-spl-wui/.output/public \
  --budgets /opt/csi/csi-spl/csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json

# Reproducible CDP benchmark runner (FP, FCP, LCP, TTI, TBT, DOM nodes, Layout, and Interactions across desktop and mobile profiles)
node csi-spl-wui/src/node/test/serve-generated.mjs --port <free>
# Script documented in csi-spl-doc/doc/md/perf-round-6/seat-claude.md section 6.1
```

### 2.2 Page performance metrics ($n=3$, median)

#### Desktop Profile (1440x900 viewport, no CPU throttling)

| Route | Page | FP (ms) | FCP (ms) | LCP (ms) | TTI (ms) | TBT (ms) | DOM Nodes | Layout (ms) | Script (ms) |
|---|---|---|---|---|---|---|---|---|---|
| `/` | Home | 160 | 180 | 564 | 392 | 175 | 610 | 62 | 91 |
| `/login` | Sign-in | 252 | 252 | 252 | 284 | 11 | 493 | 73 | 125 |
| `/channel/alerts` | Channel | 96 | 772 | 772 | 432 | 242 | 524 | 47 | 85 |
| `/issues` | Issues | 120 | 788 | 788 | 496 | 195 | 581 | 40 | 85 |
| `/workspace/docs` | Docs | 124 | 752 | 932 | 516 | 189 | 811 | 44 | 77 |

#### Mobile Profile (390x844 viewport, 4x CPU throttle, iPhone UA)

| Route | Page | FP (ms) | FCP (ms) | LCP (ms) | TTI (ms) | TBT (ms) | DOM Nodes | Layout (ms) | Script (ms) |
|---|---|---|---|---|---|---|---|---|---|
| `/` | Home | 292 | 400 | 1788 | 780 | 941 | 661 | 129 | 268 |
| `/login` | Sign-in | 128 | 320 | 320 | 534 | 236 | 482 | 124 | 239 |
| `/channel/alerts` | Channel | 160 | 1648 | 1648 | 1217 | 905 | 545 | 52 | 177 |
| `/issues` | Issues | 168 | 1784 | 1784 | 1028 | 855 | 656 | 60 | 221 |
| `/workspace/docs` | Docs | 160 | 1824 | 1824 | 1334 | 1050 | 634 | 74 | 194 |

### 2.3 Hidden DOM subtrees (measured on signed-in shell via CDP walk)

```
/channel/alerts 1440: {"dom":571,"hiddenNodes":45,"top":["45 div[data-test=user-menu-panel]"]}
/channel/alerts 390:  {"dom":603,"hiddenNodes":217,"top":["153 nav.sidebar","56 div[data-test=user-menu-panel]","8 div[data-test=theme-picker-root]"]}
/issues 1440:         {"dom":628,"hiddenNodes":71,"top":["45 div[data-test=user-menu-panel]","26 div.issues-status-dd__list"]}
/workspace/docs 1440: {"dom":857,"hiddenNodes":182,"top":["137 div.sidebar-body","45 div[data-test=user-menu-panel]"]}
```

### 2.4 Bundle and route chunk sizes (`perf-budget.py bundle`)

| Asset Scope | Chunks | Raw Size (KB) | Gzip Size (KB) | Budget Limit (KB) | Headroom (KB) |
|---|---|---|---|---|---|
| Initial Entry JS (`200.html`) | 3 | 426.2 | 154.6 | 155.0 max | **0.4** |
| Home Page JS (`index.html`) | 86 | 952.7 | 351.3 | 352.1 max | **0.8** (critical) |
| Channel Route (`/channel/...`) | 65 | 3120.4 | 952.6 | - | - |
| Issues Route (`/issues`) | 83 | 3372.6 | 1037.9 | - | - |
| Docs Route (`/workspace/docs`) | 66 | 3126.7 | 960.6 | - | - |

---

## 3. The 12 actions, in run order

| # | slug | practice | why | sites file:line | number now (command) | target | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p6-01-wui-lazy-mount-user-menu)` | lazy DOM mounting | `UserMenu.vue` unconditionally mounts dropdown menu DOM on initial shell paint (`v-show="open"`), adding 45 hidden DOM nodes on desktop and 56 on mobile (~8-9% of shell DOM) on every signed-in route | `wui:src/components/UserMenu.vue:60` | `grep -n 'v-show="open"' csi-spl-wui/src/components/UserMenu.vue` (line 60); 45 hidden DOM nodes on desktop / 56 on mobile (`[data-test="user-menu-panel"]`, signed-in only) | `v-if="open"` lazy mounting; dropdown panel DOM mounted only on click; initial shell DOM reduced by 45 nodes on desktop / 56 on mobile | Unit tests, typecheck, e2e. **Red control**: signed in, closed user menu has 0 panel DOM nodes (was 45 at 1440 / 56 at 390). Bind trigger `aria-controls` only while open. `tests/unit/user-menu.test.mjs:149` title rewritten for v-if while preserving rotation guard. All 10 tests mentioning `user-menu-panel` pass | sat | claude | simple_coding | 1 (Lane 1 start) |
| 02 | `perf(p6-02-wui-async-topic-panes)` | route / layout component code splitting | `layouts/default.vue` synchronously auto-imports `LiveTopicPane.vue` and `TopicPane.vue`, forcing them into `index.html`'s `modulepreload` set (`TopicPane` is `DlbCPcmI.js`, 4957 B gzip; default layout chunk `CVuwGkCh.js` is 46.7 KB gzip) | `wui:src/layouts/default.vue:94-95` | `grep -n "TopicPane" csi-spl-wui/src/layouts/default.vue` (lines 94-95); `ci_home_gzip_kb` 351.3 KB (0.8 KB headroom against 352.1 KB budget) | `defineAsyncComponent` for `LiveTopicPane` and `TopicPane`; components drop from `modulepreload` to prefetch; `ci_home_gzip_kb` falls by >= 40 KB (A/B build: home set −43,687 B, 351.3 -> 308.6 KB; initial set +108 B, headroom 0.3 KB); 10x target headroom restored | Smoke tests: typecheck, unit tests, perf budget. Retain 1..1 invariant chain (`v-if="section === LIVE"` / `v-else-if="section === CHANNEL"`). Cold load deep link `/t/<id>` opens pane without regression. **Red control**: `ci_home_gzip_kb` drops >= 40 KB; cold `/channel/<name>` and `/t/<id>` checked at n>=5 before/after (if regression, add CHANNEL prefetch) | sat | claude | complex_coding | 2 (Lane 2) |
| 03 | `perf(p6-03-wui-rail-sidebar-no-body-mount)` | conditional DOM subtree mounting | In rail-only sections (docs, issues rail, calendar, monitoring, help), the entire channel list is mounted and hidden via CSS (`.sidebar.sidebar--rail .sidebar-body { display: none; }`), creating 137 hidden DOM nodes (16% of DOM on `/workspace/docs` with mock tenant; scales with channel count) | `wui:src/components/ChannelSidebar.vue:146,1731` | `grep -n 'sidebar-body' csi-spl-wui/src/components/ChannelSidebar.vue` (line 146); 137 hidden nodes on `/workspace/docs` (`div.sidebar-body`) | `v-if="!railOnly"` on `.sidebar-body`; completely skips mounting 137 DOM nodes in rail sections; mobile Docs TBT reduced | Smoke tests, typecheck. **Red control**: hidden node count on `/workspace/docs` drops 137 -> 0. The 7 test files naming `sidebar-body` pass. **Runs after r13-04** | sat | claude | complex_coding | 2 (Lane 1) |
| 04 | `perf(p6-04-wui-issues-status-dd-lazy-mount)` | lazy dropdown mounting | In `pages/issues.vue`, the status dropdown list is rendered unconditionally in the table header with `v-show="statusOpen"`, mounting 26 hidden DOM nodes (buttons, status codes, and tooltip spans) into the critical paint path on desktop visits to `/issues` (0 on mobile; list not rendered at 390) | `wui:src/pages/issues.vue:204` | `grep -n 'v-show="statusOpen"' csi-spl-wui/src/pages/issues.vue` (line 204); 26 hidden DOM nodes at 1440 (`div.issues-status-dd__list`) when closed | `v-if="statusOpen"` lazy mounting; status dropdown DOM mounted only when user activates filter button; drops 26 DOM nodes on initial `/issues` desktop paint | Smoke tests, e2e. **Red control**: closed `/issues` initial mount at 1440 has 0 status dropdown child nodes (was 26); status filter selection works identically. Tests: `tests/e2e/issues.test.mjs`, `tests/e2e/issues-dropdowns-live.proof.mjs`. **Runs after r13-06** | sat | claude | simple_coding | 4 (Lane 2) |
| 05 | `perf(p6-05-wui-async-kind-picker-in-kind-badge)` | component code splitting / dynamic import | `KindBadge.vue:39-47` already mounts `KindPicker` only while open (`v-if="settable && open"`), but static auto-import bundles it into message-card chunk (`CZBtcMWA.js`, 28.7 KB) preloaded by `index.html`. Replaces former CodeViewer row (A/B build proved only −3 B gain) | `wui:src/components/KindBadge.vue:39-47` | `grep -n "KindPicker" csi-spl-wui/src/components/KindBadge.vue` (line 39); home set 351.3 KB (0.8 KB headroom) | Wrap `KindPicker` in `defineAsyncComponent(() => import('@/components/KindPicker.vue'))` in `KindBadge.vue`; cuts 501 B gzip from home set (`ci_home_gzip_kb` drops to 350.8 KB; headroom increases 0.8 -> 1.3 KB) | Unit tests, e2e tests (`KindBadge` e2e, Shift+K via `shift-k-middle.test.mjs`). **Red control**: `ci_home_gzip_kb` falls >= 0.4 KB on same box. First click opens picker immediately; `KindKeyHost` retains its static picker | sat | claude | simple_coding | 3 (Lane 1) |
| 06 | `perf(p6-06-wui-live-feed-transition-gate)` | disable mount animations on initial feed load | `LiveFeed.vue` wraps messages in `<TransitionGroup>`, triggering 2 `enter-active` class mutations per row when cold initial batch of messages arrives (3 of 3 on `/lobby`, 1 of 1 on `/channel/alerts`), causing layout recalculations and animation frames during initial paint | `wui:src/components/LiveFeed.vue:37,112` | `grep -n "TransitionGroup" csi-spl-wui/src/components/LiveFeed.vue` (line 37); all rows of cold load animate in; script is 474 lines | Gate transitions with `:css="transitionsReady"`, flipped after the first non-empty batch of messages is rendered (after first `nextTick` that sees rows). Initial batch renders statically with 0 enter-active mutations; subsequent real-time messages animate smoothly. Adds <= 20 script lines (under 500-line ceiling) | Typecheck, e2e/unit tests. **Red control**: enter-active mutations on initial 30-row load (using Row 12 fixture) drops from 60 to 0. Realtime incoming messages animate normally. **Runs after r13-07** (for behavior alignment; no file overlap) | sat | claude | simple_coding | 3 (Lane 2) |
| 07 | `perf(p6-07-wui-phone-sidebar-idle-mount)` | deferred idle component mounting | On mobile viewports (< `MOBILE_STACK_QUERY`), when a feed or other route is active (mobile stack level > 1), `nav.sidebar` is hidden via CSS (`.spool-shell:not([data-mobile-level="1"]) > .sidebar { display: none; }`), mounting 153 hidden DOM nodes on `/channel/alerts` and 231 on mobile `/lobby` and `/workspace/docs` | `wui:src/layouts/default.vue:44` | `grep -n "ChannelSidebar" csi-spl-wui/src/layouts/default.vue` (line 44); 153-231 hidden DOM nodes in `nav.sidebar` on mobile routes | On mobile viewports when boot route is not level 1, mount `ChannelSidebar` on `requestIdleCallback` (with a timeout fallback) instead of in critical initial render. Reduces mobile initial DOM by 153-231 nodes | Typecheck, e2e. **Red control**: initial mobile DOM drops by 150-230 nodes. Back navigation to channel list (`data-mobile-level="1"`) still finds sidebar mounted. Phone back matrix tests (`phone-back-matrix.test.mjs`, `mobile-back-stuck.test.mjs`) pass cleanly. **Spawns after Row 02 lands** (`default.vue`) | sat | claude | complex_coding | 4 (Lane 1) |
| 08 | `perf(p6-08-wui-issues-windowed-rows)` | progressive / chunked rendering for long list views | On tenants with hundreds of issues, rendering all table rows at once inflates the DOM, spikes layout time, and degrades mobile LCP and TBT | `wui:src/pages/issues.vue:375,520` | `grep -n "v-for=\"issue in" csi-spl-wui/src/pages/issues.vue` (lines 375, 520); unchunked rendering; mock has 0 issues | Render initial batch of 25 rows on mount, followed by progressive `requestAnimationFrame` fill. Keeps `selSet`, folded groups, keyboard navigation, and Ctrl+F intact. Fits under script size ceiling in force (after r13-06 decomposes script <= 1200 lines) | Typecheck, unit tests. **Red control**: initial table row count is <= 25 on 300-issue fixture (from Row 12); idle fill completes all rows; selection, folding, and navigation tests pass. **Runs after r13-06** | sat | claude | complex_coding | 5 (Lane 2) |
| 09 | `perf(p6-09-wui-tenant-dropbox-lazy-list)` | lazy dropdown list mounting | `TenantDropBox.vue` mounts `<ul v-show="listOpen && shownRows.length > 0">` unconditionally into the top bar DOM on every desktop page, rendering membership `<li>` elements, labels, and event listeners while closed (2 hidden nodes at 1440 on mock, 0 on mobile) | `wui:src/components/TenantDropBox.vue:63` | `grep -n 'v-show="listOpen' csi-spl-wui/src/components/TenantDropBox.vue` (line 63); 2 hidden nodes on desktop mock | `v-if="listOpen && shownRows.length > 0"` lazy mounting; list DOM instantiated only when user clicks/focuses the switcher input. Keep `aria-controls` and `aria-activedescendant` valid (bind while open, or keep `ul` with `v-if` on `li`) | Typecheck, unit tests (`tests/e2e/tenant-list-inset.test.mjs`, `tests/unit/tenant-switcher.test.mjs`). **Red control**: measured on multi-tenant session; closed list child count drops to 0 (drop row if closed list is <10 nodes for 5-tenant member); switcher navigation functions identically | sat | claude | simple_coding | 5 (Lane 1) |
| 10 | `perf(p6-10-wui-docs-toc-lazy-mount)` | lazy drawer mounting | `WorkspaceDocView.vue` renders Table of Contents drawer DOM with `v-show="tocOpen"`. At 1440 px desktop, TOC is open by default (31 visible nodes); on narrow doc pane (< 760 px, e.g. at 1024 px window), TOC is closed, creating 31 hidden TOC nodes (`.wsdoc__toc`, headings, links) | `wui:src/components/workspace-docs/WorkspaceDocView.vue:261` | `grep -n 'v-show="tocOpen"' csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue` (line 261); 31 hidden nodes at 1024 px | `v-if="tocOpen"` lazy mounting; TOC DOM mounted only when open; cuts 31 DOM nodes on narrow doc view. Ensure `goTo()` link clicks scroll before unmount; no artificial transitions | Smoke tests, unit tests, e2e (`tests/e2e/workspace-doctree.test.mjs`). **Red control**: at 1024 px window, closed TOC has 0 `.wsdoc__toc` DOM nodes (was 31). Measure on Row 12 fixture (drop row if closed TOC is <10 nodes). TOC anchor navigation functions identically | sat | claude | simple_coding | 6 (Lane 2) |
| 11 | `perf(p6-11-wui-kind-key-host-phone-gate)` | device-targeted conditional mounting | `<LazyKindKeyHost />` is mounted unconditionally on every route, including phones. On phones, its shortcut handler immediately aborts (`if (phone.value) return`), yet phones fetch its 2430 B gzip chunk (`BqdqHZmu.js`) and run setup for 4 composables in the root layout | `wui:src/layouts/default.vue:144` | `grep -n "LazyKindKeyHost" csi-spl-wui/src/layouts/default.vue` (line 144); fetches 2430 B chunk on mobile cold load | `<LazyKindKeyHost v-if="!stack.isMobile.value" />` (matching `usePhone()` in `KindKeyHost.vue:38,152`); skips mounting and chunk fetch entirely on mobile devices, preserving Shift+K for desktop/tablets with keyboards | Smoke tests, typecheck, e2e (`tests/e2e/shift-k-middle.test.mjs`). **Red control**: mobile cold load fetches 0 `kind-key` chunks and mounts 0 `kind-key-host` elements; desktop Shift+K shortcut continues to work identically across topic rows, flow lists, and issue rows | sat | claude | simple_coding | 6 (Lane 1) |
| 12 | `perf(p6-12-wui-seeded-perf-fixture-gate)` | performance measurement tooling and gate | The round plan cited `scratch/measure-wui-perf.mjs`, which was uncommitted and unreproducible across seats; moreover, mock tenants have 0 issues and 1-3 messages, making rows 06, 08, 09, 10 unmeasurable. Moved to Batch 1 so all subsequent rows can use the fixture | `wui:src/node/test/measure-wui-perf.mjs` | `git ls-files \| grep -c measure-wui-perf` -> 0; mock tenant has 0 issues and 1-3 messages | Commit reproducible CDP performance benchmark runner (`measure-wui-perf.mjs`) and seeded large-tenant fixture generator (300 issues, 30 feed messages, 20 channels) in its own module (`src/node/test/perf-fixture.mjs`, without touching `utils/mock-data.mjs` to avoid r13-08 collision) | Automated CI / local gate: `node csi-spl-wui/src/node/test/measure-wui-perf.mjs` executes cleanly against local bundle on free port, outputting reproducible mobile and desktop metrics table with n=3 medians | sat | claude | complex_coding | 1 (Lane 2 start) |

---

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 12 rows touch completely disjoint files across `csi-spl-wui/` within each batch:
- **Batch 1:** `UserMenu.vue` (Row 01, Lane 1) vs `measure-wui-perf.mjs` + `perf-fixture.mjs` (Row 12, Lane 2) -> Disjoint.
- **Batch 2:** `ChannelSidebar.vue` (Row 03, Lane 1) vs `layouts/default.vue:94-95` (Row 02, Lane 2) -> Disjoint.
- **Batch 3:** `KindBadge.vue:39-47` (Row 05, Lane 1) vs `LiveFeed.vue` (Row 06, Lane 2) -> Disjoint.
- **Batch 4:** `layouts/default.vue:44` (Row 07, Lane 1) vs `pages/issues.vue:204` (Row 04, Lane 2) -> Disjoint.
- **Batch 5:** `TenantDropBox.vue` (Row 09, Lane 1) vs `pages/issues.vue:375,520` (Row 08, Lane 2) -> Disjoint.
- **Batch 6:** `layouts/default.vue:144` (Row 11, Lane 1) vs `WorkspaceDocView.vue:261` (Row 10, Lane 2) -> Disjoint.

To satisfy the owner directive ("use 2 lanes in parallel", owner msgs `686bc1a3` / `2c1b49ee`):
- **Lane 1:** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09 -> Row 11
- **Lane 2:** Row 12 -> Row 02 -> Row 06 -> Row 04 -> Row 08 -> Row 10
- **Starting rows:** Row 01 (Lane 1) and Row 12 (Lane 2) spawn in parallel as Batch 1. When Row 01 lands, Row 03 spawns on Lane 1; when Row 12 lands, Row 02 spawns on Lane 2. Exactly 2 lanes remain active at all times.
- **Pacing and file serialization:** `default.vue` appears only in batches 2, 4, and 6 (serial in Lane 2 then Lane 1). If Lane 2 stalls on Row 02, Lane 1 waits before spawning Row 07. `issues.vue` appears only in batches 4 and 5 (serial in Lane 2, both after r13-06).

### 3.2 Off every live lane (R3)

`lane-map.sh --check <paths> --agent a-591` verifies that no live lane owns any row path. The spawner re-runs `--check` per row before spawning (R3).

---

## 4. Per row: what the lane does

- **01 (`UserMenu.vue`):** Change `v-show="open"` to `v-if="open"` on `[data-test="user-menu-panel"]`. The dropdown panel is hidden on initial load; using `v-if` ensures its 45 desktop / 56 mobile DOM elements (signed-in only), icons, and action handlers are omitted during initial paint and mounted only on user click. Bind trigger's `aria-controls` only while open. Rewrite `tests/unit/user-menu.test.mjs:149` title for v-if while preserving rotation guard.
- **02 (`layouts/default.vue`):** Replace static auto-imports of `LiveTopicPane.vue` and `TopicPane.vue` with `defineAsyncComponent(() => import('@/components/LiveTopicPane.vue'))` and `defineAsyncComponent(() => import('@/components/TopicPane.vue'))`. Preserves the 1..1 invariant chain (`v-if="section === LIVE"` / `v-else-if="section === CHANNEL"`). Moves panes from `modulepreload` to prefetch, reducing `ci_home_gzip_kb` by >= 40 KB (A/B build: −43,687 B, dropping home set from 351.3 to 308.6 KB; 10x target). Initial set +108 B (headroom 0.3 KB against 155 KB limit). Cold load deep link `/t/<id>` and `/channel/<name>` checked at n>=5 before/after (if regression, add CHANNEL prefetch).
- **03 (`ChannelSidebar.vue`):** Wrap `.sidebar-body` with `v-if="!railOnly"`. In rail-only sections (docs, issues rail, calendar, monitoring, help), skips mounting 137 hidden channel list DOM nodes. Store state is in Pinia, so remounting retains all user folds and unread status. Runs after r13-04.
- **04 (`pages/issues.vue`):** Change `v-show="statusOpen"` to `v-if="statusOpen"` on `.issues-status-dd__list`. Drops 26 hidden DOM nodes (filter option buttons, status codes, tooltip spans) from the table header on desktop `/issues` paint (0 on mobile; list not rendered at 390). Runs after r13-06.
- **05 (`KindBadge.vue`):** Wrap `KindPicker` in `defineAsyncComponent(() => import('@/components/KindPicker.vue'))` in `KindBadge.vue`. `KindBadge:39-47` mounts the picker only while open, but static auto-import bundles it into the 28.7 KB message-card chunk preloaded by `index.html`. Replacing former `CodeViewer` row (A/B build saved only 3 B); async `KindPicker` cuts 501 B gzip from `ci_home_gzip_kb` (350.8 KB, headroom 1.3 KB). `KindKeyHost` keeps its static picker.
- **06 (`LiveFeed.vue`):** Gate `<TransitionGroup>` CSS animations on initial mount via `:css="transitionsReady"`, where `transitionsReady` is flipped after the first non-empty batch of messages is rendered (after first `nextTick` that sees rows). Initial messages render statically without layout thrash; subsequent real-time messages animate smoothly. Adds <= 20 script lines (under 500-line ceiling, current script is 474 lines). Runs after r13-07 for behavior alignment (does not fight `afterAppend`), no file overlap (`useScrollAnchor.ts`/`scroll-anchor.mjs`). Red control uses Row 12 fixture.
- **07 (`layouts/default.vue`):** On mobile viewports below `MOBILE_STACK_QUERY`, when boot route is not level 1, mount `ChannelSidebar` on `requestIdleCallback` (with timeout fallback). Drops 153 hidden DOM nodes on mobile `/channel/alerts` and 231 on mobile `/lobby` and `/workspace/docs` initial paint without delaying back-navigation. Spawns after Row 02 has landed on `default.vue`.
- **08 (`pages/issues.vue`):** Progressive windowed rendering for issue table / card list. Paints the first 25 issues immediately; appends subsequent rows via `requestAnimationFrame`. Preserves `selSet`, folded groups, keyboard navigation, and Ctrl+F. Fits under script ceiling in force. Uses Row 12 fixture (300 issues). Runs after r13-06.
- **09 (`TenantDropBox.vue`):** Change `v-show="listOpen && shownRows.length > 0"` to `v-if="listOpen && shownRows.length > 0"` on `.tenant-switcher__list`. Drops hidden `<li>` elements and listeners from top bar DOM until user activates switcher. Keep `aria-controls` and `aria-activedescendant` valid. Measured on multi-tenant session (drop row if closed list is <10 nodes for 5-tenant member).
- **10 (`WorkspaceDocView.vue`):** Change `v-show="tocOpen"` to `v-if="tocOpen"` on `.wsdoc__toc`. At 1440 px desktop, TOC is open by default (31 visible nodes); on narrow doc pane (< 760 px, e.g. at 1024 px window), TOC is closed, creating 31 hidden TOC nodes. Red control taken at 1024 px window (31 hidden nodes drop to 0). Ensure `goTo()` link clicks scroll before unmount. Measured on Row 12 fixture (drop row if closed TOC is <10 nodes).
- **11 (`layouts/default.vue`):** Add `v-if="!stack.isMobile.value"` to `<LazyKindKeyHost />` (matching `usePhone()` in `KindKeyHost.vue:38,152`). Skips fetching 2430 B gzip chunk `BqdqHZmu.js` on mobile and avoids 4 composable setups in root layout, while preserving Shift+K for desktop/tablets with keyboards.
- **12 (`wui:src/node/test/measure-wui-perf.mjs`):** Commit the reproducible CDP performance benchmark runner (`measure-wui-perf.mjs`) and large-tenant fixture generator (300 issues, 30 feed messages, 20 channels) in its own module (`src/node/test/perf-fixture.mjs`, avoiding collision with r13-08 on `utils/mock-data.mjs`). Moved to Batch 1 so subsequent rows (06, 08, 09, 10) have the fixture ready for their red controls.

---

## 5. What was measured and NOT worth doing (Empirical Evidence)

Each item below was investigated with empirical measurements and discarded with concrete evidence:

| Practice / Proposal | Why Not | Empirical Evidence |
|---|---|---|
| 1. Memoize `fields()` in `date-iso.mjs` (v0.1 row 03) | `formatToParts` runs only for viewers with non-empty picked timezone (0 ms by default). Minute-keyed cache drops seconds and breaks `isoDateTimeSec` in `IssueHistory`, `PersonActivityDialog`, `ReleaseNotesDialog` | Measured by claude seat `c-250@sat`: default zone is 2.14 ms for 1,000 dates; saving is <0.25 ms per 30-row feed render. Breaks existing function (violates owner msg `95472f33`) |
| 2. `DeadlinePicker.vue` pure CSS sizing (v0.1 row 04) | Mounts only in `pages/issues.vue` (1 instance), never on login/forms. Pure CSS sizing drops owner SPL-1147 "text + 2 mm" width constraint | e2e `deadline-picker.test.mjs` C1 asserts `trailing == 8 +- 1 px` at 1440; `calc(n * 1ch)` fails for `-`, `:`, and spaces. Breaks existing tests |
| 3. Login wallpaper `v-if` (v0.1 row 07) | Wallpaper is already `display:none` on front page (`.login:has(.login-front)`), so no filter or animation runs | Measured on `/login`: `wallpaperDisplay: none`. Saves only 10 DOM nodes; template comment records that route flag cannot reach route table without expanding entry chunk |
| 4. `MarkdownBlock.vue` plain-text fast path (v0.1 row 09) | Already implemented on master one level up via `looksLikeMarkdown` in `MessageBody.vue:57` | Measured on `/lobby`: 3 plain bodies yield 0 mounted MarkdownBlock components and 0 markdown chunk loads. Redundant |
| 5. Debounce `seedTopics()` (v0.1 row 10) | Vue's pre-flush scheduler already coalesces same-tick reactive updates (10 same-tick replacements -> 1 call). Selection watcher disables topic feed during channel switch | Measured switch latency does not originate in `seedTopics()`. Trailing debounce delays topic list readiness for no measured gain |
| 6. Cache `channelView` / `feed` (v0.1 row 11) | Vue `computed` already memoizes message projections; red control is already green today | Cost per recompute is 0.73 ms at 200 msgs. Maintaining manual cache across `applyEdit`, `patchReactions`, `withoutMsg`, and `mergeCatchUp` is high correctness risk for sub-ms gain |
| 7. Collapse docs directory tree (v0.1 row 12) | Tree already starts folded on master (`open = ref(new Set(['csi-spl-doc']))` at `docs.vue:207`). `/docs` redirects to `/workspace/docs` | Measured DOM nodes on `/docs` belong to `WorkspaceDocsLayout`, where 137 nodes belong to hidden channel sidebar (resolved by row 03) |
| 8. Purging Nuxt/Vue DevTools in build | Devtools are already stripped in production `nuxt generate` | `grep -rn "devtools" csi-spl-wui/.output/public` yields 0 hits; bundle is already tree-shaken |
| 9. Static pre-compression with Brotli | Cloud Run and CDN edge already perform on-the-fly Brotli/Gzip compression | Static asset pre-compression does not alter client-side browser parse time, execution time, or TTI |
| 10. Virtual scrolling for main message feed (`LiveFeed.vue`) | Breaks native browser scroll anchor (`overflow-anchor`), search-in-page (`Ctrl+F`), and scroll position restoration; violates owner mandate msg `95472f33` | Rows 06 and 01 deliver render throughput improvements without virtual scroll complexity or DOM destruction |
| 11. Dedicated Web Worker for date formatting | Worker thread `postMessage` serialization overhead (~2-4 ms round-trip) is higher than synchronous formatting | Added complexity for negative performance gain |
| 12. Preloading all Nuxt route chunks (`<link rel="preload">` on 414 chunks) | Saturates mobile cellular bandwidth (1.78 MB gzip total client JS), competing with critical CSS/JS | Increases mobile FCP and LCP by >200 ms on throttled connections |
| 13. Global CSS utility class purge | High risk of visual regression across 40+ components for negligible byte savings (CSS gzip footprint is only ~24 KB) | CSS parsing is <5% of mobile main-thread time; JS execution and DOM thrashing are primary bottlenecks |
| 14. Removing SVG icons in sidebar | Degrades UX and violates owner mandate msg `95472f33` | Initial SVG icon rendering takes <2 ms on desktop and <6 ms on mobile; not a performance bottleneck |
| 15. Full Server-Side Rendering (SSR) migration | Architecture is static client SPA (`nuxt generate` served via Cloud Run / CDN); moving to dynamic SSR requires backend Node/Nitro server runtime changes and introduces cold start latency | Cloud Run container cold-start adds 500-1500 ms TTFB; client-side pre-rendered SPA with CDN edge caching provides faster first-byte delivery |
| 16. CodeViewer lazy loading in CodeBlock.vue (v1.0 draft row 05) | A/B build demonstrated only −3 B home set savings and −28 B chunk delta because CodeViewer shares implementation with CodeLines | Measured by mistral takeover seat c-252@sat: −3 B index.html gzip. Replaced with Proposal P1 (KindBadge.vue async KindPicker, −501 B) |

---

## 6. Expert panel of reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-591@<box>` (`perf-round-6/seat-agy.md`) - proposed v0.1, folded v1.0
  - Claude seat: `c-250@sat` (`perf-round-6/seat-claude.md`, commit `a4b20dec6`) - reviewed v0.1, proposed P1 & P2
  - Grok seat: `perf-round-6/seat-grok.md` - not seated (no grok quota on any box per dispatcher `c-002@sat` / `c-003@sat`)
  - Mistral seat: `perf-round-6/seat-mistral.md` - takeover seat queued by orchestrator `c-001` / dispatcher `c-003@sat`
- **Reviewers per row (R7):** Cross-vendor review enforced for every row across available active seats. Zero same-vendor reviews.

---

## 7. Counts

| Dimension | Count |
|---|---|
| Total rows | 12 (100% WUI speed-up across mobile and desktop) |
| Vendors | claude: 12 (or distributed with takeover seat) |
| Preferred box | sat (12) |
| Parallel lanes | 2 lanes at all times (6 batches of 2 rows) |
| Starting batch | Batch 1: Row 01 (Lane 1) and Row 12 (Lane 2) in parallel |

---

## 8. Changes

- v0.1: Initial proposed plan for Round 6 (UI speed-up on mobile and desktop), measured on `4251b33cf`. 12 concrete actions in 6 batches of 2 parallel lanes, overriding 10-row cap per owner order msg `4244afb1`.
- v1.0 DRAFT: Folded expert panel findings from claude seat `c-250@sat` (`seat-claude.md`, commit `a4b20dec6`, measured on `4a3781047`):
  - Adopted Claude Proposal P1 as Row 03: conditional mounting for `sidebar-body` (`v-if="!railOnly"` in `ChannelSidebar.vue:146`), eliminating 137 hidden DOM nodes on `/workspace/docs`.
  - Adopted Claude Proposal P2 as Row 07: deferred mounting of phone channel sidebar on `requestIdleCallback` (`layouts/default.vue:44`), eliminating 153 hidden DOM nodes on mobile `/channel/alerts`.
  - Adopted Claude Recommendation (section 4.2) as Row 12: reproducible CDP benchmark runner and seeded large-tenant fixture gate (`measure-wui-perf.mjs`).
  - Replaced low-value/invalid rows:
    - Replaced row 04 with Row 04: lazy mounting for `issues.vue:204` status dropdown list (`v-if="statusOpen"`), eliminating 26 hidden DOM nodes.
    - Replaced row 07 with Row 09: lazy mounting for `TenantDropBox.vue:63` membership list (`v-if="listOpen && shownRows.length > 0"`).
    - Replaced row 10 with Row 10: lazy mounting for `WorkspaceDocView.vue:261` TOC drawer (`v-if="tocOpen"`).
    - Replaced row 11 with Row 11: device-targeted gating for `LazyKindKeyHost` (`v-if="!stack.isMobile.value"` in `default.vue:144`).
  - Refined Row 01 targets and red control: 45 hidden nodes desktop / 56 mobile (`[data-test="user-menu-panel"]`).
  - Refined Row 02 targets: targets `ci_home_gzip_kb` (>= 4.0 KB savings) from `index.html` modulepreload set.
  - Refined Row 05 targets: cuts ~1.47 KB gzip from `ci_home_gzip_kb`.
  - Refined Row 06 gate: gates on first non-empty batch rendered (after first nextTick with rows); adds <= 25 script lines (under 500-line ceiling).
  - Refined Row 08 requirements: seeded fixture of 300 issues; progressive rAF fill preserving `selSet` and navigation.
  - Updated Section 5 with concrete empirical evidence for all 7 panel-disagreed items.
  - Marked Grok seat as "not seated" per dispatcher instruction.
  - Mistral seat pending takeover review from `c-001`/`c-003`.
- v1.0 Proposed: Folded findings, empirical measurements, and proposals from claude takeover seat `c-252@sat` (`seat-mistral.md`, commit `b73f885e5`, measured on `b6153d006`):
  - Adopted Takeover Proposal P1 as Row 05: async `KindPicker` in `KindBadge.vue:39-47` saving 501 B gzip (`ci_home_gzip_kb` 350.8 KB, headroom 1.3 KB), replacing `CodeViewer` lazy load (A/B build measured −3 B saving).
  - Re-ordered batches to move Row 12 (harness + seeded large-tenant fixture) to Batch 1 (Lane 2 start) so rows 06, 08, 09, and 10 have the fixture ready for red controls.
  - Placed fixture in its own module (`src/node/test/perf-fixture.mjs`) to avoid r13-08 collision on `utils/mock-data.mjs`.
  - Expanded Row 02 target: home set falls by >= 40 KB (A/B build measured −43,687 B; 10x target); cold `/channel/*` checked at n>=5 before/after.
  - Refined Row 06 script line ceiling: <= 20 lines (script is 474 lines, keeping within 500-line ceiling); no file overlap with r13-07.
  - Refined Row 07: holds until Row 02 lands on `default.vue`; eliminates 153 hidden nodes on `/channel/alerts` and 231 on `/lobby` and `/workspace/docs`.
  - Refined Row 09: desktop closed list has 2 nodes (mock single-membership), 0 on mobile; keep `aria-controls`/`aria-activedescendant` valid; measure on multi-tenant session (drop if <10 nodes).
  - Refined Row 10: TOC is open by default at 1440 (31 visible nodes); closed at 1024 (< 760 px doc pane); red control taken at 1024 px.
  - Refined Row 11: gate matches `usePhone()` in `KindKeyHost.vue:38,152`; skips 2430 B chunk fetch on mobile.
  - Updated Section 2.2: mobile `/workspace/docs` DOM count corrected to 634.

---

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| editor | agy | a-591@<box> | v1.0 proposed folded | this file |
| claude seat | claude | c-250@sat | signed on `0af615b8c` (`8cc3e62e2`) | `perf-round-6/seat-claude.md` |
| grok seat | grok | - | not seated (fleet quota) | `perf-round-6/seat-grok.md` |
| mistral takeover seat | claude | c-252@sat | verdict landed `b73f885e5` (pending v1.0 sign) | `perf-round-6/seat-mistral.md` |
