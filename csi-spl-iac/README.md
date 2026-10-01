# csi-spl-iac

`./run` actions and terraform for the spool. See
`../csi-spl-doc/doc/md/csi-spl.feature.md` sections 5–7.

| path | what |
|---|---|
| `src/bash/run/gcp-001-create-project.func.sh` | create `csi-spl-<env>` + link billing (dry run by default) |
| `src/bash/run/tpl-gen.func.sh` | render `csi-spl-cnf/csi-spl/<env>/tf/*.tfvars` |
| `src/bash/run/tf-*.func.sh`, `provision`, `divest` | the csi-rel terraform wrappers, run inside the tf-runner by `../csi-spl-orc` make targets (see [Usage](#usage)) |
| `src/terraform/000-gcp-remote-bucket` | the tf state bucket (local state) |
| `src/terraform/001-enable-gcp-services` | storage + iam APIs |
| `src/terraform/020-gcp-relay-bucket` | the git-rel relay bucket + sender SA |
| `src/terraform/030-cloud-run-hub` | the spool hub on Cloud Run (HTTPS + WS, min/max instances 1) + its runtime SA |
| `src/terraform/040-cloud-sql-postgres` | the hub's Cloud SQL Postgres + database + the empty DSN secret slot |
| `src/terraform/050-gcs-files` | the hub's `file_id` bucket (private, uniform, PAP enforced) |
| `src/terraform/059-gcp-satellite-budget` | prd only: the satellite's monthly budget alert, filtered to its `box` label (spec 057; applied before 060) |
| `src/terraform/060-gcp-vm-satellite` | prd only: the satellite agent box (spec 057): VM + data disk + logs-only SA + ONE ingress rule, tcp/22 from IAP |
| `src/bash/tests/` | `bash src/bash/tests/run-all-tests.sh` |
| `cnf/tpl-gen.ref` | the tpl-gen commit the renders are made with |

The hub steps are planned and applied like the others (see [Usage](#usage)),
in the order 050, 040, 030, with the owner's go. No step creates a password, a secret version or a key: the hub's DB user
and DSN are made out of band (see `040-cloud-sql-postgres/03-cloud-sql.tf`).
The hub's env-var names are published in `csi-spl-cnf/csi-spl/all.env.yaml`
under `env.hub.env`.

## Bootstrap

This section follows csi-rel-iac's README. Terraform needs a GCP project, a
service account and a state bucket before it can run, so there is a
chicken-and-egg problem. `do_gcp_000_bootstrap_gcp_env` creates the first
three imperatively (idempotent, a dry run unless `DRY_RUN=0`). Everything
after that is terraform, and terraform runs **only** in the tf-runner
container (see [Usage](#usage)), never on the host.

### Facts come from the environment, never from literals

| Variable | Meaning |
|----------|---------|
| `GCP_ORG_ID` | GCP organisation id (numeric), the parent of the projects. |
| `GCP_ACCOUNT` | The org admin user who creates the projects under `GCP_ORG_ID` and links billing. |
| `GCP_BILLING_ACCOUNT_ID` | Billing account id (`XXXXXX-XXXXXX-XXXXXX`). |
| `ENV` | Target environment: `dev` or `prd`. |
| `ORG` / `APP` | Resolved from this module if unset. |

Export them or pass them on the command line. Do not paste real ids, emails
or hostnames into this file.

The service-account key layout is created by bootstrap. Every later
terraform step and every `gcloud` step uses it:

```text
~/.gcp/.<org>/key-<org>-<app>-<env>.json
```

The same path when `ORG`, `APP` and `ENV` are set in the shell:

```text
~/.gcp/.${ORG}/key-${ORG}-${APP}-${ENV}.json
```

Keys are mode `600` and are never committed. `do_tf_init` sets
`GOOGLE_APPLICATION_CREDENTIALS` to that file for every terraform run. The
tf-runner mounts `~/.gcp` at the same place, so the container finds it too.
If the file is missing, `terraform init` refuses and names the file. It does
**not** fall back to the caller's gcloud ADC
(`src/bash/tests/tf-init-project-key.tst.sh`).

### The one human step

`do_gcp_000_bootstrap_gcp_env` cannot run unattended. Creating a project
under `GCP_ORG_ID` and minting the IaC key need the **org admin**
(`GCP_ACCOUNT`) signed in with an interactive `gcloud auth login`, run as
the box user. That is the only step an agent cannot do without a human.

```bash
gcloud auth login "${GCP_ACCOUNT:?GCP_ACCOUNT must be set}"
```

The actions pass `--account="${GCP_ACCOUNT}"` on every gcloud call. They
never run `gcloud config set` and never change the shared gcloud config.

### Run bootstrap once per env

Run it from this module directory, with the variables set in the environment.
Leave out `DRY_RUN=0` first to read the plan:

```bash
ENV=dev DRY_RUN=0 GCP_ORG_ID="${GCP_ORG_ID:?}" GCP_ACCOUNT="${GCP_ACCOUNT:?}" GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

```bash
ENV=prd DRY_RUN=0 GCP_ORG_ID="${GCP_ORG_ID:?}" GCP_ACCOUNT="${GCP_ACCOUNT:?}" GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID:?}" ./run -a do_gcp_000_bootstrap_gcp_env
```

What it does, in order (each sub-step is idempotent):

1. `do_gcp_001_create_project` creates `$ORG-$APP-$ENV` under `GCP_ORG_ID`
   and links `GCP_BILLING_ACCOUNT_ID`. It does nothing when the project
   already exists.
2. `do_gcp_002_create_project_service_account` creates the IaC SA and
   downloads its key to `~/.gcp/.<org>/key-<org>-<app>-<env>.json`.
3. `do_gcp_003_configure_proj_sa_permissions` grants that SA `roles/owner`
   on the project.
4. `do_gcp_004_project_apis_enable` enables the bootstrap APIs terraform
   needs before it can start. Step `001-enable-gcp-services` enables the
   full set.

## Prerequisites

1. `make`, `bash`, `docker` (with compose v2) on the host, and `gcloud` for
   the bootstrap.
2. The docker infra stack (tf-runner, tpl-gen, conf-validator), built and
   started for this git tree from the orc project. `GITHUB_TOKEN` goes into
   the tf-runner: step `120-github-general-secrets` runs `gh secret set`.

```bash
cd ../csi-spl-orc && GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}" make do-setup-app-inf
```

3. The per-env service-account keys at `~/.gcp/.<org>/key-<org>-<app>-<env>.json`.
   `do_gcp_000_bootstrap_gcp_env` creates them after the human login.

## Usage

Every terraform target runs `docker exec` into this tree's tf-runner
(`con-<org>-<org>-<app>-tf-runner`), which then runs this module's
`./run -a do_tf_plan` / `do_provision` / `do_divest` / `do_tf_*`. Run
`make print-help` in `../csi-spl-orc` to list the targets.

```bash
cd ../csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-tf-plan
```

```bash
cd ../csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-provision
```

```bash
cd ../csi-spl-orc && ENV=dev STEP=000-gcp-remote-bucket make do-deprovision
```

The steps are `ls src/terraform`, applied in numeric order, dev first and
then prd. `do_tf_init` copies the step to `bin/<org>/<app>/<env>/<step>`
and wipes that directory first on every run. Every step keeps its state in
the gcs bucket `<org>-<app>-<env>-tfstate`, so a run directory never holds
the only copy of a state.

## Tests

```bash
bash src/bash/tests/run-all-tests.sh
```

`readme-bootstrap.tst.sh` checks that this README still carries the
bootstrap contract: `GCP_ORG_ID`, `GCP_ACCOUNT` and
`GCP_BILLING_ACCOUNT_ID` from the environment, the SA key layout
`~/.gcp/.<org>/key-<org>-<app>-<env>.json`, the human `gcloud auth login`,
and no baked-in ids, mailboxes or hostnames.
