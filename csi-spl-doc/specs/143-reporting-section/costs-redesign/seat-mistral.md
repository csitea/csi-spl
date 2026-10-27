# Costs under Reporting: seat proposal, mistral slot

Written by a **claude** seat (c-275) in the panel's mistral slot (the mistral
lane was placed on claude; brief slug `c002-costs-panel-mistral`). Written
before reading the editor's seat file. Issue SPL-3790, epic SPL-2389, spec
[143](../spec.md).

The owner's ask (HUM-10, t1 1be0e370, msg 7503412e): "The costs tab in
monitoring should be part of the reporting tab, and the whole costs need
major refactoring with a panel of experts first. It should be organized much
better. It's pretty confusing."

Every figure in a wireframe below is **made up**. None is a real cost.

## 0. What was read, and on which tree

- Specs on origin/master (`e865d9167`): [123 cost tracking](../../123-cost-tracking/spec.md)
  (5, 5.1-5.4), [140 token burn](../../140-token-burn/spec.md) (0, 3.5,
  3.8, 3.10, 4), [143 reporting](../spec.md) (0, 1, 5.1, 6.1, 7),
  [153 monitoring lanes tab](../../153-monitoring-lanes-tab/spec.md) (heads).
- The served dev build: `curl -s https://dev.spool-hub.ai/build.json` ->
  `"commit":"b3cb06eea…","version":"5.6.0"`. `git merge-base --is-ancestor
  b3cb06eea origin/master` holds, and `git diff --stat b3cb06eea origin/master`
  over `pages/monitoring`, `pages/reporting`, `components/monitoring/token-burn`,
  `MonitoringCostsPie.vue`, `utils/{monitoring,reporting}-tabs.mjs` and
  `i18n/locales/en.json` is empty. So the code below is what dev serves.
- **Not seen**: the signed-in page itself. This seat had no dev session and
  its browser tools did not connect. https://dev.spool-hub.ai/monitoring/costs
  answers 200 with the app shell only. The screens below are described from
  that served code and the English texts in `en.json`, not from a screenshot.
  The editor or a lane with a session should check them before the build.

## 1. What confuses today

Paths are under `csi-spl-wui/src/` unless they start with another top-level
directory.

### 1.1 Two tabs, two models of "cost", both under Monitoring

| # | Problem | Where |
|---|---|---|
| C1 | **Costs and Tokens both show money, and the money means different things.** On Costs the total is money really paid (GCP lines, later invoices). On Tokens, "Today's fleet cost" is the **list-price value** of the tokens. The fleet runs on subscriptions, so that value is never paid (spec 123 Q-4: "shown beside it, never added to it"). The word "cost" covers both. | `components/monitoring/token-burn/MonitoringTokensSummary.vue:19` (`kpi_cost` = "Today's fleet cost"); `pages/monitoring/costs/index.vue:84` (paid total) |
| C2 | **What was really paid for AI never reaches the Costs total.** The paid subscriptions and top-ups live on the *Tokens* tab (Paid card). The monthly Costs read does not read them: `grep -n fleet_token_paid csi-spl-api/.../internal/store/cost_read.go` -> 0 lines. So the month's total is GCP only, the largest real spend is missing, and nothing says so. | `pages/monitoring/tokens/index.vue:44` (`PaidItemsCard`); `internal/store/cost_read.go` |
| C3 | **Data entry sits inside a live dashboard.** The paid-items form (add, edit, delete) sits below tables that are polled every 30 s. A form you type into is a bookkeeping task, not monitoring. | `pages/monitoring/tokens/index.vue:44`; `PaidItemsCard.vue` |
| C4 | **The Reporting tab for tokens is a placeholder that points back to Monitoring.** | `pages/reporting/tokens.vue:11` ("See the fleet's token use under Monitoring"); `utils/reporting-tabs.mjs:22` (`ready: false`) |

### 1.2 Mixed periods on one screen

