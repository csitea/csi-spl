# Perf round 19 (p19): mistral panel seat (m-006)

Seat: m-006, placement `c003-perf-round-19-mistral-panel-seat`.
Brief: `/var/spool-hub/spawn-remote/briefs/c6a07215-f637-48c1-94f1-a1018eeb91bf.md`
(Issue SPL-6363, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`,
class refactor, kind specs_and_docs, topic `4369bb74-1889-402e-8388-a30332f3c5f8`).
Cross-vendor panel seat of rulebook 3.2; the plan is reviewed only, no code.

Review target read: `git fetch origin review/c002-perf-round-19-planner && git
rev-parse FETCH_HEAD` -> `d86a2f88026831932f48dfbe04183853a174c008` (parent
`82745dc0b`, author and committer the csitea.net address), the v0.1 sha the
editor named. Files read at that sha: `csi-spl-doc/doc/md/perf-round-19-plan.md`
(227 lines) and `csi-spl-doc/doc/md/perf-round-19/editor.md` (273 lines).
Rules read: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 4. Form:
`csi-spl-doc/doc/md/perf-round-18-plan.md` (newest perf plan on origin/master,
`docs(p18-plan, SPL-5903)` `da68ad993`) and its `perf-round-18/seat-mistral.md`.

**PASS on `d86a2f88026831932f48dfbe04183853a174c008`** (plan v0.1), with one
defect (W1) to fold into v1.0. Checks re-run on origin/master `6beb21c8c`
(fresh fetch at review time; the plan's own reads named `9a85c02b5` at 12:36Z
and `37e0b241e` at 12:43Z — see N3).

## Checks, each with the command run and what it printed

1. Slug p19 unused on master:
   - `git log origin/master --oneline -E --grep='\(p19-' | wc -l` -> `0`
   - `git ls-remote origin | grep -E 'p19-[0-9]{2}|perf-round-19'` -> only
     `refs/heads/review/c002-perf-round-19-planner` (`d86a2f880`) and
     `refs/heads/review/c003-perf-round-19-agy-seat` (`24ff0bf2`); no
     `review/p19-*`, no `wip/*p19*`, no `*-p19-*` row branch.
   - The plan's window form (section 7): `W=2026-11-18T16:51:12+01:00`;
     `git log origin/master --since="$W" --oneline -E --grep='\(p19-' | wc -l`
     -> `0`; `git log origin/master --oneline -E --grep='\(p19-[0-9]{2}' | wc -l`
     -> `0`; `git ls-remote origin 'refs/heads/review/p19-*' 'refs/heads/wip/*p19*' 'refs/heads/*-p19-*' | wc -l`
     -> `0`.
2. Every file:line the plan cites, on `7e31ade12` and on origin/master
   (`git merge-base --is-ancestor 7e31ade12 origin/master` -> yes;
   `git diff --stat 7e31ade12 origin/master -- <the 10 row files>` -> `0`
   lines, so nothing drifted; `git log origin/master --since='3 days ago' --
   <the 10 row files>` -> 1 commit, `c68cca820` on `useLive.ts` / `live-ws.mjs`
   (+ `live-ws-core.mjs`, `live-ws-lazy.mjs`), as the plan's 3.2 says):
   - `csi-spl-wui/src/composables/useComposerSize.ts:47-78` -> `fitGlobalBox`
     at :53, `scrollHeight > clientHeight` at :70, `height = 'auto'` at :74,
     the second `scrollHeight` read at :75 — identical on both refs.
   - `csi-spl-wui/src/stores/notification.ts:162-168` -> `hydrate()` at
     :163-169 calling `readPermission()` at :165; the `Notification.permission`
     read itself is at :128 inside `permissionSteps` (:124) — identical on
     both refs (N5).
   - `csi-spl-api/src/go/spool-hub-api/internal/hub/search.go:33-35` ->
     `searchGroupedDefault = 5`, `searchGroupedMax = 20`, `searchPageDefault = 30`.
   - `csi-spl-wui/src/stores/channel.ts:238` -> `listTopics({...})`; `flow.ts:135`
     -> `listTopics`; `flow.ts:239` -> inside `readMine` (defined :233);
     `flow.ts:272` -> the `countsOnly` read inside `readCounts` (:269).
   - `csi-spl-wui/src/stores/access.ts` -> the in-flight dedupe `pending` at
     :18-44 (`api.me()` at :34).
   - `csi-spl-wui/src/utils/live-ws.mjs` -> `checkRevision` :597, `watchLive`
     :774; `csi-spl-wui/src/composables/useLive.ts` -> `fetchRevision` :85.
   - `csi-spl-wui/src/composables/useComposerWrap.ts` -> `syncMultiline` :129,
     the hidden-span measure `getBoundingClientRect` :65, `getComputedStyle` :57.
   - Existing tests EXIST on both refs: `tests/e2e/perf-baseline-live.proof.mjs`,
     `composer-long-msg.test.mjs`, `composer-buttons-bottom.test.mjs`,
     `flow-search-acceptance.test.mjs`, `issue-parent-search.test.mjs`;
     `tests/unit/composer-grow.test.mjs` EXISTs (N1).
   - The two new test files are ABSENT on both refs, as they must be:
     `tests/e2e/perf-typing-layouts.test.mjs`, `tests/e2e/perf-search-release.test.mjs`.
3. Per row (plan table lines 86-92):
   - Sites per row <= 5: 01 = 2, 02 = 2, 03 = up to 4, 04 = 2, 05 = 2, 06 = 3,
     07 = 1.
   - Baseline with command + number + n on `7e31ade12`: 01 editor 2.7 trace,
     82 forced layouts, n=3; 02 same traces, 43, n=3; 03 editor 2.8 forced-GC
     run, +1,922 retained nodes, n=3; 04 `ENV=dev PF_N=6 PF_PROFILES=d1440
     ./run -a do_spl_wui_perf_flow_events`, 10 reads in 6 first screens, n=6;
     05 editor 2.9 in-page timing, n=5; 06 same dev run, 12 reads in 6 steps,
     n=6; 07 editor 2.5 journey, n=5.
   - Counting test with a red control that fails on today's code: 01 ceiling
     reads 172 -> RED on `7e31ade12`; 02 lowered ceiling -> RED on row 01's
     tree; 03 reads +1,922 -> RED on `7e31ade12`; 04 today's code -> 2; 05
     today's store -> 1 read at creation; 06 today's code -> 2; 07 plant moves
     the type-40 count by about +40.
   - Same-box A/B with n>=5 per arm: only row 04 commits it (n=6 on dev, the
     same run again after the deploy, R5). Rows 05 (n=5) and 06 (n=6) commit
     n>=5 baselines but no after-arm n; rows 01-03 are n=3 on the distinguishing
     trace/heap (the n=5 journey corroborates rows 01-02's 172/176 in 5 of 5);
     row 07 runs the proof twice. See W1.
   - Vendor / kind / batch per row: all `claude` (plan :30, :115); kinds
     simple_coding (01, 02, 04, 05, 06), complex_coding (03), tests (07);
     batches 1, 2, 1, 1, 1, 1, 2.
   - R1 within a batch: batch 1 (rows 01, 03, 04, 05, 06) file sets are disjoint
     (`useComposerSize.ts` + new `perf-typing-layouts.test.mjs`; `SideHitList.vue`,
     `SearchSidePanel.vue`, maybe `HumanName.vue` + new `perf-search-release.test.mjs`;
     `access.ts` + the second caller named before its push; `notification.ts` +
     its unit test; `live-ws.mjs`, `useLive.ts` + their unit test). Batch 2
     (rows 02, 07) is disjoint; row 02 shares `perf-typing-layouts.test.mjs`
     with row 01 across batches, serialized as R1 allows.
   - R7: row authors are claude, row reviewers are non-claude seats (plan
     :182-184), the plan panel is agy + mistral against the claude editor —
     cross-vendor throughout. No WUI row is placed on mistral.
4. Baselines backed by command and output in the plan/editor, gain follows:
   editor 2.7 prints the per-trace table (43 / 41 / 41 forced layouts, n=3,
   41 keys) behind rows 01-02 and the expected gain -41..-82 of 82; editor 2.8
   prints the forced-GC table (+1,922 retained, identical 3 of 3; 400-hit
   17,597..17,799 -> 28,244..28,446, n=3) behind row 03 and the gain
   -1,600..-1,900; editor 2.6 prints the hub-read table (me 10, revision 12,
   n=6) behind rows 04 and 06; editor 2.9 prints the five first-read times
   (39, 10.9, 1.1, 54, 1.4 ms) behind row 05 and the median -10.9 ms gain.
5. R3 / R1 across rounds:
   - `lane-map.sh --check <the 10 row files> --agent m-006` -> exit 4:
     `unknown:` lanes with no files recorded: c-074, c-084, c-148, c-159,
     c-164, c-168, m-135. No lane owns a p19 file; exit 4 is not free, the
     R3 re-check before each spawn stands. `git ls-remote origin | grep -E
     'c-074|c-084|c-148|c-159|c-164|c-168|m-135'` -> no pushed branches under
     those ids.
   - `git diff --name-only origin/master...3123802 -- <the 10 row files>`
     (`3123802` = head of `review/c002-perf-round-20-planner`) -> `0` lines;
     the p20 plan text names a p19 file once, as the measurement command of
     its row 07 (the mock waterfall), not as a row file.
   - `git diff --name-only origin/master...9761e0ea -- <the 10 row files>`
     (`9761e0ea` = head of `review/c002-spl5070-nuxt4-migration`, c-980's
     SPL-5070 branch) -> `0` lines (N2).
6. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO
   distribution-hygiene: clean over the tracked tree`, exit 0 (re-run after
   this edit as well).

## Defects

- **W1** (plan :86-88, :90-92): rows 01-03, 05, 06 and 07 do not commit a
  same-box A/B with n>=5 per arm — only row 04 does (n=6 on dev, re-run after
  the deploy). Rows 01-03 carry n=3 on the distinguishing trace/heap baseline
  (identical in 3 of 3; the n=5 journey corroborates the typing totals), rows
  05/06 commit n>=5 baselines but no after-arm n, row 07 runs the proof twice.
  Rulebook 4.1 (command + number + n on one sha) is met for every row; the gap
  is the after-arm size. Fold into v1.0: commit n>=5 per arm for the A/B of
  rows 01-03, 05-07, or state why the counting test's red control is the guard
  instead.

## Notes

- N1: plan :86 lists `composer-grow.test.mjs` among the e2e files to run; it
  lives at `csi-spl-wui/tests/unit/composer-grow.test.mjs` (EXISTS on
  `7e31ade12` and origin/master); the other two named tests are in
  `tests/e2e/`. The file exists; only its directory differs from the row's
  list.
- N2: plan :124-126 cites c-980's branch as
  `review/c002-spl5070-nuxt4-migration-r2`; `git ls-remote origin | grep -i
  5070` shows only `review/c002-spl5070-nuxt4-migration` (`9761e0ea`) — the
  `-r2` ref is gone. The current branch touches none of the p19 files (0
  lines, check 5).
- N3: origin/master moved between the plan's reads and this review
  (`9a85c02b5` at 12:36Z, `37e0b241e` at 12:43Z, now `6beb21c8c`); 19 commits
  landed on `csi-spl-wui` since `7e31ade12`, but
  `git diff --stat 7e31ade12 origin/master -- <the 10 row files>` -> `0`
  lines, so no cited line and no baseline moved.
- N4: the lane map at review time shows 7 live lanes with no files recorded
  (the plan read 9 at 12:3xZ) — rotation; exit 4 either way and no lane owns
  the p19 files.
- N5: `notification.ts:162-168` contains `hydrate()` (:163-169) calling
  `readPermission()` (:165); the `Notification.permission` read itself is at
  :128 inside `permissionSteps` (:124). Identical on both refs; the citation
  stands.
- N6: p20's plan v0.2 sha `fd664e5b0` is in `review/c002-perf-round-20-planner`'s
  history (3 commits match); the branch head is now `3123802` (the plan said
  `356cffc8c`).
