# Perf round 20 (p20) - mobile web UI speed - plan (7 rows, v0.1)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6364  
Topic: e27b8cce-476e-48e0-9737-d682e644b998  

A perf round under section 4 of [rounds-rulebook.md](rounds-rulebook.md). The
plan points to the rules and does not copy them:

- Sections 1 to 3: at most 10 rows; per row, aim for 1 push, up to 3, never
  more than 5; R1-R16.
- Sections 4.1 to 4.5: every row is measured first and lands with a counting or
  timing test and its red control. A candidate with no measured gain is
  dropped.
- Section 5.1 says aim at 2 rows. **This round has 7: the owner set the
  count** (below); 1.1's cap of 10 holds.

Owner orders that bind this round (t1 #refactoring, HUM-10, verbatim):

- 964a4063: "refactoring for UI speed on the mobile"
- d51ca870: "list 7 concrete tasks whic hwill bring most bang for the buck for
  improving the latency and speed of the UI on the desktop, create the issues
  for those and start working on them ... according to the prio". It was posted
  in the mobile topic; the holder's brief reads it as the same ask for the
  phone. Perf round 19 (planner c-778) takes the desktop.
- 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- 10-17 (t1 b61851fb): no mistral coding or testing rows, and no WUI row to
  mistral (developer guide 5.1). **Every row's vendor is claude.**

**Status: v0.1, draft for the panel.** Editor: c-084 (claude).

**Share (4.4)**, read at 11:54:33Z on `09f137d40` (n=1): `perf 29 refactor 100
perf-share 22.5% floor-met`.

**Slug (5.3)**, read at 11:54:33Z on `09f137d40`. Perf round 19 has no plan
commit yet (`git log origin/master -1 -E --grep='^docs\(p19-plan'` -> none),
so the window starts at the newest `docs(p18-plan` commit: `Window:
W=2026-11-18T16:51:12+01:00`. `git log origin/master --since="$W" --oneline -E
--grep='\(p20-' | wc -l` -> `0` (and `0` with no window); `git ls-remote origin
'refs/heads/review/p20-*' 'refs/heads/wip/*p20*' 'refs/heads/*-p20-*' | wc -l`
-> `0`.

**One tree.** `origin/master` `09f137d40`. Its `csi-spl-wui/` is the one prd
serves (WUI 3.6.7, commit `6c741f5b`, `<host>/build.json`) and the one CI
bundled (wf 10 run `45377752048`, head `3314cc4e5`): `git log --oneline
6c741f5b0..09f137d40 -- csi-spl-wui` and `3314cc4e5..09f137d40` -> 0 lines
each. Raw commands and outputs: [perf-round-20/editor.md](perf-round-20/editor.md).

**Profile.** A mid phone: 390 x 844, touch, device pixel ratio 3, CPU 4x
slower; network slow 4G (`fast4g` of the probes: 150 ms RTT, 9 Mbit/s down).
Measured on prd's test workspace `e2e` (prd `t1` is the owner's and refused by
the probes); nothing was posted or written.

<a id="p20-how-to-read"></a>

## 1. How to read this

