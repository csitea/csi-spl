# Spec 102 v1.1 (Watchdogs) Opinion: agy-2

Independent panel review of Spec 102 Section 10.4 (Watchdogs: 3 per box, self-update), WD rows in Sections 0/14, Section 13/17 changes, Open Questions Q12-Q14, and Tasks T023-T027.

---

## 1. Summary & Overall Verdict

The addition of Section 10.4 addresses a critical vulnerability in the fleet architecture: the single point of failure and update lag of the legacy single-instance watchdog loop. The design correctly leverages the T003 per-agent ID lock (`spl_agent_id_lock`) for action arbitration and introduces structured peer liveness tracking.

However, the v1.1 draft cannot be accepted in its current form without fixing **four critical architectural defects**:
1. **Shared Tick Directory Corruption**: Today's `spl_wd_tick` unconditionally wipes `$WD_DIR/tick` (`rm -rf "$tick" && mkdir -p "$tick"`). Running three instances concurrently without isolated per-instance tick workspaces corrupts agent scan outputs (`ps`, `panes`, `agents`) and race-conditions situation hit tracking (`*.hits`).
2. **The 2-Minute Update Mathematical Contradiction**: The rolling update mandates that each instance complete at least one healthy check tick before rolling the next, finishing all three within 2 minutes (`WD_UPDATE_MAX_WAIT = 120 s`). With the draft's 60 s tick interval, sequential execution takes at least $3 \times 60\text{ s} = 180\text{ s}$, which mathematically breaches the 120 s requirement.
3. **Supervisor Conflict & Privilege Inversion (Systemd vs Cron Keeper vs Peer Restart)**: Introducing a root-installed systemd system unit template creates three competing restart authorities with divergent lifecycles and cgroup boundaries, while violating the unprivileged box update model.
4. **Dynamic Script In-Place Execution on Git Pull**: In bash, sourcing and executing external scripts (`situations/s9.sh`, takeover scripts) occurs on demand from the disk tree. An in-place `git checkout` in the shared desk-cron checkout immediately modifies scripts executed by "surviving" instances, invalidating the premise that un-restarted instances remain safely on old code.

With concrete replacements for these items, the architecture is sound and ready for implementation.

---

## 2. Scores (1 weak .. 5 strong)

| Property | Score | Why |
|---|---|---|
| **robust** | **3** | Sound T003 id lock arbitration, but severely compromised by unisolated shared tick directories (`rm -rf $tick`), TOCTOU deduplication checks outside locks, and ENOSPC cascading watchdog mutual kills. |
| **failover-proof** | **4** | Clean cross-box isolation (local watchdogs observe but never act on remote agents) and 3-daemon local quorum, though multi-supervisor fights risk process split-brain. |
| **simple** | **3** | Unnecessary root systemd supervision layered over cron keepers and peer kill-loops, paired with mathematically conflicting update timing constraints. |
| **uninterruptible** | **4** | Staggered rolling updates preserve continuous fleet monitoring, provided script execution isolation and pre-rollout health checks prevent bad commit contamination. |

---

## 3. Findings on Draft Claims vs Real Code

Verification of draft claims against code in `csi-spl-orc/src/bash/run/`, `csi-spl-orc/src/bash/features/`, and `csi-spl-rdb/`:

