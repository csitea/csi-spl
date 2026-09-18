# Feature Specification: Rented spool-hub (tenancy, root-key pinning, billing)

**Feature ID**: `006-spool-hub-rental`

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, `../README.md`)

**Status**: M1 tenancy **Partial** (hub-side code + tests + owner create
action on trunk; no cloud tenant yet) · M2 payment **Partial** (schema + cnf names only)

**Narrative (binding)**: `../../doc/md/SPEC-spool-hub-rental.md`  
**Milestones (binding)**: `../../doc/md/SPEC-spool-milestones.md` — M1 manual
tenants on the product domain; M2 buy a tenant on the site; seats are M4
(`../009-spool-m4/`).  
**Trust (binding)**: `../002-box-agent-messaging/contracts/trust-modes.md`.

**Depends on**: 002 (local, frozen) · 004 (pin semantics) · 003 (WS/REST wire,
store, `spool migrate`) · 007 (cloud estate, DNS, ingress; README §6).

## Scope and seams

006 owns, per `../README.md` §5: **tenant host resolution, the tenant row and
its root key, quota `429`, unpaid `402`, the grace window, and M2 payment**.
It cites and does not restate:

| Topic | Owner |
|---|---|
| WS hello/nonce, send envelope, recv/tail frames, REST files/pins shapes, error envelope | 003 `contracts/http-v1.md`, `contracts/error-envelope.md` |
| Pin semantics (409, `--force`, revoke, sync, `BOX-` forbidden) | 004 |
| DNS zone, wildcard records, cert, Cloud Run, ingress, secrets | 007 (README §6) |
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

## User Scenarios & Testing

### User Story 1 — Operator creates a tenant (Priority: P1, M1) · **Partial**

The owner creates a tenant by hand (M1: several owner-made tenants allowed).
They receive the tenant id, the tenant URL and the root keypair; the private
root is shown once and never stored on the hub.

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
   **Then** `https://<tenant>.<env fqdn>/v1/health` answers 200 (003 FR-023). — *Planned*
   (blocked on 007, README §6 steps 3–10).

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
2. **Given** the same on the product domain with a real second machine
   (milestones §Demo), **Then** the same. — *Planned* (007 + M1 demo).

### User Story 3b — Any peer commands any peer (Priority: P1, M1) · **Partial**

Three pinned boxes (GRK, CLE, AGY). Each may `task` each of the others; the
hub neither parses `body` nor privileges a prefix. `contracts/peer-mesh.md`.

1. **Given** boxes a, b, c pinned, **When** A→B, B→C, C→A tasks are sent,
   **Then** all arrive. — *Planned* (no three-box test).
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
   moves to `unpaid` and its data becomes eligible for deletion. — *Planned*
   (grace is not timed; nothing sets `billing_status` outside tests).

### User Story 5 — Stranger buys a tenant on the site (Priority: P1 for M2) · **Partial**

Thin checkout page → provider → signed webhook → tenant `active`; success
page + one email carry the tenant URL and root private key, once.
`contracts/payment.md`.

1. Schema `payment_checkouts` + `webhook_events_seen` and cnf names — *Implemented* (`40371a7`).
2. Provider interface, webhook handler, fake-pay, checkout page, email — *Planned*.

### Edge Cases

- Replay of hello (old `ts`, reused nonce) → 003 `contracts/http-v1.md` §2.
- Tenant URL leaked: unpinned boxes fail hello; `GET /v1/pins` needs the
  WS-issued token (003). The URL is not a secret.
- **Reserved slugs**: a tenant id equal to an env label or infra host (e.g.
  `dev`, `www`, `api`) would shadow `*.dev.<domain>` or a service host. — *Implemented* (FR-016).
- Root key lost: no escrow. Lost root = new tenant (M2: support; no dashboard re-issue).
- Unknown Host, or Host outside the pattern → `404 unknown_tenant`.

## Requirements

