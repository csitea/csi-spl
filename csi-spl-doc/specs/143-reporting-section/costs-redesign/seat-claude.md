# Costs under Reporting: the claude seat's proposal

Issue SPL-3789 · Epic SPL-2389 · Spec [143](../spec.md) · Panel of 2 seats,
this is the claude seat (the editor, c-385). Written before reading the
mistral seat's file. Doc only: nothing here is built.

The ask (HUM-10, t1 topic `1be0e370`, msg `7503412e`): "The costs tab in
monitoring should be part of the reporting tab, and the whole costs need
major refactoring with a panel of experts first. It should be organized much
better. It's pretty confusing."

Every `file:line` was read on origin/master `5034f89d9` (2026-10-27). Paths:
`wui/` = `csi-spl-wui/src/`, `hub/` and `store/` =
`csi-spl-api/src/go/spool-hub-api/internal/{hub,store}/`. Every figure in a
wireframe below is made up; none is a real cost.

## 0. What I looked at

- **Code**: `wui/pages/monitoring/costs/index.vue`,
  `wui/pages/monitoring/tokens/index.vue`, `wui/components/MonitoringCostsPie.vue`,
  `wui/components/monitoring/token-burn/*` (TokensCostsCard, MonitoringTokensSummary,
  VendorBurnTable, AgentBurnTable, PaidItemsCard, EffectivePriceTable),
  `wui/pages/reporting/*`, `wui/utils/{monitoring,reporting}-tabs.mjs`, the
  English strings in `csi-spl-wui/i18n/locales/en.json` (`monitoring.costs.*`,
  `monitoring.tokens.*`), `hub/{cost_read,fleet_tokens,fleet_token_paid,categories}.go`,
  `store/fleet_tokens.go`.
- **Specs**: 123 (cost tracking), 140 (token burn, 3.5, 3.8-3.10), 143
  (Reporting), 153 (Monitoring Lanes tab).