| # | Problem | Where |
|---|---|---|
| P1 | **Costs (a month) carries a "today" card.** For the operator admin, the month page opens with "Fleet tokens today: {tokens} tokens used · {cost}", then a month table under it. | `pages/monitoring/costs/index.vue:34`; `TokensCostsCard.vue:13` |
| P2 | **Tokens mixes four periods.** The window picker gives last hour, today (UTC) or last 24 h. The KPI strip says "today" whatever the window. The effective price uses the last 30 whole days. The paid items use their own paid periods. | `pages/monitoring/tokens/index.vue:18`; `MonitoringTokensSummary.vue`; `EffectivePriceTable.vue:10` (`effective_range` "Last {days} days") |
| P3 | **The month "so far" ends yesterday.** The cost lines' daily feed has no today (spec 140 3.10, measured on prd 10-26), while the today card counts today. The two do not add up, and nothing says why. | spec 140 3.10; `costs/index.vue:29` |

### 1.3 Mixed units and currencies

| # | Problem | Where |
|---|---|---|
| U1 | **EUR twice.** The table has fixed USD and EUR columns, then a "{currency} (day rate)" column whose default is EUR. A reader who never picked a currency sees two EUR columns that may differ: one uses the rate stored at write time, the other each day's rate. | `costs/index.vue:53-55`; `en.json` `col_second`; spec 123 5.4 |
| U2 | **Tokens sit in a money table.** A fleet-tokens part shows $0.00 USD and EUR, its token count in the part's sub-line, and its value in "List price". Read across, "0.00" looks like a free item. | `costs/index.vue:63-71`; `utils/tenant-costs.mjs:369` (mock: `usd 0, units 2.6e9`) |
| U3 | **Two totals in one total row.** The footer sums paid USD and EUR, and beside them the list-price total of tokens. One row, two meanings, no label between them. | `costs/index.vue:84-88` |
| U4 | **The pie leaves out the biggest item.** "Share of the month's cost (USD)" is drawn from paid USD only, so the token value (often the largest figure on the page) is not in it. Tokens are right to stay out. The trouble is that nothing says so. | `en.json:3077`; `costs/index.vue:45` |
| U5 | **Tokens tab currency.** The live tab shows money in the hub's `currency` (USD today: `utils/monitoring-tokens.mjs:60` falls back to USD). The month tab shows USD + EUR + a second currency. The paid items show each item's own currency. The effective price is in USD. Four currency rules across two tabs. | `monitoring-tokens.mjs:60`; `EffectivePriceTable.vue`; `PaidItemsCard.vue` |

### 1.4 Words, sources and who sees what

| # | Problem | Where |
|---|---|---|
| W1 | **One thing, two names.** The column is "Vendor" on Costs and "Agent type" on Tokens. | `en.json:3084` vs `en.json:3130` |
| W2 | **Internal names on screen.** A part reads "Fleet tokens · llm-vendor" and its kind `tokens` / `hours` as stored. "Agent hours" is a count that is never money, yet it gets a "No cost data yet for Agent hours" line every month, forever. | `costs/index.vue:63-65`; `costs/index.vue:41-43` |
| W3 | **The coverage list is plumbing.** "Days complete per source" with partial, missing and not-recorded counts is right for the operator and noise for a workspace member. | `costs/index.vue:119-130` |
| A1 | **The specs contradict each other on who sees token costs.** Spec 143 Poll 4 (owner, 10-17): the Tokens report is for operator admins only. Spec 140 3.10 (owner msgs 1bb1f74b + 96d69790, built SPL-3565, rdb 0229): every workspace role sees its own workspace's token costs. The code follows 3.10 on Costs (`costs.read` for every member) and Poll 4 on Reporting > Tokens (`operatorsOnly`). | `utils/monitoring-tabs.mjs:24` vs `utils/reporting-tabs.mjs:22` |
| A2 | **The help page is stale on who sees Costs.** It says "workspace owners and admins". Since rdb 0229 every member role holds `costs.read`. | `csi-spl-doc/doc/help/monitoring.md:20,55` |

