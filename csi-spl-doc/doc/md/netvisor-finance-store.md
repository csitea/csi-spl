# Netvisor finance store: hub tables readable by the owner human only

Spec 125 rows B4 and B5 ([spec](../../specs/125-netvisor-integration/spec.md)
sections 5.2 and 7, cases C-NVS-4 and C-NVS-5), issues SPL-4721 (schema and
store) and SPL-4732 (hub routes, section 5). The WUI screen is B7
(SPL-4741, section 6), the main-box sync B6.

## 1. Tables (rdb `0255_netvisor_finance.sql`)

| table | one row per | holds |
|---|---|---|
| `netvisor_settings` | workspace | `owner_human_id` (the ONE human who reads the data, C7), `env` (`test` or `prd`), the bank, VAT and tax bookkeeping account numbers, the spec-123 vendor exclusion list, `refresh_requested_at` (the open "Refresh now", rdb `0257`) |
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
| `NetvisorRequestRefresh(tenant, human)` | owner; an open request keeps its first time | `ErrNotFound` unless human is the owner |
| `NetvisorRefreshRequested(tenant)` | ingest | `ErrNetvisorNoOwner` |

`NetvisorIngest` clears an open refresh request when the snapshot's
`fetched_at` is at or after it (rdb `0257`).

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
- `TestNetvisorStoreRefresh`: only the owner opens a refresh; a second press
  keeps the first time; an older fetch leaves it open, a newer one clears it.
- `TestRLSCoversEveryTenantTable`, `TestRLSPoliciesFailClosed` and
  `TestCrossTenantEveryTable` cover the four tables;
  `TestSQLExecutorRefusesRelations` covers the Reporting SQL refusal.

## 5. Hub routes (B5, `internal/hub/netvisor.go`)

Bodies: `internal/wire/netvisor.go`; operations: `internal/hub/openapi.json`
(tag `netvisor`, and `operator`). No MCP tool, no `spool` CLI read and no
spool message carries a figure (C8).

### 5.1 The owner's routes

| route | answer |
|---|---|
| `GET /v1/view/netvisor/forecast` | `{env, snapshot, items, refresh_requested_at}`: the newest snapshot of the settings' env; `snapshot` is null before the first fetch |
| `GET /v1/view/netvisor/card-costs` | `{env, snapshot, lines, refresh_requested_at}` |
| `POST /v1/netvisor/refresh` | `202 {refresh_requested_at}`: "Refresh now"; a second press keeps the first time |
| `GET /v1/netvisor/settings` | the settings |
| `PUT /v1/netvisor/settings` | `{env, bank_account, vat_accounts, tax_accounts, vendor_exclusions}` replaced; the owner is never written here |

One door (`netvisorOwner`) for all five:

| caller | status |
|---|---|
| the workspace's Netvisor owner, own browser session | 2xx |
| any request with an `Authorization` header: a box or agent desk token, a CLI token, the operator service account | `403 person_only` |
| an act-as clone (of the owner too), an agent seat (`realmRefuses`) | `403 person_only` |
| every other member, admins included | `403 forbidden` (`netvisor.owner`) |
| a member of another workspace, the owner signed in to another workspace | `404 not_found` |
| no session | `401` |

The owner check is the session's human id against the `owner_human_id`
the store answers to that same human: data, never a code literal or a role.
Behind the door the store reads as that human, so rdb `0255`'s RLS is a
second wall: with the door widened to `Has(rbac.Admin)` (the red control)
another admin gets `200` but `snapshot: null`, no row.

### 5.2 The operator's routes (the main-box sync, B6)

The env's operator service account (`operatorAuth`, a Bearer id token), in
the operator workspace only; a request whose Host or `X-Spool-Tenant` names
another workspace is `403 operator_workspace_only`.

| route | answer |
|---|---|
| `PUT /v1/operator/netvisor/owner` | `{human_id}` names the owner; `409 not_member` unless a person seated in the operator workspace |
| `POST /v1/operator/netvisor/snapshots` | one snapshot (dates `YYYY-MM-DD`, amounts decimal text); `200 {snapshot_id, env, items, card_lines}`, counts only; `409 no_owner`, `409 env_mismatch`, `400 bad_snapshot` |
| `GET /v1/operator/netvisor/refresh` | `{refresh_requested_at}`, null when none is open (the B6 poller) |

Logs carry the workspace, ids, counts and outcomes, never an amount, an
account number or a label.

### 5.3 Tests

In `internal/hub`, on Postgres (real browser sessions: fake IdP, cookies,
act-as):

