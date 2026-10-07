# Spool Watchdog Setup and Operations Guide (Spec 102 v1.2)

This document describes how the spool watchdog architecture operates under
Spec 102 v1.2, how its components fit together, the layout of files and locks,
how to install the setup on a box, and how to diagnose and recover from failures.

---

## 1. Architecture Overview (The v1.2 Target Model)

Under Spec 102 v1.2, watchdog supervision on each box is provided by a
three-tier architecture designed to eliminate single points of failure:

```
┌────────────────────────────────────────────────────────────────────────┐
│ Hub API                                                                │
│  - Receives box_beats (inst = 1, 2, 3) from each live box              │
│  - Derives wd_count per box (active beats within box_down_min)         │
│  - If wd_count == 0: emits ONE Section 11.2 admin alert (DM + email)   │
│  - Observer only: strictly zero action on remote agents                │
└───────────────────────────────────▲────────────────────────────────────┘
                                    │ box_beats (inst 1, 2, 3)
┌───────────────────────────────────┴────────────────────────────────────┐
│ Box User Environment (<box user>)                                      │
│                                                                        │
│  ┌───────────────────┐  ┌───────────────────┐  ┌────────────────────┐  │
│  │ Watchdog Inst 1   │  │ Watchdog Inst 2   │  │ Watchdog Inst 3    │  │
│  │ (pid, run.1.lock) │  │ (pid, run.2.lock) │  │ (pid, run.3.lock)  │  │
│  └─────────┬─────────┘  └─────────┬─────────┘  └──────────┬─────────┘  │
│            │                      │                       │            │
│            └──────────────┬───────┴───────────────────────┘            │
│                           ▼                                            │
│            Mutual Peer Monitoring & Restart (WD4)                      │
│            - Heartbeats: heartbeat.<inst>.json every tick (30 s)       │
│            - Dead peer (< 30 s) -> restarted under start.lock          │
│            - Hung peer (WD_HUNG >= 180 s) -> TERM/KILL + restart       │
│            - Judge lock: <id>.judge.lock (one evaluator per agent)     │
│            - Crontab self-healing: verifies cron line, restores it     │
│            - Cron dead alert: alerts Section 11.2 if cron stops        │
│            - Failure alerts: alerts Section 11.2 if 2 of 3 down        │
│                                   ▲                                    │
│  ┌────────────────────────────────┴─────────────────────────────────┐  │
│  │ Crontab Starter (* * * * * and @reboot, box user)                │  │
│  │  - Single entry point in crontab, installed from source          │  │
│  │  - Runs: spl_wd_inst_start (if < 3 running, start missing ones)  │  │
│  │  - No separate keeper logic, heartbeat, or alerts                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 The 3-Watchdog Daemon Pool
- Every box runs **three active watchdog daemons** simultaneously (`INSTANCE` 1, 2, 3) as the unprivileged box user (`<box user>`).
- Each holds an exclusive OS file lock (`run.<inst>.lock`, non-blocking `flock`) for its entire lifetime. Lock files are never unlinked (`rm -f` is forbidden).
- Each operates in an isolated scratch workspace (`tick.<inst>/`, `ctx.<inst>/`, `heartbeat.<inst>.json`) so instances never clobber each other's temporary state.
- **One judge per agent per tick**: Before evaluating any agent, an instance acquires `<id>.judge.lock` (`flock -n`). If held by a peer or judged within `WD_TICK - 5` s, the instance skips that agent. All situation and episode states are written strictly under the judge lock.
- **Mutual peer supervision (WD4)**: Surviving instances inspect peer liveness (`kill -0`) and peer progress timestamps (`last_progress_ts` in `heartbeat.<inst>.json`). Dead peers are restarted immediately; hung peers ($\ge \text{WD\_HUNG} = 180\text{ s}$) are cleanly terminated (`SIGTERM`, grace, `SIGKILL`) and restarted under `run.<inst>.start.lock`.

### 1.2 The Crontab Starter
- The crontab line (`@reboot` and `* * * * *`, box user) executes the watchdogs' own start command: `spl_wd_inst_start`.
- It performs exactly one task: **if fewer than 3 instances run, start the missing ones**.
- It contains **zero separate supervisor logic, zero heartbeat (`inst = 0`), and zero alerts**.
- It runs unprivileged from the self-updating desk-cron checkout, always launching daemons from the verified `code/good` snapshot.

### 1.3 Hub-Derived Liveness & Box Beats
- Watchdog instances 1, 2, 3 report their beats to the hub's `box_beats` table.
- There is **no keeper beat (`inst = 0`)**.
- The hub computes `wd_count` as the number of active instance rows updated within `box_down_min`.
- If a box has `wd_count = 0` (no watchdog instance beating), the hub sends **one debounced admin alert** (Section 11.2).
- The hub acts strictly as an **observer**: zero remote agent migration or CAS is performed when watchdogs are down. Agent failover remains exclusively governed by full box-down detection (absence of all box communication for `box_down_min`, Section 10.2).

### 1.4 The v1.2 Decision: No Separate Keeper
In topic `637269bb-d97b-4861-b45e-87200652b169` (HUM-10), the owner decided:
- msg `a606118a`: *"what is the keeper - there should not be any single point of failure ?!"*
- msg `25731cc9`: *"... why we need a separate keeper .. why not move this responsibility to the wather services"*
- msg `575c9d19`: *"yes , go for it , of course add all of the cron things to the source code and document the setup properly ... otherwise , next time we are in trouble , we would not know how it is supposed to be working"*

This eliminated the separate keeper daemon (`do_spl_wd_ensure`), keeper heartbeats, and keeper alerts. Redundancy is achieved through mutual peer supervision among the 3 watchdogs, backed by a simple crontab starter and hub-level observation.

### 1.5 Watchdog Self-Healing & Cron Daemon Monitoring
- **Crontab Line Self-Healing**: On each tick, an active watchdog checks that the crontab starter line exists in the box user's crontab. If the line was deleted or corrupted, the watchdog reinstalls it via `do_spl_wd_ensure_install_cron`.
- **Cron Daemon Failure Detection**: The crontab starter touches `<spool root>/dispatch/wd/starter.last` on every run. If this file becomes stale while watchdogs continue running, the watchdogs detect that the system cron daemon has stopped. Since restarting cron requires root privileges, the watchdogs raise an admin alert (Section 11.2, WD5) rather than attempting a fix.

---

## 2. Codebase Status: Live Today vs. Built by Tasks T023a..T027

### 2.1 Summary Table

| Component | Live Today (Existing Code) | Built by Tasks (T023a..T027 Target) | Task |
|---|---|---|---|
| **Daemon Execution** | Single daemon loop (`do_spl_watchdog`), single lock `run.lock`, single pid `run.pid` | 3 concurrent daemons (`INSTANCE=1..3`), locks `run.1.lock`..`run.3.lock`, pids `run.1.pid`..`run.3.pid` | T023a |
| **Agent Arbitration** | Single process evaluates all agents sequentially | Non-blocking per-agent judge lock `<id>.judge.lock`, isolated scratch dirs `tick.<inst>/`, `ctx.<inst>/` | T023a |
| **Peer Monitoring** | Live (T023b): `spl-wd-peers.func.sh`, `./run -a do_spl_wd_peers` prints each instance's state | Mutual peer inspection (`kill -0`), `heartbeat.<inst>.json`, hung floor $\ge 180\text{ s}$, restart via `spl_wd_inst_start` | T023b |
| **Outer Supervisor** | Live (T023b): `./run -a do_spl_wd_inst_start` (`spl-wd-inst-start.func.sh`); the legacy keeper line is dropped on install | Crontab starter running `spl_wd_inst_start` only (starts missing instances up to 3); no separate keeper | T023b |
| **Crontab Installation** | Live (T023b): `do_spl_wd_ensure_install_cron` installs `* * * * *` (`# <app>:wd-start`) and `@reboot` (`# <app>:wd-start-boot`); `WD_CRON_KIND=ensure` = the legacy `# <app>:wd-ensure` line | Idempotent installer action maintained in source; updated to render `spl_wd_inst_start` command line | T023b |
| **Liveness Reporting** | Local log only (`wd.log`, `last.tick`) | `box_beats` reporting by instances 1..3; hub computes `wd_count`; 0-watchdog alert emitted by hub | T024 |
| **Code Updates** | Executing directly from moving checkout; risk of mixed sourced scripts | Version-pinned snapshots `code/<sha>/`, `good` symlink, baton handoff rolling restart (< 70 s), rollback to `good` | T025 |
| **Admin Alerts** | Legacy `ASKS_OWNER` DM via `do_spl_desk_reply` on crash loop or hung loop | Section 11.2 hub admin messages (DM + email) sent directly by watchdogs on 2 of 3 down, down > 5 min, or cron stopped | T026 |
| **Verification & Drill** | Manual testing | Comprehensive live drill covering peer restart, hung kill, rolling update, crontab line restore, cron dead alert | T027 |

