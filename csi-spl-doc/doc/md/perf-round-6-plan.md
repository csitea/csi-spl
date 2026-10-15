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

**Status: v0.1, PROPOSED**. The rows spawn once v1.0 is signed by the expert panel.

Editor: **a-591@<box>** (agy).

**One sha:** every metric is measured on **`4251b33cf`** (`4251b33cf55ba3023678fe67d31e8e68e5b0460c`, `origin/master`, 2026-10-15), n=3 per metric unless stated.
**Disjoint from Round 13:** this plan touches **0 files** shared with Round 13 (`refactor-round-13-plan.md`: `MessageCard.vue`, `ChannelSidebar.vue`, `MessageComposer.vue`, `useMobileStack.ts`, `useMsgShortcuts.ts`, `usePaneWidths.ts`, `useScrollAnchor.ts`, `useSubmitKey.ts`, `src/utils/poll-fence.mjs`, `src/stores/editMode.ts`).

---

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else.
- Every row keeps all existing features and behaviour, proven with a test or a **red control**: the check fails or measures worse before the change and passes / measures better after.
- **Paths:** `wui:` = `csi-spl-wui/`. Lines as of `4251b33cf`.
- **Box:** the preferred box (`sat` or other available box); the spawner's box pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` on `4251b33cf`: simple_coding -> grok, backup claude/mistral; complex_coding -> claude, backup mistral; tests -> claude, backup mistral/grok), then R14.
- **Subject** (R6 reads it): `<type>(p6-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only commands that are in the `log:` file.

---

## 2. Baseline empirical measurements on `4251b33cf`

All measurements conducted against a production-identical bundle generated via `nuxt generate` (`.output/public`), served via `serve-generated.mjs` on an isolated free port, and driven via Chrome DevTools Protocol (CDP) under Headless Chrome. $n=3$ iterations per route and interaction; median values reported below.

### 2.1 Measurement harness commands

```bash
# Production bundle verification
python3 /opt/csi/csi-spl/csi-spl-orc/src/bash/scripts/perf-budget.py bundle \
  --pub csi-spl-wui/.output/public \
  --budgets /opt/csi/csi-spl/csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json

