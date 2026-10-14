# csi-spl — the spool

> Generated from qto doc `3ba355de-263f-4b35-bb8d-c718c213b595`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Status as of 2026-09-17. Code: `github.com/csitea/csi-spl`, trunk `master`.

## 1. What the spool is

The spool is the agent-messaging hub of the fleet: the hub API on Cloud Run
and its Postgres, the box CLI, the web UI, and the GCP projects and terraform
steps around them (section 2.1).

It starts clean. Nothing was forked from csi-rel or a sibling project; the files that
were copied are listed one by one in section 2.2.

## 2. Layout

### 2.1 Directories

| dir | holds |
|---|---|
| `csi-spl-api` | Go module (`src/go/spool-hub-api`) for spool box CLI, MCP server, and Cloud Run hub API |
| `csi-spl-wui` | Nuxt 3 SSR + TypeScript web application: Slack-like multi-channel interface (M3) |
| `csi-spl-iac` | `./run` actions, terraform steps, tpl-gen templates, tests |
| `csi-spl-orc` | Local dev orchestration (`lde`), container runner (`con-spl-tf-runner`), test DB, test dispatch |
| `csi-spl-cnf` | `csi-spl/all.env.yaml`, `csi-spl/<env>.env.yaml` (sources); `csi-spl/<env>.env.json`, `csi-spl/<env>/tf/*.tfvars` (generated) |
| `csi-spl-doc` | this document |
| `csi-spl-dat`, `csi-spl-utl` | a README each, saying what would go there |
| `tpl-gen/` | git-ignored sibling clone of `github.com/csitea/tpl-gen` |

### 2.2 Copied files and their sources

Everything not listed here was written for the spool.

| file in csi-spl | copied from | changed |
|---|---|---|
| `csi-spl-iac/src/bash/run/run.sh` | `<sibling>/<sibling>-utl/src/bash/run/run.sh` (v3.8.2) | banner only |
| `csi-spl-iac/src/bash/run/help/print-help.func.sh` | `<sibling>/<sibling>-utl/src/bash/run/help/print-help.func.sh` | banner only |
| `csi-spl-iac/lib/bash/funcs/detect-base-paths.func.sh` | `<sibling>/<sibling>-utl/lib/bash/funcs/` | probe stderr silenced |
| `csi-spl-iac/lib/bash/funcs/load-config.func.sh` | `<sibling>/<sibling>-utl/lib/bash/funcs/` | no `/var` symlink manifest |
| `csi-spl-iac/lib/bash/funcs/{require-bin,verify-symlinks,require-var,parse-metadata,validate-params}.func.sh` | `<sibling>/<sibling>-utl/lib/bash/funcs/` | banner only |
| `csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh` | `<sibling>/<sibling>-iac/lib/bash/funcs/` | none |
| `csi-spl-iac/lib/bash/funcs/gcp-require-live-account.func.sh` | `<sibling>/<sibling>-iac/lib/bash/funcs/` | none |
| `csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh` | `<sibling>/<sibling>-iac/src/bash/run/gcp-001-create-project.func.sh` | rewritten around the same pre-flight + three-way check (section 4.1) |
| `csi-spl-iac/src/bash/tests/gcp-001-dead-credential-no-create.tst.sh` | `<sibling>/<sibling>-iac/src/bash/tests/` | adapted, cases added |

Why `<sibling>-utl`'s run.sh: of the eleven copies across that sibling and csi-rel it
is the newest (v3.8.2, 2026-09-02); `csi-rel-utl`'s has the same body.

Read but deliberately NOT copied: `<sibling>-orc/src/bash/run/gcp-create-project.func.sh`
(older, unguarded, runs an interactive login), `<sibling>-orc/src/bash/run/remove-gcp-project.func.sh`
(the spool has no project-removal need yet), the tf-runner container and the
make/docker plumbing (terraform runs from a tfswitch-installed binary).

### 2.3 tpl-gen: a pinned sibling clone

`tpl-gen/` is a plain clone, ignored by the repo's `.gitignore`, and its
commit is pinned in `csi-spl-iac/cnf/tpl-gen.ref`. `do_tpl_gen` refuses to
render with any other HEAD.

- Not vendored, as a sibling project does: its copy has drifted from upstream
  (on 2026-09-17 `diff -rq` against upstream, excluding `.git`, `.venv` and `__pycache__`, listed 62 differing or one-sided entries), which is the cost vendoring charges.
- Not a submodule: submodules make every clone, worktree and rebase an extra
  step for every agent on the box, for a tool the spool only runs at render time.
- The pin keeps renders reproducible; bump it deliberately by editing the ref.

Set up once:

```bash
git clone git@github.com:csitea/tpl-gen.git tpl-gen
```

