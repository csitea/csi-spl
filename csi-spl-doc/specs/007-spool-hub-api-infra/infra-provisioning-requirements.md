# Infra provisioning requirements (owner, 2026-09-19)

**Spec**: `./spec.md` §5, FR-025–FR-033 · **Authority**: owner direction
2026-09-19, to be known for this estate and for the next app fork.

Source lines are the owner's words, quoted verbatim. A CHECK is a
one-line command whose result you actually read; "the command exited 0"
is not a CHECK.

**Context**: in csi-spl (2026-09-19) agents had applied raw terraform on
the owner's user ADC and written a native tf-plan; the owner ordered a
full destroy + re-apply of dev and prd under R1-R7 because IAM was
likely broken.

## R1 Project IaC service-account keys

Deploy and terraform run on the per-project IaC SA key
`$HOME/.gcp/.csi/key-csi-spl-<env>.json` (0600), created by the bash
bootstrap gcp-000..004 (001 project, 002 SA + key, 003 roles/owner, 004
bootstrap APIs) after ONE human `gcloud auth login` as
`<owner-account>`. Relay keys
(`$HOME/.gcp/.csi/key-csi-spl-<env>-rel.json`) are bucket-scoped and
never deploy keys.

**Source**: "use the per project keys in the ~/.gcp/.csi/ for the deployment"

**CHECK**: `stat -c '%a %n' "$HOME/.gcp/.csi/key-csi-spl-dev.json" "$HOME/.gcp/.csi/key-csi-spl-prd.json"` -> `600` on each; `test "$(realpath "$HOME/.gcp/.csi/key-csi-spl-dev.json")" != "$(realpath "$HOME/.gcp/.csi/key-csi-spl-dev-rel.json" 2>/dev/null || echo none)"` -> true (relay key is a different file, never the deploy key).

## R2 GitHub Actions secrets from terraform 120

The same keys reach GitHub Actions only through the terraform step
`120-github-general-secrets` (secret `GCP_KEY_CSI_SPL_<ENV>`), never a
hand-run `gh secret set`. Workflows authenticate with
`credentials_json` from that secret; WIF is kept as the alternative.

**Source**: "in the gh provisioning terraform step, they should be set from there as well"

**CHECK**: `command grep -n 'secret_name = "GCP_KEY_${upper(var.org)}_${upper(var.app)}_${upper(var.env)}"' csi-spl-iac/src/terraform/120-github-general-secrets/03-github-actions-secrets.tf` -> 1; `command grep -L "credentials_json: \${{ secrets\[format('GCP_KEY_CSI_SPL_{0}'" .github/workflows/00_deploy-lag-watch.yml .github/workflows/20_hub-build-deploy.yml .github/workflows/30_wui-build-deploy.yml` -> empty; `command grep -rn 'gh secret set' --include='*.sh' --include='*.yml' .github csi-spl-iac/src/bash` -> empty (the only `gh secret set` is the 120 local-exec).

## R3 Terraform only via the csi-rel tf-runner path

Terraform is never run natively on the host. Only the csi-rel path:
`cd csi-spl-orc && make do-setup-app-inf` (docker tf-runner, tpl-gen,
conf-validator) then
`ENV=<env> STEP=<step> make do-tf-plan | do-provision | do-deprovision`
-> docker exec into tf-runner -> iac `./run -a do_provision` -> tf-init
exports `GOOGLE_APPLICATION_CREDENTIALS` from the R1 key and fails if
it is missing.

**Source**: "use the csi-rel way of calling terraform and also via the terraform local dev setup, not natively"

**CHECK**: `command grep -rn "terraform " csi-spl-iac/src/bash/run` only inside the tf-runner path (the copied `tf-*` / `provision` / `divest` actions, invoked by `docker exec` into `con-csi-spl-tf-runner`); `command grep -rnE '^[[:space:]]*terraform ' csi-spl-orc` -> 0; `command grep -n GOOGLE_APPLICATION_CREDENTIALS csi-spl-iac/src/bash/run/tf-init.func.sh` exports `$HOME/.gcp/.$ORG/key-${GCP_PROJECT}.json` and the path must exist (`test -f` or tf-init fails).

## R4 Canonical actions copied unchanged

csi-rel's gcp-*, tf-*, provision and make actions are canonical and
copied UNCHANGED; when one fails, the fork's config/setup is fixed,
never the script.