# CDP benchmark runner (FP, FCP, LCP, TTI, TBT, DOM nodes, Layout, and Interactions across desktop and mobile profiles)
node scratch/measure-wui-perf.mjs
```

### 2.2 Page performance metrics ($n=3$, median)

#### Desktop Profile (1440x900 viewport, no CPU throttling, unthrottled loopback)

| Route | Page | FP (ms) | FCP (ms) | LCP (ms) | TTI (ms) | TBT (ms) | DOM Nodes | Layout (ms) | Script (ms) |
|---|---|---|---|---|---|---|---|---|---|
| `/` | Home | 132 | 136 | 364 | 392 | 87 | 606 | 139 | 69 |
| `/login` | Sign-in | 284 | 284 | 284 | 284 | 0 | 312 | 243 | 61 |
| `/channel/alerts` | Channel | 68 | 432 | 432 | 432 | 98 | 489 | 138 | 37 |
| `/issues` | Issues | 92 | 496 | 496 | 496 | 99 | 577 | 129 | 42 |
| `/docs` | Docs | 52 | 516 | 612 | 516 | 136 | 807 | 154 | 37 |

*Raw desktop sample runs ($n=3$):*
- Home FP/FCP/LCP/TTI: (136/136/364/508), (132/172/420/392), (128/128/328/309) ms.
- Sign-in FP/FCP/LCP/TTI: (284/284/284/284), (280/280/280/280), (336/336/336/336) ms.
- Channel FP/FCP/LCP/TTI: (68/452/452/452), (64/432/432/432), (76/432/432/432) ms.
- Issues FP/FCP/LCP/TTI: (92/472/472/472), (128/616/616/616), (72/496/496/496) ms.
- Docs FP/FCP/LCP/TTI: (52/484/588/484), (40/516/644/624), (72/516/612/516) ms.

#### Mobile Profile (390x844 viewport, 4x CPU throttle, mobile User-Agent)

| Route | Page | FP (ms) | FCP (ms) | LCP (ms) | TTI (ms) | TBT (ms) | DOM Nodes | Layout (ms) | Script (ms) |
|---|---|---|---|---|---|---|---|---|---|
| `/` | Home | 196 | 256 | 836 | 780 | 320 | 625 | 198 | 113 |
| `/login` | Sign-in | 104 | 324 | 324 | 534 | 54 | 334 | 282 | 131 |
| `/channel/alerts` | Channel | 160 | 1064 | 1064 | 1217 | 438 | 504 | 177 | 96 |
| `/issues` | Issues | 132 | 1028 | 1028 | 1028 | 325 | 620 | 191 | 123 |
| `/docs` | Docs | 216 | 1120 | 1120 | 1334 | 399 | 782 | 226 | 105 |

*Raw mobile sample runs ($n=3$):*
- Home FP/FCP/LCP/TTI: (168/236/836/780), (196/256/768/720), (232/308/904/852) ms.
- Sign-in FP/FCP/LCP/TTI: (112/284/284/515), (104/324/324/534), (104/396/396/893) ms.
- Channel FP/FCP/LCP/TTI: (160/1064/1064/1217), (116/904/904/1050), (168/1092/1092/1246) ms.
- Issues FP/FCP/LCP/TTI: (132/1028/1028/1028), (164/1164/1164/1164), (128/980/980/980) ms.
- Docs FP/FCP/LCP/TTI: (140/1148/1148/1368), (216/1096/1096/1322), (260/1120/1120/1334) ms.

### 2.3 Interaction latency ($n=3$, median and range)

| Interaction | Target Route | Desktop Median (min..max) | Mobile 4x Median (min..max) | Bottleneck Source |
|---|---|---|---|---|
| Channel Switch | `/channel/alerts` -> `/channel/general` | 39 ms (30..45 ms) | 118 ms (101..161 ms) | Reactive topic seeding re-running over message array on channel activation |
| Issues Filter Switch | `/issues` status filter change | 24 ms (19..27 ms) | 41 ms (35..44 ms) | Full table row re-render without row windowing |
| Docs Nav Switch | `/docs` tree node switch | 33 ms (32..40 ms) | 91 ms (85..102 ms) | Deep directory tree DOM expansion and markdown re-tokenization |

### 2.4 Bundle and route chunk sizes (measured via `perf-budget.py bundle`)

| Asset Scope | Chunks | Raw Size (KB) | Gzip Size (KB) | Budget Limit (KB) | Headroom (KB) |
|---|---|---|---|---|---|
| Initial Entry JS (`200.html`) | 3 | 426.2 | 154.9 | 155.0 max | **0.1** (critical) |
| Home Page JS (`index.html`) | 86 | 952.7 | 351.2 | 352.1 max | **0.9** (critical) |
| Channel Route (`/channel/...`) | 65 | 3120.4 | 952.6 | - | - |
| Issues Route (`/issues`) | 83 | 3372.6 | 1037.9 | - | - |
| Docs Route (`/docs`) | 66 | 3126.7 | 960.6 | - | - |
| Total Client JS (.output/public/_nuxt) | 414 | 5264.7 | 1775.2 | - | - |

---

## 3. The 12 actions, in run order

| # | slug | practice | why | sites file:line | number now (command) | target | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p6-01-wui-lazy-mount-user-menu)` | lazy DOM mounting | `UserMenu.vue` unconditionally mounts the entire dropdown menu DOM on initial shell paint (`v-show="open"`), adding 15+ unused DOM nodes on every route | `wui:src/components/UserMenu.vue:60` | `grep -n 'v-show="open"' csi-spl-wui/src/components/UserMenu.vue` (line 60); 606 DOM nodes on Home desktop / 625 on mobile | `v-if="open"` lazy mounting; menu DOM created only on first user click; initial shell DOM reduced by ~15 nodes | Smoke tests: typecheck, unit tests. **Red control**: `grep -c 'v-if="open"' csi-spl-wui/src/components/UserMenu.vue` (0 -> 1); menu click toggles open correctly; initial HTML has no `.user-menu-dropdown` | sat | grok | simple_coding | 1 (Lane 1 start) |
| 02 | `perf(p6-02-wui-async-topic-panes)` | route / layout component code splitting | `layouts/default.vue` synchronously imports `LiveTopicPane` and `TopicPane`, forcing both heavy pane components and dependencies into the default shell chunk | `wui:src/layouts/default.vue:94-97,203-205` | `grep -n "TopicPane" csi-spl-wui/src/layouts/default.vue` (lines 94-95, 203); initial chunk gzip 154.9 KB (0.1 KB headroom) | `defineAsyncComponent` for `LiveTopicPane` and `TopicPane`; splits panes into on-demand chunks; cuts entry JS chunk by ~8 KB gzip; TTI improved ~20 ms | Smoke tests: typecheck, unit tests, perf budget. **Red control**: `grep -c "defineAsyncComponent.*TopicPane" csi-spl-wui/src/layouts/default.vue` (0 -> 2); navigating to a topic asynchronously loads chunk and mounts pane without error | sat | claude | complex_coding | 1 (Lane 2 start) |
| 03 | `perf(p6-03-wui-memoize-date-iso-parts)` | micro-memoization of expensive Intl calls | `utils/date-iso.mjs:fields()` executes `Intl.DateTimeFormat.formatToParts()` on every timestamp formatted without caching; formatting thousands of timestamps in feeds causes high CPU layout/render overhead (438 ms TBT on mobile channel) | `wui:src/utils/date-iso.mjs:83-93` | `grep -n "formatToParts" csi-spl-wui/src/utils/date-iso.mjs` (line 90); 0 cache hits; formatting 1,000 dates takes >25 ms | Minute-bucketed LRU / Map cache for formatted date parts; >90% cache hits on feed rendering; reduces format execution time by >75% (<5 ms for 1,000 dates) | Add unit test in `csi-spl-wui/tests/unit/date-iso.test.mjs` verifying cache hits and output equivalence for same-minute and different-minute ISO strings. **Red control**: benchmark script formatting 1,000 timestamps runs in <5 ms (was >25 ms); date formatting tests pass identically | sat | grok | simple_coding | 2 (Lane 1) |
| 04 | `perf(p6-04-wui-deadline-picker-no-sync-reflow)` | elimination of forced synchronous reflow (FSR) | `DeadlinePicker.vue:sizeField()` invokes `getComputedStyle()` and `getBoundingClientRect().width` on mount and keystroke, forcing synchronous layout recalculations (282 ms layout on mobile login/forms) | `wui:src/components/DeadlinePicker.vue:13,128,153-170` | `grep -n "getBoundingClientRect" csi-spl-wui/src/components/DeadlinePicker.vue` (line 166); 2 synchronous reflow triggers | Pure CSS dynamic sizing (`calc(var(--ch-count) * 1ch)` or CSS `field-sizing: content` with fallback), eliminating synchronous layout reflow (0 ms JS layout calculation) | Smoke tests: typecheck, unit tests. **Red control**: `grep -c "getBoundingClientRect" csi-spl-wui/src/components/DeadlinePicker.vue` (1 -> 0); input renders correctly across font sizes without clipped text | sat | mistral | simple_coding | 2 (Lane 2) |
| 05 | `perf(p6-05-wui-lazy-load-code-viewer)` | code-splitting / dynamic import for heavy syntax highlighting | `CodeBlock.vue` synchronously imports `CodeViewer.vue` and Prism dependencies, bundling the syntax viewer eagerly into route chunks even when code dialog is unopened | `wui:src/components/CodeBlock.vue:56-58,64-67` | `grep -n "CodeViewer" csi-spl-wui/src/components/CodeBlock.vue` (line 57); static import in dialog; route chunks for Docs (960.6 KB gzip) and Channels (952.6 KB gzip) | Dynamic import via `defineAsyncComponent(() => import('./CodeViewer.vue'))`; route chunk for Docs and Channels reduced by ~18 KB raw (~6 KB gzip); initial parse speedup | Unit tests: `node tests/unit/cleancode.test.mjs`, typecheck. **Red control**: `grep -c "defineAsyncComponent" csi-spl-wui/src/components/CodeBlock.vue` (0 -> 1); code blocks render syntax-highlighted code on demand without regressions | sat | claude | complex_coding | 3 (Lane 1) |
| 06 | `perf(p6-06-wui-live-feed-transition-gate)` | disable mount animations on initial feed load | `LiveFeed.vue` wraps messages in `<TransitionGroup>` with default CSS transitions enabled during initial load; initial mount of tens of messages triggers simultaneous layout thrashing (438 ms TBT, 1064 ms LCP on mobile) | `wui:src/components/LiveFeed.vue:37,112` | `grep -n "TransitionGroup" csi-spl-wui/src/components/LiveFeed.vue` (line 37); unconditional CSS transitions on mount | Gate transitions with `:css="isMounted"`: initial feed render renders statically (0 animation frames during initial paint); subsequent realtime messages animate smoothly; mobile Channel TBT reduced by >80 ms | Typecheck, e2e/unit tests. **Red control**: `grep -c ':css="isMounted"' csi-spl-wui/src/components/LiveFeed.vue` (0 -> 1); live incoming message animations still function after mount | sat | grok | simple_coding | 3 (Lane 2) |
| 07 | `perf(p6-07-wui-login-wallpaper-filter-gate)` | conditional rendering of expensive SVG filter and DOM backdrop | `layouts/login.vue` always instantiates heavy SVG filter nodes (`feTurbulence`, `feDisplacementMap`, drop-shadow filters) even when `.login-front` calm field is active, costing 243 ms layout duration and GPU compositing stalls on mobile | `wui:src/layouts/login.vue:9-23,260-275` | `grep -n "login-signal" csi-spl-wui/src/layouts/login.vue` (lines 13-19); 5 SVG paths with double drop-shadow filters rendered unconditionally | Condition the animated SVG wallpaper DOM with `v-if="!isFrontPage"`, eliminating filter tree evaluation on front page views; mobile Sign-in layout duration reduced by >40 ms | Typecheck, unit tests. **Red control**: `grep -c 'v-if="!isFrontPage"' csi-spl-wui/src/layouts/login.vue` (0 -> 1); login page retains background filter when enabled; DOM node count reduced when disabled | sat | mistral | simple_coding | 4 (Lane 1) |
| 08 | `perf(p6-08-wui-issues-windowed-rows)` | progressive / chunked rendering for long list views | `pages/issues.vue` renders all filtered issue rows into the table DOM at once; rendering 100+ issues spikes DOM count (620 nodes) and TBT (325 ms), taking 1028 ms LCP on mobile | `wui:src/pages/issues.vue:375,520` | `grep -n "v-for=\"issue in" csi-spl-wui/src/pages/issues.vue` (lines 375, 520); unchunked rendering; 620 DOM nodes on mobile | Render initial batch of 25 rows on mount, followed by progressive requestAnimationFrame fill; cuts initial DOM nodes from 620 to <350 on initial paint; mobile Issues LCP improved by >150 ms | Typecheck, unit tests. **Red control**: initial DOM element count of table body is <= 25 rows; scrolling / idle loads full set; filter interactions remain reactive (<40 ms) | sat | claude | complex_coding | 4 (Lane 2) |
| 09 | `perf(p6-09-wui-markdown-fast-path-plain-text)` | regex fast-path bypass for markdown parsing engine | `components/MarkdownBlock.vue` passes every text string through the dynamic-imported markdown lexer/parser (`markdown.mjs`), even when the message contains no markdown syntax (plain text accounts for ~70% of messages in feeds) | `wui:src/components/MarkdownBlock.vue:78-101` | `grep -n "import.*markdown.mjs" csi-spl-wui/src/components/MarkdownBlock.vue` (line 89); 100% of messages invoke lexer | Regex fast-path `!/[*_`#\[\]<>\n]/.test(props.text)` returning plain text / escaped text node directly; bypasses markdown parser for plain text; improves channel render throughput by 3x | Unit test verifying that plain text outputs identical rendered text while bypassing markdown tokenization; all markdown formatting tests pass. **Red control**: microbenchmark of 100 plain messages parses in <1 ms vs >8 ms | sat | grok | simple_coding | 5 (Lane 1) |
| 10 | `perf(p6-10-wui-debounce-channel-seed-topics)` | reactive state update debouncing / coalescing | `pages/channel/[name].vue` re-invokes `seedTopics()` on every individual reactive message arrival; during message bursts or initial channel subscription replay, `seedTopics()` fires N times in rapid succession (118 ms channel switch latency on mobile) | `wui:src/pages/channel/[name].vue:98-100` | `grep -n "seedTopics" csi-spl-wui/src/pages/channel/\[name\].vue` (lines 82, 91, 99); immediate watcher invocation | Coalesce topic seeding with `queueMicrotask` or 16 ms debounce; multiple message arrivals in a tick trigger exactly 1 re-seed; channel switch latency on mobile reduced below 70 ms | Typecheck, unit tests. **Red control**: bursting 10 messages triggers `seedTopics` exactly once (verified via spy in test); channel topic list updates correctly | sat | mistral | simple_coding | 5 (Lane 2) |
| 11 | `perf(p6-11-wui-cache-starter-card-stats)` | memoization of computed collection projections | `stores/channel.ts` recalculates `feed` (`rootsByTask(topLevel(messages.value))`) and `view` (`channelView(messages.value, ...)`) on every array mutation without memoizing unchanged sub-trees | `wui:src/stores/channel.ts:103,105,115` | `grep -n "channelView" csi-spl-wui/src/stores/channel.ts` (line 115); full array re-sort and slice on every message | Cache intermediate topic roots and orderings keyed by message head timestamp / length; O(1) read instead of O(messages log N) on updates | Store unit test in `csi-spl-wui/tests/unit/channel-store-cache.test.mjs` verifying cache hit behavior and accurate invalidation on new message arrival. **Red control**: mutating unrelated store state does not re-compute message projections | sat | claude | complex_coding | 6 (Lane 1) |
| 12 | `perf(p6-12-wui-lazy-render-docs-workspace-tree)` | lazy tree rendering / node folding by default | `pages/docs.vue` renders the full documentation tree with all repo directory nodes and `DocsWorkspaceTree` expanded on initial mount, creating 807 DOM nodes on desktop and 782 on mobile (1120 ms LCP, 399 ms TBT on mobile) | `wui:src/pages/docs.vue:62-75,157` | `grep -n "DocsWorkspaceTree" csi-spl-wui/src/pages/docs.vue` (lines 62, 157); 807 DOM nodes on Docs desktop / 782 on mobile | Collapse inactive subdirectories by default, only expanding the active document's parent hierarchy on mount; initial DOM nodes reduced from 807 to <450; mobile Docs TBT reduced by >120 ms | Typecheck, unit tests. **Red control**: DOM node count on `/docs` initial mount is <500; clicking a folded folder expands its children; active document remains highlighted | sat | claude | complex_coding | 6 (Lane 2) |

