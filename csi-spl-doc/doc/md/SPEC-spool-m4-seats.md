# SPEC: Milestone 4 — monthly licenses per user and per bot

Status: **M4**. Does **not** change M2.  
M2 stays: stranger **buys a tenant** on the site (csi-rel payment copy,
tenant URL + root key).  
M4 adds **seat metering**: they pay **you** a **monthly license per human
user and per bot**.

Related: `specs/006-spool-hub-rental/contracts/payment.md` (rails, not M2 SKU),
`SPEC-spool-byo-gcp.md` (dedicated infra still pays **these** seats).

---

## 1. Seats

| Seat | Counts as | Typical event |
|---|---|---|
| **User** | one `HUM-*` in the tenant | first social register / still entitled this period |
| **Bot** | one agent peer (`CLE-*` / `GRK-*` / `AGY-*` @ box) | first pin/announce |

Not a seat: `box_id`, messages, files (beyond byte quota), WUI tabs.
`CLE-07@box-a` and `CLE-07@box-b` are **two** bots.

---

## 2. Charge

Recurring monthly on the **same csi-rel payment copy** as M2 (new line items
/ subscription items, not a new stack). cnf: unit price per user-month and
per bot-month. Checkout or a later “add seats” page picks **N users + M bots**.

Webhook paid → seat entitlements on the tenant (`seats_users`, `seats_bots`).
M2 `billing_status=active` is **not** replaced; M4 **adds** counts.

**Over cap:** refuse **new** HUM register or **new** agent announce/pin
(`402` / `error: quota`). Existing peers keep send/recv. Recv still works
in unpaid grace.

**Dedicated GCP:** they pay Google for Run/SQL/GCS; they **still** pay you
M4 seats.

---

## 3. Out of M4

Changing M2 to “seats only” (forbidden). Per-message billing. Shop SKUs.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T22:45:00Z -->
