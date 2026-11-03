# Netvisor finance store: hub tables readable by the owner human only

Spec 125 row B4 ([spec](../../specs/125-netvisor-integration/spec.md) sections
5.2 and 7, case C-NVS-4), issue SPL-4721. Schema and store only: the hub
routes are B5, the WUI screen B7, the main-box sync B6.

## 1. Tables (rdb `0255_netvisor_finance.sql`)

| table | one row per | holds |
|---|---|---|
| `netvisor_settings` | workspace | `owner_human_id` (the ONE human who reads the data, C7), `env` (`test` or `prd`), the bank, VAT and tax bookkeeping account numbers, the spec-123 vendor exclusion list |
| `netvisor_snapshots` | fetch | `owner_human_id`, `env`, `as_of`, `month_end`, `newest_bank_voucher_date`, `fetched_at` |
| `netvisor_forecast_items` | month-end term | category, sign, amount (`numeric(18,2)`), currency, due date, overdue, approved, label |
| `netvisor_card_cost_lines` | card cost line | month, route, vendor, account number and name, dimension and item, amount, VAT code, excluded |

Items and lines carry their snapshot's `owner_human_id` under a composite FK,
so a row can never be filed under another human than its snapshot. A
workspace delete cascades all four tables.

The owner's human id is data in `netvisor_settings`, never a code literal.
No figure, account number or id is in git; tests use invented values.

## 2. Who reads what (RLS)

All four tables have `FORCE ROW LEVEL SECURITY`, the usual `tenant_scope`,
and a RESTRICTIVE `owner_scope`:

- A data row passes only when its `owner_human_id` equals the
  transaction-local `app.human_id` AND that human is the workspace's owner
  in `netvisor_settings` now.
- No `operator_scope` policy: the operator scope, the ops psql and
  `pg_dump` under it read 0 rows. The Reporting SQL tab refuses the tables
  (`forbidden_relation`), as it refuses every table with a per-human policy.
- `app.rls_scope = 'netvisor_ingest'` reaches `netvisor_settings` alone.

| caller (scope) | settings | snapshots, items, lines |
|---|---|---|
| owner human (`inNetvisorOwner`) | read, update | read, write |
| another human, an admin, an agent (`inNetvisorOwner` with its id) | 0 rows | 0 rows, insert refused |
| the tenant alone (`inTenant`) | 0 rows | 0 rows |
| operator (`asOperator`) | 0 rows | 0 rows |
| operator ingest (`inNetvisorIngest`) | read, set owner | 0 rows |
| the owner's id in another workspace | 0 rows | 0 rows |

When the operator moves the owner, the old owner reads nothing and the new
owner does not read the old owner's snapshots.

## 3. Store API (`internal/store/netvisor.go`)

`store.Netvisor`, implemented by `*Postgres`; the hub reaches it by type
assertion.

| method | scope | errors |
|---|---|---|
| `NetvisorSetOwner(tenant, human, by)` | ingest | `ErrNoHuman`, `ErrNotFound` (no workspace) |
| `NetvisorSettings(tenant, human)` | owner | `ErrNotFound` unless human is the owner |
| `NetvisorPutSettings(tenant, human, s)` | owner; never moves the owner | `ErrNotFound`, `ErrBadNetvisor` |
| `NetvisorIngest(tenant, snap)` | ingest, then the owner's | `ErrNetvisorNoOwner`, `ErrNetvisorEnv`, `ErrBadNetvisor` |
| `NetvisorLatest(tenant, human, env)` | owner | `ErrNotFound` |

The `human` argument must be the id of an authenticated human session
(`HUM-<digits>`; anything else is `ErrNoHuman`). The hub never passes an
act-as clone, an agent, a box, or a value from a path, query, header or body
(B5). `app.human_id` is set in `netvisor_postgres.go` alone
(`TestNetvisorHumanScopeCallers`).

## 4. Tests

In `csi-spl-api/src/go/spool-hub-api/internal/store`, on Postgres
(`PRE_PUSH_TIER=full ./run -a do_check_pre_push`, `hub-pg.tst.sh`):

- `TestNetvisorStoreRLS`: the owner reads its snapshot. The tenant alone,
  another human, an empty human, the operator, the ingest scope (data
  tables) and the owner's id in another workspace read 0 rows.
- `TestNetvisorStoreRLSControl`: with `owner_scope` dropped, another human
  and the tenant alone read the owner's rows.
- `TestNetvisorStoreWrites`: only the owner writes. Another human cannot
  file a snapshot even under its own id (42501). An owner move hides the old
  snapshots.
- `TestRLSCoversEveryTenantTable`, `TestRLSPoliciesFailClosed` and
  `TestCrossTenantEveryTable` cover the four tables;
  `TestSQLExecutorRefusesRelations` covers the Reporting SQL refusal.
