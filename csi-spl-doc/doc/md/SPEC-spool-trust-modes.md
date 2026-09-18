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
| `from` / `to` | agent ids unique **on this box** | agent ids + **`from_box` / `to_box`** (two boxes may both have `CLE-07`) |
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

Pin uniqueness is **per tenant, per `box_id`**. A second pin of the same
`box_id` with a **different key** → HTTP **409**. Same key → 200.

Agent ids (`CLE-07`) are unique **on one box only**. Two boxes in the same
tenant MAY both announce `CLE-07`. They are different peers:
`CLE-07@box-a` vs `CLE-07@box-b`. The hub MUST NOT 409 that.

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
   verifies against tenant pins. Unknown box → close. **Last hello wins:**
   a second connection for the same `box_id` closes the first.
   After hello, the box **GET /v1/pins** and then on a **cnf interval**
   (authorized_keys refresh).
2. **Announce agents:** the box **scans `$SPOOL_ROOT/*/`** (directory names
   matching the agent-id regex). That roster is sent on hello and when the
   set changes. Duplicate id **on this box** → 409. Same id on another box
   is fine. No separate register command.
3. **Send:** inner `v:1` (no inner sig) + envelope
   `{ "from_box", "to_box", "sig" }` over canonical inner JSON.
   `from_box` is this box. `to_box` required if `msg.to` exists on more than
   one box; omitted + unique → hub fills; omitted + ambiguous → **409**.
   If `to_box` has a live WS: push and return `delivery=sent` (box got the
   frame — not agent `--ack`). If not: **store on the hub** (TTL in cnf),
   return `delivery=queued` and tell the commander **no ack from the
   receiver**. Send is still success (exit 0) with that status.
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
  "from_box": "box-a",
  "to_box": "box-b",
  "msg": { "from": "GRK-03", "to": "CLE-07", "...inner v:1..." },
  "sig": "<base64 ed25519 of jq -cS '{from_box,to_box,msg}' without sig>"
}
```

`sig` is the **sending box** key. Inner `from`/`to` are agent names on those
boxes. Dual-write: also write `$SPOOL_ROOT/<to>/inbox/` when `to_box` is this
box (or unset in local mode).

---

## 6. Dual-write

Same-box = `to` has an inbox on **this** box and `to_box` is this box or omitted
(unambiguous local target).

`spool-send` with `$SPOOL_HUB_URL` set:

1. Always write local outbox.
2. If same-box: write local inbox. Delivery does **not** wait on the hub.
3. Hub envelope (WS send):
   - **Cross-box:** always.
   - **Same-box (default):** **skip** the hub. Local files are enough.
   - **Same-box + mirror:** also send to the hub so other boxes / a later WUI
     see the thread.

`$SPOOL_MIRROR_LOCAL` (optional, default unset = false):
- unset / `0` / `false` — skip hub for same-box (default).
- `1` / `true` — also hub-send same-box messages.
- any other value — fail-fast.

If a hub send is required (cross-box, or same-box with mirror) and the hub is
down: local 1–2 still succeed; envelope is pending-flush. Mirror-off same-box
never queues a flush.

Local-only (`$SPOOL_HUB_URL` unset): steps 1–2 only. Flag is ignored.

## 7. What this is not

- Not encrypt-to-recipient (hub **can** read bodies; WUI can show threads).
- Not a keypair per `CLE-07` on the hub (that was the old 002-on-hub story).
- Not REST for send/recv on the public product (REST remains files/pins).
- Not TOFU: box pubkey must be root-pinned before hello succeeds.
- Not a tenant-wide unique `CLE-07`. Names collide across boxes on purpose.
- Not WUI in MVP (`SPEC-spool-wui.md` is post-MVP Slack-like chat).

## 8. Offline commandee and send status

Hub queue TTL is cnf (not infinite). After TTL the message expires; commander
is not retroactively failed.

CLI/MCP send result MUST include `delivery`:

| value | meaning |
|---|---|
| `local` | same-box, hub skipped (default dual-write) |
| `sent` | hub pushed to a live `to_box` WS |
| `queued` | hub stored; **no receiver ack** (box offline or WS down) |

`queued` is not a hard error. The commander is informed. Agent-level ack is
still a later `spool-recv --ack` / `kind=result` send — not this field.

## 9. Results are ordinary sends

`kind=result` / `reject` is another peer `spool-send` to `GRK-03` (or whoever).
The hub does **not** auto-route back to the original `from`.

## 10. Box id

Renter chooses `$SPOOL_BOX_ID`. Duplicate `box_id` + **different** pubkey →
**409**. Same pubkey → 200. `--force` pin to replace a key (audit history).

## 11. Files (REST)

- `POST /v1/files` — **box key** (same proof as WS hello: signed headers or a
  short-lived upload token from the WS). Anonymous PUT forbidden.
- `GET /v1/files/{file_id}` — **capability**: knowing `file_id` (sha256) inside
  the tenant is enough. No cross-tenant.


<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:45:00Z -->
