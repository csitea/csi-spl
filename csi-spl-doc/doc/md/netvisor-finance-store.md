# Netvisor finance store: hub tables the workspace's people read, the owner writes

Spec 125 rows B4 and B5 ([spec](../../specs/125-netvisor-integration/spec.md)
sections 5.2 and 7, cases C-NVS-4 and C-NVS-5), issues SPL-4721 (schema and
store) and SPL-4732 (hub routes, section 5); SPL-4742 moved the routes to
the Netvisor workspace and made a card line's account optional (rdb
`0258`). SPL-4792 (rdb `0260`) opened READING to every person seated in the
Netvisor workspace: C7 as rewritten, owner HUM-10, csitea topic 67c25538,
poll 2a767008, answer msg cfa78746 ("WS - Every member of the csitea
workspace"); msg 91a1bc9a: agents never see the figures. The WUI screen is
B7 (SPL-4741, section 6), the main-box sync B6.

## 1. Tables (rdb `0255_netvisor_finance.sql`)

| table | one row per | holds |
|---|---|---|
| `netvisor_settings` | workspace | `owner_human_id` (the ONE human the data is filed under and who alone writes the settings and the refresh request, C7), `env` (`test` or `prd`), the bank, VAT and tax bookkeeping account numbers, the spec-123 vendor exclusion list, `refresh_requested_at` (the open "Refresh now", rdb `0257`) |
| `netvisor_snapshots` | fetch | `owner_human_id`, `env`, `as_of`, `month_end`, `newest_bank_voucher_date`, `fetched_at` |
| `netvisor_forecast_items` | month-end term | category, sign, amount (`numeric(18,2)`), currency, due date, overdue, approved, label |
| `netvisor_card_cost_lines` | card cost line | month, route, vendor, account number (1-12 digits, or `''` for none, rdb `0258`: a credit-card e-invoice line names no account) and name, dimension and item, amount, VAT code, excluded |

Items and lines carry their snapshot's `owner_human_id` under a composite FK,
so a row can never be filed under another human than its snapshot. A
workspace delete cascades all four tables.

The owner's human id is data in `netvisor_settings`, never a code literal.
No figure, account number or id is in git; tests use invented values.

## 2. Who reads what (RLS)

All four tables have `FORCE ROW LEVEL SECURITY` and the usual
`tenant_scope`. rdb `0255`'s RESTRICTIVE `owner_scope` (all commands) is
split by rdb `0260` into RESTRICTIVE policies per command:

- `owner_insert`, `owner_update`, `owner_delete`: 0255's owner rule. A data
  row is written only when its `owner_human_id` equals the transaction-local
  `app.human_id` AND that human is the workspace's owner in
  `netvisor_settings` now; the settings row only by the owner or the ingest
  scope.
- `member_read` (SELECT): the owner rule OR a person seat: a live
  membership of `app.human_id` in the transaction's workspace (not
  disabled, not past `access_until`, its human not disabled and not
  `technical`, i.e. no act-as clone, not a `channel_guest`, and with at least
  one role that is neither `pure_agent` nor `time_accountant`). A data row
  still passes only when it is filed under the CURRENT owner, so nobody
  reads a former owner's snapshots. The person test is the SQL function
  `netvisor_person_seat()` (the rdb `0219` `spool_agent_scope_ok` pattern):
  an inline policy subquery would pin `tenant_memberships.access_until`
  as a dependency and refuse the column drop that
  `TestMemberAccessUntilBeforeMigration` plays.
- No `operator_scope` policy: the operator scope, the ops psql and
  `pg_dump` under it read 0 rows. The Reporting SQL tab refuses the tables
  (`forbidden_relation`), as it refuses every table with a per-human policy.
- `app.rls_scope = 'netvisor_ingest'` reaches `netvisor_settings` alone.

| caller (scope) | settings | snapshots, items, lines |
|---|---|---|
| owner human (`inNetvisorOwner`) | read, update | read, write |
| a person seated in the workspace, admins included (`inNetvisorOwner` with its id) | read; update 0 rows | the current owner's rows; insert refused |
| an agent seat, a time accountant, an act-as clone, a suspended seat, a human seated elsewhere | 0 rows | 0 rows, insert refused |
| the tenant alone (`inTenant`) | 0 rows | 0 rows |
| operator (`asOperator`) | 0 rows | 0 rows |
| operator ingest (`inNetvisorIngest`) | read, set owner | 0 rows |
| the owner's id in another workspace | 0 rows | 0 rows |

