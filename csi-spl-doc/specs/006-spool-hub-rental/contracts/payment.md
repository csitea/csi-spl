# Contract: Payment — Milestone 2 **public MVP** (buy on the site)

## Status (measured on trunk `bbc41e7`, 2026-09-18)

| Part | Status | Evidence / task |
|---|---|---|
| Schema `payment_checkouts`, `webhook_events_seen` | **Implemented** | `40371a7`, `csi-spl-rdb/src/sql/postgres/spool-hub/0003_payment.sql`; `spool migrate applies 3 file(s)` in `hub-pg.tst.sh` |
| cnf names `SPOOL_HUB_PAYMENT_*`, `SPOOL_HUB_ENABLE_FAKE_PAY` (no secret values) | **Implemented** | `40371a7`, `csi-spl-cnf/csi-spl/all.env.yaml` |
| Event → status map (`billing.MapEvent`) and the 402/429 hub gate | **Implemented** | `internal/billing`; `contracts/http-rental.md` §3–§4 |
| `PaymentProvider` + drivers + fail-closed boot | **Implemented** | T018 `68b4cf7` (`internal/payments`) |
| Signed webhook handler + dedup | **Implemented** | T019 `68b4cf7` + `4abc060` (dedup + apply in one transaction) |
| lde/dev fake-pay | **Partial** | T020 code `68b4cf7`; dev needs the 030 apply |
| Checkout backend + claim + one-time email | **Partial** | T021 code `68b4cf7`; dev proof open; HTTP contract `checkout-v1.md` |
| Checkout page, success page | **Planned** | UI lane, against `checkout-v1.md` |
| Vendor-name gate | **Implemented** | WUI `no-payment-vendor-wui.tst.sh`; Go `no-baked-host.tst.sh` (T015, list widened for the csi-rel rails) |

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
| order (pending, stock hold) | `payment_checkouts` row `pending` = a **slug hold** (`SPOOL_HUB_PAYMENT_HOLD`); **no `tenants` row yet** |
| order paid webhook | `tenants` row created `active` with the checkout's root public key (or re-activated) |
| unpaid / failed | `unpaid` / grace (cnf), send/pin `402`, recv still works in grace |
| refund / cancel | tenant cancel after grace |
| `PaymentProvider` | same interface; amount = **M2 tenant plan** from cnf |
| fake-pay (077) | lde only: `do_spl_tenant_create` / fake paid without a rail |

Hub gate (T012–T013; **no** provider copy): `paid` → `active`; `unpaid`/`failed`
→ `grace`; `refund`/`cancel` → `unpaid` (`billing.MapEvent`; unknown event fails closed). `grace`/`unpaid` refuse send/pin/PUT
file (`402` / `unpaid`); recv, GET file, GET pins, and WS hello stay up in
grace. Over quota (messages/month, pins, stored file bytes; cnf) → `429` /
`quota`. Recv is not gated by quota.

Hub never stores card numbers, and never the tenant root private key **in
clear**: between checkout and the buyer's claim it holds only the key sealed
(AES-256-GCM) under the buyer's `claim_token`, which the hub keeps as a hash
only, so the hub alone cannot open it; the first claim wipes the seal
(`checkout-v1.md` §0). After pay: **success page + one email** with tenant URL
and root private key (once, at claim). Provider and prices in **cnf**. Webhook
signature verify before any row write. Duplicate delivery id → 200 no-op.
The buy surface is a **thin checkout page**, not the M3 Slack UI.

Rails (T018, 2026-09-19): the Go source names **protocols, not vendors**
(`no-baked-host.tst.sh`). `SPOOL_HUB_PAYMENT_PROVIDER` = `""` (none: checkout
503) · `fake` (lde/dev) · `hosted-hmac` (csi-rel 069's hosted-page rail:
`checkout-*` header HMAC, redirect, signed callback). csi-rel's card-intent,
approve-capture and two other redirect rails are not copied until a vendor
is chosen; each would be a new protocol-named driver behind the same
`PaymentProvider` seam. Unknown name → the hub refuses to boot.

## Recovery

A buyer who paid but lost the claim token (closed the tab before the success
page) has an `active` tenant whose key nobody holds. The operator re-keys it:
`spool root-keygen`, then replace `tenants.root_pubkey` by hand (owner-gated
DB change) and hand the new key over out of band. The hub never re-mints a
key on its own.


## Seats

**Not M2.** See `doc/md/SPEC-spool-m4-seats.md` (Milestone 4).

## When

**When:** This file is **M2 public MVP** — stranger buys a **tenant** on the
site. Seat packs are **M4**. M1 is proto. M3 is Slack web rollout.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:05:25Z -->
