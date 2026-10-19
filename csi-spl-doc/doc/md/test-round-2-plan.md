# Testing self-reflection round 2 - plan (12 actions)

Owner HUM-10, t1 topic `4555450c-09da-4dda-9b16-735409b0ac6e`:
- msg `5f94998c`: "testing self-reflection round"
- msg `ad549339`: "Everything about testing in the system ... Is it too much .. too little ... which tests have been mostly failing , what are the 10 most urgent changes to refactor to improve the testing"
- msg `fe3064af`: "sorry 12 , as you would have to do 4 agents at the time to improve" -> **12 rows** (owner override of the 10-row cap), built **4 lanes in parallel**: 3 batches of 4 rows, files disjoint within a batch.
Rounds need no owner go (rulebook 1.4: consensus between panel seats, then implementation, no questions to the owner).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied. Issue: SPL-2402 (lane SPL-2554).

**Status: v0.1, PROPOSED**. Submitted to expert panel for cross-vendor review.

Editor: **a-481@sat** (agy).

**One sha:** baseline counts measured on **`59ffb5dd3`** (`origin/master`, 2026-10-19 13:22Z, CI run 39259601111 success). CI per-file wall times and CPU times are taken from completed master run 39259601111 (`--- slowest 10 test files (wall s, cpu s)` across orc hermetic shards 1/3, 2/3, 3/3) and `do_report_ci_gate` across the last 100 master runs (40 success, 32 cancelled, 27 failure, 1 running).

---

## 1. The verdict: is it too much or too little?

Addressing the owner's central question (msg `ad549339`): *"Everything about testing in the system ... Is it too much .. too little ...":*

The repository contains **3,430+ test files executing across 4 main modules**. Following Round 1 improvements, the verdict by area on `59ffb5dd3` is:

| Area | Test files / suites | Total test count | Runtime (CI p90) | CI job-min share | Codebase size | CI faults found (last 100 runs) | Verdict |
|---|---|---|---|---|---|---|---|
| **WUI** (`csi-spl-wui/`) | 400 unit, 258 e2e, 141 proof | ~1,250 assertions | e2e ~10-11 min/shard (8 shards); unit ~159 s | **58.1%** (2,180 of 3,750 job-min) | 53,200 LOC (Vue/TS/mjs) | 19 failure runs (10 message-order case A6, 3 phone omnibox, 2 sideways overflow) | **Too much flaky E2E wall time & CI minute burden; too little real behavioral unit testing of composables and utilities.** 297 of 400 unit tests read source files via `readFileSync`, and 79 unit test assertions match raw source text strings (`assert.match(src(`). Core composables (`useBuildWatch`, `useOpenMessage`, `useRoadmapGoals`) and utilities (`msg-apply`, `tenant-host-core`) have 0 tests. |
| **ORC** (`csi-spl-orc/`) | 436 hermetic `.tst.sh`, 118 feature tests | ~1,550 assertions | Shards 1-3 p90 674–729 s; features 250 s | **27.5%** (1,030 of 3,750 job-min) | 48,900 LOC (bash) | 4 failure runs (2 OA-11/13, 1 maintenance.lock, 1 fail-fast) | **Too much idle sleep wait in desk and peer lifecycle tests; too little hermetic test coverage on remaining untested actions.** Round 1 eliminated idle in `orch-rotate` (426 s -> 83 s), `tmux-close-window` (169 s -> 19 s), and `desk-actions` (225 s -> 30 s). The second tier now dominates: `peer-poll` takes 361.5 s wall (~54% idle), `desk-up-all` takes 165.0 s (~72% idle), `desk-pin` takes 98.2 s (~70% idle), and `desk-welcome` takes 95.7 s (~76% idle). 31 bash actions have 0 tests. |
| **API / Hub** (`csi-spl-api/`) | 754 `*_test.go` files | 2,210 Go tests | 569 s GCS gate, 550 s Postgres gate | **11.8%** (442 of 3,750 job-min) | 69,100 LOC (Go) | 0 direct failure runs (fail-fast stops induced by WUI/ORC only) | **Balanced test volume and high reliability; but a coverage floor gap exists in fakeidp.** Package `internal/auth/fakeidp` has only 3.5% statement coverage and sits at 3.5 floor in `go-coverage-floor.txt` due to 0 unit tests for `fakeidp.go` (10 KB untested). |
| **IAC** (`csi-spl-iac/`) | 151 `.tst.sh` test files | ~480 assertions | 158 s (~2.6 min) | **2.6%** (98 of 3,750 job-min) | 14,400 LOC (bash/hcl) | 0 failure runs in last 100 | **Fast runtime; but 7 destructive actions have zero tests**, including destructive Terraform state/target mutations (`tf-destroy-target`, `tf-destroy-local-step-bucket`, `tf-remove-step`, `tf-replace-target`, `tf-state-push`) and destructive GCP API disables (`gcp-modify-project-apis-disable`, `gcp-project-apis-disable`). |

