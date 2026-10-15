# Refactoring round 12 - plan (10 actions)

Owner HUM-10, t1 topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`, msg 3d22fcea:
rounds run continuously, **no owner go for the round, its panel or its
lanes**. Refactoring share: owner t1 3209f8b8 (msgs a25bfdd6, 36ee9cec,
8cb6cc7d); spawn-share blocker b7870c0f. Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10
items, push caps, bands, R1-R16), by pointer, not copied. Issue: SPL-1920 (lane SPL-2002).

**Status: v0.1, PROPOSED** (for panel review and signatures). The rows spawn from the signed v1.0
sha (rulebook 1.4: consensus, then build, no second go).

Editor: **a-563@PC** (agy).

**One sha:** every count is measured on **`e42286100`** (`origin/master`,
2026-10-15 12:46Z), n=1 per command unless stated. Input:
[refactor-round-11-retro.md](refactor-round-11-retro.md) section 7.

## 1. How to read this

- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept, or for a gate a **red control**: the
  check fails on the bad input before the change and passes after.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` =
  `csi-spl-wui/`, `orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`. Lines as
  of `e42286100`.
- **Box:** the preferred box; the spawner's box pick may move a row (no pin).
- **Vendor:** the owner mix (`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix`
  on `e42286100`: simple_coding -> grok, backup claude; complex_coding and
  tests -> claude, backup mistral; specs_and_docs -> agy, backup claude),
  then R14. R14 after round 11: mistral is kept off gate and test suites after
  failing two review attempts on row 03, so mistral is assigned only simple
  refactorings with pre-existing templates.
- **Subject** (R6 reads it): `<type>(r12-NN-<slug>, SPL-<row issue>): ...`.
- **R7.4 line, this round:** the review line carries the run it claims
  (retro 7.1), in the landing commit:
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
  The sha is pasted from `git rev-parse`, never typed; `ran:` names only
  commands that are in the `log:` file.

## 2. Where the rows come from (measured on `e42286100`)

