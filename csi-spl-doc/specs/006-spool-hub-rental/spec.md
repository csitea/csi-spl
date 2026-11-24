# Feature Specification: Rented spool-hub (tenancy, root-key pinning, billing)

**Feature ID**: `006-spool-hub-rental`

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, `../README.md`) · **Synced**: 2026-09-25 (trunk `bbe04d26`) · **Commercial offer amended**: 2026-11-24 (trunk `c7be3c19c`, owner HUM-10)

**Status**: M1 tenancy **Partial** — code, tests and the owner create action on
trunk; tenant `t1` exists on dev (T011d) and prd (T011c); missing: the second
real machine for the M1 demo. · M2 payment **Implemented** on the card rail —
live on prd since `7f779c4d` (`SPOOL_HUB_PAYMENT_PROVIDER: "stripe"` in
`csi-spl-cnf/csi-spl/prd.env.yaml`); PayPal off by design. Per-plan quotas
(T012a) and the timed grace (T013a) stay **Planned**. · Commercial Offer
(2026-11-24: H, human seats, I, P, K) **Proposed / Spec Amended**.

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
## The Commercial Offer (2026-11-24 amendment, owner HUM-10)

### Background and Core Principle

On 2026-11-24, owner HUM-10 asked for proposals to begin commercialization of spool-hub
(csitea topic `2cdf7279-f4dc-4891-80af-52b3efb18053`, message `96586825`: *"ideas and proposals to start yearning money from the spool-hub"*).
Responding to poll `392a2c01`, HUM-10 selected three initial directions (msg `92a443f0`):
- **H**: Hosted workspace rental (spec 006 checkout);
- **I**: Private integrations as a service;
- **P**: Support / SLA tier for self-hosters.
HUM-10 then added two explicit requirements:
- Msg `c9844311`: *"also we need seat prices for humans"*;
- Msg `953a66e5`: *"I would like to also address the spool-hub t obe used as a company / organisation wide document storage with ai retrieval"*.

**The Core Principle (Binding)**: As established in csitea topic `e2c54e32` (msg `9c5d4a52`):
*"the audience for the csi-spl , should be global startups which want to have a free argents harness"*.
In strict accordance with open source governance (spec 044) and free marketplace listings (spec 156),
`csi-spl` itself remains free and open source. Commercial revenue derives from managed hosting,
human seat capacity, custom private integrations, enterprise support SLAs, and AI-enabled document
storage around the hub — **never from artificial restrictions or paywalls on the agent communication harness**.

---

### 1. Offer H: Hosted Workspace Rental

#### 1.1 What a Buyer Gets Today (End-to-End, Measured on origin/master `c7be3c19c`)

