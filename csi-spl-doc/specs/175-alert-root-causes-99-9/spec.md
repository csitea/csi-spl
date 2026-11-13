# Alert root causes and a 99.9% reliability architecture

**Status:** Draft v0.4 · primary 30-day extract window 2026-10-13T09:11Z .. 2026-11-12T09:11Z · no implementation authorized by this document.

## 1. Purpose and scope

This draft examines production alerts and feature-delivery failures, identifies what the available evidence does and does not prove, and proposes a design for 99.9% monthly availability across the system. The laptop is excluded from the availability target by design. The GCP dev and prd projects and the remote fleet are in scope.

The target permits at most **43.8 minutes of unavailable time in a 30.44-day month** (99.9% × 30.44 days). Alert counts are not outage counts: one incident may span multiple alerts, and a policy violation is not automatically a failed user operation. This draft keeps those quantities separate.

The evidence below is from read-only commands and the scrubbed extract SPL-5422 (sha256 `5365b5e8ada00055c7a54b37a94c6bbca10aead85ce65881a1d2277b951c9601`). Raw message bodies, credentials, DSNs, tokens, and environment secrets are outside this analysis. The primary 30-day extract window is **2026-10-13T09:11Z .. 2026-11-12T09:11Z**. An earlier laptop-local observer sample uses **2026-10-12T21:18:41Z .. 2026-11-11T21:18:41Z** and is labeled separately; its counts are not combined with the primary window. Availability candidates are ranked by measured budget use within each SLI; workflow-delivery and remote-control-plane signals are ranked separately where they have no customer-facing SLI denominator.

## 2. Evidence and coverage

### 2.1 Cloud Monitoring incidents and observed SLI

The scrubbed extract SPL-5422 used `ENV=<env> SINCE=32d ./run -a do_gcp_list_alert_incidents` through the read-only GCP alerts tool at 2026-11-13T07:55Z. Its replay window begins 2026-10-12T07:55Z; all listed incidents fall within the primary 30-day extract window **2026-10-13T09:11Z .. 2026-11-12T09:11Z**. It rebuilds policy incidents from each policy's condition at five-minute grain, not from the public incidents API.

| Environment | Policy | n in 30-day window |
|---|---|---:|
| dev | all 9 enabled policies | 0 |
| prd | hub 5xx rate | 12 |
| prd | hub error log rate | 3 |
| prd | hub 429 streak | 2 |
| prd | hub health check failing | 1 |
| prd | Cloud SQL down, max instances, memory high, sign-in 5xx, views slow | 0 each |

The 18 policy incidents overlap and are not 18 distinct outages. The 12 5xx windows group as 1 on Oct 15, 6 on Oct 16, 3 on Oct 20 and 2 on Oct 22. All six Oct 16 windows fall within the triage's K3 incident span; the differing five-versus-six count is a window-cut difference, not an unassigned cause. The error-log incident on Oct 18 07:10Z is the planned apply; Oct 20 09:30Z is K1 DB starvation. On Oct 15, the 429 streak and health-check incidents overlap the sole five-minute majority-fail uptime episode. Nov 3 17:14Z is a separate one-point 429 incident and remains unattributed. Incident open-to-last-violating-point spans use a five-minute grain and must not be treated as exact customer outage duration.

The extract pulled the prd uptime metric with `data/mon/pull.sh` and analyzed it with `data/an.py`: Monitoring API `projects/csi-spl-prd/timeSeries`, metric `monitoring.googleapis.com/uptime_check/check_passed`, `ALIGN_FRACTION_TRUE` at 60 seconds, in three 10-day slices. It covered **43,200 minutes**, 2026-10-13T09:12Z .. 2026-11-12T09:11Z. The configured check has five checker locations in three regions.

| Checker location | Region | Minutes with point (n) | Failing minutes (<1) | Fully failing minutes (=0) | Availability |
|---|---|---:|---:|---:|---:|
| apac-singapore | ASIA_PACIFIC | 43,172 | 29 | 16 | 99.9328% |
| eur-belgium | EUROPE | 43,200 | 12 | 4 | 99.9722% |
| usa-iowa | USA | 43,195 | 15 | 2 | 99.9653% |
| usa-oregon | USA | 43,196 | 9 | 1 | 99.9792% |
| usa-virginia | USA | 43,200 | 8 | 4 | 99.9815% |

APAC had no point for 28 minutes; those are coverage gaps, not passes.

| SLI over 43,200 minutes | Failing minutes | Availability | 99.9% budget use |
|---|---:|---:|---:|
| Strict: at least one region fails | 36 | 99.9167% | 83.3% of 43.2 min |
| Majority: at least two regions fail | 5 | 99.9884% | 11.6% of 43.2 min |
| All three regions fail | 5 | 99.9884% | 11.6% of 43.2 min |

| Region | Minutes with region data (n) | Strict region failures (any location fails) | Lenient region failures (all locations fail) | Strict availability | Lenient availability |
|---|---:|---:|---:|---:|---:|
| ASIA_PACIFIC | 43,172 | 29 | 29 | 99.9328% | 99.9328% |
| EUROPE | 43,200 | 12 | 12 | 99.9722% | 99.9722% |
| USA | 43,200 | 19 | 5 | 99.9560% | 99.9884% |

