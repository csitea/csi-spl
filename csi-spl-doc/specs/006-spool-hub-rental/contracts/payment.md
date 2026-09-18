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

Cart, stock holds, marketplace Connect, BIN/sanctions, invoices, storefront
`PaymentFrame` (that is M3 WUI if ever). Spool has no SKUs.

## Map onto spool

| csi-rel | spool |
|---|---|
| order paid webhook | `tenants.billing_status = active` (create tenant if first payment) |
| unpaid / failed | `unpaid` / grace (cnf), send/pin `402`, recv still works in grace |
| refund / cancel | tenant cancel after grace |
| `PaymentProvider` | same interface; amount = plan price from cnf |
| fake-pay (077) | lde only: `do_spl_tenant_create` / fake paid without a rail |

Hub never stores card numbers **or the tenant root private key**.
After pay: **success page + one email** with tenant URL and root private
key (once). Provider and prices in **cnf**. Webhook signature verify
before any row write. Duplicate delivery id → 200 no-op.
The buy surface is a **thin checkout page**, not the M3 Slack UI.

## When

**When:** Milestone 2 = **public MVP** — stranger buys the service on the
site. M1 is technical proto (manual tenant, proof of local + hub mail).
M3 is Slack web rollout.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:20:00Z -->
