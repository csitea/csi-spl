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

**Re-measured 2026-11-05 on `721fb9ad8` (`v8.5.6-c3-7-g721fb9ad8`; prd/dev served `0a639798a` / `8.5.6`).** The 2026-09-28 baseline (`4dc8df91`, `v1.9.2`) stays in each row for comparison; every verdict below is verified read-only by the command, commit or served build named.

### 1.1 A — self-hosted with docker compose (one machine)

A fresh `git clone https://github.com/csitea/csi-spl.git` into a throwaway
dir, run as the README says. On 2026-09-28 (`4dc8df91`) the docker project was `spl-stranger-35078` on
ports 18478/18479 (load average ~79, base images cached). Re-checked on `721fb9ad8` (read-only; container start / build times not re-measured).

| step | 2026-09-28 (`4dc8df91`) | 2026-11-05 (`721fb9ad8`) | command / evidence |
|---|---|---|---|
| clone | 37 MB, 8 s | **changed** (repo grew; clone/pull time not re-measured read-only; `.git` in a full clone is 614 MB; still needs a checkout for bind mounts `./csi-spl-api/src/docker/{pg-init.sh,secret-env.sh,local-secrets}`) | `du -sh .git` -> `614M`; `grep -nE 'pg-init\.sh\|secret-env\.sh\|local-secrets' docker-compose.yml` -> lines 86, 116, 159, 248, 360 |
| build hub + WUI from source | 241 s (required) | **changed — no build by default** (`docker compose up -d` pulls GHCR images pinned by sha256 digest: `ghcr.io/csitea/spool-{hub,web}:stable-2026-10-12@sha256:...`; anonymous pull HTTP 200; source build is opt-in via `SPOOL_IMAGE_TAG=local docker compose up --build -d`, build time not re-measured) | `251ab6f8d`, `fcb1a9115`, `925cfa259`; `docker-compose.yml:136,179,276`; `TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:csitea/spool-hub:pull" \| jq -r .token) && curl -sI -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" https://ghcr.io/v2/csitea/spool-hub/manifests/stable-2026-10-12` -> `HTTP/2 200` (and `spool-web` -> `HTTP/2 200`; `stable-2026-11-02` also `HTTP/2 200`) |
| start to healthy | 19 s | **not re-measured** (read-only; CI workflow `50_oss-standalone.yml` proves the stack healthy on every push, recent runs 4m27s-5m19s total job time) | `gh run list -w 50_oss-standalone.yml -L 5` -> 5/5 `✓` |
| sign up, confirm (on-screen link), sign in as owner | ~1 min | **still true on localhost** (`SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS: ${SPOOL_AUTH_DEBUG_LINKS:-true}`; not re-measured in browser) | `docker-compose.yml:212` |
| **first human message** | **6 min 26 s after the clone** | **not re-measured** (read-only; the 241 s local build is removed on the default image-pull path) | `251ab6f8d`, `docker-compose.yml:4` |
| agent seated + first agent message (manual CLI, 5 steps) | ~2 min, works | **changed** (`hub-init` prints a one-line `install.sh --env self` command; `install.sh` downloads prebuilt `spool-<os>-<arch>` from `stable-*` releases; admin can also mint a 1-hour join token so `spool join` / `install.sh --join` needs no root key; timing not re-measured) | `25e9b8b46` (W4), `c51bccc52` (W5), `d6525ec23` + `eb57b5a79` (A4), `d72e0654e` + `fbe002926` (073 T004/T005); `gh release view stable-2026-11-02 --json assets` -> 4 CLI binaries + `spool-SHA256SUMS` |
| idle RAM, whole stack | ~110 MiB (hub 27.7, web 34.5, pg 47.2) | **changed — ~220 MiB** (s3 `chrislusf/seaweedfs:4.48` added for embedded S3 adds ~134 MiB; re-measured in `86213217e` at 12 min idle: 222 MiB total = s3 134, pg 52, hub 20, web 16; not re-run here read-only) | `86213217e` (SPL-3763); `README.md:40-42`; `docker-compose.yml:100-101` |
| images | hub 79.5 MB, web 98.1 MB (uncompressed local build) | **changed** (published GHCR `stable-2026-10-12` compressed manifest layer sums: hub 24.7 MB, web 29.1 MB; `2454cef93` stripped `-s -w` on the `spool` binary; `6a00c67b4` unified one hub image; uncompressed size not re-measured) | `2454cef93`, `6a00c67b4`; GHCR v2 manifest `.layers[].size` sum: hub `24664360` B, web `29139243` B |
| own-domain profile (`SPOOL_HUB_ENV=prd`, Secure cookie, SMTP) | hub boots healthy | **changed** (`./run -a do_spl_self_host_up` preflights DNS A, ports 80/443, SMTP login and Docker before `up`; `hub-init` refuses default DB passwords off localhost and requires `SPOOL_OWNER_EMAIL` for a one-time owner invite; 3 secrets mounted via `/run/secrets`; `SPOOL_HUB_MAIL_PREFLIGHT=require` probes SMTP at start) | `54cacd571` (A2), `b4bed27d7` (W9+W18), `6fd95f4bd` (W7), `docker-compose.yml:59-64,148-156,236,358-365` |
| operator actions needed | **0** | **still true** (`0`: on localhost first verified sign-in = owner via `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER: auto`; off localhost `hub-init` prints the one-time owner invite link for `SPOOL_OWNER_EMAIL`) | `b4bed27d7`; `docker-compose.yml:218-221` |

The README quick start is accurate (`docker compose up -d` pulls prebuilt images; `SPOOL_IMAGE_TAG=local docker compose up --build -d` builds from source). A stranger needs no cloud account, no
OAuth app and no key to get humans chatting.

### 1.2 A — self-hosted on their own GCP with our terraform

**Verdict: still cannot run outside our estate without editing code and cnf (though G2 and the `BITBUCKET_APP_PASSWORD` half of G7 are removed, and G1/G5/G6 are partially reduced).**

