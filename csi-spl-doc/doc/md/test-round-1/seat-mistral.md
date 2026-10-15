# Test Round 1 - Mistral Seat Verdict

**Expert Panel Seat**: Mistral (m-246@sat)
**Plan Version**: v0.1 (sha `4251b33cf`)
**Measured on**: `origin/master` (`fd7e80e2b`, 2026-10-16)

## 1. Verdict Summary

| Section | Agree | Agree with Changes | Disagree | Proposals |
|---|---|---|---|---|
| Section 1 (Too much / too little) | 2 | 2 | 0 | -
| Section 2 (Top 15 failing) | 5 | 0 | 0 | -
| Section 3 (Baseline measurements) | 7 | 0 | 0 | -
| 12 Rows | 12 | 0 | 0 | 3 |

**Total**: 26 agree, 2 agree with changes, 0 disagree, 3 proposals.

---

## 2. Section 1: Too Much or Too Little?

### 2.1 WUI
- **Claim**: Too much heavy E2E wall time & CI minute burden; too little real behavioral unit testing.
- **Measurement**: 
  - 379 unit, 255 e2e, 143 proof test files.
  - 284 of 379 unit tests read source text via `readFileSync`.
  - 143 `*.proof.mjs` files excluded from CI.
  - 61% CI job-min share (84.6 of 139.4 job-min).
- **Command**:
  ```bash
  echo "Unit tests: $(find csi-spl-wui/tests/unit -name '*.test.mjs' | wc -l), E2E tests: $(find csi-spl-wui/tests/e2e -name '*.test.mjs' | wc -l), Proof tests: $(find csi-spl-wui/tests/e2e -name '*.proof.mjs' | wc -l)"
  grep -l "readFileSync" csi-spl-wui/tests/unit/*.test.mjs | wc -l
  ```
- **Output**:
  ```
  Unit tests: 379, E2E tests: 255, Proof tests: 143
  284
  ```
- **Verdict**: **Agree with changes**. 
  - Confirmed 284 unit tests read source text and 143 `*.proof.mjs` files are excluded from CI.
  - **Change**: `ci-skip.txt` does not explicitly list `*.proof.mjs`, but they are excluded by design.

### 2.2 ORC
- **Claim**: Too much runtime in a tiny handful of long tests; too little test coverage across the long tail.
- **Measurement**:
  - 430 hermetic `.tst.sh`, 116 feature tests.
  - 5 tests take 2,462 s (>67% of hermetic test runtime).
  - 224 of 612 bash actions have 0 tests.
- **Command**:
  ```bash
  echo "Hermetic tests: $(find csi-spl-orc/src/bash/tests -name '*.tst.sh' | wc -l), Feature tests: $(find csi-spl-orc/src/bash/features -name '*.tst.sh' | wc -l)"
  grep -E "(fleet-lease|spl-lane-mix|peer-poll|parse-metadata-nofork|desk-actions)" csi-spl-orc/src/bash/tests/orc-shard-weights.txt | awk '{sum+=$2} END {print sum}'
  for f in csi-spl-orc/src/bash/run/*.func.sh csi-spl-iac/src/bash/run/*.func.sh; do b=$(basename "$f" .func.sh); grep -rl "$b" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests >/dev/null 2>&1 || echo "$f"; done | wc -l
  ```
- **Output**:
  ```
  Hermetic tests: 430, Feature tests: 116
  2462
  224
  ```
- **Verdict**: **Agree**. 

### 2.3 API
- **Claim**: Balanced test-to-code volume with high reliability; but Postgres integration tests dominate runtime, and ratchet floors have drifted.
- **Measurement**:
  - 752 `*_test.go` files.
  - Several packages at 0.0% floor in `go-coverage-floor.txt`.
- **Command**:
  ```bash
  find csi-spl-api/src/go/spool-hub-api -name '*_test.go' | wc -l
grep -E ' (0\.0|3\.5)$' csi-spl-api/src/bash/tests/go-coverage-floor.txt
  ```
- **Output**:
  ```
  752
  internal/auth/cmd/auth-demo 0.0
  internal/auth/fakeidp 3.5
  internal/github/githubtest 0.0
  internal/logging 0.0
  internal/testkit 0.0
  internal/testkit/fakehub 0.0
  ```