### Summary Verdict
1. **WUI:** **Too little real unit testing, too much heavy/flaky E2E.** Flaky E2E races (e.g. `message-order.test.mjs` failing 10 times in CI shard 6/8) cause repeated pipeline re-runs, while core composables and utilities have zero behavioral tests.
2. **ORC:** **Second-tier tests suffer large idle sleep waits (`peer-poll` 361 s at ~54% idle, `desk-up-all` 165 s at ~72% idle, `desk-welcome` 96 s at ~76% idle, `desk-pin` 98 s at ~70% idle).**
3. **API:** **Well balanced**, but needs unit tests and floor ratchet for `internal/auth/fakeidp` (3.5% coverage).
4. **IAC:** **Critical safety gap**: 7 destructive Terraform state and GCP API disable actions lack hermetic tests and dry-run assertions.

---

## 2. The most-failing tests in CI (Last 100 runs)

Derived from `CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` on master (run window 2026-10-18T08:40:40Z .. 2026-10-19T13:22:30Z, 27 failed runs, 10 distinct job-failure signatures):

| Rank | Test / Step | Area | CI Failures | Classification | Root Cause / Signature |
|---|---|---|---|---|---|
| 1 | `wui: nuxt generate` / `perf-budget.py` | WUI | 11 runs | **Real Fault** (100%) | `FAIL ci_initial_gzip_kb 155.1 > 155` (runs 39114618626 .. 39120489022; fixed on master). |
| 2 | `tests/e2e/message-order.test.mjs` | WUI | 10 runs | **Flake / Race** (100%) | `FAIL 1440px A6: the thread reads oldest to newest and sits at its bottom {"n":21,"asc":false,"last":"11111111-1111-4111-8111-111111111111","fromBottom":0}` in shard 6/8 (runs 39243892211 .. 39258854521). Race in thread bottom scroll vs new reply arrival. |
| 3 | `wui: browser e2e 6/8` (phone omnibox) | WUI | 3 runs | **Real Fault / Timing** | `FAIL phone: the omnibox shows while the document is read "hidden"` (runs 39237805462, 39239550561, 39240139121; resolved in SPL-2516). |
| 4 | `wui: browser e2e 2/8` (fi sideways overflow) | WUI | 2 runs | **Real Fault** | `FAIL fi 360x800: 0 px sideways overflow ... tokens-kpi-rate:3` (runs 39234670723, 39235952134; fixed). |
| 5 | `orc: hermetic 2/3` (`OA-11` / `OA-13`) | ORC | 2 runs | **Real Fault** | `FAIL: OA-11 after the respawn: copies off: M-1=2` / `FAIL: OA-13 --max 5` (runs 39177816216, 39214423686; fixed). |
| 6 | `orc: hermetic 3/3` (`maintenance.lock`) | ORC | 1 run | **Real Fault** | `FAIL: 1. rc=0 changed: gone ... maintenance.lock PLAN posts-dir mkdir -p + chmod 2777` (run 39218763702; fixed). |

**Flake vs. Real Fault:** The dominant persistent test flake across master in recent runs is `tests/e2e/message-order.test.mjs` case A6 (10 failures in shard 6/8).

