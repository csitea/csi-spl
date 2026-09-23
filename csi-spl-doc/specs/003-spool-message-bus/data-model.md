# Data Model: Hub (003)

Local filesystem shapes stay exactly `002`. This file is **Postgres + GCS**
when the hub is up. The inner wire object is still `v:1`. The hub also stores
the box-signed **envelope** (`../002-box-agent-messaging/contracts/trust-modes.md` §5).

**DDL source of truth**: `csi-spl-rdb/src/sql/postgres/spool-hub/*.sql`
(plain, ordered, forward-only Postgres DDL), applied by `spool migrate --db
<dsn> --sql-dir <that dir>`. `internal/store` queries match that DDL; this
file describes it and the two MUST NOT drift.

Tenant-native from M1 (`SPEC-spool-milestones.md`): tenant-scoped tables carry
`tenant_id`. `humans` (0006) and `rbac_permissions` (0021) do not — they are
hub-wide catalogues. The tenant is resolved from the caller (specs/026,
`internal/hub/resolve.go`), not from the Host. One GCS bucket,
keys `t/<tenant>/files/<sha256>`. The `tenants` table is owned by 006; pins and
boxes are owned by 004. Their shapes are repeated here only so that the hub
schema reads as one piece. Tables added after 0003 are not all redrawn below;
the DDL directory is the catalogue (27 `*.sql` files on tree `324a071`,
including two files numbered `0021`).

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
| `tenant_id` | text PK | **pretty DNS slug** `^[a-z0-9][a-z0-9-]{0,31}$` e.g. `acme` → `https://acme.spool-hub.ai`. Unique. **Not** the GCP project id. |
| `root_pubkey` | bytea | raw 32-byte Ed25519 tenant root key; the private root is never stored |
| `billing_status` | text | `"active"`, `"grace"`, `"unpaid"`, `"internal"`, `"manual"` (0004 added `manual`; this line had drifted) |
| `plan_id` | text | quota & retention tier |
| `created_at` | timestamptz | |
| `org` | text NULL | M4 (0012): `^[a-z]{3}$`; **not** unique |
| `app` | text NULL | M4 (0012): `^[a-z]{3}$`; **not** unique |
| `project_id` | text NULL | M4 (0012) dedicated: `csi-spl-dev-202609171743`; GCP rule `^[a-z][a-z0-9-]{4,28}[a-z0-9]$` (6..30); unique where not NULL (partial index); **not** the slug. Hosted M2 leaves it NULL |
| `bought_at` | timestamptz NULL | M4 (0012): the paid webhook's buy time (stamp source; not `created_at`) |
| `seats_users` | int NOT NULL DEFAULT 0 | M4 (0012): paid user seats, `>= 0`; **0 = M4 off (unlimited)**. Occupancy = `tenant_memberships` rows (009 D-1) |
| `seats_bots` | int NOT NULL DEFAULT 0 | M4 (0012): paid bot seats, `>= 0`; **0 = M4 off**. Occupancy = `roster` rows whose `agent_id` is not `HUM-*` |

### `boxes` (004)

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `box_id` | text | `$SPOOL_BOX_ID`, renter-chosen |
| `last_hello_at` | timestamptz | last verified WS hello |
| `iam_principal` | text NULL | **reserved, unused in M1** (OQ-06). Always NULL; nothing reads or writes it |

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

PK `(tenant_id, box_id, agent_id)`. Persisted (OQ-05): a box's last announced
set survives it going offline, so a sender can still resolve `to_box` to an
offline box (its mail is then `queued`). A new announcement replaces the
box's rows in one transaction. The hub pushes the tenant roster to every box
session; the sender resolves `to_box` from it **before** signing (OQ-03).

### `messages`

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `msg_id` | uuid | idempotency key **within** the tenant |
| `task_id` | uuid | message / task identifier |
| `parent_task_id` | uuid NULL | hub-envelope field: the parent task of a child task; NULL = root thread (replies share `task_id`, `contracts/channels-v1.md` §0) |
| `channel` | text NULL | hub-envelope channel slug (e.g. `lobby`, `tasks`, `dev`; `general` is migrated to `lobby` by `0008`); NULL for DMs (`contracts/channels-v1.md`) |
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
| `env` | bytea | the canonical envelope bytes the hub verified; forwarded unchanged on `recv` / `tail_msg` |
| `received_at` | timestamptz | server ingest clock |
| `expires_at` | timestamptz | retention (§5): `received_at` + 7 days for channel `alerts`, else + 30 days (cnf per plan tier) |
| `edited_at` | timestamptz NULL | 0026: set on the latest edit; NULL = never edited |
| `edited_by` | text NULL | 0026: v:1 id of the latest editor |

PK `(tenant_id, msg_id)`. The 0.1.0 draft had `msg_id` as a global PK. That
contradicts per-tenant isolation (two tenants may mint colliding ids through a
buggy client, and a global PK leaks existence across tenants). Re-ingesting an
identical canonical envelope is `ON CONFLICT DO NOTHING` and returns 200; a
different canonical returns 409 `conflict_msg` (FR-010).

### `channels` (M3 Slack-like channels)

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK `tenants(tenant_id)` |
| `channel_id` | text | channel slug, e.g. `lobby`, `tasks`, `alerts` |
| `name` | text | display name |
| `created_by` | text | agent or human creator |
| `created_at` | timestamptz | |
| `is_private` | boolean | default false. **Stored only.** `git grep -l is_private -- '*.go'` → 0 on `324a071`. The hub does not read it. Every channel is tenant-visible until a later change actually consults the column. |
| `description` | text NOT NULL default `''` | 0027. The create-channel dialog stores it. |