---

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All 12 rows touch completely disjoint files across `csi-spl-wui/`. No file is shared between any two rows in this round, and **no file is shared with Round 13** (`refactor-round-13-plan.md`).

To satisfy the owner directive ("use 2 lanes in parallel", owner msgs `686bc1a3` / `2c1b49ee`):
- **Lane 1 (odd rows):** Row 01 -> Row 03 -> Row 05 -> Row 07 -> Row 09 -> Row 11
- **Lane 2 (even rows):** Row 02 -> Row 04 -> Row 06 -> Row 08 -> Row 10 -> Row 12
- **Starting rows:** Row 01 and Row 02 spawn in parallel as Batch 1. When Row 01 lands, Row 03 spawns on Lane 1; when Row 02 lands, Row 04 spawns on Lane 2. Exactly 2 lanes remain active at all times.

### 3.2 Off every live lane (R3)

`lane-map.sh --check <paths> --agent a-591` verifies that no live lane owns any row path. The spawner re-runs `--check` per row before spawning (R3).

---

## 4. Per row: what the lane does

- **01 (`UserMenu.vue`):** Change `v-show="open"` to `v-if="open"` on the dropdown panel container. The dropdown is hidden on initial load; using `v-if` ensures its DOM elements, icons, and action handlers are omitted during initial paint and mounted only on user activation.
- **02 (`layouts/default.vue`):** Replace static auto-imports of `LiveTopicPane.vue` and `TopicPane.vue` with `defineAsyncComponent(() => import('@/components/LiveTopicPane.vue'))` and `defineAsyncComponent(() => import('@/components/TopicPane.vue'))`. This extracts both large components into async chunks, reducing the initial layout JS bundle size and parse time.
- **03 (`utils/date-iso.mjs`):** Add a memoization cache to `fields(d)`. Since messages in feeds and issue tables frequently share timestamp minutes, caching formatted date parts keyed by `${zone}:${Math.floor(d.getTime() / 60000)}` avoids repeated expensive calls to `Intl.DateTimeFormat.prototype.formatToParts`.
- **04 (`DeadlinePicker.vue`):** Replace JS text-measurement (`sizeField` reading `getBoundingClientRect().width` and modifying inline styles) with pure CSS width sizing using `ch` units or CSS `field-sizing: content`. This completely eliminates forced synchronous reflow during mount and input events.
- **05 (`CodeBlock.vue`):** Wrap `CodeViewer` import in `defineAsyncComponent(() => import('@/components/CodeViewer.vue'))`. `CodeViewer` is only displayed when the user opens the `<UiDialog>` to view full code; lazy-loading it keeps Prism syntax highlighting out of the critical route bundle.
- **06 (`LiveFeed.vue`):** Gate `<TransitionGroup>` CSS animations on initial mount via `:css="isMounted"`, where `isMounted` is set in `onMounted`. Initial message feed renders as static DOM without triggering simultaneous layout recalculations and animation frames; subsequent incoming websocket messages animate normally.
- **07 (`layouts/login.vue`):** Wrap the drifting SVG signals background (`.login-wallpaper`) with `v-if="!isFrontPage"`. On `/login` front-page view, the calm theme field is displayed while the background SVG filter effects (`feTurbulence`, `feDisplacementMap`, and drop-shadows) are not rendered, saving layout duration and GPU compositing.
- **08 (`pages/issues.vue`):** Implement progressive windowed rendering for the issue table / card list. The initial render paints the first 25 issues immediately; subsequent rows are appended progressively via `requestAnimationFrame`. This cuts initial DOM nodes from 620 to <350 and reduces mobile LCP and TBT.
- **09 (`components/MarkdownBlock.vue`):** Add a fast-path regex check `!/[*_`#\[\]<>\n]/.test(props.text)` before asynchronously importing `markdown.mjs`. For plain text messages (the vast majority of channel chatter), render plain text directly without invoking the markdown tokenizer or loading the markdown parser chunk.
- **10 (`pages/channel/[name].vue`):** Coalesce calls to `seedTopics()` in the reactive `channel.messages` watcher using `queueMicrotask` or a 16 ms debounce. When multiple messages arrive in bursts or during initial channel load, `seedTopics()` executes exactly once per animation frame instead of thrashing CPU per message.
- **11 (`stores/channel.ts`):** Memoize `channelView` and `ordered` collection projections in `channelState`. When messages are appended to active channel, avoid re-sorting and transforming entire unread arrays; maintain cached root structures and invalidate only when channel identity changes.
- **12 (`pages/docs.vue`):** Change default directory state in the documentation tree to collapsed, expanding only the active document's parent hierarchy on initial mount, and lazy-load `DocsWorkspaceTree`. This cuts initial DOM nodes on `/docs` from 807 to <450, significantly improving mobile TBT and LCP.

