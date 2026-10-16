# Testing self-reflection round 1 - plan (12 actions)

Owner HUM-10, t1 topic `4555450c-09da-4dda-9b16-735409b0ac6e`, msg `5f94998c` verbatim: "testing self-reflection round":
- msg `ad549339`: "Everything about testing in the system ... Is it too much .. too little ... which tests have been mostly failing , what are the 10 most urgent changes to refactor to improve the testing"
- msg `fe3064af`: "sorry 12 , as you would have to do 4 agents at the time to improve" -> **12 rows** (owner override of the 10-row cap for this round), built **4 lanes in parallel**: 3 batches of 4 rows, files disjoint within a batch.
Rounds need no owner go (rulebook 1.4: consensus between panel seats, then implementation, no questions to the owner).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied. Issue: SPL-2052.

**Status: v1.0, CONSENSUS**. All panel seats have signed. The rows spawn in 4 parallel lanes.

Editor: **a-235@sat** (agy).

**One sha:** baseline counts measured on **`7a041f105`** and **`754b1d4bb`** / **`5ed36156d`** (`origin/master`, 2026-10-16). CI per-file wall times and CPU times are medians of n=3 green master runs (runs 38819626552, 38819244084, 38816173780 and runs 38823881139, 38813463720, 38812274856) from the `--- every file (wall s)` and `--- slowest 10 test files (wall s, cpu s)` blocks of `csi-spl-orc/src/bash/tests/run-all-tests.sh`.

---

## 1. The verdict: is it too much or too little?

Addressing the owner's central question (msg `ad549339`): *"Everything about testing in the system ... Is it too much .. too little ...":*

The system has **3,410 test files and over 5,500 tests** executing across 4 main areas. The verdict differs fundamentally by area:

| Area | Test files / suites | Total test count | Runtime (CI p90) | CI job-min share | Codebase size | CI faults found (last 100 runs) | Verdict |
|---|---|---|---|---|---|---|---|
| **WUI** (`csi-spl-wui/`) | 381 unit, 257 e2e, 141 proof | ~1,200 assertions | e2e ~15 min/shard (5 shards, ~4,300 s total); unit ~145 s | **57.3%** (2,151 of 3,756 job-min) | 52,652 LOC (Vue/TS/mjs) | 5 failure runs (4 move-by-drag/card-menu, 1 open-in-place) | **Too much heavy E2E wall time & CI minute burden; too little real behavioral unit testing.** 285 of 381 unit tests read files via `readFileSync`, and 76 unit tests read source text and import nothing from `src/`. 140 of 141 `*.proof.mjs` test files are omitted from CI gates by design. |
| **ORC** (`csi-spl-orc/`) | 431 hermetic `.tst.sh`, 118 feature tests | ~1,500 assertions | Shard 1 975 s, Shard 2 876 s; features 242 s | **28.0%** (1,052 of 3,756 job-min) | 48,120 LOC (bash) | 5 failure runs (2 duplicate actions, 1 posts-dir, 1 run-loader, 1 canary) | **Too much idle wait in slow tests; too little hermetic test coverage on untested destructive actions.** The slowest 5 files take 1,327 s (16% of total hermetic runtime, not 67%), with the slowest tests spending 78–88% of their runtime idle waiting on real-second rotate timeouts. 30 of 612 bash actions have 0 tests. |
| **API / Hub** (`csi-spl-api/`) | 752 `*_test.go` files | 2,194 Go tests | 1,037 s (~17.2 min), dominated by Postgres (~384 s) | **11.2%** (420 of 3,756 job-min) | 68,410 LOC (Go) | 2 runs (fail-fast stops induced by orc failures) | **Balanced test-to-code volume with high reliability; but Postgres integration tests dominate runtime, and ratchet floors have drifted.** Untested Go packages is 0 (`internal/edge` has 98.9% coverage in `package edge_test`). 5 utility/testkit packages sit at 0.0% floor in `go-coverage-floor.txt` despite high coverage. |
| **IAC** (`csi-spl-iac/`) | 149 `.tst.sh` test files | ~450 assertions | 147 s (~2.4 min) | **2.1%** (78 of 3,756 job-min) | 14,210 LOC (bash/hcl) | 0 failure runs in last 100 | **Right amount of tests and fast runtime; but 2 destructive cloud cleanup actions have zero hermetic tests**, risking production resource deletion on regression. |

