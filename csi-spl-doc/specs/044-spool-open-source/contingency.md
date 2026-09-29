# Contingency: compromise -> destroy and re-create

**Spec**: `spec.md` §8 · **Tasks**: `tasks.md` §5 (T070..T079, the gaps this runbook names)
**Decided by**: the owner, 2026-09-28: the repo goes public as ONE repo, and *"if somebody manages to hack us -
we destroy the infra and re-create all over"*; *"write this into git-spec as a contingency planning"*.

This is a runbook, not a design. Every action named below was checked on tree `ca60cfc7` with
`git grep -n '^do_<name>()'`; the file and line it printed are in the §9 table. An action that the grep did
NOT find is marked **GAP** and is a task in `tasks.md` §5. Until a GAP task lands, that step is the
out-of-band command the same line names, run by the owner, and it is recorded in the post-mortem (§6.2).

Rules that hold for every step (repo `CLAUDE.md`):

- Nothing mutates GCP, GitHub or DNS without the owner's go **for that call**. Every action here is a dry run
  unless `DRY_RUN=0`.
- Every gcloud call runs as the per-env project SA from its key, never the owner account. During a compromise
  that key is itself suspect: it is used only until §2.2 replaces it, and never again after.
- Terraform only through the tf-runner make targets from `csi-spl-orc`, never on the host, one run per env +
  step at a time.
- **dev first, then prd**, at every numbered step that touches an environment.

## 1. Detect and decide

### 1.1 Signals

| # | signal | how to read it | action |
|---|---|---|---|
| 1.1.1 | a version tag nobody's deploy minted | `git ls-remote --tags origin 'v*'` against the deploy runs of workflows 20 / 30; every legitimate tag is minted by `do_release_version` inside those runs | `do_release_version` mints, nothing audits: **GAP** T070 |
| 1.1.2 | a deploy that is not trunk's | `./run -a do_check_deploy_lag` (the live hub / WUI sha vs `origin/master`); `ENV=<env> ./run -a do_check_hub_deploy` (the image Cloud Run serves vs cnf) | `do_check_deploy_lag`, `do_check_hub_deploy` |
| 1.1.3 | a runner job from a fork or an unknown ref | `gh run list --json headBranch,event` on the ops repo; any `pull_request` event from a fork, or a ref that is not `master` / a known lane branch, on a self-hosted runner | **GAP** T070 |
| 1.1.4 | GCP audit log: IAM, key or secret writes nobody asked for | `ENV=<env> FILTER='logName:"cloudaudit.googleapis.com"' FRESHNESS=1d ./run -a do_gcp_tail_logs`; IAM drift against a baseline: `ENV=<env> ./run -a do_gcp_audit_iam` | `do_gcp_tail_logs`, `do_gcp_audit_iam` |
| 1.1.5 | a GitHub secret-scanning alert | `gh api repos/<owner>/<repo>/secret-scanning/alerts` on the public and the ops repo | **GAP** T070 |
| 1.1.6 | `human_events` anomalies (sign-ins, refusals, errors nobody reported) | `ENV=<env> ./run -a do_spl_db_query` with a query on `human_events` | `do_spl_db_query` |

T070 folds 1.1.1, 1.1.3 and 1.1.5 into one read-only `do_oss_security_signals`, so a detection run is one
named action and not three hand-typed `gh` calls.

### 1.2 Who decides

The owner, and only the owner. An agent that sees a signal posts it as a **blocker** to the owner with the
command and its output; it does not start §2 on its own. The owner's answer is one of:

1. **false alarm** - record why in the topic, stop;
2. **contain only** - §2, then §6 (a leaked secret with no sign that it was used);
3. **destroy and re-create** - §2 through §6 (any sign the estate itself was written to).

## 2. Contain

Order matters: the credentials that can WRITE the estate go first, then the ones that can read data.

### 2.1 GitHub Actions secrets `GCP_KEY_CSI_SPL_DEV` / `GCP_KEY_CSI_SPL_PRD`

They are the per-env project SA keys, published by terraform step `120-github-general-secrets`
(`gh secret set` from the key file; state holds only its sha256). Revoking the GCP key (§2.2) makes the GitHub
copy dead; re-publishing the new key is step 120 again, which re-runs on the changed hash:

```bash
cd csi-spl-orc && ENV=dev STEP=120-github-general-secrets make do-tf-plan
```

Removing the secret outright (so a queued job cannot even try it) has no action: **GAP** T071
(`gh secret delete` wrapped, per env).

### 2.2 The per-env project SA keys (gcp-002)

`do_gcp_002_create_project_service_account` mints ONE key when the SA has none on disk and is idempotent
otherwise; `do_gcp_002_delete_project_service_account` deletes the whole SA. Neither ROTATES: minting a new
key and deleting the old key ids while the SA stays is **GAP** T072. In a full destroy (§3) with a new project
the SA dies with it and gcp-002 mints a fresh one; in *contain only* the gap bites.

### 2.3 The relay SA key

Minted out of band by design (terraform never creates it, `csi-spl-doc/doc/md/csi-spl.feature.md` §6.3).
Rotation is the three gcloud commands of feature doc §6.3.2 (mint new, switch, delete old by id): **GAP** T073.

### 2.4 Cloud SQL passwords

| login | action |
|---|---|
| schema owner (cnf `hub.db_owner_user`) | `ENV=<env> DRY_RUN=0 ROTATE_OWNER=1 ./run -a do_spl_db_owner_split` (new password via the Cloud SQL Admin API, new owner-slot version, older versions disabled) |
| hub runtime (cnf `hub.db_user`) | **GAP** T074: no action rotates the runtime password; a re-created instance (§3) gets a new one from `do_spl_db_bootstrap` + `do_spl_db_owner_split` |

### 2.5 SMTP app password

Revoke it at the mail provider (out of band, the provider has no API we call), write the new one to the owner
file, then `ENV=<env> DRY_RUN=0 ./run -a do_spl_mail_secret_seed` (it probes the relay before storing).

### 2.6 OAuth client secrets and the session key

Regenerate each client secret in its IdP console (out of band), update the owner file, then:

- Google: `ENV=<env> DRY_RUN=0 ./run -a do_spl_auth_secrets_seed`
- every other IdP: `IDP=<idp> ENV=<env> DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed`

The **session key** is minted only into an empty slot and never rotated by that action ("a new key logs
everyone out"). Rotating it on purpose, which is exactly what a compromise wants, is **GAP** T075. The same
holds for the box-wui key (`do_spl_wui_key_seed` mints only into an empty slot; rotation is a separate step,
spec 014 `contracts/wui-dispatch.md` §2.3). A full re-create (§3) empties both slots, so both mint fresh.

### 2.7 Payment keys

Roll them in the payment provider's dashboard (out of band), then
`ENV=<env> DRY_RUN=0 ./run -a do_spl_payment_secret_seed`.

### 2.8 Self-hosted runners

`do_oss_runners_move` moves this box's runners from one repo to another (idle-wait, `config.sh remove`,
re-register). It does not take a runner OFF every repo and out of the org runner group: **GAP** T076
(`do_oss_runners_remove`). Until then the owner removes them in the org's runner settings.

## 3. Destroy and re-create the GCP estate

### 3.1 Before anything is destroyed: take the data OUT of the project

The daily dump bucket (`045-gcs-db-backups`) is **inside the same project**. Destroying step 045, or the
project, destroys every dump with it. So the first act of §3 is an off-project copy:

```bash
ENV=dev ./run -a do_gcp_backup_env
```

`do_gcp_backup_env` (read-only) writes the tf state, the DNS zones, the relay + files buckets, the registry
tags and a `pg_dump` of the hub DB to a 0700 local dir. Its `secrets/` sub-dir holds the **compromised**
values: keep it for the post-mortem, never feed it back. Take `ENV=dev ./run -a do_gcp_audit_iam` too (the
before-picture).

The standing daily copy OUT of the project (T077) is iac step `046-gcs-offsite-backups`: every 045 dump and
every 050 file lands in `gs://csi-spl-bkp-<env>` in the separate project `csi-spl-bkp`, which §3.2 never
destroys; the env SA may only add to it (spec 029 §6.6.2). Before §3.2, top it up and read what it holds:

```bash
ENV=dev DRY_RUN=0 ./run -a do_spl_backup_offsite
```

It is live once the owner has bootstrapped `csi-spl-bkp` (spec 029 §6.6.2, still pending on 2026-09-29);
until then it says "not enabled yet" and the RPO of §4.1 holds only if the `do_gcp_backup_env` copy ran.

