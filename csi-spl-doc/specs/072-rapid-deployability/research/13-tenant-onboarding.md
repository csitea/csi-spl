# 072 research 13: tenant onboarding, from a deployed hub to a working workspace

Author: c-164. Tree: `origin/master` @ `c87a6779`, 2026-10-04. Docs only.
Scope: what happens after a hub is up: the first **workspace** (tenant), its
first **human** (the owner) and its first **agent** answering in #lobby.
047 W12-W16 shipped the self-service pieces; its fresh-tenant leg was
blocked. This file measures where that leg stands now, for all three ways a
tenant is born. Ranked by spec 072 section 2: time, manual steps, clarity of
errors. `<fqdn>`, `<tenant>`, `<env>` are placeholders. n = 1 per command.

## 1. Today

### 1.1 Three ways a tenant is born

| # | birth | path (072 section 3) | creates | check |
|---|---|---|---|---|
| T-a | `hub-init` on `docker compose up` | P1 | ONE tenant, `SPOOL_TENANT` (default `main`), its root key in the hub's state dir, a one-time owner invite | `csi-spl-api/src/docker/hub-entrypoint.sh:10,78-88`; `grep -n 'SPOOL_TENANT:' docker-compose.yml` -> 62, 143 |
| T-b | a paid checkout on a hosted hub | hosted (047 path B) | tenant row + `biz_owner` invite (047 W1); the hub hands the generated root key to the buyer once, at claim | `internal/store/payments_postgres.go:172` `paidTx` (INSERT `tenants` at +5, `tenant_invites` at +45); `internal/payments/handler.go:487,519` (claim mints the pair, returns `root_private_key`); `csi-spl-wui/src/pages/checkout/claim.vue:82` |
| T-c | an operator action on dev/prd | P2 | key pair, tenant row via the Cloud SQL proxy, then CHAINS the host (cnf push to trunk, 019 + 025 apply, cert wait, probe) and the box-wui pin | `csi-spl-orc/src/bash/run/spl-tenant-create.func.sh:1-40`; exit 3 = host not ready, exit 4 = box-wui not pinned |

No route creates a tenant over the API outside checkout:
`grep -rnE 'HandleFunc\("POST /v1/(tenants?|signup)' csi-spl-api/src/go --include=*.go` -> 0.
The low-level verb is `spool hub-tenant --db <dsn>` (T-c calls it at line 98);
`grep -c hub-tenant README.md` -> 0; `grep -rl hub-tenant csi-spl-doc/doc/help | wc -l` -> 0.

### 1.2 The walk per birth: workspace -> first human -> first agent

**T-a, compose (P1).** 047 1.4 measured the hub side on its own tree
(`4db84e2a`, n=1, scripted): healthy 20.0 s -> owner signed in 20.6 s ->
first agent post in #lobby 24.2 s. The hub is not the slow part; knowing the
steps is.

| step | manual work | check |
|---|---|---|
| workspace | 0: `up` seeds it | entrypoint line 10 |
| owner | read `docker compose logs hub-init` for the `OWNER:` link; off localhost `SPOOL_OWNER_EMAIL` must be set, else `up` dies with the fix in the message (a good error) | entrypoint:84, 88 |
| first agent | the `AGENT:` line copies the root key out of the container into a 0600 file and runs `install.sh` **from a clone** | entrypoint:95-96 |
| a second workspace | no action, no doc. `do_spl_tenant_create` takes `ENV` lde, dev or prd only; the WUI bundle bakes one `SPOOL_TENANT`; tenant hosts are off (`NUXT_PUBLIC_TENANT_HOSTS` unset -> `"0"`) | `spl-tenant-create.func.sh:11`; `.env.example:13`; `grep -c TENANT_HOSTS docker-compose.yml` -> 0; `csi-spl-wui/nuxt.config.ts:496` |
| browser post -> agent | **unmeasured on compose**. On the cloud a tenant without its box-wui pin gets every browser post stored unsigned and dispatch refuses `wui_unpinned`; compose sets no WUI key and the entrypoint pins nothing | `grep -c WUI_KEY docker-compose.yml` -> 0; `grep -c box-wui csi-spl-api/src/docker/hub-entrypoint.sh` -> 0; `internal/hub/dispatch.go:157`; `internal/config/config.go:428-440` (no key, not ephemeral -> nil) |

**T-b, paid checkout (hosted).**

