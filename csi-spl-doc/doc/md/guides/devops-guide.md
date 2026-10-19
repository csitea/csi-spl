# DevOps guide

> Generated from qto doc `78e51717-7bcb-4b12-9da8-80af726f8882`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

<a id="ws-doc-29350091-124f-4b65-a89b-1c5a8cbd4a8e"></a>
## 1 About this guide

This guide builds the GCP estate of the spool from a checkout of the repo: the projects, the service-account keys, terraform through the tf-runner, Cloud Run, Cloud SQL, Firebase Hosting, DNS, the GitHub workflows, the runners, and a restore from backup. It changes nothing by being read. Every mutating command is a dry run until you add `DRY_RUN=0` or, for terraform, until you run `make do-provision` after a plan you have read. An apply needs the owner's approval for that call.

It is one of four guides. The others are linked, not copied.

| guide | answers |
|---|---|
| System guide | what the parts are |
| Installation and configuration guide | a box, from an empty Debian 13 |
| DevOps guide (this one) | the GCP estate and the pipelines |
| Operations and maintenance guide | the daily and weekly routine |
| [Incident runbook](incident-runbook.md) | on-call roles, escalation, and first-response commands |

<a id="ws-doc-481ad4ab-3511-4912-8f5e-c4ba62f3801c"></a>
### 1.1 What you hold

| item | what for |
|---|---|
| the GitHub repo `csitea/csi-spl` on a box that already has the checkout | every action below |
| the GCP organisation owner login | only gcp-000..004, and only while that project's key does not exist yet |
| `GCP_BILLING_ACCOUNT_ID` in the environment | gcp-001 links the project to it; the value is never in the repo |
| the per-env project keys, once bootstrap has written them | everything after the keys exist |
| the owner's approval | every terraform apply, every project create |

For a box that does not exist yet, follow the installation guide, sections 3 to 5 (packages, the two users, the checkout, tpl-gen at its pin, the key table). Come back here, then finish that guide. The product domain is cnf `env.dns.BASE_DOMAIN`. This guide never pastes it.

<a id="ws-doc-5bd64e9d-cdc8-47b3-8d6c-4f19df39e074"></a>
### 1.2 Conventions

| placeholder | means |
|---|---|
| `<CHECKOUT>` | the main checkout, the installation guide's `/opt/csi/csi-spl` |
| `<OWNER_USER>` | the OS user that owns the checkout, the keys and docker |
| `<ENV>` | `dev` or `prd`, unless a step says `bkp` or `all` |
| `<ORG>` `<APP>` | resolved by the action (`do_resolve_oap`); you do not type them |

Run every command as `<OWNER_USER>`, from `<CHECKOUT>`, never from an agent worktree. One `./run` action is a dry run unless `DRY_RUN=0`. `make do-tf-plan` is the plan. `make do-provision` applies. Terraform runs only inside the tf-runner container.

A block that shows only `ENV=dev` is repeated for prd with `ENV=prd`, unless the section says the step is dev only, prd only, `bkp` or `all`.

<a id="ws-doc-dc8ff975-adc6-417b-ab68-a8b1881b97c0"></a>
### 1.3 Where the rules live

Do not copy these. The fleet rules index, the developer guide and the repo `CLAUDE.md` are the homes. The provisioning rules this guide follows are spec 007, requirement R7 (numeric steps, dev then prd, DNS the other way) and R8 (the project service account after the key exists): [infra-provisioning-requirements.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/007-spool-hub-api-infra/infra-provisioning-requirements.md). Operational incident triage, on-call roles, and escalation follow the [incident runbook](incident-runbook.md). The module contract the bootstrap test pins is [csi-spl-iac/README.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-iac/README.md). It stays; this guide does not replace it.

<a id="ws-doc-70c1de60-84b2-4e69-823e-8a7d7cc04e34"></a>
## 2 Identity

<a id="ws-doc-c303759f-f85a-411e-87e5-91f0c7f6d179"></a>
### 2.1 After a project key exists

Every later action resolves one identity: an explicit `GCP_ACCOUNT`, else the project service account in that env's key, else it refuses. It passes `--account` on every gcloud call. It does not write the shared gcloud config, and it does not fall back to the owner login. The owner address is read only by gcp-000..004, from cnf `env.gcp.gcp_account_owner_email`, and only while the key file is absent. A key that lacks a permission is reported.

The gate is `bash csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`. `grep -c '^do_gcp_pin_account()' csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh` -> 1. The same function is also defined under `csi-spl-orc` (count 2 across the two trees).

<a id="ws-doc-556c6523-88e8-4c6f-91ee-1843efff9e2e"></a>
### 2.2 The human login

Creating the first project needs the org admin signed in. There is no `do_*` action for that login. It is gap D1. The iac README names the command, and gcp-000 refuses until that login can mint a token. Do it once, as `<OWNER_USER>`, before the first bootstrap, and do not run it again once the key file exists. This login writes the shared gcloud config. It is the one bootstrap exception to the rule that later actions leave that config alone.

`GCP_ACCOUNT` here is the org admin, for this one step. It is not the project service account.

```bash
gcloud auth login "${GCP_ACCOUNT:?GCP_ACCOUNT must be set}"
```

<a id="ws-doc-7d42a600-3bfb-4dac-9a4a-0cc8afb4f9dc"></a>
## 3 Bootstrap

`do_gcp_000_bootstrap_gcp_env` runs four idempotent steps and stops at the first failure: gcp-001 (project and billing), gcp-002 (the project service account and one key), gcp-003 (`roles/owner` on that project), gcp-004 (the four APIs terraform needs before it can start). The project id is cnf `env.gcp.gcp_project`. The org id is cnf `env.gcp.gcp_org_id` unless `GCP_ORG_ID` or `GCP_FOLDER_ID` is set. `GCP_BILLING_ACCOUNT_ID` is required and is not in the repo.

`grep -c '^do_gcp_000_bootstrap_gcp_env()' csi-spl-iac/src/bash/run/gcp-000-bootstrap-gcp-env.func.sh` -> 1.

<a id="ws-doc-7694df8f-26de-4977-ae62-511b24757b43"></a>
### 3.1 Dry run, dev

Leave `DRY_RUN` unset. Read the log. Nothing is created.

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

<a id="ws-doc-dcf083de-5046-4bd3-8018-f94220e439da"></a>
### 3.2 Apply, dev

The owner's approval is required for this call. The same shape, with `DRY_RUN=0`, is then repeated for `prd`, `bkp` (the off-project backup project, step 046) and `all` (the satellite project, steps 059 and 060).

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

<a id="ws-doc-291dbae6-1105-48eb-b51f-76b39ef9fe58"></a>
### 3.3 Apply, prd

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=prd DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

<a id="ws-doc-c48f722a-891e-47d4-b5e4-00ae8588d540"></a>
### 3.4 Apply, backup project

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=bkp DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

<a id="ws-doc-a9dadf86-1a49-4b62-9822-bbdd7d4793db"></a>
### 3.5 Apply, satellite project

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=all DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

<a id="ws-doc-6cc663a7-4260-45d7-9624-31247f8eda38"></a>
### 3.6 What 000 runs

| step | action | what it does | grep -c of the function |
|---|---|---|---|
| gcp-001 | `do_gcp_001_create_project` | create the project and link billing | 1 |
| gcp-002 | `do_gcp_002_create_project_service_account` | create the project SA and write one key, mode 600 | 1 |
| gcp-003 | `do_gcp_003_configure_proj_sa_permissions` | grant that SA `roles/owner` on its project | 1 |
| gcp-004 | `do_gcp_004_project_apis_enable` | enable cloudresourcemanager, serviceusage, storage, iam | 1 |

Each function lives in `csi-spl-iac/src/bash/run/` under the file named in the action. The key path is printed by gcp-002 as `$HOME/.gcp/.<org>/key-<project-id>.json`. Do not print the file. Do not commit it. After it exists, stop using the owner login.

<a id="ws-doc-764f0656-7c1d-4306-9e05-7ede38acdc22"></a>
## 4 Render the tfvars

<a id="ws-doc-789101de-0939-44d7-87e4-b834ba09d040"></a>
### 4.1 The tpl-gen pin

