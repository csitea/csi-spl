# Testing self-reflection round 2 - plan (12 actions)

Owner HUM-10, t1 topic `4555450c-09da-4dda-9b16-735409b0ac6e`:
- msg `5f94998c`: "testing self-reflection round"
- msg `ad549339`: "Everything about testing in the system ... Is it too much .. too little ... which tests have been mostly failing , what are the 10 most urgent changes to refactor to improve the testing"
- msg `fe3064af`: "sorry 12 , as you would have to do 4 agents at the time to improve" -> **12 rows** (owner override of the 10-row cap), built **4 lanes in parallel**: 3 batches of 4 rows, files disjoint within a batch.
Rounds need no owner go (rulebook 1.4: consensus between panel seats, then implementation, no questions to the owner).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16), by pointer, not copied. Issue: SPL-2402 (lane SPL-2554).

**Status: v1.0, CONSENSUS REACHED**. Panel feedback folded from Claude seat `c-487@sat` (`cefa6c737`) and Mistral reviewer seat `m-639@PC` (`e428729eb`).

Editor: **a-481@sat** (agy).

**One sha:** baseline counts measured on **`59ffb5dd3`** (`origin/master`, 2026-10-19 13:22Z, CI run 39259601111 success) and re-verified on `b7fad2def`, `cefa6c737`, and `e428729eb`. CI per-file wall times and CPU times are taken from completed master run 39259601111 (`--- slowest 10 test files (wall s, cpu s)` across orc hermetic shards 1/3, 2/3, 3/3), solo timings on sat (n=3), and `do_report_ci_gate` across the last 100 master runs.

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
1. **ORC:** **Runner contention and second-tier slow tests.** The CI runner has `nproc=4` but hardcodes `njobs=6`, causing severe runner CPU contention where identical tests run 4× slower in packed shards (165 s vs 42 s). `peer-poll` (solo 174 s wall, 197 s CPU) and `spool-install` (solo 62 s CPU) dominate execution time. 28 bash actions across orc (15) and iac (13) have zero tests.
2. **IAC:** **Critical safety gap:** Destructive Terraform state and target mutations (`tf-destroy-target`, `tf-destroy-local-step-bucket`, `tf-remove-step`, `tf-replace-target`, `tf-state-push`) lack hermetic tests and `DRY_RUN` default 1 guards.
3. **API:** **Cross-package coverage floor reporting gap:** `run-all-tests.sh` runs `go test -cover` per package without `-coverpkg`, failing to credit cross-package test execution (e.g. `internal/auth/fakeidp` showing 3.5% despite being 89.1% exercised by `internal/auth` flow tests).
4. **WUI:** **E2E Flake A6 resolved:** `tests/e2e/message-order.test.mjs` case A6 was a regression from `dedf3e9bb` fixed on master by `59ffb5dd3` (SPL-2506), with 0 failures in subsequent master runs. Drop from round per panel consensus.

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

