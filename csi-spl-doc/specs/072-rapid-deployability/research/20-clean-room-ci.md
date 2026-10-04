# 072 research 20: the clean-room CI run (deploy from zero, prove, tear down)

Status: **research v0.1**, for the lead of spec 072 to merge (section 9).
Tree: `origin/master` @ `3e05ce685` (2026-10-04), n = 1 per command unless
stated. Docs only: nothing built, nothing applied, no GCP call made.
`<org>`, `<app>`, `<run>`, `<BASE_DOMAIN>` are placeholders.

The question: **what CI job deploys the whole P2 estate into a throwaway GCP
project, proves it works, empties it again, and so keeps "rapid deploy" true
after every change?**

Owner input (HUM-10, prd t1 `6410e374`, msg `af863518`, verbatim): "Yeah you
can use one throwaway Google project. Let me know if, for example, we would
have to create the CSI SPL-INF (aka infrastructure) project for you to
experiment on." So the design below uses **one** long-lived throwaway project
`<org>-<app>-cr` that every run fills and empties; section 1.4 answers the
inf-project question. It is spec 072 A16 made permanent: A16 measures P2 once by
hand; this job re-measures it on a schedule and turns red when it breaks.

## 1. Today

### 1.1 What CI already proves, measured

| proof | what it covers | time | command -> result |
|---|---|---|---|
| wf 50 oss-standalone | **P1 from zero**: a hosted runner with only Docker builds pg + hub + WUI, a real Chrome signs up and posts in #lobby | **median 173 s**, min 146, max 191 (n=20 successful trunk runs, newest 2026-10-04) | `gh run list --workflow 50_oss-standalone.yml --branch master --status success --limit 20 --json createdAt,updatedAt` |
| wf 20 hub build + deploy | an **existing** estate: build, mint, migrate, roll Cloud Run, verify (dev and prd) | median 469 s, min 318, max 502 (n=20) | same, `20_hub-build-deploy.yml` |
| wf 30 WUI build + deploy | an **existing** Firebase site | median 143.5 s, min 115, max 183 (n=20) | same, `30_wui-build-deploy.yml` |
| wf 40 tenant-host reconcile | **terraform plan + apply on a hosted runner** through the tf infra stack (032, 025), every 15 min, an existing estate | not timed here | `40_tenant-host-reconcile.yml:19-27` (the walk), `:63` `runs-on: ubuntu-latest` |
| terraform render + validate, 18 steps | syntax and wiring only, no GCP | 54 s, 89 assertions (research 03 1.3) | `tf-steps-render-and-validate.tst.sh` |

So P1 is proven from zero on every relevant push, and wf 40 shows the
tf-runner path already runs in CI. **P2 is never proven from zero**: every
P2 run in CI targets an estate that already exists.

| fact | command -> result |
|---|---|
| no workflow creates or deletes a project or destroys a step | `grep -lE 'projects create\|do_gcp_001\|do_tf_destroy\|gcp_project_delete' .github/workflows/*.yml \| wc -l` -> 0 |
| wf 40 authenticates terraform with a **key** secret written to the key path, not WIF | `40_tenant-host-reconcile.yml:30` (`GCP_KEY_CSI_SPL_<ENV>`, published by iac 120), `:109-110` |
| the deploys authenticate keyless, by WIF | `grep -c workload_identity_provider .github/workflows/*.yml \| grep -v ':0'` -> wf 00 (1), 20 (3), 30 (1) |
| the repo is public, so hosted runner minutes are free | spec 044; wf 50 runs only `if: !github.event.repository.private` (`50_oss-standalone.yml:38`) |

### 1.2 The run, step by step, with today's time and its source

Core tier = no custom domain. Research 08 says P2 "cannot" run without one
today, so the core tier needs that research's no-domain action. Times marked
**est.** are not measured; nobody has run P2 from zero (spec 072 G17).

