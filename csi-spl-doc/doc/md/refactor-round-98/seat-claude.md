# Refactor round 98 - panel seat claude (c-429)

## Signature: PASS on f59c0375f (v1.0)

- Read: `csi-spl-doc/doc/md/refactor-round-98-plan.md` on
  `review/c002-refactor-round-98-planner` at **`f59c0375f6dcad8af8d896bf5be2f95a26b9839a`**
  (`git ls-remote` printed this sha). 2026-11-25 ~07:10Z, n=1 each.
- `git merge-base --is-ancestor 52d5d4c17 f59c0375f` -> rc 0. `git log --oneline 52d5d4c17..f59c0375f` -> one commit.
  `git diff --stat` -> the plan only, `25 insertions(+), 15 deletions(-)`. I read every changed line: the status block, 1.2(c), section 7, sections 8 and 9.
- Code blocks unchanged: `diff` of every fenced block between v0.2 and v1.0 -> no output.
  The list of 12-char sha256 values is identical. So every v0.2 result below still holds for v1.0.
- **N6 folded**: `grep -c 027-ui-performance-budget` on v1.0 -> `0`. Lines 140 and 793 now cite
  `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`, and
  `git show 7084439f1:<that path>` -> rc 0.
- **N7 folded**: line 140 reads "box generate, "Estimate for CI, not a CI reading": ~3.1 KB headroom on the box, ~2.8 KB on CI".
- No row, site, batch or vendor changed. No new defect.

---

## Verdict: PASS on 52d5d4c17 (v0.2)

- Read: `csi-spl-doc/doc/md/refactor-round-98-plan.md` on
  `review/c002-refactor-round-98-planner` at **`52d5d4c174befcabbfaeadd6ed342c3c980ef167`**
  (`git ls-remote origin refs/heads/review/c002-refactor-round-98-planner` printed this sha),
  base still `7084439f1`, origin/master at re-review `b1aea77d5`. 2026-11-25 ~06:50-07:10Z, n=1 each.
- `git diff --stat caf5a790e 52d5d4c17` -> one file, the plan, `227 insertions(+), 50 deletions(-)`.
  I read the whole diff: it folds W1, W2 and N1-N5. No row, site, batch or vendor changed.

### W1 (v0.1): fixed

