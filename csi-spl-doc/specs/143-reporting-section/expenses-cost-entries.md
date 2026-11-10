# Expenses: typed Cloud infra and HR cost entries (step B, SPL-4383)

Owner HUM-10, t1 4f48f878 (msg b0ccc0aa): "On this page there should be
different types for the INSERTION Of at least the following type of costs - AI
costs , cloud infra cost , HR costs", "so at least 3 different tabs on this
page" (msg 50d84663); the page is named **Expenses** (poll 9fbea87a, A).

Step A (SPL-4382) puts the page at `/expenses` with three tabs: `/expenses/ai`
(the paid AI items of rdb 0205, `/v1/operator/fleet-tokens/paid`),
`/expenses/cloud` and `/expenses/hr`. Step B, this page, is the storage and the
hub routes behind the Cloud and HR tabs; their entry forms landed with step A
(section 7).

## 1. Storage: rdb 0245 `cost_entries`

One row is one cost of one month, operator scope only (no `tenant_id`, RLS
policy `operator_scope`, like `fleet_token_paid_items`).

| column | rule |
|---|---|
| `type` | `cloud` or `hr` (CHECK) |
| `label` | 1..100 characters; an HR row names the role or the contract |
| `amount` | `numeric(14,4)`, above 0 |
| `currency` | ISO 4217, `^[A-Z]{3}$` |
| `period` | the month, stored as its 1st day (CHECK) |
| `note` | at most 2000 characters |
| `created_by`, `created_at` | the operator caller's hub id, the insert time |

## 2. Hub routes

The door of `GET /v1/operator/fleet-tokens`: the operator workspace's admin
or the operator service account; anyone else is answered 403
`operator.workspaces` (`TestCostEntryRoutes`).

| route | answer |
|---|---|
| `GET /v1/operator/cost-entries?type=cloud\|hr&month=YYYY-MM` | `{entries}`, period then created_at order, each with `usd_micros` and `eur_micros` (section 8); an absent filter matches every row; a bad one is 400 |
| `POST /v1/operator/cost-entries` `{type, label, amount, currency, period: YYYY-MM, note?}` | 201, the entry; a bad one is 400 `bad_cost_entry` |
| `DELETE /v1/operator/cost-entries/{id}` | 204; an unknown id is 404 |

Code: `csi-spl-api/src/go/spool-hub-api/internal/store/cost_entries.go`
(Memory), `cost_entries_postgres.go`, `internal/hub/cost_entries.go`; the
operations in `internal/hub/openapi.json`.

## 3. Tests

- `TestCostEntryStoreCRUD` (Memory and Postgres): create, list by type and
  month, delete, a bad entry is never stored.
- `TestCostEntryRLS` (Postgres): no scope and a workspace scope read no row
  and may not insert one; the operator scope reads it (control).
- `TestCostEntryRoutes`: the 403s, then the admin's create, filters, delete.

## 4. Read: the month answer counts them (SPL-4824)

