# Bug-fix round 5 - mistral reviewer verdict

Epic: SPL-2402
Spec: csi-spl-doc/specs/011-spool-project-refactor
Round: 5
Reviewer: m-110@<box> (mistral)
Plan: [bug-round-5-plan.md](../bug-round-5-plan.md) v0.1 (editor commit d55ca6551)

---

## Verdict

**Agree with the plan's rows 01 and 02.** All defects are reproduced, and the evidence matches the plan's description. No additional defects found.

---

## Evidence

### Row 01: `b05-01-orc-review-check-reads-as-log-owner`
**Defect**: The review-line check cannot read a mistral reviewer's journal when run as the fleet's shell user (`<DEV_USER>`). The journal is owned by `<HARNESS_USER>`, and every parent directory is `drwx------`. The check fails with `FATAL log ... is not readable` and does not attempt to read as the log's owner.

**Evidence**:
1. **Directory permissions** (real vibe journal):
   ```bash
   ls -ld ~<HARNESS_USER>/.vibe ~<HARNESS_USER>/.vibe/logs ~<HARNESS_USER>/.vibe/logs/session ~<HARNESS_USER>/.vibe/logs/session/unified
   ```
   Output:
   ```
   drwx------   7 <HARNESS_USER> <HARNESS_USER>  4096 2026-10-23 05:50 ~<HARNESS_USER>/.vibe
   drwx------   4 <HARNESS_USER> <HARNESS_USER>  4096 2026-10-16 10:12 ~<HARNESS_USER>/.vibe/logs
   drwx------   6 <HARNESS_USER> <HARNESS_USER>  4096 2026-10-11 10:19 ~<HARNESS_USER>/.vibe/logs/session
   drwx------ 287 <HARNESS_USER> <HARNESS_USER> 20480 2026-10-23 05:50 ~<HARNESS_USER>/.vibe/logs/session/unified
   ```

2. **Red control output** (scratch test, `chmod 000` parent):
   ```bash
   REVIEW_LINE='review: m-901@<box> mistral PASS 35a8a111d… ran: bash gc-agent.tst.sh | read: ok | log: m-901@<box>:/tmp/tmp.87PvoD5K0w/locked/s3' REVIEW_LINE_BOX=<box> do_spl_review_line_check
   ```
   Output:
   ```
   FATAL log /tmp/tmp.87PvoD5K0w/locked/s3 is not readable on box-a as <HARNESS_USER>
   ```
   Return code: `rc=1`

3. **Real-world test** (as `<DEV_USER>`):
   ```bash
   REVIEW_LINE='review: m-999@<box> mistral PASS 35a8a111d… ran: bash gc-agent.tst.sh | read: ok | log: m-999@<box>:~<HARNESS_USER>/.vibe/logs/session/unified/<session>' REVIEW_LINE_BOX=<box> do_spl_review_line_check
   ```
   Output:
   ```
   FATAL log ~<HARNESS_USER>/.vibe/logs/session/unified/<session> is not readable on <box> as <DEV_USER>
   ```
   Return code: `rc=1`

**Sites**: `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:50-52` (the readable test and the read).

---

### Row 02: `b05-02-orc-review-check-one-session-and-owner`
**Defect**: The check accepts invalid `log:` paths and reviewers:
1. **Store root as `log:`**: The check accepts a directory containing multiple sessions (e.g., `unified/`).
2. **Reviewer mismatch**: The check does not validate the reviewer on the local box (e.g., `mistral@<box>` or `m-902@<box>` with `log: m-901@<box>:...`).

**Evidence**:
1. **Store root as `log:`** (scratch test, 2 sessions):
   ```bash
   REVIEW_LINE='review: m-901@<box> mistral PASS 35a8a111d… ran: bash gc-agent.tst.sh | read: ok | log: m-901@<box>:/tmp/tmp.87PvoD5K0w/unified' REVIEW_LINE_BOX=<box> do_spl_review_line_check
   ```
   Output:
   ```
   OK 1 of 1 named in ran: are commands in /tmp/tmp.87PvoD5K0w/unified (2 commands read)
   ```
   Return code: `rc=0` (want `rc=1`)

2. **Reviewer mismatch** (scratch test):
   - **Subcase 1**: Reviewer with no agent id (`mistral@<box>`):
     ```bash
     REVIEW_LINE='review: mistral@<box> mistral PASS 35a8a111d… ran: bash gc-agent.tst.sh | read: ok | log: m-901@<box>:/tmp/tmp.87PvoD5K0w/unified/s2' REVIEW_LINE_BOX=<box> do_spl_review_line_check
     ```
     Output:
     ```
     OK 1 of 1 named in ran: are commands in /tmp/tmp.87PvoD5K0w/unified/s2 (1 commands read)
     ```
     Return code: `rc=0` (want `rc=1`)
   
   - **Subcase 2**: Reviewer ≠ `log:` owner (`m-902@<box>` vs `m-901@<box>`):
     ```bash
     REVIEW_LINE='review: m-902@<box> mistral PASS 35a8a111d… ran: bash gc-agent.tst.sh | read: ok | log: m-901@<box>:/tmp/tmp.87PvoD5K0w/unified/s2' REVIEW_LINE_BOX=<box> do_spl_review_line_check
     ```
     Output:
     ```
     OK 1 of 1 named in ran: are commands in /tmp/tmp.87PvoD5K0w/unified/s2 (1 commands read)
     ```
     Return code: `rc=0` (want `rc=1`)

**Sites**:
- `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:40-44` (the `log:` match and the local branch).
- `:50-52` (the readable test).
- `:73-88` (`_spl_review_line_syntax`, for reuse).
- `:157-158` (the Python walk).

---

## Re-checked entries

### 5-Source Table
1. **Source 3: Skipped or disabled tests, local flakes**
   - **Command**: `git grep -n -E "(t\\.Skip|test\\.skip|\\.skip\(|ci-skip\\.txt)" 35a8a111d -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl | wc -l`
   - **Output**: `186` (3 more than round 4's 183).
   - **New entries**: 3 skips gated on Postgres (`SPOOL_TEST_PG_DSN`).
   - **Judgment**: Agree with the plan. No defects.

2. **Source 5: Open defect issues**
   - **Command**: `cd /opt/csi/csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`
   - **Output**: 317 issues (total), 4 labelled `bug`; 9 new issues with defect words in titles (all lane briefs).
   - **Judgment**: Agree with the plan. No new defects.

### Not reproduced
- **The 2700 s cap (candidate (c))**:
  - **Command**: `grep -A 10 -B 5 "_pp_api_full_default" /opt/csi/csi-spl-orc/src/bash/run/check-pre-push.func.sh`
  - **Output**: The arithmetic holds (`2700 / 1950 = 1.385`). No green suite has exceeded 2700 s since the change.
  - **Judgment**: Agree with the plan. Not reproduced.

---

## Proof of the run

- **Session log**: `~<HARNESS_USER>/.vibe/logs/session/unified/<session-id>/journal/` (real path: `ls ~<HARNESS_USER>/.vibe/logs/session/unified/`).
- **Commands**: All red controls and re-checks were run as described. Return codes and outputs were recorded.
- **Sha**: All measurements on `35a8a111d` (`origin/master` at the start).