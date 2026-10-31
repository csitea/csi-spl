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
| **Costs** | `/reporting/costs` | workspace owners and admins (permission to read costs) | What the workspace costs: five pages under one month and currency header (below). |

More tabs come later: **Issues**, **Posts** and **Lanes** (admins of the
operator workspace). A tab is drawn only once its page exists.

## Costs: one month, one currency, five pages

The **Costs** tab opens on its **Spend** page. A bar under the tab names its
pages, each with its own address:

| Page | Address | Who sees it | Description |
|---|---|---|---|
| **Spend** | `/reporting/costs/spend` | everyone who sees Costs | The month's costs: a breakdown table and a pie chart, as the Monitoring Costs tab showed them. |
| **Cloud** | `/reporting/costs/cloud` | admins of the operator workspace | The cloud costs: one row per GCP project, then a project's services, then a service per day. |
| **AI tokens** | `/reporting/costs/tokens` | everyone who sees Costs | The month's tokens, what was paid for them and their list price beside it. |
| **Human** | `/reporting/costs/human` | everyone who sees Costs | Human costs: not tracked yet. |
| **Price per token** | `/reporting/costs/price` | admins of the operator workspace | Coming in a later step. |

Costs only reports. The costs themselves are entered in the **Expenses**
section of the left rail (see [Expenses](./expenses.md)): the paid
subscriptions and top-ups under its **AI costs** tab.

The header above the pages holds one **month** and one **currency** for all
five pages:

- **Month**: the current month (marked "so far") back to October 2026, the
  first month with cost lines. Never a future month.
- **Currency**: USD, or your second currency (Settings -> Appearance, EUR
  unless you picked another). USD by default.

Both ride in the address (`?month=2026-10&currency=EUR`), so a link, a page
switch and the Back button keep them.

**Spend** shows the header's month:

- **Cost breakdown**: one row per cost part (source, project or vendor, and
  kind), showing amounts in USD and EUR, percentage share of the month, list
  price where recorded, and marks for costs entered by hand or estimated,
  followed by a total row. Sources without data say "No cost data yet for
  <source>".
- **Pie chart**: shows slices for parts exceeding 1 % of the month's total,
  with the remainder grouped under "Other". If no cost data is recorded for the
  month, no chart is drawn.
- **On a phone**: each cost part is displayed as a card with its figures
  labelled under its name.

Old links land here and keep their query: `/monitoring/costs` opens Spend,
`/reporting/tokens` opens AI tokens, and `/reporting/costs` opens Spend.
`/reporting/costs/paid`, the old Paid items page, opens Expenses -> AI costs
(`/expenses/ai`). The
fleet's live token burn stays at Monitoring -> Tokens (`/monitoring/tokens`).

## Left panel order

Reporting reorders and collapses like the other rail sections, and sits before
Expenses and Archive by default.

## On a phone

Reporting is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
