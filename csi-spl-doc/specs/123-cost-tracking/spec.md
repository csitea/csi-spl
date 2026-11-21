# Spec 123: Cost Tracking

**Status:** v1.7 + 16.6 v1.0 (2026-11-22: 16.6 rewritten as built from rows L0-L6 on 49f34bef6, 16.5 states the write rule; open: the hub env wiring row L3w, the L0 applies and price, the agy n = 20 measurement; SPL-6220) · v1.7 (2026-11-20: row P02 built, the Human part from 107's tables; SPL-6075) · v1.6 + 16.6 v0.4 (2026-11-20: every owner answer folded, the follow-ups 1 `a`, 2 `m`, 3 `g` included, msg baae5fb7: the hub drafts through Google Cloud Translation in its own project with names masked, readers see the draft at once, agy corrects it nightly; new row L0 for the API and its role; SPL-6057) · 16.6 v0.3 (2026-11-20: the owner's answers 3 `1d`, 4 `mc` and 5 `t` folded, msg e9f8e835; answers 1 and 2 wait for the holder's follow-ups, msg 5a82621d; SPL-6057) · 16.6 v0.2 (2026-11-20: the spec review's notes N1-N3 folded: L4 asserts agy sees the mask token, the machine write keys an hr component apart with its own guard, the PATCH's reach follows owner question 5; SPL-6057) · 16.6 v0.1 (2026-11-20: 16.6, every new or edited cost label translated into all 19 languages on save, design only, for review; SPL-6057) · v1.6 (2026-10-30: the owner's Q-8 A and Q-9 A folded into section 13, msg 4316d471: the project's cost is a fifth Costs page, first and the default; a customer workspace gets its own project cost, its AI share + its own people, no cloud part; SPL-4368) · v1.5 (2026-10-30: 5.5, the Cloud, AI tokens and Human sections, with its R7 folded: an act-as clone of the operator admin reads 403 on the cloud days and the workspace answer of the month read; SPL-4187) · v1.4 (2026-10-29: R7 re-review W1: the 13.9 masked-viewer case counts owned hardware in the total, as 13.6 and P03; SPL-4189) · v1.3 (2026-10-29: R7 review W1..W7 folded: owned hardware is the fourth part of the project-cost read, one hand-entered kind only, files disjoint per batch, Q-10 dropped as decided by 107 Q27 A; SPL-4189) · v1.2 (2026-10-29: 13.12, owned hardware written off monthly, monthly and yearly totals first, the untracked-cost list; SPL-4189) · v1.1 (2026-10-29: section 13, the project's cost, plan only, SPL-4189) · v1.0 (draft ff04d3ca3 by a-816, folded by the editor
s123-claude from the four seat reviews in `reviews/`; rc1 cc831a665 signed by
all four seats and the drafter; the owner's answers Q-1..Q-7 folded, section 12)

## 1. Owner's Words

Topic `t1 #spool-hub-devel`, task `af4bbf51-62f5-4f04-adcd-79d3b8b044ec` (HUM-10), verbatim:
- msg `a798a19b`: "Create in the Spool Hub discussion for a new feature which is called cost tracking. This feature should start tracking the costs of the whole Spool Hub AI cloud instance, including the tokens and the AI agents. We must gather data for at least 1 month: how much all of this pleasure costs."
- msg `45f8cb69`: "Yes, both the admin and the business owner must have access to a page which also has a pie chart, but a simple table split down on what everything costs."
- msg `f99ea7d8`: "And this table should be updated on a monthly basis."
- msg `b046544e`: "Some of the costs might be insertable by hand, but, for example, the costs of paying the tokens, and so on and so forth."
- The answers to Q-1..Q-7 (msgs `9bb60e73`, `cef45738`, `4671d819`, `6078c151`, `c48f7aa2`, `6fc78646`) are quoted in section 12.

## 2. Cost Sources (What is tracked)

To see how much the entire AI cloud instance costs, we track every cost source across all environments:
1. **GCP Estate**: All resources in every `csi-spl-*` GCP project (Q-2: today `csi-spl-dev`, `csi-spl-prd` and `csi-spl-all`; a new `csi-spl-*` project is counted without a code change), one row per project and per label (`box=satellite`, `box=pool`). This includes Cloud Run (hub), Cloud SQL, Firebase Hosting, network egress, and the satellite VM (060). Cost tracking counts all three projects; the owner's b6a56949 ("the production environment and the hosts on which the workspace runs") sets what the PRICE slice of 121/122 counts, not what is tracked here.
2. **LLM Tokens**: Token consumption across all AI agents, sliced per agent, per workspace, per vendor and per model. Two kinds, read differently (section 3):
   - **fleet tokens**: the fleet's own lanes (c-, g-, a-, q-, m-) on subscriptions. Today this is almost all of the token volume (121 section 7: "our own work stays on subscriptions"). They never pass through the hub ledger: they are in each box's transcript files.
   - **metered tokens**: hub-dispatched turns on pay-per-token API keys (121 section 7), once 121 phase 3 ships.
3. **Agent Subscriptions vs API Keys**: Fixed-cost subscriptions (the vendor invoice amount) and pay-per-token API keys. A subscription's cost is its invoice; its token volume has a list-price equivalent, shown beside it, never added to it (Q-4).
4. **Agent-hours**: The time agents run, used to split a vendor's subscription per agent on the page, never as a price.
5. **Machines outside GCP** (boxes that are not GCP VMs): not tracked for now, listed on the page as "not tracked" (Q-7). The readers sit behind one cost-source interface (section 4.6), so a box source plugs in later.

## 3. How Each is Read

Measured on origin/master at ff04d3ca3, 2026-10-10 (reviews s123-claude section 2, s123-claude-2 section 2).

| Cost Source | Read From | Read By | Evidence |
|---|---|---|---|
| **GCP Estate** | GCP billing export to BigQuery, per usage day | a separate background reader with its own SA, `roles/bigquery.dataViewer` on the export dataset only, rows of every project in the export (`project.id LIKE @like`, cnf `env.cost.gcp.project_like` = `%` since SPL-4187: the owner adds his other projects to the export; a `<prefix>%` narrows it) (Q-2), never the owner account | `sed -n 245,252p csi-spl-doc/specs/047-spool-deployability/deployability-analysis.md` -> "Cloud Billing API has not been used in project ... or it is disabled": the per-env SAs cannot read billing (n = 1, 2026-09-28) |
| **Fleet tokens** | each lane's Claude Code transcript, `.message.usage` per assistant message | `do_spl_cost_tokens_read`, on each box (section 4.3) | `git grep -n cache_read_input_tokens origin/master -- csi-spl-orc` -> `spl-lane-restart.func.sh:279` already reads it |
| **Fleet tokens, other vendors** | not measured yet (agy, mistral, grok, qwen) | the same action, once each CLI's usage record is measured | until then one `unmetered` row per agent-day, never 0 |
| **Metered API tokens** | 121 `usage_events` (not built) | the hub rollup | `git grep -l usage_events origin/master -- . ':!csi-spl-doc'` -> 0 files |
| **Provider usage (token gap)** | provider usage report | 122 M4 `do_spl_token_gap_measure` (not built) | same grep -> 0 files |
| **Agent Subscriptions** | the vendor invoice, hand-entered | the operator form (section 4.4) | flat monthly fees |
| **Agent-hours** | the lease tick's run report `dispatch/agent-run.tsv` | `do_spl_cost_agent_hours_read` (section 4.3) | `git grep -n agent-run.tsv origin/master -- csi-spl-orc/src/bash/run` -> `spl-dispatch-lease.func.sh:618,622` |
| **Non-GCP machines** | not tracked (Q-7) | a future source behind the 4.6 interface | listed as "not tracked" |

What exists on the billing side: `csi-spl-iac/src/terraform/059-gcp-satellite-budget/` sets a `google_billing_budget` on csi-spl-all through the csi-spl-all SA (`01-providers.tf` comment: "the budget API is called with the csi-spl-all SA key"). It only alerts by mail; it is not a read source.

## 4. Storage and Daily Rollup

### 4.1 One table for every cost line

- **`cost_lines`** (replaces the draft's `cost_rollup_daily`, same role): `(day, source, project_or_vendor, workspace_id NULL, agent_id NULL, model NULL, kind, units, amount_micros, currency, usd_micros, eur_micros, fx_rate_day, list_value_micros NULL, origin, run_id, read_at, superseded_by NULL)`.
  - `origin` in `billing_export | metered | transcript | agent_run | invoice | hand | estimate`.
  - UNIQUE on `(day, source, project_or_vendor, workspace_id, agent_id, model, kind)`, written with UPSERT (`ON CONFLICT`).
  - `amount_micros` + `currency` is what was paid; `usd_micros` and `eur_micros` are the two report figures (Q-6), converted at the rate of `fx_rate_day` (the invoice or usage day); `list_value_micros` is the API list-price equivalent of subscription tokens (Q-4).
  - The month table and the pie are one `GROUP BY` over it. 122's `estate_cost_months` becomes a view over the GCP rows, not a second copy.
- **`cost_coverage`**: one row per `(day, source)`, `ok | missing | partial` with the reason. A source that failed a day is visible, never summed as 0 (the 121 `unmetered` rule).
- RLS: estate rows in operator scope (the operator workspace); workspace-keyed rows readable by that workspace (section 5.1). The NULLIF policy pattern and its isolation test.
- DDL first, dev and prd before the code (repo rule). Last migration today: `ls csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1` -> `0164_workspace_doc_description.sql`.

### 4.2 GCP read

- `do_gcp_billing_export_setup` (owner, once, dry run by default) and the reader `do_spl_estate_cost_read`, as 122 section 9 specifies them, are built by 123 (section 9, lane 2): one BigQuery reader, writing daily `cost_lines` rows with `origin=billing_export`. 122 then reuses them.
- **Where the export is** (SPL-3376, owner HUM-10 poll fe5d4bfb answer A): the owner set the export up in `csi-spl-prd` / `csi_spl_prd`, cnf `cost.gcp.export_source_project` / `export_source_dataset`. The reader finds its `gcp_billing_export_v1_*` table there by prefix (the billing account id stays out of git) and queries it as the reader SA, whose home and query jobs stay in `cost.gcp.export_project` (`csi-spl-all`). The setup's one grant on that dataset is `roles/bigquery.dataViewer` for the reader, made as the `csi-spl-prd` SA.
- **Late and revised rows**: the export lags and revises recent days (lateness measured during the month, n stated). The nightly run re-reads a trailing window (cnf `cost.reread_days`, start 5) with UPSERT.
- Until a closed month of export data exists, GCP rows carry `origin=estimate` from 047 section 4.2, marked so on the page.

### 4.3 Box-side readers

- **`do_spl_cost_tokens_read DAY=<utc day>`** (csi-spl-orc, read-only), run by each box's cron: sums every lane transcript's usage for the day per agent id, vendor, model, `service_tier` and kind. It writes a day file under the fleet root and posts it to an operator endpoint (`operatorAuth`); the hub upserts `cost_lines` with `origin=transcript`.
  - **Dedupe per `message.id`, take the max.** Measured (s123-claude-2 section 2.4; one box, one OS user, transcripts changed in the last 24 h, n = 164 files, 2026-10-10T11:18Z): 26 065 assistant rows for 14 002 distinct message ids; `cache_read_input_tokens` per row 4 989 894 903 vs per id 2 663 132 503 (1.87x); `output_tokens` 2.22x. A naive per-row sum about doubles the count.
  - `<synthetic>` rows with zero usage are skipped.
  - A turn already metered by the hub (a `turn_id` in `usage_events`) is skipped here, so it is counted once.
- **`do_spl_cost_agent_hours_read`**: the lease tick appends `<ts> <id> run|stop` to a day log beside `agent-run.tsv`; agent-seconds = `run` samples x the measured gap between ticks (from the timestamps, not an assumed interval).

### 4.4 Hand entry

- An operator form: month, item, amount, currency, note, who, when (owner b046544e). Stored as `cost_lines` with `origin=hand` (or `invoice` for a vendor invoice), shown marked "entered by hand".
- An edit is a new row that supersedes the old one (`superseded_by`), never an in-place change, so a closed month's total can be explained later.

### 4.5 Nightly run and month close

- **`do_spl_cost_rollup_daily`**: a named action, nightly by cron at a cnf time (`cost.rollup_utc`, start 02:00), for the previous UTC day: reads GCP (4.2), takes the box day files (4.3), aggregates `usage_events` (`units x unit_cost_micros`) once 121 ships it, pro-rates monthly subscription invoices to days, writes `cost_coverage`.
- **`do_spl_cost_month_close`**: a month closes on cnf `cost.close_day` of the next month (start 6), after the GCP re-read window. A closed month is never rewritten; a late correction is a new hand row in the open month (owner f99ea7d8, "updated on a monthly basis").
- **`do_spl_cost_report MONTH=<yyyy-mm>`**: the month table as text, in USD and EUR, for the owner's monthly post and for a test with no browser.

### 4.6 Cost sources behind one interface (Q-7)

- Every reader (GCP export, fleet transcripts, agent-hours, metered `usage_events`, hand entry) implements one cost-source contract: `name`, `read(day) -> cost_lines rows + one cost_coverage row`. The nightly run asks a factory for the registered sources from cnf (`cost.sources`) and runs each; it names no source in its own code.
- A new source (a box outside GCP, another vendor's usage record) is a new implementation plus a cnf entry, with no change to the rollup, the table or the page.
- Control: a test registers a stub source and sees its rows in the month table; with the factory bypassed (a hard-coded list) the stub's rows are missing.

## 5. Report / View (WUI Page)

A new WUI page `/costs`, reachable from the sidebar as "Costs".
- **Visuals**: a simple table + a pie chart (owner 45f8cb69).
  - The pie is inline SVG in a component imported only by the `/costs` route: no chart library (`grep -ciE 'chart|echarts|d3' csi-spl-wui/package.json` -> 0 today, and one pie is not worth one).
  - **The initial chunk ceiling is 155 KB gzip**, not 160: `grep -n ci_initial_gzip_kb csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json` -> line 4 `155.0` (owner 2026-10-02, topic 87eaa57b). It stays 155.0; a new route ceiling `ci_costs_route_gzip_kb` goes beside the roadmap one.
- **Table Rows**: cloud parts per project (hub, database, hosting, network, boxes), tokens per vendor, subscriptions/API keys, hand rows, and one "not tracked" row for machines outside GCP (Q-7).
- **Table Columns**: amount (USD and EUR, Q-6), % of the month, list-price equivalent for subscription tokens, a marker if it was 'entered by hand', and "n of N days complete" per source from `cost_coverage`.
- **Monthly Basis**: one table + pie per calendar month, closed per 4.5. Earlier months are selectable.
- **Current Month**: a running 'current month so far' figure based on the daily rows, marked "so far" until the month closes.
- **Token Gap**: for metered tokens, the page shows both the paid invoice (hand-entered) and our own metered count. The difference is the token gap (122 M4 / 121 +20% buffer). 123 reports cost only: it never applies the buffer or the 29% margin.

### 5.1 Who sees what (Q-1 = A, owner)

- `admin` and `biz_owner` are per-workspace roles: `sed -n 58,61p csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go`. The tenant `admin` has no billing right today: `csi-spl-rdb/src/sql/postgres/spool-hub/0021_tenant_rbac.sql:58` -> "runs the tenant: members, roles, settings, keys, audit; not billing".
- So the owner's "both the admin and the business owner" needs a new permission **`costs.read`** (the 0021 pattern), granted to `biz_owner` and `admin` by a migration, not `billing.manage`.
- The estate view (GCP, fleet, boxes) needs `costs.read` **in the operator workspace** (`internal/hub/operator.go` `operatorAuth`); in any other workspace a member with `costs.read` (its `biz_owner` and `admin`) sees that workspace's rows only (Q-1 = A, owner msgs `9bb60e73` and `6fc78646`).

### 5.2 The read API (build lane 4b)

Owner HUM-10, t1 dbf2f39b (msgs 6cab186b, a54b9e74): the page is the **Costs
tab of Monitoring** (`/monitoring/costs`), GCP infrastructure and tokens on
one table. Its API, `csi-spl-api/.../internal/hub/cost_read.go` and
`internal/store/cost_read.go`:

- `GET /v1/tenant/costs?month=YYYY-MM` (default: the current UTC month so
  far; a month not started is 400). `costs.read` (403 naming it otherwise).
- Scope: in the operator workspace `scope=estate`, the estate rows (tenant_id
  NULL) beside the workspace's own, read under the operator scope; in any
  other workspace `scope=workspace`, its own rows under its tenant scope,
  where RLS hides every estate row, and coverage only of its own sources.
- `parts`: the month's live lines summed per (estate, source,
  project_or_vendor, kind, origin): `units`, `usd_micros`, `eur_micros`,
  `list_value_micros`, `days`, `hand` (origin hand or invoice), `pct` (share
  of the USD total, null while it is 0). `total`: USD and EUR micros.
- `coverage`: per source `ok`, `partial`, `missing`, `unrecorded` (ended days
  with no row) of `days` = N, the days of the month that ended (today is
  still being read).
- `status`: `so_far` while the month runs, `ended` after it; `closed` comes
  with the month close (4.5).
- Tests: `TestCostMonthReadSums`, `TestCostMonthReadRLS` (store, Postgres),
  `TestCostRead*`, `TestCostWindow`, `TestCostMonthAnswer` (hub).

### 5.3 The WUI tab (build lane 5, SPL-2056)

`/monitoring/costs`, the **Costs** tab of Monitoring, over 5.2:

- **Who**: the tab shows once `/v1/view/me` answered and the member holds
  `costs.read` (`csi-spl-wui/src/utils/monitoring-tabs.mjs`, `perm`); a direct
  URL without it shows the hub's 403, naming `costs.read`.
- **Month**: a picker of the current UTC month (marked "so far" with
  "n of N days") and the 11 before it; never a future month.
- **Table**: one row per part (source, project or vendor, kind, units), USD
  and EUR, % of the month, the list price where `list_value_micros` > 0, an
  "entered by hand" mark, a total row; in the estate view one "Machines
  outside GCP: not tracked" row (Q-7). Under it "n of N days complete" per
  source, its partial, missing and unrecorded days named.
- **Pie**: inline SVG (`MonitoringCostsPie.vue`, imported only by the page),
  one slice per part over 1 % of the USD total, the rest one "other" slice.
- **Honest empties**: a source whose parts sum to 0 USD (today's fleet tokens
  and agent hours, counts only) and, in the estate view, GCP while it has no
  row, each read "No cost data yet for <source>"; no money at all draws no
  pie.
- **Budget**: `ci_costs_route_gzip_kb` 12 KB in
  `027-spool-performance/contracts/perf-budgets.json` (5.7 KB measured);
  `ci_initial_gzip_kb` stays 155.
- **Not built yet**: the hand-entry form (4.4: no hub API; `POST
  /v1/operator/cost/day` refuses origin `hand` and `invoice`) and the token
  gap view.

### 5.4 The second currency (SPL-2108)

Owner HUM-10, t1 1b6f871f msg 44fef397: a second currency beside the USD the
AI providers bill in, a personal setting whose default is EUR, converted at
the day's rate from the ECB (a European currency) or the Federal Reserve
(every other one). Dispatcher answer a81b348c: the rate of the cost's own
day, else the last one published before it, and the rate's date is shown.

- **Rates**: rdb `0200_fx_rates.sql`, one row per (day, quote, source): how
  many units of `quote` one USD bought (`base` is always USD), `source` ECB or
  FED, `fetched_at`. Hub-wide reference data: any workspace scope reads it,
  only the operator writes it.
- **Feed**: `POST /v1/operator/fx/rates` (operator SA only),
  `{rows: [{day, quote, rate, source}]}`, an UPSERT per (day, quote, source):
  a re-post is a no-op. Answer `{rows, written}`.
- **Fetch**: `ENV=<env> [DRY_RUN=0] ./run -a do_spl_fx_rates_fetch`
  (csi-spl-orc, DRY_RUN=1 by default) reads the ECB euro reference rates
  (the currencies in cnf `env.fx.ecb_currencies`) and the Federal Reserve H.10
  series (every other one) from the cnf `env.fx` URLs, turns each rate into
  units per USD and posts the last `env.fx.days` days to the feed. Daily from
  the box crontab: row `fx-rates-fetch` (16:37 box time) of
  `csi-spl-orc/cnf/box-crons/box-crons.manifest`, script
  `fx-rates-fetch-cron.sh`, for dev and prd. Test:
  `csi-spl-orc/src/bash/tests/spl-fx-rates-fetch.tst.sh`.
- **Backfill** (SPL-3791): `ENV=<env> FX_FROM=<YYYY-MM-DD> [DRY_RUN=0] ./run -a do_spl_fx_rates_fetch`
  posts every day from `FX_FROM` (1999-01-04 .. today, not with `FX_DAYS`)
  in place of the last `env.fx.days`: it reads cnf `env.fx.ecb_hist_url` (the
  ECB's full file) and `env.fx.fed_range_url` (the Fed series with `{from}`
  and `{to}` filled), in the same 500-row chunks and the same UPSERT. A
  one-off per hub (prd and dev from 2024-07-01, so an item of an older period
  converts at a rate of its own month); the cron row never sets it.
- **Setting**: `second_currency`, per workspace like `time_zone` (rdb 0078
  membership settings, no humans column). `PUT /api/v1/auth/preferences`
  takes an ISO 4217 code (upper-cased) or `null` (back to EUR); a code the
  hub holds no rate for is 400 `unsupported_second_currency`, EUR always
  passes. `GET /api/v1/auth/session` and the login answer carry
  `second_currency`, `EUR` when never picked.
- **Picker list**: `GET /v1/tenant/fx/currencies` (any member):
  `{default: "EUR", currencies: [...]}`, the quotes the hub holds a rate for.
- **Cost read** (5.2): the answer adds `second_currency` (the caller's own
  pick) and `total.second_micros`; each part adds `second_micros` (its USD
  converted cost day by cost day, each at its day's rate, else the last one
  before it; an ECB row wins a tie with a FED row of the same day),
  `fx_rate` and `fx_rate_day` (the rate of the part's latest cost day and that
  rate's date) and `fx_rate_first_day` (the rate date of its earliest cost
  day). All four are `null` when any cost day of the part has no rate on or
  before it, never a guess; `total.second_micros` is `null` when any part's
  is. `usd_micros` and `eur_micros` are unchanged.
- **Tests**: `TestCheckFXRates`, `TestPutFXRates`,
  `TestCostMonthReadSecondCurrency` (store, Postgres; a Saturday falls back
  to Friday; red control: the read with the conversion dropped fails the
  assertion), `TestFXRatesRoute`, `TestCostReadSecondCurrency` (hub),
  `TestParseSecondCurrency`, `TestCheckSecondCurrency` (auth).
- **WUI** (lane B, SPL-2199): Monitoring -> Costs has one more column after
  EUR, headed `<code> (day rate)`, each part's `second_micros` in the
  reader's pick; the cell's title is the rate and its date
  (`1 USD = 0.92 EUR, rate of <fx_rate_day>`, or, when the part's cost days
  took several rates, `Each day at its own rate, <fx_rate_first_day> to
  <fx_rate_day>. Latest: ...`). No rate is an em dash whose title says so;
  the total row likewise. USD and EUR columns are unchanged. Settings ->
  Appearance -> **Second currency** (`SecondCurrencySetting.vue`, under Time
  zone) lists `GET /v1/tenant/fx/currencies`, marks the default, saves with
  `PUT /api/v1/auth/preferences {second_currency}` (the default sends `null`)
  and the open costs page reloads on the new pick. Code:
  `csi-spl-wui/src/utils/tenant-costs.mjs` (`costSecondCell`, `costFxRate`,
  `costCurrencyOptions`; loaded by the costs page and on demand by the
  setting, never in the first-screen set), the mock (`MOCK_FX_RATES`,
  scenario `norate` in `spool.mock.costs`). Tests:
  `tests/unit/tenant-costs.test.mjs`, `tests/e2e/monitoring-costs.test.mjs`
  (1400 and 390 px). Not here: the help pages (`monitoring.md`,
  `user-settings.md`, Qto exports).

### 5.5 Three sections: Cloud, AI tokens, Human (SPL-4187)

**Status:** built: the reader (every project of the export),
`GET /v1/tenant/costs/cloud` and the three WUI pages below; their
19-locale text lands only after a claude language review (owner order
f8f9dfcc moved the agy language reviews to claude).

Owner HUM-10, t1 e2c0e6b4: msg 81217a3f "Switch it on to see all of the
expenses from the cloud, and make sure they have their own section. There
are three main types of costs: cloud costs, AI token costs, and human
costs."; msg 156c8939 "the export IS the part of the most of the cloud
costs - I need to add the other projects too"; msg 8c7f4962 "this should be
the first level by gcp project of the cloud costs, thatn there should be
drill down by service etc."

- **Every project of the export.** cnf `env.cost.gcp.project_like` is `%`:
  the reader (4.2) takes every project the billing export carries; the
  owner adds his other projects to the export himself. A `<prefix>%`
  still narrows it. Test: `spl-estate-cost-read.tst.sh` (CONTROL: the cnf
  narrowed to `csi-spl-%` drops a non-`csi-spl-` project).
- **Cloud** (`/reporting/costs/cloud`, the operator admin's, as the estate
  is): level 1 one row per GCP project (`project_or_vendor`, its
  `box=<label>` shown apart), from the month read's `gcp` parts; level 2,
  a project's services (the line `kind`); level 3, a service per day, from
  `GET /v1/tenant/costs/cloud?month=YYYY-MM&project=<project_or_vendor>`
  (`internal/hub/cost_cloud_days.go`, `store.CostCloudDays`): the estate
  project's live lines per (day, kind), `usd_micros`, `eur_micros` and
  `second_micros` at each day's rate (null with no rate, never a guess);
  403 for anyone but the operator workspace's admin, a session with no
  member and a live act-as clone of that admin included (the clone holds
  the admin's roles, but the estate is not the admin's to lend; the month
  read gives such a clone the workspace answer, never the estate's). The
  drill-down rides in the query (`?project=`, `&kind=`) beside the
  header's month and currency. Tests: `TestCostCloudDays` (store,
  Postgres, a superseded line seeded; hub, both stores),
  `TestCostCloudDaysActAsClone` (hub, Postgres). Each level draws a
  share-of-total % column and a Total row, the month's coverage line
  (`monitoring.costs.coverage_row`) and crumbs that walk back up a level.
  WUI tests: `tests/unit/costs-sections.test.mjs` (the three levels, the
  sums and the order) and the Cloud checks in
  `tests/e2e/monitoring-costs.test.mjs` (levels 1..3, totals = the row
  drilled from, the operators-only control).
- **AI tokens** (`/reporting/costs/tokens`): the month read's token parts
  (`fleet_tokens`, `ai_paid`, `ai_share`), paid money and the list value
  beside it, never added (13.3), plus today's live fleet card for the
  operator admin.
- **Human** (`/reporting/costs/human`): "not tracked yet", naming spec 107
  rows T071..T077; no number until they land (13.5).

## 6. The 1-Month Collection Plan

- **First month**: 2026-10 (Q-5), with what is live; each source is marked missing for every day before it runs. October is the iteration month (Q-3: "we will iterate during October and start for real in Nov").
- **First real month**: 2026-11, always from the first of a calendar month, never mid-month.
- **n**: 31 days of October (partial, coverage stated), then 30 days of November. The report states per source how many days were complete (`cost_coverage`).
- **Execution**: The cron automatically runs `do_spl_cost_rollup_daily` every night. The WUI page provides real-time visibility into "how much all of this pleasure costs".

| date (2026) | gate |
|---|---|
| October, as each lands | DDL `cost_lines` + `cost_coverage` on dev and prd; the hand form; the 4.3 readers with tests; each source writes October rows from the day it runs |
| by 10-25 | the export turned on through `do_gcp_billing_export_setup` (Q-3, the owner's go; c-001 runs it); the reader SA exists (Q-2) |
| 10-26..10-31 | every reader runs nightly; coverage `ok` on 5 of 6 days per source, else that source is named late |
| 11-01 | the first real month starts |
| 11-06 | October closes (4.5, partial); `do_spl_cost_report MONTH=2026-10` |
| 12-06 | November closes; `do_spl_cost_report MONTH=2026-11`; the owner post |

## 7. Reuse with Specs 121 and 122 (No Duplicates)

**None of what the draft reused is built yet.** `git grep -l <name> origin/master -- . ':!csi-spl-doc'` -> 0 files for each of `usage_events`, `model_prices`, `agent_seconds`, `estate_cost_months`, `do_spl_estate_cost_read`, `do_gcp_billing_export_setup`, `do_spl_token_gap_measure` (s123-claude section 2, s123-claude-2 section 2.1, s123-agy section 1). So 123 is the first build of the cost readers.

| need | reuse | 123 adds |
|---|---|---|
| GCP cost | 122 section 9's export setup, reader SA design, rows per project and label | builds them (section 9, lane 2), daily rows; `estate_cost_months` is a view |
| token gap | 122 M4 formula `(provider - ours) / provider` | shows it on the page; does not build M4 |
| metered API tokens | 121 section 7 `usage_events` + `model_prices` | reads them once 121 phase 3 ships; nothing new |
| fleet tokens (subscriptions) | the transcript read of `spl-lane-restart.func.sh` | `do_spl_cost_tokens_read`, deduped per message id |
| agent-hours | `dispatch/agent-run.tsv` | `do_spl_cost_agent_hours_read` |
| hand-entered invoices | the operator path pattern | the form and its rows |
| page budget | 027 `perf-budgets.json` 155 KB and its test | the lazy inline-SVG pie, a route ceiling |

One cost is never counted twice: a customer turn's tokens come from `usage_events` once it exists; a turn already metered there is skipped by the transcript reader.

## 8. Tests and Controls

| Rule | Test | Control (Fails when guard removed) |
|---|---|---|
| **Rollup Accuracy** | A test with seeded `usage_events` and a mock GCP billing export produces the exact mathematical sum in `cost_lines`. | Changing the sum multiplier causes the test to fail. |
| **Idempotency** | Running `do_spl_cost_rollup_daily` twice for the same date updates the existing rows (UPSERT) rather than duplicating costs. | Without the UPSERT `ON CONFLICT` clause, duplicate rows are created and the report total doubles. |
| **WUI Security** | The cost endpoint requires `costs.read`, returning 403 for others. | Removing the check returns 200. |
| **Transcript dedupe** | fixture: one message id on 3 rows, 100 output tokens | without the per-id max the total reads 300 |
| **Transcript sum** | a fixture transcript with known usage gives the exact sums | dropping `cache_read_input_tokens` from the sum fails it |
| **No double count** | one turn both in `usage_events` and a transcript counts once | removing the skip doubles it |
| **Late GCP row** | day D re-read with a changed cost | without the re-read window D keeps the old cost |
| **Unmetered** | a vendor with no usage record | the row reads `unmetered`; with the rule removed it reads 0 |
| **Coverage** | one source missing a day | the month is marked partial; without the check it is summed as whole |
| **Closed month frozen** | a rewrite after close is refused | without the check the total changes |
| **Hand edit** | an edit supersedes, the old row stays | an in-place update loses the old amount |
| **Tenant isolation** | workspace B reads A's `cost_lines` as `spool_hub_rt`, RLS on | 0 rows; with the policy dropped it reads A's rows |
| **Estate scope** | a non-operator `biz_owner` or `admin` reads estate rows | 403; without the operator check, 200 |
| **Chunk budget** | `ci_initial_gzip_kb` <= 155 and the new route ceiling | a static import of the pie into the shell fails the initial-size check |
| **No owner account** | the reader runs as the reader SA, `--account` on every call | the `gcloud-account-pinned.tst.sh` pattern refuses the owner email |
| **Every csi-spl-* project** | an export fixture with `csi-spl-dev`, `csi-spl-x` and a non-spool project | `csi-spl-x` is counted, the other is not; with a fixed project list `csi-spl-x` is missing |
| **Two currencies** | a EUR invoice and a USD export row | both totals match the fixture rate; without the conversion one column reads 0 |
| **Source factory** | section 4.6 | section 4.6 |

## 9. Build Lanes (ordered, disjoint files)

1. **DDL**: `cost_lines`, `cost_coverage`, the `costs.read` permission; dev and prd before any code.
2. **GCP**: `do_gcp_billing_export_setup` (dry run by default; `DRY_RUN=0` is the owner's) and `do_spl_estate_cost_read`, each with its `.tst.sh` (122 lane 3's first two items, built here; 122 section 11 then reuses them).
3. **Box readers**: `do_spl_cost_tokens_read`, `do_spl_cost_agent_hours_read` and the lease-tick day log, with tests.
4. **Hub**: the cost-source factory (4.6), the operator ingest endpoint, `do_spl_cost_rollup_daily`, `do_spl_cost_month_close`, `do_spl_cost_report`, the hand-entry API, `costs.read` checks.
5. **WUI**: `/costs`, the table, the lazy inline-SVG pie, the hand form, the route ceiling.

## 10. Owner Decisions Already Made

- The page has a pie chart and a simple table; the admin and the business owner open it (45f8cb69).
- The table is monthly (f99ea7d8); some costs are entered by hand (b046544e).
- Token buffer +20% at launch, lowered to the measured gap (9e0c0dba, via 121/122). Not asked again here; who lowers it is 121 Q-N2.

## 11. Panel and Consensus

| seat | lane | commit | what it brought |
|---|---|---|---|
| s123-claude (editor) | c-817 | 69f5c4371 | the reused parts are unbuilt; fleet subscription tokens; cost vs list value; 155 KB; operator-only estate view; Q-C1..Q-C5 |
| s123-claude-2 | c-818 | 4f2ff434c | the same unbuilt finding; the measured transcript double count (dedupe per message id); `costs.read` from 0021; `cost_lines` + `cost_coverage`; late GCP rows; the dated plan; Q-1..Q-7 |
| s123-mistral | m-819 | 3e8841f9b | granularity columns on the rollup; the hand-entry mapping; the token gap on the page; the UPSERT key; SA option B (dedicated reader) |
| s123-agy | a-820 | b0e7484dc | the unbuilt dependencies; the UNIQUE constraint for the UPSERT; the `/costs` route and sidebar entry; a cron time |

Agreed:
- **Unbuilt reuse, 123 builds the readers** (claude, claude-2, agy; mistral listed the reuse without checking the code): section 7, section 9 lane 2.
- **Fleet tokens from transcripts, deduped per message id** (claude, claude-2): section 4.3.
- **The estate view is operator-scope** (claude, claude-2): section 5.1. mistral and agy recommended A on the draft's wording ("admin sees the estate"), the same intent; Q-1 restates it with the real roles.
- **155 KB, not 160** (claude, claude-2; mistral's 160 is corrected).
- **One UPSERT table with a UNIQUE key** (all four).
- **A dedicated reader SA** for billing (all four).

Corrected in the fold:
- mistral cites "spec 122 Q-5 (owner pick B)" and "spec 121 Q-N1 (owner pick A)" for scope; 121 records b6a56949 as Q-5 = prd + hosts for the price slice, and 121 Q-N1 is the visitor spend ceiling. Neither decides cost tracking scope.
- mistral's token-buffer question is already decided (section 10).

Split, editor's call:
- **The start date** (Q-5): claude asked to wait until every source writes complete rows; claude-2 starts 11-01 with partial sources marked; mistral 11-01 or later. The editor recommends 11-01 with coverage marked: waiting moves the month, and `cost_coverage` keeps a partial month honest.

Signatures (rc1 cc831a665): s123-claude-2 c-818 signed (msg 5f8ff8e8; nit on the "$20/month" example, already gone in rc1: section 2 item 3 reads "the vendor invoice amount"); s123-mistral m-819 signed (0be19ee4); s123-agy a-820 signed (21a428e0); drafter a-816 signed (af26e9bb); s123-claude (editor) signed. 5 of 5.

v1.0 changes only what the owner's answers decide (section 12): every `csi-spl-*` project, October as the first month, USD and EUR, machines outside GCP not tracked plus the source factory (4.6).

## 12. Owner Questions

One list, merged from Q-C1..Q-C5 (s123-claude) and Q-1..Q-7 (s123-claude-2), plus the draft's Q-C1 and the seats' SA question. **All seven answered** by the owner (HUM-10, t1 af4bbf51, relayed verbatim by the dispatcher c-002 on e35387eb).

- **Q-1 Who sees which costs.**
  - A: the operator workspace (you, and whom you grant) sees the whole estate; in any other workspace, `biz_owner` and `admin` see only that workspace's costs.
  - B: every `biz_owner` and `admin` sees the whole estate.
  - **Panel: A (4 of 4).** One workspace's costs never show another's; the estate's costs are Csitea's.
  - **Owner: A.** msg `9bb60e73`: "Only the Spool Hub admin and business owner see all of the costs." Follow-up (may another workspace's owner/admin see that workspace's own costs?), msg `6fc78646`: "q1 - yes this is the plan".
- **Q-2 Who reads the GCP billing export.** The per-env SAs cannot read billing today.
  - A: a dedicated reader SA in csi-spl-all with `roles/bigquery.dataViewer` on the export dataset only, its key on disk like the per-env keys.
  - B: grant billing read to an existing SA (the per-env SAs, or the csi-spl-all SA that already runs the satellite budget).
  - C: no automated read; you type the GCP total each month, and the daily figures stay estimates.
  - **Panel: A (4 of 4).** The smallest grant that works; B sees every project on the billing account, C loses the daily view.
  - **Owner: A, widened to every spool project.** msg `cef45738`: "we will create a separate service in the background to read those , it must include the costs from the other projects as well ... the other spoo projects"; msg `c48f7aa2`: "all of the csi-spl-* projects".
- **Q-3 Turning the billing export on.**
  - A: you run `do_gcp_billing_export_setup` with `DRY_RUN=0` by 2026-10-25.
  - B: later; the start date moves to the first of the month after it.
  - **Panel: A** (claude-2; no seat objected). November becomes the first measured month.
  - **Owner: A.** msg `4671d819`: "we will iterate during October and start for real in Nov"; msg `6078c151`: "3A".
- **Q-4 What the fleet's agents cost on the page.**
  - A: the subscription invoices are the cost; the token counts and their API list-price equivalent are shown beside them.
  - B: invoices only.
  - C: the API list-price equivalent only.
  - **Panel: A** (claude, claude-2). The invoice is what is paid; the equivalent shows what the same work would cost on API keys.
  - **Owner: A.** msg `c48f7aa2`: "4 A".
- **Q-5 When the month starts.**
  - A: 2026-11-01 with what is live; a late source is marked missing per day until it runs.
  - B: only when every automatic source writes complete rows, from the first of the next month.
  - **Panel: split (claude-2 A, claude B, mistral A or later). Editor recommends A.** You asked for at least a month of data; the coverage rows keep a partial month honest.
  - **Owner: 2026-10.** msg `6078c151`: "5. 2026-10". October is the first month, with what is live and missing days marked; November is the first real month (Q-3). Section 6.
- **Q-6 Report currency.**
  - A: USD; every row keeps its own amount and currency, converted at the invoice day's rate.
  - B: the billing account's currency, as GCP bills it.
  - **Panel: A** (claude, claude-2). One currency across 121, 122 and 123, and the original amount stays auditable.
  - **Owner: both USD and EUR.** msg `6078c151`: "6, both USD and EUR". Every row keeps its original amount and currency (4.1).
- **Q-7 Machines outside GCP.**
  - A: a hand-entered monthly row per box (hardware share, power, line).
  - B: out of scope, listed as "not tracked".
  - **Panel: A** (claude-2; no seat objected). You asked for "the whole" instance; a marked hand row is honest about its source.
  - **Owner: B, plus a factory.** msg `6078c151`: "7. no supported for now - factory design patterns in the code to support for the future". Section 4.6.

## 13. The project's cost: cloud + AI tokens + human (v1.1..v1.6, plan only)

**Status: P01 built (SPL-6054), P02 built (SPL-6075), P03 built (SPL-6078), P05 built (SPL-6117, the page, first in the Costs bar and the default, owner 2026-11-21 Q-9 A again, below), P07 built (SPL-6118, the help section), the other rows Planned.** Lane issue
SPL-4189, epic SPL-2373. It is the level ABOVE the near-term three-sections
build (ask `156c8939`: Costs gets Cloud / AI tokens / Human sections), and it
does not duplicate it.

### 13.1 The owner's words (HUM-10, prd t1 topic `e2c0e6b4`, verbatim)

- msg `81217a3f`: "Switch it on to see all of the expenses from the cloud, and make sure they have their own section. There are three main types of costs: cloud costs, AI token costs, and human costs."
- msg `d0651111`: "but as the longer term vision - basically the whole Costs section , but present on higher level ( and plann this for now , but have it in the specs ) , the combination of cloud costs , human costs and ai costs"
- msg `3a190b70`: "These the costs of this project"

### 13.2 The top view

One view, **"The project's cost"**. Spec 143 3.2 defines four Costs pages,
Spend the default and first. This view is planned as a **fifth page**,
`/reporting/costs/project`, placed **first and the default** (owner Q-9 A,
13.10). This changes 143 3.2 (`143-reporting-section/costs-redesign.md`
3.2, "One Costs tab, four pages", Spend the default): that table needs the
project page as its first row and Spend no longer the default. Spec 143 is
not edited here; the change is a follow-up for its owner.
For the picked period it shows one total =
**cloud + owned hardware + AI tokens + human**, and four parts under it
(owned hardware is entered by hand, 13.12). Each part has:

- its amount in the header's currency (spec 143 3.1 rule 3) and its **share**
  of the priced total;
- its completeness in words (13.5);
- a link to its own section below, and from there to the existing page that
  holds the detail: Cloud -> Spend (Cloud group); Owned hardware -> Paid
  items (the asset list, 13.12 item 1); AI tokens -> Spend (AI agents
  group), Tokens and Price per token; Human -> the hours reports of spec 107
  (section 6) and the Releases human part (107 21.4).

Period: the Costs header's one period (143 3.1 rule 2: a calendar month "so
far" and the months before it), plus a **year to date** pick that sums the
closed months and the month so far. The page opens on two figures, this
month so far and this year to date (13.12 item 2). A pie of the four parts
(the pie of 143 3.3, drawn in inline SVG like the Tokens bars of 143 3.4)
and, under it, one bar per month of the year, each split in the four parts.
No chart library (section 5).

Made-up figures, none is a real cost:

```
Costs › The project's cost   Oct 2026 (so far), 1-28 Oct UTC   (USD) ( EUR )
+---------------+-----------+--------+----------------------------------+
| Part          |    Amount | Share  | Completeness                     |
+---------------+-----------+--------+----------------------------------+
| Cloud         |    160.00 |  16 %  | 27 of 28 days read               |
| Owned hardware|     80.00 |   8 %  | entered by hand, 1 asset         |
| AI tokens     |    630.00 |  63 %  | every paid item priced           |
| Human         |    130.00 |  13 %  | 2 of 3 people priced, 1 unpriced |
+---------------+-----------+--------+----------------------------------+
| Total, priced |  1,000.00 | 100 %  | partial: see the parts           |
+---------------+-----------+--------+----------------------------------+
```

### 13.3 How each part gets money

| part | money from | read today by | price source |
|---|---|---|---|
| **Cloud** | `cost_lines` source `gcp`, origin `billing_export` (4.2), every project of the export (5.5; Q-2 was every `csi-spl-*` project) | `GET /v1/tenant/costs` parts (5.2) | the GCP bill itself; `estimate` rows (4.2) are marked |
| **Owned hardware** | `cost_lines` origin `hand`, source `hand_asset`: the daily shares of each asset entered by hand (13.12 item 1) | not built: P08 | the purchase price, written off straight-line over its months |
| **AI tokens** | the paid items' daily shares, source `ai_paid` (spec 143 4.1, `store/cost_ai_paid.go`); later the metered API turns, `usage_events` x `unit_cost_micros` (spec 121 section 7) | the same month read | **what was paid** (subscriptions and top-ups, `fleet_token_paid`), never the list value. The list value (the `model_prices` cost of the `fleet_tokens` lines, which carry units and no money amount) stays "list value (not paid)", shown beside, never added (Q-4 A, spec 143 3.1 rule 1) |
| **Human** | approved time x each person's own price in force on the day (spec 107 21.4 step 5, 21.5) | not built: spec 107 rows T071..T077 | the member's own hourly price (`member_hourly_prices`). This view sums approved entries per day; it does not need the per-commit ledger |

Context relayed by the dispatcher (c-002, 2026-10-29), not re-measured by
this lane: prd `cost_lines` source `gcp` since 2026-10-23; `fleet_tokens.<box>`
lines since 2026-10-09 (units only).

### 13.4 Currency

One rule, the existing fx (5.4). Each part keeps its own amount and currency
(GCP: the bill's; a paid item: its own; a human price: the member's). It is
converted **per cost day** at that day's rate (rdb `0200_fx_rates.sql`, ECB
or FED, else the last rate before the day) to USD and to the viewer's second
currency. A day with no rate leaves its amount `null` in that currency,
never a guess, and the part says so (13.5).

### 13.5 When a part is incomplete

A part that is not known is never summed as 0. Each shows one of:

- **"n of N days read"**: from `cost_coverage` (Cloud) and the month read's
  coverage (AI tokens). A missing day is named in the part's section.
- **"unpriced"**: AI tokens of an agent type with no paid item that month,
  or a day with no fx rate; human minutes of a member with no price, or of a
  period not yet approved ("pending approval", 107 21.4 step 6). The minutes
  and tokens still show as counts. The money leaves them out and says how
  much is left out ("3:15 h unpriced").
- **"not tracked"**: a part with no source at all. Human reads "not tracked
  yet" until 107 T071..T073 land. Machines outside GCP are not read
  automatically (Q-7 B); one entered by hand counts in Owned hardware
  (13.12), and the page says "entered by hand".

The total is labelled **"Total, priced"**, and its row says "partial" while
any part is incomplete. The shares are of the priced total.

### 13.6 Who may see the money

- **Cloud, owned hardware and AI tokens**: `costs.read`, scoped as in 5.1
  (Q-1 A); owned hardware is an estate part, operator workspace only. The
  operator workspace sees the estate; any other workspace sees its own rows
  and its AI share (spec 143 3.3.1).
- **Human money**: only a holder of `hours.rates` (the time-accountant role,
  107 FR-20) sees the Human amount. An operator admin without it sees the
  human **hours** and "money: time-accountant only". This is decided by
  107 Q27 A (msg `ce14ad70`, 107 21.6), so it is not asked again. For that
  viewer the total and the shares cover Cloud + owned hardware + AI tokens
  only, labelled so: a total that included the human money would reveal it
  by subtraction. Built (P03, `hub/cost_project.go`
  `costProjectHumanMask`), the answer's `human_mask` says which of three
  levels the reader got:
  - `none`: a holder of `hours.rates` reads the Human part as folded.
  - `money`: a holder of `hours.read` (a customer workspace's biz_owner,
    107 21.6) or the operator workspace's admin or product owner (the
    estate read, never an act-as clone), without `hours.rates`. The Human
    part keeps its hours, counts and words; its amounts and share are
    `null`. The operator's internal and external accountant read the
    estate's other parts and get `whole` for Human (owner HUM-10, t1
    e2c0e6b4 msg 9af86e15, form 129aa0a2 answer C: "Also the product
    owner, not the accountants"); the external accountant is still 403 at
    the door (section 16 follow-up 2), so it reads no Human part at all.
  - `whole`: every other `costs.read` reader (developer, tester,
    biz_customer, a customer workspace's admin, the operator's accountants
    and the other member roles: "nothing of others", 107 Q26 A). The
    Human part is its name and `completeness: not_shown` only, every other
    field zero or `null`, and `total.partial` is read over the other parts
    and `left_out` only.

  Masked either way, `total.priced` and every other share are re-read
  without the Human money. **Field rule for P02 and later rows**: a Human
  money field goes INSIDE the part's `CostProjectMoney` (the `money` level
  clears exactly that struct); Human hours or minutes go outside it, and
  the `whole` level clears every field of the part, a new one included.
- **Never per person**: the Human part is one sum per day; no row names a
  member (107 21.7). Each member sees only their own time (107 Q26 A).

### 13.7 What "project" means

- **Now: this fleet's project, the spool**, read in the operator workspace.
  Cloud = every GCP project of the billing export (5.5); owned hardware = the assets
  entered in the operator workspace; AI tokens = the fleet's paid items (all
  boxes); Human = approved hours booked in the operator workspace.
