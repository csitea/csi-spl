# Test Round 2 - agy seat proposal (a-481@sat)

Measured on `59ffb5dd3` (`origin/master`, 2026-10-19 13:22Z, CI run 39259601111 success).

Test Round 2: testing self-reflection round 2, answering owner questions on testing balance (too much / too little), top failing tests in CI (message-order A6 flake), and the 12 most urgent changes to refactor testing across 3 batches of 4 rows for 4 parallel build lanes (owner override `fe3064af`).

The editor (this seat) drafts v0.1 in `../test-round-2-plan.md` and coordinates expert panel review across Claude, Mistral, and Grok seats.

## 1. The 12 actions (v0.1 proposal)

| # | slug | sites | n (CI wall median / baseline) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `test(r02-01-orc-speed-peer-poll)` | `orc:src/bash/tests/peer-poll.tst.sh` | 361.5 s CI wall (~54% idle, 166.7 s CPU) | < 150 s | tests | 1 | Lane 1 |
| 02 | `test(r02-02-iac-dry-run-tf-destroy)` | `iac:src/bash/tests/tf-destroy-target.tst.sh`, `iac:src/bash/tests/tf-destroy-local-step-bucket.tst.sh` | 0 tests for both destructive actions | 2 hermetic tests | tests | 1 | Lane 2 |
| 03 | `test(r02-03-wui-unit-msg-apply)` | `wui:tests/unit/msg-apply.test.mjs`, `wui:src/utils/msg-apply.mjs` | 0 tests for `msg-apply.mjs` | 1 unit test suite | tests | 1 | Lane 3 |
| 04 | `test(r02-04-go-coverage-fakeidp)` | `api:src/go/spool-hub-api/internal/auth/fakeidp/fakeidp_test.go`, `api:src/bash/tests/go-coverage-floor.txt` | 3.5% statement coverage, floor 3.5 | > 70.0% coverage, floor 70.0 | tests | 1 | Lane 4 |
| 05 | `test(r02-05-orc-speed-desk-up-all)` | `orc:src/bash/tests/desk-up-all.tst.sh` | 165.0 s CI wall (~72% idle, 46.9 s CPU) | < 60 s | tests | 2 | Lane 1 |
| 06 | `test(r02-06-iac-dry-run-tf-state-target)` | `iac:src/bash/tests/tf-remove-step.tst.sh`, `iac:src/bash/tests/tf-replace-target.tst.sh`, `iac:src/bash/tests/tf-state-push.tst.sh` | 0 tests for 3 destructive state actions | 3 hermetic tests | tests | 2 | Lane 2 |
| 07 | `test(r02-07-wui-unit-tenant-host-core)` | `wui:tests/unit/tenant-host-core.test.mjs`, `wui:src/utils/tenant-host-core.mjs` | 0 tests for `tenant-host-core.mjs` | 1 unit test suite | tests | 2 | Lane 3 |
| 08 | `test(r02-08-wui-flake-message-order)` | `wui:tests/e2e/message-order.test.mjs` | 10 CI failures in last 100 runs (shard 6/8) | 0 flakes across 20 runs | tests | 2 | Lane 4 |
| 09 | `test(r02-09-orc-speed-desk-welcome-pin)` | `orc:src/bash/tests/desk-welcome.tst.sh`, `orc:src/bash/tests/desk-pin.tst.sh` | 95.7 s and 98.2 s CI wall (~70-76% idle) | < 40 s each | tests | 3 | Lane 1 |
| 10 | `test(r02-10-iac-dry-run-gcp-apis-disable)` | `iac:src/bash/tests/gcp-modify-project-apis-disable.tst.sh`, `iac:src/bash/tests/gcp-project-apis-disable.tst.sh` | 0 tests for 2 destructive API actions | 2 hermetic tests | tests | 3 | Lane 2 |
| 11 | `test(r02-11-wui-unit-composables)` | `wui:tests/unit/useBuildWatch.test.mjs`, `wui:tests/unit/useOpenMessage.test.mjs`, `wui:tests/unit/useRoadmapGoals.test.mjs` | 0 tests for 3 core composables | 3 unit test suites | tests | 3 | Lane 3 |
| 12 | `test(r02-12-orc-speed-spool-install)` | `orc:src/bash/tests/spool-install.tst.sh` | 92.5 s CI wall (243 s packing weight) | < 45 s | tests | 3 | Lane 4 |

## 2. 4 Parallel Lanes (fe3064af)

- Lane 1: Row 01 -> Row 05 -> Row 09
- Lane 2: Row 02 -> Row 06 -> Row 10
- Lane 3: Row 03 -> Row 07 -> Row 11
- Lane 4: Row 04 -> Row 08 -> Row 12
- Batch 1 (Rows 01, 02, 03, 04) running in 4 parallel lanes with strictly disjoint files.
- Reviews per R7.2: strict cross-vendor review by Editor seat `a-481@sat` (agy) and Mistral seat `m-xxx@sat` on claude-authored rows.

## 3. Signature

signed: a-481@sat on v0.1 proposed (awaiting panel review)
