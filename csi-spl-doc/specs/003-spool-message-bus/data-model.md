# Data Model: Hub (003)

Local filesystem shapes stay exactly `002`. This file is **Postgres + GCS**
when the hub is up. Wire JSON is still `v:1`.

Rental (006): every mail table includes `tenant_id` (PK prefix or compound
key). GCS keys are `t/<tenant>/files/<sha256>`. Add a `tenants` table
(id, root_pubkey, billing_status, quotas) — specified in 006.

## 1. GCS

| Key | Value |
|---|---|
| `files/<sha256 hex>` | raw bytes, no metadata object |

No other prefixes. Lifecycle: see `contracts/limits.md` (mail files live
longer than git-rel’s 1-day probe objects; do not reuse the 001 bucket).

## 2. Postgres

### `boxes`

| column | type | notes |
|---|---|---|
| `box_id` | text PK | `$SPOOL_BOX_ID` |
| `iam_principal` | text UNIQUE | Cloud Run door |
| `last_seen_at` | timestamptz | last authenticated call |

### `pins`

| column | type | notes |
|---|---|---|
| `agent_id` | text PK | `CLE-07` |
| `pubkey` | bytea | raw 32-byte Ed25519 |
| `box_id` | text | last pin publisher |
| `updated_at` | timestamptz | |
| `revoked_at` | timestamptz NULL | set on revoke; verify ignores revoked |

### `pins_history`

Append-only: `agent_id`, `pubkey`, `box_id`, `at`, `reason`
(`pin`\|`force`\|`revoke`).

### `messages`

| column | type | notes |
|---|---|---|
| `msg_id` | uuid PK | idempotency key |
| `task_id` | uuid | index |
| `ts` | timestamptz | from the JSON, not server now |
| `from_id` | text | |
| `to_id` | text | unicast |
| `kind` | text | check constraint enum |
| `body` | text | |
| `files` | jsonb | `v:1` `files[]` |
| `sig` | text | base64 |
| `canonical` | jsonb | full `v:1` object as stored |
| `received_at` | timestamptz | server clock |

Unique `(msg_id)`. Insert of identical `canonical` is `ON CONFLICT DO NOTHING`
and returns 200. Insert of same `msg_id` with **different** canonical → 409.

### `acks`

| column | type | notes |
|---|---|---|
| `agent_id` | text | the `as` of recv |
| `msg_id` | uuid | |
| `acked_at` | timestamptz | |

PK `(agent_id, msg_id)`. Mirrors 002 archive: a row means that agent already
acked. `GET /v1/messages?as=&ack=true` inserts here.

## 3. What is not a table

- File bytes (GCS)
- Private keys
- Model tokens
- NATS payloads (ephemeral or JetStream copy of `canonical` minus nothing
  except still no file bytes)

## 4. Indexes (minimum)

- `messages (to_id, ts)`
- `messages (task_id, ts)`
- `messages (from_id, ts)`

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