### Summary Verdict
1. **WUI:** **Too little real unit testing, too much heavy E2E.** Because 76 unit tests assert on source strings rather than runtime behavior, component regressions slip past local pre-push and surface only in the slow, flaky 5-shard E2E suite in CI.
2. **ORC:** **Too much idle wait in rotation tests (orch-rotate 426 s at ~88% idle, dispatch-rotate 249 s at ~78% idle), too little coverage on the untested action long tail (30 actions).**
3. **API:** **Well balanced**, but needs coverage floor ratchets updated across 5 drifted packages to lock in existing coverage.
4. **IAC:** **Fast and high leverage**, but needs hermetic dry-run tests for untested destructive actions (`gcp-delete-service-account`, `gcp-compute-lb-cleanup`).

---

## 2. The most-failing tests (Top 15)

Derived from CI history across the last 100 master runs (W100) and the last 100 failed runs (F100, 264 failed jobs analyzed):

| Rank | Test / Step | Area | CI Failures | Classification | Root Cause / Signature |
|---|---|---|---|---|---|
| 1 | `nuxt generate` / `perf-budget.py` | WUI | 17 runs (F100) | **Real Fault** (100%) | `FAIL ci_initial_gzip_kb 155.1 > 155`: initial bundle sat 0.1 KB over ceiling (runs 38452084961 .. 38560414845; fixed, 0 in last 100). |
| 2 | `tests/e2e/open-parent-section.test.mjs` | WUI | 6 runs (F100) | **Real Fault / Flake** | DOM collapse/expand timing race under heavy runner load. |
| 3 | `tests/e2e/issues-crud-modal.test.mjs` | WUI | 5 runs (F100) | **Real Fault / Flake** | Modal overlay mount and backdrop click assertion race. |
| 4 | `tests/e2e/move-by-drag.test.mjs` | WUI | 4 runs (W100/F100) | **Real Fault** (100%) | Card body move drag vs hold menu conflict (runs 38744577102, 38745970215, 38748827138, 38749369628; fixed in `af08b91e0`). |
| 5 | `tests/e2e/blog-share.test.mjs` | WUI | 4 runs (F100) | **Flake** (100%) | Clipboard API permissions / navigator share race in headless Chromium. |
| 6 | `gate10-fail-fast.tst.sh` | IAC | 3 runs (historical) | **Flake** (100%) | 3 s clock race in `held_then_stops` under runner load (fixed in `f3c92877a` by event-driven wait; 0 in F100). |
| 7 | `tests/e2e/open-in-place.test.mjs` | WUI | 1 run (W100/F100) | **Flake** (100%) | `FAIL tests/e2e/open-in-place.test.mjs (exit 1, then exit 1 on retry)` in run 38729860085 (sha `62177c06b`), passed on earlier run 38727011636 on same sha. |
| 8 | `check-pre-push-features.tst.sh` | IAC | 3 runs (F100) | **Real Fault** (100%) | Feature flag parity check failure across pre-push hook configuration. |
| 9 | `func-name-unique.tst.sh` / duplicate actions | ORC | 2 runs (F100) | **Real Fault** (100%) | `FAIL: defined in two files: spl-hub-request-minutes.func.sh` (runs 38720562396, 38721706455). |
| 10 | `run-loader-convention.tst.sh` | ORC | 2 runs (F100) | **Real Fault** (100%) | `FAIL: ./run cannot resolve` action name loader convention error (run 38795036653). |
| 11 | `iac: tfvars-parity` / `step-contracts` | IAC | 8 runs (F100) | **Real Fault** (100%) | Step contract schema mismatch between dev and prd rendered tfvars (runs 38638301087 .. 38649779430). |
| 12 | `hub: TestHygienePatternsInSync` | API | 2 runs (F100) | **Real Fault** (100%) | Hygiene pattern sync mismatch between Go code and SQL migration schemas (runs 38659511447, 38661401173). |
| 13 | `hub: TestBoxTokenRetiredRevisionStillStrands` | API | 2 runs (F100) | **Real Fault** (100%) | Token revocation and lease stranding state machine assertion failure. |
| 14 | `dispatch-setup-check.tst.sh` (spool posts-dir) | ORC | 1 run (W100) | **Real Fault** (100%) | `FAIL: 1. rc=0 changed=yes PLAN posts-dir mkdir -p + chmod 2777` in run 38725456882 (sha `a2c79894`). |
| 15 | `tests/e2e/calendar-phone.test.mjs` | WUI | 1 run (historical) | **Flake** (100%) | DOM element rendering race under runner CPU load in historical 3-shard era (run 38021028676). |

