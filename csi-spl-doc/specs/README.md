# csi-spl git-spec — index, redo ground rules, integrator decisions

This file is the **in-repo authority for the git-spec redo** started
2026-09-18. It holds three things: the rules every spec area follows, the
index of spec dirs (numbering and cross-references), and the cross-spec
decisions the integrator has taken. Area specs link here instead of restating
them.

Owner of this file, of the numbering and of the final cross-spec consistency
pass: the **integrator** lane. Each `NNN-*` dir is owned by its area lane.

---

## 1. Why the redo

The git-spec grew across ~30 parallel lanes and drifted: specs contradicted
each other (002/003/004/006/007), tasks were ticked from agent reports rather
than from artifacts, and one gap went unnoticed end to end — **no terraform
step creates the Cloud DNS managed zone for the product domain**
(`031-gcp-hub-ingress/06-dns.tf` only writes records into an *assumed*
`var.dns_managed_zone`, and cnf sets it to `""`), with DNS sequenced last
instead of first.

---

## 2. Ground rules (every area lane)

1. **`002-box-agent-messaging` is kept untouched.** Local messaging is shipped.
   Other specs cite it; nobody edits it in this redo.
2. **Trust reality, not reports.** Every *Implemented* claim is checked against
   the artifact: `git show` / `grep` for code, `terraform state list` / `plan`
   for infra, `gcloud … --account=$GCP_ACCOUNT` for live GCP, the test suite for
   behaviour. A claim about a file cites the command and its result
   (`grep -c X file -> 3`), not a paraphrase.
3. **Status vocabulary** on every FR and task:
   - **Implemented** — artifact exists and was verified (cite sha or command).
   - **Partial** — some of it exists; say which part is missing.
   - **Planned** — nothing built yet.
4. **Docs only.** A spec that needs code, cnf, iac, orc or wui to change writes
   it as a **task**; it does not make the change.
5. **One dir per lane.** Edit only your own `specs/NNN-*/**`. Seams between
   dirs are the integrator's (section 5).
6. **Stamp** every changed doc on its last line:
   `<!-- version: X.Y.Z · updated: YYYY-MM-DD · last-edit: <ISO-8601-UTC> -->`.
7. **Distribution hygiene** (repo `CLAUDE.md`, CI `10_ci-quality.yml` sweep): no
   personal names, OS users, owner mail addresses or their domains, no
   `/home/<user>/` paths. Write `$GCP_ACCOUNT`, never a literal account.
8. Git: rebase onto `origin/master` before every push, pathspecs under
   `csi-spl-doc/specs/<your-dir>/`, the repo's author identity, no AI trailer.

---

## 3. Binding authorities (reconcile to these)

| Topic | Authority |
|---|---|
| Local unsigned vs hub box keys | `002-box-agent-messaging/contracts/trust-modes.md` |
| Milestone cut M1/M2/M3/M4 | `../doc/md/SPEC-spool-milestones.md` |
| Ids, pins, routing | `../doc/md/SPEC-spool-identity-routing.md` |
| Bus narrative | `../doc/md/SPEC-spool-message-bus.md` |
| Box API (CLI + MCP) | `../doc/md/SPEC-spool-box-api.md` |
| `task_id` / `kind` | `../doc/md/SPEC-spool-task-lifecycle.md` |
| WUI | `../doc/md/SPEC-spool-wui.md` |
| Rental / tenancy | `../doc/md/SPEC-spool-hub-rental.md` |
| Hub infra shape | `../doc/md/SPEC-spool-hub-api-infra.md` |
| Relay estate | `../doc/md/csi-spl.feature.md` |
| 003 open questions OQ-01..15 | folded into `003-spool-message-bus/spec.md` (Clarifications) |

### 3.1 Canon every spec respects

- **Trust:** local mode is **unsigned** (no keys). Hub mode is **one Ed25519
  key per box**; agents share it. `from_box` / `to_box` exist **only in the
  hub envelope**. Send result `delivery` is `local | sent | queued | pending`.
- **Hub wire:** send/recv/tail are **WebSocket only** (`/v1/ws`, hello is
  challenge-response over a hub nonce, `role=box|cli`); REST is **files and
  pins only**. No NATS, no SSE in M1. `max-instances=1` in M1.
- **Milestones:** **M1** local + hub proof on the product domain (IP allowlist
  ingress, owner-made tenants, CLI + MCP, no browser, no checkout) ·
  **M2** buy on the site (thin checkout, one-time root-key email) ·
  **M3** Slack-like WUI (reverse-prepend default, 013) · **M4** seats + buy-minute project id ·
  **later** CI logs in chat, BYO GCP.

