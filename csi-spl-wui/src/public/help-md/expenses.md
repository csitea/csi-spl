# Expenses

The **Expenses** section in the left rail (the receipt icon, after Reporting)
is where the costs are entered. **Reporting -> Costs** only reports them. The
sidebar keeps the icon rail only, and the page is the tab bar and the open
tab.

Expenses are for the admins and the product owners of the operator workspace.
A product owner reads all three tabs but has no **Add**, edit or delete. Nobody
else has the section in the rail; opening its address reads "Expenses are for
operator admins and product owners only." and no tab.

## The tabs

One tab per cost type. Each tab has its own address, so a link opens that tab
directly, and the browser's Back button steps back through the tabs you
opened. Opening `/expenses` on its own goes to **AI costs**.

| Tab | Address | Description |
|---|---|---|
| **AI costs** | `/expenses/ai` | The paid subscriptions and top-ups of the AI vendors: the list, **Add a paid item**, edit and delete, and the effective price per token per vendor beside its list price. |
| **Cloud infra costs** | `/expenses/cloud` | Cloud infrastructure costs entered by hand, such as an invoice: the list, **Add a cost** and delete. Reporting -> Costs counts them under Cloud. |
| **HR costs** | `/expenses/hr` | Human resources costs entered by hand: the list, **Add a cost** and delete. Reporting -> Costs shows them under Human, not in Spend. |

A cost on Cloud infra costs or HR costs is one row of one month: a description
(on HR costs the role or the contract), the amount net of VAT, its currency, the
month and an optional note. A row cannot be edited: delete it and enter it again.

## Sort, filter, USD and EUR

Each tab's list shows every row in USD and EUR next to the amount entered.
A converted amount is marked with ≈, and its tooltip names the currency it
was entered in and the month whose rate converted it. A dash means there is
no rate for that month.

Click a column name to sort: ascending, descending, then back to the list's
own order. A row with no rate sorts last. The filter row under the column
names narrows the list by text, month, the currency entered and, on **AI
costs**, the vendor; **Clear filters** resets them. While a filter is set the
list reads "n of total". The total row sums the rows shown in USD and EUR; if
one of them has no rate, it says so and shows no total.

## Old links

`/reporting/costs/paid` (the old Paid items page under Reporting -> Costs)
opens **AI costs** and keeps its query. Monitoring -> Tokens no longer holds
the paid items; a line under its tables links to **AI costs**.

## Left panel order

Expenses reorders and collapses like the other rail sections, and sits after
Reporting, before Archive, by default. An order saved before Expenses existed
gets it appended before Archive.

## On a phone

Expenses is one entry in the section strip at the top. Its tabs sit under the
strip.