I rebuilt the 6 changed files from the plan's verbatim blocks only, on `7084439f1`:
- the 1.3 helper (plan lines 251-258) and tests (265-274, 281-301);
- the 1.4 helper (393-414, with `:28` changed as the plan's shape says) and tests (421-435, 442-445).

Each block went in before its cited line, followed by one blank line. sha256 (12 chars):
- add.func `d71d9d3dfa83`, add.tst `2ec18079688e`, change.tst `6ceaed529f18`;
- spl-cost-gcp `b1ddd1ea1c94`, estate.tst `21782c35e31e`, vm.tst `d81229828708`.

My v0.1 rebuilds of the other 4 files give delete `9667ab90e009`, update `9331b997770a`,
estate `c8e2c0b78ffd` and vm `a8f4dae10e4d`. **All 10 equal the plan's lines 231-235 and
382-386, byte for byte.**

I ran the controls from those files in detached worktrees of `7084439f1`. The environment was
`SPOOL_TEST=1`, with `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin `/dev/null`. The test
files stub `do_log` and use fixtures, and none of them touches live state.
Format: rc / pass / fail lines / last line.

| control | tree | result | plan says |
|---|---|---|---|
| rc1a add.tst | base + head tests | 1 / 66 / 5 / `FAILED: 4` (3x `_spl_calendar_require_actor: command not found` + `add one copy`) | rc 1, 66, 5 |
| rc1b change.tst | base + head tests | 1 / 35 / 3 / `FAILED: 2` (one copy names `:35`, `:103`) | rc 1, 35, 3 |
| green add / change / update | head1 | 0 / 70 / 0, 0 / 37 / 0, 0 / 34 / 0 | 70/0, 37/0, = |
| gc1a (guard deleted in delete only) | head1 | 1 / 36 / 2 / `FAILED: 1`, `lazy delete` fails | rc 1, 36, 2 |
| gc1b (guard deleted in update only) | head1 | 1 / 36 / 2 / `FAILED: 1`, `lazy update` fails | rc 1, 36, 2 |
| rc2a estate.tst | base + head tests | 1 / 32 / 4 / `FAIL: 3 assertion(s)` (`do_spl_cost_gcp_window: command not found` + one copy `:58`) | rc 1, 32, 4 |
| rc2b vm.tst | base + head tests | 1 / 29 / 2 / `FAIL: 1 assertion(s)` (one copy `:49`) | rc 1, 29, 2 |
| green estate / vm | head2 | 0 / 36 / 0, 0 / 31 / 0 | 36/0, 31/0 |
| gc2 (helper renamed) | head2 | estate 1 / 7 / 29, vm 1 / 10 / 21 | 7/29, 10/21 |

Each red fails for the reason the plan gives: the helper is missing, or the file still has its
own copy. None fails for an environment reason.

The shared suites pass with rc 0 and identical counts on base, head1 and head2. These counts
equal the plan's 1.5 table:
- iac: `no-box-path-source` 10, `action-header-tags` 6, `param-required` 17, `run-lazy-loader` 30, `bash-cleancode` 15, `gcp-billing-export-setup` 30, `gcp-billing-invoices` 69;
- orc: `no-literal-paths` 15, `run-eager-files` 14, `func-name-unique` 2.

`shellcheck -S warning -x` on the 5 files of each head -> rc 0 for both. `do_sec_shellcheck`: NOT RUN.

### W2 (v0.1): fixed

Plan 1.2(c) (lines 134-142) and section 7 (line 764) now account for "for refactor round 95".
- `git merge-base --is-ancestor <sha> 7084439f1` -> rc 0 for each of `c68cca820`, `69dc02d2f` and `76471cb9e`.
- `perf-budgets.json` on `7084439f1`: line 4 `"ci_initial_gzip_kb": 155.0` (the ceiling), line 27 `"ci_initial_gzip_kb": 151.9`.

### Re-checks

- **Slug.** `git log origin/master --since="2026-11-24T19:33:57+02:00" --oneline -E --grep='\(r98-' | wc -l` -> `0`.
  `git ls-remote origin | grep -E 'r98-[0-9]{2}|refactor-round-98'` -> only the planner's branch and my seat branch.
  The briefs dir has only the planner's brief and mine.
- **Drift.** `git diff --name-only 7084439f1 origin/master -- <the 10 row files> | wc -l` -> `0` (origin/master `b1aea77d5`).
- **R3.** `lane-map.sh --check <the 10 paths> --agent c-429` -> exit 4, `WARN no live lane lists <the 10 paths>`, with 18 `unknown:` lanes (17 at v0.1).
  No lane lists a row file. The planner's 2.2 must be re-read at placement.
- **Hygiene.** `cd csi-spl-iac && ./run -a do_check_dist_hygiene` on this commit's tree -> clean, rc 0.

### Notes on v0.2 (non-blocking; fold into v1.0)

- **N6**: plan lines 140 and 764 cite `csi-spl-doc/specs/027-ui-performance-budget/contracts/perf-budgets.json`.
  `git show 7084439f1:<that path>` -> `fatal: path ... does not exist`.
  `git ls-tree -r --name-only 7084439f1 | grep perf-budgets` shows the real file is
  `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`.
  The plan's numbers are right at the real path. Fix the path so that the section 7
  "measured by" command runs.
- **N7**: 151.9 KB comes from a box build, not from CI. The json's own `headroom` text calls it
  "Estimate for CI, not a CI reading" and puts CI at about 2.8 KB under the ceiling. So
  "~3.1 KB headroom" should say that it is the box figure. This does not change the
  accounting: the item is served on the base.

---

# Verdict on v0.1 (kept as recorded)

- Seat: c-429 (claude), placement `c002-refactor-round-98-claude-panel-seat`, issue SPL-6457.
- Read: `csi-spl-doc/doc/md/refactor-round-98-plan.md` on
  `review/c002-refactor-round-98-planner` at **`caf5a790e5c47c2b7149139239aebefa6b0a7f7f`**
  (`git ls-remote origin refs/heads/review/c002-refactor-round-98-planner` printed this sha),
  plan base `7084439f15cfdc93915fa52161c3f8c58e1483ae`, origin/master at review time
  `5c0ba2f40c736bc907283eb932f3e9396d61e654`.
- Rules: `rounds-rulebook.md` sections 1-3 and 5; form: `refactor-round-97-plan.md` (origin/master).

## Verdict: FAIL on caf5a790e (v0.1)

Both rows are sound refactors. My own rebuild of each row's call sites keeps behaviour, and
the existing suites would catch a broken helper. I fail v0.1 for two plan-text defects, W1
and W2. Both are fixable in v1.0 without touching a row.

## Checks (n=1 each unless stated; 2026-11-25 ~06:15-06:45Z)

### 1. Slug r98 unused since W

- `git log 7084439f1 -1 --format='%H %cI %s' -E --grep='^docs\(r97-plan'` -> `3364c37cf... 2026-11-24T19:33:57+02:00`, so the plan's `W` is right for its base.
  On origin/master the newest such commit is now `5855e3ca3` (2026-11-25T07:50:08+02:00, the r97 close record). `git merge-base --is-ancestor 5855e3ca3 7084439f1` -> rc 1, so it came after the base. Rulebook 5.3 reads W once, so the plan's W stands (N1).
- `git log origin/master --since="2026-11-24T19:33:57+02:00" --oneline -E --grep='\(r98-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r98-[0-9]{2}|refactor-round-98'` -> only `caf5a790e... refs/heads/review/c002-refactor-round-98-planner` (expected).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r98-[0-9]{2}|refactor-round-98'` -> `c002-refactor-round-98-claude-panel-seat.md`, `c002-refactor-round-98-planner.md` (expected).

### 2. Sites exist on the base and on origin/master

- I read each cited line with `git show 7084439f1:<file> | sed -n <N>p`. All match the plan:
  - add `:193` = the `# _spl_calendar_event_body` comment, `:203-204` = the two actor lines;
  - delete `:35-36` and update `:103-104` = the same two lines;
  - `add.tst.sh:158` and `change.tst.sh:111` = the `ALL PASS` lines;
  - `spl-cost-gcp.func.sh:28` = `# shellcheck disable=SC2034 ...`, `:64` = the separator that opens the `do_gcp_bq_api` header;
  - estate `:56-66` and vm `:47-57` = the 11-line block (vm `:56` `local i tmp`);
  - `estate.tst.sh:247` and `vm.tst.sh:188` = the `PASS: all` lines.
- File lengths on the base (`wc -l`): 235 / 99 / 127 / 158 / 111 / 101 / 279 / 158 / 248 / 189. These equal the plan's "before" counts.
- `git diff --name-only 7084439f1 origin/master -- <the 10 row files> | wc -l` -> `0`: nothing drifted.

### 3. Red controls

**NOT RUN as the plan's own files** (W1). `rc1a`, `rc1b`, `gc1a`, `gc1b`, `rc2a`, `rc2b` and `gc2` are head test files built in scratch worktrees, and plan line 68 says they were "removed on exit". No branch, commit or plan block holds them. `find /tmp /var/tmp /mnt/data/tmp -maxdepth 6 -name spl-calendar-event-change.tst.sh -mmin -240` printed nothing. I cannot print their sha256sum or run them.

What I ran instead, in detached worktrees of `7084439f1` under a scratch dir (no live state: `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, stdin `/dev/null`, no `DRY_RUN=0`):

- **Rebuilt heads.** I rebuilt head1 and head2 from the shapes in 1.3 and 1.4 (code files only, not the new tests). sha256 (12 chars):
  - delete `9667ab90e009`, update `9331b997770a`, estate `c8e2c0b78ffd`, vm `a8f4dae10e4d`: **byte-identical to the plan's lines 213-217 and 296-300**;
  - add `752da2d5a875` and spl-cost-gcp `7f771311adab`: these differ from the plan, as expected, because my helper comments use my own wording.
  - So the call-site shape is unambiguous.
- **Mutation control, row 01.** I deleted the `ORDERED_BY` line inside `_spl_calendar_require_actor`. Results:
  - `spl-calendar-event-add.tst.sh` rc 1, last line `FAILED: 1`;
  - `-change.tst.sh` rc 1, `FAILED: 2`;
  - `-update.tst.sh` rc 1, `FAILED: 1`.
  - This is a real failure for the reason intended (a lost check), not an environment problem.
- **Mutation control, row 02.** I changed the window loop to `i > 0` (one day lost). Results:
  - `spl-estate-cost-read.tst.sh` rc 1, `FAIL: 10 assertion(s) in spl-estate-cost-read.tst.sh`;
  - `spl-vm-cost-per-day.tst.sh` rc 1, `FAIL: 3 assertion(s) in spl-vm-cost-per-day.tst.sh`.
  - My first mutation for row 02 (DAY regex `{1,2}`) was behaviour-neutral, because the `date -u -d` round-trip still refuses a 1-digit day: rc 0 on both, as it should be.

### 4. Equivalence

Suites run on base, head1 and head2. The format is rc / pass lines / fail lines, counted with `grep -ciE '^ *(ok|pass)'` and `'^ *(not ok|fail)'`:

| suite | base | head1 | head2 |
|---|---|---|---|
| orc spl-calendar-event-add.tst.sh | 0/66/0 | 0/66/0 | 0/66/0 |
| orc spl-calendar-event-change.tst.sh | 0/33/0 | 0/33/0 | 0/33/0 |
| orc spl-calendar-event-update.tst.sh | 0/34/0 | 0/34/0 | 0/34/0 |
| iac spl-estate-cost-read.tst.sh | 0/33/0 | 0/33/0 | 0/33/0 |
| iac spl-vm-cost-per-day.tst.sh | 0/30/0 | 0/30/0 | 0/30/0 |
| iac gcp-billing-export-setup.tst.sh | 0/30/0 | 0/30/0 | 0/30/0 |
| iac gcp-billing-invoices.tst.sh | 0/69/0 | 0/69/0 | 0/69/0 |
| iac run-lazy-loader.tst.sh | 0/30/0 | 0/30/0 | 0/30/0 |
| iac bash-cleancode.tst.sh | 0/15/0 | 0/15/0 | 0/15/0 |
| orc run-eager-files.tst.sh | 0/14/0 | 0/14/0 | 0/14/0 |
| orc func-name-unique.tst.sh | 0/2/0 | 0/2/0 | 0/2/0 |

The base column equals the plan's 1.5 base column. The suites were not run on these trees, so their results are not claimed: `no-box-path-source`, `action-header-tags`, `param-required`, `no-literal-paths`, `shellcheck`, `do_sec_shellcheck`. They stay R7's to run.

Reads behind the equivalence claim:

- **Row 01.**
  - The helper runs the same two regex tests, with the same messages and `return 1`, as the lines it replaces.
  - `spl-calendar-event-add.func.sh` has no top-level code. An awk pass printing the non-function, non-comment lines printed nothing, so sourcing it inside a function sets no globals or locals.
  - Function names across the three files are disjoint (`grep -oE '^[A-Za-z_]+\(\)'`): sourcing add from delete or update redefines nothing those files own.
- **Row 02.**
  - Same order: DAY check, then `do_resolve_oap ORG/APP` (`export`s, so global from any depth; `resolve-oap.func.sh:15-31`), then `do_spl_cost_gcp_cnf || return 1`, then the loop.
  - `i` is used after the block only inside awk programs (estate `:200-243`, vm `:127-140`), so dropping the caller's `local i` changes nothing.
  - Exit codes and FATAL text are unchanged.
  - The only new state is the two globals `COST_WINDOW_DAY` and `COST_WINDOW_DAYS` (N3).
- **Neither row** changes an exit code, a message, a path or a default.

### 5. Row form

- Each row has a control that fails today and passes after (R2, as described), a test list, vendor claude, kind `simple_coding` and batch 1.
- There is no mistral coding or testing row.
- R7 is an agy seat per row (cross-vendor to claude), with the claude backup only while agy is out. That backup would be same-vendor as the claude row author, so it is only valid under the waiver the plan cites (N4).
- R1: the row file sets are disjoint (orc vs iac, plan 2.1).

### 6. R3

`lane-map.sh --check <the 10 paths> --agent c-429` -> exit 4, `WARN no live lane lists <the 10 paths>, but 17 live lane(s) record no files: their scope is unknown, not free`. The last two `unknown:` lines were `c-957` (other box) (personnel cost spec) and `c-965` (other box) (rotate). The planner's 2.2 names the same 17 and reads them as other-repo, spec or channel seats. I did not read those briefs; they are on the other box. No lane lists a row file. The cost-named lane c-957 is a spec lane on another repo by its slug, which I have not verified.

### 7. Inputs accounted for

- In `/var/spool-hub/dispatch/c002-next-round-candidates.md` (140 lines), the block at `:124-125`, "for refactor round 95 ... REFACTOR/PERF: WUI entry-chunk headroom is gone ... Row shape: an eager-core split like SPL-4978", is refactor-shaped.
- Neither the plan's 1.2(c) (lines 119-132) nor its section 7 names it. `grep -n 'perf-budget\|refactor round 95'` returned nothing on the plan, and nothing on the r97 plan either (W2).
- `git log origin/master --since=2026-11-23 --format='%h %s' | grep -iE 'entry|initial_gzip|eager-core|budget'` shows no commit that serves it.
- Each row is one logical refactor, and neither is a bug row (check 4).

### 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/c-429`, rc 0.

## Defects

- **W1** (plan lines 68, 213-217, 296-300, 350-380): the 7 red and guard controls and both heads' test files exist on no tree, so their sha256 cannot be checked and no panel or R7 seat can re-run them. For v1.0, either:
  - add the 4 test hunks (add.tst.sh section 8, change.tst.sh section 6, estate.tst.sh section 8, vm.tst.sh section 6) to the plan as code blocks; or
  - push the two heads to a `wip/` branch and cite its sha.
  
  Without that, the "RED then GREEN" lines are the planner's paste only.
- **W2** (plan lines 119-132; section 7, lines 590-604): the candidates-file item "for refactor round 95" (WUI entry-chunk gzip headroom, eager-core split) is refactor-shaped and neither served nor accounted for. Add a section 7 row with its reason, for example: WUI, needs Chrome e2e and a CI-node budget measurement, overlaps live WUI lanes.

## Notes

- **N1**: since the base, `5855e3ca3` (r97 close record, `docs(r97-plan`) landed. W stays at the plan's recorded `2026-11-24T19:33:57+02:00`, as rulebook 5.3 says. Later R4/R6 reads must use that recorded date, not a fresh derivation.
- **N2**: plan line 256 says `spl-cost-gcp.func.sh` is "already sourced by `csi-spl-iac/run`". In fact it is lazily stub-loaded (`run.sh:883-891`, `_RUN_INDEX_AWK`: a functions-only file is not sourced; each of its functions gets a stub). The conclusion, that no extra `source` line is needed, still holds.
- **N3**: row 02 adds two process globals, `COST_WINDOW_DAY` and `COST_WINDOW_DAYS`. Harmless for `./run`, but the helper's header should say that it sets them.
- **N4**: row 01's `declare -F ... || source` guard only acts outside `./run`. Under `./run` the stub always exists. update already calls add's `_spl_calendar_event_link` and `_spl_calendar_reminders` with no guard (`spl-calendar-event-update.func.sh:62,111`). So `gc1a` and `gc1b` prove only the standalone-source path. That is acceptable, but the brief should say so.
- **N5**: if the claude R7 backup is used, it is same-vendor as the claude author (rulebook 2.7.2). The plan's section 4 cites ruling `dc84300a` for it; the holder should cite the ruling in the row brief.
