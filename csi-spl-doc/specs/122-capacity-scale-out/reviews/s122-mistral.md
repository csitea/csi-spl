signed against 15e4e5479

---

# Review: s122-mistral

## 1. What is missing from the draft

### 1.1. Measurement of workspace capacity (section 8)
- **Missing**: The draft proposes `do_measure_workspace_capacity` but this named action does **not exist** in `csi-spl-iac/src/bash/run/` (grep -r `measure_workspace` returns nothing).
- **Required**: A new named action `do_measure_workspace_capacity` must be created in `csi-spl-iac/src/bash/run/measure-workspace-capacity.func.sh`. It must:
  - Create ONE workspace and ONE private channel in isolation.
  - Generate baseline traffic (10 agent turns).
  - Measure exact CPU, memory, DB connections, and **token usage** on the box and the hub.
  - **Compare the measured token count with the provider's reported usage** (GCP/Azure billing export or API) to quantify the gap.
  - Output the measurements in a structured format (JSON) for CI verification.
- **Test**: A CI test must assert that the output is within reasonable bounds (e.g., CPU < 10%, memory < 512MB, DB connections < 5, token gap < 20%).

### 1.2. Token measurement gap and buffer (owner add, msg f5c0e3c7)
- **Missing**: The owner requested a **margin error for tokens** (+10% to +20%) to account for unmeasurable token usage in the spool hub.
- **Required**:
  - The `do_measure_workspace_capacity` action must measure the **gap** between the hub's token count and the provider's reported usage.
  - The gap must be used to set a **buffer value** (e.g., +20%) in the pricing calculation (spec 121).
  - The buffer must be configurable and stored in the `pricing` table (column: `token_buffer_pct`).

### 1.3. Fixed hub cost measurement (section 9)
- **Missing**: The draft states the fixed hub cost as "USD 60/month" but does not specify how this is measured. This is a **list-price estimate**, not a billing measurement.
- **Required**: Add a named action `do_measure_hub_fixed_cost` that:
  - Queries the GCP billing export for the last 30 days (or a named action like `do_gcp_billing_export`).
  - Sums the costs of the hub's CPU, DB, hosting, and network.
  - Outputs the exact monthly cost in USD.
- **Gate**: The pricing page and checkout must refuse to publish a price if this action has not run and populated the cost in the database.

### 1.4. Scale-out and scale-in controls (section 3, 5, 7)
- **Missing**: The draft describes the 80% trigger, hysteresis, and scale-in drain, but **no control tests exist** to verify these guards.
- **Required**: Add the following tests in `csi-spl-iac/src/bash/tests/`:
  - `test-scale-out-trigger.func.sh`: Forces mocked telemetry above 80% and asserts that the scale-out action is queued.
  - `test-scale-in-drain.func.sh`: Asserts that a box marked `draining` refuses new agent assignments.
  - `test-ceiling-guard.func.sh`: Asserts that scale-out is not triggered if the active fleet size equals the configured budget ceiling.

### 1.5. Failure modes (section 6)
- **Missing**: The draft describes failure modes but does not specify how they are handled or tested.
- **Required**:
  - **Provisioning Timeout**: Add a timeout to `do_tf_apply_target` and `do_satellite_playbook`. If either fails, the hub must alert the operator (via `do_spool_send_alert`) and halt scale-out.
  - **Join Token Failure**: If the new box cannot authenticate, it must be immediately destroyed (via `do_tf_destroy_target`) and a new attempt queued with exponential backoff.
  - **Ceiling Reached**: The hub must return `429 Too Many Requests` with `token_quota` or `embed_full` errors for new incoming channels.

### 1.6. Owner add: Fixed cost slice and gate (msg 55309d31)
- **Missing**: The draft does not specify how the fixed hub cost slice is calculated or gated.
- **Required**:
  - The fixed cost slice must be calculated as `(fixed_hub_cost / max_theoretical_workspaces)` (option A in Q-2).
  - The pricing page and checkout must refuse to publish a price if `do_measure_workspace_capacity` and `do_measure_hub_fixed_cost` have not run.

