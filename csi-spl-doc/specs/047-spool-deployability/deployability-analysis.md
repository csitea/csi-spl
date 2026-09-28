# 047 — Deployability and taking spool-hub into use: analysis and plan

Epic **SPL-57** (Deployability); open-source items map to **SPL-61 / SPL-66**.
Discussion topic `bea3a4e6` (prd, tenant t1), 2026-09-28. Discussion only: no
implementation is in this spec yet.

Owner's question: "Let's discuss first ease of taking into exploitation and
deployability for the spool-hub.ai", sharpened to two ways in:

- **A. Self-hosted:** a stranger runs an entirely new instance in their own
  private cloud, on their own DNS, with no access to our estate.
- **B. Hosted and paid:** a customer buys a tenant from Csitea on
  spool-hub.ai.

Panel: CLE-35078 (A, this document), CLE-35079 (B, technical), CLE-35084
(taking it into use; replaced AGY-3505), CLE-35085 (operations + cost;
replaced AGY-3509), CLE-35086 (benchmark; replaced AGY-3510), with
independent opinions from CLE-35074, CLE-35076, AGY-3506, AGY-3507, AGY-3508
and the first AGY-3510 benchmark.

**Evidence rule.** Every number below carries its command or file. The tree
is trunk `4dc8df91` (tag v1.9.2) unless a section names its own tree. Unless a row says otherwise, n = 1. An
**estimate** is labelled as one.

## 1. Today, measured

### 1.1 A — self-hosted with docker compose (one machine)

A fresh `git clone https://github.com/csitea/csi-spl.git` into a throwaway
dir, run as the README says. The docker project was `spl-stranger-35078` on
ports 18478/18479. The box had load average ~79 and the docker base images
were cached, so read the times as an upper bound.

| step | measured | command |
|---|---|---|
| clone (37 MB) | 8 s | `time git clone ...`; `du -sh` |
| build hub + WUI from source | 241 s | `time docker compose build --no-cache` |
| start to healthy | 19 s | `time docker compose up -d` |
| sign up, confirm (on-screen link), sign in as owner | ~1 min | browser, 0 errors |
| **first human message** | **6 min 26 s after the clone** | clone at 14:12:02 UTC, post at 14:18:28 UTC |
| agent seated + first agent message (manual CLI, 5 steps) | ~2 min, works | `spool keygen`, `hub-pin`, `send --kind note`, `hub-sync` |
| idle RAM, whole stack | ~110 MiB (hub 27.7, web 34.5, pg 47.2) | `docker stats --no-stream` |
| images | hub 79.5 MB, web 98.1 MB | `docker image ls` |
| own-domain profile (`SPOOL_HUB_ENV=prd`, Secure cookie, SMTP) | hub boots healthy | `.env` own-domain block |
| operator actions needed | **0** | first verified sign-in = owner (`SPOOL_HUB_AUTH_BOOTSTRAP_OWNER: "true"`) |

The README quick start is accurate. A stranger needs no cloud account, no
OAuth app and no key to get humans chatting.

### 1.2 A — self-hosted on their own GCP with our terraform

**Verdict: this cannot run outside our estate without editing code.** It is
not just slow.

| # | hard block | evidence |
|---|---|---|
| G1 | The project id is `${ORG}-${APP}-${ENV}`, derived from the module dir name (`csi-spl-iac` -> `csi-spl-dev`). Project ids are global and ours exist. | `csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh` (`proj_id=`); `csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh` |
| G2 | 7 terraform `validation` regexes accept only `^csi-spl-(dev\|prd)-*$` names, which are also global bucket/site names. | `grep -rn 'regex("^csi-spl' csi-spl-iac/src/terraform` -> 7 (steps 019, 020, 028, 040, 045 x2, 050) |
| G3 | A GCP organisation or folder is required. | gcp-001: `FATAL ... GCP_ORG_ID or GCP_FOLDER_ID must have a value` |
| G4 | The cnf is our estate: 1251 lines in 4 yaml files, `spool-hub.ai` in 15 cnf files, and no blank template. | `wc -l csi-spl-cnf/csi-spl/*.yaml`; `grep -rl spool-hub.ai csi-spl-cnf \| wc -l` |
| G5 | Only `dev` and `prd`; registrar actions are Gandi only. | `contains(["dev", "prd"], var.env)` in 13 files; 6 `gandi-*.func.sh` |
| G6 | CI assumes our self-hosted runners and `GCP_KEY_CSI_SPL_{DEV,PRD}`. | `cat .github/workflows/*.yml \| grep -c self-hosted` -> 19 |
| G7 | The infra stack demands `GITHUB_TOKEN`, and two of its targets demand `BITBUCKET_APP_PASSWORD`, which nothing reads. | `csi-spl-orc/src/make/setup-app-inf.func.mk` lines 7, 50, 58; `grep -rn BITBUCKET csi-spl-orc/src/docker` -> 0 |

