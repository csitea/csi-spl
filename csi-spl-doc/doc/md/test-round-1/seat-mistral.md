# Test Round 1 Mistral Seat Verdict

Measured on `4251b33cf` (`origin/master`, 2026-10-15 20:42Z).

## Status

Pending review of v0.1 plan (`test-round-1-plan.md`).

| Row | Slug | Practice | Verdict | Command | Output |
|-----|------|-----------|-----------|---------|---------|
| 01 | `test(r01-test-orc-speed-fleet-lease)` | mock clock seam / tight tick bounds | Pending | `grep "fleet-lease.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` | `fleet-lease.tst.sh 580` |
| 02 | `test(r01-test-orc-speed-spl-lane-mix)` | reduce synthetic rounds / mock loops | Pending | `grep "spl-lane-mix.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` | `spl-lane-mix.tst.sh 545` |
| 03 | `test(r01-test-orc-behavioral-search-sig)` | test behavioral execution not source grep | Pending | `git grep -c "grep -qE" csi-spl-orc/src/bash/tests/spl-search-sig-check.tst.sh` | `1` |
| 04 | `test(r01-test-go-coverage-logging)` | package coverage floor ratchet | Pending | `grep "internal/logging" csi-spl-api/src/bash/tests/go-coverage-floor.txt` | `internal/logging 0.0` |
| 05 | `test(r01-test-orc-speed-peer-poll)` | event-driven wait / mock sleep | Pending | `grep "peer-poll.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` | `peer-poll.tst.sh 518` |
| 06 | `test(r01-test-orc-speed-parse-metadata)` | eliminate subprocess fork overhead | Pending | `grep "parse-metadata-nofork.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` | `parse-metadata-nofork.tst.sh 453` |
| 07 | `test(r01-test-orc-behavioral-unanswered-sweep)` | query execution test not source grep | Pending | `grep -c "disabled_at" csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` | `1` |
| 08 | `test(r01-test-go-coverage-testkit)` | unit tests and floor ratchet | Pending | `grep "internal/testkit" csi-spl-api/src/bash/tests/go-coverage-floor.txt` | `internal/testkit 0.0` |
| 09 | `test(r01-test-orc-speed-desk-actions)` | mock tmux socket sleep loops | Pending | `grep "desk-actions.tst.sh" csi-spl-orc/src/bash/tests/orc-shard-weights.txt` | `desk-actions.tst.sh 366` |
| 10 | `test(r01-test-orc-untested-actions-ask-owner)` | hermetic test for untested action | Pending | `grep -rn "do_spl_ask_owner" csi-spl-orc/src/bash/tests/ \| wc -l` | `0` |
| 11 | `test(r01-test-ci-flake-open-in-place)` | deterministic DOM state wait | Pending | CI run 38729860085 log | `FAIL 1440 12 Flow: #alerts then a #lobby reply` |
| 12 | `test(r01-test-go-coverage-edge)` | unit test suite for edge package | Pending | `go list -f '{{if not .TestGoFiles}}{{.ImportPath}}{{end}}' ./...` | `github.com/csitea/csi-spl/spool-hub-api/internal/edge` |
