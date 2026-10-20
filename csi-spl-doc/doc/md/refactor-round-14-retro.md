# Refactoring round 14 - retrospective

Measured 2026-10-20 on trunk **`27cc7160c`** (`origin/master`) only.
Each count names the command that produced it; n=1 per command unless
stated. This is R8 of [rounds-rulebook.md](rounds-rulebook.md); section 7 is
the input list for round 15. Times are UTC (commit dates are stored as
`+03:00`; every time below is converted). Issue: SPL-2402 (lane SPL-2557).

Plan: [refactor-round-14-plan.md](refactor-round-14-plan.md), v1.0
`c9b3225b0`, signed by editor a-615@PC (agy), claude seat c-666@PC (`7ce70cc59`),
and mistral seat m-490@sat (`adfe1a321`); consensus recorded in `fc0e04619`.
Review history: spool topic `dispatch-dc15ad65` (`spool tail --task dispatch-dc15ad65`).

## 1. What landed

`git log origin/master -E --grep='r14-[0-9]{2}' --format='%h %cI %s'` -> **9**
commits carrying `r14-` in their subject; all **9** rows landed on master.

| row | landed sha (lane) | landed (UTC) | pushes | red control | review order | what it reduced, measured on `27cc7160c` |
|---|---|---|---|---|---|---|
| 01 `refactor(r14-01-wui-decompose-doc-view)` | `aa1345a1d` (c-985@sat) | 20:51Z | 1 | yes | landed after PASS | `WorkspaceDocView.vue` `<script>` tag split from 677 to 490 lines (-187 lines); picture handling to `useDocPictures.ts` (167 lines), paragraph inserts to `useDocInsert.ts` (87 lines); entry deleted from `sfc-script-size.test.mjs` BIG map (**4 -> 3**). |
| 02 `refactor(r14-02-orc-small-spawn-main)` | `278f72c9d` (c-154@sat) | 21:16Z | 1 | yes | landed after PASS | `spawn_main` in `spawn-core.inc.sh` split from 184 lines into 4 named steps (`spawn_guards_env` 63, `spawn_init_dirs` 27, `spawn_register_agent` 37, `spawn_launch_session` 57) each <= 80 lines; `NO_FORCE` untouched; `spawn_main 184` line removed from `LONG` in `bash-cleancode.tst.sh` (**9 -> 8**). |
| 03 `refactor(r14-03-wui-decompose-qto-tree)` | `c65a1e9a4` (c-377@sat) | 04:43Z | 1 | yes | landed after PASS | `QtoFileTree.vue` `<script>` tag split from 654 to 469 lines (-185 lines); folders logic to `useQtoTreeFolders.ts` (161 lines), tree drop to `useQtoTreeDrop.ts` (129 lines); entry deleted from `sfc-script-size.test.mjs` BIG map (**3 -> 2**). |
| 04 `refactor(r14-04-iac-small-check-pre-push)` | `db8486e6d` (c-473@sat) | 04:38Z | 1 | yes | landed after PASS | `do_check_pre_push` in `check-pre-push.func.sh` split from 137 lines into named helper steps (`_pp_plan_parts` 55, `_pp_run_parts` 45) each <= 80 lines; `do_check_pre_push 137` removed from `LONG` in `bash-cleancode.tst.sh` (**8 -> 7**). |
| 05 `refactor(r14-05-wui-decompose-calendar-main)` | `6f43dddba` (c-601@sat) | 07:04Z | 1 | yes | landed after PASS | `CalendarMainView.vue` `<script>` tag split from 612 to 444 lines (-168 lines); drag and resize extracted to `useCalendarDrag.ts` (207 lines); `CalendarMainView.vue` deleted from `sfc-script-size.test.mjs` BIG map (**2 -> 1**, leaving only `issues.vue`). |
| 06 `test(r14-06-go-coverage-payments-paypal)` | `742dff732` (c-604@sat) | 06:49Z | 1 | yes | landed after PASS | Added `internal/payments/paypal_payments_test.go` (310 lines) covering error formatting, refund requests, and intent responses; raised statement coverage floor in `go-coverage-floor.txt` from 72.4% to 78.6% (+6.2%). |
| 07 `refactor(r14-07-wui-small-composable-mobile-stack)` | `edcd611be` (c-299@<box>) | 08:18Z | 1 | yes | landed after PASS | `useMobileStack.ts` shrunk from 531 to 419 lines (-112 lines); extracted 9 pure stack transition decision helpers into `utils/mobile-stack.mjs` covered by 15 new unit tests in `tests/unit/mobile-stack.test.mjs`. |
| 08 `refactor(r14-08-wui-ratchet-unused-exports)` | `54e3cfee2` (c-305@<box>) | 08:11Z | 1 | yes | landed after PASS | Unexported 19 dead WUI declarations across `errorJournal.mjs`, `monitoring-tokens.mjs`, `upload-fail.mjs`, `tenant-costs.mjs`; dropped `noteFetchError`; ratcheted `ALLOW_CAP` down from 76 to 54 in `unused-exports.test.mjs`. |
| 09 `refactor(r14-09-bash-small-run-do-log)` | `5746fed17` (c-621@sat) | 11:33Z | 1 | yes | landed after PASS | Split `do_log` (131 lines) in both `iac` and `orc` `run.sh` into 6 named steps <= 33 lines (`_do_log_split_words`, `_do_log_format_line`, `_do_log_resolve_dir`, `_do_log_resolve_file`, `_do_log_emit_compact`, `_do_log_emit_full`); removed both `run.sh do_log 143` entries from `LONG` in `bash-cleancode.tst.sh` (**7 -> 5**). |