- `TestNetvisorHubRBAC`: the owner gets 2xx on all five routes and reads
  the figures; another admin, an act-as clone of the owner, an agent seat,
  the operator service account, a box (agent desk) token and the owner's
  cookie plus a box token get `403` and no figure; no session `401`.
- `TestNetvisorCrossTenant`: an admin of another workspace and the owner
  signed in to another workspace get `404`; the operator routes refuse
  another workspace (`403`).
- `TestNetvisorOperatorIngest`: operator auth (`401`, `403`), counts-only
  answer, the `400` and `409` refusals, the refresh request from the press to
  the snapshot that clears it.
- `TestNetvisorSnapshotIn` (any store): the wire dates.

## 6. The owner's screen (B7, Reporting -> Finance)

Spec 125 row B7, case C-NVS-7, issue SPL-4741. The WUI reads the routes of
section 5.1 from the owner's own browser session; it holds no figure of its
own and sends no Authorization header (the hub would answer `403
person_only`).

| piece | file |
|---|---|
| the tab, `/reporting/finance`, its own chunk | `csi-spl-wui/src/pages/reporting/finance.vue` |
| the settings form | `csi-spl-wui/src/components/reporting/finance/FinanceSettings.vue` |
| the hub calls, the mock, the sums | `csi-spl-wui/src/utils/reporting-finance.mjs` |
| the tab rule (`netvisorOwner`) | `csi-spl-wui/src/utils/reporting-tabs.mjs` |
| the strings | `reporting.tab.finance`, `reporting.finance.*` in the 19 `csi-spl-wui/i18n/locales/*.json` |

### 6.1 Who sees the tab

The tab has no role rule. The Reporting bar sends `GET /v1/netvisor/settings`
once per page load, and only when the reader is an admin of the operator
workspace (the operator console shows; every other workspace answers
`404`). The tab is drawn when that read answered 2xx. Any refusal or failure
hides it. Hiding is not the control: the page opened by its path reads the
settings first, and on the hub's `403` (`401`, `404`) it shows the refusal
line and sends no figure read.

An owner who is not an admin of the operator workspace gets no tab, but
`/reporting/finance` still works for them.

### 6.2 What the screen shows

- **Head**: the Netvisor company (`env`), the newest bank voucher date
  badge, the snapshot's `as_of` and fetch time, **Refresh now** (`POST
  /v1/netvisor/refresh`) and the open request's time.
- **Month-end cash forecast**: the signed sum of the items per currency, a
  subtotal per category in the hub's category order, and the item table
  (category, label, due date, overdue, approved, signed amount). An item
  with an amount the screen cannot read, or a category it has no words for,
  is left out and counted.
- **Card costs**: one switch, by vendor, cost type (account number and
  name) or cost centre (dimension and item). Each row is a month and a
  group, the newest month first. A line is left out and counted in a note
  when the sync marked it `excluded` or its vendor is on the settings'
  vendor exclusion list (owner answer Q4 = EXCL: spec-123 vendors are
  counted under Reporting -> Costs already).
- **Bookkeeping accounts** (owner answer Q2): the Netvisor company, the
  bank, VAT and tax account numbers and the vendor exclusions. The form
  checks what the hub checks (1-12 digits, at most 32 per list, at most 200
  vendors) before it sends `PUT /v1/netvisor/settings`, then reads the
  views again.

Amounts are decimal text. Sums are integer cents, never a float. A figure
reads `1 234.56 EUR` in every locale.

### 6.3 Tests

- `csi-spl-wui/tests/unit/reporting-finance.test.mjs`: the tab rule (an
  admin who is not the owner gets no tab), the mock (403 for every
  `spool.mock.me` role, admin included), the live calls (credentials
  `include`, no Authorization header), the cents (`1.15` exact), the
  breakdowns and exclusions, the form's checks, and every key in every
  locale.
- `csi-spl-wui/tests/e2e/reporting.test.mjs`, in Chrome at 1440x900 and
  390x844 against the mock bundle. The owner (no `spool.mock.me`, operator
  admin) opens the tab and sees the forecast, the voucher date, the three
  slices with the excluded vendor left out, Refresh now and the settings
  form (a bad number refused, a good one saved), with no raw key and no
  sideways scroll. An operator admin who is not the owner gets no tab, and
  on the page by path gets the refusal with no figure, label or form.
- Red controls, run for SPL-4741: the tab rule widened to an admin fails
  "a non-owner admin's bar has no Finance tab" (e2e 114/116); a key removed
  from one locale fails `i18n-parity.test.mjs`.

The mock's figures, labels and account numbers are invented (C2).
