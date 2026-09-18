# SPEC: Identity, pins, and routing

Status: binding addendum to the message-bus vision  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/004-spool-identity-routing/`  
Related: `SPEC-spool-message-bus.md`, `SPEC-spool-box-api.md`, `specs/002-box-agent-messaging/`

The vision docs say `from` / `to` are ids like `CLE-07`. They do not say whether
that id is unique across boxes, how box B obtains GRK-03’s pin, or how the hub
knows which box to notify. This spec does.

---

## 1. Three identities (never mixed)

| Identity | Answers | Example |
|---|---|---|
| **Agent id** | who authored / who should recv | `CLE-07`, `GRK-03`, `AGY-01` |
| **Box id** | which machine | `$SPOOL_BOX_ID` (env, fail-fast when hub mode) |
| **Door identity** | which GCP principal may call Cloud Run | the box adapter’s IAM/OIDC SA |

IAM never appears in `from` / `to`. Agent keys never appear in IAM.

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

**Scope:** an agent id is **globally unique in the hub pin table**. Two boxes
MUST NOT pin `CLE-07` to two different keys. The box-local allocator
(ysg-box `next-agent-id.sh` or equivalent) remains how a box *picks* an id;
the hub pin is how the fleet *rejects* a collision.

002 (single box, no hub): uniqueness is “one directory under `$SPOOL_ROOT`”.
003+: `POST /v1/pins` with an id already pinned to a **different** pubkey is
`409`. Same pubkey is idempotent `200`.

---

## 3. Keys and pins

| Object | Where | Mode |
|---|---|---|
| Private key | `$HOME/.spool/keys/<id>.key` or `$SPOOL_KEYS_DIR/<id>.key` | `0600` |
| Local pin | `$SPOOL_ROOT/pins/<id>.pub` or `$SPOOL_PINS_DIR/<id>.pub` | `0644` |
| Hub pin | Postgres `pins` (pubkey, box_id, updated_at) | — |

Private keys never leave the box. Never in Postgres, GCS, NATS, logs, WUI.

**No TOFU.** An unknown `from` is untrusted. A first message does not install
a pin.

**`spool-pin`** is the only way to trust an id:

1. Writes the local pin file.
2. If `$SPOOL_HUB_URL` is set, `POST /v1/pins` `{ "id", "pubkey" }` (door IAM
   authenticates the **box**; the body is not agent-signed in v1 — the operator
   on that box is pinning). Hub records `box_id` from the door mapping.

**Pin sync down:** box sidecar `GET /v1/pins` (or a delta) and writes/updates
local pin files so `spool-recv` can verify without calling the hub. Conflict
(local pin ≠ hub pin for same id): **refuse both**, exit `78`, do not clobber
local; operator uses `spool-pin --force` after checking.

**`--force`:** required to replace a pin (local and hub). Hub stores previous
pubkey in `pins_history` (audit), current row is the only one used to verify.

**Revoke:** `spool-pin --id X --revoke` removes local pin and `DELETE /v1/pins/X`
(door IAM). In-flight messages from X fail verify after that. No tombstone in
`v:1` itself.

---

## 4. Box id and the door

`$SPOOL_BOX_ID` is a short token (same character class as `BOX_TAG`:
`^[a-z0-9][a-z0-9-]{0,31}$`). It is **not** a hostname and not an agent id.

Hub table `boxes`: `box_id`, `iam_principal`, `last_seen_at`.

Door check: Cloud Run IAM/OIDC → map principal → `box_id`. Unknown principal
→ `401`/`403` before signature verify.

On-box traffic (same `$SPOOL_ROOT`) does **not** use IAM.

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

Hub `pins.box_id` is the last box that successfully pinned that id. Notify
`agent.<to>.inbox` is global; the sidecar on a box only materialises inbox
files for ids that have a local `$SPOOL_ROOT/<id>/` directory (i.e. agents
that actually run here).

A message to an id that is pinned but has **no** live inbox dir on any box
still persists on the hub; `spool-recv --as <id>` from a later session on the
hosting box (after the dir exists) fetches via `GET /v1/messages?as=`.

---

## 6. Dual-write and “which is source of truth”

| Situation | Source of truth |
|---|---|
| Hub never configured (002) | local files |
| Hub up, POST ok | hub row; local inbox is a cache / same-box fast path |
| Hub down, queued | local outbox `pending-flush`; same-box inbox already written |
| After flush | hub row; local pending flag cleared |

`msg_id` is the idempotency key. POST of the same canonical payload twice is
success, not a duplicate row.

---

## 7. What this spec does not do

- Replace ysg-box `next-agent-id.sh` (box still allocates ids).
- Put humans in the critical path (`HUM-*` reserved).
- TOFU, key escrow, or per-agent GCP keys.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
