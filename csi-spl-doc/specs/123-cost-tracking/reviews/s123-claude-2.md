signed against ff04d3ca3

# Spec 123 review: seat s123-claude-2 (lane c-818)

Target: draft `csi-spl-doc/specs/123-cost-tracking/spec.md` at ff04d3ca3
(76 lines). Every claim about the tree below carries the command that
checks it, run on origin/master on 2026-10-10 (head 4772552ba..ff04d3ca3).

## 1. Verdict

The draft has the right shape: sources, readers, a daily rollup, a monthly
page, a start date. It is not buildable yet, for four reasons:

1. **Everything it "reuses" is a spec, not code.** The actions and tables
   of section 7 exist only in markdown (section 2.1). 123 cannot say
   "no new BigQuery export, reuses `do_spl_estate_cost_read`" without
   saying who builds it first, and when.
2. **The biggest cost is missing.** The fleet's own agents run on
   subscriptions, and their token volume is on the boxes, in transcript
   files, not in 121's `usage_events` (section 2.4). The draft reads
   tokens only from the hub ledger and the provider APIs.
3. **The roles are mixed.** "admin sees the whole estate" uses the
   tenant role `admin`, which today has no billing right, for what is an
   operator (platform) view (section 2.3).
4. **The page budget is 155 KB, not 160**, and nothing says how the lazy
   chart is checked (section 2.5).

Sections 3-5 propose what is missing, each one buildable with its test.

## 2. Evidence check of the draft

### 2.1 The reused names exist only in specs

| name in the draft | command | result |
|---|---|---|
| `do_spl_estate_cost_read` | `git grep -c do_spl_estate_cost_read origin/master` | 3 files, all `.md` (spec 122, its review s122-claude-2, spec 123) |
| `do_gcp_billing_export_setup` | same, that name | 4 files, all `.md` |
| `do_spl_token_gap_measure` | same | 3 files, all `.md` |
| `usage_events`, `unit_cost_micros` | same | 7 and 3 files, all `.md` (specs 121-123 and reviews) |
| `estate_cost_months` | same | 3 files, all `.md` |
| `cost_rollup_daily` | same | 1 file, spec 123 |

So 123 depends on spec 122 build lane 3 (`do_gcp_billing_export_setup`,
`do_spl_estate_cost_read`, `do_spl_token_gap_measure`, 122 section 11) and
on spec 121's ledger DDL. None of them is placed as a lane today. 123 must
say whether it waits for them or builds them (proposal P1).

### 2.2 Stale line references

The draft cites spec 121 lines 219 and 223 and spec 122 line 250. After
121 v1.1 (4772552ba) and 122 v1.1 they moved:

- `git grep -n usage_events origin/master -- csi-spl-doc/specs/121-sales-channel/spec.md`
  -> 110, 263, 349 (the ledger is at 263).
- `git grep -n agent_seconds origin/master -- csi-spl-doc/specs/121-sales-channel/spec.md`
  -> 267, 303, 316.
- `git grep -n do_spl_token_gap_measure origin/master -- csi-spl-doc/specs/122-capacity-scale-out/spec.md`
  -> 329 (M4), 418 (lane 3).

Cite the section (121 section 7, 122 sections 8 and 9), not the line.
The 047 cite holds: `deployability-analysis.md:250` has the "Cloud Billing
API has not been used" line.

### 2.3 Roles: tenant `admin` has no billing right today

- `csi-spl-rdb/src/sql/postgres/spool-hub/0021_tenant_rbac.sql:58`:
  `('admin', false, 'runs the tenant: members, roles, settings, keys, audit; not billing')`.
- `billing.manage` (`internal/rbac/rbac.go:26`) goes to `biz_owner` only
  (0021: `biz_owner` gets every permission; the `admin` grant list has no
  `billing.manage`).
- The estate (GCP, the fleet, the boxes) is not a tenant's: spec 122
  section 10 puts its cost rows in operator scope ("RLS: the operator
  workspace"), and the operator workspace exists (`0115_operator_workspaces.sql`,
  `0116_operator_workspace_flag.sql`, `internal/hub/operator.go:43`
  `operatorAuth`).