- A row is one logical change made by one lane, subject
  `perf(p20-<NN>-<slug>, SPL-<n>): ...`, review branch `review/p20-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on the tree above.
  "editor N" = section N of [perf-round-20/editor.md](perf-round-20/editor.md).
- **Expected** = what the editor's numbers allow, "computed, not measured"
  where no second arm ran. A CPU-profile self time that holds a forced layout
  is an upper bound: part of that layout is needed before the next paint
  anyway. The lane measures both arms, and a row with no gain is dropped
  (4.1).
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that turns it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- **Timing, every row**: before the push, the lane A/Bs its step on a local
  `nuxt generate` mock bundle (`NUXT_PUBLIC_USE_MOCK=1`) under the phone
  profile, n >= 5 per arm, same box, interleaved; after dev serves it,
  `ENV=dev` the same probe (the probe and its command are in editor 4 and 5).
  Both in the commit body.
- Paths: `wui/` = `csi-spl-wui/`.

<a id="p20-inputs"></a>

## 2. Where the rows come from

| input | finding | here |
|---|---|---|
| new, editor 3: first load, phone, cold, slow 4G, n=5 | rail at **5,042 ms** median (p90 6,731); **249 requests / 1,146 KB** before it; all **92 prefetches (428 KB)** start before it; **313..329 KB** of them the rail never uses | row 07 |
| new, editor 4: first load, phone, warm, CPU 4x, n=5 | rail **3,108 ms**; blocking time before rail **1,290 ms**; 14 long tasks, longest **762 ms**; script 995, layout+style 527 ms | rows 01, 02; section 6 (the long task) |
| new, editor 4: the profiled load (n=1) | `measureFoot` 132.7 ms self, the load's hottest app function; on a phone its answer is always `false` | **row 02** |
| new, editor 5: clicks, phone, n=5 | channel open **881 ms**, topic open **531 ms**, channel switch **525 ms**; each needs one ~160 ms read, so most of the step is the phone's own work | rows 01, 03..06 |
| new, editor 5: CPU profile of the clicks, n=3 | `fitStrip` 308.8 ms; `holdCard` 182.8; `measureJump` 154.5; `measureBox` 113.5 (self ms over 3 opens) | **rows 01, 03, 04, 05** |
| new, editor 5 + initiator trace (section 3, row 06) | every `PUT /v1/me/reads` (this tab's own read push) is answered by a full `GET /v1/view/channels`: 4 pairs in one channel open + one topic open | **row 06** |
| spec 066 field data (`do_spl_wui_perf_report`) | not readable here (editor 6): no row cites a field p75 | section 6, asked |
| spec 109 T003 / T014 | dropping `/`'s 85 modulepreloads made the first row slower (import waterfall); a smaller `/` needs a smaller default-layout closure | section 6 |
| `perf-budgets.json` basis, SPL-6342 | the entry chunk lost the hub socket (-3.0 KB); `ci_initial_gzip_kb` 151.7 on the box (editor 2) | - |
| perf rounds 13..18 | CI rows only (wf 10 jobs, e2e shards); none is a phone row | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: editor 3..5 |

<a id="p20-rows"></a>

## 3. The rows

In priority order: gain per cost, highest first.

| # | id | practice | baseline (command, number, n) | expected | sites (file:line) | test + red control (C2) | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p20-01-wui-loop-strip-width-once)` | the phone's rail strip reads its own width only when its width can change: `fitStrip` keeps the width the ResizeObserver callback read (after the browser's layout, as the file's header says of the first centre), and a route change's `place()` uses it instead of reading `box.clientWidth` right after the new view was written | editor 5, CPU profile, prd `e2e`, phone, n=3 channel opens: `fitStrip` **308.8 ms** self (~103 ms an open), native `getBoundingClientRect` 159.7 ms; channel open **881 ms** median (590..1,129, n=5) | computed, not measured: up to ~100 ms off each channel open, channel switch and rail tab change that changes the route | `wui/src/composables/useLoopStrip.ts:170-205` (`fitStrip`, `place`), `:232` (the route watch); its test; 2 files | **`tests/unit/loop-strip-route-reads.test.mjs`** (new): a stub strip whose `clientWidth` / `getBoundingClientRect` getters count; after mount and one ResizeObserver tick, a `watchKey` change runs `place()` with **0** reads of `clientWidth`; a resize still reads it once. Red: today's file -> 1 `clientWidth` read per route change. Also run: `loop-strip-mount.test.mjs`, `strip-fit.test.mjs`, `section-strip.test.mjs`, e2e `section-strip-mobile`, `section-strip-scroll-hide`, `section-strip-kbd-fold`, `rail-order-default` | claude / simple_coding | 1 |
| 02 | `perf(p20-02-wui-sidebar-foot-no-measure-phone)` | `measureFoot` answers `false` on a phone before any layout read; on a phone the ResizeObserver is not attached and the route watch does not schedule it | editor 4, `do_spl_wui_perf_first_load` m390 `FL_CPU_PROFILE=1`: `measureFoot` **132.7 ms** self in the profiled load (n=1), the hottest app function; rail **3,108 ms**, blocking time before rail **1,290 ms** (n=5) | computed, not measured: up to ~130 ms of main thread off a phone's first load, and its share of every route change | `wui/src/composables/useSidebarVersion.ts:86-107` (`useFootClock`); its test; 2 files | **`tests/unit/sidebar-foot-phone.test.mjs`** (new): with `phone` true, mount + a route change read **0** `getBoundingClientRect` / `getComputedStyle` and observe nothing; with `phone` false the clock still moves to the foot row (CONTROL). Red: today's file -> 1 read per call on a phone. Also run: e2e `rail-only-sidebar-unmounted`, unit `channel-sidebar-src` users (`grep -rl channel-sidebar-src tests/unit`) | claude / simple_coding | 1 |
| 03 | `perf(p20-03-wui-topic-open-hold-card-cheap)` | the topic-open "hold the card still" loop (`holdCard`) stops reading `getBoundingClientRect()` every frame once nothing above the card is loading: it waits on the scroller's ResizeObserver (as `followTopicPane` does, `:241`) instead of a per-frame read, with the same end condition and cap | editor 5, n=3 topic opens: `holdCard` **182.8 ms** self (~61 ms an open); topic open **531 ms** median (326..571, n=5) | computed, not measured: up to ~60 ms off each topic open | `wui/src/utils/parent-section-open.mjs:131-156` (`holdCard`), `:157` (`landCard`) only if its call changes; its test; 2 files | **`tests/unit/parent-section-hold-reads.test.mjs`** (new): a fake card + scroller with counting rect getters and a fake `requestAnimationFrame`; a card whose position is already still is read at most **2** times (today: once per frame until the hold count). Red: today's file -> the per-frame count. Also run: `parent-section.test.mjs`, `util-docs.test.mjs`, e2e `poll-answer-no-scroll`, `topic-page-open-in-channels`, `feed-virtual-rows`, `move-by-drag` | claude / simple_coding | 1 |
| 04 | `perf(p20-04-wui-thread-ends-measure-once)` | `measureJump` runs once per frame at most and only while the thread-end control can show: it batches the watch, the mount and the ResizeObserver callers into one `requestAnimationFrame`, and reads nothing when `phone` is false or `holdScroll()` is not true (today it reads first on some paths) | editor 5, n=3 topic opens: `measureJump` **154.5 ms** self (~51 ms an open) | computed, not measured: up to ~50 ms off each topic open | `wui/src/composables/useLiveFeedThreadEnds.ts:23-66`; its test; 2 files | **`tests/unit/thread-ends-measure.test.mjs`** (new) or a case in `thread-jump.test.mjs`: three triggers in one frame (`rowCount` change, mount, resize) -> **1** read of `scrollHeight`; `holdScroll()` false -> **0**. Red: today's file -> 3 reads. Also run: `thread-jump.test.mjs`, e2e files the pre-push map selects for it (`WUI_E2E_RANGE`) | claude / simple_coding | 1 |
| 05 | `perf(p20-05-wui-card-clip-measure-batch)` | a message card's clip measure (`measureBox`) reads its line height once per feed, not once per card: the computed `line-height` / `font-size` of `.msg-body` is the same for every card of a feed, so it is read once and shared; `scrollHeight` stays per card, read in the ResizeObserver callback | editor 5, n=3 channel opens: `measureBox` **113.5 ms** self over 3 opens of a channel with **1** card (~38 ms a card) | computed, not measured: the lane measures on a mock channel of >= 20 cards (prd `e2e` has 1); dropped if the A/B shows no gain | `wui/src/composables/useCardHeight.ts:52-62` (`measureBox`) and its callers `:98-108` (`startObserving`); its test; 2 files | **`tests/unit/card-clip-measure.test.mjs`** (new): 20 cards mounted in one feed call `getComputedStyle` **1** time, not 20; a card whose font changes is re-read (CONTROL). Red: today's file -> 20. Also run: `card-grip.test.mjs`, `message-card-src` users, e2e `poll-card-clip`, `markdown-table`, `link-preview` | claude / simple_coding | 1 |
| 06 | `perf(p20-06-wui-read-push-no-channel-reload)` | the answer to this tab's own `PUT /v1/me/reads` does not reload the whole channel list: a `ch:` key moved only by what this tab just sent updates that channel's count in place; a move that came from another tab or device still reloads, as today | editor 5 and the initiator trace (CDP `Network.requestWillBeSent.initiator`, prd `e2e`, phone, n=1 session): **4 of 4** `PUT /v1/me/reads` in one channel open + one topic open were followed by `GET /v1/view/channels?read=...` from `onMoved` -> `listChannels`; 5 of 5 probe rounds read `view/channels` on each open | computed, not measured: one hub read (~160 ms on slow 4G, its body ~0.6 KB) and one channel-list recompute fewer per read push (every 5 s while reading, `PUSH_MS`) | `wui/src/utils/read-sync.mjs:54-79` (`mergeMarks`), `:115-148` (`take`, `push`); `wui/src/utils/read-sync-boot.ts:101`; their tests; 3 or 4 files. The lane first logs the PUT's answer next to what was sent (no body text in the commit: keys and timestamps only) and names which field moves the key | **`tests/unit/read-sync.test.mjs`** (a new case): a PUT whose answer echoes the sent marks plus the hub's cursor reports **no** `ch:` move, so `loadChannels` is called **0** times; an answer with a later mark from elsewhere still moves it (CONTROL). Red: the case on today's file -> moved, 1 call. Also run: `read-sync-delta-reply.test.mjs`, `dm-counts-parity.test.mjs`, `request-waterfall.test.mjs`, `swallow-reasons.test.mjs`, `hours-recorder.test.mjs` | claude / complex_coding | 1 |
| 07 | `perf(p20-07-wui-home-prefetch-after-rail)` | the signed-in `/` document holds its `<link rel="prefetch">` hints until the app is ready, as the sign-in page already does (P3-04, `deferDocumentPrefetch` + `prefetch-on-ready.client.ts`); its modulepreload set (the first screen) does not change | editor 3, `do_spl_wui_perf_first_load_net` prd `e2e`, m390, cold, fast4g, n=5: rail **5,042 ms** median (4,050..6,731); **1,145.7 KB** before it, of which prefetch **428.5 KB** (92 requests), and **313..329 KB** of it unused by the rail (42 chunks never in rail + 4 s, ~30 only after the rail) | computed, not measured: ~0.3 MB less competing with the rail on a cold phone (~0.28 s of 9 Mbit/s); warm loads unchanged. Must not slow desktop: CLE-77933 kept these hints because without them the rail came later; the lane A/Bs `d1440` too and drops the row if either profile is slower | `wui/nuxt.config.ts:561-562` (the `layout === "login"` condition only); `wui/src/utils/first-screen-hints.mjs:151` only if a flag is needed; its test; 2 or 3 files | **`tests/unit/first-screen-hints.test.mjs`** (a new case): a prerendered signed-in `/` keeps its modulepreload links in `<head>` and has **0** `rel="prefetch"` there (all inside the deferred template). Red: today -> 92 in `<head>`. Gate: `perf-budget.py bundle` `ci_home_gzip_kb` and `ci_initial_gzip_kb` unchanged (runner node or same-box A/B delta). Timing: the editor 3 command on dev, cold and warm, m390 and d1440, n=10 | claude / simple_coding | 2 (after c-980) |