## 2. The new structure under Reporting

### 2.1 The rules every Costs page keeps

1. **"Cost" means money paid, and only that.** The list-price value of
   tokens is called **"list value"** everywhere, and is never added to a
   cost. Effective price is **"price per 1M tokens"**.
2. **One period per page, picked once.** The Costs tab carries one month
   picker in its own header (current UTC month "so far", the 11 before
   it). Every sub-page reads it from `?month=YYYY-MM`, so a switch between
   sub-pages keeps the month. "So far" always says up to which day,
   e.g. "1-26 Oct, today not yet counted".
3. **One money column per table.** A toggle in the Costs header:
   **USD** (what the vendors bill) or **the reader's second currency**
   (Settings, EUR by default, each day at its day rate). The fixed EUR
   column goes. The rate shows in the cell's title, as today.
4. **Tokens never in a money column, money never in a token column.**
5. **One vocabulary**: "agent type" (claude, mistral, grok, agy, qwen) as
   the roster uses it; a source's label, never its stored id.
6. **UTC days** stated once in the header, not per table.
7. **Reading and entering are separate pages.** Forms live on their own
   sub-page, for the operator admin only.

### 2.2 The pages

One Reporting tab, **Costs** (`/reporting/costs`), placed after Releases
and SQL, replacing the reserved Tokens tab. It has four sub-pages, each its
own path and chunk, as Monitoring and Reporting tabs are today:

| sub-page | path | the one question it answers | who sees it |
|---|---|---|---|
| **Spend** (default) | `/reporting/costs/spend` | What did we pay this month, and for what? | every member with `costs.read`: own workspace; operator admin: the estate |
| **Tokens** | `/reporting/costs/tokens` | How many tokens did we use this month, by whom, and what is their list value? | see owner question Q1 |
| **Price per token** | `/reporting/costs/price` | What does 1M tokens really cost us per agent type, against list price? | operator admin |
| **Paid items** | `/reporting/costs/paid` | What subscriptions and top-ups did we pay, for which days? (enter, edit, delete) | operator admin |

**Monitoring keeps only live burn**: the Tokens tab stays at
`/monitoring/tokens` as rate and tokens (last hour, today, last 24 h), the
burn badges and alerts, and no money (owner question Q3 offers the
alternative). The Costs tab, the "Fleet tokens today" card and the Paid
card leave Monitoring.

### 2.3 Spend (default)

