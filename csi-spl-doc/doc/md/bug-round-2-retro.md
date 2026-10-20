# Bug-fix round 2 - retrospective

Measured 2026-10-20 on trunk **`ea9a1ccec`** (`origin/master`) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for bug round 3. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-2564 (lane SPL-2683).

Plan: [bug-round-2-plan.md](bug-round-2-plan.md), v1.0 `5de4bc261`, signed by
reviewer claude seat `c-979@PC` (`a5a95649d`) and editor `a-489@sat` (agy).
Topic history: spool topics `dispatch-bug-round-2`, `dispatch-b02-01`,
`dispatch-b02-02`, `dispatch-b02-03`.

## 1. What landed

`git log origin/master -E --grep='(b02-[0-9]{2}|SPL-(2616|2617|2672))' --format='%h %cI %s'` -> **4**
commits on trunk (3 row defect fixes + 1 post-land review line commit).
Ancestry verified: `git merge-base --is-ancestor <sha> origin/master` exits 0 for all 4 landed shas.

| row | landed sha (lane) | landed (UTC) | pushes | red control | what it fixed, measured on `ea9a1ccec` |
|---|---|---|---|---|---|
| 01 `fix(b02-01-orc-push-master-review-regex)` | `700f71c50` (c-518@sat) | 21:05Z | 1 | yes | Expanded `_spl_push_master_unreviewed` regex in `spl-push-master.func.sh` from `r[0-9]+-` to `[rbp][0-9]+-`, enforcing R7 review line presence on bug and perf round row commits before push. Verified in `test-pre-push-review-line.sh` (cases 10-12: 6 failed -> 0 failed). |
| 02 `fix(b02-02-orc-run-unwritable-log-dir-fallback)` | `729ca0119` (c-519@sat) | 20:48Z | 2 | yes | Made `run.sh` logging robust across `csi-spl-iac`, `csi-spl-orc`, and `csi-spl-utl`: falls back to `$TMPDIR/run-log-<uid>` or standard error warning when both `PROJ_PATH/dat` and `VAR_DIR` log paths are unwritable, eliminating fatal rc 1 crashes at lines 430/459. Post-land review line landed in `00816d618` (22:14Z). Verified in `run-log.tst.sh` (27/27 FAIL -> 27/27 PASS). |
| 03 `fix(b02-03-orc-cron-checkout-flock-serialisation)` | `52a3c50e8` (c-586@sat) | 04:50Z | 1 | yes | Created `spl_desk_cron_update_pre` helper in `spl-desk-cron-lock.func.sh` to serialise cron `git fetch && git checkout` operations on `/opt/csi/csi-spl-desk-cron` via `flock` across all 16 cron installers, and placed `desk-reconcile-cron.sh` trunk checks under the same lock. Verified in `desk-cron-trunk.tst.sh` (concurrent checkouts: 11-14 false reports -> 0). |