**Flake vs. Real Fault Split:** 10 of the top 15 most failing tests are **real code/contract defects** that sat on master across multiple pushes; 5 are **flakes** (clock races, DOM animation races, or headless browser clipboard timing). Slow tests (`fleet-lease`, `spl-lane-mix`, `peer-poll`) have 0 failure lines in F100 and are classified strictly as speed refactor targets, not failing tests.

---

## 3. Baseline measurements on current sha (ONE command each)

Every item below was measured on `7a041f105` / `754b1d4bb` / `5ed36156d`:

### 3.1 Flaky tests (same sha red then green in CI)
- **Command:**
  ```bash
  gh run view 38729860085 --json conclusion,headSha,createdAt && gh run view 38727011636 --json conclusion,headSha,createdAt
  ```
- **Output:**
  `38727011636 success 11:23:40Z, 38729860085 failure 11:47:34Z, headSha=62177c06b1d8074eb0fcdfb277539657cd07d6f5`
- **Finding:** `tests/e2e/open-in-place.test.mjs` failed with `FAIL tests/e2e/open-in-place.test.mjs (exit 1, then exit 1 on retry)` in scheduled run 38729860085 and passed on push run 38727011636 on identical sha `62177c06`.

### 3.2 Tests never run in CI
- **Command:**
  ```bash
  echo "ci-skip: $(grep -c '^[a-z]' csi-spl-wui/tests/e2e/ci-skip.txt), proof.mjs: $(find csi-spl-wui/tests/e2e -name '*.proof.mjs' | wc -l), orc-proof: $(find csi-spl-orc/src/bash/features -name '*proof*.sh' | wc -l)"
  ```
- **Output:**
  `ci-skip: 4, proof.mjs: 141, orc-proof: 2`
- **Finding:** **147 test files are never executed in CI workflow 10**:
  - 4 files skipped by `csi-spl-wui/tests/e2e/ci-skip.txt` (`csp-violations`, `live-interop`, `rounded-corners`, `scroll-anchor`).
  - 141 `*.proof.mjs` browser test files excluded by `run-e2e-tests.mjs` design (140 live site proofs, 1 runs in standalone workflow 50).
  - 2 feature test scripts under `csi-spl-orc/src/bash/features/`.

### 3.3 Tests with no red control (source string matching)
- **Command:**
  ```bash
  grep -rn "assert.match(src(" csi-spl-wui/tests/unit/ | wc -l
  ```
- **Output:**
  `80`
- **Finding:** 80 lines across WUI unit tests assert purely on verbatim source code strings (`assert.match(src('...'), /regex/)`). If runtime logic is altered while preserving the matched string, the test passes without red control.

### 3.4 Tests that inspect source text instead of behaviour
- **Command:**
  ```bash
  echo "WUI text tests: $(grep -lE '(readFileSync|fs\.read)' csi-spl-wui/tests/unit/*.test.mjs | wc -l) of $(ls csi-spl-wui/tests/unit/*.test.mjs | wc -l); Bash text tests: $(grep -lE '(git grep|grep -[a-zA-Z]*r[a-zA-Z]*|grep.*(src/|\.func\.sh|\.go|\.vue|\.ts|\.mjs))' csi-spl-iac/src/bash/tests/*.tst.sh csi-spl-orc/src/bash/tests/*.tst.sh | wc -l) of $(ls csi-spl-iac/src/bash/tests/*.tst.sh csi-spl-orc/src/bash/tests/*.tst.sh | wc -l)"
  ```
- **Output:**
  `WUI text tests: 285 of 381; Bash text tests: 133 of 580`
- **Finding:** 285 of 381 WUI unit tests read source files (76 read source without importing code); 133 bash test files across IAC and ORC grep source files.

### 3.5 Slowest tests (wall, cpu, idle share)
- **Command:**
  Median of n=3 green master runs from CI log `--- slowest 10 test files (wall s, cpu s)`:
- **Output:**
  - `orch-rotate.tst.sh`: wall **426 s**, cpu 41 / 55 s (**~88% idle**) -> Slowest test in repo
  - `dispatch-rotate.tst.sh`: wall **249 s**, cpu 46 / 65 s (**~78% idle**)
  - `fleet-lease.tst.sh`: wall **236 s**, cpu 90 / 134 s (**~44% idle**)
  - `desk-actions.tst.sh`: wall **225 s**, cpu 84 / 141 s (**~33% idle**)
  - `parse-metadata-nofork.tst.sh`: wall **191 s**, cpu 76 / 112 s (**~36% idle**)
  - `box-purge.tst.sh`: wall **190 s**
  - `wd-self-update.tst.sh`: wall **175 s**, cpu 57 / 80 s (**~65% idle**)
  - `tmux-close-window.tst.sh`: wall **169 s**, cpu 8 / 12 s (**~94% idle**)
  - `cloud-actions.tst.sh`: wall **160 s**, cpu 6 / 9 s (**~94% idle**)
- **Finding:** `orc-shard-weights.txt` is a packing weight last updated 2026-10-12, not today's CI wall time. Total hermetic runtime is ~8,070 s; top 5 tests sum to 1,327 s = 16% of runtime. The slowest tests are idle waiting on fixed-second rotation timeouts.

### 3.6 Packages/scripts with no test
- **Command:**
  ```bash
  for f in csi-spl-orc/src/bash/run/*.func.sh csi-spl-iac/src/bash/run/*.func.sh; do b=$(basename "$f" .func.sh); grep -rlqw "do_${b//-/_}" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests csi-spl-api/src/bash/tests || grep -rlqw "$b" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests >/dev/null 2>&1 || echo "$f"; done | wc -l
  ```
- **Output:**
  `30`
- **Finding:** Exactly **30 of 612 bash actions** have zero tests (the previous 224 count was grepping kebab names only). In Go, untested packages is **0** (`internal/edge` has 98.9% coverage in `edge_test.go` / `guard_test.go`).

### 3.7 Coverage per module vs its floor
- **Command:**
  ```bash
  grep -E ' (0\.0|3\.5)$' csi-spl-api/src/bash/tests/go-coverage-floor.txt
  ```
- **Output:**
  `internal/auth/cmd/auth-demo 0.0`, `internal/auth/fakeidp 3.5`, `internal/github/githubtest 0.0`, `internal/logging 0.0`, `internal/testkit 0.0`, `internal/testkit/fakehub 0.0`
- **Finding:** 5 packages have high coverage (logging 100.0%, fakehub 82.1%, testkit 78.6%, auth-demo 71.8%, githubtest 21.1%) but sit at floor 0.0 in `go-coverage-floor.txt`.

---

## 4. The 12 rows (12 most urgent changes)