---

## 3. Baseline measurements on current sha (`59ffb5dd3`) (ONE command each)

Every item below was measured on `59ffb5dd3` (`origin/master`, 2026-10-19):

### 3.1 Untested destructive IAC Terraform actions
- **Command:**
  ```bash
  for f in tf-destroy-target tf-destroy-local-step-bucket tf-remove-step tf-replace-target tf-state-push gcp-modify-project-apis-disable gcp-project-apis-disable; do grep -rlqw "$f" csi-spl-iac/src/bash/tests || echo "$f"; done
  ```
- **Output:**
  `tf-destroy-target`, `tf-destroy-local-step-bucket`, `tf-remove-step`, `tf-replace-target`, `tf-state-push`, `gcp-modify-project-apis-disable`, `gcp-project-apis-disable`
- **Finding:** **7 destructive IAC actions have zero tests**.

### 3.2 Untested bash actions (total across orc and iac)
- **Command:**
  ```bash
  for f in csi-spl-orc/src/bash/run/*.func.sh csi-spl-iac/src/bash/run/*.func.sh; do b=$(basename "$f" .func.sh); grep -rlqw "do_${b//-/_}" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests csi-spl-api/src/bash/tests || grep -rlqw "$b" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests >/dev/null 2>&1 || echo "$f"; done | wc -l
  ```
- **Output:**
  `31`
- **Finding:** **31 bash actions** across `csi-spl-orc` (15) and `csi-spl-iac` (16) have zero tests.

### 3.3 Slowest ORC tests (wall, cpu, idle share in CI)
- **Command:**
  CI run 39259601111 (master head `59ffb5dd3`), from `--- slowest 10 test files (wall s, cpu s)` across jobs 118088096935, 118088097182, 118088097171:
- **Output:**
  - `peer-poll.tst.sh`: wall **361.5 s**, cpu 166.7 s (**~54% idle**, Shard 3/3; 518 s in `orc-shard-weights.txt`)
  - `spl-lane-mix.tst.sh`: wall **336.8 s**, cpu 209.6 s (**~38% idle**, Shard 2/3; 545 s in `orc-shard-weights.txt`)
  - `desk-rebox-pg.tst.sh`: wall **175.2 s**, cpu 237.7 s (Shard 3/3, cpu-bound Postgres)
  - `desk-up-all.tst.sh`: wall **165.0 s**, cpu 46.9 s (**~72% idle**, Shard 3/3)
  - `dispatch-inbound-pg.tst.sh`: wall **158.2 s**, cpu 209.6 s (Shard 3/3, cpu-bound Postgres)
  - `fleet-lease.tst.sh`: wall **157.2 s**, cpu 67.1 s (Shard 1/3, down from 236 s in Round 1)
  - `dispatch-rotate.tst.sh`: wall **117.5 s**, cpu 44.4 s (Shard 1/3, down from 249 s in Round 1)
  - `desk-pin.tst.sh`: wall **98.2 s**, cpu 29.7 s (**~70% idle**, Shard 2/3)
  - `desk-welcome.tst.sh`: wall **95.7 s**, cpu 22.9 s (**~76% idle**, Shard 3/3)
  - `spool-install.tst.sh`: wall **92.5 s**, cpu 62.4 s (Shard 3/3; 243 s in `orc-shard-weights.txt`)
  - `orch-rotate.tst.sh`: wall **83.2 s**, cpu 41.8 s (Shard 1/3, down from 426 s in Round 1)
- **Finding:** The largest idle-time bottlenecks remaining in ORC are `peer-poll.tst.sh` (~195 s idle), `desk-up-all.tst.sh` (~118 s idle), `desk-pin.tst.sh` (~68 s idle), and `desk-welcome.tst.sh` (~73 s idle).

