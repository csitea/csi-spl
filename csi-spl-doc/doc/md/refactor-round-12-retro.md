# Refactoring round 12 - retrospective

Measured 2026-10-15 on trunk **`dc17f840e`** (`origin/master`, 19:54Z) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for round 13. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-1920 (lane SPL-2045).

Plan: [refactor-round-12-plan.md](refactor-round-12-plan.md), v1.0
`26805ed51`, signed by editor a-563@PC (agy), claude seat c-212@sat (`4fa2f5435`),
and mistral seat m-213@sat (`476fec913`); consensus recorded in `40ad4d325`.
Review history: spool topic `dispatch-3209f8b8` (`spool tail --task dispatch-3209f8b8`).

## 1. What landed

`git log origin/master -E --grep='r12-[0-9]{2}' --format='%h %cI %s'` -> **10**
commits on trunk; all 10 rows landed on master.
`... --format=%s | grep -oE 'r12-[0-9]{2}' | sort -u | wc -l` -> 10.

| row | landed sha (lane) | landed (UTC) | pushes | red control | what it reduced, measured on `dc17f840e` |
|---|---|---|---|---|---|
| 01 `ci(r12-01-review-line-check-agy-support)` | `69ba3fc76` (c-197@sat) | 14:11Z | 1 | yes | `_SPL_REVIEW_LINE_PY` in `spl-review-line-check.func.sh` parses agy `transcript.jsonl` and `transcript_full.jsonl` tool calls. Commands read on real agy session on PC: 0 -> 201 (`OK 1 of 1`). Unblocks agy reviewer seats fleet-wide. |
| 02 `ci(r12-02-review-line-check-remote-box)` | `b340c14c5` (c-219@sat) | 15:41Z | 1 | yes | `do_spl_review_line_check` supports `REVIEW_LINE_SYNTAX=1`: validates review line format, reviewer id, and registration on non-local box logs, printing the exact peer query instead of blind rc 2 failure. |
| 03 `refactor(r12-03-wui-small-store-channel)` | `5e6217e70` (c-214@sat) | 14:48Z | 1 | yes | `useChannelStore` setup body in `src/stores/channel.ts` split from 576 lines into 10 named module step functions under 80 lines (setup is 66 lines); LONG entry deleted: **3 -> 2** in `cleancode.test.mjs`. |
| 04 `refactor(r12-04-wui-small-create-live-client)` | `9e6dbc8b8` (c-223@sat) | 16:12Z | 1 | yes | `createLiveClient` in `src/utils/live-ws.mjs` split from 499 lines into module step functions with state on `liveContext` (max 73 lines); LONG entry deleted: **2 -> 1** in `cleancode.test.mjs`. |
| 05 `refactor(r12-05-wui-small-create-spool-client)` | `0b52be72a` (c-231@sat) | 21:26Z | 1 | yes | Splits `createSpoolClient` (545 lines) into 12 module step functions under 80 lines, removing the final WUI LONG entry (**1 -> 0**, empty LONG map in `cleancode.test.mjs`). Live on dev+prd (`v9.8.1-c2`). Reviewer: `a-218@sat` (agy). |
| 06 `refactor(r12-06-bash-cleancode-ceilings-lowered)` | `b06903142` (c-216@sat) | 14:04Z | 1 | yes | Lowered LONG ceilings in `bash-cleancode.tst.sh` for `do_gcp_import_to_cloudsql` (175 -> 174) and `do_gcp_project_delete` (120 -> 119), eliminating 2 NOTEs. |
| 07 `refactor(r12-07-bash-small-run-execute-step)` | `baa9eb601` (c-222@sat) | 15:23Z | 1 | yes | `execute_step` in iac and orc `run.sh` split from 99 lines (ceiling) to 54 lines + two named steps (`execute_step_hook` 8, `execute_step_parse_args` 42); kept byte-identical; both LONG entries removed from `bash-cleancode.tst.sh` (**12 -> 10**). |
| 08 `test(r12-08-go-coverage-blob-avatar-key)` | `7f1f9a258` (c-215@sat) | 14:36Z | 1 | yes | `internal/blob/blob_test.go` added table tests for `blob.AvatarKey` (3 statements, 0.0% -> 100.0%); `internal/blob` coverage floor raised **66.2 -> 66.9**. |
| 09 `test(r12-09-go-coverage-action-json-helper)` | `e6aed88b7` (c-221@sat) | 15:29Z | 1 | yes | `internal/action/action_test.go` created, covering `action.JSON` (2 statements, 0.0% -> 100.0%); `internal/action` coverage floor raised **70.3 -> 71.1**. |
| 10 `test(r12-10-no-box-path-source-expand-dirs)` | `8695ee79c` (c-217@sat) | 14:40Z | 1 | yes | `no-box-path-source.tst.sh` directory list extended from 4 to 6 dirs (+ `csi-spl-api/src`, `csi-spl-wui/src`), scanning 27 previously ungated scripts (0 violations in tree). |

