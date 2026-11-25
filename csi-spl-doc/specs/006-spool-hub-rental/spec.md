# Feature Specification: Rented spool-hub (tenancy, root-key pinning, billing)

**Feature ID**: `006-spool-hub-rental`

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, `../README.md`) · **Synced**: 2026-09-25 (trunk `bbe04d26`) · **Commercial offer**: 2026-11-25 (trunk `f7161909f`, SPL-6410)

**Status**: M1 tenancy **Partial** — code, tests and the owner create action on
trunk; tenant `t1` exists on dev (T011d) and prd (T011c); missing: the second
real machine for the M1 demo. · M2 payment **Implemented** on the card rail —
live on prd since `7f779c4d` (`SPOOL_HUB_PAYMENT_PROVIDER: "stripe"` in
`csi-spl-cnf/csi-spl/prd.env.yaml`); PayPal off by design. Per-plan quotas
(T012a) and the timed grace (T013a) stay **Planned**. · Commercial offer
(H, human seats, I, P, K): **Proposed**, owner questions open
([section](#commercial-offer)); a paid checkout charges once, nothing renews
(G-H1).

**Narrative (binding)**: `../../doc/md/SPEC-spool-hub-rental.md`  
**Milestones (binding)**: `../../doc/md/SPEC-spool-milestones.md` — M1 manual
tenants on the product domain; M2 buy a tenant on the site; seats are M4
(`../009-spool-m4/`).  
**Trust (binding)**: `../002-box-agent-messaging/contracts/trust-modes.md`.

**Depends on**: 002 (local, frozen) · 004 (pin semantics) · 003 (WS/REST wire,
store, `spool migrate`) · 007 (cloud estate, DNS, ingress; README §6) ·
026 (tenant resolution from identity).

## Scope and seams

006 owns, per `../README.md` §5: **the tenant row and its root key, quota
`429`, unpaid `402`, the grace window, and M2 payment**. Tenant **resolution**
was 006's (the request Host) and is now 026's: identity-derived on
`api.<domain>` (`internal/hub/resolve.go`: session, or the box's
`X-Spool-Tenant` proven by its pin).
It cites and does not restate:

| Topic | Owner |
|---|---|
| WS hello/nonce, send envelope, recv/tail frames, REST files/pins shapes, error envelope | 003 `contracts/http-v1.md`, `contracts/error-envelope.md` |
| Pin semantics (409, `--force`, revoke, sync, `BOX-` forbidden) | 004 |
| DNS zone, Cloud Run domain mappings (032; no wildcard, no load balancer), cert, Cloud Run ingress, secrets | 007 (README §6) |
| Peer mesh (any pinned box may command any agent) | this spec, `contracts/peer-mesh.md` |

## Context

The product is a **paid tenant** of one hub. The tenant — not the GCP project —
is the isolation boundary. Hub-mode crypto is **one Ed25519 key per box**
(trust-modes §3); the **tenant root** is the only key that may pin or revoke a
box. The renter needs no GCP identity (FR-005). The internal fleet is one
tenant of the same product.

## Verification basis (how every status below was measured)

Run 2026-09-18 on trunk `bbc41e7` (= `9f8f492` + README only), n=1 each:

| Command | Result |
|---|---|
| `go test ./...` in `csi-spl-api/src/go/spool-hub-api` | all packages `ok` |
| `bash csi-spl-api/src/bash/tests/run-all-tests.sh` | `ALL csi-spl-api TESTS PASSED` (incl. `ALL HUB E2E CHECKS PASSED` on docker Postgres 16) |
| `git grep -c do_spl_tenant_create -- csi-spl-orc csi-spl-iac csi-spl-api` | no match (exit 1) |
| `git grep -n BillingGrace -- '*.go'` | `config.go:124`, `config.go:151` only (loaded + validated, never used) |
| `git grep -n 'SetBillingStatus(' -- '*.go'` (callers) | test files only |
| `git grep -lE 'webhook\|PaymentProvider' -- '*.go'` | `internal/billing/billing.go` (a comment) |
| `git grep -c box-c -- csi-spl-api/src/bash/tests` | no match (exit 1) |
| `gcloud run services list --project csi-spl-dev --account=$GCP_ACCOUNT` | `csi-spl-hub-dev` exists; `curl …run.app/version` → GFE `404` (ingress internal-and-cloud-load-balancing, no LB yet) |
| `gcloud run services list --project csi-spl-prd --account=$GCP_ACCOUNT` | `SERVICE_DISABLED` |
| `git log origin/master..GRK-3338-006-tenants-host --oneline` | `b6a2e80 feat(006): tenants, Host resolve, create-once, isolation` — **not on trunk** (at the time) |

The pre-redo `tasks.md` ticked T001–T004 and T015 from that unmerged branch.
`b6a2e80` was then verified, corrected and landed as **`3690211`** (v1.1.0 of
this spec). Re-measured on `3690211`, n=1 each:

| Command | Result |
|---|---|
| `go test ./...` + `run-all-tests.sh` | all `ok`; `spool migrate applies 4 file(s)`; `ALL csi-spl-api TESTS PASSED` |
| `bash csi-spl-orc/src/bash/tests/tenant-create.tst.sh` | `PASS: all tenant-create.tst.sh assertions` (DRY_RUN paths) |
| `DRY_RUN=0 ENV=dev TENANT_ID=acme do_spl_tenant_create` against a temp Postgres | key printed once; row `acme`, `manual`, 32-byte pubkey; re-create and `TENANT_ID=dev` refused, no key printed |

Correction made while landing it: `billing.AllowsWrite` did not know `manual`,
so every owner-made tenant would have got `402` on its first send
(`TestManualTenantMayWrite`).

Re-measured 2026-09-25 on trunk `bbe04d26`, n=1 each:

| Command | Result |
|---|---|
| `go test -count=1 ./internal/{msg,hub,store,billing,payments,spool} -run '<every test cited in 004 + 006>'` | all six packages `ok` (in-memory store) |
| `curl -s https://api.spool-hub.ai/version`; `curl -s https://dev.api.spool-hub.ai/version` | both `0.5.7`, commit `019d9e8` |
| `curl -s https://api.spool-hub.ai/api/v1/checkout/plan` | `available:true`, `rail:"card"`, `amount_cents:2000`, `pk_live_…` |
| `git log -S'func (s *Server) tenantOf' --oneline -- csi-spl-api` | `6c66ac01` (removed, 026), `7905e353` (added) |
| `grep -n -A1 'mapped_tenants:' csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` | `mapped_tenants: []` in both |
| `getent hosts t1.spool-hub.ai` | no answer (tenant hosts retired) |
| `git grep -n BillingGrace -- '*.go' \| grep -v _test` | `config.go:238` (field), `config.go:339` (validation) only |

## User Scenarios & Testing

### User Story 1 — Operator creates a tenant (Priority: P1, M1) · **Partial**

The owner creates a tenant by hand (M1: several owner-made tenants allowed).
They receive the tenant id and the root keypair; the private root is shown
once and never stored on the hub. (The action also prints a `url`: the legacy
tenant-host form, `csi-spl-orc/src/bash/run/spl-tenant-create.func.sh:22`; see
OQ-006-5.)

**Independent Test**: create a tenant against a migrated Postgres; the row
holds the 32-byte pubkey only; a second create with a different root → conflict.

**Acceptance Scenarios**:

1. **Given** `spool root-keygen` then `spool hub-tenant --tenant t --root-pubkey …`,
   **When** it succeeds, **Then** `tenants.root_pubkey` is set and no private
   key is in the DB. — *Implemented* (`hub-e2e.tst.sh` → `ok - owner created tenant t-e2e`; `TestTenantsAndPins`).
2. **Given** `TENANT_ID=acme DRY_RUN=0 ./run -a do_spl_tenant_create`, **When**
   it succeeds, **Then** it prints URL + root private key once and the row is
   `billing_status=manual`. — *Implemented* (`3690211`; DRY_RUN paths in
   `tenant-create.tst.sh`, DRY_RUN=0 checked by hand, n=1).
3. **Given** a cloud env (dev, then prd), **When** a tenant is created,
   **Then** the API host serves it with no per-tenant host, mapping or DNS
   (026): members sign in with `?tenant=<id>`, boxes name it with
   `SPOOL_TENANT`. — *Implemented* (tenant `t1` on dev + prd, T011c / T011d;
   resolution per 026). The earlier target `https://<tenant>.<env fqdn>/v1/health`
   is *Superseded* (024 retired; `mapped_tenants: []`).

### User Story 2 — Renter pins boxes with the root key (Priority: P1, M1) · **Implemented**

Only the tenant root may pin/revoke a box pubkey; a box cannot self-pin. Same
`box_id` with another key in the same tenant → 409 (004 semantics). The same
`box_id` in another tenant is an unrelated row.

1. **Given** a root-signed pin of `box-a`, **When** `box-a` says hello and
   sends, **Then** the hub accepts. — `TestPinRESTRootSigned`, `hub-e2e.tst.sh`.
2. **Given** a pin signed by a non-root key, **Then** `400 bad_sig`. — `TestPinRESTRootSigned`.
3. **Given** `box-a` unpinned, **When** it says hello, **Then** it is refused
   (CLI exit `78`). — `hub-e2e.tst.sh` → `ok - unpinned box refused at hello (exit 78)`.

### User Story 3 — Two machines talk through the tenant with keys only (Priority: P1, M1) · **Partial**

Two `$SPOOL_ROOT`s with only box keys + `$SPOOL_HUB_URL` (no `CLOUDSDK_*`, no
IAM) exchange `task` / `result`. Wire per 003.

1. **Given** two root-pinned boxes on a local hub, **When** `GRK-03@box-a`
   sends a `task` to `CLE-07@box-b`, **Then** it arrives (`queued` then
   drained; `sent` when live) and a `result` crosses back. — *Implemented
   locally* (`hub-e2e.tst.sh`, 4-message thread).
2. **Given** the same on the live hubs with a real second machine
   (milestones §Demo), **Then** the same. — *Partial*: two box clients on ONE
   machine passed on dev and prd (T011c, `do_spl_m3_e2e`); missing: the second
   real machine (owner step).

### User Story 3b — Any peer commands any peer (Priority: P1, M1) · **Implemented**

Three pinned boxes (GRK, CLE, AGY). Each may `task` each of the others; the
hub neither parses `body` nor privileges a prefix. `contracts/peer-mesh.md`.

1. **Given** boxes a, b, c pinned, **When** A→B, B→C, C→A tasks are sent,
   **Then** all arrive. — *Implemented* (`TestThreePeerMeshRing`, 20/20 local runs).
2. **Given** `from == to` on one box, **Then** it is delivered (loopback,
   local by default per trust-modes). — *Implemented* (`hub-e2e.tst.sh` self-send `delivery=local`).

### User Story 4 — Quota and unpaid (Priority: P2, M1 gate / M2 money) · **Partial**

1. **Given** a tenant over quota, **When** it sends / pins / PUTs a file,
   **Then** `429 quota`. — *Implemented* (`TestQuotaExceeded429`), but quotas
   are **deploy-wide** cnf, not per tenant/plan (FR-008).
2. **Given** `billing_status=grace|unpaid`, **When** it sends / pins / PUTs,
   **Then** `402 unpaid`; hello, recv, GET file, GET pins still work. —
   *Implemented* (`TestUnpaidSendPin402RecvInGrace`).
3. **Given** grace has lasted `SPOOL_HUB_BILLING_GRACE`, **Then** the tenant
   moves to `unpaid` and its data becomes eligible for deletion. — *Planned*,
   gated on OQ-006-3 (today `grace` and `unpaid` behave identically, so a timer
   alone changes nothing observable). The owner can already move a tenant
   with `spool hub-tenant-billing` (FR-012).

### User Story 5 — Stranger buys a tenant on the site (Priority: P1 for M2) · **Implemented** (card rail)

Thin checkout page → provider → signed webhook → tenant `active`; success
page + one email carry the tenant URL and root private key, once.
`contracts/payment.md`.

1. Schema `payment_checkouts` + `webhook_events_seen` and cnf names — *Implemented* (`40371a7`).
2. Provider interface, webhook handler, fake-pay, checkout page, email — *Implemented*
   (T018–T021, T021w; secret slots + endpoint T022; card rail live on prd since
   `7f779c4d`). PayPal stays off by design (`SPOOL_HUB_ENABLE_PAYPAL`).

### Edge Cases

- Replay of hello (old `ts`, reused nonce) → 003 `contracts/http-v1.md` §2.
- Tenant id leaked: unpinned boxes fail hello; `GET /v1/pins` needs the
  WS-issued token (003). The tenant id is not a secret.
- **Reserved slugs**: a tenant id equal to an env label or infra host (e.g.
  `dev`, `www`, `api`) is refused. The original reason (shadowing
  `*.dev.<domain>` under Host routing) is retired with 024 / 026; the refusal
  stays so an id never collides with an env label or a service host. — *Implemented* (FR-016).
- Root key lost: no escrow. Lost root = new tenant (M2: support; no dashboard re-issue).
- Unknown tenant id → `404 unknown_tenant` (`internal/hub/resolve.go:46`); a
  box on the API host naming no tenant → `400 tenant_required`, a human session
  with several tenants → `409 tenant_required`; a legacy Host or header naming
  another tenant than the credential → `403 tenant_mismatch` (026).

## Requirements

| FR | Requirement | Status (evidence) |
|---|---|---|
| **FR-001** | `tenants` row: `tenant_id` (`^[a-z0-9][a-z0-9-]{0,31}$`), 32-byte `root_pubkey`, `billing_status`, `plan_id`, `created_at`. | **Implemented** (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql`) |
| **FR-001a** | Operator-created renter tenants carry `billing_status=manual` (narrative §2). | **Implemented** (`0004_tenant_manual.sql`; `billing.StatusManual` writes like `active`; `TestManualTenantMayWrite`, `TestTenantManualAndPubkeyOnly`) |
| **FR-002** | Tenant from the request **Host** against `$SPOOL_HUB_TENANT_HOST_PATTERN` (`{tenant}.<fqdn>`, cnf; no baked host). Host is the one routing choice; a `/t/<tenant>/` path prefix is not offered. **Amended by 026:** tenant now resolved from identity, session token, or pinned box key on `api.<domain>`; per-tenant Host routing retired. | **Superseded** by 026 (the Host rule); the replacement is **Implemented** (`internal/hub/resolve.go` `humanTenant` 56 / `boxTenant` 112 / `tokenTenant` 134. `git grep 'func (s *Server) tenantOf' -- '*.go'` → no match on `bbe04d26`; removed in `6c66ac01`. A legacy Host is an equality check, except `fallbackTenant` may select among memberships the human already has when session `t` is empty.) |
| **FR-003** | Pin/revoke box pubkeys only with a tenant-root signature; semantics per 004. | **Implemented** (`TestPinRESTRootSigned`, `TestPinRevokeAndForce`) |
| **FR-004** | Pins, messages, files, quotas isolated **per tenant**; the same `box_id`/agent id in two tenants are unrelated. | **Implemented** (`TestTwoTenantsSameAgentIDIsolated`: same `box-a`/`GRK-03` in two tenants, no cross-delivery, A's key refused as B's `box-a`; `TestFilesRoundTripAndTenantIsolation`) |
| **FR-005** | No renter GCP IAM, no per-agent token. Box key + tenant root only. | **Implemented** (hub-e2e runs with no `CLOUDSDK_*`) |
| **FR-006** | M1 ingress IP allowlist / IAP (cnf); M2 allow-unauthenticated and rate-limit unsigned calls at the hosting shield (007). | **Superseded — owner question OQ-006-4.** The M1 load balancer (031) and its IP allowlist were removed 2026-09-19 ("exactly csi-rel: no load balancer"). The hub is Cloud Run `ingress: all` (`csi-spl-cnf/csi-spl/all.env.yaml:76`) with `allow_unauthenticated: true` (`dev.env.yaml:170`, `prd.env.yaml:177`), reached through 032 domain mappings; edge limits are in-app (017 T010), not at a shield. |
| **FR-007** | Owner tenant-create action prints URL + root private key once; DB holds the pubkey only. | **Implemented** (`csi-spl-orc/src/bash/run/spl-tenant-create.func.sh`, `3690211`). The printed `url` is the legacy tenant-host form (`spl-tenant-create.func.sh:22`); since 026 a tenant needs no host (OQ-006-5). |
| **FR-008** | Quota: messages/month, pins, stored file bytes → `429 quota` (CLI exit 1). Values from the tenant's **plan** (cnf), 0 = unlimited. Recv is not quota-gated. | **Partial** — enforced, but one deploy-wide `SPOOL_HUB_QUOTA_*`, not per `plan_id` |
| **FR-009** | `grace`/`unpaid` refuse send, pin, revoke, PUT file with `402 unpaid`; hello, recv, GET file, GET pins stay up. | **Implemented** (`billing.AllowsWrite`, `TestUnpaidSendPin402RecvInGrace`) |
| **FR-010** | Grace is timed: `grace` older than `SPOOL_HUB_BILLING_GRACE` → `unpaid`; after cnf retention the tenant's data may be deleted. | **Planned** (not timed; no grace-start column) |
| **FR-011** | Any pinned box may send `kind=task` to any agent on any pinned box of the same tenant; no prefix ACL; the hub never parses `body`. | **Implemented** (003 send path has no ACL; `TestThreePeerMeshRing`: GRK→CLE→AGY→GRK across three boxes) |
| **FR-012** | An operator verb sets billing status (`paid`/`unpaid`/`refund` → `billing.MapEvent`) until M2 webhooks exist. | **Implemented** (`spool hub-tenant-billing --tenant --event` → `billing.Apply`; `TestApply`; binary checked on a temp Postgres: `failed`→`grace`, `paid`→`active`, unknown event / tenant exit 1, n=1) |
| **FR-013** | M2: copy csi-rel payment (interface, drivers, signed webhook + `webhook_events_seen`, fail-closed boot, fake-pay in lde). No card data, no vendor name in source, no root private key stored. | **Implemented** — checkout, claim and signed webhooks (`internal/payments/handler.go` `Register`; T018–T021), secret slots + webhook endpoint (T022); card rail live on prd since `7f779c4d` (`curl -s https://api.spool-hub.ai/api/v1/checkout/plan` → `available:true, rail:card`, 2026-09-25, n=1). PayPal stays off by design (`SPOOL_HUB_ENABLE_PAYPAL`). |
| **FR-014** | M2: the tenant root private key is minted at a single-use claim and shown ONCE in the buyer's browser (success page, or the claim page the one email links to); the email carries the tenant URL + a single-use, short-TTL claim link and **never key material**. Amended 2026-09-19 by 017 T008 / SEC-03 (HIGH): was "one email with tenant URL + root private key". | **Implemented** in the hub (see tasks T021); WUI claim page: T021w |
| **FR-015** | Hygiene: no payment-vendor name in source; no root/box private key in logs. | **Implemented** (`no-baked-host.tst.sh`: no product host / vendor in Go; `no-payment-vendor-wui.tst.sh`; `TestRootPrivateKeyNotLogged`) |
| **FR-016** | Reserved tenant slugs (env labels such as `dev`, and infra hosts) refused at create and never resolved. | **Implemented** (`msg.ValidTenantID` reserved list, `TestValidTenantID`) |
| **FR-017** | `v:1` schema unchanged; no `tenant_id` on `v:1` (the resolved tenant is the namespace, 026). | **Implemented** (`grep -n 'json:"tenant' csi-spl-api/src/go/spool-hub-api/internal/msg/*.go` → no match. The old proof `grep -c tenant …/msg.go` now reads 3: the `ValidTenantID` helper of FR-016, not a message field.) |
| **FR-018** | A tenant carries an optional display name (`tenants.display_name`, NULL or 1..200 chars; NULL = the WUI shows the id); the id itself is never renamed. An operator verb sets it: `ENV=<env> TENANT_ID=<id> DISPLAY_NAME=<name> ./run -a do_spl_tenant_display_name` (csi-spl-orc, per-env SA, DRY_RUN default). | **Implemented** (`csi-spl-rdb/src/sql/postgres/spool-hub/0041_tenants_display_name.sql`, `b4ef0630` (first landed as 0040 in `1482b0ca`); the session membership carries it (`internal/auth/tenant.go:18`, `internal/store/memberships.go:56`); `TestMembershipListsTenantDisplayName` PASS 2026-09-25, n=1, in-memory; DRY_RUN control in `csi-spl-orc/src/bash/tests/adhoc-harvest-actions.tst.sh` §2b. The live dev / prd values were not re-measured in this sync.) |

Removed from the pre-redo spec because 003 owns them (cited, not restated):
WS hello, envelope, `to_box` 409, `delivery` values, same-box mirror, offline
queue, file upload token — 003 `contracts/http-v1.md` and trust-modes §4–§8.

## Success Criteria

- **SC-001**: Two tenants, identical box and agent ids, no cross-talk (FR-004). — Implemented.
- **SC-002**: Two `$SPOOL_ROOT`s, keys + hub URL only, `task`→`result`. — Implemented locally (hub-e2e); cloud Partial (one machine, dev + prd, T011c).
- **SC-003**: Unpaid tenant: send `402`, recv works; after grace, `unpaid`. — Partial (no grace timer).
- **SC-004**: M1 demo step 2 on `dev` then `prd` with an owner-made tenant. — Partial (`t1` on both; two box clients on one machine passed; the second real machine is missing).
- **SC-005**: M2: a fake-pay checkout in lde yields an `active` tenant and a one-time root key. — Implemented (`TestFakeBuyEndToEnd`; dev proofs T020 `m2proof1`, T021 `m2proof2`, 2026-09-19).

## Open questions (owner)

- **OQ-006-1** Per-tenant quotas: columns on `tenants` (the `b6a2e80`
  approach, not landed) or a cnf plan table keyed by `plan_id`? Recommendation: cnf plan
  table — prices and quotas both live in cnf (payment.md); a column per tenant
  duplicates it.
- **OQ-006-2** `manual` next to the existing `internal`? Recommendation: keep
  both — `internal` = our own fleet, never billed; `manual` = hand-made renter
  tenant, billed out of band. *(Landed that way in `3690211`; reversible.)*
- **OQ-006-3** After the grace window, does an `unpaid` tenant keep read access
  (hello, recv, GET file) until retention deletes its data, or is it cut off
  (`402` on hello)? The narrative promises reads only "during grace". The
  answer decides what T013a builds; retention deletion is destructive and
  waits for this answer either way.

## Open owner questions (sync 2026-09-25)

- **OQ-006-1** (above, still open) per-plan quotas: cnf plan table or columns?
  Blocks T012a.
- **OQ-006-3** (above, still open) does an `unpaid` tenant keep reads after
  grace? Blocks T013a.
- **OQ-006-4** FR-006: the M1 IP allowlist is gone with the load balancer and
  prd is public (`ingress: all`). Drop FR-006, or re-target it at the in-app
  edge limits (017 T010)?
- **OQ-006-5** Retire `SPOOL_HUB_TENANT_HOST_PATTERN` (still required at boot,
  `internal/config/config.go:241` field, fail-fast `:350-351`; rendered in `dev.env.json` / `prd.env.json`)
  and the legacy `url` output of `do_spl_tenant_create`
  (`spl-tenant-create.func.sh:22`), now that `mapped_tenants: []` in both envs?
- **OQ-006-6** Tenant display name (FR-018) is recorded here because 006 owns
  the tenant row; no other spec covered it
  (`git grep -l do_spl_tenant_display_name csi-spl-doc/specs` was empty). Keep it
  in 006, or move it to 025 (tenant admin)?

<a id="commercial-offer"></a>
## Commercial offer (v1.5.0, 2026-11-25, owner HUM-10)

Issue SPL-6410, epic SPL-61. Doc only: this section builds nothing, sets no
price and changes no cnf. A price below is either one the owner already
decided (cited by spec and question id) or an open question in section
CO-7; none is invented here. First draft by a-959 (`37d8f9f22`, not
reviewed); every claim re-measured and corrected here by c-155.

### CO-0 The owner's words

csitea topic `2cdf7279`, 2026-11-24, HUM-10, verbatim:

- `96586825`: "idea and proposals to start yearning money from the spool-hub"
- `92a443f0`, form `392a2c01` answered **H, I, P**: "Hosted workspace
  rental (built: spec 006 checkout); Private integrations as a service;
  Support / SLA tier for self-hosters"
- `c9844311`: "also we need seat prices for humans"
- `953a66e5`: "I would like to also address the spool-hub t obe used as a
  company / organisation wide document storage with ai retrieval"

The line he drew the same day (csitea `e2c54e32`, msg `9c5d4a52`): "the
audience for the csi-spl , should be global startups which want to have a
free argents harness". csi-spl stays free and open (spec 044; the repo
licence is AGPL-3.0, `head -1 LICENSE`; spec 156 lists it free). The money
comes from hosting, seats and services around the harness, never from
locking it.

Decisions already on record that bind this section (not re-asked):

| id | decision | where |
|---|---|---|
| D1 | the price of every workspace is the cloud cost + 33% and EUR 9 per month per human member; agents are not seats; no token price, nothing else | spec 121 R6 (v1.5), spec 181 0.2, Q-6 A, Q-7 A, form `b97a036d` A |
| D2 | no AI token is ever sold | spec 181 P5, Q-10 A |
| D3 | a shared workspace pays by a prepaid card top-up drawn down; work stops at zero; no invoice | spec 121 R7 and section 8, Q-M2 = A (`e38f9953`) |
| D4 | a private workspace (own VM) is invoiced monthly in arrears, bank transfer | spec 181 Q-9 B, Q-16 B, Q-18 C |
| D5 | customer-specific integration code lives in a private repo and writes into a generic csi-spl connector | csitea `e2c54e32`, form `b343220a` answered B (msg `8ab39b9d`) |

Measured on origin/master `f7161909f` (2026-11-25, n = 1 per command) unless
a row says otherwise. Paths under `internal/` are in
`csi-spl-api/src/go/spool-hub-api/`.

<a id="co-1"></a>
### CO-1 Offer H: hosted workspace rental

#### CO-1.1 What a buyer gets today, end to end

| step | what happens | evidence |
|---|---|---|
| 1 find it | the only way in is the "Buy a workspace" link with its price, shown in the signed-out app shell; the static pages carry no price and no buy link | `csi-spl-wui/src/layouts/default.vue:139` (`<BuyWorkspaceLink />`); `grep -ciE 'checkout\|price\|buy' csi-spl-wui/src/public/{about,terms}.html` -> 0 and 0; no `pricing` page in `csi-spl-wui/src/pages/` (`ls`) |
| 2 the plan | `GET /api/v1/checkout/plan` | `internal/payments/handler.go:212`; live 2026-11-25: prd and dev both `{"amount_cents":2000,"available":true,"currency":"eur","methods":["card"],"plan_id":"default","private_workspace":{"currency":"EUR","seat_member_cents":900,"vm_margin_pct":33},"rail":"card",...}` (`curl -s https://api.spool-hub.ai/api/v1/checkout/plan`) |
| 3 order | slug + email; `POST /api/v1/checkout` holds the slug and opens a one-off card payment | `handler.go:145` route, `:322` `checkout`; `internal/payments/stripe_payments.go:110` posts `/v1/payment_intents` |
| 4 pay | the card form in the page | `csi-spl-wui/src/pages/checkout/index.vue`, `csi-spl-wui/src/utils/card-element.mjs` |
| 5 paid | the signed webhook marks the checkout paid and creates the tenant `active` | `handler.go:155` route, `:843` `stripeWebhook`, `:820` `stripeKind` (`payment_intent.succeeded` -> paid); `internal/store/payments_postgres.go:155` -> `paidTx` |
| 6 key | one mail with a single-use claim link (no key in it); the root key is shown once in the browser | `handler.go:679` `afterPaid`, `:631` `claim`; `csi-spl-wui/src/pages/checkout/claim.vue`, `success.vue` (FR-014) |
| 7 use | members sign in with `?tenant=<id>`, boxes name it with `SPOOL_TENANT` (026) | User Story 1 scenario 3 above |

Demand so far: on prd `payment_checkouts` has **0 rows** and `tenants` reads
`internal 3`, `manual 21`, no `active` (read-only `do_spl_db_query`,
ENV=prd, 2026-11-25). No stranger has ever paid.

#### CO-1.2 The gaps that stop a first paying customer

| # | gap | evidence |
|---|---|---|
| G-H1 | **nothing charges month 2.** The card rail is a one-off payment intent, yet the payment's description says "(monthly)". The decided model, a prepaid top-up drawn down (D3), is not built | `stripe_payments.go:99` (`" (monthly)"`), `:110`; `git grep -niE 'top.?up' -- csi-spl-api/src/go/spool-hub-api/internal/payments` -> nothing |
| G-H2 | no public price page: a visitor who is not on the signed-out shell never sees a price | CO-1.1 step 1 |
| G-H3 | quotas are one deploy-wide set, not per plan (T012a, OQ-006-1) | `internal/config/config.go:424-426`; `csi-spl-cnf/csi-spl/all.env.yaml:609-611` |
| G-H4 | grace is not timed (T013a, OQ-006-3): `BillingGrace` is only validated, and `grace` and `unpaid` both refuse writes alike | `config.go:427`, `:857`; `internal/billing/billing.go:87` `AllowsWrite` |
| G-H5 | billing status moves only on a refund (and the operator verbs); no event moves a tenant to `grace` when its money runs out, because no balance exists (G-H1) | `payments_postgres.go:163-172` (refund -> `billing.MapEvent`); `git grep -n 'SetBillingStatus(' -- '*.go' \| grep -v _test` -> `billing.go:70`, `internal/hub/operator_workspaces.go:455` and the store |
| G-H6 | no receipt or invoice from the hub for a card payment; the invoice tables are the private workspace's (D4). Whether the card provider's own receipt mail is on is a dashboard setting, not measured | `grep -n receipt internal/payments/*.go \| grep -v _test` -> one comment (`stripe_payments.go:81`); rdb `0315_private_workspace_invoices.sql` header |
| G-H7 | no self-service cancel: the cancel route is the operator's, for a private workspace | rdb `0319_workspace_cancellations.sql` header (`POST /v1/operator/workspaces/{id}/cancel`) |

<a id="co-2"></a>
### CO-2 Human seat prices (owner `c9844311`)

**The price is already the owner's**: EUR 9 per human member per month,
for every workspace (D1). The live plan already shows it, for the private
workspace only (`seat_member_cents: 900`, CO-1.1 step 2;
`internal/store/price_plans.go:32`). What is missing is selling it on the
hosted (shared) checkout. Whether 9 applies there too is Q3 (recommended:
yes).

| part | today | evidence |
|---|---|---|
| price switch | seats are sold when a seat price is above 0; both are `"0"` in cnf, so the hosted plan sells none (spec 009: "Implemented in code, not sold") | `internal/payments/config.go:69-71`, `:288` `SeatsSold`; `csi-spl-cnf/csi-spl/all.env.yaml:644-646` |
| what the plan shows | `seat_user_cents`, `seat_bot_cents`, `seats_max` appear only when sold | `handler.go:227-228`; `contracts/checkout-v1.md:215-218` |
| quantity | a priced kind is bought 1..`SEATS_MAX` (1000) per checkout | `handler.go:287` |
| paid | the paid webhook writes the caps on `tenants` and the UTC month's `tenant_seat_periods` row | `payments_postgres.go:341-355`, `:378` `seatCapsTx`; rdb `0016_m4_seat_line_items.sql` |
| the cap | a NEW human is refused at sign-in or invite once the count reaches the cap; re-login never takes a seat; 0 = no cap | `internal/store/humans_postgres.go:241-282` (`ErrSeatQuota`) |

**What counts as a seat** (as the cap counts it, `humans_postgres.go:271-275`):
a non-technical human whose membership has any role but channel guest
takes one seat. A channel guest takes none. An agent
takes none (D1; `handler.go:385` "agents are not seats"). The bot-seat price
stays `"0"` (D1), so nothing in the agent harness is priced. Q5 asks only
whether guests stay free.

**Proration.** Today seats are set only at checkout; there is no route to
add or remove one later (CO-6 row C6). The proposal, Q6: adding a seat takes
effect at once and is drawn from the balance pro rata for the rest of the
month; removing one takes effect at the month's end, and existing members
are never locked out (`SetSeatCaps` "never lowers occupancy",
`internal/store/seats.go:28-29`).

**What people see** (none of it is built; rows C5, C6):

- the buyer: the plan, the seat price, a seat count (1..`seats_max`) and the
  month's total, before paying;
- the workspace admin: "N of M seats used" and an add / remove control, in
  workspace settings (`csi-spl-wui/src/pages/tenant-settings/members.vue`
  shows no seat count today: `grep -ci seat` -> 0).

<a id="co-3"></a>
### CO-3 Offer I: private integrations as a service

**The offer.** We build and keep running one integration a customer needs
with its own systems (accounting, CRM, ERP, inventory). It follows D5: the
customer-specific code lives in a **private repo the customer owns**, and
writes into a **generic, org-neutral csi-spl connector**. csi-spl ships the
connector, never the customer's mapping. The first such connector, the
generic finance connector, is being specified by its own lane (csitea
`e2c54e32`, ask `0634faec`); this spec references it and does not duplicate
it.

| part | proposal |
|---|---|
| scoping | a short written scope per integration: the source system, the data read or written, the connector it writes into, the test sandbox the customer provides, the acceptance test |
| price | a fixed setup fee per integration plus a monthly upkeep fee (upstream API changes, failures, monitoring); the amounts are per quote, by the owner (Q8) |
| code ownership | the customer owns the private repo and its code. A change to the generic connector goes into csi-spl under its licence (AGPL-3.0). Where the boundary between the two sits under AGPL is a licence question to settle before the first contract (Q9) |
| data | the customer's credentials stay in the customer's own secret store or private repo deployment, never in csi-spl and never in a public commit; no customer name, account or identifier in csi-spl (distribution hygiene, repo CLAUDE.md); a brief for a non-claude lane never carries one (fleet data rule) |
| sold by | a quote and an invoice; not the card checkout |

<a id="co-4"></a>
### CO-4 Offer P: support / SLA tier for self-hosters

**Who buys it.** A team that runs csi-spl itself (spec 044 open source,
spec 156 marketplace VM) and wants someone to answer when it breaks.

| part | proposal |
|---|---|
| channel | one support workspace per customer on spool-hub, bought like any hosted workspace (CO-1); its members post, our seats answer. Nothing runs inside the customer's estate |
| covered | upgrades between released versions (`v<X.Y.Z>` tags), database migrations, the install and its terraform steps, incidents in csi-spl itself (hub, WUI, box CLI, MCP) |
| not covered | the customer's own integrations (that is CO-3), their cloud bill, their AI vendor accounts |
| response times | proposed as targets, not yet promised: severity 1 (the hub is down) and severity 2 (a part is broken) in business hours, 1 and 2 business days respectively for the first answer; levels and hours are Q10 |
| sold by | an invoice, monthly or yearly, bank transfer, like D4 (Q11); a card checkout would need the renewal of G-H1 first |

Nothing of P exists in code today, and nothing needs to before a first
contract: it is a written offer, a support workspace and an invoice.

<a id="co-5"></a>
### CO-5 Offer K: organisation-wide document store with AI retrieval

**Who buys it.** A company that wants its specs, runbooks and documents in
one place, searched by both its people and its agents.

Measured baseline:

| part | today | evidence |
|---|---|---|
| documents | per-workspace Qto documents | rdb `0157_workspace_docs.sql`; specs 113, 120, 137, 190 (media) |
| the Docs section | built | spec 075; `csi-spl-wui/src/pages/docs.vue` |
| full-text search over documents | built: Postgres `tsvector` per section and per document | rdb `0227_workspace_doc_search.sql`; spec 100 section 14 |
| a vector / embedding store | **none** | `grep -liE 'create extension.*vector' csi-spl-rdb/src/sql/postgres/spool-hub/*.sql \| wc -l` -> 0 |
| semantic retrieval + enterprise IAM | designed, not built | spec 075 section 7 ("Phase 5") |
| upload from a cloud drive | specified separately | spec 194 v0.1 (SPL-6398), not duplicated here |

**The offer.** The storage and the word search are part of every hosted
workspace now (they exist). AI retrieval is added when spec 075 section 7 is
built. Under D2 it can sell no tokens: the embeddings run on the customer's
own AI key (as spec 159 does for agents) or on a model we host, priced at its
cloud cost + 33% (D1). Packaging and storage pricing are Q12 and Q13.

**The gaps** (each a spec 075 lane, not this spec's): an embedding store and
its migration; an embedding worker on document save; a semantic query in
search; per-document access rules (075 7.2); a storage measure per workspace
for pricing (`usage_events` kind `storage_bytes` exists in spec 121 7; per
workspace document bytes not measured here).

<a id="co-6"></a>
### CO-6 Build rows, in order

Row C1 is the smallest step to a first paying workspace: the live plan is
already for sale; strangers cannot find it. Kind and vendor follow the
fleet split (`specs_and_docs` and `i18n`: agy, backup claude; coding: claude,
backup agy). Each row is one lane with its red control. `C<n>` rows are
tasks T024..T034 in `tasks.md`.

| row | kind / vendor | what | paths | test and red control | waits on |
|---|---|---|---|---|---|
| C1 | simple_coding / claude, then i18n / agy | a public price page `/pricing` that renders `GET /api/v1/checkout/plan` (no price typed into the page) and links to `/checkout`; linked from `about.html` and the sign-in page; every locale | `csi-spl-wui/src/pages/pricing.vue`, `csi-spl-wui/src/public/about.html`, locale files | e2e with the plan mocked: `available:false` -> no buy button; red control: a literal `2000` or `20` typed into `pricing.vue` fails a grep test | - |
| C2 | simple_coding / claude | the payment description stops saying "(monthly)" while nothing renews | `internal/payments/stripe_payments.go:99`, its test | a test asserts the description; red: the old string fails it | - |
| C3 | complex_coding / claude | the renewal (G-H1) as D3 says: a top-up of an existing workspace's balance by card, drawn down monthly by the plan and its seats; at zero the workspace goes `grace` | `internal/payments/handler.go`, `internal/store/payments_postgres.go`, a new rdb migration, `csi-spl-wui/src/pages/checkout/` | a top-up webhook credits once (replay -> one credit); red: a balance at zero that stays `active` fails it | Q1, Q2 |
| C4 | simple_coding / claude | per-plan quotas (T012a) | `internal/config/config.go`, `internal/hub/server.go:922-924`, cnf | a plan with a lower quota -> `429` while the deploy-wide value has room; red: the deploy-wide value wins | OQ-006-1 |
| C5 | simple_coding / claude | timed grace (T013a): grace start recorded, `unpaid` after `SPOOL_HUB_BILLING_GRACE` | `internal/billing/`, a rdb migration | fake clock past grace -> `unpaid`; red: one second before -> still `grace` | OQ-006-3, C3 |
| C6 | simple_coding / claude, cnf with the owner's go | human seats on the hosted checkout: the price in cnf, a seat count in the checkout page, the month's total | `csi-spl-cnf/csi-spl/all.env.yaml:644`, `csi-spl-wui/src/pages/checkout/index.vue` | checkout with 3 seats -> amount = plan + 3 x seat; red: `seats_users` 0 accepted while priced | Q3, Q4, Q5 |
| C7 | complex_coding / claude | seats after purchase: an admin adds or removes seats; add at once, pro rata from the balance, remove at month end; "N of M seats used" in workspace settings | `internal/payments/`, `internal/store/seats_postgres.go`, `csi-spl-wui/src/pages/tenant-settings/members.vue` | add 1 seat mid-month -> cap +1 and the pro-rata draw; red: a remove that drops the cap below occupancy | Q6, C3 |
| C8 | simple_coding / claude | a receipt per card payment, from the hub, with the buyer's billing details (VAT id) | `internal/payments/`, `internal/mail/templates/` | paid webhook -> one receipt mail; replay -> still one | Q7 |
| C9 | simple_coding / claude | self-service cancel of a hosted workspace by its owner: no renewal, data kept as the private-workspace cancel does | `internal/hub/`, `csi-spl-wui/src/pages/tenant-settings/general.vue` | cancel -> no further draw; red: a member (not owner) can cancel | C3 |
| C10 | specs_and_docs / agy | the written offers I and P: a help page with scope, what is covered, response targets, how to buy | `csi-spl-doc/doc/help/` (new page) | `do_check_dist_hygiene` green; red: a customer name in the page fails it | Q8..Q11 |
| C11 | specs_and_docs / agy | spec 075 section 7 broken into build rows (embedding store, worker, semantic search, ACLs), D2-compliant | `csi-spl-doc/specs/075-docs-section/` | a spec review panel | Q12 |

Not a row here: the generic finance connector (its own lane, CO-3), the
cloud-drive upload (spec 194), the private-workspace invoice (spec 181).

<a id="co-7"></a>
### CO-7 Open questions for the owner (one form)

- **Q1 Renewal of a hosted workspace.** Today it is charged once.
  (A) prepaid card top-up drawn down, as D3 already decided, *recommended*;
  (B) a monthly invoice in arrears, as the private workspace (D4);
  (C) a recurring card subscription at the card provider.
- **Q2 The base price.** D1 says cloud cost + 33%, but the shared hub's cost
  per workspace is not measured yet (spec 121 section 7 gate).
  (A) keep the live EUR 20 / month as the hosting share until a closed month
  measures it, then replace it, *recommended*; (B) drop the base, sell seats
  only; (C) wait: sell nothing until the cost is measured.
- **Q3 The human seat price on a hosted workspace.** (A) EUR 9 per human
  member per month, the price D1 already set for every workspace,
  *recommended*; (B) another price, which you name.
- **Q4 Seats in the base.** (A) none: the buyer buys 1..N seats, as the code
  already requires (`handler.go:287`), *recommended*; (B) the base includes
  1 seat; (C) the base includes 3 seats.
- **Q5 Guests.** (A) channel guests stay free, as the cap counts today,
  *recommended*; (B) a guest takes a seat.
- **Q6 Proration.** (A) add at once, pro rata from the balance; remove at the
  month's end, *recommended*; (B) a whole month on add, nothing back on
  remove; (C) seat changes only at the month's turn.
- **Q7 Receipt.** (A) the hub sends its own receipt with the buyer's billing
  details, *recommended*; (B) the card provider's receipt mail is enough.
- **Q8 Offer I price model.** (A) a fixed setup fee plus a monthly upkeep
  fee, both quoted by you per integration, *recommended*; (B) time and
  materials; (C) a yearly retainer.
- **Q9 Offer I licence boundary.** (A) have the AGPL-3.0 boundary between
  csi-spl and a customer's private connector code checked before the first
  contract, *recommended*; (B) sell first, check later.
- **Q10 Offer P levels.** (A) one business-hours tier first (severity 1:
  first answer within 1 business day, severity 2: within 2), *recommended*,
  because round-the-clock needs a person on call; (B) two tiers, business
  hours and 24/7; (C) best effort only, no response targets.
- **Q11 Offer P billing.** (A) an invoice, monthly or yearly, bank transfer,
  *recommended*; (B) the card checkout (needs C3 first).
- **Q12 Offer K packaging.** (A) storage and word search in every hosted
  workspace now; AI retrieval an add-on priced when spec 075 section 7 is
  built, *recommended*; (B) a separate higher plan; (C) per GB stored.
- **Q13 Offer K embeddings.** (A) on the customer's own AI key, as spec 159
  does for agents, *recommended*; (B) a model we host, at cloud cost + 33%.

## Out of Scope

NATS, Kafka, ysg-box, customer GCP accounts, card storage, custom
domains, seats (M4), WUI (005).

<!-- version: 1.5.0 · updated: 2026-11-25 · last-edit: 2026-11-25T00:12:00Z -->