| FR | Requirement | Status (evidence) |
|---|---|---|
| **FR-001** | `tenants` row: `tenant_id` (`^[a-z0-9][a-z0-9-]{0,31}$`), 32-byte `root_pubkey`, `billing_status`, `plan_id`, `created_at`. | **Implemented** (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql`) |
| **FR-001a** | Operator-created renter tenants carry `billing_status=manual` (narrative §2). | **Implemented** (`0004_tenant_manual.sql`; `billing.StatusManual` writes like `active`; `TestManualTenantMayWrite`, `TestTenantManualAndPubkeyOnly`) |
| **FR-002** | Tenant from the request **Host** against `$SPOOL_HUB_TENANT_HOST_PATTERN` (`{tenant}.<fqdn>`, cnf; no baked host). Host is the one routing choice; a `/t/<tenant>/` path prefix is not offered. | **Implemented** (`internal/hub/server.go` `tenantOf`; pattern must start `{tenant}.`) |
| **FR-003** | Pin/revoke box pubkeys only with a tenant-root signature; semantics per 004. | **Implemented** (`TestPinRESTRootSigned`, `TestPinRevokeAndForce`) |
| **FR-004** | Pins, messages, files, quotas isolated **per tenant**; the same `box_id`/agent id in two tenants are unrelated. | **Implemented** (`TestTwoTenantsSameAgentIDIsolated`: same `box-a`/`GRK-03` in two tenants, no cross-delivery, A's key refused as B's `box-a`; `TestFilesRoundTripAndTenantIsolation`) |
| **FR-005** | No renter GCP IAM, no per-agent token. Box key + tenant root only. | **Implemented** (hub-e2e runs with no `CLOUDSDK_*`) |
| **FR-006** | M1 ingress IP allowlist / IAP (cnf); M2 allow-unauthenticated and rate-limit unsigned calls at the hosting shield (007). | **Planned** (007 step 10) |
| **FR-007** | Owner tenant-create action prints URL + root private key once; DB holds the pubkey only. | **Implemented** (`csi-spl-orc/src/bash/run/spl-tenant-create.func.sh`, `3690211`) |
| **FR-008** | Quota: messages/month, pins, stored file bytes → `429 quota` (CLI exit 1). Values from the tenant's **plan** (cnf), 0 = unlimited. Recv is not quota-gated. | **Partial** — enforced, but one deploy-wide `SPOOL_HUB_QUOTA_*`, not per `plan_id` |
| **FR-009** | `grace`/`unpaid` refuse send, pin, revoke, PUT file with `402 unpaid`; hello, recv, GET file, GET pins stay up. | **Implemented** (`billing.AllowsWrite`, `TestUnpaidSendPin402RecvInGrace`) |
| **FR-010** | Grace is timed: `grace` older than `SPOOL_HUB_BILLING_GRACE` → `unpaid`; after cnf retention the tenant's data may be deleted. | **Planned** (not timed; no grace-start column) |
| **FR-011** | Any pinned box may send `kind=task` to any agent on any pinned box of the same tenant; no prefix ACL; the hub never parses `body`. | **Partial** — 003 send path has no ACL; three-peer test missing |
| **FR-012** | An operator verb sets billing status (`paid`/`unpaid`/`refund` → `billing.MapEvent`) until M2 webhooks exist. | **Planned** (`MapEvent`, `SetBillingStatus` have no non-test caller) |
| **FR-013** | M2: copy csi-rel payment (interface, drivers, signed webhook + `webhook_events_seen`, fail-closed boot, fake-pay in lde). No card data, no vendor name in source, no root private key stored. | **Partial** — schema + cnf (`40371a7`); Go + checkout **Planned** |
| **FR-014** | M2: success page + one email with tenant URL + root private key, once. | **Planned** |
| **FR-015** | Hygiene: no payment-vendor name in source; no root/box private key in logs. | **Implemented** (`no-baked-host.tst.sh`: no product host / vendor in Go; `no-payment-vendor-wui.tst.sh`; `TestRootPrivateKeyNotLogged`) |
| **FR-016** | Reserved tenant slugs (env labels such as `dev`, and infra hosts) refused at create and never resolved. | **Implemented** (`msg.ValidTenantID` reserved list, `TestValidTenantID`) |
| **FR-017** | `v:1` schema unchanged; no `tenant_id` on `v:1` (the URL is the namespace). | **Implemented** (`grep -c tenant csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go` → 0) |

Removed from the pre-redo spec because 003 owns them (cited, not restated):
WS hello, envelope, `to_box` 409, `delivery` values, same-box mirror, offline
queue, file upload token — 003 `contracts/http-v1.md` and trust-modes §4–§8.

## Success Criteria

- **SC-001**: Two tenants, identical box and agent ids, no cross-talk (FR-004). — Implemented.
- **SC-002**: Two `$SPOOL_ROOT`s, keys + hub URL only, `task`→`result`. — Implemented locally (hub-e2e); cloud Planned.
- **SC-003**: Unpaid tenant: send `402`, recv works; after grace, `unpaid`. — Partial (no grace timer).
- **SC-004**: M1 demo step 2 on `dev` then `prd` with an owner-made tenant. — Planned.
- **SC-005**: M2: a fake-pay checkout in lde yields an `active` tenant and a one-time root key. — Planned.

## Open questions (owner)

- **OQ-006-1** Per-tenant quotas: columns on `tenants` (the `b6a2e80`
  approach, not landed) or a cnf plan table keyed by `plan_id`? Recommendation: cnf plan
  table — prices and quotas both live in cnf (payment.md); a column per tenant
  duplicates it.
- **OQ-006-2** `manual` next to the existing `internal`? Recommendation: keep
  both — `internal` = our own fleet, never billed; `manual` = hand-made renter
  tenant, billed out of band.

## Out of Scope

NATS, Kafka, git-rel, ysg-box, customer GCP accounts, card storage, custom
domains, seats (M4), WUI (005).

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:40:00Z -->