### 2.2 Proof of Live Code Today (Grep Verifications)

Run these commands from the repository root to verify the existing live implementation:

1. **Watchdog daemon function definition**:
   ```bash
   grep -n 'do_spl_watchdog()' csi-spl-orc/src/bash/run/spl-watchdog.func.sh
   ```
   *Expected output*: `48:do_spl_watchdog() {`

2. **Single instance lock and PID file in live watchdog**:
   ```bash
   grep -n -E 'run\.(lock|pid)' csi-spl-orc/src/bash/run/spl-watchdog.func.sh
   ```
   *Expected output*:
   ```text
   51:  exec 7>>"$WD_DIR/run.lock"
   53:    do_log "INFO a watchdog already runs on this box ($WD_DIR/run.lock)"
   56:  echo "$$" > "$WD_DIR/run.pid"
   ```

3. **Crontab installer action in source**:
   ```bash
   grep -n 'do_spl_wd_ensure_install_cron()' csi-spl-orc/src/bash/run/spl-wd-ensure-install-cron.func.sh
   ```
   *Expected output*: `158:do_spl_wd_ensure_install_cron() {`

4. **Crontab line tag definition**:
   ```bash
   grep -n 'SPL_WD_CRON_TAG' csi-spl-orc/src/bash/run/spl-wd-ensure-install-cron.func.sh
   ```
   *Expected output*:
   ```text
   52:  SPL_WD_CRON_TAG="$SPL_ORG_APP:wd-ensure"
   ```

