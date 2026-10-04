# 072 research 03 — terraform steps and the tf-runner / make path

Spec 072 (rapid deployability), research section 03. Owner topic `6410e374`
(prd t1). Scope: `csi-spl-iac/src/terraform/*`, the `./run` tf actions, the
`csi-spl-orc` make targets and the tf-runner stack: the literal ids, the state
backend, the step order, and what a fresh GCP project needs.

**Evidence rule.** Tree `06e9c2a0` (trunk; latest tag `v8.4.0`), n = 1 unless a
row says otherwise. Read-only: no GCP call, no plan. `make do-tf-plan` was NOT
run, because it needs a project key and a built infra stack, and neither
exists for a stranger (B5, B6). Every claim about a file cites the command
that shows it. Costs are **estimates** from spec 047 §4.2, not invoices.

## 1. Today

### 1.1 The steps (18 dirs, 61 resources)

`ls -d csi-spl-iac/src/terraform/[0-9]*/ | wc -l` -> 18;
`grep -hcE '^resource "' <step>/*.tf` summed -> 61. Every step has
`backend "gcs" {}` (`grep -l 'backend "gcs"'` -> 1 per step, 18 of 18).

| step | resources | project / state bucket | needs first |
|---|---|---|---|
| 000-gcp-remote-bucket | 1 (the tfstate bucket) | `<org>-<app>-<env>` / itself | gcp-000..004 |
| 001-enable-gcp-services | 1 | env | 000 |
| 005-gcp-domain-verification | 1 DNS record | env | **025** (writes into its zone, `05.site-verification.tf:17`) |
| 016-firebase-deploy-iam | 3 | env | 001 |
| 017-github-wif-deploy | 7 | env | 028 |
| 019-firebase-static-site | 7 | env | 025, 005 |
| 020-gcp-relay-bucket | 3 | env | 001; then the relay key minted out of band |
| 025-gcp-dns-zone | 4 | env (prd before dev, for delegation) | 001; NS at the registrar |
| 028-gcp-artifact-registry | 1 | env | 001 |
| 030-cloud-run-hub | 7 (service, SA, secrets IAM) | env | **028 + a pushed image, 040, 050**, the DSN secret seeded |
| 032-gcp-cloud-run-domain-mapping | 2 | env | 030, 025; then a cert wait |
| 040-cloud-sql-postgres | 4 | env | 001 |
| 045-gcs-db-backups | 2 | env | 040 (`data "google_sql_database_instance"`) |
| 046-gcs-offsite-backups | 3 | `<org>-<app>-bkp` / bkp's own bucket | the bkp project |
| 050-gcs-files | 1 | env | 001 |
| 059-gcp-satellite-budget | 1 | `<org>-<app>-all`, prd only | billing.costsManager |
| 060-gcp-vm-satellite | 12 | `<org>-<app>-all`, prd only | 059 |
| 120-github-general-secrets | 1 (`terraform_data` + `gh secret set`) | env | the SA key; a GITHUB_TOKEN |

No step reads another step's state: `grep -l terraform_remote_state` -> 0.
Every edge in "needs first" is implicit, carried by a cnf name. Nothing
checks it.

### 1.2 The path one step takes

1. Human bootstrap, per project: `gcp-000` (calls 001..004: project under an
   org **or** folder, project SA, `roles/owner` for it, APIs). A dry run unless
   `DRY_RUN=0`. ENV is one of `dev`, `prd`, `bkp` or `all`
   (`gcp-000-bootstrap-gcp-env.func.sh:11`), so a full estate is **4 projects**.
2. `make do-setup-app-inf` builds three containers: conf-validator, tpl-gen
   and tf-runner (`docker-compose-tf-infra.yaml`).
3. `make do-generate-config-for-step` validates the yaml, then tpl-gen renders
   `csi-spl-cnf/csi-spl/<env>/tf/<step>.{vars,backend-config}.tfvars`
   (`ls csi-spl-cnf/csi-spl/dev/tf | wc -l` -> 36 = 18 x 2).
4. `make do-tf-plan` -> `docker exec … tf-runner ./run -a do_tf_plan`
   (`tf-tasks.func.mk:10-24`).