- **Per workspace** (owner Q-8 A, 13.10): a customer (non-operator)
  workspace gets its own project cost = its AI share (143 3.3.1) plus its
  own members' human cost. It has **no cloud part** and no owned hardware:
  both are estate parts (13.6), so its page shows two parts, AI tokens and
  Human, and its total is their sum. P01 answers it in the workspace's own
  scope; P04 proves it reads no estate part; P05 draws it. The 13.9 case
  "a non-operator workspace" already expects exactly this (its own parts,
  no estate cloud, no owned hardware), so the case is unchanged.

### 13.8 Planned build rows (rounds-rulebook format, at most 10)

Status of every row: **Planned**, except P01: **built** (SPL-6054,
`hub/cost_project.go`, `store/cost_project.go`; three choices where this
section predates the code on master are written at the top of
`store/cost_project.go`), P02: **built** (SPL-6075; a minute is priced
only when its entry is approved and its period frozen or final, 13.5 and
107 21.4 step 6, the rest is pending; absence rows are left out; both are
written at the top of `store/cost_project_human.go`), and P03: **built** (SPL-6078, the mask in
`hub/cost_project.go`, `TestCostProjectHumanMask` in
`hub/cost_project_mask_test.go`, `TestCostProjectHumanMaskHTTP` in
`hub/cost_project_mask_http_test.go`; 13.6), and P05: **built** (SPL-6117,
`pages/reporting/costs/project.vue` over `utils/cost-project.mjs` and the
client's `getTenantCostsProject`, e2e `tests/e2e/reporting-costs-project.test.mjs`
at 1400 and 390 px), and P07: **built** (SPL-6118, "The project's cost" in
the Reporting help, qto doc `d29362c7` and its export
`csi-spl-doc/doc/help/reporting.md`, served copy refreshed; the Costs section
above it now names five labels and the project's cost as the default). Where P05 predates master: since SPL-5312 (spec 143
`costs-redesign.md` 3.9, owner t1 41a74806, "only the following labels -
Total, Persons, Cloud, Tokens") the bar is four labels with Total the
default, and Spend is gone. Asked again where the page goes (t1 e2c0e6b4,
the dispatch holder's blocker poll 3aa4b938), the owner answered A on
2026-11-21 (msg 3a795cdb): "First label and the default, as Q-9 A says (five
labels, Total second)". So `utils/reporting-costs.mjs` `COSTS_PAGES` is
Project cost, Total, Persons, Cloud, Tokens, and `/reporting/costs` lands on
the project's cost; the old links that named Total (`/monitoring/costs`,
`/reporting/costs/spend`) still land on Total. Its links
go to the current pages: Cloud, Tokens, Persons, and Expenses -> AI costs for
the owned hardware. The header's "last 12 months" pick draws the year to date,
since the read answers a month or a year only. Each row is one lane, aiming at one push.
Each row names its files; no file is in two rows of one batch (rounds-rulebook
2.1 R1), and a row that changes an earlier row's file sits in a later batch.
A cross-vendor reviewer per row (R7). Waits: P02 waits for 107 T071..T072;
P05 waits for the three-sections build (ask `156c8939`, it owns `costs.vue`).
No row waits for an owner answer any more (v1.6): Q-9 A fixes P05's place,
Q-8 A fixes what P01, P04 and P05 show a customer workspace.
Rows P08..P09 are in 13.12 item 4; P10 (v1.2) is folded into P05 (v1.3).
Paths: `hub/`, `store/` under `csi-spl-api/src/go/spool-hub-api/internal/`;
`pages/`, `components/` under `csi-spl-wui/src/`; `tests/` under `csi-spl-wui/`.