When the operator moves the owner, nobody reads the old owner's snapshots;
the old owner, if still seated, reads the new owner's like any member.

## 3. Store API (`internal/store/netvisor.go`)

`store.Netvisor`, implemented by `*Postgres`; the hub reaches it by type
assertion.

| method | scope | errors |
|---|---|---|
| `NetvisorSetOwner(tenant, human, by)` | ingest | `ErrNoHuman`, `ErrNotFound` (no workspace) |
| `NetvisorSettings(tenant, human)` | human's | `ErrNotFound` unless human is the owner or a person seated in the workspace |
| `NetvisorPutSettings(tenant, human, s)` | owner; never moves the owner | `ErrNotFound`, `ErrBadNetvisor` |
| `NetvisorIngest(tenant, snap)` | ingest, then the owner's | `ErrNetvisorNoOwner`, `ErrNetvisorEnv`, `ErrBadNetvisor` |
| `NetvisorLatest(tenant, human, env)` | human's: the current owner's newest snapshot | `ErrNotFound` |
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
- `TestNetvisorStoreRLSControl`: with `member_read` dropped, another human
  and the tenant alone read the owner's rows.
- `TestNetvisorStoreMemberRead` (rdb `0260`): a person seated in the
  workspace reads the owner's settings and newest snapshot, and cannot put
  the settings, request a refresh or insert a snapshot (42501); an agent
  seat, a time accountant, a technical human (act-as clone), a suspended
  seat and a person of another workspace read 0 rows; after an owner move
  the former owner reads the new owner's snapshot only. Red control, run for
  SPL-4792: 0255's `owner_scope` put back in place of 0260's policies turns
  the member's read into `ErrNotFound`.
- `TestNetvisorStoreWrites`: only the owner writes. Another human cannot
  file a snapshot even under its own id (42501). An owner move hides the old
  snapshots.
- `TestNetvisorStoreRefresh`: only the owner opens a refresh; a second press
  keeps the first time; an older fetch leaves it open, a newer one clears it.
- `TestNetvisorStoreCardLineNoAccount`: a line with no account files and
  reads back with `account_number` `''`; `40x0` is refused; the table's CHECK
  is rdb `0258`'s.
- `TestRLSCoversEveryTenantTable`, `TestRLSPoliciesFailClosed` and
  `TestCrossTenantEveryTable` cover the four tables;
  `TestSQLExecutorRefusesRelations` covers the Reporting SQL refusal.

## 5. Hub routes (B5, `internal/hub/netvisor.go`)

Bodies: `internal/wire/netvisor.go`; operations: `internal/hub/openapi.json`
(tag `netvisor`, and `operator`). No MCP tool, no `spool` CLI read and no
spool message carries a figure (C8).

Every route serves ONE workspace, the Netvisor workspace: cnf
`env.hub.env.SPOOL_HUB_NETVISOR_WORKSPACE` in `csi-spl-cnf/csi-spl/all.env.yaml`
(`csitea` on dev and prd; spec 125 B5 "csitea tenant only"), read into
`Options.NetvisorWorkspace`, never a code literal. It is not the hub's
operator workspace (`t1`, the apex on dev): that one is refused like any
other. Unset, every Netvisor route is `404`.

### 5.1 The browser routes

| route | who | answer |
|---|---|---|
| `GET /v1/view/netvisor/forecast` | every person of the workspace | `{env, snapshot, items, refresh_requested_at, reader_is_owner}`: the owner's newest snapshot of the settings' env; `snapshot` is null before the first fetch |
| `GET /v1/view/netvisor/card-costs` | every person of the workspace | `{env, snapshot, lines, vendor_exclusions, refresh_requested_at, reader_is_owner}`: `vendor_exclusions` is the settings' spec-123 vendor list, so a member's screen leaves out the same lines as the owner's |
| `POST /v1/netvisor/refresh` | the owner | `202 {refresh_requested_at}`: "Refresh now"; a second press keeps the first time |
| `GET /v1/netvisor/settings` | the owner | the settings |
| `PUT /v1/netvisor/settings` | the owner | `{env, bank_account, vat_accounts, tax_accounts, vendor_exclusions}` replaced; the owner is never written here |

