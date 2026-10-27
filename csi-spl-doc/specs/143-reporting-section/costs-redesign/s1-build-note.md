# Costs redesign, slice S1: built (SPL-3798)

Issue SPL-3798 · Epic SPL-2389 · Plan [costs-redesign.md](../costs-redesign.md)
section 5, row S1 · owner HUM-10, t1 `1be0e370`, msg `3f1c7128` (answers 2 A,
6 A).

## What S1 adds

| piece | where |
|---|---|
| Reporting tab **Costs** at `/reporting/costs`, after Releases and SQL, shown with `costs.read` (it replaces the reserved `tokens` row) | `csi-spl-wui/src/utils/reporting-tabs.mjs` |
| The four pages, each its own route and chunk: Spend (default), Tokens, Price per token and Paid items (the last two drawn for an operator admin only) | `csi-spl-wui/src/utils/reporting-costs.mjs` (`COSTS_PAGES`), `src/pages/reporting/costs.vue`, `src/pages/reporting/costs/{spend,tokens,price,paid}.vue` |
| Spend: the Monitoring Costs page moved as it was (its month picker is now the header's) | `src/pages/reporting/costs/spend.vue` |
| Tokens, Price per token, Paid items: shells (title and a "coming" line); Price and Paid show the operators-only line to anyone else | the same folder |
| The header: one month (current UTC month "so far", back to `COSTS_FIRST_MONTH` = 2026-10, at most 12; a URL month before it is kept, never rewritten) and one currency (USD, default, or the reader's second currency), both in the query (`?month=`, `?currency=`) and carried by the page bar | `src/components/reporting/costs/CostsHeader.vue` |
| The redirects of section 5 "Links", query kept: `/monitoring/costs` -> `/reporting/costs/spend`, `/reporting/tokens` -> `/reporting/costs/tokens`, `/reporting/costs` -> `/reporting/costs/spend`; `/monitoring/tokens` stays | `COSTS_REDIRECTS` / `legacyCostsPath`, `src/components/LegacyMonitoringRedirect.vue` |

## Left for later slices

- The currency pick is in the URL but Spend still shows today's columns
  (USD, EUR, second currency); S2 makes it the one money column.
- The Monitoring Costs tab stays in the Monitoring bar until S2; its path is
  now the redirect.
- `COSTS_FIRST_MONTH` is a constant taken from section 2 item 13 of the plan
  (cost lines start in October 2026); no hub read names the first month yet.

## New UI text (agy language review pending, the language rule)

`reporting.tab.costs`, `reporting.costs.pages_label`,
`reporting.costs.currency`, `reporting.costs.coming`,
`reporting.costs.page.{spend,tokens,price,paid}`, in all 19 locales. Removed
with the reserved tab: `reporting.tab.tokens`, `reporting.future.tokens`,
`reporting.future.tokens_link`.

## Tests

- `csi-spl-wui/tests/unit/reporting-tabs.test.mjs`: Costs visibility per role,
  and the red control (the row without `perm` shows to a reader without
  `costs.read`).
- `csi-spl-wui/tests/unit/reporting-costs.test.mjs`: the pages, the redirect
  table, the months, the currency and the query.
- `csi-spl-wui/tests/e2e/monitoring-costs.test.mjs` (`costsS1`), at 1400 and
  390 px: `/monitoring/costs?month=2026-09` -> `/reporting/costs/spend?month=2026-09`,
  the other two redirects, the page bar per role, the header picks kept
  across the pages and the back button.
