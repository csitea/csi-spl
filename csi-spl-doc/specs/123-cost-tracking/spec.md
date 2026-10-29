# Spec 123: Cost Tracking

**Status:** v1.3 (2026-10-29: R7 review W1..W7 folded: owned hardware is the fourth part of the project-cost read, one hand-entered kind only, files disjoint per batch, Q-10 dropped as decided by 107 Q27 A; SPL-4189) · v1.2 (2026-10-29: 13.12, owned hardware written off monthly, monthly and yearly totals first, the untracked-cost list; SPL-4189) · v1.1 (2026-10-29: section 13, the project's cost, plan only, SPL-4189) · v1.0 (draft ff04d3ca3 by a-816, folded by the editor
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

## 13. The project's cost: cloud + AI tokens + human (v1.1..v1.3, plan only)

**Status: Planned, not built.** Lane issue SPL-4189, epic SPL-2373. Nothing
below exists in code. It is the level ABOVE the near-term three-sections
build (ask `156c8939`: Costs gets Cloud / AI tokens / Human sections), and it
does not duplicate it.

### 13.1 The owner's words (HUM-10, prd t1 topic `e2c0e6b4`, verbatim)

- msg `81217a3f`: "Switch it on to see all of the expenses from the cloud, and make sure they have their own section. There are three main types of costs: cloud costs, AI token costs, and human costs."
- msg `d0651111`: "but as the longer term vision - basically the whole Costs section , but present on higher level ( and plann this for now , but have it in the specs ) , the combination of cloud costs , human costs and ai costs"
- msg `3a190b70`: "These the costs of this project"

### 13.2 The top view

One view, **"The project's cost"**. Spec 143 3.2 defines four Costs pages,
Spend the default and first. This view is planned as a **fifth page**,
`/reporting/costs/project`, placed first and made the default; that changes
143 3.2 and is owner question Q-9 (13.10). Until he answers, 143 3.2 stands.
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
| **Cloud** | `cost_lines` source `gcp`, origin `billing_export` (4.2), every `csi-spl-*` project (Q-2) | `GET /v1/tenant/costs` parts (5.2) | the GCP bill itself; `estimate` rows (4.2) are marked |
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
  by subtraction.
- **Never per person**: the Human part is one sum per day; no row names a
  member (107 21.7). Each member sees only their own time (107 Q26 A).

### 13.7 What "project" means

- **Now: this fleet's project, the spool**, read in the operator workspace.
  Cloud = every `csi-spl-*` GCP project (Q-2); owned hardware = the assets
  entered in the operator workspace; AI tokens = the fleet's paid items (all
  boxes); Human = approved hours booked in the operator workspace.
- **Later, per workspace**: a customer workspace's project cost would be its
  AI share (143 3.3.1) plus its own members' human cost. It has no cloud part
  of its own until a per-workspace cloud split exists (none is planned).
  This is owner question Q-8 (13.10).

### 13.8 Planned build rows (rounds-rulebook format, at most 10)

Status of every row: **Planned**. Each row is one lane, aiming at one push.
Each row names its files; no file is in two rows of one batch (rounds-rulebook
2.1 R1), and a row that changes an earlier row's file sits in a later batch.
A cross-vendor reviewer per row (R7). Waits: P02 waits for 107 T071..T072;
P05 waits for the three-sections build (ask `156c8939`, it owns `costs.vue`).
Rows P08..P09 are in 13.12 item 4; P10 (v1.2) is folded into P05 (v1.3).
Paths: `hub/`, `store/` under `csi-spl-api/src/go/spool-hub-api/internal/`;
`pages/`, `components/` under `csi-spl-wui/src/`; `tests/` under `csi-spl-wui/`.

