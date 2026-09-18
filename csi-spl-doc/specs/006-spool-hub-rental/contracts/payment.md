# Contract: Payment — Milestone 2 **public MVP** (buy on the site)

## Status (measured on trunk `bbc41e7`, 2026-09-18)

| Part | Status | Evidence / task |
|---|---|---|
| Schema `payment_checkouts`, `webhook_events_seen` | **Implemented** | `40371a7`, `csi-spl-rdb/src/sql/postgres/spool-hub/0003_payment.sql`; `spool migrate applies 3 file(s)` in `hub-pg.tst.sh` |
| cnf names `SPOOL_HUB_PAYMENT_*`, `SPOOL_HUB_ENABLE_FAKE_PAY` (no secret values) | **Implemented** | `40371a7`, `csi-spl-cnf/csi-spl/all.env.yaml` |
| Event → status map (`billing.MapEvent`) and the 402/429 hub gate | **Implemented** | `internal/billing`; `contracts/http-rental.md` §3–§4 |
| `PaymentProvider` + drivers + fail-closed boot | **Planned** | T018 (`git grep -l PaymentProvider -- '*.go'` → none) |
| Signed webhook handler + dedup | **Planned** | T019 |
| lde fake-pay | **Planned** | T020 (flag exists, no code reads it) |
| Checkout page, success page, one-time email | **Planned** | T021 |
| Vendor-name gate | **Partial** | WUI only (`no-payment-vendor-wui.tst.sh`); Go gate T015 |

**Do not invent a second payment stack.** Copy the csi-rel implementation
(reference only: **do not import** `github.com/csitea/csi-rel/...` as a
module). Adapt the *paid event* to **tenant billing**, not a shop cart.

## Copy these (read-only source)

| csi-rel path | What to take |
|---|---|
| `csi-rel-api/src/internal/orders/payment_provider.go` | `PaymentProvider` interface + stub; fail-closed wiring |
| `csi-rel-api/src/internal/payments/` | Provider drivers (cnf-selected; names stay in cnf/driver files) |
| `csi-rel-api/src/internal/webhooks/` | Signed webhook HTTP, `webhook_events_seen` idempotency |
| `csi-rel-api/src/cmd/api/wire.go` (`paymentWiring`) | Boot: missing/placeholder key in a deployed env **fail-closes** checkout |
| `csi-rel-doc/specs/046-purchase-path/` | Purchase/webhook contracts, no card numbers in our DB |
| `csi-rel-doc/specs/068-extra-payment-providers/` | Extra rails behind the same interface |
| `csi-rel-doc/specs/077-order-flow-fake-pay/` | **lde** fake-pay so tenant activate works without a live rail |
| `csi-rel-doc/specs/000-secret-management.md` | Secrets in Secret Manager; never git |

## Do not copy

Cart, stock holds, marketplace Connect, BIN/sanctions, invoices, storefront
`PaymentFrame` (that is M3 WUI if ever). **M2 SKU is a tenant**, not seats.
Per-user / per-bot monthly licenses are **M4** (`SPEC-spool-m4-seats.md`).

## Map onto spool

| csi-rel | spool |
|---|---|
| order paid webhook | `tenants.billing_status = active` (create tenant if first payment) |
| unpaid / failed | `unpaid` / grace (cnf), send/pin `402`, recv still works in grace |
| refund / cancel | tenant cancel after grace |
| `PaymentProvider` | same interface; amount = **M2 tenant plan** from cnf |
| fake-pay (077) | lde only: `do_spl_tenant_create` / fake paid without a rail |

Hub gate (T012–T013; **no** provider copy): `paid` → `active`; `unpaid`/`failed`
→ `grace`; `refund`/`cancel` → `unpaid` (`billing.MapEvent`; unknown event fails closed). `grace`/`unpaid` refuse send/pin/PUT
file (`402` / `unpaid`); recv, GET file, GET pins, and WS hello stay up in
grace. Over quota (messages/month, pins, stored file bytes; cnf) → `429` /
`quota`. Recv is not gated by quota.

Hub never stores card numbers **or the tenant root private key**.
After pay: **success page + one email** with tenant URL and root private
key (once). Provider and prices in **cnf**. Webhook signature verify
before any row write. Duplicate delivery id → 200 no-op.
The buy surface is a **thin checkout page**, not the M3 Slack UI.


## Seats

**Not M2.** See `doc/md/SPEC-spool-m4-seats.md` (Milestone 4).

## When

**When:** This file is **M2 public MVP** — stranger buys a **tenant** on the
site. Seat packs are **M4**. M1 is proto. M3 is Slack web rollout.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:05:25Z -->