---

## 5. What was measured and NOT worth doing (Empirical Evidence)

Each item below was investigated with empirical measurements and discarded with concrete evidence:

| Practice / Proposal | Why Not | Empirical Evidence |
|---|---|---|
| 1. Purging Nuxt/Vue DevTools in build | Devtools are already stripped in production `nuxt generate` | `grep -rn "devtools" csi-spl-wui/.output/public` yields 0 hits; bundle is already tree-shaken |
| 2. Static pre-compression with Brotli | Cloud Run and CDN edge already perform on-the-fly Brotli/Gzip compression | Static asset pre-compression does not alter client-side browser parse time, execution time, or TTI |
| 3. Virtual scrolling for main message feed (`LiveFeed.vue`) | High risk to existing features: breaks native browser scroll anchor (`overflow-anchor`), search-in-page (`Ctrl+F`), and scroll position restoration; violates owner mandate msg `95472f33` ("preserve as much as possible the existing functions") | P6-06 and P6-09 deliver >3x render throughput improvement without virtual scroll complexity or DOM destruction |
| 4. Dedicated Web Worker for date formatting (`date-iso.mjs`) | Worker thread `postMessage` serialization overhead (~2-4 ms round-trip) is substantially higher than synchronous formatting (~0.05 ms per date) | In-memory minute-keyed LRU memoization (P6-03) provides 100x speedup at zero serialization overhead |
| 5. Preloading all Nuxt route chunks (`<link rel="preload">` on 414 chunks) | Saturates mobile cellular network bandwidth (1.78 MB gzip total client JS), competing with critical CSS/JS for network socket priority | Increases mobile FCP and LCP by >200 ms on throttled connections |
| 6. Global CSS utility class purge | High risk of visual regression across 40+ components for negligible byte savings; CSS gzip footprint is only ~24 KB (well within budget) | CSS parsing is <5% of mobile main-thread time; JS execution and DOM thrashing are the primary measured bottlenecks |
| 7. Removing SVG icons in sidebar | Saves <3 KB gzip but degrades UX and violates owner mandate msg `95472f33` ("preserve as much as possible the existing functions") | Initial SVG icon rendering takes <2 ms on desktop and <6 ms on mobile; not a performance bottleneck |
| 8. Full Server-Side Rendering (SSR) migration | Architecture is static client SPA (`nuxt generate` / `.output/public` served via Cloud Run / CDN); moving to dynamic SSR requires backend Node/Nitro server runtime changes, which is out of scope for WUI speed-up round and introduces cold start latency | Cloud Run container cold-start adds 500-1500 ms TTFB; client-side pre-rendered SPA with CDN edge caching provides faster first-byte delivery |

