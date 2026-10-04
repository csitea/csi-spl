# 072 research 09: secrets, keys and IAM

Status: **research, draft**. Author lane: c-162. Tree: `origin/master` @
`474b940a`, 2026-10-04, n = 1 per command. Docs only: nothing was minted,
applied or changed; no key or credential file was opened or listed.
Placeholders: `<org>`, `<app>`, `<env>`, `<project>` = `<org>-<app>-<env>`.

Question: what must a deployer create in keys, secrets and IAM, and how do we
make that safe and one scripted step instead of a page of hand-typed gcloud?

## 1. Today

### 1.1 Identities a P2 (GCP) estate has per env

| identity | made by | holds | key? | check |
|---|---|---|---|---|
| project SA `<project>@<project>` | `do_gcp_002_create_project_service_account` | **`roles/owner`** on the project (+ `billing.costsManager`) | yes, one JSON key at `$HOME/.gcp/.<org>/key-<project>.json`, mode 600 | `grep -n 'role="roles/owner"' csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh` -> 34; gcp-002 lines 2-5, 47 |
| relay SA (git-rel sender) | tf 020 | `storage.objectUser` on the relay bucket only | yes, minted **by hand** (feature doc 6.3.1) | `csi-spl-iac/src/terraform/020-gcp-relay-bucket/04-relay-sa.tf:4-23`; `grep -n 'keys create' csi-spl-doc/doc/md/csi-spl.feature.md` -> 395 |
| hub runtime SA | tf 030 | `cloudsql.client`, `secretmanager.secretAccessor`, `storage.objectUser` | no | `030-cloud-run-hub/03-runtime-sa.tf` lines 15, 24, 34 |
| deploy SA (CI, WIF) | tf 017 | `artifactregistry.writer`, `run.developer`, `iam.serviceAccountUser` | no (WIF) | `017-github-wif-deploy/03-github-wif.tf` lines 34, 45, 53, 59, 100 |
| firebase deploy SA (CI, WIF) | tf 016 | `firebasehosting.admin`, `serviceusage.serviceUsageConsumer`, `run.viewer` | no (WIF) | `016-firebase-deploy-iam/02-variables.tf:48-50` |
| satellite VM SA (our-only, 060) | tf 060 | log and metric writer | no | `060-gcp-vm-satellite/04-sa.tf:4,10` |

The terraform-managed SAs are already narrow and keyless, and keys in
terraform are banned by a gate (`csi-spl-iac/src/bash/tests/no-keys-in-tf.tst.sh`,
spec 007 FR-007). **The two keys that exist are both outside terraform, and
the strongest one is the most widely spread.**

### 1.2 Where the owner-role key travels

1. Minted by gcp-002 to `$HOME/.gcp/.<org>/key-<project>.json`. gcp-002
   lifts `iam.disableServiceAccountKeyCreation` on the project only for the
   create and re-enforces it on every path (gcp-002 lines 18-21), and a test
   checks that order (`csi-spl-iac/src/bash/tests/gcp-002-004-bootstrap.tst.sh:104`).
2. Step 120 copies the same file into a GitHub Actions secret with
   `gh secret set ... <"$KEY_PATH"`
   (`120-github-general-secrets/03-github-actions-secrets.tf:31`), so the
   value never enters terraform state. Good for state; but the key now also
   lives in GitHub.
3. CI uses that key as the **PRIMARY** auth and WIF only as the fallback:
   `20_hub-build-deploy.yml:24` "key -- PRIMARY", `30_wui-build-deploy.yml:19`
   the same. The secret name is literal:
   `grep -c GCP_KEY_CSI_SPL .github/workflows/*.yml` -> 20: 12, 30: 8,
   00: 6, 40: 5, 45: 4 (35 lines in 5 workflows).
4. Every shell action finds the key by rebuilding its path itself:
   `grep -rnE '\.gcp/\.' csi-spl-iac/src/bash/run/*.sh csi-spl-iac/lib/bash/funcs/*.sh csi-spl-orc/src/bash/run/*.sh | wc -l`
   -> 72 lines in 41 files, in at least three forms
   (`.${ORG}/key-${project}`, `.${project%%-*}/key-${project}`,
   `.${org}/key-${org}-${app}-${env}`: `gcp-each-env-sa.func.sh:33`,
   `gcp-account-pin.func.sh:117`, `gcp-compute-lb-list.func.sh:33`).

### 1.3 Secret Manager