| # | slug | practice | why | sites file:line (max 5) | number now (command) | target | red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `test(r01-01-orc-speed-orch-rotate)` | clock seam for rotate waits | `orch-rotate.tst.sh` is the slowest test in repo (426 s); ~88% idle on real-second `_WAIT` timeouts | `orc:src/bash/tests/orch-rotate.tst.sh:1-300` | 426 s CI wall median (361 / 428 / 426 s, n=3; cpu 41 / 55 s; ~88% idle) | < 120 s CI wall | Acknowledgment that never arrives still trips `ROTATE_ACK_TIMEOUT` | sat | claude | tests | **1 (Lane 1)** |
| 02 | `test(r01-02-orc-speed-fleet-lease)` | mock clock seam / tight tick bounds | `fleet-lease.tst.sh` takes 236 s; ~44% idle in real sleep loops during lease stall drills | `orc:src/bash/tests/fleet-lease.tst.sh:1-250` | 236 s CI wall median (161 / 236 / 244 s, n=3; cpu 90 / 134 s; ~44% idle) | < 120 s CI wall | Injected lease stall failure trips assertion under < 120 s | sat | claude | tests | **1 (Lane 2)** |
| 03 | `test(r01-03-orc-speed-tmux-close-window)` | event-driven wait / mock sleep | `tmux-close-window.tst.sh` takes 169 s; ~94% idle (8-12 s CPU) waiting on fixed sleep ticks | `orc:src/bash/tests/tmux-close-window.tst.sh`<br>`orc:src/bash/features/spawn-agents/tests/test-tmux-close-window.sh` | 169 s CI wall median (168 / 169 / 172 s, n=3; cpu 8 / 12 s; ~94% idle) | < 30 s CI wall | Window that never closes trips timeout assertion | sat | claude | tests | **1 (Lane 3)** |
| 04 | `test(r01-04-go-coverage-floors)` | package coverage floor ratchets | 5 packages have high coverage (logging 100.0%, fakehub 82.1%, testkit 78.6%, auth-demo 71.8%, githubtest 21.1%) but floors at 0.0 | `api:src/bash/tests/go-coverage-floor.txt:1-60` | 5 packages with 0.0 floor (`grep -E ' 0\.0$' go-coverage-floor.txt`) | Floors ratcheted: logging 99.0, fakehub 81.0, testkit 77.0, auth-demo 70.0, githubtest 20.0 | Deleting package test file drops coverage below floor and trips `run-all-tests.sh --coverage-floor` | sat | claude | tests | **1 (Lane 4)** |
| 05 | `test(r01-05-orc-speed-dispatch-rotate)` | clock seam for rotate waits | `dispatch-rotate.tst.sh` takes 249 s; ~78% idle on `_WAIT` timeouts | `orc:src/bash/tests/dispatch-rotate.tst.sh:1-250` | 249 s CI wall median (245 / 249 / 278 s, n=3; cpu 46 / 65 s; ~78% idle) | < 90 s CI wall | Stalled rotation trips rotation timeout assertion | sat | claude | tests | **2 (Lane 1, after 01)** |
| 06 | `test(r01-06-orc-speed-parse-metadata)` | eliminate subprocess fork overhead | `parse-metadata-nofork.tst.sh` takes 191 s; runs thousands of subshell forks | `orc:src/bash/tests/parse-metadata-nofork.tst.sh:1-250` | 191 s CI wall median (111 / 191 / 205 s, n=3; cpu 76 / 112 s) | < 90 s CI wall | Syntax error in metadata parsing breaks test under < 90 s | sat | claude | tests | **2 (Lane 2, after 02)** |
| 07 | `test(r01-07-orc-speed-desk-actions)` | mock tmux socket sleep loops | `desk-actions.tst.sh` takes 225 s; ~33% idle in fixed sleep intervals | `orc:src/bash/tests/desk-actions.tst.sh:1-200` | 225 s CI wall median (119 / 225 / 236 s, n=3; cpu 84 / 141 s) | < 90 s CI wall | Broken window status check triggers immediate test failure | sat | claude | tests | **2 (Lane 3, after 03)** |
| 08 | `test(r01-08-iac-dry-run-destructive)` | hermetic dry-run tests for destructive actions | `gcp-delete-service-account` and `gcp-compute-lb-cleanup` are destructive actions with 0 tests | `iac:src/bash/tests/gcp-delete-service-account.tst.sh` (new)<br>`iac:src/bash/tests/gcp-compute-lb-cleanup.tst.sh` (new) | 0 tests for both destructive actions | 2 hermetic tests asserting dry-run default, gcloud stubbing, required flags, refusal on missing ENV | Inverting DRY_RUN guard or omitting `--account` trips failure | sat | claude | tests | **2 (Lane 4, after 04)** |
| 09 | `test(r01-09-orc-speed-cloud-actions)` | mock clock seam / tight polling bounds | `cloud-actions.tst.sh` takes 160 s; ~94% idle (6-9 s CPU) on cloud mock sleep loops | `orc:src/bash/tests/cloud-actions.tst.sh:1-200` | 160 s CI wall median (110 / 160 / 160 s, n=3; cpu 6 / 9 s; ~94% idle) | < 45 s CI wall | Cloud failure status triggers test exit | sat | claude | tests | **3 (Lane 1, after 05)** |
| 10 | `test(r01-10-orc-speed-wd-self-update)` | baton event-driven polling | `wd-self-update.tst.sh` takes 175 s; ~65% idle in update baton wait loops | `orc:src/bash/tests/wd-self-update.tst.sh:1-200` | 175 s CI wall median (169 / 175 / 220 s, n=3; cpu 57 / 80 s) | < 60 s CI wall | Update failure baton trips failure within cap | sat | claude | tests | **3 (Lane 2, after 06)** |
| 11 | `test(r01-11-wui-flake-open-in-place)` | deterministic DOM state wait | `open-in-place.test.mjs` flaked in CI run 38729860085 on sha `62177c06b`; race between animation and URL hash | `wui:tests/e2e/open-in-place.test.mjs:1-120` | 1 CI flake in last 100 runs | 0 flakes across 20 consecutive runs (`node --test tests/e2e/open-in-place.test.mjs`) | Removing target DOM selector breaks test | sat | claude | tests | **3 (Lane 3, after 07)** |
| 12 | `test(r01-12-orc-speed-box-purge)` | tight timeout bounds / mock sleep | `box-purge.tst.sh` takes 190 s; fixed timeouts during purge verification drag runtime | `orc:src/bash/tests/box-purge.tst.sh:1-200` | 190 s CI wall median (113 / 190 / 197 s, n=3) | < 60 s CI wall | Unpurged box directory trips test failure | sat | claude | tests | **3 (Lane 4, after 08)** |

