# Perf round 19 (p19): the agy panel seat (c-996, run on claude)

Seat: c-996, placement `c003-perf-round-19-agy-panel-seat`. Issue SPL-6363,
Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, class
refactor, kind specs_and_docs, topic `4369bb74-1889-402e-8388-a30332f3c5f8`.
Editor: c-778 (claude).

**Vendor of this seat: claude, not agy** (N1). The brief and plan section 5
(`perf-round-19-plan.md:178-179`) ask for an agy seat; this seat was started
as a Claude Code session. The planner is claude too, so this seat is NOT
cross-vendor in the sense of rulebook 3.2. The holder decides whether it
counts; the checks below stand either way.

Review target: plan v0.1 `d86a2f88026831932f48dfbe04183853a174c008` on
`review/c002-perf-round-19-planner` (the sha the brief names for c-778).
`git fetch origin master review/c002-perf-round-19-planner` then
`git rev-parse origin/review/c002-perf-round-19-planner` ->
`d86a2f88026831932f48dfbe04183853a174c008`; `git log -1 --format='%H %P %ae %ce'`
-> parent `82745dc0b2822184cafdc34efa282833e548113e`, author and committer
csitea.net; `git diff --stat d86a2f88^ d86a2f88` -> `perf-round-19-plan.md`
+227, `perf-round-19/editor.md` +96/-11. Read in full at that sha: the plan
(227 lines) and the editor file. `origin/master` at this read (18:43Z):
`0f872e92ea6b882bb75c9f38f8a12385eb097f7b`.

## Verdict

**FAIL on `d86a2f88026831932f48dfbe04183853a174c008`** (plan v0.1, 7 rows).
All four defects can be fixed in v1.0 without changing a row's scope: W1 (the
"one sha" claim no longer holds, Nuxt 4 landed), W2 (no row names a same-box
A/B with n>=5 per arm), W3 (row 01's test names Playwright, which the WUI does
not have), W4 (two file:line ranges are wrong). The baselines this seat
re-read (rows 01, 02, 04, 06 and the row 03 journey) reproduce.

## Checks (each with the command run and what it printed, 2026-11-24 18:4x-19:0xZ)