| Spec Claim / Citation | Real Code Fact | Finding / Discrepancy |
|---|---|---|
| Section 13 row 766: `grep -n 'run\.pid' orc/run/spl-watchdog.func.sh` | Repo path is `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:56` (`echo "$$" > "$WD_DIR/run.pid"`) | **Path error in citation**: Check command omitted `csi-spl-orc/src/bash/` directory prefix. |
| Section 13 row 766: "minute cron keeper restarts dead loop in ~60 s; hung loop not caught" | `spl-wd-ensure.func.sh:125-140` detects `age > WD_ENSURE_HUNG` (300 s), logs warning, and sends blocker alert via `spl_wd_ensure_alert hung` | **Partially inaccurate claim**: The keeper *does* catch and alert on hung loops, but it **never kills or restarts** them. It only alerts. |
| Section 10.4.1 line 559: "60 s tick interval" | `spl-watchdog.func.sh:73` sets `: "${WD_TICK:=30}"` | **Unstated parameter drift**: Today's default tick interval is 30 s, not 60 s. Moving to 60 s doubles detection latency without explicit notation. |
| Section 10.4.1 line 567: "watchdog must acquire T003 per-agent id lock (`spl_agent_id_lock <id>`)" | `spl-watchdog.func.sh` does not call `spl_agent_id_lock` directly anywhere | **Missing integration**: `spl_agent_id_lock` exists only in `spl-rotate-lib.func.sh` and is called by `spl-wd-takeover.func.sh`. The main watchdog tick does not invoke it for snapshots or pokes. |
| Section 10.4.1: Takeover lock concurrency | `spl-wd-takeover.func.sh:112` enforces box-wide `peer/restart.lock` (`WD_BOX_BUSY="a restart holds peer/restart.lock"`) | **Legacy contention blocker**: Even if 3 watchdogs use T003 per-agent ID locks, any takeover still contends on the single box-wide `peer/restart.lock`. |
| Section 13 row 768: `grep -c ASKS_OWNER orc/run/spl-wd-ensure.func.sh -> 4` | Matches exactly 4 occurrences in `csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh` | **Verified** (subject to directory path prefix). |
| Section 13 row 769: `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats -> 0` | Returns `0`. | **Verified**. No `box_beats` table exists yet. |
| Section 13 row 767: `git -C /opt/csi/csi-spl-desk-cron rev-parse HEAD; ps -o pid,lstart,cmd -C bash` | Loop runs detached background process with initial code image | **Verified**. In-memory bash functions remain unchanged while on-disk files drift. |

---

## 4. Deep Failure Mode Analysis

### 4.1 Can 3 active watchdogs act twice on one agent?
- **Concurrent Inspection vs Action**: The T003 per-agent id lock (`spl_agent_id_lock <id>`) serializes write actions (restart, kill, takeover) using non-blocking flock (`flock -n`) on `<spool root>/<id>/lifetime/restart.lock`. If Watchdog 1 holds the lock, Watchdog 2 fails with exit 4 and skips. This effectively blocks simultaneous execution.
- **Sequential Double-Action & TOCTOU Race**:
  - Deduplication checks (`s9.reported`, `input.log`) must be performed **inside** the ID lock critical section. If Watchdogs 1 and 2 observe an anomaly concurrently and check `s9.reported` before acquiring the ID lock, both observe "no report". Watchdog 1 acquires the lock, writes the snapshot, reports, and releases the lock. Watchdog 2 then acquires the ID lock and repeats the snapshot and notification because it evaluated the condition prior to locking.
  - After Watchdog 1 triggers an agent restart and releases the ID lock, the restarted agent is in startup grace. If Watchdog 2 ticks during this window, situation checks (such as S3 bare shell or S5 process gone) will evaluate to positive unless they explicitly check `rotate.log` / `lifetime/phase` under the ID lock.
- **Action on Pokes and Snapshots**: Requiring a full restart ID lock for read-only pane snapshots creates lock contention with normal agent operations. Deduplication of snapshots must rely on atomic file creation (`s9.reported`) rather than heavyweight restart locks.
- **Shared Situation Hit Corruption**: Today's `spl-watchdog.func.sh` writes streak files to `$WD_DIR/<id>.hits`. With 3 instances running uncoordinated ticks, Instance 1 incrementing a streak and Instance 2 resetting it creates oscillation and missed triggers. Streak counters must either be instance-isolated or coordinated under a single state file.

### 4.2 Can all 3 watchdogs stop at once?
- **A Bad Update via In-Place Git Pull**:
  - The spec assumes that because Instances 2 and 3 have not restarted, they "remain fully operational on the previous known-good code."
  - In bash, external situation scripts (`orc/features/watchdog/situations/*.sh`) and functions called in subshells are read directly from disk at execution time.
  - When periodic crons run `git checkout origin/master` in `/opt/csi/csi-spl-desk-cron`, files on disk change immediately.
  - If a new commit introduces a syntax error, broken dependency, or fatal bug in `situations/s9.sh` or `lib.inc.sh`, Instances 2 and 3 execute the broken script on their very next tick, crashing or hanging before their scheduled update!
