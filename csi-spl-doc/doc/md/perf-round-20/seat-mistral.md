# Perf round 20 (p20): mistral panel seat (m-135)

Seat: m-135@sat, placement `mistral:c002-perf-round-20-mistral-panel-seat`.
Brief: `/var/spool-hub/dispatch/briefs/c002-perf-round-20-mistral-panel-seat.md` (Issue SPL-6364, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, class refactor, kind specs_and_docs, topic `e27b8cce-476e-48e0-9737-d682e644b998`).

**Verdict: PASS on `fd664e5b0f6ec4cb858b5e51b9019fa366a360f3`** (plan v0.2, named by editor c-084@sat, msg 12:11:06Z on task `dispatch-perf-r20`; branch `review/c002-perf-round-20-planner`, parent `f120ed920`, on `09f137d40`). Read 2026-11-24 ~14:3xZ. Every check below names the command I ran and what it printed; every file:line cited was read with `git show <sha>:<file> | sed -n <N>p`.

Plan files read at the signed sha: `git show fd664e5b0:csi-spl-doc/doc/md/perf-round-20-plan.md` (273 lines) and `git show fd664e5b0:csi-spl-doc/doc/md/perf-round-20/editor.md` (210 lines); `git diff --stat fd664e5b0~1 fd664e5b0` -> plan file only, +22 -13. Identity: `git log -1 --format='%an %ae %cn %ce' fd664e5b0` -> author and committer both the repo CLAUDE.md Commits address (the two email fields equal); `git log -1 --format='%(trailers)' fd664e5b0` -> one line, `Docs: none (a plan only; no behaviour change)` — 0 AI trailers. v0.1 check: `git diff --stat origin/master...f120ed920` -> 2 files +474 (`perf-round-20-plan.md` +264, `perf-round-20/editor.md` +210); `git log -1 --format='%P' f120ed920` -> `09f137d401de7cffa157bbc1d14d92e7b5a6d4fd`.

## Checks

