# 072: rapid deployability of the whole spool system

Status: **draft v0.4** (v0.4: research 01, 03, 04, 07, 08, 09, 12, 13, 15
merged; v0.3: owner D2/D3, the guest rule, user story 1; v0.2: owner D1).
The remaining research files of section 9 are merged into later versions.
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
(section 2, measure 1). A hosted, bought tenant (047 path B) is not a
deployment and is not in scope.

### 3.1 One cloud now, one seam for the next

Owner, HUM-10, topic `6410e374`, msg `03bc3dab`, verbatim:

> "Yes any company or organization should be able to spawn their own Google
> Cloud. Later on we will add support for AWS as well."

So P2 is a supported path for any company or organisation, and **AWS is a
stated later goal, out of scope for v1 of this spec**. To keep AWS a new
backend rather than a rewrite, the P2 actions follow one rule:

- **The cloud-specific steps sit behind one seam.** The entry points stay
  cloud-neutral (`do_spl_cnf_init`, `do_spl_estate_up`, the preflight). A cnf
  key `env.cloud` (only `gcp` in v1) picks the backend, and the backend owns
  everything provider-named: the project bootstrap (gcp-000..004), the
  terraform step list, the identity (service-account keys, WIF) and the WUI
  host (Firebase).
- **What crosses the seam is a contract, not GCP names**: the hub image, its
  env vars (a Postgres DSN, a bucket for files, a mail relay), the public URL
  and the secrets list. P1 compose already runs on that contract with no
  cloud at all (047 1.1), which is the evidence that the hub is
  cloud-neutral.
- An action that adds a GCP-only step to an entry point instead of to the
  backend is a review finding against this section.