5. `make do-provision` -> `do_provision` -> `do_tf_apply`.

### 1.3 Measured without credentials

| check | result | command |
|---|---|---|
| render in sync + `fmt` + `validate` of all 18 steps + control | **PASS, 89 assertions, 54 s** (load ~17, 16 cores) | `TPL_GEN_DIR=<main>/tpl-gen bash csi-spl-iac/src/bash/tests/tf-steps-render-and-validate.tst.sh` |
| same, from a worktree whose git refuses the tree (dubious ownership) | FAIL "no tpl-gen venv" | same, without `TPL_GEN_DIR` |
| tpl-gen reachable anonymously, HEAD = the pin | yes (`89468a10`) | `git ls-remote https://github.com/csitea/tpl-gen.git HEAD`; `cat csi-spl-iac/cnf/tpl-gen.ref` |
| tf-runner image on this box | absent | `docker image ls \| grep -c tf-runner` -> 0 |
| terraform pin | 1.9.8 in cnf | `grep terraform_version csi-spl-cnf/csi-spl/*.env.yaml` |

So a stranger can **validate** every step in under a minute with nothing but
terraform and the tpl-gen clone. They cannot **plan** one: that needs the key
file (B6), and the stack demands a GITHUB_TOKEN (B5).

### 1.4 A fresh env, counted

16 per-env steps (all but 059/060) x 2 envs x (render, plan, apply) = 96 make
calls, plus 059/060 once = **102**. Spec 047 §1.2 counted 15 steps / 90 calls.
Between them sit at least **6 manual out-of-band steps**: domain verify, image
build+push, DSN/secret seeds, relay key, cert wait, LB-absent check
(`csi-spl-doc/specs/044-spool-open-source/contingency.md:176-190`). Running
cost of one env once applied: **~$60-65/month** (estimate, 047 §4.2), 80% of it
the always-on hub CPU of step 030.

## 2. Blockers

1. **The first apply of a fresh project cannot run through the tooling.**
   Step 000's backend is the bucket that 000 creates. Its comment says
   "the FIRST apply runs with TF_BACKEND=local (do_tf_plan writes a local
   backend override)" (`000-gcp-remote-bucket/01-providers.tf:13`), but no
   code reads that variable: `git grep -l TF_BACKEND -- csi-spl-iac csi-spl-orc`
   -> 1 file, that comment. `do_tf_init` wipes the run dir unconditionally
   (`tf-init.func.sh:73`), and `do_tf_plan` deletes it after planning
   (`tf-plan.func.sh:25`), so "refuses to wipe a run dir holding one" is also
   false. The documented procedure (`csi-spl.feature.md` §6.2.4, line 327)
   runs **host** terraform, which breaks the tf-runner-only rule. The
   `bkp` project already solves this with a gcloud action:
   `gcp-bkp-state-bucket-create.func.sh`.
2. **No ordered driver; the default order is wrong.** `do_tf_sweep_steps`
   defaults to `find … | sort` (`tf-sweep-steps.func.sh:44`). Lexical order
   puts 005 before 025, and 030 before 040 and 050. 030 also needs an image
   pushed into 028 (`030 02-variables.tf:42-44,133-135`). The 6 manual steps
   in 1.4 are not hooks in any driver.
3. **What is applied is not what was reviewed, and nothing locks.** The plan
   runs with `-lock=false`, and its `.tfplan` is deleted with the run dir
   (`tf-plan.func.sh:21,25`). Apply re-plans with `-auto-approve -lock=false`
   (`tf-apply.func.sh:21`). The repo rule "one run per env + step at a time"
   is enforced only by people. `do_tf_init` also runs twice per provision
   (`provision.func.sh:44`, `tf-apply.func.sh:10`).
4. **Names and envs are pinned to this estate.** There are 9 name regexes
   `regex("^csi-spl…` in 7 files (`git grep -c 'regex("^csi-spl' -- csi-spl-iac/src/terraform`).
   14 files carry `contains(["dev", "prd"], var.env)`. The project id is
   `${ORG}-${APP}-${ENV}` (`gcp-001-create-project.func.sh:71`), and project
   ids are global, so ours are taken. The region `europe-north1` appears 16
   times in the step sources (`git grep -c europe-north1 -- csi-spl-iac/src/terraform`, summed).