---

## 4. Index — spec dirs, owners, milestone

Numbering is **kept as-is** (no dir is renamed in the redo; every existing
`specs/NNN-…` citation stays valid).

| Dir | Area | Milestone | Redo lane |
|---|---|---|---|
| `001-relay-bucket-estate/` | git-rel GCS relay estate (retro) | pre-M1 | area lane 001 |
| `002-box-agent-messaging/` | local folder spool, CLI + MCP, `trust-modes.md` | M1 (shipped) | **frozen** |
| `003-spool-message-bus/` | the hub: `spool serve` WS + REST, `hubclient`, store, blob, `spool migrate`, read-only viewer API for the WUI | M1 (+ viewer API for M3) | area lane 003 |
| `004-spool-identity-routing/` | agent ids, box ids/keys, pins, tenant root, `BOX-` forbidden | M1 | area lane 004 |
| `005-spool-wui/` | Slack-like WUI (Nuxt), its hub read-API dependency | M3 | area lane 005 |
| `006-spool-hub-rental/` | tenancy, root-key pinning, quota/unpaid, payment | M1 (tenancy) / M2 (payment) | area lane 006 |
| `007-spool-hub-api-infra/` | the cloud estate in provisioning order (section 6), lde, orc, rdb pointer | M1 | area lane 007 |
| `008-spool-cicd-logs/` | CI/CD: GitHub Actions build + deploy (dev, prd; WIF) + ci-quality gate (**M1**), and CI logs posted into chat (**later**) | M1 + later | area lane 008 |
| `009-spool-m4/` | seats + buy-minute project id | M4 | integrator (seam fixes only) |
| `010-spool-social-auth/` | social IdP login for humans (`../doc/md/SPEC-spool-social-auth.md`): hub `/auth/*`, signed session cookie (`internal/auth`); Google + Facebook first, Microsoft / LinkedIn / xAI on the same rails | M2 (register) / M3 (WUI login) | social-auth lane |
| `011-spool-project-refactor/` | whole-project refactoring: Go backend clean architecture, WUI 3-pane reverse layout & client adapter, config schema validation, orc namespacing, spec reconciliation | M1–M3 consolidation | core architecture |
| `012-spool-box-api/` | uniform box API (CLI verbs, five MCP tools, exit 78) re-verified, plus the standard box launcher `spool-harness.sh` (orc) | M1 | box-api lane |
| `013-spool-chat-reverse/` | WUI chat reverse: top omnibox, prepend feed, 3-pane, avatars (`../doc/md/SPEC-spool-chat-reverse.md`) | M3 | chat-reverse lane |
| `014-spool-wui-dispatch/` | WUI dispatch: box-wui key signing, browser-to-box task dispatch, pin controls | M3 | dispatch lane |
| `015-spool-native-auth/` | native email + password sign-in, argon2id hashing, email verification, password reset | M3 | native-auth lane |
| `016-spool-testability/` | test inventory, skip-as-failure CI policy, dual-driver proofs | cross-cutting | integrator |
| `017-spool-security-hardening/` | threat mitigation, DB owner/runtime split (`spool_hub_rt`, DML-only), RLS enforcement (`0014`/`0021`), secret separation (`csi-spl-hub-db-owner-dsn`), in-app edge limits | M3/M4 consolidation | security lane |
| `018-spool-auth-microsoft/` | Microsoft Entra ID / Microsoft identity platform sign-in, PKCE, RS256 JWKS cache, branded lockup | M3 (WUI login) | CLE-3386 |
| `019-spool-auth-linkedin/` | LinkedIn OIDC sign-in, branded mark, secret seed action | M3 (WUI login) | CLE-3387 |
| `020-spool-message-v2/` | message schema `v:2`, canonical JSON, version negotiation (`wire.Frame.MsgVersions`), dual-version readers | M3 consolidation | message-v2 lane |
| `021-spool-wui-i18n/` | WUI + hub i18n: 19 locales, donor language switcher, cookie/browser redirect, default locale `en`, `humans.preferred_locale` | M3 | CLE-3403 |
| `022-spool-wui-top-bar-search/` | WUI persistent top bar, global search omnibox (`/search`), operator picker, grouped results | M3 | wui-topbar-search lane |
| `023-spool-user-settings-keys/` | GitHub-style user settings navigation, `/settings/keys`, in-browser Ed25519 keypair generation, public key upload / private download; Appearance font size, 5 levels (3.5) | M3 | CLE-3408, CLE-3495 |
| `024-spool-tenant-hosts/` | per-tenant hosts, automated DNS reconcile (**SUPERSEDED** by 026: paused, mappings retired) | M1/M2 | CLE-3404 (**superseded**) |
| `025-spool-tenant-rbac/` | tenant roles and permissions in DB (`0021_tenant_rbac.sql`: product owner, biz owner, admin, developer, tester, pure agent) replacing binary owner/member | M3/M4 | CLE-3414 |
| `026-spool-tenant-from-identity/` | tenant from identity, not Host: single API host `api.<domain>`, `X-Spool-Tenant`, session `t`, per-tenant CNAMEs destroyed | M2/M3 | CLE-3415 |
| `027-spool-performance/` | pool tuning (8 conns), in-memory pin/tenant hotCache, concurrent blob Exists, indexed ViewThreads (`0022`), chunked retention sweeper (`0024`) | M3 consolidation | CLE-3413 (ORC-PERF) |
| `028-spool-terminal-delivery/` | message visible in recipient agent's pane: renderer, doorbell, `spool-notify.sh`, shell-inert poke line | M3 | CLE-3428 |
| `029-spool-db-backup-health/` | read-only DB health action, daily off-instance backup, restore proof | M3 ops | CLE-3430 |
| `030-spool-wire-fastpath/` | warm submit socket and box-side keepalive; no new hub envelope | M3 | CLE-3436 |
| `031-spool-owner-acceptance/` | owner acceptance register `cases.tsv` plus the gate that the named test exists | M3 | CLE-3438 |
| `032-spool-message-edit/` | edit a sent message; append-only `message_revisions` | M3 | CLE-3443 / CLE-3445 |
| `033-spool-message-levels/` | level 1 (topic opener, middle card, `is_parent = 1`) vs level 2 (thread line, right pane only, `is_parent = 0`); the pane selected last decides | M3 | message-levels lane |
| `034-spool-topic-gist/` | download the gist of one topic (one `task_id`: level-1 opener plus level-2 lines); what the gist contains is an open question | M3 | topic-gist lane |
| `036-spool-terminal-mirror/` | a seated agent's terminal prompts and final answers posted into its DM with the human (claude + grok hooks), redacted, never echoing the web UI's own words; backfill + check actions | M3 | CLE-3496 |
| `037-spool-agent-install/` | `install.sh`: any user with bash + git gets the latest claude / grok / agy, the harness and `spool-agent` on PATH, the mirror hooks, and a box seat (pinned with the root key, or PENDING until the tenant admin pins it) | M3 | CLE-34966 |
| `038-spool-agent-channel-post/` | an agent posts a new topic into a channel like a human (`spool send --channel`, MCP `channel`, `do_spl_desk_post`); members only (404 otherwise); every other member agent receives it, the sender does not | M3 | CLE-34979 |
| `039-spool-issues/` | issues the way Linear keeps them: key `SPL-12`, status workflow, priority, level, assignee (human or agent), labels, deadline with time; rail tab after Channels, grouped list, right-pane detail + discussion topic; agents file and advance their work as issues | M3 | CLE-34993 |