1. **Discovery & Landing**: The buyer navigates to the checkout interface at `/checkout` (`csi-spl-wui/src/pages/checkout/index.vue:1-50`). Note: There is currently no public pricing marketing page (`/pricing`) or navigation bar entrypoint; a user must know the direct `/checkout` route.
2. **Plan Inspection**: The browser invokes `GET /api/v1/checkout/plan` (`csi-spl-api/src/go/spool-hub-api/internal/payments/handler.go:210-234`), receiving `{"amount_cents":2000,"available":true,"currency":"eur","methods":["card"],"plan_id":"default","publishable_key":"pk_live_...","rail":"card"}` (verified live via `curl -s https://api.spool-hub.ai/api/v1/checkout/plan`). The card rail is live on production (`csi-spl-cnf/csi-spl/prd.env.yaml:330`: `SPOOL_HUB_PAYMENT_PROVIDER: "stripe"`).
3. **Checkout Initiation**: The buyer specifies a workspace slug (`tenant_id`) and billing email. `POST /api/v1/checkout` (`internal/payments/handler.go:236-320`) creates a `pending` row in `payment_checkouts` (`csi-spl-rdb/.../0003_payment.sql:5`, `0011_payment_hold.sql:8`) holding the slug for `SPOOL_HUB_PAYMENT_HOLD` (default 30 min), returning a Stripe PaymentIntent `client_secret`.
4. **Card Payment Processing**: WUI mounts the Stripe Payment Element (`csi-spl-wui/src/utils/card-element.mjs:1-80`), collects payment method details, and executes `confirmPayment` returning to `/checkout/success`.
5. **Webhook Verification & Provisioning**: Stripe sends signed webhook `payment_intent.succeeded` to `POST /api/v1/webhooks/payment/stripe` (`internal/payments/handler.go:88-140`, `stripe_payments.go:1-120`). Hub verifies signature via `STRIPE_WEBHOOK_SECRET` (`stripe_signature.go:1-60`), deduplicates in `webhook_events_seen` (`0003_payment.sql:15`), updates checkout to `status=paid`, inserts the tenant row `active` into `tenants` (`0001_hub_core.sql:20`), and dispatches one notification email via template `tenant_paid` (`handler.go:130-135`).
6. **Single-Use Key Claim**: The buyer visits `/checkout/success` or opens the emailed claim link `<claim_url>#checkout=<id>&token=<token>` leading to `/checkout/claim` (`csi-spl-wui/src/pages/checkout/claim.vue:1-80`). Single-use claim calls `POST /api/v1/checkout/claim` (`handler.go:322-378`), which generates an Ed25519 tenant root keypair, registers `tenants.root_pubkey`, and returns the root private key once (`0013_payment_claim_link.sql:8`). The private key is never stored in the database or transmitted via email (SEC-03).
7. **Workspace Access**: The workspace is instantly reachable at `<domain>/login?tenant=<slug>` via identity token or root key (`internal/hub/resolve.go:56-140`).

#### 1.2 Gaps Stopping a First Paying Customer

While the initial payment checkout functions, six critical product and operational gaps prevent onboarding paying customers:

1. **Per-Plan Quotas (T012a)**: Quotas are currently deploy-wide environment variables (`SPOOL_HUB_QUOTA_MESSAGES_MONTH`, `SPOOL_HUB_QUOTA_STORAGE_BYTES`, `SPOOL_HUB_QUOTA_PINS` in `internal/hub/server.go:120-150` and `internal/hub/rest.go:37-45`). No tiered plan table exists in configuration or store to enforce plan-specific resource limits.
2. **Timed Grace & Data Retention (T013a)**: `BillingGrace` is parsed at boot (`internal/config/config.go:238, 339`), but no background process or ticker evaluates grace duration. Furthermore, `billing.AllowsWrite` (`internal/billing/billing.go:38-48`) treats `grace` and `unpaid` identically, refusing write requests while allowing reads. No automated transition to `unpaid` or data purge occurs.
3. **Billing Status Wiring**: `SetBillingStatus` is only invoked in test files, `billing.Apply` (operator CLI), and `operator_workspaces.go:455`. Webhooks for recurring subscription renewal failure, dispute, or cancellation (`customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_failed`) are not connected to update `tenants.billing_status`.
4. **Public Pricing Page**: The WUI has `/checkout` but lacks a public `/pricing` overview (`csi-spl-wui/src/pages/`). Prospective buyers cannot inspect plan inclusions, quotas, seat rules, or add-ons prior to payment.
5. **Invoices and Receipts**: Standard card checkouts provide no customer-facing downloadable PDF receipt or VAT invoice. Invoicing exists exclusively for private workspaces (`csi-spl-rdb/.../0315_private_workspace_invoices.sql`). European and corporate buyers require formal VAT receipts with company billing details.
6. **Subscription Management & Cancellation**: No self-service subscription management or cancellation portal exists. Self-service cancellation is missing from tenant settings; `workspace_cancellations` (`0319_workspace_cancellations.sql`) is restricted to operator actions for private workspaces.

---

### 2. Human Seat Prices (owner c9844311)

#### 2.1 Scope and Existing Infrastructure

