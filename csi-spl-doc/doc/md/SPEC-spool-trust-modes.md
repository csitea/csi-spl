# SPEC: Trust modes (local unsigned vs hub box keys)

Status: binding — owner decisions 2026-09-18  
Related: `SPEC-spool-hub-rental.md`, `SPEC-spool-identity-routing.md`, `specs/002`, `specs/006`

This replaces “sign on day one everywhere.” Crypto exists **only when a hub
is configured**. Local mail matches today’s msgs dirs. Hub mail is **SSH-like
over HTTPS WebSocket** through `spool-hub.ai` (host from cnf).

---

## 1. Two modes

| | Local (`$SPOOL_HUB_URL` unset) | Hub (`$SPOOL_HUB_URL` set) |
|---|---|---|
| Trust | POSIX on `$SPOOL_ROOT` (same box, same OS users) | Ed25519 **box** keypair; commandee has commander’s **box public key** |
| `sig` on `v:1` | **omitted** | **required**, signed by the **sending box**, not by CLE/GRK/AGY |
| `from` / `to` | agent ids (`CLE-07`) | same agent ids |
| Transport | files on disk | **WebSocket** send/recv; **REST** files + pins |
| Hub can read body | n/a | **yes** (plaintext JSON; sign only, no encrypt) |

Like SSH: the commander holds a **private** key; the commandee holds that
peer’s **public** key (`authorized_keys`). The hub is the jump host
(WebSocket), not a second identity.

---

## 2. Local mode (002)

- Write `v:1` JSON **without** `sig` and without `box_id`.
- No `spool-keygen` required. Keys may exist for later hub use; they are
  unused while the hub URL is unset.
- Recv trusts the filesystem. Malformed files still surface (002).
- Same-box peer mesh: any agent id that has an inbox dir.

This is deliberate: a single laptop must work like ysg-box msgs, with no
key ceremony.

---

## 3. Hub mode — key per box, names per agent

**One Ed25519 keypair per box** (`$SPOOL_BOX_ID`). All agents on that box
share it. `from`/`to` remain agent ids so Claude vs Grok vs agy are still
addressable.

| Object | Who | Role |
|---|---|---|
| Box private key | that box only (`$HOME/.spool/keys/box-<id>.key`, `0600`) | signs WS hello + every send envelope |
| Box public key | commandee boxes + hub pin table | verify commander (SSH `authorized_keys`) |
| Tenant root key | renter | only key that may **pin/revoke box pubkeys** |
| Agent id | process on a box | `from` / `to` only; **no agent keypair in hub mode** |

Pin uniqueness is **per tenant, per `box_id`**. Two tenants may reuse box
ids. Agent id `CLE-07` should be bound to at most one box in a tenant
(announce on WS; collision → 409).

**Full mesh:** a box that is pinned may command any agent on any other
pinned box. No per-kind ACL. Unpin the box to cut it off.

**Mailbox only:** WS delivers the `task`. Spool does not start the LLM.

---

## 4. Hub wire

### REST (unchanged job)

- `POST /v1/files`, `GET /v1/files/{id}`
- `POST /v1/pins` / `DELETE` — **tenant-root signature**, body is
  `{ "box_id", "pubkey", ... }` (pins **boxes**, not `CLE-07`)
- `GET /v1/pins` — list box pubkeys for the receiving box to install as
  authorized_keys (sync into `$SPOOL_ROOT/pins/box-<id>.pub`)

### WebSocket (send / recv)

`wss://<tenant-host>/v1/ws`

1. **Hello:** `{ "box_id", "ts", "sig" }` signed with the box key. Hub
   verifies against tenant pins. Unknown box → close.
2. **Announce agents:** `{ "agents": ["CLE-07", "GRK-03"] }` so the hub can
   route `to=CLE-07` to this connection.
3. **Send:** inner `v:1` (no inner sig) + envelope `{ "box_id", "sig" }`
   over canonical inner JSON. Hub checks box pin, stores plaintext, forwards
   to the commandee box’s WS if connected, else queues.
4. **Recv / ack:** frames on the same WS for agents announced on that box.
   Proving the box key at hello is enough to drain those agents’ inboxes
   (the box is the SSH server). No per-agent recv signature.

Receiving box **must** have the sender box’s pubkey (synced pins). If missing,
it refuses the frame locally even if the hub already stored it (`78`).

---

## 5. Envelope (hub only)

Local file = inner object:

```json
{
  "v": 1,
  "msg_id": "...",
  "task_id": "...",
  "ts": "...",
  "from": "GRK-03",
  "to": "CLE-07",
  "kind": "task",
  "body": "...",
  "files": []
}
```

Hub envelope:

```json
{
  "box_id": "devbox-1",
  "msg": { "...inner v:1..." },
  "sig": "<base64 ed25519 of jq -cS .msg>"
}
```

`sig` is the **box** key. Inner object has no `sig`.

---

## 6. What this is not

- Not encrypt-to-recipient (hub **can** read bodies; WUI can show threads).
- Not a keypair per `CLE-07` on the hub (that was the old 002-on-hub story).
- Not REST for send/recv on the public product (REST remains files/pins).
- Not TOFU: box pubkey must be root-pinned before hello succeeds.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:00:00Z -->
