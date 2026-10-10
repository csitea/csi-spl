# Spec 123: Cost Tracking

**Status:** Draft

**Owner ask** (topic t1 #spool-hub-devel, task af4bbf51-62f5-4f04-adcd-79d3b8b044ec):
"Create in the Spool Hub discussion for a new feature which is called cost tracking. This feature should start tracking the costs of the whole Spool Hub AI cloud instance, including the tokens and the AI agents. We must gather data for at least 1 month: how much all of this pleasure costs."

## 1. Cost Sources (What is tracked)

To see how much the entire AI cloud instance costs, we must track every cost source across all environments:
1. **GCP Estate**: All resources across `csi-spl-dev`, `csi-spl-prd`, and `csi-spl-all`. This includes Cloud Run (hub), Cloud SQL, Firebase Hosting, network egress, and the satellite VM (060).
2. **LLM Tokens**: Token consumption across all AI agents. Sliced per agent, per workspace, and per vendor.
3. **Agent Subscriptions vs API Keys**: Some agents might use fixed-cost subscriptions (e.g., $20/month per seat for Claude Pro or ChatGPT Plus) while others use pay-per-token API keys. Both must be accounted for.
4. **Agent-hours**: The time agents spend processing, measured to allocate shared fixed costs accurately (using `agent_seconds`).

## 2. How Each is Read and Who Reads It

| Cost Source | Read From | Read By | Grep / Evidence |
|---|---|---|---|
| **GCP Estate** | GCP Billing Export to BigQuery | A dedicated reader SA with `roles/bigquery.dataViewer` on the export dataset, run by the owner. | `git grep -n "Cloud Billing API has not been used" origin/master` -> `csi-spl-doc/specs/047-spool-deployability/deployability-analysis.md:250` proves per-env SAs cannot read billing (owner decision). |
| **API Key Tokens (Metered)** | Our internal `usage_events` counters | The hub runtime (`spool_hub_rt`) / Operator | `git grep -n usage_events origin/master` -> `csi-spl-doc/specs/121-sales-channel/spec.md:219` |
| **API Key Tokens (Provider)**| Provider usage APIs (e.g. Anthropic/OpenAI usage endpoints) | Read-only API keys, called by the owner/operator | `git grep -n do_spl_token_gap_measure origin/master` -> `csi-spl-doc/specs/122-capacity-scale-out/spec.md:250` |
| **Agent Subscriptions** | Config file mapping (`env.agents.subscriptions`) | The hub / Operator | Flat monthly fees are known fixed numbers, not dynamically metered. |
| **Agent-hours** | `usage_events` with kind `agent_seconds` | The hub / Operator | `git grep -n usage_events origin/master` -> `csi-spl-doc/specs/121-sales-channel/spec.md:223` |

## 3. Storage and Daily Rollup

- **Storage**: A new table `cost_rollup_daily` (date, category, provider, workspace_id, agent_id, cost_micros_usd). Categories include `gcp`, `tokens_metered`, `tokens_gap`, `subscriptions`.
- **Daily Rollup (`do_spl_cost_rollup_daily`)**: A named action that runs daily to populate the table for the previous UTC day.
  - It pulls the daily GCP cost slice from BigQuery (`estate_cost_months` data or BigQuery daily tables).
  - It aggregates the day's `usage_events` by multiplying `units` by `unit_cost_micros`.
  - It records the provider token gap cost via `do_spl_token_gap_measure`.
  - It pro-rates the monthly agent subscriptions to a daily cost.

## 4. Report for the Owner

A new read-only command-line action: `do_spl_cost_report --month 2026-11`
It reads `cost_rollup_daily` and outputs a clear text table to the terminal:
- Total GCP cost for the month so far.
- Total token cost (our counters vs actual provider bill).
- Total agent subscription cost.
- **Grand Total** cost for the month.
- Breakdown per workspace and per vendor.

## 5. The 1-Month Collection Plan

- **Start Date**: 2026-11-01 (or the first of the next full month).
- **n**: 30 days.
- **Execution**: The owner runs `do_spl_cost_rollup_daily` (either via cron or manually) every day for 1 month, and uses `do_spl_cost_report` to view the accumulating sum.

## 6. Reuse with Spec 122 Measurements (No Duplicates)

- **GCP Cost**: Reuses `do_spl_estate_cost_read` (Spec 122 M0) and `do_gcp_billing_export_setup`. No new BigQuery export is created. We only slice the results daily.
- **Token Costs**: Reuses `do_spl_token_gap_measure` (Spec 122 M4) to find the difference between our metered tokens and what providers actually charge.
- **Token Counters**: Reuses the `usage_events` ledger from Spec 121 (no new token tracking tables).

## 7. Tests and Controls

| Rule | Test | Control (Fails when guard removed) |
|---|---|---|
| **Rollup Accuracy** | A test with seeded `usage_events` and a mock GCP billing export produces the exact mathematical sum in `cost_rollup_daily`. | Changing the sum multiplier causes the test to fail. |
| **Idempotency** | Running `do_spl_cost_rollup_daily` twice for the same date updates the existing rows (UPSERT) rather than duplicating costs. | Without the UPSERT `ON CONFLICT` clause, duplicate rows are created and the report total doubles. |
| **Report Summation** | `do_spl_cost_report` accurately sums all `cost_rollup_daily` rows, and outputs $0.00 when the table is empty. | With the `GROUP BY` logic removed, the summation is wrong. |

## 8. Owner Questions

- **Q-C1: Report output format.**
  - A: A CLI `./run` action printing a summary table to the terminal.
  - B: A new page/dashboard in the WUI.
  - **Recommendation: A.** The request is to gather data for 1 month to see the costs. A CLI action is fast to build, requires no frontend work, and meets the exact need of the owner.
- **Q-C2: Tracking agent subscriptions.**
  - A: Hardcoded in a config file (e.g., $20/month per seat) and pro-rated daily into the rollup.
  - B: Tracked manually outside the system.
  - **Recommendation: A.** Including it in the automated daily rollup ensures the final "Grand Total" actually represents the entire cost of the AI cloud instance, satisfying the ask "how much all of this pleasure costs".
- **Q-C3: Who triggers the daily rollup.**
  - A: A background cron job runs the rollup every night automatically.
  - B: The owner runs it manually via `./run -a do_spl_cost_rollup_daily` when they want to update the numbers.
  - **Recommendation: A.** Automating it ensures no days are missed during the 1-month collection period.