| # | stage | what | time | source |
|---|---|---|---|---|
| 1 | preflight | ids free, rights present, cnf renders | < 1 min | research 02 G4 (read-only) |
| 2 | project | the one throwaway project exists (owner bootstrap, once); gcp-000..004 re-run as an idempotent check | < 1 min **est.** | research 02 1.4 |
| 3 | infra steps | 000 state bucket, 001, 016, 017, 020, 028, 040, 045, 050 | 8-15 min **est.**; Cloud SQL create dominates (I believe, unchecked, 5-10 min) | research 03 1.1 (the step list) |
| 4 | database | `do_spl_db_bootstrap`: owner login, migrate, runtime role | ~1 min **est.**; the migrate of 112 files is **2.1 s** measured | research 07 1.1 (n=2) |
| 5 | hub | push or promote the image, step 030, roll | 3-8 min; wf 20's 469 s median is an upper bound (it builds and rolls 2 envs) | 1.1 above |
| 6 | WUI | generate + Firebase deploy (019 without a custom domain) | ~2.5 min | wf 30 median 143.5 s |
| 7 | smoke | `/v1/health`, `/version` = this sha, wf 50's browser proof against the `run.app` and `web.app` URLs | 1-2 min **est.** | wf 50 runs it inside its 173 s |
| 8 | teardown | destroy the run's steps in reverse order, then a label scrub of what is left | 5-10 min **est.**; a Cloud SQL delete is the slow part | - |
| | **total, core tier** | | **~20-35 min est.**, target **<= 30 min** | |
| 9 | full tier only | DNS zone, domain verify, 032 mapping, certificate wait | **+10-30 min** | research 08 table; 047 "10-25 min" |

### 1.3 Cost per run, in numbers

Resources live ~30 min per core run. List prices for europe-north1, **I
believe, unchecked against today's price sheet**; the sizes are measured.

| item | size (cnf) | price | per 30 min |
|---|---|---|---|
| Cloud Run hub, instance billing | `cpu: "1"`, `memory: 512Mi`, `min_instances: 1` (`all.env.yaml:54-61`) | ~$0.000018 / vCPU-s + ~$0.000002 / GiB-s -> ~$0.068 / h | ~$0.035 |
| Cloud SQL | `tier: db-f1-micro`, 10 GB, ZONAL (`dev.env.yaml:199-201`) | ~$0.0105 / h + ~$0.0023 / h disk | ~$0.007 |
| buckets, secrets, registry, Firebase Hosting | < 200 MB in all | free tier or < $0.01 | < $0.01 |
| GitHub-hosted runner, ~30 min | public repo | $0 (a private repo: ~$0.008 / min -> $0.24) | $0 |
| **per core run** | | | **~$0.05; budget $0.25** (5x margin for minimum billing and a slow teardown) |
| **nightly + every `stable-*`** | ~35 runs / month | | **~$2, cap $9 / month** |
| full tier, weekly | + a DNS zone ($0.20 / month, prorated) and ~30 min more | | ~$0.10 / run |

Research 03 priced a day-long throwaway env at $2-3; a run that deletes
itself after 30 minutes costs **~40x less**. An orphan (teardown failed, nobody
noticed) costs **~$60-65 / month** (047 4.2): the scrub and janitor of CR1
keep the per-run number true. What stays between runs (the identity, the state
bucket, the enabled APIs) costs < $0.10 / month.

### 1.4 One throwaway project: is a separate `<org>-<app>-inf` project needed?

**No, not for this design.** The question is where the CI identity lives
(the WIF provider and the SA the clean-room job runs as) and the state of the
run, since those must survive the teardown.

| option | holds the CI identity | verdict |
|---|---|---|
| **A. one throwaway project `<org>-<app>-cr`, kept, emptied per run** | **inside it**, the way step 017 already puts a WIF pool inside each env project (`017-github-wif-deploy/03-github-wif.tf:65`); the teardown never touches the identity, the state bucket or the APIs | **recommended**: one project, matches the owner's "one throwaway Google project" |
| B. a new project per run, deleted after | outside, so an `inf` project (WIF pool, the CI SA, a folder with `projectCreator`/`projectDeleter`, a budget) is **required** | stronger proof (gcp-000..004 from nothing each night), but 2 projects, folder rights, and a project id reserved 30 days per deleted run; worth it only later, weekly |
| C. inside dev | - | **no**, see below |