**008 keeps its dir name.** Its scope widens to the whole CI/CD area: the
pipeline (`.github/workflows/10_ci-quality.yml`, `20_hub-build-deploy.yml`) is
an M1 user story, and the CI-logs-in-chat feature stays a separate, *later*
user story in the same spec. Renaming the dir would break citations in
`SPEC-spool-milestones.md` and `SPEC-spool-cicd-logs.md` for no gain.

Dependency order between specs:
`002 → 004 → 003 → 007 (+008 pipeline) → 006 (M1 tenancy) → M1 demo →
006 (M2 payment) → 005 (M3) → 010 (social auth) → 014 (wui dispatch) →
015 (native auth) → 016 (testability) → 011 (refactor consolidation) →
017 (security hardening) → 018/019 (MS/LinkedIn auth) → 020 (message v2) →
021 (i18n) → 022 (top-bar search) → 023 (user keys) →
024 (tenant hosts, superseded) → 025 (tenant RBAC) →
026 (tenant from identity) → 027 (performance) → 028 (terminal delivery) →
029 (db health + backup) → 030 (wire fast path) → 031 (owner acceptance) →
032 (message edit) → 033 (message levels) → 034 (topic gist) →
038 (agent channel post) → 009 (M4) → 008 (CI logs in chat)`.