| slot group | empty slot made by | version seeded by | per env |
|---|---|---|---|
| hub auth, IdP, mail, payment, wui key, release-note bans | tf 030 (`06-auth-secret-slots.tf:10`, `for_each = toset(var.auth_secret_ids)`) | 6 orc seed actions | `sed -n 26p csi-spl-cnf/csi-spl/prd/tf/030-cloud-run-hub.vars.tfvars \| grep -oE '"[a-z-]+"' \| wc -l` -> 12 slots; 8 mapped as env vars (line 25) |
| db DSN, owner DSN | tf 040 (`03-cloud-sql.tf:98,121`) | `spl-db-bootstrap` | 2 |

Seed actions: `ls csi-spl-orc/src/bash/run | grep -E 'secret-seed|key-seed|bans-seed'`
-> auth-secrets, auth-idp-secret, mail-secret, payment-secret, wui-key,
release-note-bans (6, plus the db bootstrap = 7). Each is its own command
with its own inputs; there is **no action that seeds them all, and none that
says which slots are still empty**. Good already: every seed writes with
`gcloud secrets versions add --data-file`, never a value on the command line
(e.g. `spl-mail-secret-seed.func.sh:87`), and the mail seed proves the SMTP
login before it writes (its header, lines 3-5).

### 1.4 P1 (compose)

No cloud IAM. The secrets are 3 DB passwords plus SMTP, typed by hand:
`.env.example:85-87` `<openssl rand -hex 24>`; the hub refuses default DB
passwords off localhost (072 4.1, W9). Nothing generates them (072 F4).

### 1.5 Cost (list prices as I believe them, unchecked today)

SA keys, WIF pools and IAM bindings: 0. Secret Manager: about USD 0.06 per
active secret version per month after 6 free, and USD 0.03 per 10 000
accesses. 14 slots x 2 envs = 28 versions -> about USD 1.30 / month. Cost
changes no ranking below (072 section 2).

## 2. Blockers

1. **The CI and box identity is `roles/owner`.**
   `gcp-003-configure-proj-sa-permissions.func.sh:34`. A third party's
   security review stops here, and any leaked copy (disk, GitHub) owns the
   project. The tool to replace it exists: `do_gcp_audit_iam` maps every
   binding to the step that owns it (`gcp-audit-iam.func.sh` header).
2. **That owner key is copied into GitHub and used FIRST**, though WIF (016,
   017) is already built: `20_hub-build-deploy.yml:24`,
   `30_wui-build-deploy.yml:19`, `120-github-general-secrets/03-github-actions-secrets.tf:31`.
3. **A fork must edit 5 workflows** because the secret name carries our org
   and app: 35 lines (1.2 item 3). Same shape as 072 G9.
4. **The relay key is hand-typed gcloud with our literal SA and project**:
   `csi-spl.feature.md:395`; the org-policy reset it needs is prose only
   (section 6.3, line 383 ff.), while gcp-002 already automates the same
   lift and re-enforce. Breaks the "nothing ad hoc" rule (repo CLAUDE.md).
5. **gcp-002 needs an org**: `do_require_var GCP_ORG_ID` at line 38, to set
   the key policy. A no-org deployer (072 A10) cannot mint the project key.
   I believe, unchecked, that new GCP orgs enforce
   `iam.disableServiceAccountKeyCreation` by default, so every third party
   also needs `orgpolicy.policyAdmin` for this one step.
6. **Seven seeds, no runner, no empty-slot check** (1.3). A Cloud Run
   revision that maps an empty secret fails at deploy, far from the cause.
7. **72 lines rebuild the key path** (1.2 item 4); a deployer cannot keep
   keys anywhere but `$HOME/.gcp/.<org>/`, and three forms can disagree.
8. **P1 passwords by hand** (`.env.example:85-87`).

## 3. Actions

Effort as in 072 section 6 (XS < 0.5 d, S <= 1 d, M 2-5 d). One lane each;
"ties" names the 072 gap or action it changes.