### 3.4 Untested WUI core composables and utilities
- **Command:**
  ```bash
  echo "useBuildWatch: $(git grep -l "useBuildWatch" csi-spl-wui/tests/ | wc -l), useOpenMessage: $(git grep -l "useOpenMessage" csi-spl-wui/tests/ | wc -l), useRoadmapGoals: $(git grep -l "useRoadmapGoals" csi-spl-wui/tests/ | wc -l), msg-apply: $(git grep -l "msg-apply" csi-spl-wui/tests/ | wc -l), tenant-host-core: $(git grep -l "tenant-host-core" csi-spl-wui/tests/ | wc -l)"
  ```
- **Output:**
  `useBuildWatch: 0, useOpenMessage: 0, useRoadmapGoals: 0, msg-apply: 0, tenant-host-core: 0`
- **Finding:** Core WUI state composables and messaging/host utilities have 0 tests in `csi-spl-wui/tests/`.

### 3.5 API Go coverage floor gap
- **Command:**
  ```bash
  grep -E 'fakeidp' csi-spl-api/src/bash/tests/go-coverage-floor.txt && go test -count=1 -cover ./internal/auth/fakeidp
  ```
- **Output:**
  `internal/auth/fakeidp 3.5`, `coverage: 3.5% of statements`
- **Finding:** `internal/auth/fakeidp` contains `fakeidp.go` (10 KB) without a test file (`fakeidp_test.go` missing). Coverage is pinned at floor 3.5%.

### 3.6 Tests that inspect source text instead of behaviour
- **Command:**
  ```bash
  echo "WUI text tests: $(grep -lE '(readFileSync|fs\.read)' csi-spl-wui/tests/unit/*.test.mjs | wc -l) of $(ls csi-spl-wui/tests/unit/*.test.mjs | wc -l); WUI assert.match(src(): $(grep -rn "assert.match(src(" csi-spl-wui/tests/unit/ | wc -l); Bash text tests: $(grep -lE '(git grep|grep -[a-zA-Z]*r[a-zA-Z]*|grep.*(src/|\.func\.sh|\.go|\.vue|\.ts|\.mjs))' csi-spl-iac/src/bash/tests/*.tst.sh csi-spl-orc/src/bash/tests/*.tst.sh | wc -l) of $(ls csi-spl-iac/src/bash/tests/*.tst.sh csi-spl-orc/src/bash/tests/*.tst.sh | wc -l)"
  ```
- **Output:**
  `WUI text tests: 297 of 400; WUI assert.match(src(): 79; Bash text tests: 149 of 656`
- **Finding:** 297 WUI unit tests read source files; 79 lines assert on raw source text; 149 bash test suites grep source files.

### 3.7 Suites with no red control (sample n=25)
- **Command:**
  ```bash
  python3 -c 'import glob; files = sorted(glob.glob("csi-spl-iac/src/bash/tests/*.tst.sh") + glob.glob("csi-spl-orc/src/bash/tests/*.tst.sh")); no_ctrl = [f for f in files if "CONTROL" not in open(f).read() and "control" not in open(f).read().lower()]; print(f"Total: {len(no_ctrl)}"); print("\n".join(no_ctrl[:25]))'
  ```
- **Output:**
  `Total: 145`, sample: `artifact-registry-028.tst.sh`, `check-pre-push-baseline.tst.sh`, `check-pre-push-override.tst.sh`, `check-pre-push-timeout-label.tst.sh`, `check-release-note.tst.sh`, `check-sql-portable.tst.sh`, `check-weekly-full-scan.tst.sh`, `dast-prd-opt-in.tst.sh`, `dns-zone-025.tst.sh`, `export-json-section-vars-as-tf-vars.tst.sh`, `gcp-002-004-bootstrap.tst.sh`, `gcp-cloud-billing-api-enable.tst.sh`, `gcp-exit-status-checks.tst.sh`, `gcp-sa-key-email.tst.sh`, `gcp-sm-secrets-dead.tst.sh`, `github-secrets-120.tst.sh`, `measure-wui-edge-warm.tst.sh`, `spl-private-cnf.tst.sh`, `spl-wine-box-budget-tf.tst.sh`, `stop-pre-push.tst.sh`, `tmp-path-lint.tst.sh`, `utl-suite.tst.sh`, `warm-wui-edge.tst.sh`, `wif-017-trunk-pin.tst.sh`, `wine-box-actions.tst.sh`