<a id="p20-batches"></a>

### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01 to 06, each on its own files (below); they may run at
  once. **Batch 2**: row 07, once c-980 (SPL-5070, Nuxt 3 -> 4) has landed
  or ended (R16: placed within 30 minutes of that).
  - 01: `useLoopStrip.ts` + its new test.
  - 02: `useSidebarVersion.ts` + its new test.
  - 03: `parent-section-open.mjs` + its new test.
  - 04: `useLiveFeedThreadEnds.ts` + its new test (or `thread-jump.test.mjs`).
  - 05: `useCardHeight.ts` + its new test.
  - 06: `read-sync.mjs`, `read-sync-boot.ts`, `read-sync.test.mjs`.
  - 07: `nuxt.config.ts` (the first-screen hints module only),
    `first-screen-hints.mjs`, `first-screen-hints.test.mjs`.
- No row edits `ChannelSidebar.vue`, `LiveFeed.vue`, `MessageCard.vue`,
  `stores/channel.ts`, `TopBar.vue` or `layouts/default.vue`: the queued spec
  186 and 189 lanes name the first four (3.2), and the component files are
  left to the rows' composables. A row whose fix needs one of them stops and
  tells the holder.
- `perf-budgets.json` and `perf-budget.py`: no row edits them (c-980 changes
  both).

