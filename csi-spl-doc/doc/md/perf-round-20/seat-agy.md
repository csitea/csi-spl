# Perf round 20 (p20): panel seat in the agy slot - verdict

**This seat is claude, not agy.** Seat c-020 (claude), placed by the holder
c-002 as the claude backup for the agy slot (ask 600e0886; agy is out of quota
until 12-01). The planner c-084 is claude too, so this verdict is an extra
reader's, not a cross-vendor signature (rulebook 3.2). The cross-vendor
signature is m-135's (mistral) PASS on the same sha (holder c-002, msg
df179f9d).

**Verdict: PASS on `312380222e746bff97ca172888dbc5cf75d308ac`** (plan v1.0,
named by c-084, msg 97eceaf1). Read 2026-11-24, 18:5xZ..19:1xZ.
`git ls-remote origin` -> `312380222e746bff97ca172888dbc5cf75d308ac
refs/heads/review/c002-perf-round-20-planner`; `git diff --stat
origin/master...312380222` -> 2 files, +538: `perf-round-20-plan.md` +289,
`perf-round-20/editor.md` +249.

The rows' structure holds. W1 to W3 are about the expected gains. Each row is
already guarded by 4.1, "a row with no gain is dropped", so none of them
blocks the signature. Each lane should read its W before it writes code.

## 1. Checks, each with its command and output

### 1.1 Slug p20 unused

- `git log origin/master --oneline -E --grep='\(p20-' | wc -l` -> `0`
- `git ls-remote origin | grep -E 'p20-[0-9]{2}|perf-round-20'` ->
  `736accf86... refs/heads/review/c002-perf-round-20-mistral-seat`,
  `312380222... refs/heads/review/c002-perf-round-20-planner`. The planner's
  and a seat's branch only; nothing else.

### 1.2 Cited file:lines on `09f137d40` and on `origin/master`

Command: `git show <sha>:csi-spl-wui/<file> | md5sum` on both trees, then
`git show 09f137d40:<file> | sed -n <N>p` for each cited line.

- 8 of the 9 row files are byte-identical on `09f137d40` and on
  `origin/master` `6beb21c8c`: `useLoopStrip.ts`, `useSidebarVersion.ts`,
  `parent-section-open.mjs`, `useLiveFeedThreadEnds.ts`, `useCardHeight.ts`,
  `read-sync.mjs`, `read-sync-boot.ts`, `first-screen-hints.mjs`.
- **`nuxt.config.ts` drifted**: `git log --oneline 09f137d40..origin/master
  -- <the 9 files>` -> one commit, `295f426dd refactor(wui, SPL-5070): the WUI
  moves from Nuxt 3.21.11 to Nuxt 4.6.4 ...` (2026-11-24T15:35:56Z, after the
  plan's ~14:37Z read; `git merge-base --is-ancestor 295f426dd 50dbdaa6d` ->
  false). Row 07's `:539` is now `:616` and `:561-562` is now `:637-639`; the
  lines' text is unchanged (`sed -n '616p;637,639p'` -> the `(200|404)\.html`
  skip and `if (layout === "login") route.contents =
  deferDocumentPrefetch(...)`). The plan already tells the lane to re-read
  the Nuxt 4 config (section 4, 07). See N1.
- Checked line by line on `09f137d40` (each matches the plan's text unless
  noted):
  - `useLoopStrip.ts:170-205`: `fitStrip` 170-174, `place` 176-205;
    `:232` the `watch([opts.enabled, opts.watchKey], ...)`. Match.
  - `useSidebarVersion.ts:86-107`: `measureFoot` 86-90 (rect read at 88
    before `!phone.value` at 89), observer 91-101, route watch 106. Match.
  - `parent-section-open.mjs:131-156`: `holdCard` is 131-154 and `landCard`
    starts at **157**. Match within 2 lines. `:241` is `export function
    followTopicPane`. Match.
  - `useLiveFeedThreadEnds.ts:23-66`, guard `:34-38`. Match.
  - `useCardHeight.ts:52-62` (`measureBox` 52-63), `:98-108`
    (`startObserving`). Match.
  - `read-sync.mjs:54-79`: `mergeMarks` is 54-**80**. `:115-148`:
    `createReadSync` starts at **116**, `take` is 124-136 and `push` is
    144-**156**, so 148 cuts `push` after `busy = true`. See N3.
  - `read-sync-boot.ts:101`: `if (moved.some((k) => k.startsWith('ch:'))) void
    channel.loadChannels()...`. Match.
  - `first-screen-hints.mjs:151`: `export function deferDocumentPrefetch`.
    Match.

### 1.3 Rows: sites, baseline, test + red, A/B, vendor, kind, batch, R1, R7

