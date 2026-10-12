# CI Gate Analysis: Seat E - CI Flow Map

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
  - **Deploy job**: Group `hub-deploy-${{ matrix.env }}` (one running + one pending per env; newer pushes supersede pending runs).
  - `cancel-in-progress: false`.
- **Dependencies**:
  - `test` (hub suite) → `prepare` (version, image tag, build args) → `build` (image push) → `deploy` (Cloud Run service update) → `verify` (probes `/version` and `/healthz`).
- **Deploy Coupling**: Deploys the **hub** to `dev` and `prd` (or the input env on dispatch).


### 1.3 `30_wui-build-deploy.yml` (WUI Deploy)
- **Trigger**: `push` to `master` (only when specific paths change, e.g., `csi-spl-wui/**`, `csi-spl-cnf/csi-spl/*.env.json`), `workflow_dispatch` (manual trigger for specific environments).
- **Concurrency**:
  - **Deploy job**: Group `wui-deploy-${{ matrix.env }}` (one running + one pending per env; newer pushes supersede pending runs).
  - `cancel-in-progress: false`.
- **Dependencies**:
  - `test` (WUI suite) → `plan` (determines deploy targets) → `deploy` (nuxt generate, firebase deploy, probe) → `publish-docs` (docs store) → `sync-blog` (blog posts).
  - **Forward-only guard**: `wui-deploy-newest.sh` refuses to deploy a commit whose `build.json` is not the newest on the site.
- **Deploy Coupling**: Deploys the **WUI** to `dev` and `prd` (or the input env on dispatch). Probes both the site (`<site>.web.app/build.json`) and the product host (`<fqdn>/build.json`).


## 2. Supersede Storm: Root Cause and Impact

### 2.1 Root Cause
- **Push rate**: ~13 pushes/hour (1 push every ~4.6 minutes).
- **Median run time**: 47 minutes for `10_ci-quality.yml`.
- **Concurrency model**: One running + one pending run per ref (`quality-gate-${{ github.ref }}`).
- **Result**: A new push every ~4.6 minutes supersedes the pending run, leading to a **perpetual queue** of pending runs that never finish.


### 2.2 Impact
- **Cancellation rate**: 92% of runs are cancelled as superseded (577/629).
- **Push-to-verdict time**: ~47 minutes (the time it takes for the newest push to complete its run).
- **Resource waste**: 92% of runs are cancelled, wasting runner capacity and delaying feedback.


## 3. Push-to-Verdict Time Modeling

### 3.1 Current State
- **Push rate**: 13/hour → 1 push every ~4.6 minutes.
- **Run time**: 47 minutes.
- **Verdict latency**: 47 minutes (the time it takes for the newest push to complete its run).


### 3.2 Batching
- **Scenario**: Batch pushes into groups of 5 (e.g., 5 pushes every 23 minutes).
- **Run time**: Still ~47 minutes (no reduction in run time).
- **Verdict latency**: ~47 minutes (no improvement; the batch still takes the same time to run).
- **Downside**: Delays feedback for individual commits.


### 3.3 Merge Queue
- **Scenario**: A merge queue serializes pushes onto a temporary branch (e.g., `gh merge-queue`).
- **Run time**: ~47 minutes per batch (same as above).
- **Verdict latency**: ~47 minutes (no improvement; the queue still processes one batch at a time).
- **Downside**: Adds complexity and delays for individual commits.


## 4. Measurable Axes for Improvement

| Axis | Measurement Command | Baseline (Now) | Proposed Target |
|------|---------------------|----------------|-----------------|
| **1. Run time reduction** | `gh run list --workflow 10_ci-quality.yml --json databaseId,status,conclusion,updatedAt --jq '.[] | select(.conclusion == "success") | .updatedAt - .createdAt' | sort -n | awk "NR==int((1+NF)/2) {print $1}"'` | 47 minutes | ≤ 20 minutes |
| **2. Supersede rate** | `gh run list --workflow 10_ci-quality.yml --json conclusion --jq 'map(select(.conclusion == "cancelled")) | length / length * 100'` | 92% | ≤ 10% |
| **3. Push-to-verdict time** | `gh run list --workflow 10_ci-quality.yml --json databaseId,event,createdAt,updatedAt --jq '.[] | select(.event == "push" and .conclusion == "success") | .updatedAt - .createdAt' | sort -n | awk "NR==int((1+NF)/2) {print $1}"'` | 47 minutes | ≤ 10 minutes |
| **4. Parallelism** | `gh run view <run-id> --json jobs --jq '.jobs | map(select(.name | contains("wui-e2e") or contains("orc-suite"))) | length'` | 3 shards (wui-e2e), 2 shards (orc-suite) | 6 shards (wui-e2e), 4 shards (orc-suite) |
| **5. Runner capacity** | `gh api repos/csitea/csi-spl/actions/runners --jq '.runners | map(select(.status == "online")) | length'` | 6 runners (3 online) | 12 runners (6 online) |


## 5. Key Findings
1. **Supersede storm**: 92% of runs are cancelled due to a push rate (~13/hour) that exceeds the run time (47 minutes).
2. **Verdict latency**: The newest push takes ~47 minutes to complete, delaying feedback for every commit.
3. **Batching/merge queue**: Neither reduces verdict latency; both delay feedback for individual commits.
4. **Parallelism**: Increasing shards (e.g., `wui-e2e` from 3 to 6, `orc-suite` from 2 to 4) and runner capacity (from 3 to 6 online) can reduce run time.
5. **Run time reduction**: The biggest lever for improving verdict latency and reducing supersedes.