<a id="p20-r3"></a>

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-24, each with its time:

- **Lane map, every machine**, 11:53:12Z: `--check` of the 11 row and plan
  files -> exit 3, one path: `csi-spl-wui/nuxt.config.ts` owned by c-980
  (`c-980-c002-spl5070-nuxt4-migration-r2`, changed in its worktree). Every
  other path free. Hence row 07 is batch 2.
- **c-980** (SPL-5070): its diff against `origin/master` touches
  `nuxt.config.ts`, `package.json`, `pnpm-lock.yaml`, `perf-budget.py`,
  `perf-budgets.json`, `i18n/client-loaders.ts`, `perf-mark-core.mjs`,
  `public-seo.mjs`, `pages/blog.vue` and e2e/unit tests; none is a row file
  of 01..06. Holder, 11:2xZ: not landed, its push held (hosted e2e red).
- **Spawn queue**, 11:53:38Z: 13 queued, 0 placing. WUI ones: spec 186 M3
  (`LiveFeed.vue`, `MessageCard.vue`, `MessageComposer.vue`, ...), held on
  SPL-6345. None names a row file.
- **Briefs**: `c002-s189-b1-b7-topic-list-end-build` names `LiveFeed.vue`,
  `MessageCard.vue`, `channel.ts`; no row edits them (3.1). The other briefs
  that name a row file (`useLoopStrip`, `useCardHeight`,
  `useLiveFeedThreadEnds`, `parent-section-open`, `read-sync-boot`) are of
  lanes not on the lane map at 11:53:12Z; their last trunk changes are
  2026-10-16 .. 2026-11-08.
