# 072 research a2: client operator walk - own instance in own GCP org

Author: a-184 (s072 review lane a2). Tree: `origin/master` @ `9bd99ac2e`, 2026-10-04.
Persona: A client platform operator (DevOps/SRE) who received release `stable-2026-09-29`
and wants to deploy and operate their own spool instance in their own Google Cloud organization.
Scope: The end-to-end walk from release consumption to a live, healthy stack in the client's GCP org.
Owner verbatim (HUM-10 topic `6410e374`): "We need to start the specification for concrete actions
to perform in order to enable the rapid deployability of the whole system, not only by the client
but as an open-source project as a whole" and "For this project end users' usability, including
DevEx, is more important than the financials of the actual potential business running this project."
Usability and DevEx ranked above cost. Numbers given for costs and measurements.

`<org>`, `<app>`, `<env>`, `<fqdn>`, and `<project-id>` are placeholders.

## 1. Today

### 1.1 The three persona questions

| question | answer from the tree today | check |
|---|---|---|
| **What do they get?** | A git release tag (`stable-2026-09-29`); **0 release assets** (no binary, no image, no compose bundle, no tfvars bundle); source repo with 18 raw terraform steps, 1435 lines of cnf YAML, and an agent installer; docs written for our estate (`spool-hub.ai`). | `gh release view stable-2026-09-29 --json assets` -> 0; `git ls-remote --tags origin 'stable*'` -> 1; `grep -ciE "gcp\|terraform\|047\|072\|byo" README.md` -> 0 |
| **What do they have to ask us for?** | 1. Prebuilt container images or image build rights (no public GHCR). 2. Access/token for `tpl-gen` (`setup-tpl-gen.func.mk:2`). 3. A clean config template (cnf has 65 estate literals). 4. Removal of 9 `csi-spl-*` terraform regexes. 5. Guidance on 7 secret seeds. 6. Clarification on why `gcp-002` demands org-level IAM policy mutation. | `grep -li ghcr .github/workflows/*` -> 0; `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 9; `ls csi-spl-cnf/csi-spl \| grep -ciE 'tpl\|template\|example'` -> 0 |
| **Where do they wait on us?** | 1. Waiting for code fixes to unblock project IDs and Firebase site ID collisions. 2. Waiting for public image releases on GHCR. 3. Waiting on their own SecOps review while `gcp-002` tries to lift key creation at the GCP org level. 4. Waiting for a single resumable estate orchestrator instead of 102 manual make commands. | `gcp-001-create-project.func.sh:71-75`; `019-firebase-static-site/02-variables.tf:42`; `gcp-002-...:120-138` |

### 1.2 The operator's walk from zero

| step | what the client operator does | what happens today | check |
|---|---|---|---|
| 1. Unpack release | Clone or download release tag `stable-2026-09-29` | Gets raw tree (37 MB). Directory layout requires `<org>/<org>-<app>` | `resolve-oap.func.sh:13` |
| 2. GCP Org Setup | Prepare GCP Org, billing account, org admin identity `$GCP_ACCOUNT` | Human prerequisites; requires Org Admin rights | `csi-spl-iac/README.md:72` |
| 3. Bootstrap (`gcp-000`) | Run `ENV=dev ./run -a do_gcp_000_bootstrap_gcp_env` | **BLOCKED**: `gcp-001:73` refuses any `proj_id` != `${ORG}-${APP}-${ENV}`; `gcp-002:128` attempts to grant `roles/orgpolicy.policyAdmin` at the **root org** and lift `disableServiceAccountKeyCreation` across the entire GCP organization. | `gcp-001-create-project.func.sh:71-75`; `gcp-002-create-project-service-account.func.sh:120-138` |
| 4. Configure estate | Edit `csi-spl-cnf` for their own domain and accounts | **BLOCKED**: 1435 lines in 4 files with 58 mentions of `spool-hub.ai`, our org ID, and owner email; 0 templates exist. | `wc -l csi-spl-cnf/csi-spl/*.yaml` -> 1435; `grep -rn "spool-hub.ai" csi-spl-cnf \| wc -l` -> 58 |
| 5. Setup tooling | `make do-setup-app-inf` (tpl-gen, tf-runner, conf-validator) | **BLOCKED**: Fails immediately on `demand_var-GITHUB_TOKEN` to clone private `tpl-gen`. | `setup-tpl-gen.func.mk:2,19` |
| 6. Render tfvars | `ENV=dev ./run -a do_tpl_gen` | Validates YAML and renders 36 tfvars files (18 steps x 2). | `ls csi-spl-cnf/csi-spl/dev/tf \| wc -l` -> 36 |
| 7. Apply Terraform | 18 steps x render/plan/apply (or `do_tf_sweep_steps`) | **BLOCKED**: 9 regex validations reject names not starting with `csi-spl-`; step 019 Firebase site ID fails on global collision; step 046 targets `csi-spl-bkp`; lexical sweep runs Cloud Run (030) before Cloud SQL (040). | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 9; `019/02-variables.tf:42`; `tf-sweep-steps.func.sh:44` |
| 8. Build & push images | Build Cloud Run hub image and push to Artifact Registry | **BLOCKED**: No named deploy action; must build from `hub.Dockerfile` or distroless `spool-hub-api/Dockerfile` and push manually. | `grep -rln 'run services update' csi-spl-orc/src csi-spl-iac/src .github/workflows` -> wf 20 only |
| 9. Seed secrets | Run 7 secret seed actions + `do_spl_db_bootstrap` | 8 manual scripts per env; missing secrets fail at runtime. | `ls csi-spl-orc/src/bash/run/*seed*.sh \| wc -l` -> 7 |
| 10. Deploy WUI | Deploy static WUI to Firebase Hosting | **BLOCKED**: WUI Dockerfile bakes 11 `NUXT_PUBLIC_*` build args at generate time; needs Node/pnpm toolchain. | `grep -oE 'NUXT_PUBLIC_[A-Z_]+' .github/workflows/30_wui-build-deploy.yml \| sort -u \| wc -l` -> 11 |
| 11. Seat agent boxes | Run `install.sh` on worker machines | Needs 37 MB clone, downloads Go from `go.dev`, requires tenant root key on box; no join token. | `install.sh:6,272`; `037 T005 OPEN` |

### 1.3 Measured facts

| item | measured | check |
|---|---|---|
| Release assets on `stable-2026-09-29` | **0 assets**, 0 images on GHCR | `gh release view stable-2026-09-29 --json assets`; `grep -li ghcr .github/workflows/*` -> 0 |
| Trunk drift past stable | **1292 commits** | `git rev-list --count stable-2026-09-29..origin/master` -> 1292 |
| Hardcoded `csi-spl-*` validations in tf | **9 validations across 7 steps** | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 9 |
| Environment restriction in tf | **14 files** require `dev` or `prd` | `grep -rln 'contains(\["dev", "prd"\]' csi-spl-iac/src/terraform \| wc -l` -> 14 |
| Terraform steps / resources | **18 steps / 61 resources** | `ls -d csi-spl-iac/src/terraform/[0-9]*/ \| wc -l` -> 18; resource grep -> 61 |
| Config estate literals | **1435 lines**, 58 `spool-hub.ai` hits, 0 templates | `wc -l csi-spl-cnf/csi-spl/*.yaml`; `grep -rn "spool-hub.ai" csi-spl-cnf \| wc -l` -> 58 |
| Estimated monthly cost per env | **~$60-65 / month** (Cloud Run ~$50, Cloud SQL ~$11) | 047 §4.2; Cloud Run always-on CPU = ~80% of bill |

## 2. Blockers

1. **Global project ID lock & directory derivation.** `gcp-001-create-project.func.sh:71-75` derives `proj_id="${ORG}-${APP}-${ENV}"` and refuses any `gcp_project` that differs. `resolve-oap.func.sh:13` derives ORG/APP from the directory basename. GCP project IDs are globally unique, and `csi-spl-dev` / `csi-spl-prd` already belong to us.
2. **Hardcoded estate name regexes in terraform.** 9 validation blocks in 7 steps (`019:42`, `020:37`, `028:37`, `040:37`, `045:37,47`, `046:31,41`, `050:37`) reject any name not matching `^csi-spl-(dev|prd)-*$`.
3. **Globally unique Firebase Hosting site ID collision.** `019-firebase-static-site/02-variables.tf:42` forces `site_id = "csi-spl-(dev|prd)-site"`. Firebase site IDs are globally unique across all GCP projects; a client cannot deploy step 019 without code modification.
4. **Mandatory GCP Org & root-level policy mutation.** `gcp-001:57` fails without an org or folder. `gcp-002:128` grants `roles/orgpolicy.policyAdmin` at the **organization root** to lift `disableServiceAccountKeyCreation` org-wide (`gcp-002:120-138`), leaving an unrevoked admin grant. Enterprise SecOps will not permit this.
5. **No configuration template (1435 lines of estate values).** `csi-spl-cnf/csi-spl/` holds 65 estate-specific literals across 4 files, including our owner email (`all.env.yaml:26`) and org ID (`all.env.yaml:27`). No `estate.yaml` or blank template exists.
6. **Infra stack halts on `GITHUB_TOKEN`.** `setup-tpl-gen.func.mk:2,19` demands `demand_var-GITHUB_TOKEN` to build `tpl-gen` and `tf-runner`.
7. **No published release artifacts.** The release has 0 assets and 0 container images (`55_release-stable.yml:41-60`). The client must compile all Go binaries, container images, and WUI assets from source.
8. **No single estate driver; lexical execution fails.** `tf-sweep-steps.func.sh:44` sorts steps lexically, attempting step 005 before 025 and Cloud Run (030) before Cloud SQL (040) or Artifact Registry (028). No resumable `do_spl_estate_up` exists.
9. **Build-time WUI configuration.** `wui.Dockerfile:30-31` bakes `SPOOL_PUBLIC_URL` at build time; changing domain or API URL requires a full frontend rebuild.
10. **Agent seating requires root key and compiler.** `install.sh:6,272` builds `spool` from source and requires Go. Seating an agent requires copying the tenant root key to the box; no join token exists (`037 T005`).

## 3. Actions

Ranked by usability and DevEx (HUM-10). Each is sized for one lane.

| # | action | changes | effort | done when (testable check) |
|---|---|---|---|---|
| **A8** | **Unpin project & resource names** | Parameterize project ID from cnf `gcp_project` in `gcp-001:71-75` and `resolve-oap.func.sh`; replace 9 `regex("^csi-spl")` terraform validations with resource-specific syntax checks | S-M | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 0; `gcp-001` plans a project named `acme-spool-dev` |
| **A7** | **8-key `estate.yaml` template & `do_spl_cnf_init`** | Provide `csi-spl-cnf/template/estate.yaml` (8 keys) and `do_spl_cnf_init` wizard; validator names missing keys; derives resource names via A44 | S-M | `ls csi-spl-cnf/template/estate.yaml` exists; `do_spl_cnf_init` renders valid cnf that plans with 0 `spool-hub.ai` literals |
| **A18** | **Keyless bootstrap by default** | `BOOTSTRAP_AUTH=impersonate`: `gcp-002` grants `roles/iam.serviceAccountTokenCreator` instead of minting JSON keys; 0 org policy edits; `do_tf_init` uses impersonation | M | Stubbed test: 0 `org-policies` calls, 0 `keys create` calls; terraform runs with `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` |
| **A9** | **`do_spl_estate_up ENV=<env>` orchestrator** | Ordered, resumable estate up: runs bootstrap, builds/pulls images, runs tf steps in dependency order (025<005, 028<030, 040<030, 050<030), seeds secrets, probes `/v1/health` | M | Fresh GCP project: one command reaches healthy `/v1/health` and WUI; re-run changes nothing |
| **A1** | **Publish hub and WUI images to GHCR** | On `stable-*` and `v*`, CI publishes public container images to `ghcr.io/<org>/spool-hub` and `spool-web`; Cloud Run deploys from prebuilt images | M | `gh release view <tag>` lists image digests; anonymous docker pull succeeds without login |
| **A3** | **Runtime WUI configuration (`/config.json`)** | WUI fetches runtime settings (`api_base`, `site_url`, `tenant`) from `/config.json` rendered at container start; eliminate build-time args | M | `grep -c 'ARG SPOOL_PUBLIC_URL' csi-spl-wui/src/docker/wui.Dockerfile` -> 0; one prebuilt image serves any domain |
| **A4** | **Prebuilt `spool` CLI release assets** | CI attaches cross-compiled CLI binaries (linux/darwin, amd64/arm64) and `SHA256SUMS` to GitHub releases; `install.sh` downloads and verifies | S-M | `install.sh` seats agent on machine without Go compiler; `grep -c 'releases/download' install.sh` >= 1 |
| **A5** | **Agent join tokens (037 T005)** | WUI allows admin to mint short-lived join tokens; `spool join <url> <token>` seats agent; tenant root key never leaves owner | M-L | Agent seated in < 1 min from WUI without exposing root key |
| **A10** | **Org optional in GCP bootstrap** | When neither `GCP_ORG_ID` nor `GCP_FOLDER_ID` is set, `gcp-001` creates project with no parent; skip org-level policy steps | S | `DRY_RUN=1 ./run -a do_gcp_000_bootstrap_gcp_env` succeeds with no org env var |
| **A14** | **Tokenless infra tooling** | Vendor `tpl-gen` or make public ref; drop `demand_var-GITHUB_TOKEN` from `setup-tpl-gen.func.mk` | S | `make do-setup-tpl-gen` succeeds without `GITHUB_TOKEN` in environment |
| **A15** | **Unified `DEPLOY.md` guide** | Root `DEPLOY.md` documenting P1 (compose), P2 (GCP), and P3 (agents) with prerequisites, single entry-point commands, and error index | S | Linked from README; every documented command verified passing |

### 3.1 Top 3 Actions

| rank | action | why first (HUM-10 DevEx ranking) |
|---|---|---|
| 1 | **A8 + A7** (unpin names & config template) | Without this, a client cannot even begin: project creation fails on global ID collisions and terraform validation regexes reject their naming. |
| 2 | **A18 + A10** (keyless bootstrap, org optional) | Unblocks corporate adoption: eliminates demand for root organizationAdmin rights and org-wide key policy tampering. |
| 3 | **A9 + A1** (`do_spl_estate_up` + public images) | Shrinks client deployment from 102 manual make commands and hours of local compilation to one resumable command pulling prebuilt images. |

### 3.2 Target client path after A1-A18

| step | command | manual steps |
|---|---|---|
| 1. Init config | `do_spl_cnf_init` (answers 8 questions for `estate.yaml`) | ~8 answers |
| 2. Bootstrap | `ENV=dev ./run -a do_gcp_000_bootstrap_gcp_env` (keyless, org-optional) | 1 command |
| 3. Estate up | `ENV=dev ./run -a do_spl_estate_up` (resumable, ordered tf + secrets + deploy) | 1 command |
| 4. Verify | probe `/v1/health` and open WUI custom domain | 1 click |
| 5. Seat agent | mint join token in WUI; paste `spool join <url> <token>` on worker | 1 pasted line |

### 3.3 Cost analysis (numbers; HUM-10 ranks last)

| item | number | check |
|---|---|---|
| Cloud Run hub (1 vCPU, 512 MiB, min=1, CPU always on) | ~$50 / month | 047 §4.2; 2 628 000 vCPU-s x $0.000018 |
| Cloud SQL (`db-f1-micro`, 10 GB SSD, backups) | ~$11 / month | 047 §4.2; instance + disk + backups |
| Artifact Registry, Secret Manager, GCS, Firebase | ~$1-3 / month | 047 §4.2; 13 secrets, storage inside standard tiers |
| **Total client GCP bill per environment** | **~$60-65 / month** | 047 §4.2 |
| Client engineer time saved | **from ~2-3 days of manual code edits to < 30 min** | 047 §1.2 vs target path |

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | May a client GCP estate run in a single GCP project per environment (omitting separate `bkp` and satellite `all` projects)? | **Yes**: default `estate.yaml` to 1 project per env (`<proj>-dev`, `<proj>-prd`); make offsite backups (046) and satellite VM (059/060) optional flags. |
| Q2 | Should GCP bootstrap default to Workload Identity / SA Impersonation (`BOOTSTRAP_AUTH=impersonate`) rather than saving JSON keys to disk? | **Yes**: enterprise SecOps forbids downloading static service account keys to local workstations. |
| Q3 | Decouple Firebase Hosting `site_id` from fixed project naming by allowing custom site IDs? | **Yes**: Firebase site IDs are globally unique across all Google Cloud; hardcoding `csi-spl-(dev\|prd)-site` guarantees 409 collisions for clients. |
| Q4 | Can a client deploy without an external SMTP relay or Stripe account during initial evaluation? | **Yes**: allow `SMTP_HOST=""` to log invite links to Cloud Logging, and keep Stripe billing disabled by default in the client template. |