| # | slug | what | target & proof | test (red control) | vendor | batch |
|---|---|---|---|---|---|---|
| P01 | `feat(api, project-cost-read)` | `GET /v1/tenant/costs/project?month=` (or `year=`), new `hub/cost_project.go` + `store/cost_project.go` + `store/cost_project_test.go`: the four parts (Cloud, Owned hardware from source `hand_asset`, AI tokens, Human), each with amount, share and completeness, over the month read (5.2); a customer workspace gets two parts only, its AI share and its own Human (Q-8 A, 13.7) | the parts sum to `total.priced`; an unpriced part is `null`, never 0; Human is `not_tracked` until P02 | `TestCostProjectParts` (red: a part with no rate summed as 0 changes the total; a `hand_asset` line left out changes the total) | claude | 1 |
| P02 | `feat(api, project-cost-human)` | the human day sum for P01, new `store/cost_project_human.go` + `store/cost_project_human_test.go`, one call added in `store/cost_project.go` (plus the input's `HumanRead`/`Human` and the part's `minutes`/`unpriced_minutes`), and the read wired in `hub/cost_project.go` `costProjectInput` (+ `hub/cost_project_human_test.go`): approved minutes of frozen or final periods x the price in force per day, per currency, no member column; the other minutes count as pending (13.5); the Human part's new fields follow 13.6's field rule (money in `CostProjectMoney`, minutes outside it). The served Human money waits for P03's mask (13.6): P02 lands after P03 | reads 107's T071 tables (`hours_entries`, `member_hourly_prices`, rdb 0295) directly; T072's store is not needed. The served answer carries Human; `TestCostProjectHumanServed` (red on the parent: `not_tracked`) | `TestCostProjectHumanSum` (red: pricing at today's price instead of the day's changes the sum) | claude | 2 |
| P04 | `test(api, project-cost-rls)` | tenant isolation and estate scope of P01 on Postgres, new `store/cost_project_rls_test.go` only | workspace B reads 0 of A's parts; a non-operator reads no estate part (no cloud, no owned hardware) | `TestCostProjectRLS` (red: the policy dropped reads A's rows) | claude | 2 |
| P03 | `feat(api, project-cost-mask)` | the human money mask in `hub/cost_project.go` + new `hub/cost_project_mask_test.go`: without `hours.rates` the Human amount is `null` and `total.priced` covers Cloud + owned hardware + AI only, flagged | an operator admin without `hours.rates` gets hours, no money, and no total that holds it | `TestCostProjectHumanMask` (red: removing the mask lets total minus parts reveal the human money) | claude | 3 |
| P05 | `feat(wui, project-cost-page)` | new page `pages/reporting/costs/project.vue`, its entry first in the Costs bar in `pages/reporting/costs.vue` and `/reporting/costs` opening on it as the default (Q-9 A, 13.2; Spend is no longer the default), labels in the locale catalogue (agy reviews the locale text last): the two first figures (month so far, year to date, 13.12 item 2), the table, shares, completeness words, links to the sections and pages | drawn at 1400 and 390 px, no sideways scroll; both first figures equal the sums of their parts | new `tests/e2e/reporting-costs-project.test.mjs` (red: a `null` part drawn as 0.00 fails; the year total without the closed months fails) | claude | 3 |
| P06 | `feat(wui, project-cost-year)` | the year-to-date pick and the month bars split in four parts, new `components/reporting/CostProjectBars.vue` (inline SVG, lazy) + `tests/unit/cost-project.test.mjs`, mounted in `pages/reporting/costs/project.vue` | the bars sum to the year total; the route chunk stays under its ceiling | `tests/unit/cost-project.test.mjs` (red: a static import of the bars into the shell fails the 155 KB initial-size check) | claude | 4 |
| P07 | `docs(doc, project-cost-help)` | a "The project's cost" section in `csi-spl-doc/doc/help/reporting.md` and its served copy `csi-spl-wui/src/public/help-md/reporting.md` (help is one English page; the page labels' locales are P05's) | the help copy matches its source | `tests/unit/help-sync.test.mjs` (red: the source edited without refreshing the served copy fails) | agy | 4 |