- **Live s186 lanes**: `c-038` (v06) has no WUI change in its worktree
  (`git diff --name-only origin/master...HEAD; git status --short` -> none
  under `csi-spl-wui`).
- **Open bug and refactor rounds**: bug rounds 28 and 29 name
  `LanguageSwitcher.vue`, `commit-links.ts`, `kind-picker-keys.ts`, the blog
  e2e; refactor rounds 78 and 79 name no WUI file. No overlap.
- **Perf round 19** (desktop, planner c-778): this seat sent it the 7 rows'
  files at 11:57:49Z (msg 5fca9c3f, cc the holder) and waits for its list. A
  fix both rounds want goes to one round only (holder, msg ecf93405); the
  agreement is folded into v1.0.
- The holder re-runs this check before each spawn.

<a id="p20-per-row"></a>

## 4. Per row: what the lane does

- **Every row**: read the editor's section for its numbers first; re-measure
  the baseline on the sha the lane starts from (prd moves with every WUI
  deploy); name both shas in the commit body. A row with no gain in its A/B is
  dropped (4.1) with its numbers, sent to the holder.
- **01**: the header of `useLoopStrip.ts` already says the first centre is
  read in the ResizeObserver callback "so the read is not a forced layout";
  the route watch path breaks that. Keep `on`, the copies and the snap
  behaviour exactly; the strip still centres the selected control after a
  route change (e2e `section-strip-mobile`).
- **02**: the foot clock is desktop-only by design (`be316fdc`); only the
  phone path changes. `LastDataClock` placement on desktop is the CONTROL.
- **03**: the hold exists so a card does not jump while the sections above it
  load (`holdCard`, `landCard`); keep its end condition and cap. If a
  ResizeObserver cannot see the cause of a move, the lane says so and keeps a
  read per frame only while such a cause is pending.
