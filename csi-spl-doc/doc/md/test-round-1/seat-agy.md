# Test Round 1 - agy seat proposal (a-235@sat)

Measured on `4251b33cf` (`origin/master`, 2026-10-15 20:42Z).

A proposal for Test Round 1: testing self-reflection, answering owner questions on testing balance (too much / too little), top failing tests in CI, and the 12 most urgent changes to refactor testing.

The editor (this seat) merges expert panel proposals into `../test-round-1-plan.md`.
The expert panel seats (claude, grok, mistral) review empirical measurements on current trunk, give verdicts per row, and sign v1.0.

## 1. The 12 actions

| # | slug | sites | n (measured on `4251b33cf`) | target | kind | batch | lane |
|---|---|---|---|---|---|---|---|
| 01 | `test(r01-test-orc-speed-fleet-lease)` | `orc:src/bash/tests/fleet-lease.tst.sh` | 580 s wall time | < 60 s | tests | 1 | Lane 1 |
| 02 | `test(r01-test-orc-speed-spl-lane-mix)` | `orc:src/bash/tests/spl-lane-mix.tst.sh` | 545 s wall time | < 90 s | tests | 1 | Lane 2 |
| 03 | `test(r01-test-orc-behavioral-search-sig)` | `orc:src/bash/tests/spl-search-sig-check.tst.sh` | 1 static source grep | 0 greps; behavioral exit test | tests | 1 | Lane 3 |
| 04 | `test(r01-test-go-coverage-logging)` | `api:internal/logging/`, `go-coverage-floor.txt` | 0.0 floor (100.0% actual) | floor ratcheted to 85.0 | tests | 1 | Lane 4 |
| 05 | `test(r01-test-orc-speed-peer-poll)` | `orc:src/bash/tests/peer-poll.tst.sh` | 518 s wall time | < 60 s | tests | 2 | Lane 1 |
| 06 | `test(r01-test-orc-speed-parse-metadata)` | `orc:src/bash/tests/parse-metadata-nofork.tst.sh` | 453 s wall time | < 60 s | tests | 2 | Lane 2 |
| 07 | `test(r01-test-orc-behavioral-unanswered-sweep)` | `orc:src/bash/tests/unanswered-sweep-pg.tst.sh` | 1 static source grep | 0 greps; query execution test | tests | 2 | Lane 3 |
| 08 | `test(r01-test-go-coverage-testkit)` | `api:internal/testkit/fakehub/`, `go-coverage-floor.txt` | 0.0 floor (82.1% actual) | floor ratcheted to 75.0 | tests | 2 | Lane 4 |
| 09 | `test(r01-test-orc-speed-desk-actions)` | `orc:src/bash/tests/desk-actions.tst.sh` | 366 s wall time | < 60 s | tests | 3 | Lane 1 |
| 10 | `test(r01-test-orc-untested-actions-ask-owner)` | `orc:src/bash/run/spl-ask-owner.func.sh`, `orc:src/bash/tests/spl-ask-owner.tst.sh` | 0 direct tests | 1 new hermetic test | tests | 3 | Lane 2 |
| 11 | `test(r01-test-ci-flake-open-in-place)` | `wui:tests/e2e/open-in-place.test.mjs` | 1 CI flake in last 100 runs | 0 flakes across 20 runs | tests | 3 | Lane 3 |
| 12 | `test(r01-test-go-coverage-edge)` | `api:internal/edge/edge_test.go`, `go-coverage-floor.txt` | 0 TestGoFiles | 1 test file; floor 99.0 | tests | 3 | Lane 4 |

## 2. 4 Parallel Lanes (fe3064af)

- Lane 1: Row 01 -> Row 05 -> Row 09
- Lane 2: Row 02 -> Row 06 -> Row 10
- Lane 3: Row 03 -> Row 07 -> Row 11
- Lane 4: Row 04 -> Row 08 -> Row 12
- Starts with: Batch 1 (Rows 01, 02, 03, 04) running in 4 parallel lanes.

## 3. Signature

`signed: a-235@sat on v0.1 proposed`