| step | state | check |
|---|---|---|
| workspace | created by `paidTx` | `payments_postgres.go:172` |
| owner | W1 done: the buyer signs in with the checkout email as `biz_owner` | 047 W1 (SPL-1161) |
| the hop to `<tenant>.<fqdn>` | **still blocked**. The owner chose option A on 2026-09-30 (revive workflow 40) and the code is revived, but the workflow is `disabled_manually`, last run 2026-09-19. The WUI now waits ("your address is being prepared", retry every 30 s) instead of landing on NXDOMAIN, so the buyer waits **for ever** unless an operator runs `do_spl_tenant_host_provision` | `gh workflow list --all \| grep '^40'` -> `disabled_manually`; `gh run list --workflow 40_tenant-host-reconcile.yml --limit 10` -> 2 runs, newest 2026-09-19; wf 40 header lines 3-11; `csi-spl-wui/src/utils/tenant-host-boot.mjs` `PENDING_POLL_MS = 30000` |
| checklist (W15), help (W14), prefix (W16) | done, but the literal fresh-tenant first sign-in was never reached (047 W15 row) | 047 W12, W15 rows |
| first agent | the W12 block: needs git, **Go**, a clone, and the root key file on that machine | `csi-spl-wui/src/utils/connect-agent.mjs:56-70` (`git clone`, `go build`, `hub-pin ... --root-key`) |
| browser post -> agent | **broken by construction**: `paidTx` writes no box-wui pin, and only the root key can sign one. The hub holds that key only while it answers the claim. So a bought tenant's people post and no agent receives it, until someone pins | `sed -n 172,240p internal/store/payments_postgres.go \| grep -c pin` -> 0; `spl-tenant-create.func.sh:31-35` (SPL-1290: seven prd tenants found unpinned) |

**T-c, operator create (dev/prd).** One command, but an infra operation per
workspace: a cnf commit pushed to trunk, a terraform apply of 019 + 025, a
Firebase certificate wait (~30 min, `tenant-host-boot.mjs` header), a WUI
redeploy for its CSP, then the box-wui pin. Mapped tenant hosts today:
`grep -n mapped_tenants csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` -> 2 on dev,
10 on prd. The private key is printed once on stdout; the operator must hand
it to the tenant's admin out of band, because seating any agent needs it.

### 1.3 What a new workspace owner can and cannot do alone

| can (WUI) | cannot (needs an operator or a shell) |
|---|---|
| invite, roles, copy invite link (W13), channels, responders, issues without an epic and the prefix (W16), help (W14), checklist (W15) | reach their own host on a fresh hosted tenant (T-b); have browser posts reach an agent on a fresh hosted tenant (T-b); seat an agent without the root key and a Go toolchain (all); create a second workspace (T-a, T-c); recover a lost root key (all) |

## 2. Blockers

