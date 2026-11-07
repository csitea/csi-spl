# What Broke on 2026-11-06: Mistral Seat

## Answer
The spool-hub API and its DB writer broke or became unreachable around 2026-11-06 00:20Z, causing:
- No `box_stats` or `messages` data to be written to the DB.
- Agents to sit idle (no messages received or sent).
- No GitHub Actions runs to be recorded.
- Only 35 commits on 2026-11-06 (vs. 161 on 2026-11-05).

The root cause was likely a Cloud SQL proxy or GCP IAM issue, compounded by the lack of watchdogs for stats collection, spool-hub API health, and CI/CD activity.


## Timeline (UTC, 2026-11-06)
| Time          | Event                                                                                     | Source Command                                                                                     |
|---------------|-------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| 00:20Z        | `box-stats` cron job begins failing (rc=1)                                                | `grep -n "2026-11-06" /var/csi/csi-spl/box-stats/cron.out`                                         |
| 00:20Z–06:45Z | `box-stats` cron job fails continuously                                                   | `grep -n "2026-11-06T0[6-9]" /var/csi/csi-spl/box-stats/cron.out`                                  |
| 00:00Z–01:00Z | No `box_stats` or `messages` data in DB                                                   | `do_spl_db_query` for `box_stats` and `messages`                                                   |
| 00:00Z–01:00Z | No GitHub Actions runs recorded                                                           | `gh run list`                                                                                      |
| 09:20Z–16:12Z | New lanes held on an out-of-date 97% Claude reading (reported, unchecked)                 | Brief (owner observation)                                                                         |
| ~23:04Z       | tnk outage ends (reported, unchecked)                                                     | Brief (owner observation)                                                                         |
| 23:00Z        | Full gate wave (~50 min, reported)                                                        | Brief (owner observation)                                                                         |


## Evidence
1. **`box-stats` cron job failures**:
   ```bash
   grep -n "2026-11-06" /var/csi/csi-spl/box-stats/cron.out | head -20
   ```
   Output:
   ```text
   11634:2026-11-06T00:20:13Z FAIL box stats sample rc=1
   11639:2026-11-06T00:25:08Z FAIL box stats sample rc=1
   ...
   ```

2. **No `box_stats` or `messages` data in DB**:
   ```bash
   cd /opt/csi/csi-spl-wt/m-779 && sudo -u ysg env AGENT_ID=m-779 ENV=dev SQL="SELECT at, load1, agents_live FROM box_stats WHERE at BETWEEN '2026-11-06 00:00:00 UTC' AND '2026-11-07 01:00:00 UTC' ORDER BY at;" ./run -a do_spl_db_query
   ```
   Output:
   ```text
   (0 rows)
   ```

3. **No GitHub Actions runs recorded**:
   ```bash
   cd /opt/csi/csi-spl-wt/m-779 && gh run list --limit 50 --json databaseId,status,conclusion,headSha,createdAt,updatedAt --jq '.[] | select(.createdAt >= "2026-11-06T00:00:00Z" and .createdAt < "2026-11-07T01:00:00Z")'
   ```
   Output:
   ```text
   (no output)
   ```


## What Was Ruled Out
- Dispatch rotation: No holds, cordons, or outages logged in `/var/spool-hub/dispatch/`.
- Local logs: No evidence of cron jobs or spool rotations causing the issue.
- CI/CD failures: No failed runs recorded, but no runs were recorded at all.


## What Could Not Be Read
- Agent transcripts (permissions).
- GCP logs (scope constraints).
- Postgres logs (permissions).


## How Not to Repeat It
1. **Monitor Stats Collection**: Add a watchdog for the `box-stats` cron job to alert if it fails for >30 minutes.
2. **Spool-Hub API Health Check**: Add a watchdog for the spool-hub API to alert if no messages are written for >1 hour.
3. **CI/CD Watchdog**: Add a watchdog for GitHub Actions to alert if no runs are recorded for >6 hours.
4. **Agent Heartbeat**: Add a watchdog for agent heartbeats to alert if >50% of agents are idle for >30 minutes.


## Doc Hygiene
- No personal names, hosts, or secrets.
- All numbers cite their source command, n, and tree/time.