1. Slug p19 unused on master:
   - `git log origin/master --oneline -E --grep='\(p19-' | wc -l` -> `0`
   - `git ls-remote origin | grep -E 'p19-[0-9]{2}|perf-round-19'` -> one
     line, `d86a2f88026831932f48dfbe04183853a174c008 refs/heads/review/c002-perf-round-19-planner`
     (the planner's branch, expected).
2. File:lines on `7e31ade12` and on `origin/master` `0f872e92e`:
   - `git merge-base --is-ancestor 7e31ade12 origin/master` -> yes.
   - Row files, `git log --oneline 7e31ade12..origin/master -- <the 13 row and cited files> | wc -l`
     -> `0`; `wc -l` of each is equal on both shas (useComposerSize.ts 188,
     useComposerWrap.ts 147, SideHitList.vue 247, SearchSidePanel.vue 306,
     HumanName.vue 104, access.ts 59, notification.ts 586, live-ws.mjs 811,
     useLive.ts 243, perf-baseline-live.proof.mjs 359, channel.ts 800,
     flow.ts 435, search.go 892). No row file drifted.
   - But the WUI around them did: `git log --oneline 7e31ade12..origin/master -- csi-spl-wui | wc -l`
     -> `19`, among them `295f426dd` (Nuxt 3 -> 4) and `71d9941e3` (node 22).
     See W1.
   - Cited lines, `git show <sha>:<file> | sed -n <N>p`, same text on both
     shas:
     - `useComposerSize.ts:37` -> `function useFit(o: SizeOpts, st: BoxState) {`;
       `:47` -> `    const box = el?.closest('form')` (inside `omniboxMax`);
       `:53` -> `  function fitGlobalBox() {`; `:78` -> the
       `document.activeElement === el && el.selectionEnd ...` line; `:79` ->
       `  }`. The plan's `:47-78` for `fitGlobalBox`: W4.
     - `notification.ts:162` -> empty; `:163` -> `  function hydrate() {`;
       `:168` -> `    alertsEnabled.value = loadAlerts()`; `:169` -> `  }`.
       The plan's `:162-168`: W4.
     - `channel.ts:238` -> `api.listTopics({ dm: true, limit: 50, dmCounts: true, dmRead })`;
       `flow.ts:135` -> `api.listTopics({ limit: FLOW_TOPICS, ... })`;
       `flow.ts:239` -> `api.listFlow({ limit: FLOW_PAGE, ... fold: true })`;
       `flow.ts:272` -> `api.listFlow({ countsOnly: true, self: self() })`;
       `search.go:33` -> `searchGroupedDefault = 5`; `:35` ->
       `searchPageDefault    = 30 // one section, ...`. All as the plan says.
   - Symbols the rows name, `git show origin/master:<file> | grep -n`:
     `useComposerWrap.ts:57` `getComputedStyle(el)` and `:65`
     `measureEl.getBoundingClientRect().width` in `draftWidth` (row 02's
     hidden-span measure), `:129` `function syncMultiline()`;
     `access.ts:18` `let pending`, `:21` `if (pending && !force) return pending`
     (dedupes only a read in flight, as row 04 says); `live-ws.mjs:597`
     `async function checkRevision(c)`, `:774` `export function watchLive`,
     `:798` the `visibilitychange` listener; `useLive.ts:85` `fetchRevision`;
     `useComposerSize.ts:11` imports `useComposerWrap` (the batch 2 reason
     holds).
   - Test files the rows name, `git cat-file -e origin/master:<f>`: EXISTS
     `tests/e2e/composer-long-msg.test.mjs`, `composer-buttons-bottom.test.mjs`,
     `flow-search-acceptance.test.mjs`, `issue-parent-search.test.mjs`,
     `tests/unit/composer-grow.test.mjs` (unit, not e2e); MISSING (correctly
     new) `tests/e2e/perf-typing-layouts.test.mjs`,
     `perf-search-release.test.mjs`.
3. Each row (plan lines 86-92):
   - Sites: 01 two files, 02 two, 03 three or four, 04 one or two, 05 one +
     its test, 06 two + their test, 07 one. At most 5 each.
   - Baseline with command, number, n: every row names its editor section,
     a number and n (01 82 n=3, 02 43 n=3, 03 +1,922 n=3, 04 10/6 n=6,
     05 1.1..54 ms n=5, 06 12/6 n=6, 07 n=5). For 01, 02, 03, 05 the command
     is a scratch probe outside the repo (N6).
   - Test + red control that fails on today's code: present on all 7 rows.
   - **Same-box A/B with n>=5 per arm: on no row.** W2.
   - Vendor / kind / batch: all 7 rows carry them; every row `claude`
     (no mistral WUI row).
   - R1 within p19: batch 1 = 01, 03, 04, 05, 06 with disjoint file lists
     (plan 3.1); 02 and 07 in batch 2. Row 04's second caller is unnamed, so
     its disjointness is re-checked before its push (the plan says so).
   - R7: plan 5 (line 182-184) asks a non-claude reviewer for every row (N7).
4. Baselines re-read from the editor's own raw output (this box, read only):
   - Rows 01, 02: a python count of `Layout` events by first stack frame in
     `/var/tmp/c-778-p19/probe2/type{,2,3}.trace.json` -> in each of 3:
     `n:2:99285` 43, `i:2:101644` 41, `i:2:101675` 41, no stack 43,
     keydown 41, forced ms 239 / 163 / 172. Matches editor 2.7. The gains
     follow: row 01 removes at most the 82 `fitGlobalBox` reads, row 02 the
     43 text-width reads (the plan says -41 per 40 keys; per 41 keys it is
     43).
   - Row 01/02 journey: `/var/tmp/c-778-p19/probe-n5.log` -> type-40
     `172` layouts and `176` style recalcs in 5 of 5 rounds (load1
     86.7..124.5). Matches editor 2.5.
   - Row 03 journey (400 rows): `probe2/attr{,2,3}.json` nodesGC search ->
     back -> search2 -> back2: 17,608 / 17,783 / 28,255 / 28,430;
     17,597 / 17,772 / 28,244 / 28,419; 17,799 / 17,974 / 28,446 / 28,621.
     Matches editor 2.8. The 30-hit +1,922 (n=3) has no saved output in the
     scratch; not re-read (N8).
   - Rows 04, 06: `/var/tmp/c-778-p19/flow-dev/timing.json` (read as its
     owner, the dir is 0700), python per round -> `n 6`, build 3.6.7 `6c741f5b0`; first-screen
     `/v1/view/me` per round 1, 1, 2, 2, 2, 2 (all 200) = 10; flow-open
     `/v1/wui/revision` 2 in each of 6 = 12. Matches editor 2.6. The gains
     follow (4 duplicate `me` reads in 6, one revision read per step).
5. R3 and R1 across rounds:
   - `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 12 row files, the two new tests included> --agent c-996`
     -> **exit 4**: `WARN no live lane lists <the files>, but 7 live lane(s)
     record no files: their scope is unknown, not free`; the `unknown:`
     lanes are c-074, c-084, c-148, c-159, c-164, c-168, m-135 (box
     qualifiers dropped for the hygiene sweep). No lane owns a p19 file; exit
     4 is not free (N2).
   - Perf round 20: `git fetch origin review/c002-perf-round-20-planner` ->
     head `312380222` (plan v1.0); `git diff --name-only origin/master...312380222 | grep -cE '<p19 files>'`
     -> `0`; in its plan, `grep -E '<p19 files>'` -> one hit, row 07 line
     118, column 3 (its baseline cites `perf-baseline-live.proof.mjs MOCK=1
     WATERFALL=1` as the command it ran), not a site of the row (column 5 is
     `nuxt.config.ts:539`, `:561-562`, `first-screen-hints.mjs:151`). No p19
     file in a p20 row.
   - c-980 (SPL-5070): `git ls-remote origin | grep spl5070` -> only
     `review/c002-spl5070-nuxt4-migration` (`9761e0eab`); the `-r2` branch
     the plan names (line 128) is gone: the migration landed as `295f426dd`
     (W1). `git diff --name-only origin/master...9761e0eab | grep -cE '<p19 files>'`
     -> `0` of 16 files.
   - The one WUI lane with no recorded files, c-168:
     `review/c003-feat-wui-releases-desktop-single-column` `ab3e4d5e6`, 3
     files, p19 hits `0`.
6. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO
   distribution-hygiene: clean over the tracked tree of
   /opt/csi/csi-spl-wt/c-996`, before and after this file was written.

## Defects

- **W1 (plan lines 41-49, 128-130; editor lines 12-20): the one-tree claim
  no longer holds.** The plan says `git log --oneline 7e31ade12..9a85c02b5 --
  csi-spl-wui | wc -l` -> 0 "so every number holds on both". On
  `origin/master` `0f872e92e` the same count is 19, among them `295f426dd`
  (`git diff 7e31ade12 origin/master -- csi-spl-wui/package.json`: nuxt
  `^3.16.0` -> `^4.6.4`, vue-router `^4.5.0` -> `^5.5.1`, vite `^7.3.7` ->
  `^8.3.5`, engines node `>=20.0.0` -> `^22.22.3 ...`; the lock's vue
  3.5.43 -> 3.5.45) and `71d9941e3` (`10_ci-quality.yml:633` `node-version:
  22`, was 20). The row files did not change (check 2), but the mock bundle
  rows 01, 02, 03 and 07 were measured on is a Nuxt 3 / node 20 build, and
  row 03's retainer chain runs through Vue's scheduler and vnode tree. Fix in
  v1.0: name the new tree, and either re-read one mock count per row (type-40
  layouts; the 30-hit retained nodes) on a generate of `295f426dd` or later,
  or say that each lane reads its red control on its own rebased tree, quotes
  that before-number, and drops the row if the gain is gone. Also update the
  c-980 bullet (line 128-130): it has landed.
- **W2 (plan lines 86-92): no same-box A/B with n>=5 per arm.** Row 01 says
  "The lane measures both arms" with no n; rows 02-07 name none. Fix: per
  row, a same-box A/B, n>=5 per arm, its count (layouts, retained nodes,
  requests, reads) as the primary metric, as plan line 50 already argues.
- **W3 (plan line 86): row 01's test is "Playwright + CDP".**
  `git show origin/master:csi-spl-wui/package.json | grep -i playwright` ->
  nothing; the e2e driver is `puppeteer-core` `^25.13.0` (package.json line
  41), the one the proof file and the composer e2e use. As written the row
  adds a dependency. Fix: name puppeteer-core (CDP through it).
- **W4 (plan lines 86, 90): two ranges are wrong** (on `7e31ade12` and
  master alike, so wrong when written, not drift): `useComposerSize.ts
  (useFit.fitGlobalBox, :47-78)` -> `fitGlobalBox` is `:53-79` (`:47` is in
  `omniboxMax`; `useFit` starts at `:37`; if the range is meant to include
  the `omniboxMax` reads of plan 4, say `:39-79`). `notification.ts
  (permissionSteps.hydrate, :162-168)` -> `:163-169`.

## Notes

- N1: this seat is claude (see the header). A cross-vendor signature for
  rulebook 3.2 still needs a non-claude seat; the mistral seat is one.
- N2: check 5 exits 4 (7 unknown-scope lanes). The plan's own read
  (line 131-135, 12:3xZ) named 9 different lanes; the R3 re-check before each
  spawn is the one that counts.
- N3: row 06's baseline step did not do what its name says: editor 2.6
  (lines 144-145) records that the flow-open step's selector never matched
  (the Flow entries opened release notes). The 2 revision reads per step are
  real (check 4) but their trigger is not yet tied to opening Flow; the row's
  drop rule covers that. The probe was fixed since (`8d348dbe1`).
- N4: row 05 is the one row whose baseline is only ms (1.1..54, load ~100,
  plus an n=1 profile), against plan lines 50-55 (counts rank, ms do not).
  Its count is "1 read at creation"; v1.0 may say why it ranks above 06.
- N5: the three traces also hold one forced layout at `:2:98603` and one at
  `i:2:101491` each, not in editor 2.7's table; they do not change a row.
- N6: the raw output behind rows 01-03 and 05 is a scratch dir on one box
  (`/var/tmp/c-778-p19/`), not committed. Row 07 commits the journey; rows
  01-03 still depend on their lanes re-running the probes.
- N7: plan 5 asks a "non-claude" R7 for every row; all rows are WUI. If the
  holder's pick may be mistral, v1.0 may state whether the fleet's UI rule
  (no mistral UI work until `do_spl_vendor_ui_retest` passes) covers an R7
  review of a WUI row, which must run the mapped e2e.
- N8: the 30-hit retained count (+1,922, n=3) was not re-read: no saved
  output for those runs in the scratch dir (`ls probe2/` -> attr, heap,
  perm, trace and snapshot files only).

<a id="p19-seat-agy-v1"></a>

## v1.0 signature (2026-11-24 19:0xZ)

Editor c-778 named v1.0 `a1f63000c23d4ddea12aaa69444e36027d340d70` on
`review/c002-perf-round-19-planner` (msg 1d966ead, task dispatch-perf-r19;
it replaces `0a1705f2c`, msg 1fe2f7dc). `git rev-parse
origin/review/c002-perf-round-19-planner` -> `a1f63000c...`; `git log
d86a2f88..a1f63000c` -> 2 commits (`0a1705f2c`, `a1f63000c`), both
csitea.net; `git diff --stat d86a2f88 a1f63000c` -> only the plan and
`editor.md`. `origin/master` at this read: `6beb21c8c`.

**PASS on `a1f63000c23d4ddea12aaa69444e36027d340d70`** (plan v1.0, 6 rows:
01, 02, 03, 06, 05, 07; row 04 dropped by measurement). The same caveat as
above: this seat is claude (N1).

Checks:

1. W1 fixed. Plan 1 names both trees and re-reads one count per row on
   `0f872e92e`. Re-read from the editor's new raw output:
   - Layout events by first stack frame in
     `/var/tmp/c-778-p19/probe3/type{1,2,3}.trace.json` -> in each of 3:
     `C0udEsMn.js:2:94178` 43, `:2:93076` 41, `:2:93107` 41, no stack 43,
     plus `:2:93435` 1 and `:2:92923` 1; keydown 41. Matches editor 2.11.
     This seat did not re-map those columns to source (N11).
   - `/var/tmp/c-778-p19/heap30-ab.log` -> new bundle retained 1908 / 1921 /
     1921, old bundle 1922 x3. Matches row 03 and editor 2.11. This also
     answers N8.
   - `flow-dev2/timing.json` (read as its owner) -> build 3.7.6, commit
     `0f872e92ea6b...`, n 6; `/v1/view/me` 1 in each of 6 first screens
     (row 04's drop holds), `/v1/wui/revision` 2 in each of 6 flow-open
     steps (row 06 holds).
   - Row files: `git log --oneline 7e31ade12..origin/master -- <the 9 row
     files>` -> `0`. The c-980 bullet now says it landed.
2. W2 fixed: plan 3.3 gives every row a same-box A/B with n>=5 per arm,
   counts as the primary metric, and drops the row when the gain is not
   outside the before-arm's range.
3. W3 fixed: row 01 names `puppeteer-core` (the WUI's e2e driver).
4. W4 fixed: row 01 `:53-79`, row 05 `:163-169`. `git show
   origin/master:csi-spl-wui/src/composables/useComposerSize.ts | sed -n 53p`
   -> `  function fitGlobalBox() {`, `:79` -> `  }`; `notification.ts:128` ->
   `permission.value = ... Notification.permission`, `:165` ->
   `readPermission()`.
5. Slug: `git log origin/master --oneline -E --grep='\(p19-' | wc -l` ->
   `0`; `git ls-remote origin | grep -E 'p19-[0-9]{2}|perf-round-19'` ->
   the planner branch, this seat's and `review/c003-perf-round-19-mistral-seat`.
6. R3: `lane-map.sh --check <the 11 p19 files> --agent c-996` -> exit 4,
   8 unknown lanes (c-074, c-084, c-087, c-148, c-159, c-164, c-168, m-135),
   no owner (N10).
7. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> clean, after this
   edit.

Defects (v1.0): none.

Notes (v1.0):

- N9: plan line 18 still reads "**Row count: 7, the owner's**", while line
  31-34 and the title say 6. The 6-row bullet names the conflict and leaves
  the choice to the holder. Rewording line 18 would be enough; it is not a
  defect against the rulebook.
- N10: c-087 is new in the lane map. Its bug (phone Back from a channel's
  topics) landed as `0f872e92e`: `git show --name-only 0f872e92e` -> 7
  files (`useMobileStack.ts`, `mobile-stack.mjs`, phone e2e and unit tests),
  none of them a p19 file.
- N11: the new trace columns (`C0udEsMn.js:2:94178` etc.) are mapped to
  source by the editor. This seat checked the counts, not the mapping. The
  counts and their split (43 / 41 / 41) equal the v0.1 traces, whose mapping
  matched the source.