- **Shared Lock Leakage**:
  - If `dispatch/wd/update.lock` is acquired by Instance 1 and leaked due to child process file descriptor inheritance (a known issue documented in `spl-rotate-lib.func.sh:121`), neither Instance 2 nor Instance 3 can ever acquire the lock, permanently freezing all future code updates.
- **Full Disk (ENOSPC) Cascade**:
  - When the disk fills up, writing `heartbeat.<inst>.json` and updating `last.tick` fails (0 bytes or write error).
  - Peers checking `heartbeat.<peer>.json` read empty or stale timestamps.
  - Instances 1, 2, and 3 simultaneously judge each other "hung" (timestamp not advancing for 180 s).
  - Surviving peers issue `kill -TERM` and `kill -KILL` against each other in a circular mutual-termination cascade, leaving 0 watchdogs alive.
- **Supervisor Clashes (Systemd vs Cron Keeper vs Peer Restarts)**:
  - If systemd runs with `Restart=always` and `RestartSec=5s`, killing a hung instance causes systemd to restart it immediately.
  - Simultaneously, the peer watchdog that detected the hang attempts to spawn the instance under `run.<inst>.start.lock` via `./run -a do_spl_watchdog`.
  - The cron keeper `do_spl_wd_ensure` runs at `:00` and attempts its own recovery.
  - Three independent actors fight to start the daemon, causing PID file thrashing, lock contention on `run.<inst>.lock`, and orphaned background processes outside systemd cgroups.

### 4.3 Is rolling self-update really never below 1 live watchdog?
- **The Timing Contradiction**:
  - The spec requires sequential verification: Instance 1 restarts and executes 1 full healthy check tick; then Instance 2; then Instance 3.
  - If `WD_TICK_INTERVAL` is 60 s, 1 tick takes 60 s plus execution duration ($\approx 10\text{--}20\text{ s}$).
  - Instance 1 verify: $\approx 75\text{ s}$.
  - Instance 2 verify: $\approx 75\text{ s}$.
  - Instance 3 restart: $\approx 10\text{ s}$.
  - Total elapsed time: $\ge 160\text{ s}$.
  - This directly violates the WD3 mandate: "within 2 min of code arriving (`WD_UPDATE_MAX_WAIT = 120 s`)".
  - To achieve $< 120\text{ s}$, either the verification tick interval must be shortened during rollout (e.g. 15-20 s self-check tick), or `WD_TICK` must remain at 30 s ($3 \times 30\text{ s} = 90\text{ s} < 120\text{ s}$), or Instances 2 and 3 must roll in parallel once Instance 1 validates the build.
- **Pre-Existing Degraded State**:
  - If Instance 2 is already dead or hung when an update arrives, restarting Instance 1 reduces active watchdogs to 1 (Instance 3). If Instance 3 experiences an intermittent fault, active coverage drops to 0.
  - Rolling updates must enforce a strict **pre-flight health check**: abort the update if fewer than 3 instances are fully healthy.

### 4.4 Does "hung = 3 missed checks" race with a slow but healthy tick?
- **Tick Latency Under Heavy Host Load**:
  - A tick scans all processes, queries tmux sessions, and iterates over 30+ agents, spawning up to `WD_JOBS` background inspection tasks.
  - Under heavy compilation or CI test runs, I/O latency spikes and CPU throttling can cause an agent scan loop to take 90-120 s.
  - If the heartbeat timestamp is only updated at tick boundaries, a tick taking 185 s appears hung to peers whose ticks run on slightly staggered clocks.
  - Killing a healthy, working watchdog with `SIGTERM` / `SIGKILL` while it is writing logs or inspecting agents causes corrupted state and false admin alerts.