---

## 2. Owner questions

### Q-1: What unit of capacity triggers the scale-out?
- **A**: Aggregate CPU utilization and RAM allocated to agent seats (hardware-centric).
- **B**: Rate of active token processing and `agent_seconds` (software-centric).
- **Recommendation**: **A**. Hardware limits (CPU/RAM) are the actual bottlenecks that require new boxes. Token processing and `agent_seconds` are secondary and can be optimized in software.

### Q-2: How is the slice of the fixed hub cost calculated for a workspace?
- **A**: The fixed $60/month is divided by the *maximum* theoretical number of workspaces the hub can support.
- **B**: The fixed $60/month is divided by the *currently active* number of workspaces.
- **Recommendation**: **A**. This keeps the price stable for early customers rather than penalizing them with the entire fixed cost before scale-out. The maximum theoretical number must be measured by `do_measure_workspace_capacity`.

### Q-3: What is the scale-in hysteresis delay?
- **A**: 60 minutes below 40% utilization.
- **B**: 24 hours below 40% utilization (minimizes churn).
- **Recommendation**: **A**. 60 minutes is sufficient to prevent rapid flapping while saving cloud costs during daily low-traffic periods. A 24-hour delay would unnecessarily delay cost savings.

---

## 3. Concrete proposals

### 3.1. Add `do_measure_workspace_capacity`
- **Path**: `csi-spl-iac/src/bash/run/measure-workspace-capacity.func.sh`
- **Steps**:
  1. Create a throwaway workspace and private channel.
  2. Generate baseline traffic (10 agent turns).
  3. Measure CPU, memory, DB connections, and token usage.
  4. Compare the token count with the provider's reported usage (GCP/Azure API).
  5. Calculate the gap and set a buffer value (e.g., +20%).
  6. Output measurements in JSON format.
  7. Clean up the workspace and channel.
- **Test**: `csi-spl-iac/src/bash/tests/test-measure-workspace-capacity.func.sh`

### 3.2. Add `do_measure_hub_fixed_cost`
- **Path**: `csi-spl-iac/src/bash/run/measure-hub-fixed-cost.func.sh`
- **Steps**:
  1. Query the GCP billing export for the last 30 days.
  2. Sum the costs of the hub's CPU, DB, hosting, and network.
  3. Output the exact monthly cost in USD.

### 3.3. Add control tests
- **Paths**:
  - `csi-spl-iac/src/bash/tests/test-scale-out-trigger.func.sh`
  - `csi-spl-iac/src/bash/tests/test-scale-in-drain.func.sh`
  - `csi-spl-iac/src/bash/tests/test-ceiling-guard.func.sh`

### 3.4. Update the pricing gate
- **Gate**: The pricing page and checkout must refuse to publish a price if `do_measure_workspace_capacity` and `do_measure_hub_fixed_cost` have not run.
- **Database**: Store the measured values in the `pricing` table (columns: `workspace_cost`, `hub_fixed_cost`, `max_theoretical_workspaces`, `token_buffer_pct`).

---

## 4. Commands to verify claims

```bash
# Check for do_measure_workspace_capacity
cd /opt/csi/csi-spl/csi-spl-iac && grep -r "measure_workspace" .

# Check for do_measure_hub_fixed_cost
cd /opt/csi/csi-spl/csi-spl-iac && grep -r "measure_hub_fixed_cost" .

# Check for control tests
cd /opt/csi/csi-spl/csi-spl-iac && find src/bash/tests -name "*scale-*" -o -name "*ceiling*" -o -name "*drain*"

# Check for GCP billing export action
cd /opt/csi/csi-spl/csi-spl-iac && find src/bash/run -name "*billing*" -o -name "*gcp*export*"
```