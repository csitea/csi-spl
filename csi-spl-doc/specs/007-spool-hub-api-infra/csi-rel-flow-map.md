# csi-rel → csi-spl provisioning flow map

The owner's orders (2026-09-19): csi-spl provisions and deploys the way
csi-rel does. It uses the per-project SA keys, and terraform runs only
through csi-rel's make → tf-runner container path, never on the host. The
csi-rel shell actions and make targets are copied **unchanged**. When one
fails in csi-spl, the fix goes into csi-spl's **config / setup**. Every
difference from the csi-rel source is listed here with its reason.

The owner's requirements themselves (R1…) are in
[`infra-provisioning-requirements.md`](infra-provisioning-requirements.md).
This file does not repeat them. It maps the csi-rel flow onto csi-spl.

Companion tables, one per lane:

| table | covers |
|---|---|
| [`csi-rel-gcp-actions.md`](csi-rel-gcp-actions.md) | all 52 csi-rel `gcp-*` actions: in csi-spl already / ported / not ported + reason |
| [`csi-rel-tf-callers.md`](csi-rel-tf-callers.md) | the 55 csi-rel files that mention terraform: import scripts, tf-quality, deploy scripts, … |
| this file | the end-to-end path: bootstrap → make → container → `./run` → terraform, and the tf-* wrappers |

## 1. The flow, end to end

| # | csi-rel | csi-spl | status |
|---|---|---|---|
| 1 | one human `gcloud auth login` as the org admin | same (`csi-spl-iac/README.md` §Bootstrap) | same |
| 2 | `./run -a do_gcp_000_bootstrap_gcp_env` per env → 001 project, 002 SA + key `~/.gcp/.<org>/key-<org>-<app>-<env>.json`, 003 `roles/owner`, 004 bootstrap APIs | same actions in `csi-spl-iac/src/bash/run/gcp-00{0..4}-*.func.sh` | adapted earlier (c422cc7, 8bba4e2): dry run by default, `--account` on every call, no `gcloud config set` |
| 3 | `cd csi-rel-orc && make do-setup-app-inf`: `docker compose -f docker-compose-infra.yaml` down/build/up tf-runner, tpl-gen, conf-validator; then `./run -a do_check_container_dns` | `cd csi-spl-orc && make do-setup-app-inf` using `docker-compose-tf-infra.yaml` | ported, config differences in §3 |
| 4 | `ENV= STEP= make do-generate-config-for-step`: conf-validator, then tpl-gen in their containers → `<env>/tf/<step>.{vars,backend-config}.tfvars` | same target (9c57631, CLE-3359), validating the MERGED effective config (§3.1) | ported. Verified on the box stack at 4997bc3: dev 031 → VALIDATED, rendered, tree unchanged |
| 5 | `ENV= STEP= make do-tf-plan / do-provision / do-deprovision / do-tf-*`: `docker exec con-<org>-<app>-tf-runner ./run -a do_<action>` | same targets (`csi-spl-orc/src/make/tf-tasks.func.mk`), container `con-csi-csi-spl-tf-runner` | ported unchanged |
| 6 | in the container: `do_provision` → `do_tf_init` (`GOOGLE_APPLICATION_CREDENTIALS=~/.gcp/.$ORG/key-${GCP_PROJECT}.json`, env.json sections exported, step + `../modules` copied to `bin/<org>/<app>/<env>/<step>`, `tfswitch $TERRAFORM_VERSION`) → `terraform init -backend-config=… && apply -var-file=…` | same files in `csi-spl-iac/src/bash/run/` | ported unchanged (1e1ee73) |
| 7 | step `120-github-general-secrets` publishes the keys to GitHub | csi-spl step 120 publishes `GCP_KEY_CSI_SPL_<ENV>` (fe19c96, CLE-3355). Its local-exec `gh secret set` runs in the tf-runner, so the image adds `gh` (§3) | adapted by CLE-3355 |
| 8 | workflows authenticate with the published key or WIF | same pattern (§5) | adapted by CLE-3355 / CLE-3354 |

## 2. The iac tf-* wrappers (csi-rel-iac `src/bash/run` → csi-spl-iac `src/bash/run`)

Measured with `diff <(sed 's/csi-rel/csi-spl/g' <csi-rel file>) <csi-spl file> | grep -c '^[<>]'`
on csi-rel tree e4612828 (n=1 per file).

