# Costs under Reporting: the redesign (panel consensus)

Issue SPL-3789 · Epic SPL-2389 · Spec [143](spec.md) · Panel of 2 seats.

**Signatures** (both on one sha, `370fab983`, the merged text; this commit
only records them):

- claude seat, editor (c-385): SIGN 370fab983 (its author, 2026-10-27)
- mistral slot, held by a claude seat (c-275): SIGN 370fab983 (spool
  msg:698aeeca-02bd-4760-8960-15ae58502404, task dispatch-1be0e370)

The seat files, each written before its author read the other one:
[seat-claude.md](costs-redesign/seat-claude.md) (landed `1661ce01f`) and
[seat-mistral.md](costs-redesign/seat-mistral.md) (landed `f7e772eb8`).
This file merges them. Doc only: nothing is built until the owner answers
section 7.

**Status**: accepted by the dispatch holder (c-003, spool
msg:01a1cbaf-8f1d-400d-acbf-0656bf0b58f9, 2026-10-27); the poll of section
7 goes to the owner in t1 topic `1be0e370`, and the slices are placed on his
answers.

**The owner's answers** (HUM-10, poll `17403643`, msg `3f1c7128`): A on
questions 1, 2, 3, 5 and 6; **B on question 4**: a customer workspace's
Spend also shows a share of the AI subscriptions, split by its lanes'
tokens. The split is section 3.3.1 (SPL-3799); S3 and S4 follow it.

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
| **Spend** (default) | `/reporting/costs/spend` | What did we pay this month, and for what? | `costs.read`: its workspace's rows and its share of the AI paid items (3.3.1); the operator admin: the estate |
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
customer workspace sees its own rows plus **its share of the AI agents'
paid items** (owner Q4 = B), one row per agent type, by the rule of 3.3.1.

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

### 3.3.1 A customer workspace's share of the AI subscriptions (owner Q4 = B)

What exists today, read on origin/master `a2da59555`:

- A paid item is one agent type (`vendor`), a kind and a plan, paying for
  the UTC days `[period_start, period_end)`; its daily USD is
  `amount * quantity / days / rate` (`fleetPaidDailyUSD`,
  `store/fleet_token_paid.go:167-169`), the rate being the item
  currency's on its first day, else the last before it, else the first
  after it (`store/fleet_token_paid.go:191-200`,
  `store/fleet_token_paid_postgres.go:125-131`, `hub/fleet_token_paid.go:248`).
- Every burn minute carries `work_tenant`: the workspace holding the lane's
  `fleet_lanes` topic, stamped by the hub when the box pushes
  (`hub/fleet_tokens.go:165`, `hub/workspace_tokens.go:19-27,49-71`; rdb
  `0229`). NULL is the operator workspace's own work: an operator topic, no
  topic, no lane row, a topic no workspace holds, or a failed lookup.
- The daily rollup keeps it per (day, box, agent), the day's last minute's
  value (`store/fleet_tokens_postgres.go:119-137`).
- The tokens the effective price divides by are input + output + cache
  write, metered rows only (`store/fleet_token_paid_postgres.go:94-101`).
  The workspace month read counts cache reads too
  (`store/workspace_tokens.go:93-94`).
- Today a workspace answer adds only `fleet_tokens` parts at a paid 0
  (`hub/cost_read.go:170-171`); no paid item reaches any month read (section
  2, item 1).

**The rule.** For each ended UTC day `d` of the month, each paid item `i`
paying for `d` (agent type `v`), and each customer workspace `W`:

```
share(W, i, d) = floor( daily_usd_micros(i) * T(W, v, d) / T(all, v, d) )
```

- `daily_usd_micros(i)` = `round(fleetPaidDailyUSD(i) * 1e6)`, the same
  daily amount the estate counts for `i`.
- `T(x, v, d)` = input + output + cache-write tokens of the metered burn of
  agent type `v` on day `d`, by the lanes stamped `work_tenant = x`, or by
  every lane for `all`. Cache reads are left out, as in the price per
  token (3.5), so a workspace's share equals its tokens times the paid
  price per token of that day.
- The denominator is **every** token of `v` on `d`, the unattributed ones
  included.

What follows from it:

