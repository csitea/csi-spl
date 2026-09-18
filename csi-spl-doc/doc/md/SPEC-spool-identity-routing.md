# SPEC: Identity, pins, and routing

Status: binding addendum to the message-bus vision  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/004-spool-identity-routing/`  
Related: `SPEC-spool-trust-modes.md`, `SPEC-spool-hub-rental.md`, `specs/002-box-agent-messaging/`

Hub crypto is **per box**, not per agent — `SPEC-spool-trust-modes.md`.
`from`/`to` remain `CLE-07`. The box key signs. Local mode has **no** keys.

---

## 1. Three identities (never mixed)

| Identity | Answers | Example |
|---|---|---|
| **Tenant id** | which paid hub namespace | `$SPOOL_HUB_URL` / Host |
| **Tenant root** | who may pin/revoke **box** pubkeys | Ed25519; private key held by the renter |
| **Box keypair** | SSH-like commander/commandee | one Ed25519 per `$SPOOL_BOX_ID` (hub mode only) |
| **Agent id** | who authored / who should recv | `CLE-07` — a name, **not** a hub key |
| **Box id** | which machine | `$SPOOL_BOX_ID` required in hub mode |
| **Door (private deploy only)** | GCP principal for an org Cloud Run | not used for public rental |

GCP IAM never appears in `from` / `to`. Agent keys never appear in IAM.
Public rental: no renter IAM at all — see `SPEC-spool-hub-rental.md`.

Display names, tmux titles, and OS users are **not** identities.

---

## 2. Agent ids

Regex (unchanged): `^[A-Z]{2,4}-[0-9]+$`.

Reserved prefixes:

| Prefix | Kind |
|---|---|
| `CLE` | Claude Code |
| `GRK` | Grok |
| `AGY` | Antigravity |
| `HUM` | human operator (viewer / rare sender; not required in 002) |
| `BOX` | forbidden as an agent prefix (box id lives in env, not in `from`) |

A new vendor adds a prefix. Same API.

**Scope of agent ids:** unique **on one box** (one directory
`$SPOOL_ROOT/CLE-07`). Two boxes MAY both have `CLE-07`. Hub addressing is
`(box_id, agent_id)` — see `SPEC-spool-trust-modes.md` envelope `from_box` /
`to_box`.

**Scope of box pins:** unique `(tenant, box_id)`. Second pin of that box_id
with a **different** pubkey → **409**. Same pubkey → 200.

002 (no hub): uniqueness is only the local directory. Allocator
(`next-agent-id.sh` or the renter’s numbering) picks ids **per box**.

**Sub-agents (Hierarchy):** Subagents (e.g. child subagents spawned by Antigravity
or Claude Code) MUST NOT inherit the parent ID and MUST NOT use dotted sub-IDs
(`AGY-01.1` is rejected by the schema regex). Each subagent is an independent,
first-class peer on the bus allocated its own distinct top-level ID (e.g. `AGY-02`,
`AGY-03`) via the box allocator, equipped with its own keypair, pin, and inbox/outbox.

**Agent Bootstrapping (Harness Lifecycle):**
The box harness wrapper (`next-agent-id.sh` / tmux agent launcher) generates the
keypair (`spool-keygen --as <id>`) and registers the pin (`spool-pin --id <id>`)
before the AI CLI session begins. If hub pin registration returns 409 (collision),
the harness allocator increments to the next available ID before starting the session.
The AI CLI is never burdened with key generation or initial pin setup.

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

**`spool-pin`** is the only way to trust an id:

1. Writes the local pin file.
2. If `$SPOOL_HUB_URL` is set, `POST /v1/pins` is **signed by the tenant root**
   (`SPEC-spool-hub-rental.md`). An agent cannot pin itself. Optional `box_id`
   is recorded if `$SPOOL_BOX_ID` is set (hint for notify, not a credential).

**Pin sync down:** box sidecar `GET /v1/pins` (or a delta) and writes/updates
local pin files so `spool-recv` can verify without calling the hub. Conflict
(local pin ≠ hub pin for same id): **refuse both**, exit `78`, do not clobber
local; operator uses `spool-pin --force` after checking.

**`--force`:** required to replace a pin (local and hub). Hub stores previous
pubkey in `pins_history` (audit), current row is the only one used to verify.

**Revoke:** `spool-pin --id X --revoke` removes local pin and `DELETE /v1/pins/X`
(tenant-root signature). In-flight messages from X fail verify after that.

---

## 4. Box id (optional) vs tenant door

`$SPOOL_BOX_ID` is optional metadata (`^[a-z0-9][a-z0-9-]{0,31}$`). It is not
a hostname, not an agent id, and **not** a credential.

**Public rental door:** tenant URL + Ed25519 (message `sig` or signed recv /
root-signed pin). See `006/contracts/http-rental.md`.

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

1. `POST /v1/files` for any not-yet-uploaded `file_id`s
2. `POST /v1/messages` with the already-signed `v:1` object (**do not re-sign**)

If POST fails: local files remain; outbox entry is `pending-flush` (see flush
contract). Recv on the **same** box still works from `inbox/`.

If POST succeeds: hub persists; NATS notify `task.<task_id>` and
`agent.<to>.inbox`. Other boxes’ sidecars write the message into **their**
`$SPOOL_ROOT/<to>/inbox/` if they host that id, else ignore the agent subject
and still may show it on `spool-tail --task` via hub GET.

### Who hosts `to`?

Hub routes by **`to_box`**. Announce maps `(box_id, agent_id)` → WS.
A sidecar only materialises inbox files for ids that exist **on this box**.

A message to an id that is pinned but has **no** live inbox dir on any box
still persists on the hub; `spool-recv --as <id>` fetches via signed
`POST /v1/recv`.

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

Same-box skip vs mirror: `SPEC-spool-trust-modes.md` §6.

---

## 7. What this spec does not do

- Replace ysg-box `next-agent-id.sh` (box still allocates ids).
- Put humans in the critical path (`HUM-*` reserved).
- TOFU, key escrow, per-agent GCP keys, or renter GCP accounts.
- Cross-tenant uniqueness of agent ids.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:15:00Z -->