---

## 5. Seams — who writes what where two specs meet

| Seam | Owner of the text | The other spec |
|---|---|---|
| `trust-modes.md` wording | 002 (frozen) | everyone cites `trust-modes §N` |
| Hub envelope, WS frames, REST files/pins, error envelope | 003 `contracts/` | 004, 006 cite; do not restate |
| Pin semantics (409, `--force`, history, revoke, sync) | 004 | 003 cites for the REST shape |
| Tenant host resolution, root key, quota 429, unpaid 402 | 006 | 003 cites the status codes; amended by 026 (tenant from identity) |
| WUI read API (endpoints the viewer calls) | 003 `contracts/` | 005 cites and depends |
| Terraform steps, DNS, secrets, WIF, lde | 007 | 003/006 name cnf keys, never tf |
| WIF deploy identity (tf step `017`) | 007 | 008 consumes the repo variables it exports |
| Pipeline jobs, gates, deploy matrix | 008 | 007 references the deploy action |
| Whole-project refactoring boundaries, adapters & contracts | 011 | 003, 005, 006, 007, 008, 010 cite for clean architecture & adapter rules |
| Test layers, skip-pass policy, what CI must run | 016 `contracts/test-layers.md` | 008 owns the YAML; 016 inventories and files tasks 008/api/wui execute |
| Database owner/runtime split, DML role `spool_hub_rt`, RLS enforcement | 017 `contracts/security-baseline.md` | 003, 007, 008 cite it; 007 provisions role + secret; 003 runs as `spool_hub_rt` |
| Microsoft / LinkedIn OIDC providers and client descriptors | 018, 019 `spec.md` | 010 owns `/auth/*` rails and session cookie; 018/019 define provider-specific scopes and token exchange |
| Message schema `v:2`, canonical JSON, wire versions | 020 `contracts/message-schema-v2.md` | 002 (frozen v1), 003 (envelope), 008, 014 cite |
| WUI + hub i18n catalogues, `X-Locale`, default locale `en` | 021 `spec.md` | 005, 010, 015 cite; 023 consumes for settings |
| Global search grammar, parser, omnibox `/search` | 022 `spec.md` (no `contracts/` dir: `git ls-tree -r --name-only origin/master csi-spl-doc/specs/022-spool-wui-top-bar-search/` -> `spec.md`, `tasks.md`) | 003 implements hub search; 005 / 013 top-bar layout consumes |
| Human Ed25519 user keys (`/settings/keys`) | 023 `contracts/keys-v1.md` | 010 (auth), 014 (dispatch) cite |
| Per-tenant hosts automated DNS (superseded) | 024 `spec.md` | **Superseded by 026**; mappings destroyed, single API host |
| Tenant RBAC roles (`product_owner`, `biz_owner`, `admin`, `developer`, `tester`, `agent`) | 025 `spec.md` | Amends 010 two-role model (`owner` \| `member`); 003/014 enforce |
| Single API host `api.<domain>`, tenant from identity/session/token | 026 `spec.md` | Amends 003 FR-015 / OQ-07, 004, 006 FR-002, 010 SEC-001; supersedes 024 |
| Hub connection pool (8), hotCache, batch roster, chunked retention | 027 `spec.md` | 003, 007, rdb cite for performance budgets |
| Terminal delivery, pane doorbell & poke line | 028 `contracts/poke-line.md` | 002 (inbox write), 003 (`hub-run` sidecar), 012 (`spool-harness`) cite |
| DB health action, daily backup bucket `045`, restore proof | 029 `spec.md` + `tasks.md` | 007 provisions `045`; 008 does not own workflow `45` |
| Warm submit socket, hello `caps`, box keepalive | 030 `contracts/fastpath-v1.md` | 003 envelope unchanged; 020 mixed-fleet rule; 028 terminal leg |
| Owner acceptance rows | 031 `cases.tsv` | each row names the spec that owns the behaviour |
| Message edit request, frame, register | 032 `contracts/message-edit-v1.md` | 003 stores it; 005 browser shortcut |
| `messages.is_parent`, browser send field, level rule | 033 `spec.md` | 003 stores and returns it; 005 decides it from the pane selected last; 032 double-click edit at both levels |
| Topic gist of one `task_id` | 034 `spec.md` | 034 reads what 003 serves; 005 draws the control |
| Terminal -> DM mirror, `typed` / `peer` records, redaction | 036 `spec.md` | 028 terminal leg records them; 003 stores the posts; 012 desk seat |
| Installer, `spool-agent` on PATH, box pin without an agent (`do_spl_desk_pin`) | 037 `spec.md` | 036 wrapper + hooks; 012 box key / pin; 028 desk seat |
| Agent channel post: box-signed channel tag, member-only rule, same-box fan-out | 038 `spec.md` | 003 channels-v1 envelope + routing; 033 `is_parent`; rdb 0028 / 0036 membership; 028 desk seat |
| Issues: rdb 0047, issues-v1 routes + `issue` frames, discussion topic in `#tasks` | 039 `contracts/issues-v1.md` | 003 view door + browser socket; 005 panes; 025 permissions; 033 reply level for comments |

