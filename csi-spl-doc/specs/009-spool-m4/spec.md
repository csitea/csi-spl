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

## Decisions (2026-09-19, lane M4-SEATS-STORE)

- **D-1 Seat rows reuse occupancy.** A user seat is one `tenant_memberships`
  row (0006); a bot seat is one `roster` row `(tenant_id, box_id, agent_id)`
  whose `agent_id` is not `HUM-*`. No second humans or agents table. A box, a
  pin, a message or a WUI tab is not a seat; the pin quota is **not** reused.
- **D-2 Caps.** `tenants.seats_users` / `seats_bots` (`int NOT NULL DEFAULT 0`,
  `>= 0`). **`0` = M4 off (unlimited)** until entitlements are sold; the paid
  webhook (006 lane) writes them with `SetSeatCaps`.
- **D-3 Gate.** Only a **new** seat is refused: `Admit` when it would insert a
  new membership (re-login of a member is a no-op and never consumes a seat);
  `SetRoster` when the replace adds an agent and
  `tenant bots − this box's old set + new set > seats_bots`. Shrinking, or a
  re-announce of the same set, always passes. Refusal = `402` / `quota`
  (003 error-envelope); the message quota stays `429`. Existing peers keep
  send/recv; recv still works in unpaid grace (006 `billing`).
- **D-4 Disabled humans still occupy** their seat until the membership row is
  removed (there is no per-seat period table yet; the period is the 006 UTC
  calendar month). Freeing a seat on disable would let a tenant oversell by
  disable/re-invite inside one period.
- **D-5 Hello over cap.** A box hello whose roster would exceed the cap keeps
  the box's already-seated agents (old ∩ new) and drops the additions; the
  socket stays up so existing peers keep working. `announce` answers the same
  case with an `error` frame `quota` / `402`.
- **D-6 Sign-in over cap.** The registrar maps the seat refusal to
  `auth_error=not_allowed` (the redirect carries no HTTP status). A distinct
  `seat_quota` auth_error is an auth-lane change, not made here.
- **D-7 Only registrar humans are seats.** WUI lobby ids assigned in-process
  when the view door is off are not memberships; with the session door
  (dev + prd, 010/014 lane) the registrar is the only way to be a human in a
  tenant.
- **D-8 project_id mint.** `store.MintProjectID(org, app, env, t)` →
  `{org}-{app}-{env}-{YYYYMMDDHHmm}` (UTC minute, GCP rule
  `^[a-z][a-z0-9-]{4,28}[a-z0-9]$`, ≤ 30). `store.StampBuy` writes
  org/app/project_id/bought_at and on a `project_id` clash retries the next
  minute (up to 3), then a 2-char nonce suffix `-xx` (≤ 27 chars).
  `bought_at` stays the real buy time. Hosted M2 leaves `project_id` NULL
  (partial unique index, so any number of NULLs).

## Out of Scope

M2 hosted (no per-customer project). Changing M3. Shop tables.

<!-- version: 0.2.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:30:00Z -->