| # | slug | what | target & proof | test (red control) | vendor | batch |
|---|---|---|---|---|---|---|
| P01 | `feat(api, project-cost-read)` | `GET /v1/tenant/costs/project?month=` (or `year=`), new `hub/cost_project.go` + `store/cost_project.go` + `store/cost_project_test.go`: the four parts (Cloud, Owned hardware from source `hand_asset`, AI tokens, Human), each with amount, share and completeness, over the month read (5.2) | the parts sum to `total.priced`; an unpriced part is `null`, never 0; Human is `not_tracked` until P02 | `TestCostProjectParts` (red: a part with no rate summed as 0 changes the total; a `hand_asset` line left out changes the total) | claude | 1 |
| P02 | `feat(api, project-cost-human)` | the human day sum for P01, new `store/cost_project_human.go` + `store/cost_project_human_test.go`, one call added in `store/cost_project.go`: approved minutes x the price in force per day, per currency, no member column | reads 107's tables once T071..T072 land | `TestCostProjectHumanSum` (red: pricing at today's price instead of the day's changes the sum) | claude | 2 |
| P04 | `test(api, project-cost-rls)` | tenant isolation and estate scope of P01 on Postgres, new `store/cost_project_rls_test.go` only | workspace B reads 0 of A's parts; a non-operator reads no estate part (no cloud, no owned hardware) | `TestCostProjectRLS` (red: the policy dropped reads A's rows) | claude | 2 |
| P03 | `feat(api, project-cost-mask)` | the human money mask in `hub/cost_project.go` + new `hub/cost_project_mask_test.go`: without `hours.rates` the Human amount is `null` and `total.priced` covers Cloud + owned hardware + AI only, flagged | an operator admin without `hours.rates` gets hours, no money, and no total that holds it | `TestCostProjectHumanMask` (red: removing the mask lets total minus parts reveal the human money) | claude | 3 |
| P05 | `feat(wui, project-cost-page)` | new page `pages/reporting/costs/project.vue`, its entry first in the Costs bar in `pages/reporting/costs.vue` (Q-9), labels in the locale catalogue (agy reviews the locale text last): the two first figures (month so far, year to date, 13.12 item 2), the table, shares, completeness words, links to the sections and pages | drawn at 1400 and 390 px, no sideways scroll; both first figures equal the sums of their parts | new `tests/e2e/reporting-costs-project.test.mjs` (red: a `null` part drawn as 0.00 fails; the year total without the closed months fails) | claude | 3 |
| P06 | `feat(wui, project-cost-year)` | the year-to-date pick and the month bars split in four parts, new `components/reporting/CostProjectBars.vue` (inline SVG, lazy) + `tests/unit/cost-project.test.mjs`, mounted in `pages/reporting/costs/project.vue` | the bars sum to the year total; the route chunk stays under its ceiling | `tests/unit/cost-project.test.mjs` (red: a static import of the bars into the shell fails the 155 KB initial-size check) | claude | 4 |
| P07 | `docs(doc, project-cost-help)` | a "The project's cost" section in `csi-spl-doc/doc/help/reporting.md` and its served copy `csi-spl-wui/src/public/help-md/reporting.md` (help is one English page; the page labels' locales are P05's) | the help copy matches its source | `tests/unit/help-sync.test.mjs` (red: the source edited without refreshing the served copy fails) | agy | 4 |

### 13.9 Red-control cases

| case | expected | with the guard removed |
|---|---|---|
| a part with a day with no fx rate | that part `null` in the second currency, "unpriced" | it reads 0 and the total is short |
| a member with no price | the minutes show, "unpriced", money left out | the minutes are priced at 0 |
| a price changed mid-month | each day at its own price | every day at the new price |
| the list value of subscription tokens | shown beside, not in the AI amount | the AI amount jumps to the list value |
| an operator admin without `hours.rates` | hours only, total over Cloud + AI, labelled | total minus parts gives the human money |
| human not built yet | "not tracked yet" | a 0.00 row, and the other parts read as a complete 100 % |
| a non-operator workspace | its own parts, no estate cloud, no owned hardware | the estate cloud appears |
| an owned machine entered by hand | its monthly share in the month and year totals, in Owned hardware | left out of the total, or its full price in the purchase month |

### 13.10 Owner questions (only what the words leave open)

```poll
Q-8 Should a customer workspace later get its own project cost?
(A) Yes: its AI share + its own people, no cloud part (recommended)
(B) No: only the spool's own estate
Q-9 Where does the project-cost view live? Spec 143 3.2 has four Costs pages, Spend first.
(A) A fifth Costs page, first and the default (recommended)
(B) A card on top of Spend, 143 3.2 unchanged
```

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
