# 098 Generic workspace settings: one `tenants.settings` jsonb column

Status: **v1.0, built.** Owner's go: t1 `29b19f85` msg `1ec24f32`.
Migration: rdb `0136_tenant_settings_jsonb.sql`. Code:
`csi-spl-api/src/go/spool-hub-api/internal/store/tenant_kv.go` and
`internal/hub/tenant_settings.go`. Author: c-398.

## 0. Why

The owner (msg `eefc2b3a`): "could it be done more genertically for this table
to not require DDL changes for EACH type of settings additions / changes".
Then (msg `1ec24f32`): "let's add this generic col , which if heavily used will
evoke DDL changes as a strategy". And (msg `505e7698`): "ensure the
performance does not degrade in complex json operations".

## 1. The workspace table today

`tenants` (one row per workspace) has grown one column per setting:

| group | columns | rdb |
|---|---|---|
| identity | `tenant_id`, `root_pubkey`, `created_at` | 0001 |
| billing | `billing_status`, `plan_id`, `org`, `app`, `project_id`, `bought_at`, `seats_users`, `seats_bots` | 0001, 0012 |
| lifecycle | `suspended_at`, `archived_at`, `is_operator` | 0115, 0116 |
| display | `display_name`, `sort_order`, `default_locale` | 0041, 0051, 0074 |
| settings | `responders`, `topic_archive_policy`, `agent_split_{claude,grok,agy,qwen}`, `fleet_load_low`, `fleet_load_high`, `fleet_box_order`, `calendar_region`, `marketing_enabled`, `fleet_box_bands` | 0067 .. 0134 |
| generic | `settings` (this spec) | 0136 |

Each settings row above cost a migration, a dev and prd apply ordered before
the hub roll, and a column-tolerance probe or a deploy-order note.

## 2. The column

```sql
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb
        CONSTRAINT tenants_settings_object CHECK (jsonb_typeof(settings) = 'object');
```

- Catalog-only on pg 11+ (constant default): no table rewrite.
- The database holds only the keys an admin set. An absent key reads as its
  default, so a new key needs no backfill.
- Identity, billing and lifecycle stay real columns. They are filtered,
  joined and checked by constraints, which a json key cannot do well.

## 3. Key registry (the hub owns every key)

`store.RegisterTenantSetting(TenantSettingDef{...})`, called from the
feature's package `init`:

| field | meaning |
|---|---|
| `Key` | dotted lower-case words, at most 64 chars, e.g. `chat.max_pins` |
| `Kind` | `SettingBool`, `SettingInt` or `SettingString` |
| `Default` | the value in force when the key is not stored; must pass its own check |
| `Min`, `Max` | int range, inclusive |
| `MaxLen`, `OneOf` | string limit (default 200 runes, one line) and allowed values |

A bad key, a duplicate or a default its own check refuses panics at start-up,
so every test fails before the code ships.

**Adding a setting now:** one `RegisterTenantSetting` call and the code that
reads it. No migration, no prd apply and no deploy ordering.

## 4. Read and write path

| step | how |
|---|---|
| read, request path | `GetTenant` (hot cache) -> `Tenant.Settings.Bool/Int/String(key)`. The object is decoded once per cache fill, never per message. |
| read, settings page | `GET /v1/tenant/settings` -> `"settings": {key: value in force}` for every registered key |
| write | `PATCH /v1/tenant/settings {"settings": {"key": value, "other": null}}`; `null` resets a key to its default |
| validation | every key must be registered and every value must pass its check, before ANY field of the PATCH is written; else `400 bad_setting` naming the key and rule |
| SQL | `UPDATE tenants SET settings = (settings \|\| $set) - $unset::text[] WHERE tenant_id = $1 RETURNING settings`: one statement on the locked row, no read-modify-write, so two admins setting two keys at once both land (`TestTenantKVConcurrentKeys`, 16 writers) |
| cache | the write drops the hot cache (`hot.forget`), as every tenant-row write does |
| stale keys | a stored key that is no longer registered, or whose value fails a tightened check, is skipped on read and its default applies |
| permission | `tenant.settings`, like the rest of the PATCH |

**Missing column:** the store probes `pg_attribute` for `tenants.settings`
(like the 0115 probe). Until 0136 is applied, reads answer the defaults and a
write answers `503 settings_unavailable`, never a 500
(`TestTenantKVColumnMissing`).

## 5. RLS and roles