Owner csitea f7bba506 (msg f987e4d5): the Google Workspace invoices "should be
added to the cloud costs of the costs tab in the reporting section".
`GET /v1/tenant/costs?month=YYYY-MM` adds, to the ESTATE answer only (the
operator workspace's admin; the rows are operator scope), one part per entry
of that month:

| field | value |
|---|---|
| `source` | `cost_entry` |
| `project_or_vendor`, `kind`, `origin` | the label, the type (`cloud` or `hr`), `hand` (so `hand: true`) |
| `entry_micros`, `entry_currency` | the amount in its own currency |
| `usd_micros` | the amount at the currency's rate of the month's 1st day (the paid items' rule: that day, else the last before it, else the first after it) |
| `eur_micros` | the amount when it is EUR, else the USD at the EUR rate |
| `second_micros`, `fx_rate`, `fx_rate_day` | the amount itself at rate 1 when the second currency is the entry's, else the USD at the second currency's rate |
| `unpriced` | `true` when no rate turned the amount into USD: `usd_micros` 0 is then unknown, never free; nothing is guessed |

**hr entries count in Human, never in Spend** (SPL-4840, owner csitea
f7bba506 poll d82c98e2, answer A "In Human; left out of Spend"): an `hr`
entry is not a part; it is a row of the estate answer's `human` list (same
fields, `pct` null), so `total` and every part's `pct` leave it out. Every
other type stays a part. **An unpriced part has no `pct`** (SPL-4824 R7 N1):
its USD is unknown, so it has no share of the month.

No coverage row: a month holds what was entered. Code:
`internal/store/cost_entry_parts.go`, `costEntryMonthParts` in
`internal/hub/cost_read.go`. Tests: `TestCostEntryParts` (the money, red
control: P3 without `Unpriced`), `TestCostEntryPartsPostgresRates`,
`TestCostReadAddsCostEntries` (the estate reads them, the operator's
developer and another workspace's admin do not; red control: the append
removed), `TestCostReadHREntryInHumanNotSpend` (hr in `human` not `parts`,
the total the parts' sum, no `pct` on an unpriced part; red control: the
master before SPL-4840, H1 and H3 fail).

## 5. Box action: `do_spl_hub_cost_entries` (SPL-4824)

Entries are written and read through the hub as the env's project service
account (never the owner account, never a direct DB write), modelled on
`do_spl_hub_fleet_paid`; create and delete are a dry run unless `DRY_RUN=0`:

- `cd csi-spl-orc && ENV=<env> COST_TYPE=cloud COST_MONTH=2026-01 ./run -a do_spl_hub_cost_entries`
- `ENV=<env> COST_CMD=create COST_TYPE=cloud COST_LABEL='<label>' COST_AMOUNT=64.80 COST_CURRENCY=EUR COST_PERIOD=2026-01 DRY_RUN=0 ./run -a do_spl_hub_cost_entries`
- `ENV=<env> COST_CMD=delete COST_ID=<uuid> DRY_RUN=0 ./run -a do_spl_hub_cost_entries`

**Amounts are net of VAT** (owner HUM-10, poll 68d7f768 answer 4 NET, msg
4eb41f4c): `COST_AMOUNT` is the net. The table keeps one amount, so an
invoice's gross, when given as `COST_GROSS` (never below the net), is kept
in the note as `gross <amount> <currency>`.

Code: `csi-spl-orc/src/bash/run/spl-hub-cost-entries.func.sh`; test
`csi-spl-orc/src/bash/tests/spl-hub-cost-entries.tst.sh` (red control: the
dry-run guard dropped, case 2 fails; the gross-below-net check dropped,
case 6 fails).

## 6. Web UI: Reporting -> Costs (SPL-4824)

- **Cloud** (`csi-spl-wui/src/pages/reporting/costs/cloud.vue`), level 1:
  after the GCP projects, one row per `cloud` entry of the month, labelled
  with the entry and "Entered by hand: <amount in its own currency>", no
  drill. They count in the level's total.
- **No rate**: an `unpriced` entry shows a dash in USD whose title says
  "No <currency> rate for this month, so no USD amount: it is not in the USD
  total", and the total's title names how many it leaves out
  (`data-left`). Never a silent $0.
- **Every currency leaves it out the same way** (R7 W1): an unpriced entry
  with no second-currency amount is left out of that total too, counted
  (`secondLeftRows`), and never blanks it; the hub's `total.second_micros`
  (`costMonthAnswer`) and the WUI sums agree. Only a priced part with no
  rate still blanks the second total (never a guess). The heading reads
  "Cloud costs" and the column "GCP project or entered cost".
- **Spend** (`spend.vue`): the entry is a row of source "Entered costs"
  with the by-hand mark; an unpriced one shows the same dash in USD (and in
  EUR unless it is a EUR entry), and the USD, EUR and second totals' titles
  each name what they leave out.
- **Human** (`human.vue`, SPL-4840): a month whose answer has `human` rows
  lists them, one per `hr` entry in the header's currency with "Entered by
  hand: <amount>" and a total; the same dash and left-out count for an
  unpriced one. A month without them, or a reader other than the operator
  admin, keeps "Not tracked yet". Spend never lists an `hr` entry, and an
  unpriced part's "% of month" cell is empty beside its dash (R7 N1).
- Pure parts: `cloudEntries`, `humanEntries`, `sectionAmount` and `cloudTotal`
  (`unpricedRows`) in `src/utils/costs-sections.mjs`; the mock month's
  scenario `entries` (`src/utils/tenant-costs.mjs`). Tests:
  `tests/unit/costs-sections.test.mjs` (red control: `sectionAmount`
  returning the unpriced 0), `tests/e2e/monitoring-costs.test.mjs` (the
  `entries` block).

<!-- version: 0.7.0 · updated: 2026-11-05 -->

## 7. Web UI: Expenses -> Cloud infra costs and HR costs (SPL-4382)

`csi-spl-wui/src/components/expenses/CostEntriesCard.vue`, mounted by
`pages/expenses/[[tab]].vue` with the open tab's type: the list (newest month
first), **Add a cost** and delete with a confirmation. There is no edit route:
a wrong entry is deleted and entered again. The amount is the net of VAT
(section 5).