- **Remedy**:
  - Heartbeat files must include `tick_phase` and in-progress progress timestamps (`tick_start_ts`, `tick_agent_count`, `last_progress_ts`).
  - A peer is only hung if `now - last_progress_ts > 300 s` (5 minutes), aligning with `WD_ALERT_DOWN_WAIT`.

### 4.5 Supervisor architecture: Is systemd as root right for this box model?
- **Privilege Separation**: Fleet agents and crons execute as the unprivileged box user (`<box user>`). Automated code pulls do not and should not have passwordless root privileges to reload systemd daemons (`sudo systemctl daemon-reload`).
- **Autonomous Recovery**: If systemd template units require root installation (`do_spl_wd_install_service`), initial box provisioning or unit modifications cannot be handled by standard agent workflows.
- **Process Supervision Reality**: Peer monitoring already implements process-level supervision (detecting dead/hung processes, sending signals, and spawning replacements). Layering systemd underneath creates two supervisory control loops operating on conflicting signals.
- **Conclusion**: The user-space cron keeper (`do_spl_wd_ensure`) plus peer monitoring is completely sufficient, requires zero root privileges, avoids cgroup mismatches, and operates identically across dev, prd, and container environments.

---

## 5. Subsection Review (10.4.1 .. 10.4.6)

### 10.4.1 Three active daemons, supervision, and lock arbitration (WD1, WD2)
- **Verdict**: **Disagree with text as written; Concrete Replacement required**.
- **Key Issues**: Lacks per-instance tick directory isolation; introduces unnecessary root systemd supervision that conflicts with peer restarts; places deduplication checks outside lock scope.
- **Concrete Replacement Text**:
> - **Three daemons**: Every box runs 3 watchdog daemon processes simultaneously (`INSTANCE=1, 2, 3`), executing as `<box user>`.
> - **User-Space Supervision Model**:
>   - Primary supervision is handled by mutual peer monitoring (Section 10.4.2) in user space.
>   - Fallback cold-start supervision is provided by the cron keeper `do_spl_wd_ensure` running in `<box user>` crontab (`* * * * *`). The keeper checks the status of all 3 instances (`run.1.lock`, `run.2.lock`, `run.3.lock`) and starts any missing instance under `run.<inst>.start.lock`.
>   - Zero root privileges or systemd unit modifications are required. Optional systemd service units may be used for OS boot autostart only where pre-installed by the host administrator, but systemd restart policies must be `Restart=no` to prevent fighting with peer supervisors.
> - **Isolated Instance Workspaces**:
>   - Each instance maintains its own dedicated tick scratch directory: `<spool root>/dispatch/wd/tick.<inst>/`. Under no circumstances may an instance delete or touch another instance's tick directory.
>   - Instance lock: `<spool root>/dispatch/wd/run.<inst>.lock` (`flock -n`).
>   - Instance PID: `<spool root>/dispatch/wd/run.<inst>.pid`.
>   - Situation streak tracking (`*.hits`) is partitioned per instance (`<id>.<inst>.hits`) or unified via atomic state files.
> - **Arbitration via T003 Per-Agent ID Lock**:
>   - All 3 instances inspect agents concurrently.
>   - Before initiating any mutating action on an agent (restart, poke, kill, or takeover), the watchdog **must** acquire the T003 per-agent ID lock (`spl_agent_id_lock <id>`, `<spool root>/<id>/lifetime/restart.lock`, `flock -n`).
>   - If another watchdog holds the lock, `flock -n` fails (exit 4), and the watchdog immediately skips acting on that agent for that tick.
>   - The legacy box-wide `peer/restart.lock` is retired in favor of Section 4.2 concurrency slots (`RESTART_SLOTS`).
> - **Inside-Lock Deduplication**:
>   - All deduplication evaluations (`s9.reported`, `input.log`, `rotate.log`) MUST be checked **after** acquiring the agent ID lock.
>   - For S9 stuck panes: after acquiring the ID lock, the instance checks `<spool root>/<id>/lifetime/s9.reported`. If the current pane hash matches and the reported timestamp is within `WD_NOTE_DEBOUNCE` (300 s), the action is suppressed and the ID lock released.