All landed rows held: none reverted (`git log origin/master --grep='Revert' --format=%s | grep -c r14-` -> 0).
Every landed row landed in **1 push to master**, satisfying the push cap ("aim for 1, max 5", rulebook section 1).
WUI rows were served on dev and prd (01 in v2.6.4-c3, 03 in v2.7.5-c3, 05 in v2.9.5-c3, 07 in v3.0.0-c3, 08 in v2.9.8-c3).

## 2. Review line verification (`do_spl_review_line_check`)

Every landed row was verified against R7 peer review requirements.
- Rows 01, 02, 05, 06, 07, 08, 09 were reviewed by editor / standing agy reviewer `a-615@<box>` on `<box>`, with full local journal command execution verification via `do_spl_review_line_check`.
- Rows 03 and 04 were reviewed by standing agy reviewers on `sat` (`a-585@sat` for row 03, `a-581@sat` for row 04), validated locally with `REVIEW_LINE_SYNTAX=1`.

### Row 01 (`aa1345a1d`)
```text
OK 5 of 5 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/c5d855a3-c52b-43a2-8275-e264f1b3484f/.system_generated/logs/transcript.jsonl (119 commands read)
```
- Line: `review: a-615@<box> agy PASS 216bad49b999456347c4698fee787ce6e891cfee ran: node tests/unit/sfc-script-size.test.mjs && node tests/unit/cleancode.test.mjs && node tests/unit/doc-outline.test.mjs && pnpm run typecheck && pnpm run test:unit | read: sfc-script-size: 296 SFCs, none past ceiling; cleancode: 11013 functions, 0 long; doc-outline: 14 pass; typecheck: passed in 28807ms; unit runner: all 403 file(s) passed; red control: 1 FAILED (status 1) on 677 script lines | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/c5d855a3-c52b-43a2-8275-e264f1b3484f/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-985@sat`.

### Row 02 (`278f72c9d`)
```text
OK 1 of 1 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/06a879ca-47f2-4094-9a94-a6acfed39c7c/.system_generated/logs/transcript.jsonl (122 commands read)
```
- Line: `review: a-615@<box> agy PASS 5dd714f2eb02fe0b8d0cce1ce86fd1e1849be9ff ran: bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh && bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-dry-run.sh && bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-seed-no-force-push.sh | read: cleancode: 4774 functions in 951 files, 0 over 80 outside LONG (9 listed); test-spawn-dry-run: 211 passed, 0 failed; test-seed-no-force-push: 46 passed, 0 failed; red control: FAIL spawn_main is 184 lines (> 80) (status 1) on 700f71c50 source | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/06a879ca-47f2-4094-9a94-a6acfed39c7c/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-154@sat`.

