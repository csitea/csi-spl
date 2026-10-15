# 139: Least privilege for the per-env project service account

Status: **v0.1, draft for the security session of 2026-10-16** (round 1, row
1, "L, start only"). Issue: SPL-1970. Source: t1 #spool-hub-ops topic
`3d0675ba`, poll `0c9aa04c`, owner answer `c5d869f5` (all 8 actions picked).
This spec changes no IAM, no key and no service account; it measures and
proposes. Every change in section 5 is a separate run the owner approves.

Paths: `iac/` = `csi-spl-iac/`, `tf/` = `csi-spl-iac/src/terraform/`.
`<env>` is `dev` or `prd`; the env SA is
`csi-spl-<env>@csi-spl-<env>.iam.gserviceaccount.com` (made by gcp-002,
`roles/owner` from gcp-003, `iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh:34`).

## 1. The problem (row 1)

The env SA holds `roles/owner` in csi-spl-dev and csi-spl-prd. Its key is on
both agent boxes and in the GitHub secrets `GCP_KEY_CSI_SPL_DEV/PRD`
(`git grep -l GCP_KEY_CSI_SPL_ .github/workflows` -> 9 workflows). Every
agent user can read it. One injected agent, or one leaked workflow log, can
do anything to prd: delete the database, grant itself to an outside account,
read every secret.

## 2. What the env SA really did (measured 2026-10-15)

Action: `ENV=<env> SA_USAGE_DAYS=30 ./run -a do_gcp_report_sa_usage`
(`iac/src/bash/run/gcp-report-sa-usage.func.sh`, read-only, test
`iac/src/bash/tests/gcp-report-sa-usage.tst.sh`). It reads, as the env SA in
a private gcloud config:

- `gcloud logging read 'logName:"cloudaudit.googleapis.com" AND protoPayload.authenticationInfo.principalEmail="<env SA>" AND timestamp>="<now-30d>"' --project=csi-spl-<env>`
- `gcloud projects get-iam-policy csi-spl-<env> --format='json(auditConfigs)'`
- `gcloud recommender insights list --insight-type=google.iam.policy.Insight --location=global --project=csi-spl-<env>`

Run at 2026-10-15T09:04Z on tree `c-187-c002-sec-r1-prd-account`:

| | dev | prd |
|---|---:|---:|
| audit entries, 30 days | 21,966 | 45,823 |
| of which admin activity | 21,943 | 45,799 |
| of which data access | 23 | 24 |
| first entry in the window | 2026-09-19T08:26Z | 2026-09-19T08:27Z |
| distinct granted permissions | 78 | 55 |
| DENIED permission checks | 0 | 0 |
| IAM recommender insights | unreadable: API off | unreadable: API off |

The prd set of 55 is a subset of the dev set of 78 (`diff` of the two
lists: 23 lines, all `<` dev-only). The 23 dev-only ones are compute (VM,
network, NEG, firewall: steps 060/061), `dns.managedZones.create`,
`iam.roles.create` and `iap.tunnelInstances.setIamPolicy`.

Entries per caller class (from the user agent; the action never reads IPs):

| caller | dev | prd | services |
|---|---:|---:|---|
| no user agent | 20,540 | 44,489 | cloudsql connect (19,812 / 43,760), iam `actAs` (715 / 716), certificatemanager, firebase |
| gcloud | 1,099 | 1,101 | run `ReplaceService` (684 / 688), artifactregistry `CreateTag` (362 / 363), secretmanager, kms, dns, iamcredentials |
| terraform | 319 | 227 | storage, dns, run, compute, secretmanager, serviceusage, monitoring, iam, kms, certificatemanager, resourcemanager, logging, firebase, artifactregistry, iap |
| go client | 2 | 0 | iamcredentials |
| other | 6 | 6 | servicemanagement, apikeys, mobilesdk-pa (Firebase setup) |

The full per-service method and permission tables are in the two reports
(work notes, section 8).

### 2.1 What this measurement can NOT see

1. **Reads and data writes are not logged.** `auditConfigs` enables
   DATA_READ/DATA_WRITE only for `cloudkms.googleapis.com` in both projects.
   Secret reads (`secretmanager.versions.access`), GCS object reads and
   writes (terraform state, backups, docs, files), `logging.read`, every
   `get`/`list` are absent. The 78/55 are a **lower bound**, mostly the
   mutating calls.
2. **The IAM recommender is off.** `recommender.googleapis.com` is not
   enabled in either project, so the 90-day "exercised permissions" insight,
   which sees reads too, is not available.
