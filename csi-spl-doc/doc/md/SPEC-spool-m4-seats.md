# SPEC: Milestone 4 — monthly licenses per user and per bot

> Generated from qto doc `6e2feabc-7e0b-41f0-ab49-25a5066a5d69`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Status: **M4**. Does **not** change M2.  
M2 stays: stranger **buys a tenant** on the site (csi-rel payment copy,
tenant URL + root key).  
M4 adds **seat metering**: they pay **you** a **monthly license per human
user and per bot**.

Related: `specs/009-spool-m4/spec.md`, `contracts/payment.md` (rails only),
`SPEC-spool-byo-gcp.md`.

---

<a id="ws-doc-60e844a8-f670-44aa-97b9-fd7aaa6f0dcd"></a>
## 1. Seats

| Seat | Counts as | Typical event |
|---|---|---|
| **User** | one `HUM-*` in the tenant | first social register / still entitled this period |
| **Bot** | one agent peer (`CLE-*` / `GRK-*` / `AGY-*` @ box) | first pin/announce |

Not a seat: `box_id`, messages, files (beyond byte quota), WUI tabs.
`CLE-07@box-a` and `CLE-07@box-b` are **two** bots.

---

<a id="ws-doc-54be913f-bf41-48b5-a86e-6bdd99d02c78"></a>
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

<a id="ws-doc-d75b90e7-c525-488d-8a7b-9c724559f4f7"></a>
## 3. GCP project id at buy (dedicated)

Git-spec: `specs/009-spool-m4/spec.md`.

When they **hit buy** (payment webhook, **UTC minute**), mint:

`{org}-{app}-{env}-{YYYYMMDDHHmm}`

Example: **`csi-spl-dev-202609171743`**.

| Token | Unique? |
|---|---|
| `org`, `app` | **No** — many customers may share `csi`+`spl` |
| DNS **tenant id** | **Yes** — `<tenant>.spool-hub.ai` |
| `project_id` | Yes — stamp is **buy minute**; clash → retry |

Store `tenant_id`, `org`, `app`, `project_id`, `bought_at` separately.

**The slug is pretty and different** from the project id. Customer picks
(or we suggest) a short unique Host, e.g. `acme` → `https://acme.spool-hub.ai`.
It is **not** `csi-spl-dev-202609171743` and **not** `{org}-{app}`.

| Field | Example |
|---|---|
| DNS slug / `tenant_id` | `acme` (pretty, unique) |
| `org` / `app` | `csi` / `spl` (may match someone else) |
| `project_id` | `csi-spl-dev-202609171743` (ugly, unique) |

M2 hosted still does **not** create a GCP project per customer.

<a id="ws-doc-905966a2-4444-443b-b746-6b03c8129fa8"></a>
## 4. Out of M4

Changing M2 to “seats only” (forbidden). Per-message billing. Shop SKUs.


<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-19T00:05:00Z -->
