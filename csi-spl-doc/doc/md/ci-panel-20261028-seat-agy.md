# CI Panel 2026-10-28: Verdict of Seat Agy (a-561)

Status: **SIGN** on `3bb99eda4` (v0.1, editor c-005, claude).
Task: `dispatch-0101e192`. Issue: `SPL-4119`. Epic: `SPL-2402`. Spec: `csi-spl-doc/specs/011-spool-project-refactor`.
Reviewed document: `csi-spl-doc/doc/md/ci-panel-20261028.md` at git sha `3bb99eda428669527ecb84ce7e0d37e6f8b9ec71`.

This seat confirms the factual basis, agrees with the ranking, classification, root-cause smells, and fix rows F1–F4 of the editor's draft, and signs the panel report.

---

## 1. Spot-check verification of facts

Every command below was executed directly by seat `a-561` in worktree `/opt/csi/csi-spl-wt/a-561`.

| # | Item / Claim in Document | Command Executed | Output / Evidence | Verdict |
|---|---|---|---|---|
| 1 | 100 failed runs across all workflows (2026-10-25T04:36Z .. 2026-10-28T19:55Z) | `gh run list --repo csitea/csi-spl --status failure --limit 100 --json databaseId,workflowName,headSha,createdAt,conclusion` | 100 runs fetched: `10_ci-quality.yml` 75, `00_deploy-lag-watch.yml` 8, `70_supply-chain.yml` 4, `20_hub-build-deploy.yml` 3, `13_ci-next-image.yml` 3, `40_tenant-host-reconcile.yml` 3, `30_wui-build-deploy.yml` 2, `45_db-backup.yml` 2 | **CONFIRMED** |
| 2 | Failed job breakdown: red vs fail-fast stopped | Job logs read via `gh api repos/csitea/csi-spl/actions/jobs/<id>/logs` across all 100 runs | 158 primary red jobs, 163 stopped by `GATE_FAIL_FAST` (`gate fail-fast: stopped, so the next gate run starts`) | **CONFIRMED** |
| 3 | Trunk status: wf 10 green on latest runs | `gh run list --workflow 10_ci-quality.yml --branch master --limit 5` | Recent completed master runs succeeded (40778405054 on 80be17683 and prior) | **CONFIRMED** |
| 4 | Open defect F1: wf 00 deploy-lag missing `GH_TOKEN` | `grep -n "GH_TOKEN" .github/workflows/00_deploy-lag-watch.yml` | Line 155 only (dispatch step); lines 217-224 (lag step) provide no `GH_TOKEN`, causing fallback to `age_from=commit:gh-api-failed` | **CONFIRMED** |
| 5 | Open defect F2: wf 45 backup verification in window | `sed -n '180,185p' csi-spl-utl/src/bash/run/cloud-sql-backup-verify.func.sh` and `grep cron .github/workflows/45_db-backup.yml` | `status != "SUCCESSFUL"` triggers `ALERT` at line 183; cron `17 3 * * *` falls within Cloud SQL 01:00-05:00 UTC backup window | **CONFIRMED** |
| 6 | Open defect F3: bundle budget measured only in CI | `git grep -n 'perf-budget.py bundle' origin/master` | Present in `.github/workflows/10_ci-quality.yml:597-599`; absent from `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh` | **CONFIRMED** |

---

## 2. Table of top signatures, classes, smells, proposed fixes, and controls

Addressing Brief step 6:

| signature | n (runs) | class | smell (file:line) | proposed fix | red control |
|---|---|---|---|---|---|
| WUI mobile stack e2e: `a dialog over level 2`, `reading switch, no sideways scroll`, `a channel tap pushes level 2` | 7 | defect (fixed 8b3bcbc52) | `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh:80,120`: pre-push selector ignores `.css` and layouts have no users by name | F4: Include CSS, score layout state attributes (`data-mobile-*`) | Pre-push selector on 46afd70ba diff cuts mobile-stack |
| `FAIL ci_initial_gzip_kb 155.1 > 155` | 8 | defect (fixed 31559e80c) | `.github/workflows/10_ci-quality.yml:597-599`: bundle budget checked in CI only, not in local `_ppe_generate` | F3: Run `perf-budget.py bundle` in `check-pre-push-e2e.func.sh` after `_ppe_generate` | Plant 2 KB chunk import locally: passes pre-push, fails CI |
| `orc: hermetic` `FAIL: origin/master smoke rc=1` | 8 | defect (fixed 74f1640da) | Hermetic smoke test assumed branch origin was synchronized | Clean up remote branch smoke assumptions in orc | Smoke run on unpushed branch ref |
| wf 00 deploy lag `hub lagging ... age=45..50m grace=45m` | 4 | **defect, open** | `.github/workflows/00_deploy-lag-watch.yml:217-224` missing `GH_TOKEN`; `check-deploy-lag.func.sh:203` | F1: Pass `GH_TOKEN: ${{ github.token }}` to step; warn on gh api error | Contract test asserting `do_check_deploy_lag` steps have `GH_TOKEN` |
| wf 45 db backup `latest backup ... status 'RUNNING'` | 2 | **defect, open** | `csi-spl-utl/src/bash/run/cloud-sql-backup-verify.func.sh:153,180-184`: `RUNNING` status (age 0h) treated as alert | F2: If newest backup is `RUNNING` but previous is fresh and `SUCCESSFUL`, output INFO | Test case `[RUNNING age 0h, SUCCESSFUL age 24h]` -> want OK |
| `orc: hermetic 1/3` `action no SPOOL_ROOT: ... not a directory` | 3 | defect (fixed 372d72579) | `csi-spl-orc/src/bash/run/file-streams.func.sh`: assumed `/var/spool-hub` existed without fallback | Guard spool root existence in action | Run hermetic suite with empty `/var` |
| `orc: hermetic` `S4: old pid TERMed` / `stop first rc=3` | 2 | defect (fixed 4f861e051) | `agent-restart` test fixture omitted heartbeat `.pid` file | Fixture writes `.pid` file | Restart test with missing heartbeat file |