`reader_is_owner` tells the screen whether to show Refresh now and the
settings form. Two doors: `netvisorReader` for the view routes,
`netvisorOwner` (the reader door plus the owner check) for the other three.

| caller | view routes | owner routes |
|---|---|---|
| the workspace's Netvisor owner, own browser session | 2xx | 2xx |
| another person seated in the workspace, admins included | `200` | `403 forbidden` (`netvisor.owner`) |
| any request with an `Authorization` header: a box or agent desk token, a CLI token, the operator service account | `403 person_only` | `403 person_only` |
| an act-as clone (of the owner too), a session that is not a person (`realmRefuses`), a seat in the workspace that is not a person's (agent, time accountant, channel guest: `netvisorPersonSeat`) | `403 person_only` | `403 person_only` |
| a member of another workspace (the operator workspace too), the owner signed in to another workspace | `404 not_found` | `404 not_found` |
| no session | `401` | `401` |

The owner check is the session's human id against the `owner_human_id`
the store answers: data, never a code literal or a role. Behind the door the
store reads as that human, so rdb `0260`'s RLS is a second wall: a seat the
door let through by mistake that is not a person's reads 0 rows.

Why the settings and Refresh now stay the owner's (SPL-4792): opening
"Refresh now" to members would widen the UPDATE policy on the row that also
holds the account numbers, which RLS cannot narrow to one column; the brief
kept both as they were unless trivial, and this was not.

### 5.2 The operator's routes (the main-box sync, B6)

The env's operator service account (`operatorAuth`, a Bearer id token),
into the Netvisor workspace only; a request whose Host or `X-Spool-Tenant`
names another workspace, the operator workspace included, is
`403 netvisor_workspace_only` and writes nothing. One that names none (the
api host, no header) files into the Netvisor workspace.