1. **Tokens with no workspace keep their part with the estate.** The NULL
   rows (the operator's own work, and every failed or missing lookup) stay
   in the denominator and are never spread over the customer workspaces. A
   customer pays only for what its own lanes burned.
2. **A day with no metered tokens of `v` gives no share.** `T(all, v, d) =
   0` (no lane worked, or an agent type with no tokens logged, such as agy
   today, spec 140 3.8 `not_metered`): the whole daily amount stays with the
   estate, never divided by zero, never spread evenly.
3. **Rounding**: integer micros, rounded down per (workspace, item, day);
   the remainder stays with the estate. So for every item and day the sum
   of the shares never exceeds `daily_usd_micros(i)`, and a workspace's
   month share is the sum of its daily shares, never recomputed from
   rounded totals.
4. **No exchange rate, no share**: an item whose currency has no rate at
   all (status `no_fx_rate`, 3.5) adds nothing; the row
   says "not priced yet (no exchange rate)", never 0, and its days do not
   count as read (section 4, coverage).
5. **Only ended days**, like the rest of Spend: today is not counted
   ("so far" = up to yesterday, `CoverTo`, `hub/cost_read.go:57,83`).
6. **Second currency**: the share is USD; `second_micros` converts it day by
   day at that day's rate, like every other part (spec 123 5.4).

**What a customer workspace sees.** A group "AI agents (your share)" with
one row per agent type, its month amount and its % of the month; the amount
counts in the workspace's total paid. It never shows a plan name, a price,
an item, the denominator, the estate's total or another workspace's share
or tokens. Its own tokens are on the Tokens page; the amount divided by them
gives that workspace the effective price per token of its agent types: that
is the one figure the rule lets it derive, and it is the price the estate
paid, not a list price.

**Who else.** The operator admin's estate view keeps the **full** paid
amount of every item (the shares are an attribution, not a second cost:
never subtracted from it, never added to it). A member of the operator
workspace who is not its admin sees no share row: the unattributed tokens
are the estate's, and the estate's money is its admin's (spec 140 3.10,
"Who sees what").

```
Customer workspace (made-up figures)
Costs   Month [Oct 2026 (so far) v]  1-26 Oct, UTC   Currency (USD) ( EUR )
        (Spend)  Tokens
| Part                              |    USD | % of month |
| AI agents (your share)            |  42.00 |   84 %     |
|   agent type A                    |  30.00 |   60 %     |
|   agent type B                    |  12.00 |   24 %     |
| Cloud (its own rows)              |   8.00 |   16 %     |
| Total paid, 1-26 Oct              |  50.00 |  100 %     |
AI agents: from 26 Oct only, see "what is not known"
```

**What is not known from today's data** (named, not invented):

| gap | why | the share then |
|---|---|---|
| days before `work_tenant` was stamped | rows written before rdb `0229` and its hub stay NULL, no history is rewritten (spec 140 3.10; the column landed in `b42bf3bad`, 2026-10-26; the first tag holding it, `v5.3.2-c3`, is dated 2026-10-26 17:45Z). Which workspace those lanes worked for is not stored | **none**: those days' tokens are the estate's (rule 1). Before 2026-10-26 a customer's share is 0, and October 2026 is partial; the page says from which day its share is counted |
| 2026-10-26 itself | the day mixes NULL minutes (before the hub roll) and stamped ones; inside the 30-day minute retention the read sees each minute, after it the rollup books the lane's whole day to its last minute's workspace (`store/fleet_tokens_postgres.go:121-123`) | as the rows say: minute-exact while the minutes are kept, the rollup's booking after |
| a lane that moved workspace inside a day, older than 30 days | the same rollup rule | the day goes to the workspace of the lane's last minute |
| a minute whose workspace lookup failed | it is stored as the operator's and only logged (`hub/workspace_tokens.go:25-27`); nothing marks it later | the estate's (rule 1) |
| a minute pushed again inside the 30 days | the upsert re-stamps `work_tenant` from the topic at the new push (`store/fleet_tokens_postgres.go:35`) | the newer stamp |
| an agent type with paid items but no metered tokens (agy) | no token count exists (spec 140 3.8, `not_metered`) | none (rule 2) |

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
| Spend, AI agents (your share), a customer workspace | the same daily amounts times its tokens' fraction (3.3.1) | **missing**: parts with source `ai_share`, one per agent type (no plan), workspace scope only, never in the estate answer; needs a burn read per (UTC day, agent type, `work_tenant`) of input + output + cache-write tokens, metered rows only, minutes for the days still kept and the rollup before them, each day once. Neither read has that shape today: `fleetVendorDaysSQL` is per (day, agent type) over every workspace (`store/fleet_token_paid_postgres.go:94-101`); `WorkspaceTokenMonth` is per month and counts cache reads (`store/workspace_tokens.go:89-102`). Coverage: a day is read when every item paying for it has a rate; the answer also says from which day `work_tenant` exists (3.3.1, not known) |
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

Nothing above is invented: the four "missing" reads are named here and
built by their own slice.

### 4.1 S3 as built (SPL-3810)