tpl-gen is the git-ignored sibling clone `<CHECKOUT>/tpl-gen`. `do_tpl_gen` refuses unless its HEAD equals `csi-spl-iac/cnf/tpl-gen.ref`. The clone itself is the installation guide.

```bash
git -C <CHECKOUT>/tpl-gen rev-parse HEAD
```

<a id="ws-doc-f683ee63-972e-4758-9cb6-ad593f8acd02"></a>
### 4.2 Compare the pin

The two SHAs are the same, or you check out the pin before rendering. A render from any other commit is not the one the repo ships.

```bash
cat <CHECKOUT>/csi-spl-iac/cnf/tpl-gen.ref
```

<a id="ws-doc-72d8e1fa-7ad9-4fdb-9994-71d15559cd5c"></a>
### 4.3 Render dev

`do_tpl_gen` deep-merges `all.env.yaml` under `<env>.env.yaml` and writes `csi-spl-cnf/csi-spl/<env>/tf/*.tfvars`. `grep -c '^do_tpl_gen()' csi-spl-iac/src/bash/run/tpl-gen.func.sh` -> 1. One step at a time, with the conf-validator in front, is `make do-generate-config-for-step` (`grep -c '^do-generate-config-for-step:' csi-spl-orc/src/make/generate-config-for-step.func.mk` -> 1). A full rebuild uses the action below.

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev ./run -a do_tpl_gen
```

<a id="ws-doc-fc346ebb-8905-42ee-9fbf-658c6b3b1030"></a>
### 4.4 Render prd

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=prd ./run -a do_tpl_gen
```

<a id="ws-doc-ab773e69-1bb2-401c-a984-96d6d8478e66"></a>
### 4.5 The render matches the commit

A fresh render of a clean checkout produces no diff. If this prints a diff, commit the cnf change on its own before any apply. Do not apply from uncommitted tfvars.

```bash
git -C <CHECKOUT> diff --exit-code -- csi-spl-cnf/csi-spl/dev/tf csi-spl-cnf/csi-spl/prd/tf
```

<a id="ws-doc-d5da9175-bc78-459b-ab7c-e5974e76e6ae"></a>
## 5 Terraform

<a id="ws-doc-f3154303-fe4c-4013-996d-c5ca61be1fb0"></a>
### 5.1 Start the tf-runner

From the main checkout only, and not while another apply is running. This builds the tf-runner, tpl-gen and conf-validator images and does `down --rmi all` first, so it is one stack per box. `GITHUB_TOKEN` is the token handed over out of band. `grep -c '^do-setup-app-inf:' csi-spl-orc/src/make/setup-app-inf.func.mk` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && GITHUB_TOKEN="${GITHUB_TOKEN:?}" make do-setup-app-inf
```

<a id="ws-doc-495a0dac-561f-4fd8-b76a-a1e4e6ca9f5e"></a>
### 5.2 Plan one step

`make do-tf-plan` runs `do_tf_plan` inside the tf-runner. `do_tf_init` points `GOOGLE_APPLICATION_CREDENTIALS` at the project key and wipes `csi-spl-iac/bin/<org>/<app>/<env>/<step>` first, so two runs on the same env and step break each other. `grep -c '^do-tf-plan:' csi-spl-orc/src/make/tf-tasks.func.mk` -> 1. `grep -c '^do_tf_plan()' csi-spl-iac/src/bash/run/tf-plan.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-tf-plan
```

<a id="ws-doc-01cf178f-e13c-4d75-a125-432af0124440"></a>
### 5.3 Apply one step

**Dev first, always. Prd only repeats what dev already did** (owner rule 2026-10-15, t1 topic 36247645). Dev is always in sync with prd, or newer. Every change to the infrastructure goes in this order, one step at a time:

1. Plan the step on dev (`ENV=dev`, 5.2) and read the plan.
2. Apply it on dev (`ENV=dev`, the command below), with the owner's approval.
3. Prove it works on dev: a fresh dev plan shows `No changes`, and the service the step touches answers (for the hub, `/version` on dev; for the WUI, `build.json`).
4. Plan the same step on prd, from the same commit. That plan must show the same changes as the dev plan, and nothing more. If it shows anything else, stop and find out why before you apply.
5. Apply it on prd (`ENV=prd`), with the owner's approval.

Never apply to prd a step that dev has not applied, and never change prd by hand. If prd turns out to be ahead of dev for a step (as step 030 was on 2026-10-14), bring dev level first. The tools enforce it: a prd `make do-provision` (and `do-tf-apply-target`) plans dev for the same step first and is refused while dev has pending changes (`do_check_dev_leads_prd`; an owner-approved emergency only with `ENV_ORDER_OVERRIDE=<owner msg id>`, logged), and the daily `cd csi-spl-orc && ./run -a do_check_env_order` reports every step, deploy or image tag where prd leads dev.

The owner's approval is required for each apply. `make do-provision` runs `do_check_container_dns`, then for step 030 `do_check_hub_image_regress`, then `do_provision` in the tf-runner. `grep -c '^do-provision:' csi-spl-orc/src/make/tf-tasks.func.mk` -> 1. `grep -c '^do_provision()' csi-spl-iac/src/bash/run/provision.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-provision
```

<a id="ws-doc-4bb38b24-2567-4fdb-8f9c-951c11881fd6"></a>
### 5.4 One run at a time

One env and one step at a time, from the checkout the tf-runner mounts. State lives in the env's terraform state bucket (step 000), not in the wiped run directory. Destroy one step with `make do-deprovision`, which runs `do_divest` in the tf-runner. `grep -c '^do-deprovision:' csi-spl-orc/src/make/tf-tasks.func.mk` -> 1. `grep -c '^do_divest()' csi-spl-iac/src/bash/run/divest.func.sh` -> 1. A list of steps is `do_tf_deprovision_steps`, and `STEPS` has no default.

<a id="ws-doc-ca2ef158-df42-4bde-9601-7b4eb07fe5d1"></a>
### 5.5 The steps

`find csi-spl-iac/src/terraform -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort` is the numeric order. Apply dev then prd for each step, except where the table says otherwise. Spec 007 R7: on a rebuild of an estate that already exists, do not destroy `040-cloud-sql-postgres`; import it. A from-scratch project creates it. The import make target is gap D4.

| step | env | what it creates |
|---|---|---|
| 000-gcp-remote-bucket | dev, then prd | the terraform state bucket |
| 001-enable-gcp-services | dev, then prd | the rest of the APIs |
| 005-gcp-domain-verification | dev, then prd | domain verification |
| 016-firebase-deploy-iam | dev, then prd | IAM for the Firebase deploy |
| 017-github-wif-deploy | dev, then prd | GitHub workload identity for deploy |
| 019-firebase-static-site | dev, then prd | the Firebase Hosting site |
| 025-gcp-dns-zone | prd, then dev | DNS; the apex zone before the dev sub-zone |
| 028-gcp-artifact-registry | dev, then prd | the hub image registry |
| 030-cloud-run-hub | dev, then prd | the hub service; hold until the database bootstrap below |
| 032-gcp-cloud-run-domain-mapping | dev, then prd | the hub custom domain, when cnf sets one; after 030 |
| 036-spl-demo-workspace | dev, then prd | calls `do_spl_demo_workspace_create`; after the hub answers |
| 040-cloud-sql-postgres | dev, then prd | Postgres, the database, empty DSN slots; no password in state |
| 045-gcs-db-backups | dev, then prd | the bucket workflow 45 exports into |
| 046-gcs-offsite-backups | dev, then prd | the bucket in the backup project; bootstrap `ENV=bkp` first |
| 050-gcs-files | dev, then prd | the hub file bucket |
| 051-gcs-docs | dev, then prd | the docs bucket |
| 052-gcs-workspace-docs | dev, then prd | one docs bucket per workspace listed in cnf |
| 054-gcs-blog-media | dev, then prd | blog media |
| 055-gcp-kms-marketing | dev, then prd | the marketing KMS key |
| 056-gcs-box-state | dev, then prd | nightly box-state backups; the restore is the installation guide |
| 057-gcp-kms-vendor-keys | dev, then prd | vendor-key KMS |
| 058-gcp-wine-box-budget | dev only | the wine-box budget, via `do_spl_wine_box_budget_tf`; prd validation refuses |
| 059-gcp-satellite-budget | prd only | the satellite budget, in the `all` project; before 060 |
| 060-gcp-vm-satellite | prd only | the satellite VM; the playbook detail is `SYS.md` |
| 061-gcp-vm-wine-box | dev only | the wine-box VM |
| 070-gcp-monitoring | dev, then prd | monitoring |
| 120-github-general-secrets | dev, then prd | GitHub secrets from the project keys |

<a id="ws-doc-55109a80-2356-47e4-9271-fc9fc19db4e2"></a>
### 5.6 Do not sweep every step on both envs

`do_tf_sweep_steps` plans, and with `DRY_RUN=0` applies, a list of steps. Default `STEPS` is every step directory. Default `ENVS` is `dev prd`. It stops on a plan error, a destroy, or a replace. `058` and `061` validate `env == dev`. `059` and `060` validate `env == prd`. A default sweep stops on the first of those. `025` wants `ENVS="prd dev"`. Pass `STEPS` and `ENVS` yourself. `grep -c '^do_tf_sweep_steps()' csi-spl-orc/src/bash/run/tf-sweep-steps.func.sh` -> 1.

<a id="ws-doc-2368a642-9337-472b-babd-3cf29555ba64"></a>
### 5.7 Plan the shared steps

This list holds 030, 032, 036, 025, 058, 059, 060 and 061 out. Read the plan log before the apply.

```bash
cd <CHECKOUT>/csi-spl-orc && ENVS="dev prd" STEPS="000-gcp-remote-bucket 001-enable-gcp-services 005-gcp-domain-verification 016-firebase-deploy-iam 017-github-wif-deploy 019-firebase-static-site 028-gcp-artifact-registry 040-cloud-sql-postgres 045-gcs-db-backups 046-gcs-offsite-backups 050-gcs-files 051-gcs-docs 052-gcs-workspace-docs 054-gcs-blog-media 055-gcp-kms-marketing 056-gcs-box-state 057-gcp-kms-vendor-keys 070-gcp-monitoring 120-github-general-secrets" ./run -a do_tf_sweep_steps
```

<a id="ws-doc-ae5f3d1a-63a9-48ad-ad95-8cf5e245cf98"></a>
### 5.8 Apply the shared steps

The owner's approval is required. Same `STEPS` and `ENVS` as the plan. `DRY_RUN=0` applies only a plan that adds or changes, and stops on a destroy or a replace.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS="000-gcp-remote-bucket 001-enable-gcp-services 005-gcp-domain-verification 016-firebase-deploy-iam 017-github-wif-deploy 019-firebase-static-site 028-gcp-artifact-registry 040-cloud-sql-postgres 045-gcs-db-backups 046-gcs-offsite-backups 050-gcs-files 051-gcs-docs 052-gcs-workspace-docs 054-gcs-blog-media 055-gcp-kms-marketing 056-gcs-box-state 057-gcp-kms-vendor-keys 070-gcp-monitoring 120-github-general-secrets" ./run -a do_tf_sweep_steps
```