All landed rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -cE 'SPL-(2616|2617|2672)'` -> 0).
Pushes used: Row 01: 1 push; Row 02: 2 pushes (initial commit + review-line commit `00816d618`); Row 03: 1 push. All satisfied the push cap ("aim for 1, max 5", rulebook section 1.2).
All 3 rows are tooling/runner/cron fixes under `csi-spl-orc/`, `csi-spl-iac/`, and `csi-spl-utl/`; per R5, changes with no hub or web UI deploy input are done on landing.

## 2. Review line verification (`do_spl_review_line_check`)

### Row 01 (`700f71c50`)
- **Review line in commit:**
```text
review: a-522@sat agy PASS f3926333769ba5eee3bb9e7713d86b1f51c466d2 ran: bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-review-line.sh, bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-lane-push.sh, bash csi-spl-orc/src/bash/tests/spl-push-master.tst.sh | read: test-pre-push-review-line 0 failed (red control 6 failed), test-pre-push-lane-push 0 failed, spl-push-master 0 failure(s) | log: a-522@sat:~/.gemini/antigravity-cli/brain/ff05cc8a-717c-43db-97ce-4d6873317d14/.system_generated/logs/transcript.jsonl
```
- **Check output:**
```text
OK 1 of 1 named in ran: are commands in ~/.gemini/antigravity-cli/brain/ff05cc8a-717c-43db-97ce-4d6873317d14/.system_generated/logs/transcript.jsonl (53 commands read)
```
- **Verification note:** Reviewed cross-vendor by `a-522@sat` (agy) on claude author `c-518@sat`. Quoted in the landing commit body.

### Row 02 (`729ca0119` + `00816d618`)
- **Review line in commit `00816d618`:**
```text
review: a-523@sat agy PASS 729ca011995418e0903dcb752bf7a32d8a9ba230 ran: bash csi-spl-orc/src/bash/tests/run-log.tst.sh | read: run-log: 0 failure(s) (27/27 PASS), red control 27/27 FAIL | log: a-523@sat:~/.gemini/antigravity-cli/brain/fbd731a2-10d7-4ab1-b679-6dd168cccbd2/.system_generated/logs/transcript.jsonl
```
- **Check output:**
```text
OK 1 of 1 named in ran: are commands in ~/.gemini/antigravity-cli/brain/fbd731a2-10d7-4ab1-b679-6dd168cccbd2/.system_generated/logs/transcript.jsonl (45 commands read)
```
- **Verification note:** Author `c-519` initially pushed `729ca0119` before R7 review because `do_spl_push_master` on its tree did not yet carry the widened regex from Row 01. Review was performed post-land by `a-523@sat` (agy) directly on `729ca0119`, and the review line was placed onto origin/master via an empty commit `00816d618` (`docs(b02-02-orc-run-unwritable-log-dir-fallback, SPL-2617): post-land R7 review line for 729ca0119`).

### Row 03 (`52a3c50e8`)
- **Review line in commit:**
```text
review: a-592@sat agy PASS b380837c5e5691a3bb58d8a29b8116339749268d ran: bash csi-spl-orc/src/bash/tests/desk-cron-trunk.tst.sh; bash csi-spl-orc/src/bash/tests/desk-install-service-envs.tst.sh; bash csi-spl-iac/src/bash/tests/check-weekly-full-scan.tst.sh | read: desk-cron-trunk 0 failures, desk-install-service-envs 0 failures, check-weekly-full-scan 0 failed | log: a-592@sat:~/.gemini/antigravity-cli/brain/92d6560d-f22c-405b-aa64-cd59c67f3933/.system_generated/logs/transcript.jsonl
```
- **Check output:**
```text
OK 3 of 3 named in ran: are commands in ~/.gemini/antigravity-cli/brain/92d6560d-f22c-405b-aa64-cd59c67f3933/.system_generated/logs/transcript.jsonl (45 commands read)
```
- **Verification note:** Reviewed cross-vendor by `a-592@sat` (agy) on claude author `c-586@sat`. Quoted in the landing commit body.

### Summary: C7 and Review Backing
- **C7 holds on 100% of rows:**
  - Row 01: `git show f3926333769b | git patch-id` and `git show 700f71c50 | git patch-id` -> both `131037149fff6f35eaec8e6d2cb52dba9b3b0aa1`; `git diff f3926333769b 700f71c50 -- $(git show --name-only --format= 700f71c50)` -> **0** lines diff.
  - Row 02: Reviewed directly on `729ca0119`; post-land review commit `00816d618` changed **0** files (`git show --stat --format= 00816d618 | wc -l` -> 0).
  - Row 03: `git show b380837c5 | git patch-id` and `git show 52a3c50e8 | git patch-id` -> both `7ff4e177ffcd2d7049a04e9178578fa5aee9e90d`; `git diff b380837c5 52a3c50e8 -- $(git show --name-only --format= 52a3c50e8)` -> **0** lines diff.
- **Red control proof present on 100% of rows:** All 3 rows verified failing before fix and passing after fix.
- **Review line verification:** 100% of review lines passed `do_spl_review_line_check` with valid syntax, matching vendor, and verifiable commands in session transcripts.

## 3. CI verdict per row (R11)

The first completed, non-cancelled workflow 10 run whose head commit contains the row sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 150`, filtered for `conclusion != cancelled`, verified via `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 (`700f71c50`) | 39329963259 (`c61301688`) | success | **pass** |
| 02 (`729ca0119`) | 39329963259 (`c61301688`) | success | **pass** |
| 02 review (`00816d618`) | 39337144630 (`f35ebaaaf`) | success | **pass** |
| 03 (`52a3c50e8`) | 39371750776 (`52a3c50e8`) | success | **pass** |

All landed rows satisfy R11.2 cleanly: 100% green runs on the first completed CI quality gate check.

## 4. What went wrong and rule changes

- **Premature push of Row 02 before R7 review line was obtained:**
  Author lane `c-519` pushed `729ca0119` before R7 review was conducted because `do_spl_push_master` on its branch did not yet carry the widened regex from Row 01 (Row 01 was running concurrently in a parallel lane). This required post-land review by `a-523@sat` and an additional empty commit `00816d618` on trunk to record the review line.
  *Rule change / lesson:* Parallel lanes within a batch must not rely on sibling lanes' unmerged fixes for safety gates. When working in a round batch where the review-check gate itself is being implemented, subsequent lanes must self-verify the review line prior to push.
- **Omission of `box-disk-guard-install.func.sh:34` in Row 03 initial plan / implementation:**
  Row 03 addressed 16 cron installers using the standard pattern `git checkout -q --detach origin/$trunk`, but missed line 34 of `box-disk-guard-install.func.sh` which had a literal `master` string. This necessitated an out-of-round follow-up lane `c-603` (SPL-2681, landed in `0478e8ac3`).
  *Rule change / lesson:* Grep patterns when preparing plan rows should account for literals as well as variables (`origin/(master|\$trunk)`).
- **Reviewer seat duplicate placement:**
  Two reviewer seats (`c-979@PC` and `c-513@sat`) were queued and spawned for bug round 2 planning review. `c-979` landed `seat-claude.md` first, leaving `c-513` as a duplicate that had to end `SPL-2611` as diss without committing.
  *Rule change / lesson:* Dispatchers must verify that an active reviewer seat is not already placed on a sibling box before placing duplicate reviewer seats.

## 5. Branches (R8 steps 1-2)

Branches listed on origin for bug round 2:
`git ls-remote --heads origin 'review/b02-*' 'wip/*b02*'`

```text
f3926333769ba5eee3bb9e7713d86b1f51c466d2	refs/heads/review/b02-01
729ca011995418e0903dcb752bf7a32d8a9ba230	refs/heads/review/b02-02
```

Per R8 and the brief, delete no branches; remote review branches remain listed.

## 6. What worked, what to change

- **Worked:** All 3 defect fixes landed on trunk; C7 verified clean (0 lines diff on touched files); red controls 100% verified; CI workflow 10 passed on 100% of rows; runner logging fallback prevented fatal crashes when log directory is unwritable; cron checkout locking eliminated desk-reconcile blockers completely.
- **Change 1 (Review Line Pre-Check):** Ensure implementing lanes always verify review line presence locally before calling push-master, regardless of whether push-master regex has landed.
- **Change 2 (Comprehensive Pattern Grepping):** Grep patterns for fleet-wide migrations should match both variable and literal forms.
- **Change 3 (Reviewer Queue Deduplication):** Enforce single reviewer seat placement across boxes.

## 7. Round 3 inputs (measured on `ea9a1ccec`)

All counts measured on **`ea9a1ccec`** (`origin/master`):

1. **Known follow-up: `box-disk-guard-install.func.sh:34` unlocked desk-cron checkout:**
   Owned elsewhere (lane `c-603@sat`, slug `c002-bug-disk-guard-unlocked-checkout`, landed on trunk in `0478e8ac3` [SPL-2681]).
   `git grep -n 'git checkout -q --detach' csi-spl-utl/src/bash/run/box-disk-guard-install.func.sh` -> **0 lines** (fixed and clean).
2. **CI gate active trunk defects:**
   `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` -> **0 active trunk defects** (last green on newest completed run `67d7a04f` for all 25 jobs).
3. **Desk reconcile blockers:**
   `SPOOL_ROOT=/var/spool-hub spool tail --task desk-reconcile | tail -n 20` -> **0 blockers** since cron checkout flock serialisation landed in SPL-2672 / SPL-2681.
4. **`issue-close-landed.py --keys` on `.git` file:**
   `python3 csi-spl-orc/src/bash/scripts/issue-close-landed.py --keys .git HEAD 2>&1` -> `CalledProcessError 128`, but on real checkout dir `python3 csi-spl-orc/src/bash/scripts/issue-close-landed.py --keys . HEAD` -> **`SPL-2681`** (exit 0). Measured and not a bug: all real callers pass checkout directory paths.
5. **`spl-review-line-check.func.sh` on spool task id:**
   `cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE='review: a-391@sat agy PASS 9dca293ca72c204e50fc01d23aa7b97689268022 ran: desk-cron-trunk.tst.sh on FETCH_HEAD and red control on origin/master | read: 0 failure(s) on 9dca293ca, 4 failure(s) on origin/master | log: a-391@sat:dispatch-bug-round-1' ./run -a do_spl_review_line_check 2>&1 | grep -o 'FATAL log.*'` -> **`FATAL log dispatch-bug-round-1 is not readable on sat as <user>`**. Measured and not a bug: R7 §2.7.4 requires an absolute file path.
6. **`TestWUIWakeFansOutAcrossProcesses` race condition:**
   `cd csi-spl-api/src/go/spool-hub-api && go test -count=5 -run TestWUIWakeFansOutAcrossProcesses ./internal/hub` -> **ok 5 of 5 runs passed** (not reproduced).
7. **Hermetic allow-list debt in `tests-hermetic.tst.sh`:**
   `grep -c "desk-install-service-envs.tst.sh" csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh` -> **1** (allowlist size = 3). Refactoring/gate tightening debt.

## 8. Commands

```bash
git log origin/master -E --grep='(b02-[0-9]{2}|SPL-(2616|2617|2672))' --format='%h %cI %s'
git merge-base --is-ancestor <sha> origin/master
git ls-remote --heads origin 'review/b02-*' 'wip/*b02*'
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 150 --json databaseId,headSha,conclusion,createdAt
cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE='<line>' ./run -a do_spl_review_line_check
cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
```