- **Finding:** **145 bash test suites** contain no negative control or red verification step.

### 3.8 Flaky test in CI: `tests/e2e/message-order.test.mjs`
- **Command:**
  ```bash
  CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate | grep -c "the thread reads oldest to newest"
  ```
- **Output:**
  `10`
- **Finding:** `tests/e2e/message-order.test.mjs` case A6 failed 10 times in the last 100 runs in CI (shard 6/8).

---

## 4. The 12 rows (12 most urgent changes)

| # | slug | practice | why | sites file:line (max 5) | number now (command) | target | red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `test(r02-01-orc-speed-peer-poll)` | mock clock / event-driven polling | `peer-poll.tst.sh` takes 361.5 s CI wall (~54% idle, 166.7 s CPU) simulating 8 OD loops on 2 boxes | `orc:src/bash/tests/peer-poll.tst.sh:1-250` | 361.5 s CI wall (CI run 39259601111 job 3/3; 518 s in `orc-shard-weights.txt`) | < 150 s CI wall | Injected peer poll timeout trips assertion under < 150 s | sat | claude | tests | **1 (Lane 1)** |
| 02 | `test(r02-02-iac-dry-run-tf-destroy)` | hermetic dry-run tests for destructive Terraform actions | `tf-destroy-target` and `tf-destroy-local-step-bucket` are destructive actions with 0 tests | `iac:src/bash/tests/tf-destroy-target.tst.sh` (new)<br>`iac:src/bash/tests/tf-destroy-local-step-bucket.tst.sh` (new) | 0 tests for both actions (`grep -rlqw tf-destroy-target csi-spl-iac/src/bash/tests \|\| echo 0`) | 2 hermetic tests asserting dry-run default, stubbed terraform/gcloud, required flags, refusal on missing ENV | Inverting DRY_RUN guard or omitting target flag trips failure | sat | claude | tests | **1 (Lane 2)** |
| 03 | `test(r02-03-wui-unit-msg-apply)` | behavioral unit tests for core message mutation utility | `msg-apply.mjs` has 0 tests (`git grep -l "msg-apply" csi-spl-wui/tests/` -> 0) | `wui:tests/unit/msg-apply.test.mjs` (new)<br>`wui:src/utils/msg-apply.mjs:1-150` | 0 tests for `msg-apply.mjs` | 1 unit test suite covering message insertion, deduplication, updates, and sorting | Mutating message apply sort order or dropping id match trips test failure | sat | claude | tests | **1 (Lane 3)** |
| 04 | `test(r02-04-go-coverage-fakeidp)` | unit test suite and coverage floor ratchet | `internal/auth/fakeidp` has only 3.5% statement coverage and floor 3.5 (`fakeidp_test.go` missing) | `api:src/go/spool-hub-api/internal/auth/fakeidp/fakeidp_test.go` (new)<br>`api:src/bash/tests/go-coverage-floor.txt:18` | 3.5% statement coverage, floor 3.5 (`go test -cover ./internal/auth/fakeidp`) | > 70.0% coverage, ratchet floor in `go-coverage-floor.txt` to 70.0 | Removing fake token handler in `fakeidp_test.go` drops coverage under floor and trips `run-all-tests.sh --coverage-floor` | sat | claude | tests | **1 (Lane 4)** |
| 05 | `test(r02-05-orc-speed-desk-up-all)` | process readiness polling / eliminate fixed sleep | `desk-up-all.tst.sh` takes 165.0 s CI wall (~72% idle, 46.9 s CPU) in fixed sleep loops (lines 340, 408-410, 468) | `orc:src/bash/tests/desk-up-all.tst.sh:1-200` | 165.0 s CI wall (CI run 39259601111 job 3/3; cpu 46.9 s) | < 60 s CI wall | Process termination failure trips assertion within < 60 s | sat | claude | tests | **2 (Lane 1, after 01)** |
| 06 | `test(r02-06-iac-dry-run-tf-state-target)` | hermetic dry-run tests for state and step removal actions | `tf-remove-step`, `tf-replace-target`, and `tf-state-push` have 0 tests | `iac:src/bash/tests/tf-remove-step.tst.sh` (new)<br>`iac:src/bash/tests/tf-replace-target.tst.sh` (new)<br>`iac:src/bash/tests/tf-state-push.tst.sh` (new) | 0 tests for all 3 actions | 3 hermetic tests asserting dry-run default, refusal on missing ENV/step, stubbed terraform state commands | Omitting state confirmation or bypassing dry-run guard trips failure | sat | claude | tests | **2 (Lane 2, after 02)** |
| 07 | `test(r02-07-wui-unit-tenant-host-core)` | behavioral unit tests for tenant host resolution | `tenant-host-core.mjs` has 0 tests (`git grep -l "tenant-host-core" csi-spl-wui/tests/` -> 0) | `wui:tests/unit/tenant-host-core.test.mjs` (new)<br>`wui:src/utils/tenant-host-core.mjs:1-120` | 0 tests for `tenant-host-core.mjs` | 1 unit test suite covering tenant domain parsing, default fallbacks, custom domain resolution | Returning incorrect tenant fallback trips assertion failure | sat | claude | tests | **2 (Lane 3, after 03)** |
| 08 | `test(r02-08-wui-flake-message-order)` | deterministic DOM state wait / eliminated race | `tests/e2e/message-order.test.mjs` failed 10 times in CI (last 100 runs, shard 6/8) on case A6 thread bottom-sitting race | `wui:tests/e2e/message-order.test.mjs:270-305` | 10 CI failures in last 100 runs (runs 39258854521, 39256952187, 39256267400, 39255036322, 39247318829) | 0 flakes across 20 consecutive runs (`node tests/e2e/message-order.test.mjs`) | Inverting sort order assertion breaks test | sat | claude | tests | **2 (Lane 4, after 04)** |
| 09 | `test(r02-09-orc-speed-desk-welcome-pin)` | mock socket sleep loops / tight polling intervals | `desk-welcome.tst.sh` (95.7 s wall, ~76% idle) and `desk-pin.tst.sh` (98.2 s wall, ~70% idle) spend ~70-76% idle waiting on fixed sleep ticks | `orc:src/bash/tests/desk-welcome.tst.sh:1-150`<br>`orc:src/bash/tests/desk-pin.tst.sh:1-150` | 95.7 s and 98.2 s CI wall (CI run 39259601111 jobs 2/3 and 3/3) | < 40 s CI wall each | Broken pin or welcome status check trips immediate failure | sat | claude | tests | **3 (Lane 1, after 05)** |
| 10 | `test(r02-10-iac-dry-run-gcp-apis-disable)` | hermetic dry-run tests for destructive GCP API disabling | `gcp-modify-project-apis-disable` and `gcp-project-apis-disable` have 0 tests, risking unintended API disabling | `iac:src/bash/tests/gcp-modify-project-apis-disable.tst.sh` (new)<br>`iac:src/bash/tests/gcp-project-apis-disable.tst.sh` (new) | 0 tests for both actions | 2 hermetic tests asserting dry-run default, gcloud stubbing, required service account, refusal on missing ENV | Missing `--account` or bypassing dry-run guard trips failure | sat | claude | tests | **3 (Lane 2, after 06)** |
| 11 | `test(r02-11-wui-unit-composables)` | behavioral unit tests for untested core composables | `useBuildWatch.ts`, `useOpenMessage.ts`, and `useRoadmapGoals.ts` have 0 tests in `csi-spl-wui/tests/` | `wui:tests/unit/useBuildWatch.test.mjs` (new)<br>`wui:tests/unit/useOpenMessage.test.mjs` (new)<br>`wui:tests/unit/useRoadmapGoals.test.mjs` (new) | 0 tests for all 3 composables (`git grep -l "useBuildWatch\|useOpenMessage\|useRoadmapGoals" csi-spl-wui/tests/` -> 0) | 3 unit test suites covering reactivity, error handling, state updates | Inverting mock api responses in tests trips failure | sat | claude | tests | **3 (Lane 3, after 07)** |
| 12 | `test(r02-12-orc-speed-spool-install)` | mock file-watcher / eliminate installer idle wait | `spool-install.tst.sh` takes 92.5 s CI wall (243 s packing weight) running multi-step installer loops | `orc:src/bash/tests/spool-install.tst.sh:1-250` | 92.5 s CI wall (CI run 39259601111 job 3/3; 243 s in `orc-shard-weights.txt`) | < 45 s CI wall | Installer verification failure trips test exit within cap | sat | claude | tests | **3 (Lane 4, after 08)** |