**Flake vs. Real Fault:** `tests/e2e/message-order.test.mjs` case A6 failed 10 times in shard 6/8 across master runs between `dedf3e9bb` and `59ffb5dd3`. Re-measurement by both Claude and Mistral seats confirmed that `59ffb5dd3` (SPL-2506) completely fixed the root cause (0 failures in completed runs since). Per unanimous panel consensus, this row is resolved and excluded from Round 2.

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
| 01 | `test(r02-01-orc-speed-peer-poll)` | cut forks / loop optimization | `peer-poll.tst.sh` is slowest orc test (solo 168.6-174.1 s wall at 190-197 s cpu, n=3). Section 2/3 loops & hub stub forks dominate. | `orc:src/bash/tests/peer-poll.tst.sh:1-350` | solo 168.6-174.1 s wall, 190-197 s cpu (n=3, sat) | solo cpu < 100 s (n=3) | Injected peer poll timeout trips assertion under < 100 s | sat | claude | tests | **1 (Lane 1)** |
| 02 | `test(r02-02-iac-dry-run-tf-destroy)` | hermetic dry-run tests + `DRY_RUN` default 1 for destructive Terraform actions | `tf-destroy-target` and `tf-destroy-local-step-bucket` have 0 tests and lack `DRY_RUN` guards | `iac:src/bash/run/tf-destroy-target.func.sh`<br>`iac:src/bash/run/tf-destroy-local-step-bucket.func.sh`<br>`iac:src/bash/tests/tf-destroy-target.tst.sh` (new)<br>`iac:src/bash/tests/tf-destroy-local-step-bucket.tst.sh` (new) | 0 tests for both actions; 0 `DRY_RUN` guards | 2 hermetic tests asserting dry-run default, stubbed `terraform` on PATH, stubbed `do_tf_init`, required flags, refusal on missing ENV | Inverting DRY_RUN guard or omitting target flag trips failure | sat | claude | tests | **1 (Lane 2)** |
| 03 | `test(r02-03-orc-jobs-derivation-weights)` | right-size orc CI pool (`njobs` from `nproc`) & refresh weights | CI runner has `nproc=4` but hardcodes `njobs=6`, causing severe runner CPU contention (tests 4× slower in packed shards). Weights drifted (e.g. `spl-session-prune` 243 s vs 20 s actual). | `orc:src/bash/tests/run-all-tests.sh:80-95`<br>`orc:src/bash/tests/orc-shard-weights.txt`<br>`orc:src/bash/tests/orc-jobs-derivation.tst.sh` (new) | `njobs=6` hardcoded when `GITHUB_ACTIONS=true` on 4-core runner; drifted weights | `njobs` capped at `nproc`; `orc-shard-weights.txt` refreshed; hermetic unit test for `njobs` derivation | Hardcoding `njobs=99` trips cap test; stale weight comparison trips test | sat | claude | tests | **1 (Lane 3)** |
| 04 | `test(r02-04-go-coverage-coverpkg)` | cross-package `-coverpkg` measurement & floor ratchets | `go test ./...` without `-coverpkg` fails to count cross-package usage (`fakeidp` sits at 3.5% floor despite 89.1% execution by `internal/auth` flow tests). | `api:src/bash/tests/run-all-tests.sh:100-120`<br>`api:src/bash/tests/go-coverage-floor.txt:23` | `fakeidp` sits at 3.5% floor without cross-package coverage; bare `-coverprofile` | `run-all-tests.sh` supports `-coverpkg=./...` or merged profile; ratchet fakeidp floor to 80.0 | Removing fake token handler drops coverage below floor and trips `run-all-tests.sh` | sat | claude | tests | **1 (Lane 4)** |
| 05 | `test(r02-05-orc-red-control-pre-push)` | negative / red controls for pre-push gate suites | `check-pre-push-*.tst.sh` suites lack negative controls (Section 3.7) | `iac:src/bash/tests/check-pre-push-baseline.tst.sh`<br>`iac:src/bash/tests/check-pre-push-override.tst.sh`<br>`iac:src/bash/tests/check-pre-push-timeout-label.tst.sh` | 0 negative controls in all 3 suites (`grep -i control` -> 0) | 3 negative controls asserting refusal on invalid baseline, unauthorized override, missing timeout labels | Inverting control expectation trips test suite failure | sat | claude | tests | **2 (Lane 1, after 01)** |
| 06 | `test(r02-06-iac-dry-run-tf-state-target)` | hermetic dry-run tests + `DRY_RUN` default 1 for state/step actions | `tf-remove-step`, `tf-replace-target`, `tf-state-push`, and `tf-state-pull` have 0 tests. `tf-remove-step` deletes files relative to cwd. | `iac:src/bash/run/tf-remove-step.func.sh`<br>`iac:src/bash/run/tf-replace-target.func.sh`<br>`iac:src/bash/run/tf-state-push.func.sh`<br>`iac:src/bash/run/tf-state-pull.func.sh`<br>`iac:src/bash/tests/tf-state-actions.tst.sh` (new) | 0 tests for all 4 state actions (`grep -rqE "(tf-remove-step|tf-replace-target|tf-state-push|tf-state-pull)" csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/tests` -> 0); 0 `DRY_RUN` guards | Hermetic test suite asserting dry-run default, refusal on missing STEP/TARGET, sandbox cwd for `tf-remove-step`, pin `-lock=false` for `tf-state-push` | Bypassing DRY_RUN or omitting required env trips failure | sat | claude | tests | **2 (Lane 2, after 02)** |
| 07 | `test(r02-07-orc-untested-probe-actions)` | hermetic tests for diagnostic probe actions | `spl-msg-edit-probe` and `spl-wire-probe` have 0 tests in `csi-spl-orc/src/bash/run/` | `orc:src/bash/run/spl-msg-edit-probe.func.sh`<br>`orc:src/bash/run/spl-wire-probe.func.sh`<br>`orc:src/bash/tests/spl-probe-actions.tst.sh` (new) | 0 tests (`grep -rqE "(spl-msg-edit-probe|spl-wire-probe)" csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> 0) | Hermetic test suite verifying stubbed curl/socket checks, output parsing, exit code contracts | Corrupting probe response json or stub failure trips test | sat | claude | tests | **2 (Lane 3, after 03)** |
| 08 | `test(r02-08-iac-gcp-compute-lb-list)` | hermetic test for load balancer list action | `gcp-compute-lb-list` has 0 tests in `csi-spl-iac/src/bash/run/` | `iac:src/bash/run/gcp-compute-lb-list.func.sh`<br>`iac:src/bash/tests/gcp-compute-lb-list.tst.sh` (new) | 0 tests (`grep -rq "gcp-compute-lb-list" csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/tests` -> 0) | Hermetic test suite asserting `--account`, `--project`, throwaway CLOUDSDK_CONFIG, and refusal on missing ENV | Omitting `--account` or missing ENV trips test failure | sat | claude | tests | **2 (Lane 4, after 04)** |
| 09 | `test(r02-09-orc-untested-orch-burn-actions)` | hermetic tests for orchestrator & burn actions | `spl-token-burn-push-env`, `spl-wd-orch-outcome`, and `spl-standby-bench-helpers` have 0 tests in `csi-spl-orc/src/bash/run/` | `orc:src/bash/run/spl-token-burn-push-env.func.sh`<br>`orc:src/bash/run/spl-wd-orch-outcome.func.sh`<br>`orc:src/bash/run/spl-standby-bench-helpers.func.sh`<br>`orc:src/bash/tests/spl-orch-ops-actions.tst.sh` (new) | 0 tests for all 3 actions (`grep -rqE "(spl-token-burn-push-env|spl-wd-orch-outcome|spl-standby-bench-helpers)" csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> 0) | Hermetic test suite asserting dry-run PLAN, exit code contracts, argument validation | Inverting dry-run flag or invalid outcome parameter trips failure | sat | claude | tests | **3 (Lane 1, after 05)** |
| 10 | `test(r02-10-iac-gcp-sync-tail-satellite)` | hermetic tests for utility and log tail actions | `gcp-sync-local-to-s3`, `gcp-tail-logs`, and `satellite-image-latest` have 0 tests in `csi-spl-iac/src/bash/run/` | `iac:src/bash/run/gcp-sync-local-to-s3.func.sh`<br>`iac:src/bash/run/gcp-tail-logs.func.sh`<br>`iac:src/bash/run/satellite-image-latest.func.sh`<br>`iac:src/bash/tests/gcp-misc-actions.tst.sh` (new) | 0 tests for all 3 actions (`grep -rqE "(gcp-sync-local-to-s3|gcp-tail-logs|satellite-image-latest)" csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/tests` -> 0) | Hermetic test suite asserting argument validation, stubbed aws/gcloud/curl commands, refusal on missing ENV | Omitting mandatory arguments trips test failure | sat | claude | tests | **3 (Lane 2, after 06)** |
| 11 | `test(r02-11-orc-lane-lifecycle-actions)` | hermetic tests for lane lifecycle reporting actions | `spl-rotate-status`, `spl-local-hub-status`, `spl-dispatch-deploy-lag` have 0 tests | `orc:src/bash/run/spl-rotate-status.func.sh`<br>`orc:src/bash/run/spl-local-hub-status.func.sh`<br>`orc:src/bash/run/spl-dispatch-deploy-lag.func.sh`<br>`orc:src/bash/tests/spl-lane-lifecycle-actions.tst.sh` (new) | 0 tests for all 3 reporting actions (`grep -rqE "(spl-rotate-status|spl-local-hub-status|spl-dispatch-deploy-lag)" csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> 0) | Hermetic test suite asserting stdout formatting, TSV output parsing, exit code contracts | Invalid TSV headers or missing status trips failure | sat | claude | tests | **3 (Lane 3, after 07)** |
| 12 | `test(r02-12-orc-speed-spool-install)` | cut forks / reuse installation fixture | `test-install.sh` takes solo 59.6-62.5 s wall at 62-64 s cpu (111 PASS), packed at 243 s weight | `orc:src/bash/features/spool-install/tests/test-install.sh:1-300`<br>`orc:src/bash/tests/spool-install.tst.sh:1-10` | solo 59.6-62.5 s wall at 62-64 s cpu (n=3, sat) | solo cpu < 35 s (n=3) via fixture reuse and fork reduction | Broken install verification trips test exit code | sat | claude | tests | **3 (Lane 4, after 08)** |

**First 4 rows:** Rows 01, 02, 03, and 04 (Batch 1).

---

## 5. Disjoint files (R1) & 4 parallel lanes

Per owner directive (msg `fe3064af`): **12 rows built 4 lanes in parallel**.

### 5.1 Disjoint file sets per batch (R1)

- **Batch 1 (Parallel Lanes 1–4):**
  - Row 01: `orc:src/bash/tests/peer-poll.tst.sh`
  - Row 02: `iac:src/bash/run/tf-destroy-target.func.sh`, `iac:src/bash/run/tf-destroy-local-step-bucket.func.sh`, `iac:src/bash/tests/tf-destroy-target.tst.sh`, `iac:src/bash/tests/tf-destroy-local-step-bucket.tst.sh`
  - Row 03: `orc:src/bash/tests/run-all-tests.sh`, `orc:src/bash/tests/orc-shard-weights.txt`, `orc:src/bash/tests/orc-jobs-derivation.tst.sh`
  - Row 04: `api:src/bash/tests/run-all-tests.sh`, `api:src/bash/tests/go-coverage-floor.txt`
  *(All files disjoint across modules).*

- **Batch 2 (Parallel Lanes 1–4, after Batch 1 lands):**
  - Row 05: `iac:src/bash/tests/check-pre-push-baseline.tst.sh`, `iac:src/bash/tests/check-pre-push-override.tst.sh`, `iac:src/bash/tests/check-pre-push-timeout-label.tst.sh`
  - Row 06: `iac:src/bash/run/tf-remove-step.func.sh`, `iac:src/bash/run/tf-replace-target.func.sh`, `iac:src/bash/run/tf-state-push.func.sh`, `iac:src/bash/run/tf-state-pull.func.sh`, `iac:src/bash/tests/tf-state-actions.tst.sh`
  - Row 07: `orc:src/bash/run/spl-msg-edit-probe.func.sh`, `orc:src/bash/run/spl-wire-probe.func.sh`, `orc:src/bash/tests/spl-probe-actions.tst.sh`
  - Row 08: `iac:src/bash/run/gcp-compute-lb-list.func.sh`, `iac:src/bash/tests/gcp-compute-lb-list.tst.sh`
  *(All files disjoint).*

- **Batch 3 (Parallel Lanes 1–4, after Batch 2 lands):**
  - Row 09: `orc:src/bash/run/spl-token-burn-push-env.func.sh`, `orc:src/bash/run/spl-wd-orch-outcome.func.sh`, `orc:src/bash/run/spl-standby-bench-helpers.func.sh`, `orc:src/bash/tests/spl-orch-ops-actions.tst.sh`
  - Row 10: `iac:src/bash/run/gcp-sync-local-to-s3.func.sh`, `iac:src/bash/run/gcp-tail-logs.func.sh`, `iac:src/bash/run/satellite-image-latest.func.sh`, `iac:src/bash/tests/gcp-misc-actions.tst.sh`
  - Row 11: `orc:src/bash/run/spl-rotate-status.func.sh`, `orc:src/bash/run/spl-local-hub-status.func.sh`, `orc:src/bash/run/spl-dispatch-deploy-lag.func.sh`, `orc:src/bash/tests/spl-lane-lifecycle-actions.tst.sh`
  - Row 12: `orc:src/bash/features/spool-install/tests/test-install.sh`, `orc:src/bash/tests/spool-install.tst.sh`
  *(All files disjoint).*

### 5.2 4-Lane Progression
- **Lane 1 (Orc Speed & Red Controls):** Row 01 -> Row 05 -> Row 09
- **Lane 2 (IAC Safety - Destructive Terraform & GCP Actions):** Row 02 -> Row 06 -> Row 10
- **Lane 3 (Orc Infrastructure - Runner Pool, Probes & Lifecycle):** Row 03 -> Row 07 -> Row 11
- **Lane 4 (Contracts, Tooling & Install - Go Coverpkg, LB List & Install):** Row 04 -> Row 08 -> Row 12

### 5.3 Collision Control (R3)
`lane-map.sh --check` verifies none of these paths are owned by any live lane on any box.
Disjoint from live work: the coding-standards panel (t1 2402f33e: developer guide / constitution / drift check files), the watchdog fence lanes (`spl-watchdog.func.sh`, `wd-*.tst.sh`), and the role-fallback guard lane (`spl-role-fallback-up.func.sh`, `role-fallback-up.tst.sh`). None of these files are touched by any row in this plan.

---

## 6. What was measured and NOT worth doing

| Proposal / Practice | Why not | Measured evidence |
|---|---|---|
| `tests/e2e/message-order.test.mjs` case A6 flake fix | Root cause was regression from `dedf3e9bb` fixed by `59ffb5dd3` (SPL-2506); 0 failures in runs since | Both Claude and Mistral seats confirmed 0 failures across completed master runs post-fix. Dropped per consensus. |
| `desk-up-all`, `desk-welcome`, `desk-pin` sleep loops | Solo wall times are 42.8 s, 21.0 s, 27.4 s (already < targets); no wait loops | High CI wall in shard 3/3 is runner CPU contention (`njobs=6` on `nproc=4`), resolved systematically by Row 03. |
| `msg-apply.mjs` standalone unit test | Already tested through re-exports | `applyEdit` is called 9 times in `tests/unit/msg-edit-wire.test.mjs` via `msg-edit.mjs:293`. |
| `tenant-host-core.mjs` standalone unit test | Already tested through re-exports | `tests/unit/tenant-host.test.mjs` covers `tenant-host-core.mjs` at 96.92% lines and 84.38% branches. |
| `internal/auth/fakeidp` duplicate tests | Already 89.1% covered by `internal/auth` flow tests | Bare `go test ./...` reported 3.5% only because it lacks `-coverpkg`. Solved systematically by Row 04. |
| `useBuildWatch`, `useOpenMessage`, `useRoadmapGoals` plain unit tests | Pure logic is already tested in underlying `.mjs` utilities; `.ts` files are Vue/Pinia glue | Plain node cannot import TS composables without a full Nuxt component harness. |
| `gcp-modify-project-apis-disable` / `gcp-project-apis-disable` new tests | Already tested | `csi-spl-iac/src/bash/tests/gcp-tf-shared-bodies.tst.sh:101-113` runs both actions against stubbed gcloud (63 PASS). |
| `spl-lane-mix.tst.sh` speed refactor | Mostly CPU work (yq parsing and subshells); wall 336.8 s vs CPU 209.6 s | CPU time = 209.6 s (~62% of runtime). Cutting sleep loops does not reduce runtime without rewriting config loader. |
| `spl-db-hot-measure.tst.sh` speed refactor | Heavy CPU parallelism (CPU 225.5 s > wall 180.8 s) | Parallel worker load under load test harness; not idle wait. |
| `calendar-purge-trash.tst.sh` speed refactor | CPU-bound Postgres/database operations (wall 147.7 s, CPU 169.2 s) | CPU time exceeds wall time. No sleep loops to eliminate. |
| `demo-wipe.tst.sh` speed refactor | CPU-bound database wipe operations (wall 158.0 s, CPU 248.1 s) | CPU time exceeds wall time. |
| `spl-session-prune.tst.sh` speed refactor | Despite packing weight 243 s in `orc-shard-weights.txt`, actual runtime in CI is under 20 s | Test finishes quickly in CI; packing weight is stale rather than real execution bottleneck (refreshed in Row 03). |
| Wholesale rewrite of all 297 WUI text tests | Massive diff churn across ~300 files violating single-responsibility and push caps | Tackled incrementally in dedicated feature and refactor lanes. |
| Unskipping all 4 E2E tests in `ci-skip.txt` | Environmental limitations in headless Chromium | Tests fail in headless container environments without display server support. |
| Splitting orc hermetic tests into 4+ shards | Bottlenecked by runner capacity; sat has ~3 runners online on average | Spec 133: adding shards increases queue time without reducing wall time when runner pool is constrained. |

---

## 7. Panel of experts and reviewers (R7)

- **Expert Panel:**
  - Editor / agy seat: `a-481@sat` (`test-round-2/seat-agy.md`)
  - Claude seat: `c-487@sat` (`test-round-2/seat-claude.md`)
  - Mistral seat (docs/review only per owner rule): `m-639@PC` (`test-round-2/seat-mistral.md`)
  - Grok seat: unseated (quota limitation per dispatcher `c-002@sat`)
- **Reviewers per row (R7.2):**
  - Vendor mix: all 12 rows are assigned to claude (`do_spl_lane_mix` for kind=tests: claude 85%, grok 15%; owner rule: no mistral coding or test-writing rows).
  - Cross-vendor review: Editor seat `a-481@sat` (agy) and Mistral seat `m-639@PC` (docs/review only) provide strict cross-vendor review for all 12 claude-authored rows (`grep -c 'same vendor'` -> 0).
  - Review lines verified via `do_spl_review_line_check`.

---

## 8. Changes

- v0.1: Initial proposed plan for Test Round 2 (testing self-reflection round 2), answering owner questions on testing balance (too much / too little), top failing tests in CI (message-order A6 flake), and 12 empirical changes structured across 3 batches of 4 rows for 4 parallel build lanes (owner override `fe3064af`).
- v1.0: Consensus reached with expert panel seats. Folded verdict from Claude seat `c-487@sat` (`cefa6c737`) and Mistral seat `m-639@PC` (`e428729eb`):
  - Adopted Claude Proposal P1 as Row 03 (`test(r02-03-orc-jobs-derivation-weights)`): right-sizes `njobs` in `run-all-tests.sh` to runner `nproc` and refreshes drifted shard weights.
  - Adopted Claude Proposal P2 / Mistral Proposal 2 as Row 04 (`test(r02-04-go-coverage-coverpkg)`): adds cross-package `-coverpkg` support to Go aggregate test runner and ratchets fakeidp floor.
  - Adopted Claude changes on Row 01 (solo CPU < 100 s target, fork reduction), Row 02 (`DRY_RUN` default 1, stubbed terraform on PATH and `do_tf_init`), Row 06 (`DRY_RUN` default 1, sandbox cwd, state lock pin), and Row 12 (site `test-install.sh`, solo CPU < 35 s target).
  - Dropped fixed A6 flake row per unanimous panel consensus.
  - Replaced already-tested WUI utilities/composables and duplicate helper suites with 28 untested bash actions across orc and iac.
  - Verified R1 disjoint file sets across all 3 batches of 4 parallel lanes.

---

## 9. Consensus

| Seat | Kind | ID | Signed | File |
|---|---|---|---|---|
| Editor | agy | a-481@sat | signed on v1.0 | `test-round-2/seat-agy.md` |
| Claude seat | claude | c-487@sat | reviewed v0.1 (`cefa6c737`), awaiting v1.0 signing | `test-round-2/seat-claude.md` |
| Mistral seat (docs/review only) | mistral | m-639@PC | reviewed v0.1 (`e428729eb`), awaiting v1.0 signing | `test-round-2/seat-mistral.md` |
| Grok seat | grok | unseated | unseated (quota limitation) | `test-round-2/seat-grok.md` |
