# 072: rapid deployability of the whole spool system

Status: **draft v0.18** (the version log is at the end of section 9). Lead
and editor: c-165. Baseline tree for section 4: `origin/master` @
`803aff49a`, 2026-10-04; each research file names its own tree. Docs only: this
spec builds nothing.

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

### 2.1 User story 1: a contributor earns the feature they build (the first story)

Owner, HUM-10, topic `6410e374`, msg `699f38b0`, verbatim:

> "So that might be the first line: If somebody sends me an invite and
> explains to me what kind of feature he likes and I would consider that
> feature valuable, I would provide him with access. That person would
> basically use his own tokens and his own hardware resources to build the
> whole thing and push it and then after that he will get the benefits of
> exactly this feature. It will enable him to use the whole system for
> himself."

**This is the spec's first user story, and the work plan (section 7.0) makes
it work end to end before anything else.** Each step names what it needs.

| step | the contributor ... | what makes it work | actions |
|---|---|---|---|
| 1 | asks the owner for access and pitches a feature they want | a written way in: the contributor page says where and how to ask | A28 |
| 2 | is approved, and gets scoped, revocable, expiring access | `do_spl_hub_invite` with a `developer` role and a TTL; access that ends on a date; never GCP, the root key or CI secrets (3.2 R1, R2) | A27 |
| 3 | seats their own laptop or cloud VM, with their own AI-vendor tokens | a per-seat join token, a CLI download, no Go, no GCP (3.2 R3) | A5, A4 |
| 4 | builds the feature with their agents and pushes it | a fork whose CI runs to a verdict on GitHub-hosted runners; the repo's gates; the owner reviews and merges | A13 |
| 5 | runs the whole system for themselves, with the feature in it | the self-host paths: compose (P1) today, faster with prebuilt images; their own GCP (P2) later | A1, A2, A3 (P1); A9 (P2) |

Acceptance: the A29 newcomer test, extended to step 5: a contributor with no
GCP knowledge goes from an approved invite to their own agent's first pushed
change and their own running stack, from written pages alone.

## 3. Who deploys, and on what

| path | who | where | 047 verdict | this spec |
|---|---|---|---|---|
| **P1 compose** | a client or a third party | one VM or laptop, any provider, Docker | works; 6 min 26 s to the first human message (047 1.1, tree `4dc8df91`, n=1) | make it **one command, no build, no clone** |
| **P2 GCP estate** | a client in their own GCP org, or a third party copying the hosted shape | GCP: Cloud Run hub, Cloud SQL, Firebase WUI, 18 terraform steps | **cannot run outside our estate without editing code** (047 1.2) | make it **one resumable action from a filled template**; a supported path (owner D1 = yes, section 8, reverses 047 D2) |
| **P3 agent boxes** | anyone seating agents on either hub | any Linux / macOS box | works, needs a 37 MB clone and a Go build (047 U8) | **one pasted line, no toolchain** |
| **P3+ contributor** | a person with no GCP knowledge whom the owner invites (owner, msgs `e8d15511`, `97f2df08`) | their own laptop or cloud VM, with **their own AI-vendor login and tokens** | not covered by 047 | invited, scoped, revocable, expiring; seats agents with a join token and contributes through the public repo |

P1 serves the most people for the least effort, so its actions rank first
(section 2, measure 1), and the owner orders no-cloud self-host first (msg `fe7fd2b9`, 3.1). A hosted, bought tenant (047 path B) is not a
deployment and is not in scope.

### 3.1 GCP now; the cloud layer is out of scope

Owner, HUM-10, topic `6410e374`, msg `03bc3dab`, verbatim:

> "Yes any company or organization should be able to spawn their own Google
> Cloud. Later on we will add support for AWS as well."

So P2 is a supported path for any company or organisation, on GCP. **How to
make the cloud layer swappable (GCP now, AWS later) is out of scope for this
spec**: the owner gave it its own discussion topic, opened by the dispatcher,
with no work started (msg `d7e415ed`; topic `a5a141bc`). This spec designs no seam; its P2
actions are GCP actions.

The owner's decisions for that topic (msg `fe7fd2b9`), recorded here only;
no lane starts until the owner says go:

- **Scope:** every service: compute, blob storage, database, secrets, web
  hosting, DNS/TLS, CI identity.
- **Shape:** a factory pattern for the provider interface.
- **Order:** no-cloud self-host first, then AWS.
- **Default:** GCP is the default supported provider; this instance runs on
  GCP wherever cloud resources are needed.

The self-host-first order is why P1 (compose, no cloud) is this spec's first
path (section 3).

### 3.2 Guests and contributors: access without giving up the project

Owner, HUM-10, topic `6410e374`, verbatim:

> "I would like to be able to invite, from time to time, even deeply technical
> persons to the project but, of course, not give up the whole project to
> different persons (because I am paying for it right now and I have already
> invested several thousand in it)." (msg `e8d15511`)

> "But I would like to be able to allow persons who do not have the whole GCP
> experience or stuff to be able to use their own local machines or virtual
> machines in the cloud (with their own tokens) for the AI agents to be able to
> join forces with this project and start participating in the development of
> this project as well." (msg `97f2df08`)

Design rules every action in this spec keeps:

- **R1 Scoped, revocable, expiring.** A guest gets a workspace role
  (`developer` or `tester`) through `do_spl_hub_invite` (`INVITE_ROLE`,
  `TTL_HOURS`), loses it through `do_spl_hub_invite_revoke` or
  `do_spl_tenant_member_role`, and their access ends on a date (A27: today
  only the invite expires, not the membership).
- **R2 No guest holds the estate.** No guest needs GCP access, a cloud key,
  the tenant root key or a CI secret. Agents join with a per-seat token (A5).
  The owner alone keeps billing, the cloud projects and the owner/admin roles.
- **R3 Their machine, their tokens.** A contributor runs agents on their own
  laptop or cloud VM with their own AI-vendor login. The project never pays
  for, stores or proxies those tokens. Code comes in through the public repo
  (044), reviewed like any outside contribution.
- **Acceptance (P3+):** a newcomer's machine is seated and its agent takes a
  task, from a written page alone (A28, A29).

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

### 4.5 Findings the research added (v0.3)

Each row is the contributor's claim with its check; the full walk is in the file.