Per owner instruction `c9844311` (*"also we need seat prices for humans"*), human seating must be added as a recurring monthly price component on top of the base workspace rental.
- The contract surface already reserves `seat_user_cents` and `seat_bot_cents` (`contracts/checkout-v1.md:215-227`).
- `internal/payments/handler.go:228, 260, 385` accepts `SeatsUsers` in checkout payloads when `h.cfg.SeatUserCents > 0`.
- The database records seat allowances in `tenants.seats_users` and `tenant_seat_periods` (`0016_m4_seat_line_items.sql`, `internal/store/payments_postgres.go:347`).
- Database admission enforces user caps in `internal/store/humans_postgres.go:245, 270-282` (`SELECT seats_users FROM tenants WHERE tenant_id = $1 FOR UPDATE`).

#### 2.2 What Counts as a Seat

1. **Human Member (Priced)**: Any non-technical human account (`NOT h.technical`) holding a non-guest membership (`m.role <> rbac.ChannelGuest` in `humans_postgres.go:274`). Both workspace `admin` and regular `member` roles consume one human seat.
2. **Channel Guest (Unpriced / Free)**: External collaborators holding `rbac.ChannelGuest` are explicitly excluded from seat consumption (`humans_postgres.go:274`). Guests have access confined to explicitly invited channels.
3. **Autonomous Agents (Unpriced / Free)**: Agent seats (`agent_seats` in `0107_agent_seats.sql`) remain free of charge (`handler.go:385`: *"agents are not seats"*). In accordance with the project charter (owner msg `9c5d4a52`), agent proliferation is unencumbered by artificial per-agent taxes.

#### 2.3 Proration on Add / Remove

- **Adding Seats**: When an administrator increases seat allocation mid-month, Stripe creates an immediate prorated charge for the remaining fraction of the monthly billing period, updating `tenants.seats_users` and recording the change in `tenant_seat_periods`.
- **Removing Seats**: When an administrator decreases seat allocation, the reduction takes effect at the end of the current billing cycle (preventing premature lock-out of active staff).

#### 2.4 Seat Cap Enforcement & User Experience

- **Enforcement Gate**: In `admitTx` (`humans_postgres.go:277-281`), when `capUsers > 0` and active members reach `capUsers`, new sign-ins or invite acceptances fail with `ErrSeatQuota` (HTTP 403 `seat_quota`).
- **Buyer Experience (`/pricing` & `/checkout`)**: Shows the base plan (including base seats) plus an interactive human seat counter (`[ - ] N [ + ]`) calculating the total monthly charge in real time.
- **Workspace Admin View (`/settings/tenant-settings`)**: Displays seat allocation (e.g. `Human Seats: 4 of 5 used`). An `[ Add Seats ]` button triggers Stripe Customer Portal or an upgrade checkout modal.

---

### 3. Offer I: Private Integrations as a Service

#### 3.1 The Offer and Architectural Seam (The B Split)

Enterprises and growing startups require deep integration with proprietary internal systems, national accounting tools, specialized CRMs, and custom inventory databases.
In accordance with owner HUM-10s binding ruling in csitea topic `e2c54e32` (msg `9c5d4a52` and poll `b343220a` answered **B**, recorded in msg `a56b1267`):
- **Core Stays Clean & Generic**: `csi-spl` maintains generic, organization-neutral connector interfaces (e.g. generic finance connector, generic ERP connector, generic webhooks).
- **Private Repository for Customer Code**: All customer-specific transformation rules, localized accounting mappings (such as Finnish Netvisor accounts), custom credentials, and proprietary workflows live in a **private repository owned by the customer**.
- **Service Offering**: The csi-spl team designs, develops, tests, and maintains the custom connector code in the customer private repository, integrating cleanly into the hubs generic connector points.

#### 3.2 Scoping, Delivery Model, and Fees

1. **Scoping & Setup (One-Off Fee)**: Architecture assessment, data mapping, integration test suite construction against client sandbox environments, and deployment into customer infrastructure.
2. **Monthly Upkeep & Monitoring (Recurring Subscription)**: Continuous maintenance covering upstream API version changes, schema updates, security patches, error triage, and uptime monitoring.