- **Dev, live** (2026-10-27 ~10:09Z, headless Chrome, 1400 px and 390 px,
  signed in as the dev probe member of workspace t1, a plain member, n = 1
  look each):
  - `https://dev.spool-hub.ai/monitoring/costs`: tabs "Agents Boxes Events
    Costs"; "Month 2026-10 (so far)", the picker listing 12 months back to
    2025-11; "So far: 26 of 31 days"; "This workspace"; "No cost data yet
    this month, so no pie."; a table headed "Part · USD · EUR · EUR (day
    rate) · % of month · List price"; "No cost lines this month."; "Total
    $0.00 €0.00 €0.00".
  - `https://dev.spool-hub.ai/monitoring/tokens`: the Tokens tab is not in the
    bar, but the direct URL draws "Window: Last hour / Today (UTC) / Last 24
    hours", a "Refresh" button, then "Only an admin of the operator workspace
    sees the fleet's token burn."
  - `https://dev.spool-hub.ai/reporting/releases`: only "Releases" in the
    Reporting bar (KPI strip "Releases 225 · Commits 723 · Commits per day
    103.3 · Deploys 239 on dev, 181 on prd").
  - `https://dev.spool-hub.ai/reporting/tokens`: "This report is for operator
    admins only."
- **Not seen live**: the operator admin's estate view and the Tokens page
  with data. No operator-admin login exists for a lane on dev; for those two
  I read the code and the mock (`wui/utils/tenant-costs.mjs` mock,
  `wui/utils/monitoring-tokens.mjs` mock). Say so wherever it matters.

## 1. What confuses today

Each item: what the reader sees, where, why it confuses.

| # | the problem | where |
|---|---|---|
| P1 | **Money really paid for AI vendors is not in the Costs total.** Subscriptions and top-ups are entered in the Paid card of Monitoring > Tokens (`fleet_token_paid`), but the Costs read never reads that table: `grep -l 'fleet_token_paid\|FleetPaid' hub/cost_read.go store/cost_read*.go store/workspace_tokens.go` -> nothing. So the "Total" on Costs leaves out what is, for this estate, a main cost. The Costs "Invoices" source (`monitoring.costs.source.hand`) has no form at all (spec 123 5.3 "Not built yet"). | `wui/pages/monitoring/costs/index.vue:82-89`; `wui/components/monitoring/token-burn/PaidItemsCard.vue:1-9` |
| P2 | **The same tokens carry two different "cost" figures.** Tokens says "Today's fleet cost" and "Today's cost" (a list-price figure); Costs shows the same fleet tokens with USD $0.00 and the list price in a separate "List price" column (subscription tokens are never a paid amount, spec 123 Q-4). One reader sees "$42 today" on one tab and "$0.00" on the next for the same work. | `MonitoringTokensSummary.vue:18-21`, `VendorBurnTable.vue:17,41-44`, `costs/index.vue:57,71` |
| P3 | **Three money columns, two of them the same currency.** "USD · EUR · EUR (day rate)": the fixed EUR column and the second-currency column both read EUR for every reader who kept the default. Seen on dev: "Total $0.00 €0.00 €0.00". | `costs/index.vue:53-55`; dev 1400 px |
| P4 | **Four different periods on the money screens, unlabelled as such.** Costs: a calendar month UTC "so far". Tokens: a window picker (last hour / today UTC / last 24 h) that only chooses which lanes are listed, while every figure stays "today since 00:00 UTC" and the rate is the last 5 minutes (`store/fleet_tokens.go:269-284`: `seenWindow` gates the row, the sums use `f.today`). Effective price: "last 30 whole days". The card on Costs: today. Picking "Last 24 hours" and reading "Today's tokens" is the clearest single trap. | `tokens/index.vue:16-21`; `EffectivePriceTable.vue:10`; `TokensCostsCard.vue:13` |
| P5 | **Mixed units in one table.** One Costs row is dollars (GCP), the next is a token count with $0.00 (fleet tokens), the next agent-seconds with $0.00 (agent hours); the `units` sit in small grey text under the part name. The pie only counts money, so a row that dominates the table by size is absent from the pie. | `costs/index.vue:62-66`; spec 123 5.3 "Honest empties" |
| P6 | **Two token sources under one label.** The estate's "Fleet tokens" rows come from the nightly transcript reader (`cost_lines`, origin `transcript`, no today); a workspace's "Fleet tokens" rows come from the minute collector (`fleet_token_burn_events`, spec 140 3.10). Same label, different counts, different freshness. | spec 140 3.10 "Read"; spec 123 4.3 |
| P7 | **Paid items and the price per token live on a live monitoring page.** The Paid card (a data-entry form) and the effective price (a 30-day report) sit under a page that polls every 30 s for live burn. They are neither live nor monitoring. | `tokens/index.vue:43-44` |
| P8 | **Who sees what is uneven and partly stale.** Costs: every member role (rdb 0229); Tokens, Paid, Effective: operator admin only; Reporting > Tokens: reserved, operator only, and it links back to Monitoring. The 403 sentence still says "workspace owner or admin" (`monitoring.costs.forbidden`) and the help page says "visible to workspace owners and admins" (`grep -n 'owners and admins' csi-spl-doc/doc/help/monitoring.md` -> 2 lines), both untrue since 0229. | `monitoring-tabs.mjs:24,26`; `reporting-tabs.mjs:22`; `pages/reporting/tokens.vue:11` |
| P9 | **Controls for a page you cannot see.** A non-operator who opens `/monitoring/tokens` gets the window picker and Refresh above the 403 sentence (dev, quoted in 0). | `tokens/index.vue:15-24,33` |
| P10 | **The month picker offers months with no data.** 12 months back to 2025-11; cost lines start in October 2026 (spec 140 3.10: "Every October `cost_lines` row"). Eleven picks read "No cost lines this month". | `wui/utils/tenant-costs.mjs:233-241` |
| P11 | **The workspace burn table hides at the bottom.** The operator's "Token costs per workspace" (tokens and list price per workspace and vendor) sits under the main table, after the total, in a different unit. | `costs/index.vue:94-117` |
| P12 | **Coverage is jargon.** "Days complete per source · 26 of 31 days complete · 2 partial · 1 not recorded" with no word on what it changes in the total. | `costs/index.vue:119-130` |

The root of P1-P6: **one page mixes three questions**: what did we pay
(money), how much did we use (tokens), and what is a token worth (a ratio).
Each has its own source, unit and period.

## 2. The new structure under Reporting

### 2.1 One Costs tab, four pages, one question each

The reserved Reporting tab `tokens` (`reporting-tabs.mjs:22`, `ready: false`)
becomes **`costs`**: `/reporting/costs`, label "Costs", landing on its first
page. The Costs tab has its own second row of page links (the Monitoring
pattern, one path per page, each its own chunk).

| page | path | its one question | unit | who |
|---|---|---|---|---|
| **Spend** | `/reporting/costs/spend` | What did we pay in this period, and for what? | money only (USD + the reader's second currency) | `costs.read` (every member role: its workspace; operator admin: the estate) |
| **Usage** | `/reporting/costs/usage` | How many tokens did we use, by whom, on what work? | tokens only; list price shown as "list value", never as paid | workspace: its own lanes' tokens; operator admin: every lane, every workspace, by category |
| **Unit price** | `/reporting/costs/unit-price` | What does one million tokens really cost us, against the list price? | money per 1M tokens | operator admin |
| **Paid items** | `/reporting/costs/paid` | What have we bought (subscriptions, top-ups, invoices)? Enter and correct them. | money, per item | operator admin (write); the item list is the source of Spend's AI rows |

Rules for all four:

- **One period picker for the section**, carried in the URL (`?period=2026-10`
  or `?from=2026-10-01&to=2026-10-28`) so a link and the back button keep it:
  `This month (so far)` (default) · a past month · `Last 7 days` · `Last 30
  days` · `Custom`. All days UTC, the label says "UTC". The months offered
  start at the first month that holds a cost line (fixes P10).
- **A page answers in one unit family.** Money pages never show a token
  count as a row; the token page never shows a "cost" that was not paid
  (its list figure is labelled "list value (not paid)").
- **Two money columns at most**: USD (what vendors bill) and the reader's
  second currency (Settings > Appearance, default EUR). The fixed EUR
  column goes; if the reader's pick is USD, one column (fixes P3).
- **Every empty or partial figure says why** in words, beside the figure:
  "3 days not read yet, the total may grow" replaces the coverage list (P12).
- **Phone**: each table row becomes a card (the pattern that exists,
  `costs/index.vue:233-242`), the period picker a single select.

### 2.2 Spend: "What did we pay?"

Rows grouped in three blocks, a subtotal each, one total:

1. **Cloud** (GCP billing export per project; `cost_lines` origin
   `billing_export` / `estimate`).
2. **AI vendors** (subscriptions and top-ups from Paid items, spread per day
   over their period, the rule spec 140 3.8 already uses; metered API keys
   once spec 121 ships).
3. **Other** (hand-entered invoices; "Machines outside GCP: not tracked").

A pie of the blocks (three slices max, then its rows as a bar list), and a
"per day" bar strip of the total. Agent hours and token counts are NOT here.

Desktop (made-up figures):

```
Reporting  [Releases] [SQL] [Costs] ...
Costs:  (Spend)  Usage  Unit price  Paid items          Period [This month (so far) v]  UTC
-------------------------------------------------------------------------------------------
 Total so far   $1,234.00   €1,140.00        26 of 31 days read · the total may grow
 [pie: Cloud 22% | AI vendors 74% | Other 4%]   [per-day bars ▁▂▃▂▅▃▂ ...]
-------------------------------------------------------------------------------------------
 Part                          USD        EUR (day rate)   % of total
 Cloud                       $271.00        €250.00          22 %
   csi-spl-prd · Cloud Run    $120.00        €111.00
   csi-spl-prd · Cloud SQL    $101.00         €93.00
   csi-spl-all · VM           $50.00          €46.00   estimate
 AI vendors                  $913.00        €843.00          74 %
   Vendor A · subscription   $800.00        €739.00   26 of 31 days
   Vendor B · top-up         $113.00        €104.00
 Other                        $50.00         €46.00           4 %
   Invoice · domain           $50.00         €46.00   entered by hand
   Machines outside GCP       not tracked
 Total                     $1,234.00      €1,140.00         100 %
```

Phone (390 px):

```
Costs  [Spend v]            (page select)
[This month (so far) v]  UTC
Total so far  $1,234.00 · €1,140.00
26 of 31 days read · may grow
[pie]
┌ Cloud ············ $271.00 · 22 % ┐
│ csi-spl-prd · Cloud Run  $120.00   │
│ ...                                │
└────────────────────────────────────┘
┌ AI vendors ······· $913.00 · 74 % ┐
...
```

A workspace (not the operator) sees the same page with its own rows only:
today that is its hand rows, if any, and its share of AI vendors only once
question Q3 (section 5) is answered; until then the block reads "AI vendor
costs are paid by the operator; your usage is on the Usage page".

### 2.3 Usage: "How many tokens, by whom, on what?"

KPI strip: tokens in the period · of which cache reads · list value (not
paid) · lanes that reported. A "group by" picker: **vendor** (default) ·
agent lane · workspace (operator only) · activity category (operator only,
the spec 143 4 tree, `GET /v1/reporting/tokens/by-category`). A per-day
stacked bar. Agent hours (agent-seconds per vendor) are a second small
table here, since they are usage, not money.

```
Costs:  Spend  (Usage)  Unit price  Paid items       Period [Last 30 days v]  UTC
Tokens 412.0M   cache reads 61 %   list value $3,020 (not paid)   lanes 48
Group by: (Vendor) Agent lane  Workspace  Category
 Vendor      Tokens     Cache reads   List value (not paid)   Days   Agent hours
 Vendor A    350.0M        63 %            $2,700              30      410 h
 Vendor B     52.0M        48 %              $320              30       95 h
 Vendor C     10.0M         —            not priced            12       40 h
 Vendor D       —           —            not metered            9       30 h
[per-day stacked bars]
```

Phone: the strip as 2x2 tiles, the table as cards, "Group by" a select.

### 2.4 Unit price: "What does a token really cost us?"

The existing effective-price table (`EffectivePriceTable.vue`), moved, on the
section's period instead of its fixed 30 days, plus one line per vendor:
"paid $X for Y tokens = $Z per 1M; list $W per 1M". Status words stay
(not metered, not priced, no exchange rate).

### 2.5 Paid items: "What did we buy?"

The existing Paid card (`PaidItemsCard.vue` + `PaidItemForm.vue`), moved, as
its own page, with the hand-entered invoices (spec 123 4.4) as a second
kind of item once their API exists (`kind`: subscription · top-up ·
invoice). Each item shows its period and "counted in Spend from <day> to
<day>". Edits never rewrite a closed month (spec 123 4.4: a new row
supersedes).

### 2.6 What Monitoring keeps

Monitoring answers "what is happening now". It keeps **Tokens as live burn
only**: the burn rate (tokens/min, 5-minute mean), the last minute, live
lanes per vendor and per agent, the stale badge. It drops: the "Today's
fleet cost" KPI and the "Today's cost" columns (money moves to Reporting),
the window picker (P4: the window only filtered rows; replace it with
"lanes active in the last hour / all lanes today" as a plain toggle), and
the Paid card. The Costs tab leaves Monitoring.

Phone and desktop of Monitoring > Tokens are unchanged apart from the
removed columns (spec 140 4.2 layout and the SPL-2476 panel plan).

## 3. Data: what feeds each figure

| figure | source today | gap |
|---|---|---|
| Spend · Cloud rows | `GET /v1/tenant/costs` parts with source `gcp` (`cost_lines`, `hub/cost_read.go:123`) | none |
| Spend · AI vendor rows | `fleet_token_paid` via `GET /v1/operator/fleet-tokens/effective?from&to` (its `items` and `paid_usd` per vendor) | **missing**: the Costs read does not include paid items (P1). Name: `GET /v1/tenant/costs` adds parts with source `paid`, from `fleetPaidDailyUSD` (`store/fleet_token_paid.go`), operator scope only |
| Spend · Other (hand invoices) | none | **missing**: the hand-entry API (spec 123 4.4; `POST /v1/operator/cost/day` refuses origin `hand`) |
| Spend · period other than a calendar month | `GET /v1/tenant/costs?month=` only | **missing**: `from`/`to` on the Costs read |
| Spend · second currency | `second_micros`, `fx_rate*` in the Costs read (spec 123 5.4) | none |
| Spend · days read | `coverage` in the Costs read | none |
| Usage · estate per vendor / agent per period | `fleet_token_burn_daily` + minutes; today only through `GET /v1/operator/fleet-tokens` (windows 1h, 24h, today) | **missing**: a period read, `GET /v1/reporting/tokens?from&to&by=vendor|agent|workspace` over the daily rollup (365 days kept, spec 140 3.6) |
| Usage · per workspace | `workspaces` in the operator's Costs read (spec 140 3.10), month only | covered by the period read above |
| Usage · a workspace's own lanes | its `fleet_tokens` parts in `GET /v1/tenant/costs` (spec 140 3.10) | moves to the period read, workspace scope |
| Usage · by category | `GET /v1/reporting/tokens/by-category?from&to&depth` (`hub/categories.go:81`) | none (operator only today) |
| Usage · agent hours | `cost_lines` source `agent_hours.<box>` (counts) in the Costs read | none (shown on Usage instead of Spend) |
| Unit price | `GET /v1/operator/fleet-tokens/effective?from&to` (`hub/fleet_token_paid.go:55`) | none |
| Paid items | `GET/POST/PATCH/DELETE /v1/operator/fleet-tokens/paid` | none |
| Monitoring live burn | `GET /v1/operator/fleet-tokens` | none |

Nothing above is invented: each "missing" line is a hub change with its own
slice.

## 4. Migration

**Redirects** (in `legacyMonitoringPath`, `monitoring-tabs.mjs`, the
SPL-2075 pattern): `/monitoring/costs` -> `/reporting/costs/spend`, keeping
`?month=` as `?period=`; `/reporting/tokens` -> `/reporting/costs/usage`.
`/monitoring/tokens` stays (live burn).

**Moves**: Costs page -> Spend; Paid card -> Paid items; effective price ->
Unit price; workspaces table -> Usage (group by workspace); agent hours ->
Usage. **Removed**: the fixed EUR column; the TokensCostsCard on Costs (its
figures are on Usage); the money columns and the Paid card on Monitoring >
Tokens; the empty months in the picker; the "workspace owner or admin"
wording.

**Slices** (each one small task, one issue, its test):

| # | area | slice | test |
|---|---|---|---|
| S1 | wui | `costs` tab in `reporting-tabs.mjs` (replaces reserved `tokens`), the Costs second-row bar, `/reporting/costs` -> `spend`; redirects of `/monitoring/costs` and `/reporting/tokens` | `tests/unit/reporting-tabs.test.mjs` (visibility per role, redirect map; red: a member without `costs.read` sees the tab) |
| S2 | wui | Spend page = today's Costs page moved, blocks Cloud / AI vendors / Other, one second-currency column, months from the first cost line; Monitoring Costs tab removed | `tests/e2e/monitoring-costs.test.mjs` renamed `reporting-costs-spend`, 1400 + 390 px; `tenant-costs.test.mjs` |
| S3 | api | Costs read adds `paid` parts from `fleetPaidDailyUSD` (operator scope) | `TestCostReadPaidParts` (Postgres; red: an item in range missing from the total) |
| S4 | api | Costs read takes `from`/`to` beside `month` | `TestCostWindow` extended |
| S5 | api | `GET /v1/reporting/tokens?from&to&by=` over minutes + daily rollup, workspace and operator scope | `TestReportingTokens*` (Postgres, RLS: a workspace never sees another's lanes) |
| S6 | wui | Usage page on S5 + by-category | unit + e2e 1400/390 px |
| S7 | wui | Unit price page (EffectivePriceTable moved, on the section period) | e2e |
| S8 | wui | Paid items page (PaidItemsCard moved); removed from Monitoring > Tokens | e2e paid round moved |
| S9 | wui | Monitoring > Tokens: money columns and KPI removed, window picker -> active/all toggle, no controls above a 403 | `monitoring-tokens.test.mjs`; e2e |
| S10 | api+wui | hand-entered invoices (spec 123 4.4) as a Paid items kind | its own spec slice; only after the owner's Q4 |
| S11 | doc | help pages (`monitoring.md`, a new `reporting.md` Costs section), spec 123 5.3 and 140 4 pointers, the 403 wording | doc review |

S1+S2 alone already answer the owner's first sentence (Costs out of
Monitoring into Reporting); S3 fixes the biggest wrong figure (P1).

## 5. Open questions for the owner

1. **Q1: How many pages under Reporting > Costs?**
   (A) Four: Spend, Usage, Unit price, Paid items (recommended: one question
   per page). (B) Two: Spend (with Paid items inside) and Usage (with the
   unit price inside). (C) One long page with the four as sections.
2. **Q2: Does Monitoring > Tokens keep any money figure?**
   (A) No: live tokens only, all money in Reporting (recommended: removes P2
   at its root). (B) Keep one "list value per hour" figure, labelled "not
   paid". (C) Keep today's columns as they are.
3. **Q3: What does a customer workspace see on Spend?**
   (A) Its own hand rows only, its token use on Usage (recommended until
   there is a billing model). (B) A share of the AI subscriptions, split by
   its lanes' tokens. (C) Nothing: Spend is operator-only, a workspace gets
   Usage only.
4. **Q4: Hand-entered invoices (domain, other services):**
   (A) Build them as a Paid items kind now (recommended: the "Other" block
   is empty without it). (B) Later, after S1-S9.
5. **Q5: The default period:** (A) This month so far (recommended: the
   owner's "monthly basis", spec 123 msg f99ea7d8). (B) Last 30 days.
