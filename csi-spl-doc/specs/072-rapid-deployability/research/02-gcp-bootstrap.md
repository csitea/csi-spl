# 072 research 02: the gcp-000..004 bootstrap for an outsider

Contributor: c-167. Brief: spec 072 section 9, sub-brief "02 gcp-bootstrap".
Tree: `origin/master` @ `474b940a8` (the bootstrap files and the cnf are
unchanged since `06e9c2a09`: `git diff --stat 06e9c2a09 474b940a8 -- csi-spl-iac csi-spl-cnf`
-> empty). Read-only: no GCP call was made, no key was read, `DRY_RUN=0` was
never run. Builds on 047 G1 and G3 and on spec 072 A8, A9 and A10, and does
not repeat them.

The question: an **outsider** has their own GCP org (or only a folder, or no
org at all), their own billing account and their own admin login. What in
gcp-000..004 ties them to our estate, which steps only a human with org
rights can do, and how does it become one command?

## 1. Today

### 1.1 How it was measured

The four actions and their helpers were sourced into a shell with `gcloud`
stubbed. The stub answers `NOT_FOUND` to every read, `HOME` points at an
empty scratch dir, so no network call is made and no key is read. Each walk
ran once (n=1). The stub is deterministic, so n=1 shows what the code does.
It does not show what live GCP answers. The four existing suites pass on
this tree:
`for t in gcp-001-dead-credential-no-create gcp-002-004-bootstrap gcp-owner-login-bootstrap-only readme-bootstrap; do bash csi-spl-iac/src/bash/tests/$t.tst.sh; done`
-> 4 x `PASS: all ... assertions`.

| walk | inputs | what the stub run printed |
|---|---|---|
| A | outsider org id, `GCP_ACCOUNT`, billing id | `PROJ_ID=csi-spl-dev`, the key at `$HOME/.gcp/.csi/key-csi-spl-dev.json`. 001 and 002 plan their steps, then **003 stops**: `FATAL ...@csi-spl-dev.iam.gserviceaccount.com does not exist: run do_gcp_002_... first` |
| B | `GCP_FOLDER_ID` only, no `GCP_ACCOUNT` | `bootstrap: no project SA key yet, so the owner account from env.gcp.gcp_account_owner_email mints it`, then `FATAL set exactly one of GCP_ORG_ID and GCP_FOLDER_ID, not both` |
| C | `GCP_FOLDER_ID` + `GCP_ACCOUNT`, gcp-001 alone | `parent=--folder=...`: the folder works when gcp-001 runs alone |
| D | no org in the env or the cnf | `The environment variable "GCP_ORG_ID" does not have a value` |

### 1.2 The flow, step by step

| step | does | identity it needs | Csitea-bound |
|---|---|---|---|
| human | `gcloud auth login "$GCP_ACCOUNT"`, interactive (`csi-spl-iac/README.md:72-78`) | the org admin | no |
| 000 | resolves ORG/APP, **forces `GCP_ORG_ID`** from the env or the cnf, runs 001..004 (`gcp-000-bootstrap-gcp-env.func.sh:21-32`) | - | yes (B3, B4) |
| 001 | creates the project `<org>-<app>-<env>` under the org or folder and links billing (`gcp-001-create-project.func.sh:106-161`) | can create projects on the parent, and use the billing account | yes (B1, B2) |
| 002 | creates the SA `<proj>@<proj>`, lifts `iam.disableServiceAccountKeyCreation` **at the org**, mints a JSON key into `$HOME/.gcp/.<org>/`, then enforces the policy again (`gcp-002-...func.sh:88-177`) | org policy admin, IAM admin | yes (B6) |
| 003 | `roles/owner` for that SA on its project (`gcp-003-...func.sh:232-246`). With `ENV=all` it also grants billing costsManager | project IAM admin | no |
| 004 | enables 4 APIs. The rest comes from tf step 001 (`gcp-004-...func.sh:306`) | serviceusage admin | no |
| after | tf step `000-gcp-remote-bucket` creates the state bucket. It is **not** part of gcp-000 | the SA key | partly (bucket name in cnf) |