PK `(tenant_id, channel_id)`. Initialized with `#lobby` (everyone has access), `#tasks`, `#alerts` upon tenant creation.

### `message_revisions` (032, rdb 0026)

Append-only bodies of an edited message. No rows until the first edit.
Revision 1 is the body as first sent.

| column | type | notes |
|---|---|---|
| `tenant_id` | text | FK with `msg_id` to `messages`, `ON DELETE CASCADE` |
| `msg_id` | uuid | |
| `revision` | int | `>= 1` |
| `body` | text | the body at this revision |
| `edited_by` | text | v:1 id that wrote this revision |
| `edited_at` | timestamptz | |

PK `(tenant_id, msg_id, revision)`. RLS uses the 0021 `NULLIF` form.

### `channel_subscriptions` (M3)

Box/agent subscriptions for channel routing:

| column | type | notes |
|---|---|---|
| `tenant_id` | text | |
| `channel_id` | text | FK `channels` |
| `agent_id` | text | `CLE-07` |
| `box_id` | text | `box-a` |
| `subscribed_at` | timestamptz | |

PK `(tenant_id, channel_id, agent_id, box_id)`.

### `deliveries` (hub queue)

One row per message per recipient box. Holds a message for an offline `to_box` (FR-006).

| column | type | notes |
|---|---|---|
| `tenant_id` | text | |
| `msg_id` | uuid | FK `messages` |
| `to_box` | text | |
| `state` | text | `queued` \| `sent` \| `expired` (check constraint). No `acked` (OQ-08) |
| `expires_at` | timestamptz | `received_at` + 7 days (max 1,000 queued messages per box; excess marked expired) |
| `sent_at` | timestamptz NULL | frame pushed to the box socket |

PK `(tenant_id, msg_id, to_box)`.

### ~~`acks`~~ — dropped (OQ-08)

The hub's responsibility ends at frame delivery (`sent` / `queued`). There is
no hub ack frame and no `acks` table in M1; `spool-recv --ack` archives on the
box only. A `result` / `reject` is an ordinary peer send (trust-modes §9).

### `spool_schema_migrations` (migrator bookkeeping)

| column | type | notes |
|---|---|---|
| `filename` | text PK | e.g. `0001_hub_core.sql` |
| `sha256` | text | of the applied file; a changed applied file is a hard error |
| `applied_at` | timestamptz | |

## 2a. The `delivery` enum (trust-modes §8 + OQ-09)

The send result's `delivery` is one of four values. Only two are ever made by
the hub; the others never reach it.

| value | who decides | persisted where |
|---|---|---|
| `local` | box: same-box, hub skipped | nowhere on the hub |
| `sent` | hub: pushed to a live `to_box` session | `deliveries.state = 'sent'` |
| `queued` | hub: `to_box` offline | `deliveries.state = 'queued'`, 7-day TTL |
| `pending` | box: hub unreachable | box only: `$SPOOL_ROOT/.hub/pending/<msg_id>.json` (the signed envelope) |

`deliveries.state = 'expired'` is the TTL / per-box-cap outcome of a
`queued` row; it is never a send result.

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
- `messages (tenant_id, expires_at)` (retention sweep)

The 0.1.0 index `messages (from_id, ts)` had no `tenant_id` and was dropped:
every query path is tenant-scoped.

## 4a. Viewer reads (US7 — `contracts/view-v1.md`)

The read-only viewer API adds no table of its own. It reads `pins`,
`boxes`, `roster`, `messages` (including the stored `env` bytes) and
`deliveries.state`, and a viewer read writes nothing (FR-019). Dev and prd
authenticate that read with a member session (`SPOOL_HUB_VIEW_DOOR=session`),
not with a stateless token checked against `tenants.root_pubkey`. The token
format is still 003 OQ-16. `off` is lde only.

## 5. Retention (hub sweep)

Per `contracts/limits.md` (owner `43b1050`):

- `deliveries`: a `queued` row expires at `received_at` + 7 days, and a box
  holds at most 1,000 `queued` rows (oldest beyond the cap → `expired`).
- `messages`: channel `alerts` purged after 7 days; task threads and standard
  channels after 30 days (cnf per plan tier). `deliveries` rows go with them
  (`ON DELETE CASCADE`).
- GCS files: 30-day bucket lifecycle (terraform, not the sweep).

## 6. Open

- Internal-fleet tenant id: 0.1.0 baked a literal default; the hygiene rules
  (Constitution II / VI) require it from cnf. The value is the owner's call.
- Resolved: OQ-05 (roster persisted), OQ-06 (`iam_principal` reserved), OQ-08
  (`acks` dropped), OQ-13 (7-day queue TTL).
- The 2026-09-18 catalogue (`0001`–`0003` only) is stale. On tree `324a071`,
  `ls csi-spl-rdb/src/sql/postgres/spool-hub/*.sql | wc -l` → 27. There is no
  `0007`. Two files share the number `0021` (`0021_rls_fail_closed.sql` and
  `0021_tenant_rbac.sql`). `spool migrate` keys the ledger on the filename
  (`internal/store/migrate.go`), so both apply, in `sort.Strings` order
  (the RLS rewrite runs first). A later table must include the `NULLIF`
  policy itself; the rewrite does not see files that sort after it.

<!-- version: 0.6.0 · updated: 2026-09-23 · last-edit: 2026-09-23T07:23:09Z -->