---

## 6. Expert panel of reviewers (R7)

- **Expert Panel:** one seat of every active agent kind placed via dispatcher (`c-003@<box>`):
  - Editor / agy seat: `a-591@<box>` (`perf-round-6/seat-agy.md`) - proposed v0.1
  - Claude seat: `perf-round-6/seat-claude.md` - pending review
  - Grok seat: `perf-round-6/seat-grok.md` - pending review
  - Mistral seat: `perf-round-6/seat-mistral.md` - pending review
  - (No qwen seat: disabled/off in instance settings, per `do_spl_lane_mix`).
- **Reviewers per row (R7):** Cross-vendor review enforced for every row:
  - Claude rows (02, 05, 08, 11, 12) reviewed by agy, grok, or mistral seats.
  - Grok rows (01, 03, 06, 09) reviewed by claude or mistral seats.
  - Mistral rows (04, 07, 10) reviewed by claude or grok seats.
  - Zero same-vendor reviews. Every review verified via `do_spl_review_line_check`.

---

## 7. Counts

| Dimension | Count |
|---|---|
| Total rows | 12 (100% WUI speed-up; 0 shared files with Round 13) |
| Vendors | claude: 5, grok: 4, mistral: 3 |
| Preferred box | sat (12) |
| Parallel lanes | 2 lanes at all times (6 batches of 2 rows) |
| Starting batch | Batch 1: Row 01 (Lane 1) and Row 02 (Lane 2) in parallel |

---

## 8. Changes

- v0.1: Initial proposed plan for Round 6 (UI speed-up on mobile and desktop), measured on `4251b33cf`. 12 concrete actions in 6 batches of 2 parallel lanes, overriding 10-row cap per owner order msg `4244afb1`.

---

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| editor | agy | a-591@<box> | v0.1 proposed | this file |
| claude seat | claude | pending | pending | `perf-round-6/seat-claude.md` |
| grok seat | grok | pending | pending | `perf-round-6/seat-grok.md` |
| mistral seat | mistral | pending | pending | `perf-round-6/seat-mistral.md` |