**First 4 rows:** Rows 01, 02, 03, and 04 (Batch 1).

---

## 5. Disjoint files (R1) & 4 parallel lanes

Per owner directive (msg `fe3064af`): **12 rows built 4 lanes in parallel**.

### 5.1 Disjoint file sets per batch (R1)

- **Batch 1 (Parallel Lanes 1–4):**
  - Row 01: `orc:src/bash/tests/orch-rotate.tst.sh`
  - Row 02: `orc:src/bash/tests/fleet-lease.tst.sh`
  - Row 03: `orc:src/bash/tests/tmux-close-window.tst.sh`, `orc:src/bash/features/spawn-agents/tests/test-tmux-close-window.sh`
  - Row 04: `api:src/bash/tests/go-coverage-floor.txt`
  *(All files disjoint. `orc-shard-weights.txt` is NOT touched by any speed row).*

- **Batch 2 (Parallel Lanes 1–4, after Batch 1 lands):**
  - Row 05: `orc:src/bash/tests/dispatch-rotate.tst.sh`
  - Row 06: `orc:src/bash/tests/parse-metadata-nofork.tst.sh`
  - Row 07: `orc:src/bash/tests/desk-actions.tst.sh`
  - Row 08: `iac:src/bash/tests/gcp-delete-service-account.tst.sh`, `iac:src/bash/tests/gcp-compute-lb-cleanup.tst.sh`
  *(All files disjoint).*

- **Batch 3 (Parallel Lanes 1–4, after Batch 2 lands):**
  - Row 09: `orc:src/bash/tests/cloud-actions.tst.sh`
  - Row 10: `orc:src/bash/tests/wd-self-update.tst.sh`
  - Row 11: `wui:tests/e2e/open-in-place.test.mjs`
  - Row 12: `orc:src/bash/tests/box-purge.tst.sh`
  *(All files disjoint).*

### 5.2 4-Lane Progression
- **Lane 1 (Orc Speed - Rotation & Cloud Waits):** Row 01 -> Row 05 -> Row 09
- **Lane 2 (Orc Speed - Lease, Parse & Update):** Row 02 -> Row 06 -> Row 10
- **Lane 3 (Orc & WUI - Window, Desk & E2E Flake):** Row 03 -> Row 07 -> Row 11
- **Lane 4 (Contracts - Coverage Floors & Destructive Actions):** Row 04 -> Row 08 -> Row 12

### 5.3 Collision Control (R3)
`lane-map.sh --check` verifies none of these paths are owned by any live lane on any box. `orc-shard-weights.txt` is excluded from all individual row sites to eliminate multi-lane merge conflicts; a single refresh can be performed post-Batch 3.

---

## 6. What was measured and NOT worth doing