All landed rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -c r12-` -> 0).
Every landed row landed in **1 push to master**, satisfying the push cap ("aim for 1, max 5", rulebook section 1).
WUI rows 03, 04, and 05 were served on dev and prd (03 in v9.6.8-c2, 04 in v9.6.9-c2, 05 in v9.8.1-c2); tooling and test rows with no deploy input are done on landing (R5).

## 2. Review line verification (`do_spl_review_line_check`)

Every landed row's landing commit carried an R7 review line conforming to the plan section 1 format (`review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`).
Because all 9 reviewers ran on box `sat`, running `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` from a non-sat box tests the multi-box contract established by row 02.

Default run outputs `REFUSED the log is on box 'sat', this is '<box>': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here` (rc 2), printing the exact peer command on `sat`.
With `REVIEW_LINE_SYNTAX=1`, each line is locally validated: format OK, reviewer identity and vendor match registry, and `ran:` names a valid test:

### Row 01 (`69ba3fc76`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: m-213@sat mistral PASS 94345d17b1d33e32adb0f6cc0cd3cb5fad169ee7 ran: git fetch origin review/r12-01 && git checkout --detach 94345d17b1d33e32adb0f6cc0cd3cb5fad169ee7 && bash csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh | read: 0 failure(s); RED CONTROL: git show 94345d17b1d33e32adb0f6cc0cd3cb5fad169ee7~1:csi-spl-orc/src/bash/run/spl-review-line-check.func.sh > /tmp/spl-review-line-check.func.sh.old && cp /tmp/spl-review-line-check.func.sh.old csi-spl-orc/src/bash/run/spl-review-line-check.func.sh && bash csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh | read: 2 failure(s) | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/07605995-8f03-6a89-781a-75c60cfa1d2d/journal/0000000000000001.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: m-213@sat mistral PASS 94345d17b1d33e32adb0f6cc0cd3cb5fad169ee7 ran: ... | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/07605995-8f03-6a89-781a-75c60cfa1d2d/journal/0000000000000001.jsonl`
- Verification note: Reviewed cross-vendor by mistral `m-213@sat` on claude author `c-197@sat`.

### Row 02 (`b340c14c5`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-218@sat agy PASS 35cd562b89243ed1360c45c923aaea824014acae ran: bash csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh | read: spl-review-line-check: 0 failure(s); red control: old func rc=2 (bare REFUSED), new func rc=0 (SYNTAX OK + peer query), malformed rc=1 (SYNTAX FAIL) | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c1ae842b-cca5-49ae-9c36-52eaba0991aa/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-218@sat agy PASS 35cd562b89243ed1360c45c923aaea824014acae ran: ... | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c1ae842b-cca5-49ae-9c36-52eaba0991aa/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-218@sat` on claude author `c-219@sat`. First production review verified via agy transcript support added by row 01.

### Row 03 (`5e6217e70`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: m-213@sat mistral PASS 5b18eed8d307fa3893b9663a898690173f97577b ran: git fetch origin review/r12-03 && git checkout --detach 5b18eed8d307fa3893b9663a898690173f97577b && cd csi-spl-wui && node tests/unit/cleancode.test.mjs && node src/node/test/run-unit-tests.mjs && pnpm run typecheck | read: cleancode: 10107 functions, 2 listed long, none deeper than 4 or wider than 6; unit runner: 377 of 377, All tests passed; typecheck: No errors | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/06ffbd05-33b1-4a5e-62d7-39a2a7a63836/journal/0000000000001494.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: m-213@sat mistral PASS 5b18eed8d307fa3893b9663a898690173f97577b ran: ... | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/06ffbd05-33b1-4a5e-62d7-39a2a7a63836/journal/0000000000001494.jsonl`
- Verification note: Reviewed cross-vendor by mistral `m-213@sat` on claude author `c-214@sat`.

