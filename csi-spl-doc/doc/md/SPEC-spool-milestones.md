# SPEC: Spool milestones

Status: binding product cut  
Related: `SPEC-spool-hub-rental.md`, `specs/002-box-agent-messaging/contracts/trust-modes.md`, `SPEC-spool-wui.md`

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
The hub **is** production-shaped: Cloud Run on **spool-hub.ai** (not a
private alias). There is **no buy button** yet.

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

Infra/DNS/docker/lde: **copy csi-rel + pas-psf**, not the shop —
`SPEC-spool-hub-api-infra.md` / `specs/007-spool-hub-api-infra/`.

Stateless **Cloud Run** (HTTPS + WebSocket) + **Postgres** + **GCS**. Nothing
durable on the container. `tenant_id` on every row and GCS prefix
`t/<tenant>/files/<sha256>` from day one. Product DNS
`https://<tenant>.spool-hub.ai` (`$SPOOL_HUB_URL` in binaries). One GCS
bucket. Cloud Run min instances **1** by default (cnf-overridable). Hub is
**optional**: unset `$SPOOL_HUB_URL` = local only. WS **last hello wins**.
Pins: hello + periodic `GET /v1/pins`.


### M1 constraints (owner 2026-09-18)

| Topic | M1 |
|---|---|
| DNS prd | `https://<tenant>.spool-hub.ai` |
| DNS dev | `https://<tenant>.dev.spool-hub.ai` |
| Ingress | **IAP and/or IP allowlist** until M2. Unknown internet cannot hold a WS. |
| Tenant create | **Owner-only** `do_spl_tenant_create`. **Several** manual tenants allowed
  (not a single internal one). Isolation is still `tenant_id`. |
| Second box | A **real second machine**: GCP VM **or** a grok-bot VM (try one of those). |
| Demo invocations | **CLI and MCP**: recorded demo includes **Claude or agy `spool mcp`** on at least one box; the other may be Grok CLI. |
| Public buy | M2. M1 has no checkout. |

M2 **removes** the IAP/IP allowlist so paying strangers can connect with box keys only.

### Out of M1

Buy-from-the-site (M2). Slack web UI (M3). NATS, ysg-box adapter, git-rel,
Kafka, per-agent hub keys.

### Demo (M1 acceptance) — then M2 may start

1. **Local:** GRK-03 → CLE-07 on one `$SPOOL_ROOT`, no `$SPOOL_HUB_URL`.
2. **Hub:** this box + a **second box** (GCP VM or grok-bot VM), **one of several**
   owner-created tenants, two box keys, pins synced, talking to **spool-hub.ai**
   (prd) or **dev.spool-hub.ai** (dev). Ingress IAP/IP allowlist.
3. One side **`spool mcp`** (Claude or agy); the other may be Grok CLI.
   `task` then `result` across boxes.
4. HUM-1 on box-a commands CLE@box-b. Missing pubkey → refuse (`78`).
5. **Infra from spec 007 is applied on both `dev` and `prd`.**
6. No browser, no checkout.

---

## Milestone 2 — public MVP

**Same mesh as M1**, plus a stranger can **buy the service on the site**.

- **The site** is a **thin checkout page only** (landing + pay). Not the M3
  Slack UI. Not a SKU inside csi-rel/pas-psf.
- **Payment: copy csi-rel** — `specs/006-spool-hub-rental/contracts/payment.md`.
- After pay: **success page and one email** contain the tenant URL and the
  **tenant root private key**. Shown **once**. Hub never stores that private
  key. Lost mail → support / new tenant (no dashboard re-issue in M2).
- Cancel / unpaid → grace, then `402` on send/pin; recv still works in grace.
- Buyers use CLI/MCP like M1. No Slack UI.

---

## Milestone 3 — rollout (Slack-like web)

Humans and agents chat on the **spool-hub.ai web interface**, Slack-like:
threads, command any agent, same `v:1` bus. `SPEC-spool-wui.md` /
`csi-spl-wui`.

**Hosting: the same setup as csi-rel and pas-psf** — static WUI (Firebase
Hosting path) + Cloud Run API. Copy that WUI infra, not the shop pages.
Authenticated renter (payment account / tenant), not GCP IAM per agent.
Not started until M1 is done (dev+prd infra) and M2 can sell.

---

## Order

**M1 proto** (local + spool-hub.ai, infra on **dev and prd**) →
**M2 public MVP** (thin checkout + one-time email of URL and root key) →
**M3 rollout** (Slack WUI, csi-rel/pas-psf hosting).

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:00:00Z -->
