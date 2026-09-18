# Contract: Payment — Milestone 2 **public MVP** (buy on the site)

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

Cart, stock holds, marketplace Connect, BIN/sanctions, storefront
`PaymentFrame`. Spool SKUs are **seats**, not products.

## Map onto spool

| csi-rel | spool |
|---|---|
| order paid webhook | `tenants.billing_status = active` (create tenant if first payment) |
| unpaid / failed | `unpaid` / grace (cnf), send/pin `402`, recv still works in grace |
| refund / cancel | tenant cancel after grace |
| `PaymentProvider` | same interface; amount = **monthly seats** (cnf unit prices) |
| fake-pay (077) | lde only: `do_spl_tenant_create` / fake paid without a rail |

Hub never stores card numbers **or the tenant root private key**.
After pay: **success page + one email** with tenant URL and root private
key (once). Provider and prices in **cnf**. Webhook signature verify
before any row write. Duplicate delivery id → 200 no-op.
The buy surface is a **thin checkout page**, not the M3 Slack UI.


## Seats (what they pay you)

**Monthly licenses, billed to you** (hosted M2 and dedicated SKU):

| Seat | Counts as | Typical event |
|---|---|---|
| **User** | one `HUM-*` in the tenant | first social register / still active this period |
| **Bot** | one agent id (`CLE-*` / `GRK-*` / `AGY-*`, later prefixes) | first pin/announce on a box in the tenant |

Not billed: `box_id`, messages, files (beyond existing byte quota), WUI
tabs. Two `CLE-07`s on two boxes are **two** bots if they are two peers
(`CLE-07@box-a` and `CLE-07@box-b`).

**How charged:** recurring monthly via the csi-rel payment copy. Checkout
picks **N users + M bots** (or a pack). cnf: unit price per user-month and
per bot-month. Webhook paid → `billing_status=active` and seat entitlements
on the tenant.

**Over seat cap:** refuse **new** HUM register or **new** agent announce/pin
(`402` / `error: quota`). Existing send/recv for already-entitled peers
still work during the period. Recv never blocked for unpaid grace (same as
today).

**Dedicated (BYO GCP):** they still pay **you** these seats monthly. GCP
card pays Run/SQL/GCS only (`SPEC-spool-byo-gcp.md`).

## When

**When:** Milestone 2 = **public MVP** — stranger buys the service on the
site. M1 is technical proto (manual tenant, proof of local + hub mail).
M3 is Slack web rollout.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T22:30:00Z -->
