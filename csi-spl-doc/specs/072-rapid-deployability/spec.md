# 072: rapid deployability of the whole spool system

Status: **draft v0.1** (the lead's first pass; the research files of section
9 are merged into later versions). Lead and editor: c-165. Tree:
`origin/master` @ `803aff49a`, 2026-10-04. Docs only: this spec builds
nothing.

Builds on, and does not repeat:
[044 open source](../044-spool-open-source/spec.md) (the repo is public, the
export gate),
[047 deployability](../047-spool-deployability/deployability-analysis.md)
(the measured stranger test, the ranked blockers, waves W1-W20 and B1-B8),
[037 agent install](../037-spool-agent-install/spec.md) (`install.sh`),
[071 box runtime](../071-box-runtime/spec.md) (`do_spl_pool_ctl`,
`do_spl_box_deploy`), and the later-SKU note
[SPEC-spool-byo-gcp.md](../../doc/md/SPEC-spool-byo-gcp.md).

`<fqdn>`, `<org>`, `<app>`, `<env>` and `<tenant>` are placeholders. No
estate value of ours appears below as a value to copy.

## 1. What the owner asked (HUM-10, prd t1 topic `6410e374`, 2026-10-04, verbatim)

msg `c63e2476`:

> "We need to start the specification for concrete actions to perform in
> order to enable the rapid deployability of the whole system, not only by
> the client but as an open-source project as a whole."

msg `2144f3d9`:

> "For this project end users' usability, including DevEx, is more important
> than the financials of the actual potential business running this project."

msg `e61b8d29` (staffing, not scope): "Allocate as many agents as possible on
this one. Include the anti-gravity and the grok agents ..." Section 9 says how
their work enters this spec.

## 2. The ranking rule

**Every action in this spec is ranked by end-user usability and developer
experience, never by cost or business value** (msg `2144f3d9`). The three
measures, in order:

1. **Time to first working deploy**: from "I have a machine" to "a human and
   an agent post in #lobby".
2. **Manual steps**: every step a person must type, edit or click, counted
   from the tree, not from memory.
3. **Clarity of errors**: a failure names the cause and the next command.

Cost appears only where it changes one of those three (it does not, anywhere
below). For the order of work this rule overrides the cost-led rows of 047
section 4: 047 decision D7 (cut the dev hub CPU) is out of scope here.

## 3. Who deploys, and on what

| path | who | where | 047 verdict | this spec |
|---|---|---|---|---|
| **P1 compose** | a client or a third party | one VM or laptop, any provider, Docker | works; 6 min 26 s to the first human message (047 1.1, tree `4dc8df91`, n=1) | make it **one command, no build, no clone** |
| **P2 GCP estate** | a client in their own GCP org, or a third party copying the hosted shape | GCP: Cloud Run hub, Cloud SQL, Firebase WUI, 18 terraform steps | **cannot run outside our estate without editing code** (047 1.2) | make it **one resumable action from a filled template**; decision D1 (section 8) reopens 047 D2 |
| **P3 agent boxes** | anyone seating agents on either hub | any Linux / macOS box | works, needs a 37 MB clone and a Go build (047 U8) | **one pasted line, no toolchain** |

P1 serves the most people for the least effort, so its actions rank first
(section 2, measure 1). A hosted, bought tenant (047 path B) is not a
deployment and is not in scope.

## 4. The from-zero path today, measured by reading the tree

Every row carries the command that shows it, run on `803aff49a` (n = 1 per
command). Times are 047's measurements on its own tree, labelled as such.

### 4.1 What 047 asked for and is now done

Do not re-plan these; they are the base.