A fork keeps those scripts verbatim UNLESS its own CLAUDE.md forbids
what they do (examples: `gcloud config set` on the shared config,
private keys in terraform state). Each such deviation is listed here
with the CLAUDE.md rule it satisfies. Owner choice: keep csi-spl
rules. The ported tf-init stays byte-identical to csi-rel (no extra
key check).

Listed deviations (rule: keep csi-spl rules):
- `gcp-000`..`gcp-004` omit `gcloud config set account` / `gcloud config
  set project`; every gcloud call carries `--account` (or a throwaway
  `CLOUDSDK_CONFIG`). Satisfies CLAUDE.md: never `gcloud config set`
  on the shared config.
- terraform never creates a `google_service_account_key` (the relay SA
  key is minted out of band). Satisfies CLAUDE.md: no key in git, in
  terraform state or in a log.

**Source**: "battle tested for the last 5 years and refined ... they DO work, should you have the proper configs and setup", "Keep csi-spl rules"

**CHECK**: `command grep -n 'do_tf_init' csi-spl-iac/src/bash/run/tf-plan.func.sh csi-spl-iac/src/bash/run/provision.func.sh` -> hits in both; `command grep -n GOOGLE_APPLICATION_CREDENTIALS csi-spl-iac/src/bash/run/tf-init.func.sh` is the export only (no extra `test -f` of that key vs csi-rel); `command grep -n 'gcloud config set' csi-spl-iac/src/bash/run/gcp-00*.func.sh` of live commands -> 0 (the gcp-000 hit is the comment that names the omission); `command grep -rn '^resource "google_service_account_key"' --include='*.tf' csi-spl-iac/src/terraform` -> 0; a red tf-* / gcp-* / provision / make action is diagnosed in `<env>.env.yaml`, the R1 key path, or `make do-setup-app-inf`, never by editing the copied script except the deviations listed above.

## R5 Every terraform variable is in the rendered tfvars

Every terraform variable of every step is set in its rendered
`<env>/tf/<step>.vars.tfvars` (+ `backend-config.tfvars`), rendered
from `*.tfvars.tpl` by tpl-gen (`generate-config-for-step`:
conf-validator then the tpl-gen container) from `<env>.env.yaml` /
`all.env.yaml`; no hand-edited tfvars; a fresh render equals the
committed files.

**Source**: "all of the configuration entries are in the tf-var files ... generated via the *.tpl files and the tpl gen"

**CHECK**: `comm -23 <(grep -rh '^variable "' csi-spl-iac/src/terraform/000-gcp-remote-bucket --include='*.tf' | sed 's/.*"\([^"]*\)".*/\1/' | sort -u) <(awk -F' =' '/^[a-zA-Z_][a-zA-Z0-9_]* *=/{print $1}' csi-spl-cnf/csi-spl/dev/tf/000-gcp-remote-bucket.vars.tfvars | sort -u)` -> empty (repeat per step / env); a fresh tpl-gen render then `git diff -- csi-spl-cnf/csi-spl/<env>/tf/` -> empty.

## R6 Deploy local first, then GitHub; skipped is not green

Deploy order: from local first (dev, then prd), then via the GitHub
pipeline; CI/CD must pass with the deploy job actually running (a
skipped deploy is not green).

**Source**: "deploy first from the local and then via the gh", "make sure the CICD passes"

**CHECK**: `gh run list --workflow 20_hub-build-deploy.yml --branch master --limit 1 --json databaseId,headSha,conclusion` then `gh run view <id> --json jobs --jq '.jobs[] | {name,conclusion}'` — a job whose name contains `deploy` with conclusion `skipped` is not green; local `ENV=dev` then `ENV=prd` `make do-provision` of the changed steps landed first.

## R7 Numeric rebuild with backups; per-step both envs; DNS exception; skip 020+SQL

Re-provisioning: all steps run in numeric order 000 -> last. Each step
runs across both envs, **dev first then prd**, then the next step (not
all-of-dev then all-of-prd). A full rebuild destroys last -> 000 then
re-applies 000 -> last, with backups (Cloud SQL export restored and
row-counted, state pulls, secret values, DNS records, bucket contents,
NS set) taken first. Destroy pairing is the reverse of apply (prd then
dev) except DNS.

The ONE exception is the DNS zone step: applied prd (apex) before
dev (sub-zone) and destroyed dev before prd.