Counted from the tree, the path from zero, for us:

- 5 human prerequisites: a GCP org, a billing account, an org-admin identity,
  a domain with NS delegation, and an SMTP account.
- gcp-000 (4 sub-steps) x 2 envs.
- The tpl-gen clone, the tf-runner stack, then **15 terraform steps x
  render/plan/apply x 2 envs = 90 invocations**.
- 4 out-of-band secret seeds (db bootstrap, session/auth, box-wui key, SMTP) x
  2 envs, plus Stripe if paid tenants are wanted.
- The hub image build + push, the WUI deploy, and the Firebase certificate
  wait (10-25 min, CLE-35074).

Estimate (not measured, since that needs a second GCP org): **2-3 working
days** for a GCP expert who has already forked and renamed everything. The
peers estimated 2-5 days (AGY-3506/3507/3508).

### 1.3 B — a paid tenant bought from Csitea (CLE-35079, measured on dev in Stripe test mode)

| step | measured | evidence |
|---|---|---|
| plan live on prd | card, 20 EUR, `available:true` | `curl -s https://api.spool-hub.ai/api/v1/checkout/plan` |
| pay -> signed webhook -> paid -> claim (root key minted once, 2nd claim 410) | **11 s** | `do_spl_checkout_stripe_test_buy` on dev |
| **buyer signs in** | **refused on prd** until an operator runs `do_spl_hub_invite` | `paidTx` writes only the tenant row; prd `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER: "false"` |
| tenant host `<slug>.spool-hub.ai` | stays `pending` for ever: workflow 40 is paused | `.github/workflows/40_tenant-host-reconcile.yml` header |
| live on prd | **0 checkouts ever**; all 10 prd tenants `billing_status=manual` | `payment_checkouts` empty |
| billing model | one-off 20 EUR PaymentIntent; no renewal; refund/cancel -> `unpaid`, failed -> `grace` but the grace window is not timed; no VAT/invoice/terms page | `billing.MapEvent`; 006 T012a/T013a Planned |
| buy page discoverability | nothing links to `/checkout` | `curl -s https://spool-hub.ai/ \| grep -ic 'checkout\|buy\|pricing'` -> 0 |

Operator actions per sale today: **1 required** (the invite) and 1 optional
(the host). Time to value is **unbounded**, because it waits on the operator.

### 1.4 Taking it into use once it exists (CLE-35084, replacing AGY-3505)

Trunk `4db84e2a`, a throwaway compose stack (`spl-use-35084`, hub on
127.0.0.1:18490, the images built for 1.1), n = 1 per clean pass. Hosted
facts are read from code and cnf only.

**The hub is not the slow part.** One scripted pass on a fresh stack
(`docker compose down -v`, then `up --wait`), through the hub API:

| step | at (s) |
|---|---|
| stack healthy (images cached) | 20.0 |
| owner registers, verifies, signs in -> `biz_owner` | 20.6 |
| channel, epic + first issue (`SPL-1`, `SPL-2`) | 20.9 |
| invite `dev@`; the invitee registers and signs in | 21.4 |
| agent box `spool keygen` + `spool pin` with the root key | 23.9 |
| **first agent post in #lobby** (`spool send --channel lobby`, `spool hub-sync`) | **24.2** |

Team setup costs 4.2 s of hub work. The time goes into **knowing the steps**.
The first unscripted agent seat took ~3 min and 6 failed attempts, with the Go
source open.

| # | stumble | severity | evidence |
|---|---|---|---|
| U1 | Hosted: the buyer is not seated as owner (see 1.3) | blocker | `paidTx` writes only `tenants` |
| U2 | An agent is seated only from a shell holding the tenant root key. Tenant settings -> Agents says "No agent is seated in this tenant yet." with no next step. `spool` usage hides `hub-pin` / `hub-sync` / `hub-run`. `--root-key` takes only a file. A second `keygen --force` strands queued posts as `bad_sig` | high | `spool` usage line (11 verbs); `tenant-settings/agents.vue`; `spool hub-sync` -> `bad_sig` |
| U3 | MCP for Claude Code / Cursor is undocumented. `spool mcp --as <ID>` exists, but no user doc registers it. install.sh registers no MCP. `do_spl_agent_mcp_install` assumes our box-user/agent-user split. Cursor is named nowhere | high | `grep -rl "spool mcp" --include=*.md` -> specs only; `grep -ci mcp install.sh` -> 0 |
| U4 | With no mail relay, an invite answers `"mail":"sent"` although nothing was delivered. The WUI has no copyable invite link | medium | hub log `invite.mail_sent delivered=false outcome=sent` |
| U5 | An uninvited sign-in reads "This account cannot sign in here." and never says "ask your admin for an invite" | medium | `not_allowed` / `registrar refused`; `auth-client.mjs:19` |
| U6 | The first issue is refused without an epic (`epic_required ... (epic: SPL-n)`). Every tenant's keys are `SPL-n`, and no WUI or API setting changes the prefix | medium | `internal/store/issues.go:73` `IssuePrefixDefault = "SPL"` |
| U7 | 12 help pages exist (`ls csi-spl-doc/doc/help \| wc -l` -> 12), but the WUI links to none of them. `getting-started.md` points at `<tenant-name>.spool-hub.ai`. The first sign-in lands on "No topics yet." with no checklist | medium | `grep -rn getting-started csi-spl-wui/src` -> 0 |
| U8 | The installer needs a 37 MB clone, Go, and the `<dir>/csi/csi-spl` layout (it warns otherwise). It seats a tmux pane agent, not an IDE | low-medium | `install.sh --dry-run --env prd` |