5. **Legacy outer supervisor function**:
   ```bash
   grep -n 'do_spl_wd_ensure()' csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh
   ```
   *Expected output*: `69:do_spl_wd_ensure() {`

---

## 3. Files, Locks, Heartbeats, and Directory Layout

All runtime files live under `<spool root>/dispatch/wd/` (default `/var/spool-hub/dispatch/wd/`) and log directories `/var/<org>/<org>-<app>/wd/` (default `/var/csi/csi-spl/wd/`):

### 3.1 Directory Structure

```text
<spool root>/dispatch/wd/
├── run.1.lock                 # Exclusive OS lock held by Instance 1 (flock -n, fd 7)
├── run.2.lock                 # Exclusive OS lock held by Instance 2 (flock -n, fd 7)
├── run.3.lock                 # Exclusive OS lock held by Instance 3 (flock -n, fd 7)
├── run.1.pid                  # Process PID of Instance 1
├── run.2.pid                  # Process PID of Instance 2
├── run.3.pid                  # Process PID of Instance 3
├── run.1.start.lock           # Start arbitration lock for Instance 1
├── run.2.start.lock           # Start arbitration lock for Instance 2
├── run.3.start.lock           # Start arbitration lock for Instance 3
├── <id>.judge.lock            # Per-agent non-blocking judge lock (one instance evaluates)
├── <id>.judged                # Timestamp of last completed evaluation for agent <id>
├── heartbeat.1.json           # Progress heartbeat file for Instance 1
├── heartbeat.2.json           # Progress heartbeat file for Instance 2
├── heartbeat.3.json           # Progress heartbeat file for Instance 3
├── tick.1/                    # Scratch evaluation workspace for Instance 1
├── tick.2/                    # Scratch evaluation workspace for Instance 2
├── tick.3/                    # Scratch evaluation workspace for Instance 3
├── ctx.1/                     # Snapshot context directory for Instance 1
├── ctx.2/                     # Snapshot context directory for Instance 2
├── ctx.3/                     # Snapshot context directory for Instance 3
├── update.lock                # Coordination lock for rolling code self-update
├── update.next                # Baton file (1 -> 2 -> 3) during rolling update
├── starter.last               # Timestamp written on each crontab starter invocation
├── code/                      # Version-pinned code snapshots
│   ├── <sha-1>/               # git archive snapshot of csi-spl-orc at commit <sha-1>
│   ├── <sha-2>/               # git archive snapshot of csi-spl-orc at commit <sha-2>
│   ├── good                   # Symlink pointing to verified stable snapshot
│   ├── candidate              # Symlink pointing to snapshot being rolled out
│   └── bad                    # Quarantine marker for failed commits
└── inst.<n>.down_since        # Epoch timestamp recording when instance <n> became down
```

