# Bug-fix round 1 - retrospective

Measured 2026-10-18 on trunk **`11ce3c834`** (`origin/master`) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for bug round 2. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-2448 (lane SPL-2519).

Plan: [bug-round-1-plan.md](bug-round-1-plan.md), v1.0
`17c1eaf62`, signed by reviewer claude seat `c-835` (`64bc93144`)
and editor `a-391@sat` (agy).
Topic history: spool topic `dispatch-bug-round-1` (`spool tail --task dispatch-bug-round-1`).

## 1. What landed

`git log origin/master -E --grep='(b01-[0-9]{2}|SPL-(2457|2458|2490|2491))' --format='%h %cI %s'` -> **4**
commits on trunk; all 4 rows landed on master.
Ancestry verified: `git merge-base --is-ancestor <sha> origin/master` exits 0 for all 4 landed shas.

| row | landed sha (lane) | landed (UTC) | pushes | red control | what it fixed, measured on `11ce3c834` |
|---|---|---|---|---|---|
| 01 `fix(b01-01-orc-wd-heldout-restore-tag-env)` | `8ac0f7d62` (c-842@<box>) | 23:15Z | 1 | yes | Cleared host spool identity variables (`SPOOL_BOX_ENV_KEYS`, `BOX_TAG`, `SPOOL_BOX`, `SPOOL_AGENT_ID`) in `wd-heldout-hand-restore.tst.sh` so host `SPOOL_BOX_TAG` does not override test fixture `box.env`. Line 81 assertion failure eliminated. |
| 02 `fix(b01-02-orc-test-pre-push-hook-stdin)` | `ef312bbcc` (c-394@sat) | 23:42Z | 1 | yes | Fed synthetic ref lines to all 6 unredirected `bash "$HOOK"` calls in `test-pre-push-hook.sh` so `pre-push` hook's `cat` does not hang waiting indefinitely on idle terminal stdin (rc 124 timeout at 40s -> 0 failed in ~1s). |
| 03 `fix(b01-03-orc-desk-cron-safe-dirty-recovery)` | `8e1895d8d` (c-424@sat) | 04:13Z | 1 | yes | `desk-reconcile-cron.sh` safely recovers a dirty checkout behind trunk: snapshots staged and unstaged tracked changes to `refs/rescue/desk-cron/<ts>` via `git stash create` and `update-ref`, resets tracked files and checks out trunk; untracked files left untouched. Eliminates stale cron execution. |
| 04 `fix(b01-04-orc-guard-desk-cron-tree-writers)` | `40262df55` (c-425@sat) | 04:50Z | 1 | yes | Root-cause defense for Row 03: created `spl_refuse_desk_cron_tree` guard (`spl-desk-cron-tree-guard.func.sh`) and wired into `do_spl_doctree_export_md`, `do_spl_doctree_import_md`, `do_spl_i18n_mask`, `do_spl_i18n_unmask` to refuse tree writes when run in a `*-desk-cron` worktree (FATAL, rc 1, 0 writes). |