| # | finding | from | check |
|---|---|---|---|
| F10 | gcp-000 forces the cnf org, so a folder never works through the one-command path | research/02 B3 | `gcp-000-bootstrap-gcp-env.func.sh:21-23`; gcp-001 `not both` at :51 (line corrected by review 01-02) |
| F11 | When the env leaves them unset, our org id and owner login are the silent defaults: an outsider who forgets `GCP_ACCOUNT` aims at our org | research/02 B4 | `csi-spl-cnf/csi-spl/all.env.yaml:26-27`; `gcp-account-pin.func.sh:185-192` |
| F12 | gcp-002 rewrites the **org-level** key-creation policy and leaves a permanent org policyAdmin grant | research/02 B6 | `grep -c remove-iam-policy-binding csi-spl-iac/src/bash/run/gcp-002-create-project-service-account.func.sh` -> 0 |
| F13 | The dry run stops at gcp-003 on a new project; "(or it may not exist)" reads a taken project id as free | research/02 B2, B7 | `gcp-003-configure-proj-sa-permissions.func.sh:45-46` (line corrected by review 01-02); `grep -n 'it may not exist' gcp-001-create-project.func.sh` -> line 94 |
| F14 | Two hub images: compose builds alpine in Docker, Cloud Run ships distroless from a host Go build | research/05 B3 | `grep -cE '^FROM' csi-spl-api/src/docker/hub.Dockerfile csi-spl-orc/src/docker/spool-hub-api/Dockerfile` -> 2, 1 |
| F15 | No named hub or WUI deploy action: the roll and the Hosting deploy exist only inside wf 20 / wf 30 | research/05 B4, 06 B3 | `grep -rln 'run services update' csi-spl-orc/src csi-spl-iac/src .github/workflows` -> wf 20 only |
| F16 | A fork's deploy is skipped **silently green**: wf 20/30 read `GCP_KEY_CSI_SPL_<ENV>` while step 120 writes `GCP_KEY_<ORG>_<APP>_<ENV>` | research/05 B4, 06 T3 | `grep -c CSI_SPL .github/workflows/20_*.yml .github/workflows/30_*.yml` -> 12, 8 |
| F17 | The Hosting site id regex admits only our two ids, which are globally unique for ever | research/06 T1 | `019-firebase-static-site/02-variables.tf:41-44` |
| F18 | wf 30 bakes 11 `NUXT_PUBLIC_*` values per env and the build reads our cnf path from disk | research/06 1.2, B7 | `grep -oE 'NUXT_PUBLIC_[A-Z_]+' .github/workflows/30_wui-build-deploy.yml \| sort -u \| wc -l` -> 11; `nuxt.config.ts:91` |
| F19 | The version odometer allows one digit per part: at `9.9.9` every hub and WUI deploy fails at the mint (c-160 counted 159 steps left at ~130 a day on 2026-10-04). **Not a deployability action**: c-160 routed it to the orchestrator (msg `1af8a098`) | research/05 B1 | `grep -n 'spl_version_valid()' csi-spl-orc/lib/bash/funcs/spl-release-version.func.sh` -> `^[0-9]\.[0-9]\.[0-9]$` |
| F20 | The contributor's local dev stack (lde) needs host Go and a filled module cache, and `do_setup_app_inf` provisions the box spool root (`/var`, a group, sudo) | research/01 B1-B3, B8 | research/01 section 1 |
| F21 | Changing `SPOOL_HTTP_PORT` alone leaves the public URL on 8080, a silent failure; the fixed compose project name stops two clones side by side | research/01 B4, B7 | `SPOOL_HTTP_PORT=18580 docker compose config \| grep -c localhost:8080` > 0 |
| F22 | A contributor's pull request runs only hub-suite, wui-suite and wui-e2e; iac, orc, cnf and the hygiene sweep run after the merge, so their reds land on trunk | research/12 B2 | `awk '/^jobs:/{f=1;next} f&&/^  [a-z-]+:/' .github/workflows/11_ci-public.yml` |
| F23 | Live-estate workflows (00, 21, 22, 31, 40, 45, 55, 68) have no "is this our estate" guard: an enabled fork would probe, tag or DAST-scan **our** hosts | research/12 B3 | `grep -nE 'github\.repository ==\|vars\.SPOOL_' .github/workflows/*.yml \| wc -l` -> 0 |
| F24 | The CI and box identity is `roles/owner`, and that key is copied into GitHub and used before WIF | research/09 B1, B2 | `gcp-003-configure-proj-sa-permissions.func.sh:34`; `20_hub-build-deploy.yml:24` |
| F25 | Seven secret seeds with no runner and no empty-slot check: an empty slot fails at the Cloud Run deploy, far from its cause | research/09 B6 | research/09 1.3 |
| F26 | ~65 estate values in 1435 cnf lines; 48 are resource names derivable from org, app and env; 96 keys are identical in dev and prd | research/04 1.1, 3.2 | research/04 section 1 |
| F27 | Terraform: the state bucket is made by a host-terraform procedure; apply re-plans instead of applying the reviewed plan, with `-lock=false`; there is no step order in cnf | research/03 B1-B3 | `grep -c 'lock=false' csi-spl-iac/src/bash/run/tf-plan.func.sh csi-spl-iac/src/bash/run/tf-apply.func.sh` |
| F28 | Plain `http://<ip>` off localhost breaks file upload and download with a browser error (`crypto.subtle` needs a secure context); 4 variables must agree by hand for one domain; GCP has no "no custom domain" mode | research/08 B1-B4 | `csi-spl-wui` `spool-client.mjs:86`; `grep -c 'ssh -L' README.md` -> 0 |
| F29 | The release has 0 assets, the compose file needs the tree (`pg-init.sh` bind mount), nothing is signed or checksummed, and the stable is proven on Cloud Run, not on the compose path a client runs | research/15 B1, B2, B5, B6 | `gh release view stable-2026-09-29 --json assets`; `docker-compose.yml:36` |
| F30 | Migrations: no lint for duplicate prefixes or edited applied files; the hub starts on a schema behind its image | research/07 | research/07 D3, D4 |
| F31 | Hosted path (047 path B, not a deployment, recorded for its owner): workflow 40 is `disabled_manually` although its header says revived, and a bought tenant gets no box-wui pin, so its browser posts reach no agent | research/08 B5, 13 B1, B2 | `gh workflow list --all \| grep '^40'`; `dispatch.go:157` `wui_unpinned` |
| F32 | The one loop over every step runs them in **lexical** order, so 005 plans before 025 (its DNS zone) and 030 before 028 / 040 (its registry and database): a from-zero sweep stops at the first dependent step | research/a2 B8 | `grep -n '| sort)' csi-spl-orc/src/bash/run/tf-sweep-steps.func.sh` -> line 73 |
| F33 | Nothing a deployer pulls is pinned or checked: 0 of 8 Dockerfiles pin a base image by digest; `install.sh` runs vendor installers through bash and downloads yq and Go with no checksum | research/a3 B4, B5 | `git grep -cE '^FROM.*@sha256' -- '*Dockerfile*'` -> no file; `git ls-files '*Dockerfile*' \| wc -l` -> 8; `install.sh:241-245`, `:279-282` |
| F34 | **Correction to research a3 B7** ("no rate limiting on unauthenticated routes"): the hub already answers 429 on sign-in attempts and at its edge. A load test of `/api/v1/auth/register` (a3 S8's own check) is still worth one run before the stranger tests, so no new action | lead check | `grep -n StatusTooManyRequests csi-spl-api/src/go/spool-hub-api/internal/auth/native.go csi-spl-api/src/go/spool-hub-api/internal/edge/edge.go` -> `native.go:133`, `edge.go:220` |
| F35 | The help page a newcomer follows to connect an agent sets our hosted hub URL and a legacy agent id (`CLE-01`, a form that ended 2026-10-03), while the README says `localhost:8080` and `spool-agent` | research/a1 B2 | `grep -nE "SPOOL_HUB_URL=\|CLE-0" csi-spl-doc/doc/help/connect-an-agent.md` -> lines 31, 38, 41 |
| F36 | The hub test suite a contributor runs first fails on a clean machine: it forces `GOPROXY=off` with a cold module cache | research/a1 B6, research/01 | `grep -n GOPROXY csi-spl-api/src/bash/tests/run-all-tests.sh` -> line 18 |
| F37 | **Correction to research a4 A-DEV1** ("purge dead scripts"): most of its list is live. `do_divest` is the terraform destroy behind `make do-deprovision`; the 3 tenant-host actions are called by workflow 40 and `do_spl_tenant_create`; `gcp-s3-download-all` has a live lane and a test; the `gcp-*-s3*` actions use `gcloud storage` (GCS), not AWS. Only the WordPress excludes inside the GCS sync actions are dead text | lead check | `grep -n divest csi-spl-orc/src/make/tf-tasks.func.mk` -> lines 88, 102, 137; `git grep -l do_spl_tenant_host -- .github csi-spl-orc/src` -> wf 40, `spl-tenant-create.func.sh` |
| F38 | **A live WUI bug on user story 1 step 3**: Tenant settings -> Agents opens the connect guide on `CLE-01`, a legacy id the validator has rejected since `2026-10-03T20:59:59Z`, so the paste block is hidden; three connect procedures (README, help page, guide) disagree. Reported to the orchestrator; **fixed** in `496bfb803` (c-174, A65 part 1), live on dev and prd | review 17-18 (g-182) B1, B2; lead check | `grep -n "ref('CLE-01')" csi-spl-wui/src/components/ConnectAgentGuide.vue` -> line 62; `csi-spl-wui/src/utils/agent-id.mjs:20` |
| F39 | Resuming a half-built bootstrap in a new shell is not safe: once the key file exists the identity resolves to the SA, which gcp-003 has not yet made owner, so the run cannot finish its own grant | review 01-02 (g-168) | `gcp-account-pin.func.sh:180-183` |
| F40 | The step a stranger meets first is the name, not the key: with the project id `csi-spl-dev` an outsider stops at project create (and at `spl-cloud-cnf.func.sh:111`, 028 `:37`) before any org-policy step or image build. So A8 (names) ships before A18 (keyless) and A21 (one image) | reviews 01-02, 05-06; research a2 | `gcp-001-create-project.func.sh:71`; `spl-cloud-cnf.func.sh:111` |
| F41 | Steps 059/060 (our satellite VM) render for dev too, so a default `ENVS="dev prd"` sweep plans them; the satellite project `csi-spl-all` is a fourth project class beside dev, prd and bkp | review 03-04 (g-169) | `git grep -l csi-spl-all \| wc -l` -> 39 (reviewer's count) |
| F42 | Stale text describes a load balancer (step 031) this tree removed: wf 20 :635-636, wf 30 :7-13, the firebase.json renderer :42-44, 019 `02-variables.tf:47-56`; wf 30 probes `<site>.web.app`, not the custom domain a person types; CI's cloud-sql-proxy is v2.14.1 while cnf pins 2.18.0 | review 05-06 (g-178) | `ls -d csi-spl-iac/src/terraform/031*` -> none; `grep -oE "cloud-sql-proxy[^ ]*v[0-9.]+" .github/workflows/20_hub-build-deploy.yml`; `all.env.yaml:235` |
| F43 | GCP with no custom domain (A41) would put the WUI on the Firebase host and the API on the Cloud Run URL: two sites, so the `SameSite=Lax` session cookie is not sent and sign-in fails, while A41's old check stayed green | review 07-08 (g-170) | `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1407` |
| F44 | `do_spl_tenant_create` prints the new root private key on stdout (by design, once); the 040 step pins no backup retention count; lde's hub DSN user is the container superuser, so row level security does not bind there (reviewer's claim, not re-checked by the lead) | review 07-08 (g-170) | `spl-tenant-create.func.sh:3,58`; `grep -c retained_backups -r csi-spl-iac/src/terraform/040-cloud-sql-postgres` -> 0 |
| F45 | wf 22 (deploy verify, it probes our hosts) also runs from wf 20 on any hub-path push of a fork, with no schedule enabled; the README "another machine" paragraph teaches copying the root key | review 11-12 (g-171) | `grep -n 22_deploy-verify .github/workflows/20_hub-build-deploy.yml` -> line 714; `README.md` "On another machine" |
| F46 | The one stable is 35 migration files behind trunk (77 vs 112) and its note says 52 migrations; the README quick start should stay on master until the stable path (A37) is proven | review 15-16 (g-172) | `git rev-list --count stable-2026-09-29..origin/master` (reviewer: 1291) |

## 5. Gap table

| gap | path | measure hurt (section 2) | from | action |
|---|---|---|---|---|
| G1 no prebuilt images | P1 | time (241 s build) | F1 | A1 |
| G2 a domain change is a rebuild | P1, P2 | steps, time | F2, F18 | A3, A26 |
| G3 own domain is hand-edited | P1 | steps, errors | F4 | A2 |
| G4 no preflight | P1, P2 | errors | F5 | A2, A9 |
| G5 upgrade by hand | P1 | steps | F6 | A6 |
| G6 an agent box needs Go and a clone | P3 | time, steps | F7, F3 | A4 |
| G7 an agent seat needs the root key | P3 | steps, errors | F8 | A5 |
| G8 no cnf template | P2 | steps (1435 lines) | 4.3 #3 | A7 |
| G9 estate names in code | P2 | steps (9 + 14 edits) | 4.3 #2, #4, #5, F17 | A8 |
| G10 an org is required | P2 | prerequisites | 4.3 #1 | A10 |
| G11 no whole-estate action | P2 | steps (20-130 commands) | 4.3 #6-#10 | A9 |
| G12 GitHub vars by hand | P2 | steps (6) | 4.3 #11 | A11 |
| G13 our-only steps are unmarked | P2 | errors (judgement) | 4.3 #9 | A12 |
| G14 fork CI waits on our runners | P2, contributors | errors (a silent queue) | 4.3 #13 | A13 |
| G15 tpl-gen needs a GitHub token | P2 | prerequisites | 4.3 #7 | A14 |
| G16 no one-page "which path" guide | all | errors (the wrong path chosen) | README covers P1 and P3 only | A15 |
| G17 P2 never measured | P2 | trust | 047 1.2 "estimate" | A16 |
| G18 box runtime only for dev/prd | P3 | steps | F9 | A17 |
| G19 the bootstrap changes the whole org and needs a key | P2 | errors (an org admin refuses), steps | F12 | A18, A20 |
| G20 no full dry run, no preflight of rights | P2 | errors | F10, F11, F13 | A19, A10 |
| G21 two hub images | P1, P2 | time (host Go), steps | F14 | A21 |
| G22 no named hub / WUI deploy action | P2 | steps | F15 | A22, A23 |
| G23 a fork deploys nothing and stays green | P2 | errors | F16 | A24 |
| G24 guest access does not expire | P3+ | trust (owner rule R1) | 3.2 | A27 |
| G25 no page for a contributor with no GCP knowledge | P3+ | steps, errors | 3.2 | A28, A29 |
| G26 contributor dev stack needs Go and sudo | P3+ (US1 step 4) | time, steps | F20, F21 | A46 |
| G27 a pull request is not fully gated; forks can reach our estate | P3+ (US1 step 4), us | errors, trust | F22, F23 | A34, A35 |
| G28 owner-rights key in CI | P2 | trust (a third party's review stops) | F24 | A31, A32 |
| G29 secrets are 16 hand-run seeds | P2 | steps, errors | F25 | A30 |
| G30 the cnf is 65 values to type | P2 | steps | F26 | A44, A7 |
| G31 terraform apply is not the reviewed plan | P2 | errors, trust | F27 | A42 |
| G32 no-domain and plain-http shapes fail unclearly | P1, P2 | errors | F28 | A40, A41 |
| G33 the release is not a client artifact | P1 | time, trust | F29 | A1, A36-A39 |
| G34 schema drift is silent | P1, P2 | errors | F30 | A45 |

## 6. The actions, ranked

Effort: XS < 0.5 day, S <= 1 day, M 2-5 days, L > 1 week, for one lane.
Owner = the lane kind that builds it. Each acceptance check is a command or a
timed run a receiver can repeat.

| # | action | path | owner | effort | acceptance check |
|---|---|---|---|---|---|
| **A1** | Publish the hub image (one image, A23) and the WUI image or bundle (A26) per `stable-*` and `v*` tag to **GHCR as public packages**, the only zero-cost registry (D2, section 8); each `stable-*` release also attaches an images-only compose pinned by **digest**, `.env.example` and `SHA256SUMS` (research 15 C1); `docker-compose.yml` pulls by default and builds only with `--build`. If GHCR stops being free, A1 falls back to today's local build (section 8, D2) | P1 | CI + api | M | on a fresh VM with only Docker: `curl -fsSLO <raw compose URL> && docker compose up -d --wait` healthy in **< 2 min**, no clone; `grep -li ghcr .github/workflows/*` >= 1; an anonymous pull of the image works (no `docker login`) |
| **A2** | `spool-up`: one script (also `./run -a do_spl_self_host_up`) that asks ~5 questions (domain, owner email, SMTP), writes `.env` with generated passwords, **preflights** the DNS A record, ports 80/443, the SMTP login and Docker, then `up --wait` and prints the owner link. Patterns to copy (research 19): Discourse's preflight list, Zulip's safe re-run that ends with the link, Supabase's generated keys written to `.env` with mode 600 | P1 | orc + docs | S-M | fresh VM: one command plus the answers -> the owner link is printed; each preflight failure names its fix (control: a wrong A record fails before `up`) |
| **A3** | The WUI reads its env values at runtime from a served `/config.json` in the shape Element Web uses (research 19) (api and auth base, tenant, site URL, tenant hosts, env name, locale, lobby task id), for **both** carriers: compose writes it from `.env` at container start, the Hosting deploy (A23) writes it per env. Build-time values stay only as lde defaults; the build stops reading our cnf path (06 W1, W8); first edit: `nuxt generate` fails closed when the public URL is unset instead of publishing localhost (review 05-06) | P1, P2 | WUI | M | one `nuxt generate` with no `NUXT_PUBLIC_*` set, served with two different `config.json`s, calls two different api hosts; `grep -c 'ARG SPOOL_PUBLIC_URL' csi-spl-wui/src/docker/wui.Dockerfile` -> 0; `grep -c NUXT_PUBLIC_API_BASE .github/workflows/30_wui-build-deploy.yml` -> 0 (today 2) |
| **A4** | Prebuilt `spool` CLI per release (linux and darwin, amd64 and arm64) as release assets; `install.sh` downloads it and checks the sha256, builds only as a fallback, and runs without a clone. The k3s pattern (research 19): the same pasted line installs, and with `SPOOL_HUB_URL` + `SPOOL_JOIN_TOKEN` also seats. It resolves paths from `$HOME`, not the clone layout, adds `~/.local/bin` to PATH, pins Go and yq to `go.mod` and a sha256 (research 10 A20, A21, A24; 16 R6). Target: under 30 s of machine time and < 300 MB in the home, from ~130 s and ~1.3 GB today (research 10, n=1) | P3 | CI + orc | S-M | a box with no Go and no clone: the pasted line seats an agent; `grep -c 'releases/download' install.sh` >= 1 |
| **A5** | Agent join tokens (037 T005, 047 B2; owner D3 = yes): a tenant admin mints a short-lived, **per-seat** token (valid 1 hour, single use, shown once, like the GitHub runner token; research 19) in Tenant settings -> Agents; `spool join <url> <token>` seats the box; each seat is revocable on its own; the root key never leaves the owner (rules R1, R2 in 3.2) | P3 | api + WUI + orc | M-L | from the WUI alone, an agent is seated in **< 1 min**; a used or expired token is refused naming the fix; revoking one seat leaves the others seated |
| **A6** | `do_spl_self_host_backup` / `_restore` / `_upgrade` (research 07 D1, 15 C7): the README lines as actions (db name from `.env`, a 0700 dir, `KEEP=<n>`, an optional off-machine copy hook); upgrade = backup, `docker compose pull`, `up -d` (Gitea's shape, not a Discourse-style rebuild; review 19-20), i.e. fetch the newest `stable-*`, pull, `up --wait`, compare `/version`; on failure print the restore line; the notes name the hard stops (a stable you may not skip), as Sentry does (research 19) | P1 | orc + docs | S | an upgrade from the previous stable to the current one in one command; `/version` = the new tag |
| **A7** | A 9-key `estate.yaml` (org, app, project id (default derived; review 03-04), base domain, GitHub repository, bootstrap account, org/folder/none, mail, env names; billing stays an env var) plus `do_spl_cnf_init`, its questions kept in one declarative answers file in the `app.json` style (prompt, required, `generator: secret`; research 19), after the derivations of A44 (research 04 C6, C7, 03 A8); tenant hosts off in the template (08 D5, 13 N4); the validator names each missing key; the answers render a new estate's cnf that conf-validator accepts | P2 | cnf + iac | M | `do_spl_cnf_init` with sample answers, then `ENV=<env> ./run -a do_tpl_gen` renders every step's tfvars with 0 references to our domain or project ids |
| **A8** | Estate names and env names from cnf only: the 9 `regex("^csi-spl` validations become each resource's own id rule (019 names the Hosting site's global-uniqueness trap); the project id is cnf `env.gcp.gcp_project`, not the directory name (and the conf-validator's realm rule stops requiring `<org>-<app>-<env>`: `csi-spl-cnf/src/python/conf-validator/EnvModels/cloud.py:64` refuses A8's own fixture today; review 03-04), in the bootstrap (02 G1), `do_spl_cloud_cnf` (05 H4) and the key path; the env names are the `*.env.yaml` files the cnf holds, in terraform, gcp-001, the firebase.json renderer and the DNS action (02 G8, 06 W6) | P2 | iac + orc | S-M | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 0; a fixture cnf with `gcp_project: acme-spool-dev-7f3a` under a directory named `csi-spl-iac` plans `projects create acme-spool-dev-7f3a`; a fixture `stg.env.yaml` makes `ENV=stg` plan |
| **A9** | `do_spl_estate_up ENV=<env>`: gcp-000 -> the infra stack -> every enabled step in the cnf `steps_order` (dependency-checked: 025<005, 028<030, 040<030, 050<030; research 03 A2), with named hooks between steps (image push, `do_spl_db_bootstrap` after 040, secrets A30, domain verify, cert wait; 07 D7), then the first tenant and its owner invite in one action (07 D6) through the sweep's gate -> the seeds -> the GitHub vars (A11) -> the first deploy; **resumable** (skips what exists), dry run by default, every stop names the step and the fix | P2 | iac + orc | M | in a throwaway project, one command per env reaches a healthy `/v1/health` and the WUI; a second run changes nothing and says so |
| **A10** | Org optional end to end: with no org and no folder, gcp-001 creates a project with no parent, gcp-002 skips the policy step, and gcp-000 prints what that loses; gcp-000 sets `GCP_ORG_ID` from cnf only when `GCP_FOLDER_ID` is empty, so a folder works (02 G2, G7) | P2 | iac | S | `ENV=<env> DRY_RUN=1 ./run -a do_gcp_000_bootstrap_gcp_env` with neither set -> a 4-step plan and one `INFO no org: ...` line; with a folder only -> `--folder=<id>`, no `not both` stop |
| **A11** | `do_spl_gh_wire`: writes step 017's outputs into the 6 GitHub repo variables | P2 | iac | XS-S | after it, `gh variable list` shows the 6 `vars.*` that wf 20 and 30 read |
| **A12** | Mark our-only steps optional in cnf and **off by default in the sweep** (satellite 059/060, which render for dev too (F41), off-project backups 046, domain verification 005); the sweep skips a step marked off | P2 | cnf + iac | S | with them off, the sweep plans 0 resources for them |
| **A13** | The CI runner is a repo variable: every `runs-on` in wf 10 and 99 reads `vars.SPOOL_CI_RUNNER`, else `ubuntu-latest`; this repo sets the variable through a named action, not by hand (research 12 C1) | P2, contributors | CI | S | a fork's push runs wf 10 to a verdict; on this repo nothing changes |
| **A14** | A slim infra stack: tpl-gen without a token (vendored, or fetched by a public ref); `GITHUB_TOKEN` optional except for step 120; the key dir mounted read-only, no `~/.aws` / `~/.ssh` mounts (research 03 A5) | P2 | orc | S | `make do-setup-tpl-gen` with no `GITHUB_TOKEN` succeeds |
| **A15** | One page, `DEPLOY.md` at the repo root: which path (P1, P2, P3, or a hosted tenant), how long each takes, the one command each, an error index (message -> fix), and the box size each path needs (research 19); the README opens with a "Choose your path" block (research 18 D1) | all | docs | S | linked from the top of README; every command on it has a passing acceptance check in this table |
| **A16** | Timed stranger tests. P1 on every `stable-*` (047 metric 5). P2 as a **clean-room estate** in the one throwaway project (owner `af863518`, research 20): `do_spl_cleanroom_host_bootstrap ENV=cr` once (owner); per run a scratch cnf from the template with every resource labelled `spl-run=<run>`; `do_spl_estate_up ENV=cr` (A9), a smoke (health, `/version`, wf 50's browser proof), then `do_spl_cleanroom_down`, which refuses unless the project carries `spl-cleanroom=true`; deploys use `SPL_NO_MINT=1` (no release tag); the proof cnf sets `min_instances: 0`, so a leaked run costs ~$10, not ~$60, a month (review 19-20); the nightly run is "from empty" (kept project), and a monthly run is truly from zero (project create, billing, APIs), never calling project delete from the nightly job; workflow `75_cleanroom-estate.yml` nightly and on every `stable-*`, a weekly full tier with a delegated sub-zone; `do_report_cleanroom N=10` publishes the median minutes per stage (research 20 CR1-CR8) | P1, P2 | CI + iac + owner (the one project) | M | a nightly run green from zero to smoke to an empty project, ~20-35 min (estimate), ~$0.05 a run, capped at $9 a month; `DEPLOY.md` cites `do_report_cleanroom` with its n and date |
| **A17** | `do_spl_box_deploy` and `do_spl_pool_ctl` accept the env names the cnf declares, and `ENV=self` with a hub URL; the key prerequisite is `todo`, not `missing`, on a box with no GCP (research 11 M2, 17 N17.7) | P3 | orc | S | `ENV=self SPOOL_HUB_URL=<url> BOX_DEPLOY_CMD=check ./run -a do_spl_box_deploy` -> a verdict, not a refusal |
| **A18** | **Keyless bootstrap by default** (`BOOTSTRAP_AUTH=impersonate`): gcp-002 creates the SA and grants the human `roles/iam.serviceAccountTokenCreator` on it, with no JSON key and no org-policy change; `do_tf_init` and `do_gcp_account` impersonate when no key file exists, and refuse with one line naming both routes when neither is there (research 03 A4); `BOOTSTRAP_AUTH=key` keeps today's path (02 G5) | P2 | iac | M | in impersonate mode a stubbed-gcloud log shows 0 `org-policies` and 0 `keys create` calls, and terraform gets `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`; the key-mode test stays green |
| **A19** | **A full, honest dry run plus a read-only preflight** (`do_gcp_bootstrap_preflight`): gcp-003/004 plan against a planned SA instead of stopping; a project that reads "(or it may not exist)" counts as **taken**; `testIamPermissions` on the parent and the billing account; every input says where it came from (env or cnf) (02 G3, G4) | P2 | iac | S | stub walk -> 4 `OK DRY_RUN` lines, exit 0; a denied permission -> a refusal naming the role and scope; a cnf-sourced org prints `org: <id> (from cnf ...)` |
| **A20** | **The key path, when chosen, changes only the project**: the key policy is set on `projects/<id>`, the org's previous policy is untouched, the temporary policyAdmin grant is removed, the member prefix follows the account type (02 G6) | P2 | iac | S | stub log: `set-policy` targets only `projects/<id>`; a `remove-iam-policy-binding` follows every `add`; `grep -c remove-iam-policy-binding gcp-002-create-project-service-account.func.sh` >= 1 (today 0) |
| **A21** | **One hub image** for compose, Cloud Run and the release: `do_build_push_hub_image` builds `csi-spl-api/src/docker/hub.Dockerfile` with the minted `SPOOL_VERSION`; the distroless cloud Dockerfile and the host Go build go (05 H2) | P1, P2 | api + orc | S-M | `ls csi-spl-orc/src/docker/spool-hub-api/Dockerfile` -> absent; `check-hub-deploy.tst.sh` green; dev `/version` = the minted tag after one wf 20 run |
| **A22** | **`do_hub_deploy ENV=<env>`**: mint, build or promote and push, `do_spl_db_bootstrap`, roll, `do_check_hub_deploy`; dry run by default; wf 20 calls it (05 H3) | P2 | orc | S | `grep -c 'run services update' .github/workflows/20_*.yml` -> 0; `ENV=dev ./run -a do_hub_deploy` (dry) prints 5 steps and the image ref |
| **A23** | **`do_spl_wui_deploy ENV=<env>`**: generate (or take the prebuilt bundle, A26), write `config.json` + `build.json`, render firebase.json, `firebase deploy` as the env identity, probe; wf 30 calls it; on a new custom domain it probes the host a person types (the custom domain), not only `<site>.web.app` (F42); prints the expected 10-60 min certificate wait and the `<site>.web.app` URL meanwhile (06 W3, W7) | P2 | orc | S-M | `DRY_RUN=1 ENV=dev ./run -a do_spl_wui_deploy` prints the steps, the target site and, for a new domain, the wait line; a test stubs `firebase` |
| **A24** | **Deploy workflows name envs and secrets from cnf**: wf 20 and 30 build the env matrix from the cnf env files and the auth secret as `GCP_KEY_<ORG>_<APP>_<ENV>` (what step 120 writes); an env that should deploy and has no auth **fails** instead of a green `::notice:: skipped` (05 H5, 06 W4) | P2 | CI | S | `grep -c CSI_SPL .github/workflows/20_*.yml .github/workflows/30_*.yml` -> 0, 0 (today 12, 8); `grep -cF "'DEV' \|\| 'PRD'"` on both -> 0 |
| **A25** | **Fix the stale deploy text and pin the deploy tools**: the cnf, step 030 and `build-push-hub-image.func.sh` still teach "bump hub.image.tag, then apply"; four places still describe the removed load balancer (F42), and so does the provisioning-order row in `csi-spl-doc/specs/README.md:216` (review 03-04); wf 20 installs `yq` from `releases/latest` and runs cloud-sql-proxy v2.14.1 against cnf's 2.18.0; 040 pins a backup retention count (05 H7, H8) | P2 | docs + CI | XS | `grep -rn 'bump hub.image.tag' csi-spl-cnf csi-spl-iac/src/terraform/030* csi-spl-orc/src/bash/run/build-push-hub-image.func.sh` -> 0; `grep -c 'releases/latest' .github/workflows/20_*.yml` -> 0 |
| **A26** | **One prebuilt WUI bundle per release**: after A3, `stable-*` / `v*` attach `wui-<ver>.tar.gz` and its sha256 to the GitHub release (release assets carry no bandwidth limit, section 8 D2); the compose web image and A23 both take it, so neither path needs Node and pnpm (06 W5) | P1, P2 | CI | S | `gh release view <tag> --json assets` lists the tarball; A23 with `WUI_BUNDLE=<url>` deploys without `pnpm install` |
| **A27** | **Membership that expires**: a guest's membership carries an optional `access_until`; past it the hub refuses the guest's sign-in and agents, and Tenant settings -> Members shows it. Today only the invite expires (`do_spl_hub_invite` `TTL_HOURS` 1..720 = how long the invite stays open), not the access (rule R1) | P3+ | api + WUI + rdb | S-M | `grep -n 'access_until' csi-spl-rdb/src/sql/postgres/spool-hub/*.sql` >= 1 (today `CREATE TABLE tenant_memberships` in `0006_users_and_memberships.sql` has no expiry column); a hub test: a member past `access_until` gets 403 and a control member does not |
| **A28** | **A contributor page**, `CONTRIBUTING-WITH-AGENTS.md` (or a section of `DEPLOY.md`): from an invite mail to your own agent taking a task, on your own laptop or cloud VM, with your own AI-vendor login, no GCP; it names what the guest can and cannot reach (rules R1-R3) | P3+ | docs | S | the A29 run follows it alone |
| **A29** | **The newcomer test (P3+ acceptance)**: someone with no GCP knowledge, on a fresh machine, from the A28 page alone: accept the invite, seat an agent with a join token (A5), the agent takes a task and posts its result | P3+ | any lane + one newcomer | S (after A4, A5, A28) | a posted run: tree, n, minutes per step, 0 steps outside the page; target **< 15 min** |

### 6.2 Actions from the research (v0.4)

Same shape as the table above; the source column names the research file and its own id, where the full walk and check live.

| # | action | source | path | owner | effort | acceptance check |
|---|---|---|---|---|---|---|
| **A30** | `do_spl_secrets_check` (read-only: every 030/040 secret slot has an enabled version; never reads a value) and `do_spl_secrets_seed_all` (the 7 seeds in order, generating what can be generated, asking only SMTP / IdP / payment, idempotent) | 09 K1, K2 | P2 | iac + orc | S-M | stubbed test: an empty required slot -> exit 1 naming its seed action; a second seed run adds 0 versions; 0 `versions access` calls |
| **A31** | WIF first in CI: wf 00, 20, 30, 40, 45 authenticate by WIF when the provider var is set, the key only as a fallback; the log says which | 09 K3 | P2 | CI | S | a branch run logs `auth = WIF`; a lint test asserts the WIF branch comes first |
| **A32** | Least privilege: the project SA gets the measured role list (`do_gcp_audit_iam`), not `roles/owner`; owner stays with the human bootstrap | 09 K8 | P2 | iac | M | in the D4 throwaway project a full sweep plans and applies with the new SA; `grep -c roles/owner csi-spl-iac/src/bash/run/gcp-003-*.func.sh` -> 0 |
| **A33** | One key resolver `do_gcp_key_path` honouring `GCP_KEY_DIR`; the relay key mint and rotate become actions (feature doc 6.3 today), in A20's project-only shape, never reusing gcp-002's org-wide window (review 09-10); secret names org-neutral | 09 K4-K6 | P2 | iac | S each | `grep -rlE '\.gcp/\.' csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| wc -l` -> 0 outside the resolver |
| **A34** | Estate guard: every live-estate workflow (00, 21, 22, 31, 40, 45, 55, 68), **and wf 20's call of wf 22** (F45; the call also needs `needs.deploy.result == 'success'`, since a skipped deploy still calls it today; review 11-12), runs only when `vars.SPOOL_ESTATE == 'true'`, set on this repo by the A13 action; a static fork-portability test keeps it so | 12 C2, C4 | us, P3+ | CI | S | `ci-estate-guard.tst.sh` red when a cron or cnf-host workflow lacks the guard; a fork shows them as skipped |
| **A35** | One gate for push and pull request: wf 10's suites move into a reusable workflow that wf 10 (push) and wf 11 (pull request, fork branches) both call, so a contributor gets iac, orc, cnf, hygiene **and the read-only security scanners** (gitleaks, trivy config, checkov) before merge (research a3 S6) | 12 C3 | P3+ | CI | M | a pull request's checks list iac, orc, cnf and hygiene; wf 10 and 11 job sets are equal; actionlint green |
| **A36** | Compose runs with no tree: `pg-init.sh` moves into the hub image (or an inline `configs:` entry), the bind mount goes | 15 C2 | P1 | api + orc | S | in an empty dir with only the release compose + `.env`: `docker compose up -d --wait` healthy |
| **A37** | Prove the stable on the client path before cutting it: wf 55 runs the wf 50 stranger job on the candidate with the pulled images and the release compose, plus a previous-stable -> candidate upgrade whose first fixture is the real gap (the one stable is 35 migrations behind; F46) and a backup-restore drill; red cuts nothing | 15 C4, 07 D2 | P1 | CI | S | a planted break on a throwaway branch makes wf 55 cut no tag |
| **A38** | Sign what we ship: keyless `cosign` of both image digests and `SHA256SUMS` from the release job (GitHub OIDC, no key stored); one verify line in `DEPLOY.md`; the first command a client runs is `sha256sum -c SHA256SUMS` (a tool every machine has), signing is the second layer (review 15-16) | 15 C6 | P1, P3 | CI | S | `cosign verify ghcr.io/<owner>/spool-hub@<digest> --certificate-identity-regexp ...` exits 0 in CI |
| **A39** | A release a client can act on: notes open with "Before you upgrade" (`.env` keys changed, migrations, the upgrade command); `/version`, the footer and `spool version` print `stable-<date> (v<X.Y.Z>)`; `SECURITY.md` names the latest stable, with a same-day stable for a security fix | 15 C8-C10 | P1 | CI + docs | S each | a fixture range that changes `.env.example` lists each key under "Before you upgrade"; `grep -c 'rebuild from it' SECURITY.md` -> 0 |
| **A40** | No-domain and plain-http shapes made clear: README "No domain yet" (localhost, `ssh -L`); hub-init refuses `http://<non-loopback>` naming both fixes, the WUI shows a banner without a secure context; `SPOOL_SITE_ADDRESS`, `SPOOL_DOMAIN`, the cookie flag **and `SPOOL_BIND`** derive from `SPOOL_PUBLIC_URL` (a public URL on the loopback default never gets its certificate; review 07-08) | 08 D1-D3 | P1 | api + WUI + docs | XS-S each | compose with `SPOOL_PUBLIC_URL=http://203.0.113.5:8080` -> hub-init exits non-zero naming both fixes; localhost -> 0 (control); `grep -c 'ssh -L' README.md` >= 1 |
| **A41** | GCP without a custom domain: an empty `BASE_DOMAIN` serves the WUI on the Firebase default host with the API behind Hosting's `run` rewrite on the **same origin** (F43), and turns 005/025/032 off | 08 D6 | P2 | iac + cnf | M | `do_tpl_gen` renders with `BASE_DOMAIN: ""`; the sweep plans 0 resources in 005/025/032; **a browser signs in** on the default host (the old check stayed green while sign-in failed) |
| **A42** | Terraform you can trust: `do_gcp_state_bucket_create` (000 imports the bucket; the host-terraform procedure goes); `do_provision` applies the saved, reviewed plan with the lock on and refuses a stale one; `do_tf_validate_all` validates all 18 steps in a minute with no key | 03 A1, A3, A7 | P2 | iac | S-M | `grep -c 'lock=false' tf-plan.func.sh tf-apply.func.sh` -> 0; a stub terraform receives the plan path; a fresh HOME with no key prints 18 validates |
| **A43** | Remove only what is dead: the other organisation's name from the terraform comments (03 A10) and the WordPress excludes in the GCS sync actions (a4 A-DEV1, narrowed by F37). **The AWS-era items** (`.env.aws`, `AWS_PROFILE`, the local-step-bucket actions; 03 A9) **stay** until the cloud-layer topic `a5a141bc` decides keep or replace (3.1). The tenant-host actions, `do_divest` and the GCS sync actions stay: they are live (F37) | 03 A10, a4 A-DEV1 | P2 | iac | XS | `git grep -c 'wp-config' -- csi-spl-iac/src/bash/run` -> 0; the 3 tenant-host actions and `do_divest` still exist |
| **A44** | Derive the cnf: names, secret slot ids and host values from `{org}`, `{app}`, `{env}`, `{fqdn}`; one key per fact; the 96 identical keys into `all.env.yaml`; region and key-dir literals out of code; a single-source test keeps it. Every step renders **byte-identical**, so it needs no plan, no apply and no owner go | 04 C1-C5, C8-C10 | P2 | cnf + iac | M | `ENV=dev ./run -a do_tpl_gen && ENV=prd ./run -a do_tpl_gen && git diff --exit-code csi-spl-cnf/csi-spl/*/tf` exits 0 after each lane |
| **A45** | Schema guards: a migration lint in pre-push (unique prefixes, no edited applied file, and no new file below the head prefix: today a new `0007_*.sql` would apply on every database; review 07-08); `spool serve` refuses to start on a schema behind its image, naming the migrate command; `/version` shows the schema head | 07 D3, D4 | P1, P2 | rdb + api | XS + S | a copied `0112_x.sql` turns the lint red; a postgres test with the last migration row deleted -> serve exits non-zero with that message |
| **A46** | The contributor's dev stack in one command, Docker only: the lde hub builds in Docker from `hub.Dockerfile` (no host Go); lde stops provisioning the box spool root; `SPOOL_PUBLIC_URL` follows `SPOOL_HTTP_PORT`; a per-clone compose project; `./run -a do_lde_up` / `do_lde_down`; a "Develop locally" section; a hosted CI job proves it on a clean clone; lde's hub runs as the runtime user so row level security binds as in prd (F44), and the default lde stack can sign a human in (review 01-02) | 01 A1-A7 | P3+ (US1 step 4) | orc + docs + CI | S each | `env -i HOME=$(mktemp -d) PATH=<no go> ./run -a do_setup_app_inf` on a fresh clone -> exit 0; `do_lde_up` -> `:58080/healthz` and `:3000/` both 200 |
| **A47** | A second workspace on compose in one command (`ENV=self ./run -a do_spl_tenant_create`), printing the owner invite link and where the root key went (a 0600 file, never stdout, on every path; F44); and a self-service root-key re-key in Tenant settings for a `biz_owner` | 13 N5, N7 | P1 | orc + api + WUI | S, M | on the compose stack one command -> a second tenant whose owner signs in; an e2e re-keys and seats an agent with the new key |
| **A48** | Measure the compose browser -> agent leg on a fresh `up`, and fix it if a WUI post reaches no agent (hub-init pins box-wui under a generated key) | 13 N3 | P1 | orc + api | XS to measure, S to fix | a compose e2e: a #lobby post from the WUI reaches a seated agent; control: unpin -> `wui_unpinned` |
| **A49** | **The installer writes no fleet config by default**: our fleet `CLAUDE.md`, fleet settings and the mcp-bot step run only with `--fleet`, which our boxes pass; `skipDangerousModePermissionPrompt` is never a default. A contributor's machine (2.1 step 3) keeps its own Claude Code setup | 10 A18 | P3, P3+ | orc | S | on a fresh home, `install.sh --cli none --no-seat` -> `test ! -e ~/.claude/CLAUDE.md` and no `skipDangerous` in `~/.claude/settings.json`; with `--fleet` the output is today's |
| **A50** | **Installer errors and defaults a stranger owns**: an unreachable hub, bad TLS or 404 is rc 5 naming the URL, not "PENDING"; the spool root defaults under `$XDG_STATE_HOME`, the orchestrator to the role, no `t1` default; with `SPOOL_HUB_URL` set the env is `self`; a dry run says "would render", never "rendered" (review 09-10); no legacy `CLE-00` default (`install.sh:393`) | 10 A19, A22, A23 | P3 | orc | XS-S | `SPOOL_HUB_URL=http://127.0.0.1:9 install.sh --env self --tenant t1` -> rc 5 naming the URL; after a default install `grep -rhoE '/var/spool-hub\|CLE-00' ~/.claude` -> nothing |
| **A51** | **A fresh-box installer job**: `install.sh --cli none --no-seat` as a new user on `debian:13`, `ubuntu:24.04` and `macos-latest`, asserting rc, A49's files, the re-run, A50's control, and posting the seconds | 10 A25 | P3 | CI | S | the job goes red when an assertion fails; control: revert A50 on a throwaway branch -> red |
| **A52** | **A second machine in one command**: `do_spl_box_enrol` on the new machine writes box.env, mints the desk key, pins it (join token once A5 lands, else prints the one admin line), refuses a box id already live; the desk start refuses a default box id that another host already uses | 11 M1, M3 | P3 | orc + api | S-M | against a stub hub, two runs -> the second changes nothing; a live box id -> exit non-zero naming the clash |
| **A53** | **Box bootstrap for any ssh host**: `HOST=<ssh host> ./run -a do_box_playbook` runs the satellite roles on a plain inventory, its facts from cnf, not literals; terraform 060 is one way to get a host, not the only one | 11 M4, M5 | P3 | iac + cnf | M | `do_box_playbook HOST=localhost SATELLITE_PLAYBOOK_ARGS=--check` against a Debian 13 container exits 0 |
| **A54** | **The release asset contract**: every `stable-*` carries the images (A1), the 4 CLI builds (A4), the pinned compose (A1) and `SHA256SUMS`; wf 55 fails when one is missing; the front door (README, `install.sh --update`) moves to the newest stable **only after A37 is green** (F46), `--update=master` keeps today's path | 16 R1, R5 | P1, P3 | CI + orc + docs | S | `release-stable.tst.sh` contract check; `install.sh --update --dry-run` prints the newest stable tag |
| **A55** | **Release notes that are true**: migrations listed and counted from the tree diff, not `git log --diff-filter=A` (the published note also says 52 where the tag holds 77; F46) (the published `stable-2026-09-29` note names a migration that release does not contain); a release-level forward-only gate (no stable migration renamed, edited or deleted) | 16 R2, R3 | P1 | orc + api | XS + S | `release-stable.tst.sh`: a migration added then renamed inside the range is listed once, by its new name; a control renaming a stable migration turns the gate red on a throwaway branch |
| **A56** | **CLI and hub agree on versions**: `/version` adds `min_client`; an older `spool` prints "this box runs X, the hub needs >= Y: run install.sh --update"; `spool version --hub` prints both | 16 R9 | P3 | api | S-M | a test hub with `min_client` above the test CLI -> the CLI exits non-zero with that line |
| **A57** | **Compose takes every optional hub setting**: `env_file: .env.hub` (optional) plus a commented `.env.hub.example` listing the `SPOOL_HUB_*` keys the cloud cnf sets (IdPs, payments, quotas, retention); Caddy redirects `/` by locale like the hosted WUI; wf 50 also runs the own-domain profile | 17 N17.1, N17.5, N17.6 | P1 | orc + WUI + CI | S each | `grep -c env_file docker-compose.yml` >= 1 and a wf 50 step proves one `.env.hub` key reaches the hub; `curl -sI -H 'Accept-Language: <code>' localhost:8080/` -> 302 |
| **A58** | **The `./run` front door**: `--help` grouped (start here, bootstrap, terraform, deploy, read-only, destructive, dev, gate), per-action help, "did you mean" in `./run` and `spool`, every FATAL ends with the next command, the log-dir failure names itself | 18 D4-D9 | all | orc + iac + api | S each (~12 agent-hours in all) | `./run -a do_gcp_001_create_projec` suggests the right name; every `FATAL no gcloud account` line contains `./run -a`; `--help` output contains `start here` |
| **A59** | **Docs that stay true**: the iac and api READMEs name all 18 steps and the current verbs, checked by a test; `csi-spl-doc/README.md` points at the maintained index; CONTRIBUTING says to run `do_check_pre_push` before a PR; a weekly newcomer-walk job runs every README block marked `<!-- smoke -->`; `blob.go` and the README say the `hub-files` volume is the supported one-machine store (today `blob.go:4` says "tests and local dev only"; review 17-18 N4), and no S3 driver is added here | 18 D2, D3, D10-D12 | all | docs + CI | XS-S each | the freshness test is red on today's tree and green after; a planted dead link reds the weekly job on a throwaway branch |
| **A60** | **Protect the public trunk before contributors arrive**: `do_oss_public_settings` checks and (owner's go) sets a master ruleset: no force-push, no deletion, wf 11 required, a pull request needs one maintainer review; the fleet's push identity may bypass. Today the public trunk has **no** branch protection | 14 O2 | P3+ (US1 step 4) | orc | S | the action prints `OK master ruleset`; its test stubs a repo with no ruleset and reads `FAIL`; research 14: branch protection API -> 404, 0 rulesets |
| **A61** | **A contributor knows the rules before the first push**: the DCO either checked on fork pull requests in wf 11 or dropped from CONTRIBUTING; issue and PR templates (path, `/version`, tree; test run, cheap gate); a short untrusted-input doc linked from SECURITY.md and CONTRIBUTING; SECURITY.md states the known limitation (any tenant member can prompt any agent of that tenant until the prompt allow-list lands) | 14 O4, O5, O7, O11 | P3+ | docs + CI | XS each | an unsigned fork commit fails wf 11 naming the fix (or `grep -c DCO CONTRIBUTING.md` -> 0); `gh api repos/<owner>/<repo>/community/profile --jq .health_percentage` -> 100 |
| **A62** | **Open-source hygiene that keeps itself**: spec 044 restated for the one-repo reality; the export gate as a hosted ratchet in wf 11 (a new fleet id in product code fails with class, file and line), then the 1587 fleet-id hits driven to 0 per package; licence files and SPDX headers; the open false-positive secret-scanning alert triaged; Dependabot grouped with a weekly lane | 14 O1, O3, O6, O8-O10 | all | orc + docs + CI | XS-M per item | the O9 ratchet fails a planted fleet id on a throwaway branch; `grep -c 'NEW public repo' csi-spl-doc/specs/README.md` -> 0; open secret-scanning alerts -> 0 |
| **A63** | **Evaluate on GCP with no mail relay and no Stripe**: the template sets `SPOOL_HUB_MAIL_TRANSPORT: log` (invite and confirmation links go to Cloud Logging, as lde does) and payments off; `do_spl_estate_up` prints where to read the links; a real relay is one key later | research/a2 Q4 | P2 | cnf + docs | XS | a template-rendered env has `SPOOL_HUB_MAIL_TRANSPORT: log`; the hub boots with no SMTP values (`grep -n MAIL_TRANSPORT csi-spl-cnf/csi-spl/lde.env.yaml` -> `"log"` is the working precedent) |
| **A64** | **Pin and verify what a deployer pulls**: every Dockerfile base image pinned `@sha256:<digest>` (a weekly bump lane, like Dependabot's); `install.sh` checks the sha256 of Go and yq and fails closed on a mismatch; the vendor CLI installers run from a pinned, checksummed copy where the vendor publishes one | research/a3 S3 | P1, P3 | orc + api + CI | S | `git grep -cE '^FROM.*@sha256:' -- '*Dockerfile*'` equals the number of `FROM` lines; a corrupted tarball in the installer test fails closed |
| **A65** | **One true set of agent-connect instructions** (F38): the in-app guide defaults to a new-form id (a unit test: the initial id passes `isWritableAgentId` after `LEGACY_ID_UNTIL`) and shows the paste block; README, help page and guide give the same two choices (installer, or CLI + MCP) and the README stops teaching a root-key copy for another machine (F45); getting started stops heading social sign-in "(Recommended)" on a stack that sets no provider (`getting-started.md:29`; review 17-18 N3); the help page uses `{{api}}` (filled from the running site, as the WUI help already does) and a current agent id, and says the same as the README; a doc test fails on a literal hosted URL or a legacy id in `doc/help` | research/a1 W2 | P3, P3+ | WUI + docs | XS-S | `grep -cE "spool-hub\.ai\|CLE-0" csi-spl-doc/doc/help/connect-an-agent.md` -> 0; `grep -n "ref('CLE-01')" csi-spl-wui/src/components/ConnectAgentGuide.vue` -> 0 |
| **A66** | **The hub tests run on a fresh clone**: `run-all-tests.sh` downloads modules once when the cache is cold, then runs offline as today | research/a1 B6 | P3+ (US1 step 4) | api | XS | `env -i HOME=$(mktemp -d) PATH=$PATH bash csi-spl-api/src/bash/tests/run-all-tests.sh` passes on a fresh clone |
| **A67** | **Actions take flags, not only ambient env vars**: an `@arg --flag VAR` tag lets `./run -a <action> --env dev` set `ENV`, documented in the action's own help (A58); env vars keep working. Low priority: it helps every user of `./run`, but no path is blocked without it | a4 A-DEV4 | all | orc + iac | M | `./run -a do_gcp_001_create_project --env dev --dry-run` parses; `grep -rn "@arg" csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| wc -l` >= 100 |

Also from the research, folded into existing rows rather than new ones: 02 G1-G9 -> A8, A10, A18-A20, A9; 03 A2, A4-A6, A8 -> A9, A18, A14, A8, A7; 04 C6-C7 -> A7; 05 H2-H8 -> A21-A25; 06 W1-W8 -> A3, A8, A23, A24, A26; 07 D1, D5-D8 -> A6, A8, A9, A25; 08 D4, D5 -> A2, A7; 09 K9, K10 -> A2, A15; 12 C5-C7 -> A16, A24, A15; 13 N4, N6 -> A7, A16; 15 C3, C5, C7 -> A3, A4, A6; 10 A4, A5, A20, A21, A24 -> A4, A5; 11 M2, M9 -> A17, A15; 16 R4, R6-R8 -> A37, A4, A39; 17 N17.3, N17.4 -> A21, A6; 18 D1 -> A15; 19 items 1-9 -> A2-A7, A15; a2 (a-184) B1-B10 and its actions confirm A1, A3-A5, A7-A10, A14, A15, A18 and their order (A8 + A7 first for a client); a3 (a-185, security) S1, S2, S4, S5, S7 -> A5, A31, A49, A32, A2 + A30; a1 (a-183, newcomer walk) B1, B3-B5, B7-B11 -> A46 (port), A49, A1, A40, A61, A58, A4, A15; a4 (a-186, DevEx critique) A-DEV2, A-DEV3, A-DEV5, A-DEV6, A-DEV7 -> A58, A58, A2, A9 + A18, A4 + A5; A-DEV1 -> A43 narrowed (F37); the ten grok reviews (g-168 .. g-182) corrected F10, F13 and widened A3, A6, A7, A12, A16, A23, A25, A33, A34, A37, A38, A40, A41, A45-A47, A50, A54, A55, A65 (F38-F46).

**Not in this spec's scope (hosted path B), handed to the orchestrator for their owners:** research 13 N1 (the owner enables workflow 40) and N2 (pin box-wui when a bought tenant is claimed); research 08 D7 (a check that workflow headers match GitHub's enabled state); research 05 H1 (the version odometer at `9.9.9`). Parked with the cloud-layer topic (3.1): research 17 N17.2 (an S3-compatible blob store) and research 11 M6, M8 (fleet ranking through the hub, a GitHub identity per machine), which are fleet operations, not deployability.

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

### 7.0 User story 1 first

These lanes, in this order, make 2.1 work end to end; they run before the rest
of the table below, which keeps its ids for reference.

| order | lane | action | 2.1 step |
|---|---|---|---|
| 1 | L59 | A65 the in-app connect guide shows its block again (a live bug, F38) | 3 |
| 2 | L5, then L33 | A13 fork CI on GitHub-hosted runners, then A34 estate guard (a fork never touches our estate) | 4 |
| 3 | L6 | A15 first cut, with the contributor section of A28 | 1 |
| 4 | L31 | A46 contributor dev stack, Docker only | 4 |
| 5 | L32 | A35 one gate for push and pull request | 4 |
| 6 | L45 | A49 installer writes no fleet config by default, A50 installer errors a stranger owns | 3 |
| 7 | L55 | A60 trunk ruleset (owner go), A61 contributor rules | 4 |
| 8 | L3, then L8 | A4 the `spool` CLI as a release asset, the installer downloads it | 3 |
| 9 | L26 | A27 membership that expires | 2 |
| 10 | L17 | A5 join tokens (spec first, then hub, WUI, CLI) | 3 |
| 11 | L1 | A3 WUI runtime config | 5 |
| 12 | L25, then L2, then L7 | A21 one hub image, A1 publish to GHCR, compose pulls | 5 |
| 13 | L9 | A2 `spool-up` with preflight | 5 |
| 14 | L30 | A28 final + A29 newcomer test, run to step 5 | all |

### 7.1 All lanes

P2 order inside the waves, from three independent walks (F40): names first (A8, then A7), then the dry run and preflight (A19), then keyless (A18) and one image (A21). A lane on A30 or A31 does not start before the user-story-1 installer lanes (A49, A50; review 09-10).

| wave | lane | task (one) | owns | needs |
|---|---|---|---|---|
| 1 | L1 | A3: WUI runtime config for compose and Hosting (`config.json` read at boot; the build args become lde defaults); one lane with research 06 W1 | `csi-spl-wui/src/docker/wui.Dockerfile`, the WUI boot config | - |
| 2 | L2 | A1a: a CI job publishing the hub and web images to GHCR (public) on `v*` / `stable-*` | a new `.github/workflows/56_*.yml` | L25, D2 answered |
| 1 | L3 | A4a: `spool` CLI release assets on `stable-*` | a job in `55_release-stable.yml` | - |
| 1 | L4 | A8: generic name validations, project id from cnf | the 7 steps' `02-variables.tf`, `gcp-001`, `resolve-oap.func.sh`, conf-validator `EnvModels/cloud.py` | - |
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
| 4 | L19 | A16: P1 stranger test on stables; P2 clean-room estate (one sub-lane per research 20 CR1-CR8; CR1 teardown first) | a results file in this dir; `75_cleanroom-estate.yml`; cleanroom actions | L9, L18, D4 answered |
| 4 | L20 | A15 final: `DEPLOY.md` with every new command and the error index | `DEPLOY.md` | wave 3 |
| 1 | L21 | A19: full dry run + preflight | gcp-000..004, a new `gcp-bootstrap-preflight.func.sh` + tests | - |
| 1 | L22 | A24: deploy workflows name envs and secrets from cnf | the env/secret lines of wf 20 and wf 30 | - |
| 1 | L23 | A25: stale deploy text + pinned yq | the cnf comments, 030 `02-variables.tf`, `build-push-hub-image.func.sh`, wf 20 yq step, the stale 031 rows (wf 20/30, renderer, 019 vars, `specs/README.md:216`) | - |
| 2 | L24 | A18 + A20: keyless bootstrap, project-only key path | `gcp-002-*.func.sh`, `do_tf_init`, `do_gcp_account` + tests | L21 |
| 2 | L25 | A21: one hub image | `build-push-hub-image.func.sh`, the cloud Dockerfile | - |
| 2 | L26 | A27: membership `access_until` | a new migration, the hub auth check, Members pane | - |
| 3 | L27 | A22: `do_hub_deploy` | a new action + test; wf 20 deploy job | L25 |
| 3 | L28 | A23: `do_spl_wui_deploy` | a new action + test; wf 30 deploy job | L1 |
| 3 | L29 | A26: prebuilt WUI bundle as a release asset | a job in `55_release-stable.yml` | L1 |
| 4 | L30 | A28 + A29: contributor page, then the newcomer test | `CONTRIBUTING-WITH-AGENTS.md`; a results file in this dir | L8, L17 |
| 1 | L31 | A46: contributor dev stack (one sub-lane per research 01 action) | `do_setup_app_inf`, `docker-compose.yml` port defaults, a new `do_lde_up` | - |
| 2 | L32 | A35: reusable gate for push and pull request | wf 10, 11, a new reusable workflow | L5 |
| 1 | L33 | A34: estate guard + fork-portability test | the 8 live-estate workflows, a new iac test | - |
| 1 | L34 | A44: cnf derivations, byte-identical (C4, C5 first) | `csi-spl-cnf`, `spl-merged-cnf.func.sh` | - |
| 2 | L35 | A30: secrets check + seed-all | two new actions + tests | - |
| 2 | L36 | A42: state bucket action, reviewed-plan apply, validate-all | `tf-plan`, `tf-apply`, a new action, step 000 | - |
| 2 | L37 | A36 + A37: no-tree compose, stable proven on the client path | `docker-compose.yml`, `pg-init.sh`, wf 55 | L7 |
| 2 | L38 | A40: no-domain docs, plain-http refusal, one name variable | README, hub-init entrypoint, WUI banner | - |
| 2 | L39 | A45: migration lint + schema-head guard | pre-push part, `spool serve` | - |
| 3 | L40 | A31 then A32: WIF first, then least privilege | auth steps of wf 00/20/30/40/45; gcp-003 | A11, D4 |
| 3 | L41 | A38 + A39: signing, client release notes, one version name | wf 55, `SECURITY.md` | L2 |
| 3 | L42 | A47 + A48: compose second workspace, browser -> agent leg | `do_spl_tenant_create`, hub-init | - |
| 4 | L43 | A41: GCP without a custom domain | cnf, 005/025/032 skip | L12 |
| any | L44 | A33, A43: key resolver, relay key actions, AWS leftovers | iac run dir | - |
| 1 | L45 | A49 + A50: installer fleet opt-in, errors and defaults | `spool-install/install.sh` and its tests | - |
| 2 | L46 | A51: fresh-box installer job | a new workflow | L45 |
| 3 | L47 | A52: box enrol for a second machine | a new action + test | L16 |
| 4 | L48 | A53: box bootstrap for any ssh host | `do_box_playbook`, the satellite playbook vars | - |
| 1 | L49 | A55: true release notes + forward-only gate (R2 is a live bug, XS) | `release-stable.func.sh`, a new test | - |
| 2 | L50 | A54: release asset contract + front door on the stable | wf 55, `release-stable.tst.sh`, README, `install.sh --update` | L2, L3 |
| 3 | L51 | A56: CLI/hub version agreement | hub `/version`, `spool` CLI | - |
| 2 | L52 | A57: compose `.env.hub`, Caddy locale root, own-domain wf 50 leg | `docker-compose.yml`, the Caddyfile, wf 50 | - |
| any | L53 | A58: `./run` front door (one sub-lane per item) | the `./run` framework of iac and orc, `spool` usage | - |
| any | L54 | A59: docs that stay true + weekly newcomer walk | READMEs, CONTRIBUTING, a new weekly workflow | - |
| 1 | L55 | A60 + A61: trunk ruleset (owner go), contributor rules | `oss-public-settings.func.sh`, wf 11, CONTRIBUTING, SECURITY.md, `.github/` templates | D16 |
| any | L56 | A62: open-source hygiene (one sub-lane per item) | spec 044 files, wf 11 gate job, licence files, `.github/dependabot.yml` | - |
| 2 | L57 | A63: evaluation mode for a P2 estate | the cnf template mail/payment keys, `DEPLOY.md` | L15 |
| 1 | L58 | A64: digest pins + installer checksums | the 8 Dockerfiles, `install.sh` and its tests | - |
| 1 | L59 | A65 + A66: agent-connect help page, hub tests on a fresh clone | `csi-spl-wui/src/components/ConnectAgentGuide.vue` + its unit test; `doc/help/connect-an-agent.md` + a doc test; the README "another machine" paragraph; `run-all-tests.sh` | - |
| 4 | L60 | A67: `@arg` flags for `./run` actions | the `./run` framework of iac and orc | L53 |

## 8. Decisions needed from the owner

| # | decision | recommendation |
|---|---|---|
| D1 | Is P2 (a company or organisation runs the GCP shape in its own org) a supported path now? Reverses 047 D2 | **ANSWERED yes** (msg `03bc3dab`): any company or organisation spawns its own Google Cloud; AWS later, in its own topic (3.1) |
| D2 | Publish images, and to which registry? | **ANSWERED** (msg `2ff40a49`): "Do not publish images to GCA or GHR if that incurs costs." Per the vendor pages (read 2026-10-04, table below), **GHCR public packages are free to us and to downloaders**; Artifact Registry is not. So A1 publishes to GHCR as **public** packages only, and the CLI binaries and the WUI bundle go out as GitHub release assets. **Fallback**: GitHub promises a month's notice before any change; on such a notice A1 stops publishing and compose builds locally (today's path, which works) |
| D3 | Build agent join tokens (037 T005)? | **ANSWERED yes** (msg `97f2df08`), with the contributor persona P3+ (3.2): their own machine, their own AI-vendor tokens, no GCP. A5, A27-A29 |
| D4 | One throwaway GCP project and its billing for the P2 stranger test (A16) | **ANSWERED yes** (msg `af863518`): "you can use one throwaway Google project"; no separate infrastructure project is needed (research 20) |

Registry costs, from the vendors' own pages, read 2026-10-04 (n = 1 read each):

| registry / carrier | storage | download (egress) | anonymous pull | source |
|---|---|---|---|---|
| GHCR, public package | free | free | yes: an anonymous token pulled `ghcr.io/v2/homebrew/core/wget/tags/list` -> HTTP 200 | <https://docs.github.com/en/billing/concepts/product-billing/github-packages>: "GitHub Packages usage is free for public packages"; "Container image storage and bandwidth for the Container registry is currently free", with "at least one month in advance" notice of a change |
| GitHub release assets | free, each file < 2 GiB | no bandwidth limit | yes | <https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases>: "There is no limit on the total size of a release, nor bandwidth usage" |
| Google Artifact Registry | 0.5 GiB free per billing account, then $0.000136986 per GiB-hour (~$0.10 per GiB-month) | internet egress billed to the repository owner at Premium tier | only if made public, and then we pay the egress | <https://cloud.google.com/artifact-registry/pricing> |

A P2 estate still needs an Artifact Registry of its own (Cloud Run deploys from it; research 05 H6 believes, unchecked, that Cloud Run cannot pull GHCR directly). That registry is **the deployer's** cost in **their** project, not ours, and 028's cleanup policy bounds it.

Open questions from the research, each with the contributor's recommendation (not yet asked of the owner):

| # | question | recommendation | from |
|---|---|---|---|
| D5 | Keyless bootstrap (impersonation) by default for outsiders, the JSON key opt-in (A18)? | yes | research/02 Q1 |
| D6 | When a key is used, change only the project, never the org policy or org IAM (A20)? | yes | research/02 Q2 |
| D7 | Support a GCP project with no org, for a solo developer (A10)? | yes, with the losses printed | research/02 Q3 |
| D8 | One hub image for compose, Cloud Run and the release (A21)? | yes | research/05 Q3 |
| D9 | The WUI reads a served `config.json` (one ~1 KB request before mount) instead of baked values (A3)? | yes | research/06 Q1 |
| D10 | CI keyless by WIF while the project key stays on the box (the 2026-09-19 rule holds); drop the GitHub key secret once WIF is green (A31)? | yes | research/09 Q1 |
| D11 | Narrow the project SA from `roles/owner` to the measured list (A32)? | yes, proven first in the D4 project | research/09 Q2 |
| D12 | A contributor's pull request runs the full gate (A35), still behind "approve outside contributors"? | yes | research/12 Q2 |
| D13 | One throwaway fork under a second GitHub account to measure fork CI once (research 12 C5)? Outward-facing | yes, once, deleted after | research/12 Q3 |
| D14 | Security fixes go to the latest stable, with a same-day stable for a fix, never "rebuild from master" (A39)? | yes | research/15 Q2 |
| D15 | Is plain `http://<ip>` supported? | no: refused with the two fixes named (A40) | research/08 Q1 |
| D16 | Set a ruleset on the public trunk (no force-push or deletion, wf 11 required, one maintainer review on a pull request, the fleet's push identity bypasses; A60)? Outward-facing repo setting | yes, before the first contributor is invited | research/14 |

### 8.1 The question list sent to the owner (msg `85a28d38`)

The open questions of this section and of the research files, merged, answered ones dropped, the odometer question left out (asked separately). Each maps to its source: Q1 D16; Q2 research 14 O4 + 18 Q2; Q3 D12; Q4 research 10 Q1 (A49); Q5 D5 + D6; Q6 D10 + D11; Q7 D15; Q8 research 17 Q1; Q9 research 17 Q3; Q10 D7; Q11 research 13 Q3, Q4; Q12 research 16 Q1, Q2; Q13 D14 + research 16 Q3; Q14 research 20 Q2, Q3; Q15 D13. Answers are recorded in the table above as they come.

> **Spec 072: 15 questions to finish the spec** (owner msg `85a28d38`). Reply with the number and a letter, e.g. "1a 2b". **(a) is the recommendation every time.** Already answered and not asked again: own GCP for any organisation, the registry cost rule, join tokens, the contributor deal, the cloud-layer decisions, and the one throwaway project.
>
> **Contributors and access**
> 1. Before the first outside contributor, lock the public trunk: no force-push or deletion, checks required, a maintainer reviews every pull request, our agents still push directly? a) yes, now · b) later · c) no
> 2. Should outside contributors sign off their commits (DCO)? a) yes, and a check enforces it · b) drop the rule
> 3. Should a contributor's pull request run the full test gate before merge? a) yes · b) only hub and web tests, as today
> 4. Should the agent installer write our fleet's own Claude Code settings only when asked (`--fleet`), instead of on everyone's machine? a) yes · b) no
>
> **Security and keys**
> 5. Should a new organisation set up its Google Cloud without downloadable keys, and never change org-wide policy? a) yes, both · b) no downloadable keys, but org policy may change · c) keep today's way
> 6. Should CI sign in to Google without a stored key, and then lose the "owner" role in favour of only the rights it needs? a) yes, both · b) keyless only · c) neither
> 7. Should a self-hosted instance on a bare `http://<ip>` address be supported? a) no: refuse it and name the two fixes (own domain, SSH tunnel) · b) yes
>
> **What a self-hoster gets**
> 8. Is the one-machine Docker install a supported production setup, not just a trial? a) supported production · b) trial only
> 9. Should Google/social sign-in and payments work in a self-hosted install? a) yes, both off until configured · b) only on our hosted service
> 10. Should someone with a personal Google account and no organisation be able to deploy? a) yes, with a printed list of what they lose · b) no
> 11. In the open-source defaults, should a workspace live on the main address, with one workspace per install? a) yes · b) no, one sub-domain per workspace, as hosted
>
> **Releases**
> 12. Is the weekly `stable-<date>` the only release outsiders should pin, with images published for every build and the CLI only for stables? a) yes · b) images for stables only, too
>    (Dissent for the record: review 15-16 recommends images for stables only; the recommendation above keeps (a) so a fork's P2 estate can roll exactly what we roll.)
> 13. Who gets security fixes? a) the latest stable, plus a same-day stable for a fix, with upgrades tested from the last 4 stables · b) the latest stable only · c) master only, as today
>
> **Testing the from-zero path**
> 14. Should a clean-room deploy run in the one throwaway project every night and before every stable (~$2/month, capped at $9), with a red run blocking only the weekly stable? a) yes · b) only before a stable · c) not yet
> 15. May a lane create one public test fork under a second GitHub account to prove that a fork's CI works, deleted after? a) yes, once · b) no
>
> About your question on a separate infrastructure project (`af863518`): none is needed. The one throwaway project holds its own CI identity (research 20).
>
> Unless you object, these engineering choices follow the recommendations: one hub image, a web config read at runtime, config derived from org/app/env, and a full dry run plus preflight before any Google change.