A7, A9 and A12 (section 6) carry this rule in their acceptance checks.

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
| F10 | gcp-000 forces the cnf org, so a folder never works through the one-command path | research/02 B3 | `gcp-000-bootstrap-gcp-env.func.sh:21-23`; gcp-001 `not both` at :85-86 |
| F11 | When the env leaves them unset, our org id and owner login are the silent defaults: an outsider who forgets `GCP_ACCOUNT` aims at our org | research/02 B4 | `csi-spl-cnf/csi-spl/all.env.yaml:26-27`; `gcp-account-pin.func.sh:185-192` |
| F12 | gcp-002 rewrites the **org-level** key-creation policy and leaves a permanent org policyAdmin grant | research/02 B6 | `grep -c remove-iam-policy-binding csi-spl-iac/src/bash/run/gcp-002-create-project-service-account.func.sh` -> 0 |
| F13 | The dry run stops at gcp-003 on a new project; "(or it may not exist)" reads a taken project id as free | research/02 B2, B7 | `gcp-003-...:223-229`; `grep -c 'it may not exist' gcp-001-create-project.func.sh` -> 1 |
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
| **A2** | `spool-up`: one script (also `./run -a do_spl_self_host_up`) that asks ~5 questions (domain, owner email, SMTP), writes `.env` with generated passwords, **preflights** the DNS A record, ports 80/443, the SMTP login and Docker, then `up --wait` and prints the owner link | P1 | orc + docs | S-M | fresh VM: one command plus the answers -> the owner link is printed; each preflight failure names its fix (control: a wrong A record fails before `up`) |
| **A3** | The WUI reads its env values at runtime from a served `/config.json` (api and auth base, tenant, site URL, tenant hosts, env name, locale, lobby task id), for **both** carriers: compose writes it from `.env` at container start, the Hosting deploy (A23) writes it per env. Build-time values stay only as lde defaults; the build stops reading our cnf path (06 W1, W8) | P1, P2 | WUI | M | one `nuxt generate` with no `NUXT_PUBLIC_*` set, served with two different `config.json`s, calls two different api hosts; `grep -c 'ARG SPOOL_PUBLIC_URL' csi-spl-wui/src/docker/wui.Dockerfile` -> 0; `grep -c NUXT_PUBLIC_API_BASE .github/workflows/30_wui-build-deploy.yml` -> 0 (today 2) |
| **A4** | Prebuilt `spool` CLI per release (linux and darwin, amd64 and arm64) as release assets; `install.sh` downloads it and checks the sha256, builds only as a fallback, and runs without a clone | P3 | CI + orc | S-M | a box with no Go and no clone: the pasted line seats an agent; `grep -c 'releases/download' install.sh` >= 1 |
| **A5** | Agent join tokens (037 T005, 047 B2; owner D3 = yes): a tenant admin mints a short-lived, **per-seat** token in Tenant settings -> Agents; `spool join <url> <token>` seats the box; each seat is revocable on its own; the root key never leaves the owner (rules R1, R2 in 3.2) | P3 | api + WUI + orc | M-L | from the WUI alone, an agent is seated in **< 1 min**; a used or expired token is refused naming the fix; revoking one seat leaves the others seated |
| **A6** | `do_spl_self_host_backup` / `_restore` / `_upgrade` (research 07 D1, 15 C7): the README lines as actions (db name from `.env`, a 0700 dir, `KEEP=<n>`, an optional off-machine copy hook); upgrade = backup, fetch the newest `stable-*`, pull, `up --wait`, compare `/version`; on failure print the restore line | P1 | orc + docs | S | an upgrade from the previous stable to the current one in one command; `/version` = the new tag |
| **A7** | An 8-key `estate.yaml` (org, app, base domain, GitHub repository, bootstrap account, org/folder/none, mail, env names; billing stays an env var) plus `do_spl_cnf_init`, after the derivations of A44 (research 04 C6, C7, 03 A8); tenant hosts off in the template (08 D5, 13 N4); the validator names each missing key; the answers render a new estate's cnf that conf-validator accepts | P2 | cnf + iac | M | `do_spl_cnf_init` with sample answers, then `ENV=<env> ./run -a do_tpl_gen` renders every step's tfvars with 0 references to our domain or project ids; the template has `env.cloud: gcp` and no GCP name outside the backend's block (3.1) |
| **A8** | Estate names and env names from cnf only: the 9 `regex("^csi-spl` validations become each resource's own id rule (019 names the Hosting site's global-uniqueness trap); the project id is cnf `env.gcp.gcp_project`, not the directory name, in the bootstrap (02 G1), `do_spl_cloud_cnf` (05 H4) and the key path; the env names are the `*.env.yaml` files the cnf holds, in terraform, gcp-001, the firebase.json renderer and the DNS action (02 G8, 06 W6) | P2 | iac + orc | S-M | `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> 0; a fixture cnf with `gcp_project: acme-spool-dev-7f3a` under a directory named `csi-spl-iac` plans `projects create acme-spool-dev-7f3a`; a fixture `stg.env.yaml` makes `ENV=stg` plan |
| **A9** | `do_spl_estate_up ENV=<env>`: gcp-000 -> the infra stack -> every enabled step in the cnf `steps_order` (dependency-checked: 025<005, 028<030, 040<030, 050<030; research 03 A2), with named hooks between steps (image push, `do_spl_db_bootstrap` after 040, secrets A30, domain verify, cert wait; 07 D7), then the first tenant and its owner invite in one action (07 D6) through the sweep's gate -> the seeds -> the GitHub vars (A11) -> the first deploy; **resumable** (skips what exists), dry run by default, every stop names the step and the fix | P2 | iac + orc | M | in a throwaway project, one command per env reaches a healthy `/v1/health` and the WUI; a second run changes nothing and says so; the action dispatches on `env.cloud` and `env.cloud: aws` exits with "not supported yet", naming 3.1 (control for the seam) |
| **A10** | Org optional end to end: with no org and no folder, gcp-001 creates a project with no parent, gcp-002 skips the policy step, and gcp-000 prints what that loses; gcp-000 sets `GCP_ORG_ID` from cnf only when `GCP_FOLDER_ID` is empty, so a folder works (02 G2, G7) | P2 | iac | S | `ENV=<env> DRY_RUN=1 ./run -a do_gcp_000_bootstrap_gcp_env` with neither set -> a 4-step plan and one `INFO no org: ...` line; with a folder only -> `--folder=<id>`, no `not both` stop |
| **A11** | `do_spl_gh_wire`: writes step 017's outputs into the 6 GitHub repo variables | P2 | iac | XS-S | after it, `gh variable list` shows the 6 `vars.*` that wf 20 and 30 read |
| **A12** | Mark our-only steps optional in cnf (satellite 059/060, off-project backups 046, domain verification 005); the sweep skips a step marked off | P2 | cnf + iac | S | with them off, the sweep plans 0 resources for them; the step list lives in the gcp backend's cnf block, not in the entry point (3.1) |
| **A13** | The CI runner is a repo variable: every `runs-on` in wf 10 and 99 reads `vars.SPOOL_CI_RUNNER`, else `ubuntu-latest`; this repo sets the variable through a named action, not by hand (research 12 C1) | P2, contributors | CI | S | a fork's push runs wf 10 to a verdict; on this repo nothing changes |
| **A14** | A slim infra stack: tpl-gen without a token (vendored, or fetched by a public ref); `GITHUB_TOKEN` optional except for step 120; the key dir mounted read-only, no `~/.aws` / `~/.ssh` mounts (research 03 A5) | P2 | orc | S | `make do-setup-tpl-gen` with no `GITHUB_TOKEN` succeeds |
| **A15** | One page, `DEPLOY.md` at the repo root: which path (P1, P2, P3, or a hosted tenant), how long each takes, the one command each, and an error index (message -> fix) | all | docs | S | linked from the top of README; every command on it has a passing acceptance check in this table |
| **A16** | Timed stranger tests: P2 from `DEPLOY.md` alone in a throwaway GCP project, and P1 on every `stable-*` (047 metric 5) | P1, P2 | any lane + owner (billing) | M | a posted run with the tree, n, and the minutes per step |
| **A17** | `do_spl_box_deploy` and `do_spl_pool_ctl` accept the env names the cnf declares, and `ENV=self` with a hub URL | P3 | orc | S | `ENV=self SPOOL_HUB_URL=<url> BOX_DEPLOY_CMD=check ./run -a do_spl_box_deploy` -> a verdict, not a refusal |
| **A18** | **Keyless bootstrap by default** (`BOOTSTRAP_AUTH=impersonate`): gcp-002 creates the SA and grants the human `roles/iam.serviceAccountTokenCreator` on it, with no JSON key and no org-policy change; `do_tf_init` and `do_gcp_account` impersonate when no key file exists, and refuse with one line naming both routes when neither is there (research 03 A4); `BOOTSTRAP_AUTH=key` keeps today's path (02 G5) | P2 | iac | M | in impersonate mode a stubbed-gcloud log shows 0 `org-policies` and 0 `keys create` calls, and terraform gets `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`; the key-mode test stays green |
| **A19** | **A full, honest dry run plus a read-only preflight** (`do_gcp_bootstrap_preflight`): gcp-003/004 plan against a planned SA instead of stopping; a project that reads "(or it may not exist)" counts as **taken**; `testIamPermissions` on the parent and the billing account; every input says where it came from (env or cnf) (02 G3, G4) | P2 | iac | S | stub walk -> 4 `OK DRY_RUN` lines, exit 0; a denied permission -> a refusal naming the role and scope; a cnf-sourced org prints `org: <id> (from cnf ...)` |
| **A20** | **The key path, when chosen, changes only the project**: the key policy is set on `projects/<id>`, the org's previous policy is untouched, the temporary policyAdmin grant is removed, the member prefix follows the account type (02 G6) | P2 | iac | S | stub log: `set-policy` targets only `projects/<id>`; a `remove-iam-policy-binding` follows every `add`; `grep -c remove-iam-policy-binding gcp-002-create-project-service-account.func.sh` >= 1 (today 0) |
| **A21** | **One hub image** for compose, Cloud Run and the release: `do_build_push_hub_image` builds `csi-spl-api/src/docker/hub.Dockerfile` with the minted `SPOOL_VERSION`; the distroless cloud Dockerfile and the host Go build go (05 H2) | P1, P2 | api + orc | S-M | `ls csi-spl-orc/src/docker/spool-hub-api/Dockerfile` -> absent; `check-hub-deploy.tst.sh` green; dev `/version` = the minted tag after one wf 20 run |
| **A22** | **`do_hub_deploy ENV=<env>`**: mint, build or promote and push, `do_spl_db_bootstrap`, roll, `do_check_hub_deploy`; dry run by default; wf 20 calls it (05 H3) | P2 | orc | S | `grep -c 'run services update' .github/workflows/20_*.yml` -> 0; `ENV=dev ./run -a do_hub_deploy` (dry) prints 5 steps and the image ref |
| **A23** | **`do_spl_wui_deploy ENV=<env>`**: generate (or take the prebuilt bundle, A26), write `config.json` + `build.json`, render firebase.json, `firebase deploy` as the env identity, probe; wf 30 calls it; on a new custom domain it prints the expected 10-60 min certificate wait and the `<site>.web.app` URL meanwhile (06 W3, W7) | P2 | orc | S-M | `DRY_RUN=1 ENV=dev ./run -a do_spl_wui_deploy` prints the steps, the target site and, for a new domain, the wait line; a test stubs `firebase` |
| **A24** | **Deploy workflows name envs and secrets from cnf**: wf 20 and 30 build the env matrix from the cnf env files and the auth secret as `GCP_KEY_<ORG>_<APP>_<ENV>` (what step 120 writes); an env that should deploy and has no auth **fails** instead of a green `::notice:: skipped` (05 H5, 06 W4) | P2 | CI | S | `grep -c CSI_SPL .github/workflows/20_*.yml .github/workflows/30_*.yml` -> 0, 0 (today 12, 8); `grep -cF "'DEV' \|\| 'PRD'"` on both -> 0 |
| **A25** | **Fix the stale deploy text and pin the deploy tools**: the cnf, step 030 and `build-push-hub-image.func.sh` still teach "bump hub.image.tag, then apply"; wf 20 installs `yq` from `releases/latest` (05 H7, H8) | P2 | docs + CI | XS | `grep -rn 'bump hub.image.tag' csi-spl-cnf csi-spl-iac/src/terraform/030* csi-spl-orc/src/bash/run/build-push-hub-image.func.sh` -> 0; `grep -c 'releases/latest' .github/workflows/20_*.yml` -> 0 |
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
| **A33** | One key resolver `do_gcp_key_path` honouring `GCP_KEY_DIR`; the relay key mint and rotate become actions (feature doc 6.3 today); secret names org-neutral | 09 K4-K6 | P2 | iac | S each | `grep -rlE '\.gcp/\.' csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| wc -l` -> 0 outside the resolver |
| **A34** | Estate guard: every live-estate workflow (00, 21, 22, 31, 40, 45, 55, 68) runs only when `vars.SPOOL_ESTATE == 'true'`, set on this repo by the A13 action; a static fork-portability test keeps it so | 12 C2, C4 | us, P3+ | CI | S | `ci-estate-guard.tst.sh` red when a cron or cnf-host workflow lacks the guard; a fork shows them as skipped |
| **A35** | One gate for push and pull request: wf 10's suites move into a reusable workflow that wf 10 (push) and wf 11 (pull request, fork branches) both call, so a contributor gets iac, orc, cnf and hygiene before merge | 12 C3 | P3+ | CI | M | a pull request's checks list iac, orc, cnf and hygiene; wf 10 and 11 job sets are equal; actionlint green |
| **A36** | Compose runs with no tree: `pg-init.sh` moves into the hub image (or an inline `configs:` entry), the bind mount goes | 15 C2 | P1 | api + orc | S | in an empty dir with only the release compose + `.env`: `docker compose up -d --wait` healthy |
| **A37** | Prove the stable on the client path before cutting it: wf 55 runs the wf 50 stranger job on the candidate with the pulled images and the release compose, plus a previous-stable -> candidate upgrade and a backup-restore drill; red cuts nothing | 15 C4, 07 D2 | P1 | CI | S | a planted break on a throwaway branch makes wf 55 cut no tag |
| **A38** | Sign what we ship: keyless `cosign` of both image digests and `SHA256SUMS` from the release job (GitHub OIDC, no key stored); one verify line in `DEPLOY.md` | 15 C6 | P1, P3 | CI | S | `cosign verify ghcr.io/<owner>/spool-hub@<digest> --certificate-identity-regexp ...` exits 0 in CI |
| **A39** | A release a client can act on: notes open with "Before you upgrade" (`.env` keys changed, migrations, the upgrade command); `/version`, the footer and `spool version` print `stable-<date> (v<X.Y.Z>)`; `SECURITY.md` names the latest stable, with a same-day stable for a security fix | 15 C8-C10 | P1 | CI + docs | S each | a fixture range that changes `.env.example` lists each key under "Before you upgrade"; `grep -c 'rebuild from it' SECURITY.md` -> 0 |
| **A40** | No-domain and plain-http shapes made clear: README "No domain yet" (localhost, `ssh -L`); hub-init refuses `http://<non-loopback>` naming both fixes, the WUI shows a banner without a secure context; `SPOOL_SITE_ADDRESS`, `SPOOL_DOMAIN` and the cookie flag derive from `SPOOL_PUBLIC_URL` | 08 D1-D3 | P1 | api + WUI + docs | XS-S each | compose with `SPOOL_PUBLIC_URL=http://203.0.113.5:8080` -> hub-init exits non-zero naming both fixes; localhost -> 0 (control); `grep -c 'ssh -L' README.md` >= 1 |
| **A41** | GCP without a custom domain: an empty `BASE_DOMAIN` serves the WUI on the Firebase default host and the hub on its Cloud Run URL, and turns 005/025/032 off | 08 D6 | P2 | iac + cnf | M | `do_tpl_gen` renders with `BASE_DOMAIN: ""`; the sweep plans 0 resources in 005/025/032 |
| **A42** | Terraform you can trust: `do_gcp_state_bucket_create` (000 imports the bucket; the host-terraform procedure goes); `do_provision` applies the saved, reviewed plan with the lock on and refuses a stale one; `do_tf_validate_all` validates all 18 steps in a minute with no key | 03 A1, A3, A7 | P2 | iac | S-M | `grep -c 'lock=false' tf-plan.func.sh tf-apply.func.sh` -> 0; a stub terraform receives the plan path; a fresh HOME with no key prints 18 validates |
| **A43** | Remove the AWS-era leftovers and the other organisation's name from the terraform comments | 03 A9, A10 | P2 | iac | XS | `git grep -cE 'terrafom\|AWS_PROFILE' -- csi-spl-iac/src/bash/run csi-spl-orc/src/make` -> 0 |
| **A44** | Derive the cnf: names, secret slot ids and host values from `{org}`, `{app}`, `{env}`, `{fqdn}`; one key per fact; the 96 identical keys into `all.env.yaml`; region and key-dir literals out of code; a single-source test keeps it. Every step renders **byte-identical**, so it needs no plan, no apply and no owner go | 04 C1-C5, C8-C10 | P2 | cnf + iac | M | `ENV=dev ./run -a do_tpl_gen && ENV=prd ./run -a do_tpl_gen && git diff --exit-code csi-spl-cnf/csi-spl/*/tf` exits 0 after each lane |
| **A45** | Schema guards: a migration lint in pre-push (unique prefixes, no edited applied file); `spool serve` refuses to start on a schema behind its image, naming the migrate command; `/version` shows the schema head | 07 D3, D4 | P1, P2 | rdb + api | XS + S | a copied `0112_x.sql` turns the lint red; a postgres test with the last migration row deleted -> serve exits non-zero with that message |
| **A46** | The contributor's dev stack in one command, Docker only: the lde hub builds in Docker from `hub.Dockerfile` (no host Go); lde stops provisioning the box spool root; `SPOOL_PUBLIC_URL` follows `SPOOL_HTTP_PORT`; a per-clone compose project; `./run -a do_lde_up` / `do_lde_down`; a "Develop locally" section; a hosted CI job proves it on a clean clone | 01 A1-A7 | P3+ (US1 step 4) | orc + docs + CI | S each | `env -i HOME=$(mktemp -d) PATH=<no go> ./run -a do_setup_app_inf` on a fresh clone -> exit 0; `do_lde_up` -> `:58080/healthz` and `:3000/` both 200 |
| **A47** | A second workspace on compose in one command (`ENV=self ./run -a do_spl_tenant_create`), printing the owner invite link and where the root key went; and a self-service root-key re-key in Tenant settings for a `biz_owner` | 13 N5, N7 | P1 | orc + api + WUI | S, M | on the compose stack one command -> a second tenant whose owner signs in; an e2e re-keys and seats an agent with the new key |
| **A48** | Measure the compose browser -> agent leg on a fresh `up`, and fix it if a WUI post reaches no agent (hub-init pins box-wui under a generated key) | 13 N3 | P1 | orc + api | XS to measure, S to fix | a compose e2e: a #lobby post from the WUI reaches a seated agent; control: unpin -> `wui_unpinned` |

