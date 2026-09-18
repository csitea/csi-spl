# SPEC: Spool milestones

Status: binding product cut  
Related: `SPEC-spool-hub-rental.md`, `SPEC-spool-trust-modes.md`, `SPEC-spool-wui.md`

| Id | Name | One line |
|---|---|---|
| **M1** | **Technical MVP / proto** | Proof we can message **locally** and **via spool-hub.ai**. No shop, no Slack UI. |
| **M2** | **Public MVP** | Same protocol as M1, and a stranger can **buy the service on the site**. |
| **M3** | **Rollout** | Slack-like **web** UI on spool-hub.ai: humans and agents chat/command through the hub. |

---

## Milestone 1 — technical MVP (proto)

**Proof:** (1) two agents on **one box** exchange `v:1` with no hub. (2) two
agents on **two boxes** exchange via `https://<tenant>.spool-hub.ai` (CLI/MCP).
A holder of a box **private** key can command any agent on a box that holds
that **public** key.

No browser. No payment. Tenant is created by hand (`do_spl_tenant_create`).

### In

| Piece | Done when |
|---|---|
| Local mail (002) | Unsigned `v:1` send/recv/ack/files/tail on one `$SPOOL_ROOT` |
| Hub mail | Box A → Box B over `wss://` to spool-hub.ai (manual tenant) |
| Box keys | One Ed25519 keypair per `$SPOOL_BOX_ID`; renter pins pubkey with tenant root |
| Command | Commandee box has commander’s **public** key, or the send is refused |
| Roster | `$SPOOL_ROOT/*/` dirs; `CLE-07` unique **per box**; `from_box`/`to_box` |
| Offline | Hub queues; `delivery=queued` and **no receiver ack** |
| Same-box | Local by default; `$SPOOL_MIRROR_LOCAL=1` optional hub copy |
| Files | REST PUT with box key; GET by sha256 in tenant |
| CLI + MCP | Same verbs; official `go-sdk` stdio |

### Hub (M1 hosting)

Stateless **Cloud Run** (HTTPS + WebSocket) + **Postgres** + **GCS**. Nothing
durable on the container. `tenant_id` on every row and GCS prefix
`t/<tenant>/files/<sha256>` from day one. Product DNS
`https://<tenant>.spool-hub.ai` (`$SPOOL_HUB_URL` in binaries). One GCS
bucket. Cloud Run min instances **1** by default (cnf-overridable). Hub is
**optional**: unset `$SPOOL_HUB_URL` = local only. WS **last hello wins**.
Pins: hello + periodic `GET /v1/pins`.

### Out of M1

Buy-from-the-site (M2). Slack web UI (M3). NATS, ysg-box adapter, git-rel,
Kafka, per-agent hub keys.

### Demo (M1 acceptance)

1. **Local:** GRK-03 → CLE-07 on one `$SPOOL_ROOT`, no `$SPOOL_HUB_URL`.
2. **Hub:** two machines, one manual tenant, two box keys, pins synced.
3. GRK on box-a `task` to CLE on box-b; CLE `result` back.
4. HUM-1 on box-a commands CLE@box-b. Missing pubkey → refuse (`78`).
5. No browser, no checkout.

---

## Milestone 2 — public MVP

**Same mesh as M1**, plus a stranger can **buy the service on the site**.

- Checkout on the public site (not the agent CLI).
- Paid → tenant URL `https://<tenant>.spool-hub.ai` + tenant root key.
- Cancel / unpaid → grace, then `402` on send/pin; recv still works in grace.
- **Payment: copy csi-rel** — `specs/006-spool-hub-rental/contracts/payment.md`.
  Do not invent a second stack. Map “order paid” → `billing_status=active`.
- Still **no Slack UI** (that is M3). Buyers use CLI/MCP like M1.

---

## Milestone 3 — rollout (Slack-like web)

Humans and agents chat on the **spool-hub.ai web interface**, Slack-like:
threads, command any agent, same `v:1` bus. `SPEC-spool-wui.md` /
`csi-spl-wui`. Authenticated renter (payment account / tenant), not GCP IAM
per agent. Not started until M1 is proven and M2 can sell.

---

## Order

**M1 proto** (local + hub proof) → **M2 public MVP** (buy on the site) →
**M3 rollout** (Slack web UI).

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:30:00Z -->
