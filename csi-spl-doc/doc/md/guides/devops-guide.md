Exported from the Qto doc [DevOps guide](https://spool-hub.ai/workspace/docs?doc=78e51717-7bcb-4b12-9da8-80af726f8882&view=doc) (`78e51717-7bcb-4b12-9da8-80af726f8882`) on 2026-10-11T20:29:06Z; edit in Qto, not here.

# 1 About this guide

This guide builds the GCP estate of the spool from a checkout of the repo: the projects, the service-account keys, terraform through the tf-runner, Cloud Run, Cloud SQL, Firebase Hosting, DNS, the GitHub workflows, the runners, and a restore from backup. It changes nothing by being read. Every mutating command is a dry run until you add `DRY_RUN=0` or, for terraform, until you run `make do-provision` after a plan you have read. An apply needs the owner's approval for that call.

It is one of four guides. The others are linked, not copied.

| guide | answers |
|---|---|
| System guide | what the parts are |
| Installation and configuration guide | a box, from an empty Debian 13 |
| DevOps guide (this one) | the GCP estate and the pipelines |
| Operations and maintenance guide | the daily and weekly routine |

## 1.1 What you hold

| item | what for |
|---|---|
| the GitHub repo `csitea/csi-spl` on a box that already has the checkout | every action below |
| the GCP organisation owner login | only gcp-000..004, and only while that project's key does not exist yet |
| `GCP_BILLING_ACCOUNT_ID` in the environment | gcp-001 links the project to it; the value is never in the repo |
| the per-env project keys, once bootstrap has written them | everything after the keys exist |
| the owner's approval | every terraform apply, every project create |

For a box that does not exist yet, follow the installation guide, sections 3 to 5 (packages, the two users, the checkout, tpl-gen at its pin, the key table). Come back here, then finish that guide. The product domain is cnf `env.dns.BASE_DOMAIN`. This guide never pastes it.

## 1.2 Conventions

| placeholder | means |
|---|---|
| `<CHECKOUT>` | the main checkout, the installation guide's `/opt/csi/csi-spl` |
| `<OWNER_USER>` | the OS user that owns the checkout, the keys and docker |
| `<ENV>` | `dev` or `prd`, unless a step says `bkp` or `all` |
| `<ORG>` `<APP>` | resolved by the action (`do_resolve_oap`); you do not type them |

Run every command as `<OWNER_USER>`, from `<CHECKOUT>`, never from an agent worktree. One `./run` action is a dry run unless `DRY_RUN=0`. `make do-tf-plan` is the plan. `make do-provision` applies. Terraform runs only inside the tf-runner container.

A block that shows only `ENV=dev` is repeated for prd with `ENV=prd`, unless the section says the step is dev only, prd only, `bkp` or `all`.

## 1.3 Where the rules live

Do not copy these. The fleet rules index, the developer guide and the repo `CLAUDE.md` are the homes. The provisioning rules this guide follows are spec 007, requirement R7 (numeric steps, dev then prd, DNS the other way) and R8 (the project service account after the key exists): [infra-provisioning-requirements.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/007-spool-hub-api-infra/infra-provisioning-requirements.md). The module contract the bootstrap test pins is [csi-spl-iac/README.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-iac/README.md). It stays; this guide does not replace it.

# 2 Identity

## 2.1 After a project key exists

Every later action resolves one identity: an explicit `GCP_ACCOUNT`, else the project service account in that env's key, else it refuses. It passes `--account` on every gcloud call. It does not write the shared gcloud config, and it does not fall back to the owner login. The owner address is read only by gcp-000..004, from cnf `env.gcp.gcp_account_owner_email`, and only while the key file is absent. A key that lacks a permission is reported.

The gate is `bash csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`. `grep -c '^do_gcp_pin_account()' csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh` -> 1. The same function is also defined under `csi-spl-orc` (count 2 across the two trees).

## 2.2 The human login

Creating the first project needs the org admin signed in. There is no `do_*` action for that login. It is gap D1. The iac README names the command, and gcp-000 refuses until that login can mint a token. Do it once, as `<OWNER_USER>`, before the first bootstrap, and do not run it again once the key file exists. This login writes the shared gcloud config. It is the one bootstrap exception to the rule that later actions leave that config alone.

`GCP_ACCOUNT` here is the org admin, for this one step. It is not the project service account.

```bash
gcloud auth login "${GCP_ACCOUNT:?GCP_ACCOUNT must be set}"
```

# 3 Bootstrap

`do_gcp_000_bootstrap_gcp_env` runs four idempotent steps and stops at the first failure: gcp-001 (project and billing), gcp-002 (the project service account and one key), gcp-003 (`roles/owner` on that project), gcp-004 (the four APIs terraform needs before it can start). The project id is cnf `env.gcp.gcp_project`. The org id is cnf `env.gcp.gcp_org_id` unless `GCP_ORG_ID` or `GCP_FOLDER_ID` is set. `GCP_BILLING_ACCOUNT_ID` is required and is not in the repo.

`grep -c '^do_gcp_000_bootstrap_gcp_env()' csi-spl-iac/src/bash/run/gcp-000-bootstrap-gcp-env.func.sh` -> 1.

## 3.1 Dry run, dev

Leave `DRY_RUN` unset. Read the log. Nothing is created.

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

## 3.2 Apply, dev

The owner's approval is required for this call. The same shape, with `DRY_RUN=0`, is then repeated for `prd`, `bkp` (the off-project backup project, step 046) and `all` (the satellite project, steps 059 and 060).

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

## 3.3 Apply, prd

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=prd DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

## 3.4 Apply, backup project

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=bkp DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

## 3.5 Apply, satellite project

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=all DRY_RUN=0 GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

## 3.6 What 000 runs

| step | action | what it does | grep -c of the function |
|---|---|---|---|
| gcp-001 | `do_gcp_001_create_project` | create the project and link billing | 1 |
| gcp-002 | `do_gcp_002_create_project_service_account` | create the project SA and write one key, mode 600 | 1 |
| gcp-003 | `do_gcp_003_configure_proj_sa_permissions` | grant that SA `roles/owner` on its project | 1 |
| gcp-004 | `do_gcp_004_project_apis_enable` | enable cloudresourcemanager, serviceusage, storage, iam | 1 |

Each function lives in `csi-spl-iac/src/bash/run/` under the file named in the action. The key path is printed by gcp-002 as `$HOME/.gcp/.<org>/key-<project-id>.json`. Do not print the file. Do not commit it. After it exists, stop using the owner login.

# 4 Render the tfvars

## 4.1 The tpl-gen pin

tpl-gen is the git-ignored sibling clone `<CHECKOUT>/tpl-gen`. `do_tpl_gen` refuses unless its HEAD equals `csi-spl-iac/cnf/tpl-gen.ref`. The clone itself is the installation guide.

```bash
git -C <CHECKOUT>/tpl-gen rev-parse HEAD
```

## 4.2 Compare the pin

The two SHAs are the same, or you check out the pin before rendering. A render from any other commit is not the one the repo ships.

```bash
cat <CHECKOUT>/csi-spl-iac/cnf/tpl-gen.ref
```

## 4.3 Render dev

`do_tpl_gen` deep-merges `all.env.yaml` under `<env>.env.yaml` and writes `csi-spl-cnf/csi-spl/<env>/tf/*.tfvars`. `grep -c '^do_tpl_gen()' csi-spl-iac/src/bash/run/tpl-gen.func.sh` -> 1. One step at a time, with the conf-validator in front, is `make do-generate-config-for-step` (`grep -c '^do-generate-config-for-step:' csi-spl-orc/src/make/generate-config-for-step.func.mk` -> 1). A full rebuild uses the action below.

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev ./run -a do_tpl_gen
```

## 4.4 Render prd

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=prd ./run -a do_tpl_gen
```

## 4.5 The render matches the commit

A fresh render of a clean checkout produces no diff. If this prints a diff, commit the cnf change on its own before any apply. Do not apply from uncommitted tfvars.

```bash
git -C <CHECKOUT> diff --exit-code -- csi-spl-cnf/csi-spl/dev/tf csi-spl-cnf/csi-spl/prd/tf
```

# 5 Terraform

## 5.1 Start the tf-runner

From the main checkout only, and not while another apply is running. This builds the tf-runner, tpl-gen and conf-validator images and does `down --rmi all` first, so it is one stack per box. `GITHUB_TOKEN` is the token handed over out of band. `grep -c '^do-setup-app-inf:' csi-spl-orc/src/make/setup-app-inf.func.mk` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && GITHUB_TOKEN="${GITHUB_TOKEN:?}" make do-setup-app-inf
```

## 5.2 Plan one step

`make do-tf-plan` runs `do_tf_plan` inside the tf-runner. `do_tf_init` points `GOOGLE_APPLICATION_CREDENTIALS` at the project key and wipes `csi-spl-iac/bin/<org>/<app>/<env>/<step>` first, so two runs on the same env and step break each other. `grep -c '^do-tf-plan:' csi-spl-orc/src/make/tf-tasks.func.mk` -> 1. `grep -c '^do_tf_plan()' csi-spl-iac/src/bash/run/tf-plan.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-tf-plan
```

## 5.3 Apply one step

The owner's approval is required for this call. `make do-provision` runs `do_check_container_dns`, then for step 030 `do_check_hub_image_regress`, then `do_provision` in the tf-runner. `grep -c '^do-provision:' csi-spl-orc/src/make/tf-tasks.func.mk` -> 1. `grep -c '^do_provision()' csi-spl-iac/src/bash/run/provision.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-provision
```

## 5.4 One run at a time

One env and one step at a time, from the checkout the tf-runner mounts. State lives in the env's terraform state bucket (step 000), not in the wiped run directory. Destroy one step with `make do-deprovision`, which runs `do_divest` in the tf-runner. `grep -c '^do-deprovision:' csi-spl-orc/src/make/tf-tasks.func.mk` -> 1. `grep -c '^do_divest()' csi-spl-iac/src/bash/run/divest.func.sh` -> 1. A list of steps is `do_tf_deprovision_steps`, and `STEPS` has no default.

## 5.5 The steps

`find csi-spl-iac/src/terraform -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort` is the numeric order. Apply dev then prd for each step, except where the table says otherwise. Spec 007 R7: on a rebuild of an estate that already exists, do not destroy `020-gcp-relay-bucket` or `040-cloud-sql-postgres`; import them. A from-scratch project creates them. The import make target is gap D4.

| step | env | what it creates |
|---|---|---|
| 000-gcp-remote-bucket | dev, then prd | the terraform state bucket |
| 001-enable-gcp-services | dev, then prd | the rest of the APIs |
| 005-gcp-domain-verification | dev, then prd | domain verification |
| 016-firebase-deploy-iam | dev, then prd | IAM for the Firebase deploy |
| 017-github-wif-deploy | dev, then prd | GitHub workload identity for deploy |
| 019-firebase-static-site | dev, then prd | the Firebase Hosting site |
| 020-gcp-relay-bucket | dev, then prd | the git-rel relay bucket; its sender key is not created here (gap D5) |
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

## 5.6 Do not sweep every step on both envs

`do_tf_sweep_steps` plans, and with `DRY_RUN=0` applies, a list of steps. Default `STEPS` is every step directory. Default `ENVS` is `dev prd`. It stops on a plan error, a destroy, or a replace. `058` and `061` validate `env == dev`. `059` and `060` validate `env == prd`. A default sweep stops on the first of those. `025` wants `ENVS="prd dev"`. Pass `STEPS` and `ENVS` yourself. `grep -c '^do_tf_sweep_steps()' csi-spl-orc/src/bash/run/tf-sweep-steps.func.sh` -> 1.

## 5.7 Plan the shared steps

This list holds 030, 032, 036, 025, 058, 059, 060 and 061 out. Read the plan log before the apply.

```bash
cd <CHECKOUT>/csi-spl-orc && ENVS="dev prd" STEPS="000-gcp-remote-bucket 001-enable-gcp-services 005-gcp-domain-verification 016-firebase-deploy-iam 017-github-wif-deploy 019-firebase-static-site 020-gcp-relay-bucket 028-gcp-artifact-registry 040-cloud-sql-postgres 045-gcs-db-backups 046-gcs-offsite-backups 050-gcs-files 051-gcs-docs 052-gcs-workspace-docs 054-gcs-blog-media 055-gcp-kms-marketing 056-gcs-box-state 057-gcp-kms-vendor-keys 070-gcp-monitoring 120-github-general-secrets" ./run -a do_tf_sweep_steps
```

## 5.8 Apply the shared steps

The owner's approval is required. Same `STEPS` and `ENVS` as the plan. `DRY_RUN=0` applies only a plan that adds or changes, and stops on a destroy or a replace.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS="000-gcp-remote-bucket 001-enable-gcp-services 005-gcp-domain-verification 016-firebase-deploy-iam 017-github-wif-deploy 019-firebase-static-site 020-gcp-relay-bucket 028-gcp-artifact-registry 040-cloud-sql-postgres 045-gcs-db-backups 046-gcs-offsite-backups 050-gcs-files 051-gcs-docs 052-gcs-workspace-docs 054-gcs-blog-media 055-gcp-kms-marketing 056-gcs-box-state 057-gcp-kms-vendor-keys 070-gcp-monitoring 120-github-general-secrets" ./run -a do_tf_sweep_steps
```

# 6 Cloud SQL

## 6.1 Bootstrap the database, dev

After step 040, before step 030. `do_spl_db_bootstrap` creates the owner login and the runtime login, writes their DSN secret versions, and runs `spool migrate` as the owner through the Cloud SQL proxy. Passwords are not logged. 040 leaves the slots empty on purpose, so they never sit in the state bucket. On a fresh env this action does the split. If it tells you the runtime slot still holds the owner, run the next section. `grep -c '^do_spl_db_bootstrap()' csi-spl-orc/src/bash/run/spl-db-bootstrap.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap
```

## 6.2 Bootstrap the database, prd

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=prd DRY_RUN=0 ./run -a do_spl_db_bootstrap
```

## 6.3 Split owner from runtime

Only when bootstrap says the runtime slot still holds the owner. The owner keeps the schema. The runtime login gets DML grants. The hub reads the runtime DSN. `grep -c '^do_spl_db_owner_split()' csi-spl-orc/src/bash/run/spl-db-owner-split.func.sh` -> 1. `ROLLBACK=1` and `ROTATE_OWNER=1` are separate runs; the function header says what each does.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_db_owner_split
```

## 6.4 Automated backups

Step 040 turns on Cloud SQL automated backups and point-in-time recovery. Workflow 45 is additive: a Cloud SQL backup restores only into Cloud SQL and dies with the project. There is no `do_*` action that restores a PITR timestamp. That is gap D6. The logical dump is the next section.

# 7 Cloud Run

## 7.1 Apply the hub service

Step 030 creates the service and then ignores the image (`lifecycle ignore_changes`), so a later apply does not roll it back. The image is minted and rolled by workflow 20, or from the box by `do_deploy_hub`.

The first apply, when no service exists yet, is gap D3. `make do-provision` of step 030 runs `do_check_hub_image_regress` first, and that action returns 1 when `gcloud run services describe` cannot see a service. `ALLOW_IMAGE_REGRESS` is checked only after a live image is read, so it does not unlock the first create. Do not docker-exec terraform on the host to get past it.

When the service already exists, the sweep is the path. The owner's approval is required.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS=030-cloud-run-hub ./run -a do_tf_sweep_steps
```

## 7.2 Domain mapping

After 030, and only when cnf sets a custom domain. The cert is Google's; `do_spl_wait_for_mapping_cert` polls it. `grep -c '^do_spl_wait_for_mapping_cert()' csi-spl-orc/src/bash/run/spl-wait-for-mapping-cert.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS=032-gcp-cloud-run-domain-mapping ./run -a do_tf_sweep_steps
```

## 7.3 Deploy the hub from the box

Workflow 20 does this on a push that changes a hub input. From a box, `do_deploy_hub` is the same sequence: the commit must be on `origin/master`, `do_release_version`, `do_build_push_hub_image` when the tag is missing, `do_spl_db_bootstrap`, roll the service, `do_heal_hub_deploy`, `do_check_hub_deploy`. Dry run first. `grep -c '^do_deploy_hub()' csi-spl-orc/src/bash/run/deploy-hub.func.sh` -> 1. Dev, then prd.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_deploy_hub
```

## 7.4 The regress guard

`do_check_hub_image_regress` refuses a 030 apply that would move the live image backwards. A newer cnf tag is allowed. A tree whose 030 ignores the image reports `ahead` and exits 0. `grep -c '^do_check_hub_image_regress()' csi-spl-orc/src/bash/run/check-hub-image-regress.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev ./run -a do_check_hub_image_regress
```

# 8 DNS and tenants

## 8.1 The zone, prd then dev

Spec 007 R7: apply `025-gcp-dns-zone` on prd before dev, and destroy it on dev before prd. The owner's approval is required.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="prd dev" STEPS=025-gcp-dns-zone ./run -a do_tf_sweep_steps
```

## 8.2 One tenant host

`do_spl_tenant_host_provision` adds the tenant to cnf `env.dns.mapped_tenants` and to `steps.052-gcs-workspace-docs.workspaces`, renders 052, 019 and 025, plans, and refuses a destroy. It then waits for the Firebase cert and probes the host. The apex tenant is not given a second host. Dry run first. `grep -c '^do_spl_tenant_host_provision()' csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh` -> 1. The steps inside it call `do_spl_wait_for_firebase_domain` and `do_spl_probe_wui_host` (each `grep -c` of the function -> 1).

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TENANT_ID=<TENANT> DRY_RUN=0 ./run -a do_spl_tenant_host_provision
```

# 9 Firebase Hosting

## 9.1 Deploy the WUI from the box

Workflow 30 does this on a push that changes a WUI input. From a box, `do_deploy_wui` generates the site and runs `firebase deploy --only hosting` as the project service account. It does not use a firebase login on the box. Dev, then prd. `grep -c '^do_deploy_wui()' csi-spl-orc/src/bash/run/deploy-wui.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_deploy_wui
```

## 9.2 Prove the deploy

`do_check_deploy_lag` reads the hub `/version` and the WUI `build.json` for the commit, not the image tag in cnf. Exit 0 is current or pending. Exit 3 is lagging. `grep -c '^do_check_deploy_lag()' csi-spl-orc/src/bash/run/check-deploy-lag.func.sh` -> 1. `do_check_hub_deploy` answers a different question: does the live image equal the tag cnf names. `grep -c '^do_check_hub_deploy()' csi-spl-orc/src/bash/run/check-hub-deploy.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev ./run -a do_check_deploy_lag
```

# 10 The other env-gated steps

## 10.1 Wine box budget, plan

Step 058 is the dev wine-box budget. `do_spl_wine_box_budget_tf` reads the billing account from the dev project's billing link, as the dev project service account, and passes it only into that one make run, so the account stays out of the log. Leave `TF_VERB` unset: this is the plan. `grep -c '^do_spl_wine_box_budget_tf()' csi-spl-iac/src/bash/run/spl-wine-box-budget-tf.func.sh` -> 1, on commit `bfede0918`. The prd render of 058 is a marker and is not applied.

```bash
cd <CHECKOUT>/csi-spl-iac && ./run -a do_spl_wine_box_budget_tf
```

## 10.2 Wine box budget, apply

The owner's approval is required for this call. The same action, with `TF_VERB=provision`.

```bash
cd <CHECKOUT>/csi-spl-iac && TF_VERB=provision ./run -a do_spl_wine_box_budget_tf
```

## 10.3 Wine box VM

After the budget apply. Dev only. The prd render carries a marker and is not applied.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS=dev STEPS=061-gcp-vm-wine-box ./run -a do_tf_sweep_steps
```

## 10.4 Satellite, prd only

Budget, then the VM. Both render from prd and create resources in the satellite project (bootstrap `ENV=all` first). The Ansible playbook that the 060 apply runs is the installation guide and `SYS.md`, not this guide.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS=prd STEPS="059-gcp-satellite-budget 060-gcp-vm-satellite" ./run -a do_tf_sweep_steps
```

## 10.5 Demo workspace

After `do_deploy_hub` for that env. `make do-provision` of step 036 builds the spool CLI on the host first. The private key the action writes is not a terraform output. Do not print it.

```bash
cd <CHECKOUT>/csi-spl-orc && DRY_RUN=0 ENVS="dev prd" STEPS=036-spl-demo-workspace ./run -a do_tf_sweep_steps
```

# 11 Backups

## 11.1 Take a dump

`do_spl_db_backup` runs `gcloud sql export` inside Google, into the 045 bucket, as the project service account. No row and no password cross the box. Workflow 45 does this daily, then verifies, then copies off-project. `grep -c '^do_spl_db_backup()' csi-spl-orc/src/bash/run/spl-db-backup.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_db_backup
```

## 11.2 Prove the dump

Restores the newest object into a throwaway Postgres container on this box and compares tables to the live database, read-only. A missing table, or a table that restores empty while live has rows, fails. Equal counts are not the test. `grep -c '^do_spl_db_backup_verify()' csi-spl-orc/src/bash/run/spl-db-backup-verify.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev ./run -a do_spl_db_backup_verify
```

## 11.3 Copy off the project

`do_spl_backup_offsite` copies new 045 dumps and 050 files into the 046 bucket. The env service account can add an object there and cannot read it back. While cnf `steps.046-gcs-offsite-backups.copy_enabled` is false the action exits 0. `grep -c '^do_spl_backup_offsite()' csi-spl-orc/src/bash/run/spl-backup-offsite.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev DRY_RUN=0 ./run -a do_spl_backup_offsite
```

# 12 Restore from backup

## 12.1 Copy the estate before a destroy

`do_gcp_backup_env` is read-only against GCP. It writes state, secret versions, DNS zones, the relay and files buckets, image tags and a database dump under a 0700 directory. Secret values are files, mode 600, and are not logged. Take it, and a green `do_spl_db_backup`, before `do_tf_deprovision_steps`. `grep -c '^do_gcp_backup_env()' csi-spl-iac/src/bash/run/gcp-backup-env.func.sh` -> 1. `grep -c '^do_tf_deprovision_steps()' csi-spl-orc/src/bash/run/tf-deprovision-steps.func.sh` -> 1. `STEPS` is required.

```bash
cd <CHECKOUT>/csi-spl-iac && ENV=dev ./run -a do_gcp_backup_env
```

## 12.2 Drill on this box

The default target is a throwaway container, removed at the end. `BACKUP_SOURCE` defaults to `bkp` when the off-project copy is enabled, else `env`. `grep -c '^do_spl_db_restore()' csi-spl-orc/src/bash/run/spl-db-restore.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TARGET=local DRY_RUN=0 ./run -a do_spl_db_restore
```

## 12.3 Drill on a throwaway database

A new database on the same instance, dropped after the count unless `KEEP=1`.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TARGET=database:spool_restore_drill DRY_RUN=0 ./run -a do_spl_db_restore
```

## 12.4 Restore into a recreated instance

`TARGET=env` is refused while the hub database still has tables. Prd also needs `ALLOW_PRD_RESTORE=1`. This is the disaster path after step 040 and `do_spl_db_bootstrap` have recreated an empty database. When the env project itself is gone, `BACKUP_SOURCE=bkp` reads the backup project.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev TARGET=env BACKUP_SOURCE=bkp DRY_RUN=0 ./run -a do_spl_db_restore
```

## 12.5 Restore the file bucket

`do_spl_files_restore` is the 050 half. `SOURCE=bkp` is the off-project copy. `TARGET=env` does not replace an object that is already there. Prd needs `ALLOW_PRD_RESTORE=1`. `grep -c '^do_spl_files_restore()' csi-spl-orc/src/bash/run/spl-files-restore.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=dev SOURCE=bkp TARGET=local DRY_RUN=0 ./run -a do_spl_files_restore
```

## 12.6 Erase one file on request

`do_spl_file_erase` removes one `FILE_ID` (a file posted by mistake) everywhere we hold it, and reads each leg back. The hub leg deletes `t/<tenant>/files/<id>` from the 050 bucket as the env SA: the object `DELETE /v1/files/{id}` removes, whose route needs a box upload token no operator holds. The box leg removes every path on this box whose name carries the id, under every real home and the spool and tmp trees, `find -xdev` per root. The backup leg only reports: the off-project copy keeps an object for its retention, and a delete there needs the owner's go for that delete. `DRY_RUN=1` is the default. `grep -c '^do_spl_file_erase()' csi-spl-orc/src/bash/run/spl-file-erase.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && FILE_ID=<sha256> ENV=prd TENANT=<tenant> DRY_RUN=0 ./run -a do_spl_file_erase
```

On a box with no env key, run the box leg alone.

```bash
cd <CHECKOUT>/csi-spl-orc && FILE_ID=<sha256> HUB_LEG=0 BKP_LEG=0 DRY_RUN=0 ./run -a do_spl_file_erase
```

# 13 Workflows

## 13.1 What each one gates

The file is `.github/workflows/<file>`. Runner is the literal `runs-on` in that file, measured by reading it. Workflow 10's `runs-on` is an expression: the caller's input, else the repo variable `SPOOL_CI_RUNNER`, else `[self-hosted, spool-ci]` on this repo, else `ubuntu-latest`.

| file | gates | runner |
|---|---|---|
| 00_deploy-lag-watch.yml | `do_check_deploy_lag` on a schedule | ubuntu-latest |
| 10_ci-quality.yml | the quality gate on every master push; a docs-only push skips the code jobs | expression, self-hosted `spool-ci` on this repo |
| 11_ci-public.yml | the same gate for a pull request, after a maintainer approves it | passes ubuntu-latest into 10 |
| 15_sec-deps-secrets.yml | dependency and secret scans | ubuntu-latest |
| 20_hub-build-deploy.yml | mint, build, migrate, roll the hub; then, non-blocking, the invite e2e (`do_spl_invite_e2e`) on dev t1 and on prd in the test workspace `e2e` only (`vars.INVITE_E2E_TENANT_PRD`; t1 and customer workspaces are refused) | ubuntu-latest |
| 21_hub-deploy-catchup.yml | a trunk hub or WUI that never got served | ubuntu-latest |
| 22_deploy-verify.yml | HTTPS smoke of the hub and the WUI | ubuntu-latest |
| 30_wui-build-deploy.yml | mint and Firebase Hosting | ubuntu-latest |
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

# 14 Runners

## 14.1 Register

`do_gh_runner_add` registers org runners in `GH_RUNNER_GROUP`, as systemd units, one dedicated OS user, rootless docker, no sudo. It refuses a group that is not limited to selected workflows pinned to the default branch, so a pull request cannot reach them. Dry run unless `APPLY=1`. `grep -c '^do_gh_runner_add()' csi-spl-orc/src/bash/run/gh-runner-add.func.sh` -> 1. The group name is the one the org already uses; the action reads it from the API. Do not invent one in this guide.

```bash
cd <CHECKOUT>/csi-spl-orc && GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> APPLY=1 ./run -a do_gh_runner_add
```

## 14.2 Check

`do_check_gh_runner` is read-only. A runner the CPU budget parked is `PARKED`, not a failure. The budget actions are `do_apply_gh_runner_cpu_budget` and `do_setup_gh_runner_cpu_budget_cron` (each function `grep -c` -> 1). The daily look at them is the operations guide.

```bash
cd <CHECKOUT>/csi-spl-orc && ./run -a do_check_gh_runner
```

## 14.3 Point the quality gate

`do_gh_set_ci_vars` sets the repo variable `SPOOL_CI_RUNNER`. Unset, workflow 10 already uses `[self-hosted, spool-ci]` on this repo. Set the variable only with this action. To leave self-hosted while a box is down, the workflow header names the hosted value. Jobs queue, they do not fail, when the runner is offline. `grep -c '^do_gh_set_ci_vars()' csi-spl-iac/src/bash/run/gh-set-ci-vars.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-iac && SPOOL_CI_RUNNER='"ubuntu-latest"' DRY_RUN=0 ./run -a do_gh_set_ci_vars
```

# 15 Version

## 15.1 Mint

`do_release_version` claims a `v<X.Y.Z>` tag one step past the highest tag on the remote, or re-reads the tag the commit already has. Workflows 20 and 30 call it. So do `do_deploy_hub` and `do_deploy_wui`. Do not roll the version by hand. `.version` and cnf `hub.image.tag` are the floor. Raise the floor in the files the repo `CLAUDE.md` names, and only for a jump such as 2.0.0. A dry run pushes nothing. `grep -c '^do_release_version()' csi-spl-orc/src/bash/run/release-version.func.sh` -> 1.

```bash
cd <CHECKOUT>/csi-spl-orc && ./run -a do_release_version
```

## 15.2 The ruleset

`do_spl_gh_master_ruleset` is how the `master-no-force` ruleset is managed. Lifting it is the owner's, by hand. This guide does not run it. `grep -c '^do_spl_gh_master_ruleset()' csi-spl-iac/src/bash/run/spl-gh-master-ruleset.func.sh` -> 1. What a push to master must do is the developer guide.

# 16 Tests in production (opt-in rule)

## 16.1 The opt-in rule

Tests do not run in production by default. CI quality gates (such as workflow `10_ci-quality.yml`) and pre-push hooks execute unit, lint, mock, and local integration tests, leaving production unexercised unless an explicit action or workflow is dispatched.

Production has an opt-in way to run any or all of the tests, where the operator picks which tests to run.

Owner words (HUM-10, t1 topic cd592c84-45ab-49a6-927c-0864718e53b9):

- 03:20Z msg 4dfc19b5-0118-4c7e-86b2-a04b26c995a1: "And regardless of the fact that these workspaces are test workspaces, we should have the capability to run all of the tests also in production."
- 03:21Z msg 05d5d1b6-3682-475b-88c5-cc37f37f0321: "They should not be run all of the time in production, but there should be a capability, if desired, to run all of the tests to pick what tests to run in production. Write down somewhere in some DevOps guide or somewhere else."

### Guardrails for production testing
- **Test workspaces only:** Production tests and proofs never target primary, owner, or tenant customer workspaces (`t1`, etc.). On `prd`, any test that writes state, creates sessions, seats members, or posts messages runs strictly inside dedicated test workspaces (default `e2e` or `e2e-*`, configured via `spl_test_workspaces`).
- **Destructive operations forbidden or gated:** Tests that drop tables, alter schemas (DDL), purge tenants, or mutate production data are forbidden on `prd` or protected by explicit confirmation flags (e.g. `PROBE_PRD_GO=1`, `ALLOW_PRD_RESTORE=1`).
- **Rate and load limits:** Active scanning, load tests, or crawler probes must respect strict rate limits (e.g. <= 5 req/s) to prevent degrading user service.
- **Non-blocking post-deploy verification:** Post-deploy probes running in CI on `prd` (such as `invite-e2e-prd` in workflow 20 or `verify` in workflow 22) run non-blocking (`continue-on-error: true`) so transient probe or network issues do not mark an already successful deploy as failed.

## 16.2 Current test suite inventory and production readiness

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
| OWASP ZAP baseline scan | Workflow `.github/workflows/68_dast.yml:65` | `.github/workflows/68_dast.yml:13` ("Owner-go (topic 875651f8): ZAP against the dev WUI host only, <=5 req/s, never prd.") | no | **Gap T2**: Workflow 68 is pinned to dev target only (`https://dev.$d`). No workflow or CLI action allows running a passive ZAP scan against prd. Follow-up: add opt-in workflow input (`environment: dev \| prd`) with conservative rate caps (<=5 req/s). |
| Database search index probe | `cd csi-spl-orc && ./run -a do_spl_search_index_probe` | `csi-spl-orc/src/bash/run/spl-search-index-probe.func.sh:96` (`[[ "${ENV:-}" != prd ]] \|\| { do_log "FATAL ENV=prd is refused: the probe runs DDL (rolled back) on dev only; prd gets P1 through rdb T002 with the owner's go"; return 1; }`) | no | **Gap T3**: Hardcoded refusal for `ENV=prd` because it creates test indexes via DDL. Follow-up: add a read-only query-plan check (`EXPLAIN`) that verifies index usage on prd without executing DDL. |
| WUI browser E2E test suite | `cd csi-spl-wui && pnpm run test:e2e` | `csi-spl-wui/src/node/test/run-e2e-tests.mjs:16` ("`*.proof.mjs files are never discovered — they drive live sites`") | no | **Gap T4**: Discovers ~95 tests designed for local mock/dev server (`localhost:3000`), excluding live proofs (`*.proof.mjs`). No aggregator or runner executes a selected suite of live proofs against prd. Follow-up: build a live proof runner (e.g. `pnpm test:live:suite` or `do_spl_wui_live_suite`) targeting `BASE_URL=https://<BASE_DOMAIN>` or a test workspace. |
| Live chat WebSocket interop test | `cd csi-spl-wui && pnpm run test:live` | `csi-spl-wui/tests/e2e/live-interop.test.mjs:5` ("`Run (lde hub with the door off): HUB_URL=http://t1.localhost:58080 node --experimental-websocket tests/e2e/live-interop.test.mjs`") | no | **Gap T5**: Requires hub authentication door to be disabled (`door off`). Fails against prd because prd enforces production auth. Follow-up: support passing test workspace credentials/tokens so interop can run against prd. |
| Go API module test suite | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` | `csi-spl-api/src/bash/tests/run-all-tests.sh:2` | no | **Gap T6**: Entire Go test suite is pure unit/local integration using SQLite, local throwaway Postgres, or fake-gcs. There is no CLI or test harness to run API integration tests against a live prd Cloud Run endpoint. Follow-up: provide a live API smoke/integration suite runnable against `api.<BASE_DOMAIN>`. |
| Standby agent benchmark | `cd csi-spl-orc && ./run -a do_spl_standby_bench` | `csi-spl-orc/src/bash/run/spl-standby-bench.func.sh:37` (`[[ "${ENV:-}" == dev ]] \|\| { do_log "FATAL ENV must be dev (the standby bench is dev only), got: '${ENV:-}'"; return 1; }`) | no | **Gap T7**: Hardcoded refusal for `ENV=prd`. Follow-up: allow operator opt-in with strict concurrency caps if benchmarking against prd agents is needed. |
| Test workspace purge | `cd csi-spl-orc && ./run -a do_spl_tenant_test_purge` | `csi-spl-orc/src/bash/run/spl-tenant-test-purge.func.sh:26` (`[[ "${ENV:-}" == dev ]] \|\| { do_log "FATAL removing test workspaces is DEV only (ENV=${ENV:-})"; return 1; }`) | no | **Gap T8**: Hardcoded refusal for `ENV=prd`. Follow-up: allow cleanup of explicitly designated test workspaces (`e2e-*`) on prd under operator confirmation. |

# 17 Gaps

A step with no action, or an action that refuses the from-scratch case. Each one is a candidate lane. None of these was written above as if it already worked.

| id | what is missing | what exists instead |
|---|---|---|
| D1 | no `do_*` wraps `gcloud auth login` for the org admin | the iac README names the command; gcp-000 refuses without a token |
| D2 | no single action applies every step in the legal env order | `do_tf_sweep_steps` with an explicit `STEPS` and `ENVS`, as the sections above |
| D3 | the first `make do-provision` of 030 returns 1 when the service does not exist yet | `do_check_hub_image_regress` describes the live service before it decides; `ALLOW_IMAGE_REGRESS` does not cover a missing service |
| D4 | `make do-import` requires `AWS_PROFILE` | `do_tf_import` exists (`grep -c '^do_tf_import()' csi-spl-iac/src/bash/run/tf-import.func.sh` -> 1) but the make target is not a GCP path, and terraform on the host is forbidden |
| D5 | the relay sender key is not created by terraform | repo `CLAUDE.md`: minted out of band; feature doc section 6.3 |
| D6 | no `do_*` restores a Cloud SQL PITR timestamp | `do_spl_db_restore` restores the logical dump |
| D7 | `make do-provision-and-update-gh-keys` calls `do_github_update_gcp_keys` | `grep -c '^do_github_update_gcp_keys()' csi-spl-iac/src/bash/run/*.func.sh csi-spl-orc/src/bash/run/*.func.sh` -> 0; step 120 is the action that sets the secrets |
| D8 | the owner's approval is spoken for that call; no action records it | every apply section above waits for it |

# 18 Docs this guide replaces

| doc | what happens to it |
|---|---|
| `csi-spl-doc/doc/md/HOWTO-local-cloud-deploy.md` | the two box deploys live here (`do_deploy_hub`, `do_deploy_wui`); that file is a pointer to this guide |
| `csi-spl-iac/README.md` | stays; `readme-bootstrap.tst.sh` pins the bootstrap contract in it |
| spec 007, spec 029, spec 044 | stay; they are the design record, this is the operator path |
| `csi-spl-doc/doc/md/box-state-backup.md` | stays; box state is the installation guide |
| the system guide, the installation guide, the operations guide | the other three guides |

# 19 How a count was taken

The `grep -c` figures in this guide are the count of the function line `^<action>()` in the file named next to it. They were taken on commit `b51567f09`. Those function files are unchanged through `396613b00`. The count for `do_spl_wine_box_budget_tf` is on commit `bfede0918`, in the wine-box section. The form is one action, one file.

```bash
grep -c '^do_gcp_000_bootstrap_gcp_env()' csi-spl-iac/src/bash/run/gcp-000-bootstrap-gcp-env.func.sh
```