Also from the research, folded into existing rows rather than new ones: 02 G1-G9 -> A8, A10, A18-A20, A9; 03 A2, A4-A6, A8 -> A9, A18, A14, A8, A7; 04 C6-C7 -> A7; 05 H2-H8 -> A21-A25; 06 W1-W8 -> A3, A8, A23, A24, A26; 07 D1, D5-D8 -> A6, A8, A9, A25; 08 D4, D5 -> A2, A7; 09 K9, K10 -> A2, A15; 12 C5-C7 -> A16, A24, A15; 13 N4, N6 -> A7, A16; 15 C3, C5, C7 -> A3, A4, A6.

**Not in this spec's scope (hosted path B), handed to the orchestrator for their owners:** research 13 N1 (the owner enables workflow 40) and N2 (pin box-wui when a bought tenant is claimed); research 08 D7 (a check that workflow headers match GitHub's enabled state); research 05 H1 (the version odometer at `9.9.9`).

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
| 1 | L5, then L33 | A13 fork CI on GitHub-hosted runners, then A34 estate guard (a fork never touches our estate) | 4 |
| 2 | L6 | A15 first cut, with the contributor section of A28 | 1 |
| 2a | L31 | A46 contributor dev stack, Docker only | 4 |
| 2b | L32 | A35 one gate for push and pull request | 4 |
| 3 | L3, then L8 | A4 the `spool` CLI as a release asset, the installer downloads it | 3 |
| 4 | L26 | A27 membership that expires | 2 |
| 5 | L17 | A5 join tokens (spec first, then hub, WUI, CLI) | 3 |
| 6 | L1 | A3 WUI runtime config | 5 |
| 7 | L25, then L2, then L7 | A21 one hub image, A1 publish to GHCR, compose pulls | 5 |
| 8 | L9 | A2 `spool-up` with preflight | 5 |
| 9 | L30 | A28 final + A29 newcomer test, run to step 5 | all |