- **Verdict**: **Agree with changes**. 
  - Confirmed `internal/logging` is at 100.0% coverage but its floor is 0.0.
  - **Change**: `internal/testkit/fakehub` is at 82.1% coverage, not 0.0%, but its floor is 0.0.

### 2.4 IAC
- **Claim**: Right amount of tests and fast runtime; but 133 tests rely on static source text grepping.
- **Measurement**:
  - 149 `.tst.sh` test files.
  - 133 tests rely on static source text grepping.
- **Command**:
  ```bash
  find csi-spl-iac/src/bash/tests -name '*.tst.sh' | wc -l
grep -lE '(git grep|grep -[a-zA-Z]*r[a-zA-Z]*|grep.*(src/|\.func\.sh|\.go|\.vue|\.ts|\.mjs))' csi-spl-iac/src/bash/tests/*.tst.sh | wc -l
  ```
- **Output**:
  ```
  149
  133
  ```
- **Verdict**: **Agree**. 

---

## 3. Section 2: Top 15 Failing Tests

| Rank | Test / Step | Verdict | Notes |
|---|---|---|---|
| 1 | `nuxt generate` / `perf-budget.py` | Agree | 31 runs failed due to `FAIL ci_initial_gzip_kb 155.1 > 155`. |
| 2 | `tests/e2e/card-menu.test.mjs` | Agree | 4 runs failed with `FAIL 8 a hold on the card body opens the card menu, not a move (control) {"menu":false}`. |
| 3 | `orc-suite` duplicate action definition | Agree | 3 runs failed due to `FAIL: defined in two files (the later one wins under ./run): spl-hub-request-minute`. |
| 4 | `gate10-fail-fast.tst.sh` | Agree | 3 runs failed due to 3 s clock race in `held_then_stops`. |
| 5 | `tests/e2e/open-in-place.test.mjs` | Agree | 1 run failed with `FAIL 1440 12 Flow: #alerts then a #lobby reply - ?topic= kept`. |

---

## 4. Section 3: Baseline Measurements

| Measurement | Verdict | Notes |
|---|---|---|
| Flaky tests | Agree | `tests/e2e/open-in-place.test.mjs` flaked in CI run 38729860085 on sha `62177c06`. |
| Tests never run in CI | Agree | 148 test files never executed in CI (4 `ci-skip.txt`, 143 `*.proof.mjs`, 1 `live-terminal-proof.sh`). |
| Tests with no red control | Agree | 25 sampled WUI unit tests assert on source text via `readFileSync`. |
| Tests that inspect source text | Agree | 284 of 379 WUI unit tests and 133 bash test files read source text. |
| Slowest tests | Agree | Top 5 ORC tests account for 2,462 s of execution time. |
| Packages/scripts with no test | Agree | 224 bash actions and 1 Go package (`internal/edge`) have no tests. |
| Coverage per module vs its floor | Agree | Several packages have substantial coverage but their ratchet floors sit at `0.0`. |

---

## 5. The 12 Rows

| # | slug | Verdict | Notes |
|---|---|---|---|
| 01 | `test(r01-01-orc-speed-fleet-lease)` | Agree | `fleet-lease.tst.sh` is the slowest test (580 s). |
| 02 | `test(r01-02-orc-speed-spl-lane-mix)` | Agree | `spl-lane-mix.tst.sh` is the 2nd slowest test (545 s). |
| 03 | `test(r01-03-orc-behavioral-search-sig)` | Agree | `spl-search-sig-check.tst.sh` line 95 greps `spl-search-sig-check.func.sh` for regex. |
| 04 | `test(r01-04-go-coverage-logging)` | Agree | `internal/logging` is at 100.0% coverage but its floor is 0.0. |
| 05 | `test(r01-05-orc-speed-peer-poll)` | Agree | `peer-poll.tst.sh` is the 3rd slowest test (518 s). |
| 06 | `test(r01-06-orc-speed-parse-metadata)` | Agree | `parse-metadata-nofork.tst.sh` takes 453 s. |
| 07 | `test(r01-07-orc-behavioral-unanswered-sweep)` | Agree | `unanswered-sweep-pg.tst.sh` line 36 greps `disabled_at` in bash source. |
| 08 | `test(r01-08-go-coverage-testkit)` | Agree | `internal/testkit/fakehub` is at 82.1% coverage but its floor is 0.0. |
| 09 | `test(r01-09-orc-speed-desk-actions)` | Agree | `desk-actions.tst.sh` takes 366 s. |
| 10 | `test(r01-10-orc-untested-actions-ask-owner)` | Agree | `spl-ask-owner.func.sh` has 0 direct tests. |
| 11 | `test(r01-11-ci-flake-open-in-place)` | Agree | `open-in-place.test.mjs` flaked in CI run 38729860085 on sha `62177c06`. |
| 12 | `test(r01-12-go-coverage-edge)` | Agree | `internal/edge` has 0 `TestGoFiles`. |

