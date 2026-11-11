# Reporting

The **Reporting** section in the left rail (the bar-chart icon, beside
Monitoring) is where the workspace's reports live. It opens on its
**Releases** tab.

## The tabs

A row of tabs sits at the top of the page. Each tab has its own address, so a
link opens that tab directly, and the browser's Back button steps back through
the tabs you opened. Opening `/reporting` on its own goes to the Releases tab.

| Tab | Address | Who sees it | Description |
|---|---|---|---|
| **Releases** | `/reporting/releases` | every member | Delivery report over the release notes: KPI summary, filter bar (range, kinds, areas, search), and daily commit list with release notes. |
| **SQL** | `/reporting/sql` | workspace admins | Read-only SQL query editor for workspace tables returning up to 2,000 rows, with Copy, CSV and JSON export. |
| **Costs** | `/reporting/costs` | workspace owners and admins (permission to read costs) | What the workspace costs: four labels, Total, Persons, Cloud and Tokens, under one period and currency header (below). |
| **Marketing** | `/reporting/marketing` | the workspace owner and its admins | One card per marketing stage; its numbers appear once a source is connected. Attribution: last touch, 28 days. |
| **Incomes** | `/reporting/incomes` | the workspace owner only | The chosen year's income from invoices: one row per month, the year's totals per currency below. |
| **Finance** | `/reporting/finance` | every person of the Netvisor workspace | The newest Netvisor snapshot: the month-end cash forecast and its items, the newest bank voucher date, and card costs. Only the Netvisor owner can ask for a refresh. |

More tabs come later: **Issues**, **Posts** and **Lanes** (admins of the
operator workspace). A tab is drawn only once its page exists, and only for
a reader who may open it.

## Costs: four labels, one period, one currency

The **Costs** tab opens on its **Total** label. A bar under the tab names the
four labels, each with its own address, and every reader of Costs sees all
four:

| Label | Address | Its items |
|---|---|---|
| **Total** | `/reporting/costs/total` | Persons, Cloud and Tokens (and Other, when a cost fits none of them). |
| **Persons** | `/reporting/costs/persons` | Each person cost entered by hand under Expenses -> HR costs. |
| **Cloud** | `/reporting/costs/cloud` | Each GCP project and each cloud cost entered by hand (for example an invoice). Click a project to see its services; for a single month, click a service to see its days. |
| **Tokens** | `/reporting/costs/tokens` | The token use per vendor (with its tokens and list price, never added to a cost), the paid AI subscriptions, or a workspace's share of them. |

Each label shows, right after its name:

- **A pie chart** of its items. Each item's value and percentage share is
  written beside the chart, so a phone reads it too. With no cost in the
  period, no chart is drawn.
- **A table** of its items with one column per month of the period, a total
  column when the period has more than one month, and the share. Click a
  column name to sort by it (highest amount first, names A to Z); click it
  again to reverse the order. The last row holds the totals.

The money is your workspace's: the admins and product owners of the operator
workspace see the whole estate, everyone else their own workspace's costs.
When a workspace has no Persons or Cloud costs of its own, the label says so.

The header above the labels holds one **period** and one **currency** for all
four:

- **Period**: the year to date (from 1 January), the current month (marked
  "so far"), or one of the 11 months before it.
- **Currency**: USD, or your second currency (Settings -> Appearance, EUR
  unless you picked another). USD by default.

Both ride in the address (`?month=2026-10&currency=EUR`, or `?month=ytd`), so
a link, a label switch and the Back button keep them.

An entry with no exchange rate shows a dash, and a total says how many entries
it leaves out. Under Total, a single month also shows how many of its days
each source has read, and names a source with no cost data yet. Under Tokens,
a link leads to Expenses -> AI costs, where each agent type's price per token
is shown.

Costs only reports. The costs themselves are entered in the **Expenses**
section of the left rail (see [Expenses](./expenses.md)).

Old links land on their label and keep their query: `/monitoring/costs`,
`/reporting/costs` and `/reporting/costs/spend` open Total,
`/reporting/costs/human` opens Persons, and `/reporting/tokens` and
`/reporting/costs/price` open Tokens. `/reporting/costs/paid`, the old Paid
items page, opens Expenses -> AI costs (`/expenses/ai`). The fleet's live
token burn stays at Monitoring -> Tokens (`/monitoring/tokens`).

## Left panel order

Reporting reorders and collapses like the other rail sections, and sits before
Expenses and Archive by default.

## On a phone

Reporting is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