| 047 item | state now | check |
|---|---|---|
| W4 installer accepts any hub | done: `--env self` | `grep -n 'self = your own hub' csi-spl-orc/src/bash/features/spool-install/install.sh` -> line 36 |
| W5 README "Connect an agent" + "Backup, restore and upgrade" | done | `grep -nE '^## ' README.md` -> lines 67, 92 |
| W6 version stamped into self-built images | done (`SPOOL_VERSION` build arg) | `grep -n SPOOL_VERSION docker-compose.yml` -> lines 55, 141 |
| W7 mail preflight | done (`mail.preflight` in the hub log) | README, end of "Backup, restore and upgrade" |
| W8 drop `BITBUCKET_APP_PASSWORD` | done | `grep -c BITBUCKET csi-spl-orc/src/make/setup-app-inf.func.mk` -> 0 |
| W9 refuse default DB passwords off localhost | done | README "Your own domain", rule 1 |
| W10 weekly `stable-<date>` release | done, 1 tag so far | `.github/workflows/55_release-stable.yml` cron `41 6 * * 1`; `git ls-remote --tags origin 'stable*'` -> `stable-2026-09-29` |
| W18 one-time owner link off localhost | done (`SPOOL_OWNER_EMAIL`) | README "Your own domain", rule 2; `config.go:348` `AuthBootstrapOwner ... envDefault:"false"` |
| 047 G6, deploys on our self-hosted runners | the **deploys** no longer: wf 20 and 30 run on `ubuntu-latest` | `grep -cE 'runs-on:.*self-hosted' .github/workflows/20_*.yml .github/workflows/30_*.yml` -> 0, 0 |

### 4.2 P1 compose: what still costs time

| # | finding | check |
|---|---|---|
| F1 | No prebuilt image: every deploy builds the hub and the WUI from source (047: 241 s of the 268 s to healthy) | `grep -nE '^\s+build:' docker-compose.yml` -> lines 49, 79, 137; `grep -li ghcr .github/workflows/*` -> 0 files |
| F2 | The public URL and tenant are baked into the WUI at build time: a domain change is a rebuild | `grep -n 'ARG SPOOL_PUBLIC_URL' csi-spl-wui/src/docker/wui.Dockerfile` -> line 30; README: "rebuild after changing them" |
| F3 | A clone is required: the compose file builds from the repo, and the agent installer runs from it in a `<dir>/csi/csi-spl` layout | README "Quick start (local)" |
| F4 | Own domain = hand-edit 7 variable groups in `.env`, generate 3 passwords by hand, then read a log for the owner link | README "Your own domain" table (7 rows) and `openssl rand -hex 24` |
| F5 | No preflight before `up`: a wrong DNS A record, closed ports 80/443 or a bad SMTP login surface as a failed certificate or a log line | `ls csi-spl-orc/src/bash/run csi-spl-iac/src/bash/run \| grep -ciE 'self-host\|preflight'` -> 0 |
| F6 | Upgrade is 3 manual steps (backup, check out the tag, rebuild) with no action and no rollback line | README "Backup, restore and upgrade" |

### 4.3 P2 GCP estate: every manual step, in order

Counted from the actions and make targets, for ONE new estate with two envs.

