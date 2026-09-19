# csi-rel shell actions and make targets that call terraform: what csi-spl ported

Lane IAC-TF-CALLERS (a sub-lane of IAC-FLOW-PORT). The owner rule: csi-rel's
shell actions and make targets are copied UNCHANGED, apart from the org/app
names. When one fails in csi-spl, the fix goes in csi-spl's config or setup, not
in the logic. A logic change needs ORC's OK first.

## 1. How the list was measured

Measured on csi-rel tree `e4612828`, n=1:

```bash
command grep -rlE '\bterraform\b' csi-rel-iac/src/{bash,make} csi-rel-iac/run csi-rel-orc/src/{bash,make} csi-rel-orc/run | command grep -vE '/tests?/|\.md$'
```

That returns 55 files. `\bterraform\b` also matches comments and log strings.
So each file below was read, and then checked for a real call with:

```bash
command grep -cE '^[^#]*\bterraform[[:space:]]+(init|plan|apply|import|state|validate|fmt|destroy|output|show)' <file>
```

Two files return 1 on that check: `check-credential-drift` (line 319) and
`alert-relay-drill` (line 591). In both, the match is text inside a
`do_log` or `printf` message, not a command.

The csi-spl steps it was checked against are `ls csi-spl-iac/src/terraform`:
000 001 016 017 019 020 025 028 030-cloud-run-hub 031-gcp-hub-ingress 040 050 120.

## 2. The 55 files

