# Costs under Reporting: the redesign (panel consensus)

Issue SPL-3789 · Epic SPL-2389 · Spec [143](spec.md) · Panel of 2 seats.

**Signatures** (both on one sha):

- claude seat, editor (c-385): pending
- mistral slot, held by a claude seat (c-275): pending

The seat files, each written before its author read the other one:
[seat-claude.md](costs-redesign/seat-claude.md) (landed `1661ce01f`) and
[seat-mistral.md](costs-redesign/seat-mistral.md) (landed `f7e772eb8`).
This file merges them. Doc only: nothing is built until the owner answers
section 7.

Every figure in a wireframe is **made up**; none is a real cost. Paths:
`wui/` = `csi-spl-wui/src/`, `hub/` and `store/` =
`csi-spl-api/src/go/spool-hub-api/internal/{hub,store}/`. Code was read on
origin/master `5034f89d9` (claude seat) and `e865d9167` (mistral slot); dev
served `b3cb06eea`, whose diff to master over the costs files is empty.

## 1. The ask

The owner (HUM-10, t1 topic `1be0e370`, msg `7503412e`): "The costs tab in
monitoring should be part of the reporting tab, and the whole costs need
major refactoring with a panel of experts first. It should be organized much
better. It's pretty confusing."

What dev showed (claude seat, 2026-10-27 ~10:09Z, signed in as a plain
member of workspace t1, 1400 and 390 px, n = 1 look each;
`https://dev.spool-hub.ai/monitoring/costs`): "Month 2026-10 (so far)" with
12 months back to 2025-11, "So far: 26 of 31 days", "This workspace", "No
cost data yet this month, so no pie.", columns "Part · USD · EUR · EUR (day
rate) · % of month · List price", "Total $0.00 €0.00 €0.00". Not seen live by
either seat: the operator admin's estate view and the Tokens page with data
(no operator-admin login for a lane); those come from the served code.

## 2. What confuses today

Both seats found the same core independently. Ids are the seats' own
(claude `P`, mistral slot `C/P/U/W/A`).

| # | the problem | where | seats |
|---|---|---|---|
| 1 | **The money really paid for AI vendors is not in the Costs total.** Subscriptions and top-ups are entered in the Paid card on Monitoring > Tokens (`fleet_token_paid`); the month read never reads that table (`grep -l 'fleet_token_paid\|FleetPaid' hub/cost_read.go store/cost_read*.go store/workspace_tokens.go` -> nothing). The largest real spend is missing and nothing says so. | `wui/pages/monitoring/costs/index.vue:82-89`; `wui/pages/monitoring/tokens/index.vue:44` | P1, C2 |
| 2 | **"Cost" means two things.** Tokens' "Today's fleet cost" / "Today's cost" is the list-price value of subscription tokens, never paid (spec 123 Q-4). Costs shows the same tokens at $0.00 with their value under "List price", and its footer sums paid money beside a list total. | `MonitoringTokensSummary.vue:18-21`, `VendorBurnTable.vue:17,41-44`, `costs/index.vue:57,71,84-88` | P2, C1, U3 |
| 3 | **EUR twice.** "USD · EUR · EUR (day rate)": the fixed EUR column and the default second currency are both EUR, at different rates. | `costs/index.vue:53-55` | P3, U1 |
| 4 | **Mixed periods.** Costs: a calendar month that ends yesterday. Tokens: a window picker that only chooses which lanes are listed, while every figure stays "today since 00:00 UTC" (`store/fleet_tokens.go:269-284`) and the rate is the last 5 minutes. The effective price: the last 30 whole days. The card on Costs: today. | `tokens/index.vue:16-21`; `EffectivePriceTable.vue:10`; `TokensCostsCard.vue:13`; `costs/index.vue:29,34` | P4, P1-P3 (mistral) |
| 5 | **Mixed units in one table.** Dollars, token counts at $0.00 and agent-seconds at $0.00 in one column; the pie counts money only and does not say so. | `costs/index.vue:45,62-71` | P5, U2, U4 |
| 6 | **Four currency rules.** Tokens: the hub's currency (USD); Costs: USD + EUR + a pick; paid items: each item's own; effective price: USD. | `wui/utils/monitoring-tokens.mjs:60` | U5 |
| 7 | **Same label, two sources.** The estate's "Fleet tokens" come from the nightly transcript reader (`cost_lines`); a workspace's from the minute collector (spec 140 3.10). | spec 123 4.3; spec 140 3.10 | P6 |
| 8 | **A bookkeeping form inside a live dashboard.** The Paid card (add, edit, delete) and a 30-day report sit under tables polled every 30 s. | `tokens/index.vue:43-44` | P7, C3 |
| 9 | **Reporting > Tokens is a placeholder that points back to Monitoring.** | `wui/pages/reporting/tokens.vue:11`; `wui/utils/reporting-tabs.mjs:22` | P8, C4 |
| 10 | **Who sees token costs is contradictory.** Spec 143 Poll 4 (10-17): operator admins only. Spec 140 3.10 (10-26, built, rdb 0229): every member role sees its own workspace's token costs. The code follows 3.10 on Costs and Poll 4 on Reporting > Tokens. | `wui/utils/monitoring-tabs.mjs:24` vs `reporting-tabs.mjs:22` | A1, P8 |
| 11 | **Stale words.** The 403 says "workspace owner or admin" (`monitoring.costs.forbidden`); the help page says "owners and admins" (`grep -n 'owners and admins' csi-spl-doc/doc/help/monitoring.md` -> lines 20, 56). Untrue since 0229. "Vendor" on Costs, "Agent type" on Tokens; stored ids such as `tokens` / `hours` on screen. | `en.json`; `costs/index.vue:63-65` | P8, A2, W1, W2 |
| 12 | **Plumbing on screen.** "Days complete per source … partial … not recorded" says nothing about what it does to the total; "No cost data yet for Agent hours" shows every month, since agent hours are never money. | `costs/index.vue:41-43,119-130` | P12, W2, W3 |
| 13 | **Empty months and blind controls.** The month picker offers 12 months back though cost lines start in October 2026; a non-operator opening `/monitoring/tokens` gets the window picker and Refresh above the 403 sentence (seen on dev). | `wui/utils/tenant-costs.mjs:233-241`; `tokens/index.vue:15-24,33` | P9, P10 |

