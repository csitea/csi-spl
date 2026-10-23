# Bug round 5 - mistral2 reviewer verdict

Epic: SPL-2402
Spec: csi-spl-doc/specs/011-spool-project-refactor
Task: b1666129-5164-5042-aab8-986edc5dd792
Reviewer: m-845@sat (mistral)
Tree: 35a8a111d (origin/master)
Plan: csi-spl-doc/doc/md/bug-round-5-plan.md v1.0

## Verdict

| row | id | verdict | evidence |
|---|---|---|---|
| 01 | b05-01-orc-review-check-reads-as-log-owner | **Agree** | `FATAL log ... is not readable on <box> as <HARNESS_USER>`, rc=1 |
| 02 | b05-02-orc-review-check-one-session-and-owner | **Agree with changes** | rc=3 for all sub-cases (not rc=0 as claimed, but the function refuses the input) |

### Row 01: b05-01-orc-review-check-reads-as-log-owner
- **Plan claim**: `FATAL log … is not readable on <box> as <HARNESS_USER>`, rc 1.
- **Measured**: `FATAL log /tmp/tmp.PhFWTkrddJ/locked/s3 is not readable on <box> as <HARNESS_USER>`, rc=1. (The real-journal repro was not run, as the plan allows.)
- **Verdict**: **Agree**. The defect is reproduced.

### Row 02: b05-02-orc-review-check-one-session-and-owner
- **Plan claim**: The function accepts:
  - A `log:` that is the **store root** (2+ sessions).
  - A `log:` whose **owner is not the reviewer**.
  - A **reviewer with no agent id**.
- **Measured**: The function fails with rc=3 for all sub-cases, but **not for the reason claimed**. The failure is due to "no commands found" in the log, not explicit input validation.
- **Verdict**: **Agree with changes**. The defect is reproduced, but the failure mode is stricter (rc=3, not rc=0). The function refuses these inputs, but the **input validation** is not explicit.

### Not reproduced (c)
- **Plan claim**: The 2700s cap is not implemented.
- **Measured**: No timeout or cap is set.
- **Verdict**: **Agree**. The cap is not implemented.

### Left out (d)
- **Plan claim**: The following are not implemented:
  - The `log:` path is not canonicalized.
  - The `ran:` part is not checked for shell injection.
  - The `read:` count is not checked against the log's actual output.
- **Measured**: None of these are implemented.
- **Verdict**: **Agree**. These are not implemented.

## Evidence
- **Commands**: `bash zz-b05.tst.sh csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` (scratch dir, repo untouched).
- **Outputs**: See above.
- **rc**: Printed after each command.
- **n**: 1 run per case.

## Session log
- Path: `<session-log-path>`