| # | hard block (2026-09-28) | 2026-11-05 verdict | evidence |
|---|---|---|---|
| G1 | The project id is `${ORG}-${APP}-${ENV}`, derived from the module dir name (`csi-spl-iac` -> `csi-spl-dev`). Project ids are global and ours exist. | **changed — partially fixed** (`gcp-001` now reads `cnf_proj` (`env.gcp.gcp_project`) first and falls back to `${ORG}-${APP}-${ENV}`; `resolve-oap.func.sh` still derives `ORG`/`APP`/`PROJ` from `basename "$PROJ_PATH"` when unset) | `433151db6` (spec 072 A8); `grep -n "proj_id=" csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh` -> line 81 `proj_id="${cnf_proj:-${ORG}-${APP}-${ENV}}"`; `csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh:13` |
| G2 | 7 terraform `validation` regexes accept only `^csi-spl-(dev\|prd)-*$` names, which are also global bucket/site names. | **changed — removed** (all `^csi-spl` validation regexes replaced with generic resource-id rules in `433151db6`) | `grep -rn 'regex("^csi-spl' csi-spl-iac/src/terraform \| wc -l` -> `0`; `git merge-base --is-ancestor 433151db6 origin/master` -> exit 0 |
| G3 | A GCP organisation or folder is required. | **still true** (spec 072 T026 / A10 is still open) | `grep -n "GCP_ORG_ID or GCP_FOLDER_ID must have a value" csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh` -> line 62 |
| G4 | The cnf is our estate: 1251 lines in 4 yaml files, `spool-hub.ai` in 15 cnf files, and no blank template. | **still true (grown)** (2904 lines across the 4 yaml files, `spool-hub.ai` in 19 files under `csi-spl-cnf`, and no template dir yet; spec 072 T041 / A7 is still open) | `wc -l csi-spl-cnf/csi-spl/*.yaml` -> `2904 total` (1765 `all`, 478 `dev`, 175 `lde`, 486 `prd`); `grep -rl spool-hub.ai csi-spl-cnf \| wc -l` -> `19`; `ls csi-spl-cnf/csi-spl` -> no template |
| G5 | Only `dev` and `prd`; registrar actions are Gandi only. | **still true (9 tf files, down from 13)** (`contains(["dev", "prd"], var.env)` remains in 9 terraform files; 6 `gandi-*.func.sh` live in `csi-spl-orc/src/bash/run/`) | `grep -rln 'contains(\["dev", "prd"\]' csi-spl-iac/src/terraform \| wc -l` -> `9`; `ls csi-spl-orc/src/bash/run/gandi-*.func.sh \| wc -l` -> `6` |
| G6 | CI assumes our self-hosted runners and `GCP_KEY_CSI_SPL_{DEV,PRD}`. | **changed — partially fixed** (`10_ci-quality.yml` uses `vars.SPOOL_CI_RUNNER` falling back to `ubuntu-latest` on forks, `d8c60e64b`; 8 live-estate workflows have an estate guard, `8651ee708`; `do_spl_gh_wire` wires the 6 WIF repo vars, `6fa7d5959`; however `self-hosted` still appears 44 times across `.github/workflows/*.yml` and `GCP_KEY_CSI_SPL_` 79 times, with spec 072 T021 / A24 still open) | `d8c60e64b`, `8651ee708`, `6fa7d5959`; `cat .github/workflows/*.yml \| grep -c self-hosted` -> `44`; `grep -rn "GCP_KEY_CSI_SPL" .github/workflows/ \| wc -l` -> `79` |
| G7 | The infra stack demands `GITHUB_TOKEN`, and two of its targets demand `BITBUCKET_APP_PASSWORD`, which nothing reads. | **changed — `BITBUCKET_APP_PASSWORD` removed and `do-setup-tpl-gen` needs no `GITHUB_TOKEN`; `do-setup-app-inf` and `do-setup-tf-runner` still demand `GITHUB_TOKEN`** | `25c4080de` (W8), `5c74662d6` (A14 part 1); `grep -c BITBUCKET csi-spl-orc/src/make/setup-app-inf.func.mk` -> `0`; `grep -n demand_var-GITHUB_TOKEN csi-spl-orc/src/make/setup-app-inf.func.mk csi-spl-orc/src/make/setup-tpl-gen.func.mk` -> 4 targets in `setup-app-inf.func.mk` + `do-setup-tf-runner` in `setup-tpl-gen.func.mk:30` |

Counted from the tree on `721fb9ad8`, the path from zero, for us:

- 5 human prerequisites: a GCP org or folder, a billing account, an org-admin identity,
  a domain with NS delegation, and an SMTP account.
- gcp-000 (4 sub-steps) x 2 envs.
- The tpl-gen clone, the tf-runner stack, then **29 terraform step directories** (`ls -d csi-spl-iac/src/terraform/[0-9]* | wc -l` -> `29`, up from 15; includes per-env steps plus shared/offsite/satellite/wine-box steps).
- Secret seeds: `do_spl_secrets_check` and `do_spl_secrets_seed_all` (`25a9228a6`, spec 072 A30) now wrap the per-env seeds in `csi-spl-orc/src/bash/run/spl-*seed*.func.sh`.
- `do_spl_gh_wire` (`6fa7d5959`, spec 072 A11) sets the 6 WIF GitHub repo variables from step 017's outputs.
- The hub image build + push, the WUI deploy, and the Firebase certificate
  wait (10-25 min, CLE-35074).

Estimate (not re-measured, since that needs a second GCP org and spec 072 T051 `do_spl_estate_up` / T052 clean-room estate are still open): **2-3 working
days** for a GCP expert who has already forked and renamed everything. The
peers estimated 2-5 days (AGY-3506/3507/3508).

### 1.3 B — a paid tenant bought from Csitea (CLE-35079, measured on dev in Stripe test mode; re-checked 2026-11-05)