The root: **one page answers three questions at once**. What did we pay
(money), how much did we use (tokens), and what is a token worth (a ratio)
each have their own source, unit and period.

## 3. The new structure under Reporting

### 3.1 Rules every Costs page keeps

1. **"Cost" is money paid, and only that.** The list-price value of tokens is
   "list value (not paid)" everywhere and is never added to a cost.
2. **One period, picked once** in the Costs header: the current UTC month
   "so far" (default; the owner's "monthly basis", spec 123 msg `f99ea7d8`)
   and earlier months back to the first month holding a cost line, at most
   12. It rides in the URL (`?month=YYYY-MM`), so switching pages and the back
   button keep it. "So far" names its days: "1-26 Oct, today not yet
   counted".
3. **One money column per table**, in the currency picked in the Costs
   header (owner Q2). The fixed EUR column goes; a cell's title shows the
   rate and its day, as today.
4. **Tokens never in a money column, money never in a token column.**
5. **One vocabulary**: "agent type" (as the roster says), a source's label
   and never its stored id; UTC stated once in the header.
6. **Reading and entering are separate pages.** Forms live on their own
   page, for the operator admin.
7. **Every partial figure says what it means** in words, beside the
   figure ("26 of 26 days read"); the per-source detail opens on demand,
   for the operator admin.
8. **Phone**: no sideways scroll; each table row is a card (the pattern in
   `costs/index.vue:233-242`); the page bar becomes a select when it does
   not fit.

### 3.2 One Costs tab, four pages

The reserved Reporting tab `tokens` (`reporting-tabs.mjs:22`, `ready: false`)
becomes **Costs**, `/reporting/costs`, after Releases and SQL. It has its own
page bar (one path per page, each its own chunk, as Monitoring's tabs):

| page | path | its one question | who sees it |
|---|---|---|---|
| **Spend** (default) | `/reporting/costs/spend` | What did we pay this month, and for what? | `costs.read`: its workspace's rows; the operator admin: the estate |
| **Tokens** | `/reporting/costs/tokens` | How many tokens did we use this month, by whom, and what is their list value? | owner Q1 (recommended: every member, its own workspace; operator admin, all) |
| **Price per token** | `/reporting/costs/price` | What does 1M tokens really cost us per agent type, against the list price? | operator admin |
| **Paid items** | `/reporting/costs/paid` | What subscriptions and top-ups (later: invoices) did we pay, for which days? Enter and correct them. | operator admin |

### 3.3 Spend (default)

Rows grouped by what was bought, never by stored source, a subtotal each:
**Cloud** (one row per GCP project and its parts), **AI agents** (one row per
agent type and plan: the paid items' daily shares inside the month, the rule
of spec 140 3.8), **Invoices** (hand-entered, once built, owner Q5), **Not
tracked** ("Machines outside GCP", estate view only). Columns: part ·
amount · % of the month. A pie of the groups; under 1 % joins "other".
Token counts and agent hours are not on this page (they are on Tokens). A
customer workspace sees its own rows (owner Q4).

Desktop (made-up figures):

```
Reporting  [Releases] [SQL] [Costs]
Costs   Month [Oct 2026 (so far) v]  1-26 Oct, UTC   Currency (USD) ( EUR )
        (Spend)  Tokens  Price per token  Paid items
+------------------------------------+----------+--------+     .----.
| Part                               |      USD | % of   |    / AI   \
|                                    |          | month  |   |  71 %  |
+------------------------------------+----------+--------+   | Cloud  |
| AI agents                          |   710.00 |  71 %  |    \ 29 % /
|   agent type A · plan 1            |   600.00 |  60 %  |     '----'
|   agent type B · top-up            |   110.00 |  11 %  |
| Cloud                              |   290.00 |  29 %  |
|   prd project · Cloud Run (hub)    |   200.00 |  20 %  |
|   prd project · Cloud SQL          |    70.00 |   7 %  |
|   all project · VM        estimate |    20.00 |   2 %  |
| Machines outside GCP               | not tracked       |
+------------------------------------+----------+--------+
| Total paid, 1-26 Oct               | 1,000.00 | 100 %  |
+------------------------------------+----------+--------+
26 of 26 days read for every source            [details]
```

Phone (390 px):

```
Costs           [Oct 2026 (so far) v]
1-26 Oct, UTC           (USD) ( EUR )
[Spend v]                (page select)
Total paid               1,000.00 USD
┌ AI agents ········ 710.00 · 71 % ┐
│ agent type A · plan 1     600.00  │
│ agent type B · top-up     110.00  │
└───────────────────────────────────┘
┌ Cloud ············ 290.00 · 29 % ┐
│ ...                               │
└───────────────────────────────────┘
        ( pie, full width )
26 of 26 days read          details
```

### 3.4 Tokens

Unit: tokens. The only money-like column is "List value (not paid)", never
summed into Spend. Rows: agent type, opening to its agent lanes; for the
operator admin, a "by workspace" view (today's `workspaces[]`) and, later, a
by-category view over the spec 143 4 activity tree
(`GET /v1/reporting/tokens/by-category`). Columns: tokens (in + out + cache
write) · cache reads · list value · days with tokens · agent hours (both
seats: agent hours are usage, never money). agy reads "not metered", a model
with no price "not priced", never 0. A small daily bar strip per agent type
(inline SVG like the pie, no chart library).

```
Costs › Tokens   Oct 2026 (so far), 1-26 Oct UTC     View (Agent type) Workspace
+--------------+----------+-------------+------------------------+-------+
| Agent type   | Tokens   | Cache reads | List value (not paid)  | Hours |
+--------------+----------+-------------+------------------------+-------+
| > type A     |  1.20 B  |   9.00 B    |  5,400.00 USD          |  410  |
| > type B     |  0.30 B  |   0.80 B    |    420.00 USD          |   95  |
|   type C     |  0.05 B  |   0.10 B    |  not priced            |   40  |
|   type D     |  not metered           |                        |   30  |
+--------------+----------+-------------+------------------------+-------+
[daily bars per agent type ▁▂▃▂▅▃▂ ...]
```

Phone: one card per agent type, "Tokens 1.20 B · cache 9.00 B" then "List
5,400 USD (not paid) · 410 h"; its lanes open under it; the view pick a
select.

### 3.5 Price per token (operator admin)

The effective-price table (`EffectivePriceTable.vue`), moved, on the picked
month instead of a fixed 30 days. Columns: agent type · paid in the month ·
tokens · paid per 1M · list per 1M · status (effective, list only, not
metered, no exchange rate).

```
Costs › Price per token   Oct 2026 (so far)
| Agent type | Paid    | Tokens | Paid / 1M | List / 1M | Status      |
| type A     | 600.00  | 1.20 B |   0.50    |   4.50    | effective   |
| type B     | 110.00  | 0.30 B |   0.37    |   1.40    | effective   |
| type D     |  80.00  |   -    |    -      |    -      | not metered |
```

Phone: one card per agent type, the two prices side by side, the rest
under them.

### 3.6 Paid items (operator admin)

The Paid card (`PaidItemsCard.vue`, `PaidItemForm.vue`), moved as is (list,
add, edit, delete, the hub's refusal text), no polling around it. Filter:
"items paying for days in the picked month" (default) or "all". Each item
says "counted in Spend from <day> to <day>". Hand-entered invoices join as a
second kind once built (owner Q5); an edit never rewrites a closed month
(spec 123 4.4).

```
Costs › Paid items                                   [+ Add a paid item]
| Plan    | Agent type | Kind         | Price of one | Qty | Days paid       |
| plan 1  | type A     | subscription |   200.00 USD |  3  | 1 Oct - 1 Nov   |
| top-up  | type B     | top-up       |   110.00 USD |  1  | 5 Oct - 5 Nov   |
```

Phone: one card per item, the actions under it.

### 3.7 What Monitoring keeps

Monitoring answers "what is burning now". It keeps **Tokens as live burn
only**: tokens per minute (5-minute mean), the last minute, live lanes per
agent type and per lane, the burn and stale badges, the alerts. It drops the
money (owner Q3), the Paid card and the "Fleet tokens today" card. Its window
picker, which today only filters the lane list (item 4), becomes a plain
"lanes active in the last hour / all lanes today" toggle, and a non-operator
sees the 403 sentence with no controls above it. The Costs tab leaves
Monitoring.

## 4. Data: what feeds each figure

| figure | read from | exists? |
|---|---|---|
| Spend, Cloud | `GET /v1/tenant/costs?month=` parts with source `gcp` (`hub/cost_read.go:123`, `cost_lines`) | yes |
| Spend, AI agents | `fleet_token_paid` daily shares (`fleetPaidDailyUSD`, `store/fleet_token_paid.go`) | **missing in the month read**: parts with source `ai_paid`, one per agent type and plan, `usd_micros` = the month's daily shares, `second_micros` as the others, estate scope only; coverage: a day is read when every item paying for it has a rate |
| Spend, Invoices | `cost_lines` origin `hand` / `invoice` | **missing**: the hand-entry API (spec 123 4.4; `POST /v1/operator/cost/day` refuses origin `hand`) |
| Spend, currency | `usd_micros`, `second_micros`, `fx_rate*` (spec 123 5.4) | yes; `eur_micros` is no longer shown |
| Spend, days read | `coverage` of the month read | yes |
| Tokens, a workspace's own | its `fleet_tokens` parts in the month read (spec 140 3.10) | yes |
| Tokens, per agent type and lane, operator, a month | `fleet_token_burn_daily` (365 days kept) + today's minutes | **missing**: `GET /v1/operator/fleet-tokens/range?from=&to=`, answering `by_vendor`, `by_agent`, `by_day`, each day counted once; the live read stays |
| Tokens, per workspace | `workspaces[]` of the operator's month read | yes |
| Tokens, by category | `GET /v1/reporting/tokens/by-category?from&to&depth` (`hub/categories.go:81`) | yes (operator) |
| Tokens, agent hours | `cost_lines` source `agent_hours.<box>` in the month read | yes |
| Price per token | `GET /v1/operator/fleet-tokens/effective?from=&to=` (`hub/fleet_token_paid.go:55`) | yes |
| Paid items | `GET/POST/PATCH/DELETE /v1/operator/fleet-tokens/paid` | yes |
| Monitoring live burn | `GET /v1/operator/fleet-tokens?window=` | yes |

Nothing above is invented: the three "missing" reads are named here and
built by their own slice.

## 5. Migration

**Links** (the `legacyMonitoringPath` pattern in `monitoring-tabs.mjs`):
`/monitoring/costs` -> `/reporting/costs/spend` (`?month=` kept);
`/reporting/tokens` -> `/reporting/costs/tokens`; `/reporting/costs` ->
`/reporting/costs/spend`. `/monitoring/tokens` stays (live burn).

**Moves and removals**:

| item | after |
|---|---|
| `pages/monitoring/costs/index.vue` | rewritten as the Spend page |
| `MonitoringCostsPie.vue` | Spend's chunk, renamed `CostsPie.vue` (budget `ci_costs_route_gzip_kb` follows it) |
| `TokensCostsCard.vue` | removed |
| `PaidItemsCard.vue`, `PaidItemForm.vue` | the Paid items page |
| `EffectivePriceTable.vue` | the Price per token page |
| Monitoring > Tokens money (KPI "Today's fleet cost", "Today's cost" columns) | removed (owner Q3) |
| `monitoring-tabs.mjs` row `costs` | removed; the redirect stays |
| `reporting-tabs.mjs` row `tokens` | replaced by `costs` |
| the fixed EUR column | removed |
| help `monitoring.md` Costs section, the 403 wording | a `reporting.md` Costs section; "every member role" |

**Slices** (each one small lane with its own issue and test; hub slices
first so the pages read real data):

| # | area | slice | test |
|---|---|---|---|
| S1 | wui | Reporting tab `costs`, its page bar and the 4 routes (Tokens, Price, Paid as shells), month picker (months from the first cost line) and currency pick in the header, `?month=` shared; the redirects | unit `reporting-tabs.test.mjs` (visibility per role; red: a reader without `costs.read` sees the tab), redirect table; e2e `/monitoring/costs?month=2026-09` -> `/reporting/costs/spend?month=2026-09` |
| S2 | wui | Spend from today's month read: one money column, grouping, no token or hours row, the days-read line; the Monitoring Costs tab removed | unit grouping; e2e 1400 + 390 px; red: a `fleet_tokens` part in the mock shows in no Spend row |
| S3 | api | the month read adds `ai_paid` parts from `fleet_token_paid` (estate scope) | store test on Postgres: a 30-day item in a 31-day month gives the right share; a workspace scope gets none (RLS); red: the part dropped fails the total |
| S4 | wui | Spend's AI agents group from S3 | unit + e2e with the mock's `ai_paid` |
| S5 | wui | Paid items page and Price per token page (moves; Price on the month) | the paid round of `tests/e2e/monitoring-costs.test.mjs`, moved to the new paths |
| S6 | wui | Monitoring > Tokens without money, the window toggle, no controls above a 403; `TokensCostsCard` removed | unit: no `kpi_cost` key read; e2e |
| S7 | api | `GET /v1/operator/fleet-tokens/range` from the daily rollup + today's minutes | store test: a day in both the minutes and the rollup is counted once; 403 for a non-operator |
| S8 | wui | Tokens page (agent type, lanes, per workspace, agent hours, daily bars) over S7 and the month read; workspace scope per owner Q1 | unit + e2e 1400 + 390 px |
| S9 | doc | help `reporting.md` Costs section, `monitoring.md` trimmed, spec 123 5.3 / 140 4 / 143 5.1 pointers; i18n keys in every locale, agy review last (language rule) | i18n parity, help coverage |
| S10 | api + wui | hand-entered invoices (spec 123 4.4) as a Paid items kind and the Spend "Invoices" group | only after owner Q5; its own spec slice |

S1 + S2 already answer the owner's first sentence (Costs out of Monitoring,
into Reporting); S3 + S4 fix the biggest wrong figure (item 1).

## 6. Where the seats differed, and the merge

| topic | claude seat | mistral slot | merged |
|---|---|---|---|
| second page's name | Usage | Tokens | **Tokens**: the owner's own word, and `/reporting/tokens` redirects straight to it |
| period | month plus 7 / 30 days and a custom range | months only | **months only** (rule 2): the owner asked for a monthly basis; a range would need `from`/`to` on the month read for little gain. The empty-months fix (claude P10) is kept |
| money columns | USD + the second currency, two columns | one column, a USD / second-currency toggle | **one column** (rule 3); which currency is owner Q2 |
| hand-entered invoices | build now as a Paid items kind | later, on the Paid items page | owner Q5 |
| who sees Tokens | not asked | owner Q1 (spec 143 Poll 4 vs 140 3.10) | owner Q1 |
| a customer workspace on Spend | owner Q | not asked | owner Q4 |
| Monitoring's window picker | a lane toggle | kept | **a lane toggle** (item 4: today it only filters the list) |
| agent hours | on Usage | owner Q4, recommended on Tokens | **on Tokens**, both seats agree: no owner question |

## 7. Questions for the owner

Recommended: **A** on every question.

```poll
Who sees the Costs > Tokens page?
(A) Every member: its own workspace's tokens and list value; the operator admin sees all (spec 140 3.10, as built)
(B) Operator admins only (spec 143 poll 4)
In which currency does Spend show money?
(A) One column, USD or my second currency, switched in the header (default USD)
(B) One column, my second currency only
(C) Keep USD + EUR + second currency (today)
Does Monitoring > Tokens keep any money figure?
(A) No: live tokens and rates only, money is in Reporting
(B) Keep today's figure, renamed "list value (not paid)"
What does a customer workspace see on Spend?
(A) Its own rows only; its token use is on Tokens
(B) Also a share of the AI subscriptions, split by its lanes' tokens
(C) No Spend page; Tokens only
Hand-entered invoices (domain, other services):
(A) Build them now, as a kind on Paid items
(B) Later, after the moves
How is Costs laid out in Reporting?
(A) One Costs tab with four pages: Spend, Tokens, Price per token, Paid items
(B) Four separate Reporting tabs
(C) One long Costs page with four sections
```