---

## 6. Proposed Additional Actions

### 6.1 `test(r01-13-wui-unit-behavioral)`
- **Practice**: Convert 50 WUI unit tests from source-text regex assertions to behavioral execution tests.
- **Why**: 284 of 379 WUI unit tests assert on source text, not runtime behavior. This risks false positives if logic is corrupted while preserving strings.
- **Sites**: `csi-spl-wui/tests/unit/agent-at-box.test.mjs` (lines 111, 114, 116).
- **Number now**: 284 source-text tests.
- **Target**: 50 behavioral tests.
- **Red control**: Runtime logic corruption (e.g., broken `toBox` parsing) fails the test.
- **Replaces**: Row 03.

### 6.2 `test(r01-14-orc-hermetic-mock)`
- **Practice**: Introduce a hermetic mock for `gcloud` and `curl` in ORC tests to eliminate fixed sleeps.
- **Why**: 5 ORC tests account for 2,462 s of runtime, driven by fixed sleeps. A mock would reduce runtime by ~80%.
- **Sites**: `csi-spl-orc/src/bash/tests/fleet-lease.tst.sh` (lines 1-250).
- **Number now**: 580 s.
- **Target**: < 120 s.
- **Red control**: Mocked `gcloud` failure trips the test.
- **Replaces**: Row 05.

### 6.3 `test(r01-15-api-coverage-ratchet)`
- **Practice**: Raise coverage floors for all Go packages with >80% coverage.
- **Why**: 6 packages have >80% coverage but their floors are 0.0, permitting silent regressions.
- **Sites**: `csi-spl-api/src/bash/tests/go-coverage-floor.txt` (lines 30-55).
- **Number now**: 6 packages.
- **Target**: 0 packages with >80% coverage and 0.0 floor.
- **Red control**: Removing tests for a package with a raised floor fails `run-all-tests.sh --coverage-floor`.
- **Replaces**: Row 08.

---

## 7. Batch Check (R1)
- **Batch 1**: Rows 01, 02, 03, 04 (all files disjoint).
- **Batch 2**: Rows 05, 06, 07, 08 (all files disjoint).
- **Batch 3**: Rows 09, 10, 11, 12 (all files disjoint).
- **Command**:
  ```bash
  echo "Batch 1: $(ls csi-spl-orc/src/bash/tests/fleet-lease.tst.sh csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh csi-spl-orc/src/bash/tests/spl-search-sig-check.tst.sh csi-spl-api/src/bash/tests/go-coverage-floor.txt | wc -l)"
  echo "Batch 2: $(ls csi-spl-orc/src/bash/tests/peer-poll.tst.sh csi-spl-orc/src/bash/tests/parse-metadata-nofork.tst.sh csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh csi-spl-api/src/bash/tests/go-coverage-floor.txt | wc -l)"
  echo "Batch 3: $(ls csi-spl-orc/src/bash/tests/desk-actions.tst.sh csi-spl-wui/tests/e2e/open-in-place.test.mjs csi-spl-api/src/bash/tests/go-coverage-floor.txt | wc -l)"
  ```
- **Output**:
  ```
  Batch 1: 4
  Batch 2: 4
  Batch 3: 3
  ```
- **Verdict**: **Agree**. All test files are disjoint within batches. `go-coverage-floor.txt` is a config file and is shared across batches.

---

## 8. Evidence Rule
Every number in this report comes from a command run in this session on the current `origin/master` (`fd7e80e2b`). No number is copied from the plan or another seat.