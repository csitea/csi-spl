# Review: s123-mistral

**Signed against ff04d3ca3.**

## 1. What is missing

The draft is thin (76 lines). What is missing:

### 1.1 Cost sources
- **GCP projects**: The draft lists `csi-spl-dev`, `csi-spl-prd`, and `csi-spl-all` but does not specify which projects are included in the fixed-cost slice. Spec 122 Q-5 (owner pick B) includes all three.
- **Token granularity**: The draft mentions "per agent, per workspace, and per vendor," but the `cost_rollup_daily` schema does not reflect this. The ledger (`usage_events`) supports it, but the rollup must preserve it.
- **Agent-hours**: The draft mentions `agent_seconds`, but spec 122 replaces this with a fixed-cost slice. The draft must clarify this.

### 1.2 Measurement methods
- **GCP Billing Export**: The draft assumes the per-env SAs can read billing, but spec 122 M0 confirms they **cannot**. This is a blocker. The draft must propose a solution (e.g., a dedicated reader SA).
- **Token gap**: The draft does not mention the token gap measurement (spec 122 M4), which is critical for pricing. The WUI must show both the metered tokens and the provider invoice, with the gap highlighted.
- **Fixed-cost slice**: The draft does not explain how the fixed-cost slice is calculated (spec 122 M3, `W_max`). It must reference spec 122's measurement steps.

### 1.3 Storage and rollup
- **Hand-entered costs**: The draft mentions an admin-only entry form but does not specify how these costs are mapped to categories in `cost_rollup_daily`. For example, a hand-entered "tokens paid invoice" must map to `tokens_gap`.
- **Daily rollup**: The draft does not explain how the rollup aggregates `usage_events` or pro-rates subscriptions. It must describe the UPSERT logic for `cost_rollup_daily`.

### 1.4 Reporting
- **Admin vs business-owner scope**: The draft does not clarify who sees which costs. Spec 121 Q-N1 (owner pick A) restricts `biz_owner` to their own workspace costs.
- **Token gap visibility**: The draft does not show the token gap in the WUI. The table must include columns for "metered tokens," "provider invoice," and "gap."

### 1.5 1-month collection plan
- **Start date**: The draft proposes 2026-11-01 but does not justify it or tie it to a measurement gate. The start date must be the first day of the next full month after spec 122's pricing gate holds.
- **n**: The draft does not explain how "at least 1 month" is enforced or what happens after the month ends. The cron must run indefinitely, and the WUI must show a rolling 30-day window.

### 1.6 Reuse
- The draft claims reuse of spec 122 and 121 but does not explicitly state:
  - What is reused: `do_spl_estate_cost_read` (spec 122 M0), `do_spl_token_gap_measure` (spec 122 M4), `usage_events` (spec 121).
  - What is added: `cost_rollup_daily`, the WUI page, the hand-entry form, the daily rollup action.

## 2. Owner questions

### 2.1 Billing read access for SAs
- **Options**:
  - A: Grant `roles/bigquery.dataViewer` to the per-env SAs on the billing export dataset.
  - B: Use a dedicated reader SA with `roles/bigquery.dataViewer` and no other permissions.
  - C: Require the owner to manually export billing data monthly.
- **Recommendation**: B. It is the least privileged and aligns with spec 122 M0.

### 2.2 Admin vs business-owner scope
- **Options**:
  - A: `admin` sees the whole estate; `biz_owner` sees only their workspace costs.
  - B: Both `admin` and `biz_owner` see the whole estate costs.
- **Recommendation**: A. It maintains privacy between business owners (spec 121 Q-N1).

### 2.3 Token buffer
- **Options**:
  - A: Set the buffer to +20% at launch, lowered to the measured gap after 14 days (spec 122 M4).
  - B: Set the buffer to +20% permanently.
- **Recommendation**: A. It aligns with the owner's pick (spec 122 M4).

## 3. Concrete proposals

### 3.1 Schema changes
- **`cost_rollup_daily`**: Add columns for `workspace_id`, `agent_id`, and `vendor` to preserve granularity from `usage_events`.
- **`hand_entered_costs`**: A new table for admin entries (date, category, amount, currency, note, workspace_id). The daily rollup maps these to `cost_rollup_daily`.

### 3.2 Measurement
- **GCP Billing Export**: Use a dedicated reader SA (option B) with `roles/bigquery.dataViewer` on the billing export dataset only.
- **Token gap**: Reuse `do_spl_token_gap_measure` (spec 122 M4) and show the gap in the WUI.
- **Fixed-cost slice**: Reference spec 122's measurement steps (M0-M3) and use `W_max` as the divisor.

### 3.3 Rollup logic
- **UPSERT**: The daily rollup must use `ON CONFLICT` to update existing rows for the same date, category, and workspace.
- **Pro-rating**: Subscriptions are pro-rated to a daily cost using `units * (unit_cost_micros / days_in_month)`.

### 3.4 WUI page
- **Table columns**: Date, category, workspace, metered tokens, provider invoice, gap, cost (USD), % of total.
- **Admin vs business-owner**: Filter rows by workspace for `biz_owner`.
- **Lazy loading**: The pie chart loads after the initial 160 KB chunk.

### 3.5 1-month plan
- **Start date**: 2026-11-01, or the first of the next full month after spec 122's pricing gate holds.
- **Cron**: Run `do_spl_cost_rollup_daily` indefinitely, with a rolling 30-day window in the WUI.

## 4. Tests and controls

| Rule | Test | Control |
|---|---|---|
| **Billing export access** | A test SA with `roles/bigquery.dataViewer` reads the export. | Without the role, the query fails. |
| **Token gap** | A seeded `usage_events` row and a mock provider report produce the correct gap. | Without the provider report, the gap is not calculated. |
| **Fixed-cost slice** | A seeded `estate_cost_months` row and `W_max` produce the correct slice. | Without `W_max`, the slice is not calculated. |
| **Hand-entered costs** | A hand-entered row maps to the correct category in `cost_rollup_daily`. | Without the mapping, the row is ignored. |
| **Admin vs business-owner** | A `biz_owner` query returns only their workspace rows. | Without the filter, all rows are returned. |
| **UPSERT** | Running the rollup twice for the same date updates existing rows. | Without `ON CONFLICT`, duplicate rows are created. |

## 5. Reuse
- **Reused**: `do_spl_estate_cost_read` (spec 122 M0), `do_spl_token_gap_measure` (spec 122 M4), `usage_events` (spec 121).
- **Added**: `cost_rollup_daily`, `hand_entered_costs`, the WUI page, the hand-entry form, `do_spl_cost_rollup_daily`.

## 6. Clobber guard
- This file is the only change. Before commit:
  ```bash
  git diff --stat origin/master | grep -q "1 file changed, 0 deletions" || echo "Clobber guard violated"
  ```