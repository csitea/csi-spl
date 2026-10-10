# Spec 123: Cost Tracking

**Status:** v1.0 (draft ff04d3ca3 by a-816, folded by the editor
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
| **GCP Estate** | GCP billing export to BigQuery, per usage day | a separate background reader with its own SA, `roles/bigquery.dataViewer` on the export dataset only, rows filtered to `project.id LIKE 'csi-spl-%'` (Q-2), never the owner account | `sed -n 245,252p csi-spl-doc/specs/047-spool-deployability/deployability-analysis.md` -> "Cloud Billing API has not been used in project ... or it is disabled": the per-env SAs cannot read billing (n = 1, 2026-09-28) |
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
