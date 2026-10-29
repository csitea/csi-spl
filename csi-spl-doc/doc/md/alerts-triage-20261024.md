# Alerts triage 2026-10-24 (SPL-3189)

Epic SPL-2364, spec 146 (reliability round). Owner ask (t1 1164741e, msg
8bdcbccb), steps 1-4: read every alert, find its dependencies and trends,
classify the problem types, file one issue per new type. Step 5 (the panel and
the fix lanes) is the dispatcher's. Read only: nothing was changed on dev, prd
or a box.

## 1. What was read

| source | how | window | n |
|---|---|---|---|
| GCP alert incidents, dev + prd | `cd csi-spl-iac && ENV=<env> SINCE=14d ./run -a do_gcp_list_alert_incidents`, then `do_gcp_get_alert_incident` for single incidents | 2026-10-10T09:13Z .. 10-24T09:13Z | prd 39 incidents, dev 1 |
| hub ERROR log lines | `ENV=<env> FORMAT=json FRESHNESS=14d ./run -a do_gcp_tail_logs` with the filter of the `hub error log rate` log metric | same | prd 5402 lines, dev 69 |
| hub run metrics, one at-max episode | `cd csi-spl-orc && ENV=prd REQ_SINCE=2026-10-23T19:50:00Z REQ_MINUTES=140 ./run -a do_spl_hub_run_metrics` | 140 min | 1 window |
| box alerts (#alerts of t1: bench, NO-LOCAL-AGENT, no live orchestrator) | `ENV=prd SQL=... ./run -a do_spl_db_query`, `channel='alerts'` | 10-17 .. 10-24 (the channel keeps 7 days) | 49 alert lines |
| disk guard notes | `DISK HEADROOM` notes in the orchestrator's spool inbox on sat | 10-10 .. 10-24 | 63 WARN + 6 CRITICAL |
| CI gate | `cd csi-spl-iac && CI_GATE_RUNS=<n> CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 10-17T14:01Z .. 10-24T09:38Z (the run list stops at 1000 runs: 7 days, not 14) | 1000 runs, 97 failed; signatures for the last 400 (32 failed) |

How to read the incident counts: the list action rebuilds incidents by
replaying TODAY's policy conditions over the past series. A policy that is
newer than the window shows what it would have paged, not what did page:
`hub at max instances` and `hub memory high` landed 10-21 (b43250bc4),
`hub sign-in 5xx` and `hub views slow` 10-22 (ee3f5a978, their log metrics
have no older data).

Not checked: the second box's (box-2 below) disk notes (they go to box-2's orchestrator inbox), box-2's own
beat log, Cloud SQL's operation list, who sent the 10-13 non-uuid task id, and
the watchdog's per-seat restart log (no fleet-level alert line comes from it
other than the ones in #alerts).

## 2. GCP alert policies, 14 days

| policy | env | incidents | first | last | per day | trend |
|---|---|---|---|---|---|---|
| hub at max instances | prd | 15 (7 since the policy went live) | 10-14 07:10Z | 10-23 20:53Z | 10-14 2, 15 1, 16 2, 17 1, 20 2, 21 1, 22 4, 23 2 | up |
| hub 5xx rate | prd | 10 | 10-16 18:18Z | 10-22 10:08Z | 10-16 5, 20 3, 22 2 | down (none after the 10-22 tier change) |
| hub error log rate | prd | 8 | 10-13 19:03Z | 10-22 22:43Z | 10-13 1, 18 1, 20 3, 22 3 | down |
| hub error log rate | dev | 1 | 10-22 15:23Z | 10-22 15:23Z | 10-22 1 | flat |
| hub 429 streak | prd | 2 | 10-11 16:14Z | 10-15 07:37Z | 10-11 1, 15 1 | gone since 10-15 |
| hub health check failing | prd | 2 | 10-11 16:15Z | 10-15 07:36Z | 10-11 1, 15 1 | gone since 10-15 |
| Cloud SQL down, memory high, sign-in 5xx, views slow | dev + prd | 0 | - | - | - | - |

What the prd ERROR lines were (5402 lines):

| line | n | days | belongs to |
|---|---|---|---|
| `topic channel` / `store message`: invalid input syntax for type uuid "dispatch-<8hex>" | 4534 | 10-13 only, 19:0x..23:13Z | type G3 |
| `Cloud SQL connection failed ... dial error` | 258 | 10-18 07:00-07:08 (129), 10-20 09:19-09:24 (29), 10-22 09:46 (1), 10-22 22:38-22:39 (99) | G2 (planned applies), K1 (10-20 stall) |
| relay / sweep loops: `failed to connect` or `write failed` | 361 | 10-18, 10-20, 10-22 | same windows as above |
| `http 5xx` | 121 | 10-10..10-22, most on 10-16 (17), 10-20 (51), 10-22 (26) | K1, K3 |
| `flow read` / tenant lists: statement timeout | 57 | 10-20, 10-22 | K1 |
| `auth.native_login store`: context deadline exceeded | 21 | 10-16 (16), 10-20, 10-22 | K3, K1 |

## 3. Box and CI alerts

| alert | where | n | first | last | trend |
|---|---|---|---|---|---|
| Box box-2 benched (beat gap > 120 s) outside a hub stall | t1 #alerts | 11 | 10-17 11:26Z | 10-24 01:54Z | flat, ~1.5 a day |
| Box sat / box-2 benched inside a hub stall | t1 #alerts | 4 | 10-18 07:11Z | 10-22 09:54Z | follows the stalls |
| NO-LOCAL-AGENT (orch or dispatch) | t1 #alerts | 8 | 10-20 06:50Z | 10-22 10:28Z | 10-20 5, 10-22 3 |
| "no live orchestrator" ALERT | t1 #alerts | 9 alerts | 10-18 00:3xZ | 10-22 10:0xZ | about 1 a day |
| DISK HEADROOM sat, WARN (>= 85 %) | orch spool inbox | 63 | 10-10 | 10-24 | flat, 3-11 a day |
| DISK HEADROOM sat, CRITICAL (>= 92-93 %) | orch spool inbox | 6 | 10-11 | 10-24 05:22Z | up: 5 of 6 after 10-19 |
| CI gate (wf 10) failed runs | GitHub Actions | 97 of 1000 | 10-17 | 10-24 | down: failed / (failed + green) 19 % 10-17, 37 % 10-19, 13 % 10-22, 10 % 10-23, 5 % 10-24 |

The first red job of each failed run (97 runs; 13 had no failed job, e.g. a
start-up failure): wui browser e2e 33 (13 on 10-19), orc hermetic action tests
26 (every day, 7 on 10-22), wui initial-JS budget 12 (all 10-18), iac 6, hub
Postgres gate 5, others 2. The 400-run signatures show separate defects that
each lived for hours, not one cause: `9e. a second re-check writes no new Go
cache entry` (2 runs 10-24 00:49-01:01Z, green since 08:49Z), `7. prd hub
unserved past the grace` (3 runs 10-23 15:37-15:52Z, SPL-3065), a lane-restart
case 6 (10-23 17:33Z), `no-x-scroll.test.mjs` (10-23 11:47Z).

The 9 "no live orchestrator" alerts: two real outages (10-18 12:0xZ, 19 h,
the claude login, SPL-2521; 10-21 17:2xZ, SPL-2766), one epoch-sized false
alert (10-20 01:35Z, SPL-2654), two inside a hub stall (10-18 07:11Z, 10-22
10:0xZ, type K2), one in a takeover drill (10-20 08:4xZ), and three short ones
that cleared by themselves in 3-59 min (10-18 00:43Z, 10-19 11:43Z, 10-21
18:52Z). Three is too few to call a type; they are listed, not filed.

## 4. Dependency chains

Each link: the same minute, or the next event within 40 min, on the
timestamps above.

| # | chain | seen | n |
|---|---|---|---|
| D1 | DB on a shared core starved (CPU flat at 0.25) -> statement timeouts + `Cloud SQL connection failed` -> hub 5xx + error-log incidents + sign-in timeouts -> boxes benched, NO-LOCAL-AGENT, "no live orchestrator" | 10-20 08:45-09:20Z, 10-22 09:20-10:15Z | 2 stalls (db-tier-evidence-2026-10-22.md) |
| D2 | planned Cloud SQL apply (restart) -> `Cloud SQL connection failed` for seconds to 8 min -> error-log incident -> (10-18) "no live orchestrator" + sat benched | prd 10-18 07:00Z, prd 10-22 22:38Z, dev 10-22 15:19Z | 3 applies |
| D3 | retired Cloud Run instances hold both max_instances slots -> 429 "Rate exceeded" -> uptime check fails (1 min later) | 10-11 16:14Z, 10-15 07:33Z | 2 |
| D4 | a box posts the bench alert through the hub that is down -> "the benched alert could not be delivered" -> only the "back" line arrives | 10-18, 10-20, 10-22 (4 lines) | 4 of 4 benches inside a stall |
| D5 | non-uuid task_id -> 500 -> the sender retries ~9 a minute -> 4534 ERROR lines -> error-log incident | 10-13 19:03-23:13Z | 1 |

No chain was seen from `hub at max instances` to any other alert: in its
15 episodes there is no 429, health or 5xx incident that opens inside it except
10-16 18:1x and 10-20 08:3x, which are the K3 and K1 windows.

## 5. Problem types

One root cause = one type. "Covered" = an issue already holds it; no new
issue was filed.

| type | evidence | 14-day count | trend | cause | owner | issue |
|---|---|---|---|---|---|---|
| K1 prd DB too small (shared core) | 5xx 10-20 + 10-22, error log, statement timeouts | 5 5xx + 4 error-log incidents, 2 stalls | down: none after the 10-22 22:38Z tier change (1.5 days, too short to prove) | CPU starvation, swapping | iac 040 | covered: SPL-2880, SPL-2932 (done) |
| K2 retired instances hold max slots | 429 + health 10-11, 10-15 | 2 + 2 | gone 9 days | 60-min sockets on retired instances | api | covered: SPL-1981 (done, socket max life) |
| K3 stuck prd instance 10-16 | 5xx 18:18-20:23Z, sign-in deadline | 5 | gone | WS hello deadlock on a cold instance | api | covered: SPL-2238 (fix 5d43e166b), SPL-2252 |
| K4 sat disk fills | 6 CRITICAL notes | 6 | up to 10-24, 83 % at 09:40Z | Go build cache, worktrees | orc / utl | covered: SPL-3110, SPL-3119, SPL-3171, SPL-3179 |
| K5 "no live orchestrator" epoch false alert | 10-20 01:35Z | 1 | gone | unbounded age | orc | covered: SPL-2654 (done) |
| G1 at-max alert pages an idle hub (noise) | 15 incidents, CPU p99 <= 0.06 in the measured one | 15 | up | max 2 = min + 1 is the normal idle state | iac 070 | **SPL-3193** |
| G2 planned DB apply pages error-log (noise) | 3 of 9 error-log incidents | 3 | follows applies | no snooze on an approved apply, loops log ERROR per tick | iac 070/040 + api | **SPL-3194** |
| G3 non-uuid task_id -> 500 + ERROR flood | 4534 lines, 1 incident | 1 | one burst | task_id is not validated as a uuid | api msg.Validate | **SPL-3195** |
| B1 one hub stall fans out into box alerts | D1/D2/D4: 15 box lines in 3 stalls | 3 stalls | follows K1 | box alerts read "hub unreachable" as "box/orch dead", and post through that hub | orc lease / bench | **SPL-3196** |
| B2 box-2 heartbeat gaps | 11 benches outside stalls, gaps 125-198 s | 11 in 7 days | flat | unknown, box-2 side | orc box beat (box-2) | **SPL-3197** |
| B3 disk WARN re-fires at the 85 % line (noise) | 63 WARN at 85-88 % | 63 | flat | re-arms right below 85 % | orc check-disk-headroom | **SPL-3198** |
| C1 CI reds | 97 failed runs in 7 days, separate short-lived signatures | 97 | down | a defect landed, then fixed by its lane | each lane, the standing CI seat | covered: the standing CI seat; no new issue |

The bench line's text ("33 beats in 10m < 30") contradicts itself; that is
SPL-1998 (wip), not a new type. Fixed by SPL-4200 (2026-10-29): it was the gap
rule worded as the count rule; see `alerts-fix-round-plan.md` section 2.5.

## 6. Issues filed

All six in t1, epic SPL-2364, spec 146, discussion t1 1164741e, status
eval, filed 2026-10-24 10:00-10:01Z by the orchestrator's desk from this
lane's bodies (the lane had no desk seat). Each body carries its evidence.

| key | type | class |
|---|---|---|
| SPL-3193 | G1 the at-max-instances alert pages an idle hub | noise (policy) |
| SPL-3194 | G2 a planned DB apply pages error-log | noise (policy / apply path) |
| SPL-3195 | G3 a non-uuid task_id gets a 500 and floods ERROR lines | bug (api) |
| SPL-3196 | B1 one hub stall fans out into box alerts | bug (orc) |
| SPL-3197 | B2 box-2 heartbeat gaps | bug (box, box-2) |
| SPL-3198 | B3 the disk WARN re-fires at 85 % | noise (orc guard) |

Out of scope, reported only: `do_gcp_tail_logs` fails with "no gcloud
account" unless `GCP_SA_KEY_FILE` is set (the other iac gcp actions resolve
the key from ENV).