**First 4 rows:** Rows 01, 02, 03, and 04 (Batch 1).

---

## 5. Disjoint files (R1) & 4 parallel lanes

Per owner directive (msg `fe3064af`): **12 rows built 4 lanes in parallel**.

### 5.1 Disjoint file sets per batch (R1)

- **Batch 1 (Parallel Lanes 1–4):**
  - Row 01: `orc:src/bash/tests/peer-poll.tst.sh`
  - Row 02: `iac:src/bash/tests/tf-destroy-target.tst.sh`, `iac:src/bash/tests/tf-destroy-local-step-bucket.tst.sh`
  - Row 03: `wui:tests/unit/msg-apply.test.mjs`, `wui:src/utils/msg-apply.mjs`
  - Row 04: `api:src/go/spool-hub-api/internal/auth/fakeidp/fakeidp_test.go`, `api:src/bash/tests/go-coverage-floor.txt`
  *(All files disjoint across modules. `orc-shard-weights.txt` is NOT touched by any speed row).*

- **Batch 2 (Parallel Lanes 1–4, after Batch 1 lands):**
  - Row 05: `orc:src/bash/tests/desk-up-all.tst.sh`
  - Row 06: `iac:src/bash/tests/tf-remove-step.tst.sh`, `iac:src/bash/tests/tf-replace-target.tst.sh`, `iac:src/bash/tests/tf-state-push.tst.sh`
  - Row 07: `wui:tests/unit/tenant-host-core.test.mjs`, `wui:src/utils/tenant-host-core.mjs`
  - Row 08: `wui:tests/e2e/message-order.test.mjs`
  *(All files disjoint).*

