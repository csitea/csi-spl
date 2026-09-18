# SPEC: Spool milestones

Status: binding product cut  
Related: `SPEC-spool-hub-rental.md`, `SPEC-spool-trust-modes.md`, `SPEC-spool-wui.md`

---

## Milestone 1 — non-WUI mesh (first ship, **not** public)

**Goal:** Agents on **different boxes** message each other through the hub.
A **user** who holds a box **private** key can **command any agent** on any
box that holds the matching **public** key. No browser UI.

This is SSH `authorized_keys`, over the spool hub, with agent names in
`from`/`to`.

### In

| Piece | Done when |
|---|---|
| Local mail (002) | Unsigned `v:1` send/recv/ack/files/tail on one `$SPOOL_ROOT` |
| Tenant | Manual `do_spl_tenant_create` (payment webhook **not** required) |
| Box keys | One Ed25519 keypair per `$SPOOL_BOX_ID`; renter pins pubkey with tenant root |
| Cross-box mail | Box A → Box B `kind=task` / `note` / `result` over `wss://` |
| Command | Whoever has box-A’s **private** key can send `task` to any announced agent on a box that has box-A’s **public** key |
| Roster | `$SPOOL_ROOT/*/` dirs; `CLE-07` unique **per box**; `from_box`/`to_box` |
| Offline | Hub queues; send returns `delivery=queued` and **no receiver ack** |
| Same-box | Local by default; `$SPOOL_MIRROR_LOCAL=1` optional hub copy |
| Files | REST PUT with box key; GET by sha256 in tenant |
| CLI + MCP | Same verbs; official `go-sdk` stdio |


### Hub (M1 hosting)

The hub **is**:

- a **stateless Cloud Run** service — **HTTPS + WebSocket**
- **Postgres** (messages, pins, boxes, queue, acks)
- **GCS** (file bytes)

Not on the container disk: mail, files, WS session state. Instance kill is
normal; queued mail lives in Postgres until `to_box` reconnects (TTL cnf).

**Encapsulation for many renters from day one** (even if M1 demos one tenant):

- every Postgres row has `tenant_id`
- GCS keys are `t/<tenant>/files/<sha256>`
- tenant from **Host**: product DNS `https://<tenant>.spool-hub.ai`
  (cnf/env `$SPOOL_HUB_URL` in binaries — never a baked hostname)
- GCS: **one bucket**, keys `t/<tenant>/files/<sha256>`
- no “add tenant_id later” migration
- Cloud Run **min instances = 1** by default (keep a warm WS); **cnf-overridable**
  (including 0). The **box works with no hub at all** (`$SPOOL_HUB_URL` unset).
- WS: **last hello wins** — a new connection with the same `box_id` closes the old one
- Pins: refresh on WS hello **and** periodic `GET /v1/pins` (interval in cnf)

Tests may use sqlite. Production M1 is Cloud Run + Postgres + GCS. Public
service: no renter GCP IAM (`SPEC-spool-hub-rental.md`).

### Out (not M1)

- Entire **WUI** (Slack-like chat is Milestone 3)
- Payment provider / checkout (Milestone 2)
- NATS, ysg-box adapter, git-rel, Kafka, custom domains, per-agent hub keys

### Demo (M1 acceptance)

1. Two machines, one tenant, two box ids, two box keypairs.
2. Renter pins both pubkeys (root).
3. Each box syncs pins (has the other’s **public** key).
4. `GRK-03` on box-a sends `task` to `CLE-07` on box-b (`--to-box box-b`).
5. `CLE-07` recvs, replies `kind=result` to `GRK-03` on box-a.
6. A human on box-a (`HUM-1` dir + same box key) sends `task` to `CLE-07@box-b`.
7. No browser involved.

If step 6’s public key is **not** on box-b, the command is refused (`78` /
unpinned box). That is the whole authorisation model.

---

## Milestone 2 — public MVP

**This is the public product.** Strangers pay, get `https://<tenant>.spool-hub.ai`,
run the same M1 protocol (CLI/MCP, box keys, no WUI).

Checkout via the configured payment provider. Tenant create/resume/cancel
from the webhook. Quota / `402` unpaid.

**Payment implementation: copy csi-rel** — binding
`specs/006-spool-hub-rental/contracts/payment.md`. Drivers, fail-closed boot,
signed webhooks, Secret Manager from csi-rel (`payment_provider.go`,
`internal/payments/`, `internal/webhooks/`, specs `046` / `068` / `077` /
`000-secret-management`). Map “order paid” → tenant `billing_status=active`.
Fake-pay (077) is lde only.

Public DNS and Cloud Run are in front of paying tenants. Still **no WUI**
(that is M3).

---

## Milestone 3 — WUI (Slack-like)

Authenticated human chats and commands any agent in a thread UI. Same `v:1`
bus. `SPEC-spool-wui.md`. Not started until M1 is demoable.

---

## Order

`002 local` → hub WS + pins (M1, not public) → **public MVP (M2, pay + csi-rel payment)** → WUI (M3).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:15:00Z -->