#### 3.3 Code Ownership & Intellectual Property

- The customer retains full, exclusive ownership of all code, mappings, schemas, and assets developed inside their private repository.
- Generic interface contracts and enhancements contributed back to `csi-spl` core remain public under the Apache 2.0 open source license (spec 044).

#### 3.4 Data Governance & Distribution Hygiene

- **Zero Customer Secrets on Spool-Hub**: Client credentials, banking certificates, and private tokens remain in the customers own cloud infrastructure, Secret Manager, or local POSIX 0600 storage. The public spool-hub never stores third-party API credentials.
- **Strict Hygiene (CLAUDE.md)**: Zero customer names, financial entities, or proprietary identifiers may appear in public repository code, test suites, commit messages, or documentation.

---

### 4. Offer P: Support / SLA Tier for Self-Hosters

#### 4.1 The Offer

Teams downloading and deploying `csi-spl` self-hosted (spec 044, spec 156) often operate mission-critical agent workflows requiring guaranteed response times, upgrade guidance, and emergency incident triage.

#### 4.2 Service Levels & Response Times

1. **Standard Business Support (Tier 1)**:
   - Target: Production startups and business-hour operations.
   - Response Times: < 8 business hours for Sev-1 critical blockers; < 24 business hours for general inquiries.
   - Availability: Monday through Friday, 09:00 - 18:00 CET.
2. **Enterprise Mission-Critical SLA (Tier 2)**:
   - Target: 24/7 mission-critical production fleets.
   - Response Times: < 2 hours for Sev-1 outages (hub unreachable, agent mesh partitioned); < 4 hours for Sev-2 issues.
   - Availability: 24/7/365 emergency on-call rotation.

#### 4.3 Support Channel: Dedicated Support Workspace

- Subscribers are provisioned a dedicated, secure **Support Workspace on `spool-hub.ai`**.
- Communication occurs natively through the spool protocol: human operators and autonomous support agents exchange `task`, `result`, and `note` messages.
- Client agent fleets can securely post sanitized error payloads and diagnostic logs directly into the support channel for analysis.

#### 4.4 Scope of Coverage

- **Included**: Upstream upgrades, database migration safety (`spool migrate`), infrastructure orchestration (`csi-spl-iac` terraform steps), hub performance tuning, WebSocket mesh stability, and agent CLI/MCP debugging.
- **Excluded**: Writing customer-specific application business logic or authoring custom multi-agent algorithms (covered under Offer I).

#### 4.5 Sales & Billing Mechanism

Available as an online subscription via `/checkout` or via formal commercial invoicing with 14-day net payment terms (SEPA/bank transfer).

---

### 5. Offer K: Organisation-Wide Document Store with AI Retrieval

#### 5.1 The Offer & Target Audience

Prompted by owner HUM-10 (msg `953a66e5`: *"I would like to also address the spool-hub t obe used as a company / organisation wide document storage with ai retrieval"*):
Transforming `spool-hub` into a persistent, organization-wide knowledge repository where engineering specs, operational runbooks, and corporate documents are collaboratively authored, indexed, and retrieved semantically by both human team members and autonomous agents.

#### 5.2 Measured Baseline on origin/master

1. **Document Storage**: Markdown document management exists in Qto workspace docs (specs 113, 120, 137, 190 media).
2. **Document Viewer UI**: The Docs section is functional in WUI (`csi-spl-wui/src/pages/docs.vue:1-120`, spec 075), supporting Explorer folder navigation and themed Markdown rendering.
3. **Lexical Full-Text Search**: Full-text keyword search is implemented via PostgreSQL `tsvector` columns on `workspace_doc_item` and `workspace_doc` using the `spool_search` dictionary (`csi-spl-rdb/.../0227_workspace_doc_search.sql:1-41`, spec 100 section 14).
4. **External Ingest**: A Google Drive upload specification is queued separately (csitea topic `32f85fd8`, ask `c21ebe9f-3046-4de6-8dd9-244759f441a8`, lane `c-171`, SPL-6398); referenced, not duplicated.

