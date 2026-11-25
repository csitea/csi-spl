# Feature Specification: Rented spool-hub (tenancy, root-key pinning, billing)

**Feature ID**: `006-spool-hub-rental`

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, `../README.md`) · **Synced**: 2026-09-25 (trunk `bbe04d26`) · **Commercial offer**: 2026-11-25 (v1.5.0 trunk `f7161909f`, SPL-6410; v1.6.0 trunk `c9dd02117`, SPL-6473)

**Status**: M1 tenancy **Partial** — code, tests and the owner create action on
trunk; tenant `t1` exists on dev (T011d) and prd (T011c); missing: the second
real machine for the M1 demo. · M2 payment **Implemented** on the card rail —
live on prd since `7f779c4d` (`SPOOL_HUB_PAYMENT_PROVIDER: "stripe"` in
`csi-spl-cnf/csi-spl/prd.env.yaml`); PayPal off by design. Per-plan quotas
(T012a) and the timed grace (T013a) stay **Planned**. · Commercial offer
(H, human seats, I, P, K): **Decided** (v1.6.0, Q1–Q11 answered in msg
`ddf19d47`, [section](#commercial-offer)); hosted workspace sales stay **off**
until the shared hub's cost per workspace is measured over a closed UTC month
(Q1 C, rows C0 and C0b); a paid checkout charges once, nothing renews (G-H1).

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
## Commercial offer (v1.6.0, 2026-11-25, owner HUM-10)

Issues SPL-6410 (v1.5.0, epic SPL-61, landed `e5063f872`) and SPL-6473
(v1.6.0, epic SPL-2402, folding all 11 owner answers from form `38ceff26`,
msg `ddf19d47`). Doc only: this section builds nothing, sets no live price
and changes no cnf or terraform. Every price rule below is an owner decision
(cited by spec, form and msg id); none is invented here. First draft by a-959
(`37d8f9f22`, not reviewed); v1.5.0 re-measured by c-155; v1.6.0 folded and
re-verified on `origin/master` `c9dd02117` by a-492.

### CO-0 The owner's words

csitea topic `2cdf7279`, HUM-10, verbatim:

- 2026-11-24, `96586825`: "idea and proposals to start yearning money from the spool-hub"
- 2026-11-24, `92a443f0`, form `392a2c01` answered **H, I, P**: "Hosted workspace
  rental (built: spec 006 checkout); Private integrations as a service;
  Support / SLA tier for self-hosters"
- 2026-11-24, `c9844311`: "also we need seat prices for humans"
- 2026-11-24, `953a66e5`: "I would like to also address the spool-hub t obe used as a
  company / organisation wide document storage with ai retrieval"
- 2026-11-25 07:47Z, `ddf19d47`, form `38ceff26`: answered all 11 commercial-offer
  questions Q1–Q11 (recorded in full in [CO-7](#co-7); notably **Q1 C** — sell
  nothing until the cost is measured — and **Q11 B** — AI retrieval on a model
  we host, at cloud cost + 33%).

The line he drew on 2026-11-24 (csitea `e2c54e32`, msg `9c5d4a52`): "the
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

Measured on `origin/master` `c9dd02117` (2026-11-25, n = 1 per command) unless
a row says otherwise. Paths under `internal/` are in
`csi-spl-api/src/go/spool-hub-api/`.

<a id="co-1"></a>
### CO-1 Offer H: hosted workspace rental

#### CO-1.1 What exists today, end to end

| step | what happens | evidence |
|---|---|---|
| 1 find it | the only way in is the "Buy a workspace" link with its price, shown in the signed-out app shell; the static pages carry no price and no buy link | `csi-spl-wui/src/layouts/default.vue:139` (`<BuyWorkspaceLink />`); `csi-spl-wui/src/components/BuyWorkspaceLink.vue:33`; `grep -ciE 'checkout\|price\|buy' csi-spl-wui/src/public/{about,terms}.html` -> 0 and 0; no `pricing` page in `csi-spl-wui/src/pages/` (`ls`) |
| 2 the plan | `GET /api/v1/checkout/plan` | `internal/payments/handler.go:212`; live 2026-11-25: prd and dev both `{"amount_cents":2000,"available":true,"currency":"eur","methods":["card"],"plan_id":"default","private_workspace":{"currency":"EUR","seat_member_cents":900,"vm_margin_pct":33},"rail":"card",...}` (`curl -s https://api.spool-hub.ai/api/v1/checkout/plan`); `csi-spl-cnf/csi-spl/prd.env.yaml:330-331`, `dev.env.yaml:319,325` |
| 3 order | slug + email; `POST /api/v1/checkout` holds the slug and opens a one-off card payment | `handler.go:145` route, `:322` `checkout`; `internal/payments/stripe_payments.go:110` posts `/v1/payment_intents` |
| 4 pay | the card form in the page | `csi-spl-wui/src/pages/checkout/index.vue`, `csi-spl-wui/src/utils/card-element.mjs` |
| 5 paid | the signed webhook marks the checkout paid and creates the tenant `active` | `handler.go:155` route, `:843` `stripeWebhook`, `:820` `stripeKind` (`payment_intent.succeeded` -> paid); `internal/store/payments_postgres.go:155` -> `paidTx` |
| 6 key | one mail with a single-use claim link (no key in it); the root key is shown once in the browser | `handler.go:679` `afterPaid`, `:631` `claim`; `csi-spl-wui/src/pages/checkout/claim.vue`, `success.vue` (FR-014) |
| 7 use | members sign in with `?tenant=<id>`, boxes name it with `SPOOL_TENANT` (026) | User Story 1 scenario 3 above |

Demand so far: on prd `payment_checkouts` has **0 rows** and `tenants` reads
`internal 3`, `manual 21`, no `active` (read-only `do_spl_db_query`,
ENV=prd, 2026-11-25, measured in v1.5.0). No stranger has ever paid.

#### CO-1.2 Decision Q1 C: no sale until the hub's cost per workspace is measured (`ddf19d47`)

The owner picked **Q1 C** (`ddf19d47`, form `38ceff26`): **sell nothing until
the shared hub's cost per workspace is measured over a closed UTC calendar
month.** The live EUR 20 hosted checkout (`prd.env.yaml:330-331`,
`dev.env.yaml:319,325`) is **not offered** until that measurement holds.

- **How hosted sales stay off now (row C0b)**: set
  `SPOOL_HUB_PAYMENT_PROVIDER: ""` and `SPOOL_HUB_PAYMENT_PLAN_CENTS: "0"` in
  both `dev.env.yaml:319,325` and `prd.env.yaml:330-331` (already the
  `all.env.yaml:626-628` defaults; setting `PLAN_CENTS: "0"` with
  `PROVIDER: "stripe"` is refused at boot by
  `internal/payments/config.go:182-184`), **and** set
  `SPOOL_HUB_ENABLE_FAKE_PAY: "false"` in `dev.env.yaml:318` (otherwise
  `Rail()` still returns `"fake"` on dev when `Provider == ""` and
  `EnableFakePay` is true, `config.go:268`, leaving dev at
  `available: true` since `dev.env.yaml:328` sets the claim URL and
  `checkPrices` allows `PLAN_CENTS: "0"` on the fake rail). With all three
  off, `Rail()` returns `"none"` (`config.go:264-272`) and `Methods()` is
  empty (`config.go:275-285`) on both dev and prd: `GET /api/v1/checkout/plan`
  answers `available: false, rail: "none"` (`handler.go:219`),
  `POST /api/v1/checkout` answers `503 payment_unavailable`
  (`handler.go:520-521`), `/checkout` renders `checkout.not_on_sale`
  (`csi-spl-wui/src/pages/checkout/index.vue:19`,
  `csi-spl-wui/src/utils/checkout-client.ts:136`), and
  `BuyWorkspaceLink.vue:33` hides the price. Private-workspace orders on
  `POST /api/v1/checkout/private-workspace` (`handler.go:35,400`) call no
  payment provider (spec 181 Q-18 C) and stay unaffected.
- **What is measured (row C0, first build row)**: the shared production hub's
  monthly cloud cost in `csi-spl-prd`: Cloud Run hub
  (`030-cloud-run-hub/04-cloud-run-service.tf:107-112`, `role = "hub"`),
  Cloud SQL Postgres (`040-cloud-sql-postgres/03-cloud-sql.tf:92-97`,
  `role = "hub-db"`), GCS buckets (`050-gcs-files/03-files-bucket.tf:45-50`
  `role = "hub-files"`, `051-gcs-docs/03-docs-bucket.tf:33-38` `role = "docs"`,
  `052-gcs-workspace-docs/03-workspace-docs-buckets.tf:81-86`
  `role = "workspace-docs"`), Firebase Hosting (`019`/`021`), and DNS /
  networking (`025`), plus any shared pool boxes hosting customer workspaces
  (spec 122 Q-5, owner `b6a56949`). Excluded: `csi-spl-dev`, the operator
  satellite (`box=satellite`, unless it hosts customer workspaces),
  private-workspace VMs (billed directly under spec 181 Q-8 A,
  `csi-spl-iac/src/bash/run/spl-vm-cost-per-day.func.sh:94-104`), and all AI
  tokens (D2). Because `do_spl_estate_cost_read` groups by
  `(day, project, box, service)` and writes `cost_lines.project_or_vendor` as
  `<project>` or `<project>/box=<label>` (dropping the `workspace` label,
  `csi-spl-iac/src/bash/run/spl-estate-cost-read.func.sh:23-25,146-154`), and
  step `062-gcp-workspace-vms` stamps every private VM with
  `box = "${var.vm_name_prefix}-${tenant}"`
  (`062-gcp-workspace-vms/03-vm.tf:18-19`, `02-variables.tf:53-55`, cnf
  `steps.062-gcp-workspace-vms.vm_name_prefix` at `all.env.yaml:314-315`),
  row C0 excludes private VMs in `cost_lines` by that `box` label prefix in
  `project_or_vendor` (and `box=satellite` unless hosting customer
  workspaces).
- **From which billing data**: a **full, closed UTC calendar month** of the
  GCP BigQuery billing export (`gcp_billing_export_v1_*` in
  `csi-spl-prd.csi_spl_prd`, cnf `env.cost.gcp.export_source_project` and
  `export_source_dataset`, `csi-spl-cnf/csi-spl/all.env.yaml:1948-1949`),
  queried as the dedicated reader SA `spl-cost-reader` (`all.env.yaml:1953`,
  `roles/bigquery.dataViewer` only, never the owner account) into
  `cost_lines` (`origin = 'billing_export'`, `source = 'gcp'`,
  `tenant_id IS NULL`, `superseded_by IS NULL`) and `cost_coverage`
  (`rdb 0166_cost_lines.sql:43-81`) by `do_spl_estate_cost_read`
  (`csi-spl-iac/src/bash/run/spl-estate-cost-read.func.sh:49`, run nightly by
  `do_spl_cost_rollup_daily`,
  `csi-spl-orc/src/bash/run/spl-cost-rollup-daily.func.sh:49`). A month counts
  as closed only after the trailing `env.cost.reread_days` (`5` days,
  `all.env.yaml:1908`, spec 123 section 4.5 month close) AND when every day
  of that UTC month has `cost_coverage.state = 'ok'` (0 `missing`, 0
  `partial`, 0 unrecorded days; credits netted, EUR billed currency). Any
  incomplete month or `origin = 'estimate'` row is refused, never read as 0
  (spec 121 v1.6 / spec 122 section 9 pricing gate).
- **The formula (cost + 33%, D1)**:
  - `monthly_hub_cost_eur` = sum of `cost_lines.eur_micros` for the closed UTC
    month over the included `csi-spl-prd` shared-hub lines (and any shared
    customer pool boxes).
  - `cost_per_workspace_eur = monthly_hub_cost_eur / W_max`, where `W_max` is
    the measured hub workspace capacity (spec 122 section 8 M2/M3 and Q-6 A,
    `2d9490e7`: dividing by `W_max` prevents early buyers from carrying an
    idle hub). Measured on `c9dd02117`: `capacity_measurements` (spec 122 M2/M3)
    is not built yet (`git grep -l capacity_measurements -- csi-spl-rdb
    csi-spl-api csi-spl-iac csi-spl-orc` -> 0 files); row C0 therefore requires
    an explicit measured `W_MAX > 0` input (or reads `capacity_measurements`
    once spec 122 lands) and refuses to guess when absent, while printing the
    active-workspace count and `monthly_hub_cost_eur / active_workspaces`
    beside it for the owner.
  - `base_price_eur = ceil_cents(cost_per_workspace_eur * 1.33)` — cloud cost
    per workspace + 33% (D1, spec 181 Q-11 A), rounded up to whole EUR cents,
    proposed as `SPOOL_HUB_PAYMENT_PLAN_CENTS`.
  - Monthly total for a hosted workspace with `N` human seats (`N >= 1`,
    Q2 A; channel guests and agents = 0, Q3 A, D1):
    `base_price_eur + N * EUR 9` (plus the AI retrieval add-on if enabled once
    built, Q10 A, Q11 B).
- **Who switches sales on**: **the owner (HUM-10) only.** Row C0 is read-only
  and never mutates cnf, the hub DB or GCP. After reviewing C0's closed-month
  report, the owner gives explicit go to set `SPOOL_HUB_PAYMENT_PROVIDER:
  "stripe"`, the measured `SPOOL_HUB_PAYMENT_PLAN_CENTS`, and
  `SPOOL_HUB_PAYMENT_SEAT_USER_CENTS: "900"` in `dev.env.yaml` first and
  `prd.env.yaml` second (dev leads prd), and to apply terraform step
  `030-cloud-run-hub` (row C6; repo CLAUDE.md: nothing mutates GCP without
  the owner).

#### CO-1.3 The gaps that stop a first paying customer

| # | gap | evidence |
|---|---|---|
| G-H0 | **hosted sales are live at an unmeasured EUR 20** while Q1 C (`ddf19d47`) forbids selling until a closed month measures the shared hub's cost per workspace; no read-only action computes `(closed-month prd hub cost / W_max) * 1.33` yet | `prd.env.yaml:330-331`, `dev.env.yaml:319,325`; live `GET /api/v1/checkout/plan` -> `amount_cents: 2000, available: true` (CO-1.1 step 2) |
| G-H1 | **nothing charges month 2.** The card rail is a one-off payment intent, yet the payment's description says "(monthly)". The renewal is decided: a prepaid card top-up drawn down (D3, "for everyone"), not re-asked; it is not built | `stripe_payments.go:99` (`" (monthly)"`), `:110`; `git grep -niE 'top.?up' -- csi-spl-api/src/go/spool-hub-api/internal/payments` -> nothing |
| G-H2 | no public price page: a visitor who is not on the signed-out shell never sees a price (or the "not on sale yet" state + offers I and P while Q1 C holds) | CO-1.1 step 1 |
| G-H3 | quotas are one deploy-wide set, not per plan (T012a, OQ-006-1) | `internal/config/config.go:424-426`; `csi-spl-cnf/csi-spl/all.env.yaml:609-611` |
| G-H4 | grace is not timed (T013a, OQ-006-3): `BillingGrace` is only validated, and `grace` and `unpaid` both refuse writes alike | `config.go:427`, `:857`; `internal/billing/billing.go:87` `AllowsWrite` |
| G-H5 | billing status moves only on a refund or cancel event (and the operator verbs); no event moves a tenant to `grace` when its money runs out, because no balance exists (G-H1) | `payments_postgres.go:163-172` (refund, cancel -> `billing.MapEvent`; `internal/billing/billing.go:50` -> `unpaid`); `git grep -n 'SetBillingStatus(' -- '*.go' \| grep -v _test` -> `billing.go:70`, `internal/hub/operator_workspaces.go:455` and the store |
| G-H6 | no receipt from the hub for a card payment (decided **Q5 A**, `ddf19d47`: the hub sends its own receipt with the buyer's billing details); the invoice tables are the private workspace's (D4) | `grep -n receipt internal/payments/*.go \| grep -v _test` -> one comment (`stripe_payments.go:81`); rdb `0315_private_workspace_invoices.sql` header |
| G-H7 | no self-service cancel: the cancel route is the operator's, for a private workspace | rdb `0319_workspace_cancellations.sql` header (`POST /v1/operator/workspaces/{id}/cancel`) |

<a id="co-2"></a>
### CO-2 Human seat prices (owner `c9844311`; Q2 A, Q3 A, Q4 A `ddf19d47`)

**The price is decided**: EUR 9 per human member per month, for every
workspace (D1). The live plan already shows it for the private workspace only
(`seat_member_cents: 900`, CO-1.1 step 2; `internal/store/price_plans.go:32`).
On hosted workspaces, seats go on sale together with the measured base plan
when the owner switches hosted sales on after row C0 (row C6).

| part | today | evidence |
|---|---|---|
| price switch | seats are sold when a seat price is above 0; both are `"0"` in cnf, so the hosted plan sells none (spec 009: "Implemented in code, not sold") | `internal/payments/config.go:69-71`, `:288` `SeatsSold`; `csi-spl-cnf/csi-spl/all.env.yaml:644-646` |
| what the plan shows | `seat_user_cents`, `seat_bot_cents`, `seats_max` appear only when sold | `handler.go:227-228`; `contracts/checkout-v1.md:215-218` |
| quantity | a priced kind is bought 1..`SEATS_MAX` (1000) per checkout (**Q2 A**, `ddf19d47`: no seats included in the base; the buyer buys 1..N seats) | `handler.go:287` |
| paid | the paid webhook writes the caps on `tenants` and the UTC month's `tenant_seat_periods` row | `payments_postgres.go:341-355`, `:378` `seatCapsTx`; rdb `0016_m4_seat_line_items.sql` |
| the cap | a NEW human is refused at sign-in or invite once the count reaches the cap; re-login never takes a seat; 0 = no cap | `internal/store/humans_postgres.go:241-282` (`ErrSeatQuota`) |

**What counts as a seat** (as the cap counts it, `humans_postgres.go:271-275`,
confirmed by **Q3 A**, `ddf19d47`): a non-technical human whose membership
has any role but channel guest takes one seat. A channel guest stays free
(takes no seat). An agent takes none (D1; `handler.go:385` "agents are not
seats"). The bot-seat price stays `"0"` (D1), so nothing in the agent harness
is priced.

**Proration (decided Q4 A, `ddf19d47`).** Today seats are set only at
checkout; there is no route to add or remove one later (CO-6 row C7). Under
**Q4 A**: adding a seat takes effect at once and is drawn from the prepaid
balance pro rata for the rest of the month; removing a seat takes effect at
the month's end, and existing members are never locked out (`SetSeatCaps`
"never lowers occupancy", `internal/store/seats.go:28-29`).

**What people see** (none of it is built; rows C6, C7):

- the buyer: the measured base plan, the EUR 9 seat price, a seat count
  (1..`seats_max`, Q2 A) and the month's total, before paying;
- the workspace admin: "N of M seats used" and an add / remove control, in
  workspace settings (`csi-spl-wui/src/pages/tenant-settings/members.vue`
  shows no seat count today: `grep -ci seat` -> 0).

<a id="co-3"></a>
### CO-3 Offer I: private integrations as a service (Q6 A, Q7 A `ddf19d47`)

**The offer.** We build and keep running one integration a customer needs
with its own systems (accounting, CRM, ERP, inventory). It follows D5: the
customer-specific code lives in a **private repo the customer owns**, and
writes into a **generic, org-neutral csi-spl connector**. csi-spl ships the
connector, never the customer's mapping. The first such connector, the
generic finance connector, is specified by its own lane (csitea `e2c54e32`,
ask `0634faec`); this spec references it and does not duplicate it.

| part | decision |
|---|---|
| scoping | a short written scope per integration: the source system, the data read or written, the connector it writes into, the test sandbox the customer provides, the acceptance test |
| price (**Q6 A**, `ddf19d47`) | a fixed setup fee per integration plus a monthly upkeep fee (upstream API changes, failures, monitoring); both amounts quoted by the owner per integration |
| code ownership & licence gate (**Q7 A**, `ddf19d47`) | the customer owns the private repo and its code; a change to the generic connector goes into csi-spl under AGPL-3.0. **Prerequisite before the first contract**: have the AGPL-3.0 boundary between csi-spl and the customer's private connector code checked first |
| data | the customer's credentials stay in the customer's own secret store or private repo deployment, never in csi-spl and never in a public commit; no customer name, account or identifier in csi-spl (distribution hygiene, repo CLAUDE.md); a brief for a non-claude lane never carries one (fleet data rule) |
| sold by | a quote and an invoice; not the card checkout |

<a id="co-4"></a>
### CO-4 Offer P: support / SLA tier for self-hosters (Q8 A, Q9 A `ddf19d47`)

**Who buys it.** A team that runs csi-spl itself (spec 044 open source,
spec 156 marketplace VM) and wants someone to answer when it breaks.

| part | decision |
|---|---|
| channel | one support workspace per customer on spool-hub; its members post, our seats answer. Nothing runs inside the customer's estate |
| covered | upgrades between released versions (`v<X.Y.Z>` tags), database migrations, the install and its terraform steps, incidents in csi-spl itself (hub, WUI, box CLI, MCP) |
| not covered | the customer's own integrations (that is CO-3), their cloud bill, their AI vendor accounts |
| response times (**Q8 A**, `ddf19d47`) | one business-hours tier first: severity 1 (the hub is down) first answer within 1 business day, severity 2 (a part is broken) within 2 business days |
| sold by (**Q9 A**, `ddf19d47`) | an invoice, monthly or yearly, bank transfer (like D4); does not wait on the hosted card checkout or C3b |

Nothing of P exists in code today, and nothing needs to before a first
contract: it is a written offer (row C10), a support workspace and an
invoice.

<a id="co-5"></a>
### CO-5 Offer K: organisation-wide document store with AI retrieval (Q10 A, Q11 B `ddf19d47`)

**Who buys it.** A company that wants its specs, runbooks and documents in
one place, searched by both its people and its agents.

Measured baseline (`origin/master` `c9dd02117`):

| part | today | evidence |
|---|---|---|
| documents | per-workspace Qto documents | rdb `0157_workspace_docs.sql`; specs 113, 120, 137, 190 (media) |
| the Docs section | built (Phase 1 repo docs; Phases 2–4 planned) | spec 075; `csi-spl-wui/src/pages/docs.vue` |
| full-text search over documents | built: Postgres `tsvector` per section and per document | rdb `0227_workspace_doc_search.sql`; spec 100 section 14 |
| a vector / embedding store | **none** | `grep -liE 'create extension.*vector' csi-spl-rdb/src/sql/postgres/spool-hub/*.sql \| wc -l` -> 0 |
| semantic retrieval + enterprise IAM | designed, not built | spec 075 section 7 ("Phase 5") |
| upload from a cloud drive | specified separately | spec 194 v0.1 (SPL-6398), not duplicated here |

**The offer (Q10 A, Q11 B, `ddf19d47`).**

- **Included now (Q10 A)**: document storage and Postgres full-text word
  search are part of every hosted workspace at no extra charge.
- **AI retrieval add-on (Q10 A + Q11 B)**: semantic AI retrieval is a
  separate opt-in add-on, built after the document store (spec 075 Phases 2–4
  and section 7) and priced strictly from the **measured cloud cost + 33%**
  (D1) of **an embedding model we host ourselves** (Q11 B). Under D2 no AI
  token is ever sold and no third-party token-billed embedding API is called.
- **What Q11 B needs (build rows C12–C14, after the document store)**:
  1. **Hosting (row C12)**: a dedicated IAM-gated Cloud Run v2 service
     (terraform step `033-cloud-run-embeddings` — step `033` is free on
     `c9dd02117` between `032-gcp-cloud-run-domain-mapping` and
     `036-spl-demo-workspace` — following the `031-cloud-run-pdf` pattern:
     `ingress = "INGRESS_TRAFFIC_ALL"` with IAM-only invocation,
     `min_instance_count = 0`, `cpu_idle = true`, `startup_cpu_boost = false`,
     `csi-spl-iac/src/terraform/031-cloud-run-pdf/04-cloud-run-service.tf:24-60`),
     running an open-weights embedding model image pinned in cnf in
     `europe-north1` (zero idle cost), labelled
     `{ org, app, env, role = "embeddings" }` so its compute, memory and
     traffic cost is isolated in `gcp_billing_export_v1_*`. Row C12 also
     wires `hub.embeddings.url` from `all.env.yaml` through step
     `030-cloud-run-hub` (`030-cloud-run-hub/02-variables.tf:127`,
     `030-cloud-run-hub/04-cloud-run-service.tf:41,58`,
     `csi-spl-iac/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl:28`,
     matching `pdf_url` -> `SPOOL_PDF_URL`) so `030` passes
     `SPOOL_HUB_EMBEDDINGS_URL` only when set. Vector rows sit in Postgres
     (`pgvector`, HNSW index, strict `tenant_scope` RLS, spec 075 section
     7.1).
  2. **Key handling (rows C12–C13)**: **no third-party AI API key** (D2) and
     **no static API key or shared secret** in git, cnf, terraform state or
     logs (repo CLAUDE.md). Service-to-service auth is GCP IAM only:
     `033-cloud-run-embeddings` grants `roles/run.invoker` solely to the hub
     runtime service account (`031-cloud-run-pdf/05-invoker.tf:7-13`, no
     `allUsers`, no `allAuthenticatedUsers`), and the hub calls it with its
     own Google ID token (`idtoken.NewClient`, pattern
     `internal/topicpdf/render.go:61`). The URL is one cnf/env var
     (`SPOOL_HUB_EMBEDDINGS_URL`, empty = AI retrieval off, `503
     embeddings_unavailable`, matching `SPOOL_PDF_URL` in
     `internal/config/config.go:685` and `internal/topicpdf/render.go:76`).
     The service is stateless: it persists no workspace document text, logs
     no document body, and holds no cross-tenant cache; all reads and writes
     enforce `tenant_scope` RLS and spec 075 section 7.2 per-document ACLs.
  3. **Metering per workspace & Q10 add-on pricing (rows C13–C14)**: every
     document-embed and semantic-search call appends a tenant-scoped row to
     `usage_events` (`rdb 0171_usage_events.sql:50-72`) under non-token
     resource kinds (`embed_compute_ms`, `embed_vector_bytes`, added by a
     forward-only migration; never `llm_tokens_*`, preserving the no-token
     constraint in `rdb 0302_private_workspace_price.sql:45`). A per-workspace
     `ai_retrieval_enabled` opt-in flag defaults `false`. Row C14 reads the
     closed-month `role = "embeddings"` GCP cloud cost in EUR from
     `gcp_billing_export_v1_*` (credits netted, all days `ok`), allocates it
     across opted-in workspaces by their metered `usage_events` share, and
     prices Q10's add-on at **measured cloud cost + 33%** (D1). Consistent
     with Q1 C, the add-on is not offered for sale until its closed-month
     cloud cost is measured and the owner switches it on.

<a id="co-6"></a>
### CO-6 Build rows, in order (disjoint files, red controls)

Row **C0** (measure the shared hub's cost per workspace over a closed month)
is the **first** build row (Q1 C, `ddf19d47`); **C0b** takes the live EUR 20
checkout off sale until C0's measurement holds and the owner switches hosted
sales on. Offers I and P (C10) and the non-selling groundwork (C1–C5, C8–C9,
C11) can proceed without opening hosted sales; hosted-checkout activation
with human seats (C6) waits on C0, C0b, C3b and explicit owner go. The Q11 B
hosted-model rows (C12–C14) run **after** the document store (spec 075
Phases 2–4 and C11).

Kind and vendor follow the fleet split (`specs_and_docs` and `i18n`: agy,
backup claude; coding: claude, backup agy). Concurrent rows own disjoint file
paths: shared files are strictly serialized by `waits on` (`C0b -> C6` on
`{dev,prd}.env.yaml` and `hub-payment-030.tst.sh`; `C0b -> C6 -> C12` on
rendered `030-cloud-run-hub.vars.tfvars`; `C4 -> C12` on `all.env.yaml`;
`C4 -> C12 -> C13` on `internal/config/config.go`; `C3b -> C8 -> C6 -> C7`
on `internal/payments/handler.go` and `checkout/index.vue`; WUI locale keys
in `csi-spl-wui/i18n/locales/*.json` follow their row order; each new rdb
migration claims its own number via `do_rdb_migration_next`). Every row ships
with a red control. `C<n>` rows map 1-to-1 to tasks `T024..T040` in
`tasks.md`.

| row | kind / vendor | what | paths | test and red control | waits on |
|---|---|---|---|---|---|
| C0 | simple_coding / claude | **Measure the shared hub's cost per workspace over a closed UTC month** (Q1 C): read-only action reading `cost_lines` (`origin='billing_export'`, `source='gcp'`, `superseded_by IS NULL`) and `cost_coverage` for a closed UTC month (every day `state='ok'` after the 5-day `reread_days` window) over `csi-spl-prd` shared-hub services + any shared customer pool hosts, excluding `csi-spl-dev`, non-hosting `box=satellite`, private-VM rows by the `062-gcp-workspace-vms` `box` label prefix in `cost_lines.project_or_vendor` (`<project>/box=<vm_name_prefix>-<tenant>`), and AI tokens; divides by measured `W_max` (`W_MAX > 0`, or spec 122 M2/M3 `capacity_measurements` once built; also prints active-workspace count), applies `+ 33%` (D1) rounded up to EUR cents, and prints the proposed `SPOOL_HUB_PAYMENT_PLAN_CENTS` for the owner; never mutates cnf or GCP — only the owner switches sales on | `csi-spl-iac/src/bash/run/spl-hub-workspace-cost.func.sh`, `csi-spl-iac/src/bash/tests/spl-hub-workspace-cost.tst.sh` | fixture closed month (all days `ok`) -> prints exact `ceil_cents((cost / W_max) * 1.33)`; red control: 1 `partial`/`missing` day, an `estimate` row, an unset/zero `W_MAX`, a `csi-spl-dev` line, or a private-VM `project_or_vendor` (`.../box=<vm_name_prefix>-<tenant>`) line included in the sum fails the test | - |
| C0b | simple_coding / claude, cnf + 030 apply with owner's go | **Take the live EUR 20 hosted checkout off sale** (Q1 C): set `SPOOL_HUB_PAYMENT_PROVIDER: ""`, `SPOOL_HUB_PAYMENT_PLAN_CENTS: "0"`, and `SPOOL_HUB_ENABLE_FAKE_PAY: "false"` in `dev.env.yaml:318,319,325` and `PROVIDER: ""` + `PLAN_CENTS: "0"` in `prd.env.yaml:330-331`, re-render tfvars (`do_tpl_gen`), apply `030-cloud-run-hub` dev then prd on owner's go so both dev and prd answer `available: false, rail: "none"` on `GET /api/v1/checkout/plan`, `503 payment_unavailable` on `POST /api/v1/checkout`, and `checkout.not_on_sale` on `/checkout` while `POST /api/v1/checkout/private-workspace` stays up | `csi-spl-cnf/csi-spl/dev.env.yaml`, `csi-spl-cnf/csi-spl/prd.env.yaml`, rendered `csi-spl-cnf/csi-spl/{dev,prd}/tf/030-cloud-run-hub.vars.tfvars`, `csi-spl-iac/src/bash/tests/hub-payment-030.tst.sh` | `do_tpl_gen` + `hub-payment-030.tst.sh` assert `PROVIDER == ""`, `PLAN_CENTS == "0"`, and `ENABLE_FAKE_PAY == "false"` on dev and prd; red control: `PLAN_CENTS: "2000"` with `stripe` on prd, OR `SPOOL_HUB_ENABLE_FAKE_PAY: "true"` on dev (leaving dev on `rail: "fake", available: true`), fails the test | - (owner go for apply) |
| C1 | simple_coding / claude, then i18n / agy | Public price page `/pricing` rendering `GET /api/v1/checkout/plan` (no price typed into the page) and linking to `/checkout` only while `available: true`; when `available: false` (Q1 C hold), shows "not on sale yet" and links to offers I and P / private workspace; linked from `about.html` and sign-in; every locale | `csi-spl-wui/src/pages/pricing.vue`, `csi-spl-wui/src/public/about.html`, `csi-spl-wui/src/pages/login.vue`, `csi-spl-wui/i18n/locales/*.json`, `csi-spl-wui/tests/e2e/pricing.test.mjs` | e2e with the plan mocked: `available:false` -> no buy button; `available:true` -> price rendered from JSON; red control: a literal `2000` or `20` typed into `pricing.vue` fails a grep test | - |
| C2 | simple_coding / claude | Payment description stops saying `"(monthly)"` while nothing renews (G-H1) | `internal/payments/stripe_payments.go`, `internal/payments/stripe_payments_test.go` | unit test asserts the payment intent description omits `"(monthly)"`; red control: the old `" (monthly)"` string fails it | - |
| C3a | complex_coding / claude | Renewal (G-H1) as D3 says, store side: a workspace prepaid balance, drawn down monthly by the measured base plan and its human seats (EUR 9/seat, Q2 A, Q3 A); at zero the workspace goes `grace` | `internal/store/balance.go`, `internal/store/balance_postgres.go`, `internal/store/balance_test.go`, `internal/billing/drawdown.go`, `internal/billing/drawdown_test.go`, new rdb migration | a month's draw-down lowers the balance by base + seats; at zero -> `grace`; red control: a balance at zero that stays `active` fails it | - |
| C3b | complex_coding / claude | Renewal, checkout side: a card top-up of an existing workspace's prepaid balance | `internal/payments/topup.go`, `internal/payments/topup_test.go`, `internal/payments/handler.go` (top-up route), `internal/store/payments_postgres.go`, `csi-spl-wui/src/pages/checkout/topup.vue` | a signed top-up webhook credits once; red control: a replayed webhook that credits twice fails it | C3a |
| C4 | simple_coding / claude | Per-plan quotas (T012a): quotas keyed by `plan_id` instead of deploy-wide `SPOOL_HUB_QUOTA_*` | `internal/config/config.go`, `internal/hub/server.go`, `csi-spl-cnf/csi-spl/all.env.yaml` (quota lines 609–611), `internal/hub/quota_plan_test.go` | a plan with a lower quota -> `429` while the deploy-wide value has room; red control: the deploy-wide value winning fails it | OQ-006-1 |
| C5 | simple_coding / claude | Timed grace (T013a): `grace_started_at` recorded on entry to `grace`, moved to `unpaid` after `SPOOL_HUB_BILLING_GRACE` | `internal/billing/grace.go`, `internal/billing/grace_test.go`, new rdb migration | fake clock past `BillingGrace` -> `unpaid`; red control: one second before `BillingGrace` moving to `unpaid` fails it | OQ-006-3, C3a |
| C8 | simple_coding / claude | Hub receipt per card payment (Q5 A): hub sends its own receipt mail with the buyer's billing details (name/company, address, VAT id) on every paid checkout and top-up | `internal/payments/receipt.go`, `internal/payments/receipt_test.go`, `internal/payments/handler.go` (billing details + `afterPaid` hook), `internal/mail/templates/payment_receipt.tmpl`, new rdb migration | paid webhook -> one receipt mail carrying buyer VAT id and line items; red control: a replayed webhook sending a second mail, or a receipt missing billing details, fails it | C3b |
| C6 | simple_coding / claude, cnf + 030 apply with owner's go | Human seats on the hosted checkout & sales switch-on (Q1 C, Q2 A, Q3 A, D1): set the C0-measured `SPOOL_HUB_PAYMENT_PLAN_CENTS`, `SPOOL_HUB_PAYMENT_SEAT_USER_CENTS: "900"` (bot seats stays `"0"`, guests stay free), and `SPOOL_HUB_PAYMENT_PROVIDER: "stripe"` in `dev.env.yaml` then `prd.env.yaml` (re-render `030` tfvars, update `hub-payment-030.tst.sh` from C0b's off-sale assertion to the measured-price assertion, apply on owner's go) ONLY after C0's closed-month report and owner go; seat count (1..`seats_max`) and month total in `/checkout` | `csi-spl-cnf/csi-spl/dev.env.yaml`, `csi-spl-cnf/csi-spl/prd.env.yaml`, rendered `csi-spl-cnf/csi-spl/{dev,prd}/tf/030-cloud-run-hub.vars.tfvars`, `csi-spl-iac/src/bash/tests/hub-payment-030.tst.sh`, `csi-spl-wui/src/pages/checkout/index.vue`, `csi-spl-wui/tests/e2e/checkout-seats.test.mjs` | checkout with 3 seats -> total = measured base + 3 x EUR 9; red control: `seats_users: 0` accepted while priced, or a channel guest counted against the seat cap, fails it | C0, C0b, C3b, C8, owner go |
| C7 | complex_coding / claude | Seats after purchase (Q4 A): workspace admin adds or removes seats; add takes effect at once with pro-rata draw from the prepaid balance; remove takes effect at month end; "N of M seats used" in workspace settings | `internal/payments/seats_manage.go`, `internal/payments/seats_manage_test.go`, `internal/payments/handler.go` (seat-change route), `internal/store/seats_postgres.go`, `csi-spl-wui/src/pages/tenant-settings/members.vue` | add 1 seat mid-month -> cap +1 and pro-rata balance draw; remove -> scheduled for month end; red control: a remove that lowers the cap immediately or below occupancy fails it | C3a, C6 |
| C9 | simple_coding / claude | Self-service cancel of a hosted workspace by its `biz_owner` (G-H7): stops further monthly draw-down, keeps hub data for 30 days as private-workspace cancel (`rdb 0319`) does | `internal/hub/hosted_cancel.go`, `internal/hub/hosted_cancel_test.go`, `csi-spl-wui/src/pages/tenant-settings/general.vue` | `biz_owner` cancel -> no further draw-down and 30-day retention scheduled; red control: a non-owner member cancelling -> 403, allowed fails it | C3a |
| C10 | specs_and_docs / agy | Written offers I and P (Q6 A, Q7 A, Q8 A, Q9 A): help page with offer I (fixed setup + monthly upkeep per owner quote, private customer repo + generic connector, AGPL-3.0 boundary check prerequisite before first contract) and offer P (one business-hours tier, sev-1 1 business day / sev-2 2 business days, monthly or yearly bank-transfer invoice, support workspace) | `csi-spl-doc/doc/help/commercial-offers.md` | `do_check_dist_hygiene` green, AGPL gate + business-hours targets present; red control: a customer name or a 24/7 SLA promise in the page fails the check | - (AGPL check Q7 A before first offer-I contract) |
| C11 | specs_and_docs / agy | Document store AI retrieval spec breakdown (Q10 A, Q11 B): update spec 075 section 7 into build rows (pgvector extension + tenant-RLS embeddings table, chunking/indexing worker on doc save, semantic search query, per-doc ACLs 075 7.2) wired to our **self-hosted** embedding model (Q11 B), with zero third-party AI API keys and zero token resale (D2) | `csi-spl-doc/specs/075-docs-section/spec.md`, `csi-spl-doc/specs/075-docs-section/tasks.md` | cross-vendor spec review; red control: a row calling a third-party token-billed embedding API, storing a static API key, or naming no red control fails the review | - (build runs after spec 075 Phases 2–4 document store) |
| C12 | complex_coding / claude (iac, apply with owner's go) | **Hosted embedding model service, IAM key handling & 030 URL wiring** (Q11 B, after document store): dedicated IAM-gated Cloud Run v2 service (`033-cloud-run-embeddings`, pattern `031-cloud-run-pdf`: `ingress = "INGRESS_TRAFFIC_ALL"` with IAM-only access, scale-to-zero `min_instance_count = 0`, `cpu_idle = true`, `startup_cpu_boost = false`), running an open-weights embedding model in `europe-north1`, labelled `role = "embeddings"`, `roles/run.invoker` granted ONLY to the hub runtime SA (no `allUsers`, no static API key in git/cnf/state/logs), stateless (no doc text persisted or logged); wires `hub.embeddings.url` in `all.env.yaml` through step `030-cloud-run-hub` as `SPOOL_HUB_EMBEDDINGS_URL` (matching `pdf_url` -> `SPOOL_PDF_URL`) | `csi-spl-iac/src/terraform/033-cloud-run-embeddings/`, `csi-spl-iac/src/tpl/%org%-%app%/%env%/tf/033-cloud-run-embeddings.*`, `csi-spl-iac/src/terraform/030-cloud-run-hub/{02-variables.tf,04-cloud-run-service.tf}`, `csi-spl-iac/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl`, `csi-spl-cnf/csi-spl/all.env.yaml` (`hub.embeddings.url`), rendered `csi-spl-cnf/csi-spl/{dev,prd}/tf/030-cloud-run-hub.vars.tfvars`, `csi-spl-iac/src/bash/tests/embeddings-service-033.tst.sh` | terraform plan + test assert `ingress = "INGRESS_TRAFFIC_ALL"`, `min_instance_count = 0`, `role = "embeddings"`, IAM invoker restricted to hub runtime SA, and `030` merges `SPOOL_HUB_EMBEDDINGS_URL` only when set; red control: `allUsers` invoker, static API key env var, or `min_instance_count > 0` fails `embeddings-service-033.tst.sh` | C4, C6, C11, spec 075 Phases 2–4 |
| C13 | complex_coding / claude | **Hub embedding client & per-workspace metering** (Q10 A, Q11 B): load `SPOOL_HUB_EMBEDDINGS_URL` in `internal/config/config.go` (matching `SPOOL_PDF_URL` at `:685`); hub client calling it via GCP IAM ID token (`idtoken.NewClient`, pattern `internal/topicpdf/render.go:61`; empty URL -> `503 embeddings_unavailable`); forward-only rdb migration adding `embed_compute_ms` and `embed_vector_bytes` kinds to `usage_events` (never `llm_tokens_*`) and per-workspace `ai_retrieval_enabled` opt-in (default `false`); meter every doc-index and semantic-query call per workspace under tenant RLS | `internal/config/config.go` (`SPOOL_HUB_EMBEDDINGS_URL`), `internal/embeddings/`, `internal/hub/doc_semantic_search.go`, new rdb migration, `internal/embeddings/client_test.go`, `internal/store/embed_usage_test.go` | doc index + semantic search write tenant-scoped `usage_events` (`embed_compute_ms`, `embed_vector_bytes`); opted-out workspace refused; red control: an unmetered embedding call, cross-tenant vector read, or `llm_tokens_*` billing line fails the test | C12 |
| C14 | simple_coding / claude | **Hosted-model cost measurement & Q10 add-on pricing** (Q10 A, Q11 B): read-only BigQuery cost action reading `role = "embeddings"` closed-month GCP cloud cost in EUR from `gcp_billing_export_v1_*` (credits netted, every day `ok`), allocating across opted-in workspaces by metered `usage_events` share, applying **cloud cost + 33%** (D1), and gating the Q10 AI retrieval add-on price until a closed-month measurement holds and the owner switches the add-on on | `csi-spl-iac/src/bash/run/spl-embeddings-cost-read.func.sh`, `csi-spl-iac/src/bash/tests/spl-embeddings-cost-read.tst.sh` | fixture closed month of `role = "embeddings"` export rows + metered workspace shares -> exact per-workspace `(cloud_cost * 1.33)` in EUR; red control: an incomplete month, an unlabelled service line, or a non-opted-in workspace billed fails the test | C13 |

Not a row here: the generic finance connector (its own lane, CO-3), the
cloud-drive upload (spec 194), the private-workspace invoice (spec 181).

<a id="co-7"></a>
### CO-7 Owner decisions (Q1–Q11, form `38ceff26`, msg `ddf19d47`)

All 11 questions from v1.5.0 are **decided** (owner HUM-10, csitea topic
`2cdf7279`, form `38ceff26`, msg `ddf19d47`, 2026-11-25 07:47Z). No
commercial-offer question stays open (earlier `OQ-006-1` and `OQ-006-3` in
the 2026-09-25 sync above still gate rows C4 and C5).

| q | owner's pick | decision (msg `ddf19d47`, form `38ceff26`) | folded into |
|---|---|---|---|
| **Q1** | **C** *(v1.5 had A)* | Sell nothing until the cost is measured (no live EUR 20 hosted checkout until a closed UTC month measures the shared hub's cost per workspace; owner switches sales on) | CO-1.2, CO-1.3 (G-H0), CO-6 (C0, C0b, C6) |
| **Q2** | **A** | None: the buyer buys 1..N seats, as the code already requires (`handler.go:287`) | CO-2, CO-6 (C3a, C6) |
| **Q3** | **A** | Guests stay free, as the seat cap counts today (`humans_postgres.go:271-275`) | CO-2, CO-6 (C3a, C6) |
| **Q4** | **A** | Add at once, pro rata from the balance; remove at the month's end | CO-2, CO-6 (C7) |
| **Q5** | **A** | The hub sends its own receipt with the buyer's billing details | CO-1.3 (G-H6), CO-6 (C8) |
| **Q6** | **A** | A fixed setup fee plus a monthly upkeep fee, both quoted by the owner per integration | CO-3, CO-6 (C10) |
| **Q7** | **A** | Have the boundary between csi-spl and the customer's private code checked before the first contract | CO-3, CO-6 (C10) |
| **Q8** | **A** | One business-hours tier first: severity 1 answered within 1 business day, severity 2 within 2 | CO-4, CO-6 (C10) |
| **Q9** | **A** | An invoice, monthly or yearly, bank transfer | CO-4, CO-6 (C10) |
| **Q10** | **A** | Storage and word search in every hosted workspace now; AI retrieval an add-on priced when it is built | CO-5, CO-6 (C11, C13, C14) |
| **Q11** | **B** *(v1.5 had A)* | On a model we host, at cloud cost + 33% (hosting, IAM key handling, per-workspace metering; prices Q10's add-on) | CO-5, CO-6 (C11, C12, C13, C14) |

Questions as asked in v1.5.0 (form `38ceff26`), kept as the record:

- **Q1 The base price. Owner: C (`ddf19d47`).** (A) keep the live EUR 20 /
  month until a closed month measures it; (B) drop the base, sell seats only;
  **(C) wait: sell nothing until the cost is measured.**
- **Q2 Seats in the base. Owner: A (`ddf19d47`).** **(A) none: the buyer buys
  1..N seats, as the code already requires (`handler.go:287`)**; (B) base
  includes 1 seat; (C) base includes 3 seats.
- **Q3 Guests. Owner: A (`ddf19d47`).** **(A) channel guests stay free, as
  the cap counts today**; (B) a guest takes a seat.
- **Q4 Proration. Owner: A (`ddf19d47`).** **(A) add at once, pro rata from
  the balance; remove at the month's end**; (B) whole month on add, nothing
  back on remove; (C) seat changes only at month's turn.
- **Q5 Receipt. Owner: A (`ddf19d47`).** **(A) the hub sends its own receipt
  with the buyer's billing details**; (B) the card provider's receipt mail is
  enough.
- **Q6 Offer I price model. Owner: A (`ddf19d47`).** **(A) a fixed setup fee
  plus a monthly upkeep fee, both quoted by the owner per integration**; (B)
  time and materials; (C) a yearly retainer.
- **Q7 Offer I licence boundary. Owner: A (`ddf19d47`).** **(A) have the
  AGPL-3.0 boundary between csi-spl and a customer's private connector code
  checked before the first contract**; (B) sell first, check later.
- **Q8 Offer P levels. Owner: A (`ddf19d47`).** **(A) one business-hours tier
  first (severity 1: first answer within 1 business day, severity 2: within
  2)**; (B) two tiers, business hours and 24/7; (C) best effort only.
- **Q9 Offer P billing. Owner: A (`ddf19d47`).** **(A) an invoice, monthly or
  yearly, bank transfer**; (B) the card checkout (needs C3b first).
- **Q10 Offer K packaging. Owner: A (`ddf19d47`).** **(A) storage and word
  search in every hosted workspace now; AI retrieval an add-on priced when
  spec 075 section 7 is built**; (B) a separate higher plan; (C) per GB
  stored.
- **Q11 Offer K embeddings. Owner: B (`ddf19d47`).** (A) on the customer's
  own AI key, as spec 159 does for agents; **(B) on a model we host, at cloud
  cost + 33%.**

## Out of Scope

NATS, Kafka, ysg-box, customer GCP accounts, card storage, custom
domains, seats (M4), WUI (005).

<!-- version: 1.6.0 · updated: 2026-11-25 · last-edit: 2026-11-25T09:05:00Z -->
