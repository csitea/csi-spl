# Refactoring round CI-2 - plan

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-3516 (status wip)  

Owner HUM-10 directives & fleet rules:
- Owner msg 8cb6cc7d: lane-share band for refactoring is **20-30%** ([fleet-rules-index.md](fleet-rules-index.md)).
- Owner HUM-10 directive (msg b8e22a15): **"do not ask me for input - just reach consensus between all of the members of the panel and start implementation"**.
- Owner HUM-10 directive (msg 3d22fcea): rounds run continuously, embedded in core operation, no owner go needed.
- Owner 10-17 directive (t1 b61851fb msg 91bf8278): **no mistral coding rows** (docs and review only).
- WUI work assigned to **claude**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, push caps 1..1 up to 3 max 5, disjoint files per batch).

**Status: v0.2 review revision** (planner seat: **a-584@PC**, agy).  
Reviewer seat: **c-555@PC** (claude), assigned by current dispatch lease holder (`c-002@sat`) on task `1c120227-ce10-5ffd-895a-2168872fce83`.  

**One sha:** Every count, site, and input is measured on start sha **`a066b182e`** (`origin/master` a066b182e8a07de8ae379e56694a8fd83c1cf969, 2026-10-26), n=1 per command unless stated.

---

## 1. Inputs re-measurement and verification (on `a066b182e`)

Re-measurement of the 6 inputs from the CI failures panel (`csi-spl-doc/doc/md/ci-failures-100-2026-10-25.md` section 7 and brief):

| # | input | class | command on `a066b182e` | measured result | disposition |
|---|---|---|---|---|---|
| **I2** | Pre-push e2e part runs e2e files covering changed WUI component | Refactor row candidate | `cd csi-spl-iac && WUI_E2E_CHANGED="csi-spl-wui/src/components/MessageComposer.vue" ./run -a do_check_pre_push_e2e` | `tests/e2e/phone-composer-target.test.mjs` assigned score 9 and cut (`CUT tests/e2e/phone-composer-target.test.mjs 9 103`) behind 6 generic tests | **Reproduced.** Selected as **Row 01**. *(Promotion note per W3: Section 8 originally noted I2 as process work; promoted to refactor row because the defect is directly implemented in `check-pre-push-e2e.func.sh` where component heuristics drop direct covering tests, requiring bash refactoring of `_ppe_select` and `_ppe_cap`).* |
| **I4** | Scheduled wf 10 run on NEXT runner image on throwaway branch | Process / CI workflow | `git grep -n "schedule:" .github/workflows/10_ci-quality.yml` | Only hourly master verdict runs (`cron: '43 * * * *'`); no cron for runner canary; `vars.SPOOL_CI_RUNNER` sets runner image | **Process work, not a refactor row.** Recommended for dispatcher / ops scheduling. |
| **I10** | wf 70 osv red on serialize-javascript GHSA-m5mm-p8h7-m29v | Dependency work | `git log -1 2d19197d3 --format="%h %s" && grep -n "serialize-javascript" csi-spl-wui/pnpm-lock.yaml` | `2d19197d3 fix(wui deps, SPL-3391): wf 70 osv green - serialize-javascript 7.1.4, drop the unused braces ignore`. Lockfile has `serialize-javascript@7.1.4`. | **Not reproduced / Already fixed.** Landed on trunk at `2d19197d3`. Dependency update, not a refactor row. |
| **I11** | WUI layout review runs every e2e file matching changed component | Review process rule | `git grep -n "review:" csi-spl-doc/doc/md/rounds-rulebook.md` | Rulebook section 2.7.4 defines C1-C7 criteria; no automated component-to-e2e reviewer enforcement | **Process work, not a refactor row.** Procedural checklist addition for reviewer briefs. |
| **I13** | Trace wf 30 smoke reds (39480361834, 39717268991, 39757582395) | Ops / Investigation | `gh api repos/csitea/csi-spl/actions/runs/<id>` + job logs | Traced below: all 3 failed `do_spl_wui_live_proof` on live endpoints due to deployment propagation / 404 timing, not code regressions | **Investigation work, not a refactor row.** Findings recorded below. |
| **CI-sig** | Today's CI signatures (wf 10 last 100 runs) | Measurement | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 100 runs: 73 success, 22 cancelled, 5 failure. All 5 failures analyzed in section 2 below. | **Measured.** Yields Row 02. |