### 3.2 Heartbeat Schema (`heartbeat.<inst>.json`)
Each instance updates its heartbeat at tick start and after each evaluated agent:
```json
{
  "instance": 1,
  "pid": 123456,
  "ts": 1728300000,
  "tick_seq": 420,
  "tick_phase": "agents",
  "last_progress_ts": 1728300015,
  "progress_seq": 841,
  "status": "ok",
  "git_sha": "a1b2c3d4e5f6"
}
```
- `ts`: Tick start timestamp.
- `last_progress_ts`: Epoch timestamp updated after evaluating each agent.
- `progress_seq`: Monotonically incremented counter. Peers use `last_progress_ts` to differentiate slow ticks under heavy load from hung processes.

---

## 4. Installation and Verification on a Box

Every watchdog installation step is a named action in source code, fully reproducible and idempotent.

### 4.1 Prerequisites
- Host running Linux with bash 5+.
- Box user account (`<box user>`) with access to `<spool root>` (`/var/spool-hub`) and `<desk cron checkout>` (`/opt/csi/csi-spl-desk-cron`).
- Standard system utilities: `flock`, `crontab`, `setsid`, `pkill`/`kill`.

### 4.2 Installing the Crontab Starter Lines
The crontab starter is managed entirely by `do_spl_wd_ensure_install_cron`
(default `WD_CRON_KIND=start`). It writes TWO tagged lines and takes the
legacy 093 keeper line (`# <app>:wd-ensure`) out. A running watchdog puts
missing starter lines back by itself on its next tick (`peers.log`: `CRON restored`).

1. **Inspect current crontab and preview diff (Dry Run)**:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && ./run -a do_spl_wd_ensure_install_cron
   ```
   *Output shows the proposed before -> after diff and validates spec 068 8.1 compliance.*

2. **Apply the crontab installation (`DRY_RUN=0`)**:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
   ```