### 8.2 The second question list

From the walks and reviews merged after 8.1. Sources: Q16 A63 (research a2 Q4); Q17 F46 (review 15-16); Q18 A16 (review 19-20); Q19 research 11 Q1; Q20 research 07 Q1; Q21 research 18 Q3 (A58).

> **Spec 072: second, shorter question list** (from the last research walks and the 10 second-opinion reviews). Reply with the number and a letter, e.g. "16a 17a". **(a) is the recommendation.** Questions 1-15 (sent earlier) are still open.
>
> 16. When someone tries the Google Cloud setup, should it work with no mail server and no Stripe at first (sign-in links go to the cloud log)? a) yes · b) no, require a mail server
> 17. Should the README quick start keep using the latest code until the weekly stable has passed its own from-zero and upgrade test? The stable is 35 database changes behind. a) yes, switch after the test is green · b) switch to the stable now
> 18. Should the nightly test start from an emptied project, plus a full from-scratch run once a month (create project, link billing)? a) yes · b) nightly only · c) monthly only
> 19. Is "an outsider runs agents on several machines" part of this spec's first version? a) yes, after the single-machine paths work · b) now · c) later spec
> 20. Should a self-hosted install be able to use an external, managed Postgres instead of the bundled one? a) yes, after backups and upgrades work · b) no
> 21. Should `./run --help` show about 15 "start here" actions, with the full list of ~330 behind `--all`? a) yes · b) no, keep one list

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
| v0.2 | owner D1 = yes; section 3.1 (one cloud now, one seam for AWS later) | c-165 |
| v0.3 | owner D2 (zero-cost registry: GHCR public + release assets), D3 = yes with the contributor persona, the guest rule (3.2, R1-R3); research 02 (c-167), 05 (c-160), 06 (c-169): F10-F19, G19-G25, A18-A29, L21-L30, D5-D9; the owner's user story 1 (2.1, msg `699f38b0`) and the plan order that serves it first (7.0) | c-165 |
| v0.4 | research 01 (c-158), 03, 04 (c-168), 07 (c-161), 08 (c-170), 09 (c-162), 12 (c-172), 13 (c-164), 15: F20-F31, G26-G34, A30-A48 (6.2), lanes L31-L44, US1 order widened (7.0), D10-D15; out-of-scope items handed on | c-165 |
| v0.5 | owner `d7e415ed`: the cloud layer leaves this spec (3.1 is a pointer); research 10 (c-171), 11 (c-163), 16 (c-174), 17 (c-166), 18, 19 (c-167): 14 (c-173): A49-A62, lanes L45-L56, D16, A49 and A60-A61 join the user-story-1 order; S3 store and fleet-ops items parked | c-165 |
| v0.6 | owner `fe7fd2b9`: the four cloud-layer decisions recorded in 3.1 (scope, factory shape, self-host first then AWS, GCP default); P1 first now cites it | c-165 |
| v0.7 | owner D4 answered (`af863518`); 8.1 the 15-question list for the owner (`85a28d38`) | c-165 |
| v0.8 | research 20 (c-176): A16 becomes the clean-room estate in the one throwaway project (CR1-CR8) | c-165 |
| v0.9 | research a2 (a-184, client walk): F32 (lexical step order), A63 (evaluate without a mail relay), lane L57; the rest confirms existing actions | c-165 |
| v0.10 | research a3 (a-185, security of deploy): F33, F34 (a correction: rate limits exist), A64 digest pins + installer checksums, A35 adds the security scanners, lane L58 | c-165 |
| v0.11 | research a1 (a-183, newcomer walk): F35, F36, A65 (true agent-connect help), A66 (hub tests on a fresh clone), both in the user-story-1 order | c-165 |
| v0.12 | research a4 (a-186, DevEx critique): F37 (most of A-DEV1's delete list is live), A43 narrowed (AWS items wait for topic `a5a141bc`, per c-001), A67 `@arg` flags; 3.1 names topic `a5a141bc`; all 4 cross-cutting walks merged | c-165 |
| v0.13 | the 10 grok second opinions (g-168, g-169, g-170, g-171, g-172, g-177, g-178, g-179, g-180, g-182): F38-F46 (incl. the live connect-guide bug, reported), line corrections, 22 actions widened, P2 order "names first", Q12 dissent; all 34 research files merged | c-165 |
| v0.14 | 8.2 the second, shorter owner question list (Q16-Q21) | c-165 |
| v0.15 | 7.0 renumbered 1-14 (one row per lane, L59 once); `tasks.md` generated from sections 7.0 and 7.1 | c-165 |
| v0.16 | review 03-04 follow-up (g-169): A8 includes the conf-validator realm rule (`cloud.py:64`), A25 the stale 031 row in the spec index; L4, L23 own them | c-165 |
| v0.17 | reviews 17-18 (g-182) N3, N4 and 11-12 (g-171) R2 detail: A65, A59, A34 widened | c-165 |
| v0.18 | F38 fixed (`496bfb803`); tasks.md T001 split: T001a done, T001b open | c-165 |
