# Spec 122: Capacity Scale-Out

## 1. Introduction
This spec defines the capacity scale-out mechanism for the spool hub. When the service reaches 80% capacity, new hardware resources are provisioned automatically and joined to the hub to serve incoming workspaces and private channels. The mechanism is bounded by a strict budget ceiling and funded by the customers' prepaid cards, ensuring the scaling is profitable and bounded.

## 2. What "Capacity" Measures
Capacity measures the real hardware bottleneck of the spool hub and its boxes:
1. **Agent Seats & RAM**: The total memory allocated to active agent processes across the fleet.
2. **CPU Utilization**: The aggregate CPU load across the fleet, measured in `agent_seconds` and raw CPU percentage.
3. **Database Connections**: The active connection pool utilization on the hub's Postgres instance.

These metrics are read periodically by a hub background worker from GCP Cloud Monitoring (via `do_gcp_list_monitoring` and related telemetry) and from the `usage_events` ledger (for `agent_seconds`).

## 3. Scale-Out: 80% Trigger, Hysteresis, and Budget Guard
- **Trigger**: When aggregate capacity utilization stays above 80% for 5 continuous minutes, the scale-out action is queued.
- **Hysteresis**: The 5-minute sustained period prevents flapping from brief traffic spikes.
- **Ceiling & Budget Guard**: Since cloud costs are paid by customers' cards, we must prevent unbounded scaling (e.g., from a bug or a DDoS attack). A hard configuration ceiling (e.g., max 20 boxes) limits the total fleet size. The billing state ensures we only scale when prepaid customer balances cover the cost.

## 4. Provisioning a New Box
When scale-out is triggered:
1. The hub orchestrator invokes the infrastructure automation via `csi-spl-iac` named actions (e.g., `do_tf_apply_target` or a dedicated terraform runner) to provision a new VM.
2. The hub mints a new Box Join Token (Spec 073).
3. `do_satellite_playbook` is executed on the new box to install the agent runtime, passing the join token.
4. The box connects to the hub, its public key is pinned, and it is marked as `ready` in the fleet roster to receive new agents and workspaces.

## 5. Scale-In: Draining and Removal
- **Trigger**: When capacity utilization falls below 40% for 60 continuous minutes, scale-in is triggered.
- **Drain**: The orchestrator selects the least-utilized box and marks it as `draining`. No new workspaces or agents are assigned to it.
- **Remove**: Existing active sessions naturally conclude or are gracefully migrated. Once the box has zero active agents, the hub revokes its join token and runs `do_tf_destroy_target` to terminate the VM and stop billing.

## 6. Failure Modes
- **Provisioning Timeout**: If `tf-apply` or `satellite-playbook` fails, the hub alerts the operator and halts scale-out. It does not infinitely retry.
- **Join Token Failure**: If the new box cannot authenticate, it is immediately destroyed and a new attempt is queued with exponential backoff.
- **Ceiling Reached**: If capacity hits 100% and the budget ceiling prevents further scale-out, the hub returns `429 Too Many Requests` (with `token_quota` or `embed_full` errors) for new incoming channels until capacity frees up.

## 7. Tests and Controls
- **Mock Scale-Out**: A unit test forces the mocked telemetry above 80% and asserts that the scale-out terraform action is queued.
- **Scale-In Drain Test**: Asserts that a box marked `draining` refuses new agent assignments.
- **Ceiling Guard Test**: Asserts that scale-out is not triggered if the active fleet size equals the configured budget ceiling.

## 8. Workspace Cost Measurement (Named Action + Test)
To justify the margin and calculate exact pricing, we must measure the baseline resource usage of a workspace.
- **Action**: A new named action `do_measure_workspace_capacity` runs an isolated load test. It creates ONE workspace and ONE private channel, generates standard baseline traffic (10 agent turns), and measures the exact CPU, memory, DB connections, and token usage on the box and the hub.
- **Test**: The measurement output is verified against reasonable bounds in CI.

## 9. Hub Fixed Cost and Pricing Gate
- **Fixed Cost**: The baseline hub cost (hub CPU, DB, hosting, network) is approximately USD 60/env/month. A slice of this fixed cost is dynamically added to each workspace's price.
- **Formula**: The price for a workspace is `(own measured cost + fixed-cost share) + 29%` margin (per Spec 121).
- **Gate**: The WUI pricing page and the payment checkout are gated. No price is published or sold if `do_measure_workspace_capacity` has not populated the cost numbers in the database.

## 10. Owner Questions

- **Q-1 What unit of capacity triggers the scale-out?**
  - **A**: Aggregate CPU utilization and RAM allocated to agent seats (hardware-centric).
  - **B**: Rate of active token processing and `agent_seconds` (software-centric).
  - **Recommended: A**. Hardware limits are the actual bottlenecks that require new boxes.

- **Q-2 How is the slice of the fixed hub cost calculated for a workspace?**
  - **A**: The fixed $60/month is divided by the *maximum* theoretical number of workspaces the hub can support.
  - **B**: The fixed $60/month is divided by the *currently active* number of workspaces.
  - **Recommended: A**. This keeps the price stable for early customers rather than penalizing them with the entire fixed cost before scale-out.

- **Q-3 What is the scale-in hysteresis delay?**
  - **A**: 60 minutes below 40% utilization.
  - **B**: 24 hours below 40% utilization (minimizes churn).
  - **Recommended: A**. 60 minutes is sufficient to prevent rapid flapping while saving cloud costs during daily low-traffic periods.
