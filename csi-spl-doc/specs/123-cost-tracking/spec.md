# Spec 123: Cost Tracking

**Status:** Draft

## 1. Owner's Words

Topic `t1 #spool-hub-devel`, task `af4bbf51-62f5-4f04-adcd-79d3b8b044ec` (HUM-10), verbatim:
- msg `a798a19b`: "Create in the Spool Hub discussion for a new feature which is called cost tracking. This feature should start tracking the costs of the whole Spool Hub AI cloud instance, including the tokens and the AI agents. We must gather data for at least 1 month: how much all of this pleasure costs."
- msg `45f8cb69`: "Yes, both the admin and the business owner must have access to a page which also has a pie chart, but a simple table split down on what everything costs."
- msg `f99ea7d8`: "And this table should be updated on a monthly basis."
- msg `b046544e`: "Some of the costs might be insertable by hand, but, for example, the costs of paying the tokens, and so on and so forth."

## 2. Cost Sources (What is tracked)

To see how much the entire AI cloud instance costs, we track every cost source across all environments:
1. **GCP Estate**: All resources across `csi-spl-dev`, `csi-spl-prd`, and `csi-spl-all`. This includes Cloud Run (hub), Cloud SQL, Firebase Hosting, network egress, and the satellite VM (060).
2. **LLM Tokens**: Token consumption across all AI agents. Sliced per agent, per workspace, and per vendor.
3. **Agent Subscriptions vs API Keys**: Fixed-cost subscriptions (e.g., $20/month per seat) and pay-per-token API keys.
4. **Agent-hours**: The time agents spend processing, measured to allocate shared fixed costs accurately (`agent_seconds`).

## 3. How Each is Read

| Cost Source | Read From | Read By | Grep / Evidence |
|---|---|---|---|
| **GCP Estate** | GCP Billing Export to BigQuery | A dedicated reader SA with `roles/bigquery.dataViewer` | `git grep -n "Cloud Billing API has not been used" origin/master` -> `csi-spl-doc/specs/047-spool-deployability/deployability-analysis.md:250` proves per-env SAs cannot read billing. |
| **API Key Tokens (Metered)** | Our internal `usage_events` counters | The hub runtime (`spool_hub_rt`) / Operator | `git grep -n usage_events origin/master` -> `csi-spl-doc/specs/121-sales-channel/spec.md:219` |
| **API Key Tokens (Provider)**| Provider usage APIs (or manual entry) | `do_spl_token_gap_measure` / Hand entry | `git grep -n do_spl_token_gap_measure origin/master` -> `csi-spl-doc/specs/122-capacity-scale-out/spec.md:250` |
| **Agent Subscriptions** | Hand-entered rows or config mapping | The hub / Operator | Flat monthly fees are known fixed numbers. |
| **Agent-hours** | `usage_events` with kind `agent_seconds` | The hub / Operator | `git grep -n usage_events origin/master` -> `csi-spl-doc/specs/121-sales-channel/spec.md:223` |

## 4. Storage and Daily Rollup

- **Storage**: A new table `cost_rollup_daily` (date, category, provider, workspace_id, agent_id, cost_micros_usd). Categories include `gcp`, `tokens_metered`, `tokens_gap`, `subscriptions`, `hand_entered`.
- **Hand-Entered Costs**: An admin-only entry form in the WUI (month, cost item, amount, currency, note). Stored as `hand_entered` or mapped to their category (like tokens paid invoice) in `cost_rollup_daily`.
- **Daily Rollup (`do_spl_cost_rollup_daily`)**: A named action that runs automatically by cron every night to populate the table for the previous UTC day.
  - It pulls the daily GCP cost slice from BigQuery (`estate_cost_months` data or BigQuery daily tables).
  - It aggregates the day's `usage_events` by multiplying `units` by `unit_cost_micros`.
  - It pro-rates the monthly agent subscriptions to a daily cost.

## 5. Report / View (WUI Page)

A new WUI page accessible by `admin` and `biz_owner`.
- **Visuals**: A pie chart + a simple table.
  - To respect the initial WUI chunk budget, the pie chart is loaded lazily.
- **Table Rows**: Cloud parts, tokens per vendor, subscriptions/API keys.
- **Table Columns**: Amount, % of the month, and a marker if it was 'entered by hand'.
- **Monthly Basis**: Shows one table + pie per calendar month, closed at month end. Earlier months are selectable.
- **Current Month**: Shows a running 'current month so far' figure based on the daily rollup.
- **Token Gap**: For tokens, the page shows both the paid invoice (hand-entered) and our own metered count. The difference is the token gap (122 M4 / 121 +20% buffer).

## 6. The 1-Month Collection Plan

- **Start Date**: 2026-11-01 (or the first of the next full month).
- **n**: 30 days.
- **Execution**: The cron automatically runs `do_spl_cost_rollup_daily` every night. The WUI page provides real-time visibility into "how much all of this pleasure costs".

## 7. Reuse with Spec 122 Measurements (No Duplicates)

- **GCP Cost**: Reuses `do_spl_estate_cost_read` (Spec 122 M0) and `do_gcp_billing_export_setup`. No new BigQuery export is created.
- **Token Costs**: Reuses `do_spl_token_gap_measure` (Spec 122 M4) to find the difference between our metered tokens and the hand-entered provider invoice.
- **Token Counters**: Reuses the `usage_events` ledger from Spec 121 (no new token tracking tables).

## 8. Tests and Controls

| Rule | Test | Control (Fails when guard removed) |
|---|---|---|
| **Rollup Accuracy** | A test with seeded `usage_events` and a mock GCP billing export produces the exact mathematical sum in `cost_rollup_daily`. | Changing the sum multiplier causes the test to fail. |
| **Idempotency** | Running `do_spl_cost_rollup_daily` twice for the same date updates the existing rows (UPSERT) rather than duplicating costs. | Without the UPSERT `ON CONFLICT` clause, duplicate rows are created and the report total doubles. |
| **WUI Security** | The WUI endpoint enforces the `admin` and `biz_owner` roles, returning 403 for others. | Removing the role check allows unauthorized access. |

## 9. Owner Questions

- **Q-C1: View Scope (Visibility of costs).**
  - A: `admin` sees the whole estate cost; `biz_owner` sees only their own workspace costs.
  - B: Both `admin` and `biz_owner` see the whole estate costs.
  - **Recommendation: A.** Keeps the costs of other workspaces isolated to the platform admins, maintaining privacy between business owners.