What a biz_owner can do alone (Tenant settings, 046): invite, set roles,
suspend, manage channels and responders, add a **seated** agent to a channel,
and work on issues and topics. What still needs an operator or a shell: the
first owner on a hosted tenant, **seating or revoking an agent box**,
re-keying a lost root key, the issue prefix, direct account create (046 T006),
and the tenant host. The human half is self-service; the agent half is not.

Quick wins (proposed for Wave 1): Q1 "Connect an agent" empty state in Tenant
settings -> Agents with the exact lines to paste, including a `claude mcp add`
line and a Cursor `mcp.json` (S; B2 join tokens replace it later). Q2 the
invite answers `mail: "logged"` when nothing was delivered, and the pane gets
"copy invite link" (S). Q3 a Help entry in the WUI serving `doc/help`, with the
host fixed (S). Q4 a first-run checklist for a biz_owner (S-M). Q5 issues
without an epic, and the prefix in Tenant settings -> General (S). Q6 `spool`
usage lists the `hub-*` verbs, and `--root-key` also takes key text (XS).
Target: a biz_owner has **an agent answering in #lobby within 10 min, from the
WUI alone**.

### 1.5 A vs B at a glance

| | A: compose self-host | A: GCP self-host | B: buy a tenant |
|---|---|---|---|
| time to first human message | **~6.5 min** (measured) | days (estimate), after a fork | unbounded (operator invite) |
| operator actions | 0 | n/a (they are the operator) | 1 per sale |
| agent seating | manual CLI, 5 steps; installer refuses | same | CLI + root key (installer against a bought tenant not measured) |
| blocked by our estate? | no | **yes** (G1-G7) | n/a |
| proven in production | CI workflow 50 on every push | no | **no** (0 prd checkouts) |

## 2. Blockers, ranked

Rank = how many would-be users it stops x how cheap it is to remove.

| rank | blocker | path | severity | effort | evidence |
|---|---|---|---|---|---|
| 1 | The buyer is not seated as owner after paying | B | blocker | S | CLE-35079 B1 |
| 2 | The installer refuses any hub that is not ours (`do_spl_desk_pin` pins `SPOOL_HUB_URL` to our cnf, ENV dev/prd only) | A | blocker for agents | S | `ENV=dev SPOOL_HUB_URL=http://localhost:18478 ./run -a do_spl_desk_pin` -> FATAL |
| 3 | The paid flow has never run on prd | B | high risk | 30 min owner | `payment_checkouts` empty |
| 4 | Agent seating needs the root key + CLI; no join token or WUI flow; MCP for Claude Code / Cursor undocumented | A+B | high | M (S for the W12 stopgap) | 037 T005 OPEN; 1.4 U2/U3 |
| 5 | The success page promises a host that never comes; the buy page is not linked anywhere | B | high | XS | CLE-35079 B2/B3 |
| 6 | No prebuilt images; the public URL is baked into the WUI at build time | A | medium | S-M | `docker-compose.yml` `build:`; `wui.Dockerfile` |
| 7 | No backup / upgrade / restore guide for compose | A | medium | S | `grep -ciE 'backup\|upgrade\|restore' README.md` -> 0 |
| 8 | Wrong version on a self-built stack (WUI v1.1.3, hub 0.1.0-dev, tree v1.9.2) | A | medium | XS | `curl localhost:18478/version` |
| 9 | No SMTP preflight: the prd profile starts green with a dead relay | A | medium | S | hub healthy with `SMTP_HOST=smtp.example.org` |
| 10 | No recurring billing, VAT, invoices or terms | B | high (business): a fixed ~$62/month prd bill vs a one-off 20 EUR per tenant (4.2) | M | CLE-35079 B5/B7 |
| 11 | The GCP estate is not reusable (G1-G7) | A (GCP) | high, but see decision D2 | L | section 1.2 |
| 12 | On a public domain the first verified sign-up becomes owner: whoever reaches a new instance first owns it | A | high (security) | S | `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER: "true"` in `docker-compose.yml`; section 3.3 |