What already works for an outsider: every gcloud call carries `--account`,
and nothing writes the shared gcloud config
(`gcp-002-004-bootstrap.tst.sh`: `no config set / auth login / activate / ADC write in any mode (42 calls)`).
Every step can run again safely: it reads first and skips what already exists.
A dead credential stops the run before it reads anything
(`gcp-001-dead-credential-no-create.tst.sh`). The billing id comes from the
environment and is never committed.

### 1.3 Owner-only (human) steps, per env

Today an outsider's human has to do 1 interactive login and hold 5 sets of
rights. The role names below come from the GCP IAM documentation. They were
not measured here, because this box has no outsider account.

| # | right | GCP role (documented minimum) | on | used by |
|---|---|---|---|---|
| H1 | create a project | `roles/resourcemanager.projectCreator` | org or folder | 001 |
| H2 | link billing | `roles/billing.user` | billing account | 001 |
| H3 | grant itself org policy admin | `roles/resourcemanager.organizationAdmin` (to set org IAM) | org | 002:128 |
| H4 | lift and enforce the key policy | `roles/orgpolicy.policyAdmin` | org | 002:119-123 |
| H5 | create the SA and key, grant owner | project owner: the creator gets it on a new project | project | 002, 003 |

Rights H3 and H4 can only be held at the org. That is why an org is
mandatory today (B5). The org admin (H3) is also the widest right in GCP.

### 1.4 Cost and time

The bootstrap costs **$0**: projects, SAs, IAM bindings and enabling APIs
are free. The state bucket that follows costs well under $0.10 a month. The
cost is in the estate that the bootstrap opens the door to: **~$60-65 per
env per month** (047 section 4, an estimate). Wall time is a few minutes per
env. When the key policy has to be lifted, step 002 waits up to 220 s while
the change propagates (`gcp-002-...func.sh:153`, the sleeps 10+30+60+120).

## 2. Blockers

**B1. The project id is fixed by the directory name.** It is
`<org>-<app>-<env>` from the module directory's basename
(`resolve-oap.func.sh:43`; `gcp-spl-proj-id.func.sh:17`;
`gcp-001-create-project.func.sh:106`). A cnf `env.gcp.gcp_project` that
differs is *refused*, not used (`gcp-001...:107-110`,
`gcp-spl-proj-id.func.sh:25-28`). GCP project ids are global, and ours
already exist (047 G1), so a clone that keeps the directory names cannot
bootstrap at all. Walk A: `PROJ_ID=csi-spl-dev`. The key directory follows
the same id (`gcp-account-pin.func.sh:117`: `.${project%%-*}`).

**B2. A project that someone else owns reads as "absent".** The three-way
existence check treats `it may not exist` as NOT_FOUND
(`grep -c 'it may not exist' gcp-001-create-project.func.sh` -> 1, line 129).
When the caller lacks access to a project that *does* exist, gcloud answers
"does not have permission to access projects instance [...] (or it may not
exist)" (the wording is gcloud's from memory, not re-measured here). The dry
run then plans a `projects create` that `DRY_RUN=0` cannot do (the id is
taken). The dry run looks green and the real run fails.

**B3. gcp-000 cannot use a folder.** It exports `GCP_ORG_ID` from the cnf
whenever the env does not set it (`gcp-000-...:21-23`). gcp-001 then sees
both the org and the folder and stops (`gcp-001...:85-86`). Walk B fails;
walk C (gcp-001 alone) passes. An outsider who has only a folder in a
corporate org, the most common case for a team trial, cannot use the
one-command path.

**B4. Our estate's values are the defaults.** When the env does not set
them, the org id and the owner login come from our cnf
(`csi-spl-cnf/csi-spl/all.env.yaml:26-27`;
`gcp-account-pin.func.sh:185-192`; `do_gcp_org_id`, line 239). An outsider
who forgets `GCP_ACCOUNT` or `GCP_ORG_ID` aims at **our** org with **our**
login (walk B, line 1). It fails safely at the token check, but with a
confusing message, and the dry-run plan shows our org as the parent.