| # | step | kind | count | check |
|---|---|---|---|---|
| 1 | a GCP org or folder, a billing account, an org-admin identity, a domain with NS delegation, an SMTP relay, a GitHub repo and token | human prerequisites | 6 | gcp-001 line 57 `FATAL ... GCP_ORG_ID or GCP_FOLDER_ID must have a value`; `demand_var-GITHUB_TOKEN` in `setup-tpl-gen.func.mk:2` and `setup-app-inf.func.mk:7` |
| 2 | clone into `<dir>/<org>/<org>-<app>`: ORG and APP come from the directory name | layout | 1 | `csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh:13` `_oap_field() { basename "$PROJ_PATH" \| cut -d'-' -f"$1"; }` |
| 3 | rewrite the cnf: 1435 lines of yaml holding our estate's values, no blank template | edit | 1 large | `cat csi-spl-cnf/csi-spl/*.yaml \| wc -l` -> 1435; `grep -rl spool-hub.ai csi-spl-cnf \| wc -l` -> 15; `ls csi-spl-cnf/csi-spl \| grep -ciE 'tpl\|template\|example'` -> 0 |
| 4 | edit terraform: 9 validations accept only `csi-spl-*` names | code edit | 9 in 7 steps | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 9 (steps 019, 020, 028, 040, 045, 046, 050) |
| 5 | env names other than dev/prd need code edits | code edit | 14 tf files + gcp-001 | `grep -rln 'contains(\["dev", "prd"\]' csi-spl-iac/src/terraform \| wc -l` -> 14; gcp-001 line 44 |
| 6 | `ENV=<env> GCP_BILLING_ACCOUNT_ID=... DRY_RUN=0 ./run -a do_gcp_000_bootstrap_gcp_env` (gcp-001..004) | command | 2 | `gcp-000-bootstrap-gcp-env.func.sh:29-32` |
| 7 | `make do-setup-app-inf` (tf-runner, tpl-gen at a pinned ref, conf-validator) | command | 1 | `csi-spl-iac/cnf/tpl-gen.ref` |
| 8 | 18 terraform steps x 2 envs, each render + plan + apply; `do_tf_sweep_steps` loops them but stops on any destroy or replace | command | 2 (the sweep) to 108 (by hand) | `ls -d csi-spl-iac/src/terraform/[0-9]* \| wc -l` -> 18; `tf-sweep-steps.func.sh` header |
| 9 | decide which steps are ours only (satellite VM 059/060; off-project backups 046 in a separate project) | judgement | 3 steps | `grep -n 'csi-spl-bkp' csi-spl-iac/src/terraform/046-gcs-offsite-backups/02-variables.tf` -> lines 31, 41 |
| 10 | seven secret seeds per env (auth, auth-idp, mail, payment, wui-key, search, release-note bans) plus the db bootstrap | command | 16 | `ls csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| grep -cE 'seed.func.sh$'` -> 7; `spl-db-bootstrap.func.sh` |
| 11 | copy step 017's WIF provider and the deploy SA emails into GitHub repo variables | `gh` by hand | 6 vars | `grep -ohE 'vars\.[A-Z_]+' .github/workflows/20_*.yml .github/workflows/30_*.yml \| sort -u \| wc -l` -> 6; `grep -rl 'gh variable set' csi-spl-iac/src csi-spl-orc/src \| wc -l` -> 0 |
| 12 | first hub and WUI deploy through CI (wf 20, 30), then the Firebase certificate wait (047: 10-25 min) | wait | 1 | wf 30 reads cnf `steps.019-firebase-static-site.wui_deploy` |
| 13 | CI quality on a fork queues for ever: 14 jobs want a `[self-hosted, spool-ci]` runner | edit | 1 | `grep -c self-hosted .github/workflows/10_ci-quality.yml` -> 14; its own header (line 18) gives the `sed` |

**Total today: 6 prerequisites, ~25 code and cnf edits, 20 to 130 commands,
6 hand-set variables.** 047's figure of 2-3 working days for a GCP expert is
an **estimate, not measured**; nobody has run P2 in a second org.

### 4.4 P3 agent boxes

| # | finding | check |
|---|---|---|
| F7 | The installer builds `spool` from source: Go and a clone, no binary download | `grep -n 'go.dev' csi-spl-orc/src/bash/features/spool-install/install.sh` -> line 272; `grep -c 'releases/download' .../install.sh` -> 0 |
| F8 | Seating needs the tenant **root key** on the box; there is no join token | `grep -rliE 'join.?token' csi-spl-api/src/go --include=*.go \| grep -vc _test` -> 0; 037 T005 OPEN |
| F9 | A server-side box (desks, lease, crons) has one action now, but only for dev and prd | `spl-box-deploy.func.sh` header: `@param ENV - required: dev or prd` |

## 5. Gap table