The sole majority-fail episode was 2026-10-15T07:33Z .. 07:37Z (5 minutes), matching the 429-streak and health-check incidents. There were 31 other strict failing minutes where fewer than all three regions failed. APAC's 28 no-point minutes are separately reported as missing data.

The request metric was pulled by `data/mon/pull.sh` and analyzed by `data/an5.py`: `run.googleapis.com/request_count`, `ALIGN_DELTA` at 60 seconds and `REDUCE_SUM`, once with all response codes and once with `response_code_class="5xx"`. Its request totals and per-minute error rates are in §3; it does not provide a 429 request count.

### 2.2 CI quality gate

The primary 30-day CI evidence is the scrubbed SPL-5422 extract, window **2026-10-13T09:11Z .. 2026-11-12T09:11Z**. It paged GitHub Actions runs in two-hour creation-time slices (`gh api repos/csitea/csi-spl/actions/runs?created=<2-hour window>`) and read job/failed-step names for failed and cancelled runs (`gh api .../actions/runs/<id>/jobs?filter=latest`); annotations were sampled for 542 of 1,851 failed jobs. The largest slice held 347 runs, below the 1,000-result cap. It counted n=37,764 runs: 21,541 success, 13,884 skipped, 1,469 cancelled, 854 failure, and 16 still queued. Of the skipped runs, 13,883 were workflow 12's conditional action-download-flake reruns. Of the cancelled runs, 1,216 were workflow 10 runs stopped before any job began because a newer push superseded them; those are not reds. Job data covers 853 of 854 failed runs and 2,299 of 2,323 failed-or-cancelled runs; the 24 missing runs were cancelled job reads that timed out.

Workflow 10 (`ci: quality gate`) had 3,862 runs: 544 failed, 1,248 cancelled, 2,068 succeeded, 2 still queued, a 14.1% run failure share (544/3,862). Across workflows, 854 failed runs occurred on 643 distinct commits out of 3,155 commits with a run; 796 failed runs were on master. Job counts below are failed jobs, with matrix shards counted separately, and `runs` is distinct runs where that job failed or was cancelled:

| Failed job signal | Failed jobs | Runs | Evidence limit |
|---|---:|---:|---|
| WUI browser E2E shards (workflow 10) | 679 | 278 | per-shard failures can exceed distinct runs |
| ORC hermetic action tests (workflow 10) | 471 | 285 | no test logs read |
| Hub gofmt/vet/tests/smoke/GCS gate (workflow 10) | 87 | 95 | grouped job name |
| WUI Nuxt generation for E2E (workflow 10) | 60 | 64 | grouped setup job |
| Hub Postgres gate/coverage floor (workflow 10) | 59 | 65 | grouped job name |
| Hub gofmt/vet/tests/smoke/Postgres+GCS gate (workflow 10) | 47 | 47 | grouped job name |
| ORC feature tests (workflow 10) | 37 | 42 | grouped job name |
| IAC tfvars parity/step contracts/terraform validate (workflow 10) | 30 | 35 | grouped job name |

The top 30-day step signatures were WUI browser E2E n=670, ORC hermetic `run-all-tests.sh` n=438, dependency/security `pnpm audit` n=94, hub test suite n=86, and WUI initial-JS budget n=58. These are failed-step names, not diagnoses; no job logs were opened. Workflow 10 had 544 failed runs (14.1%) in the 30-day cohort, while two earlier overlapping n=100 samples had 30% and 21% failed runs over roughly 28 hours. Those short samples suggest a recent concentration but do not establish a separate trend. The 2026-10-24 triage's 5–10% daily share is another differently windowed measure. Treat delivery stability as a distinct objective, not as uptime minutes. The extraction reports no queue-time measurement, so runner saturation remains unproven.

### 2.3 Remote fleet alerts and lease/rotation telemetry

The primary fleet evidence is SPL-5422, built from the remote source box’s own copies of the lease, rotation, failover and disk-headroom logs. Window filter: `awk '$1>="2026-10-13T09:11" && $1<"2026-11-12T09:11"'` (2026-10-13T09:11Z .. 2026-11-12T09:11Z). The laptop-local logs are not in this extract; the laptop is excluded from the SLO by design. The lease-log class command is `data/an-logs.py` over `data/lease-w.log`, grouping `awk '{print $2}' | sort | uniq -c`.

| Lease-log class | n | Lease-log class | n |
|---|---:|---|---:|
| ROTATE | 3,153 | FLEET | 1,860 |
| ABLE | 1,218 | SEAT-HOLD | 502 |
| KEEP | 308 | COPY-SKIPPED | 228 |
| SWITCH | 187 | ALERT | 144 |
| HANDBACK | 129 | HOLD | 105 |
| NO-LOCAL-AGENT | 77 | HUB-UNREACHABLE | 52 |
| COPY-FAILED | 45 | COPY | 45 |
| VENDOR | 33 | HEALTH-UNREAD | 22 |
| NO-LOCAL-ALERT | 19 | FALLBACK-WAIT | 16 |
| HANDOFF | 15 | OPS-NOTICE | 8 |
| SWITCH-DEAD | 5 | | |