<a id="ws-doc-0779e54c-46b7-448d-b482-6e7ff4e08159"></a>
## 6 Cloud SQL

<a id="ws-doc-741ff089-72d8-473a-ab50-021b3c011932"></a>
### 6.1 Bootstrap the database, dev

After step 040, before step 030. `do_spl_db_bootstrap` creates the owner login and the runtime login, writes their DSN secret versions, and runs `spool migrate` as the owner through the Cloud SQL proxy. Passwords are not logged. 040 leaves the slots empty on purpose, so they never sit in the state bucket. On a fresh env this action does the split. If it tells you the runtime slot still holds the owner, run the next section. `grep -c '^do_spl_db_bootstrap()' csi-spl-orc/src/bash/run/spl-db-bootstrap.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap
```

<a id="ws-doc-06a4f778-00ba-4404-9be9-ba593ec54764"></a>
### 6.2 Bootstrap the database, prd

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=prd DRY_RUN=0 ./run -a do_spl_db_bootstrap
```

<a id="ws-doc-fef3aaed-c6aa-4a2b-b5f4-2dbaf41b7ef1"></a>
### 6.3 Split owner from runtime

Only when bootstrap says the runtime slot still holds the owner. The owner keeps the schema. The runtime login gets DML grants. The hub reads the runtime DSN. `grep -c '^do_spl_db_owner_split()' csi-spl-orc/src/bash/run/spl-db-owner-split.func.sh` -> 1. `ROLLBACK=1` and `ROTATE_OWNER=1` are separate runs; the function header says what each does.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_db_owner_split
```

<a id="ws-doc-faa3790e-2362-42fd-b17d-558ac6af3e90"></a>
### 6.4 Automated backups

Step 040 turns on Cloud SQL automated backups and point-in-time recovery. Workflow 45 is additive: a Cloud SQL backup restores only into Cloud SQL and dies with the project. There is no `do_*` action that restores a PITR timestamp. That is gap D6. The logical dump is the next section.

<a id="ws-doc-e48db97e-6cf4-4d05-ab1f-cabe773a5025"></a>
## 7 Cloud Run

<a id="ws-doc-f36e9b18-70eb-48d0-8d20-b593a22eae5d"></a>
### 7.1 Apply the hub service

Step 030 creates the service and then ignores the image (`lifecycle ignore_changes`), so a later apply does not roll it back. The image is minted and rolled by workflow 20, or from the box by `do_deploy_hub`.

The first apply, when no service exists yet, is gap D3. `make do-provision` of step 030 runs `do_check_hub_image_regress` first, and that action returns 1 when `gcloud run services describe` cannot see a service. `ALLOW_IMAGE_REGRESS` is checked only after a live image is read, so it does not unlock the first create. Do not docker-exec terraform on the host to get past it.

When the service already exists, the sweep is the path. The owner's approval is required.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS=030-cloud-run-hub ./run -a do_tf_sweep_steps
```

<a id="ws-doc-dff6af38-9b56-4cdd-90d0-346d1f608426"></a>
### 7.2 Domain mapping

After 030, and only when cnf sets a custom domain. The cert is Google's; `do_spl_wait_for_mapping_cert` polls it. `grep -c '^do_spl_wait_for_mapping_cert()' csi-spl-orc/src/bash/run/spl-wait-for-mapping-cert.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS=032-gcp-cloud-run-domain-mapping ./run -a do_tf_sweep_steps
```

<a id="ws-doc-b6ef6a8f-4073-49dc-8796-d9b326f06311"></a>
### 7.3 Deploy the hub from the box

Workflow 20 does this on a push that changes a hub input. From a box, `do_deploy_hub` is the same sequence: the commit must be on `origin/master`, `do_release_version`, `do_build_push_hub_image` when the tag is missing, `do_spl_db_bootstrap`, roll the service, `do_heal_hub_deploy`, `do_check_hub_deploy`. Dry run first. `grep -c '^do_deploy_hub()' csi-spl-orc/src/bash/run/deploy-hub.func.sh` -> 1. Dev, then prd.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_deploy_hub
```

<a id="ws-doc-3d36aeb2-89b9-40a6-831d-fd180e607140"></a>
### 7.4 The regress guard

`do_check_hub_image_regress` refuses a 030 apply that would move the live image backwards. A newer cnf tag is allowed. A tree whose 030 ignores the image reports `ahead` and exits 0. `grep -c '^do_check_hub_image_regress()' csi-spl-orc/src/bash/run/check-hub-image-regress.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev ./run -a do_check_hub_image_regress
```

<a id="ws-doc-b8b4ec74-ab9e-4e85-adee-8db62061f4db"></a>
## 8 DNS and tenants

<a id="ws-doc-d70f9022-d8a4-47f1-a81c-d3e684c8e61b"></a>
### 8.1 The zone, prd then dev