- `utils/cost-entries.mjs` holds the form's checks, `store.CheckCostEntry`'s
  rules counted in bytes as the hub does, plus a currency the hub quotes; the
  hub's refusal shows as it came.
- The client calls are ops of `fleetPaid` (`entries`, `entry_create`,
  `entry_delete`, `utils/spool-client-lazy.mjs`), so the initial chunk gains no
  stub name; the card and the util load with their tab.
- Tests: `tests/unit/cost-entries.test.mjs` (the checks and the body per type), `costEntryRound` in
  `tests/e2e/monitoring-costs.test.mjs` (1400 + 390 px: insert per type, the
  other tab does not list it, delete).

## 8. Sort, filter, USD and EUR on every Expenses list (SPL-5198)

Owner HUM-10, t1 965283be msg 382450e2: "listing should have sorting and
filtering simir to the issues listing , it must also have the pricess in
dollars and euros". Applies to the three tabs: AI costs (the paid items),
Cloud infra costs and HR costs.

### 8.1 The hub prices each row

- `GET /v1/operator/cost-entries` adds `usd_micros` and `eur_micros` to each
  entry (`store.PriceCostEntries`). They use the rates of the entry's month,
  the same rule as the month read in section 4.
- `GET /v1/operator/fleet-tokens/paid` adds the same two fields to each item
  (`store.PricePaidItems`), at the rates of its `period_start`, the day the
  effective read already converts it at.
- A field is the amount itself when the row was entered in that currency.
  Otherwise it is converted with the rates already in `fx_rates` (rdb 0200);
  there is no second rate source. When no rate exists the field is `null`,
  never 0.
- `usd_rate_day` and `eur_rate_day` name the day of the rate that made each
  converted field (`null` when the row is in that currency or no rate made
  it). The rate lookup falls back to the last rate before the day, else the
  first after it, with no bound, so this day can be far from the row's own.
  When two rates made the EUR field (neither USD nor EUR entered), it names
  the one farther from the row's day. Both lists share one rule
  (`store.priceUSDEUR`).

### 8.2 The Web UI list

- Columns: the label, the amount as entered (in its own currency), USD, EUR,
  the month (or the period), the note, and for the paid items also the
  vendor, the kind and the quantity. Each column name except the amount as
  entered (no sort across currencies) is a sort control (`components/SheetSortButton.vue`, `aria-sort` on its
  `th`), the same control as Issues and Monitoring -> Lanes: a click cycles
  ascending, descending, then back to the list's own order. A row with no
  rate sorts last either way.
- A filter row under the column names: text (label or plan, and note), the
  month, the entered currency, and for the paid items the vendor. **Clear
  filters** resets them. While a filter is set, the list says
  "n of total". When no row matches, it says so.
- A converted amount is marked with ≈ and a title naming the source currency
  and the day of the rate used (`usd_rate_day` / `eur_rate_day`). A missing
  rate shows a dash, with a title naming the currency that has no stored
  rate; the amount as entered stays in its own column.
- The total row sums the shown rows in USD and EUR; a paid item counts its
  amount times its quantity. If any shown row has no rate, the total is not
  shown and the row says why. It never shows a partial sum.
- Code: `utils/cost-entries.mjs`, `utils/monitoring-paid.mjs` (`moneyCell`,
  `moneyTotals`, `mockMoney` shared by both lists), `CostEntriesCard.vue`,
  `PaidItemsCard.vue`.
- Tests: `TestPriceCostEntries`, `TestCostEntryListPriced`,
  `TestPricePaidItems`; `tests/unit/cost-entries-sort-filter.test.mjs`,
  `tests/unit/paid-items-sort-filter.test.mjs`.