The `FLEET` records show 282 orch holder flips and 1,578 dispatch flips; takeovers after a silent holder were 77 orch and 65 dispatch. Thirteen takeovers followed more than 180 seconds of silence, ranging from 188 to 4,555 seconds. The `none@unreachable` intervals (25 windows) sum to **79,731 role-seconds (22 h 8 m 51 s)**; orch and dispatch intervals can overlap, so this is not the union of wall-clock downtime. The longest paired orch/dispatch window was about 10 h 16 m on Nov 10; it includes a 30-minute hub-stall notice, followed by desk quiesce and a box-not-pinned refusal. This is a control-plane reachability signal, not 22 hours of proven user-facing hub downtime; intentional quiesce and placement refusal must be separated from service failure.

`HUB-UNREACHABLE` had n=52 lines: WebSocket dial/handshake send 29, context-cancelled JSON read 6, non-101 handshake 5 (four 429, one 404), desk quiesced 3, close frame 3, frame-header EOF 3, box not pinned 2, and no lease reply 1. `NO-LOCAL-AGENT` had n=77 lines; reasons named were watchdog S2 42, no spinner 14, vendor weekly limit 12, login expired 7 and dead 2. These are line/event counts, not distinct incidents or duration.

### 2.3.1 Automatic notices, watchdog, rotation and disk

The #alerts channel retains seven days, so the 30-day count uses `grep 'ALERT #alerts:'` on the remote source box’s filtered lease log: n=144. Classes: laptop benched 58, laptop back 60, remote-source back 6, `NO-LOCAL-AGENT` 19, and hub stall 1. The laptop is the excluded laptop; its 118 notices do not enter the target-fleet ranking. The single hub-stall notice covers 2026-11-10T05:42Z .. 06:12Z. Monitoring had no failed uptime-check minute on Nov 10; request metrics show two 5xx minutes that day, but the extract does not establish whether either overlaps the stall. This interval remains a measured observer-path/service correlation question.

The failover log `data/rf-w.log` had n=362 lines: SKIP 350, WAIT 6, OK 6. Rotation log `data/rot-w.log` counted a line when it contained ` FAIL ` (n=102): 50 final failures (SPAWN 24, ACK 22, HOLD 2, GATE 2) and 52 non-final step failures (DONE 15, RS-SPAWN 15, RELEASE 12, RS-WIP 5, ACK 3, RECOVERED 2). `IDLOCK REFUSED` occurred n=110. These counts use the same 30-day window and are control-plane delivery signals; they are not direct customer uptime minutes.

Sat disk-headroom log `/var/csi/csi-spl/disk-headroom/cron.out` had n=2,799 CHECK lines at limits of 85% blocks and 80% inodes. Class counts: WARN /mnt/data blocks 916; WARN / blocks 194; WARN /tmp inodes 23; WARN CRITICAL 20; WARN could not tell orchestrator 6; WARN /tmp blocks 3; INFO told orchestrator 115; CLEAR 115. These are repeated checks/notes, not 1,162 separate disk outages. The six unreported WARN cases and 23 inode warnings merit follow-up; no disk note bodies were read.

Sat box-load samples were available only for 2026-11-06T07:30Z .. 2026-11-12T09:11Z after older multi-day reads failed. Sat had 1,747 samples over 147 hours (16 CPUs), mean load1 49.5, max 201.2; the laptop had 1,419 samples over 128 hours, mean 29.6, max 193.6. Event-hour remote-source mean load1 was 73.2 for rotation FAIL and 98.4 for dispatch takeovers, versus 41.7 in hours with no listed event. This is a correlation in a six-day subset, not proof that load caused the events.

### 2.3.2 Earlier laptop-local observer sample (separate window)

An earlier local aggregate from `/var/spool-hub/dispatch/lease.log` used 2026-10-12T21:18:41Z .. 2026-11-11T21:18:41Z. The filter `awk '$1 >= "2026-10-12T21:18:41Z" && $1 <= "2026-11-11T21:18:41Z" && $2=="HUB-STALL" && $3=="over:"' /var/spool-hub/dispatch/lease.log` selected n=19 spans; Python parsed each field-4 start/end pair to total 645 seconds, maximum 168 seconds. The same local window's `awk` grouping of `$2=="ALERT" && $3=="#alerts:"` counted 19 automatic hub-stall notices. These remain in-scope observer signals but are not merged into SPL-5422's remote-source counts or primary 30-day metrics. Neither this earlier local sample nor the remote source box’s Nov 10 stall is independently confirmed as service downtime; use the uptime/request series above to classify impact.

### 2.4 Prior scrubbed incident analysis (14-day subset)

The repo's [2026-10-24 alert triage](../../doc/md/alerts-triage-20261024.md) is an earlier sanitized investigation, overlapping only part of the primary window. Its commands and windows were `ENV=<env> SINCE=14d ./run -a do_gcp_list_alert_incidents` (2026-10-10T09:13Z .. 2026-10-24T09:13Z, prd n=39 incidents, dev n=1), `ENV=<env> FORMAT=json FRESHNESS=14d ./run -a do_gcp_tail_logs` (prd n=5,402 hub ERROR lines, dev n=69), and `CI_GATE_RUNS=1000 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (7 days, n=1,000 workflow runs, 97 failed). It also reports 63 WARN and 6 CRITICAL `DISK HEADROOM` notes from the orchestrator spool inbox during 2026-10-10 .. 2026-10-24; the report names that inbox as the source but does not retain an extraction command. The same report gives a seven-day `do_spl_db_query` sample of 49 `#alerts` lines; that count is omitted from the ranking because the report does not give a reproducible query. These are historical subset counts, not substitutes for the primary 30-day totals or current policy replay; policy definitions changed during the period.

