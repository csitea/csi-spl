# Test Round 1 - agy seat proposal (a-235@sat)

Measured on `7a041f105` and `754b1d4bb` / `5ed36156d` (`origin/master`, 2026-10-16).

Test Round 1: testing self-reflection, answering owner questions on testing balance (too much / too little), top failing tests in CI, and the 12 most urgent changes to refactor testing.

The editor (this seat) synthesizes expert panel consensus from Claude seat `c-245` (`c1c42bebe`), Claude takeover seat `c-249` (`5ed36156d`), and signatures on `7289d2db8` (`37ca626ec` and `82cbfa914`) into `../test-round-1-plan.md` v1.0.

## 1. The 12 actions (v1.0 consensus)

| # | slug | sites | n (CI wall median / baseline) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `test(r01-01-orc-speed-orch-rotate)` | `orc:src/bash/tests/orch-rotate.tst.sh` | 426 s wall median (~88% idle) | < 120 s | tests | 1 | Lane 1 |
| 02 | `test(r01-02-orc-speed-fleet-lease)` | `orc:src/bash/tests/fleet-lease.tst.sh` | 236 s wall median (~44% idle) | < 120 s | tests | 1 | Lane 2 |
| 03 | `test(r01-03-orc-speed-tmux-close-window)` | `orc:src/bash/tests/tmux-close-window.tst.sh`, `features/spawn-agents/tests/test-tmux-close-window.sh` | 169 s wall median (~94% idle) | < 30 s | tests | 1 | Lane 3 |
| 04 | `test(r01-04-go-coverage-floors)` | `api:src/bash/tests/go-coverage-floor.txt` | 5 packages at 0.0 floor | ratcheted floors | tests | 1 | Lane 4 |
| 05 | `test(r01-05-orc-speed-dispatch-rotate)` | `orc:src/bash/tests/dispatch-rotate.tst.sh` | 249 s wall median (~78% idle) | < 90 s | tests | 2 | Lane 1 |
| 06 | `test(r01-06-orc-speed-parse-metadata)` | `orc:src/bash/tests/parse-metadata-nofork.tst.sh` | 191 s wall median | < 90 s | tests | 2 | Lane 2 |
| 07 | `test(r01-07-orc-speed-desk-actions)` | `orc:src/bash/tests/desk-actions.tst.sh` | 225 s wall median (~33% idle) | < 90 s | tests | 2 | Lane 3 |
| 08 | `test(r01-08-iac-dry-run-destructive)` | `iac:src/bash/tests/gcp-delete-service-account.tst.sh`, `iac:src/bash/tests/gcp-compute-lb-cleanup.tst.sh` | 0 tests for 2 destructive actions | 2 hermetic tests | tests | 2 | Lane 4 |
| 09 | `test(r01-09-orc-speed-cloud-actions)` | `orc:src/bash/tests/cloud-actions.tst.sh` | 160 s wall median (~94% idle) | < 45 s | tests | 3 | Lane 1 |
| 10 | `test(r01-10-orc-speed-wd-self-update)` | `orc:src/bash/tests/wd-self-update.tst.sh` | 175 s wall median (~65% idle) | < 60 s | tests | 3 | Lane 2 |
| 11 | `test(r01-11-wui-flake-open-in-place)` | `wui:tests/e2e/open-in-place.test.mjs` | 1 CI flake in last 100 runs | 0 flakes across 20 runs | tests | 3 | Lane 3 |
| 12 | `test(r01-12-orc-speed-box-purge)` | `orc:src/bash/tests/box-purge.tst.sh` | 190 s wall median | < 60 s | tests | 3 | Lane 4 |

## 2. 4 Parallel Lanes (fe3064af)

- Lane 1: Row 01 -> Row 05 -> Row 09
- Lane 2: Row 02 -> Row 06 -> Row 10
- Lane 3: Row 03 -> Row 07 -> Row 11
- Lane 4: Row 04 -> Row 08 -> Row 12
- Batch 1 (Rows 01, 02, 03, 04) running in 4 parallel lanes with strictly disjoint files.
- Reviews per R7.2: Editor seat a-235@sat (agy) reviews all 12 rows (zero same-vendor reviews).

## 3. Signature

signed: a-235@sat on v1.0 consensus (panel signatures landed: c-245 on 37ca626ec, c-249 on 82cbfa914)