- RLS is unchanged. `tenants` already has ENABLE + FORCE and the fail-closed
  policies (0021). A column needs no policy of its own.
  `TestTenantKVCrossTenant` checks that, under tenant A's scope, B's
  `settings` can be neither read nor updated.
- The owner role (`spool_hub`) migrates. The runtime role (`spool_hub_rt`)
  writes the column through its table-level DML grant
  (`spool-hub-roles/runtime-grants.sql`). `spool_public_names` keeps its
  two-column grant and cannot read `settings`.

## 6. Performance

- No jsonb path operator (`->`, `->>`, `@>`, `jsonb_path_*`) runs in SQL on any
  path. The hub reads the whole object and decodes it in Go once per cache
  fill.
- **No index.** Nothing filters on a key. A GIN index is added only when a
  query needs one, and such a query is itself the promotion trigger (section 7).
- Benchmark `internal/store/tenant_kv_bench_test.go`, results in section 8.

## 7. Promotion rule (owner, msg `1ec24f32`)

A key moves out of `settings` into a real column, by a normal migration, when
ANY of these holds:

1. A SQL query filters, joins, sorts or groups on it (`WHERE settings->>...`):
   a column can be indexed and constrained.
2. It is read on a request path WITHOUT the cached tenant row, i.e. it needs its
   own SQL read more than once per request burst.
3. It is read across workspaces (operator listings, reports).
4. Its value is a list or object larger than 1 KB, or it is written more than
   once a minute per workspace (a counter or state, not a setting).
5. The object grows past 64 keys or 4 KB. The decode cost grows with the
   object, and it is paid once per hub instance every 5 s per workspace (the
   hot cache TTL) plus after each write. Measure it with
   `BenchmarkTenantKVDecode`.

Promotion steps: add the column (migration), copy the value
(`UPDATE tenants SET col = (settings->>'key')::type`), switch the reader, then
remove the key from the registry. The stale key is ignored on read until a
later cleanup strips it (`settings - 'key'`).

## 8. Measured

Postgres 16 (docker `postgres:16-alpine`, non-superuser owner role, so RLS
binds), Go 1.25.14, `-benchtime=2000x -count=5` (n = 5 x 2000 ops per row), on
a box at load average 60..80 on 16 cores. Absolute numbers are inflated by that
load, so compare the rows with each other. The row holds 16 stored keys, more
than any workspace has today. Median of the 5 runs:

| benchmark | ns/op | B/op | allocs/op |
|---|---|---|---|
| read, one column (today: `marketing_enabled`) | 472,973 | 1,250 | 38 |
| read, `settings` + decode | 550,690 | 6,506 | 109 |
| read, whole tenant row incl. settings, uncached | 726,268 | 7,986 | 128 |
| **read, tenant row from the hot cache (the request path)** | **486** | **32** | **1** |
| write, one column (today: `SetMarketingEnabled`) | 3,094,042 | 930 | 32 |
| write, one settings key (`\|\|` merge + RETURNING + decode) | 4,172,810 | 7,098 | 119 |
| decode alone, 16 keys | 102,874 | 4,985 | 70 |

Reading it:

- The request path reads the cached row: under 1 us, one allocation, no
  decode and no SQL. That is the same as today, since settings ride the row
  that is already cached.
- A cold read of `settings` is within the noise of a one-column read (one
  round trip each). The decode adds about 5 KB and 70 allocations, paid at
  most once per workspace every 5 s per instance.
- A one-key write is about 1.3x a one-column write. It is an admin action,
  measured in writes per day.
- A first cut decoded each key with its own `json.Decoder` (43 KB, 169
  allocs, 2.5x slower). The single-pass decode above replaced it before
  landing.

## 9. Not moved in this lane (a later, separate migration)

These existing setting columns stay columns until a dedicated lane moves them,
each by the section 7 test (several already fail it and should stay):
`responders`, `topic_archive_policy` (read by the archive hot path on the
cached row; may stay a column), `agent_split_claude/grok/agy/qwen`,
`fleet_load_low`, `fleet_load_high`, `fleet_box_order`, `calendar_region`,
`marketing_enabled`, `fleet_box_bands` (rdb 0134, c-393's lane).

The move per key: register the key with the column's default, copy
`UPDATE tenants SET settings = settings || jsonb_build_object('key', col)
WHERE col IS DISTINCT FROM <default>`, switch readers and writers, and drop the
column in a later migration once no deployed image reads it.

## 10. Registered keys

None yet. The first feature that needs a workspace setting registers it here
and in code. The tests register `test.*` / `hubtest.*` keys in their own
binaries only.