The source report's scrubbed error-class breakdown attributed 4,534 of the 5,402 prd ERROR lines to a non-UUID `task_id` causing a 500/retry storm on 2026-10-13 19:03–23:13Z (one incident). Another 258 lines were Cloud SQL connection failures, 57 were statement timeouts, and 361 were relay/sweep loop failures, clustered around planned DB applies and two DB-starvation stalls. The triage joined two DB-starvation stalls on 2026-10-20 and 2026-10-22 to 5xx and error-log alerts, and an Oct16 cold-instance WebSocket hello deadlock to 5xx/sign-in deadlines. A separate false-noise cluster was 63 repeated disk WARN notes at 85–88% and 6 CRITICAL notes; a hub stall also fanned out into 15 box-alert lines across 3 stalls. See the source report for its exact command, window, n, and limits for each class.

That triage explicitly warns that its incident action replays **today's** policy against past time series. The 2026-10-21 at-max and memory policies and the 2026-10-22 sign-in/views policies did not exist for the full window. The 30-day output above likewise uses current policy conditions. Do not add historical and replay counts as if they were the same incident ledger.

Its per-policy output for the 14-day run was: prd at-max n=15 (7 after the policy went live), prd 5xx n=10, prd error-log n=8, dev error-log n=1, prd 429 n=2 and prd health n=2; total prd n=39, dev n=1. The same report's 7-day CI first-red table counted 33 WUI E2E failed runs, 26 ORC hermetic-test failed runs, 12 WUI initial-JS-budget failed runs and 97 failed workflow runs overall. These older rows establish historical source volume and failure classes, not current policy state.

### 2.5 Existing system measurements to revalidate

- Spec 029's read-only command, `ENV=dev ./run -a do_spl_db_health` and `ENV=prd ./run -a do_spl_db_health` from `csi-spl-orc`, measured one pass per environment on 2026-09-21. At that time it found zonal Cloud SQL without HA and a shared-core prd tier. Current config on origin/master sets prd Cloud SQL `availability_type: REGIONAL` (SPL-2250, `csi-spl-cnf/csi-spl/prd.env.yaml` 040 step) and the automated backups/PITR are enabled. The dedicated-core tier was applied in `4eadfa55f` (SPL-2932). Do not propose enabling HA or PITR again; measure actual failover and restore time in a controlled, separately approved drill.
- The three-region, 60-second Cloud Monitoring uptime check is configured in `csi-spl-cnf/csi-spl/all.env.yaml` 070 step and `csi-spl-iac/src/terraform/070-gcp-monitoring/04-uptime.tf`; it checks `/v1/health` every 60 seconds, with a 10-second timeout and three regions. This configuration is not evidence of observed availability. The 12 checks in spec 146 (`csi-spl-doc/specs/146-reliability-round/tasks.md`) are host and fleet checks, not the source for the Cloud Monitoring uptime configuration.
- Spec 093 describes DB-backed job ownership and failover for alert investigations. It is a control-plane resiliency mechanism, not an availability guarantee for the hub, database, CI, WUI, or host fleet.

## 3. Measured availability and budget ranking

For the primary 30-day window (43,200 minutes), a 99.9% SLI has a **43.2-minute** budget; 43.8 minutes is the average-calendar-month budget. The measurements below come from SPL-5422 (§2.1). Ranks compare budget use only within each explicitly named SLI; minute counts across probes and request errors are not additive. Historical fixes are listed separately in §3.1.

| Rank | Open availability signal / SLI | Evidence, command, window and n | Measured budget relation | Attribution / next proof |
|---:|---|---|---|---|
| 1 | Strict regional uptime check: at least one region fails | Monitoring API `projects/csi-spl-prd/timeSeries`, metric `monitoring.googleapis.com/uptime_check/check_passed`, `ALIGN_FRACTION_TRUE` at 60 s; three 10-day slices, 43,200 minutes, 2026-10-13T09:12Z .. 2026-11-12T09:11Z. | 36 failing minutes; availability 99.9167%; 83.3% of the 43.2-minute budget used, 7.2 minutes remain. | Five minutes were a majority/all-region failure on Oct 15 and match the 429/health incident. The other 31 strict failing minutes were regional; classify checker/network versus serving impact by region and revision. The 28 APAC no-point minutes are missing data, not passes. |
| 2 | 5xx-only request availability | Monitoring API `projects/csi-spl-prd/timeSeries`, metric `run.googleapis.com/request_count`, 60 s `ALIGN_DELTA` and `REDUCE_SUM`, total plus `response_code_class="5xx"`; 6,837,300 requests, window 2026-10-13T09:11Z .. 2026-11-12T09:11Z. | 2,425 5xx responses; 5xx-free request share 99.9645%, using 35.5% of a 0.1% request-error budget. There were 224 minutes with any 5xx, 125 minutes above 1%, 67 above 5%, and 0 above 50%. | Four consecutive-minute episodes over 5% occurred on Oct 16. These are partial-error minutes, not 67 full-outage minutes. The extract has no request count for 429, so the stricter `(all − 429 − 5xx)/all` SLI is not derivable from this sample; report it as unmeasured, not as 99.9645%. |
| Unranked | Nov 3 429 point | Policy replay from `ENV=<env> SINCE=32d ./run -a do_gcp_list_alert_incidents`; prd hub 429 n=2, including one point at 2026-11-03T17:14Z, primary 30-day window. | No 429 request count or duration is provided for this point. | Correlate the point with request counts and region results; do not convert a single policy point to a full outage minute. The Oct 15 429 event belongs to the measured five-minute majority-fail episode. |