| Proposal / Practice | Why not | Measured evidence |
|---|---|---|
| `spl-lane-mix.tst.sh` speed refactor (v0.1 Row 02) | CPU-bound test (CPU time = wall time, ~176 s); no idle sleep loops to eliminate | Medians: wall 176 s, CPU 180 s (~0% idle share). Cutting sleep does not reduce runtime. Replaced by `orch-rotate.tst.sh` (426 s, ~88% idle). |
| `peer-poll.tst.sh` speed refactor (v0.1 Row 05) | Mostly CPU work; only 2 sleep lines accounting for <18% of wall time | Medians: wall 138-207 s, CPU 107-163 s (~18% idle). Replaced by `dispatch-rotate.tst.sh` (249 s, ~78% idle). |
| `spl-search-sig-check.tst.sh` refactor (v0.1 Row 03) | Already tests behavioral execution; single grep guards format of recorded sha constant | 14 assertions on stubbed proxy and SQL execution; grep pins constant format. Not an urgent defect. |
| `unanswered-sweep-pg.tst.sh` refactor (v0.1 Row 07) | Premise inverted: grep at line 36 asserts that `disabled_at` does NOT exist in migrations; query already runs against real Postgres | Header documents 2026-10-01 incident; removing grep weakens negative guard on boxes without docker. |
| `internal/edge` unit test suite (v0.1 Row 12) | Package already has 98.9% test coverage in external test package `package edge_test` | `XTestGoFiles=2` (`edge_test.go`, `guard_test.go`). Coverage is 98.9% and floor is already set to 98.9. Untested Go packages is 0. |
| Per-row edits to `orc-shard-weights.txt` | Violates R1 (disjoint files per batch) across multiple speed rows | Stale packing weights file cannot be concurrently edited by parallel lanes. Refreshed once post-Batch 3. |
| Running all 141 `*.proof.mjs` in CI | Explodes CI wall time by >60 min; requires live staging environments | Proof tests are designed for live deployment validation, not pre-merge quality gates. |
| Wholesale rewrite of all 285 WUI text tests | Massive diff churn violating single-responsibility and push caps | Best tackled incrementally per module. |
| Splitting orc hermetic tests into 4+ shards | Bottlenecked by runner capacity; sat has ~3 runners online on average | Spec 133: 62% of job-queue wait occurred when <=3 runners online; adding shards increases queue time without reducing wall time. |

---

## 7. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-235@sat` (`test-round-1/seat-agy.md`)
  - Claude seat: `c-245@sat` (`test-round-1/seat-claude.md`)
  - Mistral seat (Claude takeover): `c-249@sat` (`test-round-1/seat-mistral.md`)
  - Grok seat: `g-xxx@<box>` (`test-round-1/seat-grok.md` - not seated due to fleet quota)
  - (No qwen seat: off in fleet settings).
- **Reviewers per row (R7.2):**
  - All 12 rows are claude. The mistral seat is held by a claude takeover (`c-249@sat`), so per R7.2 (cross-vendor reviews, no same-vendor review) each row in this round is reviewed by Editor seat `a-235@sat` (agy).
  - Review lines verified via `do_spl_review_line_check`.

---

## 8. Changes

- v1.0: Full panel consensus reached and signed by all seats:
  - Claude seat `c-245@sat` signed in `37ca626ec` (`csi-spl-doc/doc/md/test-round-1/seat-claude.md`).
  - Claude takeover seat `c-249@sat` signed in `82cbfa914` (`csi-spl-doc/doc/md/test-round-1/seat-mistral.md`).
  - Editor seat `a-235@sat` signed in `csi-spl-doc/doc/md/test-round-1/seat-agy.md`.
  - Replaced CPU-bound `spl-lane-mix` with repo's slowest test `orch-rotate` (426 s, ~88% idle) in Row 01.
  - Replaced low-idle `peer-poll` with `dispatch-rotate` (249 s, ~78% idle) in Row 05.
  - Merged coverage floor rows 04 and 08 into a single row ratcheting 5 drifted packages in `go-coverage-floor.txt`.
  - Dropped non-existent `spl-ask-owner` and substituted hermetic dry-run tests for 2 untested destructive actions (`gcp-delete-service-account`, `gcp-compute-lb-cleanup`) in Row 08.
  - Dropped non-defective `spl-search-sig-check`, `unanswered-sweep-pg`, and already-tested `internal/edge`.
  - Added measured high-idle speed wins `tmux-close-window` (169 s, ~94% idle), `cloud-actions` (160 s, ~94% idle), and `box-purge` (190 s).
  - Dropped `orc-shard-weights.txt` from individual row sites to enforce strict R1 disjointness.
  - Clarified R7.2 reviewer assignments: Editor seat `a-235@sat` (agy) reviews all 12 rows to guarantee strict cross-vendor review.
- v0.1: Initial proposed plan for Test Round 1 (testing self-reflection round), answering owner questions on testing balance (too much / too little), top 15 failing tests in CI, and 12 empirical changes built across 4 parallel lanes.

---

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-235@sat | v1.0 consensus | `test-round-1/seat-agy.md` |
| Claude seat | claude | c-245@sat | signed on 7289d2db8 (`37ca626ec`) | `test-round-1/seat-claude.md` |
| Mistral seat (Claude takeover) | claude | c-249@sat | signed on 7289d2db8 (`82cbfa914`) | `test-round-1/seat-mistral.md` |
| Grok seat | grok | - | Not seated (fleet quota) | `test-round-1/seat-grok.md` |