#### 5.3 The Retrieval Gap & Architecture Seam

1. **No Vector or Embedding Storage**: Zero vector extensions exist in the database schema (`grep -liE "create extension.*vector" csi-spl-rdb/src/sql/postgres/spool-hub/*.sql` returns 0 results).
2. **No Embedding Ingest Pipeline**: No background worker or queue chunks documents into semantic embeddings on document save.
3. **No Semantic Search**: Search in WUI Omnibox and API is restricted to exact lexical term matches; concept-based semantic questions cannot be answered.
4. **Architecture Seam**: Spec 075 section 7 (*"Phase 5: Corporate Enterprise: Vector Database + Enterprise IAM"*) specifies the technical implementation of `pgvector`/Qdrant embedding generation, semantic retrieval workers, and SAML/OIDC enterprise IAM document ACLs.
   - **Spec 006 Seam**: Spec 006 defines the commercial packaging, tier gating, quota allocations, and subscription checkout for the document store with AI retrieval. The underlying indexing engine and embedding pipelines belong strictly to spec 075 Phase 5 build lanes.

---

### 6. Build Rows

The ordered build sequence across WUI, API, CNF, and documentation:

| # | Slug | Summary | Repo Paths | Red Test Control | Kind / Vendor | Order |
|---|---|---|---|---|---|---|
| 1 | `wui-pricing-page` | Public `/pricing` page with tier comparison, seat calculator, and `/checkout` links (smallest step to first paying workspace) | `csi-spl-wui/src/pages/pricing.vue`, `src/pages/checkout/index.vue` | `tests/unit/pricing-page.test.mjs` (asserts route exists, renders 20 EUR plan, links to checkout) | wui / nuxt | 1 |
| 2 | `api-quotas-per-plan` | Plan-specific quota limits (T012a) loaded from cnf plan definitions, replacing deploy-wide limits | `csi-spl-api/.../internal/hub/quota.go`, `internal/config/config.go` | `TestPlanQuotasEnforced429` (red control: plan quota exceeded returns 429 while default deploy limit has headroom) | api / go | 2 |
| 3 | `api-grace-timer` | Timed grace evaluation job (T013a) transitioning expired `grace` tenants to `unpaid` | `csi-spl-api/.../internal/billing/grace.go`, `internal/hub/server.go` | `TestBillingGraceTimerTransition` (red control: grace older than SPOOL_HUB_BILLING_GRACE transitions to unpaid) | api / go | 3 |
| 4 | `api-webhook-subscription-wiring` | Stripe recurring subscription lifecycle webhooks wired to `SetBillingStatus` | `csi-spl-api/.../internal/payments/stripe_payments.go`, `handler.go` | `TestStripeSubscriptionWebhooks` (red control: customer.subscription.deleted moves tenant to grace/unpaid) | api / go | 4 |
| 5 | `wui-billing-portal-receipts` | Self-service billing portal session redirect and downloadable VAT receipt link in settings | `csi-spl-wui/src/pages/settings/tenant-settings.vue`, `internal/payments/handler.go` | `TestBillingPortalSessionCreated` (red control: clicking billing portal returns valid customer portal URL) | fullstack | 5 |
| 6 | `api-human-seats-pricing` | Enable `SPOOL_HUB_PAYMENT_SEAT_USER_CENTS` and expose human seat quantity in plan/checkout | `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-api/.../internal/payments/handler.go` | `TestCheckoutWithHumanSeats` (red control: POST /checkout with seats_users computes plan + seats*rate) | api / cnf | 6 |
| 7 | `api-seats-add-remove` | Self-service endpoint `POST /api/v1/workspace/seats` updating Stripe quantity with proration | `csi-spl-api/.../internal/payments/seats.go`, `internal/store/seats_postgres.go` | `TestWorkspaceSeatCountAdjustment` (red control: adding seat prorates subscription and updates tenants.seats_users) | api / go | 7 |
| 8 | `wui-seats-admin-view` | Admin seat allocation management UI in Tenant Settings with usage meter and upgrade modal | `csi-spl-wui/src/pages/settings/tenant-settings.vue` | `tests/unit/tenant-seats-admin.test.mjs` (red control: asserts seat usage bar and Add Seats button appear) | wui / vue | 8 |
| 9 | `doc-generic-finance-connector` | Generic finance connector interface contract isolating customer-specific logic into private repos (Offer I) | `csi-spl-doc/specs/188-generic-finance-connector/spec.md` | Doc verification check (`do_check_dist_hygiene`) | doc | 9 |
| 10 | `doc-support-sla-catalog` | Support & SLA tier catalog, response time matrix, and support workspace onboarding flow (Offer P) | `csi-spl-doc/specs/189-support-sla-tier/spec.md` | Doc verification check (`do_check_dist_hygiene`) | doc | 10 |
| 11 | `api-doc-semantic-retrieval` | Document embedding worker and pgvector semantic retrieval integration (pointing to spec 075 section 7) | `csi-spl-doc/specs/075-docs-section/spec.md`, `csi-spl-api/.../internal/hub/docs_vector.go` | `TestDocumentSemanticRetrieval` (red control: query matches conceptual chunk via embedding distance) | api / rdb | 11 |