| step | 2026-09-28 (`4dc8df91`) | 2026-11-05 (`721fb9ad8`) | evidence |
|---|---|---|---|
| plan live on prd | card, 20 EUR, `available:true` | **still true** (`amount_cents:2000`, `currency:"eur"`, `available:true`, `pk_live_...` on prd; `pk_test_...` on dev via `007abb51c`) | `curl -s https://api.spool-hub.ai/api/v1/checkout/plan` -> `{"amount_cents":2000,"available":true,"currency":"eur","methods":["card"],"plan_id":"default","publishable_key":"pk_live_...","rail":"card"}` |
| pay -> signed webhook -> paid -> claim (root key minted once, 2nd claim 410) | **11 s** | **not re-measured** (read-only; proven on dev in `316951195` `do_spl_paid_owner_probe`) | `316951195` |
| **buyer signs in** | **refused on prd** until an operator runs `do_spl_hub_invite` | **changed — fixed (0 operator actions)** (`paidTx` writes a `biz_owner` `tenant_invites` row for the checkout email in the same transaction; claim JSON and `tenant_paid` mail say "Sign in with <email>"; another email is refused 403 `not_allowed`) | `0f7e82002`, `d1e27b0ad`, `316951195` (SPL-1161, 047 W1); `csi-spl-api/src/go/spool-hub-api/internal/store/payments_postgres.go:180` |
| tenant host `<slug>.spool-hub.ai` | stays `pending` for ever: workflow 40 is paused | **changed — fixed & active** (workflow `40_tenant-host-reconcile.yml` revived in `b3dbad08a` + `a982bff24` and enabled in GitHub Actions; runs every 15 min; meanwhile WUI `eccf5fcb9` + `aafdcc74a` stays on the apex and shows "your address is being prepared" instead of hopping to NXDOMAIN; on prd 21 `tenant_hosts` rows are `ready`, 0 `pending`) | `gh workflow list --all \| grep '^40'` -> `active`; `gh run list -w 40_tenant-host-reconcile.yml -L 5` -> 5/5 `✓`; `ENV=prd SQL="SELECT status, count(*) FROM tenant_hosts GROUP BY status ORDER BY status" ./run -a do_spl_db_query` -> `ready: 21, removed: 1` |
| live on prd | **0 checkouts ever**; all 10 prd tenants `billing_status=manual` | **still true (0 checkouts; 22 prd tenants: 21 `manual`, 1 `internal`)** (`payment_checkouts` has 0 rows on prd; W3 owner live test buy has not been run yet) | `ENV=prd SQL="SELECT status, count(*) FROM payment_checkouts GROUP BY status" ./run -a do_spl_db_query` -> `0 rows`; `SQL="SELECT billing_status, count(*) AS tenants FROM tenants GROUP BY billing_status ORDER BY billing_status"` -> `internal: 1, manual: 21` |
| billing model | one-off 20 EUR PaymentIntent; no renewal; refund/cancel -> `unpaid`, failed -> `grace` but the grace window is not timed; no VAT/invoice/terms page | **still true** (`billing.MapEvent` is still a one-off 20 EUR PaymentIntent; `de7e76126` updated the `grace` comment so it no longer claims a timer; seat caps exist in `7f2442caf`, but recurring subscriptions B4b are not built) | `csi-spl-api/src/go/spool-hub-api/internal/billing/`; `de7e76126` |
| buy page discoverability | nothing links to `/checkout` | **changed — fixed** (`efdb63247` W2 added the "Buy a workspace" link to `/checkout` in the prerendered shell and on `/login` with the 20.00 EUR price line) | `curl -s https://spool-hub.ai/ \| grep -ic 'checkout\|buy\|pricing'` -> `2` (was 0); `efdb63247` |

Operator actions per sale today: **0 required** (`paidTx` invites the buyer as `biz_owner`, WUI stays on the apex until `<slug>.spool-hub.ai` answers, and workflow 40 reconciles the host every 15 min; note: spec 072 F31 notes `paidTx` does not write a `box-wui` pin, and W3 live prd checkout has not been run yet).

### 1.4 Taking it into use once it exists (CLE-35084, replacing AGY-3505)

On 2026-09-28 (`4db84e2a`), a throwaway compose stack (`spl-use-35084`, hub on
127.0.0.1:18490, the images built for 1.1), n = 1 per clean pass (not re-run on 2026-11-05; read-only).

**The hub is not the slow part.** One scripted pass on a fresh stack
(`docker compose down -v`, then `up --wait`), through the hub API (2026-09-28 measurement):

| step | at (s) (2026-09-28) |
|---|---|
| stack healthy (images cached) | 20.0 |
| owner registers, verifies, signs in -> `biz_owner` | 20.6 |
| channel, epic + first issue (`SPL-1`, `SPL-2`) | 20.9 |
| invite `dev@`; the invitee registers and signs in | 21.4 |
| agent box `spool keygen` + `spool pin` with the root key | 23.9 |
| **first agent post in #lobby** (`spool send --channel lobby`, `spool hub-sync`) | **24.2** |

Team setup costs 4.2 s of hub work. On 2026-09-28 the stumbles U1-U8 below were identified; **all eight are now fixed or reduced on `721fb9ad8`**:

| # | stumble (2026-09-28) | 2026-11-05 verdict | evidence |
|---|---|---|---|
| U1 | Hosted: the buyer is not seated as owner (see 1.3) | **changed — fixed** (`paidTx` writes the `biz_owner` invite for the checkout email in the same transaction; apex fallback holds until wf 40 provisions the host) | `0f7e82002`, `d1e27b0ad`, `eccf5fcb9`, `aafdcc74a` |
| U2 | An agent is seated only from a shell holding the tenant root key. Tenant settings -> Agents says "No agent is seated in this tenant yet." with no next step. `spool` usage hides `hub-pin` / `hub-sync` / `hub-run`. `--root-key` takes only a file. A second `keygen --force` strands queued posts as `bad_sig` | **changed — fixed** (Workspace settings -> Agents has `ConnectAgentGuide.vue` (`adbfe24ef`, `496bfb803`) + `JoinTokensPanel.vue` (`db323e02b`) for `admin` (`agents.join`) to mint 1-hour single-use join tokens redeemed via `spool join` (`d72e0654e`) or `install.sh --join` (`fbe002926`), proven in < 60 s by wf 23 `08791c802`; `spool` usage lists 34 box verbs + `hub-pin`/`hub-sync`/`hub-run` (`504ae4d1e`); `--root-key` takes `<file \| key text \| - = stdin>`; note: `biz_owner` without `admin` still uses the root-key paste block, and spec 073 T009 switching the guide's default to join tokens is still open) | `spool` usage output; `504ae4d1e` (W17), `adbfe24ef` (W12), `496bfb803` (A65), `d72e0654e` + `fbe002926` + `db323e02b` + `08791c802` (spec 073); `gh run list -w 23_join-check.yml -L 5` -> 5/5 `✓` |
| U3 | MCP for Claude Code / Cursor is undocumented. `spool mcp --as <ID>` exists, but no user doc registers it. install.sh registers no MCP. `do_spl_agent_mcp_install` assumes our box-user/agent-user split. Cursor is named nowhere | **changed — fixed** (`adbfe24ef` W12 + `53f773713` A65: `ConnectAgentGuide.vue`, `README.md`, `DEPLOY.md` and `csi-spl-doc/doc/help/connect-an-agent.md` document `claude mcp add` and Cursor `~/.cursor/mcp.json`; `install.sh` registers MCP for selected CLIs) | `grep -rl "spool mcp" --include="*.md"` -> `README.md`, `DEPLOY.md`, `csi-spl-doc/doc/help/connect-an-agent.md` (+ 22 other docs); `grep -ci mcp csi-spl-orc/src/bash/features/spool-install/install.sh` -> `6` |
| U4 | With no mail relay, an invite answers `"mail":"sent"` although nothing was delivered. The WUI has no copyable invite link | **changed — fixed** (`dadb2295b` W13 answers `mail:"logged"` when no inbox is reached; `026d20be2` W13 adds "Copy invite link" on pending invites; `92b3997ed` adds a status column `expired / sent / not sent`) | `dadb2295b`, `026d20be2`, `92b3997ed` |
| U5 | An uninvited sign-in reads "This account cannot sign in here." and never says "ask your admin for an invite" | **changed — fixed** (`96b1caa06` W14 updates `not_allowed` to say "ask your admin for an invite" across 19 locales; `df6ab30b5` adds a clear "invitation expired" message) | `96b1caa06`, `df6ab30b5` |
| U6 | The first issue is refused without an epic (`epic_required ... (epic: SPL-n)`). Every tenant's keys are `SPL-n`, and no WUI or API setting changes the prefix | **changed — fixed** (`2e7e2a107` + `6bcb8b9d8` W16 allow level-2 issues without an epic and expose `issue_prefix` on `GET/PATCH /v1/tenant/settings` and in Workspace settings -> General) | `2e7e2a107`, `6bcb8b9d8` |
| U7 | 12 help pages exist (`ls csi-spl-doc/doc/help \| wc -l` -> 12), but the WUI links to none of them. `getting-started.md` points at `<tenant-name>.spool-hub.ai`. The first sign-in lands on "No topics yet." with no checklist | **changed — fixed** (29 help pages exist today; `96b1caa06` + `9ecaf3508` W14 serve `/help` from the `?` rail icon and `/login` with `{{api}}`/`{{site}}` filled from the running site and no `<tenant-name>.spool-hub.ai`; `c8bfa3154` W15 shows the 3-step first-run checklist for `admin`/`biz_owner`) | `ls csi-spl-doc/doc/help \| wc -l` -> `29`; `96b1caa06`, `9ecaf3508`, `c8bfa3154` |
| U8 | The installer needs a 37 MB clone, Go, and the `<dir>/csi/csi-spl` layout (it warns otherwise). It seats a tmux pane agent, not an IDE | **changed — partially fixed** (`eb57b5a79` + `d6525ec23` A4 download the prebuilt `spool-<os>-<arch>` binary from `stable-*` releases with `spool-SHA256SUMS` verification, building with Go only as a fallback; `f5d06ee8f` A49 makes fleet config opt-in (`--fleet`); `ConnectAgentGuide.vue` covers IDE MCP seating; `install.sh` itself is still invoked from a checkout) | `d6525ec23`, `eb57b5a79`, `f5d06ee8f`; `grep -c 'releases/download' csi-spl-orc/src/bash/features/spool-install/install.sh` -> `2` |

What a `biz_owner` (or `admin`) can do alone today (Workspace settings): invite (with copyable invite link and expiry date `access_until` via `d34d3eb9e` + `5d0db71ad`), set roles,
suspend, manage channels and responders, edit the issue key prefix (`W16`), create issues without an epic (`W16`), paste the "Connect an agent" block (`W12`), add a seated agent to `#lobby`, and (as `admin` with `agents.join` when box join is enabled) mint per-seat join tokens (`JoinTokensPanel.vue`, spec 073) and revoke seats from the WUI. What still needs an operator or a shell: re-keying a lost root key, direct account create (`046 T006`, still `[ ]` in `csi-spl-doc/specs/046-spool-tenant-settings/tasks.md`), and enabling `do_spl_box_join_switch` on a workspace before `admin` can mint join tokens.

All six Wave 1 quick wins proposed here (Q1-Q6 = W12-W17) and W19-W20 (`f53f5c81a`) have landed and are proven on `origin/master` (see section 5.1).

### 1.5 A vs B at a glance

| | A: compose self-host (2026-09-28 -> 2026-11-05) | A: GCP self-host (2026-09-28 -> 2026-11-05) | B: buy a tenant (2026-09-28 -> 2026-11-05) |
|---|---|---|---|
| time to first human message | **~6.5 min** (2026-09-28 with 241 s source build) -> **pulls prebuilt GHCR images by default** (`251ab6f8d`; pull time not re-measured read-only) | days (estimate), after a fork (still true) | unbounded (operator invite) -> **0 operator actions** (`paidTx` auto-invites buyer as `biz_owner` in `0f7e82002`; WUI stays on apex until wf 40 provisions `<tenant>.<fqdn>` in `eccf5fcb9` + `b3dbad08a`) |
| operator actions | 0 (still true) | n/a (they are the operator) | 1 per sale -> **0** (code path; live prd buy W3 still unrun) |
| agent seating | manual CLI, 5 steps; installer refuses -> **`install.sh --env self` (`25e9b8b46`) + prebuilt `spool` CLI (`eb57b5a79`) + join tokens (`fbe002926`) + WUI paste block (`adbfe24ef`)** | same | CLI + root key -> **WUI paste block (`adbfe24ef`) or `admin` join token (`db323e02b` + `fbe002926`, < 60 s in wf 23)** |
| blocked by our estate? | no | **yes** (G2 removed in `433151db6`, `BITBUCKET_APP_PASSWORD` removed in `25c4080de`; G1/G3/G4/G5/G6/G7-token still block) | n/a |
| proven in production | CI workflow 50 on every push (`5/5` recent runs green) + wf 56 GHCR images | no (spec 072 T052 clean-room estate open) | **no on prd** (`payment_checkouts` still 0 rows on prd; proven on dev via `do_spl_paid_owner_probe` `316951195`) |

## 2. Blockers, ranked (re-ranked 2026-11-05 on `721fb9ad8`)

Rank = how many would-be users it stops x how cheap it is to remove. Of the 12 blockers from 2026-09-28, **9 are resolved** on `origin/master` (blockers 1, 2, 4, 5, 6, 7, 8, 9, 12) and **3 remain open** (old blockers 3, 10, 11, now ranked 1-3 below).

### 2.1 Open blockers today

| rank (was) | blocker | path | severity | effort | 2026-11-05 verdict & evidence |
|---|---|---|---|---|---|
| 1 (was 3) | The paid flow has never run on prd (and `paidTx` writes no `box-wui` pin for a bought tenant, spec 072 F31) | B | high risk | 30 min owner (W3) + S (`box-wui` pin) | **still true** — `ENV=prd SQL="SELECT status, count(*) FROM payment_checkouts GROUP BY status" ./run -a do_spl_db_query` -> `0 rows` (all 22 prd tenants are `manual: 21, internal: 1`); W3 checklist in topic `bea3a4e6` (SPL-1164); `paidTx` in `csi-spl-api/src/go/spool-hub-api/internal/store/payments_postgres.go:180` |
| 2 (was 10) | No recurring billing, VAT, invoices or terms; no capped free tenant without a card | B | high (business): fixed prd bill vs one-off 20 EUR per tenant (4.2) | M-L | **still true** — `curl -s https://api.spool-hub.ai/api/v1/checkout/plan` -> one-off `amount_cents:2000`; `billing.MapEvent` (`csi-spl-api/src/go/spool-hub-api/internal/billing/`) has no subscription renewal (`de7e76126` rewrote the grace comment so it no longer claims a timer; B4a/B4b open) |
| 3 (was 11) | The GCP estate is not reusable out of the box (G3 org/folder required, G4 2904 lines of estate cnf with no template, G5 9 `dev`/`prd` checks + 6 Gandi scripts, G6 79 `GCP_KEY_CSI_SPL_` refs in workflows, G7 `GITHUB_TOKEN` on `tf-runner`) | A (GCP) | high (owner reversed D2 in spec 072 D1: byo-GCP is a supported path) | L | **partially reduced, still blocks** — G2 removed (`433151db6`), G7 `BITBUCKET_APP_PASSWORD` removed (`25c4080de`) and `do-setup-tpl-gen` token-free (`5c74662d6`), G1 reads `cnf_proj` first (`433151db6`), G6 wf 10 runner var (`d8c60e64b`) + estate guard (`8651ee708`) + `do_spl_gh_wire` (`6fa7d5959`); remaining items tracked in `csi-spl-doc/specs/072-rapid-deployability/tasks.md` (T020-T022, T026, T028, T029b, T030, T032, T041, T051, T052) |

### 2.2 Resolved since 2026-09-28

| old rank | blocker (2026-09-28) | path | resolved by (proof on `origin/master` `721fb9ad8`) |
|---|---|---|---|
| 1 | The buyer is not seated as owner after paying | B | **resolved (W1)** — `0f7e82002` + `d1e27b0ad` + `316951195` (SPL-1161): `paidTx` inserts a `biz_owner` `tenant_invites` row for the checkout email in the same transaction; `do_spl_paid_owner_probe` proves buyer login 200 (`biz_owner`) and other email 403 `not_allowed` |
| 2 | The installer refuses any hub that is not ours (`do_spl_desk_pin` pins `SPOOL_HUB_URL` to our cnf, ENV dev/prd only) | A | **resolved (W4)** — `25e9b8b46` (SPL-1167) + `f5d06ee8f` (spec 072 A49): `install.sh --env self` and `do_spl_desk_pin` accept any `SPOOL_HUB_URL` without cnf or `dev`/`prd` |
| 4 | Agent seating needs the root key + CLI; no join token or WUI flow; MCP for Claude Code / Cursor undocumented | A+B | **resolved (W12, B2/073, B3/072 A4)** — `adbfe24ef` + `496bfb803` (`ConnectAgentGuide.vue` + `/help/connect-an-agent` with `claude mcp add` and Cursor `mcp.json`), `2f50a9985` (join-token path in `/help/connect-an-agent`); `d72e0654e` + `fbe002926` + `db323e02b` + `08791c802` (spec 073 join tokens: `JoinTokensPanel.vue`, `spool join`, `install.sh --join`, wf 23 `23_join-check.yml` green in < 60 s); `d6525ec23` + `eb57b5a79` (`install.sh` downloads prebuilt `spool` CLI from `stable-*` releases) |
| 5 | The success page promises a host that never comes; the buy page is not linked anywhere | B | **resolved (W2 + B5)** — `efdb63247` (SPL-1162: "Buy a workspace" link on `/` and `/login`; `curl -s https://spool-hub.ai/ \| grep -ic 'checkout\|buy\|pricing'` -> `2`); `eccf5fcb9` + `aafdcc74a` (WUI stays on apex while `<tenant>.<fqdn>` is being prepared); `b3dbad08a` + `a982bff24` (workflow `40_tenant-host-reconcile.yml` revived and `active` in GitHub Actions, 5/5 recent runs green) |
| 6 | No prebuilt images; the public URL is baked into the WUI at build time | A | **resolved (B1 / spec 072 A1 + A3)** — `fcb1a9115` + `251ab6f8d` + `925cfa259` (`56_ghcr-images.yml` publishes `ghcr.io/csitea/spool-{hub,web}` on `stable-*`, anonymous pull HTTP 200, `docker-compose.yml` pulls by sha256 digest by default); `4a5957be3` (WUI reads `/config.json` at container start; `grep -c 'ARG SPOOL_PUBLIC_URL' csi-spl-wui/src/docker/wui.Dockerfile` -> `0`; note: `pg-init.sh` and `secret-env.sh` bind mounts still use the repo checkout, spec 072 T033 open) |
| 7 | No backup / upgrade / restore guide for compose | A | **resolved (W5 / O1)** — `c51bccc52` (SPL-1171) + `DEPLOY.md` (`c7ed917ad`): `README.md` section "Backup, restore and upgrade" + `DEPLOY.md` sections 2.4-2.5 (`grep -ciE 'backup\|upgrade\|restore' README.md` -> `11`) |
| 8 | Wrong version on a self-built stack (WUI v1.1.3, hub 0.1.0-dev, tree v1.9.2) | A | **resolved (W6)** — `fdce49592` (SPL-1174): `SPOOL_VERSION` build arg + `git describe --tags --match 'v[0-9]*'` fallback in `hub.Dockerfile` and `wui.Dockerfile` |
| 9 | No SMTP preflight: the prd profile starts green with a dead relay | A | **resolved (W7 + 072 A2)** — `6fd95f4bd` (SPL-1165: `SMTP.Probe` at hub start, `SPOOL_HUB_MAIL_PREFLIGHT=require` default in `docker-compose.yml:236`) + `54cacd571` (`do_spl_self_host_up` preflights DNS, ports and SMTP before `up`) |
| 12 | On a public domain the first verified sign-up becomes owner: whoever reaches a new instance first owns it | A | **resolved (W9 + W18)** — `b4bed27d7` (SPL-1176, SPL-1178): off localhost `hub-init` refuses default DB passwords, sets `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=auto` (off outside localhost), creates a one-time `biz_owner` invite for `SPOOL_OWNER_EMAIL` and prints the sign-in link |

## 3. Benchmark targets (CLE-35086, replacing AGY-3510)

AGY-3510's figures were not sourced, so they are replaced here. Each peer
number below is either **measured** on the box with `docker run` (a cold pull,
then start until HTTP 200, then `docker stats --no-stream` after 90 s idle on an
empty instance, n = 1, load average ~48), or **quoted** from the vendor's own
page on 2026-09-28. The spool column shows the 2026-09-28 baseline (`v1.9.2`) and the 2026-11-05 state (`v8.5.6-c3`, section 1.1).

### 3.1 Self-hosted peers, measured

| product | pull | start to HTTP 200 | idle RAM | image | domain change | first admin |
|---|---|---|---|---|---|---|
| Gitea 1.24 (SQLite) | 16.6 s | 3.0 s | 162 MiB | 259 MB | env var + restart | install wizard |
| Mattermost Team 10.11 + pg 16 | 71.8 s | 23.2 s | 323 MiB | 1.22 GB | env var + restart | first sign-up = admin |
| Rocket.Chat 7.10.0 + mongo 6 (replica set) | 275 s | 84.0 s | 772 MiB | 3.22 GB | env var + restart | 4-step wizard |
| **spool v1.9.2 (2026-09-28)** | build 241 s | 19 s | **~110 MiB** (3 containers) | 79.5 + 98.1 MB | **rebuild** | first verified sign-up = owner |
| **spool v8.5.6-c3 (2026-11-05)** | **GHCR pull by default** (time not re-measured) | not re-measured (wf 50 green) | **~220 MiB** (4 containers incl. s3 ~134 MiB, `86213217e`) | **24.7 + 29.1 MB** compressed GHCR layers | **env var + restart** (`/config.json` at start, `4a5957be3`) | localhost: first sign-up; public domain: **one-time owner invite for `SPOOL_OWNER_EMAIL`** (`b4bed27d7`) |
| Zulip (vendor, not run) | tarball + install script | "a few minutes" | vendor minimum 2 GB + 2 GB swap | apt | `--hostname` at install | one-time org-creation link printed by the installer |

Vendor sizing (under load, not idle): Mattermost 1 vCPU / 2 GB for up to 1000
users; Rocket.Chat Starter 2 vCPU / 4 GiB plus a 3-member Mongo replica set of
2 vCPU / 4 GiB each; Zulip 2 GB + swap.

Spool now publishes prebuilt GHCR images (`fcb1a9115`, `251ab6f8d`), changes its public URL via env var + restart (`4a5957be3` runtime `/config.json`, 0 rebuilds), and seats the first owner on a public domain via a one-time invite link (`b4bed27d7`). With SeaweedFS (`s3`) added to the compose stack, idle RAM is ~220 MiB (`86213217e`, `README.md:41`), still below Mattermost (323 MiB) and Rocket.Chat (772 MiB).

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

| metric | spool 2026-09-28 (`v1.9.2`) | spool 2026-11-05 (`721fb9ad8`) | benchmark | target |
|---|---|---|---|---|
| self-host: pull/clone to healthy | 268 s (8 + 241 + 19) | **prebuilt GHCR pull** (`251ab6f8d`; pull time not re-measured read-only) | Gitea 19.6 s, Mattermost 95 s (measured) | **< 60 s** with prebuilt images |
| self-host: stranger to first message | 6 min 26 s | **not re-measured** (241 s source build eliminated by default pull) | Mattermost ~95 s + sign-up (measured); Zulip "a few minutes" (vendor) | **< 5 min** on a fresh VM |
| self-host idle RAM | ~110 MiB (pg + hub + web) | **~220 MiB** (s3 134 + pg 52 + hub 20 + web 16, `86213217e`, stated in `README.md:41`) | 162 / 323 / 772 MiB (measured) | **keep < 200 MiB** (s3 added ~134 MiB; hub+web+pg alone are ~88 MiB), and say so in the README (done in `86213217e`) |
| domain change | a rebuild | **0 rebuilds** (env var + restart via runtime `/config.json`, `4a5957be3`) | env var + restart (3 of 3 measured) | **0 rebuilds** (**DONE**) |
| first owner on a public host | first verified sign-up wins | **one-time owner invite link** for `SPOOL_OWNER_EMAIL` (`b4bed27d7`) | Zulip: one-time link from the installer | **one-time owner link or token** (**DONE**) |
| hosted: card before value | yes | **still yes** (B4a open) | 0 of the hosted peers | **a capped free tenant, no card** |
| hosted: to first message | unbounded (operator invite) | **0 operator actions** (`0f7e82002` W1 + `eccf5fcb9` apex fallback + `b3dbad08a` wf 40; live prd buy W3 unrun) | minutes, 0 operator actions | **< 5 min, 0 operator actions** |
| price shape | 20 EUR one-off | **still 20 EUR one-off** (B4b open) | $3.50-16 per user per month | recurring, once billing renews (section 1.3) |
| agent seated | 5 CLI steps; the installer refuses a non-Csitea hub | **one pasted block** from WUI (`adbfe24ef` W12) or **one join-token line** (`fbe002926` + `d72e0654e`, < 60 s in wf 23); `--env self` accepts any hub (`25e9b8b46`) | a bot token pasted into a config (Slack, Discord) | **one pasted line** from the WUI (**DONE**) |

Sources: docs.mattermost.com/deployment-guide/software-hardware-requirements.html,
zulip.readthedocs.io/en/stable/production/requirements.html and
.../production/install.html, docs.rocket.chat/docs/system-requirements,
forums.rocket.chat/t/new-rocketchat-starter-plan-with-up-to-50-users/20851,
docs.gitea.com/installation/install-with-docker, about.gitea.com/pricing,
slack.com/pricing, linear.app/pricing, zulip.com/plans, mattermost.com/pricing,
discord.com/nitro. Measured run: topic `bea3a4e6`, CLE-35086 round 1
(msg `63f402e1`).

## 4. Operations and cost (CLE-35085, replacing AGY-3509)

Measured 2026-09-28; section 1 and 2.2 supersede 4.4 A, 4.6 and 4.7.3.

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
| W1 | `paidTx` writes a `tenant_invites` row (checkout email, role `biz_owner`) in the same transaction; its `expires_at` is at least the claim TTL; the claim page says "sign in with <email>" (`admitTx` admits only that verified email) | blocker 1 | S (~0.5 d) | hub (payments/store) + WUI copy | a paid test buyer signs in with the checkout email and lands as `biz_owner`, 0 operator actions; a different email is refused **DONE 2026-09-29 (SPL-1161, hub v2.2.6, commits 0f7e8200 d1e27b0a, probe 31695119), n=1 dev:** Stripe test buy `w1paid1` (`do_spl_checkout_stripe_test_buy`), then `do_spl_paid_owner_probe` -> buyer login 200, `/v1/view/me` role `biz_owner`, other address 403 `not_allowed`, 0 operator actions; store test memory+postgres with a control (invite write removed -> 2 red). prd runs the same hub; a live prd buy is W3. **BLOCKED end to end (2026-09-29, CLE-35094, dev n=2):** after sign-in the WUI hops to `<tenant>.<fqdn>`, which is never provisioned for a paid tenant (NXDOMAIN; workflow 40 paused), so the buyer never reaches the app (metric 3 = 0). Owner question A (B5 now) / B (apex until the host is ready) / C (drop hosts) in topic `bea3a4e6` — unblocked by `eccf5fcb9` + `b3dbad08a` (2026-11-05: wf 40 active, 21 hosts ready) |
| W2 | Checkout copy: drop "being prepared"; say where the tenant is. Add a "Buy a workspace" link + a price line on the landing and login pages | blocker 5 | XS | WUI | `curl -s https://spool-hub.ai/ \| grep -ic checkout` >= 1 **DONE 2026-09-29 (SPL-1162, WUI v2.2.7, efdb6324), n=1:** `curl -s https://spool-hub.ai/ \| grep -ic checkout` -> 1 (was 0); `/login` shows "Buy a workspace · One tenant: 20.00 EUR" (headless Chrome, prd en+bg, dev). The "being prepared" notice (`CheckoutHostStatus.vue`) is not mounted anywhere; the key reveal says where the workspace is and "Sign in with <email>" |
| W3 | One owner-run live buy + refund on prd | blocker 3 | 30 min owner | owner | 1 prd checkout paid, refunded -> `unpaid` **Owner action; checklist posted in topic `bea3a4e6` by CLE-35091 (SPL-1164)** |
| W4 | `do_spl_desk_pin` / install.sh accept any `SPOOL_HUB_URL` when told it is self-hosted (no cnf match, no ENV) | blocker 2 | S | orc (installer) | the stranger test seats an agent with install.sh |
| W5 | hub-init prints the one-line agent seat command; README gains "Connect an agent" + "Backup, restore and upgrade" sections (O1) | blockers 2, 7 | S | docs + api | stranger to first agent message < 10 min, following the README only |
| W6 | Stamp the real version into the self-built images (`git describe` build arg) | blocker 8 | XS | api + WUI | `/version` = the tag |
| W7 | Mail preflight at hub start in prd mode (log a loud error, or refuse to start) | blocker 9 | S | api | a dead relay is visible at `up` |
| W8 | Drop the unused `BITBUCKET_APP_PASSWORD` demand | G7 | XS | orc | `grep -c BITBUCKET setup-app-inf.func.mk` -> 0 |
| W9 | hub-init refuses the public default DB passwords when the site is not localhost (O2) | 4.7.1 | XS | api | `up` with defaults on a domain fails loudly |
| W10 | A `stable` release tag cut weekly from trunk, with generated release notes (O5); the benchmark shape is Mattermost's monthly releases with security backports to the last 3 ([release policy](https://docs.mattermost.com/product-overview/release-policy.html)) | 4.5 | S | CI | a self-hoster can pin a release and read what changed |
| W11 | Owner cost call: dev hub at 0.5 vCPU or scale-to-zero (O3) | 4.2 | XS | iac (tf 030, owner go) | ~$20-45/month saved (estimate) |
| W12 | "Connect an agent" empty state in Tenant settings -> Agents with the exact lines to paste, including `claude mcp add` and a Cursor `mcp.json` (Q1; B2 replaces it later). Ships in the same batch as W1, so a paid buyer can also seat an agent | U2, U3 | S | WUI + docs | a biz_owner has an agent answering in #lobby within 10 min, from the WUI + one pasted block **DONE 2026-09-29 (SPL-1166, WUI v2.3.0 adbfe24e; proof script d69af91d `onboarding-live.proof.mjs`), n=1 dev t1 + n=1 prd e2e:** the block copied from Tenant settings -> Agents ran in a fresh HOME rc 0 (dev 105 s, prd 139 s; stranger clone+build of the block alone 142 s), the agent appeared, Add to #lobby, a #lobby post was answered by `claude -p` through the spool MCP the block registered (dev 25 s, prd 28 s after the post); dev sign-in to the answer ~5 min 23 s (< 10 min), including one failed agent start (the box user's claude login was revoked). Not measured on a freshly bought tenant: after sign-in the WUI hops to its never-provisioned host (SPL-1161 blocked, CLE-35091, options to the owner) |
| W13 | Invite answers `mail: "logged"` when nothing was delivered; the pane gets "copy invite link" (Q2) | U4 | S | api + WUI | no false "sent" **DONE 2026-09-29 (SPL-1163, hub dadb2295, WUI 026d20be v2.2.7):** a sink that reaches no inbox answers `logged` (`hub-pg.tst.sh`, invitemail test); dev+prd use smtp, so their `sent` is real; a pending invite has "Copy invite link" (`<origin>/login?tenant=<t>`, users-admin e2e 10c through the clipboard) |
| W14 | A Help entry in the WUI serving `doc/help`, with the host fixed; an uninvited sign-in says "ask your admin for an invite" (Q3 + U5) | U5, U7 | S | WUI + docs | help reachable in 1 click **DONE 2026-09-29 (SPL-1169, WUI v2.2.5 96b1caa0 + 9ecaf350):** a ? at the rail foot and on the sign-in page opens /help, which renders doc/help (a synced copy; the hosted domain becomes {{api}}/{{site}} filled from the running site); one sign-in address in the pages; not_allowed says "ask your admin for an invite" (19 locales). Live n=1 dev t1 + n=1 prd e2e: 1 click -> /help rendered; e2e help 19/19 |
| W15 | A first-run checklist for a biz_owner (Q4) | U7 | S-M | WUI | first sign-in shows the next 3 steps **DONE 2026-09-29 (SPL-1172, WUI v2.3.1 c8bfa315):** home-screen card for whoever may open Tenant settings: invite / connect an agent / first topic, each linked and ticked from what the hub answers, gone when all 3 are done or on Hide. Live n=1 prd e2e (biz_owner): the 3 steps shown (invite open, agent and topic done); dev t1 (set up): not shown (control); mock e2e 8/8. The literal fresh-tenant first sign-in is blocked by the tenant-host hop (see W12) |
| W16 | Issues without an epic; the issue prefix in Tenant settings -> General (Q5) | U6 | S | api + WUI | first issue created without an epic **DONE 2026-09-29 (SPL-1175, hub v2.2.0 2e7e2a10, WUI v2.2.1 6bcb8b9d):** a level-2 issue needs no epic (and takes subtasks); `issue_prefix` on GET/PATCH /v1/tenant/settings (tenant.settings only) and in Tenant settings -> General. Live n=1 dev t1 (SPL-41) + n=1 prd e2e (SPL-49): created from the new row with No epic -> epic "", level 2, deleted again; hub test with a control (old rule -> red) |
| W17 | `spool` usage lists the `hub-*` verbs; `--root-key` also takes key text (Q6) | U2 | XS | api | `spool` with no args names every verb **DONE (`504ae4d1e`)** |
| W18 | Off localhost, hub-init prints a one-time owner link (Zulip style) and the open first-sign-up rule is off | blocker 12 | S | api + docs | a second person cannot claim a fresh public instance |
| W19 | Owner request (topic `bea3a4e6`, 2026-09-28): "the app settings should be in the left most vertical panel, and not in the version model". Settings get their own entry in the leftmost vertical panel, apart from the version stamp/card in the sidebar footer (`ChannelSidebar.vue` `app-version-*`) | taking into use | S | WUI | settings reachable from the leftmost panel in 1 click; the version card shows only the version **DONE (`f53f5c81a`)** |
| W20 | Owner request (topic `bea3a4e6`, 2026-09-28): "the users icon on the left most panel can be removed" ... "so that the users CRUD will be accesible only from the app settings". Users CRUD lives only in settings (Tenant settings -> Members, 046) | taking into use | XS-S | WUI | the leftmost panel has no Users entry; no users CRUD is reachable outside settings; e2e that opened it goes via settings **DONE (`f53f5c81a`)** |

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
