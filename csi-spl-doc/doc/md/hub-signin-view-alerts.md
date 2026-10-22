# Hub sign-in and slow-view alerts (SPL-2867)

Two alert policies in `csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf`,
beside the R03 five and the two of [hub capacity alerts](hub-capacity-alerts.md).
They page the same channels (cnf `env.gcp.alert_email_<n>` / `alert_sms_<n>`).

| policy | condition | cnf (`steps.070-gcp-monitoring`) |
|---|---|---|
| `<org>-<app>-<env> hub sign-in 5xx` | log metric `<org>-<app>-<env>-hub-signin-5xx`: Cloud Run request log entries of the hub on `signin_path` with status >= 500, summed over 300 s | `signin_path` (`/api/v1/auth/login`), `signin_5xx_per_5min` (1) |
| `<org>-<app>-<env> hub views slow` | two conditions, either pages: log metric `<org>-<app>-<env>-hub-view-latency` (a distribution of `httpRequest.latency` in seconds) on `view_path`, p95 over 300 s above the threshold for `view_slow_seconds`; or log metric `<org>-<app>-<env>-hub-view-5xx`, 5xx on `view_path` summed over 300 s | `view_path` (`/v1/view/`), `view_p95_seconds` (4), `view_slow_seconds` (300), `view_5xx_per_5min` (3) |

Both read Cloud Run's request log: `run.googleapis.com/request_count` and
`request_latencies` carry no path, so a path-scoped alert needs a log metric.

## 1. Why: the prd incident of 2026-10-22

From about 09:40 to 10:10Z sign-in answered 503 after 10 s (the hub's DB pool
wait) and `/v1/view/channels`, `/flow` and `/topics` took 36 to 193 s, while
`/v1/health` stayed 200: health does not touch the DB pool, so the uptime
check could not page. The owner found the outage, not an alert. A hub restart
(`do_gcp_hub_restart`) cleared it at 10:10Z.

What 070 had then, listed read-only as the prd SA
(`ORG=csi APP=spl ENV=prd ./run -a do_gcp_list_monitoring`, 2026-10-22):
health check, 429 streak, 5xx rate, error log rate, Cloud SQL down. The two
capacity policies were not applied in prd yet.

| policy | in the window (prd request and error logs) | could it page |
|---|---|---|
| health check failing | `/v1/health` 200 throughout | no |
| 429 streak | no 429 | no |
| 5xx rate (>= 5 in 5 min) | 26 5xx 09:40-10:10Z, at most 10 in a sliding 5 min | yes, its threshold was crossed |
| error log rate (>= 10 in 5 min) | 56 entries 09:30-10:20Z, at most 14 in a sliding 5 min | yes, its threshold was crossed |
| Cloud SQL down | the DB stayed up (14 of 25 connections) | no |

Whether those two sent their email is not verified: incidents are not readable
with the tools here, and the action log records none. Both are generic: a 5xx
burst names no path, so neither says "nobody can sign in". The two new policies
do.

## 2. Why these numbers

Measured read-only as the prd SA from the hub's request log, 7 days to
2026-10-22T11Z (dev: no sign-in 5xx and no view slower than 3 s):

- Sign-in 5xx came only inside three degraded windows (10-16 17-19Z,
  10-20 08-09Z, 10-22 09-10Z), never otherwise. One in five minutes pages; on
  10-22 the first came 09:47Z.
- `/v1/view/*` p95 over a sliding 5 min: 0.1-0.9 s on a normal morning;
  9-10 s for 5 min on 10-22T03:35Z, 19 s on 10-18T07:10Z; 16-172 s in the
  incident. Above 4 s for 300 s pages: the incident from about 09:49Z, and
  the two shorter episodes too (about two pages that week outside it).
- 4 s sits under the hub's per-view limit (SPL-2866: 5 s, then 1 s grace,
  then 503 `view_timeout`). Once that limit is live a view's latency cannot
  pass about 6 s, so a threshold above it could never fire; the test checks
  the incident capped at 6 s still pages.
- `/v1/view/*` 5xx: at least 3 in 5 min only inside the three degraded
  windows; elsewhere at most 2 (10-21T18Z). With the limit live, a repeat of
  10-22 shows as a burst of 503 `view_timeout`, which this condition pages.

## 3. First response

- Sign-in 5xx: the hub's error logs (`ENV=prd SEVERITY=ERROR ./run -a do_gcp_tail_logs`)
  and `do_spl_db_health`; `pg_stat_activity` (`do_spl_db_query`) shows what
  holds the pool. The remedy that worked on 10-22 was `do_gcp_hub_restart`
  (orchestrator, owner go for prd), see the [incident runbook](guides/incident-runbook.md).
- Views slow: the same; a slow view holding a pool connection starves sign-in
  next.

## 4. Apply

Plan with `PLAN_REF=<sha> ENV=dev STEP=070-gcp-monitoring make do-tf-plan`
(csi-spl-orc); the apply is the orchestrator's with the owner's go, dev first.
The `REGEXP_EXTRACT(httpRequest.latency, ...)` extractor is checked by the
API only at apply: the dev apply proves it.

## 5. Test

`csi-spl-iac/src/bash/tests/monitoring-incident-070.tst.sh`: both log metrics
and policies hold their rule, every threshold is a variable rendered into the
dev and prd tfvars with its cnf value, both are in the `alert_policies`
output. Controls: the terraform without either policy or metric, a mean in
place of the p95, a policy with no channels and a tfvars without either
threshold each fail; the incident's measured series (also capped at 6 s)
fire with the cnf thresholds where a normal hour, a one-minute blip and
10-21T18Z's two view 5xx stay quiet.