### 10.4.2 Heartbeat and peer monitoring (WD4)
- **Verdict**: **Disagree with text as written; Concrete Replacement required**.
- **Key Issues**: False-positive hung kills on slow ticks; unlinking active flock files; races between two surviving peers killing the same hung instance.
- **Concrete Replacement Text**:
> - **Watchdog Heartbeats**: On every tick, each watchdog instance writes `<spool root>/dispatch/wd/heartbeat.<inst>.json` containing `{"instance": <inst>, "pid": <pid>, "ts": <epoch>, "tick_seq": <seq>, "tick_phase": "<start|agents|done>", "last_progress_ts": <epoch>, "status": "ok", "git_sha": "<sha>"}`. Heartbeats update `last_progress_ts` during agent iteration to prevent slow ticks from appearing hung.
> - **Peer Dead Check**: At the start of its tick, each watchdog checks process liveness (`kill -0 <peer_pid>`). If a peer process is dead or its PID file is missing, the surviving peer restarts the dead watchdog under `run.<peer_inst>.start.lock` (`flock -n`).
> - **Peer Hung Check**: A peer is judged hung only if `kill -0 <peer_pid>` succeeds, but `last_progress_ts` has not advanced for $\ge 300\text{ s}$ (5 minutes, matching `WD_ALERT_DOWN_WAIT`).
> - **Single-Actor Recovery Guard**: The entire termination and recovery sequence (SIGTERM, 30 s wait, SIGKILL, and restart) must be executed while holding `run.<peer_inst>.start.lock`. The surviving peer that acquires the start lock executes the kill and restart; other surviving peers fail to acquire the start lock and skip recovery.
> - **Lock Hygiene**: Instance lock files (`run.<inst>.lock`) must **never be deleted or unlinked** from disk (`rm -f`). Stale locks are cleared purely by process exit releasing the OS `flock` descriptor.

### 10.4.3 Cross-box watchdog liveness and relation to box_beats (WD1, 10.2)
- **Verdict**: **Agree, with one debounce requirement**.
- **Notes**:
  - The separation between observation and action is completely correct. Remote watchdog outages must never trigger local takeovers of remote agents.
  - Clarification: Orchestrator warning notes emitted when a remote box reports `wd_count: 0` must be debounced with `WD_NOTE_DEBOUNCE` (300 s) to prevent beat frame flooding.

### 10.4.4 Watchdog self-update on desk-cron changes (WD3)
- **Verdict**: **Disagree with text as written; Concrete Replacement required**.
- **Key Issues**: The 2-minute deadline is mathematically incompatible with three 60 s sequential ticks; in-place `git checkout` breaks code isolation for running instances.
- **Concrete Replacement Text**:
> - **Update Trigger**: Periodic crons fetch master into `/opt/csi/csi-spl-desk-cron`.
> - **Pre-Flight Health Quorum**: Before initiating a rolling update, the coordinator instance verifies that **all 3 watchdog instances are currently alive and reporting `status: ok`**. If any instance is dead or hung, the update is deferred and an alert raised.
> - **Script Execution Isolation**: To ensure instances running old code do not execute modified scripts from disk, watchdogs must either load library functions into memory at launch or execute from version-pinned directory snapshots (`releases/<sha>`).
> - **Rolling Restart Sequence (< 120 s)**:
>   - Managed under `dispatch/wd/update.lock`.
>   - Instance 1 restarts with new code. It executes an accelerated **self-check tick** (verifying syntax, environment, and 1 probe scan, $\le 20\text{ s}$).
>   - Once Instance 1 writes `status: ok` on the new commit, Instance 2 restarts and executes its self-check tick ($\le 20\text{ s}$).
>   - Once Instance 2 is healthy, Instance 3 restarts ($\le 20\text{ s}$).
>   - Total rollout duration is bounded to $< 70\text{ s}$, safely within the 120 s requirement.
> - **Rollback & Quarantine**: If Instance 1 crashes or fails its initial self-check tick, the rollout is immediately halted. Instance 1 is held in quarantine (stopped), Instances 2 and 3 continue operating uninterrupted on old code, and an immediate admin alert is dispatched.