---

## 6. Canonical provisioning order (007 encodes it; others cite it)

Per environment, **dev fully, then prd**. DNS comes **before** anything that
needs a name, and ingress comes **last**:

| # | Step | Terraform / action |
|---|---|---|
| 1 | remote state | `000-gcp-remote-bucket` |
| 2 | enable services | `001-enable-gcp-services` |
| 3 | **DNS managed zone** for the product domain (import, never recreate) + owner-gated nameserver handoff | `025-gcp-dns-zone` (new, prd only; dev records live in the prd zone) — 007 |
| 4 | Cloud SQL Postgres | `040-cloud-sql-postgres` |
| 5 | GCS files bucket | `050-gcs-files` |
| 6 | Artifact Registry | `028-gcp-artifact-registry` |
| 7 | build + push the hub image | `do_build_push_hub_image` |
| 8 | DB user + DSN secret version + `spool migrate` | `do_spl_db_bootstrap` |
| 9 | Cloud Run hub | `030-cloud-run-hub` |
| 10 | ingress: LB + wildcard managed cert + apex / `*.` records | `031-gcp-hub-ingress` |

`020-gcp-relay-bucket` (the git-rel relay, spec 001) is **not in this chain**: it
depends only on step 2 and nothing in the hub chain depends on it, so it is an
independent branch after step 2.

007 numbered the new DNS-zone dir `025-gcp-dns-zone` (csi-rel/pas-psf call it
`007-dns`); the full gate-per-step table is
`007-spool-hub-api-infra/contracts/provisioning-order.md`.

### 6.1 Measured DNS state (2026-09-18T19:05Z) — read before writing the DNS step

| Check | Result |
|---|---|
| `dig +norec NS spool-hub.ai @v0n1.nic.ai` (the `.ai` TLD) | `ns-166-a`, `ns-194-b`, `ns-143-c` `.gandi.net` |
| `gcloud dns managed-zones list --project=csi-spl-prd` | `spool-hub` · `spool-hub.ai.` · `ns-cloud-e1..e4.googledomains.com` (hand-made, only NS + SOA) |
| `gcloud dns managed-zones list --project=csi-spl-dev` | none |
| `dig +short A spool-hub.ai` | Gandi parking address |

So at 19:05Z the Cloud DNS zone **existed but was not delegated**.

**Update, measured 2026-09-18T19:44Z (n=1 each, read-only): the handoff has
happened, outside the repo.**

| Check | Result |
|---|---|
| `dig +norec NS spool-hub.ai @v0n1.nic.ai` | `ns-cloud-e1..e4.googledomains.com` (TTL 3600) |
| `dig +short @ns-cloud-e1.googledomains.com A spool-hub.ai` | empty: **the apex no longer resolves** |
| same for `www.spool-hub.ai` | empty: the Gandi `www` redirect is gone |
| same for `t1.dev.spool-hub.ai` | `136.68.5.155` (the dev `*.dev` A record is in the zone) |

Option A was then **decided and completed** (`57c82ba`, 007): `025-gcp-dns-zone`
adopts the zone (`9ed50ac`), the `ns-cloud-*` refusal is lifted (`1b78621`),
and the apex and `www` point at the prd hub load balancer instead of Gandi
parking. Measured 2026-09-18 ~20:20Z (n=1 each):

| Host | A (from `ns-cloud-e1`) | `curl …/version` |
|---|---|---|
| `spool-hub.ai`, `www.`, `api.` | `34.54.10.95` (prd LB) | 200 |
| `dev.spool-hub.ai`, `dev.api.` | `136.68.5.155` (dev LB) | 200 |

The earlier "stay on Gandi" text (`300a998`, `cb25346`) is superseded for
DNS authority. `api`, `www` and `dev` are reserved tenant labels
(`msg.ValidTenantID`, 006 FR-016), so these hosts can never be a tenant.