3. **The window is 26 days, not 30**: the first entry in both projects is
   2026-09-19 (the projects' re-create). A monthly job (if any) may be
   missing.
4. **Who issues the cloudsql connects is suggested, not proven.** About 1.1
   per minute in prd with no user agent fits the per-minute box crons
   (desk reconcile, unanswered sweep) through the Cloud SQL connector; it is
   not the hub (its runtime SA `csi-spl-hub-<env>`, step 030, is a separate
   principal and is not in this report).

Section 5 step 0 closes 1 and 2 before any role is removed.

## 3. The callers of the env SA today

| # | caller | runs where | measured use | auth today |
|---|---|---|---|---|
| C1 | terraform (tf-runner, `make do-tf-*`) | agent box container | creates/deletes every resource class, sets IAM on project, buckets, secrets, KMS, SAs, WIF pool | env SA key (`do_tf_init`) |
| C2 | deploy workflows 20, 30, 32 | GitHub-hosted | run `ReplaceService` + `actAs` runtime SA, artifactregistry `CreateTag`, firebase hosting, docs bucket objects (unlogged) | env SA key PRIMARY, WIF deploy SA (016/017) fallback |
| C3 | ops workflows 00, 40, 45, 46, 47, 48 | GitHub-hosted | deploy-lag reads, tenant host reconcile (dns, domain mappings, certificate manager), db backup/export/restore-verify, demo wipe, db maint, vendor key grant check (kms `getIamPolicy`) | env SA key |
| C4 | agent box actions | both boxes | cloudsql connect (the bulk), secret fetch, log reads, IAM audit, hub restart, deploy-lag | env SA key on the box |
| C5 | bootstrap gcp-000..004 | human, by hand | creates the project, the SA, its key, its owner binding | owner account, then env SA |

## 4. Proposed identities and roles

The principle: **no key with project-wide write on an agent box or in a
GitHub secret.** Each caller gets its own identity; keyless (WIF or
impersonation) wherever the caller is not a box cron.

| caller | identity | roles (project unless a resource is named) | key |
|---|---|---|---|
| C1 terraform | `csi-spl-<env>-tf` (new) | `run.admin`, `storage.admin`, `dns.admin`, `secretmanager.admin`, `cloudkms.admin`, `cloudsql.admin`, `compute.admin` (dev steps 060/061), `monitoring.editor`, `logging.configWriter`, `certificatemanager.owner`, `artifactregistry.admin`, `firebase.admin`, `iap.admin`, `serviceusage.serviceUsageAdmin`, `iam.serviceAccountAdmin`, `iam.serviceAccountUser`, `iam.workloadIdentityPoolAdmin`, `iam.roleAdmin`, `resourcemanager.projectIamAdmin` | **none**: terraform impersonates it (`GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`) from the owner's own login, only during an apply the owner approved |
| C2 deploy | the existing WIF deploy SAs (017 `csi-spl-deploy-<env>`, 016 `csi-spl-<env>-fb-deploy`) | as 016/017 grant today: artifactregistry writer on the 028 repo, `run.developer` on the 030 service, `actAs` the hub runtime SA, firebase hosting admin; plus `storage.objectAdmin` on the 051 docs bucket for workflow 32 | none (WIF, master only) |
| C3 ops CI | `csi-spl-<env>-ops-ci` (new, WIF, master only) | `cloudsql.client` + `cloudsql.editor` (export, 45), `secretmanager.secretAccessor` on the named DB/app secrets, `storage.objectAdmin` on the 045/046 backup buckets, `dns.admin` on the 025 zone, `run.admin` on domain mappings, `certificatemanager.editor` (40), `cloudkms.viewer` + `iam.securityReviewer` (48), `run.viewer` (00) | none (WIF) |
| C4 box ops | `csi-spl-<env>-box` (new) | `cloudsql.client`, `cloudsql.instanceUser`, `secretmanager.secretAccessor` on the named secrets the box actions read, `run.viewer`, `run.developer` on the 030 service (hub restart), `logging.viewer`, `logging.privateLogViewer`, `iam.securityReviewer` | one key per box, readable by the agent group only (rows 4 and 7 fix the modes) |
| C5 bootstrap | the env SA, renamed in role only: `roles/owner` stays | `roles/owner` | its key **off the agent boxes and out of GitHub**: the owner holds it |

Honest limits of this table:

- `resourcemanager.projectIamAdmin` can grant any role, `owner` included: C1
  is still owner-equivalent. The gain is that it has **no key**: nothing on
  a box or in GitHub can use it outside an approved apply.
- C4 keeps a key on the box. What an injected agent can do drops from
  "anything" to "read the named secrets, connect to the DB as itself, restart
  the hub". The DB connect still reaches all data; narrowing that is the
  database role's job (IAM DB users), out of this spec.
- C3 and C4 role lists include reads the logs cannot show (2.1). They are
  checked by section 5 step 0 before the cut, not assumed.

## 5. Rollout (dev first; prd only after dev is green 7 days)

Each step is a named action with DRY_RUN=1 default, run with the owner's go
for that step. "Dev always equals or leads prd" (fleet rules index 2).

0. **See the reads** (owner go, both envs, one IAM change each): enable
   DATA_READ + DATA_WRITE audit logs for `allServices` for 14 days, and
   enable `recommender.googleapis.com`. Then re-run
   `do_gcp_report_sa_usage` and add every newly seen permission to section 4
   before step 2. Cost: data-access logs are billed above the free
   ingestion; the 14-day volume is to be read from the first day's count.
1. **Create the identities in dev** through a new terraform step
   (`tf/018-iam-least-privilege`): C1, C3, C4 SAs and their bindings; the
   016/017 grants extended for C2. No caller switched yet; nothing breaks.
2. **Switch the callers in dev, one per run**, each followed by its test (6):
   C2 (WIF only: drop the key branch of 20/30/32), C3 (the six ops
   workflows to the ops-ci WIF identity), C4 (box actions to the box key),
   C1 (`do_tf_init` impersonates the tf SA instead of reading the env key).
3. **Watch dev 7 days**: `do_gcp_report_sa_usage` for the env SA must show
   0 entries after the switch, and for each new identity 0 DENIED checks.
4. **Cut dev**: remove the env SA key from the boxes and the
   `GCP_KEY_CSI_SPL_DEV` secret; the owner moves the remaining key off-box.
5. **Repeat 1-4 for prd.**
6. **Close the row**: gcp-003 documents `roles/owner` as bootstrap-only;
   `gcloud-account-pinned.tst.sh` and `do_gcp_pin_account` resolve the
   per-caller identity instead of the env SA.

What breaks at each step, if the role list is short:

| step | breaks | seen as | undo |
|---|---|---|---|
| 2 C2 | hub or WUI deploy | workflow 20/30/32 red on the auth or deploy job | re-add the key branch (one revert), the key is still in the secret until step 4 |
| 2 C3 | backups, db maint, tenant hosts | 45/47/40 red; the deploy-lag watch (00) alerts | point the workflow back to the key secret |
| 2 C4 | desk crons, db queries, hub restart | box cron logs `PERMISSION_DENIED`, desk reconcile stops | `ACCOUNT=<env SA>` per call until fixed |
| 2 C1 | terraform plan/apply | `make do-tf-plan` 403 | add the role to the tf SA (it has no key, so this is cheap) |
| 4 | anything still on the env key | the step 3 report shows the env SA still called | do not cut until step 3 reads 0 |

## 6. The test that proves it

1. **A permission matrix check, read-only**: a new action
   `do_gcp_check_sa_least_privilege` calls `projects.testIamPermissions` (and
   the bucket/secret equivalents) as each identity with a fixed probe list:
   `resourcemanager.projects.setIamPolicy`, `iam.serviceAccountKeys.create`,
   `cloudsql.instances.delete`, `secretmanager.versions.access`,
   `storage.buckets.delete`, `run.services.update`, ... It compares the
   granted subset with the expected matrix (cnf), and fails on any extra.
   **Control**: run it today against the env SA: it must FAIL (owner holds
   every probe). That proves the check can see an over-grant.
2. **Each caller's own job, green after its switch**: workflows 20, 30, 32,
   00, 40, 45, 46, 47, 48 on master; `make do-tf-plan` for every step with
   no diff; the box crons' logs without `PERMISSION_DENIED` for 24 h.
3. **Usage proof**: `do_gcp_report_sa_usage` with `SA_USAGE_TARGET` set to
   each new identity: 0 DENIED, and the env SA: 0 entries after its cut.

## 7. Decisions for the owner

- D1: the 14-day data-access audit window (step 0): cost against
  completeness. Without it, section 4's read roles are inferred from the code,
  not measured.
- D2: where the bootstrap (owner) key lives once it is off the boxes.
- D3: whether C1 impersonation runs from the owner's login only, or also
  from a dedicated apply seat with a short-lived token.

## 8. Prep artifacts

- The read-only action, its report script and its test:
  `iac/src/bash/run/gcp-report-sa-usage.func.sh`,
  `iac/src/bash/scripts/sa-usage-report.py`,
  `iac/src/bash/tests/gcp-report-sa-usage.tst.sh` (27 PASS; the control
  fails when the `--account` pin is removed), on review branch
  `review/sec-r1-prd-account`.
- The two reports and the prep note: work notes,
  `work/security-round/2026-10-16/prep-prd-account.md`.