So the owner's "both the admin and the business owner" (45f8cb69) needs a
new permission, not `billing.manage`, and the estate view belongs to the
operator workspace. P8 and Q-3.

### 2.4 Where the fleet's tokens and hours really are

- 121 counts tokens for "every agent turn the hub dispatches" (121
  section 7, "Where tokens are counted"). I believe, unchecked, that the
  fleet lanes' own work (briefs on disk, spawned by the spawn-agents
  scripts) carries no hub `turn_id`, so the ledger would not see it.
- The read path for Claude transcripts already exists:
  `csi-spl-orc/src/bash/run/spl-lane-restart.func.sh:274-281` reads
  `.message.usage` (`input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`) from a lane's transcript.
- **Measured trap, double count.** One box, one OS user's transcripts
  changed in the last 24 h (`find $HOME/.claude/projects -name '*.jsonl'
  -mmin -1440`), n = 164 files, 2026-10-10T11:18Z, read with `jq` on
  `select(.type=="assistant") | .message`:
  - assistant rows 26 065, distinct `message.id` 14 002;
  - `cache_read_input_tokens` summed per row 4 989 894 903, per distinct
    id 2 663 132 503 (1.87x);
  - `output_tokens` per row 15 993 042, per distinct id (max) 7 205 419
    (2.22x); first vs max per id differ by 0.6% (7 164 982).

  One message is written as several rows with the same usage, so a naive
  sum about doubles the count. The reader must take one usage per
  `message.id` (the max). This is a guard with a control (section 5).
- Models seen in that sample: `claude-opus-5-5`, `claude-haiku-4-5-20251001`
  and `<synthetic>` rows with zero usage (30 rows), which are skipped.
- The other vendors (agy, mistral, grok, qwen; cnf `all.env.yaml` agent
  split comment near line 855): what their CLIs record locally is not
  measured. Until it is, their tokens are `unmetered`, never 0 (the 121
  rule).
- **Agent-hours**: 121's `agent_seconds` is per hub turn too. What exists
  for the fleet is the lease tick's run report
  `dispatch/agent-run.tsv` (`internal/hubclient/agent_run.go:13-30`,
  written by `spl_lease_agent_run_report`, `spl-dispatch-lease.func.sh:621`):
  `<id> TAB run|stop` per tick. On this box now: 14 lines, 12 `run`,
  1 `stop`. A snapshot, not seconds: agent-seconds = run samples x the tick
  interval (P5).

### 2.5 The WUI budget is 155 KB gzip

`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`:
`"ci_initial_gzip_kb": 155.0` (owner 2026-10-02, "Let's lower it to 155"),
and route ceilings exist, e.g. `"ci_roadmap_route_gzip_kb": 25.0`. The
brief's "160 KB" is stale. `grep -ciE 'chart|echarts|d3' csi-spl-wui/package.json`
-> 0: the WUI has no chart library today, and adding one for one pie is
not worth its bytes.

### 2.6 What GCP already has

`csi-spl-iac/src/terraform/059-gcp-satellite-budget/03-budget.tf`: a
`google_billing_budget` on csi-spl-all, filtered to the satellite label.
It only alerts by mail; it is not a read source. Its comment says the
amount is "in the billing account's currency" (Q-6).

## 3. Reuse and what 123 adds

| need | reuse | 123 adds |
|---|---|---|
| GCP cost | 122's billing export and its one reader (M0) | the reader writes per DAY (the export rows carry a usage day); 122's `estate_cost_months` becomes the monthly sum of those rows, so there is one BigQuery reader, not two (P2) |
| metered API tokens (customer agents) | 121 `usage_events` + `model_prices` | nothing new; the rollup reads the ledger |
| token gap | 122 M4 `do_spl_token_gap_measure` | the page shows invoice vs metered per vendor; no second gap measure |
| fleet tokens (subscriptions) | the transcript read of `spl-lane-restart.func.sh` | `do_spl_cost_tokens_read`, one per box, deduped per message id (P4) |
| agent-hours | `dispatch/agent-run.tsv` | `do_spl_cost_agent_hours_read` (P5) |
| hand-entered invoices | 121's operator path pattern | the entry form and its table (P3) |
| price buffer | 121 +20% token buffer | 123 does not price anything: it reports cost; it never applies the buffer or the 29% margin |