- **Rows, grouped by category**, not by stored source:
  - **Cloud**: one row per GCP project (hub, database, hosting, network,
    satellite VM inside it as today's parts).
  - **AI agents**: one row per agent type, the paid items' daily shares in
    the month (new, section 3).
  - **Invoices**: hand-entered lines (once 123 4.4 is built).
  - **Not tracked**: "Machines outside GCP", estate view only.
- **Columns**: name · amount (one currency) · % of the month.
- **Pie** of the same rows, the same currency; "other" under 1 %.
- **A footer line**, never in the table: "Coverage: GCP 26/26 days, AI
  agents 26/26 days" with a link "details" that opens the per-source
  partial / missing list (operator admin only).
- **Workspace view**: its own cost lines. Its token use is *not* here: it
  is on Tokens (rule 4).

Desktop (made-up figures):

```
Reporting  [Releases] [SQL] [Costs]
Costs   Month: [Oct 2026 (so far) v]  1-26 Oct, UTC   Currency: (USD) ( EUR )
        [Spend] [Tokens] [Price per token] [Paid items]
+--------------------------------------+-----------+--------+   .----.
| Part                                 |       USD |  % of  |  /  AI  \
|                                      |           |  month | |  71 %  |
+--------------------------------------+-----------+--------+ | Cloud  |
| AI agents                            |    710.00 |   71 % |  \ 29 % /
|   claude  (subscription)             |    600.00 |   60 % |   '----'
|   mistral (subscription)             |    110.00 |   11 %
| Cloud                                |    290.00 |   29 %
|   hub (Cloud Run)                    |    200.00 |   20 %
|   database (Cloud SQL)               |     70.00 |    7 %
|   hosting + network                  |     20.00 |    2 %
| Machines outside GCP                 | not tracked         |
+--------------------------------------+-----------+--------+
| Total paid, 1-26 Oct                 |  1,000.00 |  100 % |
+--------------------------------------+-----------+--------+
Coverage: Cloud 26/26 days · AI agents 26/26 days   [details]
```

Phone (390 px): the header wraps to two lines (month, currency); each
category is a card whose rows read `name ........ 600.00  60 %`; the pie
goes under the cards at full width; no sideways scroll.

```
Costs            Oct 2026 (so far) v
1-26 Oct, UTC          (USD) ( EUR )
[Spend][Tokens][Price][Paid]
AI agents                 710.00 71%
  claude                  600.00 60%
  mistral                 110.00 11%
Cloud                     290.00 29%
  hub                     200.00 20%
  ...
Total paid               1,000.00
        ( pie, full width )
Coverage 26/26 · 26/26   details
```

### 2.4 Tokens

- **Unit: tokens.** The one money-like column is **list value**, headed
  "List value (not paid)". It never sums into Spend.
- **Rows, three levels**: agent type, then a click opens its agents; for
  the operator admin, a second table **per workspace** (today's
  `workspaces[]`).
- **Columns**: tokens (in + out + cache write) · cache reads · list value
  · days with tokens. agy reads "not metered", grok "not priced", never 0.
- **A small daily bar strip** per agent type over the month (inline SVG,
  as the pie; no chart library).
- Later (spec 143 5.1): a by-category view over the activity tree. Not
  in the first slices.

```
Costs › Tokens   Oct 2026 (so far), 1-26 Oct UTC
+-----------+---------------+-------------+--------------------------+
| Agent type| Tokens        | Cache reads | List value (not paid)    |
+-----------+---------------+-------------+--------------------------+
| > claude  |   1.20 B      |   9.00 B    |   5,400.00 USD           |
| > mistral |   0.30 B      |   0.80 B    |     420.00 USD           |
|   grok    |   0.05 B      |   0.10 B    |   not priced             |
|   agy     |   not metered |             |                          |
+-----------+---------------+-------------+--------------------------+
By workspace (operator admin): workspace · agent type · tokens · list value
```

Phone: one card per agent type, `Tokens 1.20 B · Cache 9.00 B · List
5,400 USD (not paid)` on two lines; the agents open under it.

### 2.5 Price per token (operator admin)

- **The question**: per agent type, the price we really paid per 1M tokens
  in the month, beside the list price of the same days.
- **Columns**: agent type · paid in the month · tokens · price per 1M
  (paid) · list price per 1M · status (`effective`, `list only`, `not
  metered`, `no exchange rate`).
- Period: the picked month (`from` = its first day, `to` = the end of
  "so far"), not a free 30 days.

```
Costs › Price per token   Oct 2026 (so far)
| Agent type | Paid    | Tokens | Paid / 1M | List / 1M | Status       |
| claude     | 600.00  | 1.20 B |   0.50    |   4.50    | effective    |
| mistral    | 110.00  | 0.30 B |   0.37    |   1.40    | effective    |
| agy        |  80.00  |   -    |    -      |    -      | not metered  |
```

Phone: one card per agent type, the two prices side by side in large
type, the rest under them.

### 2.6 Paid items (operator admin)

- Today's Paid card moved as is (list, add, edit, delete, the hub's refusal
  text), with no polling around it.
- One filter: "items that pay for days in the picked month" (default) or
  "all".
- Later, the invoices hand-entry form (123 4.4) as a second section on the
  same page, so every hand entry lives in one place.