### 3.2 Destroy

The dry run (it lists what each step holds):

```bash
STEPS="050-gcs-files 045-gcs-db-backups 040-cloud-sql-postgres 032-gcp-cloud-run-domain-mapping 030-cloud-run-hub 028-gcp-artifact-registry 020-gcp-relay-bucket 019-firebase-static-site 017-github-wif-deploy 016-firebase-deploy-iam 120-github-general-secrets" ENVS=dev ./run -a do_tf_deprovision_steps
```

With the owner's go, the same line with `DRY_RUN=0`. `do_tf_deprovision_steps` goes through
`make do-deprovision` (tf-runner) and stops at the first step whose state list is not empty afterwards. Notes:

1. `040` and `030` carry `deletion_protection: true` in cnf (`all.env.yaml`, `prd.env.yaml`); a destroy run
   sets it false for that run only (owner rule 2026-09-19) and back afterwards.
2. `025-gcp-dns-zone` is **kept**: the provisioning contract's invariant is "never recreate the DNS zone"
   (it changes the name servers at the registrar). Its records are re-written by §3.3. Re-creating the zone
   is justified only if the zone itself was written to (1.1.4), and then the registrar NS handoff (contract
   row 3a) is part of the re-create.
3. `000-gcp-remote-bucket` and `001-enable-gcp-services` are kept unless the project itself is abandoned.
   Abandoning the project (a new project id) is the heavier variant: gcp-000..004 re-run first
   (`do_gcp_000_bootstrap_gcp_env` .. `do_gcp_004_project_apis_enable`), the owner's one-time bootstrap.

### 3.3 Re-create, in step order

The order is `csi-spl-doc/specs/007-spool-hub-api-infra/contracts/provisioning-order.md` (follow it, this
table only maps it onto the 15 step dirs). Per step: render, plan, owner go, provision, read that row's gate.

```bash
cd csi-spl-orc && ENV=dev STEP=<step> make do-generate-config-for-step
```

```bash
cd csi-spl-orc && ENV=dev STEP=<step> make do-tf-plan
```

```bash
cd csi-spl-orc && ENV=dev STEP=<step> make do-provision
```

| # | step (the 15 dirs under `csi-spl-iac/src/terraform/`) | then |
|---|---|---|
| 3.3.1 | `000-gcp-remote-bucket`, `001-enable-gcp-services` | only if destroyed (§3.2 note 3) |
| 3.3.2 | `025-gcp-dns-zone` | re-apply for the records; zone kept |
| 3.3.3 | `005-gcp-domain-verification` | `ENV=<env> ./run -a do_spl_domain_verify` |
| 3.3.4 | `040-cloud-sql-postgres` | new instance, empty secret slots |
| 3.3.5 | `050-gcs-files`, `045-gcs-db-backups` | new, empty buckets |
| 3.3.6 | `028-gcp-artifact-registry` | `ENV=<env> ./run -a do_build_push_hub_image` |
| 3.3.7 | DB logins + schema | `do_spl_db_bootstrap`, then `do_spl_db_owner_split` (new owner + runtime passwords), then §4.2 |
| 3.3.8 | `020-gcp-relay-bucket` | mint the relay key (feature doc §6.3.1; T073) |
| 3.3.9 | `030-cloud-run-hub` | seed every secret slot (the §2.5 .. §2.7 actions, and `do_spl_wui_key_seed`), then `do_check_hub_deploy` |
| 3.3.10 | `120-github-general-secrets` (and `017-github-wif-deploy` if WIF is used) | the new key reaches workflow 20 |
| 3.3.11 | `032-gcp-cloud-run-domain-mapping` | `do_spl_wait_for_mapping_cert`, `do_spl_lb_absent_check` |
| 3.3.12 | `016-firebase-deploy-iam`, `019-firebase-static-site` | the WUI host (§5.4) |

dev completes §3 through §6.1, then prd starts at §3.1.

## 4. Restore the data

### 4.1 RPO: 24 hours (21.6 h measured)