5. **The infra stack costs a stranger more than it needs.** The compose file
   demands `GITHUB_TOKEN:?` 6 times
   (`grep -c 'GITHUB_TOKEN:?' docker-compose-tf-infra.yaml` -> 6), and 4 make
   targets demand it too, though only step 120 uses it. The file has 12
   whole-home mount lines (`~/.ssh`, `~/.config`, `~/.aws`, `~/.gcp`
   into each of the 3 containers). Setup also carries a fixed `sleep 10`
   (`setup-app-inf.func.mk:14`) and a `down --rmi all` on every run.
6. **Only a key file works as an identity.** `do_tf_init` always exports
   `GOOGLE_APPLICATION_CREDENTIALS=~/.gcp/.<org>/key-<project>.json`
   (`tf-init.func.sh:59`), so the provider's ADC and impersonation paths
   (`01-providers.tf`: "identity from the caller") never get a chance. A
   contributor holding `gcloud auth application-default login` cannot even
   plan.
7. **Legacy weight on the hot path.** `tf-init.func.sh` still exports the
   `.env.aws` section (lines 31 and 36) and reads a misspelt `.env.terrafom`
   section (line 34). `tf-apply-local-step-bucket.func.sh` is AWS-era
   (`AWS_PROFILE`, `-remote-bucket`), and `do-import` demands `AWS_PROFILE`
   (`tf-tasks.func.mk:27`).
8. **Distribution hygiene.** Another organisation's bucket name sits in the
   comments and variables of steps 000, 001 and 020: 7 lines in 5 files
   (`git grep -c "$OTHER_ORG_PREFIX" -- csi-spl-iac/src/terraform`, with the
   prefix from spec 044 §2).

## 3. Actions

Ranked by usability and DevEx first, cost second. Each action is one lane.
None of them mutates GCP; the dry runs are the tests.