All landed rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -cE 'SPL-(2457|2458|2490|2491)'` -> 0).
Every landed row landed in **1 push to master**, satisfying the push cap ("aim for 1, max 5", rulebook section 1).
All 4 rows are tooling/test fixes under `csi-spl-orc/`; per R5, changes with no deploy input are done on landing.

## 2. Review line verification (`do_spl_review_line_check`)

### Row 01 (`8ac0f7d62`)
- **Review line in commit:** None (empty).
- **Check output:**
```text
FATAL REVIEW_LINE must be set (the 'review: ...' line)
```
- **Verification note:** Row 01 was dispatched as ask `cc9fdc39` before bug round 1 plan v1.0 was approved and before the reviewer seat was spawned. It landed without an R7 review line. Red control proof was recorded in the commit body and report (`c-842`).

### Row 02 (`ef312bbcc`)
- **Review line in commit:** None (empty).
- **Check output:**
```text
FATAL REVIEW_LINE must be set (the 'review: ...' line)
```
- **Verification note:** Row 02 was dispatched as ask `e108c643` before bug round 1 plan v1.0 was approved and before the reviewer seat was spawned. It landed without an R7 review line. Red control proof was recorded in the commit body and report (`c-394`).

### Row 03 (`8e1895d8d`)
- **Review line in commit:**
```text
R7 review: a-391@sat agy PASS 9dca293ca72c204e50fc01d23aa7b97689268022 ran: desk-cron-trunk.tst.sh on FETCH_HEAD and red control on origin/master | read: 0 failure(s) on 9dca293ca, 4 failure(s) on origin/master (msg 66e82e38)
```
- **Check output on commit line:**
```text
FATAL the line has no '| log: <id>@<box>:<path>'
```
- **Check output on spool message line (`msg 66e82e38`, which had `| log: a-391@sat:dispatch-bug-round-1`):**
```text
FATAL log dispatch-bug-round-1 is not readable on sat as <user>
```
- **Verification note:** Reviewed cross-vendor by editor `a-391@sat` (agy) on claude author `c-424@sat`. The reviewer emitted `log: a-391@sat:dispatch-bug-round-1` (a spool task name rather than a session journal file path). The author then replaced `| log: ...` with `(msg 66e82e38)` in the commit message. The reviewer's actual transcript exists on `sat` in `~/.gemini/antigravity-cli/brain/df288f5f-d3b4-4ddf-904b-4195d6242a68/.system_generated/logs/transcript.jsonl`.

### Row 04 (`40262df55`)
- **Review line in commit:**
```text
R7 review: a-391@sat agy PASS eb0e0c79ad8c0add035630a465d4b9937ea97219 ran: desk-cron-write-guard.tst.sh, spl-i18n-mask.tst.sh, check-qto-doc-drift.tst.sh, doctree-export-md.tst.sh on FETCH_HEAD and red control on origin/master | read: ALL PASS (12) on eb0e0c79a, 7 FAILED on origin/master (msg dd233e16)
```
- **Check output on commit line:**
```text
FATAL the line has no '| log: <id>@<box>:<path>'
```
- **Check output on spool message line (`msg dd233e16`, which had `| log: a-391@sat:dispatch-bug-round-1`):**
```text
FATAL log dispatch-bug-round-1 is not readable on sat as <user>
```
- **Verification note:** Reviewed cross-vendor by editor `a-391@sat` (agy) on claude author `c-425@sat`. Emitted with `log: a-391@sat:dispatch-bug-round-1` and trimmed in the commit body to `(msg dd233e16)`.

### Summary: C7 and Review Backing
- **C7 holds on 100% of reviewed rows:**
  - Row 03: `git diff 9dca293ca 8e1895d8d -- csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh csi-spl-orc/src/bash/tests/desk-cron-trunk.tst.sh` -> **0** lines diff.
  - Row 04: `git diff eb0e0c79a 40262df55 -- $(git show --name-only --format= 40262df55)` -> **0** lines diff.
- **Red control proof present on 100% of rows:** All 4 rows (01-04) verified red before fix, green after fix.
- **Review line defect:** Rows 01 and 02 carried no review line (dispatched prior to round panel review); rows 03 and 04 omitted the file path in `log:` and had `log:` stripped from the commit body.

## 3. CI verdict per row (R11)

The first workflow 10 run, completed and not cancelled, whose head contains the row sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 150`, filtered for `conclusion != cancelled`, then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 39078363682 (`8ac0f7d62`) | success | **pass** |
| 02 | 39080225672 (`ef312bbcc`) | success | **pass** |
| 03 | 39096696646 (`25f4bf14a`) | success | **pass** |
| 04 | 39098532556 (`40262df55`) | success | **pass** |

All 4 landed rows satisfy R11.2 cleanly: 100% green runs on the first completed CI check.

## 4. What went wrong and rule changes