### 13.9 Red-control cases

| case | expected | with the guard removed |
|---|---|---|
| a part with a day with no fx rate | that part `null` in the second currency, "unpriced" | it reads 0 and the total is short |
| a member with no price | the minutes show, "unpriced", money left out | the minutes are priced at 0 |
| a price changed mid-month | each day at its own price | every day at the new price |
| the list value of subscription tokens | shown beside, not in the AI amount | the AI amount jumps to the list value |
| an operator admin without `hours.rates` | hours only, total over Cloud + owned hardware + AI tokens, labelled | total minus parts gives the human money |
| human not built yet | "not tracked yet" | a 0.00 row, and the other parts read as a complete 100 % |
| a non-operator workspace | its own parts, no estate cloud, no owned hardware | the estate cloud appears |
| an owned machine entered by hand | its monthly share in the month and year totals, in Owned hardware | left out of the total, or its full price in the purchase month |

### 13.10 Owner questions: Q-8 and Q-9 decided (v1.6)

Both answered, decided (owner HUM-10, prd t1 topic `e2c0e6b4`, msg
`4316d471`, 2026-10-29 16:00Z, poll `3d141fbb`):

- **Q-8 A**: "Yes: its AI share + its own people, no cloud part
  (recommended)". A customer workspace gets its own project cost (13.7).
- **Q-9 A**: "A fifth Costs page, first and the default (recommended)". The
  project's cost is `/reporting/costs/project`, first in the Costs bar and
  the page `/reporting/costs` opens on (13.2, P05); confirmed against
  SPL-5312's four labels on 2026-11-21 (msg 3a795cdb, "five labels, Total
  second"), built with P05 (SPL-6117).

No owner question of section 13 is open.

Q-10 of v1.1 is withdrawn: what an operator admin without `hours.rates`
sees is decided by spec 107 Q27 A (msg `ce14ad70`), 13.6.

### 13.12 Owned hardware, monthly and yearly first (v1.2, narrowed in v1.3)

The owner (HUM-10, t1 `e2c0e6b4`, relayed verbatim by the dispatcher; the
box name is replaced by `<box>`, public repo):

- msg `b84a7d41`: "Are there any other parts of the infrastructure which we are missing out ... BTW t should be possible to add the cost of the <box> box - as well - it is an expensive laptop - Bought some 1 year ago for 2000 € - and it should be depreciated fully in 2 years , so the ui should support adding this type of costs as well this way"
- msg `143a0a1c`: "aka the importance is to be able to see the monthly and yearly costs"

This narrows Q-7 (B, "not tracked"): a machine outside GCP is still not
READ automatically, but its cost can now be **entered by hand** as owned
hardware. It is a new source behind the 4.6 factory (`hand_asset`): the
daily rollup and Spend read it like any other source, and the project-cost
read (P01) counts it as the fourth part of 13.2, Owned hardware, in the
month and the year totals.

**1. One hand-entered cost kind, owned hardware** (the 4.4 form, operator
workspace, by a `costs.read` holder who may see money; stored as
`cost_lines` with origin `hand`, an edit supersedes, never in place). Only
this kind: the owner asked for owned hardware (msg `b84a7d41`), and any
other hand-entered kind waits for his word.

- **Owned hardware (an asset)**: name, purchase price + currency, purchase
  date, write-off period in months. Straight line: the monthly share =
  price / months, from the purchase month for `months` months, then 0.
  Example: 2,000 EUR over 24 months = 83.33 EUR a month (the last month takes
  the rounding rest, so the shares sum to the price exactly). A month's share
  is pro-rated to days like a subscription (4.5), so "so far" stays honest.
  An asset bought before the first cost month carries its remaining months
  only (bought 2025-10, 24 months: 2026-10 .. 2027-09 remain).
Its shares convert per day at the existing fx (13.4) and appear as the
part **"Owned hardware"** of 13.2, marked "entered by hand", never inside
Cloud.

**2. Monthly and yearly totals first.** The top view (13.2) opens on two
figures: **this month so far** and **this year to date**, each split in the
parts, then the 12 month bars. Every closed month's total stays as closed
(4.5); a hand row added later lands in the open month.

**3. Infrastructure costs, tracked or not** (prd facts relayed by the
dispatcher, not re-measured by this lane: `cost_lines` holds the sources
`gcp`, `fleet_tokens.<box>` and `agent_hours.<box>`; `fleet_token_paid_items`
holds the paid AI subscriptions). The page lists every kind with a mark:

| cost kind | tracked today | how, or the plan |
|---|---|---|
| GCP projects `csi-spl-*` | yes | billing export (4.2) |
| AI subscriptions and top-ups | yes | paid items (spec 143 4.1) |
| AI tokens, counts | yes, units only | `fleet_tokens.<box>` (4.3), list value beside |
| agent hours | yes, usage only | `agent_hours.<box>`, never money |
| owned machines (laptops, boxes) | no | hand asset, 13.12 item 1 |
| domains and DNS | no | not tracked; no plan in this spec |
| GitHub plan and CI minutes | no | not tracked; no plan in this spec |
| other SaaS (mail, storage) | no | not tracked; no plan in this spec |
| power and network line of a box | no | not tracked; no plan in this spec |
| human time | no | spec 107 T071..T077, then P02 |
| metered API tokens | no | spec 121 `usage_events` |

**4. Rows** (continuing 13.8, Planned):

| # | slug | what | target & proof | test (red control) | vendor | batch |
|---|---|---|---|---|---|---|
| P08 | `feat(api, cost-hand-asset)` | the asset entry API (`POST /v1/operator/cost/hand`, supersede on edit), new `hub/cost_hand.go` + `store/cost_hand_asset.go` + `store/cost_hand_asset_test.go`, and the `hand_asset` source behind 4.6 writing the daily shares | 2,000 EUR / 24 months: 24 monthly shares summing to 2,000.00 exactly; month 25 is 0 | `TestCostHandAssetShares` (red: dropping the rounding rest makes the sum 1,999.92) | claude | 1 |
| P09 | `feat(wui, cost-hand-form)` | the asset form and list ("counted from .. to ..") on the Paid items page, `pages/reporting/costs/paid.vue` | an asset entered lists its months and monthly share; P05 then shows it in the month and year totals | new `tests/e2e/reporting-costs-hand.test.mjs` (red: the full price counted in the purchase month fails) | claude | 2 |

P10 (v1.2, the two first figures) is folded into P05 (v1.3): it shared P05's
page and e2e file in the same batch (R1).

### 13.11 Change log

- v1.1 (2026-10-29, SPL-4189): section 13 added, plan only; rows P01..P07
  Planned; owner questions Q-8..Q-10 open.
- v1.2 (2026-10-29, SPL-4189): 13.12, the owner's msgs `b84a7d41` and
  `143a0a1c`: owned hardware written off straight-line, recurring hand
  costs, monthly and yearly totals first, the tracked/untracked list; rows
  P08..P10 Planned.
- v1.3 (2026-10-29, SPL-4189): the cross-vendor R7 (FAIL, W1..W7) folded.
  W1: owned hardware is the fourth part of 13.2 and of the P01 read, its
  month and year totals. W2: the pie cite is 143 3.3, inline SVG as 3.4.
  W3: spec 121 section 7. W4: Q-10 withdrawn (decided by 107 Q27 A); Q-9
  says the view is a fifth page that changes 143 3.2. W5: P07 names
  `help-sync.test.mjs` and the files. W6: every row names its files; P03 to
  batch 3, P06 and P07 to batch 4, P09 to batch 2, P10 folded into P05.
  W7: the recurring hand cost kind dropped; only owned hardware.
- v1.4 (2026-10-29, SPL-4189): R7 re-review (g-844, FAIL on W1 only):
  the 13.9 case "an operator admin without `hours.rates`" now expects the
  total over Cloud + owned hardware + AI tokens, matching 13.6 and P03.
- v1.5 (2026-10-30, SPL-4187): 5.5 added, the owner's msgs `81217a3f`,
  `156c8939` and `8c7f4962`: Cloud (project, service, day), AI tokens and
  Human get a section each; the reader takes every project of the billing
  export. Its R7 (c-504, FAIL on W1) folded: an act-as clone of the
  operator admin reads 403 on `GET /v1/tenant/costs/cloud` and the
  workspace answer of `GET /v1/tenant/costs` (the month read's estate rule
  had the same gap); tests for a session with no member, a clone and a
  superseded line.
- v1.6 (2026-10-30, SPL-4368): the owner's answers, msg `4316d471` (poll
  `3d141fbb`), folded. Q-9 A: the project's cost is a fifth Costs page,
  first and the default (13.2, P05); 143 3.2 (`costs-redesign.md`) needs
  the matching change, reported as a follow-up. Q-8 A: a customer
  workspace gets its own project cost, its AI share + its own people, no
  cloud part (13.7, P01); the 13.9 non-operator case already matched. The
  13.10 poll is replaced by the two decisions; Q-10 stays withdrawn. No
  row waits for an owner answer any more: P01, P04 and P05 are unblocked
  by these answers (P05 still waits for the three-sections build, P02 for
  107 T071..T072).
