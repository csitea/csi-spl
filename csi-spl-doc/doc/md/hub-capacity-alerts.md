# Hub capacity alerts (Cloud Run radar step 5, SPL-2542)

Two alert policies in `csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf`,
beside the five of row R03 (health check, 429 streak, 5xx rate, error logs,
Cloud SQL down). They page the same channels (cnf `env.gcp.alert_email_<n>` /
`alert_sms_<n>`).

| policy | condition | cnf (`steps.070-gcp-monitoring`) |
|---|---|---|
| `<org>-<app>-<env> hub at max instances` | `run.googleapis.com/container/instance_count`, max per minute, summed per revision, at `hub.cloud_run.max_instances` | `instances_at_max_seconds` (3600) |
| `<org>-<app>-<env> hub memory high` | `container/memory/utilizations` p99 per minute, max per revision, above the threshold | `memory_utilization_threshold` (0.8), `memory_high_seconds` (300) |

`max_instances` is per revision, so both group by revision: during a roll or a
canary two revisions run side by side, each under its own ceiling. The ceiling
reaches 070 as `hub_max_instances`, rendered from `hub.cloud_run.max_instances`,
never a second literal.

## 1. Why these numbers

Measured read-only as each env's service account, 7 days to
2026-10-19T10:50Z, one point a minute (n = 10080 minutes per env):

| | dev | prd |
|---|---|---|
| minutes a revision ran at max (2) | 45 | 1346 (13 %) |
| episodes at max lasting >= 60 / 120 / 180 / 240 min | 0 / 0 / 0 / 0 | 6 / 4 / 3 / 0 |
| p99 memory utilisation per minute: p99 / max | 0.25 / 0.28 | 0.33 / 0.56 |

- At 3600 s the instance alert would have paged prd 6 times that week, dev
  never. prd runs at its ceiling for hours most days: the alert says the
  headroom of max 2 is gone, before the 429 streak policy fires. A quieter
  setting is a cnf change: 10800 s would have paged 3 times, 14400 s never.
- 0.8 is above anything measured (0.56) and under the hub's `GOMEMLIMIT`
  (460 MiB of 512 Mi = 0.9), past which the Go GC fights for memory and the
  next step is an OOM kill that drops every socket on the instance.

## 2. First response

- At max: `cd csi-spl-orc && ENV=<env> REQ_SINCE=<start> REQ_MINUTES=60 ./run -a do_spl_hub_run_metrics`
  (instances, requests in flight, CPU). Raising `hub.cloud_run.max_instances`
  needs a bigger DB tier first (the DB budget in
  `csi-spl-iac/src/bash/tests/hub-startup-probe-030.tst.sh`).
- Memory high: the hub's logs for the revision, and `do_gcp_hub_instance_health`.

## 3. Test

`csi-spl-iac/src/bash/tests/monitoring-capacity-070.tst.sh`: the two
conditions, the rendered `hub_max_instances`, the memory threshold under
`GOMEMLIMIT`; controls: a "greater than max" condition (never fires) and a
policy with no channels fail the rule, a planted 0.1 memory threshold fires on
a dev-shaped series where 0.8 stays quiet.