| source | command | n | row |
|---|---|---|---|
| retro 7.1 | `git grep -i agy e42286100 -- csi-spl-orc/src/bash/run/spl-review-line-check.func.sh \| wc -l` | 0 agy support | 01 |
| retro 7.9 | `git grep -c 'exit 2' e42286100 -- csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` | 1 refusal exit | 02 |
| retro 7.2 | `sed -n '/channel\.ts/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/stores/channel.ts <anon>', 576]` | 03 |
| retro 7.3 | `sed -n '/createLiveClient/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/utils/live-ws.mjs createLiveClient', 499]` | 04 |
| retro 7.4 | `sed -n '/createSpoolClient/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/utils/spool-client.mjs createSpoolClient', 545]` | 05 |
| retro 7.5 | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \| grep -c "NOTE LONG"` | 2 NOTEs (ceilings 175 and 120) | 06 |
| retro 7.6 | `git grep -n 'execute_step 99' e42286100 -- csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \| wc -l` | 2 files at 99 lines | 07 |
| retro 7.7 | `export PATH="/usr/local/go/bin:$PATH" && cd csi-spl-api/src/go/spool-hub-api && go test -coverprofile=/tmp/blob.cov ./internal/blob && go tool cover -func=/tmp/blob.cov \| grep AvatarKey` | `AvatarKey 0.0%` | 08 |
| retro 7.8 | `export PATH="/usr/local/go/bin:$PATH" && cd csi-spl-api/src/go/spool-hub-api && go test -coverprofile=/tmp/action.cov ./internal/action && go tool cover -func=/tmp/action.cov \| grep 'action.go:398'` | `JSON 0.0%` | 09 |
| retro 7.10 | `git grep -c 'csi-spl-api' e42286100 -- csi-spl-iac/src/bash/tests/no-box-path-source.tst.sh` | 0 (api and wui unscanned) | 10 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `ci(r12-01-review-line-check-agy-support)` | R7 reviewer evidence, gate | `do_spl_review_line_check` has 0 agy transcript support, excluding agy from R7 reviewing | `orc:src/bash/run/spl-review-line-check.func.sh:8-17,85-136`<br>`orc:src/bash/tests/spl-review-line-check.tst.sh` | 0 agy support | `_SPL_REVIEW_LINE_PY` also parses agy `transcript.jsonl` (and `transcript_full.jsonl`) extracting `CommandLine` from `run_command` tool calls. **Red control:** fixture agy transcript fails with old python script (`MISSING`), passes with new (`OK 1 of 1`). Tests: `spl-review-line-check.tst.sh` (new agy test cases). R9: `PRE_PUSH_TIER=full`. | PC | claude | simple_coding | 1 |
| 02 `ci(r12-02-review-line-check-remote-box)` | R7 review evidence, cross-box | `do_spl_review_line_check` refuses any log not on local box with exit 2, breaking multi-box validation | `orc:src/bash/run/spl-review-line-check.func.sh:34-37`<br>`orc:src/bash/tests/spl-review-line-check.tst.sh` | 1 exit 2 | When `box != me`, verify via SSH peer or check remote presence gracefully. **Red control:** remote box log exits 2 on old script; passes or delegates on new script. | sat | claude | simple_coding | 2 (after 01: `spl-review-line-check.func.sh`) |
| 03 `refactor(r12-03-wui-small-store-channel)` | small functions | store setup body is 576 lines | `wui:src/stores/channel.ts:67`<br>`wui:tests/unit/cleancode.test.mjs` | 1 LONG entry | Split setup into named module steps under 80 lines; `useChannelStore` API unchanged; delete LONG entry (3 -> 2). Tests: `cleancode.test.mjs`, unit tests importing `channel.ts`, `pnpm run typecheck`, `perf-budget.py bundle`. **Red control:** old file with LONG line deleted fails `cleancode.test.mjs`. | sat | claude | simple_coding | 1 |
| 04 `refactor(r12-04-wui-small-create-live-client)` | small functions | `createLiveClient` is 499 lines | `wui:src/utils/live-ws.mjs:209`<br>`wui:tests/unit/cleancode.test.mjs` | 1 LONG entry | Extract module step functions under 80 lines; delete LONG entry (2 -> 1). Tests: `cleancode.test.mjs`, `live-ws.test.mjs`, typecheck, perf budget. **Red control:** old file with LONG line deleted fails `cleancode.test.mjs`. | sat | claude | simple_coding | 2 (after 03: `cleancode.test.mjs`) |
| 05 `refactor(r12-05-wui-small-create-spool-client)` | small functions | `createSpoolClient` is 545 lines (the last WUI LONG entry) | `wui:src/utils/spool-client.mjs:272`<br>`wui:tests/unit/cleancode.test.mjs` | 1 LONG entry | Extract module step functions under 80 lines; delete LONG entry (1 -> 0, empty LONG map!). Tests: `cleancode.test.mjs`, `spool-client.test.mjs`, typecheck, perf budget. **Red control:** old file with LONG line deleted fails `cleancode.test.mjs`. | sat | claude | simple_coding | 3 (after 04: `cleancode.test.mjs`) |
| 06 `refactor(r12-06-bash-cleancode-ceilings-lowered)` | clean code, ceilings | two functions shrunk in round 11; clean-code gate prints 2 NOTEs | `iac:src/bash/tests/bash-cleancode.tst.sh:23,24` | 2 NOTEs | Lower ceiling of `do_gcp_import_to_cloudsql` 175 -> 174 and `do_gcp_project_delete` 120 -> 119. Tests: `bash-cleancode.tst.sh`. **Red control:** setting ceilings to 173 and 118 fails `bash-cleancode.tst.sh`. | sat | claude | simple_coding | 1 |
| 07 `refactor(r12-07-bash-small-run-execute-step)` | small functions | `execute_step` in `run.sh` is 99 lines (ceiling 99) in both iac and orc | `iac:src/bash/run/run.sh:26`<br>`orc:src/bash/run/run.sh:26`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:27,31` | 2 files at 99 lines | Split `execute_step` into helper steps under 80 lines; remove both LONG entries (12 -> 10). Tests: `bash-cleancode.tst.sh`, `./run` actions smoke test. **Red control:** old 99-line body with LONG entry deleted fails `bash-cleancode.tst.sh`. | sat | claude | simple_coding | 2 (after 06: `bash-cleancode.tst.sh`) |
| 08 `test(r12-08-go-coverage-blob-avatar-key)` | tests, coverage | `AvatarKey` is 0.0% coverage (pure path logic, no external dependencies) | `api:internal/blob/blob.go:40`<br>`api:internal/blob/blob_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt:19` | 1 function at 0.0% | Add table tests for `AvatarKey` (valid sha256 hex, invalid hex, boundary cases); raise `internal/blob` floor from 66.2 to 67.5. **Red control:** without new tests, raised floor fails `run-all-tests.sh --coverage-floor`. | sat | claude | tests | 1 |
| 09 `test(r12-09-go-coverage-action-json-helper)` | tests, coverage | `JSON` helper is 0.0% coverage | `api:internal/action/action.go:398`<br>`api:internal/action/action_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt:14` | 1 function at 0.0% | Add unit tests for `action.JSON(v)` verifying exact CLI output serialization; raise `internal/action` floor from 70.3 to 71.5. **Red control:** without new tests, raised floor fails. | sat | claude | tests | 2 (after 08: `go-coverage-floor.txt`) |
| 10 `test(r12-10-no-box-path-source-expand-dirs)` | gate, coverage | `no-box-path-source.tst.sh` only scans iac and orc, leaving api and wui shell scripts ungated | `iac:src/bash/tests/no-box-path-source.tst.sh:15-30` | 0 tests for api/wui | Extend `scan()` in `no-box-path-source.tst.sh` to cover shell scripts in `csi-spl-api/` and `csi-spl-wui/`. **Red control:** plant script in `csi-spl-api/src/bash/` with `/opt/` source fails the test. | sat | claude | tests | 1 |

### 3.1 Disjoint files (R1)