### Row 04 (`9e6dbc8b8`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-218@sat agy PASS a8a9280f6777cbd8c4722266ab4c59f48b9e05c7 ran: cd /opt/csi/csi-spl-wt/a-218/csi-spl-wui && node tests/unit/cleancode.test.mjs && node tests/unit/live-ws.test.mjs | read: cleancode: 10127 functions, 1 listed long; live-ws: 34 passed, 0 failed; red control: old live-ws.mjs -> FAIL createLiveClient is 499 lines (> 80), cleancode: 1 FAILED (rc 1), restored -> rc 0 | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/16bb22b7-eb66-4755-ad92-6aca2c83f880/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-218@sat agy PASS a8a9280f6777cbd8c4722266ab4c59f48b9e05c7 ran: ... | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/16bb22b7-eb66-4755-ad92-6aca2c83f880/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-218@sat` on claude author `c-223@sat`.

### Row 05 (`0b52be72a`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-218@sat agy PASS 58725bb638f81c78e70cd0130158cebc0de1d3dc ran: cd /opt/csi/csi-spl-wt/a-218/csi-spl-wui && node tests/unit/cleancode.test.mjs && node --test tests/unit/spool-client.test.mjs tests/unit/channel-paging.test.mjs tests/unit/initial-js-trims.test.mjs && node src/node/test/run-unit-tests.mjs | read: cleancode: 10230 functions, 0 listed long; unit tests: pass 35, fail 0; all 379 file(s) passed; red control: old spool-client.mjs -> FAIL createSpoolClient is 545 lines (> 80), cleancode: 1 FAILED (rc 1), restored -> rc 0 | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/ab47a6df-891a-403a-ac06-f8cca5f4efb4/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-218@sat agy PASS 58725bb638f81c78e70cd0130158cebc0de1d3dc ran: ... | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/ab47a6df-891a-403a-ac06-f8cca5f4efb4/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-218@sat` on claude author `c-231@sat`.

### Row 06 (`b06903142`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: m-213@sat mistral PASS 4303fdf421606d8161072f8eb6c82b6e7edc3377 ran: git fetch origin review/r12-06 && git checkout --detach 4303fdf421606d8161072f8eb6c82b6e7edc3377 && bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh | read: rc 0, no NOTE LONG; RED CONTROL: sed -i '\''s/do_gcp_import_to_cloudsql 174/do_gcp_import_to_cloudsql 173/'\'' csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh && sed -i '\''s/do_gcp_project_delete 119/do_gcp_project_delete 118/'\'' csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh && bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh | read: rc 2, two FAIL lines | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/07605995-8f03-6a89-781a-75c60cfa1d2d/journal/0000000000001725.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: m-213@sat mistral PASS 4303fdf421606d8161072f8eb6c82b6e7edc3377 ran: ... | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/07605995-8f03-6a89-781a-75c60cfa1d2d/journal/0000000000001725.jsonl`
- Verification note: Reviewed cross-vendor by mistral `m-213@sat` on claude author `c-216@sat`.

### Row 07 (`baa9eb601`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: m-213@sat mistral PASS d83d04d864f5d9b628ea4491a2c31d3c01e629e5 ran: git fetch origin review/r12-07 && git checkout --detach d83d04d864f5d9b628ea4491a2c31d3c01e629e5 && git show d83d04d864f5d9b628ea4491a2c31d3c01e629e5 --stat && diff <(sed -n '\''/^# execute_step_hook/,/^  return $exit_status/p'\'' csi-spl-iac/src/bash/run/run.sh) <(sed -n '\''/^# execute_step_hook/,/^  return $exit_status/p'\'' csi-spl-orc/src/bash/run/run.sh) && bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh && bash csi-spl-iac/src/bash/tests/run-log-nofork.tst.sh | read: diff empty; PASS: all bash-cleancode.tst.sh assertions; PASS: all run-log-nofork.tst.sh assertions; old execute_step 98 | 98 | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/06ffbd05-33b1-4a5e-62d7-39a2a7a63836/scratchpad/review-r12-07.log' ./run -a do_spl_review_line_check
```
- Line: `review: m-213@sat mistral PASS d83d04d864f5d9b628ea4491a2c31d3c01e629e5 ran: ... | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/06ffbd05-33b1-4a5e-62d7-39a2a7a63836/scratchpad/review-r12-07.log`
- Verification note: Reviewed cross-vendor by mistral `m-213@sat` on claude author `c-222@sat`.

### Row 08 (`7f1f9a258`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: m-213@sat mistral PASS 94d4ff7218203c644502a20cbd35dd1b54b5083e ran: git fetch origin review/r12-08 && git checkout --detach 94d4ff7218203c644502a20cbd35dd1b54b5083e && cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=/tmp/r12-08.out ./internal/blob/ && go tool cover -func=/tmp/r12-08.out | grep AvatarKey | read: 66.9%, AvatarKey 100.0%; RED CONTROL: sed -i '\''41s/if !sha256Re.MatchString(fileID) {/if false {/'\'' internal/blob/blob.go && go test -count=1 -run TestAvatarKey ./internal/blob/ -v | read: FAIL (8 subtests) | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/07605995-8f03-6a89-781a-75c60cfa1d2d/journal/0000000000002089.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: m-213@sat mistral PASS 94d4ff7218203c644502a20cbd35dd1b54b5083e ran: ... | log: m-213@sat:/mnt/data/home/<user>/.vibe/logs/session/unified/07605995-8f03-6a89-781a-75c60cfa1d2d/journal/0000000000002089.jsonl`
- Verification note: Reviewed cross-vendor by mistral `m-213@sat` on claude author `c-215@sat`.