| # | csi-rel file | verdict | reason |
|---|---|---|---|
| 1 | csi-rel-iac/src/bash/run/tf-apply.func.sh | other lane | IAC-FLOW-PORT, ported at 1e1ee73 |
| 2 | csi-rel-iac/src/bash/run/tf-apply-local-step-bucket.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 3 | csi-rel-iac/src/bash/run/tf-apply-target.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 4 | csi-rel-iac/src/bash/run/tf-destroy.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 5 | csi-rel-iac/src/bash/run/tf-destroy-local-step-bucket.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 6 | csi-rel-iac/src/bash/run/tf-destroy-target.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 7 | csi-rel-iac/src/bash/run/tf-import.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 8 | csi-rel-iac/src/bash/run/tf-init.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 9 | csi-rel-iac/src/bash/run/tf-new-step.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 10 | csi-rel-iac/src/bash/run/tf-plan.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 11 | csi-rel-iac/src/bash/run/tf-remove-step.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 12 | csi-rel-iac/src/bash/run/tf-replace-target.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 13 | csi-rel-iac/src/bash/run/tf-state-list.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 14 | csi-rel-iac/src/bash/run/tf-state-pull.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 15 | csi-rel-iac/src/bash/run/tf-state-push.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 16 | csi-rel-iac/src/bash/run/tf-state-remove.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 17 | csi-rel-iac/src/bash/run/tf-state-show.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 18 | csi-rel-iac/src/bash/run/tf-taint-target.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 19 | csi-rel-iac/src/bash/run/tf-untaint-target.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 20 | csi-rel-iac/src/bash/run/provision.func.sh | other lane | IAC-FLOW-PORT, 1e1ee73 |
| 21 | csi-rel-orc/src/bash/run/check-container-dns.func.sh | other lane | IAC-FLOW-PORT |
| 22 | csi-rel-orc/src/make/tf-tasks.func.mk | other lane | IAC-FLOW-PORT. Its `do-tf-030-import-existing-cloud-run` target calls #23 |
| 23 | csi-rel-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh | **ported** | `csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh`. Only names changed (section 3.1) |
| 24 | csi-rel-orc/src/bash/scripts/tf-030-import-existing-cloud-run.sh | **ported** | `csi-spl-orc/src/bash/scripts/tf-030-import-existing-cloud-run.sh`. The address table was re-mapped to csi-spl's 030 (section 3.2) |
| 25 | csi-rel-iac/src/make/generate-config-for-step.func.mk | other lane | IAC-TFVARS-TPLGEN |
| 26 | csi-rel-orc/src/make/generate-config-for-step.func.mk | other lane | IAC-TFVARS-TPLGEN |
| 27 | csi-rel-orc/src/make/setup-tpl-gen.func.mk | other lane | IAC-TFVARS-TPLGEN |
| 28 | csi-rel-orc/src/make/tf-quality.func.mk | not ported | It calls `terraform fmt` and `validate`, but only against `/opt/$ORG/$ORG-$APP/$ORG-$APP-inf/src/tf/…`, a layout that was decommissioned. The path is dead in csi-rel too: `ls -d /opt/csi/csi-rel/csi-rel-inf` returns "No such file or directory". It also needs `lib/bash/funcs/resolve-oap.func.sh`, which csi-spl-orc does not have. Running `terraform fmt -check` / `validate` on `csi-spl-iac/src/terraform` would be a logic change (ORC's call). `tf-steps-render-and-validate.tst.sh` already validates every step |
| 29 | csi-rel-iac/src/make/install-terraform.func.mk | not ported | It does not call terraform. Its only line is `@do_install_terraform()`, and no file in csi-rel defines that function (`command grep -rn do_install_terraform` finds only this caller). The target is broken in csi-rel |
| 30 | csi-rel-orc/src/bash/scripts/tf-029-import-existing-secrets.sh | not ported | csi-spl has no 029 step. The hub's auth secret slots live in 030 (`google_secret_manager_secret.auth`), and #24 imports them |
| 31 | csi-rel-orc/src/bash/scripts/tf-120-import-existing-secrets.sh | not ported | It imports `github_actions_secret.gcp_sa_key[…]`. csi-spl's 120 declares only `terraform_data.gcp_key_secret`, because it publishes with `gh secret set` so the key never enters state. `terraform_data` has nothing live to import. A lost 120 state only means the key is published again, which is the same value |
| 32 | csi-rel-orc/src/bash/scripts/tf-120-import-wif-vars.sh | not ported | It imports `github_actions_variable.wif_*`. csi-spl's 120 declares no `github_actions_variable` |
| 33 | csi-rel-orc/src/bash/run/wait-for-cert.func.sh | not ported (a csi-spl version already exists) | csi-spl already has its own version (GRK-3346 orc-dns-ops), and this port does not overwrite it. See section 4. The csi-rel file only mentions terraform in its description |
| 34 | csi-rel-orc/src/bash/run/firebase-deploy-iam-sync-gh-secrets.func.sh | not ported | Only mentions terraform. It uploads the key that csi-rel's 016 `local_sensitive_file` wrote. csi-spl's 016 mints no key (WIF, see `02-variables.tf:42-44`), so there is nothing to upload |
| 35 | csi-rel-orc/src/bash/run/rotate-db-password.func.sh | not ported | Only mentions terraform (comments about csi-rel's 050-gcp-vm-rdb). Specific to csi-rel's VM Postgres, which csi-spl does not have (csi-spl's 040 is Cloud SQL) |
| 36 | csi-rel-orc/src/bash/run/check-credential-drift.func.sh | not ported | Only mentions terraform (a log string at :319). It checks csi-rel's VM Postgres role against Secret Manager |
| 37 | csi-rel-orc/src/bash/run/alert-relay-drill.func.sh | not ported | Only mentions terraform (a printf at :591). csi-rel business step 066 (alert relay) |
| 38 | csi-rel-orc/src/bash/run/check-monitoring-health.func.sh | not ported | Only mentions terraform (comments). csi-rel business steps 065/066 |
| 39 | csi-rel-orc/src/bash/run/db-enable-pgvector.func.sh | not ported | Only mentions terraform (a path in a comment). csi-rel's 050 VM Postgres |
| 40 | csi-rel-orc/src/bash/run/pg-tune.func.sh | not ported | Only mentions terraform (a comment). csi-rel's 050 VM Postgres |
| 41 | csi-rel-orc/src/bash/run/sync-captcha-site-key.func.sh | not ported | Only mentions terraform (comments). csi-rel business step 032 (captcha) |
| 42 | csi-rel-orc/src/bash/run/morph-full-project.func.sh | not ported | Only mentions terraform (an rsync `--exclude='.terraform'`) |
| 43 | csi-rel-orc/src/bash/run/zip-all-projects.func.sh | not ported | Only mentions terraform (a zip `-x '*/.terraform/*'`) |
| 44 | csi-rel-iac/src/bash/run/zip-all-projects.func.sh | not ported | Only mentions terraform (a zip `-x '*/.terraform/*'`) |
| 45 | csi-rel-orc/src/bash/run/broadcast-dir-from-bas.func.sh | not ported | Only mentions terraform (an example path in a comment) |
| 46 | csi-rel-iac/src/bash/run/broadcast-dir-from-bas.func.sh | not ported | Only mentions terraform (an example path in a comment) |
| 47 | csi-rel-orc/src/bash/run/replicate-dir-to-tgt-proj.func.sh | not ported | Only mentions terraform (an example path in a comment) |
| 48 | csi-rel-iac/src/bash/run/replicate-dir-to-tgt-proj.func.sh | not ported | Only mentions terraform (an example path in a comment) |
| 49 | csi-rel-orc/src/bash/run/replicate-file-to-tgt-proj.func.sh | not ported | Only mentions terraform (an example path in a comment) |
| 50 | csi-rel-iac/src/bash/run/replicate-file-to-tgt-proj.func.sh | not ported | Only mentions terraform (an example path in a comment) |
| 51 | csi-rel-orc/src/bash/scripts/deploy-cloud-run.sh | not ported | Only mentions terraform (comments about step 066). It is csi-rel's gcloud image-advance deploy. csi-spl deploys the hub by terraform on an immutable image tag (030 `lifecycle` comment), which is the IAC-FLOW-PORT / CI lanes |
| 52 | csi-rel-orc/src/bash/scripts/deploy-lag-check.sh | not ported | Only mentions terraform (a comment at :101). csi-spl has its own read-only `do_check_hub_deploy` |
| 53 | csi-rel-orc/src/bash/scripts/monitoring-watchdog-cron.sh | not ported | Only mentions terraform (a comment). csi-rel business step 065 |
| 54 | csi-rel-orc/src/bash/scripts/check-088-repo-setup.sh | not ported | Only mentions terraform (grep strings over csi-rel paths). csi-rel business spec 088 |
| 55 | csi-rel-orc/src/bash/scripts/check-helper-scripts-in-repo.sh | not ported | Only mentions terraform (a find `-prune` of `.terraform`) |

Totals: 22 belong to IAC-FLOW-PORT, 3 to IAC-TFVARS-TPLGEN, 2 are ported here,
and 28 are not ported. Of those 28, 6 call terraform, or were listed as if they
did, but cannot run against csi-spl as they are: #28 to #33. The other 22 only
mention terraform.

## 3. Ported files: every difference that is not a name change

The diff was produced with:

```bash
diff <(sed 's/csi-rel/csi-spl/g' <csi-rel-src>) <csi-spl-dst>
```

### 3.1 `csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh`

The only differences are the step name: `030-gcp-cloud-run` became
`030-cloud-run-hub` on lines 4 and 41. That is a name. Everything else is
unchanged: ENV guard, key path `~/.gcp/.<org>/key-<gcp_project>.json`, the
`tf-030` work-dir guard, `hashicorp/terraform:1.9`, and the two `docker run`s
(init, then the importer). The action also resolves `csi-spl-iac/…` and
`csi-spl-cnf/csi-spl/<env>/tf/…`, which are names.

### 3.2 `csi-spl-orc/src/bash/scripts/tf-030-import-existing-cloud-run.sh`

This file is not unchanged, and the change needs ORC's sign-off. The diff has
195 changed lines. csi-spl's step 030 is not csi-rel's step 030, so the address
table the importer walks has to differ. Importing csi-rel's addresses
(`cloud_run_sa`, `api`, `cloud_run_aiplatform_user`, domain mappings) into
csi-spl's state fails every time, because none of those addresses exist in
`csi-spl-iac/src/terraform/030-cloud-run-hub`.

**Kept exactly:** `tf_get`, `is_empty`, `is_true`, `try_import` (idempotent:
an address already in state is skipped; a failed import prints WARN and the
script continues), `-input=false -lock-timeout=120s -var-file=`, import only,
the summary line, and exit 0.

**Changed, with the reason for each:**

| csi-rel section | csi-spl section | reason |
|---|---|---|
| `cloud_run_sa[0]`, `count` on `cloud_run_service_account` | `google_service_account.hub`, always declared, id from `runtime_sa_account_id` | csi-spl's SA has no `count` and uses a different variable |
| reports-bucket IAM (skipped) | `google_storage_bucket_iam_member.hub_files_object_user`, id `b/<files_bucket_name> roles/storage.objectUser …` | csi-spl binds the 050 files bucket, and its name is in the tfvars |
| `cloud_run_sql_client[0]` | `hub_cloudsql_client` (no count) | resource name and count |
| project-level `cloud_run_secret_accessor[0]` | per-secret `hub_secret_accessor["<sid>"]` for each value of `secret_environment_variables` | csi-spl grants at the secret level, not the project level |
| `cloud_run_aiplatform_user[0]` | removed | csi-spl's 030 declares no Vertex binding |
| `google_cloud_run_v2_service.api` | `google_cloud_run_v2_service.hub` | resource name. The tfvars key is `service_name`, not `cloud_run_service_name` |
| `allow_unauthenticated[0]` | `public_invoker[0]`, gated on `allow_unauthenticated` | resource name and tfvars key |
| domain mappings (primary and additional) | removed | csi-spl's domain is the 031 load balancer, not a Cloud Run domain mapping |
| (none) | `google_secret_manager_secret.auth["<sid>"]` for each `auth_secret_ids` | csi-spl's 030 creates the auth secret slots |
| (none) | `list_items`, `map_values` helpers | parse the one-line list and map tfvars that tpl-gen renders |
| header: history of a csi-rel-specific incident | header: why the table differs | hygiene rule: no csi-rel business history |

The drift guard: `csi-spl-orc/src/bash/tests/tf-030-import-existing-cloud-run.tst.sh`
reads the `resource` blocks of the step. It fails if the importer names an
address the step does not declare, and it fails if the step declares a
resource the importer does not cover (`terraform_data` is excluded). If a
resource is added to 030 later, that test goes red until this table is
updated.

## 4. Existing csi-spl file with the same name: `wait-for-cert.func.sh`

Not overwritten. csi-spl's version is a deliberate rewrite, not a copy with
names changed:

| | csi-rel | csi-spl (GRK-3346) |
|---|---|---|
| waits on | a Cloud Run domain mapping, `CertificateProvisioned == True` | the 031 Certificate Manager wildcard cert, `managed.state == ACTIVE` |
| inputs | `DOMAIN`, `GCP_PROJECT`, `REGION` | `ENV` (from cnf), `DOMAIN`, `GCP_PROJECT`, `GCP_ACCOUNT` (required, passed as `--account` on every call), `CERT_NAME`, `CERT_LOCATION` |
| why | csi-rel's 031 is a domain mapping | csi-spl's 031 is an HTTPS load balancer with Certificate Manager. There is no domain mapping to wait on |

The csi-rel version cannot work in csi-spl, because csi-spl has no domain
mapping. Keeping the csi-spl version needs ORC's confirmation, which has been
asked for.

## 5. Recovery use (destroy and re-apply)

For each env, after `terraform init` has lost or reset the 030 state:

```bash
ENV=dev ./run -a do_tf_030_import_existing_cloud_run
```

Run it from `csi-spl-orc`. It imports up to 13 addresses per env (4 fixed,
7 auth slots, 1 DSN accessor, 1 invoker). It never applies. After it, run a
`do-tf-plan` through the tf-runner.


A NotFound is expected and does not stop the run. On 2026-09-19 (08:26Z, as
reported by the DEPLOY lane, n=1 per env) each env held exactly one secret,
`csi-spl-hub-db-dsn`. The 7 auth slots had never been applied, so those 7
imports fail with NotFound. The importer prints WARN for each one and keeps
going (exit 0, `failed=7`), and the next 030 apply creates them. Case 4 of the
test pins this non-fatal behaviour.