- **Sites**: every row names 2 to 4 files (at most 5). Pass.
- **Baseline with command + number + n**: rows 01, 03, 04 and 05 cite
  editor 5's CPU profile. Its probe script is quoted in full; its raw output
  is not, only the summed table (n=3). Row 02 cites editor 4
  (`do_spl_wui_perf_first_load`, evidence dir named, n=5 for the timings and
  n=1 for the profile). Row 06 is n=1 and the plan says it has no raw output
  (v1.0 N2). Row 07 cites editor 3 (n=5) and p19's n=1. Pass, with the n's as
  stated.
- **Counting test + red control that fails on today's code**: every row names
  a new test or case and today's red count. Row 03's red is "the per-frame
  count" with no number: `grep -n 'HOLD_STILL_FRAMES ='
  parent-section-open.mjs` -> `121:const HOLD_STILL_FRAMES = 10`, so today's
  count for a still card is at least 10 reads against the test's "at most 2".
  The lane can state that number (N4).
- **A/B**: section 1 "Timing, every row": same box, interleaved, n >= 5 per
  arm, then `ENV=dev`. Row 07: n=10 on dev and n >= 5 for the p19 waterfall.
  Pass.
- **Vendor / kind / batch**: all claude; kinds simple_coding except row 06,
  complex_coding; batch 1 = rows 01-06, batch 2 = row 07. Pass.
- **R1 within a batch**: the files in 3.1 are disjoint row by row. Pass.
- **No mistral coding or testing row, no WUI row to mistral**: none. Pass.
- **R7 of another vendor than its author**: plan 5 says "of another vendor,
  never a plan seat". The same wording is on master in
  `perf-round-18-plan.md:188-190`. See N2 for the placement risk.

### 1.4 Baselines against the expected gains (W1-W3)

The profile numbers in the plan match editor 4 and 5 as quoted (`measureFoot`
132.7, `fitStrip` 308.8, `holdCard` 182.8, `measureJump` 154.5, `measureBox`
113.5; editor.md lines 110 and 150-154). No expected gain exceeds its
measured self time. But each expected gain equals the *whole* self time
divided by the opens, which assumes the forced layout disappears rather than
moves. Plan section 1 calls such a figure an upper bound. Rows 01, 04 and 05
are less than that, read against the code:

- **W1 (row 01, plan line 112)**: the forced layout probably moves, not
  vanishes. `place()` calls `fitStrip(box, enabled)` (`useLoopStrip.ts:180`),
  and two lines later `readSnap(box, ...)` (`:182`) reads
  `getBoundingClientRect()` on every item, `box.scrollWidth`,
  `box.clientWidth` and the selected control's rect (`:100-123`), in the same
  synchronous call. If `fitStrip` stops reading `clientWidth`, the layout that
  the route change dirtied is forced at `readSnap` instead. The profile already
  shows 159.7 ms of native `getBoundingClientRect` in the same step. The
  planned test (0 `clientWidth` reads per route change) passes either way, so
  it proves the read is gone, not the time. Ask of the lane: count *forced
  layouts* per route change (DevTools `Layout` events or a trace) in the A/B,
  not only reads. Either drop the row, or reshape it to read the width once
  together with `readSnap`'s reads (one layout instead of two only if
  `data-fit` is written between them).
- **W2 (row 04, plan line 115)**: batching the three triggers into one
  `requestAnimationFrame` saves only the 2nd and 3rd reads. Those are cheap
  when nothing is written between them, because the layout is already clean;
  `measureJump` writes only `jumpEnds.value`, which Vue applies to the DOM
  later. A read in a rAF callback after a DOM write still forces layout, and
  the ResizeObserver caller (`:27`) already reads after layout. "Up to ~50 ms"
  is the first read's cost, which batching does not remove. The lane measures
  forced layouts as in W1.
- **W3 (row 05, plan line 116)**: the baseline cannot show this row's
  mechanism. Editor 5 profiled a channel with **1** card (plan: "prd `e2e`
  has 1"), so the 113.5 ms over 3 opens is one card's reads per open. Sharing
  the line-height read across cards saves nothing at n=1 card, and "~38 ms a
  card" is not a per-card figure that sharing divides. Also, `measure()` runs
  synchronously in `startObserving` (`useCardHeight.ts:101`), and
  `inner.scrollHeight` (`:61`) still forces layout per card. The plan text
  ("`scrollHeight` stays per card, read in the ResizeObserver callback") would
  also have to drop that synchronous call to remove the forced layout. The
  plan already has the lane build a >= 20-card mock and drop the row without
  a gain. The expected line should say the figure is not a per-card number.
  p19's trace supports the row's premise: `perf-round-19-plan.md:243` on
  master -> "6 in `useCardHeight` (the `.msg-body` `getComputedStyle` +
  `scrollHeight` read)" of 15 forced layouts per cold `/lobby`, n=3, on
  `0f872e92e`.

Rows 02 and 03 hold as written. Row 02: the rect is read before the phone
test (`useSidebarVersion.ts:88-89`). Row 03: `apply()` writes the scroll, then
`:147` reads the rect every frame, so each frame forces a layout that a
ResizeObserver wait avoids.

### 1.5 Rulebook 4.4 share line

The plan quotes the line but does not name the command; the command is in
`rounds-rulebook.md:253` (at `312380222`). Run at 19:10:13Z on
`origin/master` `1617248e9`:

`git fetch -q origin master && git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '...'`
-> `perf 29 refactor 100 perf-share 22.5% floor-met`

This is the same as the plan's line.

### 1.6 R3: lane map

`lane-map.sh --check <the 9 row files> --agent c-020` -> **exit 4**. No
live lane lists a row file; `nuxt.config.ts` is no longer c-980's (its
change landed as `295f426dd`). 8 live lanes on sat record no files:
`c-074` (s187 build planner), `c-084` (this plan), `c-087`
(`bug-acfc125c-topics-list-back-to-channels`), `c-148` (rotate), `c-159`
(`s186-m3-wui-select-phase`), `c-164` (`s153-q2-store-priority-rank`),
`c-168` (`feat-wui-releases-desktop-single-column`), `m-135` (the mistral
seat). c-087, c-159 and c-168 are WUI lanes, so their scope is unknown, not
free (N5).

### 1.7 R1 across rounds: perf round 19

`git ls-remote origin | grep -E 'perf-round-19'` -> the planner branch
`review/c002-perf-round-19-planner` `a1f63000c` and two seat branches
(`c003-...-agy-seat`, `c003-...-mistral-seat`). The p19 plan has since landed
on master (`ce30cb0c5 docs(p19-plan, SPL-6363): ... 6 rows`).

- `grep -c <file>` of each p20 row file in `perf-round-19-plan.md`, on
  `a1f63000c` and on `origin/master` -> 1 each, 2 for
  `useLiveFeedThreadEnds.ts` and `useCardHeight.ts`.
- Each hit is p19 naming p20's files: its 3.2 (lines 154-158, "its files are
  ... None is a p19 file") or its section 6 (lines 241, 243, "p20 files").
  p19's row sites (`grep -o 'src/.../...'`) are `useComposerSize.ts`,
  `useComposerWrap.ts`, `HumanName.vue`, `SearchSidePanel.vue`,
  `SideHitList.vue`, `access.ts`, `useLive.ts`, `live-ws.mjs` and
  `notification.ts`.

No overlap with any p20 row.

### 1.8 Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO
distribution-hygiene: clean over the tracked tree`, exit 0. Run on the tree
of `312380222` plus this file (branch `review/c002-perf-round-20-agy-seat`).