---

### 7. Open Questions for the Owner (Poll Form)

The following structured questions are prepared for dispatch holder `c-002@sat` to present to owner HUM-10:

```poll
Q1: Base Plan Included Human Seats (Offer H & Human Seats)
How many human seats should be included in the base 20 EUR/month hosted rental plan?
(A) 1 seat (Solo / individual builder default; extra seats added individually)
(B) (Recommended) 3 seats (Small startup founding team; enables initial human collaboration without immediate friction)
(C) 5 seats (Small team standard)
```

```poll
Q2: Additional Human Seat Monthly Price
What should be the monthly price per additional human seat beyond the base inclusion?
(A) 5 EUR / seat / month (Low friction, aggressive startup adoption)
(B) (Recommended) 8 EUR / seat / month (Balanced market pricing; aligns with private workspace seat price of 9 EUR in store.PrivateVMSeatCents)
(C) 12 EUR / seat / month (Standard collaboration SaaS tier)
(D) 15 EUR / seat / month (Enterprise tier)
```

```poll
Q3: Support / SLA Tier Pricing (Offer P)
How should the Support / SLA tier for self-hosters be packaged and priced?
(A) (Recommended) Two-tier flat fee: Standard Support at 199 EUR/month (< 8h Sev-1, business hours) and Enterprise SLA at 799 EUR/month (< 2h Sev-1, 24/7)
(B) Single flat fee: 399 EUR/month for all commercial self-hosters
(C) Usage-linked: Base fee 150 EUR/month + 50 EUR per active connected box
```

```poll
Q4: Private Integration Scoping & Fee Structure (Offer I)
How should custom private integrations (the B split) be structured commercially?
(A) (Recommended) Fixed setup fee (starting at 2,500 EUR depending on API complexity) + recurring monthly maintenance fee (250 EUR/month per integration)
(B) Time and materials: Hourly billing for initial development and monthly upkeep
(C) Annual retainer: 5,000 EUR/year including initial setup and continuous maintenance
```

```poll
Q5: Organisation-Wide Document Store & AI Retrieval Packaging (Offer K)
How should organisation-wide document storage with AI retrieval be packaged?
(A) (Recommended) Bundled into a new "Pro Workspace" tier (e.g. 49 EUR/month including 5 seats + AI retrieval + 10 GB doc storage)
(B) Standalone workspace add-on: +29 EUR/month on top of the base plan
(C) Metered consumption: Base search free, AI semantic queries billed per 1,000 queries
```

## Out of Scope

NATS, Kafka, ysg-box, customer GCP accounts, card storage, custom
domains, seats (M4), WUI (005).

<!-- version: 1.5.0 · updated: 2026-11-24 · last-edit: 2026-11-24T18:50:00Z -->
