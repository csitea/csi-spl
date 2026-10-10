signed against 15e4e5479

## 1. What is missing (Specs 057, 058, 064, 071, 108 and IAC Actions)
- `do_tf_apply_target`: The draft suggests this for provisioning a new VM, but `csi-spl-iac/src/bash/run/tf-apply-target.func.sh` (line 6) targets specific resources within a step. The real action for a full terraform apply is `do_tf_apply` (`csi-spl-iac/src/bash/run/tf-apply.func.sh` line 6).
- `do_satellite_playbook`: The draft claims it is executed "on the new box". According to `csi-spl-iac/src/bash/run/satellite-playbook.func.sh` (line 7), this action runs an ansible playbook *inside the tf-runner container* (which connects to the new box via SSH), not directly on the new box.
- Missing Agent Setup (`do_spl_box_deploy` & `do_spl_pool_ctl`): The draft lacks the actual agent deployment steps. According to spec 071 (`csi-spl-doc/specs/071-box-runtime/spec.md`, lines 86 & 156), installing crons requires `do_spl_box_deploy` and starting the long-lived processes requires `do_spl_pool_ctl`.
- Workspace Isolation: The draft states new resources will "serve incoming workspaces" (plural). However, spec 108 (`csi-spl-doc/specs/108-workspace-owned-boxes/spec.md`, line 34) mandates "One box = one workspace". A single hub-spawned box cannot serve multiple workspaces if it adheres to spec 108 isolation.

## 2. "USD 60/month fixed hub cost"
This is a 2026-09-28 list-price estimate, not the actual billing.
**Proposal**: Label it explicitly as a "2026-09-28 list-price estimate" in the spec. To measure the actual cost, introduce a named action `do_gcp_billing_export` to query the real BigQuery billing export for the hub's GCP project, filtering by the `env` label to capture the true monthly fixed cost.

## 3. Q-2 option A: Measurement Order
To calculate Q-2 option A (fixed cost divided by theoretical max workspaces), we need the per-workspace capacity first.
**Measurement Order**:
1. Measure the hub's absolute maximum capacity bounds (e.g., max concurrent DB connections, max CPU).
2. Run `do_measure_workspace_capacity` to record the exact capacity consumed by one workspace.
3. Calculate theoretical max workspaces = (Hub absolute maximum capacity) / (Measured per-workspace capacity).

## 4. Owner Add (55309d31 & f5c0e3c7)
**Proposals to add**:
- **Fixed Hub Cost Slice**: Calculated as (Actual Hub Fixed Cost) / (Theoretical Max Workspaces).
- **Capacity per Private Channel**: Run `do_measure_workspace_capacity` with 1 channel, then with 2 channels, and subtract the baseline to find the capacity footprint per private channel.
- **The Gate**: The WUI pricing page must query the DB for the measurement results. If the capacity numbers are missing or stale, it must return an error or hide the price, refusing checkout.

## 5. Control Tests
**Concrete proposals for missing tests**:
- **80% Trigger and Hysteresis (`test_scale_out_hysteresis`)**: Simulate telemetry at 85% for 4 minutes, then drop to 50%; assert that the scale-out action is NEVER queued. Fails if the 5-minute guard is removed.
- **Budget Guard (`test_scale_out_budget_ceiling`)**: Simulate telemetry at 95% and set the active fleet size to the configured max limit; assert that a `429 Too Many Requests` error is returned and no new boxes are provisioned. Fails if the ceiling guard is bypassed.
- **Scale-In Drain (`test_scale_in_drain`)**: Mark a box as `draining`; assert that the orchestrator refuses to assign any new workspaces to it, and that `do_tf_destroy_target` is called ONLY when the active agent count reaches 0. Fails if new assignments are allowed or if destroyed prematurely.
- **Failure Modes (`test_provisioning_failure_backoff`)**: Mock `do_satellite_playbook` to fail; assert that the join token is immediately revoked and the next provisioning attempt is delayed by the exponential backoff multiplier. Fails if retries happen immediately in an infinite loop.

## Owner questions

- **Q-1**:
  - A: Aggregate CPU utilization and RAM allocated to agent seats (hardware-centric).
  - B: Rate of active token processing and `agent_seconds` (software-centric).
  - **Recommended**: A. Hardware limits are the actual bottlenecks that require new boxes.
- **Q-2**:
  - A: The fixed $60/month is divided by the *maximum* theoretical number of workspaces the hub can support.
  - B: The fixed $60/month is divided by the *currently active* number of workspaces.
  - **Recommended**: A. This keeps the price stable for early customers rather than penalizing them with the entire fixed cost before scale-out.
- **Q-3**:
  - A: 60 minutes below 40% utilization.
  - B: 24 hours below 40% utilization (minimizes churn).
  - **Recommended**: A. 60 minutes is sufficient to prevent rapid flapping while saving cloud costs during daily low-traffic periods.