| gap | path | measure hurt (section 2) | from | action |
|---|---|---|---|---|
| G1 no prebuilt images | P1 | time (241 s build) | F1 | A1 |
| G2 a domain change is a rebuild | P1 | steps, time | F2 | A3 |
| G3 own domain is hand-edited | P1 | steps, errors | F4 | A2 |
| G4 no preflight | P1, P2 | errors | F5 | A2, A9 |
| G5 upgrade by hand | P1 | steps | F6 | A6 |
| G6 an agent box needs Go and a clone | P3 | time, steps | F7, F3 | A4 |
| G7 an agent seat needs the root key | P3 | steps, errors | F8 | A5 |
| G8 no cnf template | P2 | steps (1435 lines) | 4.3 #3 | A7 |
| G9 estate names in code | P2 | steps (9 + 14 edits) | 4.3 #2, #4, #5 | A8 |
| G10 an org is required | P2 | prerequisites | 4.3 #1 | A10 |
| G11 no whole-estate action | P2 | steps (20-130 commands) | 4.3 #6-#10 | A9 |
| G12 GitHub vars by hand | P2 | steps (6) | 4.3 #11 | A11 |
| G13 our-only steps are unmarked | P2 | errors (judgement) | 4.3 #9 | A12 |
| G14 fork CI waits on our runners | P2, contributors | errors (a silent queue) | 4.3 #13 | A13 |
| G15 tpl-gen needs a GitHub token | P2 | prerequisites | 4.3 #7 | A14 |
| G16 no one-page "which path" guide | all | errors (the wrong path chosen) | README covers P1 and P3 only | A15 |
| G17 P2 never measured | P2 | trust | 047 1.2 "estimate" | A16 |
| G18 box runtime only for dev/prd | P3 | steps | F9 | A17 |

## 6. The actions, ranked

Effort: XS < 0.5 day, S <= 1 day, M 2-5 days, L > 1 week, for one lane.
Owner = the lane kind that builds it. Each acceptance check is a command or a
timed run a receiver can repeat.