- **Early dispatch of rows 01 and 02 before plan consensus / reviewer assignment:**
  The dispatcher queued and landed rows 01 (`8ac0f7d62`) and 02 (`ef312bbcc`) before bug round 1 plan v1.0 was approved and before the reviewer seat was spawned. Consequently, rows 01 and 02 did not go through the R7 cross-vendor review process and carried no `review:` line in their landing commits.
  *Rule change / lesson:* Follow R4 / rounds rulebook strictly: do not dispatch round rows before the round plan v1.0 is finalized, signed by the cross-vendor panel, and approved. Any bug row that is part of a round must ride the round's plan and receive an R7 cross-vendor review.
- **Review line format defect and omission of session log path:**
  For rows 03 and 04, editor `a-391@sat` (agy) acted as R7 reviewer. However, instead of providing an absolute filesystem path to its session journal / transcript (`~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl`), it emitted `log: a-391@sat:dispatch-bug-round-1`.
  Furthermore, the implementing lanes (`c-424` and `c-425`) stripped the `| log: ...` clause when pasting the review line into their commit messages, replacing it with `(msg <id>)`.
  As a result, `do_spl_review_line_check` fails both on the commit lines (`FATAL the line has no '| log: <id>@<box>:<path>'`) and on the spool messages (`FATAL log dispatch-bug-round-1 is not readable on sat as <user>`).
  *Rule change / lesson:* Reviewer briefs and seeds must emphasize that the `log:` parameter must be an absolute path to the session journal (e.g. transcript.jsonl), never a spool task id. In addition, the pre-push check or `do_spl_push_master` must validate that the review line in the commit message matches the R7 format `review: ... ran: ... | read: ... | log: ...` before allowing a round commit to land.
- **`spl-push-master.func.sh` only matches refactor round commit subjects:**
  `_spl_push_master_unreviewed` in `csi-spl-orc/src/bash/run/spl-push-master.func.sh` tests commit subjects with:
  `[[ "$(git log -1 --format=%s "$h")" =~ ^(test|refactor|ci|fix|feat|perf)\((r[0-9]+-[0-9]{2})- ]] || continue`
  This regex strictly matches only `r<N>-NN` refactor rounds. It skips bug rounds (`b<N>-NN`) and perf rounds (`p<N>-NN`), and commits formatted like `fix(orc, SPL-2490)`. Thus, `do_spl_push_master` completely bypassed review validation for rows 03 and 04, permitting the malformed review lines to land undetected.
  *Rule change / lesson:* Expand `_spl_push_master_unreviewed` regex to validate all round types (`(r[0-9]+|b[0-9]+|p[0-9]+)-[0-9]{2}`) and enforce review line syntax whenever an issue belongs to a round epic.
- **`do_git_prune_round_branches` incompatibility with non-numeric round slugs:**
  `do_git_prune_round_branches` strictly validates `[[ "$n" =~ ^[1-9][0-9]*$ ]]` and looks only for `review/r<N>-*`. For bug round 1 (`review/b01-*`), the script aborts with `FATAL ROUND must be round numbers`.
  *Rule change / lesson:* Update `do_git_prune_round_branches` to support round prefixes (e.g. `b01`, `perf6`) so all round branches can be pruned in the retro step.

## 5. Branches (R8 steps 1-2)

Branches listed on origin for bug round 1:
`git ls-remote --heads origin 'review/b01-*' 'wip/*b01*'`

```text
9dca293ca72c204e50fc01d23aa7b97689268022	refs/heads/review/b01-03
eb0e0c79ad8c0add035630a465d4b9937ea97219	refs/heads/review/b01-04
```

Per R8 and the brief, `do_git_prune_round_branches` only takes numeric rounds (`review/r<N>-*`) and does not match `review/b01-*`, so no remote branches were deleted by this lane.

## 6. What worked, what to change

- **Worked:** All 4 defect fixes landed on trunk in 1 push each; C7 verified clean (0 lines diff between reviewed and landed code); red control verified on all 4 rows; CI workflow 10 passed on 100% of rows; desk-reconcile dirty checkout recovery and tree writer guard successfully eliminated repeating cron checkout corruption.
- **Change 1 (Round Review Gate):** Update `_spl_push_master_unreviewed` in `spl-push-master.func.sh` so `do_spl_push_master` enforces review line checks on bug and perf rounds, not only `r<N>-NN` refactor rounds.
- **Change 2 (Remote Branch Pruning):** Extend `do_git_prune_round_branches` to support alphanumeric round slugs (`b01`, `perf6`).
- **Change 3 (Session Log Validation):** Clarify reviewer guidelines so reviewers always cite absolute file paths to `transcript.jsonl` / `journal.jsonl`, never spool task IDs.

