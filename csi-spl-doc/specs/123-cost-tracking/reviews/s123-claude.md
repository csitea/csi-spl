signed against ff04d3ca3

# Spec 123 review: seat s123-claude (also the editor)

Target: `csi-spl-doc/specs/123-cost-tracking/spec.md` at ff04d3ca3 (76
lines, drafter a-816). Every claim about the code below carries its
command, run on origin/master at ff04d3ca3 on 2026-10-10.

## 1. Verdict

The draft has the owner's four messages right and the right shape (sources,
rollup, monthly page, hand entry). It has one large gap: **section 7 reuses
parts that do not exist yet.** Neither spec 121 nor spec 122 has been built;
both are specs only. So 123 is not a page on top of a working ledger. It is
the first build of the cost readers, and it has to say which ones it builds,
in which order, and what the 1-month collection can count on the day it
starts.

## 2. What the draft says exists, measured

| draft claims (section 3, 7) | command | result |
|---|---|---|
| reuses 121 `usage_events` | `git grep -l usage_events origin/master -- . ':!csi-spl-doc'` | 0 files |
| reuses 122 `do_spl_estate_cost_read` | same grep for `do_spl_estate_cost_read` | 0 files |
| reuses 122 `do_gcp_billing_export_setup` | same grep | 0 files |
| reuses 122 `do_spl_token_gap_measure` | same grep | 0 files |
| `estate_cost_months` "data" | same grep | 0 files |
| `model_prices` / `unit_cost_micros` (121) | same grep for `model_prices` | 0 files |
| `agent_seconds` | same grep | 0 files |
| last rdb migration | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -1` | `0164_workspace_doc_description.sql` |

What does exist and the draft does not use:

| fact | command | result |
|---|---|---|
| a billing-account API that already works with an SA: the satellite budget | `git grep -l billingbudgets origin/master` | `csi-spl-iac/src/terraform/059-gcp-satellite-budget/01-providers.tf`, `csi-spl-iac/src/bash/run/gcp-004-project-apis-enable.func.sh` |
| it runs as the csi-spl-all SA, not the per-env SAs | `sed -n 14,17p csi-spl-iac/src/terraform/059-gcp-satellite-budget/01-providers.tf` | "the budget API is called with the csi-spl-all SA key" |
| the per-env SAs cannot read billing | `sed -n 245,252p csi-spl-doc/specs/047-spool-deployability/deployability-analysis.md` | "Cloud Billing API has not been used in project ... or it is disabled", measured 2026-09-28, n = 1 |
| Claude Code transcripts carry per-turn token usage on the box | `jq -c 'select(.type=="assistant")\|.message.usage\|keys'` on a lane transcript | `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `service_tier`, ... (n = 1 transcript) |
| the fleet already parses that usage | `git grep -n cache_read_input_tokens origin/master -- csi-spl-orc` | `csi-spl-orc/src/bash/run/spl-lane-restart.func.sh:279` |
| a per-agent run report exists | `git grep -n agent-run.tsv origin/master -- csi-spl-orc/src/bash/run` | `spl-dispatch-lease.func.sh:618,622` |
| the WUI initial chunk ceiling is **155 KB**, not 160 | `grep -n ci_initial_gzip_kb csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json` | line 4: `155.0` (owner 2026-10-02, topic 87eaa57b) |
| `admin` and `biz_owner` are per-workspace roles | `sed -n 58,61p csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go` | `BizOwner = "biz_owner"`, `Admin = "admin"` |
| the estate-wide scope is the operator workspace | `git grep -n OperatorTenant origin/master -- csi-spl-api/src/go/spool-hub-api/internal/config/config.go` | lines 392, 399 |

The last two matter for Q-C1: "admin sees the whole estate" is wrong as
written, because every workspace has its own `admin`. The whole-estate view
belongs to the admin and biz_owner **of the operator workspace** only.

## 3. What is missing

1. **Build order against 121/122.** 123 must own (or explicitly wait for)
   the readers. Without that, the collection month starts with an empty
   table.
2. **The fleet's own token cost.** Today almost all tokens are spent by the
   fleet's own agents on subscriptions (121 section 7: "our own work stays
   on subscriptions", Q-M3 = A). 121's ledger counts hub-dispatched turns
   for customers; it will never see a c-/g-/a-/q-/m- lane's tokens. The
   owner's "including the tokens and the AI agents" is mostly this cost.
3. **Subscription vs metered, in money.** A subscription seat costs its flat
   fee whatever it spends; its tokens have a list-price value, not a cost.
   The draft mixes them in one `cost_micros_usd`. They need two columns:
   `cost` (what is paid) and `list_value` (tokens x list price), so the
   owner sees both "what we pay" and "what it would cost on API keys".
4. **Vendors.** Five lanes (claude, grok, agy, qwen, mistral). Only the
   Claude transcript format is checked above; for the other four I believe,
   unchecked, that each CLI writes a usage record somewhere on the box.
   Each needs a measured reader, or it is a hand-entered row.
5. **Currency.** Hand entry has a currency field; storage is USD micros
   only. Needs a currency column plus the rate used, or one currency fixed.
6. **The GCP side for dev, prd and csi-spl-all separately**, plus the
   satellite label, as 122 Q-5 B does. The draft names the projects but not
   the per-project rows.
7. **Start date and n.** "2026-11-01" assumes the readers are live by then.
   The plan needs a readiness gate: collection day 1 is the first day all
   automatic readers wrote a row, n = days with a complete row, and the
   report is called "1 month" only at n >= 28 complete days.
