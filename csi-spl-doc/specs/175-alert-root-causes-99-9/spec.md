# Alert root causes and a 99.9% reliability architecture

**Status:** Draft v0.1 · evidence window 2026-10-12 through 2026-11-11 · no implementation authorized by this document.

## 1. Purpose and scope

This draft examines production alerts and feature-delivery failures, identifies what the available evidence does and does not prove, and proposes a design for 99.9% monthly availability across the system. The laptop laptop is excluded from the availability target by design. The GCP dev and prd projects and the remote fleet are in scope.

The target permits at most **43.8 minutes of unavailable time in a 30.44-day month** (99.9% × 30.44 days). Alert counts are not outage counts: one incident may span multiple alerts, and a policy violation is not automatically a failed user operation. This draft keeps those quantities separate.

The evidence below is from read-only commands and the supplied scrubbed diagnostic surface. Raw message bodies, credentials, DSNs, tokens, and environment secrets are outside this analysis. Findings marked *incomplete* require a scrubbed fleet-wide extract before this draft can rank every source.

## 2. Evidence and coverage

### 2.1 Cloud Monitoring policy replays

Command: `cd csi-spl-iac && ORG=csi APP=spl SINCE=30d ./run -a do_gcp_list_alert_incidents`. The action replayed policy conditions over **2026-10-12T21:20:34Z .. 2026-11-11T21:20:34Z**, dev and prd. This is a reconstructed incident list from each policy's time series, not the unavailable public incidents API.

| Environment | Policy | n | Reconstructed violating windows |
|---|---|---:|---|
| dev | all nine enabled policies reported | 0 | none |
| prd | hub 5xx rate | 12 | 2026-10-15 07:35Z; six windows on 2026-10-16 18:15–20:25Z; three on 2026-10-20 08:35–09:30Z; two on 2026-10-22 09:55–10:10Z |
| prd | hub 429 streak | 2 | 2026-10-15 07:33–07:37Z; 2026-11-03 17:14Z point |
| prd | hub error log rate | 3 | 2026-10-13 19:10–23:10Z; 2026-10-18 07:10Z point; 2026-10-20 09:30Z point |
| prd | hub health check failing | 1 | 2026-10-15 07:34–07:36Z |
| prd | Cloud SQL down, max instances, memory high, sign-in 5xx, views slow | 0 | none |

The policy counts sum to 18, but the periods overlap and must not be added as 18 independent outages. The 5xx policy reports 12 separate violating windows. Six fell between 18:15Z and 20:25Z on 2026-10-16, spanning 130 minutes with gaps; the first/last violating samples do not mean 130 continuous minutes of user impact. A health-check failure overlapped both a 429 and a 5xx point on 2026-10-15. Policy replay gives first/last violating samples, not the alerting product's exact open/close transitions.

### 2.2 CI quality gate

The task's command, `CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`, was invoked from `csi-spl-iac`; its first n=100 summary was 55 success, 30 failure, 12 cancelled, 3 running over 2026-11-10T15:45:10Z .. 2026-11-11T20:50:07Z. The signature-enabled report was stopped before the per-job section; no failure-log excerpt is used here. A complete no-log report, `CI_GATE_RUNS=100 CI_GATE_SIGNATURES=0 ./run -a do_report_ci_gate`, covered **2026-11-10T16:43:32Z .. 2026-11-11T21:05:53Z** (about 28.4 hours), n=100: 54 success, 30 failure, 12 cancelled, 4 running. In its 30 failed runs, per-job red counts were WUI browser E2E 3/8=18, 1/8=15, 7/8=12, 2/8=7, 6/8=1; IAC tfvars/step-contract/validate=4; ORC hermetic 1/4=3 and 3/4=3. Eight additional job failures were fail-fast stops, not reds. **No CI job logs were read for this completed per-job report.**

The 100-run sample is not 30 days and cannot support a 30-day CI root-cause ranking. An expanded no-log run (`CI_GATE_RUNS=2500 CI_GATE_SIGNATURES=0`) was stopped before a report completed because the per-run job and annotation reads were still in progress after several minutes. A 30-day per-job count is pending a scrubbed summary from the dispatch holder. Do not interpret run-level failures as distinct failed jobs or defects.

