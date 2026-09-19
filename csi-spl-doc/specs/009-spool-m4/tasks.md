# Tasks: Milestone 4 — seats + buy-time GCP project id

**Spec**: `./spec.md` · **Ground rules**: `../README.md` (status vocabulary, seams §5)

**Status**: T001-T007 **Implemented** in code (T002/T004/T005 by CLE-3405,
2026-09-19; live once rdb 0016 is applied and the hub image carrying them rolls). M4 starts only after M3 (`005`) ships and
M2 (`006` payment) sells; the schema and gate are in place with caps at
`0` (= M4 off) until then:
`grep -c 'seats_users\|project_id' csi-spl-rdb/src/sql/postgres/spool-hub/0012_m4_seats_buy_stamp.sql -> 8`.

## Seams

- Payment rails, event map, 402 gate: **006** owns them; M4 adds line items only.
- `HUM-*` / bot peer identity: **004**. Per-tenant DNS slug resolution: **006**.
- A dedicated GCP project is minted by the infra lane (**007**) — M4 fixes only
  the id format, not the provisioning.

## Tasks

- [x] T001 Guard that the M2 checkout SKU stays one tenant, never seats: a
      006 payment test asserts no seat line item on the M2 plan — FR-001.
      **Implemented** (CLE-3371): `go test ./internal/payments -run TestM2SkuIsOneTenantNoSeats`
      (the card intent carries only amount/currency/metadata/automatic methods;
      the paid tenant has 0 seats, no project id, no bought_at). CONTROL:
      planting `line_items[0][quantity]` in the intent turns it red.
- [x] T002 Schema: seats per tenant (`HUM-*` and bot peers), monthly period,
      cap from the plan (cnf) — FR-002. **Implemented**: caps + occupancy
      (rdb 0012 `cc65587`, store `7f2442c`, applied dev + prd); the plan's
      seat prices in cnf `hub.env` (`SPOOL_HUB_PAYMENT_SEAT_USER_CENTS` /
      `_SEAT_BOT_CENTS` / `_SEATS_MAX`, "0" = not sold); the monthly period
      is rdb `0016_m4_seat_line_items.sql` `tenant_seat_periods` (one row per
      tenant per UTC month, RLS as 0014), written by the paid transition in
      the SAME transaction as the caps. Check:
      `go test ./internal/store -run 'Seats|CheckoutPaidAppliesSeatLineItems|LineItemShape'`
      (+ `hub-pg.tst.sh` for Postgres; `TestRLSCoversEveryTenantTable` lists the table).
- [x] T003 Hub gate: a **new** seat over cap → `402`; existing seats keep
      working (reuse 006 `billing`) — FR-002. **Implemented** `7f2442c`.
      Check: `go test ./internal/store ./internal/hub -run 'Seat'` (controls:
      over-cap member → ErrSeatQuota, re-login ok; announce grow → 402 quota,
      shrink ok; mutation of `overBotCap` turns both red).
      Scope: `store.ErrSeatQuota` from `Admit` (new membership only) and
      `SetRoster` (replace math, D-3); hub `announce` → `error` `quota`/402,
      hello keeps old ∩ new (D-5); registrar → `not_allowed` (D-6).
- [x] T004 Seat line items on the copied csi-rel payment rails (006
      `contracts/payment.md`) — FR-002. **Implemented**: `POST /api/v1/checkout`
      takes `seats_users` / `seats_bots` (a priced kind 1..SEATS_MAX, an
      unpriced kind 0 = unlimited; the M2 plan refuses seats `seats_not_sold`);
      total = plan + seats; the card rail records the items as PaymentIntent
      `metadata[<item>_qty|_unit_cents]` + description
      (`payments.LineItemProvider`); the checkout row keeps them (0016); only
      the verified paid webhook applies them. PayPal (off) charges the same
      total without item detail. Check: `go test ./internal/payments -run 'M4|M2Sku'`
      (CONTROLS: forged webhook → 400, no tenant, no period; replay →
      `duplicate`, one period; a 4th bot on 3 paid seats → `ErrSeatQuota`;
      mutation: dropping the cap write turns it red; T001 still green).
- [x] T005 `project_id` stamp `{org}-{app}-{env}-{YYYYMMDDHHmm}` from the paid
      webhook's UTC time, length check ≤ 30 — FR-003. **Implemented**: mint +
      `StampBuy` `7f2442c`; the paid transition stamps a dedicated SKU
      (`SPOOL_HUB_PAYMENT_DEDICATED`, checkout `org` / `app`) inside its
      transaction (each candidate under a savepoint; `stampWith` = StampBuy's
      order). Check: `go test ./internal/payments -run M4Dedicated` +
      `./internal/store -run 'SeatsBuyStamp|CheckoutPaidAppliesSeatLineItems'`
      (CONTROL: the minute held by another tenant → the next minute;
      mutation: skipping the held check turns it red).
- [x] T006 Persist `tenant_id`, `org`, `app`, `project_id`, `bought_at` as
      separate columns; slug ≠ project id ≠ `{org}-{app}` — FR-004.
      **Implemented** `cc65587` + `7f2442c`; data-model matches (`4585699`).
      Scope: 0012 columns + `Tenant` fields + `SetBuyStamp`; 003
      data-model `tenants` text matches the DDL again.
- [x] T007 Duplicate DNS slug → `409`; duplicate project id in one UTC minute
      → retry with the next minute or a 2-char nonce — FR-005.
      **Implemented** `7f2442c` (slug 409 unchanged; hosted NULL ×2 ok).
      Scope: partial `UNIQUE (project_id) WHERE project_id IS NOT NULL`;
      `SetBuyStamp` clash → `ErrConflict`; `StampBuy` retries (D-8).

## FR → task

| FR | Tasks | Status |
|---|---|---|
| FR-001 | T001 | Implemented |
| FR-002 | T002, T003, T004 | Implemented |
| FR-003 | T005 | Implemented |
| FR-004 | T006 | Implemented |
| FR-005 | T007 | Implemented |

<!-- version: 0.4.0 · updated: 2026-09-19 · last-edit: 2026-09-19T16:25:00Z -->
