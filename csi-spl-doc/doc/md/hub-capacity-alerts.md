# Hub capacity alerts (Cloud Run radar step 5, SPL-2542)

Two alert policies in `csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf`,
beside the five of row R03 (health check, 429 streak, 5xx rate, error logs,
Cloud SQL down). They page the same channels (cnf `env.gcp.alert_email_<n>` /
`alert_sms_<n>`).

| policy | condition | cnf (`steps.070-gcp-monitoring`) |
|---|---|---|
| `<org>-<app>-<env> hub at max instances` | `run.googleapis.com/container/instance_count`, max per minute, summed per revision, at `hub.cloud_run.max_instances`, AND `container/cpu/utilizations` p99 per minute, max per revision, above the CPU threshold (SPL-3424) | `instances_at_max_seconds` (3600), `instances_at_max_cpu_p99` (0.6) |
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

### 1.1 At max AND busy (SPL-3424)

At max alone paged 7 times from 2026-10-21, when it went live, to the
alerts fix round, each time on an idle hub (CPU p99 <= 0.06 in the measured
episode, plan section 4). The owner chose Q1 = A (msg e13d9db4;
[alerts fix round plan](alerts-fix-round-plan.md) row 01): page only when
the hub is at max AND busy. The policy now has two conditions with
`combiner = "AND"`, both per revision and for `instances_at_max_seconds`:
the instance count at its max, and the p99 container CPU utilisation above
`instances_at_max_cpu_p99` (0.6, cnf `steps.070-gcp-monitoring`). An idle
hour at max stays quiet; a busy one pages. Live only after the owner's go
for the 070 apply, dev then prd.

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
a dev-shaped series where 0.8 stays quiet. SPL-3424: the at-max policy ANDs a
CPU p99 condition on `var.instances_at_max_cpu_p99` and the rendered tfvars
carry the cnf value; controls: combiner `OR` and a literal CPU threshold fail
the rule, an idle at-max hour (CPU p99 0.06) stays quiet where a busy one
(0.75) fires.

## 4. What fired: the alert incidents of a window

`cd csi-spl-iac && ORG=csi APP=spl ENV=<dev|prd> SINCE=24h ./run -a do_gcp_list_alert_incidents`
(SPL-2886) prints, per alert policy, how many incidents opened in the window,
the first and last minute, the series read and the resource, then one line per
incident with its peak value. Read-only, as each env's own service account.

Cloud Monitoring has no public API that lists incidents
(`v3/projects/<p>/incidents` answers 404, measured 2026-10-22) and logs none,
so the action replays every enabled policy: it reads each threshold condition's
time series with the condition's own filter and aggregation and finds where
the condition held for its duration
(`csi-spl-iac/src/bash/scripts/alert-incidents.py`). It is a rebuild, not the
alert log: an absence or ratio condition is named "not replayed", and
`SERIES 0` means the metric had no data in the window, not that no incident
was proven. Test: `csi-spl-iac/src/bash/tests/gcp-list-alert-incidents.tst.sh`.

## 5. Severity (SPL-3477)

Every alert policy of step 070 sets `severity`, so the alert email subject
names it instead of "No severity" (owner answer A, msg 917de544, 2026-10-25):

| severity | policies (`google_monitoring_alert_policy.<name>`) |
|---|---|
| `CRITICAL` | `uptime` (hub down), `sql_down`, `signin_5xx` |
| `ERROR` | `rate_5xx`, `error_logs`, `rate_429` |
| `WARNING` | `instances_at_max`, `memory_high`, `view_slow` |

Test: section 8 of `csi-spl-iac/src/bash/tests/monitoring-incident-070.tst.sh`
holds each policy to exactly its row; a policy without severity, a swapped one
and a policy outside the table each fail it. A new policy gets a row here and
in the test's map.