### 2.3 Fleet alerts and lease/rotation telemetry

The available laptop aggregate file is `/var/spool-hub/dispatch/lease.log`. Window filter used: `$1 >= "2026-10-12T21:02:28Z"` (through the file's latest entry during the read, 2026-11-11). The following is a **local aggregate only**, not the remote fleet total:

| Event class | n | Interpretation limit |
|---|---:|---|
| `ALERT #alerts: Hub stall` | 19 | automated notices; overlapping/repeated stalls are not 19 independent hub outages |
| `ALERT #alerts: Box benched` | 4 | availability notices, includes recovery debounce behavior |
| `ALERT #alerts: Box back` | 7 | recovery notices; not failures |
| `ALERT #alerts: Box laptop back` | 4 | laptop excluded from the SLO; excluded from target ranking |
| `ALERT #alerts: NO-LOCAL-AGENT dispatch` | 2 | both name laptop; excluded from target ranking |
| disk/headroom/inode terms in automatic `#alerts` notices | 0 | does not prove there were no disk notes; the disk note stream is separate |
| `disk-headroom` task | 2 | `SPOOL_ROOT=/var/spool-hub spool tail --task disk-headroom --json | jq -s '{n:length,first:.[0].ts,last:.[-1].ts,kinds:(group_by(.kind)|map({kind:.[0].kind,n:length}))}'` returned n=2 note records (first 2026-10-16T17:45:30Z, last 2026-10-31T04:52:05Z); message text was not read, so alert vs reply and severity are unknown |
| `FLEET` takeover entries (`dispatch`, `orch`) | 134 | lease transitions, not all incidents; target attribution and silent duration need the scrubbed full extract |
| `ROTATE` records | 981 | includes scheduled handoffs and release/hold records; 641 records name master/failover/orch, and zero match explicit `FAILED`, `failure` or `ERROR` markers |

The 30-day window for these local counts is **2026-10-12T21:18:41Z .. 2026-11-11T21:18:41Z**. Exact class-only commands were `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" {c[$2]++} END {print "FLEET",c["FLEET"],"ROTATE",c["ROTATE"],"ALERT",c["ALERT"],"HUB-STALL",c["HUB-STALL"],"OPS-NOTICE",c["OPS-NOTICE"],"WATCHDOG",c["WATCHDOG"]}' /var/spool-hub/dispatch/lease.log` (n: FLEET=1593, ROTATE=981, ALERT=36, HUB-STALL=38, OPS-NOTICE=57, WATCHDOG=0); `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" && $2=="FLEET" && $0 ~ /takes over from/ {c[$3]++} END {for(k in c) print k,c[k]}' /var/spool-hub/dispatch/lease.log` (dispatch=66, orch=68); `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" && $2=="ROTATE" && $3 ~ /^(master|failover|orch)$/ {c[$3]++} END {for(k in c) print k,c[k]}' /var/spool-hub/dispatch/lease.log` (n=641: failover=299, master=250, orch=92); and `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" && $2=="ROTATE" && $0 ~ /FAILED|failure|ERROR/ {n++} END {print n+0}' /var/spool-hub/dispatch/lease.log` (n=0). Automatic notice categories were grouped with `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" && $2=="ALERT" && $3=="#alerts:" {k=$4; if(k=="Box") k=k" "$5" "$6; else if(k=="NO-LOCAL-AGENT") k=k" "$5; else if(k=="Hub") k=k" "$5; c[k]++} END {for(k in c) print k,c[k]}' /var/spool-hub/dispatch/lease.log`. The keyword count command `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" && $2=="ALERT" && $3=="#alerts:" && tolower($0) ~ /disk|headroom|inode/ {n++} END {print n+0}' /var/spool-hub/dispatch/lease.log` returned n=0. The separate spool task count above did not inspect note bodies.

This file is written on laptop and the task excludes laptop from its target SLO. It is useful evidence of the control-plane's observed event vocabulary, but it cannot be represented as sat or whole-fleet incidence. The dispatch holder was asked for scrubbed 30-day counts/classes for remote-fleet rotation, lease, watchdog, disk-headroom and automatic notices, and for 30-day CI job counts. Until that extract arrives, these categories are unranked and the target-fleet evidence is incomplete.

### 2.4 Prior scrubbed incident analysis (14-day subset)

The repo's [2026-10-24 alert triage](../../doc/md/alerts-triage-20261024.md) is an earlier sanitized investigation within this 30-day window. It used `ENV=<env> SINCE=14d ./run -a do_gcp_list_alert_incidents` (2026-10-10T09:13Z .. 2026-10-24T09:13Z, prd n=39 incidents, dev n=1), `ENV=<env> FORMAT=json FRESHNESS=14d ./run -a do_gcp_tail_logs` (prd n=5,402 hub ERROR lines, dev n=69), and `CI_GATE_RUNS=1000 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (7 days, n=1,000 workflow runs, 97 failed). It also reports 63 WARN and 6 CRITICAL `DISK HEADROOM` notes from the orchestrator spool inbox during 2026-10-10 .. 2026-10-24; the report names that inbox as the source but does not retain an extraction command. The same report gives a seven-day `do_spl_db_query` sample of 49 `#alerts` lines; that line count is omitted from the ranking because the report does not give a reproducible query for it. These are historical subset counts from that report, not substitutes for the requested 30-day totals or the current policy replay; policy definitions changed during the period.

The source report's scrubbed error-class breakdown attributed 4,534 of the 5,402 prd ERROR lines to a non-UUID `task_id` causing a 500/retry storm on 2026-10-13 19:03–23:13Z (one incident). Another 258 lines were Cloud SQL connection failures, 57 were statement timeouts, and 361 were relay/sweep loop failures, clustered around planned DB applies and two DB-starvation stalls. The triage joined two DB-starvation stalls on 2026-10-20 and 2026-10-22 to 5xx and error-log alerts, and an Oct16 cold-instance WebSocket hello deadlock to 5xx/sign-in deadlines. A separate false-noise cluster was 63 repeated disk WARN notes at 85–88% and 6 CRITICAL notes; a hub stall also fanned out into 15 box-alert lines across 3 stalls. See the source report for its exact command, window, n, and limits for each class.

That triage explicitly warns that its incident action replays **today's** policy against past time series. The 2026-10-21 at-max and memory policies and the 2026-10-22 sign-in/views policies did not exist for the full window. The 30-day output above likewise uses current policy conditions. Do not add historical and replay counts as if they were the same incident ledger.

Its per-policy output for the 14-day run was: prd at-max n=15 (7 after the policy went live), prd 5xx n=10, prd error-log n=8, dev error-log n=1, prd 429 n=2 and prd health n=2; total prd n=39, dev n=1. The same report's 7-day CI first-red table counted 33 WUI E2E failed runs, 26 ORC hermetic-test failed runs, 12 WUI initial-JS-budget failed runs and 97 failed workflow runs overall. These older rows establish historical source volume and failure classes, not current policy state.

### 2.5 Existing system measurements to revalidate

- Spec 029's read-only command, `ENV=dev ./run -a do_spl_db_health` and `ENV=prd ./run -a do_spl_db_health` from `csi-spl-orc`, measured one pass per environment on 2026-09-21. It found zonal Cloud SQL without HA; prd was on a shared-core tier. Prd moved to a dedicated core on 2026-10-22 (origin commit `4eadfa55f`, SPL-2932), so the shared-core finding is already addressed; current HA/zone configuration has not been remeasured here.
- Spec 146 documents a three-region, 60-second Cloud Monitoring uptime check for the hub `/v1/health`, alert policies for 429, 5xx, error-log rate, SQL-down and other service signals, plus host-side disk, watchdog and beat checks. Their existence does not prove end-to-end user success or watcher independence.
- Spec 093 describes DB-backed job ownership and failover for alert investigations. It is a control-plane resiliency mechanism, not an availability guarantee for the hub, database, CI, WUI, or host fleet.

## 3. Ranked findings and proposed fixes

The available ranking is provisional and mixes distinct units (log lines, disk notes, CI job reds, and alert-policy windows); it ranks repeated signals by their measured counts without treating one line as one outage. Historical 14-day findings come from §2.4, while current GCP policy windows and the short CI sample come from §§2.1–2.2. Expected cuts are targets for the named cause, not claims that the whole source is now quiet.

| Rank | Observed cause / signal | Evidence and likely root cause | Proposed fix | Expected alert cut |
|---:|---|---|---|---|
| 1 | Invalid task IDs flood prd ERROR logs: n=4,534 lines, one incident | §2.4's 14-day `do_gcp_tail_logs` breakdown found 4,534 of 5,402 prd ERROR lines on 2026-10-13; the GCP 30-day replay includes the matching four-hour error-log window. Cause: non-UUID `task_id` reached UUID-backed storage, returned 500, and retried. | Existing fix `e230d5c6b` (SPL-3195, 2026-10-25) rejects invalid UUIDs as 400 before store access; keep the error class out of retrying paths. | Target 100% fewer server ERROR lines and error-log alerts from this invalid-ID class; measure post-fix for a complete 30 days. |
| 2 | Disk WARN re-arms on threshold wobble: n=63 WARN notes and 6 CRITICAL notes | §2.4's 2026-10-10 .. 2026-10-24 disk-note extract found 63 WARN notes at 85–88% and 6 CRITICAL. Cause: falling one point below a line re-armed the same alert. | Existing fix `d94ca74b1` (SPL-3198, 2026-10-25) adds a five-point re-arm hysteresis. Preserve CRITICAL crossings and recovery signals. | Target zero repeat WARNs while the mount remains in the hysteresis band; the 30-day disk-note class breakdown is pending. |
| 3 | WUI browser E2E CI reds: n=53 jobs in the 100-run sample | The five red shards are 3/8=18, 1/8=15, 7/8=12, 2/8=7 and 6/8=1 in a 28.4-hour sample; a prior 7-day triage recorded 33 first-red E2E runs. Task inputs track wf 10 E2E as SPL-5250. No failure logs were read, so test defect vs test flake remains unresolved. | Reproduce from the scrubbed job-level failure class, then isolate shared browser state and test data and replace timing guesses with observable completion conditions where evidenced. Keep the required E2E gate. | Provisional target ≥75% fewer red E2E jobs in a comparable 30-day window after the evidenced cause is fixed; no red suppression. |
| 4 | Idle at-max policy noise: n=15 replayed incidents, 7 after the policy went live | The 2026-10-24 triage found p99 CPU ≤0.06 in its measured idle episode; the policy paged on max instances alone. The current 30-day replay returns n=0 for the current policy. | Existing fix `cec11cf8c` (SPL-3424, 2026-10-26) requires both max instances and busy CPU (AND). | Target zero idle at-max pages; current-policy replay is n=0 across this 30-day window, but the replay does not reproduce historical policy versions. |
| 5 | Hub stall fans out into box alerts: n=15 box-alert lines in 3 stalls | §2.4's triage linked shared hub stalls to false box-benched/NO-LOCAL alerts; an unreachable hub cannot reliably deliver its own per-box diagnosis. | Existing fixes `03ce2355f` (SPL-3196, 2026-10-25) and `b0276203e` (SPL-3462, 2026-10-26) hold box judgments during a common hub stall and emit one stall summary. | Target reduce the 15-line/3-stall pattern to one summary per stall (≥80% fewer lines) while preserving single-box bench alerts. Verify with the pending post-fix, remote-fleet extract. |
| 6 | Planned Cloud SQL applies inflate error-log alerts: n=3 of 9 historical error-log incidents | The prior triage traced 3 of 9 error-log incidents to approved DB restarts. The current 30-day replay has 3 error-log windows total; the 10/13 flood is G3 and two windows align with the documented apply periods. | Existing fixes log recurring loop failures once (`565310db7`, SPL-3194, 2026-10-25), snooze planned applies (`dc7590f4c`, SPL-3457, 2026-10-26), and require 10 minutes of error rate (`13526c84d`, SPL-3963, 2026-10-28). | Target zero planned-apply alert pages and at most one ERROR per persistent failing loop; keep unscheduled SQL failures visible. |
| 7 | prd hub 5xx rate: n=12 windows | The 30-day replay has 12 windows. Earlier triage attributes five 10/20–10/22 windows to two DB-starvation stalls and five 10/16 windows to a cold-instance WebSocket hello deadlock; one 10/15 point coincides with the retired-instance 429/health event and one 10/16 window remains unassigned. | Keep the dedicated-core DB tier landed in `4eadfa55f` (SPL-2932, 2026-10-22); retain the cold-instance fix `5d43e166b` (SPL-2238, 2026-10-16). Add revision/deploy/SQL correlation to each future incident and test the still-unassigned window before proposing another code change. | Target zero recurrence of the two identified failure modes over a full post-fix 30 days; do not suppress the 5xx policy. The unassigned window remains open. |
| 8 | prd hub 429 streak: n=2 windows, health-check n=1 | The 10/15 429 and health-check overlap the documented retired-instance slot issue; a second 429 point on 2026-11-03 has no cause in the scrubbed evidence. | The socket lifetime fix `68ca6401e` (SPL-1981, 2026-10-15) frees retired Cloud Run instance slots. Correlate the Nov 3 point with revision and capacity metrics before choosing a fix. | Target zero repeats from retained retired-instance sockets; keep the unresolved Nov 3 incident visible until its cause is identified. |
| pending | 30-day CI, remote-fleet lease/rotation/watchdog/disk and #alerts ranking | The 100-run CI sample covers 28.4 hours; the local lease log includes laptop, which is excluded from the SLO; the separate disk task has only n=2 note records and message text was not read. The current dispatch holder has requested a scrubbed 30-day fleet extract from another seat. | Add the full scrubbed extract and rerank before review; do not treat the partial samples as 30-day totals. | Assign numeric reductions only after deduplicated per-class 30-day denominators are complete. |

The largest historical raw error count is the G3 invalid-ID burst (4,534 ERROR lines from one incident in the 14-day triage); it predates the Oct25 fix. The largest repeated CI signal in the recent sample is WUI E2E (53 red jobs in 28.4 hours), and the 30-day current-policy replay has 12 prd 5xx windows. These units are different and do not add up to product downtime. The 30-day CI report and the remote-fleet operational log extract are still required before final ranking.

## 4. Architecture challenge

The design below treats the current topology as a hypothesis. It is a recommendation for decisions and staged work; no infrastructure change is authorized here.

### 4.1 Candidate single points of failure

| Dependency / hypothesis | Why it can consume the error budget | Redesign option | Cost and trade-off |
|---|---|---|---|
| One GCP region per environment, one shared hub endpoint, and revision capacity limits | A bad revision, regional control-plane event, or exhausted concurrency can affect every tenant. The live min/max instance values were not rechecked here. Repeated prd 5xx windows make this the first correlation to test. | Canary or percentage rollout with automated health comparison and fast rollback; test a second region and fail over only if a multi-region data/write design is safe. | More deployment states, cross-region routing, duplicate capacity and harder incident diagnosis. Start with canary/rollback; multi-region only after dependency tests. |
| Cloud SQL without HA in the last measured snapshot | Database unavailability or maintenance can take down all API writes and reads. Spec 029's prior prd sample reported shared-core/no HA; remeasure before acting. | Enable regional HA, point-in-time recovery, and regular restore/failover drills; keep the application pool and retry budget bounded. | Higher recurring cost; failover can increase latency and requires tested reconnect/idempotency behavior. |
| Single hub/API dependency shared by UI, CLI, agents and orchestration | A healthy endpoint probe can miss failed login, post, receive, or WUI flows; one backend incident spans all clients. | Define separate service SLIs for API, WUI, and end-to-end message delivery; add tenant-safe synthetics and dependency-level traces. | Synthetic traffic and telemetry cost; test identities and content handling need careful isolation. |
| Box orchestrator/lease and local disk/heartbeat services | A coordinator can fail while hosted API remains available; failover may not help if control state, log transfer, or shared storage is on the failed box. Current laptop log evidence is not valid evidence for remote-fleet availability. | Keep durable lease state off a single laptop/box; use quorum/lease fencing with independent heartbeats, bounded failover, and capacity on at least two remote-fleet boxes. | More infrastructure and failure modes; quorum can reduce write availability during partitions. Exclude laptop as a voter and SLO dependency. |
| CI runner capacity and serial pre-push work | A stuck or saturated runner can stall feature releases; bypassing gates trades delivery speed for trunk risk. The 30-day per-job and runner-capacity evidence remains pending. | Measure queue time by required job; add an independent runner pool only if queueing contributes materially; cache only deterministic checks and preserve branch protection. | Runner spend, cache invalidation risk, and maintaining reproducible environments. Never weaken required correctness checks to improve a dashboard. |
| Monitoring and alert transport share the component they monitor | A hub or network incident may suppress its own alert, and a green local watchdog does not prove the observer path is working. | Independent external synthetic probes, a separate notification route, and a dead-man heartbeat for every scheduled monitor; periodically test the alert-to-human path. | Additional monitoring vendor/API cost and alert ownership; duplicate signals must be fingerprinted, not silenced. |

The cheapest first step is evidence correlation and deploy rollback around the existing GCP service. HA database and multi-region service are larger recurring-cost decisions. A multi-region Cloud SQL design is not assumed to be safe until write consistency, idempotency, failover time and restore behavior are demonstrated.

### 4.2 Reliability and delivery are separate objectives

Availability alone does not measure stable feature delivery. Track a release SLI beside availability: percentage of master deploys that pass required CI, deploy to dev, pass a synthetic bake, then deploy to prd without rollback or a new attributable incident within 60 minutes. Keep the 30-day cohort, job-level failures, lead time and rollback rate visible. A successful release must not be claimed from a green workflow alone.

## 5. SLI, SLO and proof plan

1. **Hub/API availability SLI:** successful requests / eligible requests, from server-side request metrics in Cloud Monitoring, split by dev/prd and operation class. Exclude only documented client-caused 4xx; count service 5xx, timeouts and failed health probes as unavailable. Report both request-weighted availability and one-minute synthetic availability so low traffic cannot hide outages.
2. **End-to-end message SLI:** successful synthetic create → recipient delivery → read acknowledgement within a defined 60-second bound / all synthetic attempts. Read from a dedicated synthetic tenant and a remote-fleet agent pair, with no customer message bodies. This tests more of the product path than `/health` alone.
3. **WUI SLI:** successful page load plus authenticated read/action synthetic from an external region, measured separately from API uptime.
4. **Non-laptop control-plane SLI:** scheduled heartbeat and lease claim/renew/failover success across eligible remote-fleet boxes, with timestamps and missed beats retained. Exclude laptop from denominator, quorum and failover capacity.
5. **Monthly objective:** each customer-facing SLI ≥99.9% over a rolling 30-day window, plus a burn-rate alert. 99.9% is not proven by a single 60-second uptime check or a short quiet period.
6. **Release SLI:** required CI and staged-deploy success as specified in §4.2; review by workflow job and release cohort, not by run count alone.

Proof requires at least 90 days of retained minute-level SLI data, region and revision labels, alert-open/close records, deploy markers, and a tested synthetic failure. Publish the monthly error-budget burn and the largest contributing incident class. A policy count is supporting evidence, never the SLI denominator.

## 6. Decisions required before implementation

- Supply the pending scrubbed 30-day remote-fleet log and per-job CI extract; update §2–3 and rerank before review.
- Revalidate the current prd Cloud SQL HA tier and Cloud Run serving topology using read-only probes.
- Decide whether 99.9% is a per-service objective or one end-to-end product objective. This draft recommends both, with the end-to-end message SLI as the customer-facing headline.
- Approve recurring-cost analysis for database HA, independent runner capacity and any second-region design before infrastructure work is proposed.

<!-- version: 0.1.0 · updated: 2026-11-11 · last-edit: 2026-11-11T21:42:45Z -->
