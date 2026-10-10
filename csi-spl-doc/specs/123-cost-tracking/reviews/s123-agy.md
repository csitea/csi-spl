signed against ff04d3ca3

## 1. What is missing (Concrete proposals)

The draft outlines the sources and the plan, but lacks buildable details:
- **Storage**: The `cost_rollup_daily` table lacks its DDL definition and constraints. It must have a composite unique constraint `UNIQUE(date, category, provider, workspace_id, agent_id)` to support the `ON CONFLICT` UPSERT idempotency test mentioned in the draft.
- **WUI Navigation**: The placement of the new WUI page (e.g., in the sidebar as "Costs") and its route (e.g., `/costs`) are not defined.
- **Missing dependencies**: The draft relies on `usage_events` and `do_spl_estate_cost_read` being built. As proved by `git grep -l usage_events origin/master`, `usage_events` only exists in spec files (121/122), not in code. This spec must sequence its work after spec 121 and 122 land, or build them itself.
- **Cron setup**: The schedule for the daily rollup cron job is not specified (e.g., run at 02:00 UTC daily).

## 2. Reuse and Additions

- **Reuses spec 122**: `do_spl_estate_cost_read` (M0), BigQuery export setup, and the token gap measurement (`do_spl_token_gap_measure`, M4).
- **Reuses spec 121**: The `usage_events` ledger for token metering.
- **Adds in 123**: The `cost_rollup_daily` table for aggregation, the `do_spl_cost_rollup_daily` cron job, the hand-entered costs WUI form, and the owner report (table + pie chart).

## 3. Owner Questions

**Q-C1: View Scope (Visibility of costs)** (already in draft, confirming c-002 recommendation)
- A: `admin` sees the whole estate cost; `biz_owner` sees only their own workspace costs.
- B: Both `admin` and `biz_owner` see the whole estate costs.
- **Recommendation: A.** Keeps the costs of other workspaces isolated to the platform admins.

**Q-C2: Billing read access for the service accounts**
(The per-env SAs cannot read billing today, see `csi-spl-doc/specs/047-spool-deployability/deployability-analysis.md:250`).
- A: Create a new dedicated global SA (e.g., `spool-billing-reader@csi-spl-all`) with `roles/bigquery.dataViewer` on the export dataset, and pass its key to the rollup cron.
- B: Grant `roles/bigquery.dataViewer` to the existing per-env runtime SAs (e.g., `spool-hub-rt@csi-spl-prd`).
- **Recommendation: A.** Principle of least privilege; the dev/prd runtime SAs should not have access to org-wide billing data.