**Why dev cannot hold it.** (1) The clean-room teardown deletes Cloud Run
services, Cloud SQL instances and buckets; in dev one scoping bug deletes the
dev hub and its database, which live tenants and agents use. (2) dev's SA has
`roles/owner` on dev (`gcp-003-configure-proj-sa-permissions.func.sh:34`), so
a CI job that may destroy there may destroy everything there. (3) Names
collide: 030's service and 040's instance are named per env, one each. (4)
"From zero" is false in a project that already has the APIs, IAM and state.
(5) Cost and quota of the proof would hide inside dev's numbers.

The tree already keeps non-env projects for one job each: gcp-001 accepts
`bkp` (off-project backups) and `all` (the satellite)
(`gcp-001-create-project.func.sh:44`). The throwaway project is the third of
that kind; the satellite project `all` should not double as it (it runs a
prd-serving VM, research 03 1.1 step 060).

**Owner steps for option A** (after CR2 lands; until then gcp-001 refuses
`ENV=cr`, line 44), from `csi-spl-iac`, with the owner's own login (this is
the one-time bootstrap the repo rule reserves for the owner):

1. `ENV=cr GCP_BILLING_ACCOUNT_ID=<billing id> DRY_RUN=1 ./run -a do_spl_cleanroom_host_bootstrap` and read the plan (project `<org>-<app>-cr`, billing link, APIs, WIF provider bound to this repo, the CI SA, a $10 / month budget).
2. The same command with `DRY_RUN=0`.
3. `ENV=cr DRY_RUN=1 ./run -a do_spl_cleanroom_down` -> "nothing to delete", the control that the identity can read the project.

If the owner prefers option B later, the owner steps add one folder and the
`<org>-<app>-inf` project, and CR2 grows by the folder IAM.

## 2. Blockers

1. **The throwaway project has no bootstrap path.** gcp-001 accepts only
   dev, prd, bkp, all (`gcp-001-create-project.func.sh:44`), and gcp-002 mints
   a JSON key by lifting the org key policy for up to 220 s (research 02 B6).
   A keyless CI identity inside the project (WIF) has no action yet.
