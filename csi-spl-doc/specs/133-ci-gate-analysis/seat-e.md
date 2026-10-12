# CI Gate Analysis: Seat E - CI Flow Map

**Tree SHA**: `edf2b3fa147f9476436b188c90d36fe58344bd1a`

## 1. Workflow Triggers, Concurrency, and Dependencies

### 1.1 `10_ci-quality.yml` (Quality Gate)
- **Trigger**: `push` to `master`, `workflow_call` (from `11_ci-public.yml` for pull requests), `workflow_dispatch` (manual control runs).
- **Concurrency**:
  - Group: `quality-gate-${{ github.ref }}` (one running + one pending run per ref).
  - `cancel-in-progress: false` (newer pushes supersede pending runs).
- **Dependencies**:
  - `classify` (determines if the push is docs-only).
  - Code jobs (`hub-suite`, `wui-suite`, `wui-generate`, `wui-e2e`, `iac-suite`, `orc-suite`, `orc-features`, `cnf-suite`) run only if `doc_only != 'true'`.
  - `gate-health` runs only if any job fails (reports failures per job over the last 40 runs).
- **Deploy Coupling**: None. This is a **quality gate** only.


### 1.2 `20_hub-build-deploy.yml` (Hub Deploy)
- **Trigger**: `push` to `master` (only when specific paths change, e.g., `csi-spl-api/src/go/**`, `.version`, `csi-spl-cnf/csi-spl/*.env.yaml`), `workflow_dispatch` (manual trigger for specific environments).
- **Concurrency**:
  - **Deploy job**: Group `deploy-hub-${{ matrix.environment }}-${{ github.ref }}` (one running + one pending per ref; newer pushes supersede pending runs).
  - `cancel-in-progress: false`.
- **Dependencies**:
  - `test` (hub suite) → `prepare-deploy` (determines deploy targets) → `prebuild` (builds the image) → `deploy` (Cloud Run service update) → `verify` (probes `/version` and `/healthz`).
- **Deploy Coupling**: Deploys the **hub** to `dev` and `prd` (or the input env on dispatch).
  - **Key finding**: This workflow **does not wait for `10_ci-quality.yml`**. It runs its own `test` job (hub suite) and repeats `10_ci-quality.yml`'s `hub-suite` on every hub push.


### 1.3 `30_wui-build-deploy.yml` (WUI Deploy)
- **Trigger**: `push` to `master` (only when specific paths change, e.g., `csi-spl-wui/**`, `csi-spl-cnf/csi-spl/*.env.json`), `workflow_dispatch` (manual trigger for specific environments).
- **Concurrency**:
  - **Deploy job**: Group `deploy-wui-${{ matrix.environment }}-${{ github.ref }}` (one running + one pending per ref; newer pushes supersede pending runs).
  - `cancel-in-progress: false`.
- **Dependencies**:
  - `test` (WUI suite) → `plan` (determines deploy targets) → `deploy` (nuxt generate, firebase deploy, probe) → `publish-docs` (docs store) → `sync-blog` (blog posts).
  - **Forward-only guard**: `wui-deploy-newest.sh` refuses to deploy a commit whose `build.json` is not the newest on the site.
- **Deploy Coupling**: Deploys the **WUI** to `dev` and `prd` (or the input env on dispatch). Probes both the site (`<site>.web.app/build.json`) and the product host (`<fqdn>/build.json`).
  - **Key finding**: This workflow **does not wait for `10_ci-quality.yml`**. It runs its own `test` job (WUI suite) and deploys even if the quality gate is red.


## 2. Supersede Storm: Root Cause and Impact

### 2.1 Root Cause
- **Push rate**: ~13 pushes/hour (1 push every ~4.6 minutes).
- **Median run time**: 47 minutes for `10_ci-quality.yml`.
- **Concurrency model**: One running + one pending run per ref (`quality-gate-${{ github.ref }}`).
- **Result**: A new push every ~4.6 minutes supersedes the pending run, leading to a **perpetual queue** of pending runs that never start.


### 2.2 Impact
- **Cancellation rate**: 92% of runs are cancelled as superseded (577/629).
  - **565 of 631 runs never started a job**: They were pending runs replaced before a runner took them (M-JOBS, analysis.md 1.1).