The extract also records 25 `none@unreachable` intervals summing to 79,731 role-seconds (22 h 8 m 51 s) in the remote source box’s dispatch/orch copy (§2.3). The intervals may overlap between roles and include intentional desk quiesce and a box-not-pinned refusal; this sum is not elapsed service downtime and is not a customer-facing uptime SLI. Keep it as a separate control-plane candidate until intentional holds, no-seat periods and actual inability to perform eligible work are separated. The one remote-source hub-stall notice (30 minutes on Nov 10) has no failed uptime-check minutes that day; the two 5xx minutes that day have no times in the extract, so overlap is unknown. Do not add these signals to the measured API budgets.

### 3.1 Landed causes: verify the post-fix rate

These are historical causes with relevant fixes already on origin/master. They are not new implementation proposals. Where the primary 30-day extract still shows related signals, only the specific fixed mechanism is treated as addressed; measure post-fix recurrence and reopen investigation when a new occurrence is attributed.

| Historical cause and evidence | Landed fix | Expected cut and post-fix verification |
|---|---|---|
| Invalid task IDs: 4,534 of 5,402 prd ERROR lines in one four-hour burst on Oct 13; `ENV=prd FORMAT=json FRESHNESS=14d ./run -a do_gcp_tail_logs`, 14-day triage (§2.4). SPL-5422 has no 30-day error-log class breakdown for this cause. | SPL-3195, `e230d5c6b`: reject invalid UUID before store access. | Expected cut: 100% of this invalid-ID 500/error class. Verify zero such lines in a post-fix 30-day log-class count; 4xx remains non-paging. |
| Disk WARN re-arm: prior extract had n=63 WARN at 85–88% and n=6 CRITICAL, Oct 10–24 (§2.4); the new remote-source 30-day log has n=916 /mnt/data block WARN, 194 / block WARN, 23 /tmp inode WARN, and 20 WARN CRITICAL among 2,799 checks (§2.3.1). | SPL-3198, `d94ca74b1`: five-point hysteresis. | Expected cut: remove duplicate WARN transitions within the hysteresis band, not all threshold checks. The 30-day recurrence shows disk alert volume remains; classify unique threshold episodes and host impact before calling this cause closed. Preserve CRITICAL crossings and recovery. |
| Idle at-max policy: n=15 in the 14-day triage (7 after policy live); measured idle episode CPU p99 ≤0.06. SPL-5422 has n=0 at-max incidents in the primary window. | SPL-3424, `cec11cf8c`: max instances AND busy-CPU threshold. | Expected cut: 100% of idle-only at-max pages; the current replay observed zero at-max policy incidents, while the 14-day historical sample remains the earlier evidence. Retain pages when busy at max. |
| Common hub stall fanned out to n=15 box-alert lines in n=3 stalls (14-day triage). | SPL-3196 `03ce2355f` and SPL-3462 `b0276203e`: hold per-box judgments during a common hub stall and emit one summary. | Expected cut: at least 80% fewer lines (15 → at most 3, one per stall); verify no false per-box bench/NO-LOCAL lines while an isolated box failure still pages. |
| Planned DB applies were among 3 of 9 historical error-log incidents in the prior triage; the current replay has one apply window on Oct 18 07:10Z. Oct 20 09:30Z is K1 starvation, not an apply. | SPL-3194 `565310db7`, SPL-3457 `dc7590f4c`, SPL-3963 `13526c84d`: dedupe recurring loop errors, snooze approved apply, require 10-minute error rate. | Expected cut: zero planned-apply pages and at most one log line per persistent loop; keep unscheduled SQL errors visible. |
| Prd 5xx: n=12 threshold incidents; 2,425 failed requests in 6,837,300, with 67 minutes above a 5% 5xx ratio and none above 50% (§2.1). K2 one Oct 15; all six Oct 16 windows fall inside K3; K1 accounts for five Oct 20/22 windows. | SPL-1981 `68ca6401e` (K2 retired instance), SPL-2238 `5d43e166b` (K3 cold WebSocket hello), SPL-2932 `4eadfa55f` (K1 dedicated DB tier). | Expected cut: no recurrence of these three attributed causes; verify by incident class. The measured request share is 99.9645% for 5xx only, not the complete 429+5xx request SLI. Verify future per-cause recurrence and the missing 429 denominator before claiming the combined SLI. |
| WUI E2E shards: new 30-day extract counts 679 failed E2E jobs across 278 runs; prior 28.4-hour sample had 53 red jobs. The 30-day cohort overlaps SPL-5250's Nov 11 fixes and does not split pre/post-fix counts (§2.2). | SPL-5250: `6c1ccd083`, `7a101930c`, `2c6519bf6` fix stale feed reads. | Expected cut: remove the stale-read failure class if that is still represented; the extract contains no job logs or failure-class split, so quantify reduction only with a post-fix per-shard cohort. Preserve the gate. |
| Satellite-to-laptop relay move path (task lead SPL-5246). | SPL-5246 `6c3a802c8` fixes routing to the moved desk's user. | Expected cut: zero missed relay deliveries after a desk move; verify with the moved-desk delivery drill, separate from hub availability. |
| Hub canary and rollback control. | SPL-2249 `e32bef074`, enabled dev/prd; design and trade-offs in [Hub canary deploy](../../doc/md/hub-canary-deploy.md). | Expected cut: contain a bad revision before 100% traffic promotion; measure rollback drill and canary incident rate. This is existing machinery, not a missing implementation or a substitute for SLI monitoring. |