### 7.1 All lanes

| wave | lane | task (one) | owns | needs |
|---|---|---|---|---|
| 1 | L1 | A3: WUI runtime config for compose and Hosting (`config.json` read at boot; the build args become lde defaults); one lane with research 06 W1 | `csi-spl-wui/src/docker/wui.Dockerfile`, the WUI boot config | - |
| 2 | L2 | A1a: a CI job publishing the hub and web images to GHCR (public) on `v*` / `stable-*` | a new `.github/workflows/56_*.yml` | L25, D2 answered |
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
| 1 | L21 | A19: full dry run + preflight | gcp-000..004, a new `gcp-bootstrap-preflight.func.sh` + tests | - |
| 1 | L22 | A24: deploy workflows name envs and secrets from cnf | the env/secret lines of wf 20 and wf 30 | - |
| 1 | L23 | A25: stale deploy text + pinned yq | the cnf comments, 030 `02-variables.tf`, `build-push-hub-image.func.sh`, wf 20 yq step | - |
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

## 8. Decisions needed from the owner

| # | decision | recommendation |
|---|---|---|
| D1 | Is P2 (a company or organisation runs the GCP shape in its own org) a supported path now? Reverses 047 D2 | **ANSWERED yes** (msg `03bc3dab`): any company or organisation spawns its own Google Cloud; AWS later, behind the seam of 3.1 |
| D2 | Publish images, and to which registry? | **ANSWERED** (msg `2ff40a49`): "Do not publish images to GCA or GHR if that incurs costs." Per the vendor pages (read 2026-10-04, table below), **GHCR public packages are free to us and to downloaders**; Artifact Registry is not. So A1 publishes to GHCR as **public** packages only, and the CLI binaries and the WUI bundle go out as GitHub release assets. **Fallback**: GitHub promises a month's notice before any change; on such a notice A1 stops publishing and compose builds locally (today's path, which works) |
| D3 | Build agent join tokens (037 T005)? | **ANSWERED yes** (msg `97f2df08`), with the contributor persona P3+ (3.2): their own machine, their own AI-vendor tokens, no GCP. A5, A27-A29 |
| D4 | One throwaway GCP project and its billing for the P2 stranger test (A16) | **yes**, deleted after the run |

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