Source: workflow `45_db-backup.yml` runs once a day (`cron: '17 5 * * *'`; its own comment: GitHub's
scheduler is best-effort, "treat this as once a day"), each run exporting one dump with `do_spl_db_backup`
and proving it restores with `do_spl_db_backup_verify` (spec 029 FR-007). So the newest dump is at most ~24 h
old, plus the scheduler's drift. If §3.1 ran, the `pg_dump` it took is newer and is the one to restore: the
RPO is then the time since §3.1. Measured 2026-09-29 03:06Z: the newest prd dump was 77 617 s (21.6 h) old.

### 4.2 Restore

The dump to restore is the newest one in the off-project bucket (`BACKUP_SOURCE=bkp`, the default once 046 is
live), or the §3.1 copy. `do_spl_db_restore` imports it **as the schema owner** into the re-created 040
instance (after `do_spl_db_bootstrap` + `do_spl_db_owner_split` have made the logins, and while the database
holds no table: the action refuses to merge into data), then compares every table against what it restored.
Rehearse into a throwaway first:

```bash
ENV=dev TARGET=database:spool_restore_drill DRY_RUN=0 ./run -a do_spl_db_restore
```

```bash
ENV=dev TARGET=env DRY_RUN=0 ./run -a do_spl_db_restore
```

prd adds `ALLOW_PRD_RESTORE=1` to the second line. The user files, into the new 050 bucket (no-clobber):

```bash
ENV=dev TARGET=env DRY_RUN=0 ./run -a do_spl_files_restore
```

Do not fall back to a bare `gcloud sql import sql`: without `--user=<schema owner>` it dies on the dump's
`ALTER DEFAULT PRIVILEGES FOR ROLE` (measured on dev 2026-09-29, spec 029 §6.6.3). `do_gcp_import_to_cloudsql`
(iac) is a csi-rel port with the wrong cnf keys and it drops the app database first; do not use it.

### 4.3 RTO estimate: ~3-4 hours per environment, unmeasured

No full destroy/re-create has been timed; the 2026-09-19 destroy (spec 007 `adhoc-harvest.md` rows 15-18)
re-created 050 and re-applied 030 only. The estimate is built from the parts that ARE measured or bounded:

| part | figure | source |
|---|---|---|
| domain mapping certificate | ~15-20 min before a new host serves | spec 026 spec.md ("A self-serve tenant stayed dark for ~15-20 minutes") |
| 12 step rows x (render + plan + owner read + provision) | ~10 min each, ~2 h | estimate, not measured |
| DB restore (`do_spl_db_restore`, 8-10 MB dumps) | **51 s** prd -> container, **86 s** dev -> Cloud SQL throwaway DB | measured 2026-09-29, spec 029 §6.6.3 |
| files restore (`do_spl_files_restore`) | **20 s** prd (323 objects, 55 MB), 16 s dev | measured 2026-09-29, spec 029 §6.6.3 |
| desks, DNS, WUI, e2e (§5, §6.1) | ~1 h | estimate, not measured |

So ~3-4 h for dev, the same again for prd: about **a working day** end to end. The data leg is now measured
and is minutes; the re-create leg is still the estimate. T079 is a timed dev drill that replaces it.

## 5. Re-seat the fleet and the hosts

### 5.1 Tenants

A new database holds only what the dump restored. Tenant root keys live off-project on the operator box; a
tenant missing from the dump is re-created per the new-tenant runbook, not invented here.

### 5.2 Re-pin the boxes

Every box key pinned on the OLD hub is re-pinned on the new one:
`DRY_RUN=0 ROOT_KEY_JSON=<tenant root key file> ./run -a do_spl_desk_pin` per box (mode `self`), or
`BOX_PUBKEY=... ROOT_KEY_JSON=...` for someone else's box (mode `admin`). The hub's own box-wui pin:
`do_spl_cloud_pin_box_wui`.

### 5.3 Re-seat the desks

`./run -a do_spl_desk_up_all` seats every agent that is live in a pane on this box (it runs `do_spl_desk_up`
per agent); `do_spl_desk_up_tenants` for the per-tenant desks. `do_spl_desk_check` reads the result.

### 5.4 DNS and the WUI

1. `ENV=<env> ./run -a do_provision_firebase_dns_env` writes every record Firebase Hosting needs; then
   `do_spl_wait_for_firebase_domain`.
2. Tenant hosts: `do_spl_tenant_host_provision` per tenant host.
3. Re-publish the WUI: dispatch workflow `30_wui-build-deploy.yml` for the env (it mints its version with
   `do_release_version`), and the hub through `20_hub-build-deploy.yml`.

