# Expenses

The **Expenses** section in the left rail (the receipt icon, after Reporting)
is where the costs are entered. **Reporting -> Costs** only reports them. The
sidebar keeps the icon rail only, and the page is the tab bar and the open
tab.

Expenses are for the admins of the operator workspace. Anyone else who opens
the page reads "Expenses are for operator admins only." and no tab.

## The tabs

One tab per cost type. Each tab has its own address, so a link opens that tab
directly, and the browser's Back button steps back through the tabs you
opened. Opening `/expenses` on its own goes to **AI costs**.

| Tab | Address | Description |
|---|---|---|
| **AI costs** | `/expenses/ai` | The paid subscriptions and top-ups of the AI vendors: the list, **Add a paid item**, edit and delete, and the effective price per token per vendor beside its list price. |
| **Cloud infra costs** | `/expenses/cloud` | Cloud infrastructure costs. Entering them comes in a later step. |
| **HR costs** | `/expenses/hr` | Human resources costs. Entering them comes in a later step. |

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