**B5. A GCP org is mandatory.** `do_require_var GCP_ORG_ID` runs in gcp-000
(line 22) and gcp-002 (line 38). gcp-001 stops on line 92 when neither an
org nor a folder is set. Walk D. A solo developer with a personal account
and no Workspace or Cloud Identity org cannot start (047 G3; spec 072 A10
covers gcp-001 only, but 000 and 002 block too).

**B6. gcp-002 changes the outsider's whole org.** It grants
`user:$GCP_ACCOUNT` `roles/orgpolicy.policyAdmin` **at the org** and never
removes it (`grep -c remove-iam-policy-binding gcp-002-create-project-service-account.func.sh`
-> 0; lines 128-130). It overwrites the **org-level**
`iam.disableServiceAccountKeyCreation` policy with `enforce: false`, then
with `enforce: true` (lines 119-123). Whatever the org had before (inherit
from parent, conditions, a deliberate "not enforced") is replaced, not
restored. While the policy is lifted, every project in the org may mint
keys, for up to 220 s. The `user:` prefix also breaks when `GCP_ACCOUNT` is
a group or an SA. Most org admins will refuse to run this.

**B7. The dry run stops half way.** On a project that does not exist yet,
gcp-003 stops because the SA "does not exist" (`gcp-003-...:223-229`): the
dry run of 002 did not create it. The outsider sees no plan for 003 and
004, and gcp-000 exits non-zero on a dry run (walk A). The only full plan
is the one that mutates.

**B8. The only identity is a long-lived JSON key with owner rights.**
`roles/owner` sits on a key file on disk (`README.md` "SA key layout",
`gcp-003-...:213`). B6 exists only because a key is wanted. Many orgs
forbid keys by policy, and new orgs enforce that constraint by default.
Impersonation (`--impersonate-service-account`, terraform
`impersonate_service_account`) would need no key and no org policy change.

**B9. Only the env names dev, prd, bkp and all are accepted**
(`gcp-spl-proj-id.func.sh:15`, `gcp-001...:79`). This is the bootstrap half
of spec 072 step 4.3 #5.

**B10. Nothing checks the outsider's rights or the project id up front.**
A missing H1..H4, or a taken id, shows up as a gcloud error mid-run. 001 may
already have created the project when 002 fails, which leaves a half-built
estate for the next run to resume (it can, since every step is safe to
re-run, but the user has no way to know that).

## 3. Actions

Effort: XS < 0.5 day, S <= 1 day, M 2-5 days, for one lane. Each one is
proven by a stubbed-gcloud test in the `gcp-002-004-bootstrap.tst.sh` style.
None needs a GCP mutation to prove.