## 2. Defects

- **W1** row 01 (plan line 112): the forced layout moves to `readSnap`
  (`useLoopStrip.ts:182`, `:100-123`); a read-count test cannot see that.
  Measure forced layouts.
- **W2** row 04 (plan line 115): batching removes the cheap repeated reads,
  not the first forced one; "~50 ms" is an upper bound that batching does not
  reach.
- **W3** row 05 (plan line 116): a 1-card baseline does not support "~38 ms a
  card". The synchronous `measure()` at `useCardHeight.ts:101` and the
  per-card `scrollHeight` at `:61` keep the forced layout unless the row also
  changes them.

## 3. Notes

- **N1** Row 07's batch-2 trigger has fired: c-980's Nuxt 4 change is on
  master (`295f426dd`, 15:35:56Z). Rulebook R16 places it within 30 minutes.
  Its sites are now `nuxt.config.ts:616` and `:637-639` (holder's
  placement).
- **N2** R7 for the 7 WUI rows can only be agy or grok (not claude, not
  mistral). agy is out of quota until 12-01 (holder, msg df179f9d) and grok
  was held at 97% weekly. Row placement needs one of them, or the holder's
  replacement under rulebook 2.7.3.
- **N3** Small line-range drift in the plan text: `read-sync.mjs:54-79` ->
  54-80; `:115-148` -> `createReadSync` 116, `push` ends 156;
  `parent-section-open.mjs:131-156` -> `holdCard` ends 154.
- **N4** Row 03's red control can state its number: `HOLD_STILL_FRAMES = 10`
  (`parent-section-open.mjs:121`), so today's still card is read at least 10
  times.
- **N5** R3 rerun at placement: three WUI lanes record no files (c-087,
  c-159, c-168). The holder asks them before a batch 1 spawn.
- **N6** Row 06: `mergeMarks` already has an echo guard (`idEcho(m, c)`,
  `read-sync.mjs:62`), and a `count` above the local one moves the key on its
  own (`:69-73`). The lane's logging step should name which of the two moves
  `ch:` on this tab's own PUT before it adds a new rule.
- **N7** p19's plan lists two more p20 files that p20 v1.0's 3.1 does not
  name: `prefetch-on-ready.client.ts` and `serve-generated.mjs`
  (`perf-round-19-plan.md:158`). If row 07 needs them, add them to its row.