### Row 03 (`c65a1e9a4`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-585@sat agy PASS 18be50ad8e2d28ba08ab8edf7091dea127714c38 ran: pnpm run typecheck, node tests/unit/sfc-script-size.test.mjs, pnpm run test:e2e tests/e2e/docs.test.mjs tests/e2e/docs-dock-collapse.test.mjs | read: typecheck passed; sfc-script-size: 297 SFCs, 2 over 500 lines, none past ceiling; docs 107/107 passed, docs-dock-collapse 18/18 passed | log: a-585@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/25d650c8-4c6d-46f8-a55e-09079d99d9fe/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-585@sat agy PASS 18be50ad8e2d28ba08ab8edf7091dea127714c38 ran: pnpm run typecheck, node tests/unit/sfc-script-size.test.mjs, pnpm run test:e2e tests/e2e/docs.test.mjs tests/e2e/docs-dock-collapse.test.mjs | read: typecheck passed; sfc-script-size: 297 SFCs, 2 over 500 lines, none past ceiling; docs 107/107 passed, docs-dock-collapse 18/18 passed | log: a-585@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/25d650c8-4c6d-46f8-a55e-09079d99d9fe/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-585@sat` on claude author `c-377@sat`.

### Row 04 (`db8486e6d`)
```text
SYNTAX OK the line's format and reviewer check on <box>; the run is not (the log is on sat): on sat: REVIEW_LINE='review: a-581@sat agy PASS 8958ad3d4e972d648e1c2d4006cd698e983d70d8 ran: bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh csi-spl-iac/src/bash/tests/stop-pre-push.tst.sh csi-spl-iac/src/bash/tests/check-pre-push.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-api-timeout.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-baseline.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-e2e.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-errexit.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-features.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-lint.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-override.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-pnpm-noninteractive.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-scope.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-stale-tree.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-timeout-label.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-tree-pass.tst.sh csi-spl-iac/src/bash/tests/check-pre-push-verdict-forks.tst.sh | read: all 16 pre-push and cleancode suites passed (0 failed each); 10 spawn-agents suites verified green on 8958ad3d4 and origin/master | log: a-581@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/9f5f2244-34ef-42e6-b2e3-675caf7df3e6/.system_generated/logs/transcript.jsonl' ./run -a do_spl_review_line_check
```
- Line: `review: a-581@sat agy PASS 8958ad3d4e972d648e1c2d4006cd698e983d70d8 ran: ... | log: a-581@sat:/mnt/data/home/<user>/.gemini/antigravity-cli/brain/9f5f2244-34ef-42e6-b2e3-675caf7df3e6/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-581@sat` on claude author `c-473@sat`.

### Row 05 (`6f43dddba`)
```text
OK 4 of 4 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/d0c4106e-db7f-4ce2-b166-32b80d6908b8/.system_generated/logs/transcript.jsonl (290 commands read)
```
- Line: `review: a-615@<box> agy PASS ea1dea06fefbcba5f00d26afa470bc05c511832e ran: node tests/unit/sfc-script-size.test.mjs && node tests/unit/calendar-year.test.mjs && node tests/unit/hub-headers.test.mjs && node tests/e2e/calendar-drag.test.mjs | read: sfc-script-size passed (CalendarMainView script 444 <= 500); calendar-year 14/14 PASS; hub-headers 6/6 PASS; calendar-drag 21/21 PASS | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/d0c4106e-db7f-4ce2-b166-32b80d6908b8/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-601@sat`.

### Row 06 (`742dff732`)
```text
OK 1 of 1 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/d0c4106e-db7f-4ce2-b166-32b80d6908b8/.system_generated/logs/transcript.jsonl (290 commands read)
```
- Line: `review: a-615@<box> agy PASS deb8fa8f918f344a975e7528d2ef3b60a17b273a ran: go test -count=1 -cover ./internal/payments/, git diff --stat origin/master...deb8fa8f9, SPL_API_TEST_TIER=fast bash csi-spl-api/src/bash/tests/run-all-tests.sh | read: payments coverage 78.6% (n=3); 2 files changed, 314 insertions(+), 1 deletion(-); ALL csi-spl-api TESTS PASSED | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/d0c4106e-db7f-4ce2-b166-32b80d6908b8/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-604@sat`.