| # | action | changes | effort | done when (a test checks) |
|---|---|---|---|---|
| **G1** | **The project id comes from the cnf.** `do_gcp_spl_proj_id` and gcp-001 read `env.gcp.gcp_project`, with the convention as the fallback, and refuse only a malformed id (`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`). ORG for the key directory comes from the cnf too | 072 A8 (its bootstrap half); B1 | S | a fixture cnf with `gcp_project: acme-spool-dev-7f3a` under a directory named `csi-spl-iac` -> the dry run plans `projects create acme-spool-dev-7f3a` and the key path `.../.acme/key-acme-spool-dev-7f3a.json` |
| **G2** | **gcp-000 honours a folder**: set `GCP_ORG_ID` from the cnf only when `GCP_FOLDER_ID` is empty. The org is still needed by 002, until G5 removes that need | new; B3 | XS | walk B with `GCP_ACCOUNT` set -> 001 plans `--folder=<id>`, no `not both` stop |
| **G3** | **A complete, honest dry run.** gcp-000 tells 003 and 004 that the SA and project are only planned (for example `BOOTSTRAP_PLANNED=1`), so they print their planned calls and do not stop. 001 counts `PERMISSION_DENIED` and `it may not exist` as **taken**, not absent | new; B2, B7 | S | walk A -> 4 lines `OK DRY_RUN for ...`, exit 0; a stub that answers "(or it may not exist)" -> `FATAL project id <id> is taken or not yours; set env.gcp.gcp_project` |
| **G4** | **`do_gcp_bootstrap_preflight`**: read-only. It checks the id is free (G3's three-way), `testIamPermissions` on the parent (`resourcemanager.projects.create`) and on the billing account (`billing.resourceAssociations.create`), and prints where each input came from (env or cnf). 000 runs it first | new; B4, B10 | S | a stub that denies one permission -> a refusal naming the missing role and the scope (`roles/billing.user on billingAccounts/<id>`); a cnf-sourced org prints `org: <id> (from cnf all.env.yaml)` |
| **G5** | **Keyless bootstrap by default** (`BOOTSTRAP_AUTH=impersonate`). 002 creates the SA and grants the human `roles/iam.serviceAccountTokenCreator` on it, with no key and no org policy change. `do_tf_init` and `do_gcp_account` use impersonation when no key file exists. `BOOTSTRAP_AUTH=key` keeps today's path | new; B6, B8, and B5 for 002 | M | in impersonate mode the stub log shows 0 `org-policies` and 0 `keys create` calls, and `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` is set for terraform; the key mode test stays green |
| **G6** | **The key path changes only one project.** When a key *is* wanted, set the policy on `projects/<id>`, not on the org. Read the org's previous policy and restore exactly that. Remove the temporary policyAdmin grant again. Use `user:`, `group:` or `serviceAccount:` according to the account | new; B6 | S | stub log: `set-policy` targets only `projects/<id>`; a `remove-iam-policy-binding` follows every `add`; a `@*.iam.gserviceaccount.com` account is granted as `serviceAccount:` |
| **G7** | **An org is optional end to end**: with no org and no folder, 001 creates a project without a parent, 002 skips the policy step (none to lift), and 000 prints what that loses (no org policy, no folder IAM) | 072 A10 (+ 000 and 002); B5 | S | walk D -> a full 4-step plan, exit 0, and one `INFO no org: ...` line |
| **G8** | **The env names are the ones the cnf declares**: the allowlist comes from the `*.env.yaml` names present in the cnf, plus bkp and all | 072 4.3 #5 (bootstrap half); B9 | XS | a fixture cnf with `stg.env.yaml` -> `ENV=stg` plans `<org>-<app>-stg` |
| **G9** | **One command for every env**: `ENVS="dev prd" ./run -a do_spl_estate_bootstrap` runs G4, then 000 per env, then tf step 000 (the state bucket) per env through the tf-runner. The human logs in once, the rights are checked once, and each stop names the env, the step and the fix | 072 A9 (its first stage) | S | stub run for 2 envs -> the preflight once, 000 twice, the bucket step twice, in that order; a failing env stops the run with `env=<e> step=<s> fix: ...` |

Order: G2 and G3 first (XS/S, no dependencies). Then G1 and G4. Then G5,
which makes G6 the fallback rather than the default. Then G7, G8 and G9.

### 3.1 The top 3

1. **G5, keyless bootstrap (impersonation).** It removes the org policy
   change, the org admin right H3/H4 and the owner key on disk in one
   change. Of everything here it does the most for DevEx and for whether an
   org admin will run it at all.
2. **G3 + G4, a full dry run and a preflight.** The outsider sees all 4
   steps and every missing right before anything changes, and a taken
   project id stops the run instead of showing green.
3. **G1, the project id from the cnf** (the bootstrap half of A8). Without
   it, no outsider gets past step 001.

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | Should the bootstrap be keyless (impersonation, G5) by default for outsiders, with the JSON key as an opt-in? | **Yes, and for our own estate too in a later step.** A key with owner rights on disk is the weakest link, and new orgs forbid keys by default. CI already uses WIF (step 017) |
| Q2 | When a key is still used, may gcp-002 stop changing the **org-level** key policy and the org IAM, and act on the project only (G6)? | **Yes.** Today one bootstrap changes every project in the org for up to 220 s and leaves a permanent org-level grant behind (B6) |
| Q3 | Should a GCP project with no org (a personal account) be supported (G7)? | **Yes**, with the losses printed. It is the cheapest first try for a solo developer, and usability ranks above cost |
| Q4 | When the plain `<org>-<app>-<env>` id is taken, should the bootstrap add a random suffix by itself? | **No.** The id lives in the cnf (G1). The preflight (G4) proposes `<org>-<app>-<env>-<4 hex>` and the user writes it down, so the id stays reproducible |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T07:20:00Z -->