### Row 09 (`e6aed88b7`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-218@sat agy PASS 8813a47d7ef28ed1cdcb48a876d3b0ed6ed71532 ran: cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/action/ | read: coverage: 71.1% of statements, JSON 100.0%; red control: mutation to json.MarshalIndent -> FAIL: TestJSON, restored -> PASS | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c1ae842b-cca5-49ae-9c36-52eaba0991aa/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-218@sat agy PASS 8813a47d7ef28ed1cdcb48a876d3b0ed6ed71532 ran: ... | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c1ae842b-cca5-49ae-9c36-52eaba0991aa/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-218@sat` on claude author `c-221@sat`.

### Row 10 (`8695ee79c`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-218@sat agy PASS 8e2672aaad22fac619bd863534e8f649490ebeb8 ran: bash csi-spl-iac/src/bash/tests/no-box-path-source.tst.sh && IAC_TEST_ONLY=no-box-path-source.tst.sh bash csi-spl-iac/src/bash/tests/run-all-tests.sh && bash $R/csi-spl-iac/src/bash/tests/old.tst.sh && bash $R/csi-spl-iac/src/bash/tests/new.tst.sh | read: clean tree: PASS: no-box-path-source, 1/1 passed; red control: old test rc=0 (4 dirs), new test rc=1 on /opt/ plant (plant.sh:1), both rc=0 with relative source | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c1ae842b-cca5-49ae-9c36-52eaba0991aa/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-218@sat agy PASS 8e2672aaad22fac619bd863534e8f649490ebeb8 ran: ... | log: a-218@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/c1ae842b-cca5-49ae-9c36-52eaba0991aa/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-218@sat` on claude author `c-217@sat`.

### Summary: C7 and Review Backing
- **C7 holds on 100% of landed rows:** `git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l` -> **0** for all 10 rows (01-10).
- **Review lines backed by output:** All 10 landed rows carry valid review evidence; syntax check passes (`SYNTAX OK`) on all lines; all 10 journals reside on box `sat`.
- **Zero same-vendor reviews:** Cross-vendor reviewing restored across the fleet:
  - Mistral `m-213@sat` reviewed rows 01, 03, 06, 07, 08 (5 rows).
  - Agy `a-218@sat` reviewed rows 02, 04, 05, 09, 10 (5 rows), enabled by row 01 agy transcript parser.

## 3. CI verdict per row (R11)

