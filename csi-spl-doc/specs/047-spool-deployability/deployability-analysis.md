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

Panel: CLE-35078 (A, this document), CLE-35079 (B, technical), AGY-3505
(taking it into use), AGY-3509 (operations + cost), AGY-3510 (benchmark),
with independent opinions from CLE-35074, CLE-35076, AGY-3506, AGY-3507 and
AGY-3508.

**Evidence rule.** Every number below carries its command or file. The tree
is trunk `4dc8df91` (tag v1.9.2). Unless a row says otherwise, n = 1. An
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

### 1.4 Taking it into use once it exists (AGY-3505)

_Pending AGY-3505's round 1 analysis. What the others measured already:_
agents seat only through the CLI with the tenant root key (no join token, 037
T005 OPEN); the root key is shown once and a lost key is an operator re-key;
there is no in-WUI "connect an agent" flow.

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
| 4 | Agent seating needs the root key + CLI; no join token or WUI flow | A+B | high | M | 037 T005 OPEN; AGY-3507/3508/3510 |
| 5 | The success page promises a host that never comes; the buy page is not linked anywhere | B | high | XS | CLE-35079 B2/B3 |
| 6 | No prebuilt images; the public URL is baked into the WUI at build time | A | medium | S-M | `docker-compose.yml` `build:`; `wui.Dockerfile` |
| 7 | No backup / upgrade / restore guide for compose | A | medium | S | `grep -ciE 'backup\|upgrade\|restore' README.md` -> 0 |
| 8 | Wrong version on a self-built stack (WUI v1.1.3, hub 0.1.0-dev, tree v1.9.2) | A | medium | XS | `curl localhost:18478/version` |
| 9 | No SMTP preflight: the prd profile starts green with a dead relay | A | medium | S | hub healthy with `SMTP_HOST=smtp.example.org` |
| 10 | No recurring billing, VAT, invoices or terms | B | medium (business) | M | CLE-35079 B5/B7 |
| 11 | The GCP estate is not reusable (G1-G7) | A (GCP) | high, but see decision D2 | L | section 1.2 |

## 3. Benchmark targets (AGY-3510)

The peer figures below were reported from product docs by AGY-3510 and were
**not re-measured here**.

| metric | spool today (measured here) | benchmark | target |
|---|---|---|---|
| self-host: clone/pull to healthy | 268 s (8 + 241 + 19) | Gitea `docker run` < 1 min | **< 2 min** with prebuilt images |
| self-host: stranger to first message | 6 min 26 s | Mattermost 3-5 min | **< 10 min** on a fresh VM with own domain + TLS |
| self-host idle RAM | ~110 MiB | Gitea ~80 MB, Mattermost/Zulip 2-4 GB | **keep < 200 MiB** |
| domain change | a rebuild | an env var + restart | **0 rebuilds** |
| agent seated on own hub | 5 manual CLI steps | Slack bot install ~30 s | **one pasted line** |
| hosted: pay to first message | unbounded (operator) | Slack/Linear < 90 s, no card | **< 5 min, 0 operator actions** |

## 4. Operations and cost (AGY-3509)

_Pending AGY-3509's analysis: the GCP running cost per env and per tenant,
backups and restore (spec 029, contingency T070..T079), updates and
versioning, support load, and the self-hoster's security duties._ Known from
this lane: compose has no documented backup or upgrade (blocker 7), and the
hub Cloud Run service runs as one 1 vCPU / 512 MiB instance (commit
`4dc8df91`).

## 5. How to improve: the plan

### 5.1 Wave 1 — quick wins (about 3-4 days of lane work in total)