```
Costs › Paid items                                   [+ Add a paid item]
| Plan     | Agent type | Kind         | Price of one | Qty | Days paid       |
| Plan A   | claude     | subscription |     200.00   |  3  | 1 Oct - 1 Nov   |
| Top-up B | mistral    | top-up       |     110.00   |  1  | 5 Oct - 5 Nov   |
```

## 3. Data: what feeds each figure

| figure | read from today | exists? |
|---|---|---|
| Spend, Cloud rows | `GET /v1/tenant/costs?month=` parts with source `gcp` (`internal/store/cost_read.go`, `cost_lines`, rdb 0166) | yes |
| Spend, AI agents rows | `fleet_token_paid` daily shares (`fleetPaidDailyUSD`, `store/fleet_token_paid.go`), rdb 0205 | **missing in the month read**: name it `parts` with source `ai_paid`, one per vendor, `usd_micros` = the month's sum of daily shares, `second_micros` like the others; estate scope only |
| Spend, Invoices | `cost_lines` origin `hand`/`invoice` | **missing**: the hand-entry API (123 4.4; `POST /v1/operator/cost/day` refuses origin `hand`) |
| Spend, currency toggle | `usd_micros`, `second_micros` (spec 123 5.4) | yes; `eur_micros` stops being shown |
| Coverage footer | `coverage` of the same read | yes; `ai_paid` needs a coverage rule (a day covered when any item pays for it) |
| Tokens per agent type, workspace view | the month read's `fleet_tokens` parts (spec 140 3.10) | yes |
| Tokens per agent type and per agent, month, operator | `fleet_token_burn_daily` (rdb 0199, per day, box, agent, vendor, model) plus today's minutes | **missing**: a month-range read. Name: `GET /v1/operator/fleet-tokens/range?from=&to=`, answering `by_vendor`, `by_agent`, `by_day`; the 3.5 live read stays as it is |
| Tokens per workspace (operator) | the month read's `workspaces[]` | yes |
| Daily bars | `by_day` of the range read above | missing with it |
| Price per token | `GET /v1/operator/fleet-tokens/effective?from=&to=` (spec 140 3.8) | yes; the page passes the month |
| Paid items | `/v1/operator/fleet-tokens/paid` (GET, POST, PATCH, DELETE) | yes |
| Monitoring live burn | `GET /v1/operator/fleet-tokens?window=` | yes |
| Agent hours | `cost_lines` source `agent_hours` | exists, **not shown** in Spend (a count, never money); see Q4 |

Nothing in this table is invented: the two "missing" reads are named, not
built.

## 4. Migration

### 4.1 Links

- `/monitoring/costs` -> `/reporting/costs/spend` (query `?month=` kept),
  through the same pattern as `legacyMonitoringPath`
  (`utils/monitoring-tabs.mjs`, `components/LegacyMonitoringRedirect.vue`).
- `/reporting/tokens` -> `/reporting/costs/tokens`.
- `/reporting/costs` -> `/reporting/costs/spend`.
- `/monitoring/tokens` stays (live burn).

### 4.2 What moves, what goes

| item | today | after |
|---|---|---|
| `pages/monitoring/costs/index.vue` | Monitoring > Costs | becomes the Spend page (rewritten to 2.3) |
| `MonitoringCostsPie.vue` | costs route chunk | Spend's chunk, renamed `CostsPie.vue` |
| `TokensCostsCard.vue` | top of Costs | **removed** |
| `PaidItemsCard`, `PaidItemForm` | Monitoring > Tokens | Paid items page |
| `EffectivePriceTable.vue` | inside the Paid card | Price per token page |
| Monitoring > Tokens KPI "Today's fleet cost" and cost columns | money | removed (or renamed "list value", Q3) |
| `monitoring-tabs.mjs` `costs` row | ready | removed (the redirect stays) |
| `reporting-tabs.mjs` `tokens` row | reserved | replaced by `costs` |
| the EUR column | fixed | removed; the currency toggle |
| help `monitoring.md` Costs section | | moves to a `reporting.md` Costs section; fixes A2 |