| # | action | done when (a test can check it) | effort |
|---|---|---|---|
| A1 | **State bootstrap as a named action.** `do_gcp_state_bucket_create` (modelled on `gcp-bkp-state-bucket-create`) creates `<project>-tfstate` with gcloud, a dry run by default. Step 000 then *imports* the bucket (an `import {}` block), and the TF_BACKEND comment and the host-terraform procedure in feature doc §6.2.4 are removed. | a test: the action's DRY_RUN prints exactly one `gcloud storage buckets create … --account`; `git grep -c TF_BACKEND` -> 0 outside a reader; 000 validates with the import block | S, 0.5 d |
| A2 | **One ordered, dependency-checked env driver.** cnf `env.steps_order` lists every step once, in dependency order (1.1). `do_tf_provision_env` walks it through the make targets with named hooks between steps (image push, secret seeds, relay key, domain verify, cert wait). It is a dry run by default, and stops at the gate `do_tf_sweep_steps` already has. | a test: every `src/terraform/[0-9]*` dir appears exactly once in `steps_order`; 025<005, 028<030, 040<030, 050<030, 040<045, 030<032; a DRY_RUN prints 16 plan lines per env and the hooks in place | M, 1.5 d |
| A3 | **Apply the reviewed plan, with a lock.** `do_tf_plan` keeps `<env>.tfplan` (and its sha256) in a run dir it does not wipe; `do_provision` applies that file (`terraform apply <plan>`) and refuses a stale one; `-lock=false` is gone; init runs once. | `grep -c 'lock=false' csi-spl-iac/src/bash/run/tf-{plan,apply}.func.sh` -> 0; a test with a stub terraform: apply receives the plan path, not `-auto-approve` | S-M, 1 d |
| A4 | **Credentials by any standard route.** `do_tf_init` sets `GOOGLE_APPLICATION_CREDENTIALS` only when the key file exists; otherwise it uses `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` (the per-env SA), and refuses with one clear line when both are missing. It never falls back to the owner account (repo rule). | a stub-gcloud test: key present -> key; key absent + impersonation set -> impersonation; neither -> FATAL naming both | S, 0.5 d |
| A5 | **Slim the infra stack.** GITHUB_TOKEN becomes optional (`:-`); only step 120 refuses without it. Mount `~/.gcp/.<org>` read-only, drop the `~/.aws` and `~/.ssh` mounts, drop `sleep 10`. | `grep -c 'GITHUB_TOKEN:?' docker-compose-tf-infra.yaml` -> 0; `grep -cE '~/\.(aws\|ssh)'` -> 0; `GITHUB_TOKEN= make do-setup-app-inf` reaches up | S, 0.5 d |
| A6 | **Unpin the names.** Each name regex derives from `var.org`/`var.app`/`var.env` (`^${org}-${app}-${env}-rel$`) or goes; the env check becomes a format check `^[a-z][a-z0-9]{1,7}$` (owner D1 = yes, spec 072). Same lane as spec 072 **A8**. | `git grep -c 'regex("^csi-spl'` -> 0; the validate test passes on a fixture tfvars set with org `xyz`, app `abc` | S, 0.5-1 d |
| A7 | **"Validate in 1 minute" as the first contact.** `./run -a do_tf_validate_all` wraps the existing test (tpl-gen auto-cloned at the pin into a cache dir, terraform from tfswitch). It goes into the iac README as step 1 of "Deploy your own". | a fresh `HOME`, no key: the action exits 0 and prints 18 validates | XS-S, 0.5 d |
| A8 | **Blank cnf template.** `csi-spl-cnf/csi-spl/_template.env.yaml`, plus `do_cnf_new_env` that asks for the 5 human inputs (org/folder, billing via env, region, domain, SMTP) and renders. Same lane as spec 072 **A7** (`do_spl_cnf_init`). | conf-validator passes on the rendered template; tpl-gen renders 36 tfvars; A7 validates them | M, 1-2 d |
| A9 | **Remove the AWS-era code.** Drop `.env.aws`, fix `.env.terrafom`, remove `tf-apply-local-step-bucket`/`tf-destroy-local-step-bucket` and the `AWS_PROFILE` demand in `do-import`. | `git grep -cE 'terrafom\|AWS_PROFILE' -- csi-spl-iac/src/bash/run csi-spl-orc/src/make` -> 0; suites green | XS, 2 h |
| A10 | **Hygiene: the other org's name out of the steps.** Replace it with "the measured reference relay bucket" in the comments; the measured access model itself stays. | `git grep -c "$OTHER_ORG_PREFIX" -- csi-spl-iac/src/terraform` -> 0; the render test still asserts the model | XS, 1 h |

Order: A1, A3 and A9 in parallel (they touch different files); then A2 (it
uses A3's plan file); A4, A5 and A7 in parallel; A6 and A8 merge into spec 072 A8 and A7.
Total ~7-9 lane-days. A1+A2+A3 alone turn "a fresh env" from 102 hand-run
make calls plus 6 tribal steps into one dry-run-first command per env.

**Cost of the actions themselves:** $0 in GCP (dry runs and stubs only). The
first real proof, a throwaway env applied end to end and destroyed the same
day, is about **$2-3** (one day of the ~$60-65/month env, estimate). It needs
the owner's go (Q4).

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | *Answered* by spec 072 D1 = yes (msg `03bc3dab`, 2026-10-04): any organisation runs its own GCP, so this file does not ask again. Open: should env names be free (A6), or stay a fixed pair that a cnf renames? | **Free**, checked by format: a client's own names (`stg`, `uat`) cost one regex, while a fixed pair costs every client a rename. |
| Q2 | Replace the local-backend bootstrap of step 000 with a gcloud state-bucket action plus an import (A1)? | **Yes.** It is the only step a fresh project cannot pass through the tooling today, and the bkp project already works that way. |
| Q3 | Apply the saved, reviewed plan and turn state locking on (A3)? `-auto-approve -lock=false` goes. | **Yes.** It costs one `terraform apply <plan>` and removes the "one run per env+step" rule that depends on people. |
| Q4 | Once A1-A3 land, a throwaway env (`<org>-<app>-t72`, its own project) applied end to end by the driver, timed, then destroyed? It mutates GCP: a new project and a billing link. | **Yes, after A1-A3**, ~$2-3 (estimate). It is the only way to replace the 047 "2-3 days" estimate with a measured number. |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T10:30:00Z -->