3. **Verify the installation**:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && WD_CRON_ACTION=check ./run -a do_spl_wd_ensure_install_cron
   ```
   *Expected output*: `OK wd-start is installed and its script is executable`.

4. **Verify crontab contents**:
   ```bash
   crontab -l | grep -E ':wd-(start|start-boot|ensure)$'
   ```
   *Expected lines* (no `wd-ensure` line):
   ```text
   * * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /opt/csi/csi-spl-desk-cron/csi-spl-orc/run -a do_spl_wd_inst_start >> /var/csi/csi-spl/wd/starter.out 2>&1 # csi-spl:wd-start
   @reboot PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /opt/csi/csi-spl-desk-cron/csi-spl-orc/run -a do_spl_wd_inst_start >> /var/csi/csi-spl/wd/starter.out 2>&1 # csi-spl:wd-start-boot
   ```

### 4.3 Launching the Watchdog Instances
The starter line launches the missing instances within a minute. To start them now
(from `code/good/csi-spl-orc/run` when that snapshot exists, else the checkout's `./run`):
```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && ./run -a do_spl_wd_inst_start
```

One instance only:
```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && WD_INSTANCES=2 ./run -a do_spl_wd_inst_start
```

Each instance's state as its peers judge it (`ok`, `dead`, `dead-held`, `hung`) and the starter's age:
```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && ./run -a do_spl_wd_peers
```

Every peer action (restart, TERM, KILL, crontab restore, alert) is one line in:
```bash
tail -n 20 /var/spool-hub/dispatch/wd/peers.log
```

### 4.4 Peer Rules (T023b)
- `WD_HUNG = max(3 * WD_TICK, 180)` s; the floor is not configurable.
- A judge checks its peers only when it wrote its own heartbeat this tick
  (disk full: an alert, never a kill) and its own previous tick is less than
  `3 * WD_TICK` ago (suspend: no verdict that tick).
- Dead (`run.<n>.lock` free, or its pid gone): started at once under
  `run.<n>.start.lock`. Hung: process group TERM, `ROTATE_TERM_WAIT` (30 s),
  KILL, then started under the same lock.
- Cron dead: `starter.last` older than `WD_STARTER_STALE` (300 s): one blocker
  to the orchestrator per `WD_ALERT_DEBOUNCE` (300 s). The hub admin message
  (11.2) is T026.

---

## 5. "When Something is Wrong" Checklist

When troubleshooting watchdog anomalies, follow this step-by-step diagnostic checklist.

### Checklist Quick Reference

| Issue / Symptom | Primary Diagnostic Command | Resolution Action |
|---|---|---|
| **One watchdog dead** | `ps aux \| grep do_spl_watchdog` | Surviving peers auto-restart within 30 s; manual: `WD_INSTANCES=<n> ./run -a do_spl_wd_inst_start` |
| **Watchdog hung (> 180 s)** | Compare `last_progress_ts` in `heartbeat.<n>.json` with `date +%s` | Surviving peers auto-kill and restart; manual: `kill -TERM <pid>`, then `WD_INSTANCES=<n> ./run -a do_spl_wd_inst_start` |
| **All 3 watchdogs dead** | `ls /var/spool-hub/dispatch/wd/run.*.pid` | Crontab starter restarts all 3 within 60 s; manual: `./run -a do_spl_wd_inst_start` |
| **Crontab line missing** | `WD_CRON_ACTION=check ./run -a do_spl_wd_ensure_install_cron` | Watchdogs self-heal on next tick; manual: `DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron` |
| **Cron daemon dead** | Check age of `/var/spool-hub/dispatch/wd/starter.last` | Watchdogs send Section 11.2 alert; admin restarts cron: `sudo systemctl restart cron` |
| **Hub reports wd_count: 0** | Hub admin alert or `box_beats` query | Check if box is reachable, check local watchdog PIDs and network connectivity |
| **Update failed / halted** | Inspect `/var/spool-hub/dispatch/wd/code/` links | Instance 1 auto-rolls back to `good`; investigate error log in `update.lock` |

---

### Detailed Procedures

#### Scenario 1: One Watchdog Instance is Dead
1. Check running processes:
   ```bash
   ps aux | grep do_spl_watchdog | grep -v grep
   ```
2. Check instance pid files:
   ```bash
   for i in 1 2 3; do
     pid=$(cat "/var/spool-hub/dispatch/wd/run.$i.pid" 2>/dev/null || echo "none")
     if [[ "$pid" != "none" ]] && kill -0 "$pid" 2>/dev/null; then
       echo "Instance $i: healthy (pid $pid)"
     else
       echo "Instance $i: DEAD (pid $pid)"
     fi
   done
   ```
3. *Recovery*: Surviving peers detect the missing process at tick start and restart it automatically under `run.<inst>.start.lock` from `code/good`. To manually trigger restart:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && WD_INSTANCES=<missing_instance_number> ./run -a do_spl_wd_inst_start
   ```