### 3.2 Delivery and operations signals (separate from API uptime minutes)

The 30-day CI failure-volume ranking is by failed job count, not by incident or outage count. The evidence is SPL-5422's per-job report in §2.2. Workflow 10 had 544 failed runs of 3,862 (14.1%); its largest job signals were WUI E2E (679 failed jobs/278 runs) and ORC hermetic tests (471/285). There are no job logs in the extract, so the failure step is a symptom signature, not a proven defect. Prior short samples were 30/100 and 21/100 failed workflow runs over roughly 28 hours; they indicate recent concentration but overlap and do not replace the 30-day denominator.

| Operational signal | 30-day count and window | Interpretation / expected cut | Next proof |
|---|---|---|---|
| Rotation final failures | n=50 of 102 ` FAIL ` lines; SPAWN 24, ACK 22, HOLD 2, GATE 2, sat log window 2026-10-13T09:11Z .. 2026-11-12T09:11Z (§2.3.1). | Spawn and acknowledgement are the main final-failure classes. Event-hour load correlation is strong in a six-day subset but does not prove load caused the failures. No percentage cut is claimed until cause-specific attempt denominators exist. | Split failures by stage, eligible seat, vendor and load; measure successful recovery and time-to-usable-seat. Preserve the old lane until replacement ACK. |
| Control-plane reachability and seat availability | `none@unreachable` n=25, total 79,731 role-seconds; `HUB-UNREACHABLE` n=52; `NO-LOCAL-AGENT` n=77, remote-source 30-day window (§2.3). | Large operational signal, but intervals include intentional quiesce and refusal states; it is not a direct customer API SLI. | Separate intentional holds, missing seats, relay/network failures and service outages; report eligible-operation success and unavailable minutes for remote-fleet dispatch/orchestration. |
| Disk/headroom | 2,799 CHECK lines; WARN /mnt/data blocks 916, WARN / blocks 194, WARN /tmp inodes 23, WARN CRITICAL 20; remote-source 30-day window (§2.3.1). | Repeated threshold checks are not independent outages. Hysteresis is already built; distinguish repeated readings in one episode from new threshold entries. | Count unique host/volume episodes, duration above threshold, and missed work; verify the six WARN events that could not notify the orchestrator. |
| Automatic notices | n=144 #alerts lines; 58 tnk bench + 60 laptop back are excluded laptop notices; in-scope classes include 6 remote-source back, 19 NO-LOCAL-AGENT and 1 hub stall (§2.3.1). | Back notices are recovery, not failures; one hub stall does not establish 30 minutes of service outage. | Join each in-scope notice to independent uptime, requests and eligible fleet size; do not rank laptop alerts toward the target. |

Task-supplied leads (two stale lease observations on Nov 12, relay SPL-5246, `/tmp` inode leak SPL-5302 and pre-push timeouts at load 120–160) are now partly covered by the primary extract. The extract measures stale takeovers n=13, relay/seat symptom classes and inode WARN n=23, but does not identify those exact two observations or prove the named incidents' causes. SPL-5246 is already fixed; SPL-5302 still needs unique-episode and post-fix verification. The extract has no pre-push wait-time series, so that lead remains unquantified.

### 3.3 Actionable follow-up register