### 1.1 Trace of I13 (the three wf 30 smoke reds)
- **Run 39480361834** (dev, 2026-10-20 19:04Z, head `6ea526200`): docs/locale update only (`csi-spl-wui/i18n/locales/*.json`). Failed on step `FAIL t: 2 L2 is in the topic, in the main column` (live probe timed out waiting for message echo on `dev.spool-hub.ai`).
- **Run 39717268991** (prd, 2026-10-22 03:31Z, head `030ad6f2c`): WUI refactor `useCardKeys.ts`. Failed on step `FAIL channel: 1 hub stores L1 with is_parent 1 ***"status":404***` (`hubRows` queried `/v1/view/topics/<task>` and received HTTP 404 because topic message persistence lagged).
- **Run 39757582395** (prd, 2026-10-22 09:43Z, head `c175100bc`): utl workdir sweep only (`csi-spl-utl/`). Failed on `FAIL lobby: shows the lobby cards ***"cards":0***` and topic 404.
- **Conclusion**: None of the 3 runs was caused by a WUI bundle regression in the deployed commit. All 3 failed `do_spl_wui_live_proof` running against live Cloud Run / Firebase hosting environments due to transient topic propagation delays and 404 timing.

---

## 2. Today's CI gate analysis (measured on `a066b182e`)

Command: `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`  
Window: 2026-10-25T15:49:10Z .. 2026-10-26T09:57:51Z (100 runs on master):
- **73 success** (73%)
- **22 cancelled** (superseded pending runs)
- **5 failure** (5%)

Analysis of the 5 failed runs:
1. **40252668560** (head `7acb5ce1`, 2026-10-26T01:07Z): `orc: hermetic action tests 2/3` failed on `503 Service Unavailable` from external registry `mirror.gcr.io` during docker pull. Hub job stopped by `GATE_FAIL_FAST=1`. (Infra/network flake).
2. **40250420281** (head `c8e696c9`, 2026-10-26T00:39Z): `orc: feature tests` failed on `FAIL - fake sudo is up on the CLE-94 tty (waited 20107 ms; tty: ) (want '1', got '0')` in `test-spool-send.sh`. Fixed by `dd60d8043` (SPL-3409) and `5068a9285` (R-a, SPL-3453). All 5 other failed jobs were `GATE_FAIL_FAST` stops.
3. **40244469102** (head `b68740bf`, 2026-10-25T23:22Z): `iac suite` failed on `FAIL: 1. responsive server (rc=0 best=53ms out=INFO tmux-health OK socket=/tmp/thg.8s9Hyl/tt/tmux-1001/test-probe sessions=1 ms=11)` in `tmux-health-guard.tst.sh`. Bound was 50ms, exceeded under runner CPU load. Fixed on master in `87b1eb023` by relaxing bound to 500ms. Identical brittle latency bounds exist in `box-beat-telemetry.tst.sh` and `clock-sync-check.tst.sh`, yielding **Row 02**.
4. **40233594333** (head `caa8ffb2`, 2026-10-25T21:02Z): `orc: feature tests` failed on `FAIL - pane showing bash+sudo is alive: poked, exit 0 (want '0', got '7')` in `test-spool-send.sh`. Fixed by `dd60d8043` and `5068a9285` (R-a). All 5 other failed jobs were fail-fast stops.
5. **40224793692** (head `f0c811bd`, 2026-10-25T19:10Z): `orc: hermetic action tests 2/3` failed on `FAIL: 12. 0 false report(s) or recoveries in 2 ticks beside concurrent checkouts:` in `desk-cron-trunk.tst.sh` case 12 (git auto-maintenance racing with loose object clone). Fixed on master in `dea358a0f` (`maintenance.auto false`, `gc.auto 0`).

### 2.1 Notes on dropped candidate items (W1 and W2)
- **Candidate: hub-pg store group DB isolation (dropped per W1)**: Run 39510389592 failed in group b (not group a) on `TestPutFXRates` (`fx_test.go:96`), which was already fixed in `8993bf9ed` via `fxTestQuote` checks before quoting. Furthermore, running groups against a single `spool_hub_store` is an intentional architectural design (`fx_test.go:18-20`) required for the subsequent RLS check (`hub-pg.tst.sh:245`). The proposed red control would not fail on origin/master today. Dropped.
- **Candidate: orc git fixture auto-gc (dropped per W2)**: Run 40224793692 was resolved on master in `dea358a0f` for `desk-cron-trunk.tst.sh`. Expanding `maintenance.auto false` across other fixtures lacks a reproducible failing red control on origin/master today because local git 2.47 does not trigger background auto-maintenance. Dropped.

---

## 3. The refactor rows (Round CI-2)