---

## 7. Consistency pass (integrator, after the area lanes push)

A `speckit-analyze`-style pass, recorded in section 8:

- every FR maps to at least one task; every task cites an FR;
- every contract endpoint / frame has an FR; no FR cites a removed endpoint
  (REST `/v1/messages`, `/v1/recv`);
- the DNS-zone step exists and sits before Cloud SQL and before ingress;
- trust, `delivery`, and milestone tags agree across 003/004/005/006/007/008;
- every Implemented status carries a checkable citation.

## 8. Consistency record

Pass run by the integrator on trunk `a27078c`, after every area lane landed
(001 `cacc7a8`, 003 `a4a5918`+`01eed0a`, 004 `6f1e759`, 005 `4942381`+`3e2f1f5`,
006 `523c953`, 007 `16fbda7`, 008 `a27078c`).

### 8.1 Checks

| Check | Result |
|---|---|
| Every FR defined in a `spec.md` is cited in that dir's `tasks.md` | yes, except the invariants in 8.3 (008's `FR-P01..P10` each cited ≥ 1) |
| Every task cites an FR its spec defines | yes — 0 dangling |
| Implemented / Partial / Planned on every FR and task | yes in 001, 003–009; 002 frozen |
| REST `/v1/messages`, `/v1/recv` presented as live | none — every remaining mention is "dropped by OQ-02" or "005 client calls the wrong route" (005 G5, 003 view-v1 §7) |
| NATS / SSE presented as M1 | none outside frozen 002 |
| `delivery` enum lacks `pending` | none |
| DNS-zone step exists and precedes Cloud SQL and ingress | yes — 007 step 3 `025-gcp-dns-zone`, import-only, NS handoff owner-gated |
| Status codes (402 / 409 / 429 / 78) agree 003 ↔ 004 ↔ 006 | yes — 003 `error-envelope.md` is the table, 004/006 cite it |
| Dead relative links in `specs/` | none |

### 8.2 Seams fixed by the integrator

- `331badd` — external liveness gates (005, 006, 007 step 10, SC-004) probe
  `/v1/health` (003 FR-023, landed `6c863ee`); `/healthz` is shadowed on
  Cloud Run. 003 no longer asks 007 for an LB health-check path: a serverless
  NEG backend takes none.
- `614f6c6` — 009 gets `tasks.md` (all Planned); binding docs in `../doc/md`
  follow the redo: WUI catch-up reads view-v1, bus notify is WS frames (NATS
  post-M1), the rental door is the box key on hello + envelope, the DNS-zone
  step is `025-gcp-dns-zone`.

### 8.3 FRs accepted without a task

Invariants already verified in their spec with a cited check; no work remains:
001 FR-004 (anonymous GET/list → 403), 004 FR-011 (sub-agents get top-level
ids), 005 FR-003 (no key or signed URL in the browser), 006 FR-017 (no
`tenant_id` on `v:1`). 007 FR-001 is the ordering rule itself; its open
steps are each a task.

### 8.4 Open after the redo (not seams — owners named)

| Item | Owner |
|---|---|
| **Ingress: documented M1 exception** (decided 2026-09-18). The Cloud Armor allowlist is `0.0.0.0/0` in dev and prd (`37e2e58`), recorded in `../doc/md/SPEC-spool-milestones.md` (M1 Ingress) and 007 FR-012 / SC-004. It widens only L7: the **data plane stays gated**: a WS needs a hello signed by a root-pinned box key. `GET /v1/files/{id}` needs an upload token or a member session (`internal/hub/rest.go` `fileReader`); the sha256 is not a capability. `/v1/view/*` on dev and prd needs a member session (`SPOOL_HUB_VIEW_DOOR=session` in `dev.env.yaml` and `prd.env.yaml`, tree `324a071`). `off` is lde only (`lde.env.yaml`). The 2026-09-18 wording that dev runs `off`, and that a file id is a capability, is superseded. `/v1/health` 200 from any IP is still expected. **End condition: M2 sign-off**; 403-for-non-allowlisted is an M2 expectation | 008 T115 + the M2 ingress follow-up |
| `017-github-wif-deploy` (tf step `017`, trunk `2a7888c`) is still **not applied**: `gh variable list -R csitea/csi-spl` prints nothing, so `GCP_WIF_PROVIDER_<ENV>` / `GCP_DEPLOY_SA_EMAIL_<ENV>` are unset and every deploy job takes its **other** branch — the SA-key secrets (`gh secret list` -> `GCP_KEY_CSI_SPL_DEV`, `GCP_KEY_CSI_SPL_PRD`, iac 120). So the pipeline DOES deploy both envs (the earlier record that it skips them, and that both hubs were deployed outside the pipeline, is stale); what is outstanding is only the keyless identity. Deployed-state check: `./run -a do_check_hub_deploy` (`csi-spl-orc/src/bash/run/check-hub-deploy.func.sh`); post-deploy smoke: `22_deploy-verify.yml` | 007 T050 (apply, owner go) -> 008 T105-T109 |
| Several lanes stamped `last-edit` in local time with a `Z` suffix | cosmetic; fix on next edit |