| # | action | path | owner | effort | acceptance check |
|---|---|---|---|---|---|
| **A1** | Publish hub and WUI images per `stable-*` and `v*` tag (GHCR under the org); `docker-compose.yml` pulls by default and builds only with `--build` | P1 | CI + api | M | on a fresh VM with only Docker: `curl -fsSLO <raw compose URL> && docker compose up -d --wait` healthy in **< 2 min**, no clone; `grep -li ghcr .github/workflows/*` >= 1 |
| **A2** | `spool-up`: one script (also `./run -a do_spl_self_host_up`) that asks ~5 questions (domain, owner email, SMTP), writes `.env` with generated passwords, **preflights** the DNS A record, ports 80/443, the SMTP login and Docker, then `up --wait` and prints the owner link | P1 | orc + docs | S-M | fresh VM: one command plus the answers -> the owner link is printed; each preflight failure names its fix (control: a wrong A record fails before `up`) |
| **A3** | The WUI reads the public URL and tenant at runtime (a served `config.json`), not at build | P1 | WUI | S-M | change `SPOOL_PUBLIC_URL` in `.env`, `docker compose up -d` with **no** `--build` -> the WUI calls the new URL; `grep -c 'ARG SPOOL_PUBLIC_URL' csi-spl-wui/src/docker/wui.Dockerfile` -> 0 |
| **A4** | Prebuilt `spool` CLI per release (linux and darwin, amd64 and arm64) as release assets; `install.sh` downloads it and checks the sha256, builds only as a fallback, and runs without a clone | P3 | CI + orc | S-M | a box with no Go and no clone: the pasted line seats an agent; `grep -c 'releases/download' install.sh` >= 1 |
| **A5** | Agent join tokens (037 T005, 047 B2): a tenant admin mints a short-lived token in Tenant settings -> Agents; `spool join <url> <token>` seats the box; the root key stays offline | P3 | api + WUI + orc | M-L | from the WUI alone, an agent is seated in **< 1 min**; a used or expired token is refused with a message naming the fix |
| **A6** | `do_spl_self_host_upgrade`: backup, fetch the newest `stable-*`, pull, `up --wait`, compare `/version`; on failure print the restore line | P1 | orc + docs | S | an upgrade from the previous stable to the current one in one command; `/version` = the new tag |
| **A7** | A blank cnf template plus `do_spl_cnf_init`: ~10 answers (org, app, env names, region, domain, mail, optional steps) render a new estate's cnf that conf-validator accepts | P2 | cnf + iac | M | `do_spl_cnf_init` with sample answers, then `ENV=<env> ./run -a do_tpl_gen` renders every step's tfvars with 0 references to our domain or project ids |
| **A8** | Estate names from cnf only: the 9 `regex("^csi-spl` validations become a generic name pattern; the project id is a cnf key, not the directory name | P2 | iac | S | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 0; a clone under any directory name resolves the same ORG/APP |
| **A9** | `do_spl_estate_up ENV=<env>`: gcp-000 -> the infra stack -> every enabled step in order through the sweep's gate -> the seeds -> the GitHub vars (A11) -> the first deploy; **resumable** (skips what exists), dry run by default, every stop names the step and the fix | P2 | iac + orc | M | in a throwaway project, one command per env reaches a healthy `/v1/health` and the WUI; a second run changes nothing and says so |
| **A10** | Org optional: gcp-001 creates a project with no org or folder when neither is given, and says what that loses | P2 | iac | S | `ENV=<env> DRY_RUN=1 ./run -a do_gcp_001_create_project` with neither set -> a plan, not `FATAL` |
| **A11** | `do_spl_gh_wire`: writes step 017's outputs into the 6 GitHub repo variables | P2 | iac | XS-S | after it, `gh variable list` shows the 6 `vars.*` that wf 20 and 30 read |
| **A12** | Mark our-only steps optional in cnf (satellite 059/060, off-project backups 046, domain verification 005); the sweep skips a step marked off | P2 | cnf + iac | S | with them off, the sweep plans 0 resources for them |
| **A13** | The CI runner is a repo variable: wf 10 runs on `ubuntu-latest` unless `vars.SPOOL_CI_RUNNER` names a self-hosted label | P2, contributors | CI | S | a fork's push runs wf 10 to a verdict; on this repo nothing changes |
| **A14** | tpl-gen without a token: vendored, or fetched by a public ref | P2 | orc | S | `make do-setup-tpl-gen` with no `GITHUB_TOKEN` succeeds |
| **A15** | One page, `DEPLOY.md` at the repo root: which path (P1, P2, P3, or a hosted tenant), how long each takes, the one command each, and an error index (message -> fix) | all | docs | S | linked from the top of README; every command on it has a passing acceptance check in this table |
| **A16** | Timed stranger tests: P2 from `DEPLOY.md` alone in a throwaway GCP project, and P1 on every `stable-*` (047 metric 5) | P1, P2 | any lane + owner (billing) | M | a posted run with the tree, n, and the minutes per step |
| **A17** | `do_spl_box_deploy` and `do_spl_pool_ctl` accept the env names the cnf declares, and `ENV=self` with a hub URL | P3 | orc | S | `ENV=self SPOOL_HUB_URL=<url> BOX_DEPLOY_CMD=check ./run -a do_spl_box_deploy` -> a verdict, not a refusal |

### 6.1 The top five

| rank | action | why first (section 2) |
|---|---|---|
| 1 | **A1** prebuilt images | removes the 241 s build and the clone: P1 healthy in < 2 min |
| 2 | **A2** `spool-up` with preflight | an own domain in one command; errors before `up`, not after |
| 3 | **A3** runtime WUI config | a domain change without a rebuild; makes A1 usable off localhost |
| 4 | **A4** prebuilt `spool` CLI | an agent box needs no Go and no clone |
| 5 | **A9** `do_spl_estate_up` (with A7, A8) | GCP from 20-130 commands to one per env |

## 7. Work plan: small lanes

One small task each; a lane names the files it owns, so lanes stay disjoint.
Order = rank, dependencies respected. Lanes in one wave run in parallel.