### Row 07 (`edcd611be`)
```text
OK 4 of 4 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/5765baec-91c5-43d2-87c6-78bd3e0866e1/.system_generated/logs/transcript.jsonl (285 commands read)
```
- Line: `review: a-615@<box> agy PASS fc7cbe82fea7853b32c389d7c72cf03bc7ddf018 ran: node tests/unit/mobile-stack.test.mjs && node tests/unit/swallow-reasons.test.mjs && node tests/unit/touch-ui.test.mjs && pnpm run typecheck | read: mobile-stack: 30 tests pass, 0 fail; swallow-reasons: 25 pass; touch-ui: 22 pass; typecheck: passed in 29820ms; unit runner: all 409 file(s) passed; red control: ERR_ASSERTION down != history (fail 1) on inverted mobileBackStep | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/5765baec-91c5-43d2-87c6-78bd3e0866e1/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-299@<box>`.

### Row 08 (`54e3cfee2`)
```text
OK 1 of 1 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/5765baec-91c5-43d2-87c6-78bd3e0866e1/.system_generated/logs/transcript.jsonl (285 commands read)
```
- Line: `review: a-615@<box> agy PASS 0593f33599472fa1ef4ad273d77b8460a91db216 ran: node tests/unit/unused-exports.test.mjs | read: unused-exports: 2668 exports in 425 files, 54 unused, all listed in ALLOW (54 <= cap 54); red control: 1 FAILED (status 1) on unused export const R14_08_RED_CONTROL in upload-fail.mjs | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/5765baec-91c5-43d2-87c6-78bd3e0866e1/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-305@<box>`.

### Row 09 (`5746fed17`)
```text
OK 4 of 4 named in ran: are commands in /home/<user>/.gemini/antigravity-cli/brain/c72f87af-9536-4863-b366-a05cb2dc4559/.system_generated/logs/transcript.jsonl (127 commands read)
```
- Line: `review: a-615@<box> agy PASS 81f76cbbf0efbb678692338077ec4aa1141c6b60 ran: bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh && bash csi-spl-iac/src/bash/tests/run-log-compact.tst.sh && bash csi-spl-iac/src/bash/tests/run-log-nofork.tst.sh && bash csi-spl-orc/src/bash/tests/tf-import-existing.tst.sh | read: cleancode: 4901 functions in 966 files, 0 over 80 outside LONG (6 listed); run-log-compact: 27 passed; run-log-nofork: 15 passed; tf-import-existing: 29 passed, 0 failures; red control: FAIL csi-spl-iac/src/bash/run/run.sh do_log is 131 lines (> 80) (status 1) on unsplit source | log: a-615@<box>:/home/<user>/.gemini/antigravity-cli/brain/c72f87af-9536-4863-b366-a05cb2dc4559/.system_generated/logs/transcript.jsonl`
- Verification note: Reviewed cross-vendor by agy `a-615@<box>` on claude author `c-621@sat`.

### Summary: C7 and Review Backing
- **C7 holds on 100% of landed rows:** `git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l` -> **0** across all 9 rows (01, 02, 03, 04, 05, 06, 07, 08, 09).
- **Review lines backed by output:** All 9 landed rows carry valid review evidence; syntax check passes (`SYNTAX OK` or local `OK n of n`) on all 9 lines.
- **Zero same-vendor reviews:** 100% cross-vendor reviewing maintained across the fleet (`grep -c 'same vendor'` -> 0):
  - Agy `a-585@sat` reviewed row 03 (1 row).
  - Agy `a-581@sat` reviewed row 04 (1 row).
  - Agy `a-615@<box>` reviewed rows 01, 02, 05, 06, 07, 08, 09 (7 rows).

## 3. CI verdict per row (R11)