| route | answer |
|---|---|
| `PUT /v1/operator/netvisor/owner` | `{human_id}` names the owner; `409 not_member` unless a person seated in the Netvisor workspace |
| `POST /v1/operator/netvisor/snapshots` | one snapshot (dates `YYYY-MM-DD`, amounts decimal text, a card line's `account_number` 1-12 digits or `""`/absent for none); `200 {snapshot_id, env, items, card_lines}`, counts only; `409 no_owner`, `409 env_mismatch`, `400 bad_snapshot` |
| `GET /v1/operator/netvisor/refresh` | `{refresh_requested_at}`, null when none is open (the B6 poller) |

Logs carry the workspace, ids, counts and outcomes, never an amount, an
account number or a label.

### 5.3 Tests

In `internal/hub`, on Postgres (real browser sessions: fake IdP, cookies,
act-as):

- `TestNetvisorHubRBAC`: the owner gets 2xx on all five routes and reads
  the figures (`reader_is_owner` true); a developer and an admin of the
  workspace read the figures on the view routes (`reader_is_owner` false) and
  get `403` with no figure or account on the owner routes; an act-as clone of
  the owner, an agent seat, the operator service account, a box (agent desk)
  token and the owner's cookie plus a box token get `403` and no figure; no
  session `401`.
- `TestNetvisorCrossTenant`: an admin of another workspace and the owner
  signed in to another workspace get `404`; the operator routes refuse
  another workspace (`403`).
- `TestNetvisorFinanceWorkspaceOnly`: the Netvisor workspace answers the
  operator routes `409 no_owner` before the owner is named, then `200`; the
  operator workspace and a third workspace get `403 netvisor_workspace_only`
  by Host or `X-Spool-Tenant`; the owner seated in the operator workspace
  gets `404` on the owner routes there. Red control: `netvisorOperator`
  pointed back at `operatorTenant` turns the Netvisor workspace's `409` into
  `403`.
- `TestNetvisorCardLineNoAccount`: a card line without `account_number`
  ingests and the owner reads it back with `""`; `40x0` is `400`.
- `TestNetvisorOperatorIngest`: operator auth (`401`, `403`), counts-only
  answer, the `400` and `409` refusals, the refresh request from the press to
  the snapshot that clears it.
- `TestNetvisorSnapshotIn` (any store): the wire dates.

## 6. The Finance screen (B7, Reporting -> Finance)

Spec 125 row B7, case C-NVS-7, issue SPL-4741; every person of the Netvisor
workspace since SPL-4792. The WUI reads the routes of section 5.1 from the
reader's own browser session; it holds no figure of its own and sends no
Authorization header (the hub would answer `403 person_only`).

| piece | file |
|---|---|
| the tab, `/reporting/finance`, its own chunk | `csi-spl-wui/src/pages/reporting/finance.vue` |
| the settings form | `csi-spl-wui/src/components/reporting/finance/FinanceSettings.vue` |
| the hub calls, the mock, the sums | `csi-spl-wui/src/utils/reporting-finance.mjs` |
| the tab rule (`netvisorReader`) | `csi-spl-wui/src/utils/reporting-tabs.mjs` |
| the strings | `reporting.tab.finance`, `reporting.finance.*` in the 19 `csi-spl-wui/i18n/locales/*.json` |

### 6.1 Who sees the tab

The tab has no role rule. The Reporting bar sends `GET
/v1/view/netvisor/forecast` once per page load and hub base, in any
workspace: the hub alone knows which workspace keeps Netvisor data and
answers `404` in the others, `403` to an agent seat or an act-as clone. The
tab is drawn when that read answered 2xx. Any refusal or failure hides it.
Hiding is not the control: the page opened by its path reads the two views
first, and on the hub's `403` (`401`, `404`) it shows the refusal line.

The views' `reader_is_owner` decides the rest: only the owner's screen shows
**Refresh now** and the settings form, and only the owner's page reads `GET
/v1/netvisor/settings`, so another person sends no read the hub refuses. The
card costs leave out the vendors of the view's `vendor_exclusions` for every
reader.

### 6.2 What the screen shows

- **Head**: the Netvisor company (`env`), the newest bank voucher date
  badge, the snapshot's `as_of` and fetch time, **Refresh now** (`POST
  /v1/netvisor/refresh`, the owner's only) and the open request's time.
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
- **Bookkeeping accounts** (owner answer Q2; the owner's screen only): the Netvisor company, the
  bank, VAT and tax account numbers and the vendor exclusions. The form
  checks what the hub checks (1-12 digits, at most 32 per list, at most 200
  vendors) before it sends `PUT /v1/netvisor/settings`, then reads the
  views again.

Amounts are decimal text. Sums are integer cents, never a float. A figure
reads `1 234.56 EUR` in every locale.

### 6.3 Tests

- `csi-spl-wui/tests/unit/reporting-finance.test.mjs`: the tab rule (no
  role alone draws it; the forecast answer does), the mock (another person
  reads the views with `reader_is_owner` false and gets 403 on the owner
  routes; an agent, a time accountant and a channel guest get 403
  everywhere), the probe (the forecast, once per hub base, false on another
  workspace's 404), the live calls (credentials `include`, no Authorization
  header), the cents (`1.15` exact), the breakdowns and exclusions, the
  form's checks, and every key in every locale.
- `csi-spl-wui/tests/e2e/reporting.test.mjs`, in Chrome at 1440x900 and
  390x844 against the mock bundle. The owner (no `spool.mock.me`, operator
  admin) opens the tab and sees the forecast, the voucher date, the three
  slices with the excluded vendor left out, Refresh now and the settings
  form (a bad number refused, a good one saved), with no raw key and no
  sideways scroll. An admin who is not the owner sees the tab and the same
  figures with the excluded vendor left out, no Refresh now and no form, and
  sends no refused read. An agent seat gets no tab, and on the page by path
  gets the refusal with no figure, label or form.
- Red controls: run for SPL-4741, a key removed from one locale fails
  `i18n-parity.test.mjs`; run for SPL-4792, the tab rule widened to every
  role fails the unit test "a role alone draws no Finance tab", and the page
  reading the settings for every reader fails the e2e "a member sends 0
  refused reads".

The mock's figures, labels and account numbers are invented (C2).
