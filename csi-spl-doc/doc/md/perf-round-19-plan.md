# Perf round 19 (p19) - plan (6 rows, v1.0)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6363  
Topic: 4369bb74-1889-402e-8388-a30332f3c5f8  

This round follows section 4 of [rounds-rulebook.md](rounds-rulebook.md)
(perf rounds). The plan points to the rules and does not copy them:

- Sections 1 to 3: per row, aim for 1 push, up to 3, never more than 5;
  R1-R16.
- Sections 4.1 to 4.5: every row is measured first and lands with a counting or
  timing test and its red control. A candidate with no measured gain is
  dropped.
- **Row count: 6; 04 dropped, measured.** The owner asked for 7 (HUM-10, t1 4369bb74, msg 6eb7d949: "list 7
  concrete tasks whic hwill bring most bang for the buck for improving the
  latency and speed of the UI on the desktop"). This overrides section 5.1
  (aim at 2) for this round only; section 1.1 (at most 10) holds. Row 04's
  gain was measured gone and no measured candidate replaces it, so the
  dispatch holder ruled 6 rows (seat c-996 N9).

Owner orders that bind this round:

- HUM-10 msgs 20a0121d ("refactoring for UI speed on the desktop"), 6eb7d949
  (above), 2737efe6 ("create the issues for those and start working on them
  ... according to the prio"): the rows are placed in the order of section 3.
- HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Every row's
  vendor is claude.**
- **6 rows, not 7.** Row 04 is dropped by its measurement on today's tree
  (section 6), and no measured candidate takes its place: the one lead left
  (L5, the cold `/lobby` forced layouts) is in perf round 20's files
  (section 6). The holder decides whether the round runs with 6.

**Status: v1.0, for the panel** (send-back of v0.1 `d86a2f880`: seat c-996,
W1-W4, N1-N8). Editor: c-778 (claude).

<a id="p19-how-to-read"></a>

## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p19-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p19-<NN>`
  (rulebook 4.5).
- **Two trees, and today's is the one that counts.** v0.1 measured on
  `7e31ade12` (Nuxt 3). Since then `295f426dd` (Nuxt 3 -> 4, vue-router 5,
  vite 8) and `71d9941e3` (CI node 22) landed: `git log --oneline
  7e31ade12..0f872e92e -- csi-spl-wui | wc -l` -> `19`, and on the row files
  -> `0`. v1.0 re-read **one count per row on `0f872e92e`** (`origin/master`
  at 18:43Z 2026-11-24), same box, same hour, the old bundle beside it
  (editor 2.11). Every row below quotes the `0f872e92e` number first.
- **Mock** = a `nuxt generate` with wf 10's mock env, served locally
  (`serve-generated.mjs`), desktop viewport 1440 x 900, headless Chrome.
  `0f872e92e`: node 20.20.2, the only node on this box; CI now uses node 22,
  so each lane's red control re-reads its before-number on its own rebased
  tree with the CI node, quotes it in the commit body, and **drops the row
  if the gain is gone** (rulebook 4.3). **Dev** = the dev host's own harness
  actions, read only; v1.0's dev read is build 3.7.6, commit `0f872e92`.
- **Same-box A/B, n>=5 per arm** (section 3.3): every row measures its count
  before and after on one box in one hour, at least 5 runs per arm, and puts
  both arms in the commit body. The count is the primary metric; ms are
  reported, never ranked.
- **Counts rank the rows; ms do not.** The box ran at 1-min load 35..124 (16
  cores) during every measurement, so a wall or script ms below is a box
  reading. Layouts, style recalcs, DOM nodes, listeners and request counts do
  not move with load: the n=5 journey gave the same count in 5 of 5 rounds,
  the n=3 typing traces the same forced-layout count in 3 of 3 (editor 2.5,
  2.7).
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `wui/` = `csi-spl-wui/`, `src/` = `csi-spl-wui/src/`.
- Raw commands, outputs and the probes: [perf-round-19/editor.md](perf-round-19/editor.md).

<a id="p19-inputs"></a>

## 2. Where the rows come from

| input | finding | here |
|---|---|---|
| this seat: desktop journey probe on the mock, n=5 (editor 2.5) | 40 typed characters in the top-bar field cost **172 layouts and 176 style recalcs** in 5 of 5 rounds | rows 01, 02 |
| this seat: Chrome traces of 41 typed keys, with forced-layout stacks, n=3 (editor 2.7) | per key, **3 layouts forced from script**: 1 in `useComposerWrap`'s text-width measure, 2 in `useComposerSize.fitGlobalBox` | rows 01, 02 |
| this seat: journey with forced GC + heap snapshots (editor 2.8) | a search's hit list is **never released**: its DOM and its `HumanName` instances stay reachable after the next search and after leaving `/search` | row 03 |
| this seat: dev first screen, `do_spl_wui_perf_flow_events`, n=6 (editor 2.6) | `GET /v1/view/me` read **twice** in 4 of 6 first screens, both 200; on dev 3.7.6 (`0f872e92`, editor 2.11): 1 in each of 6 | row 04, **dropped in v1.0** |
| this seat: `Notification.permission` timed in the page, n=5 (editor 2.9) | the first read takes **1.1..54 ms** (median 10.9) and runs while the notification store hydrates | row 05 |
| this seat: dev Flow open, n=6 (editor 2.6) | `GET /v1/wui/revision` **12 times in 6 Flow-open steps** | row 06 |
| this seat: dev first load, `do_spl_wui_perf_first_load`, n=8, and the dev CPU profile, n=1 (editor 2.3, 2.4) | `useSidebarVersion` foot-row check and the Vite preload helper link walk are hot at first load | p20 rows (section 6) |
| p20 plan v0.2 (`fd664e5b0`, c-084) | rows 01..07 on mobile, row 07 = app-document prefetch after the rail, desktop baseline from this seat | section 6, R1 |
| `perf-round-18-plan.md` section 6, `lesson-speed-up-measure-first.md`, specs 027 and 066 | measure first, counting tests; no carried WUI candidate | - |

<a id="p19-rows"></a>

## 3. The rows

In priority order (gain per cost): 01, 02, 03, 06, 05, 07 (v1.0 ranks 05 below 06: its gain is ms only, N4). Row ids stay as in v0.1. Each row aims at 1 push; 3 at most.

| # | id | change | baseline (command, number, n, sha) | expected gain | files | test + red control (C2) | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p19-01-wui-composer-fit-no-collapse)` | `fitGlobalBox` stops collapsing the field to `height: auto` and re-reading `scrollHeight` on every key while the draft still fits its height: read `scrollHeight` once, write the height only when it changes, collapse only when text was removed. The owner's caret rules in the same function (t1 d3bbe2c2: the caret at the end stays in view, the scroll is kept) do not change | **`0f872e92e`** (editor 2.11): Chrome trace of 41 keys typed into `form.composer.omnibox--global textarea` on the mock `/lobby`: **82 forced layouts** from `fitGlobalBox` (41 at the `scrollHeight > clientHeight` read, 41 at the read after `height = 'auto'`), 3 of 3 traces; journey type-40 **172 layouts / 176 recalcs** in 5 of 5. Same on `7e31ade12` (editor 2.5, 2.7) | -41 to -82 forced layouts per 40 keys (at most one read per key, none when nothing changed); computed, not measured: about 2/3 of typing's forced layout time (all forced layouts of the 41 keys: 163..239 ms, n=3, load 83..120). The lane measures both arms | `src/composables/useComposerSize.ts` (`useFit.fitGlobalBox`, :53-79; with the `omniboxMax` reads of section 4, :39-79); `wui/tests/e2e/perf-typing-layouts.test.mjs` (new; row 02 extends it) | **`perf-typing-layouts.test.mjs`** (new e2e on the generated mock bundle, `puppeteer-core` (the WUI's e2e driver, `package.json:41`, no new dependency) + CDP `Performance.getMetrics`): type 40 characters into the top-bar field on `/lobby`, assert the `LayoutCount` delta <= a ceiling the lane sets from its after-arm (+10%), and that the field still grows on a second line and shrinks on delete. Red: the ceiling on `7e31ade12` reads 172 -> RED; after the fix GREEN. Also run and green: the unit test `tests/unit/composer-grow.test.mjs`, the e2e `composer-long-msg.test.mjs` and `composer-buttons-bottom.test.mjs`, the e2e files the pre-push map selects (`WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`), `pnpm run typecheck` | claude / simple_coding | 1 |
| 02 | `perf(p19-02-wui-composer-wrap-measure-text)` | `useComposerWrap`'s one-line test measures the draft's width with a canvas `measureText` and the field's font, read once per focus (and on a font-size change), instead of styling a hidden span and reading its `getBoundingClientRect` on every key | **`0f872e92e`** (editor 2.11), the same traces: **43 forced layouts** per 41 keys from the text-width measure (called from `syncMultiline` on every `text` change), 3 of 3 traces. Same on `7e31ade12` (editor 2.7) | -43 forced layouts per 41 keys; computed, not measured: about 1/3 of typing's forced layout time | `src/composables/useComposerWrap.ts` (the text-width measure); `wui/tests/e2e/perf-typing-layouts.test.mjs` (row 01's: its ceiling) | the row 01 test with its ceiling lowered to row 02's after-arm. Red: the lowered ceiling on row 01's tree -> RED. Plus a unit test that the canvas width of sample strings is within 1 px of the span width the old code read (fixture font), so the lifted-row decision does not change (owner t1 26282b6e). Also run and green: the row 01 list | claude / simple_coding | 2 (after 01: same e2e file) |
| 03 | `perf(p19-03-wui-search-hits-release)` | the search hit list releases its DOM and its `HumanName` instances when a new search replaces it and when the side panel closes. The lane finds the holder first: the snapshot shows the old hits' `HumanName` instances reachable from their scheduler jobs through a component vnode tree (editor 2.8) | **`0f872e92e`** (editor 2.11), the 3-step sequence below: **+1,908, +1,921, +1,921** retained (n=3); `7e31ade12` beside it, same hour: +1,922 x3. v0.1's read, editor 2.8, mock journey with forced GC (`HeapProfiler.collectGarbage` x2, CDP `Nodes`): `/lobby` **1,783** nodes -> search `q=line` with **30 hits** -> a search with 0 hits -> `/lobby`: **3,705** (+1,922 retained), same in 3 of 3; with 400 hits a second search adds them again: 17,597..17,799 -> 28,244..28,446 nodes, n=3; a 0-hit search alone retains +248 (n=1). `7e31ade12` | -1,600..-1,900 retained nodes per 30-hit search (the hub's one-section page is 30, `csi-spl-api/src/go/spool-hub-api/internal/hub/search.go:35`): the heap and every full GC stop growing with the searches a session makes | `src/components/SideHitList.vue`, `src/components/SearchSidePanel.vue`; `src/components/HumanName.vue` only if the holder is there (the lane names it; R3 re-check before that push); `wui/tests/e2e/perf-search-release.test.mjs` (new) | **`perf-search-release.test.mjs`** (new e2e, mock, CDP): seed 30 hits, run the 3-step sequence above with forced GC, assert retained `Nodes` <= the 0-hit run + 300 and `JSEventListeners` within +50. Red: on `7e31ade12` it reads +1,922 -> RED. Also run and green: `flow-search-acceptance.test.mjs`, `issue-parent-search.test.mjs`, the pre-push map's e2e, `pnpm run typecheck` | claude / complex_coding | 1 |
| ~~04~~ | **dropped in v1.0** (section 6): `perf(p19-04-wui-me-read-once)` | the first screen reads `GET /v1/view/me` once. The lane first finds the second caller (a `load(true)`, a second store, a sign-in flip; `stores/access.ts` dedupes only a read in flight). **Drop rule:** if the second read is a forced refresh the page needs, the row is dropped with that finding | v0.1, editor 2.6 (dev 3.6.7): `/v1/view/me` 10 reads in 6 first screens. **v1.0, editor 2.11, the same action on dev 3.7.6 (`0f872e92`): 6 reads in 6 first screens** (1 each): the duplicate is gone | -1 hub read in 2 of 3 first screens (-66 ms median client wait where it is on the path; the lane says whether it is) | `src/stores/access.ts`; the second caller's file if it is elsewhere (named in the push; R3 re-check) | a unit test counting `api.me()` calls across the first-screen callers, asserting 1. Red: today's code -> 2. Live: the same flow-events run on dev after the deploy (R5), its count in the issue | claude / simple_coding | 1 |
| 06 | `perf(p19-06-wui-revision-check-once)` | one `GET /v1/wui/revision` per trigger: the lane finds why a Flow-open step reads it twice (the interval and the visibility check together, or two `watchLive` hooks) and makes concurrent checks share one fetch. **Drop rule:** if the two reads have triggers that each must run, the row is dropped with that finding | **dev 3.7.6, `0f872e92`** (editor 2.11), `ENV=dev PF_N=6 PF_PROFILES=d1440 ./run -a do_spl_wui_perf_flow_events`: `/v1/wui/revision` **12 reads in 6 flow-open steps**, client median 69 / p90 135 ms; v0.1 (3.6.7): 12 in 6. The step's Flow selector matched in neither run (flow-open -1), so the trigger is not yet tied to opening Flow (N3): the lane attributes it first, the drop rule covers it | -1 request per step; off the paint path (the check never blocks a view), so the gain is network and hub load, not a wait | `src/utils/live-ws.mjs` (`checkRevision`, `watchLive`), `src/composables/useLive.ts` (`fetchRevision`) | a unit test on `watchLive` / `checkRevision` with a counting `fetchRevision`: two triggers in one tick -> 1 fetch. Red: today's code -> 2. Also run and green: the live-ws unit tests, `pnpm run typecheck` | claude / simple_coding | 1 |
| 05 | `perf(p19-05-wui-notification-permission-lazy)` | the notification store stops reading `Notification.permission` at hydrate: it reads it when first needed (the bell, the first gesture, a push) or in an idle callback. The visibility-change and permission-status reads stay | count: **1 `permission` read at store creation** (the unit test's red). **`0f872e92e`** (editor 2.11), in-page `performance.now()` around the first `Notification.permission` read on the mock `/lobby`, a fresh context each: **1.0, 4.4, 5.6, 2.9, 7.3 ms** (median 4.4), n=5, load ~22; v0.1 on `7e31ade12`: 39, 10.9, 1.1, 54, 1.4 ms (median 10.9), load ~100; editor 2.4, dev CPU profile: `readPermission` 80 ms self at hydrate (n=1) | -1 read at creation; -1..-7 ms (median -4.4) of main-thread work at first paint, computed from the reads, not measured on a fix. The one ms-only gain of the round, so it ranks below 06 (N4) | `src/stores/notification.ts` (`permissionSteps.hydrate`, :163-169, whose `readPermission()` at :165 reads `Notification.permission` at :128) | a unit test with a counting `Notification` stub: creating the store reads `permission` 0 times; the bell and `askOnFirstGesture` still read it before they ask. Red: today's store -> 1 read at creation. Also run and green: the notification unit tests (`grep -l notification wui/tests/unit/*`), `pnpm run typecheck` | claude / simple_coding | 1 |
| 07 | `perf(p19-07-wui-perf-journey-counters)` | the desktop journey counters become a committed proof: the probe of editor 2.5 (cold `/lobby`, channel switch, topic, 400-reply topic, scroll, search, back, type 40) becomes a `JOURNEY=1` mode of `perf-baseline-live.proof.mjs`, printing per step layouts, style recalcs, and nodes and listeners after a forced GC, so round 20+ starts from one command, not a scratch script | **`0f872e92e`** (editor 2.11): the scratch probe, type-40 172 layouts in 5 of 5, same as `7e31ade12` 5 of 5 beside it; no committed command prints them (the probe lives outside the repo, N6) | no runtime gain: it makes rows 01-03's gains, and a regression of them, readable in one run. Ranked last for that reason | `wui/tests/e2e/perf-baseline-live.proof.mjs` | the proof on the mock bundle twice: same counts in both runs. Red control: a plant (one extra forced layout per key in a throwaway copy of `useComposerSize.ts`) moves the type-40 count by about +40 | claude / tests | 2 (after 01-03: its first output shows their gains) |

Every row is claude: rulebook R14 (an established vendor) and the owner's
10-17 rule (no mistral coding or testing).

<a id="p19-batches"></a>

### 3.1 Batches and disjoint files (R1)

- **Batch 1** (disjoint, may run at once; placed in priority order): rows
  01, 03, 06, 05.
  - 01: `useComposerSize.ts`, `perf-typing-layouts.test.mjs` (new).
  - 03: `SideHitList.vue`, `SearchSidePanel.vue`, maybe `HumanName.vue`,
    `perf-search-release.test.mjs` (new).
  - 05: `notification.ts` and its unit test.
  - 06: `live-ws.mjs`, `useLive.ts` and their unit test.
- **Batch 2**: row 02 after row 01 (both edit `perf-typing-layouts.test.mjs`,
  and `useComposerSize.ts` calls `useComposerWrap.ts`); row 07 after rows
  01-03 (R16: within 30 minutes of the last).
- No row edits a file of perf round 20 or of c-980 (3.2).

<a id="p19-ab"></a>

### 3.3 Same-box A/B per row (W2)

Each lane runs both arms on one box within one hour, the before-arm on its
rebased `origin/master`, the after-arm on its commit, **n>=5 per arm**, and
puts both arms' counts (min..max) in the commit body. A gain that is not
outside the before-arm's range is no gain; the row is dropped.

| row | count (primary) | how, per run |
|---|---|---|
| 01 | `LayoutCount` delta of 40 typed keys; forced layouts at `fitGlobalBox` | `perf-typing-layouts.test.mjs` x5 per arm; plus 1 trace per arm for the frame split |
| 02 | the same, at the text-width measure | as 01, on row 01's tree as before-arm |
| 03 | retained `Nodes` after the 30-hit + 0-hit sequence, forced GC | `perf-search-release.test.mjs` x5 per arm |
| 06 | `GET /v1/wui/revision` per trigger | the unit test's fetch count (deterministic) + `do_spl_wui_perf_flow_events PF_N=5` on dev after deploy (R5) |
| 05 | `permission` reads at store creation | the unit test (deterministic); in-page first-read ms x5 per arm, reported, not ranked |
| 07 | the proof's per-step counts | the proof x5 on one bundle: same counts in 5 of 5 |

<a id="p19-r3"></a>

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-24 (editor 3):

- **Perf round 20** (mobile, c-084, plan v0.2 `fd664e5b0`, branch head
  `356cffc8c`): its files are `nuxt.config.ts` (first-screen hints module),
  `useLoopStrip.ts`, `useSidebarVersion.ts`, `parent-section-open.mjs`,
  `useLiveFeedThreadEnds.ts`, `useCardHeight.ts`, `read-sync.mjs`,
  `read-sync-boot.ts`, `first-screen-hints.mjs`,
  `prefetch-on-ready.client.ts`, `serve-generated.mjs`. None is a p19 file.
  Agreed with c-084 (msgs e31d60bb, 784bbd4b): the prefetch fix for app
  documents is one row, p20-07, which quotes this seat's desktop waterfall.
- **c-980** (SPL-5070, Nuxt 4): **landed** as `295f426dd`; no p19 row waits
  for it. Its remaining branch `review/c002-spl5070-nuxt4-migration`
  (`9761e0eab`) touches 0 p19 files (seat c-996, check 5).
- **Lane map, every machine**, re-read 19:00Z 2026-11-24 (v1.0): `--check`
  of the 11 p19 files -> exit 4, no lane lists them; 7 live lanes record no
  files (c-074, c-084, c-148, c-159, c-164, c-168, m-135). c-168's branch
  touches 0 p19 files (seat c-996); the others are not WUI-row lanes by their
  slugs, which is not proof: the R3 check before each spawn asks them. v0.1's
  read, 12:3xZ: `--check` of the p19 files -> exit 4:
  no lane lists them; 9 live lanes record no files (a-089, c-074, c-084,
  c-087, c-091, c-094, c-096, c-918, c-980). Their 19 pushed branches
  (`review/*`, `wip/*`, `tmp/*` of those lanes) touch none of the p19 files
  (0 lines each). The R3 check before each spawn re-reads the map and the
  queue.
- `git log origin/master --since='3 days ago' -- <p19 files>`: 1 commit
  (landed) on `useLive.ts` / `live-ws.mjs`, none on the others.

<a id="p19-per-row"></a>

## 4. Per row: what the lane does

- **01**: The `scrollHeight > clientHeight` branch already skips the collapse
  when the text grew past the box; the cost is the `else` branch, which runs
  on every key of a draft that fits (`height = 'auto'`, then a second
  `scrollHeight` read). Keep the last fitted text length and height: a key
  that adds text to a draft that still fits writes nothing. The
  `omniboxMax()` reads (two `getBoundingClientRect` in the bottom dock) are
  cached per focus and window resize. Docs: the comment block above `useFit`
  is the doc; the commit carries `Docs: none (<why>)` unless spec 027's
  budget table lists typing.
- **02**: one shared canvas; the font from `getComputedStyle(field)` on focus,
  not per key. The width must match the span's (letter and word spacing
  included) or the lifted-row decision flips (owner t1 26282b6e): the unit
  test pins that.
- **03**: take a heap snapshot on the mock (editor 2.8 names the script) and
  read the retainer chain of one old `side-hit` element up to a root. Fix the
  holder, not the symptom. If the holder is in Vue itself, the row reports it
  and keys the list so the old tree unmounts.
- **06**: attribute first, then fix; the drop rule is in the row.
- **05**: the HUM-24 behaviour (311427c6: the first gesture asks once; a
  permission changed in site settings shows on return) holds: the unit test
  covers both.
- **07**: no new dependency; the driver the proof file already uses.

<a id="p19-panel"></a>

## 5. Panel and reviewers (R7)

Read on 2026-11-24 12:39:41Z:

- Dispatch lease holder: `c-002@sat`.
- `do_spl_box_pick`: `pick=hold` (both fleet boxes over their overflow mark: load5 32.7 = 204% and 103.6 = 647% of their cores):
  no seat can be spawned at this reading; the holder places the panel when a
  box frees.

- **Plan panel (rulebook 3.2)**: editor c-778 (claude), one **agy** seat
  (specs_and_docs main) and one **mistral** seat (reviews), as p20 asked.
  Asked of the holder with the v0.1 sha. A seat signs only a sha this editor
  names.
- **Row reviewers (2.7.2)**: the row authors are claude, so code R7 is a
  non-claude seat, the holder's pick at placement under the current R7 rule.
  Every row is WUI and its R7 runs the mapped e2e, so **no mistral R7 seat**
  (fleet UI rule: never mistral on UI work until `do_spl_vendor_ui_retest`
  passes; N7). A row never pushes without its R7 PASS.
- v0.1's panel: seat c-996 (claude, not agy: N1) FAIL on `d86a2f880`, W1-W4
  fixed here; the holder asked c-001 for a cross-vendor seat.

<a id="p19-left-out"></a>

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| app-document prefetch (190 prefetch links, 357 KB gzip; 357 of 380 requests start before the first message paints) | **p20 row 07** (one row, one round); it covers desktop and quotes this seat's waterfall | editor 2.2, n=10 |
| the Vite preload helper walking every `<link>` per dependency (100 ms self) | shrinks with p20-07's fewer head links; re-measure after it lands | editor 2.4, n=1 profile |
| `useSidebarVersion` foot-row check (86 ms self) | **p20 row 02**'s file | editor 2.4, n=1 |
| render only the first N search hits | **dropped: mock artifact.** The mock answers a search with every match (401); the hub pages 5 per section grouped, 30 for one section (`search.go:33-35`). Row 03 fixes the part that grows | editor 2.8 |
| `GET /v1/view/topics` twice per first screen | **dropped: two callers.** `stores/channel.ts:238` (DM list) and `stores/flow.ts:135` read the route with different queries; not shown to be a duplicate | editor 2.6 |
| `GET /v1/view/flow` again on the first Flow open | **dropped: different reads.** The first screen's is the counts-only badge read (`flow.ts:272`), the open reads the lines page (`flow.ts:239`) | editor 2.6 |
| the document's inline locale script (117 ms self in the profile) | **dropped: unexplained.** It is 2,574 bytes (`200.html`); the self time is the profiler's attribution of the document's top level, not shown to be this script's work | editor 2.4, n=1 |
| 400-reply topic: +3,954 nodes, +880 listeners (~2.2 per card) | not a row now: the per-card listeners sit near the card files p20 rows edit (`useCardHeight.ts`, `useLiveFeedThreadEnds.ts`); a round after p20 | editor 2.5, n=5 |
| **row 04, `/v1/view/me` read once** | **dropped by measurement (v1.0).** Dev 3.7.6 (`0f872e92`): 6 reads in 6 first screens, 1 each (v0.1, dev 3.6.7: 10 in 6). No duplicate to remove | editor 2.11, n=6 |
| cold `/lobby` forced layouts (L5), the candidate for row 04's place | **not a p19 row: p20 files.** 44 layouts per cold load, 15 forced from script: 6 in `useCardHeight` (the `.msg-body` `getComputedStyle` + `scrollHeight` read), 3 in `useSidebarVersion`'s foot-row `getBoundingClientRect`, 6 single frames. Both files are p20 rows' | editor 2.11, n=3 traces, `0f872e92e` |
| field (RUM) numbers, `do_spl_wui_perf_report` | not readable by this seat (403: the dev test member is no workspace admin) | - |

<a id="p19-slug"></a>

## 7. Slug and status (R4, R6)

- Slug proof, read 2026-11-24 12:43:11Z on `origin/master` `37e0b241e`:
  `W=2026-11-18T16:51:12+01:00` (the newest `docs(p18-plan` commit);
  `git log origin/master --since="$W" --oneline -E --grep='\(p19-' | wc -l`
  -> `0`; `git log origin/master --oneline -E --grep='\(p19-[0-9]{2}' | wc -l`
  -> `0`; `git ls-remote origin 'refs/heads/review/p19-*'
  'refs/heads/wip/*p19*' 'refs/heads/*-p19-*' | wc -l` -> `0`.
- Status (R6): `git fetch origin master && git log origin/master
  --since=2026-11-24 --grep='(p19-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --since=2026-11-24
  --grep='p19-' --format=%B | grep -c '^review: '` must reach the row count
  (6, less any row dropped by its drop rule).

<a id="p19-changes"></a>

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 18. From then on the Qto doc is the primary copy.

- v0.1 (c-778, 2026-11-24 12:4xZ): first draft on `7e31ade12`.
- v1.0 (c-778, 2026-11-24 19:0xZ): send-back of seat c-996 (FAIL on
  `d86a2f880`). W1: re-read one count per row on `0f872e92e` (Nuxt 4) beside
  `7e31ade12`, row 04 dropped by that read, lanes re-read their before-number
  with the CI node; c-980 bullet updated (landed). W2: section 3.3. W3: row
  01 names puppeteer-core. W4: `fitGlobalBox :53-79`, `hydrate :163-169`.
  N3 in row 06, N4 row 05 below 06, N6/N8 the 30-hit output now saved
  (editor 2.11), N7 no mistral R7 on WUI rows, N2 lane map re-read.
  Seat m-006 (mistral, PASS on `d86a2f880`): its A/B point is section 3.3;
  N1 `composer-grow.test.mjs` is a unit test; N5 the read is at
  `notification.ts:128`, called from `hydrate` at :165.