| csi-rel action | csi-spl | non-name diff lines |
|---|---|---|
| `tf-init` | ported | 2: one comment line, `"rel"` → `"spl"` in an example |
| `tf-plan` | ported. **Replaces** csi-spl's native `do_tf_plan` (local-state guard, `TF_OFFLINE_PLAN`) | 0 |
| `tf-apply`, `tf-apply-target`, `tf-destroy`, `tf-destroy-target`, `tf-import`, `tf-replace-target`, `tf-taint-target`, `tf-untaint-target` | ported | 0 |
| `tf-state-list`, `tf-state-pull`, `tf-state-push`, `tf-state-remove`, `tf-state-show` | ported | 0 |
| `tf-apply-local-step-bucket`, `tf-destroy-local-step-bucket` | ported | 0 |
| `tf-new-step`, `tf-remove-step` | ported | 0 (they expect csi-rel's `lib/tpl/terraform/step*` templates, which csi-spl does not have yet) |
| `provision`, `divest` | ported | 0 |
| `export-json-section-vars-as-tf-vars` (+ lib `export-json-section-vars`) | ported | 1 comment: `/opt/<org>/…` example path made generic |
| lib `require-var` (defines `do_simple_log`, which tf-apply uses) | replaces csi-spl's copy | 0 |

Config/setup changes these needed (not logic):

| change | why |
|---|---|
| `env.versions.infra_version` in `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` (+ re-rendered env.json) | `tf-init` reads `${INFRA_VERSION}` under `set -u` |
| `csi-spl-iac/src/terraform/modules/` (README only) | `tf-init` copies and md5-compares `src/terraform/modules` on every run |

What changed in behaviour:

- `tf-init` wipes `bin/<org>/<app>/<env>/<step>` on every run. The native
  `do_tf_plan` refused to wipe a run dir that held a `terraform.tfstate*`.
  All csi-spl steps keep their state in gcs, so no run dir holds a state.
  CLE-3355 checked this in its worktree and in the main checkout: none.
- There is no offline plan (`TF_OFFLINE_PLAN`) any more. A plan needs the
  project key.
- **The key must exist.** `tf-init` has no explicit check for it (csi-rel
  has none). Measured instead: with `GOOGLE_APPLICATION_CREDENTIALS` pointing
  at a missing key and a user ADC present in `$HOME`, `terraform init` of
  the gcs backend refuses and names the missing file. It does not fall back
  to the ADC. `csi-spl-iac/src/bash/tests/tf-init-project-key.tst.sh`,
  terraform 1.9.8, n=1 per run.

## 3. The orc make layer + docker infra stack (csi-rel-orc → csi-spl-orc)

| csi-rel file | csi-spl file | non-name diff lines / change |
|---|---|---|
| `Makefile` | `Makefile` | reads `src/docker/tf-infra.env` instead of `src/docker/.env`; the compose file is `docker-compose-tf-infra.yaml`; `DOCKER_COMPOSE_CMD` is defined here (csi-rel: `src/make/setup-app.func.mk`, not ported); `.DEFAULT_GOAL := print-help` (csi-rel's `usage` runs `do_help_to_history`, which csi-spl-orc does not have) |
| `src/make/setup-app-inf.func.mk` | same | 0 |
| `src/make/tf-tasks.func.mk` | same | 0 |
| `lib/make/{demand-var,derive-proj-paths,make-help,resolve-oap,set-default-shell,define-all-run-vars}` | same | 0 |
| `lib/make/set-init-vars.mk` | same name, csi-spl content | config: `APP := $(ORG_APP)` (`csi-spl`). csi-rel's `APP=rel` would send `$(APP)-orc` and `./${APP}-orc/…` at `rel-orc`. No slot scheme: one stack per box, `CON_PREFIX=con-csi-csi-spl`, `COMPOSE_PROJECT_NAME=con-csi-csi-spl-tf-infra`, so `down --rmi all` cannot reach another app's containers (the default project name is `docker` for every app on this box) |
| `src/docker/.env` (committed) | `lib/make/app-path.mk` + `src/docker/tf-infra.env` | config: `APP_PATH` / `ORG_DIR` come from the tree the Makefile runs in, so a worktree builds against itself. The repo `.gitignore` bans `.env` files. `app-path.mk` must sort before `derive-proj-paths.mk`: GNU make expands the exported `BASE_PATH ?= $(shell dirname …)` at the first `$(shell)` |
| `src/docker/docker-compose-infra.yaml` | `src/docker/docker-compose-tf-infra.yaml` | renamed because `docker-compose-infra.yaml` is already csi-spl's lde stack; `env_file: tf-infra.env`; image names `img-${ORG_APP}-<svc>` (csi-rel: `img-<svc>`, the same tag every app on the box builds) |
| `src/docker/tf-runner/Dockerfile` | same | setup: adds the `gh` CLI for step 120's local-exec |
| `src/docker/tpl-gen/Dockerfile` | same | setup: base `python:3.10-slim-bookworm` instead of `python:3.10.11-slim-bullseye`. A fresh build of the bullseye base now 404s on bullseye-security, because Debian 11 LTS ended 2026-08-31 |
| `src/docker/docker-compose-infra.yaml` (tpl-gen service volumes) | `docker-compose-tf-infra.yaml` | setup: tpl-gen's `.venv` is a named volume (`tpl-gen-venv`). The csi-rel init runs `rm -r` + `poetry install` on the in-project `.venv` of the MOUNTED tpl-gen clone. In csi-spl that clone is also the host venv that `do_tpl_gen` and the iac tests run, so the first bring-up (from /opt/csi/csi-spl, 2026-09-19) left it pointing at a container-only python. CLE-3359 measured that, n=1. The host venv was rebuilt |
| `src/docker/conf-validator/Dockerfile`, `.dockerignore` ×3 | same | 0 |
| `src/bash/scripts/docker-init-{tf-runner,tpl-gen,conf-validator}.sh` | same | 0 |
| `src/bash/run/check-container-dns.func.sh` | same | 0 |
| `src/bash/run/flush-dns.func.sh` (its `_dns_*` helpers) | `lib/bash/funcs/dns-resolver-sets.func.sh` | csi-spl-orc keeps its own `do_flush_dns` (a DRY_RUN-gated morph without the helpers). The helpers are copied unchanged into lib, which `run.sh` sources first |
| `lib/bash/funcs/{resolve-oap,define-all-run-vars,resolve-all-proj-paths}.func.sh` | same | 0 |

The tf-runner container mounts the tree at `$APP_PATH` and `~/.gcp`, `~/.ssh`,
`~/.config` and `~/.aws` of the user who runs make. `GITHUB_TOKEN` is in its
environment (`demand_var-GITHUB_TOKEN`). One stack per box: the containers
mount the tree that last ran `make do-setup-app-inf`.

### 2.1 Owner-approved deviations (2026-09-19)

- `tf-init` stays exactly as in csi-rel: no explicit fail-fast on a missing
  key (the owner's answer). The refusal comes from terraform itself (§2).
- `gcp-002` / `gcp-003` / `gcp-004` and step `120-github-general-secrets`
  stay in their csi-spl versions (c422cc7, 8bba4e2, fe19c96). They differ
  from csi-rel because the repo rules require it: no `gcloud config set`,
  `--account` on every call, and no key in terraform state (120 publishes
  the key with `gh secret set` from a local-exec, not as a resource
  attribute).

  Per item (owner answer (a), 2026-09-19; CLE-3355):

  | ported item | csi-rel does | csi-spl does | csi-spl CLAUDE.md rule it satisfies | evidence |
  |---|---|---|---|---|
  | gcp-002 SA + key | `gcloud config set account/project`, `gcloud auth login` | `--account` per call, no config write; dry run unless `DRY_RUN=0`; the org key-creation policy is lifted only when enforced and re-enforced on every path (a failed key create included); a stale key file is refused | "every gcloud call carries `--account` ... never `gcloud config set` anything" | `gcp-002-004-bootstrap.tst.sh` (36 assertions); live 2026-09-19 08:20Z: both keys minted, policy was not enforced so it was never touched |
  | gcp-003 roles/owner | `config set project`, grants unconditionally | `--account`, three-way SA check, no re-grant | same | live: "holds roles/owner" dev + prd |
  | gcp-004 bootstrap APIs | `auth application-default set-quota-project` (writes shared ADC) | enables only the missing ones, no ADC write | same | live: enabled cloudresourcemanager, which was OFF in both projects |
  | 120 github secrets | `github_actions_secret.plaintext_value` + a Secret Manager mirror: the key is in tf state | `terraform_data` + local-exec `gh secret set < keyfile`; state holds only `filesha256(key)` | "No key in git, in terraform state or in a log" | `github-secrets-120.tst.sh`; live state of 120 dev/prd: 1766 B, `private_key` 0 hits, sha256 1 hit |

### 3.1 The render path (CLE-3359, 9c57631 / be368d3; config and setup only)

| csi-rel | csi-spl | reason |
|---|---|---|
| `generate-config-for-step.func.mk` validates and renders `$(APP)-cnf/$(APP)/$(ENV).env.yaml` | same recipe, but `CNF_SRC` and the validated file are `$(SPL_MERGED_CNF)`, plus the prerequisite `do-spl-merged-cnf` | csi-spl's raw `<env>.env.yaml` is deep-merged under `all.env.yaml` plus the derived fqdn. On its own it is incomplete, and the validator rejects it with rc 1 |
| — | `spl-merged-cnf.func.mk` writes `csi-spl-cnf/csi-spl/.merged/<env>.env.yaml` (git-ignored) | the same `do_spl_merged_cnf` the native `do_tpl_gen` uses |
| templates under `src/tpl/%app%` | symlink `%app%` → `%org%-%app%` | the make side has `APP=csi-spl`, while the native `do_tpl_gen` has `APP=spl` |
| `run-tpl-gen.func.mk`, `setup-tpl-gen.func.mk` | byte-identical | — |
| conf-validator module | CLI, exit contract, pyproject and lock from csi-rel. The EnvModels are csi-spl's (dev/prd effective config plus the realm rule) | a different config shape |
| `do-generate-docs-for-step`, the csi-rel-iac copies | not ported | there are no doc templates, and csi-rel-iac has no Makefile |
| tpl-gen / conf-validator `.venv` in the mounted tree | a named volume each, and the images own the mount point (2dbb0be, be368d3, 4997bc3) | the csi-rel init rebuilds the in-project venv of the MOUNTED tree, which is also the host venv. A new volume on a path missing from the image is root-owned, so the image creates the dir as appusr |

### 3.2 csi-spl additions (no csi-rel source; approved by ORC 2026-09-19)

- `do_tf_import_existing` + the 020 / 040 import table (CLE-3360, ae8d2bc,
  fixed at 4bae1ca). The owner chose re-import over rebuild for
  `020-gcp-relay-bucket` and the `040-cloud-sql-postgres` instance. It runs
  `do_tf_state_list`, then `do_tf_import` in the tf-runner for each missing
  address. It never applies.
- The ported `gcp-*` actions each run under a throwaway `CLOUDSDK_CONFIG`
  (GRK-3361). csi-spl's rule "never write the shared gcloud config" beats
  csi-rel's `config set` / `activate-service-account` / `auth revoke --all`
  (owner precedent, relayed by ORC).
- The owner account is committed in `all.env.yaml`
  (`env.gcp.gcp_account_owner_email`, owner order). The 10 ci hygiene sweep
  allows exactly that key's line (3aae810).

## 4. The gcp-* actions and the other terraform callers

See [`csi-rel-gcp-actions.md`](csi-rel-gcp-actions.md) (lane IAC-GCP-ACTIONS)
and [`csi-rel-tf-callers.md`](csi-rel-tf-callers.md) (lane IAC-TF-CALLERS).

Owner-directed deviation from "copy unchanged": every gcloud call pins
`--account` from the yaml `env.gcp.gcp_account_owner_email`, and the
active-account fallback of csi-rel's `do_gcp_account` is removed (lane
GCP-ACCOUNT-PIN).

## 5. CI auth: csi-rel vs csi-spl

| | csi-rel `20_api-build-deploy.yml` (≈ lines 394-417) | csi-spl `20_hub-build-deploy.yml`, `00_deploy-lag-watch.yml`, `30_wui-build-deploy.yml` |
|---|---|---|
| mechanism | composite `./.github/actions/gcp-auth`: WIF when the env is in `WIF_ENVS`, else the `GCP_SA_KEY_<ENV>` secret (`credentials_json`) | the project key secret `GCP_KEY_CSI_SPL_<ENV>` (published by tf 120) first, WIF (`GCP_WIF_PROVIDER_<ENV>` + `GCP_DEPLOY_SA_EMAIL_<ENV>`, tf 017) as the alternative; an env with neither is skipped with a notice |
| identity | the deploy SA, or the key's SA | the project IaC SA `csi-spl-<env>@csi-spl-<env>.iam.gserviceaccount.com` (key) or the 017 deploy SA (WIF) |
| owner | — | CLE-3355 / CLE-3354 (not changed by this port) |