Left out because owned by live lanes or queued rows:
- `report-ci-gate.func.sh` + gate health in `10_ci-quality.yml`: owned by live row **R-g** (lane `c-284@sat`).
- `tenant-host.tst.sh`: owned by live row **R-c** (lane `c-249@sat`).
- `check-hub-deploy.func.sh` (deploy-lag watch rolling): owned by queued row `c002-ci100-rb-w1-lag-watch-rolling`.

The 2 confirmed refactor rows for Round CI-2:

| # | row slug | practice | smell & why | sites file:line (max 5) | measurement on `a066b182e` | test & red control | target box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| **01** | `refactor(ci2-01-pre-push-e2e-component-map)` | Pre-push e2e selection, testability | **S1 / T1 (I2)**: `check-pre-push-e2e.func.sh` selects e2e tests for changed WUI files via `_ppe_keys` matching `[Tt]est[Ii]d` literals. Tests targeting components via CSS selectors/tags (e.g. `phone-composer-target.test.mjs`) receive score 9 and get CUT behind generic tests by `_ppe_cap` (max 6), allowing regressions like SPL-3190 to escape to master. | `iac:src/bash/run/check-pre-push-e2e.func.sh:96-187`<br>`iac:src/bash/tests/check-pre-push-e2e.tst.sh` | `WUI_E2E_CHANGED="csi-spl-wui/src/components/MessageComposer.vue" ./run -a do_check_pre_push_e2e` cuts `phone-composer-target` (score 9, weight 103s) behind 6 generic tests | Refactor `_ppe_select` and `_ppe_cap` in `check-pre-push-e2e.func.sh` so component edits prioritize their direct covering tests. Tests: `check-pre-push-e2e.tst.sh`. **Red control:** `WUI_E2E_CHANGED="csi-spl-wui/src/components/MessageComposer.vue" do_check_pre_push_e2e` outputs `CUT ... phone-composer-target` today; passes (selected in `_PPE_FILES`) after. | sat | claude | complex_coding | 1 |
| **02** | `test(ci2-02-utl-timing-asserts-resilience)` | Test reliability, timing resilience | **Brittle latency bounds in tests**: Run 40244469102 failed because `tmux-health-guard.tst.sh` asserted `ms < 50` on `./run` under runner load (fixed in `87b1eb023`). Identical tight upper bounds exist in `box-beat-telemetry.tst.sh` (`ms < 50`) and `clock-sync-check.tst.sh` (`ms < 100`), risking identical spurious CI failures under runner CPU load. | `utl:src/bash/tests/box-beat-telemetry.tst.sh:236-245`<br>`utl:src/bash/tests/clock-sync-check.tst.sh:228-237` | `box-beat-telemetry.tst.sh:240` asserts `ms < 50`; `clock-sync-check.tst.sh:232` asserts `ms < 100` | Relax `./run` harness latency assertions from 50ms/100ms to 500ms (matching `87b1eb023`), preventing load-induced flakes. Tests: `box-beat-telemetry.tst.sh`, `clock-sync-check.tst.sh`. **Red control:** Inject 60ms sleep in probe mock; fails today; passes under relaxed 500ms bound. | pc | claude | tests | 1 |

---

## 4. Disjoint files & batch ordering (R1)

All files within the batch are strictly disjoint:
- **Batch 1 (Parallel start):**
  - **Row 01:** `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh`, `csi-spl-iac/src/bash/tests/check-pre-push-e2e.tst.sh`
  - **Row 02:** `csi-spl-utl/src/bash/tests/box-beat-telemetry.tst.sh`, `csi-spl-utl/src/bash/tests/clock-sync-check.tst.sh`
  *(Disjoint trees: `csi-spl-iac` vs `csi-spl-utl`).*

---

## 5. Panel consensus & reviewer seats

- **Planner (editor seat):** `a-584@PC` (agy)
- **Reviewer seat:** `c-555@PC` (claude), assigned by dispatch lease holder `c-002@sat`.
  - v0.1: Review verdict **FAIL** with findings W1..W4 delivered on task `1c120227-ce10-5ffd-895a-2168872fce83` (msg `becdef10-93af-4c8e-9af0-224dda5da63b`).
  - v0.2: Folded reviewer findings (dropped candidate rows 03 and 04 per W1 and W2; added I2 promotion note per W3; noted planner box id per W4 (using @PC in repo docs as literal host name is banned by dist hygiene sweep)).

| seat | vendor | role | status / signature | commit sha |
|---|---|---|---|---|
| `a-584@PC` | agy | Planner / Editor | v0.2 submitted | pending |
| `c-555@PC` | claude | Panel Reviewer | Reviewing v0.2 | — |