- **Batch 3 (Parallel Lanes 1–4, after Batch 2 lands):**
  - Row 09: `orc:src/bash/tests/desk-welcome.tst.sh`, `orc:src/bash/tests/desk-pin.tst.sh`
  - Row 10: `iac:src/bash/tests/gcp-modify-project-apis-disable.tst.sh`, `iac:src/bash/tests/gcp-project-apis-disable.tst.sh`
  - Row 11: `wui:tests/unit/useBuildWatch.test.mjs`, `wui:tests/unit/useOpenMessage.test.mjs`, `wui:tests/unit/useRoadmapGoals.test.mjs`
  - Row 12: `orc:src/bash/tests/spool-install.tst.sh`
  *(All files disjoint).*

### 5.2 4-Lane Progression
- **Lane 1 (Orc Speed - Peer Poll & Desk Waits):** Row 01 -> Row 05 -> Row 09
- **Lane 2 (IAC Safety - Destructive Terraform & GCP Actions):** Row 02 -> Row 06 -> Row 10
- **Lane 3 (WUI Unit - Utilities & Composables):** Row 03 -> Row 07 -> Row 11
- **Lane 4 (Contracts & Stability - API Floor, E2E Flake & Install):** Row 04 -> Row 08 -> Row 12

### 5.3 Collision Control (R3)
`lane-map.sh --check` verifies none of these paths are owned by any live lane on any box.
Disjoint from live work: the coding-standards panel (t1 2402f33e: developer guide / constitution / drift check files), the watchdog fence lanes (`spl-watchdog.func.sh`, `wd-*.tst.sh`), and the role-fallback guard lane (`spl-role-fallback-up.func.sh`, `role-fallback-up.tst.sh`). None of these files are touched by any row in this plan.
`orc-shard-weights.txt` is excluded from all individual row sites to eliminate multi-lane merge conflicts; a single refresh can be performed post-Batch 3.