### 4.3 Slices (each one small lane, its test)

Hub slices first, so the pages can read real data; WUI slices go to claude
or grok (developer guide 5.1).

| # | slice | test |
|---|---|---|
| S1 | wui: Reporting tab `costs` + the 4 sub-page routes as empty shells, the month picker and currency toggle in the tab header, `?month=` shared; redirects 4.1 | unit: `reporting-tabs.test` (visibility per role), redirect table; e2e: `/monitoring/costs?month=2026-09` lands on `/reporting/costs/spend?month=2026-09` |
| S2 | wui: Spend page from today's read: one currency column, category grouping, no token rows, coverage footer; old Monitoring Costs tab removed | unit: grouping + no `fleet_tokens` row in Spend; e2e 1400 + 390 px; red control: a `fleet_tokens` part in the mock shows in no Spend row |
| S3 | hub: the month read adds `ai_paid` parts from `fleet_token_paid` (estate scope) | store test on Postgres: 1 item of 30 days, month of 31 -> the right share; a workspace scope gets none (RLS) |
| S4 | wui: Spend shows the AI agents group from S3 | unit + e2e with the mock's `ai_paid` |
| S5 | wui: Paid items page (move), Price per token page (move, `from`/`to` from the month) | e2e: the paid round of `monitoring-costs.test.mjs` moved to the new path |
| S6 | wui: Monitoring > Tokens without money (or renamed, per Q3); `TokensCostsCard` removed | unit: no `kpi_cost` key read by the tab; e2e |
| S7 | hub: `GET /v1/operator/fleet-tokens/range` from the daily rollup + today's minutes | store test: a day in both the minutes and the rollup is counted once; operator-only 403 |
| S8 | wui: Tokens page (agent type, agents, per workspace, daily bars) over S7 and the month read | unit + e2e 1400 + 390 px |
| S9 | doc: help `reporting.md` Costs section, `monitoring.md` trimmed; i18n keys for 19 locales, agy review last (language rule) | `i18n-parity`, help-coverage |

## 5. Open questions for the owner

1. **Q1: who sees the Tokens page?**
   - A: every member sees their own workspace's token use and list value;
     the operator admin sees all (spec 140 3.10, as built).
   - B: operator admins only (spec 143 Poll 4).
   - Recommendation: **A**. It is the newer owner order (10-26 after
     10-17) and the code already serves it on Costs. Poll 4 is then
     marked superseded in spec 143.
2. **Q2: the money unit on Spend.**
   - A: one column with a USD / second-currency toggle (default USD).
   - B: one column in the second currency only.
   - C: keep USD + EUR + second currency (today).
   - Recommendation: **A**. One number per row, and the toggle keeps the
     vendors' own currency one click away.
3. **Q3: does Monitoring > Tokens keep any money?**
   - A: no money; tokens and rates only, and a link to Reporting.
   - B: keep today's list value, renamed "list value (not paid)".
   - Recommendation: **A**. Monitoring answers "is something burning
     now?", and tokens per minute answer it.
4. **Q4: agent hours.**
   - A: drop them from the Costs pages (a count, never money).
   - B: show them on Tokens as one more column.
   - Recommendation: **B**. They are what the subscription split per
     agent uses (spec 123 2.4).
5. **Q5: one Costs tab with sub-pages, or four Reporting tabs?**
   - A: one Costs tab, four sub-pages (this proposal).
   - B: Spend, Tokens, Price and Paid as four top-level Reporting tabs.
   - Recommendation: **A**. It keeps the month and the currency in one
     header, and the Reporting bar stays short on a phone.

<!-- last-edit: 2026-10-27 · seat c-275 (claude, mistral slot) · SPL-3790 -->