8. **Missing days are visible.** A day a reader failed is a `missing` row,
   never a 0 (the same rule as 121's `unmetered`).
9. **Who runs the nightly job and where.** Box-side readers (transcripts)
   run on each box and post a day summary to the hub; GCP reads run as a
   named action. The draft has one action doing both.

## 4. Proposals (each buildable alone)

- **P1 `do_spl_agent_token_day`** (csi-spl-orc, box-side, read-only): for one
  UTC day, sum the usage of every lane transcript on the box per agent id,
  vendor, model and `service_tier`. Writes one TSV, sends it to the hub.
  Test: a fixture transcript with known usage gives the exact sums; control:
  dropping `cache_read_input_tokens` from the sum fails it.
- **P2 rdb `cost_days`** (DDL first, dev and prd): `(day, source, project,
  workspace_id NULL, agent_id NULL, vendor NULL, model NULL, cost_micros,
  list_value_micros, currency, state complete|missing|estimate, entered_by
  NULL)`, operator RLS, unique key on everything but the amounts (UPSERT).
  Replaces the draft's `cost_rollup_daily`, same role.
- **P3 `cost_manual`** rows: month, item, amount, currency, note,
  entered_by; admin of the operator workspace only. Shown with the "entered
  by hand" marker (owner b046544e).
- **P4 GCP read**: 122's `do_gcp_billing_export_setup` +
  `do_spl_estate_cost_read`, built here as written in 122 section 9, once
  the owner answers Q-C2. Until then the GCP rows are `estimate` from 047
  section 4.2, marked so on the page.
- **P5 `do_spl_cost_month_close`**: on day 1 of each month, freeze last
  month (owner f99ea7d8, "updated on a monthly basis"); a closed month is
  never rewritten; a late correction is a new manual row.
- **P6 WUI page** `/costs`: table first (plain, in the route chunk); the pie
  chart in its own lazy component loaded after the table renders, no chart
  library in the initial chunk. Test: `perf-budgets.json`
  `ci_initial_gzip_kb` stays <= 155.0 on the mock generate; control: an
  eager import of the chart component makes the initial-chunk check fail.
- **P7 the readiness gate** of item 3.7, as a hub check that the page shows
  ("day 9 of 28 complete; missing: grok tokens").

## 5. Reuse, exactly

| from | 123 reuses | 123 adds |
|---|---|---|
| 122 section 9 | the export setup, the reader SA design, `estate_cost_months` rows per project and label | builds them (they are not built); daily, not only monthly |
| 122 M4 | the gap formula `(provider - ours) / provider` | shows it on the page; does not build M4 itself |
| 121 section 7 | `usage_events` for customer turns, `model_prices` for list value | the fleet's own subscription tokens, which 121 never counts |
| 059 | the billing-account API through the csi-spl-all SA | nothing; evidence for Q-C2 |
| 027 | the 155 KB ceiling and its test | the lazy chart |

One cost is never counted twice: a customer turn's tokens come from
`usage_events` once 121 phase 3 ships; until then from P1. P1 skips any
turn a hub `turn_id` already metered (a test with one turn in both sources
counts it once; control: removing the skip doubles it).

## 6. Tests and controls (beyond the draft's three)

| rule | test | control |
|---|---|---|
| a failed reader is visible | a day with no P1 file -> `missing` row, page shows the gap | with the missing-row write removed, the day reads 0 and the test fails |
| a closed month is frozen | rewrite after close is refused | without the check the total changes |
| tenant isolation | a biz_owner of workspace B reads 0 rows of A (as `spool_hub_rt`, RLS on) | dropping the policy returns A's rows |
| estate view is operator-only | an `admin` of a non-operator workspace gets 403 on the estate view | with the operator check removed it gets 200 |
| no double count | section 5 last paragraph | same |

## 7. Owner questions

- **Q-C1 Who sees which costs.**
  - A: the admin and biz_owner of the operator workspace see the whole
    estate; every other workspace's admin and biz_owner see their own
    workspace only.
  - B: every admin and biz_owner sees the whole estate.
  - **Recommend A** (as c-002): workspace admins are customers' people;
    the estate's costs are Csitea's.
- **Q-C2 How the cost readers read GCP billing.**
  - A: the owner grants a dedicated reader SA `roles/bigquery.dataViewer`
    on the billing export dataset only (122 section 9 as written).
  - B: reuse the csi-spl-all SA, which already calls the billing-account
    budget API (059), and add only the export read.
  - C: no SA access; the owner types the monthly GCP invoice as a manual
    row, the daily figures stay estimates.
  - **Recommend A**: least privilege, one grant, and 122 already needs it.
- **Q-C3 What a subscription seat costs on the page.**
  - A: the flat fee as the cost, plus the list value of its tokens as a
    second column.
  - B: the flat fee only.
  - **Recommend A**: the owner asked "how much all of this costs", and the
    list value shows what the same work would cost on API keys.
- **Q-C4 When the month starts.**
  - A: on the first day all automatic readers write complete rows; the
    report is "1 month" at 28 complete days.
  - B: fixed 2026-11-01, whatever is live; missing sources marked.
  - **Recommend A**: a month with half the sources missing does not answer
    the owner's question.
- **Q-C5 Currency.**
  - A: store each row in the currency paid with the rate used; the page
    shows one currency the owner picks.
  - B: everything stored in USD at entry.
  - **Recommend A**: invoices come in more than one currency, and a rate
    fixed at entry cannot be audited later.