2. **The tooling reads a key file.** `csi-spl-iac/src/bash/run/tf-init.func.sh:59`
   exports `GOOGLE_APPLICATION_CREDENTIALS=~/.gcp/.$ORG/key-<project>.json`.
   wf 40 meets it by writing a stored key secret to that path (1.1); the
   throwaway project should hold no key at all (B1's org-policy lift). Research 03 A4 (impersonation) is the keyless route.
3. **Env names are pinned to dev / prd.** `grep -rln 'contains(\["dev", "prd"\]' csi-spl-iac/src/terraform | wc -l`
   -> 14; `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:21` `FATAL ENV must be dev or prd`.
   A clean-room env `cr` is refused by every step and by the db and hub actions.
4. **Resource names are pinned, and two are global.** `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform | wc -l`
   -> 9, among them `040-cloud-sql-postgres/02-variables.tf:37` (`^csi-spl-(dev|prd)-pg$`)
   and `019-firebase-static-site/02-variables.tf:42` (`^csi-spl-(dev|prd)-site$`).
   In one kept project the Firebase site (global id, `prevent_destroy`) is
   created once and kept; the Cloud SQL instance needs a **run-unique name**,
   since a deleted instance name cannot be reused for days (I believe,
   unchecked, up to a week).
5. **No ordered whole-estate driver.** 18 steps with implicit edges, nothing
   checks the order (research 03 1.1, `grep -l terraform_remote_state` -> 0);
   spec 072 A9 and research 03 A2 are not built.
6. **Teardown by terraform would stop.** `prevent_destroy = true` at
   `025-gcp-dns-zone/03-dns-zone.tf:40` and `019-firebase-static-site/03-firebase-site.tf:44`;
   `force_destroy = false` on 7 buckets (`grep -rn 'force_destroy *= *false' csi-spl-iac/src/terraform | wc -l`
   -> 7); `deletion_protection` on 030 (`all.env.yaml:59` true) and 040. These
   guards are right for dev and prd; in the throwaway env the cnf turns the
   variable ones off, the kept resources (state bucket, Firebase site) stay,
   and a label scrub catches whatever a failed destroy leaves.
7. **The project delete action is not CI-shaped.** `gcp-project-delete.func.sh`
   asks for confirmation (line 97, `FORCE` skips it), defaults the id to
   `${ORG}-${APP}-${ENV}` (line 21), and checks nothing about which project it
   deletes. The clean room must never call it: a cron with one wrong variable
   would delete dev or prd. Its teardown deletes resources, never projects.
8. **Two steps reach outside the throwaway project.** Step 120 writes Actions
   secrets into `var.gh_repo` (`120-github-general-secrets/02-variables.tf:35-41`):
   in a clean-room run it would overwrite this repo's real secrets. Step 046
   writes into the separate backup project (research 07 B2). Both must be off.
9. **A deploy mints a release.** wf 20 mints and pushes a `v<X.Y.Z>` tag per
   deploy (repo CLAUDE.md; research 05 1.1 step 6). A clean-room deploy must
   not mint, or each night spends an odometer step (research 05: 159 left).
10. **P2 needs a domain today** (research 08 table): steps 005, 025, 032 and
    019's custom domain assume one. The core tier waits on research 08's
    no-domain action; the full tier waits on a delegated sub-zone.

## 3. Actions

Each is one lane, in the spec 072 section 6 shape. "Needs" names the spec 072
or research ids that land first. Ranked by DevEx: the first two make the job
safe to exist at all, the rest make it run.

| # | action | changes | needs | effort | done when (a test can check) |
|---|---|---|---|---|---|
| **CR1** | **`do_spl_cleanroom_down`, safe by construction.** Works in ONE project and refuses unless both hold: the project id equals cnf `env.gcp.gcp_project` of env `cr` and the project carries the label `spl-cleanroom=true`. It destroys the run's steps in reverse order, then deletes every resource labelled `spl-run=<run>` that is left (Cloud Run, Cloud SQL, buckets but the state bucket, secrets); never the identity, the state bucket or the Firebase site. `JANITOR=1 MAX_AGE_H=3` scrubs runs older than 3 h. It never calls `projects delete`. Dry run by default | B6, B7; new | - | S | a stub-gcloud tst.sh: the `cr` project with the label -> the delete lines, each with `--account`; `grep -c 'projects delete'` on the action -> 0; **controls**: the dev project id, an unlabelled project -> a refusal and 0 delete lines |
| **CR2** | **The throwaway project, one owner bootstrap.** `do_spl_cleanroom_host_bootstrap ENV=cr` (dry run default): gcp-001 learns `cr` (line 44); the project `<org>-<app>-cr` with the label `spl-cleanroom=true`, the billing link, the APIs; inside it a WIF provider bound to this repo on `refs/heads/master` and `refs/tags/stable-*`, and the CI SA with `roles/owner` on **this project only**; a $10 / month budget. No key is minted | B1; repo rule "per-env SA, never the owner account" | - | S | DRY_RUN prints the gcloud lines, each with `--account`; `grep -c 'keys create'` on the action -> 0; no IAM line names the org, a folder, dev or prd |
| **CR3** | **An ephemeral env from the template.** `do_spl_cleanroom_cnf RUN=<run>` renders the run's view of env `cr` into a scratch dir (never committed): the kept project and Firebase site, a run-unique pg instance name, the label `spl-run=<run>` on every resource, `deletion_protection: false`, steps 005/025/032/046/059/060/120 off, the image ref = this sha's image | B3, B4, B8 | spec 072 A7, A8, A12 | S | conf-validator accepts it; tpl-gen renders it with `ENV=cr`; `grep -c gh_repo` over the rendered tfvars -> 0; two runs give two different instance names and the same project |
| **CR4** | **Keyless tooling.** The tf-runner and the db and hub actions accept the credentials `google-github-actions/auth` (WIF) leaves behind when no key file exists | B2 | research 03 A4, A5 | S | research 03 A4's stub test plus a case: no key file, WIF credentials present -> no `FATAL`; on a box the per-env key stays the first choice |
| **CR5** | **Deploy without a release.** `do_hub_deploy` (research 05 H3) and the WUI deploy accept `SPL_NO_MINT=1`: image tag `sha-<sha>`, no git tag pushed, `/version` shows the sha | B9 | research 05 H3 (A1 / H6 to pull instead of build) | XS | a stub test: `SPL_NO_MINT=1` -> 0 pushes of a `v*` tag; the dry run prints `sha-<sha>` |
| **CR6** | **The workflow `75_cleanroom-estate.yml`.** Triggers: `workflow_dispatch`, a nightly cron, every `stable-*` tag. `ubuntu-latest`, `concurrency: cleanroom`, `timeout-minutes: 60`. Jobs: `up` (CR3, then spec 072 A9 `do_spl_estate_up ENV=cr`), `smoke` (health, `/version` = sha, wf 50's browser proof on the `run.app` and `web.app` URLs), `down` (`if: always()`, CR1), and an hourly `janitor` (CR1 `JANITOR=1`). `concurrency` is a must: one project holds one run. Each stage writes its seconds into `result.json`, the run's artifact | B5; spec 072 A16 | CR1-CR5, spec 072 A9, research 08 no-domain action | M | a `workflow_dispatch` run is green end to end and its `result.json` has one row per stage of 1.2; **control** on a throwaway branch: a planted failing smoke still runs `down` and leaves 0 Cloud Run services and 0 SQL instances in the project |
| **CR7** | **The deploy time as a published number.** `./run -a do_report_cleanroom N=10` reads the last N `result.json` artifacts and prints the median per stage and in total; `DEPLOY.md` (spec 072 A15) cites the command with its n and date, not an estimate | spec 072 G17, A15 | CR6 | XS-S | with 3 fixture artifacts the action prints the medians; `DEPLOY.md` cites the command, not a hand-typed number |
| **CR8** | **Full tier, weekly.** Same workflow, `TIER=full`: a sub-zone `cr-<run>.<BASE_DOMAIN>` delegated by one NS record that CR2's SA may write in the parent zone, plus 005, 025, 032 and the certificate wait; `down` removes the NS record | B10 | CR6, research 08 | M | a weekly run is green including a TLS GET on the tenant host; after `down` the parent zone holds 0 `cr-*` records |

Order: CR1 and CR2 first (the job is only safe with them; CR2 is the owner's one GCP step), then CR3, CR4 and
CR5 in parallel, then CR6, then CR7. CR8 after CR6 is green 7 nights in a
row. ~6-9 lane-days, plus the spec 072 actions it needs (A7, A8, A9, A12).
**No lane mutates GCP** until CR2 runs with the owner's go.

### 3.1 The top 3

1. **CR1, the safe teardown with its janitor.** Without it the job either
   leaks a ~$60-65 / month env per failed night or sits one variable away from
   emptying dev. It never deletes a project. Small, and it lands first.
2. **CR6, the workflow.** It turns "rapid deploy" from a claim into a nightly
   green or red, and replaces 047's 2-3 day estimate with a measured number
   per stage.
3. **CR3, the ephemeral env from the template.** The cheapest proof that A7
   and A8 work: if the template cannot render a `cr` env with fresh names, no
   outsider's env will render either.

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Is a separate `<org>-<app>-inf` project needed? | **No** (1.4): one throwaway project `<org>-<app>-cr` holds its own CI identity, as every env project holds its own WIF pool. Needed only if a per-run project (option B) is wanted later |
| Q1b | Go for the 3 owner steps of 1.4 (project `<org>-<app>-cr`, billing link, WIF, CI SA, $10 / month budget) once CR2 has landed? | **Yes**; until then nothing is created |
| Q2 | Cadence: nightly plus every `stable-*`? | **Yes**: ~35 runs, ~$2 a month, cap $9. Not per push: trunk mints 55-154 versions a day (research 05 1.2) |
| Q3 | What does a red clean-room run block? | **The weekly `stable-*` release only** (wf 55), so a stable tag means "deploys from zero". Trunk deploys to dev and prd stay unblocked |
| Q4 | Run the full tier (a real sub-domain and certificates) weekly, after 7 green core nights? | **Yes**: the domain and the certificate wait are where a stranger loses the most time (research 08), so they need their own proof |