### 10.4.5 Admin alerts (WD5)
- **Verdict**: **Agree, with alert debounce specification**.
- **Notes**:
  - Alerting when 2 of 3 watchdogs are down on a box is the correct proactive threshold (Q12 safe default).
  - Add explicit debounce: alerts for simultaneous down conditions must be debounced by 300 s (`WD_ENSURE_DEBOUNCE`).
  - Add fallback: if the Section 11.2 hub message fails, fallback to a local spool blocker (`spool-send.sh --to orchestrator --kind blocker`).

### 10.4.6 Tests and controls
- **Verdict**: **Disagree with table as written; Concrete Replacement required**.
- **Key Issues**: Missing controls for tick directory collision, rolling update time limits, and disk-full scenarios.
- **Concrete Replacement Table**:

| Case | Fixture / Condition | Expected | Control |
|---|---|---|---|
| **multi-daemon arbitration** | 2 watchdogs detect same stuck agent simultaneously | Exactly one acquires T003 ID lock; exactly one snapshot/restart executed | ID lock held -> second instance skips cleanly without error |
| **scratch directory isolation** | Instances 1 and 2 tick simultaneously | Instance 1 and 2 operate in separate `tick.1/` and `tick.2/` dirs; zero file clobbering | Shared tick directory -> race condition caught |
| **snapshot deduplication** | Watchdog 1 records hash in `s9.reported`; Watchdog 2 ticks on same pane | Watchdog 2 inspects `s9.reported` inside lock and suppresses duplicate note | New pane hash -> snapshot taken and reported |
| **dead peer restart** | Kill instance 2 (`kill -9`) | Peer 1 or 3 acquires `run.2.start.lock` and restarts instance 2 within 1 tick | Instance 2 alive -> zero restart action taken |
| **hung peer restart** | Freeze instance 2 heartbeat for $> 300\text{ s}$ | Exactly one peer acquires start lock, terminates instance 2 (`TERM`/`KILL`), and restarts it | Heartbeat advancing normally -> zero action taken |
| **rolling update timing** | desk-cron HEAD advances to new SHA | Rolling restart of Instances 1, 2, 3 completes in $< 120\text{ s}$; active monitoring never drops below 2 live instances | HEAD unchanged -> zero restarts |
| **self-update stop rule** | New commit has syntax error / fails check 1 | Instance 1 fails; rollout halts immediately; Instances 2 and 3 remain alive on old code; admin alerted | Clean commit -> rollout succeeds across all 3 |
| **cross-box observation** | Remote box reports `wd_count: 0` in hub beat ack | Observing box emits debounced warning note to orchestrator; takes NO action on remote agents | Remote box healthy -> zero warning; remote box partitioned -> Section 10.2 fence activates |
| **admin alert threshold** | 2 watchdogs killed simultaneously | Admin alert triggered immediately (2 of 3 down) | 1 watchdog killed and restored in $< 5\text{ min}$ -> logged only, no admin alert |
| **disk full guard** | Filesystem full (ENOSPC on heartbeat write) | Heartbeat write failure logged to stderr; instances do NOT mutually terminate peers | Normal disk capacity -> heartbeats advance cleanly |

---

## 6. Holes: What WD1..WD5 Require that the Draft Misses or Contradicts

1. **WD3 Timing Violation**: Owner explicitly confirmed WD3 ("within 2 min of code arriving"). The draft's sequential rolling sequence requiring full 60 s checks breaches this threshold. Accelerated verification ticks are mandatory.
2. **WD1 Daemon Definition vs Execution Model**: Owner asked for "running as daemon". The draft equated "daemon" with systemd system units requiring root installation. In the fleet's execution model, user-space background daemons monitored by crontab and peers satisfy the requirement without root privilege barriers.
3. **WD2 Action Redundancy Suppression**: Owner asked for "All 3 active" with arbitration via the ID lock. The draft failed to isolate the internal tick working directories (`tick/`), meaning concurrent active monitoring corrupted the scanning state.
4. **WD4 Hung Remediation Safety**: Owner confirmed "hung watchdog ... another restarts it after 3 missed checks". The draft implemented a 180 s kill timer based on tick end timestamps, causing false-positive kills of healthy watchdogs during heavy machine load.
5. **WD5 Debouncing & Delivery Resilience**: Owner confirmed admin alert on 5 min downtime or multiple down. The draft omitted alert storm suppression and channel fallbacks if the hub API is unreachable.