Spec 007 R7: apply `025-gcp-dns-zone` on prd before dev, and destroy it on dev before prd. The owner's approval is required.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="prd dev" STEPS=025-gcp-dns-zone ./run -a do_tf_sweep_steps
```

<a id="ws-doc-9897292e-41de-49ef-ab1a-acadf26dcb00"></a>
### 8.2 One tenant host

`do_spl_tenant_host_provision` adds the tenant to cnf `env.dns.mapped_tenants` and to `steps.052-gcs-workspace-docs.workspaces`, renders 052, 019 and 025, plans, and refuses a destroy. It then waits for the Firebase cert and probes the host. The apex tenant is not given a second host. Dry run first. `grep -c '^do_spl_tenant_host_provision()' csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh` -> 1. The steps inside it call `do_spl_wait_for_firebase_domain` and `do_spl_probe_wui_host` (each `grep -c` of the function -> 1).

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TENANT_ID=<TENANT> DRY_RUN=0 ./run -a do_spl_tenant_host_provision
```

<a id="ws-doc-89dacbf1-0920-48fc-af67-4782f09b1639"></a>
## 9 Firebase Hosting

<a id="ws-doc-c4966b80-01e6-4cac-a49e-c4b3b5dc1e84"></a>
### 9.1 Deploy the WUI from the box

Workflow 30 does this on a push that changes a WUI input. From a box, `do_deploy_wui` generates the site and runs `firebase deploy --only hosting` as the project service account. It does not use a firebase login on the box. Dev, then prd. `grep -c '^do_deploy_wui()' csi-spl-orc/src/bash/run/deploy-wui.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_deploy_wui
```

<a id="ws-doc-f1b90ce2-c411-4466-8411-ec0c4ba28dda"></a>
### 9.2 Prove the deploy

`do_check_deploy_lag` reads the hub `/version` and the WUI `build.json` for the commit, not the image tag in cnf. Exit 0 is current or pending. Exit 3 is lagging. `grep -c '^do_check_deploy_lag()' csi-spl-orc/src/bash/run/check-deploy-lag.func.sh` -> 1. `do_check_hub_deploy` answers a different question: does the live image equal the tag cnf names. `grep -c '^do_check_hub_deploy()' csi-spl-orc/src/bash/run/check-hub-deploy.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev ./run -a do_check_deploy_lag
```

<a id="ws-doc-dae2b3b2-e55f-4e45-ac11-775fca38964e"></a>
## 10 The other env-gated steps

<a id="ws-doc-83d9b807-75bc-4544-bf05-ed714ba59f95"></a>
### 10.1 Wine box budget, plan

Step 058 is the dev wine-box budget. `do_spl_wine_box_budget_tf` reads the billing account from the dev project's billing link, as the dev project service account, and passes it only into that one make run, so the account stays out of the log. Leave `TF_VERB` unset: this is the plan. `grep -c '^do_spl_wine_box_budget_tf()' csi-spl-iac/src/bash/run/spl-wine-box-budget-tf.func.sh` -> 1, on commit `bfede0918`. The prd render of 058 is a marker and is not applied.

```bash
cd <CHECKOUT>/csi-spl-iac && ./run -a do_spl_wine_box_budget_tf
```

<a id="ws-doc-a72268bf-d613-45b5-a7b1-7bb3a709aee0"></a>
### 10.2 Wine box budget, apply

The owner's approval is required for this call. The same action, with `TF_VERB=provision`.

```bash
cd <CHECKOUT>/csi-spl-iac && TF_VERB=provision ./run -a do_spl_wine_box_budget_tf
```

<a id="ws-doc-2c18c131-c19d-48fc-9acb-ee4529d66362"></a>
### 10.3 Wine box VM

After the budget apply. Dev only. The prd render carries a marker and is not applied.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS=dev STEPS=061-gcp-vm-wine-box ./run -a do_tf_sweep_steps
```

<a id="ws-doc-89c81063-f467-413d-8155-58eaf57153c3"></a>
### 10.4 Satellite, prd only

Budget, then the VM. Both render from prd and create resources in the satellite project (bootstrap `ENV=all` first). The Ansible playbook that the 060 apply runs is the installation guide and `SYS.md`, not this guide.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS=prd STEPS="059-gcp-satellite-budget 060-gcp-vm-satellite" ./run -a do_tf_sweep_steps
```

<a id="ws-doc-668db710-0e6d-4ba1-8a86-80d72819149e"></a>
### 10.5 Demo workspace

After `do_deploy_hub` for that env. `make do-provision` of step 036 builds the spool CLI on the host first. The private key the action writes is not a terraform output. Do not print it.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS=036-spl-demo-workspace ./run -a do_tf_sweep_steps
```

<a id="ws-doc-8cdffcf2-a799-4d3b-bb33-b93eb2d82d3f"></a>
## 11 Backups

<a id="ws-doc-cec54d1d-658a-43c8-a49e-60010705b5dd"></a>
### 11.1 Take a dump

`do_spl_db_backup` runs `gcloud sql export` inside Google, into the 045 bucket, as the project service account. No row and no password cross the box. Workflow 45 does this daily, then verifies, then copies off-project. `grep -c '^do_spl_db_backup()' csi-spl-orc/src/bash/run/spl-db-backup.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_db_backup
```

<a id="ws-doc-794b2619-7ab3-429d-b792-a45370eeb96a"></a>
### 11.2 Prove the dump

Restores the newest object into a throwaway Postgres container on this box and compares tables to the live database, read-only. A missing table, or a table that restores empty while live has rows, fails. Equal counts are not the test. `grep -c '^do_spl_db_backup_verify()' csi-spl-orc/src/bash/run/spl-db-backup-verify.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev ./run -a do_spl_db_backup_verify
```

<a id="ws-doc-812898c0-ef3b-40ff-86ab-c3d2c24b92e2"></a>
### 11.3 Copy off the project

`do_spl_backup_offsite` copies new 045 dumps and 050 files into the 046 bucket. The env service account can add an object there and cannot read it back. While cnf `steps.046-gcs-offsite-backups.copy_enabled` is false the action exits 0. `grep -c '^do_spl_backup_offsite()' csi-spl-orc/src/bash/run/spl-backup-offsite.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_backup_offsite
```

<a id="ws-doc-5b480e7b-a84e-4f6d-88dc-f83652bd2dc3"></a>
## 12 Restore from backup

<a id="ws-doc-95723e20-408c-4e0c-9928-5b5a3b44f09b"></a>
### 12.1 Copy the estate before a destroy

`do_gcp_backup_env` is read-only against GCP. It writes state, secret versions, DNS zones, the relay and files buckets, image tags and a database dump under a 0700 directory. Secret values are files, mode 600, and are not logged. Take it, and a green `do_spl_db_backup`, before `do_tf_deprovision_steps`. `grep -c '^do_gcp_backup_env()' csi-spl-iac/src/bash/run/gcp-backup-env.func.sh` -> 1. `grep -c '^do_tf_deprovision_steps()' csi-spl-orc/src/bash/run/tf-deprovision-steps.func.sh` -> 1. `STEPS` is required.

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev ./run -a do_gcp_backup_env
```

<a id="ws-doc-39fe9aa5-2c16-42e9-90b0-329cafb0fd7d"></a>
### 12.2 Drill on this box

The default target is a throwaway container, removed at the end. `BACKUP_SOURCE` defaults to `bkp` when the off-project copy is enabled, else `env`. `grep -c '^do_spl_db_restore()' csi-spl-orc/src/bash/run/spl-db-restore.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TARGET=local DRY_RUN=0 ./run -a do_spl_db_restore
```

<a id="ws-doc-bd798ce1-2cab-4673-b65a-0d15a90e439b"></a>
### 12.3 Drill on a throwaway database

A new database on the same instance, dropped after the count unless `KEEP=1`.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TARGET=database:spool_restore_drill DRY_RUN=0 ./run -a do_spl_db_restore
```

<a id="ws-doc-2929038a-e5be-474e-93bf-2aa8156ed0a0"></a>
### 12.4 Restore into a recreated instance

`TARGET=env` is refused while the hub database still has tables. Prd also needs `ALLOW_PRD_RESTORE=1`. This is the disaster path after step 040 and `do_spl_db_bootstrap` have recreated an empty database. When the env project itself is gone, `BACKUP_SOURCE=bkp` reads the backup project.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TARGET=env BACKUP_SOURCE=bkp DRY_RUN=0 ./run -a do_spl_db_restore
```

<a id="ws-doc-4478bb7e-5a6b-45e5-a095-042d7ecd7a3f"></a>
### 12.5 Restore the file bucket

