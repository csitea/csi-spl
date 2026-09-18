# Data Model: Hub (003)

Local filesystem shapes stay exactly `002`. This file is **Postgres + GCS**
when the hub is up. The inner wire object is still `v:1`. The hub also stores
the box-signed **envelope** (`../002-box-agent-messaging/contracts/trust-modes.md` §5).

Tenant-native from M1 (`SPEC-spool-milestones.md`): every table carries
`tenant_id`. The tenant is resolved from the request Host. One GCS bucket,
keys `t/<tenant>/files/<sha256>`. The `tenants` table is owned by 006; pins and
boxes are owned by 004. Their shapes are repeated here only so that the hub
schema reads as one piece.

## 1. GCS

| Key | Value |
|---|---|
| `t/<tenant_id>/files/<sha256 hex>` | raw bytes, no metadata object; one bucket for all tenants |

Lifecycle: see `contracts/limits.md` (30-day retention).

## 2. Postgres

Every table includes `tenant_id`. The internal fleet is one tenant of the same
product. Its id is cnf, and no literal id is baked into migrations (0.1.0
named one; see OQ below).

### `tenants` (006)

| column | type | notes |
|---|---|---|
| `tenant_id` | text PK | `^[a-z0-9][a-z0-9-]{0,31}$` (006) |
| `root_pubkey` | bytea | raw 32-byte Ed25519 tenant root key; the private root is never stored |
| `billing_status` | text | `"active"`, `"grace"`, `"unpaid"`, `"internal"` |
| `plan_id` | text | quota & retention tier |
| `created_at` | timestamptz | |

### `boxes` (004)

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `box_id` | text | `$SPOOL_BOX_ID`, renter-chosen |
| `last_hello_at` | timestamptz | last verified WS hello |
| `iam_principal` | text NULL | **private deploy only** (OQ-06); NULL on the public product |

PK `(tenant_id, box_id)`.

### `pins` (004 / 006) — **box** pubkeys, not agent keys

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `box_id` | text | the pinned box |
| `pubkey` | bytea | raw 32-byte Ed25519 box public key |
| `updated_at` | timestamptz | |
| `revoked_at` | timestamptz NULL | set on revoke; verify ignores revoked |

PK `(tenant_id, box_id)`. Same `box_id` with a different key → 409 unless
`--force` (history row). Per-agent pins (`agent_id` → pubkey) are **gone**
in hub mode: agents have no hub key.

### `pins_history`

Append-only: `tenant_id`, `box_id`, `pubkey`, `at`, `reason` (`pin`|`force`|`revoke`).

### `roster`

Agent ids a box announced at hello (dir scan of `$SPOOL_ROOT/*/`).

| column | type | notes |
|---|---|---|
| `tenant_id` | text | |
| `box_id` | text | |
| `agent_id` | text | `CLE-07`; unique per box, **not** per tenant |
| `announced_at` | timestamptz | |

PK `(tenant_id, box_id, agent_id)`. Used to resolve `to_box` (FR-005). Whether
the roster is persisted or held only in memory for live sockets depends on
OQ-05; it is listed here because FR-005 must work across instances.

### `messages`

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `msg_id` | uuid | idempotency key **within** the tenant |
| `task_id` | uuid | thread index |
| `ts` | timestamptz | from the inner `v:1` |
| `from_box` | text | envelope; must equal the hello box |
| `from_id` | text | inner `from` (asserted by `from_box`) |
| `to_box` | text | envelope, resolved (FR-005) |
| `to_id` | text | inner `to` |
| `kind` | text | check constraint: task, result, note, reject |
| `body` | text | |
| `files` | jsonb | `v:1` `files[]` refs |
| `msg` | jsonb | full inner `v:1` object (no `sig`) |
| `env_sig` | text | base64 box signature over the canonical envelope |
| `received_at` | timestamptz | server ingest clock |

PK `(tenant_id, msg_id)`. The 0.1.0 draft had `msg_id` as a global PK. That
contradicts per-tenant isolation (two tenants may mint colliding ids through a
buggy client, and a global PK leaks existence across tenants). Re-ingesting an
identical canonical envelope is `ON CONFLICT DO NOTHING` and returns 200; a
different canonical returns 409 `conflict_msg` (FR-010).

### `deliveries` (hub queue)

One row per message per recipient box. Holds a message for an offline `to_box` (FR-006).

| column | type | notes |
|---|---|---|
| `tenant_id` | text | |
| `msg_id` | uuid | FK `messages` |
| `to_box` | text | |
| `state` | text | `queued` \| `sent` (\| `acked`, OQ-08) |
| `expires_at` | timestamptz | `received_at` + queue TTL from cnf (OQ-13) |
| `sent_at` | timestamptz NULL | frame pushed to the box socket |

PK `(tenant_id, msg_id, to_box)`.

### `acks`

Kept from 0.1.0; semantics open (OQ-08: whether the box reports agent `--ack`
to the hub at all).

| column | type | notes |
|---|---|---|
| `tenant_id` | text | |
| `box_id` | text | recipient box |
| `agent_id` | text | recipient `as` |
| `msg_id` | uuid | |
| `acked_at` | timestamptz | |

PK `(tenant_id, box_id, agent_id, msg_id)`. The 0.1.0 key omitted `box_id`,
which is ambiguous now that agent ids repeat across boxes.

## 3. What is not a table

- File bytes (GCS)
- Private keys: box, tenant root, and the no-longer-used agent keys
- Model tokens
- Ephemeral notify payloads
- WS session state (Cloud Run is stateless; a live-socket map, if any, is per instance)

## 4. Indexes (minimum)

- `messages (tenant_id, to_box, to_id, ts)`
- `messages (tenant_id, task_id, ts)`
- `messages (tenant_id, from_box, from_id, ts)`
- `deliveries (tenant_id, to_box, state, expires_at)`

The 0.1.0 index `messages (from_id, ts)` had no `tenant_id` and was dropped:
every query path is tenant-scoped.

## 5. Open

- Internal-fleet tenant id: 0.1.0 baked a literal default; the hygiene rules
  (Constitution II / VI) require it from cnf. The value is the owner's call.
- OQ-05, OQ-06, OQ-08 and OQ-13 in `spec.md` decide whether `roster`,
  `boxes.iam_principal`, `acks` and `deliveries.expires_at` stay as drafted.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:24:00+03:00 -->