## 7. Round 2 inputs (measured on `11ce3c834`)

All counts measured on **`11ce3c834`** (`origin/master`):

1. **`do_git_prune_round_branches` rejects non-numeric round slugs (such as `b01`):**
   `cd csi-spl-orc && sudo -u <DEV_USER> env ROUND=b01 ./run -a do_git_prune_round_branches 2>&1 | grep -o "ROUND must be round numbers.*"` -> **`ROUND must be round numbers, e.g. ROUND=8 or ROUND="7,8", got: 'b01'`** (n=1).
2. **`spl-push-master.func.sh` review check regex skips bug and perf rounds (`bNN-NN`):**
   `python3 -c 'import re; rx = re.compile(r"^(test|refactor|ci|fix|feat|perf)\((r[0-9]+-[0-9]{2})-"); print(bool(rx.match("fix(b01-03-orc-desk-cron-safe-dirty-recovery, SPL-2490): test")))'` -> **`False`** (n=1).
3. **`issue-close-landed.py --keys` fails with fatal error when `gdir` is a worktree `.git` file:**
   `git -C .git log -1 --format=%s 2>&1 | head -n 1` -> **`fatal: cannot change to '.git': Not a directory`** (n=1).
4. **`spl-review-line-check.func.sh` fails on spool task id log references (`log: <id>@<box>:<task>`):**
   `cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE='review: a-391@sat agy PASS 9dca293ca72c204e50fc01d23aa7b97689268022 ran: desk-cron-trunk.tst.sh on FETCH_HEAD and red control on origin/master | read: 0 failure(s) on 9dca293ca, 4 failure(s) on origin/master | log: a-391@sat:dispatch-bug-round-1' ./run -a do_spl_review_line_check 2>&1 | grep -o 'FATAL log.*'` -> **`FATAL log dispatch-bug-round-1 is not readable on sat as <user>`** (n=1).
5. **`run.sh` logging fails fatally with unhandled pipefail error when `dat/log/bash` cannot be created by non-root user:**
   `cd /opt/csi/csi-spl-wt/a-471/csi-spl-iac && ./run -a do_check_dist_hygiene 2>&1 | grep -o 'FATAL Command.*failed at line 430.*'` -> **`FATAL Command '[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]' failed at line 430 with status 1.`** (n=1).
6. **`do_tpl_gen` writes files into `csi-spl-cnf/` without `spl_refuse_desk_cron_tree` guard:**
   `git grep "spl_refuse_desk_cron_tree" csi-spl-iac/src/bash/run/tpl-gen.func.sh | wc -l` -> **`0`** (n=1).
7. **`TestWUIWakeFansOutAcrossProcesses` in `spool-hub-api/internal/hub` has unsynchronized race condition between process A and process B:**
   `sed -n '109,114p' csi-spl-api/src/go/spool-hub-api/internal/hub/wui_wake_test.go | grep -c "onA" || true` -> **`0`** (n=1).
8. **`tests-hermetic.tst.sh` allow-list debt: `desk-install-service-envs.tst.sh` sources run actions without `SPOOL_TEST=1` or `SPOOL_BOX_ENV`:**
   `grep -c "desk-install-service-envs.tst.sh" csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh` -> **`1`** (n=1).

## 8. Commands

```bash
git log origin/master -E --grep='(b01-[0-9]{2}|SPL-(2457|2458|2490|2491))' --format='%h %cI %s'
git merge-base --is-ancestor <sha> origin/master
git ls-remote --heads origin 'review/b01-*' 'wip/*b01*'
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 150 --json databaseId,headSha,conclusion,createdAt
cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE='<line>' ./run -a do_spl_review_line_check
```