A rebuild destroys and re-applies every step EXCEPT
`020-gcp-relay-bucket` (its SA key lives on every box) and
`040-cloud-sql-postgres` (a deleted instance name can be held up to a
week); those two are re-imported into terraform state under the new
key instead. Owner choice: everything except 020 + SQL.

**Source**: "destroy first all of the objects and then re-apply with the new auth", "re-run all of the terraform steps from the beginning till the end", "apply at the same time to both of the environments in all of the steps, but always dev first and then prd ... except for the dns STEP, which requires the order to be otherwise", "Everything except 020 + SQL"

**CHECK**: `ls -1d csi-spl-iac/src/terraform/[0-9]* | sort` is the step order; for each step except DNS, apply `ENV=dev` then `ENV=prd` (destroy `prd` then `dev`); `025-gcp-dns-zone` is applied on prd (apex) before any dev DNS apply, and destroyed on dev before prd; a rebuild destroy/apply skips `020-gcp-relay-bucket` and `040-cloud-sql-postgres` (`ls -1d csi-spl-iac/src/terraform/020-gcp-relay-bucket csi-spl-iac/src/terraform/040-cloud-sql-postgres` -> both exist) and `terraform import`s them under the new state key instead; backups exist before the first destroy.


## R8 Owner realm; per-env service accounts only, never the owner account

All GCP objects are created in the owner's designated realm only: the
`csi-spl-<env>` projects (`csi-spl-dev`, `csi-spl-prd`) under the
designated organization and billing account; the bootstrap never creates
a project in another org, and a rebuild destroys objects inside the
projects, never the projects.

Once the service-account keys are provisioned, every action runs as the
per-env project service account and nothing else. Every shell wrapper
that calls gcloud or terraform resolves its identity ONCE:
`ACCOUNT` / `GCP_ACCOUNT` (explicit, e.g. CI's deploy SA) > the per-env
project SA from its key `~/.gcp/.<org>/key-<org>-<app>-<env>.json`
(`client_email`, activated in a throwaway `CLOUDSDK_CONFIG`) > refuse.
It passes `--account` on every gcloud call, never writes the shared
`~/.config/gcloud`, and never falls back to the owner account or to the
active gcloud account. The owner account (`env.gcp.gcp_account_owner_email`
in `<env>.env.yaml`, `<owner-account>` in docs, never a mail address) is
read ONLY by the human bootstrap gcp-000..004, which mints those keys,
and only while no key exists yet. A key that lacks a permission is
reported, never worked around with the owner account.

**Source**: "once the service account keys are provisioned, then you should be using only the service accounts per environment for everything. You should not be using the owner account." "You should be using the service account keys." (owner, 2026-09-19; supersedes the earlier "... from a gcp_account_owner_email variable from the yaml confs"). Earlier, still in force: "make sure all of the objects are created under the <owner-account> gcp realm - aka the csi-spl-dev and csi-spl-prd projects".

**CHECK**: `bash csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh` -> PASS, including its controls: key present -> the SA email; key absent in a non-bootstrap action -> refused, the owner never printed; bootstrap with no key -> the owner; STATIC: only gcp-000..004 reach the owner resolver, and every gcloud-calling file resolves its identity (the count it prints must not be 0). `command grep -rn 'gcloud config set account' csi-spl-iac csi-spl-orc` -> 0.

## R9 Nothing ad hoc: every infra step is a named, reusable action

"Nothing in the infrastructure should be run ad hoc. Whenever it is executable via Terraform or via some Bash script, we create a Bash script and we execute it via Terraform. Nothing should be ad hoc. For anything you provision ad hoc, there should be a shell action wrapper for that with a proper naming convention and the thing should stay in the source code so that next time, when we are using it, we will reuse it."

How to apply: csi-rel naming, `<verb>-<noun>.func.sh` exposing `do_<verb>_<noun>`, invoked via `./run -a do_<verb>_<noun>`; infra actions live in `csi-spl-iac/src/bash/run`; terraform only via the make / tf-runner path; a one-off need becomes a named action plus its test in the same commit, and runs through that action.

**Source**: owner, 2026-09-19 (verbatim above).

**CHECK**: every provisioning step named in this document maps to a `csi-spl-iac/src/bash/run/*.func.sh` action or a terraform step; `command ls csi-spl-iac/src/bash/run/*.func.sh | command wc -l` -> non-zero, and a change that provisions something lands the action and its test in the same commit.

<!-- version: 1.2.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:30:00Z -->
