# Bug round 7 - mistral reviewer verdict

Reviewer: m-908@sat (mistral)
Plan: csi-spl-doc/doc/md/bug-round-7-plan.md v0.3, commit 65fd724ae

## Verdict

| # | defect | verdict | evidence |
|---|---|---|---|
| 01 | `fix(b06-01-orc-relay-short-task)` | **Agree with changes** | The defect is real, but the fix refuses 5 task ids in use (`01d0e8da`, `3165a101`, `9815f53a`, `9da17538`, `eda22eda`). The fix must refuse only task ids that are **not in use**. |
| 02 | `fix(b06-02-api-hub-pg-source-guard)` | **Agree** | The defect is real, and the fix is correct. |
| 03 | `fix(b06-03-orc-lane-restart-case6-diag)` | **Agree** | The defect is real, and the fix is correct. |
| 04 | `fix(b06-04-iac-pre-push-timeout-blame)` | **Agree** | The defect is real, and the fix is correct. |

### Section 4: Measured and not a bug
- **(b) Owner post reached the dispatcher as a channel post.** **Agree.** The read is correct, and the refusal is correct.
- **Round 6 row 01 broke `dispatch-setup-check.tst.sh` case 7.** **Agree.** The grep for the old value finds it. The rulebook text is the dispatcher's call.

### Section 5: Not reproduced
- **(e) `lane-restart.tst.sh` case 6 red once in CI.** **Agree.** The red is not reproduced, but the diagnostics gap is real (Row 03).
- **`no-x-scroll.test.mjs` red once.** **Agree.** Not reproduced locally.
- **Box GC: three passes in a row ended stale.** **Agree.** Not reproduced.

## Evidence

### Row 01
- **UUID mapping:** `python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL,"spool-task:9e1e51f3"))'` -> `451c5d94-9794-5aaf-886b-4cebc1a60abc` (verified).
- **Task ids in use:** `find /var/spool-hub -name "*.json" -path "*/outbox/*" -newermt "2026-10-16" -exec jq -r '.task_id // empty' {} \; | sort -u | grep -E '^[0-9a-fA-F]{6,31}$'` -> 5 ids (`01d0e8da`, `3165a101`, `9815f53a`, `9da17538`, `eda22eda`).
- **Red control:** Fails today, passes with the fix.

### Row 02
- **Sourced guard:** `timeout 60 env PG_BIN=/nonexistent SPOOL_TEST_PG_IMAGE=none:0 bash -c '. csi-spl-api/src/bash/tests/hub-pg.tst.sh; echo "AFTER rc=$?"'` -> no `AFTER` line (caller's shell killed). With the fix: `AFTER rc=2`.
- **SPOOL_TEST_PG_DSN:** Not exported today. With the fix: exported and usable.

### Row 03
- **Fail message:** `FAIL: 6.` block does not include `send.log:` today. With the fix: includes `send.log:`.

### Row 04
- **Blame line:** `FATAL pre-push: FAIL api (TIMED OUT ...) -- a NEW failure your commits introduce` today. With the fix: `it timed out on your tree and passed on trunk`.
- **Logs:** 77 `TIMED OUT … trunk=<sha>-green` lines since 2026-10-16.

## Log
- Session: <HARNESS_HOME>/.vibe/logs/session/unified/55e69a55-731b-4a8b-a2e9-00b3995550f3