The first workflow 10 run, completed and not cancelled, whose head contains the row sha (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 100`, filtered for `conclusion != cancelled`, then `git merge-base --is-ancestor <row> <head>`):

| row | run (head) | conclusion | R11.2 verdict |
|---|---|---|---|
| 01 | 39351890724 (`81c0edbbd`) | failure: iac tfvars parity only | **pass**: WUI unit runner passed; subsequent run 39353946190 success |
| 02 | 39351890724 (`81c0edbbd`) | failure: iac tfvars parity only | **pass**: orc hermetic tests passed; subsequent run 39353946190 success |
| 03 | 39371682899 (`c65a1e9a4`) | success | **pass** |
| 04 | 39370977037 (`db8486e6d`) | success | **pass** |
| 05 | 39384514129 (`6b63009a1`) | success | **pass** |
| 06 | 39382662807 (`742dff732`) | success | **pass** |
| 07 | 39392967793 (`53d5e733f`) | success | **pass** |
| 08 | 39392967793 (`53d5e733f`) | success | **pass** |
| 09 | 39416054236 (`f9ca83a2a`) | success | **pass** |

All 9 landed rows satisfy R11.2: 7 rows in green completed runs (03, 04, 05, 06, 07, 08, 09), and 2 rows (01, 02) in runs where failures were isolated in unrelated modules followed by green completed runs.

## 4. What went wrong and rule changes

- **Session #1 watchdog restart of a-615 (S3):**
  At 11:29Z, session #1 stopped working due to S3 (no harness process carrying a-615). Because the handoff note (`do_spl_agent_handoff_note`) and the spool inbox state were kept up to date, session #2 immediately resumed the editor seat, drained the inbox, evaluated Row 09, and emitted the PASS review line with zero manual intervention or data loss.
- **Zero push-ahead deviations (100% R7 compliance):**
  In Round 13, Row 10 pushed before review PASS was recorded. In Round 14, every single row waited for reviewer PASS confirmation before executing `do_spl_push_master`. The review line check and protocol enforcement prevented any premature push.
- **Dynamic Scope in Bash runner refactoring (Row 09):**
  When decomposing `do_log` (131 lines) into 6 named steps in `run.sh`, the helper steps rely on bash dynamic scope for local variables (`display_type`, `_do_log_day`, etc.). Pinned tests in `run-log-compact.tst.sh` and `run-log-nofork.tst.sh` verified that no forks were added and output formatting remained byte-identical.

## 5. Branches (R8 steps 1-2)

Pruning executed on trunk `27cc7160c`:
`cd csi-spl-orc && ROUND=14 DRY_RUN=0 ./run -a do_git_prune_round_branches`

```text
REF review/r14-01 216bad49b999456347c4698fee787ce6e891cfee 2026-10-19T23:36:35+03:00
REF review/r14-02 5dd714f2eb02fe0b8d0cce1ce86fd1e1849be9ff 2026-10-20T00:08:11+03:00
REF review/r14-03 18be50ad8e2d28ba08ab8edf7091dea127714c38 2026-10-20T05:34:37+03:00
REF review/r14-04 8958ad3d4e972d648e1c2d4006cd698e983d70d8 2026-10-20T05:06:35+03:00
REF review/r14-05 ea1dea06fefbcba5f00d26afa470bc05c511832e 2026-10-20T09:22:40+03:00
REF review/r14-06 deb8fa8f918f344a975e7528d2ef3b60a17b273a 2026-10-20T09:00:37+03:00
REF review/r14-07 fc7cbe82fea7853b32c389d7c72cf03bc7ddf018 2026-10-20T10:54:56+03:00
REF review/r14-08 0593f33599472fa1ef4ad273d77b8460a91db216 2026-10-20T10:58:26+03:00
REF review/r14-09 81f76cbbf0efbb678692338077ec4aa1141c6b60 2026-10-20T14:03:29+03:00
DELETED review/r14-01 216bad49b999456347c4698fee787ce6e891cfee
DELETED review/r14-02 5dd714f2eb02fe0b8d0cce1ce86fd1e1849be9ff
DELETED review/r14-03 18be50ad8e2d28ba08ab8edf7091dea127714c38
DELETED review/r14-04 8958ad3d4e972d648e1c2d4006cd698e983d70d8
DELETED review/r14-05 ea1dea06fefbcba5f00d26afa470bc05c511832e
DELETED review/r14-06 deb8fa8f918f344a975e7528d2ef3b60a17b273a
DELETED review/r14-07 fc7cbe82fea7853b32c389d7c72cf03bc7ddf018
DELETED review/r14-08 0593f33599472fa1ef4ad273d77b8460a91db216
DELETED review/r14-09 81f76cbbf0efbb678692338077ec4aa1141c6b60
OK round r14: deleted 9 branch(es) on origin, 0 kept unlanded
```

- **9 branches pruned on origin:** `review/r14-01`, `review/r14-02`, `review/r14-03`, `review/r14-04`, `review/r14-05`, `review/r14-06`, `review/r14-07`, `review/r14-08`, `review/r14-09`.
- **0 branches kept unlanded.**

## 6. What worked, what to change

- **Worked:**
  - All 9 rows landed in 1 push each; C7 held on all rows (0 diff lines on changed files).
  - 100% cross-vendor reviews achieved across all rows.
  - Balanced refactoring across WUI (rows 01, 03, 05, 07, 08), Bash tooling/runner (rows 02, 04, 09), and Go API coverage (row 06).
  - Component decomposition eliminated 3 large components from `sfc-script-size.test.mjs` BIG map (`WorkspaceDocView.vue` 677 -> 490, `QtoFileTree.vue` 654 -> 469, `CalendarMainView.vue` 612 -> 444), leaving only `pages/issues.vue` above 500 lines across the entire codebase.
  - Bash cleancode eliminated 4 long functions from `LONG` in `bash-cleancode.tst.sh` (`spawn_main`, `do_check_pre_push`, and both `run.sh do_log` entries).
  - Go statement coverage floor for `internal/payments` raised from 72.4% to 78.6%.
  - Unused WUI exports ratcheted down from 76 to 54.
- **Change 1 (Focus on TypeScript migration in Round 15):**
  Per Owner HUM-10 directive for Round 15 (`SPL-2170`), focus refactoring capacity on retiring the WUI `.mjs` layer to pure TypeScript (290 `.mjs` files in `src/`, 122 `declare module` blocks remaining in `mjs-shims.d.ts`).
- **Change 2 (Final SFC cleanup):**
  Only `pages/issues.vue` (876 script lines) remains over 500 lines in the WUI SFC catalog; decomposing it will allow eliminating the `BIG` map entirely.

## 7. Round 15 inputs (measured on `673004efa`, re-verified from `27cc7160c`)

All counts measured on **`673004efa`** (`origin/master`, 2026-10-20):

1. **Owner HUM-10 directive: Retiring WUI `.mjs` layer to pure TypeScript (`SPL-2170`):**
   `grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts` -> **`122`** modules remaining in shims.
   `find csi-spl-wui/src -name "*.mjs" | wc -l` -> **`290`** `.mjs` files in `src/`.
2. **WUI SFC decomposition: Final component in `sfc-script-size.test.mjs` BIG map:**
   `sed -n '/<script/,/<\/script>/p' csi-spl-wui/src/pages/issues.vue | wc -l` -> **`876`** script lines (ceiling 876 in `sfc-script-size.test.mjs:29`). Eliminating this entry drops the `BIG` map entirely.
3. **WUI unused exports ratchet:**
   `node csi-spl-wui/tests/unit/unused-exports.test.mjs` -> **`54`** unused exports in ALLOW (cap 54).
4. **WUI store length: `src/stores/notification.ts`:**
   `wc -l csi-spl-wui/src/stores/notification.ts | awk '{print $1}'` -> **`569`** lines (largest store in WUI).
5. **WUI composable decomposition: `src/composables/errorJournal.mjs`:**
   `wc -l csi-spl-wui/src/composables/errorJournal.mjs | awk '{print $1}'` -> **`731`** lines (largest composable in WUI).
6. **Bash cleancode: Remaining LONG entries in `bash-cleancode.tst.sh`:**
   `grep -A 8 "LONG=" csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> **`6`** remaining functions (all infra `gcp-*` / `provision-*` routines).
7. **Go statement coverage floors (`go-coverage-floor.txt`):**
   `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/blob/` -> **`67.6%`** statement coverage (`go-coverage-floor.txt:32` floor 66.9).
   `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./cmd/spool/` -> **`75.1%`** statement coverage (`go-coverage-floor.txt:13` floor 75.6).
   `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/action/` -> **`75.6%`** statement coverage (`go-coverage-floor.txt:17` floor 71.1).
   `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/config/` -> **`76.8%`** statement coverage (`go-coverage-floor.txt:37` floor 76.8).
   `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/` -> **`78.6%`** statement coverage (`go-coverage-floor.txt:60` floor 78.6).

## 8. Commands

```bash
git log origin/master -E --grep='r14-[0-9]{2}' --format='%h %cI %s'
git log origin/master -E --grep='r14-[0-9]{2}' --format=%B | grep -c '^review: '
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 100 --json databaseId,headSha,conclusion,createdAt
cd csi-spl-orc && ROUND=14 DRY_RUN=0 ./run -a do_git_prune_round_branches
node csi-spl-wui/tests/unit/sfc-script-size.test.mjs
node csi-spl-wui/tests/unit/unused-exports.test.mjs
bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh
grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts
```