- **Batch 1:** 01, 03, 06, 08, 10.
  - 01: `orc:src/bash/run/spl-review-line-check.func.sh`, `orc:src/bash/tests/spl-review-line-check.tst.sh`
  - 03: `wui:src/stores/channel.ts`, `wui:tests/unit/cleancode.test.mjs`
  - 06: `iac:src/bash/tests/bash-cleancode.tst.sh`
  - 08: `api:internal/blob/blob_test.go`, `api:src/bash/tests/go-coverage-floor.txt`
  - 10: `iac:src/bash/tests/no-box-path-source.tst.sh`
  No path appears in two actions of Batch 1.
- **Batch 2:** 02, 04, 07, 09.
  - 02: `orc:src/bash/run/spl-review-line-check.func.sh` (after 01 lands)
  - 04: `wui:src/utils/live-ws.mjs`, `wui:tests/unit/cleancode.test.mjs` (after 03 lands)
  - 07: `iac:src/bash/run/run.sh`, `orc:src/bash/run/run.sh`, `iac:src/bash/tests/bash-cleancode.tst.sh` (after 06 lands)
  - 09: `api:internal/action/action_test.go`, `api:src/bash/tests/go-coverage-floor.txt` (after 08 lands)
  No path appears in two actions of Batch 2.
- **Batch 3:** 05.
  - 05: `wui:src/utils/spool-client.mjs`, `wui:tests/unit/cleancode.test.mjs` (after 04 lands)
- Dependent rows are placed within 30 min of their prerequisite landing (R16).

### 3.2 Off every live lane (R3)

`lane-map.sh --check <paths> --agent a-563` on `e42286100` verifies that no live lane owns any row path. The spawner re-runs `--check` per row before spawning (R3).

## 4. Per row: what the lane does

- **01:** update `_SPL_REVIEW_LINE_PY` in `spl-review-line-check.func.sh` to extract commands from agy `transcript.jsonl` tool calls (`args.CommandLine` where `name == "run_command"`). Commit body carries red control proof.
- **02:** add cross-box handling to `do_spl_review_line_check` when `box != me`.
- **03:** split `useChannelStore` setup body in `src/stores/channel.ts` into named module step functions under 80 lines; API and reactivity unchanged; remove LONG entry from `cleancode.test.mjs`.
- **04:** extract helper functions from `createLiveClient` in `live-ws.mjs` under 80 lines; remove LONG entry.
- **05:** extract helper functions from `createSpoolClient` in `spool-client.mjs` under 80 lines; remove LONG entry (achieving 0 WUI LONG entries).
- **06:** lower ceilings in `bash-cleancode.tst.sh` for `do_gcp_import_to_cloudsql` (174) and `do_gcp_project_delete` (119).
- **07:** split `execute_step` in `iac:run.sh` and `orc:run.sh` into named helper steps under 80 lines; remove both LONG entries from `bash-cleancode.tst.sh`.
- **08:** write `internal/blob/blob_test.go` covering `AvatarKey`; raise coverage floor to 67.5 in `go-coverage-floor.txt`.
- **09:** write `internal/action/action_test.go` covering `JSON(v)`; raise coverage floor to 71.5 in `go-coverage-floor.txt`.
- **10:** extend `no-box-path-source.tst.sh` directory list to include shell scripts in `csi-spl-api` and `csi-spl-wui`.

## 5. Panel and reviewers (R7)

- **Signing panel:** editor `a-563@PC` (agy), `c-192@sat` (claude review seat), and `m-561@sat` (mistral seat): 3 vendors.
- **Reviewer per row** (R7.2):
  - With row 01 landing agy support in `do_spl_review_line_check`, the **agy seat** reviews claude rows (01-10).
  - Backup reviewer: mistral seat `m-561@sat` or claude seat `c-192@sat` where cross-vendor constraints allow.
  - Review evidence must conform to rulebook 2.7.4.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| bash LONG `check-pre-push 137`, `spawn_main 185`, `run.sh do_log 143`, gcp-001/002, `provision-firebase-dns 169` | larger functions or active CI areas; row 07 tackles `execute_step` first | `bash-cleancode.tst.sh` |
| `cmd/spool` remaining 17 functions at 0.0% | require Postgres, key daemon, or process entry (`main.go`) | `go tool cover -func` |
| remote branch prune round 11 | executed under R8 step 2 by retro lane | `ROUND=11 DRY_RUN=0 ./run -a do_git_prune_round_branches` |

## 7. Counts

| | n |
|---|---|
| rows | 10 (ci 2, refactor 5, test 3) |
| vendor | claude 10 (or grok backup on simple_coding) |
| box (preferred) | sat 8, PC 2 |
| batches | batch 1: 5; batch 2: 4; batch 3: 1 |

## 8. Changes

- v0.1: Initial proposed plan from round 11 retrospective section 7, measured on `e42286100`.

## 9. Consensus

| seat | id | signed | file |
|---|---|---|---|
| editor (agy) | a-563@PC | v0.1 proposed | this file |
| claude seat | c-192@sat | pending | `refactor-round-12/seat-claude.md` |
| mistral seat | m-561@sat | pending | `refactor-round-12/seat-mistral.md` |

Signed plan sha: pending panel review and sign-off.
