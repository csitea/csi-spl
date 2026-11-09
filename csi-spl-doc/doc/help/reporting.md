# Reporting

> Generated from qto doc `d29362c7-6679-4644-b941-08a687260dd7`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The **Reporting** section in the left rail (the bar-chart icon, beside
Monitoring) is where the workspace's reports live. It opens on its
**Releases** tab.

<a id="ws-doc-1ca16b36-7cda-472f-b772-ca042e5e8cfb"></a>
## The tabs

A row of tabs sits at the top of the page. Each tab has its own address, so a
link opens that tab directly, and the browser's Back button steps back through
the tabs you opened. Opening `/reporting` on its own goes to the Releases tab.

| Tab | Address | Who sees it | Description |
|---|---|---|---|
| **Releases** | `/reporting/releases` | every member | Delivery report over the release notes: KPI summary, filter bar (range, kinds, areas, search), and daily commit list with release notes. |
| **SQL** | `/reporting/sql` | workspace admins | Read-only SQL query editor for workspace tables returning up to 2,000 rows, with Copy, CSV and JSON export. |
| **Costs** | `/reporting/costs` | workspace owners and admins (permission to read costs) | What the workspace costs: five pages under one month and currency header (below). |
| **Marketing** | `/reporting/marketing` | the workspace owner and its admins | One card per marketing stage; its numbers appear once a source is connected. Attribution: last touch, 28 days. |
| **Incomes** | `/reporting/incomes` | the workspace owner only | The chosen year's income from invoices: one row per month, the year's totals per currency below. |
| **Finance** | `/reporting/finance` | every person of the Netvisor workspace | The newest Netvisor snapshot: the month-end cash forecast and its items, the newest bank voucher date, and card costs. Only the Netvisor owner can ask for a refresh. |

More tabs come later: **Issues**, **Posts** and **Lanes** (admins of the
operator workspace). A tab is drawn only once its page exists, and only for
a reader who may open it.

<a id="ws-doc-d2049805-1b4a-44be-b785-d5f8841d0dea"></a>
## Costs: one month, one currency, five pages

The **Costs** tab opens on its **Spend** page. A bar under the tab names its
pages, each with its own address. The bar draws a page only for a reader who
may open it:

| Page | Address | Who sees it | Description |
|---|---|---|---|
| **Spend** | `/reporting/costs/spend` | everyone who sees Costs | The month's costs: a breakdown table and a pie chart (below). Hand-entered hr costs are not in it; they are on Human. |
| **Cloud** | `/reporting/costs/cloud` | admins and product owners of the operator workspace | The month's cloud costs: one row per GCP project, then a project's services, then a service per day. The month's hand-entered cloud costs (for example an invoice) are listed with the projects, without the drill-down. |
| **AI tokens** | `/reporting/costs/tokens` | everyone who sees Costs | The month's AI token costs: the tokens, what was paid in the header's currency, and the list price beside it. Admins and product owners of the operator workspace also see today's live fleet tokens. |
| **Human** | `/reporting/costs/human` | everyone who sees Costs | Admins and product owners of the operator workspace see the month's hand-entered hr costs: one row per entry in the header's currency, with the amount as entered, and a total. Any other reader, or a month without hr entries, sees "Not tracked yet". |
| **Price per token** | `/reporting/costs/price` | admins and product owners of the operator workspace | Coming in a later step. |

Costs only reports. The costs themselves are entered in the **Expenses**
section of the left rail (see [Expenses](./expenses.md)): the paid
subscriptions and top-ups under its **AI costs** tab.

Opening a page you may not see by its address shows "This report is for
operator admins and product owners only." in place of its content.

On Cloud and Human, an entry with no exchange rate to USD shows a dash, and
the total says how many entries it leaves out.

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
  followed by a total row. Hand-entered hr costs are left out of the rows,
  the total and every percentage. A part with no exchange rate to USD shows
  a dash and an empty percentage. Sources without data say "No cost data yet
  for <source>".
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

<a id="ws-doc-721fc8b4-45aa-48e3-be56-7abe9573d522"></a>
## Left panel order

Reporting reorders and collapses like the other rail sections, and sits before
Expenses and Archive by default.

<a id="ws-doc-073f2958-6e12-4c4d-b27f-a570d002b51b"></a>
## On a phone

Reporting is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