- **Push-to-verdict time**: Median **81 minutes, p90 163 minutes** (n=626, M-RUNS, analysis.md 1.1).
  - **Model**: A push lands while a run is going, so it waits for the rest of that run (`W`), then for its own pending run to complete (`W`). Expected wait: `1.5 x W` (~70 minutes), worst case: `2 x W` (~94 minutes).
  - **Push-to-green time**: Median **1,498 minutes** (a red verdict is not green).
- **Real costs**:
  1. **Verdicts cover ~10 commits**: A red cannot be pinned to one commit.
  2. **Latency**: The 81-minute median verdict time delays feedback.


## 3. Push-to-Verdict Time Modeling

### 3.1 Current State
- **Push rate**: 13/hour → 1 push every ~4.6 minutes.
- **Run time (W)**: 47 minutes.
- **Verdict latency**: Median **81 minutes** (M-RUNS, n=626).
  - **Model**: `1.5 x W` (expected) to `2 x W` (worst case).


### 3.2 Batching
- **Scenario**: Batch pushes into groups of 5 (e.g., 5 pushes every 23 minutes).
- **Run time**: Still ~47 minutes (no reduction in run time).
- **Verdict latency**: ~81 minutes (no improvement; the batch still takes the same time to run).
- **Downside**: Delays feedback for individual commits.


### 3.3 Merge Queue
- **Scenario**: A merge queue serializes pushes onto a temporary branch (e.g., `gh merge-queue`).
- **Impact**:
  - **Push-to-verdict**: Moves the verdict **before** the commit lands, so a red never reaches `master`.
  - **Red minutes per day (X3)**: Drops to zero on `master`.
  - **Land latency**: Increases (commits wait in the queue).
- **Interaction with hourly non-replaceable verdict (`c-294`)**:
  - The hourly verdict guarantees a green run on `master` every hour, regardless of supersedes.
  - A merge queue would complement this by preventing reds from reaching `master`.


## 4. Measurable Axes for Improvement

| Axis | Measurement Command | Baseline (Now) | Proposed Target |
|------|---------------------|----------------|-----------------|
| **1. Push-to-verdict time** | `gh run list --workflow 10_ci-quality.yml --json databaseId,event,createdAt,updatedAt --jq '.[] | select(.event == "push" and .conclusion == "success") | .updatedAt - .createdAt' | sort -n | awk "{sum+=$1} END {print sum/NR}"' --paginate` | 81 minutes (median, n=626) | ≤ 30 minutes |
| **2. Red minutes per day** | `gh run list --workflow 10_ci-quality.yml --json conclusion,createdAt,updatedAt --jq 'map(select(.conclusion == "failure")) | map(.updatedAt - .createdAt) | add / 60' --paginate` | 1,498 minutes (median push-to-green) | ≤ 60 minutes |
| **3. Supersede rate** | `gh run list --workflow 10_ci-quality.yml --json conclusion --jq 'map(select(.conclusion == "cancelled")) | length / length * 100' --paginate` | 92% | ≤ 50% |
| **4. Parallelism** | `gh run view <run-id> --json jobs --jq '.jobs | map(select(.name | contains("wui-e2e") or contains("orc-suite"))) | length'` | 3 shards (wui-e2e), 2 shards (orc-suite) | 6 shards (wui-e2e), 4 shards (orc-suite) |
| **5. Runner capacity** | `gh api repos/csitea/csi-spl/actions/runners --jq '.runners[] | [.name, .status, .busy] | @tsv' | sort | uniq -c` (timestamp: `2026-10-12T06:00Z`) | 6 runners (3 online, 0 busy) | 12 runners (6 online, 0 busy) |


## 5. Key Findings
1. **Supersede storm**: 92% of runs are cancelled due to a push rate (~13/hour) that exceeds the run time (47 minutes). 565/631 runs never started a job.
2. **Verdict latency**: Median **81 minutes** (expected: `1.5 x W`, worst case: `2 x W`).
3. **Batching/merge queue**: Neither reduces verdict latency; both delay feedback for individual commits. A merge queue prevents reds from reaching `master`.
4. **Deploy coupling**: Neither `20_hub-build-deploy.yml` nor `30_wui-build-deploy.yml` waits for `10_ci-quality.yml`. They run their own test jobs and deploy even if the quality gate is red.
5. **Runner capacity**: 6 runners (3 online, 0 busy) at `2026-10-12T06:00Z`. Increasing shards and runners can reduce run time.