## 4. Proposals (each buildable)

**P1. Build order, stated.** 123 needs 122 lane 3's export setup and
reader, and 121's ledger DDL. Proposal: 123 lane 1 builds
`do_gcp_billing_export_setup` and the reader itself (writing daily rows,
P2) as 122 lane 3's first two items, so 122 later only reuses them. One
owner of each action; 122 section 11 lane 3 then names 123 as where they
came from.

**P2. One table for every cost line.** `cost_lines`:
`(day, source, project_or_vendor, workspace_id NULL, agent_id NULL,
model NULL, kind, units, amount_micros, currency, usd_micros, origin,
run_id, read_at)`, `origin` in `billing_export | metered | transcript |
agent_run | invoice | hand | estimate`, UNIQUE on (day, source,
project_or_vendor, workspace_id, agent_id, model, kind) and written with
UPSERT. The month table and pie are one `GROUP BY`. 122's
`estate_cost_months` is a view over the GCP rows, not a second copy.
Operator scope (RLS: the operator workspace), plus workspace-keyed rows
for a tenant's own costs (P8). DDL first, dev and prd before the code
(the repo's rule).

**P3. Hand entry.** An operator form: month, item, amount, currency, note,
who, when. Stored as `cost_lines` with `origin=hand` (or `invoice` when
it is a vendor invoice), shown marked "entered by hand". Edits are new
rows with the old one superseded (`superseded_by`), never an in-place
change, so a closed month's total can be explained later.

**P4. Fleet token reader.** `do_spl_cost_tokens_read DAY=<utc day>`, run
on each box by that box's cron, as each agent OS user's transcripts are
readable (the lane-restart path already does this). One usage per
`message.id` (max), grouped by (agent id from the transcript's session,
vendor, model, kind). It writes a day file under the fleet root and posts
it to an operator endpoint (`operatorAuth`); the hub upserts `cost_lines`
with `origin=transcript`. A vendor whose CLI has no usage record writes
one `unmetered` row per agent-day. Units only: a subscription's tokens
have no per-token price; the page may show the API list-price equivalent
beside the invoice (Q-4).

**P5. Agent-hours.** The lease tick appends `<ts> <id> run|stop` to a
day log next to `agent-run.tsv`; `do_spl_cost_agent_hours_read` sums
`run` samples x the measured tick gap (from the timestamps, not an
assumed interval). Used to split a vendor's subscription per agent on the
page, never as a price.

**P6. Late and revised GCP rows.** The export lags and revises recent
days (to be measured during the month: the lateness of each row, n
stated). The rollup re-reads a trailing window (cnf
`cost.reread_days`, start 5) with UPSERT; a month is "closed" only on
cnf `cost.close_day` of the next month (start 6). The page shows "so far"
until then. Whether the export backfills days before it was turned on is
read from GCP's own docs at setup; the plan assumes it does not.

**P7. Coverage, so a gap is never a zero.** One `cost_coverage` row per
(day, source): `ok | missing | partial` with the reason. The month table
shows "n of N days complete" per source; a source with a missing day is
marked, never summed as if whole.

**P8. Access.** A new permission `costs.read` (0021 pattern), granted to
`biz_owner` and to `admin` by a migration. With it a member sees their
own workspace's `cost_lines`. The estate view (GCP, fleet, boxes) needs
`costs.read` in the operator workspace. RLS on `cost_lines` like the
other tenant tables (NULLIF policy plus its isolation test).

**P9. The page and a text report.** A Nuxt route `/costs` (route chunks
are lazy), the pie as inline SVG in a component imported only by that
route, no chart dependency. A ceiling `ci_costs_route_gzip_kb` in
perf-budgets.json beside the roadmap one; `ci_initial_gzip_kb` stays
155.0. Also `./run -a do_spl_cost_report MONTH=<yyyy-mm>`: the same table
as text, for the owner's monthly post and for a test with no browser.

**P10. The 1-month plan, with gates.**

| date (2026) | gate |
|---|---|
| by 10-24 | DDL `cost_lines` + `cost_coverage` on dev and prd; P3 form; P4 and P5 readers with tests |
| by 10-25 | the owner runs the export setup (Q-2); the reader SA exists (Q-1) |
| 10-26..10-31 | dry month: every reader runs nightly; coverage must be `ok` on 5 of 6 days per source, else that source is named late |
| 11-01 | collection starts (Q-7) |
| 12-06 | November closes (P6); `do_spl_cost_report MONTH=2026-11`; the owner post |

n = 30 days (November). The report states per source how many of the 30
were complete, and the start date moves to the first of a month only,
never mid-month, so a "month" is always a calendar month.

## 5. Tests and controls

| guard | test | control (fails when the guard is removed) |
|---|---|---|
| transcript dedupe | fixture: one message id on 3 rows, usage 100 out | without the per-id max the total reads 300 |
| upsert | rollup twice for one day | without ON CONFLICT the month total doubles |
| late GCP row | fixture: day D re-read with a changed cost | without the re-read window D keeps the old cost |
| unmetered | a vendor with no usage record | the row reads `unmetered`; with the rule removed it reads 0 |
| coverage | one source missing a day | the month row is marked partial; without the check it is summed as whole |
| tenant isolation | workspace B reads A's `cost_lines` | 0 rows; with the policy dropped it reads A's rows |
| `costs.read` | a member without it gets 403 | with the check removed, 200 |
| estate scope | a tenant `biz_owner` reads estate rows | 403; without the operator check, 200 |
| hand edit | an edit supersedes, the old row stays | an in-place update loses the old amount |
| chunk budget | `ci_initial_gzip_kb` <= 155 and the new route ceiling | a static import of the pie into the shell raises the initial size and fails |
| no owner account | the reader runs as the reader SA (`--account` on every call) | the repo's `gcloud-account-pinned.tst.sh` pattern refuses the owner email |

## 6. Owner questions (for c-002 after consensus)

**Q-1 Who reads the billing export.**
- A: a reader SA in csi-spl-all with `roles/bigquery.dataViewer` on the
  export dataset only, its key on disk like the per-env keys.
- B: the per-env SAs get billing viewer on the billing account.
- C: no automated read; the owner types the GCP total each month.
- Recommendation: **A**, the smallest grant that works; B sees every
  project on the billing account, C loses the daily view.

**Q-2 Turn the export on, and when.**
- A: the owner runs `do_gcp_billing_export_setup` with `DRY_RUN=0` by
  2026-10-25.
- B: later; the start date moves to the next first of a month after it.
- Recommendation: **A**, so November is the first measured month.

**Q-3 Who sees which costs (the draft's Q-C1, restated with the roles).**
- A: the operator workspace (the owner and whom they grant) sees the
  whole estate; in a customer workspace, `biz_owner` and `admin` see only
  that workspace's costs.
- B: every `biz_owner` and `admin` sees the whole estate.
- Recommendation: **A** (c-002's pick), one workspace's costs never show
  another's; today the owner, as operator, sees everything.

**Q-4 What the fleet's agents "cost".**
- A: the subscription invoices are the cost; the token counts and an API
  list-price equivalent are shown beside them as volume.
- B: invoices only.
- C: the API list-price equivalent only.
- Recommendation: **A**: the invoice is what is paid, and the volume
  shows what a move to API keys (121 Q-M3) would cost.

**Q-5 Machines outside GCP (the boxes that are not GCP VMs).**
- A: a hand-entered monthly row per box (hardware share, power, line).
- B: out of scope, listed as "not tracked".
- Recommendation: **A**, the owner asked for "the whole" instance; a
  marked hand row is honest about its source.

**Q-6 Report currency.**
- A: USD, as 121 and 122 store `usd_micros`; every row keeps its own
  currency and amount, converted at the invoice day's rate.
- B: the billing account's currency, as GCP bills it.
- Recommendation: **A**, one currency across 121, 122 and 123.

**Q-7 Start with missing sources?**
- A: start 2026-11-01 with what is live; a late source is marked missing
  per day until it runs.
- B: start only when every source is live.
- Recommendation: **A**: the owner asked for at least one month of data,
  and the coverage rows (P7) keep a partial month honest.