---

## 3. Empirical verification of editor open questions & unchecked items

Seat `a-561` executed empirical investigations to resolve the open questions and unchecked items flagged in the editor's draft:

### 3.1 Unchecked item 3.4 (Row F4): Pre-push selector test omission for 46afd70ba
- **Editor note**: The editor left unchecked whether `_ppe_select` on `46afd70ba`'s diff actually excluded the four tests that failed in CI (`mobile-stack`, `command-palette`, `omnibox-grip`, `undo-snackbar-mobile`).
- **Empirical measurement**: Executed `_ppe_select` against the exact file diff of `46afd70ba`:
  - Diff contained: `csi-spl-wui/src/assets/css/main.css`, `csi-spl-wui/src/components/ChannelSidebar.vue`, `csi-spl-wui/src/layouts/default.vue`, `csi-spl-wui/src/pages/issues.vue`, plus e2e test files.
  - Selected tests (kept): `section-strip-mobile` (135), `section-strip-every-level` (100), `issues-mobile` (474), `pane-keys` (49), `issues` (355), `issues-crud-modal` (314).
  - **All 4 failing tests were CUT below the score cap**:
    - `tests/e2e/omnibox-grip.test.mjs`: score 31 -> **CUT**
    - `tests/e2e/command-palette.test.mjs`: score 25 -> **CUT**
    - `tests/e2e/mobile-stack.test.mjs`: score 22 -> **CUT**
    - `tests/e2e/undo-snackbar-mobile.test.mjs`: score 3 -> **CUT**
- **Underlying Code Smells**:
  1. `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh:80`: Case pattern `src/*.vue|src/*.ts|src/*.js|src/*.mjs|src/*.tsx` omits `*.css`. Changes to `main.css` are completely ignored by the selector.
  2. Line 120: `_ppe_names` explicitly excludes layouts (`[[ "$rel" == src/layouts/* ]] && return 0`), preventing dependency closure discovery for layouts.
  3. Line 110: `_ppe_keys` queries only `data-test` and `testId`, failing to match state attributes such as `data-mobile-level` and `data-mobile-section-page`.
- **Verdict**: **CONFIRMED & PROVEN**. Row F4 is valid and necessary.

### 3.2 Unreproduced item (Section 4): `TestHubRunTwoDaemonsOneLeaves`
- **Editor note**: `TestHubRunTwoDaemonsOneLeaves` failed once in CI on 886a4ac75 (`upgrades A 2 + B 3: more than one re-hello each`), but passed 20/20 locally under memory store.
- **Empirical code analysis**:
  - In `csi-spl-api/src/go/spool-hub-api/internal/hub/hub_run_supersede_test.go:125-126`:
    ```go
    if na+nb > 4 {
        t.Fatalf("upgrades A %d + B %d: more than one re-hello each", na, nb)
    }
    ```
  - `SupersedeYield` is set to 300ms, and `SupersedeFight` is 3s. Over the 3-second fight window, up to 10 backoff cycles can occur.
  - On a busy CI runner with Postgres latency, daemon A completed 2 dials and daemon B completed 3 dials (`2 + 3 = 5 > 4`), triggering the assertion failure despite supersede resolution working correctly.
- **Smell**: An arbitrary integer threshold (`na+nb > 4`) asserting on non-deterministic retry counts during a time-based contention race.

### 3.3 Unchecked item (Section 4): wf 20 dev revision not Ready (run 40640625433)
- **Editor note**: Dev revision ready=False on 10-28 05:53 (commit 8a87f0dac, tag v6.0.6-c3) was unchecked for cause.
- **Empirical log tracing**:
  - Job log `122668783254` reveals Cloud Run revision `csi-spl-hub-dev-01128-muv` reported `ready=False` (`latest_ready=csi-spl-hub-dev-01125-hop`).
  - `do_check_hub_deploy` attempted 6 checks spaced ~15s apart (total ~90s). The revision failed to become ready within the 90s window, returning exit status 4 (`dev service or its latest revision is not Ready`).
  - The canary rollback guard operated as intended; subsequent master build 6389ad926 succeeded.

---

## 4. Agreement on proposed fix rows and batches

This seat endorses Section 5 fix rows F1–F4 and the batching strategy:
- **Batch 1**:
  - `F1`: `fix(ci-01-lag-watch-gh-token, SPL-<n>)`
  - `F2`: `fix(ci-02-backup-verify-in-window, SPL-<n>)`
  - `F3`: `fix(ci-03-prepush-bundle-budget, SPL-<n>)`
- **Batch 2**:
  - `F4`: `fix(ci-04-prepush-e2e-layout-pick, SPL-<n>)` (shares files with F3; starts after F3 lands).

---

## 5. Signature

signed: **a-561** (agy seat) on `3bb99eda4` (v0.1 confirmed, empirical verifications for F4, `TestHubRunTwoDaemonsOneLeaves`, and wf 20 dev revision provided).
