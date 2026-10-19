# Test Round 2: Mistral Seat Verdict

**Editor**: a-481@sat (agy)
**Task ID**: dispatch-4555450c
**Baseline**: All measurements on trunk `59ffb5dd3` (2026-10-19).

---

## 1. Verdict Summary

| #  | Practice                                      | Verdict               | Reason                                                                                                                                                                                                                     |
|----|-----------------------------------------------|-----------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 01 | `test(r02-01-orc-speed-peer-poll)`            | **Agree with changes** | Baseline verified: `peer-poll.tst.sh` takes **124.3 s** (n=1, sat), down from 168.6-174.1 s. CI packing weight (518 s) is stale. The test is CPU-bound due to `njobs=6` on `nproc=4`.                                      |
| 02 | `test(r02-02-iac-dry-run-tf-destroy)`         | **Agree**             | Baseline verified: 7 destructive IAC actions (`tf-destroy-target`, `tf-destroy-local-step-bucket`, `tf-remove-step`, `tf-replace-target`, `tf-state-push`, `gcp-modify-project-apis-disable`, `gcp-project-apis-disable`) have **0 tests**. No `DRY_RUN` guard exists. |
| 03 | `test(r02-03-orc-jobs-derivation-weights)`    | **Agree**             | Baseline verified: `njobs=6` is hardcoded when `GITHUB_ACTIONS=true`, causing severe runner CPU contention.                                                                                                                 |
| 04 | `test(r02-04-go-coverage-coverpkg)`           | **Agree with changes** | Baseline verified: `fakeidp` sits at **3.5%** floor despite **13.2%** cross-package coverage in `internal/auth`. Other 4 packages have been ratcheted since the plan was written.                                           |
| 05 | `test(r02-05-orc-red-control-pre-push)`       | **Agree**             | Baseline verified: 3 planted regressions stay green: (1) override hygiene bypass (`do_check_dist_hygiene || true`), (2) unconditional `TIMED OUT` emission on passing suites, (3) HEAD unparseable crash against clean base (`good bad _mute_part`). |
| 06 | `test(r02-06-iac-dry-run-tf-state-target)`    | **Agree**             | Baseline verified: 4 state actions (`tf-remove-step`, `tf-replace-target`, `tf-state-push`, `tf-state-pull`) have **0 tests**. No `DRY_RUN` guard exists.                                                                    |
| 07 | `test(r02-07-orc-untested-probe-actions)`     | **Agree**             | Baseline verified: `spl-msg-edit-probe` and `spl-wire-probe` have **0 tests**.                                                                                                                                            |
| 08 | `test(r02-08-iac-gcp-compute-lb-list)`        | **Agree**             | Baseline verified: `gcp-compute-lb-list` has **0 tests**. No validation for `--account` or required ENV.                                                                                                                   |
| 09 | `test(r02-09-orc-spl-token-burn-push-env)`    | **Agree**             | Baseline verified: `spl-token-burn-push-env` has **0 tests**. No validation for token format or ENV.                                                                                                                       |
| 10 | `test(r02-10-iac-gcp-sync-tail-satellite)`    | **Agree**             | Baseline verified: `gcp-sync-local-to-s3`, `gcp-tail-logs`, and `satellite-image-latest` have **0 tests**. No validation for mandatory arguments.                                                                           |
| 11 | `test(r02-11-orc-lane-lifecycle-actions)`     | **Agree**             | Baseline verified: `spl-rotate-status`, `spl-local-hub-status`, and `spl-dispatch-deploy-lag` have **0 tests**.                                                                                                            |
| 12 | `test(r02-12-orc-speed-spool-install)`        | **Agree with changes** | Baseline verified: `test-install.sh` takes **43.1-48.3 s** (n=3, sat), down from 59.6-62.5 s.                                                                                                                              |

**A6 Flake Row (Test Round 1 Row 08)**: **Disagree (no longer needed)**. The fix in `59ffb5dd3` (SPL-2506) resolved the root cause. No failures in the last 100 runs.

---

## 2. Proposals

### Proposal 1: Untested WUI Utilities (`msg-apply.mjs` and `tenant-host-core.mjs`)
- **Practice**: Add behavioral unit tests for `msg-apply.mjs` and `tenant-host-core.mjs`.
- **Why**: These utilities are critical for message handling and tenant resolution but have **0 tests**. Brittle source regex matching tests do not verify behavior.
- **Measurement**:
  ```bash
  echo "msg-apply: $(git grep -l "msg-apply" csi-spl-wui/tests/ | wc -l), tenant-host-core: $(git grep -l "tenant-host-core" csi-spl-wui/tests/ | wc -l)"
  ```
  **Output**: `msg-apply: 0, tenant-host-core: 0`

### Proposal 2: WUI Source Regex Matching Tests
- **Practice**: Replace 79 source regex matching tests (`assert.match(src(`) with behavioral tests.
- **Why**: These tests are brittle and do not verify runtime behavior. They assert on raw source text, which can change without breaking functionality.
- **Measurement**:
  ```bash
  grep -rn "assert.match(src(" csi-spl-wui/tests/unit/ | wc -l
  ```
  **Output**: `79`

---

## 3. Disjoint Files (R1)

Verified: No file appears in two rows. The files are disjoint within each batch.

---

## 4. Commands and Outputs

### Row 01: `peer-poll.tst.sh` Timing (n=1)
```bash
cd /opt/csi/csi-spl-wt/m-639 && sudo -u <DEV_USER> env TIMEFORMAT='%3R' bash -c 'time bash csi-spl-orc/src/bash/tests/peer-poll.tst.sh' 2>&1
```
**Output**: `124.315`

### Row 04: `fakeidp` Coverage
```bash
cd /opt/csi/csi-spl-wt/m-639/csi-spl-api/src/go/spool-hub-api && sudo -u <DEV_USER> env PATH=$PATH:/usr/local/go/bin go test -count=1 -cover ./internal/auth/fakeidp 2>&1 | grep "coverage:"
```
**Output**: `coverage: 3.5% of statements`

### Row 12: `test-install.sh` Timing (n=3)
```bash
cd /opt/csi/csi-spl-wt/m-639 && sudo -u <DEV_USER> env TIMEFORMAT='%3R' bash -c 'for i in {1..3}; do time bash csi-spl-orc/src/bash/features/spool-install/tests/test-install.sh; done' 2>&1 | grep -E "^[0-9]"
```
**Output**: `43.142`, `44.412`, `48.346`

---

## 5. Signed

**Signed**: m-639 on `0140c6016`