#### Scenario 2: Watchdog Instance is Hung
1. Inspect heartbeat progress timestamps:
   ```bash
   now=$(date +%s)
   for i in 1 2 3; do
     hb="/var/spool-hub/dispatch/wd/heartbeat.$i.json"
     if [[ -f "$hb" ]]; then
       last=$(jq -r '.last_progress_ts' "$hb")
       age=$(( now - last ))
       echo "Instance $i: last progress ${age}s ago"
     fi
   done
   ```
2. If `age >= 180`, the instance is classified as hung.
3. *Recovery*: Surviving peers terminate the hung PID (`SIGTERM`, 30 s grace, then `SIGKILL`) and restart it. To manually terminate and restart:
   ```bash
   pid=$(cat /var/spool-hub/dispatch/wd/run.<inst>.pid)
   kill -TERM "$pid"
   sleep 5
   kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && WD_INSTANCES=<inst> ./run -a do_spl_wd_inst_start
   ```

#### Scenario 3: All Three Watchdogs Are Dead
1. Verify if any instance is holding a lock:
   ```bash
   for i in 1 2 3; do
     flock -n "/var/spool-hub/dispatch/wd/run.$i.lock" true && echo "Instance $i: lock free (unsupervised)" || echo "Instance $i: lock held"
   done
   ```
2. *Recovery*: The crontab starter (`* * * * *`, box user) executes `spl_wd_inst_start` every minute and launches all 3 missing instances within 60 seconds. To restart immediately without waiting for cron:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && ./run -a do_spl_wd_inst_start
   ```

#### Scenario 4: Crontab Starter Line Was Deleted or Corrupted
1. Check crontab line status:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc
   WD_CRON_ACTION=check ./run -a do_spl_wd_ensure_install_cron
   ```
2. *Recovery*: If watchdogs are running, they detect the missing line and re-apply it automatically. To re-apply manually:
   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc
   DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
   ```

#### Scenario 5: System Cron Daemon is Dead
1. Check when the starter last ran:
   ```bash
   now=$(date +%s)
   last=$(cat /var/spool-hub/dispatch/wd/starter.last 2>/dev/null || echo 0)
   echo "Starter last ran $(( now - last ))s ago"
   ```
2. If age $> 300\text{ s}$ while watchdogs are alive, watchdogs raise a Section 11.2 admin alert.
3. *Recovery*: Root access is required to restart system cron:
   ```bash
   sudo systemctl status cron
   sudo systemctl restart cron
   ```

#### Scenario 6: Rolling Self-Update Failure or Stalled Rollout
1. Inspect the code links:
   ```bash
   ls -la /var/spool-hub/dispatch/wd/code/
   ```
2. Check if a candidate commit is quarantined as `bad`:
   ```bash
   cat /var/spool-hub/dispatch/wd/code/bad 2>/dev/null
   ```
3. Check update lock:
   ```bash
   cat /var/spool-hub/dispatch/wd/update.lock 2>/dev/null
   ```
4. *Recovery*: Under the stop rule (10.4.4), Instance 1 automatically rolls back to `code/good` upon failure. If manual intervention is required:
   ```bash
   # Ensure good symlink points to stable commit
   cd /var/spool-hub/dispatch/wd/code
   ln -sfn <stable-sha> good
   # Remove stale update lock if coordinator process died
   rm -f /var/spool-hub/dispatch/wd/update.lock
   ```

---

<!-- version: 1.2.1 · updated: 2026-10-07 (T023b: starter lines, peer rules, do_spl_wd_peers) -->