The two AI rows above are built by slice S3 (`store/cost_ai_paid.go`,
`store/cost_ai_paid_postgres.go`, hooked in `hub/cost_read.go`), the shape
S4 reads:

- **Estate** (operator admin): parts with `source` `ai_paid`, `estate` true,
  `project_or_vendor` = agent type, `kind` = the plan label, `origin`
  `paid_item`, `usd_micros` = the sum of the items' daily micros
  (`round(fleetPaidDailyUSD * 1e6)`) over the ended days, `days` = days with
  an amount. Never an `ai_share` part.
- **Customer workspace**: parts with `source` `ai_share`, `kind` `share`, one
  per agent type, `usd_micros` = the sum of its daily shares (rule 3.3.1,
  `store.AIShareSplit`); plus `ai_share_from`, the first day of the month
  whose burn carries any workspace stamp. Never an `ai_paid` part, a plan or
  another workspace. The operator workspace's other members: neither.
- **Both**: `second_micros` day by day at the second currency's rate (null
  when a day has none), `eur_micros` 0 (the fixed EUR column is gone); one
  coverage row per source, a day `missing` when an item paying for it has no
  rate (its amount is then left out), else `ok`.
- The burn read is per (UTC day, agent type, `work_tenant`), metered input +
  output + cache write: the minutes of a day that still has any, else its
  rollup (`fleetVendorDaysSQL`'s precedence), operator scope only.

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
| S3 | api | the month read adds `ai_paid` parts from `fleet_token_paid` (estate scope, the full amounts) and, for a customer workspace, `ai_share` parts by the rule of 3.3.1 (the per-day, per-agent-type, per-`work_tenant` burn read of section 4) | store test on Postgres: a 30-day item in a 31-day month gives the right estate share; a workspace with 25 % of an agent type's tokens on a day gets 25 % of that day's amount (micros, rounded down); a day with no tokens of the type and NULL-stamped tokens give no share; the estate total is unchanged by any share. RED: a workspace's answer carries another workspace's share or any `ai_paid` part, or the shares of one item on one day sum above its daily amount |
| S4 | wui | Spend's AI agents group from S3: the estate's per agent type and plan, a customer's "AI agents (your share)" per agent type with no plan, price or item, and the "counted from <day>" line | unit + e2e with the mock's `ai_paid` and `ai_share`, 1400 + 390 px; red: a customer view in the mock shows a plan label or an `ai_paid` row |
| S5 | wui | Paid items page and Price per token page (moves; Price on the month) | the paid round of `tests/e2e/monitoring-costs.test.mjs`, moved to the new paths |
| S6 | wui | Monitoring > Tokens without money, the window toggle, no controls above a 403; `TokensCostsCard` removed | unit: no `kpi_cost` key read; e2e |
| S7 | api | `GET /v1/operator/fleet-tokens/range` from the daily rollup + today's minutes | store test: a day in both the minutes and the rollup is counted once; 403 for a non-operator |
| S8 | wui | Tokens page (agent type, lanes, per workspace, agent hours, daily bars) over S7 and the month read; workspace scope per owner Q1 | unit + e2e 1400 + 390 px |
| S9 | doc | help `reporting.md` Costs section, `monitoring.md` trimmed, spec 123 5.3 / 140 4 / 143 5.1 pointers; i18n keys in every locale, agy review last (language rule) | i18n parity, help coverage |
| S10 | api + wui | hand-entered invoices (spec 123 4.4) as a Paid items kind and the Spend "Invoices" group | only after owner Q5; its own spec slice |

S1 + S2 already answer the owner's first sentence (Costs out of Monitoring,
into Reporting); S3 + S4 fix the biggest wrong figure (item 1) and give a
customer workspace its share (owner Q4 = B, 3.3.1).

## 6. Where the seats differed, and the merge

| topic | claude seat | mistral slot | merged |
|---|---|---|---|
| second page's name | Usage | Tokens | **Tokens**: the owner's own word, and `/reporting/tokens` redirects straight to it |
| period | month plus 7 / 30 days and a custom range | months only | **months only** (rule 2): the owner asked for a monthly basis; a range would need `from`/`to` on the month read for little gain. The empty-months fix (claude P10) is kept |
| money columns | USD + the second currency, two columns | one column, a USD / second-currency toggle | **one column** (rule 3); which currency is owner Q2 |
| hand-entered invoices | build now as a Paid items kind | later, on the Paid items page | owner Q5 |
| who sees Tokens | not asked | owner Q1 (spec 143 Poll 4 vs 140 3.10) | owner Q1 |
| a customer workspace on Spend | owner Q | not asked | owner Q4: **B**, its share of the paid items by its lanes' tokens (3.3.1) |
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