1. **Workflow 40 is disabled.** Every fresh hosted tenant stops at "your
   address is being prepared". `gh workflow list --all` -> `40 cd: tenant host
   reconcile  disabled_manually`. Enabling it is the owner's go (wf 40 header
   lines 10-11). This is the blocker 047 recorded as "fresh-tenant leg
   blocked": the code side is done, the switch is not.
2. **A paid tenant is born without a box-wui pin**, so its browser posts reach
   no agent (`dispatch.go:157` `wui_unpinned`). `paidTx` pins nothing; T-c
   pins only because the operator action does (`spl-tenant-create.func.sh:205-214`).
3. **The first agent needs the root key.** `grep -rliE 'join.?token'
   csi-spl-api/src/go --include=*.go | grep -vc _test` -> 0; 037 T005 OPEN
   (`037-spool-agent-install/tasks.md:32`). The W12 block also needs Go and a
   clone (`connect-agent.mjs:63-64`). Same gap as 072 G6/G7, A4/A5.
4. **A tenant host is an infra apply.** One workspace = one cnf push to trunk
   + two terraform steps + a cert + a WUI redeploy (T-c). Bearable for our
   estate at 10 tenants; for a stranger on P2 it turns "add a workspace" into
   a terraform run. The off switch exists (`TENANT_HOST=0`, cnf
   `steps.019.wui_tenant_hosts`, hub `SPOOL_HUB_WUI_TENANT_HOSTS`) but no doc
   or template says so, and our cnf ships it on (`dev.env.yaml:135,280`).
5. **No second workspace on compose.** No action, no API, no doc; the bundle
   is single-tenant (1.2, T-a).
6. **Compose browser -> agent is unproven** (1.2, T-a last row). A
   self-hoster may hit blocker 2 on the default stack, and nobody has looked.

## 3. Actions

Each is one lane. Effort as in spec 072 section 6 (XS < 0.5 d, S <= 1 d,
M 2-5 d).

| # | action | changes | owner | effort | done when (a test can check) |
|---|---|---|---|---|---|
| **N1** | Owner enables workflow 40, then one dev Stripe test buy proves the leg (`do_spl_checkout_stripe_test_buy`) | blocker 1; 047 B5 | owner + any lane | XS | `gh workflow list --all \| grep '^40'` shows `active`; the test tenant's `tenant_hosts.host_status` = `ready` with 0 operator actions; the buyer's first sign-in lands on its host |
| **N2** | Pin box-wui at birth on the paid path: at claim, while the hub still holds the generated root key, write the box-wui pin in the claim's transaction (the key is still never stored) | blocker 2 | api (payments/store) | S | store test, memory + postgres: a claimed checkout has an active box-wui pin equal to the hub's key; control: drop the pin write -> red. Dev: `do_spl_check_box_wui_pins` lists the test tenant pinned |
| **N3** | Measure compose browser -> agent: on a fresh `up`, seat an agent with the printed `AGENT:` line, post in #lobby from the WUI, expect a reply. If refused: `hub-init` pins box-wui (it holds the root key) under a generated WUI key | blocker 6 | orc + api | XS to measure, S to fix | a compose e2e (workflow 50's stack) where a WUI post in #lobby reaches a seated agent; control: unpin -> `wui_unpinned` |
| **N4** | Tenant hosts off by default for strangers: the cnf template (072 A7) ships `wui_tenant_hosts: false`; `do_spl_tenant_create` with hosts off chains no apply; sign-in on the apex with `?tenant=<t>` lands in that tenant | blocker 4; 072 A7, A12 | cnf + orc | S | flag off: `ENV=<env> DRY_RUN=1 TENANT_ID=x ./run -a do_spl_tenant_create` prints no host step; an e2e signs in on the apex into tenant `x` |
| **N5** | A second workspace on compose: `ENV=self ./run -a do_spl_tenant_create` (or a README section with the one `docker compose exec hub spool hub-tenant` line), printing the owner invite link and where the root key went | blocker 5; 072 A17 | orc + docs | S | on the compose stack, one command -> a second tenant whose owner signs in; the action's test green, or `grep -c hub-tenant README.md` >= 1 |
| **N6** | Timed fresh-tenant walk on both births: compose (T-a) and a dev test buy (T-b), from "workspace exists" to "an agent answers in #lobby", n >= 3 each, posted with the tree | 047 metric; 072 A16 | any lane | S | a results file in this directory with seconds per step, the sha and n; target < 10 min (047 W12) |
| **N7** | "Lost root key" gets a self-service answer: a `biz_owner` re-keys from Tenant settings (the hub mints a new pair, re-pins box-wui, shows the private key once; existing box pins stay until revoked) | 1.3 last cell; every root-key step until A5 lands | api + WUI | M | an e2e re-keys a tenant and seats an agent with the new key; the old key's next pin is refused |

**Ranked (section 2 rule):** N1 (unblocks the whole hosted leg, minutes of
work), N2 (without it the hosted leg "works" and no agent hears anyone), N3
(P1's default stack is the most-used path: prove it before strangers do),
then N4, N5, N6, N7. Blocker 3 is already A4 (prebuilt CLI) and A5 (join
tokens) in the spec; this file adds only the measured fact that the W12 block
is the first-agent bottleneck on every birth. Cost: N1-N7 add no running
resource; N4 removes one terraform apply and one certificate per workspace.

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | Enable workflow 40 now (`gh workflow enable 40_tenant-host-reconcile.yml`), as option A of 2026-09-30 implies? | **yes**: the code is revived; the switch is the only thing between a buyer and the app |
| Q2 | Should the hub pin box-wui itself at claim time (it holds the root key there for one request)? | **yes**: the alternative is an operator step per sale, which W1 removed for the owner seat |
| Q3 | Per-tenant hosts in the open-source default (P1, P2)? | **off**: apex + `?tenant=` needs no terraform per workspace; keep hosts on for our hosted estate only |
| Q4 | One workspace per compose stack as the documented P1 shape, with a second workspace as an advanced action (N5)? | **yes**: a self-hoster usually wants one; the advanced action keeps the door open without a WUI rebuild per tenant |
