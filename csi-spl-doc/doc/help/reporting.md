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
| **Costs** | `/reporting/costs` | workspace owners and admins (permission to read costs) | What the workspace costs: five labels, Project cost (the default), Total, Persons, Cloud and Tokens, under one period and currency header (below). |
| **Marketing** | `/reporting/marketing` | the workspace owner and its admins | One card per marketing stage; its numbers appear once a source is connected. Attribution: last touch, 28 days. |
| **Incomes** | `/reporting/incomes` | the workspace owner only | The chosen year's income from invoices: one row per month, the year's totals per currency below. |
| **Finance** | `/reporting/finance` | every person of the Netvisor workspace | The newest Netvisor snapshot: the month-end cash forecast and its items, the newest bank voucher date, and card costs. Only the Netvisor owner can ask for a refresh. |

More tabs come later: **Issues**, **Posts** and **Lanes** (admins of the
operator workspace). A tab is drawn only once its page exists, and only for
a reader who may open it.

<a id="ws-doc-d2049805-1b4a-44be-b785-d5f8841d0dea"></a>
## Costs: five labels, one period, one currency

The **Costs** tab opens on its **Project cost** label. A bar under the tab
names the five labels, each with its own address, and every reader of Costs
sees all five:

| Label | Address | Its items |
|---|---|---|
| **Project cost** | `/reporting/costs/project` | Cloud, Owned hardware, AI tokens and Human as one total, with how complete each part is (below). |
| **Total** | `/reporting/costs/total` | Persons, Cloud and Tokens (and Other, when a cost fits none of them). |
| **Persons** | `/reporting/costs/persons` | Each person cost entered by hand under Expenses -> HR costs. |
| **Cloud** | `/reporting/costs/cloud` | Each GCP project and each cloud cost entered by hand (for example an invoice). Click a project to see its services; for a single month, click a service to see its days. |
| **Tokens** | `/reporting/costs/tokens` | The token use per vendor (with its tokens and list price, never added to a cost), the paid AI subscriptions, or a workspace's share of them. |

Total includes Persons. The hub's own cost total leaves person costs out, so
a page that shows that total can show a lower number for the same month.

Total, Persons, Cloud and Tokens each show, right after the label's name:

- **A pie chart** of its items. Each item's value and percentage share are
  written beside the chart, so a phone reads them too. With no cost in the
  period, no chart is drawn.
- **A table** of its items with one column per month of the period, a total
  column when the period has more than one month, and the share. Click a
  column name to sort by it (highest amount first, names A to Z); click it
  again to reverse the order. The last row holds the totals.

The money is your workspace's: the admins and product owners of the operator
workspace see the whole estate, everyone else their own workspace's costs.
When a workspace has no Persons or Cloud costs of its own, the label says so.

The header above the labels holds one **period** and one **currency** for all
five:

- **Period**: the year to date (from 1 January), the last 12 months, the
  current month (marked "so far"), or one of the 11 months before it.
- **From month** and **To month**: any start month and end month, both
  included, at most 24 months apart. Every label then shows one column per
  month and a total column that adds them up. They start on the current
  month; a period picked above sets them to its first and last month, and
  picking one of them replaces the period with your range.
- **Currency**: USD, or your second currency (Settings -> Appearance, EUR
  unless you picked another). USD by default.

Both ride in the address (`?month=2026-10&currency=EUR`, `?month=ytd`, or
`?from=2026-01&to=2026-03` for a range), so a link, a label switch and the
Back button keep them.

An entry with no exchange rate shows a dash, and a total says how many entries
it leaves out. Under Total, a single month also shows how many of its days
each source has read, and names a source with no cost data yet. Under Tokens,
a link leads to Expenses -> AI costs, where each agent type's price per token
is shown.

Costs only reports. The costs themselves are entered in the **Expenses**
section of the left rail (see [Expenses](./expenses.md)).

Old links land on their label and keep their query: `/reporting/costs` opens
Project cost, `/monitoring/costs` and `/reporting/costs/spend` open Total,
`/reporting/costs/human` opens Persons, and `/reporting/tokens` and
`/reporting/costs/price` open Tokens. `/reporting/costs/paid`, the old Paid
items page, opens Expenses -> AI costs (`/expenses/ai`). The fleet's live
token burn stays at Monitoring -> Tokens (`/monitoring/tokens`).

<a id="ws-doc-9da0e6d2-b4b7-48c7-a9aa-61d1525fc987"></a>
## The project's cost

**Project cost**, the first label under Costs and the one `/reporting/costs`
opens on, puts everything the project costs on one page:
**cloud + owned hardware + AI tokens + human**, as one total with four parts
under it.

| Part | What it counts |
|---|---|
| **Cloud** | The GCP bill of every project in the billing export, and the cloud costs entered by hand (for example an invoice). |
| **Owned hardware** | Machines the workspace owns: each one's purchase price written off in equal monthly shares over its write-off months. Entering them is not built yet, so this part reads 0 for now. |
| **AI tokens** | What was paid for AI: the subscriptions and top-ups. Their list price is shown on the **Tokens** label, never added to it. |
| **Human** | Approved time, priced at each person's own hourly price on the day it was worked. Only approved time in a frozen or final period is priced. Time still proposed or disputed, and approved time in an open period, counts as pending: its hours are counted, its money is left out. |

The page first shows two figures, **this month so far** and **this year to
date**, each the sum of its parts. Under them a table holds the parts for the
header's period: a month, the year to date, or the range from the start
month to the end month, both included. The project's cost reads no "last 12
months", so that pick is drawn as the year to date, and the page says so.

Each part shows its amount in the header's currency, its share of the
total, and how complete it is:

- **complete**: every day of the period read, every entry priced.
- **n of N days read**: some ended days have no cost data yet.
- **unpriced**: some entries have no price (no exchange rate for their day,
  no hourly price for the person, or time still pending). They show as
  counts and are left out of the money; the page lists what is left out.
- **entered by hand**: the part comes from entries typed in, all priced.
- **not tracked yet**: the part has no source yet.

A part that is not known shows a dash and is never counted as 0. The total
is labelled **Total, priced**, and it says **partial** while any part is
incomplete. The shares are of the priced total. Below the table each part
has a short section with a link to its own page: Cloud, Tokens, Persons, and
Expenses -> AI costs (the paid items) for the owned hardware.

<a id="ws-doc-c80bed70-81ff-4faa-bdac-66942efc2a39"></a>
### Who sees what

- In the operator workspace, its admins, product owners and accountants
  see all four parts for the whole estate. Its other members see two,
  like any other workspace.
- Any other workspace sees two parts: its share of the AI tokens and its own
  people's time. It has no Cloud and no Owned hardware part; those belong to
  the estate.
- Only a time accountant (the hours rates permission) sees the Human money,
  and only together with a role that can open Costs.
  The operator workspace's admins and product owners, and a workspace's
  biz owner, see the Human hours without the money. Every other reader sees
  the Human part's name only. When the Human money is hidden, the total and
  the shares cover the other parts only, so the hidden amount cannot be
  worked out from them.
- No row names a person: Human is one sum per day.

<a id="ws-doc-721fc8b4-45aa-48e3-be56-7abe9573d522"></a>
## Left panel order

Reporting reorders and collapses like the other rail sections, and sits before
Expenses and Archive by default.

<a id="ws-doc-073f2958-6e12-4c4d-b27f-a570d002b51b"></a>
## On a phone

Reporting is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
