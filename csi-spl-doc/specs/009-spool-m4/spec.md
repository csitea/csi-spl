# Feature Specification: Milestone 4 — seats + buy-time GCP project id

**Feature ID**: `009-spool-m4`

**Created**: 2026-09-18

**Status**: Draft — **M4**. Does **not** change M2.

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-m4-seats.md`  
**Related**: `SPEC-spool-byo-gcp.md` (dedicated billing is still later; **this**
feature is seat SKUs + how a dedicated `project_id` is minted at **buy**)

## User Story 1 — monthly seats (P1)

After M3, the tenant pays **you** per `HUM-*` and per bot peer per month.
Same payment rails as M2, extra line items. Over cap → 402 on **new** seats.

## User Story 2 — project id at buy (P1)

When the customer **hits buy** (paid webhook UTC time), if this SKU mints a
GCP project, the id is:

`{org}-{app}-{env}-{YYYYMMDDHHmm}`

Example: **`csi-spl-dev-202609171743`** (buy at 17:43 UTC on 2026-09-17).

`org` and `app` **need not be unique**. **DNS tenant id** (`<tenant>.spool-hub.ai`)
**must** be unique. Same org+app+env **same UTC minute** → retry (next minute
or 2-char nonce).

Stamp is the **minute they bought**, not hour.

## Requirements

- **FR-001**: M2 checkout SKU unchanged (tenant, not seats).
- **FR-002**: M4 seats as `SPEC-spool-m4-seats.md`.
- **FR-003**: Dedicated `project_id` = `{org}-{app}-{env}-{YYYYMMDDHHmm}` at
  buy (UTC). Length 24; GCP max 30.
- **FR-004**: Persist `tenant_id`, `org`, `app`, `project_id`, `bought_at`
  separately. **Slug is pretty and unique** (`acme` → `https://acme.spool-hub.ai`).
  It is **not** the project id and **not** `{org}-{app}`.
- **FR-005**: Duplicate DNS slug → 409. Duplicate project id → retry stamp.

## Out of Scope

M2 hosted (no per-customer project). Changing M3. Shop tables.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-19T00:05:00Z -->
