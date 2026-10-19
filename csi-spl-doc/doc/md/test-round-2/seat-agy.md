# Test Round 2 - agy seat proposal (a-481@sat)

Measured on `59ffb5dd3` (`origin/master`, 2026-10-19 13:22Z, CI run 39259601111 success).

Test Round 2: testing self-reflection round 2, answering owner questions on testing balance (too much / too little), top failing tests in CI (message-order A6 flake), and the 12 most urgent changes to refactor testing across 3 batches of 4 rows for 4 parallel build lanes (owner override `fe3064af`).

The editor (this seat) drafts v0.1 in `../test-round-2-plan.md` and coordinates expert panel review across Claude, Mistral, and Grok seats.

## 1. The 12 actions (v1.0 consensus)

| # | slug | sites | baseline (measured) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `test(r02-01-orc-speed-peer-poll)` | `orc:src/bash/tests/peer-poll.tst.sh` | solo 168.6-174.1 s wall, 190-197 s cpu (n=3) | solo cpu < 100 s | tests | 1 | Lane 1 |
| 02 | `test(r02-02-iac-dry-run-tf-destroy)` | `iac:src/bash/run/tf-destroy-target.func.sh`, `iac:src/bash/run/tf-destroy-local-step-bucket.func.sh`, `iac:src/bash/tests/tf-destroy-*.tst.sh` | 0 tests; 0 `DRY_RUN` guards | 2 hermetic tests + `DRY_RUN` default 1 | tests | 1 | Lane 2 |
| 03 | `test(r02-03-orc-jobs-derivation-weights)` | `orc:src/bash/tests/run-all-tests.sh`, `orc:src/bash/tests/orc-shard-weights.txt`, `orc:src/bash/tests/orc-jobs-derivation.tst.sh` | `njobs=6` hardcoded on 4-core runner; drifted weights | `njobs` capped at `nproc`; refreshed weights | tests | 1 | Lane 3 |
| 04 | `test(r02-04-go-coverage-coverpkg)` | `api:src/bash/tests/run-all-tests.sh`, `api:src/bash/tests/go-coverage-floor.txt` | `fakeidp` sits at 3.5% floor without cross-package coverage | `-coverpkg` support; fakeidp floor 80.0 | tests | 1 | Lane 4 |
| 05 | `test(r02-05-orc-agent-identity-reconcile)` | `orc:src/bash/run/spl-agent-identity-reconcile.func.sh`, `orc:src/bash/run/spl-agent-name-resume.func.sh`, `orc:src/bash/tests/spl-agent-identity-reconcile.tst.sh` | 0 tests for both agent identity actions | Hermetic test suite | tests | 2 | Lane 1 |
| 06 | `test(r02-06-iac-dry-run-tf-state-target)` | `iac:src/bash/run/tf-remove-step.func.sh`, `iac:src/bash/run/tf-replace-target.func.sh`, `iac:src/bash/run/tf-state-*.func.sh`, `iac:src/bash/tests/tf-state-actions.tst.sh` | 0 tests for all 4 state actions; 0 `DRY_RUN` guards | Hermetic test suite + `DRY_RUN` default 1 | tests | 2 | Lane 2 |
| 07 | `test(r02-07-orc-untested-probe-actions)` | `orc:src/bash/run/spl-msg-edit-probe.func.sh`, `orc:src/bash/run/spl-wire-probe.func.sh`, `orc:src/bash/run/spl-desk-live-proof.func.sh`, `orc:src/bash/tests/spl-probe-actions.tst.sh` | 0 tests for all 3 probe actions | Hermetic test suite | tests | 2 | Lane 3 |
| 08 | `test(r02-08-iac-gcp-list-actions)` | `iac:src/bash/run/gcp-compute-lb-list.func.sh`, `iac:src/bash/run/gcp-list-*.func.sh`, `iac:src/bash/tests/gcp-list-actions.tst.sh` | 0 tests for all 4 list actions | Hermetic test suite | tests | 2 | Lane 4 |
| 09 | `test(r02-09-orc-vibe-guard-actions)` | `orc:src/bash/run/spl-vibe-*.func.sh`, `orc:src/bash/tests/spl-vibe-guard-actions.tst.sh` | 0 tests for all 3 vibe guard actions | Hermetic test suite | tests | 3 | Lane 1 |
| 10 | `test(r02-10-iac-gcp-sync-tail-satellite)` | `iac:src/bash/run/gcp-sync-local-to-s3.func.sh`, `iac:src/bash/run/gcp-tail-logs.func.sh`, `iac:src/bash/run/satellite-image-latest.func.sh`, `iac:src/bash/tests/gcp-misc-actions.tst.sh` | 0 tests for all 3 actions | Hermetic test suite | tests | 3 | Lane 2 |
| 11 | `test(r02-11-orc-lane-lifecycle-actions)` | `orc:src/bash/run/spl-lane-age-report.func.sh`, `orc:src/bash/run/spl-rotate-status.func.sh`, `orc:src/bash/run/spl-local-hub-status.func.sh`, `orc:src/bash/run/spl-dispatch-deploy-lag.func.sh`, `orc:src/bash/tests/spl-lane-lifecycle-actions.tst.sh` | 0 tests for all 4 reporting actions | Hermetic test suite | tests | 3 | Lane 3 |
| 12 | `test(r02-12-orc-speed-spool-install)` | `orc:src/bash/features/spool-install/tests/test-install.sh`, `orc:src/bash/tests/spool-install.tst.sh` | solo 59.6-62.5 s wall at 62-64 s cpu (n=3) | solo cpu < 35 s | tests | 3 | Lane 4 |

## 2. 4 Parallel Lanes (fe3064af)

- Lane 1: Row 01 -> Row 05 -> Row 09
- Lane 2: Row 02 -> Row 06 -> Row 10
- Lane 3: Row 03 -> Row 07 -> Row 11
- Lane 4: Row 04 -> Row 08 -> Row 12
- Batch 1 (Rows 01, 02, 03, 04) running in 4 parallel lanes with strictly disjoint files.
- Reviews per R7.2: strict cross-vendor review by Editor seat `a-481@sat` (agy) and Mistral seat `m-639@PC` (docs/review only) on claude-authored rows.

## 3. Status and Signatures

- v0.1 proposed: landed on origin/master in `f7e038464` (docs published to dev and prd).
- Panel review received: Claude seat `c-487@sat` (`cefa6c737`), Mistral seat `m-639@PC` (`e428729eb`).
- Panel feedback folded into v1.0 (P1 runner sizing as Row 03, P2 coverpkg as Row 04, A6 dropped, 28 untested bash actions covered).
- v1.0 signed by Editor (`a-481@sat`); coordinating panel signatures from `c-487@sat` and `m-639@PC`.

signed: a-481@sat on v1.0 (SPL-2402, SPL-2554)