1. Slug p20 unused:
   - `git log origin/master --oneline -E --grep='\((p20-' | wc -l` -> `0`.
   - `git ls-remote origin | grep -E 'p20-[0-9]{2}|perf-round-20'` -> one line: `cc0889bcb... refs/heads/review/c002-perf-round-20-planner` (the planner's branch, expected; this seat's branch appears once this file is pushed).
   - The plan's own slug commands: `git ls-remote origin 'refs/heads/review/p20-*' 'refs/heads/wip/*p20*' 'refs/heads/*-p20-*' | wc -l` -> `0`; window `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(p18-plan')` -> `2026-11-18T16:51:12+01:00` (matches the plan's quoted `Window:`); `git log origin/master --since="$W" --oneline -E --grep='\(p20-' | wc -l` -> `0`, and without the window -> `0`. `git log origin/master -1 -E --grep='^docs\(p19-plan'` -> no output (no p19 plan commit on master, as the plan states).
2. Every file:line the plan cites exists on `09f137d40` and on `origin/master` (8d348dbe1); none drifted: `git diff --stat 09f137d40 origin/master -- <the 9 row files>` -> empty. Per range, `git show <sha>:<file> | sed -n <a>,<b>p | grep -cE <pattern>` on both shas, identical:
   - `useLoopStrip.ts:170-205` `fitStrip|place` -> 3; `:232` `watch` -> 1. Line reads: `:170` `function fitStrip(box: HTMLElement, enabled: boolean) {`, `:172` reads `box.clientWidth`, `:232` `watch([opts.enabled, opts.watchKey], () => { void nextTick(() => place(ctx, false)) })`.
   - `useSidebarVersion.ts:86-107` `useFootClock|measureFoot` -> 4; `:86` `function measureFoot() {`, `:88` `const r = el?.getBoundingClientRect()`, `:89` tests `!phone.value` after the read, `:106` the route watch with `requestAnimationFrame(measureFoot)`.
   - `parent-section-open.mjs:131-156` `holdCard` -> 1 (`:131` `function holdCard(card, scroller, apply) {`; the rAF `tick` at `:146` reads `card.getBoundingClientRect().top` every frame); `:157` `landCard`; `:241` `followTopicPane`.
   - `useLiveFeedThreadEnds.ts:23-66` `measureJump` -> 4 (`:33` `function measureJump() {`, `:51` `}`; callers: ResizeObserver `:27`, `onMounted` `:60`, watch `:64`).
   - `useCardHeight.ts:52-62` `measureBox` -> 1; `:98-108` `startObserving` -> 1.
   - `read-sync.mjs:54-79` `mergeMarks` -> 1 (`:54` `export function mergeMarks(cursors, marks) {`); `:115-148` `take|push` -> 3 (`take` at `:131` calls `onMoved(moved, marks)` at `:141` on every answer).
   - `read-sync-boot.ts:101` -> `if (moved.some((k) => k.startsWith('ch:'))) void channel.loadChannels().catch(() => {})`.
   - `nuxt.config.ts:539` -> `if (!name.endsWith(".html") || /^\/(200|404)\.html$/.test(name) || ...) return` (the 200/404 skip); `:561-562` the `layout === "login"` condition with `deferDocumentPrefetch`.
   - `first-screen-hints.mjs:151` -> `export function deferDocumentPrefetch(html) {`.
3. Each row (plan section 3 table): at most 5 sites (rows name 2-4 files each); baseline with command + number + n (every row cites an editor section that carries the command and an output table, plus n); a counting unit test with a red control that fails on today's code (red controls verified in code for rows 01, 02, 03, 06: `useLoopStrip.ts:232`->`place`->`fitStrip` reads `box.clientWidth` per route change; `useSidebarVersion.ts:88-89` reads the rect before the phone test; `parent-section-open.mjs:146` reads per frame; `read-sync-boot.ts:101` reloads on any `ch:` move); a same-box A/B with n>=5 per arm (plan section 1 "Timing, every row": mock-bundle A/B n>=5 per arm same box interleaved before the push, `ENV=dev` probe after; row 07 adds n=10 on dev and n>=5 for the p19 waterfall); vendor, kind, batch present per row (all `claude`, kinds simple_coding except row 06 complex_coding; batch 1 = rows 01-06, batch 2 = row 07). R1 within a batch: the 3.1 file lists are disjoint (01 useLoopStrip.ts, 02 useSidebarVersion.ts, 03 parent-section-open.mjs, 04 useLiveFeedThreadEnds.ts, 05 useCardHeight.ts, 06 read-sync.mjs/read-sync-boot.ts/read-sync.test.mjs, 07 nuxt.config.ts/first-screen-hints.mjs/first-screen-hints.test.mjs). No mistral coding or testing row (all rows claude); no WUI row to mistral. R7: plan section 5 — row reviewers are the holder's pick at placement, another vendor than the claude authors, never a plan seat, and a WUI row never to mistral; assignment per row happens in the row brief (R4), consistent with rulebook 2.7.2.
4. Baselines backed by command + output in the editor file, and expected gains within the measured self time (checked for rows 01, 02, 03, 04, 06, 07):
   - Row 01: editor 5 carries the probe script and the output table (`fitStrip` 308.8 ms self over n=3 channel opens, ~103 ms an open; channel open 881 ms median, 590..1,129, n=5). Expected "up to ~100 ms" <= ~103 ms measured. OK.
   - Row 02: editor 4 command `ENV=prd PF_N=5 PF_PROFILES=m390 FL_CPU_PROFILE=1 ./run -a do_spl_wui_perf_first_load` with output (rail 3,108 ms, blocking 1,290 ms, n=5; profiled round n=1: `measureFoot` 132.7 ms self). Expected "up to ~130 ms" <= 132.7 ms. OK.
   - Row 03: `holdCard` 182.8 ms / 3 opens ~ 61 ms; expected ~60 ms. OK. Row 04: `measureJump` 154.5 / 3 ~ 51.5 ms; expected ~50 ms. OK.
   - Row 06: expected one hub read (~160 ms) fewer per read push; editor 5 measured each hub read 156..201 ms. OK.
   - Row 07: expected ~0.28 s of 9 Mbit/s; editor 3 measured 313..329 KB of the 428.5 KB prefetch unused by the rail (313 KB * 8 / 9000 kbit/s ~ 0.278 s). OK.
   - No row's expected gain exceeds its measured self time. The plan also states the upper-bound rule for self times holding a forced layout.
5. Rulebook 4.4 share line, the command the rulebook names, run fresh:
   - on `09f137d40`: `git log 09f137d40 --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk ...` -> `perf 29 refactor 100 perf-share 22.5% floor-met` — exactly the plan's quoted line.
   - on `origin/master` (8d348dbe1): same command -> `perf 29 refactor 100 perf-share 22.5% floor-met`.
6. R3: `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <9 row files + csi-spl-doc/doc/md/perf-round-20/seat-mistral.md> --agent m-135` -> exit 3, one path: `csi-spl-wui/nuxt.config.ts owned by c-980@sat c-980-c002-spl5070-nuxt4-migration-r2 (changed in its worktree; no files recorded)` — exactly as the plan's 3.2 records and the brief expects; every other row file and this seat file are free. (With the two plan files added, exit 3 also names them owned by c-084@sat, the planner — expected.)
7. R1 across rounds: `git ls-remote origin | grep -E 'perf-round-19'` -> `d86a2f88026831932f48dfbe04183853a174c008 refs/heads/review/c002-perf-round-19-planner`; fetched, `git rev-parse FETCH_HEAD` -> `d86a2f880...`; `git diff --stat origin/master...FETCH_HEAD` -> 2 files +500 (p19 plan + editor only). `git show d86a2f880:csi-spl-doc/doc/md/perf-round-19-plan.md | grep -c <each p20 row file>` -> 1,1,1,2,2,1,1,1,1, but every mention is p19 naming them as p20's files / off-limits (plan lines 121-124 "its files are ... None is a p19 file", line 194 "p20 row 02's file", line 199 defers a row because p20 rows edit those files); p19's own batch files are `useComposerSize.ts`, `SideHitList.vue`, `SearchSidePanel.vue`, `access.ts`, `notification.ts`, `live-ws.mjs`, `useLive.ts` — no overlap with p20's rows. The plan's 3.2 records bug rounds 28/29 and refactor rounds 78/79 naming no WUI row file.
8. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-135`, exit 0.

One-tree note: `git log --oneline 6c741f5b0..09f137d40 -- csi-spl-wui | wc -l` -> `0` (re-ran). `curl -s https://e2e.spool-hub.ai/build.json` -> `{"commit":"8d348dbe195ad3c2c8a9ecf5a5578b87f21384cd","built_at":"2026-11-24T14:18:04Z","run":"45411853276","version":"3.6.9"}` — prd has moved from `6c741f5b` (v3.6.7, what the plan read at 11:54Z) to `8d348dbe1`; `git diff --stat 09f137d40 8d348dbe1 -- csi-spl-wui` -> only a help md and `tests/e2e/perf-flow-events.timing.mjs`, none of the 9 row files, so the baselines still describe the served row code (N1).

## Defects

- W1 (minor, fold into v1.0): the action table (plan section 3, line 105) has no `box` column. Rulebook 3.1 requires the table to detail "target box", and the form plan `perf-round-18-plan.md` (line 104) carries a `box` column ("either fleet box"). The p20 table carries vendor/kind and batch only; the box is picked at placement (R4). Not blocking: R4 assigns boxes at spawn.

## Notes

- N1: prd now serves `8d348dbe1` v3.6.9 (build.json above), not `6c741f5b` v3.6.7 as at the plan's 11:54Z reading; the 9 row files are unchanged between the two (`git diff --stat` above), and the plan's per-row rule re-measures the baseline on the lane's start sha anyway.
- N2: row 06's causal claim "4 of 4 PUTs followed by GET from `onMoved` -> `listChannels`" cites an initiator trace (CDP `Network.requestWillBeSent.initiator`, n=1) that is quoted only in the plan, not in the editor file (editor 5 quotes the 5-of-5 probe-round observation). The mechanism is confirmed in code at `read-sync.mjs:131-141` (`take` calls `onMoved(moved, marks)` on every answer) and `read-sync-boot.ts:101`.
- N3: row 04's parenthetical "(today it reads first on some paths)" does not match `09f137d40`: `measureJump`'s phone/holdScroll guard (`useLiveFeedThreadEnds.ts:34-38`) is before the reads on all paths. The row's red control (watch + mount + ResizeObserver -> 3 reads in one frame) does hold on today's code.
- N4: row 01's "~100 ms" expected is measured only on channel open (`fitStrip` 308.8 ms / 3 opens); channel switch (525 ms median, n=5) and rail tab change are extrapolations, labeled "computed, not measured" — consistent with the plan's upper-bound rule.
- N5: row 07's desktop baseline is n=1 (p19's mock waterfall, times not quoted, box load/cores 4.3); the row's own timing rule (n>=5 per arm before the push, n=10 on dev) covers the A/B, so 4.1 holds.
- N6: check 1's `ls-remote` shows only the planner's branch; this seat's `review/c002-perf-round-20-mistral-seat` appears once this file is pushed (expected per the brief).

<a id="p20-seat-v10"></a>

## v1.0 signature (2026-11-24 14:5xZ)

Editor c-084 named v1.0, first `65987550644182baafa3684e09b1c08166677d5d` (holder msg a9a472b6), then corrected by the holder (msg 4e117660, task `dispatch-perf-r20`) to **`312380222e746bff97ca172888dbc5cf75d308ac`** — c-084's 1f99302a changes one timestamp line in the one-tree note (~14:45Z -> ~14:37Z), 1 file +1 -1, fast-forward from `6598755`. This seat signs `312380222e746bff97ca172888dbc5cf75d308ac`. Verified: `git ls-remote origin | grep perf-round-20-planner` -> branch head `312380222e746bff97ca172888dbc5cf75d308ac`; `git log -1 --format='%H %P %an %ae %cn %ce %s' 3123802...` -> parent `65987550644182baafa3684e09b1c08166677d5d` (fast-forward from `fd664e5b0` through `ca630d473`), author and committer both the repo CLAUDE.md Commits address, subject `docs(p20-plan, SPL-6364): perf round 20 plan v1.0, the one-tree note's read time is 14:37Z, not 14:45Z`; `git log -1 --format='%(trailers)' 3123802...` -> one `Docs: none (...)` line, 0 AI trailers; `git diff 6598755 3123802` -> only the one-tree note's `~14:45Z` -> `~14:37Z` line.

Delta read: `git diff fd664e5b0 312380222e746bff97ca172888dbc5cf75d308ac` -> 2 files, 69 insertions(+), 14 deletions(-): `perf-round-20-plan.md` +44/-14ish, `perf-round-20/editor.md` +39 — identical to the `6598755` delta except that one timestamp line. Plan hunks, each judged:

- Title/status v0.2 -> v1.0. Bookkeeping.
- One-tree note added: prd `e2e` serves WUI 3.6.9 `8d348dbe1`, `origin/master` is `50dbdaa6d`, row-file diff empty. Folds N1. Re-verified: `git rev-parse origin/master` -> `50dbdaa6d1c2ca6f92af4f755a9feaadb88027fc`; `git diff --stat 09f137d40 origin/master -- <9 row files>` -> empty; `curl -s https://e2e.spool-hub.ai/build.json` earlier -> commit `8d348dbe1` v3.6.9.
- Rows table: header gains the `box` column and every row gets `either fleet box`. Folds W1 (rulebook 3.1, p18 form line 104).
- Row 01 expected reworded: "~100 ms off each channel open (the profiled step); channel switch and a rail tab change ... are extrapolated from it". Folds N4.
- Row 04 practice reworded: "today's guard, `:34-38`, already runs before the reads; the gain is the batching". Folds N3. Re-verified: `git show 09f137d40:csi-spl-wui/src/composables/useLiveFeedThreadEnds.ts | sed -n '34,38p'` -> the `if (!phone.value || o.holdScroll() !== true) { ... return }` guard.
- Row 06 baseline adds "quoted here only; the editor file keeps no raw output of it, so the lane re-takes it before the change". Folds N2.
- Section 6 probe row updated with c-117's finding and fix `8d348dbe1` (SPL-6386). Not one of my notes; verified `git merge-base --is-ancestor 8d348dbe1 origin/master` -> rc 0.
- Counts line ("Rows: 7"), the v1.0 entry in section 8 (folds W1, N1-N4 explicitly, N5/N6 need no change), and the consensus table (records this seat's PASS, msg 1901395a, seat file `960bb5d2f`; agy not placed). Bookkeeping.
- Editor file: new section 7 "Seat state (for a restart of this seat)" — bookkeeping, no measurement changed.

Nothing else moved: no row's sites, baseline numbers, tests, vendors, kinds or batches changed; the only site-text change is row 04's added `:34-38` reference, verified above.

Re-checks on the new state: `git log origin/master --oneline -E --grep='\((p20-' | wc -l` -> `0`; rulebook 4.4 command on `origin/master` -> `perf 29 refactor 100 perf-share 22.5% floor-met`; `lane-map.sh --check <9 row files + this seat file> --agent m-135` -> exit 3, only `csi-spl-wui/nuxt.config.ts` owned by c-980@sat.

**PASS on `312380222e746bff97ca172888dbc5cf75d308ac`** (plan v1.0, the sha the holder corrected to): W1 and N1-N4 are folded correctly and nothing else moved. The earlier `6598755` PASS stands for the same delta minus one timestamp line.

## Seat state at the 15:20Z rotation (2026-11-24)

- Branch `review/c002-perf-round-20-mistral-seat` at `3bfa6a954` (this file only; three commits: verdict on v0.2 `fd664e5b0` `960bb5d2f`, v1.0 signature `dbcf5fdb0`, corrected v1.0 signature `3bfa6a954`). Pushed; pre-push gate all parts PASSED.
- Verdicts sent on task `dispatch-perf-r20`: PASS `fd664e5b0` (msg `1901395a` to c-002, `19f1835c` to c-084), PASS `3123802` (msg `3bdf42bb` to c-002, `367a86fc` to c-084). c-084 forwarded the `3123802` PASS to the holder (14:46:24Z).
- Panel state: mistral PASS on the planner head `312380222e746bff97ca172888dbc5cf75d308ac`; agy seat (ask 21032ee7) not placed. No land before the holder's GO.
- Waiting on: a message on `dispatch-perf-r20` whose body starts with ACCEPTED (c-084 or the dispatch holder); this seat closes only on it.

## Seat state at the 16:15Z rotation (2026-11-24)

- Branch `review/c002-perf-round-20-mistral-seat` at `c951ca991` (this file only; four commits: verdict on v0.2 `fd664e5b0` `960bb5d2f`, v1.0 signature `dbcf5fdb0`, corrected v1.0 signature `3bfa6a954`, 15:20Z state `c951ca991`). Pushed; pre-push gate all parts PASSED.
- Verdicts sent on task `dispatch-perf-r20` (unchanged, not re-sent): PASS `fd664e5b0` and PASS `312380222e746bff97ca172888dbc5cf75d308ac` to c-002 and c-084; c-084 forwarded the `3123802` PASS to the holder (14:46:24Z).
- Task topic re-read at 16:0xZ (`spool tail --task dispatch-perf-r20`): latest activity 15:08:03Z (agy seat re-placed on claude, ask 600e0886 queued); no new plan sha named, no ACCEPTED for this seat.
- Panel state: mistral PASS on the planner head `312380222e746bff97ca172888dbc5cf75d308ac`. Waiting on: a message on `dispatch-perf-r20` whose body starts with ACCEPTED (c-084 or the dispatch holder); this seat closes only on it.

## Seat state at the 17:17Z rotation (2026-11-24)

- Branch `review/c002-perf-round-20-mistral-seat` at `972b1449a` (this file only; five commits: verdict on v0.2 `fd664e5b0` `960bb5d2f`, v1.0 signature `dbcf5fdb0`, corrected v1.0 signature `3bfa6a954`, 15:20Z state `c951ca991`, 16:15Z state `972b1449a`). Pushed; pre-push gate all parts PASSED.
- Verdicts sent on task `dispatch-perf-r20` (unchanged, not re-sent): PASS `fd664e5b0` and PASS `312380222e746bff97ca172888dbc5cf75d308ac` to c-002 and c-084; c-084 forwarded the `3123802` PASS to the holder (14:46:24Z).
- Task topic re-read at 17:0xZ (`spool tail --task dispatch-perf-r20`): latest activity still 15:08:03Z (agy seat re-placed on claude, ask 600e0886 queued); no new plan sha named, no ACCEPTED for this seat.
- Panel state: mistral PASS on the planner head `312380222e746bff97ca172888dbc5cf75d308ac`. Waiting on: a message on `dispatch-perf-r20` whose body starts with ACCEPTED (c-084 or the dispatch holder); this seat closes only on it.

## Seat state at the 18:18Z rotation (2026-11-24)

- Branch `review/c002-perf-round-20-mistral-seat` at `6babc7d4e` (this file only; six commits: verdict on v0.2 `fd664e5b0` `960bb5d2f`, v1.0 signature `dbcf5fdb0`, corrected v1.0 signature `3bfa6a954`, 15:20Z state `c951ca991`, 16:15Z state `972b1449a`, 17:17Z state `6babc7d4e`). Pushed; pre-push gate all parts PASSED.
- Verdicts sent on task `dispatch-perf-r20` (unchanged, not re-sent): PASS `fd664e5b0`, PASS `65987550644182baafa3684e09b1c08166677d5d`, PASS `312380222e746bff97ca172888dbc5cf75d308ac` to c-002 and c-084; c-084 forwarded the `3123802` PASS to the holder (14:46:24Z).
- Task topic re-read at 18:03Z (`spool tail --task dispatch-perf-r20`): latest activity still 15:08:03Z (agy seat re-placed on claude, ask 600e0886 queued); no new plan sha named, no ACCEPTED for this seat.
- Panel state: mistral PASS on the planner head `312380222e746bff97ca172888dbc5cf75d308ac`. Waiting on: a message on `dispatch-perf-r20` whose body starts with ACCEPTED (c-084 or the dispatch holder); this seat closes only on it.

## Seat state at the 19:19Z rotation (2026-11-24)

- Branch `review/c002-perf-round-20-mistral-seat` at `dc61daa7e` (this file only; seven commits: verdict on v0.2 `fd664e5b0` `960bb5d2f`, v1.0 signature `dbcf5fdb0`, corrected v1.0 signature `3bfa6a954`, 15:20Z state `c951ca991`, 16:15Z state `972b1449a`, 17:17Z state `6babc7d4e`, 18:18Z state `dc61daa7e`). Pushed; pre-push gate all parts PASSED.
- Verdicts sent on task `dispatch-perf-r20` (unchanged, not re-sent): PASS `fd664e5b0`, PASS `65987550644182baafa3684e09b1c08166677d5d`, PASS `312380222e746bff97ca172888dbc5cf75d308ac` to c-002 and c-084; c-084 forwarded the `3123802` PASS to the holder (14:46:24Z).
- Task topic re-read at 19:0xZ (`spool tail --task dispatch-perf-r20`): latest activity still 15:08:03Z (agy seat re-placed on claude, ask 600e0886 queued); `grep -n ACCEPTED` over the tail matches only "wait for ACCEPTED" (14:38:03Z) and g-565's ACCEPTED (15:07:45Z) — no ACCEPTED-body message for this seat; no new plan sha named. `git ls-remote origin`: planner head still `312380222e746bff97ca172888dbc5cf75d308ac`, this seat branch at `dc61daa7e`.
- Panel state: mistral PASS on the planner head `312380222e746bff97ca172888dbc5cf75d308ac`. Waiting on: a message on `dispatch-perf-r20` whose body starts with ACCEPTED (c-084 or the dispatch holder); this seat closes only on it.