## 6. Verify and write it down

### 6.1 Verify

1. `curl https://<api_fqdn>/version` returns the version workflow 20 just minted.
2. `./run -a do_check_deploy_lag` reads current for hub and WUI.
3. `ENV=<env> ./run -a do_spl_probe_wui_host` for the WUI host.
4. `ENV=<env> ./run -a do_spl_m3_e2e` (prd: the test tenant `e2e` only).
5. `ENV=<env> ./run -a do_gcp_audit_iam` shows no UNOWNED binding (the after-picture against §3.1).

### 6.2 Post-mortem

One markdown file in the private ops repo: the signal (§1.1 row), the decision and its time, every command
run with its output, every out-of-band step a GAP forced (and the GAP task it adds weight to), the measured
RPO and RTO against §4.1 / §4.3, and what the attacker could read that re-creating does not undo (§7).

## 7. What re-creating does NOT fix

Re-creating the GCP estate replaces everything it owns. It does not replace what an attacker could READ
outside it. The one irreversible exposure is the **self-hosted runner box**: it holds other organisations'
SSH keys and cloud credentials, and a job that ran there could have copied any of them. No destroy of the
spool estate recalls a copied key; each would have to be rotated at its own organisation.

That is why the runners are hardened **before** the flip to public, not after an incident:

1. the runners sit in an org runner group restricted to named workflows on `master` (spec §7 FR-OS-005,
   task T024, `do_oss_runners_move`);
2. no `pull_request` workflow of the public repo runs on a self-hosted runner;
3. fork pull-request runs need a maintainer's approval (D9).

## 8. Gaps (the T07x tasks)

| task | gap | step |
|---|---|---|
| T070 | `do_oss_security_signals`: tags vs deploy runs, fork / unknown-ref runner jobs, secret-scanning alerts, read-only | 1.1 |
| T071 | revoke the `GCP_KEY_*` GitHub Actions secrets | 2.1 |
| T072 | rotate a per-env project SA key (mint new, delete old ids, SA kept) | 2.2 |
| T073 | mint + rotate the relay SA key as actions (feature doc §6.3) | 2.3, 3.3.8 |
| T074 | rotate the hub runtime DB password | 2.4 |
| T075 | rotate the session key and the box-wui key on purpose | 2.6 |
| T076 | `do_oss_runners_remove`: every runner off every repo and out of the org runner group | 2.8 |
| T077 | a daily copy of the 045 dumps OUT of the project - **code landed** (iac 046, `do_spl_backup_offsite`); live after the owner's `csi-spl-bkp` bootstrap | 3.1, 4.1 |
| ~~T078~~ | ~~`do_spl_db_restore` into a new 040 instance~~ - **done**, plus `do_spl_files_restore` | 4.2 |
| T079 | a timed destroy/re-create drill on dev that measures the RTO | 4.3 |

## 9. The actions, as grepped

Command: `git grep -n '^<name>()'` on tree `ca60cfc7`, one line each (n = 1 grep per name).

