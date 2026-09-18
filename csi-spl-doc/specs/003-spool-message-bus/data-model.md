# Data Model: Hub (003)

Local filesystem shapes stay exactly `002`. This file is **Postgres + GCS**
when the hub is up. Wire JSON is still `v:1`.

Rental (006): every mail table includes `tenant_id` (PK prefix or compound
key). GCS keys are `t/<tenant>/files/<sha256>`. Add a `tenants` table
(id, root_pubkey, billing_status, quotas) — specified in 006.

## 1. GCS

| Key | Value |
|---|---|
| `t/<tenant_id>/files/<sha256 hex>` | raw bytes, no metadata object (partitioned per tenant) |

Lifecycle: see `contracts/limits.md` (30-day retention).

## 2. Postgres (Tenant-Native from Day 1)

Every table includes `tenant_id` (default internal fleet tenant: `"csitea-internal"`). This ensures zero breaking migrations when public rental (006) activates.

### `tenants`

| column | type | notes |
|---|---|---|
| `tenant_id` | text PK | e.g. `"csitea-internal"`, or rental slug |
| `root_pubkey` | bytea | raw 32-byte Ed25519 tenant root key |
| `billing_status` | text | `"active"`, `"grace"`, `"unpaid"`, `"internal"` |
| `plan_id` | text | quota & retention tier |
| `created_at` | timestamptz | |

### `boxes`

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `box_id` | text | `$SPOOL_BOX_ID` |
| `iam_principal` | text UNIQUE | Cloud Run door identity |
| `last_seen_at` | timestamptz | last authenticated call |

PK `(tenant_id, box_id)`.

### `pins`

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `agent_id` | text | `CLE-07`, `GRK-03`, `AGY-01` |
| `pubkey` | bytea | raw 32-byte Ed25519 |
| `box_id` | text | last pin publisher |
| `updated_at` | timestamptz | |
| `revoked_at` | timestamptz NULL | set on revoke; verify ignores revoked |

PK `(tenant_id, agent_id)`. Agent IDs are unique within a tenant.

### `pins_history`

Append-only: `tenant_id`, `agent_id`, `pubkey`, `box_id`, `at`, `reason` (`pin`|`force`|`revoke`).

### `messages`

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `msg_id` | uuid PK | global idempotency key |
| `task_id` | uuid | thread index |
| `ts` | timestamptz | from message JSON |
| `from_id` | text | author agent id |
| `to_id` | text | recipient agent id |
| `kind` | text | check constraint: task, result, note, reject |
| `body` | text | |
| `files` | jsonb | `v:1` `files[]` |
| `sig` | text | base64 |
| `canonical` | jsonb | full `v:1` object |
| `received_at` | timestamptz | server ingest clock |

Unique `(tenant_id, msg_id)`. Insert of identical `canonical` is `ON CONFLICT DO NOTHING` and returns 200.

### `acks`

| column | type | notes |
|---|---|---|
| `tenant_id` | text | |
| `agent_id` | text | recipient `as` |
| `msg_id` | uuid | |
| `acked_at` | timestamptz | |

PK `(tenant_id, agent_id, msg_id)`.

## 3. What is not a table

- File bytes (GCS)
- Agent private keys
- Model tokens
- Ephemeral SSE / NATS payloads

## 4. Indexes (minimum)

- `messages (tenant_id, to_id, ts)`
- `messages (tenant_id, task_id, ts)`
- `messages (tenant_id, from_id, ts)`
- `messages (from_id, ts)`

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