Resolved since the first record (kept for audit):
~~quality gate false red~~ (`4839514`, `cb1f254`) ·
~~DNS option A vs B~~ (decided and live, §6.1) ·
~~empty `025` state, no `025` dir~~ (`9ed50ac`) ·
~~prd nothing past step 2~~ (`csi-spl-hub-prd` running; run, sqladmin, compute enabled) ·
~~dev hub not reachable~~ (031 applied; 200 above) ·
~~view-v1 not built / WUI on dropped routes~~ (`internal/hub/view.go` serves `/v1/view/*`;
`grep -c '/v1/messages\|/v1/channels' csi-spl-wui/utils/spool-client.mjs` -> 0) ·
~~`GRK-3342-007-tf-007-dns` stale branch~~ (superseded by `025`) ·
~~10_ci-quality test skip holes and missing -race~~ (016 T002–T006 closed: `bed8732`, `5cf1a56`, `a798b07`, `cfcec60`) ·
~~Per-tenant DNS routing and manual CNAMEs~~ (superseded by 026 tenant from identity on `api.<domain>`, `0e09b33`, `170b863`) ·
~~Database RLS liftable by runtime role~~ (017 T029 owner/runtime DB split live dev + prd, `spool_hub_rt`, `85274e0`) ·
~~Postgres pool starvation & unbounded sweep~~ (027 T010–T040 pool tuned to 8, in-memory hotCache, chunked sweep `0024`, `f0484b8`, `57a21c7`) ·
~~Missing message visibility in recipient terminal~~ (028 spec + orc renderer, `31355bd`) ·
~~WUI channel/DM threads sorted by initial root ts~~ (CLE-3425: sorted by last activity `activityOf`, `9adb06c`).

### 8.5 Master trunk sync pass (specs 017 through 028, trunk through cea65d2)

Pass run by the integrator reconciling git-spec with trunk source code and infrastructure:

| Topic | State on trunk | Citation / Evidence |
|---|---|---|
| **017 Security Hardening** | Implemented & Live: DB split to `spool_hub_rt` (DML-only) + owner DSN `csi-spl-hub-db-owner-dsn`; RLS forced across 15 tenant tables (`0014`, `0021`); `EXPECT_NOT_LIFTABLE=1` exits 0 with `liftable=0` on dev and prd; hub logs `db.rls_not_liftable` | `85274e0`, `3dfce38`, `c0fe234`, `097a6c5`, `db-owner-split.tst.sh` (35/35 PASS) |
| **018 & 019 Social Auth (MS & LinkedIn)** | Implemented (code): OIDC clients in `internal/auth`, branded SVG lockups in `SocialAuthButtons.vue` in all 19 locales; live rollout gated on owner App Registration | `4dc854e`, `ea6bf1e`, `e8c2f75`, `auth-idp-secret-seed.tst.sh` (ALL PASS) |
| **020 Message Schema `v:2`** | Partial: readers implemented on trunk (`msg.Supported` admits 1 & 2, `wire.Frame.MsgVersions`); WUI `SpoolMessage.v` admits `1 \| 2`; hub 0.1.9 live; writers switch pending | `fb55fcf`, `71a87eb`, `cfcec60`, `nuxi typecheck` exit 0 |
| **021 WUI + Hub i18n** | Implemented & Live: 19 locales, donor language switcher, cookie redirect, default locale `en` (OQ-1 decided), `0017_human_preferred_locale.sql` live dev + prd, `X-Locale` header | `2e2c601`, `e586002`, `f2c024a`, `locale-switch.proof.mjs` (43/43 PASS) |
| **022 Top Bar & Global Search** | Implemented & Live: TopBar layout, Omnibox `/search` mode, grouped search results (`search-v1`), CSP & no-x-scroll clean | `63e37dc`, `top-bar-search.proof.mjs` |
| **023 User Settings & Keys** | Implemented & Live: GitHub-style `/settings` nav, in-browser Ed25519 keygen, `.pub`/`.key` download, `0018_human_keys.sql` live dev + prd | `2e7170b`, `settings-keys-live.proof.mjs` (12/12 PASS) |
| **024 Tenant Hosts** | **SUPERSEDED** by 026: scheduled workflow 40 disabled, per-tenant CNAMEs destroyed | `0e09b33`, `170b863` |
| **025 Tenant RBAC** | Implemented & Live: `0021_tenant_rbac.sql` applied dev + prd; 6 roles (`product_owner`, `biz_owner`, `admin`, `developer`, `tester`, `agent`); hub entry gates enforce; WUI role reflection | `714f3cb`, `8fe6517`, `do_spl_rbac_probe` PASS |
| **026 Tenant from Identity** | Implemented & Live: single API host `api.<domain>`, `X-Spool-Tenant` header, session `t`, pinned key resolution; per-tenant DNS destroyed (`mapped_tenants = []`); `do_spl_m3_e2e` passing on API host dev (14 PASS) & prd (15 PASS) | `0e09b33`, `170b863`, `dcfbe0a` |
| **027 Performance** | Implemented & Live: Postgres pool tuned to 8 conns (`398b374`), in-memory hotCache for pins/tenants (`0a11fae`), indexed ViewThreads `0022` (`74e01d8`), chunked retention sweeper `0024` (`0ba3ea5`), 200k c=50 send throughput 33.9 -> 2570 sends/s, p95 3.3s -> 27ms | `1f73fae`, `e6a96ec`, `f0484b8`, `57a21c7`, hub 0.1.16 live dev + prd |
| **028 Terminal Delivery** | Implemented through T050, including the proof (T040–T042 are `[x]` in `028/tasks.md`, not planned). The earlier "proof planned" cell in this table was stale against that file. | `31355bd`, `d5b6042`, `028/tasks.md` |
| **WUI Feed Ordering & Shell** | Implemented & Live: thread cards and sidebar channel/DM lists ordered by LAST activity (`activityOf`, `9adb06c`, `cea65d2`); single thread section in shell layout (`e54e4db`, CLE-3429); syntax-highlighted wrapping code snippets & generic modal dialog (`469c432`, CLE-3423) | `9adb06c`, `cea65d2`, `e54e4db`, `469c432`, `list-order.test.mjs` (28 PASS) |

### 8.6 Spec-vs-code pass (tree `324a071`, 2026-09-23)

Code prevails. Live GCP was not re-queried. Citations are `git grep` / file reads on this tree, n=1.

| Topic | What the tree shows | Spec change |
|---|---|---|
| Index stopped at 028 | dirs `029`–`032` exist | §4, §5, dependency order |
| 028 proof | `028/tasks.md` T040–T042 are `[x]` | §8.5 cell corrected above |
| View door | `grep SPOOL_HUB_VIEW_DOOR csi-spl-cnf/csi-spl/*.env.yaml` → lde `off`, dev `session`, prd `session` | §8.4; also 003 FR-020, 005 FR-010, 007 FR-012, milestones ingress |
| File read | `fileReader` in `internal/hub/rest.go` requires a bearer upload token or `humanTenant` | sha256-as-capability wording removed from §8.4 |
| 032 header | `spec.md` said Planned; `tasks.md` T001–T009 Implemented; `0026_message_revisions.sql` and `internal/hub/edit.go` exist | 032 header set to Implemented |
| 006 FR-013 | tasks T018–T021 are `[x]`; `internal/payments/handler.go` registers checkout, claim, webhooks | FR-013 status aligned; T022 stays open |
| 006 FR-002 | `git grep 'func (s *Server) tenantOf'` → no match | citation moved to `internal/hub/resolve.go` |
| 003 data-model | missing `channels.description`, `messages.edited_at` / `edited_by`, `message_revisions`; `is_private` has `git grep -l is_private -- '*.go'` → 0; `humans` and `rbac_permissions` have no `tenant_id` | data-model.md amended |
| 020 writers | `internal/msg/msg.go` `const Version = V1` | unchanged: writers still default to v1 |
| 030 | no `tasks.md`; status lived only in `spec.md` §0.5–0.7 | `030/tasks.md` added as the status list |
| 031 | no `tasks.md`; `cases.tsv` is the register (OA-10..14 and OA-40 are PENDING) | indexed; no tasks file invented |

<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