| # | change | removes | effort | lane | metric |
|---|---|---|---|---|---|
| W1 | `paidTx` writes a `tenant_invites` row (checkout email, role `biz_owner`) in the same transaction; its `expires_at` is at least the claim TTL; the claim page says "sign in with <email>" (`admitTx` admits only that verified email) | blocker 1 | S (~0.5 d) | hub (payments/store) + WUI copy | a paid test buyer signs in with the checkout email and lands as `biz_owner`, 0 operator actions; a different email is refused |
| W2 | Checkout copy: drop "being prepared"; say where the tenant is. Add a "Buy a workspace" link + a price line on the landing and login pages | blocker 5 | XS | WUI | `curl -s https://spool-hub.ai/ \| grep -ic checkout` >= 1 |
| W3 | One owner-run live buy + refund on prd | blocker 3 | 30 min owner | owner | 1 prd checkout paid, refunded -> `unpaid` |
| W4 | `do_spl_desk_pin` / install.sh accept any `SPOOL_HUB_URL` when told it is self-hosted (no cnf match, no ENV) | blocker 2 | S | orc (installer) | the stranger test seats an agent with install.sh |
| W5 | hub-init prints the one-line agent seat command; README gains "Connect an agent" + "Backup and upgrade" sections | blockers 2, 7 | S | docs + api | stranger to first agent message < 10 min, following the README only |
| W6 | Stamp the real version into the self-built images (`git describe` build arg) | blocker 8 | XS | api + WUI | `/version` = the tag |
| W7 | Mail preflight at hub start in prd mode (log a loud error, or refuse to start) | blocker 9 | S | api | a dead relay is visible at `up` |
| W8 | Drop the unused `BITBUCKET_APP_PASSWORD` demand | G7 | XS | orc | `grep -c BITBUCKET setup-app-inf.func.mk` -> 0 |

### 5.2 Wave 2 — the big items

| # | change | effort | lane | metric |
|---|---|---|---|---|
| B1 | Publish hub + web images (GHCR) per release tag; move pg-init into hub-init so the compose file needs no repo checkout; the WUI reads the public URL at runtime | M (1-2 wk) | api + WUI + CI | `curl compose.yml && docker compose up -d` healthy < 2 min |
| B2 | Agent join tokens: a tenant admin mints a short-lived token in Tenant settings; `spool-agent join <url> <token>` seats the box; the root key stays offline | M-L | api + WUI + orc | an agent is seated from the WUI in < 1 min |
| B3 | Prebuilt `spool` CLI binaries (release assets), so the installer needs no Go build | S-M | CI | install.sh without a toolchain |
| B4 | Recurring billing (Stripe subscriptions), grace period, VAT/invoices, terms; then a trial | M-L | hub payments + WUI | renewal, cancel, and grace proven on dev |
| B5 | Paid -> tenant host automatic (revive workflow 40, or drop per-tenant hosts for tenant-from-identity) | M | iac/orc | `host_status` reaches `ready` with 0 operator actions |
| B6 | Only if D2 = yes: parameterise the GCP estate (project/resource names from cnf, org optional, a blank cnf template, env names free) | L (2-3 wk) | iac + cnf | a second org stands up with a documented runbook |

### 5.3 Success metrics for SPL-57

1. Stranger (compose, own domain) to first **human** message: **< 10 min**, by the README only.
2. Stranger to first **agent** message on their own hub: **< 15 min**, 0 undocumented steps.
3. Buyer to first message on spool-hub.ai: **< 5 min, 0 operator actions**.
4. A stranger test (fresh clone, fresh VM) re-run by an agent on every release, with the numbers posted.

## 6. Decisions needed from the owner

| # | decision | recommendation |
|---|---|---|
| D1 | A paid tenant seats the buyer as owner automatically (W1)? | **yes** |
| D2 | Is "self-host on your own GCP with our terraform" a product? | **no, not now**: compose on any VM (GCE included) is the supported self-host; the GCP estate stays Csitea's operation; byo-GCP stays "later" as `SPEC-spool-byo-gcp.md` already says |
| D3 | Run W3 (one live 20 EUR buy + refund on prd)? | **yes**, before any marketing |
| D4 | Publish images to GHCR under the org (B1)? | yes |
| D5 | Billing: stay one-off 20 EUR, or move to a subscription before a trial? | subscription first, then the trial |
| D6 | Order: Wave 1 now (W1-W8 in parallel lanes), then B2 (join tokens) as the next spec? | yes |