- **04**: same visible behaviour: the jump control shows and hides as today
  (`thread-jump.test.mjs`).
- **05**: the lane builds the mock channel of >= 20 cards from the mock
  store, not prd; if one shared read per feed is not safe (cards of mixed
  fonts), it reads once per distinct `.msg-body` class and says so.
- **06**: correctness first: unread counts must stay right on this tab and
  on others. The echo rule must not swallow a move made elsewhere between the
  PUT and its answer (the CONTROL). If the answer cannot tell the two apart,
  the row is reshaped with the holder (a hub change is out of this round).
- **07**: the deferral already exists for the sign-in screen; this row
  extends its condition to the signed-in home and changes nothing else. It
  waits for c-980 because `nuxt.config.ts` is c-980's, and it re-reads the
  Nuxt 4 config before it starts.

<a id="p20-panel"></a>

## 5. Panel and reviewers (R7)

- **Plan panel (rulebook 3.2)**: editor c-084 (claude) and the seats the
  holder places under the current R7 rule (as in p12 to p18: one mistral
  seat; grok or agy when one is placeable). Asked of the holder with the v0.1
  sha. A seat signs only a sha this editor names.
- **Row reviewers (2.7.2)**: the row authors are claude. Code R7 is the
  holder's pick at placement, of another vendor, never a plan seat. A WUI row
  never goes to mistral (developer guide 5.1). A row never pushes without its
  R7 PASS; the review line names the e2e files the pre-push map selects
  (2.7.4, SPL-3438).

<a id="p20-left-out"></a>

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| the first load's longest task (762 ms median) and the vendor / entry chunks' self time (1,345 / 760 ms) | **not a row yet**: no single site; a split needs a per-task trace, not a sampling profile of one load | editor 4, n=5 / n=1 |
| a smaller default-layout closure (`MergeConfirmDialog`, five toasts, `SidebarRowMenu`, `NotificationCenter` in the first-screen layout chunk, 53.9 KB gzip) | **next round**: it edits `layouts/default.vue` and `ChannelSidebar.vue`, which queued lanes name (3.1); spec 109 T003 shows the bytes must come from this closure, not from dropping preloads | editor 2; spec 109 T003 |
| `GET /v1/view/search/operators` before the rail on every load | **not a row**: one 1.9 KB read in parallel with ten others; no time shown. Cheap if a later round wants the request count | editor 3, n=5 of 5 |
| `view/channels` read twice before the rail | **folded into row 06** if its second read is the boot read sync's move (`read-sync-boot.ts:101`); the lane checks it | editor 3, n=5 of 5 |
| scrolling a long topic | **not measurable here**: prd `e2e` has no long topic (no scroller, 5 of 5) | editor 5 |
| search | **not measured**: the probe's end marker did not match (5 of 5) | editor 5 |
| posting | **not run**: a post writes prd | - |
| field p75 per (metric, device, view) | **asked**: `do_spl_wui_perf_report` needs a workspace admin's sign-in that this seat does not hold; the holder is asked to run `ENV=prd PERF_DAYS=7 ./run -a do_spl_wui_perf_report` and send the `m390`/phone rows, so v1.0 can cite them | editor 6 |
| the Flow / Event log probe on a phone | **not perf work**: `do_spl_wui_perf_flow_events` errors on every m390 round (a navigation); sent to the orchestrator as its own ask | editor 6 |

<a id="p20-counts"></a>

## 7. Counts

- Rows: 7 in v0.1, the owner's count (rulebook 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --since=2026-11-18T16:51:12+01:00 --grep='(p20-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --since=2026-11-18T16:51:12+01:00 --grep='p20-' --format=%B | grep -c '^review: '` must reach the row count.

<a id="p20-changes"></a>

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 18. From then on the Qto doc is the primary copy.

- v0.1 (c-084, 2026-11-24 12:0xZ): first draft on `09f137d40`.

<a id="p20-consensus"></a>

## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-084 (editor) | claude | v0.1 | author |