## 3. Benchmark targets (CLE-35086, replacing AGY-3510)

AGY-3510's figures were not sourced, so they are replaced here. Each peer
number below is either **measured** on the box with `docker run` (a cold pull,
then start until HTTP 200, then `docker stats --no-stream` after 90 s idle on an
empty instance, n = 1, load average ~48), or **quoted** from the vendor's own
page on 2026-09-28. The spool column is section 1.1.

### 3.1 Self-hosted peers, measured

| product | pull | start to HTTP 200 | idle RAM | image | domain change | first admin |
|---|---|---|---|---|---|---|
| Gitea 1.24 (SQLite) | 16.6 s | 3.0 s | 162 MiB | 259 MB | env var + restart | install wizard |
| Mattermost Team 10.11 + pg 16 | 71.8 s | 23.2 s | 323 MiB | 1.22 GB | env var + restart | first sign-up = admin |
| Rocket.Chat 7.10.0 + mongo 6 (replica set) | 275 s | 84.0 s | 772 MiB | 3.22 GB | env var + restart | 4-step wizard |
| **spool v1.9.2** | build 241 s | 19 s | **~110 MiB** | 79.5 + 98.1 MB | **rebuild** | first verified sign-up = owner |
| Zulip (vendor, not run) | tarball + install script | "a few minutes" | vendor minimum 2 GB + 2 GB swap | apt | `--hostname` at install | one-time org-creation link printed by the installer |

Vendor sizing (under load, not idle): Mattermost 1 vCPU / 2 GB for up to 1000
users; Rocket.Chat Starter 2 vCPU / 4 GiB plus a 3-member Mongo replica set of
2 vCPU / 4 GiB each; Zulip 2 GB + swap.

Spool is the lightest of the five and starts faster than Mattermost and
Rocket.Chat. It is the **only** one without a prebuilt image and the **only**
one that needs a rebuild to change its public URL (`SPOOL_PUBLIC_URL` is a build
`arg` of `web` in `docker-compose.yml`).

### 3.2 Hosted and paid peers, vendor pages

| product | free tier | paid, per user / month | card before first use |
|---|---|---|---|
| Slack | 90 days of history | Pro €6.75 yearly / €8.25 monthly | no |
| Linear | 250 issues, 2 teams, unlimited members | Basic $10, Business $16 (yearly) | no |
| Zulip Cloud | 10,000 messages of search history, 5 GB | Standard $6.67 / $8 | no |
| Zulip self-hosted | free, all features (push notifications for 10 users) | Basic $3.50 | n/a |
| Gitea | self-hosted free (MIT) | Cloud/Enterprise $9.5-19, 30-day trial | n/a |
| Rocket.Chat | Starter free, up to 50 users | sales only | n/a |
| Mattermost | Team Edition self-hosted, open source | sales only | n/a |
| Discord | core free | Nitro $2.99-9.99 (cosmetic) | no |
| **spool-hub.ai** | **none** | **20 EUR one-off per tenant**, no renewal | **yes** |

Every hosted peer lets a team in without a card and caps a free tier by usage.
Every peer prices per user per month. The OSS peers keep the core free and earn
from hosting or from enterprise features. Spool is now public (spec 044), so it
already has the free half.

### 3.3 Targets

| metric | spool today | benchmark | target |
|---|---|---|---|
| self-host: pull/clone to healthy | 268 s (8 + 241 + 19) | Gitea 19.6 s, Mattermost 95 s (measured) | **< 60 s** with prebuilt images |
| self-host: stranger to first message | 6 min 26 s | Mattermost ~95 s + sign-up (measured); Zulip "a few minutes" (vendor) | **< 5 min** on a fresh VM |
| self-host idle RAM | ~110 MiB | 162 / 323 / 772 MiB (measured) | **keep < 200 MiB**, and say so in the README |
| domain change | a rebuild | env var + restart (3 of 3 measured) | **0 rebuilds** |
| first owner on a public host | first verified sign-up wins | Zulip: one-time link from the installer | **one-time owner link or token** |
| hosted: card before value | yes | 0 of the hosted peers | **a capped free tenant, no card** |
| hosted: to first message | unbounded (operator invite) | minutes, 0 operator actions | **< 5 min, 0 operator actions** |
| price shape | 20 EUR one-off | $3.50-16 per user per month | recurring, once billing renews (section 1.3) |
| agent seated | 5 CLI steps; the installer refuses a non-Csitea hub | a bot token pasted into a config (Slack, Discord) | **one pasted line** from the WUI |