---

## 7. Verdicts on Open Questions Q12, Q13, Q14

### Q12: Admin alert threshold for simultaneous watchdog failures on a box
- **Verdict**: **Keep Default (a) (2 of 3 down)**.
- **Rationale**: When 2 of 3 watchdogs fail, redundancy is broken and the box operates with a single point of failure. Because the rolling self-update never takes down more than 1 watchdog at a time, and peer restarts recover single failures in $< 60\text{ s}$, 2 instances down at once indicates an active crisis (OOM, disk exhaustion, or crashing code). Alerting early gives operators time to intervene before total fleet blindness occurs.

### Q13: Watchdog daemon supervisor mechanism
- **Verdict**: **Pick Option (b) (Cron keeper `do_spl_wd_ensure` alone supervises all 3 detached loops directly in user space)**.
- **Rationale**:
  1. Option (a) introduces root privilege escalation (`/etc/systemd/system/`) into a codebase that deploys and updates completely unprivileged as `<box user>`.
  2. Running systemd with `Restart=always` alongside peer-based hung process termination (`kill -TERM` / `kill -KILL`) causes active supervisor warfare.
  3. Option (b) matches the existing fleet infrastructure: `do_spl_wd_ensure` already runs every minute in crontab. Extending it to check and ensure three instances (`run.1.lock`, `run.2.lock`, `run.3.lock`) under user-space `flock` locks is simple, proven, root-free, and container-compatible.

### Q14: Cross-box watchdog liveness alert threshold
- **Verdict**: **Keep Default (a) (Alert when remote box has 0 active watchdogs)**.
- **Rationale**: Each box is responsible for healing its own local watchdog failures via peer monitoring and cron keepers. A remote box temporarily having 1 or 2 watchdogs active is a normal state during rolling code updates. Alerting on single remote drops would generate cross-box alert noise during every routine deployment. Alerting only on 0 active watchdogs ensures notifications reflect genuine, complete monitoring outages.

---

## 8. Review of Tasks T023..T027

| Task | Priority / Dependencies | Scope & Path Hygiene | Test & Control Quality | Verdict |
|---|---|---|---|---|
| **T023** | P2 (after T003) | Multi-daemon watchdog core. Paths must use `csi-spl-orc/src/bash/run/` prefix. Delete `spl-wd-install-service` if Q13(b) adopted. | Good test/control: verifies 3 instances running, kill/restart, and lock arbitration. Add tick directory isolation test. | **Approve with path fix** |
| **T024** | P3 (after T017, T023) | Cross-box watchdog liveness in `box_beats`. Must include migration in `csi-spl-rdb/src/sql/postgres/spool-hub/` for `box_beats` table/column. | Good test/control: validates warning emitted on 0 remote watchdogs, no action on remote agents. | **Approve with DB migration addition** |
| **T025** | P3 (after T023) | Watchdog rolling self-update. Must implement accelerated verification ticks to satisfy $< 120\text{ s}$ limit. | Good test/control: tests commit advance, sequential restart, and bad-commit halt. | **Approve with timing fix** |
| **T026** | P2 (after T012, T023) | Admin alert for watchdog failures. Must add debounce flag and hub API fallback. | Good test/control: validates 2-of-3 kill immediate alert and 301 s timeout alert. | **Approve with debounce requirement** |
| **T027** | drill (after T023..T026) | Redundancy & self-update drill covering all failure modes. | Good test/control: proves zero interruption to running agents during all watchdog restarts and updates. | **Approve as written** |

- **Dependency Order**: Correct. T023 starts in P2 immediately after T003. T026 follows T023 in P2. T024 and T025 land in P3. T027 closes out the implementation with a live drill.