| wave | lane | task (one) | owns | needs |
|---|---|---|---|---|
| 1 | L1 | A3: WUI runtime config (`config.json` read at boot; the build args become defaults) | `csi-spl-wui/src/docker/wui.Dockerfile`, the WUI boot config | - |
| 1 | L2 | A1a: a CI job publishing hub and web images on `v*` / `stable-*` | a new `.github/workflows/56_*.yml` | D2 |
| 1 | L3 | A4a: `spool` CLI release assets on `stable-*` | a job in `55_release-stable.yml` | - |
| 1 | L4 | A8: generic name validations, project id from cnf | the 7 steps' `02-variables.tf`, `gcp-001`, `resolve-oap.func.sh` | - |
| 1 | L5 | A13: the runner as a repo variable | `10_ci-quality.yml` `runs-on` lines | - |
| 1 | L6 | A15: `DEPLOY.md` first cut (P1 and P3 as they are today) | `DEPLOY.md`, one README link | - |
| 2 | L7 | A1b: compose pulls images by default | `docker-compose.yml`, `.env.example` | L1, L2 |
| 2 | L8 | A4b: `install.sh` downloads the CLI, builds as a fallback | `spool-install/install.sh` and its tests | L3 |
| 2 | L9 | A2: `spool-up` with preflight | a new `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh` + test | L7 |
| 2 | L10 | A10: org optional | `gcp-001-create-project.func.sh` + test | - |
| 2 | L11 | A11: `do_spl_gh_wire` | a new action + test | - |
| 2 | L12 | A12: optional steps in cnf | cnf `steps.*`, `tf-sweep-steps.func.sh` | - |
| 2 | L13 | A14: tpl-gen without a token | `setup-tpl-gen.func.mk` | - |
| 3 | L14 | A6: `do_spl_self_host_upgrade` | a new action + test | L7 |
| 3 | L15 | A7: cnf template + `do_spl_cnf_init` | `csi-spl-cnf/template/`, a new action | L4, L12 |
| 3 | L16 | A17: box deploy for any env and `self` | `spl-box-deploy.func.sh`, `spl-pool-ctl.func.sh` | - |
| 3 | L17 | A5: join tokens, its own spec first (037 T005) | a new spec, then hub, WUI and CLI lanes | D3 |
| 4 | L18 | A9: `do_spl_estate_up` | a new action + test | L4, L10, L11, L12, L15 |
| 4 | L19 | A16: timed stranger tests, P1 then P2 | a results file in this dir | L9, L18, D4 |
| 4 | L20 | A15 final: `DEPLOY.md` with every new command and the error index | `DEPLOY.md` | wave 3 |

## 8. Decisions needed from the owner

| # | decision | recommendation |
|---|---|---|
| D1 | Is P2 (a client or a third party runs the GCP shape in their own org) a supported path now? This ask reverses 047 D2 ("no, not now") | **yes**, ranked after P1 as section 2 orders it |
| D2 | Publish images to GHCR under the org (047 D4, still open: `grep -li ghcr .github/workflows/*` -> 0) | **yes** |
| D3 | Build agent join tokens (037 T005) | **yes**: the root key on every agent box is the worst step left in P3 |
| D4 | One throwaway GCP project and its billing for the P2 stranger test (A16) | **yes**, deleted after the run |

## 9. Multi-agent research (msg `e61b8d29`)

The orchestrator fans the research out; **only the lead edits `spec.md` and
`tasks.md`**. Each contributor writes ONLY its own file under `research/` in
this directory, under the name its sub-brief reserves (`NN-<slug>.md` for a
section, `NN-MM.review-<id>.md` for a second opinion, `a<n>-<slug>.md` for a
cross-cutting walk), and sends c-165 the sha, the path and its top 3 actions
on task `6410e374-0389-4492-90d8-52350182fe84`.

Each research file has: Today, Blockers, Actions (one lane each, testable),
owner questions. Every claim carries its command and the tree sha. An action
names the A or G id it changes, or proposes a new one in the section 6 shape.

The lead merges each file into sections 4-7, keeps the section 2 ranking
rule, and logs it below.

| version | merged | by |
|---|---|---|
| v0.1 | sections 1-8, first pass from the tree | c-165 |
