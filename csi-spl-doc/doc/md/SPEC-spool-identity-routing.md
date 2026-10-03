# SPEC: Identity, pins, and routing

Status: binding addendum to the message-bus vision  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/004-spool-identity-routing/`  
Related: `specs/002-box-agent-messaging/contracts/trust-modes.md`, `SPEC-spool-hub-rental.md`, `specs/002-box-agent-messaging/`

Hub crypto is **per box**, not per agent — `specs/002-box-agent-messaging/contracts/trust-modes.md`.
`from`/`to` remain `c-004`. The box key signs. Local mode has **no** keys.

---

## 1. Three identities (never mixed)

| Identity | Answers | Example |
|---|---|---|
| **Tenant id** | which paid hub namespace | `$SPOOL_HUB_URL` / Host |
| **Tenant root** | who may pin/revoke **box** pubkeys | Ed25519; private key held by the renter |
| **Box keypair** | SSH-like commander/commandee | one Ed25519 per `$SPOOL_BOX_ID` (hub mode only) |
| **Agent id** | who authored / who should recv | `c-004` — a name, **not** a hub key |
| **Box id** | which machine | `$SPOOL_BOX_ID` required in hub mode |
| **Door (private deploy only)** | GCP principal for an org Cloud Run | not used for public rental |

GCP IAM never appears in `from` / `to`. Agent keys never appear in IAM.
Public rental: no renter IAM at all — see `SPEC-spool-hub-rental.md`.

Display names, tmux titles, and OS users are **not** identities.

---

## 2. Agent ids

Agent ids follow the grammar in [spec 061 section 0](../../specs/061-agent-id-rename/spec.md#0-the-marker-the-old-form-ends-2026-10-03):
`^[acgq]-[0-9]{3}$` (lower case letter followed by 3 digits `004`..`999`).
Legacy agent ids (`^(CLE|AGY|GRK|QWN)-[0-9]+$`) end at `2026-10-03T20:59:59Z`.
Roles `001`..`003` are reserved seats (`c-001` orchestrator, `c-002` master dispatcher, `c-003` failover dispatcher; `a-001`, `g-001`, `q-001` never handed out).

Reserved prefixes / letters:

| Prefix / Letter | Kind |
|---|---|
| `c-` (legacy `CLE-`) | Claude Code |
| `g-` (legacy `GRK-`) | Grok |
| `a-` (legacy `AGY-`) | Antigravity |
| `q-` (legacy `QWN-`) | Qwen Code |
| `HUM-` | human operator (viewer / rare sender; not required in 002) |
| `BOX-` | forbidden as an agent prefix (box id lives in env, not in `from`) |

A new vendor adds a letter. Same API.

**Scope of agent ids:** unique **on one box** (one directory
`$SPOOL_ROOT/c-004`). Two boxes MAY both have `c-004`. Fleet addressing is
`c-NNN@<box>` (spec 058 / spec 061 §3.3); hub addressing is
`(box_id, agent_id)` — see `specs/002-box-agent-messaging/contracts/trust-modes.md` envelope `from_box` /
`to_box`.

**Scope of box pins:** unique `(tenant, box_id)`. Second pin of that box_id
with a **different** pubkey → **409**. Same pubkey → 200.

002 (no hub): uniqueness is only the local directory. Allocator
(`next-agent-id.sh` or the renter’s numbering) picks ids **per box**.

**Sub-agents (Hierarchy):** Subagents (e.g. child subagents spawned by Antigravity
or Claude Code) MUST NOT inherit the parent ID and MUST NOT use dotted sub-IDs
(`a-004.1` is rejected by the schema regex). Each subagent is an independent,
first-class peer on the bus allocated its own distinct top-level ID (e.g. `a-005`,
`a-006`) via the box allocator, equipped with its own inbox/outbox directory
(`$SPOOL_ROOT/<id>/{inbox,outbox,archive}`). Keypairs and pins are per-box,
shared by all agents on that box.

**Agent Bootstrapping (Harness Lifecycle):**
Two in-repo scripts, both in `csi-spl-orc/src/bash/features/spawn-agents/scripts/`:

- **`next-agent-id.sh`** (the spawner) **allocates** the agent id, per box.
- **`spool-harness.sh`** (the standard box launcher, `specs/012-spool-box-api/`,
  `c619d5d`) takes that id with `--as`, **validates it but never allocates**,
  prepares `$SPOOL_ROOT/<id>/{inbox,outbox,archive}`, checks the box key
  (`$HOME/.spool/keys/box-<box_id>.key`; required in hub mode, else exit 78),
  starts or waits for one `spool hub-run` sidecar and its roster entry, then
  `exec`s the AI CLI. Contract: `specs/012-spool-box-api/contracts/spool-harness.md`.

The harness is a launcher script, not a `spool` subcommand. The AI CLI is never
burdened with key generation or initial pin setup.

---

## 3. Keys and pins

| Object | Where | Mode |
|---|---|---|
| Box private key (hub) | `$HOME/.spool/keys/box-<box_id>.key` | `0600` |
| Box pin file (hub) | `$SPOOL_ROOT/pins/box-<box_id>.pub` | `0644` |
| Hub pin | Postgres `pins` (`box_id`, pubkey, tenant) | — |
| Agent private keys | unused in hub mode; unused in local mode | — |

Private keys never leave the box. Never in Postgres, GCS, NATS, logs, WUI.

**No TOFU.** An unknown `from` is untrusted. A first message does not install
a pin.

**`spool pin`** (or `spool hub-pin` for the hub side only) is the only way to trust a box:

1. Writes the local pin file (`$SPOOL_ROOT/pins/box-<box_id>.pub`).
2. If `$SPOOL_HUB_URL` is set, `POST /v1/pins` is **signed by the tenant root**
   (`SPEC-spool-hub-rental.md`). The signed payload is `{box_id, force, pubkey, ts}`. An agent or a box cannot pin itself.

**Pin sync down:** box sidecar `GET /v1/pins` and writes/updates
local pin files so receiving boxes can verify without calling the hub per message. Conflict
(local pin ≠ hub pin for same `box_id`): **refuse both**, exit `78`, do not clobber
local; operator uses `spool pin --force` after checking.

**`--force`:** required to replace a pin with a different key, and to re-pin a
revoked box (local and hub). A same-key re-pin is a no-op. `pins_history` records
the key that became active (audit); only the active row verifies. Every state
change must carry a signed `ts` later than the last one, else 409
`stale_pin_op` (replay guard). Full state machine:
`specs/004-spool-identity-routing/contracts/pin-semantics.md` (binding).

**Revoke:** `spool pin --box <box_id> --revoke` removes local pin and calls
`DELETE /v1/pins/{box_id}` (tenant-root signature). In-flight messages from that box fail verify after that.

---

## 4. Box id (optional) vs tenant door

`$SPOOL_BOX_ID` is optional metadata (`^[a-z0-9][a-z0-9-]{0,31}$`). It is not
a hostname, not an agent id, and **not** a credential.

**Public rental door:** tenant URL + Ed25519: the box key on the WS hello and on every send
envelope (trust-modes §4–5), and the tenant root key on pin / revoke. See `006/contracts/http-rental.md`.

**Private org deploy (optional):** Cloud Run IAM in front of the same API.
Not the product for paying renters.

On-box traffic (same `$SPOOL_ROOT`) does not use IAM or the hub.

---

## 5. Where a message goes (routing)

`to` is **unicast**: exactly one agent id. No `cc`, no box-wide fanout in v1.

### Same box

`spool-send` **always** writes:

- sender `outbox/`
- recipient `inbox/` if `$SPOOL_ROOT/<to>/` exists

This is 002. It stays true when the hub is configured.

### Hub configured (`$SPOOL_HUB_URL` set)

After the local write, the CLI also:

1. `POST /v1/files` for any not-yet-uploaded `file_id`s (using WS-issued upload token)
2. Sends the message envelope over WebSocket `/v1/ws` (`send` frame) signed by the sending box key.

If send fails (hub down): local files remain; outbox entry is `pending-flush` (see flush
contract in `internal/hubclient/flush.go`). Recv on the **same** box still works from `inbox/`.

If send succeeds: hub persists into Postgres; delivers `recv` frame over WebSocket to the
destination box's live session socket (`role=box`). The destination box sidecar dual-writes the
message into its local `$SPOOL_ROOT/<to>/inbox/`. Live task activity streams over WebSocket via
`tail` frames.

### Who hosts `to`?

Hub routes by **`to_box`**. Box hello/announce frames map `(box_id, agent_id)` → active WebSocket.
A sidecar only materialises inbox files for ids that exist **on this box**.

If `to_box` is offline when a message arrives, the hub queues the envelope in Postgres (up to
`queue_max_per_box`, TTL 7 days). When `to_box` reconnects with `role=box` hello, all queued `recv`
frames are delivered automatically followed by a `queue_end` frame.

---

## 6. Dual-write and “which is source of truth”

| Situation | Source of truth |
|---|---|
| Hub never configured (002) | local files |
| Same-box, default (no mirror) | local files only; hub never sees it |
| Same-box + `$SPOOL_MIRROR_LOCAL=1` | local + hub (WUI / other boxes) |
| Cross-box, hub up | hub row; commandee box inbox via WS |
| Hub down, hub send required | local outbox `pending-flush`; same-box inbox already written if local |
| After flush | hub row; pending cleared |

`msg_id` is the idempotency key. A repeated hub send of the same payload is
success, not a duplicate row.

Same-box skip vs mirror: `specs/002-box-agent-messaging/contracts/trust-modes.md` §6.

---

## 7. What this spec does not do

- Replace ysg-box `next-agent-id.sh` (box still allocates ids).
- Put humans in the critical path (`HUM-*` reserved).
- TOFU, key escrow, per-agent GCP keys, or renter GCP accounts.
- Cross-tenant uniqueness of agent ids.

<!-- version: 0.4.0 · updated: 2026-09-19 · last-edit: 2026-09-18T22:55:25Z -->