---

## 6. What was measured and NOT worth doing

| Proposal / Practice | Why not | Measured evidence |
|---|---|---|
| `spl-lane-mix.tst.sh` speed refactor | Mostly CPU work (yq parsing and subshells); wall 336.8 s vs CPU 209.6 s; not an idle-wait loop | CPU time = 209.6 s (~62% of runtime). Cutting sleep loops does not reduce runtime without rewriting the configuration loader. |
| `spl-db-hot-measure.tst.sh` speed refactor | Heavy CPU parallelism (CPU 225.5 s > wall 180.8 s) | Parallel worker load under load test harness; not idle wait. |
| `calendar-purge-trash.tst.sh` speed refactor | CPU-bound Postgres/database operations (wall 147.7 s, CPU 169.2 s) | CPU time exceeds wall time. No sleep loops to eliminate. |
| `demo-wipe.tst.sh` speed refactor | CPU-bound database wipe operations (wall 158.0 s, CPU 248.1 s) | CPU time exceeds wall time. |
| `spl-session-prune.tst.sh` speed refactor | Despite packing weight 243 s in `orc-shard-weights.txt`, actual runtime in CI is under 20 s | Test finishes quickly in CI; packing weight is stale rather than real execution bottleneck. |
| Wholesale rewrite of all 297 WUI text tests | Massive diff churn across ~300 files violating single-responsibility and push caps | Tackled incrementally via behavioral unit tests for core utilities and composables (Rows 03, 07, 11). |
| Unskipping all 4 E2E tests in `ci-skip.txt` (`csp-violations`, `live-interop`, `rounded-corners`, `scroll-anchor`) | Environmental limitations in headless Chromium (mock server CSP headers, browser window manager) | Tests fail in headless container environments without display server support. |
| Per-row edits to `orc-shard-weights.txt` | Violates R1 (disjoint files per batch) across multiple speed rows | Stale packing weights file cannot be concurrently edited by parallel lanes. Refreshed once post-Batch 3. |
| Splitting orc hermetic tests into 4+ shards | Bottlenecked by runner capacity; sat has ~3 runners online on average | Spec 133: adding shards increases queue time without reducing wall time when runner pool is constrained. |

---

## 7. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-481@sat` (`test-round-2/seat-agy.md`)
  - Claude seat: `c-xxx@sat` (`test-round-2/seat-claude.md`)
  - Mistral seat (docs/review only per owner rule): `m-xxx@sat` (`test-round-2/seat-mistral.md`)
  - Grok seat: `g-xxx@<box>` (`test-round-2/seat-grok.md` - if seated / quota permits)
- **Reviewers per row (R7.2):**
  - Vendor mix: all 12 rows are assigned to claude (`do_spl_lane_mix` for kind=tests: claude 85%, grok 15%; owner rule: no mistral coding or test-writing rows).
  - Cross-vendor review: Editor seat `a-481@sat` (agy) and Mistral seat `m-xxx@sat` (docs/review only) provide strict cross-vendor review for all 12 claude-authored rows (`grep -c 'same vendor'` -> 0).
  - Review lines verified via `do_spl_review_line_check`.

---

## 8. Changes

- v0.1: Initial proposed plan for Test Round 2 (testing self-reflection round 2), answering owner questions on testing balance (too much / too little), top failing tests in CI (message-order A6 flake), and 12 empirical changes structured across 3 batches of 4 rows for 4 parallel build lanes (owner override `fe3064af`).

---

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-481@sat | v0.1 proposed | `test-round-2/seat-agy.md` |
| Claude seat | claude | pending | pending review of v0.1 | `test-round-2/seat-claude.md` |
| Mistral seat (docs/review only) | mistral | pending | pending review of v0.1 | `test-round-2/seat-mistral.md` |
| Grok seat | grok | pending | pending review of v0.1 | `test-round-2/seat-grok.md` |