```bash
git -C tpl-gen checkout "$(cat csi-spl-iac/cnf/tpl-gen.ref)"
```

```bash
python3 -m venv tpl-gen/src/python/tpl-gen/.venv
```

```bash
tpl-gen/src/python/tpl-gen/.venv/bin/pip install jinja2 pyyaml jq colorama rich pprintjson requests
```

## 3. Environments, projects and the domain

### 3.1 Projects

| env | GCP project | region | tf state bucket |
|---|---|---|---|
| dev | `csi-spl-dev` | `europe-north1` | `csi-spl-dev-tfstate` |
| prd | `csi-spl-prd` | `europe-north1` | `csi-spl-prd-tfstate` |

prd is the live env; dev is for proving changes first.

### 3.2 What is NOT in config

The billing account is an environment variable that fails fast, never
committed: `GCP_BILLING_ACCOUNT_ID`.

The org and the owner account ARE config (a deliberate deviation from the
csi-rel copy): `env.gcp.gcp_org_id` and `env.gcp.gcp_account_owner_email` in
`all.env.yaml`, overridable per env. `GCP_ORG_ID` or `GCP_FOLDER_ID` in the
environment override the org.

Who a call runs as (owner rule 2026-09-19: "once the service account keys are
provisioned, then you should be using only the service accounts per
environment for everything. You should not be using the owner account."):
every shell wrapper that calls gcloud resolves the identity once with
`do_gcp_account` / `do_gcp_pin_account` — `ACCOUNT` > `GCP_ACCOUNT` > the
per-env project SA from its key `~/.gcp/.<org>/key-<org>-<app>-<env>.json`,
activated in a throwaway `CLOUDSDK_CONFIG` > refuse — and passes `--account`
on every call. The owner account is read only by the human bootstrap
gcp-000..004 (`do_gcp_pin_bootstrap_account`) while no key exists yet; the
active gcloud account never. CI sets `GCP_ACCOUNT` to its deploy SA, which
wins.

### 3.3 The domain: change it in ONE place

The spool's domain is `spool-hub.ai`. It is stored once:

- **`csi-spl-cnf/csi-spl/all.env.yaml` → `env.dns.BASE_DOMAIN`** — change the
  domain here and nowhere else, then re-render both envs (section 4.2.1).
- `csi-spl-cnf/csi-spl/<env>.env.yaml` → `env.dns.env_subdomain`: `dev` for
  dev, empty for prd.
- The effective hostname `env.dns.fqdn` is derived at render time
  (`do_spl_merged_cnf`) into `<env>.env.json`: `dev.spool-hub.ai` and the apex
  `spool-hub.ai`. This is the csi-rel convention.

`csi-spl-iac/src/bash/tests/domain-single-source.tst.sh` fails if the domain
appears in any tracked file outside `csi-spl-cnf/` and `csi-spl-doc/`.

Nothing GCP DNS-related exists: no domain verification in GCP, no Cloud DNS
zone we own, no Cloud Run mapping. Those are future steps and need the
owner's go. As read on 2026-09-17 the domain is registered at Gandi
(created that day) with Gandi nameservers. Measured 2026-09-18:
`http://spool-hub.ai/` is Gandi parking (apex A on Gandi webredir). Keep
that apex on Gandi until the owner attaches the hub or WUI.

## 4. How to operate it

All commands run from `csi-spl-iac` as the box user. Every gcloud call carries
`--account` or runs under a throwaway `CLOUDSDK_CONFIG`; nothing is ever
written to the shared `~/.config/gcloud`.

### 4.1 Create a project

`do_gcp_001_create_project` proves `GCP_ACCOUNT` can mint a token, then reads
whether the project exists (exists / reported absent / could not tell) and
only on "reported absent" creates it; then links billing. **It is a dry run
unless `DRY_RUN=0`**: the dry run prints the create and link commands it would
run.

#### 4.1.1 Dry run

```bash
ENV=dev GCP_BILLING_ACCOUNT_ID="$GCP_BILLING_ACCOUNT_ID" ./run -a do_gcp_001_create_project
```

#### 4.1.2 Create and link (needs the owner's go)

```bash
ENV=dev GCP_BILLING_ACCOUNT_ID="$GCP_BILLING_ACCOUNT_ID" DRY_RUN=0 ./run -a do_gcp_001_create_project
```

The account and org come from `env.gcp`; set `GCP_ACCOUNT` / `GCP_ORG_ID` to
override them, or `GCP_FOLDER_ID` for a folder parent.

#### 4.1.3 Identity notes (measured 2026-09-17)

- The human credentials cached on the box were refused by the org's reauth
  policy for non-interactive use; the operator must log in interactively first.
- No service account on the box held `resourcemanager.projects.create` on the
  csi organization.
- The billing account with spend is visible only to the identity of the org
  that owns it; `gcloud billing accounts list --account "$GCP_ACCOUNT"` shows
  which accounts an identity can link.

### 4.2 Render, plan, apply

#### 4.2.1 Render the tfvars (after any yaml change)

```bash
ENV=dev ./run -a do_tpl_gen
```

#### 4.2.2 Plan one step

`TF_BACKEND=local TF_OFFLINE_PLAN=1` plans with no state bucket and no
credential, for resources that do not exist yet. Once 000 is applied, plan
001 and the later steps against the real state with the default `TF_BACKEND=gcs`.

```bash
ENV=dev STEP=001-enable-gcp-services ./run -a do_tf_plan
```

The plan is saved to `bin/csi/spl/<env>/<step>/csi-spl-<env>.tfplan`
(git-ignored). `do_tf_plan` wipes and re-copies the run dir, so it refuses
while the dir holds a `terraform.tfstate*` or a lock file: a local state there
may be the only copy. Plans take the state lock (no `-lock=false`).

#### 4.2.3 Apply a reviewed plan (needs the owner's go)

There is deliberately no apply action: apply is a manual step, and it applies
exactly the saved, reviewed plan. Order 000, 001, then the steps in numeric order, dev before prd, under
the operator's credentials:

```bash
"$HOME/.local/share/csi-spl/bin/terraform-1.9.8" -chdir=bin/csi/spl/dev/001-enable-gcp-services apply csi-spl-dev.tfplan
```

#### 4.2.4 Bootstrap 000, then migrate its state into its own bucket

The state bucket cannot hold its own state before it exists. The first plan
of 000 therefore runs with a local backend, and its state is then migrated to
`gs://csi-spl-<env>-tfstate/terraform/000-gcp-remote-bucket`. Until the
migration the run dir holds the ONLY copy of that state.

Every command below takes absolute paths, so the procedure works from any
directory. `$APP` is the checkout root:

```bash
APP=/opt/csi/csi-spl; ENV=dev; TF="$HOME/.local/share/csi-spl/bin/terraform-1.9.8"; R="$APP/csi-spl-iac/bin/csi/spl/$ENV/000-gcp-remote-bucket"
```

1. Plan the bootstrap, review, apply it (4.2.3):

```bash
cd "$APP/csi-spl-iac" && ENV="$ENV" STEP=000-gcp-remote-bucket TF_BACKEND=local ./run -a do_tf_plan
```

2. Back the local state up outside the repo, and record its checksum — step
   6 compares the migrated state against this copy:

```bash
mkdir -p "$HOME/.local/share/csi-spl/tfstate/$ENV/000-gcp-remote-bucket" && cp -p "$R/terraform.tfstate" "$HOME/.local/share/csi-spl/tfstate/$ENV/000-gcp-remote-bucket/terraform.tfstate.$(date -u +%Y%m%dT%H%M%SZ)" && sha256sum "$R/terraform.tfstate" && jq -r '[.lineage,.serial]|@tsv' "$R/terraform.tfstate"
```

3. Put the gcs backend block in the run dir (drop the local override):

```bash
rm -f "$R/backend_override.tf" && cp "$APP/csi-spl-iac/src/terraform/000-gcp-remote-bucket/01-providers.tf" "$R/"
```

4. Migrate. `-force-copy` answers the "copy existing state to the new
   backend?" prompt with yes: without it the migration blocks on a prompt no
   agent and no CI run can answer, and the credential is passed explicitly
   because the box's gcloud config is shared (section 4 preamble):

```bash
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token --account="$GCP_ACCOUNT")" "$TF" -chdir="$R" init -migrate-state -force-copy -input=false -backend-config="$APP/csi-spl-cnf/csi-spl/$ENV/tf/000-gcp-remote-bucket.backend-config.tfvars"
```

5. Prove the remote state holds the bucket:

```bash
"$TF" -chdir="$R" state list
```

6. Prove it MIGRATED rather than started empty — the lineage in the bucket
   must equal the lineage of the backup from step 2, and the serial must have
   advanced. A fresh state carries a NEW lineage, and its plan proposes
   CREATING a bucket that already exists:

```bash
gcloud storage cat "gs://csi-spl-$ENV-tfstate/terraform/000-gcp-remote-bucket/default.tfstate" --account="$GCP_ACCOUNT" | jq -r '[.lineage,.serial]|@tsv'
```

7. Only then move the local `terraform.tfstate*` out of the run dir — move,
   never delete, and step 2 kept a copy besides. From now on plan 000 with
   the default `TF_BACKEND=gcs`; the next plan must show no changes:

```bash
cd "$APP/csi-spl-iac" && ENV="$ENV" STEP=000-gcp-remote-bucket ./run -a do_tf_plan
```

Repeat with `prd`.
