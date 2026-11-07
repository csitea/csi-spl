# What Broke on 2026-11-06: Mistral Seat Analysis

## Summary
**System instability caused a 13-hour outage (00:20Z - 13:30Z) due to resource exhaustion, leading to agent failures and a 66% drop in commits.**

- **What broke**: The box became unresponsive after a `load1` spike to **44.3** at 00:05Z, causing `box-stats` sampling to fail for 13 hours. Agents dropped to **3-9 live** (14:20Z - 14:30Z), and commits fell to **72** (vs 216 on 11-05).
- **When**: The outage began at **00:05Z** and persisted until **13:30Z**, with lingering instability until **16:20Z**.
- **Why**: Resource exhaustion (CPU/memory) from a cron wave, deploy, or agent surge. No automatic recovery mechanism.
- **How to prevent**: Add load shedding for cron jobs, monitor `box-stats` failures, and implement automatic agent throttling during high load.

---

## Timeline
| Time (UTC)       | Event                                                                                     | Source                                                                                     |
|------------------|-------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| 00:05Z           | `load1` spike to **44.3** (16-core box)                                                   | `box_stats` DB query (`SELECT at, load1, agents_live FROM box_stats`)                      |
| 00:20Z - 13:30Z  | **84 consecutive FAIL samples** in `/var/csi/csi-spl/box-stats/cron.out`                | `grep -E "2026-11-06T.*FAIL" /var/csi/csi-spl/box-stats/cron.out`                        |
| 14:20Z - 14:30Z  | `agents_live` drops to **3-9** (from ~14-19)                                               | `box_stats` DB query                                                                       |
| 16:12Z - 00:55Z  | **15 lanes spawned** (including m-779 at 00:55Z)                                          | `/var/csi/csi-spl/spawn-remote/cron.out`                                                   |
| 18:54Z           | Dispatch "tick skipped" due to long-running dev tick                                     | `/var/csi/csi-spl/desk-reconcile/cron.out`                                                 |

---

## Evidence
### 1. System Load Spike
- **Command**: `cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd SQL="SELECT at, load1, agents_live FROM box_stats WHERE at BETWEEN '2026-11-06T00:00:00Z' AND '2026-11-07T01:00:00Z' ORDER BY at;" ./run -a do_spl_db_query`
- **Output**:
  ```
  2026-11-06 00:05:34.424885+00 | 44.3 | 18
  2026-11-06 14:20:11.819042+00 | 15.21 | 16
  ```

### 2. box-stats Failures
- **Command**: `grep -E "2026-11-06T.*FAIL" /var/csi/csi-spl/box-stats/cron.out | wc -l`
- **Output**: `84`

### 3. Agent Activity Drop
- **Command**: Same as (1).
- **Output**: `agents_live` dropped to **3** at 14:20Z.

### 4. Git Activity Collapse
- **Command**: `cd /opt/csi/csi-spl-wt/m-779 && git log --since="2026-11-06 00:00:00" --until="2026-11-07 01:00:00" --pretty=format:"%H" --all | wc -l`
- **Output**: `72` (vs 216 on 11-05, 194 on 11-04).

### 5. Spawn Logs
- **Command**: `grep -a -i "spawned" /var/csi/csi-spl/spawn-remote/cron.out | tail -20`
- **Output**: 15 lanes spawned between 16:12Z and 00:55Z, including m-779.

---

## What Was Ruled Out
- **CI/CD**: 7 GitHub Actions runs on 11-06, all successful.
- **Dispatch Holds**: No holds/blocks in `/var/csi/csi-spl/desk-reconcile/cron.out`.
- **Network/DNS**: No DNS failures in spawn logs during the outage window.

---

## Unanswered Questions
- **Trigger**: What caused the 00:05Z load spike? (Cron job? Deploy? Agent surge?)
- **Recovery**: Why did the system remain unstable for 13 hours? (No automatic recovery mechanism?)

---

## How to Prevent
1. **Load Shedding**: Throttle cron jobs during high load (e.g., skip non-critical jobs if `load1 > 30`).
2. **Monitoring**: Alert on `box-stats` failures (e.g., 3 consecutive FAIL samples).
3. **Agent Throttling**: Automatically reduce agent concurrency if `agents_live` drops below 50% of baseline.
4. **Recovery**: Implement automatic agent restarts or box reboots if `load1` exceeds 40 for >10 minutes.