# Tasks: Milestone 4 — seats + buy-time GCP project id

**Spec**: `./spec.md` · **Ground rules**: `../README.md` (status vocabulary, seams §5)

**Status**: every task **Planned**. M4 starts only after M3 (`005`) ships and
M2 (`006` payment) sells. Nothing below exists yet:
`grep -rn 'seat' csi-spl-rdb/src/sql/postgres/spool-hub/ -> 0` and
`grep -rn 'bought_at\|project_id' csi-spl-rdb/src/sql/postgres/spool-hub/ -> 0`
(trunk 331badd).

## Seams

- Payment rails, event map, 402 gate: **006** owns them; M4 adds line items only.
- `HUM-*` / bot peer identity: **004**. Per-tenant DNS slug resolution: **006**.
- A dedicated GCP project is minted by the infra lane (**007**) — M4 fixes only
  the id format, not the provisioning.

## Tasks

- [ ] T001 Guard that the M2 checkout SKU stays one tenant, never seats: a
      006 payment test asserts no seat line item on the M2 plan — FR-001. **Planned**.
- [ ] T002 Schema: seats per tenant (`HUM-*` and bot peers), monthly period,
      cap from the plan (cnf) — FR-002. **Planned**.
      Lane M4-SEATS-STORE scope: rdb `0012_m4_seats_buy_stamp.sql` adds
      `tenants.seats_users` / `seats_bots` (`0` = M4 off, spec D-2); store
      `CountMembers`, `CountBots`, `SetSeatCaps` on Memory + Postgres (D-1).
      The cnf per-plan cap stays with the webhook (006 lane).
- [ ] T003 Hub gate: a **new** seat over cap → `402`; existing seats keep
      working (reuse 006 `billing`) — FR-002. **Planned**.
      Scope: `store.ErrSeatQuota` from `Admit` (new membership only) and
      `SetRoster` (replace math, D-3); hub `announce` → `error` `quota`/402,
      hello keeps old ∩ new (D-5); registrar → `not_allowed` (D-6).
- [ ] T004 Seat line items on the copied csi-rel payment rails (006
      `contracts/payment.md`) — FR-002. **Planned**.
- [ ] T005 `project_id` stamp `{org}-{app}-{env}-{YYYYMMDDHHmm}` from the paid
      webhook's UTC time, length check ≤ 30 — FR-003. **Planned**.
      Scope: exported `store.MintProjectID` + `store.StampBuy` (D-8); the
      paid webhook that calls them is the 006 payment lane's.
- [ ] T006 Persist `tenant_id`, `org`, `app`, `project_id`, `bought_at` as
      separate columns; slug ≠ project id ≠ `{org}-{app}` — FR-004. **Planned**.
      Scope: 0012 columns + `Tenant` fields + `SetBuyStamp`; 003
      data-model `tenants` text matches the DDL again.
- [ ] T007 Duplicate DNS slug → `409`; duplicate project id in one UTC minute
      → retry with the next minute or a 2-char nonce — FR-005. **Planned**.
      Scope: partial `UNIQUE (project_id) WHERE project_id IS NOT NULL`;
      `SetBuyStamp` clash → `ErrConflict`; `StampBuy` retries (D-8).

## FR → task

| FR | Tasks | Status |
|---|---|---|
| FR-001 | T001 | Planned |
| FR-002 | T002, T003, T004 | Planned |
| FR-003 | T005 | Planned |
| FR-004 | T006 | Planned |
| FR-005 | T007 | Planned |

<!-- version: 0.2.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:30:00Z -->