- v1.7 (2026-11-20, SPL-6075): P02 built. It reads T071's tables directly,
  so it did not wait for T072. The row now also names the hub wiring
  (dispatch holder, msg c3b149d2): the store read alone would leave the
  served Human `not_tracked`. The Human part also carries its minutes,
  unpriced minutes and pending minutes (13.5), outside the money that P03
  masks. R7 (FAIL, W1 W2) folded: a minute is priced only when its period
  is frozen or final (107 21.4 step 6), proposed and disputed rows count as
  pending; P02 lands after P03, so the money is never served unmasked.
  R7 r3 (FAIL, W3 N2) folded on P03 r2: a returned period's approved
  minutes count as pending too, and the Human part's `hr` lines never enter
  `left_out` (they travel in the month read's human list, guarded and
  tested); with P02 the fold's word for a workspace that booked nothing is
  `complete`, so P03's HTTP test reads `complete` where it read
  `not_tracked`.

## 14. The operator's product owner reads the estate (SPL-5181)

Owner HUM-10, t1 8426e63e, msg b17ead41: "The product owner should be able to
see all of the expenses and costs, which are visible to the admin as well.";
msg 573da484: "It should also be able to see the expenses tab."; t1 36406a93,
msg 97bab339: "The product owner should also be able to see the lanes."