| action | defined at |
|---|---|
| `do_check_deploy_lag` | `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh:54` |
| `do_check_hub_deploy` | `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh:27` |
| `do_release_version` | `csi-spl-orc/src/bash/run/release-version.func.sh:22` |
| `do_gcp_tail_logs` | `csi-spl-iac/src/bash/run/gcp-tail-logs.func.sh:22` |
| `do_gcp_audit_iam` | `csi-spl-iac/src/bash/run/gcp-audit-iam.func.sh:23` |
| `do_spl_db_query` | `csi-spl-orc/src/bash/run/spl-db-query.func.sh:21` |
| `do_gcp_002_create_project_service_account` | `csi-spl-iac/src/bash/run/gcp-002-create-project-service-account.func.sh:31` |
| `do_gcp_002_delete_project_service_account` | `csi-spl-iac/src/bash/run/gcp-002-delete-project-service-account.func.sh:4` |
| `do_spl_db_owner_split` | `csi-spl-orc/src/bash/run/spl-db-owner-split.func.sh:47` |
| `do_spl_mail_secret_seed` | `csi-spl-orc/src/bash/run/spl-mail-secret-seed.func.sh:23` |
| `do_spl_auth_secrets_seed` | `csi-spl-orc/src/bash/run/spl-auth-secrets-seed.func.sh:22` |
| `do_spl_auth_idp_secret_seed` | `csi-spl-orc/src/bash/run/spl-auth-idp-secret-seed.func.sh:29` |
| `do_spl_wui_key_seed` | `csi-spl-orc/src/bash/run/spl-wui-key-seed.func.sh:22` |
| `do_spl_payment_secret_seed` | `csi-spl-orc/src/bash/run/spl-payment-secret-seed.func.sh:33` |
| `do_oss_runners_move` | `csi-spl-orc/src/bash/run/oss-runners-move.func.sh:41` |
| `do_gcp_backup_env` | `csi-spl-iac/src/bash/run/gcp-backup-env.func.sh:29` |
| `do_tf_deprovision_steps` | `csi-spl-orc/src/bash/run/tf-deprovision-steps.func.sh:20` |
| `do_provision` (what `make do-provision` execs) | `csi-spl-iac/src/bash/run/provision.func.sh:40` |
| `do_spl_domain_verify` | `csi-spl-orc/src/bash/run/spl-domain-verify.func.sh:27` |
| `do_build_push_hub_image` | `csi-spl-orc/src/bash/run/build-push-hub-image.func.sh:25` |
| `do_spl_db_bootstrap` | `csi-spl-orc/src/bash/run/spl-db-bootstrap.func.sh:32` |
| `do_spl_wait_for_mapping_cert` | `csi-spl-orc/src/bash/run/spl-wait-for-mapping-cert.func.sh:24` |
| `do_spl_lb_absent_check` | `csi-spl-orc/src/bash/run/spl-lb-absent-check.func.sh:18` |
| `do_spl_db_backup` | `csi-spl-orc/src/bash/run/spl-db-backup.func.sh:34` |
| `do_spl_db_backup_verify` | `csi-spl-orc/src/bash/run/spl-db-backup-verify.func.sh:32` |
| `do_spl_db_restore` | `csi-spl-orc/src/bash/run/spl-db-restore.func.sh:46` (tree `8da3cde0`) |
| `do_spl_files_restore` | `csi-spl-orc/src/bash/run/spl-files-restore.func.sh:31` (tree `8da3cde0`) |
| `do_spl_backup_offsite` | `csi-spl-orc/src/bash/run/spl-backup-offsite.func.sh:27` (tree `8da3cde0`) |
| `do_gcp_bkp_state_bucket_create` | `csi-spl-iac/src/bash/run/gcp-bkp-state-bucket-create.func.sh:20` (tree `8da3cde0`) |
| `do_gcp_import_to_cloudsql` (legacy, see §4.2) | `csi-spl-iac/src/bash/run/gcp-import-to-cloudsql.func.sh:9` |
| `do_spl_desk_pin` | `csi-spl-orc/src/bash/run/spl-desk-pin.func.sh:36` |
| `do_spl_cloud_pin_box_wui` | `csi-spl-orc/src/bash/run/spl-cloud-pin-box-wui.func.sh:28` |
| `do_spl_desk_up_all` | `csi-spl-orc/src/bash/run/spl-desk-up-all.func.sh:67` |
| `do_spl_desk_up_tenants` | `csi-spl-orc/src/bash/run/spl-desk-up-tenants.func.sh:26` |
| `do_provision_firebase_dns_env` | `csi-spl-iac/src/bash/run/provision-firebase-dns-env.func.sh:21` |
| `do_spl_wait_for_firebase_domain` | `csi-spl-orc/src/bash/run/spl-wait-for-firebase-domain.func.sh:25` |
| `do_spl_tenant_host_provision` | `csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh:39` |
| `do_spl_probe_wui_host` | `csi-spl-orc/src/bash/run/spl-probe-wui-host.func.sh:19` |
| `do_spl_m3_e2e` | `csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh:87` |

Make targets, `git grep -n '^do-tf-plan:\|^do-provision:\|^do-deprovision:\|^do-generate-config-for-step:' -- csi-spl-orc`:
`csi-spl-orc/src/make/tf-tasks.func.mk:10` (`do-tf-plan`), `:45` (`do-provision`), `:87` (`do-deprovision`);
`csi-spl-orc/src/make/generate-config-for-step.func.mk:12`.

<!-- version: 1.1.0 · updated: 2026-09-29 -->