The first workflow 10 run, completed and not cancelled, whose head contains the row sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 150`, filtered for `conclusion != cancelled`, then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 38749369628 (`69ba3fc76`) | failure: wui browser e2e 5/5 only | **pass**: orc hermetic tests passed; 38753973680 success |
| 02 | 38762742078 (`b340c14c5`) | success | **pass** |
| 03 | 38756807081 (`78bba364c`) | success | **pass** |
| 04 | 38768413628 (`d57662969`) | success | **pass** |
| 05 | 38810972094 (`0b52be72a`) | success | **pass** |
| 06 | 38748827138 (`053d6c8fa`) | failure: wui browser e2e 5/5 only | **pass**: iac tests passed; 38753973680 success |
| 07 | 38760227296 (`baa9eb601`) | success | **pass** |
| 08 | 38753973680 (`8695ee79c`) | success | **pass** |
| 09 | 38762742078 (`b340c14c5`) | success | **pass** |
| 10 | 38753973680 (`8695ee79c`) | success | **pass** |

All 10 landed rows satisfy R11.2: 8 rows in green completed runs, and 2 rows (01 and 06) in runs where the only red job was an unrelated WUI browser test (`wui: browser e2e 5/5`) while the jobs executing their tests passed cleanly, confirmed green on the next completed run `38753973680`.

## 4. What went wrong and rule changes

- **Mistral panel seat m-213 obsolete measurement and re-landing on rotation:**
  The mistral seat `m-213@sat` measured its baseline on an older sha `e42286100` and labeled it `origin/master` in commit `5afa8435a` (17:23Z). It was sent back and corrected it in `80e146bb7` and `f48525f17` (GOOD). However, following its 18:21Z rotation, the rotated agent re-landed the stale measurement unprompted in commit `6312c1318` without re-verifying against current trunk. Orchestrator `c-001` reverted `6312c1318` in `287f44f61`, restoring `f48525f17`.
  *Rule change / lesson:* Panel seat rotation briefs must mandate verifying current trunk and seat file status before committing, prohibiting unprompted re-commits of stale measurements.
- **Row 05 batch serialization and refactor share drop:**
  Row 05 was queued in Batch 3 because rows 03, 04, and 05 all touched `cleancode.test.mjs`. Because Batch 3 had to wait for row 04 to land (`9e6dbc8b8`), row 05 was queued only when the fleet refactor share fell to 16% (`c-001` blocker `7e976555`).
  *Rule change / lesson:* Avoid 3-batch chains. In round 13, limit batches to at most 2 and ensure every batch has at least 2 independent rows running in parallel.
- **Agy transcript parsing rollout success:**
  Row 01 (`69ba3fc76`) successfully added agy transcript parsing to `do_spl_review_line_check`. Agy reviewer seat `a-218@sat` immediately served as cross-vendor reviewer for rows 02, 04, 09, 10, completely eliminating the same-vendor review defect observed in round 11.
- **Remote-box review verification (`REVIEW_LINE_SYNTAX=1`):**
  Row 02 (`b340c14c5`) resolved the cross-box verification limitation by adding `REVIEW_LINE_SYNTAX=1`. This allows agents on any box to verify review line syntax and reviewer registration locally while outputting the exact command needed to verify the journal on the owning box (`sat`).
- **Coverage gate slack and mutation red controls:**
  For rows 08 and 09, the plan proposed red controls based on failing the coverage floor test without the new tests. However, the CI coverage runner allows 1.0 point of slack (`coverage + 1.0 < floor`), so the floor failure did not trigger. Both lanes adapted by providing mutation-based red controls (e.g. mutating `action.JSON` to `json.MarshalIndent` or `AvatarKey` check to `if false`), which cleanly failed and passed.
  *Rule change:* For Go coverage rows, when the statement gain is small (<= 1.0%), specify mutation-based red controls instead of floor-underflow controls.

## 5. Branches (R8 steps 1-2)

Dry run on trunk `dc17f840e`:
`cd csi-spl-orc && ROUND=12 DRY_RUN=1 ./run -a do_git_prune_round_branches`

```text
REF review/r12-01 94345d17b1d33e32adb0f6cc0cd3cb5fad169ee7 2026-10-15T16:35:47+03:00
REF review/r12-02 35cd562b89243ed1360c45c923aaea824014acae 2026-10-15T18:03:34+03:00
REF review/r12-03 5b18eed8d307fa3893b9663a898690173f97577b 2026-10-15T17:08:08+03:00
REF review/r12-04 a8a9280f6777cbd8c4722266ab4c59f48b9e05c7 2026-10-15T18:49:46+03:00
REF review/r12-06 4303fdf421606d8161072f8eb6c82b6e7edc3377 2026-10-15T16:57:36+03:00
REF review/r12-07 d83d04d864f5d9b628ea4491a2c31d3c01e629e5 2026-10-15T17:40:39+03:00
REF review/r12-08 94d4ff7218203c644502a20cbd35dd1b54b5083e 2026-10-15T17:07:54+03:00
REF review/r12-09 8813a47d7ef28ed1cdcb48a876d3b0ed6ed71532 2026-10-15T18:13:27+03:00
REF review/r12-10 8e2672aaad22fac619bd863534e8f649490ebeb8 2026-10-15T17:18:28+03:00
REF wip/m-213-c002-r12-seat-mistral f48525f170f72807b356ecb2036041e112b01574 2026-10-15T20:32:27+03:00
DRY_RUN round 12: 10 branch(es) listed, 0 kept unlanded on origin, nothing deleted (DRY_RUN=0 deletes the listed)
```

- **10 branches listed for pruning:** `review/r12-01`, `review/r12-02`, `review/r12-03`, `review/r12-04`, `review/r12-06`, `review/r12-07`, `review/r12-08`, `review/r12-09`, `review/r12-10`, `wip/m-213-c002-r12-seat-mistral` (all landed on master).
- **0 branches kept unlanded.**
Execution of `DRY_RUN=0` runs immediately after this retro lands.

## 6. What worked, what to change

- **Worked:** All landed rows landed in 1 push each; C7 held on all rows (0 lines diff); 100% cross-vendor reviews (0 same-vendor reviews); agy transcript support enabled agy seat `a-218@sat` to review 4 rows; `channel.ts` and `live-ws.mjs` successfully split into clean module steps under 80 lines; `execute_step` split while remaining byte-identical.
- **Change 1 (Round 13 focus):** Dedicate round 13 entirely to the Web UI (`csi-spl-wui/`), targeting cleaner code (large component / composable decomposition) and better testability (extracting pure logic into unit-testable utils).
- **Change 2 (Concurrency):** Build 2 row lanes in parallel at all times (owner instruction), ordering batches with disjoint files so no lane is blocked waiting on single-file batch chains.
- **Change 3 (Non-WUI items):** Items outside WUI carry to round 14's input list by pointer.

## 7. Round 13 inputs (measured on `dc17f840e`)

All counts measured on **`dc17f840e`** (`origin/master`):

1. **WUI component decomposition: `MessageCard.vue` script length:**
   `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/MessageCard.vue | wc -l` -> **`1416`** lines.
2. **WUI component decomposition: `ChannelSidebar.vue` script length:**
   `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/ChannelSidebar.vue | wc -l` -> **`1007`** lines.
3. **WUI component decomposition: `MessageComposer.vue` script length:**
   `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/components/MessageComposer.vue | wc -l` -> **`1135`** lines.
4. **WUI composable decomposition: `useMobileStack.ts` length:**
   `wc -l csi-spl-wui/src/composables/useMobileStack.ts | awk '{print $1}'` -> **`531`** lines.
5. **WUI composable decomposition: `useMsgShortcuts.ts` length:**
   `wc -l csi-spl-wui/src/composables/useMsgShortcuts.ts | awk '{print $1}'` -> **`464`** lines.
6. **WUI composable decomposition: `usePaneWidths.ts` length:**
   `wc -l csi-spl-wui/src/composables/usePaneWidths.ts | awk '{print $1}'` -> **`314`** lines.
7. **WUI composable decomposition: `useScrollAnchor.ts` length:**
   `wc -l csi-spl-wui/src/composables/useScrollAnchor.ts | awk '{print $1}'` -> **`293`** lines.
8. **WUI test gap: untested composable `useSubmitKey.ts`:**
   `git grep -l "useSubmitKey" csi-spl-wui/tests/unit/ | wc -l` -> **`0`**.
9. **WUI test gap: untested utility `poll-fence.mjs`:**
   `git grep -l "poll-fence" csi-spl-wui/tests/unit/ | wc -l` -> **`0`**.
10. **WUI test gap: untested store `src/stores/editMode.ts`:**
    `git grep -l "editMode" csi-spl-wui/tests/unit/ | wc -l` -> **`0`**.

### Items carried to Round 14 (outside WUI, by pointer)
- `csi-spl-api` Hub repo edit and action coverage gaps (carried from round 12 plan section 6).
- `csi-spl-orc` / `csi-spl-iac` long bash functions: `check-pre-push` (137 lines), `spawn_main` (185 lines), `run.sh do_log` (143 lines), `provision-firebase-dns` (169 lines).

## 8. Commands

```bash
git log origin/master -E --grep='r12-[0-9]{2}' --format='%h %cI %s'
git log origin/master -E --grep='r12-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 150 --json databaseId,headSha,conclusion,createdAt
cd csi-spl-orc && ROUND=12 DRY_RUN=1 ./run -a do_git_prune_round_branches
node csi-spl-wui/tests/unit/cleancode.test.mjs
node csi-spl-wui/src/node/test/run-unit-tests.mjs
```