This replaces the rule of t1 f3ed0eed msg 96d69790 (the estate is the operator
admin's only), wherever this spec says the operator admin reads the estate.

- One gate, `internal/hub/operator_read.go`: the operator workspace's admin or
  product owner, never a live act-as clone. It serves the estate month, the
  cloud days, and `GET /v1/operator/` `cost-entries`, `fleet-tokens`,
  `fleet-tokens/paid`, `fleet-tokens/effective` and `fleet-lanes`.
  `/v1/view/me` says it as `operator_reader`; the WUI reads that flag.
- Read only: every POST, PATCH and DELETE stays the operator admin's (or the
  service account's), never the product owner's, and the WUI draws the
  product owner no add, edit or delete.
- An act-as clone of the operator admin is refused these reads too, and
  (SPL-5348) the writes of the same data: every POST, PATCH and DELETE of
  `cost-entries` and `fleet-tokens/paid` goes through
  `internal/hub/operator_write.go`, `fleetLoadCaller` minus a live act-as
  clone, 403 `operator.workspaces`. A clone may not write what it may not
  read. Since SPL-5369 (owner HUM-10, t1 8426e63e, 08:51:55Z, pick A) every
  operator write refuses a live clone, not only these: the gate is
  `operatorActor`, every method but GET and HEAD (spec 054 section 5);
  `operator_write.go` is now `fleetLoadCaller` itself.
- The WUI needs no change for it: a clone's `/v1/view/me` says
  `operator_reader` false, so the Expenses page draws no cards at all.
- Unchanged for the product owner: `fleetLoadCaller`, `monitoringStaff`, the
  lane console, the Topics tab, Finance and Incomes. (For an act-as clone,
  SPL-5369 changed two of them, above: `fleetLoadCaller` refuses its writes
  and the lane console gate is `operatorAdmin`.)


## 15. Billing accounts and their invoices (SPL-5220)

Owner HUM-10, csitea #laskut f655b326, relayed by c-004: "there should be 1..1
billing accounts for the [owner login]"; "the shell action to fetch all of the
invoices for all of the billing accounts for the last 12 months from the day of
the call". Msg 92e8e78d: "Create a service account which will be able to fetch
and update the billing the same way I personally do." Answer to the A/B/C poll
(msg b980e841): **B**, "also script the console download in a browser with your
logged-in session (fragile, breaks when Google changes the page, and you have
to log in each time)".

### 15.1 What an API gives (read 2026-11-10, n = 6 project keys)

- The Cloud Billing API (v1 and v1beta, discovery revision 20261106) has no
  invoice, document or payment method. The invoice PDFs come from the console
  only (Billing > Documents). Neither a service account nor a gcloud login
  can fetch them.
- An SA with billing-account roles can list the accounts and their projects,
  move a project's billing, and read the monthly amounts from the BigQuery
  billing export (4.2).

### 15.2 The billing SA

- `env.cost.gcp.billing_sa` = `spl-billing`, in `export_project`
  (`csi-spl-all`, the cnf's "-all").
- Terraform step `002-gcp-billing-sa` (SPL-5265; owner, f655b326: "the sa
  account must be created as terraform step") creates it and grants
  `roles/bigquery.jobUser` on csi-spl-all, and its one key (below). It is rendered
  from prd only and runs as the csi-spl-all SA, its state in
  `csi-spl-all-tfstate` (the 059 pattern); its own state means adding it
  recreates no other step. Plan:
  `cd csi-spl-iac && ./run -a do_gcp_billing_sa_tf` (it lists the billing
  account ids as the csi-spl-all SA and runs
  `make do-tf-plan ENV=prd STEP=002-gcp-billing-sa`, the ids masked); the
  apply is the owner's go.
- The step also grants `roles/billing.viewer` and `roles/billing.user` to
  the billing SA on EACH billing account (SPL-5506; owner HUM-10, #laskut
  f655b326, msg a508c121: "I grant csi-spl-all Billing Admin once; Terraform
  does the rest"). Precondition, the owner's one manual grant: the csi-spl-all
  SA holds Billing Account Administrator on that account. The ids are never
  committed: `var.billing_account_ids` (no default, refused when empty) comes
  from `GCP_BILLING_ACCOUNT_IDS` at run time (`TF_VAR_billing_account_ids`). Its README:
  `csi-spl-iac/src/terraform/002-gcp-billing-sa/README.md`.
- The step also grants `roles/bigquery.dataViewer` to the billing SA on the
  billing export dataset only, `env.cost.gcp.export_source_project` /
  `export_source_dataset` (csi-spl-prd / csi_spl_prd), so
  `do_gcp_billing_invoices_fetch` reads the amounts (SPL-5799; owner HUM-10,
  #laskut f655b326, msgs 92f3fb10 and 303bd484: "Second provider in terraform
  step 002, running as the csi-spl-prd service account"). The csi-spl-all SA
  has no role on that dataset (measured 2026-11-17: `testIamPermissions` on
  csi-spl-prd granted it none of `bigquery.datasets.*`), so the grant goes
  through a second google provider, alias `export_source`, that runs on that
  project's own key `~/.gcp/.<org>/key-<export_source_project>.json` (the
  025 "parent" pattern).
- `do_gcp_billing_sa_create` creates nothing since then (`DRY_RUN=0` is
  refused), so the step is the one creator. As the csi-spl-all SA it reports
  whether the SA and its jobUser exist, names the step when they do not, and
  PRINTS the owner's own steps, which stay outside terraform:
  - Billing Account Administrator for the csi-spl-all SA on each billing
    account, once (owner msg a508c121): step 002 then makes the viewer and
    user roles;
  - `roles/billing.projectManager` on a project it is to move.
- Its key is made by step 002 too (SPL-5457; owner HUM-10, #laskut
  f655b326, msg 8d767855: "change the Terraform code to actually provision
  the key on the file system while provisioning the account"). It is ONE
  key (not per env), written to the applying user's
  `~/.gcp/.<org>/key-<org>-<app>-billing.json`, mode 0600, never in git, an
  output or a log. This is the one exception to the repo rule "no key in
  terraform state": the private key is in the step's state,
  `gs://csi-spl-all-tfstate/terraform/002-gcp-billing-sa`, readable by
  csi-spl-all's owners and editors.
- Moving a project's billing, and closing an account, are the owner's go for
  each call. No action here does either.
- The tf logs mask the ids (SPL-5797): `do_tf_apply` / `do_tf_destroy` and
  their twins, and `do_tf_plan_pending`, pipe terraform through `do_tf_log_mask`, so
  stdout and `csi-spl-iac/dat/log/tf_*.log` keep only the last 4 chars of an
  id. `gcloud billing accounts get-iam-policy <id>` takes no `--account`
  (it collides with the command's ACCOUNT argument, HTTP 400): use
  `CLOUDSDK_CORE_ACCOUNT` in a throwaway `CLOUDSDK_CONFIG`. Detail: the step
  002 README section 5.
- Those logs are 0640 and the apply / destroy never prompts (SPL-5822, the
  SPL-5797 follow-ups): `do_tf_log_open` (same file as `do_tf_log_mask`)
  creates each `tf_*.log` 0640 before the first `tee -a`, and lowers one that
  already exists (with the boxes' umask 0002 tee made it 0664: every local
  user read terraform's output). The five apply / destroy actions pass
  `-input=false`, their `plan -destroy` dry run too: a missing variable fails
  at once instead of waiting on an `Enter a value:` prompt that the line
  filter holds back and a cron run never answers. Test:
  `csi-spl-iac/src/bash/tests/tf-apply-no-input.tst.sh`.

### 15.3 `do_gcp_billing_invoices_fetch` (read only)

It runs as the billing SA only: its key (`BILLING_SA_KEY_FILE`) is activated in
a throwaway `CLOUDSDK_CONFIG`, with `--account` on every call. A key of another
SA is refused, and so is a missing key; the owner account is never a fallback.
For the invoice months of the last `BILLING_MONTHS` (12) months from the day
of the call (2026-11-10 gives 202511..202610: every invoice issued in that
year), it writes into `BILLING_OUT_DIR` (default
`$HOME/.local/share/<org>-<app>/billing-invoices`, mode 700, refused inside a
git work tree, since it holds unmasked account ids and the PDFs):
`accounts.tsv`, `projects-<id>.tsv`, `amounts.tsv` (cost + credits per
account-month, from the export) and `summary.tsv` + `README.md`, the PDF
checklist. A month counts as `have` when a PDF dated the next month is
under `pdf/<id>/`. Ids are logged masked.

### 15.4 `do_gcp_billing_invoices_browser` (the owner's, choice B)

- The owner runs it at his own desk, as himself. It refuses when it sees an
  agent, and these are ALL its checks:
  - `AGENT_ID`, `SPOOL_AGENT_ID` or `CLAUDECODE` set;
  - `SUDO_USER` set: the fleet wraps agent calls in `sudo -u <user> bash -c`,
    which drops the three markers above (R7 c-526, n = 1);
  - an ancestor process (read from `/proc`, up to pid 1) whose comm is
    `claude`, `agy`, `grok`, `vibe` or `qwen`;
  - no terminal on stdin, or neither `DISPLAY` nor `WAYLAND_DISPLAY` set
    (any value passes: it is not a proof of a person).

  A caller that hides all of these gets through. So the run keeps nothing
  worth taking:
- It opens a visible google-chrome on a THROWAWAY profile:
  `chromium.launch()` + `newContext()`, never a persistent context.
  playwright-core 1.65.0 makes the profile under `os.tmpdir()` and removes it
  on close (read in its `coreBundle.js`, the `playwright_<name>dev_profile-`
  mkdtemp). The action points `TMPDIR` at a fresh mktemp dir, mode 700, and
  removes that dir when the run ends, on Ctrl-C, TERM and HUP too. Only a
  SIGKILL leaves it, under the system tmp dir. The owner logs in himself on
  each run, as his B answer says ("you have to log in each time"). No
  session survives the run; no password or cookie is read, logged or stored.
- For each account (`BILLING_ACCOUNT_IDS`, or the newest fetch run's), it opens
  the account's overview (`/billing/<id>`) and follows the console's own
  Billing navigation link to **Invoices** (a self-serve account), else to
  **Payment status** (an invoiced account), the pages Google's get-invoice
  how-to names (read 2026-11-17). It never opens a hard-coded deep path: the
  old `/billing/<id>/documents` answered "URL not found" (owner, #laskut
  f655b326, msg 917d252a; SPL-5810). There it picks the invoice rows dated in
  the window (`src/js/billing-invoices/lib.mjs`) and saves each one, one row
  at a time (a row's download control, else its checkbox and "Download
  selected", which gives one PDF for one row, else the row's menu item
  "Download"), as `pdf/<id>/<date>-<number>.pdf`, the checklist the fetch
  ticks off. The list is read from the payments.google.com iframe when there
  is one, else from the page, and only once no progress bar shows and its
  row count reads the same three polls in a row (R7 c-073 W1). After the
  saves it counts the rows three more times, a poll apart, and fails the
  account when the count changed (R7 c-073 N6). That counts polls, not time:
  a list that shows the same partial count for up to five polls and then
  grows fails; one that shows it for six or more polls, with no progress
  bar, is still read half full and exits 0. A link off
  console.cloud.google.com is never followed.
  `BILLING_DRY=1` lists the rows and saves nothing.
- **playwright-core is pinned to 1.65.0** and installed at run time on the
  owner's desk with npm, once, into `BILLING_PW_DIR`
  (`$HOME/.cache/<org>-<app>/playwright-core-1.65.0`). It drives the
  installed Chrome and downloads no browser.
- FRAGILE, as the owner accepted: a "URL not found" page (the overview, or
  the page behind the entry), no Invoices or Payment status entry, no
  documents list, a list that never stops loading, has a next page or
  changed its row count after it was read, no
  invoice row in the window (Google changed the page, or the account has
  none), or a download that is not a PDF (a name not ending in `.pdf`, a zip
  among them, or a saved file not starting `%PDF-`, which is removed) fails
  that account with ONE line,
  `FATAL XXXXXX-XXXXXX-XX<last 4>: <what was looked for>`; the run saves the
  other accounts and exits 2, never 0 with nothing saved. A Chrome that
  does not start prints one FATAL line (no stack) and exits 2. It guesses
  nothing.

### 15.5 Tests

`csi-spl-iac/src/bash/tests/gcp-billing-invoices.tst.sh` runs offline, with
gcloud, curl, npm and node stubbed. The fetch cases use the real pin lib. The
test covers:

- `--account` on every call, one throwaway config, and that
  `~/.config/gcloud` is never made;
- the 12-month window, the amounts and the `have` tick;
- the refusals and the masked ids;
- the SA dry run against its `DRY_RUN=0` control;
- the browser's refusals: each env marker, `SUDO_USER` with the markers
  dropped, each agent ancestor name, a real `/proc` walk under a bash copy
  named `claude`, no terminal; red against the c98d86148 guard (10 FAILED);
- the pinned install, and the terminal case run through script(1): a fresh
  mode-700 `TMPDIR` that is gone after the run and after a TERM, and
  `download.mjs` with no persistent context;
- the out dir inside a git work tree, refused before any call;
- `node --test` of `lib.mjs` on synthetic rows and page snippets;
- `download.mjs` itself on static console pages
  (`src/bash/tests/fixtures/billing-invoices/*.html`) through a fake
  playwright-core: the overview's Invoices link and the Payment status
  fallback are followed and `/documents` is never opened; the not-found
  overview, no entry, a not-found page behind the entry and an empty
  Invoices page each give one masked FATAL line and rc 2. CONTROL: the old
  `/documents` path on the same pages fails (SPL-5810). After R7 c-073: a
  lazily filling list gives all its rows (CONTROL: one read gives 1 of 3,
  rc 0); a list partial for 3 or 5 reads and then whole fails on the
  recount (CONTROL: without the recount, 1 of 3, rc 0); a list still
  loading or with a next page, and a link off the console, fail; the direct, checkbox and menu download paths save real
  `%PDF-` files; a zip or a non-PDF body fails with nothing left; the
  payments iframe beats the page's own table; an entry with no href is
  clicked by name; a Chrome launch error is one line.

Not covered: the real console page. Only the owner's own run can show it.

### 15.6 `do_spl_hub_cost_invoice_import`: the invoice month totals (SPL-5802)

Owner HUM-10, #laskut f655b326, msg 92f3fb10, answer 2: "A — The 12 invoice
PDFs: you download them, a new lane imports the month totals". The owner
puts the PDFs in one dir; the action (csi-spl-orc) imports them:

- `COST_INVOICE_DIR` (required, no default): every `*.pdf` under it, sub
  dirs too, so the browser action's `pdf/<account id>/` works as is.
  `pdftotext -layout` reads each, `src/bash/scripts/invoice-pdf-month-totals.py`
  parses it: the month (the service period line, else the month before the
  file's `YYYY-MM-DD-` prefix), the billing account (from the text, else the
  dir name; only its last 4 are ever written), the net before VAT (the
  `Subtotal` or `excl. VAT` line) and the currency. A field it cannot
  read is `-` with `unparsed:<field>`, never a guess: `1,234` and
  `1.234,567` are not read (thousands or decimals cannot be told
  apart), and the net is never the first of several. Two or more
  different subtotals give the one that adds up with the `VAT` line to
  the `Total` line, else no net; a single subtotal that does not add up
  with them (when both exist) is refused too.
- It writes `COST_INVOICE_TSV` (default `<dir>/month-totals.tsv`, mode 600,
  refused inside a git work tree). `COST_INVOICE_CMD=totals` stops there,
  with no cloud call.
- `import` (the default, `ENV=dev|prd`) reads, as the env's project SA, the
  hub's cloud cost entries (period and label only) and the gcp days of
  `cost_lines` (read only, counts only), and prints the table: month,
  account last 4, net, currency, action. It never double counts: a month
  with a cloud entry labelled Google Cloud or GCP is `conflict:cost_entry`;
  a month the billing export holds any day of is
  `conflict:cost_lines=<n>/<days>` (some days too: an invoice total on top
  of them would count those days twice); a net of 0 or less, a second
  invoice of the same month and account, and an unparsed row are skipped.
  Only `create` rows are written, each through `do_spl_hub_cost_entries
  COST_CMD=create` (cloud, the net, label `Google Cloud (billing account
  ending <last4>)`, fixed: the conflict check reads that label, so a
  re-run finds the rows it wrote).
- `DRY_RUN=1` (default) runs each create row through that action's dry
  create and prints the table's sha256. `DRY_RUN=0` needs
  `COST_INVOICE_PLAN_SHA` equal to it: only the table the owner OKed is
  written. The table is the one output with amounts; no billing account id
  is printed, a PDF only by its base name.
- Test: `csi-spl-orc/src/bash/tests/spl-hub-cost-invoice-import.tst.sh`
  (synthetic invoices, the hub and the `cost_lines` read stubbed, one real
  PDF through `pdftotext` when the box has it).
- How the hub READS an invoice entry beside the export lines of the same
  month (a field, not the label; the export days plus the invoice minus
  the export): spec 143 [costs-workspace-views.md](../143-reporting-section/costs-workspace-views.md)
  section 4 (SPL-6086, v0.1 draft).

## 16. Who enters the costs: the accountant roles (SPL-5359)

Owner HUM-10, csitea #csi-fina topic ba50f507, 2026-11-12 09:02Z: "we must
enter into the system all the human-resource costs"; 09:03Z: "so that the
report shows them with the total costs"; 09:06Z and 09:11Z: an
internal-accountant and an external-accountant role in every workspace. The
roles and their grants: spec 025 section 12.

- **What they enter.** The hand-entered cost entries of 4.4 (`cost_entries`,
  rdb 0245, types `cloud` and `hr`), through `GET`, `POST` and `DELETE
  /v1/operator/cost-entries`. Those rows are the estate's (no `tenant_id`),
  so `costs.write` opens the three routes only to a member of the
  **operator** workspace, never a live act-as clone
  (`costEntryGate`, `internal/hub/cost_entries.go`). In any other workspace
  the routes answer as before (403 `operator.workspaces`).
- **What they read.** `GET /v1/tenant/costs` (`costs.read`): the reader's
  workspace answer. The estate answer, the one that lists the hr entries
  under Human on Total, is still the operator admin's and product owner's
  (section 14).
- **Open follow-ups**, not built here:
  1. the estate read for a `costs.write` member of the operator workspace
     (one more case in section 14's rule), so an accountant sees the hr
     entries on Total;
  2. a costs-only browser door for a seat without `topics.read`
     (external_accountant, time_accountant): spec 025 section 12;
  3. the cost-entry UI for an accountant: the Expenses page follows
     `operator_reader`, there is no edit route (create and delete only), and
     an `hr` row is a label and an amount, not a person;
  4. per-workspace hr costs (`cost_entries` has no `tenant_id`).

### 16.2 Human costs per person, component and month, and the month lock (SPL-5433)

Owner HUM-10, t1 #spool-hub-devel topic 2d974709, 2026-11-12 17:47Z: "the UI
to insert the human costs ... remember the accounting peridos monthly and a
total for both the start of the year till now and for the last 12 months".
The design (v4) went to the owner as polls a82c0089, 2ff12c21 and 12c458ad,
all answered 2026-11-13: one line per person (Q1 A); a month closes by itself
on the 6th of the next month (Q2 B); the real name is stored, readable only
by the accountants (Q3 B); the payroll is computed on both sides (Q4 B) for
management reporting (Q5 A); the accountant files with their own tool, the
hub holds no Incomes Register access (Q6 A). It is built in four steps:
(a) this section, (b) the report's groups and last 12 months, (c) the
employer side computed, (d) the worker side (tax cards, net pay, the payslip
check).

- **Store (rdb 0280).** `hr_cost_components`: the components in HUM-24's 8
  groups (`salaries_wages`, `employer_contributions`,
  `working_time_allowances`, `bonuses_incentives`, `leave_absence`,
  `benefits_insurance`, `training_recruitment`, `transport_meals`), a row
  per component, so another country adds rows, not code. `hr_people`: a
  person as a code (`E-01`), department, employment type (`employee`,
  `hourly`, `owner_management`, `contractor`), birth year. `hr_person_names`:
  the real name, whose policy asks the operator scope AND
  `app.costs_names = 'on'`, which the store sets only for a caller holding
  `costs.write`. `cost_entries` gains, on `hr` lines only, `person_id` (none
  = the organisation's line; a person's line needs a component),
  `component`, `source` (e.g. "payslip 2026-10"), `account` (the ledger
  account), `period_kind` (`month`, or `year` for a yearly total on the
  year's January) and `corrects_period`.
- **The month lock.** A month of `hr` lines closes by itself at 00:00
  Europe/Helsinki on the 6th of the next month (`store.CostCloseDay`); the
  hub computes it on each read and write, there is no cron. A yearly line
  follows its year's December. Creating or deleting an `hr` line in a closed
  month answers 409 `month_closed`; a late correction is a line in an open
  month with `corrects_period` (4.5: a closed month is never rewritten).
  Only the operator admin (`operatorWriteCaller`) reopens a month, with a
  reason, and closes it again; both are logged. `cloud` entries are not
  locked.
- **Routes** (`internal/hub/hr_costs.go`, the cost entries' doors):
  `GET /v1/operator/hr-components`; `GET /v1/operator/hr-people` (the names
  only to a `costs.write` member, `names: true`); `POST
  /v1/operator/hr-people` (a `costs.write` member only, 409 `code_taken`);
  `GET /v1/operator/cost-periods/{month}`; `POST
  /v1/operator/cost-periods/{month}/close|reopen` (the admin).
- **The report.** A person's `hr` lines reach the month read summed per
  component under the component's label, so no report row is a person's
  (13.6); a yearly line is left out of the months. The name is never in a
  log line, an export or a test (tests use `FirstName LastName`).
- **The screen** (Expenses -> HR costs, `components/expenses/`): the month's
  lock state ("2026-10 is open; it closes on 2026-11-06", or closed), with
  Close month and Reopen (a reason) for the operator admin; the People list
  (codes for everyone, names only when the hub sends `names: true`) and its
  Add person form for a `costs.write` member; the add form's hr fields
  (person, component by group, source, ledger account, month or whole year,
  corrects month); each row's second line (code, component, source,
  correction). `/v1/view/me` carries `cost_writer` (costs.write in the
  operator workspace, no act-as clone), which opens Expenses with its Cloud
  infra and HR tabs to the accountants; AI costs stays the operator
  readers'. The strings are in every locale (agy reviews them before they
  ship, the language rule).
- **Follow-up 3 above** is this section; follow-up 1 (the estate read for an
  accountant) is step (b), 16.3.

### 16.3 Step (b): the report's groups, the last 12 months, the accountant's estate read (SPL-5433)

- **The accountant reads the estate.** `GET /v1/tenant/costs` answers the
  estate scope to the operator workspace's `internal_accountant` and
  `external_accountant` too (`costEstateReaders`, `readsCostEstate` in
  `internal/hub/operator_read.go`), never to an act-as clone, so the person
  who enters the hr lines sees them on Total and Persons (follow-up 1). Not
  every `costs.write` holder: the operator workspace's `biz_owner` keeps its
  own row only (spec 140 3.10, `TestCostReadEstateScope`). The lanes and the
  other operator reads keep `readsOperatorEstate`. The external accountant is
  still refused at the browser door until follow-up 2 exists.
- **Groups.** Each part of the month answer's `human` list carries its
  `component` and that component's `group` (one of the 8 of 16.2, from
  `hr_cost_components`). Reporting -> Costs -> Persons shows one row per
  group, its components summed, labelled by `expenses.hr.group.<group>`; a
  line without a component keeps its own label as its row. Still no row is a
  person's (13.6).
- **The last 12 months.** The Costs header's period gains "Last 12 months"
  (`?month=l12m`, `COSTS_L12M` in `utils/reporting-costs.mjs`): the current
  month so far and the 11 before it, oldest first, beside the year to date.
  The one new string, `reporting.costs.period_l12m`, is in every locale and
  reviewed by agy before it ships (the language rule).

### 16.4 Step (c): the employer side computed (SPL-5433)

The owner's Q4 B (poll 2ff12c21): the hub computes the payroll, and a typed
payslip value wins with its difference flagged. Step (c) is the employer
side. The worker side (tax cards, the employee's shares, net pay, the payslip
check) is step (d).

- **The rates (rdb 0284 `hr_rates`).** One row per year and employer
  contribution: `rate_pct` (a percent with up to 4 decimals), `applies_to`
  (the employment types it is levied for, default `employee` and `hourly`),
  `source` (where the accountant read it) and who set it. Only a component of
  the `employer_contributions` group takes a rate. `yel` takes none, because
  it is the entrepreneur's own pension and not a share of gross. No rate is
  seeded: the accountant sets each year's rates from the pension insurer's,
  the accident insurer's and the Tax Administration's letters. With no rate,
  nothing is computed for that component.
  - The design (v4 point 3) put the rates in cnf. They live in the hub
    instead, because a cnf value reaches the hub only as a Cloud Run env var
    through terraform, which needs an owner's go per change. A rate changes
    once a year, and the accountant changes it without a deploy.
- **The calculation (`store.ComputeHRPayroll`, pure).** For each person,
  month and currency:
  - **Gross** is the sum of the person's monthly lines in the groups
    `salaries_wages`, `working_time_allowances`, `bonuses_incentives` and
    `leave_absence`. Benefits, training and travel lines are cost
    (**other**) but not gross. A yearly line is not a month's.
  - **Each rated contribution** is computed as gross x rate / 100, rounded
    to cents, when the person's employment type is in `applies_to`.
  - **A typed line wins.** A line of that component whose source does not
    start with `computed:` (a payslip's value) replaces the computed amount.
    A difference above one cent is flagged `diff`.
  - **A booked line counts until it goes stale.** A line whose source starts
    with `computed:` was booked from the calculation, and its amount counts.
    It is flagged `stale` once the calculation moves away from it, or once
    no rate computes that component for the person any more.
  - **The totals.** The employer total is the sum of the amounts that count.
    The cost is gross + employer total + other (Q5 A: the company's cost).
- **Booking.** The cost reports sum `cost_entries`, so a computed amount
  reaches them only once it is booked. Booking a month does three things:
  - it writes one `hr` line for each computed amount that has neither a
    typed line nor an up-to-date booked line (label = the component's,
    account = its `default_account`, source `computed: <year> rates`);
  - first, it removes the month's stale booked lines;
  - it never touches a typed line.

  A second booking with nothing changed writes nothing. A closed month
  answers 409 `month_closed`, as for a typed line.
- **Routes** (`internal/hub/hr_payroll.go`):
  - `GET /v1/operator/hr-rates?year=` and `GET /v1/operator/hr-payroll/{month}`:
    the hr reads' doors. The payroll carries codes, never names.
  - `PUT` and `DELETE /v1/operator/hr-rates/{year}/{component}`, and
    `POST /v1/operator/hr-payroll/{month}/book`: the cost entries' write
    doors (a `costs.write` member of the operator workspace, or the operator
    admin).
- **The screen** (Expenses -> HR costs, `components/expenses/HrPayrollCard.vue`):
  "Employer side, <month>", read when opened.
  - **The table.** One row per person: the code, and the name to a reader
    who holds it. The columns are gross pay, the employer side (each
    contribution with its rate and amount, marked computed, from the
    payslip, booked, "the payslip differs by", or "out of date"), other
    costs and total cost, with a total row per currency.
  - **For a `costs.write` reader:** "Book the computed amounts (n)", where n
    counts the amounts to book and the stale booked lines. A closed month
    offers no booking.
  - **The year's rates** are listed for everyone, and a `costs.write` reader
    sets or removes them in a form (component, rate %, applies to, source).
  - The strings are in every locale (`expenses.hr.payroll.*`).
- **Tests.**
  - `store/hr_payroll_test.go` covers the calculation, flags and bookings,
    the rate checks, and the rate store on both drivers.
  - `hub/hr_payroll_test.go` covers rates, payroll, book, rebook and the
    closed month, with made-up figures in 2007-04. Red control: without the
    stale removal, the rebook leaves two tyel lines.
  - `csi-spl-wui/tests/unit/hr-payroll.test.mjs` covers the rate form, the
    payroll answer as read, and the mock's calculation and book, which follow
    the hub's.
- **Not here.**
  - The unemployment insurance's two payroll bands: the accountant sets the
    band's rate.
  - A rate per insurer policy: one rate per component and year.
  - The worker side: step (d), section 16.5.

### 16.5 Step (d): the worker side and the payslip check (SPL-5433)

The owner's Q4 B (poll 2ff12c21) asks for the worker side too: the
employee's statutory shares, the tax withheld from the tax card with a
running year-to-date income, and the net pay, each checked against the
payslip. Under Q5 A (management reporting) the worker side is part of the
gross: it is never booked, never added to a report or a total, and only the
accountant sees it.

- **The tables (rdb 0286).**
  - `hr_worker_rates`: the employee's share of `tyel_employee` or
    `unemployment_employee`, per year and age band (`age_from`..`age_to`,
    at most 10 bands, no overlap), a percent with up to 4 decimals. The
    accountant sets each year's bands from the pension insurer's and the
    Unemployment Insurance Fund's letters. No row = no share computed.
  - `hr_tax_cards`: one person's card for one year, typed by hand: `base_pct`
    up to `income_limit` of the year's income, `extra_pct` above it.
  - `hr_payslips`: the worker-side values one payslip carries for a person,
    month and currency (`tyel_employee`, `unemployment_employee`,
    `tax_withheld`, `net_pay`), each empty when the payslip does not show it.
  - Tax cards and payslips are personal. Like `hr_person_names`, their
    policy asks `app.costs_names = 'on'` as well as the operator scope, and
    the hub sets it only for a `costs.write` caller.
- **The calculation (`store.ComputeHRWorker`, pure)**, per person, month and
  currency, from the employer side's gross (16.4):
  - **Age** is the month's year minus the person's birth year. Both shares
    go by age band, so a person with no birth year gets no share, and the row
    says `birth_year` is missing.
  - **The shares** (an `employee` or `hourly` person only: an owner in
    management pays YEL, typed as a line, and a contractor invoices) are
    gross x the band's rate / 100, rounded to cents.
  - **Year-to-date** (`store.HRYearToDate`) is the gross of the person's
    monthly lines of the same year and currency before the month.
  - **The tax** (not for a contractor) is `base_pct` on the part of the
    month's gross still under the card's limit after the year-to-date income,
    and `extra_pct` on the part above it. With no card for the year, the tax
    is not computed and the row says `tax_card` is missing.
  - **The net** is gross minus the shares minus the tax, each as it counts.
  - **The payslip wins.** A typed value replaces the computed one, and a
    difference above one cent is flagged `diff`. The net is computed from
    the values that count, so its flag shows only its own difference.
- **Routes** (`internal/hub/hr_worker.go`):
  - `GET /v1/operator/hr-worker-rates?year=` (the hr reads' doors) and
    `PUT /v1/operator/hr-worker-rates/{year}/{kind}` (the cost entries'
    write doors), whose bands replace the year's bands of that share.
  - `GET /v1/operator/hr-tax-cards?year=`, and `PUT` and
    `DELETE /v1/operator/hr-tax-cards/{person_id}/{year}`: a `costs.write`
    member only. Another reader who passes the hr doors gets 403
    `costs.write`.
  - `PUT` and `DELETE /v1/operator/hr-payslips/{month}/{person_id}`: a
    `costs.write` member only, and 409 `month_closed` in a closed month.
  - `GET /v1/operator/hr-payroll/{month}` adds `worker` (one row per person
    and currency) for a `costs.write` member only. Every other reader gets
    the employer side as before.
  - The log names the year or month and who acted, never a card's or a
    payslip's figures.
- **The screen** (Expenses -> HR costs, `components/expenses/HrWorkerCard.vue`):
  "Worker side and payslip check, <month>", read when opened, and mounted
  for a names reader (`costs.write`) only.
  - **The table.** One row per person and currency: the code and the name,
    gross pay, the year's income (and the part before this month), each
    employee's share with its rate, the tax withheld with the card's figures,
    and the net. Each value is marked computed, from the payslip, or "the
    payslip differs by"; a missing tax card or birth year is named.
  - **The forms:** the month's payslip values (person, currency, any of the
    four values; Remove), the year's tax cards (listed; person, base %,
    extra %, income limit, source; Remove), and the year's age bands per
    share (listed; share, ages, rate %, source; Remove).
  - The strings are in every locale (`expenses.hr.worker.*`).
- **Tests.**
  - `store/hr_worker_test.go` covers the calculation (age bands, the limit
    crossed in a month, owner and contractor, a missing birth year or card),
    the payslip check, the checks, the store on both drivers, and on
    Postgres that both personal tables hide without `app.costs_names`.
  - `hub/hr_worker_test.go` covers bands, card, payslip and the payroll's
    worker side with made-up figures in 2005, the product owner's payroll
    with no worker side, and the closed month, plus every wrong caller on
    every new route. Red control: without the `readsHRNames` check in
    `handleHRPayroll`, the product owner's payroll carries `worker`.
  - `csi-spl-wui/tests/unit/hr-worker.test.mjs` covers the three forms, the
    worker side as read, and the mock's calculation (the hub test's figures).
    The e2e opens the card and adds and removes a band.
- **Not here.**
  - Filing to the Incomes Register (Q6): the accountant files with their own
    tool.
  - The tax card's withholding rate for a second job, the 60 % rate with no
    card, and taxable benefits in the tax base: the tax base is the gross of
    16.4.
  - A tax limit counted across currencies: year-to-date is per currency.

### 16.5 The cost labels in the interface language, with a master language (SPL-5546)

Owner HUM-10, csitea 720fa031, 2026-11-14: "the labels in this view should
be in the language of the interface"; "the data those labels must be stored
in language aware table"; "there should be a master language where those
should be fetched from the db". Before this, Persons showed each
hand-entered line's one free-text label, in whatever language it was typed.

- **Tables (rdb 0285).** `cost_label_settings` holds the estate's master
  locale, the language `cost_entries.label` is written in (one row,
  seeded `en`: the owner's answer to poll 1e669c40, csitea msg 98e46028,
  2026-11-15, "B — English (en)"). `cost_entry_labels` holds one label per
  (entry, locale); `hr_cost_component_labels` one per (component, locale),
  `en` seeded from rdb 0280. Operator scope, like rdb 0245. The migration
  copies every existing `cost_entries.label` once as its master-locale row,
  untranslated: other languages are entered by the accountant.
- **The master text is the key.** Cost allocations match an item on
  `project_or_vendor`, the entry's own text (`hub/cost_allocations.go`), so
  that text never changes with the reader's language: the master locale's
  label equals it, is written when the entry is entered, and is never edited
  through the labels.
- **Reading.** The reader's locale is `?locale=`, else `X-Locale`, else
  `Accept-Language`. A label is that locale's, else the master locale's,
  else the entry's own text (a component's: then `en`, then its seed).
  `GET /v1/tenant/costs` gives each hand-entered part (its own or a
  workspace's share of one) a `label` where that differs from
  `project_or_vendor`; `GET /v1/operator/hr-components` answers the labels
  in the locale; `GET /v1/operator/cost-entries` gives each entry its
  `labels` map and the answer its `master_locale`.
- **Writing (the write rule, as built by rdb 0303 and rows L2, L3 and the
  fill fix; 16.6.4).** Every label row carries `origin` (`hand` or
  `machine`), `source_text` (the master text it was made from, NULL on the
  master row) and `reviewed_at` (when agy confirmed a machine row). Four
  writers, one rule: a machine write never touches a hand row.
  - *A person*, `PATCH /v1/operator/cost-entries/{id}/labels {labels:
    {locale: text}}` (1..100 characters, one of the 19 locales; a
    master-locale text other than the entry's own is 400
    `bad_cost_labels`). It writes per row, not the whole set
    (`SetCostEntryLabels`): a locale whose text differs from the stored row
    becomes `hand`, `source_text` = the current master text, `reviewed_at`
    NULL; a locale sent unchanged keeps its row as it is (a machine row stays
    `machine`); a locale left out is deleted. The rows are written on every
    entry with the same master text, in one transaction (owner answer 5
    `t`). The master row is never touched. It has the cost entries' write
    door (costs.write in the operator workspace). A label is display text,
    not a booked amount, so a closed month does not refuse it, and no
    amount, period, person or split changes.
  - *A new entry*, the POST: its master row (`hand`) and, in the same
    transaction, the other locales' rows of the newest entry with the same
    text that has any, origin and review mark kept (`pgCostLabelKnownCopy`).
  - *The hub's draft and agy's review* (16.6): `SetMachineCostLabels`,
    keyed by a text (every entry with it) or an hr component, an upsert
    whose `ON CONFLICT ... DO UPDATE` carries `WHERE <table>.origin =
    'machine'`; `source_text` = the current master text, `reviewed_at`
    `now()` for agy's review, NULL for a draft. The master locale is never
    machine written.
  - *The fill action* `do_spl_cost_labels_fill` (next point): the master
    row `hand`, every other row `machine` with its `source_text`, under the
    same guard (b89c25431, SPL-6165).
- **WUI.** The Costs label pages read in the interface language
  (`useCostsPeriod` sends `?locale=` and reloads on a language switch);
  Persons and Cloud show `label`, keyed by `project_or_vendor`. Expenses
  shows, under each hand-entered line, "Other languages": the master text
  and a row per other language to add, edit or remove
  (`components/expenses/CostEntryLabels.vue`). Its strings are in every
  locale and reviewed by agy before they ship (the language rule).
- **Filling the existing labels (SPL-6053).** The owner's poll f0c06053,
  answer A (csitea 720fa031, msg fb2ae7ee): "fill all 19 languages for every
  existing label now". `cd csi-spl-orc && ENV=<env> LABELS_MAP=<file>
  ./run -a do_spl_cost_labels_fill` reads a mapping file kept out of git
  (estate data: refused inside a git tree or readable by other users) that
  carries each entry text and hr component in all 19 locales, and writes
  them in one transaction. DRY_RUN=1 (the default) prints only counts per
  table and locale and rolls back. The master text stays the key, so the
  action renames `cost_entries.label` to the master-locale (`en`) text and
  writes the master row with it in the same transaction. It refuses when a
  `cost_allocations` row keys on a text it would rename. The source
  language's row keeps the text as typed. It writes by SQL in one
  transaction, not through the PATCH, which refuses the master row;
  components have no route. Since b89c25431 (SPL-6165) it follows the write
  rule above: every other-locale row `machine` with its `source_text`,
  never over a hand row; a rename re-makes the machine rows from the new
  text and keeps the hand rows, stale. A second run changes nothing. Test:
  `csi-spl-orc/src/bash/tests/spl-cost-labels-fill-pg.tst.sh`. New or
  edited labels are translated on save: 16.6.
- **Tests.** `store/cost_labels_test.go` (both drivers),
  `hub/cost_labels_test.go`, `tests/unit/cost-entries.test.mjs`,
  `tests/unit/costs-labels.test.mjs`, the e2e
  `tests/e2e/reporting-costs-labels.test.mjs` (`personsLanguage`: Persons
  in `/bg/` reads the bg label, the keys unchanged).

### 16.6 Every new or edited cost label in all 19 languages on save (SPL-6057, v1.0, as built)

Owner HUM-10, csitea 720fa031: "Every label MUST be in the curretly selected
lanaguage in the language settings of the user !!!" (msg 43a43e76), and the
answer to poll f0c06053 (msg fb2ae7ee): "A — Both: fill all 19 languages for
every existing label now, and a second lane translates every new or edited
label into all 19 on save". This section is the second half. The first half,
the labels already in the tables, is `do_spl_cost_labels_fill` (16.5).

Every owner question is answered (16.6.8). In short: the hub translates a
new label at once through Google Cloud Translation in its own GCP project,
with names masked first. Readers see that text straight away, marked
unreviewed. A nightly run sends the machine text, still masked, to agy, who
confirms or corrects it.

v1.0 describes the code as landed (rows L0-L6, 16.6.1), not the plan; where
the code differs from v0.4, the text says so. Read 2026-11-22 on
`49f34bef6`.

#### 16.6.1 What landed, and what is still open

| row | sha | issue | what |
|---|---|---|---|
| L0 | `ad950c0e8`, `4a1c86baa` | SPL-6132 | `translate.googleapis.com` on step 001's `gcp_services` (cnf `all.env.yaml`, both envs' rendered 001 tfvars); `google_project_iam_member.hub_cloudtranslate_user` (`roles/cloudtranslate.user`) on the hub's runtime SA in `030-cloud-run-hub/03-runtime-sa.tf`; the step-030 importer covers it |
| L1 | `8e8236820` | SPL-6133 | rdb `0303_cost_labels_origin.sql`: the three columns on both label tables |
| L2 | `cb64560e0` | SPL-6141 | the store (16.6.4), both drivers |
| fill fix | `b89c25431` | SPL-6165 | `do_spl_cost_labels_fill` writes `machine` rows with `source_text`, under the guard (R7 finding W1 on L2) |
| L3 | `3d1d453e2`, `7814d8a61`, `402b88141`, `5e35e46e5`, `267bd3bbd` | SPL-6173 | the dev measurement; `internal/i18nmask`; `internal/translate`; the draft on save, the three routes, `label_origins` and `stale_locales`; the openapi document |
| L4 | `c25211556` | SPL-6201 | `do_spl_cost_labels_translate` |
| L5 | `9de071fa0` | SPL-6207 | `do_spl_cost_labels_translate_install_cron`, cnf `env.cost.labels_translate_utc` |
| L6 | `743f68e90` | SPL-6203 | the Expenses marks |

Served: `cd csi-spl-orc && ENV=<env> ./run -a do_check_deploy_lag`
(2026-11-22) -> hub `served=4dd74b36` and wui `served=f6703d2b` on dev and
on prd; `git merge-base --is-ancestor` puts `5e35e46e5` (L3) in both and
`743f68e90` (L6) in `f6703d2b`.

Still open on `49f34bef6`:

- **The hub calls no API yet.** The draft is off unless the hub's
  environment sets `SPOOL_HUB_COST_LABELS_TRANSLATE_URL`, and nothing sets
  it: `git grep -n 'COST_LABELS_TRANSLATE' -- csi-spl-cnf csi-spl-iac` -> 0
  lines. So the POST drafts nothing and `POST .../cost-labels/fill` answers
  503 `translate_unavailable`; the night run (L4) then logs the fill as a
  WARN, reviews what exists and exits 3. The wiring (cnf rows, step 030's env, the
  tpl-gen template) is row L3w (brief
  `hand-sat-c001-s123-l3w-translate-env-cnf-030`), queued, not on master.
- **The L0 applies** (dev, then prd, each on the owner's go): not recorded
  on master; this row did not read GCP.
- **The price** row L0 was to record is not recorded. The 30-character
  sizing in 16.6.3 stands as an estimate; the dev measurement counted about
  660 characters sent per text with the span markup (16.6.3).
- **agy's schema measurement** (row L4's first step, n = 20) is not run: the
  box that built L4 had no agy. The action carries it as
  `TRANSLATE_CMD=measure MEASURE_N=20 ./run -a do_spl_cost_labels_translate`
  for a box with a signed-in agy; until then the action validates agy's JSON
  itself and does not pass `--json-schema` (16.6.6).
- The first prd night run (`DRY_RUN=0`) and the prd cron install each wait
  for the owner's go; dev first.

#### 16.6.2 The trigger

The unit of work is a **master text**, not an entry: every entry with the
same text reads the same labels (`costLabelsInSQL` keys labels by text), so
a text is translated once. An hr component is its own unit, keyed apart.

1. **On the POST, a known text is copied (sync, no vendor).** In the same
   transaction as the master row, the store copies the other locales' rows
   from the newest entry with the same text that has any, keeping each
   row's origin, `source_text` and `reviewed_at` (`pgCostLabelKnownCopy`,
   `store/cost_entries_postgres.go`). A recurring line is then in every
   language it had the moment it is saved, at no cost.
2. **On the POST, a missing text is translated at once (owner answer 1
   `b`).** After the transaction commits, still inside the request, the hub
   runs the fill for that one text (`costLabelDraftNew`,
   `hub/cost_labels_machine.go`): it masks the text (16.6.5), takes the
   characters from the daily cap, calls Google Cloud Translation once per
   missing locale in parallel under one deadline, unmasks, checks each
   answer (16.6.6) and writes the rows `machine`, `reviewed_at` NULL. The
   deadline is `SPOOL_HUB_COST_LABELS_TRANSLATE_TIMEOUT`, default `8s`, not
   v0.4's proposed 5 s: the dev measurement's p95 per call was 5.32 s, max
   5.74 s. The POST answers 201 whatever the API did: a failed or late call
   leaves its locales missing (point 3), it never fails or rolls back the
   save. A known text the copy made whole calls nothing.
3. **A text is *missing* when any of its entries lacks a non-master locale,
   or holds a machine row made from another text** (`MissingCostLabels`;
   for a component, against its master text). That is a query, not a queue
   table, so a failed call, the fill action's leftovers and an hr component
   whose migration carried only its `en` label are all picked up by
   `POST /v1/operator/cost-labels/fill`, the night run's first step, the
   same code as point 2.
4. **Until the rows exist the reader sees the fallback** (16.5): its
   locale's label, else the master locale's, else the entry's own text. Once
   the machine rows exist the reader sees them at once, unreviewed (owner
   answer 2 `d`); Expenses marks them (16.6.7, L6).
5. **A master text that changes** (a future edit route, a migration that
   rewrites an hr component's `en`, the fill action's rename) makes every
   machine row made from the old text *stale* (`source_text` differs); stale
   machine rows count as missing and are re-made. A hand row is never
   re-made, only listed stale (16.6.4).
6. **Every night (owner answer 3 `1d`) agy reviews** the machine rows not
   yet reviewed (16.6.3, owner follow-up answer 1 `a`).

#### 16.6.3 Who translates

Decided by the owner (answers 1 `b`, 2 `d`, 3 `1d` and the follow-ups `a`,
`m`, `g`; 16.6.8):

| step | who | sees | writes |
|---|---|---|---|
| draft, on save and in the fill | the hub, `internal/translate`: Google Cloud Translation v3 `translateText` at `SPOOL_HUB_COST_LABELS_TRANSLATE_URL` (`https://translation.googleapis.com/v3/projects/csi-spl-<env>/locations/global`) | the masked text only (16.6.5) | `origin = 'machine'`, `reviewed_at` NULL, `updated_by = 'hub-translate'` |
| review, nightly | `do_spl_cost_labels_translate` (csi-spl-orc) on the desk box, one agy `--print` call per run that finds work | the masked text and the masked machine drafts, from the hub | through the hub: the confirmed draft or the correction, `reviewed_at = now()` |
| correction, any time | a person, the PATCH | everything, as before | `origin = 'hand'` |

- **Identity.** The hub calls the API as its own runtime SA, with the Cloud
  Run metadata server's token (`translate.MetadataToken`, cached until a
  minute before it expires): no key file, no secret. Row L0 gives that SA
  `roles/cloudtranslate.user` on its own project (v3 has no resource-level
  IAM, so the project role is the narrowest).
- **Cost.** The daily cap is `SPOOL_HUB_COST_LABELS_TRANSLATE_DAILY_CHARS`,
  default 200000 characters, `0` = no cap. It counts what is sent (the
  masked text with its span markup, times the locales asked), per UTC day,
  **in each hub process**: a restart starts the count again, and each Cloud
  Run instance keeps its own. A text over the cap is counted `capped` and
  waits for the next fill. Measured on dev (`internal/translate/testdata/
  measurement-dev-2026-11-21.md`, n = 20 texts x 18 locales): 13158
  characters sent, about 660 per text. The price is not recorded (16.6.1).
- **The language rule** (agy has the last word): it holds, a night later.
  Until then the reader sees the API's text, marked unreviewed.
- **Locales.** The dev measurement: all 18 non-master locales answered 20 of
  20, `he`, `mk` and `sr` included, so no locale code mapping is needed; the
  no-translate span came back intact 360 of 360 (evidence on that sample,
  not proof of absence).
- **Not chosen:** a claude draft (the API drafts), an agent lane per label,
  a batch every few minutes.

#### 16.6.4 Hand edits are never overwritten

rdb `0303_cost_labels_origin.sql` (row L1) adds to both `cost_entry_labels`
and `hr_cost_component_labels`:

- `origin text NOT NULL DEFAULT 'hand' CHECK (origin IN ('hand','machine'))`.
  The migration made every other-language row already in the tables
  `machine` (owner answer 4 `mc`) and the master-locale row `hand`; with no
  master locale set, every row `hand`. Only a person's PATCH writes `hand`
  after it; the master row is `hand` through the column default.
- `source_text text`: the master text the row was made from; NULL on the
  master row. The migration set it to the entry's (component's) own text.
- `reviewed_at timestamptz`: when agy confirmed or corrected a machine row;
  NULL until then and on a hand row. Every existing row started NULL, so the
  first night's run reviews them too.

The writes are 16.5's write rule. In short:

- **A person (the PATCH)** writes per row on every entry of the text: a
  changed locale becomes `hand` with `source_text` = the current master
  text; an unchanged one keeps its row; a locale left out is deleted, and
  the next fill makes it again as `machine` (Expenses says so).
- **The hub's draft and agy's review** both go through
  `SetMachineCostLabels`, keyed by exactly one of a text and a component;
  its upsert carries `WHERE <table>.origin = 'machine'`, so a hand row is
  skipped in SQL and a person who corrects a row between a read and a write
  still wins.
- **The fill action** writes `machine` rows under the same guard; on a
  rename it re-makes the machine rows from the new text in the same
  transaction and keeps the hand rows, stale.
- **Stale hand rows** (the master text changed after a person corrected the
  row) are kept, never re-made, and listed in the entries' GET as
  `stale_locales`; Expenses marks them for the accountant to re-check.

`GET /v1/operator/cost-entries` keeps `labels {locale: text}` and adds
`label_origins {locale: hand|machine|reviewed}` (`reviewed` = a machine row
with `reviewed_at` set, the master row `hand`) and `stale_locales [locale]`
(sorted; hand rows only, a stale machine row is re-made instead); nothing
existing changes shape.

**The routes (row L3, `hub/cost_labels_machine.go`):**

| route | door | answer |
|---|---|---|
| `POST /v1/operator/cost-labels/fill` | `operatorWriteCaller`: the operator workspace's admin or the operator service account | 200 `{texts, written, refused, failed, capped}` (counts only); 503 `translate_unavailable` when the hub names no translate URL |
| `GET /v1/operator/cost-labels/unreviewed` | the same | 200 `{items: [{key, source_sha, masked_text, masked_drafts: {locale: text}}]}` |
| `PUT /v1/operator/cost-labels/reviewed {key, source_sha, labels: {locale: masked text}}` | the operator service account only (a `Bearer` token; anything else 403 `not_operator`) | 200 `{written, refused: {locale: why}}`; 409 `stale_source` |

An accountant's costs.write opens none of the three (403). A store without
labels answers 501.

- `key` is opaque: `t:` + the first 16 bytes of sha256 over the text (so the
  id carries no label), or `c:<component>`.
- `source_sha` is sha256 over the master text and its masked form: it
  changes when the text or the term list that masks it changes. The PUT
  answers 409 `stale_source` when it differs, and also when the key names
  no unreviewed text or component any more (its text changed, or it was
  reviewed meanwhile).
- The unreviewed read per text is its newest entry's machine row per locale
  made from the current text, `reviewed_at` NULL (`UnreviewedCostLabels`).
- The PUT refuses per locale (`refused`): `not_asked` (no unreviewed draft
  in that locale), then the 16.6.6 checks; the rest are written reviewed.

#### 16.6.5 What leaves the box, and to whom

- **Only the label TEXT**, never the amount, currency, period, note, person,
  account or entry id.
- **The hub masks before anything leaves it** (owner follow-up answer 2
  `m`): `internal/i18nmask`, the Go port of spec 115's `do_spl_i18n_mask`.
  Emails and phone numbers by pattern, then the terms of the hub's own list,
  built on each call (`costLabelMasker`): every hr person's name, whole and
  each part of two letters or more (`NAME`), and every workspace's display
  name and id of two characters or more (`WORKSPACE`). Each match becomes
  `[EMAIL_n]`, `[PHONE_n]`, `[NAME_n]`, `[WORKSPACE_n]`. The shared fixture
  `csi-spl-orc/src/bash/tests/fixtures/i18n-mask/` keeps the two giving the
  same tokens (`spl-i18n-mask-fixture.tst.sh` on the bash side,
  `i18nmask/mask_test.go` on the Go side). The mask is deterministic for one
  text and one term list, so the hub rebuilds the token map instead of
  storing it: no map leaves the hub or is written anywhere.
- **To Google Cloud Translation** (owner follow-up answer 3 `g`): the masked
  text HTML-escaped, `mimeType: text/html`, each token wrapped `<span
  translate="no">[NAME_1]</span>` (`translate.Wrap`); the answer has its
  spans stripped and is unescaped (`translate.Unwrap`), then unmasked.
- **To agy, nightly:** the unreviewed read's items, masked: the action on
  the box never sees a name and needs no term list. Its prompt and schema
  are `csi-spl-orc/src/bash/run/assets/spl-cost-labels-translate/
  {prompt.txt,schema.json}`: per item `i` and per locale, `ok` or a
  corrected text. The action PUTs it back still masked, and the hub unmasks
  it (a draft is re-masked for the read with the same token map).
- **A term the list does not name is not masked** (spec 115's limit): a
  person who is neither an hr person nor a workspace name, typed into a
  label, reaches the API as typed.
- The hub's log and the run's log carry counts only: texts, locales
  written, refused, failed, capped, stale; never a label and never agy's
  output.

#### 16.6.6 Failure handling

- **Before any write**, each answer, the API's or agy's, is checked after the
  unmask (`costLabelAnswerWhy`); a failed check drops that locale and the
  others are written. The reasons: `token_lost` (a token of the mask is
  missing), `length` (empty or over 100 characters, rdb 0285's CHECK),
  `same_as_master` (equal to the master text, unless the text is one of
  `csi-spl-wui/i18n/i18n-keep-english.json`'s values: the hub keeps a copy,
  `TestCostLabelKeepEnglishInStep` keeps it equal), `token_left` and
  `span_left`. On the dev sample `Bonus Q3` came back as English in 4 of 18
  locales: those stay missing and the next fill asks again.
- **The API on save**: an error, a 429 or the deadline drops the locales it
  did not answer; the save stands. The cap is checked before the call; a
  text over it is `capped`, no call.
- **The night run** (`do_spl_cost_labels_translate`): one run per env at a
  time (`flock -n` on its state dir's `run.lock`), as the env's project SA
  (`do_gcp_pin_account`, never the owner account). `DRY_RUN=1` (the
  default) reads the unreviewed list and prints counts only. With
  `DRY_RUN=0`: the fill (a failure is a WARN; the review still runs and the run exits 3), the
  read (at most `TRANSLATE_MAX_ITEMS`, default 40; the rest wait), one agy
  `--print` call (`--print-timeout` = `TRANSLATE_AGY_TIMEOUT_S`, default
  600), then one PUT per text. agy's answer is checked by the action against
  `schema.json`'s shape; `--json-schema` is not passed until the n = 20
  measurement says it holds (16.6.1). An agy failure, a timeout or an answer
  off the schema writes nothing for the run; the rows stay machine and
  unreviewed and the next night retries. Per locale the action itself
  refuses an empty text, one over 100 characters with no mask token, and one
  holding `<span`; the hub checks the rest.
- The run keeps a per-text failure count in its state dir (`fails.tsv`,
  the key's sha256 prefix); after 3 runs in a row fail the same text, one
  `spool-send.sh` note to the orchestrator (`TRANSLATE_NOTE_TO`, default the
  lease's orch holder; counts and the prefix, never the text), then none for
  that text until it succeeds. agy at its vendor limit is one note per day.
- **Not built:** v0.4's "the hub counts API failures per day on its
  metrics". The hub logs the counts of each draft and fill
  (`cost labels drafted on save`, `cost labels filled`); no metric.
- A 409 `stale_source` drops the text from the run; the next run re-reads
  it.

#### 16.6.7 Rows

Each row was its own lane, files disjoint, in the order of its dependency.
Status on `49f34bef6`: 16.6.1.

| row | what | files | after | done test | red control | status |
|---|---|---|---|---|---|---|
| L0 | infra: the API on step 001, `roles/cloudtranslate.user` on the hub's runtime SA in step 030 | `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf`, the rendered tfvars | - | `do_tpl_gen` + `git diff --exit-code`; dev plan; apply dev, then prd, each on the owner's go | a plan that touches another resource is not applied | landed `ad950c0e8`, `4a1c86baa`; applies not recorded here; price not recorded |
| L1 | the three columns on both label tables | `csi-spl-rdb/src/sql/postgres/spool-hub/0303_cost_labels_origin.sql` | - | `store/cost_labels_test.go` on Postgres | an INSERT with `origin = 'x'` fails the CHECK | landed `8e8236820` |
| L2 | the store (16.6.4), both drivers | `internal/store/cost_labels.go`, `cost_labels_postgres.go`, `cost_entries_postgres.go`, `cost_entries.go`, their tests | L1 | a machine write over a hand row leaves it; an unchanged machine row stays `machine`; a PATCH writes every entry of its text and no other; a POST of a known text lands with its 19 rows | the machine write without its guard turns the hand-row test red | landed `cb64560e0`; the fill fix `b89c25431` |
| L3 | the hub: the Go mask and its shared fixture, the translate client, the draft on save, the three routes, `label_origins` and `stale_locales`. First commit: the dev measurement | `internal/hub/cost_labels.go`, `internal/hub/cost_labels_machine.go`, `internal/i18nmask/`, `internal/translate/`, their tests, `csi-spl-orc/src/bash/tests/fixtures/i18n-mask/` | L0 for the live call, L2 | API stubbed: `TestCostLabelsDraftOnSave`, `TestCostLabelsStubErrorThenFill`, `TestCostLabelsReviewRoundTrip`, `TestCostLabelsMachineDoors`; the mask fixture | the unreviewed answer carrying an amount field; the stub receiving the planted name | landed `3d1d453e2`..`267bd3bbd`; served dev and prd |
| L3w | the hub's environment: cnf rows, step 030's env vars, the tpl-gen template; then a dev plan | `csi-spl-cnf`, `csi-spl-iac/src/terraform/030-cloud-run-hub/`, the template, an iac test | L3 | `do_tpl_gen` + diff; the iac test | 030 drops a var | queued, not on master |
| L4 | `do_spl_cost_labels_translate`. First step: the agy schema measurement (n = 20) | `csi-spl-orc/src/bash/run/spl-cost-labels-translate.func.sh`, `assets/spl-cost-labels-translate/`, `csi-spl-orc/src/bash/tests/spl-cost-labels-translate.tst.sh` | L3 | stubs: agy's correction is the one written, an `ok` writes the draft as reviewed; the log has no label | agy stub answers `refuse` -> zero writes; 101 characters -> that locale refused | landed `c25211556`; the measurement not run |
| L5 | the cron line, once a night at cnf `env.cost.labels_translate_utc` (`03:00`, an hour after the rollup), turned into box local time at install; `flock -n`, tag `csi-spl:cost-labels-translate[-<env>]`, install / remove / check, refused from a linked worktree | `csi-spl-orc/src/bash/run/spl-cost-labels-translate-install-cron.func.sh` and its test | L4 | install twice = one line; check names the schedule | a second install that adds a line fails the test | landed `9de071fa0`; no install by the lane |
| L6 | the WUI: Expenses shows per row "machine translated, not yet reviewed", "reviewed" or "corrected by hand", the stale hand rows, the languages still waiting; removing a row says it will be made again | `csi-spl-wui/src/components/expenses/CostEntryLabels.vue`, `src/utils/cost-entries.mjs`, `i18n/locales/*.json`, the unit and e2e tests | L3 | e2e on the generated bundle: a machine row shows its mark, a hand edit flips it | a locale file missing the new key fails `i18n-parity` | landed `743f68e90`; served dev and prd |
| L7 | the docs: this section's v1.0 and 16.5's write rule | `csi-spl-doc/specs/123-cost-tracking/spec.md` | L2..L6 | - | - | this text |

The first prd night run (L4, `DRY_RUN=0`) and the prd cron install (L5)
each wait for the owner's go; dev runs first (dev leads prd).

#### 16.6.8 The owner's answers (all folded since v0.4)

The first form (HUM-10, csitea 720fa031, msg e9f8e835, verbatim):
"Answer 1: B — A machine translation API in the hub: instant, no agy review,
a new vendor | Answer 2: D — Claude's draft at once, agy corrects it later |
Answer 3: 1D — Once a night | Answer 4: MC — Machine: a later run may re-make
them | Answer 5: T — Every entry with the same text".

The follow-up form 5a82621d (HUM-10, msg baae5fb7, 2026-11-20T17:10:56Z,
verbatim): "Answer 1: A — Yes: the night run sends them to agy, who corrects
them (recommended, keeps agy's final word on languages) Answer 2: M — The hub
masks them, as it does for agy (recommended) Answer 3: G — Google Cloud
Translation, in our own GCP project (recommended)".

Where each one landed:

- 1 `b`: the hub drafts through a machine translation API on save (16.6.2
  point 2, 16.6.3).
- 2 `d`: readers see the draft at once, marked unreviewed (16.6.2 point 4,
  row L6). The draft is the API's, not claude's: with `b` no claude call
  is left in the path.
- 3 `1d`: the run is nightly (row L5).
- 4 `mc`: existing rows are `machine`, so the first night reviews them
  (16.6.4).
- 5 `t`: a correction writes every entry with the same text (16.6.4, row L2).
- Follow-up 1 `a`: agy corrects the API's text every night (16.6.3, row L4).
- Follow-up 2 `m`: the hub masks names before the API and before agy
  (16.6.5). "As it does for agy": today that mask is a bash action, not hub
  code, so row L3 ports it.
- Follow-up 3 `g`: Google Cloud Translation in `csi-spl-<env>`, as the hub's
  runtime SA (16.6.3, row L0).

#### 16.6.9 Gates for this section

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` and `./run -a
do_check_pre_push` on the commit that carries it; each build row carries
its own tests, as listed in 16.6.7.

## 17. The biz owner and the internal accountant open Expenses (SPL-5420)

Owner HUM-10, t1 #spool-hub-bugs ea5d52a7, 2026-11-12T16:18:08Z: "Add access
to the expenses section to the business owners and the internal accountant
roles owning persons."

- **Who.** A member of the **operator** workspace holding `biz_owner` or
  `internal_accountant`, never a live act-as clone, now reads the Expenses
  section: `GET /v1/operator/` `fleet-tokens/paid`, `fleet-tokens/effective`
  and `cost-entries`. The rule is `expensesReaders` in
  `internal/hub/operator_read.go` (`expensesReadCaller`): section 14's admin
  and product owner plus these two roles. `/v1/view/me` says it as
  `expenses_reader`; the WUI's `useExpensesReader` draws the rail entry and
  the page from it.
- **No cross-workspace read.** The Expenses rows are the estate's (the paid
  items, rdb 0205; the cost entries, rdb 0245, no `tenant_id`), so a
  `biz_owner` or `internal_accountant` of any other workspace reads none of
  them (403 `operator.workspaces`, `expenses_reader` false) and the WUI
  draws no Expenses entry there. A workspace's own expenses need section 16's
  follow-up 4 (per-workspace rows) first.
- **Not widened.** `operator_reader` (section 14) is unchanged: the two roles
  do not read the fleet tokens, the lanes, the estate month or the cloud days.
- **Read only in the WUI.** The cards stay read only for anyone but the
  operator admin (`readonly` = not the operator console). On the hub,
  `costs.write` (section 16) already lets both roles of the operator
  workspace create and delete a cost entry; the paid items' writes stay the
  operator admin's. Whether the WUI draws the cost-entry form for them is
  section 16's follow-up 3, not built here.
- Tests: `TestExpensesReadGate`, `TestOperatorReadActAsClone`
  (`internal/hub/operator_read_test.go`); `tests/unit/operator-reader.test.mjs`;
  e2e `expensesBizOwner` in `tests/e2e/monitoring-costs.test.mjs`.