| Issue / owner area | Deliverable | Done when |
|---|---|---|
| Issue: to file at land / iac + reliability | Keep a repeatable, key-safe monthly SLI extract on the approved per-env read path; include request counts for both 429 and 5xx so the complete request-success SLI is measurable. The laptop metadata read gap is local to that laptop; no key re-mint is proposed. | One half-open 30-day window reports per-location and per-region uptime, missing samples, request classes, failed minutes and request totals for dev and prd, with command and n; no credential material is emitted. |
| Issue: to file at land / api + reliability | Attribute the 31 regional-only failing minutes, the Oct 15 five-minute majority outage, the Nov 3 429 point, the remote-source Nov 10 hub-stall notice, the 25 `none@unreachable` intervals, and the earlier laptop observer spans. | Every interval is classified as serving, checker/network, control-plane, intentional hold or unknown; each actual impact duration is assigned only to its matching SLI budget. |
| Issue: to file at land / WUI + CI | Establish the post-SPL-5250 per-shard E2E red rate and remaining failure classes from the 679 failed jobs/278 runs in the mixed 30-day cohort. | A job-level report separates pre/post-fix runs, failed shards, cancellations and fail-fast stops; required checks remain enabled. |
| Issue: to file at land / hub deploy | Set the rollout/error-budget response using measured SLI burn and verify the existing SPL-2249 canary/rollback in dev and prd. | A controlled drill records the old revision restored within the canary window; failed new-revision probes never promote it; the policy names when prd releases batch. |
| Issue: to file at land / reliability + API | Add end-to-end message and authenticated WUI synthetic SLIs using an isolated tenant and remote-fleet pair; the current extract has no observed values for either SLI. | The 30-day report shows attempt counts and success fractions; a planted failure is detected within the stated objective without customer data. |
| Issue: to file at land / monitoring + IAC | Test the independent notification route and alert-to-human path; add a dead-man signal for the monitoring process. | A controlled failure in each monitored path reaches the independent route within its objective; a stopped monitor produces a dead-man alert. |

The dispatch holder confirmed that none of these six next steps has an open t1 issue. The holder will file the six issues under epic SPL-2364 once this spec is on master, because each issue's Spec field must point to a folder on master. This lane has no t1 issue-desk seat and creates or assigns no issues. The rows are proposed deliverables, not approval for code or production changes.

## 4. Architecture challenge

The design below treats the current topology as a hypothesis. It is a recommendation for decisions and staged work; no infrastructure change is authorized here.

### 4.1 Candidate single points of failure

| Dependency / hypothesis | Why it can consume the error budget | Redesign option | Cost and trade-off |
|---|---|---|---|
| One GCP serving region, shared hub endpoint, and revision capacity | The primary 30-day probe SLI is 99.9167% under the strict rule that any region failing makes the minute unavailable (36/43,200 min); all three regions failed together for 5 minutes. The 5xx-only request SLI is 99.9645% (2,425/6,837,300 errors). 31 strict failing minutes were regional, and not all are attributed. | Canary/rollback already exists (SPL-2249; enabled in dev and prd). Attribute the 31 regional minutes and the 5-minute outage before deciding whether multi-region serving or more capacity would reduce measured risk; separately prove Cloud SQL write consistency and failover behavior. | Canary adds release steps and temporary capacity but is already built. A second region adds routing, replicated capacity, failover complexity and data-consistency risk; do not adopt without measured region-correlated outage evidence. |
| Cloud SQL regional availability and restore | Prd is configured REGIONAL with standby (SPL-2250); dedicated-core tier landed (SPL-2932); automated backups and PITR are enabled. The old spec-029 sample is not current configuration. A database failure can still affect all API reads/writes if reconnection or restore exceeds budget. | Do not re-enable HA/PITR. Run separately approved failover and restore drills; measure client reconnect time, data loss window, RTO and application error minutes. Keep pools bounded and retries idempotent. | HA and PITR costs are already incurred. Drills have operational risk and require an approved window; multi-region writes cost more and can introduce conflict/fencing risk. |
| Shared hub/API dependency across WUI, CLI, agents and orchestration | `/v1/health` does not measure authenticated feed/message paths. The primary check found 36 strict failing minutes and the request metric found 2,425 5xx responses, but a 30-minute remote-source hub-stall notice on Nov 10 had no failed uptime-check minute that day; exact 5xx overlap is unavailable. | Keep the existing 3-region, 60-second health check, and add tenant-safe authenticated WUI and end-to-end message synthetics with independent timestamps and request IDs. Correlate each alert with release revision and service request metrics. | Synthetic traffic and telemetry cost; test identities/content need isolation. This adds coverage without treating a 200 health response as end-to-end success. |
| Remote-fleet lease, log transfer and local disk/heartbeat | Sat's 30-day copy has 25 `none@unreachable` windows totaling 79,731 role-seconds, 13 stale takeovers over 180 s, 52 HUB-UNREACHABLE lines and 77 NO-LOCAL-AGENT lines. The longest interval contains intentional desk quiesce/refusal, so the summed role-time is not a confirmed service outage. | Measure eligible remote-fleet lease claims/renewals, dead-man heartbeat, relay delivery and disk/inode headroom from an independent observer. Separate intentional holds and no-seat intervals from failure; keep fencing and test failover across at least two eligible non-laptop boxes. | More observability and operational roles; quorum can reduce writes during partitions. Exclude laptop from the SLO, quorum and failover capacity by design. |
| CI runner capacity and serial pre-push work | Workflow 10 had 544 failed runs of 3,862 (14.1%). WUI E2E had 679 failed jobs and ORC hermetic tests 471; queue-time is absent, so runner saturation is still a hypothesis. | Measure queue and execution time by required job; add independent runner capacity only if queueing is material. Cache only deterministic checks and preserve branch protection. | Runner spend, cache invalidation risk, and reproducibility work. Never weaken correctness gates to improve the dashboard. |
| Monitoring and alert delivery | Uptime and 5xx extracts were successfully read from the remote-fleet's approved prd service-account path. The laptop's Nov 12 local read failed before querying because its local key metadata was incomplete; no key was opened or re-minted, and this does not establish a fleet-wide credential defect. | Keep the approved read path and automate the monthly per-env SLI extract; test a failure from each source through the notification channel and alert-to-human path. Keep an external heartbeat/dead-man monitor for the monitoring process itself. | Requires notification test coverage and clear alert ownership; an independent route has extra cost but avoids dependence on the hub being measured. |