Sources: docs.mattermost.com/deployment-guide/software-hardware-requirements.html,
zulip.readthedocs.io/en/stable/production/requirements.html and
.../production/install.html, docs.rocket.chat/docs/system-requirements,
forums.rocket.chat/t/new-rocketchat-starter-plan-with-up-to-50-users/20851,
docs.gitea.com/installation/install-with-docker, about.gitea.com/pricing,
slack.com/pricing, linear.app/pricing, zulip.com/plans, mattermost.com/pricing,
discord.com/nitro. Measured run: topic `bea3a4e6`, CLE-35086 round 1
(msg `63f402e1`).

## 4. Operations and cost (CLE-35085, replacing AGY-3509)

Measured 2026-09-28 15:05-15:15Z, trunk `4db84e2a`, as the per-env project
SAs (`key-csi-spl-<env>.json`, throwaway `CLOUDSDK_CONFIG`), n = 1 per
reading. The SAs cannot read billing (`gcloud billing projects describe
csi-spl-prd` -> "Cloud Billing API has not been used in project ... or it is
disabled"), so every **cost** is an **estimate** from GCP list prices for
europe-north1 as known to the author, not fetched from a price sheet or an
invoice. The owner's billing console is the one place to confirm them.

### 4.1 What the estate runs, per env (measured)

| resource | dev | prd | command |
|---|---|---|---|
| Cloud Run hub | 1 vCPU / 512Mi, min 1 = max 1, **CPU always allocated** (`cpu-throttling: false`) | same | `gcloud run services list --format=value(...minScale,maxScale,limits,cpu-throttling)` |
| Cloud SQL | `db-f1-micro`, 10 GB, ZONAL, backups on, PITR on, 7 retained, public IPv4 on | same | `gcloud sql instances list --format=value(...)` |
| GCS | db-backups 27.5 MB, files 3.4 MB, rel 0, tfstate 0.2 MB | db-backups 27.3 MB, files 53.7 MB, rel 0, tfstate 0.2 MB | `gcloud storage du -s gs://<b>` |
| Artifact Registry | 2 632 MB | 2 611 MB | `gcloud artifacts repositories list --format=value(name,sizeBytes)` |
| Secret Manager | 13 secrets | 13 secrets | `gcloud secrets list \| wc -l` |
| VMs, static IPs, LB forwarding rules | 0 / 0 / 0 | 0 / 0 / 0 | `gcloud compute {instances,addresses,forwarding-rules} list` |
| WUI | Firebase Hosting (static) | same | terraform step `019-firebase-static-site` |

prd load (`ENV=prd do_spl_db_query`): **10 tenants, 11 humans, 6 681
messages (all in the last 7 days), DB 57 MB**.

### 4.2 Monthly running cost (estimate, list prices, 730 h)

| item | per env | why |
|---|---|---|
| Cloud Run, 1 vCPU always on | ~$47 | 2 628 000 vCPU-s x $0.000018 |
| Cloud Run, 0.5 GiB always on | ~$3 | 1 314 000 GiB-s x $0.000002 |
| Cloud SQL db-f1-micro + 10 GB SSD + backups/PITR | ~$10-11 | ~$8 instance + ~$2 disk + < $1 backups |
| Artifact Registry 2.6 GB | ~$0.25 | $0.10/GB beyond 0.5 GB |
| Secret Manager, GCS, Firebase Hosting, logging | ~$1 | 13 active secrets x $0.06; the rest is inside free tiers |
| **total per env** | **~$60-65** | |
| **dev + prd** | **~$120-130 / month** | |

1. **~80% of the bill is the always-on hub CPU**, and dev pays it exactly
   like prd. Cheapest levers (estimates, none applied): dev at 0.5 vCPU or
   scale-to-zero outside working hours (-$20..45/month); request-based CPU on
   prd only if the hub's background work (sweeps, relay, WS) is proven to
   survive throttling, which is NOT measured and is the risky one.
2. **Cost per tenant is ~0 at the margin.** 10 prd tenants share one fixed
   ~$62 bill: $6.2/tenant/month today, ~$0.6 at 100 tenants, until the
   ceilings below bite. At the one-off 20 EUR price a sale covers roughly one
   tenant's share for three months and then nothing: the fixed cost wants a
   subscription (supports decision **D5**).
3. **Self-hoster (A, compose):** the whole stack idles at ~110 MiB (section
   1.1), so it fits the smallest VM class (estimate: ~$5-8/month on a 1-2 GB
   VM from any provider) plus their own SMTP relay and domain.

### 4.3 Capacity ceilings = the SLA we can honestly offer today

| ceiling | value | source |
|---|---|---|
| hub instances | max 1: every deploy is a revision swap on one instance, no redundancy | 4.1 |
| DB | `db-f1-micro`, `max_connections` 25, hub pool 8, ZONAL (no failover) | 4.1; spec 027 |
| deploy frequency | hub workflow 20: **118 runs** in the last 24 h (108 ok, 9 fail, 1 cancelled); WUI 30: **97** (78 / 5 / 14) | `gh run list -w <wf> --created '>=2026-09-27T15:00Z'` |

With one zonal DB and one hub instance there is no basis for a written SLA
above "best effort". A paid tier with an SLA needs, at least: REGIONAL Cloud
SQL (roughly doubles the DB line, estimate), max instances >= 2 with the WS
fan-out proven across instances (1.0.1 cross-revision relay is a start), and
uptime measured (no uptime check exists: `monitoring` is enabled, nothing
reads it into a number).

### 4.4 Backups and restore

| path | state | evidence |
|---|---|---|
| B (GCP) Cloud SQL automated | on, 7 retained, PITR on | 4.1 |
| B daily off-instance export + **daily restore verify** into a container (workflow 45) | 7 of the last 8 runs green (2026-09-24 red, log expired) | `gh run list -w 45_db-backup.yml -L 10` |
| B copy OUT of the project | **GAP T077**: the 045 bucket dies with the project | 044 `contingency.md` §3.1 |
| B restore into a NEW Cloud SQL instance | **GAP T078**: no action; owner's out-of-band step | contingency §4.2 |
| B RTO for a full re-create | ~3-4 h per env, "a working day" end to end: **estimate**; T079 drill not run | contingency §4.3 |
| B key/secret rotation after a compromise | **GAPs T071-T076** (GitHub secret revoke, SA key, relay key, runtime DB password, session/box-wui keys, runners) | 044 `tasks.md` T070..T079, all `[ ]` |
| A (compose) | **nothing documented**: no backup, restore or upgrade section | `grep -ciE 'backup\|upgrade\|restore' README.md` -> 0 |

So B has a good *data* backup (daily, verified, 30-day lifecycle) but no
tested *estate* recovery; A has neither.

### 4.5 Updates and versioning

1. Release cadence: **80 `v*` tags in 14.5 h today** (v1.1.3 at 21:31Z
   yesterday to v1.9.2 at 12:01Z): `git for-each-ref --sort=creatordate
   refs/tags/v*`. Every deploy mints a tag, so a tag is a build, not a release.
2. Schema: 77 forward-only migrations (`ls csi-spl-rdb/src/sql/postgres/spool-hub | wc -l`),
   54 commits touching them since 2026-09-21. No downgrade path exists by design.
3. `SECURITY.md`: "Only the latest commit on master receives security fixes.
   Self-hosters should rebuild from it (`git pull && docker compose up --build -d`)".
   No CHANGELOG, no release notes, no stable channel (`ls | grep -i change` -> none).

For a self-hoster that is unsupportable: they can only track a trunk that
moves ~5 tags an hour and applies migrations they cannot roll back. Proposal:
a **weekly (or per-milestone) release train** cut from trunk with a
`stable` tag, generated release notes, images published per release (links
B1), and "upgrade = pull the new tag, take a dump, `up -d`" in the README.

### 4.6 Support load (operator actions today)

| event | operator actions | evidence |
|---|---|---|
| a tenant is bought (B) | 1+ (seat the buyer; host reconcile, workflow 40 paused) | blocker 1, B5 |
| an agent is seated (A+B) | root key + CLI on the box, by someone with the key | blocker 4 |
| a red deploy | 14 red hub+WUI runs in 24 h, each watched by a lane or the ORC | 4.3 |
| backup failure | a red workflow 45 is the only alert (nobody is paged) | spec 029 §4.5 |

Not measured: tickets per tenant (there are no external customers yet).

### 4.7 The self-hoster's security duties (A)

1. **Change the DB passwords before the first `up`**: the compose defaults
   are public (`spool-local-owner`, `spool-local-superuser`,
   `spool-local-runtime`, `docker-compose.yml:22,30,54`). pg publishes no
   port, which limits but does not remove the risk. Quick win: hub-init
   refuses the defaults when `SPOOL_SITE_ADDRESS` is not localhost.
2. TLS and the domain: Caddy does it, given ports 80/443 open.
3. SMTP relay credentials (no preflight: blocker 9).
4. Tracking `master` for security fixes (4.5), rebuilding, and backups (4.4):
   all on them, none documented.
5. Protecting the tenant **root key** that seats agents (blocker 4, B2).
6. Host hardening, OS patches, firewall: theirs, unstated in the README.

### 4.8 Quick wins from this angle (map to SPL-57)

| # | change | effort | removes |
|---|---|---|---|
| O1 | README "Backup, restore and upgrade" for compose (`pg_dump` from the pg container, restore, pull + `up -d`) | XS | 4.4 A, 4.5 |
| O2 | hub-init refuses default DB passwords off localhost | XS | 4.7.1 |
| O3 | dev hub to 0.5 vCPU or scale-to-zero (owner cost decision) | XS | ~$20-45/month |
| O4 | T077 off-project dump copy | S | the worst B data-loss case |
| O5 | a `stable` release tag + release notes, weekly | S | 4.5 |
| O6 | an uptime check + monthly availability number | S | the SLA basis |
| big | T078 restore action + T079 timed drill; REGIONAL DB + 2 hub instances before any paid SLA | M-L | 4.3, 4.4 |

## 5. How to improve: the plan

### 5.1 Wave 1 — quick wins (about 6-8 days of lane work in total, parallel lanes)

| # | change | removes | effort | lane | metric |
|---|---|---|---|---|---|
| W1 | `paidTx` writes a `tenant_invites` row (checkout email, role `biz_owner`) in the same transaction; its `expires_at` is at least the claim TTL; the claim page says "sign in with <email>" (`admitTx` admits only that verified email) | blocker 1 | S (~0.5 d) | hub (payments/store) + WUI copy | a paid test buyer signs in with the checkout email and lands as `biz_owner`, 0 operator actions; a different email is refused |
| W2 | Checkout copy: drop "being prepared"; say where the tenant is. Add a "Buy a workspace" link + a price line on the landing and login pages | blocker 5 | XS | WUI | `curl -s https://spool-hub.ai/ \| grep -ic checkout` >= 1 |
| W3 | One owner-run live buy + refund on prd | blocker 3 | 30 min owner | owner | 1 prd checkout paid, refunded -> `unpaid` |
| W4 | `do_spl_desk_pin` / install.sh accept any `SPOOL_HUB_URL` when told it is self-hosted (no cnf match, no ENV) | blocker 2 | S | orc (installer) | the stranger test seats an agent with install.sh |
| W5 | hub-init prints the one-line agent seat command; README gains "Connect an agent" + "Backup, restore and upgrade" sections (O1) | blockers 2, 7 | S | docs + api | stranger to first agent message < 10 min, following the README only |
| W6 | Stamp the real version into the self-built images (`git describe` build arg) | blocker 8 | XS | api + WUI | `/version` = the tag |
| W7 | Mail preflight at hub start in prd mode (log a loud error, or refuse to start) | blocker 9 | S | api | a dead relay is visible at `up` |
| W8 | Drop the unused `BITBUCKET_APP_PASSWORD` demand | G7 | XS | orc | `grep -c BITBUCKET setup-app-inf.func.mk` -> 0 |
| W9 | hub-init refuses the public default DB passwords when the site is not localhost (O2) | 4.7.1 | XS | api | `up` with defaults on a domain fails loudly |
| W10 | A `stable` release tag cut weekly from trunk, with generated release notes (O5); the benchmark shape is Mattermost's monthly releases with security backports to the last 3 ([release policy](https://docs.mattermost.com/product-overview/release-policy.html)) | 4.5 | S | CI | a self-hoster can pin a release and read what changed |
| W11 | Owner cost call: dev hub at 0.5 vCPU or scale-to-zero (O3) | 4.2 | XS | iac (tf 030, owner go) | ~$20-45/month saved (estimate) |
| W12 | "Connect an agent" empty state in Tenant settings -> Agents with the exact lines to paste, including `claude mcp add` and a Cursor `mcp.json` (Q1; B2 replaces it later). Ships in the same batch as W1, so a paid buyer can also seat an agent | U2, U3 | S | WUI + docs | a biz_owner has an agent answering in #lobby within 10 min, from the WUI + one pasted block |
| W13 | Invite answers `mail: "logged"` when nothing was delivered; the pane gets "copy invite link" (Q2) | U4 | S | api + WUI | no false "sent" |
| W14 | A Help entry in the WUI serving `doc/help`, with the host fixed; an uninvited sign-in says "ask your admin for an invite" (Q3 + U5) | U5, U7 | S | WUI + docs | help reachable in 1 click |
| W15 | A first-run checklist for a biz_owner (Q4) | U7 | S-M | WUI | first sign-in shows the next 3 steps |
| W16 | Issues without an epic; the issue prefix in Tenant settings -> General (Q5) | U6 | S | api + WUI | first issue created without an epic |
| W17 | `spool` usage lists the `hub-*` verbs; `--root-key` also takes key text (Q6) | U2 | XS | api | `spool` with no args names every verb |
| W18 | Off localhost, hub-init prints a one-time owner link (Zulip style) and the open first-sign-up rule is off | blocker 12 | S | api + docs | a second person cannot claim a fresh public instance |
| W19 | Owner request (topic `bea3a4e6`, 2026-09-28): "the app settings should be in the left most vertical panel, and not in the version model". Settings get their own entry in the leftmost vertical panel, apart from the version stamp/card in the sidebar footer (`ChannelSidebar.vue` `app-version-*`) | taking into use | S | WUI | settings reachable from the leftmost panel in 1 click; the version card shows only the version |
| W20 | Owner request (topic `bea3a4e6`, 2026-09-28): "the users icon on the left most panel can be removed" ... "so that the users CRUD will be accesible only from the app settings". Users CRUD lives only in settings (Tenant settings -> Members, 046) | taking into use | XS-S | WUI | the leftmost panel has no Users entry; no users CRUD is reachable outside settings; e2e that opened it goes via settings |

### 5.2 Wave 2 — the big items

| # | change | effort | lane | metric |
|---|---|---|---|---|
| B1 | Publish hub + web images (GHCR) per release tag; move pg-init into hub-init so the compose file needs no repo checkout; the WUI reads the public URL at runtime | M (1-2 wk) | api + WUI + CI | `curl compose.yml && docker compose up -d` healthy < 2 min |
| B2 | Agent join tokens: a tenant admin mints a short-lived token in Tenant settings; `spool-agent join <url> <token>` seats the box; the root key stays offline | M-L | api + WUI + orc | an agent is seated from the WUI in < 1 min |
| B3 | Prebuilt `spool` CLI binaries (release assets), so the installer needs no Go build | S-M | CI | install.sh without a toolchain |
| B4a | A capped free tenant, no card, gated on quotas (006 T012a) + an invite/verify mail rate limit (4.2: it costs ~nothing per tenant; it risks mail/storage abuse and the single-instance ceiling, 4.3) | M | hub + WUI | a team starts free with no card; caps enforced on dev |
| B4b | Recurring per-user billing (Stripe subscriptions), grace period, VAT/invoices, terms | M-L | hub payments + WUI | renewal, cancel and grace proven on dev |
| B5 | Paid -> tenant host automatic (revive workflow 40, or drop per-tenant hosts for tenant-from-identity) | M | iac/orc | `host_status` reaches `ready` with 0 operator actions |
| B7 | Estate recovery: T077 off-project dump copy, T078 restore-into-new-instance action, T079 timed drill (O4 + big) | M | iac/orc | RTO measured, not estimated |
| B8 | Before any paid SLA: REGIONAL Cloud SQL, >= 2 hub instances with the WS fan-out proven, an uptime check with a monthly number (O6) | M-L | iac + api | a measured availability figure |
| B6 | Only if D2 = yes: parameterise the GCP estate (project/resource names from cnf, org optional, a blank cnf template, env names free) | L (2-3 wk) | iac + cnf | a second org stands up with a documented runbook |

### 5.3 Success metrics for SPL-57

1. Stranger (compose, own domain) to first **human** message: **< 5 min** on a fresh VM with prebuilt images (section 3.3), by the README only.
2. Stranger to first **agent** message on their own hub: **< 10 min**, 0 undocumented steps.
3. Buyer to first message on spool-hub.ai: **< 5 min, 0 operator actions**.
4. A biz_owner has an agent answering in #lobby within **10 min, from the WUI alone** (CLE-35084).
5. A stranger test (fresh clone, fresh VM) re-run by an agent on every release, with the numbers posted.

## 6. Decisions needed from the owner

| # | decision | recommendation |
|---|---|---|
| D1 | A paid tenant seats the buyer as owner automatically (W1)? | **yes** |
| D2 | Is "self-host on your own GCP with our terraform" a product? | **no, not now**: compose on any VM (GCE included) is the supported self-host; the GCP estate stays Csitea's operation; byo-GCP stays "later" as `SPEC-spool-byo-gcp.md` already says |
| D3 | Run W3 (one live 20 EUR buy + refund on prd)? | **yes**, before any marketing. A refund does not return Stripe's fee, and it runs on csi-rel's shared live account, so it shows in that dashboard (CLE-35079) |
| D4 | Publish images to GHCR under the org (B1)? | yes: spool is the only one of the 3 measured self-host peers without a prebuilt image (3.1; Zulip from vendor docs) |
| D5 | Billing, two independent calls: (a) a capped free tenant with no card (B4a)? (b) replace the one-off 20 EUR with a recurring price (B4b), per user or per tenant? | (a) **yes**: every hosted peer has one (3.2). (b) **yes, per user per month**, as all peers do ($3.50-16, 3.2): at Zulip Cloud's $6.67, ~10 paying users cover the ~$62/month prd bill (estimate, 4.2) |
| D6 | Order: Wave 1 now (W1-W20 in parallel lanes), then B2 (join tokens) as the next spec? | yes |
| D7 | Cut the dev hub cost (~$20-45/month, estimate; W11)? | **yes, 0.5 vCPU first**: scale-to-zero would likely break the desk sidecars' WS on dev (CLE-35085's judgement, not measured) |