`do_spl_files_restore` is the 050 half. `SOURCE=bkp` is the off-project copy. `TARGET=env` does not replace an object that is already there. Prd needs `ALLOW_PRD_RESTORE=1`. `grep -c '^do_spl_files_restore()' csi-spl-orc/src/bash/run/spl-files-restore.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev SOURCE=bkp TARGET=local DRY_RUN=0 ./run -a do_spl_files_restore
```

<a id="ws-doc-ec65b3b1-7e1a-41c5-b47a-7824945e803f"></a>
### 12.6 Erase one file on request

`do_spl_file_erase` removes one `FILE_ID` (a file posted by mistake) everywhere we hold it, and reads each leg back. The hub leg deletes `t/<tenant>/files/<id>` from the 050 bucket as the env SA: the object `DELETE /v1/files/{id}` removes, whose route needs a box upload token no operator holds. The box leg removes every path on this box whose name carries the id, under every real home and the spool and tmp trees, `find -xdev` per root. The backup leg only reports: the off-project copy keeps an object for its retention, and a delete there needs the owner's go for that delete. `DRY_RUN=1` is the default. `grep -c '^do_spl_file_erase()' csi-spl-orc/src/bash/run/spl-file-erase.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && FILE_ID=<sha256> ENV=prd TENANT=<tenant> DRY_RUN=0 ./run -a do_spl_file_erase
```

On a box with no env key, run the box leg alone.

```bash
cd <CHECKOUT>/csi-spl-orc && FILE_ID=<sha256> HUB_LEG=0 BKP_LEG=0 DRY_RUN=0 ./run -a do_spl_file_erase
```

<a id="ws-doc-aacff2e2-cc9d-419f-88f9-5169e2b8348e"></a>
## 13 Workflows

<a id="ws-doc-63ada7fd-b299-4a4a-9692-b87a6cb93e6b"></a>
### 13.1 What each one gates

The file is `.github/workflows/<file>`. Runner is the literal `runs-on` in that file, measured by reading it. Workflow 10's `runs-on` is an expression: the caller's input, else the repo variable `SPOOL_CI_RUNNER`, else `[self-hosted, spool-ci]` on this repo, else `ubuntu-latest`.

| file | gates | runner |
|---|---|---|
| 00_deploy-lag-watch.yml | `do_check_deploy_lag` on a schedule | ubuntu-latest |
| 10_ci-quality.yml | the quality gate on every master push; a docs-only push skips the code jobs | expression, self-hosted `spool-ci` on this repo |
| 11_ci-public.yml | the same gate for a pull request, after a maintainer approves it | passes ubuntu-latest into 10 |
| 12_ci-rerun-setup-flake.yml | reruns a run lost to an action download at Set up job | ubuntu-latest |
| 15_sec-deps-secrets.yml | dependency and secret scans | ubuntu-latest |
| 20_hub-build-deploy.yml | mint, build, migrate, roll the hub; then, non-blocking, the invite e2e (`do_spl_invite_e2e`) on dev t1 and on prd in the test workspace `e2e` only (`vars.INVITE_E2E_TENANT_PRD`; t1 and customer workspaces are refused) | ubuntu-latest |
| 21_hub-deploy-catchup.yml | a trunk hub or WUI that never got served | ubuntu-latest |
| 22_deploy-verify.yml | HTTPS smoke of the hub and the WUI | ubuntu-latest |
| 30_wui-build-deploy.yml | mint and Firebase Hosting; a push (or "all") run stands down, green, when its commit is older than the one the site's `build.json` serves (`wui-deploy-guard.sh`, SPL-1829), so a late older run never rolls the site back | ubuntu-latest |
| 31_wui-edge-warm.yml | warm the WUI edge | ubuntu-latest |
| 32_docs-publish.yml | publish the repo docs | ubuntu-latest |
| 40_tenant-host-reconcile.yml | tenant hosts (specs/024) | ubuntu-latest |
| 45_db-backup.yml | dump, verify, offsite copy, a local restore drill | ubuntu-latest |
| 46_demo-wipe.yml | the nightly demo-workspace wipe | ubuntu-latest |
| 47_db-maint.yml | nightly `do_spl_db_maint`, dev then prd | ubuntu-latest |
| 48_vendor-key-grant-check.yml | the vendor-key grant check | ubuntu-latest |
| 50_oss-standalone.yml | the root compose file on a clean machine | ubuntu-latest |
| 55_release-stable.yml | the weekly stable tag | ubuntu-latest |
| 56_ghcr-images.yml | publish hub and web images for that tag | ubuntu-latest |
| 60_codeql.yml | CodeQL | ubuntu-latest |
| 61_semgrep.yml | Semgrep | ubuntu-latest |
| 62_gosec.yml | gosec | ubuntu-latest |
| 63_eslint-security.yml | eslint security plugin on the WUI | ubuntu-latest |
| 64_trufflehog.yml | verified-secret scan | ubuntu-latest |
| 65_iac-checkov.yml | Checkov on the terraform | ubuntu-latest |
| 66_hadolint.yml | Dockerfiles | ubuntu-latest |
| 67_shellcheck.yml | shellcheck | ubuntu-latest |
| 68_dast.yml | headers and ZAP against dev only | ubuntu-latest |
| 70_supply-chain.yml | Trivy IaC and OSV | ubuntu-latest |
| 85_actionlint.yml | the workflow files | ubuntu-latest |
| 99_runner-smoke.yml | a self-hosted job actually starts | self-hosted |

A fork's pull request runs only on GitHub-hosted runners, with read-only permissions and no secrets. Deploy workflows do not run for a pull request. That rule is [CONTRIBUTING.md](https://github.com/csitea/csi-spl/blob/master/CONTRIBUTING.md).

<a id="ws-doc-a98da65f-8e1d-4820-bfed-09238d57d0f8"></a>
## 14 Runners

<a id="ws-doc-7386eec7-aa95-46e0-b1ef-b6f900906557"></a>
### 14.1 Register

`do_gh_runner_add` registers org runners in `GH_RUNNER_GROUP`, as systemd units, one dedicated OS user, rootless docker, no sudo. It refuses a group that is not limited to selected workflows pinned to the default branch, so a pull request cannot reach them. Dry run unless `APPLY=1`. `grep -c '^do_gh_runner_add()' csi-spl-orc/src/bash/run/gh-runner-add.func.sh` -> 1. The group name is the one the org already uses; the action reads it from the API. Do not invent one in this guide.

```bash
cd <CHECKOUT>/csi-spl-orc && GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> APPLY=1 ./run -a do_gh_runner_add
```

<a id="ws-doc-d50b42d7-ff60-4844-8139-23ca24ed83e8"></a>
### 14.2 Check

`do_check_gh_runner` is read-only. A runner the CPU budget parked is `PARKED`, not a failure. The budget actions are `do_apply_gh_runner_cpu_budget` and `do_setup_gh_runner_cpu_budget_cron` (each function `grep -c` -> 1). The daily look at them is the operations guide.

```bash
cd <CHECKOUT>/csi-spl-orc && ./run -a do_check_gh_runner
```

<a id="ws-doc-98899cdd-2dbf-4855-b90c-87652a52cf51"></a>
### 14.3 Point the quality gate

`do_gh_set_ci_vars` sets the repo variable `SPOOL_CI_RUNNER`. Unset, workflow 10 already uses `[self-hosted, spool-ci]` on this repo. Set the variable only with this action. To leave self-hosted while a box is down, the workflow header names the hosted value. Jobs queue, they do not fail, when the runner is offline. `grep -c '^do_gh_set_ci_vars()' csi-spl-iac/src/bash/run/gh-set-ci-vars.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-iac && SPOOL_CI_RUNNER='"ubuntu-latest"' DRY_RUN=0 ./run -a do_gh_set_ci_vars
```

<a id="ws-doc-96e62bb1-a574-4563-a3c8-ec2a84aff95a"></a>
## 15 Version

<a id="ws-doc-af47a079-f49c-4d6c-a8f9-cea10519e53d"></a>
### 15.1 Mint

`do_release_version` claims a `v<X.Y.Z>` tag one step past the highest tag on the remote, or re-reads the tag the commit already has. Workflows 20 and 30 call it. So do `do_deploy_hub` and `do_deploy_wui`. Do not roll the version by hand. `.version` and cnf `hub.image.tag` are the floor. Raise the floor in the files the repo `CLAUDE.md` names, and only for a jump such as 2.0.0. A dry run pushes nothing. `grep -c '^do_release_version()' csi-spl-orc/src/bash/run/release-version.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ./run -a do_release_version
```

<a id="ws-doc-a10d9449-38f6-40ae-a339-3e0dfd71e1c3"></a>
### 15.2 The ruleset

`do_spl_gh_master_ruleset` is how the `master-no-force` ruleset is managed. Lifting it is the owner's, by hand. This guide does not run it. `grep -c '^do_spl_gh_master_ruleset()' csi-spl-iac/src/bash/run/spl-gh-master-ruleset.func.sh` -> 1. What a push to master must do is the developer guide.

<a id="ws-doc-32d23c7e-0990-4e86-b975-8759603c63dc"></a>
## 16 Tests in production (opt-in rule)

<a id="ws-doc-5ffe9592-a286-4c13-bcce-99d5a835d7ea"></a>
### 16.1 The opt-in rule

Tests do not run in production by default. CI quality gates (such as workflow `10_ci-quality.yml`) and pre-push hooks execute unit, lint, mock, and local integration tests, leaving production unexercised unless an explicit action or workflow is dispatched.

Production has an opt-in way to run any or all of the tests, where the operator picks which tests to run.

Owner words (HUM-10, t1 topic cd592c84-45ab-49a6-927c-0864718e53b9):

- 03:20Z msg 4dfc19b5-0118-4c7e-86b2-a04b26c995a1: "And regardless of the fact that these workspaces are test workspaces, we should have the capability to run all of the tests also in production."
- 03:21Z msg 05d5d1b6-3682-475b-88c5-cc37f37f0321: "They should not be run all of the time in production, but there should be a capability, if desired, to run all of the tests to pick what tests to run in production. Write down somewhere in some DevOps guide or somewhere else."

<a id="ws-doc-0e877793-cded-4a8d-89ba-fa7feb189d7f"></a>
#### Guardrails for production testing
- **Test workspaces only:** Production tests and proofs never target primary, owner, or tenant customer workspaces (`t1`, etc.). On `prd`, any test that writes state, creates sessions, seats members, or posts messages runs strictly inside dedicated test workspaces (default `e2e` or `e2e-*`, configured via `spl_test_workspaces`).
- **Destructive operations forbidden or gated:** Tests that drop tables, alter schemas (DDL), purge tenants, or mutate production data are forbidden on `prd` or protected by explicit confirmation flags (e.g. `PROBE_PRD_GO=1`, `ALLOW_PRD_RESTORE=1`).
- **Rate and load limits:** Active scanning, load tests, or crawler probes must respect strict rate limits (e.g. <= 5 req/s) to prevent degrading user service.
- **Non-blocking post-deploy verification:** Post-deploy probes running in CI on `prd` (such as `invite-e2e-prd` in workflow 20 or `verify` in workflow 22) run non-blocking (`continue-on-error: true`) so transient probe or network issues do not mark an already successful deploy as failed.

<a id="ws-doc-5e646b86-3c9a-416e-a845-63cd1a59a8e3"></a>
### 16.2 Current test suite inventory and production readiness

Read-only inventory of test suites, proofs, and probes across the estate: which can target `prd` today, which cannot, the commands to run them, and the gaps to follow up.

| suite / proof | command | file & evidence | targets prd today? | gap (follow-up) |
|---|---|---|---|---|
| Hub acceptance smoke | `ENV_NAME=prd bash csi-spl-orc/src/bash/scripts/verify-hub-endpoints.sh` (or CI workflow `22_deploy-verify.yml`) | `csi-spl-orc/src/bash/scripts/verify-hub-endpoints.sh:48` (`: "${ENV_NAME:?ENV_NAME must be set (dev \| prd)}"`) | yes | none (verifies `GET /` and `GET /version` over HTTPS on prd) |
| Member invite flow E2E | `cd csi-spl-orc && ENV=prd TENANT_ID=e2e ./run -a do_spl_invite_e2e` (or CI `20_hub-build-deploy.yml:815`) | `csi-spl-orc/src/bash/run/spl-invite-e2e.func.sh:44` (`# @example ENV=prd TENANT_ID=e2e ./run -a do_spl_invite_e2e`), line 50 (`spl_invite_e2e_test_workspace`) | yes (test workspace only) | none (runs invite -> mail -> sign-in -> bound; refuses `t1` and customer workspaces) |
| WUI live proof / parent-level | `cd csi-spl-orc && ENV=prd SPL_PROBE_PW=<secret> ./run -a do_spl_wui_live_proof` (or CI `30_wui-build-deploy.yml:565`) | `csi-spl-orc/src/bash/run/spl-wui-live-proof.func.sh:23` (`# @param ENV - required: dev or prd`), line 59 (refuses `#lobby`, uses `live_proof_channel`) | yes (with probe secret) | none (executes `parent-level-live.proof.mjs` against deployed WUI in hidden test channel) |
| M3 full E2E | `cd csi-spl-orc && ENV=prd M3_CREATE_TENANT=1 ./run -a do_spl_m3_e2e` | `csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh:85` (`# @example ENV=prd M3_CREATE_TENANT=1 ./run -a do_spl_m3_e2e`), line 89 (`[[ "${ENV:-}" == prd ]] && TENANT_ID="${TENANT_ID:-e2e}"`) | yes (test workspace only) | none (exercises hub auth, seating, channels, agents, messages in test tenant `e2e`) |
| WUI runtime first-load timing | `cd csi-spl-orc && ENV=prd PF_N=10 ./run -a do_spl_wui_perf_first_load` | `csi-spl-orc/src/bash/run/spl-wui-perf-first-load.func.sh:28` (`# @example ENV=prd PF_N=10 FL_CPU_PROFILE=1 ./run -a do_spl_wui_perf_first_load`), line 34 (`[[ "$ENV" == prd ]] && tenant=e2e \|\| tenant=t1`) | yes (test workspace only) | none (benchmarks first-load runtime timing on `e2e` workspace; refuses `t1` on prd) |
| WUI first-load network map | `cd csi-spl-orc && ENV=prd ./run -a do_spl_wui_perf_first_load_net` | `csi-spl-orc/src/bash/run/spl-wui-perf-first-load-net.func.sh:27` (`# @example ENV=prd ./run -a do_spl_wui_perf_first_load_net`), line 35 | yes (test workspace only) | none (measures network map on `e2e` workspace; refuses `t1` on prd) |
| WUI Flow + Event log timing | `cd csi-spl-orc && ENV=prd ./run -a do_spl_wui_perf_flow_events` | `csi-spl-orc/src/bash/run/spl-wui-perf-flow-events.func.sh:26` (`# @example ENV=prd ./run -a do_spl_wui_perf_flow_events`), line 33 | yes (test workspace only) | none (measures render timing on `e2e` workspace; refuses `t1` on prd) |
| WUI perf summary report | `cd csi-spl-orc && ENV=prd PERF_DAYS=7 ./run -a do_spl_wui_perf_report` | `csi-spl-orc/src/bash/run/spl-wui-perf-report.func.sh:28` (`# @example ENV=prd PERF_DAYS=7 ./run -a do_spl_wui_perf_report`) | yes | none (queries `GET /v1/admin/perf/summary` on prd) |
| Probe member seating | `cd csi-spl-orc && ENV=prd TENANT_ID=e2e PROBE_MEMBER_ROLE=developer DRY_RUN=0 ./run -a do_spl_probe_member_seat` | `csi-spl-orc/src/bash/run/spl-probe-member-seat.func.sh:38` (`# @example ENV=prd TENANT_ID=e2e-2 PROBE_MEMBER_ROLE=biz_owner DRY_RUN=0 ./run -a do_spl_probe_member_seat`), line 44 | yes (test workspace only) | none (seats probe human in prd test workspace) |
| Deploy lag & hub image check | `cd csi-spl-orc && ENV=prd ./run -a do_check_deploy_lag` / `ENV=prd ./run -a do_check_hub_deploy` | `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh:32`, `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh:25` | yes | none (checks live `/version` and `build.json` in prd) |
| Database backup verification & restore drill | `cd csi-spl-orc && ENV=prd ./run -a do_spl_db_backup_verify` / `ENV=prd TARGET=local DRY_RUN=0 ./run -a do_spl_db_restore` | `csi-spl-orc/src/bash/run/spl-db-backup-verify.func.sh:31`, `csi-spl-orc/src/bash/run/spl-db-restore.func.sh:63` | yes | none (restores prd GCS dump into local throwaway container and compares against live prd DB) |
| Message delivery probes | `cd csi-spl-orc && ENV=prd TENANT_ID=e2e ./run -a do_spl_delivery_probe` / `ENV=prd PROBE_PRD_GO=1 ./run -a do_spl_workspace_delivery_probe` | `csi-spl-orc/src/bash/run/spl-delivery-probe.func.sh:32`, `csi-spl-orc/src/bash/run/spl-workspace-delivery-probe.func.sh:70` | yes (test workspace only; `PROBE_PRD_GO=1` required) | none (exercises message delivery loop; gated on prd) |
| Stripe webhook probe | `cd csi-spl-orc && ENV=prd STRIPE_API_BASE=<base> DRY_RUN=0 ./run -a do_spl_stripe_webhook_probe` | `csi-spl-orc/src/bash/run/spl-stripe-webhook-probe.func.sh:27` (`# @example ENV=prd STRIPE_API_BASE=<stripe rest base> DRY_RUN=0 ./run -a do_spl_stripe_webhook_probe`), line 31 | yes | none (fires test payment webhook against prd without charging) |
| DAST security headers | `cd csi-spl-iac && ./run -a do_sec_headers` (workflow `68_dast.yml:43`) | `csi-spl-iac/src/bash/run/sec-headers.func.sh:33` (`_sec_headers_default_url`), line 130 | yes | Resolved: `do_sec_headers` now resolves the apex domain (`https://<BASE_DOMAIN>`) when `ENV=prd`. |
| OWASP ZAP baseline scan | dev (default, also the weekly schedule): `gh workflow run 68_dast.yml`; prd (opt-in): `gh workflow run 68_dast.yml -f environment=prd -f confirm_prd=prd` | `.github/workflows/68_dast.yml` (inputs `environment` dev \| prd default dev, `confirm_prd`; ZAP rate-limit rule `network.ratelimit.rules.rule(0).reqsPerSec=5` on the target host), test `csi-spl-iac/src/bash/tests/dast-prd-opt-in.tst.sh` | yes (opt-in, confirmed dispatch only) | Resolved T2: `environment=prd` without `confirm_prd=prd` fails before any request; prd scans the apex `https://<BASE_DOMAIN>` passively at <= 5 req/s; the security-headers job follows the same input (`ENV=prd`). |
| Database search index probe | dev (DDL probe, rolled back): `cd csi-spl-orc && ENV=dev ./run -a do_spl_search_index_probe`; prd (opt-in, read-only): `cd csi-spl-orc && ENV=prd PROBE_PRD_GO=1 ./run -a do_spl_search_index_probe` | `csi-spl-orc/src/bash/run/spl-search-index-probe.func.sh` (`spl_search_index_probe_check`, `spl_search_index_probe_ro_sql`, `spl_search_index_probe_ro_guard`), test `csi-spl-orc/src/bash/tests/spl-search-index-probe.tst.sh` (section 5) | yes (opt-in, read-only, test workspace only) | none (**T3 closed**, SPL-1799): `ENV=prd` without `PROBE_PRD_GO=1` is refused before any cnf, gcloud or psql call. With it, as the per-env prd service account, two `BEGIN TRANSACTION READ ONLY` sessions, each ending in `ROLLBACK`: the runtime login, on its own DSN, `EXPLAIN (ANALYZE, BUFFERS)` a rare-word `spool_search_candidates` call and counts its `messages_search` scans (G1); then the owner reads the catalog (btree_gin, `messages_search`, the function, its owner, the runtime login's EXECUTE) and the body's plan as `spool_search_reader`. No DDL, no GRANT, no SET ROLE to the runtime login, no insert, no temp table: a script holding a write is refused before psql runs. Whether the planner picks `messages_search` depends on the workspace's size: on a small `e2e` it may pick the btree. `TENANT_ID` defaults to `e2e` and must be `e2e` or `e2e-<x>`. dev keeps the DDL probe unchanged. |
| WUI browser E2E test suite | `cd csi-spl-wui && pnpm run test:e2e` | `csi-spl-wui/src/node/test/run-e2e-tests.mjs:16` ("`*.proof.mjs files are never discovered — they drive live sites`") | no (by design: mock / dev server) | none (the live proofs have their own picker, next row) |
| WUI live proofs (picker) | `cd csi-spl-wui && pnpm run test:live:proofs --list`, then `ENV=prd LIVE_PROOF_PRD_GO=1 BASE_URL=https://<BASE_DOMAIN> TENANT=e2e EMAIL=<probe member> PW_FILE=<0600 file> pnpm run test:live:proofs <name>...` | `csi-spl-wui/src/node/test/run-live-proofs.mjs` (`guardTarget`), test `csi-spl-wui/tests/unit/live-proof-runner.test.mjs` | yes (opt-in, test workspace only) | none (**T4 closed**, SPL-1771): lists every `*.proof.mjs` (`ro` = header says WRITES NOTHING, `rw?` = read it first), runs only the picked ones (names, paths or `--all`; no pick refuses), one at a time, no retry, `LIVE_PROOF_GAP_S` (default 5 s on prd) between them. `ENV=prd` needs `LIVE_PROOF_PRD_GO=1`; `TENANT` defaults to `e2e` and must be `e2e` or `e2e-<x>`, and a workspace label in the `BASE_URL` host must be one too (set `BASE_DOMAIN` to check it exactly), so `t1` and customer workspaces are refused. A `rw?` proof writes in that test workspace; pick `ro` ones for a read-only run. |
| Live chat WebSocket interop test | `cd csi-spl-wui && pnpm run test:live` (lde, door off); dev / prd: `ENV=prd LIVE_INTEROP_PRD_GO=1 HUB_URL=https://api.<BASE_DOMAIN> TENANT=e2e EMAIL=<probe member> PW_FILE=<0600 file> pnpm run test:live` (or `SESSION_COOKIE_FILE=<0600 file>` holding `<cookie name>=<value>` instead of `EMAIL` + `PW_FILE`) | `csi-spl-wui/tests/e2e/live-interop.test.mjs`, `csi-spl-wui/src/node/test/live-interop-target.mjs` (`interopTarget`, `openSession`), test `csi-spl-wui/tests/unit/live-interop-target.test.mjs` | yes (opt-in, test workspace only) | none (**T5 closed**, SPL-1782): runs with a test workspace member's session instead of the door off: the cookie rides the socket upgrade and the view reads. `GET /api/v1/auth/session` names the member and the workspace before any socket opens. `ENV=prd` needs `LIVE_INTEROP_PRD_GO=1` and a session; `TENANT` defaults to `e2e`, must be `e2e` or `e2e-<x>`, and must equal the session's workspace, so `t1` and customer workspaces are refused (exit 2). It WRITES three lobby posts and one small file in that workspace, so a prd run needs the owner's go. |
| Go API module test suite | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` | `csi-spl-api/src/bash/tests/run-all-tests.sh:2` | no (by design: unit / local integration) | none (the live API smoke, next row) |
| Live API smoke (read-only) | `cd csi-spl-orc && ENV=dev ./run -a do_spl_api_smoke`, `ENV=prd API_SMOKE_PRD_GO=1 ./run -a do_spl_api_smoke` | `csi-spl-orc/src/bash/run/spl-api-smoke.func.sh` (`_spl_api_smoke_guard`), test `csi-spl-orc/src/bash/tests/spl-api-smoke.tst.sh` | yes (opt-in, read-only) | none (**T6 closed**, SPL-1784): GETs only against the cnf `api_fqdn` (`api.<BASE_DOMAIN>` on prd), one at a time, no retry, no sign-in, `API_SMOKE_GAP_S` (default 1 s on prd) between requests. Public tier: `/version`, `/v1/health`, and the door (anonymous `/v1/view/me` and `/v1/operator/workspaces` answer 401). Member tier only with a 0600 session cookie of a test workspace (`TENANT` `e2e` or `e2e-<x>`; `API_SMOKE_COOKIE_FILE`, default the m3 e2e member's): `/v1/view/me` must name that workspace or the tier stops, then channels, roster, `/v1/openapi.json`; an expired cookie is a SKIP. `ENV=prd` needs `API_SMOKE_PRD_GO=1`. |
| Standby agent benchmark | `cd csi-spl-orc && ENV=prd BENCH_PRD_CONFIRM=1 BENCH_CONCURRENCY=2 ./run -a do_spl_standby_bench` | `csi-spl-orc/src/bash/run/spl-standby-bench.func.sh:37` (opt-in `ENV=prd` with `BENCH_PRD_CONFIRM`, concurrency <= 3, n <= 50) | yes | **Gap T7**: Resolved. Opt-in prd with strict concurrency caps (BENCH_CONCURRENCY <= 3, BENCH_N <= 50). |
| Test workspace purge | dev: `cd csi-spl-orc && ENV=dev PURGE_TENANTS="<id>..." ./run -a do_spl_tenant_test_purge`; prd (opt-in): `cd csi-spl-orc && ENV=prd PURGE_PRD_GO=1 PURGE_TENANTS="e2e-<x>..." ./run -a do_spl_tenant_test_purge` (dry run; `DRY_RUN=0` deletes) | `csi-spl-orc/src/bash/run/spl-tenant-test-purge.func.sh` (`spl_tenant_test_purge_prd_ok`), test `csi-spl-orc/src/bash/tests/tenant-test-purge.tst.sh` | yes (opt-in, `e2e-<x>` test workspaces only) | none (**T8 closed**, SPL-1809): `ENV=prd` without `PURGE_PRD_GO=1` is refused, and on prd every id must be `e2e-<x>` (the shared `e2e`, `t1` and customer workspaces are refused), both before any cnf, gcloud or psql call. The dev guards still apply: never a mapped tenant, a workspace with a message or one with a ready host; a 0600 backup of every `tenant_id` row comes first; dry run unless `DRY_RUN=0`. A prd `DRY_RUN=0` run WRITES, so it needs the owner's go first. |

<a id="ws-doc-244faf77-0ad6-4150-bb2b-9c47fde750a1"></a>
## 17 The disk guard

The box disk sweep frees each box's disk on a schedule. Install it on every box that runs agent lanes, from the main checkout (an install from a linked worktree is refused: its path vanishes with the worktree). A dry run prints the crontab change; `DRY_RUN=0` installs one line, tagged `# csi-spl:box-disk-sweep`, every 15 minutes.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_box_disk_sweep_install_cron
```

The line runs `box-disk-sweep.sh`, whose `workdirs` step runs `cd csi-spl-utl && ./run -a do_sweep_workdirs`: it removes the finished lanes' directories that the retire listed in `$SPOOL_ROOT/workdirs.tsv`.

Thresholds of the `workdirs` step, cnf `env.box.workdir_sweep` in `csi-spl-cnf/csi-spl/all.env.yaml` (an env var of the same upper-case name wins, e.g. `WORKDIR_SWEEP_AGE_H`):

| key | default | meaning |
|---|---|---|
| `age_h` | 24 | a listed directory is removed this many hours after its lane finished |
| `crit_age_h` | 6 | the limit when the disk is critical |
| `crit_free_pct` | 8 | critical: the lowest free % of `/`, `/mnt/data` and `/tmp` is at or under this |

The sweep's other limits are env vars on the cron line (`BOX_SWEEP_LOW_FREE_PCT` 15, `BOX_SWEEP_CRIT_FREE_PCT` 7, the age of each step): see the header of `box-disk-sweep.sh`.

<a id="ws-doc-b3b747e9-7b1b-41d1-869a-a4aec5e92645"></a>
## 18 Rollback

Point an environment back at a release it served before (SPL-2131). Two actions in `csi-spl-orc`, the WUI first, then the hub, always on `dev` first and the same `TO` on `prd` afterwards:

```bash
cd csi-spl-orc && ENV=dev TO=previous ./run -a do_wui_rollback
```

```bash
cd csi-spl-orc && ENV=dev TO=previous ./run -a do_hub_rollback
```

- `TO` has no default: a v-tag (`v1.2.0`), a commit sha, `previous`, a Cloud Run revision name (hub) or a Firebase Hosting version id (WUI).
- `DRY_RUN=1` is the default and only prints the plan; `DRY_RUN=0` switches.
- Return codes: 2 a bad form, 3 an unknown target, 4 `prd` while `dev` does not serve that commit (`ENV_ORDER_OVERRIDE=<owner msg id>`), 5 a newer migration that is not additive (DROP, RENAME, SET NOT NULL, a type change): set `ROLLBACK_SCHEMA_OK=1` only after reading the migrations it lists.
- After the switch each action checks that `/version` or `build.json` serves the target; a failed WUI check re-releases the version that was live before.
- A rollback holds only until the next deploy or the wf 21 catch-up. To keep it, disable wf 21 and land a revert on master.

The compose path and the details: `DEPLOY.md` section 2.5.

<a id="ws-doc-925991a0-30e3-44af-9590-058f10e0bd91"></a>
## 19 Gaps

A step with no action, or an action that refuses the from-scratch case. Each one is a candidate lane. None of these was written above as if it already worked.

| id | what is missing | what exists instead |
|---|---|---|
| D1 | no `do_*` wraps `gcloud auth login` for the org admin | the iac README names the command; gcp-000 refuses without a token |
| D2 | no single action applies every step in the legal env order | `do_tf_sweep_steps` with an explicit `STEPS` and `ENVS`, as the sections above |
| D3 | the first `make do-provision` of 030 returns 1 when the service does not exist yet | `do_check_hub_image_regress` describes the live service before it decides; `ALLOW_IMAGE_REGRESS` does not cover a missing service |
| D4 | `make do-import` requires `AWS_PROFILE` | `do_tf_import` exists (`grep -c '^do_tf_import()' csi-spl-iac/src/bash/run/tf-import.func.sh` -> 1) but the make target is not a GCP path, and terraform on the host is forbidden |
| D5 | closed 2026-10-15 (SPL-1910): the step it named left this repository | none |
| D6 | no `do_*` restores a Cloud SQL PITR timestamp | `do_spl_db_restore` restores the logical dump |
| D7 | `make do-provision-and-update-gh-keys` calls `do_github_update_gcp_keys` | `grep -c '^do_github_update_gcp_keys()' csi-spl-iac/src/bash/run/*.func.sh csi-spl-orc/src/bash/run/*.func.sh` -> 0; step 120 is the action that sets the secrets |
| D8 | the owner's approval is spoken for that call; no action records it | every apply section above waits for it |

<a id="ws-doc-383be4b8-5cc5-4018-a082-7d6adf8c02ae"></a>
## 20 Docs this guide replaces

| doc | what happens to it |
|---|---|
| `csi-spl-doc/doc/md/HOWTO-local-cloud-deploy.md` | the two box deploys live here (`do_deploy_hub`, `do_deploy_wui`); that file is a pointer to this guide |
| `csi-spl-iac/README.md` | stays; `readme-bootstrap.tst.sh` pins the bootstrap contract in it |
| spec 007, spec 029, spec 044 | stay; they are the design record, this is the operator path |
| `csi-spl-doc/doc/md/box-state-backup.md` | stays; box state is the installation guide |
| the system guide, the installation guide, the operations guide | the other three guides |

<a id="ws-doc-af3aa8f4-395a-4c2d-826e-b51b29e90e03"></a>
## 21 How a count was taken

The `grep -c` figures in this guide are the count of the function line `^<action>()` in the file named next to it. They were taken on commit `b51567f09`. Those function files are unchanged through `396613b00`. The count for `do_spl_wine_box_budget_tf` is on commit `bfede0918`, in the wine-box section. The form is one action, one file.

```bash
grep -c '^do_gcp_000_bootstrap_gcp_env()' csi-spl-iac/src/bash/run/gcp-000-bootstrap-gcp-env.func.sh
```