| # | action | ties | owner | effort | done-criterion (a test can check) |
|---|---|---|---|---|---|
| **K1** | `do_spl_secrets_check ENV=<env>`: read-only; lists every slot from the rendered 030 and 040 tfvars and whether it has an ENABLED version (`gcloud secrets versions list`, never `access`); marks optional slots (IdP, payment) | G4, A9; blocker 6 | iac | XS-S | stubbed-gcloud test: an empty required slot -> exit 1 naming the slot and its seed action; the stub log holds 0 `versions access` calls |
| **K2** | `do_spl_secrets_seed_all ENV=<env>`: runs the 7 seeds in order, **generates** what can be generated (session key, wui key, db passwords), asks only for outside values (SMTP, IdP, payment), skips a slot that already has a version; dry run by default; ends with K1 | G11, A9; blocker 6 | orc | S-M | stubbed test: a second run adds 0 versions; values reach gcloud only via `--data-file`; `versions add` calls in the stub log = the number of empty slots |
| **K3** | **WIF first in CI**: wf 20, 30, 40, 45, 00 authenticate by WIF when `vars.GCP_WIF_PROVIDER_<ENV>` is set and fall back to the key only when it is not; the notice line says which | G12, A11; blocker 2 | CI | S | a branch run logs `auth = WIF`; a workflow lint test asserts the WIF branch comes first in every auth step |
| **K4** | `do_gcp_relay_key_mint` and `do_gcp_relay_key_rotate`: section 6.3 as actions; names from cnf (step 020), the same lift and re-enforce of the key policy as gcp-002 (reuse its function), `umask 077`, path only in the log; rotate deletes the old key only after a git-rel round trip; doc 6.3 then cites the actions | A9; blocker 4 | iac | S | stubbed test in the shape of `gcp-002-004-bootstrap.tst.sh`: order lift / create / re-enforce, re-enforce also after a failed create; `grep -c 'iam.gserviceaccount.com' csi-spl-doc/doc/md/csi-spl.feature.md` -> 0 |
| **K5** | One key resolver `do_gcp_key_path <project>` honouring `GCP_KEY_DIR` (default `$HOME/.gcp/.<org>`); the 41 files call it | G9; blocker 7 | iac | S | `grep -rlE '\.gcp/\.' csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| wc -l` -> 0 outside the resolver; a test with `GCP_KEY_DIR=<tmp>` resolves there |
| **K6** | Secret name not tied to our org: the GitHub secret becomes `GCP_KEY_<ENV>` (or a repo variable names it); step 120 and the workflows agree | G9; blocker 3 | CI + iac | S | `grep -c GCP_KEY_CSI_SPL .github/workflows/*.yml` -> 0 for every file; this repo's runs stay green |
| **K7** | Key policy without an org: with no org or folder set, gcp-002 reads and lifts the project-level policy only and says so | A10; blocker 5 | iac | S | `ENV=<env> DRY_RUN=1 ./run -a do_gcp_002_create_project_service_account` with no org -> a plan, not `FATAL` |
| **K8** | Least privilege for the project SA: replace `roles/owner` in gcp-003 with the role list the 18 steps need, measured by `do_gcp_audit_iam` on dev; owner stays with the human bootstrap only | blocker 1 | iac | M | in the throwaway project of 072 D4 a full sweep plan and apply with the new SA exits 0; `grep -c roles/owner csi-spl-iac/src/bash/run/gcp-003-*.func.sh` -> 0 |
| **K9** | P1: `spool-up` (072 A2) writes `.env` with generated DB passwords, mode 600 | G3, A2; blocker 8 | orc | XS (inside A2) | after A2's run: `grep -cE '<openssl\|<choose-one>' .env` -> 0 and `stat -c %a .env` -> 600 |
| **K10** | A "Secrets and keys" section in `DEPLOY.md` (072 A15): one table, every key and secret: what it is, the action that makes it, where it lives, the rotate command, required or optional | A15 | docs | XS | a doc test: every `do_*` named in the table is a defined action function |

Order by 072 section 2 (time, steps, error clarity): **K1, K2, K3** first
(one command per env for secrets, errors before the deploy, the owner key
out of CI's default path); then K4, K5, K6, K7; K8 last, as it needs the
throwaway project (072 D4).

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | The rule of 2026-09-19 is "use the service account keys" for every shell action. Keep the project key on the box but make CI keyless (K3), so GitHub no longer holds a key? | **yes**: keys stay on the box (the rule holds), WIF becomes CI's default; drop the GitHub key secret per env once a WIF run is green there |
| Q2 | Narrow the project SA from `roles/owner` to the measured role list (K8)? | **yes**, after K3, proven first in the D4 throwaway project; the human bootstrap keeps owner |
| Q3 | Is the git-rel relay (step 020 and its key) part of what a third party deploys? | **no, optional and off by default** (072 A12): the hub service does not reference it (`grep -ci relay csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf` -> 0); K4 still lands, for our estate |
| Q4 | May K2 generate the session key, wui key and DB passwords itself, so a deployer types only SMTP, IdP and payment values? | **yes**: every generated value goes straight to `--data-file`, never to a terminal or a log |