The measured API checks meet 99.9% for this 30-day window, but the strict regional SLI has only 7.2 minutes of budget headroom. Attribute its 31 regional-only failing minutes, the Oct 15 five-minute episode, the 2,425 5xx responses, and the unmatched 30-minute hub-stall notice. Define a separate eligible-operation SLI for dispatch/orchestration before treating the 79,731 summed role-seconds of `none@unreachable` as product downtime. Canary/rollback and regional SQL HA already exist; multi-region writes remain a high-cost option until consistency, idempotency, failover and restore behavior are demonstrated.

### 4.2 Reliability and delivery are separate objectives

Availability alone does not measure stable feature delivery. Track a release SLI beside availability: percentage of master deploys that pass required CI, deploy to dev, pass a synthetic bake, then deploy to prd without rollback or a new attributable incident within 60 minutes. Keep the 30-day cohort, job-level failures, lead time and rollback rate visible. A successful release must not be claimed from a green workflow alone.

## 5. SLI, SLO and proof plan

1. **Request-success SLI:** the intended measure is (all eligible responses minus 429 and 5xx) / all eligible responses, from `run.googleapis.com/request_count` summed over revisions by response class. The 30-day extract supplies 6,837,300 total requests and 2,425 5xx, so the measured 5xx-only request share is 99.9645%; the 429 request count is absent, so the full request-success SLI is not yet measured. The 5xx-only share uses 35.5% of a 0.1% request-error budget. The method follows [Hub SLO](../../doc/md/SLO-spool-hub.md) §2.1; the target is 99.9%, not that proposal's old 99.5%.
2. **Uptime-check SLI:** pass samples / observed samples for each configured region, from `monitoring.googleapis.com/uptime_check/check_passed`, 60-second interval and 10-second timeout. In 2026-10-13T09:12Z .. 2026-11-12T09:11Z (n=43,200 aggregate minutes), strict any-region availability was 99.9167% (36 failing min), majority availability 99.9884% (5 min), and all-three-region availability 99.9884% (5 min). Per-location/region counts and 28 APAC missing minutes are in §2.1. Report regional values and missing data separately; a one-minute check does not prove every endpoint worked between samples.
3. **End-to-end message SLI:** successful synthetic create → recipient delivery → read acknowledgement within 60 seconds / all synthetic attempts. Use a dedicated synthetic tenant and remote-fleet agent pair, with no customer message bodies; store attempt/result timestamps only.
4. **WUI SLI:** successful page load plus authenticated read/action synthetic from an external region, measured separately from API uptime.
5. **Remote control-plane SLI:** successful scheduled heartbeat and lease claim/renew/failover across eligible remote-fleet boxes. Report successful operations / attempts and missed-heartbeat minutes, with the laptop excluded from denominator, quorum and failover capacity.
6. **Release SLI:** required CI and staged-deploy success as specified in §4.2; report workflow failure rate, queue time, rollback rate and 60-minute post-release incident rate by release cohort. Keep it separate from uptime minutes.
7. **Monthly objective:** each customer-facing service SLI and end-to-end message SLI ≥99.9% over a rolling 30-day window, with a burn-rate alert. In the measured window, strict regional uptime and 5xx-only request availability exceed 99.9%; the full 429+5xx request SLI, WUI synthetic, message synthetic and remote-control-plane SLI remain unmeasured. Do not infer these from zero policy incidents.

Proof requires at least 90 days of retained minute-level SLI data, region and revision labels, alert-open/close records, deploy markers, and a tested synthetic failure. The 30-day view names each command, exact start/end, n, successful and failed samples/requests, minutes consumed, and the largest correlated incident class. Publish the monthly budget burn. A policy count is supporting evidence, never the SLI denominator.

## 6. Decisions required before implementation

- Attribute the 31 regional-only uptime failures and the 5-minute Oct 15 all-region failure; keep 429 request counts in the recurring extract so the full request-success SLI is available.
- Define a separate eligible-operation SLI for dispatch/orchestration and split the 79,731 summed role-seconds of `none@unreachable` into actual failures, intentional holds and no-seat/refusal time.
- Keep the owner's whole-system 99.9% objective; report per-service SLIs and the end-to-end message SLI independently so one healthy component cannot hide another's failure.
- Measure Cloud SQL failover and restore time in an approved drill; do not propose enabling regional HA or PITR again.
- Review additional runner capacity and second-region serving only after the per-job queue and outage-duration measurements show that each would reduce the budget burn enough to justify its recurring cost.

<!-- version: 0.4.0 · updated: 2026-11-13 · last-edit: 2026-11-13T09:14Z -->
