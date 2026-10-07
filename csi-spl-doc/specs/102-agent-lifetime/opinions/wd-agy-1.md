# Opinion: Spec 102 v1.1 (Watchdogs) — Panelist agy-1

Independent panel review of Spec 102 v1.1 draft (commit `8ee516f2`) section 10.4,
related sections (0, 4.2, 8, 10.2, 11, 13, 14, 16, 17), and tasks T023..T027
against owner decisions WD1..WD5, measured operational facts, and the live codebase.

---

## 1. Executive Summary & Scores

| Property | Score | Why |
|---|:---:|---|
| **robust** | **3** | Arbitration via T003 agent id lock is sound, but the draft misses per-instance state directory isolation (`$WD_DIR/tick`, `$WD_DIR/ctx/$id`) and shared debounce isolation (`$id.hits`), risking tick race conditions and accelerated debounces between concurrent active daemons. |
| **failover-proof** | **4** | Three active daemons per host with peer liveness monitoring (WD4) and fallback keeper cron guarantee local daemon survivability; cross-host observation via `box_beats` strictly decouples watchdog health reporting from remote agent failover (10.2). |
| **simple** | **3** | Introducing systemd system units alongside cron supervision and peer-level process killers creates unnecessary supervisor tri-homing and requires privileged root unit installation; peer monitoring plus unprivileged cron keeper is simpler, fully unprivileged, and self-contained. |
| **uninterruptible** | **3** | Rolling self-update claims continuous coverage, but executing interpreted shell scripts from a single shared worktree means a bad commit checked out on disk can break running peer daemons during subshell/source execution before rollback or isolation can occur. |

---

## 2. Verification of Draft Claims Against Today's Code

Claims in Section 13 and Section 10.4 were verified against the repository and runtime environment:

| Section / Row | Draft Claim | Verification Result | Finding |
|---|---|---|---|
| Section 13, Row 766 (`093 6.4 watchdog loops per box`) | `ONE loop per box, pid in dispatch/wd/run.pid; minute cron keeper restarts dead loop in ~60 s; hung loop not caught` | Partially holds. Code inspection of `csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh:125-140` (`spl_wd_ensure_hung`) shows a hung loop *is* detected when `age > WD_ENSURE_HUNG` (180 s) and emits an alert / owner DM (live flag `ensure.alert.hung` observed with timestamp `1791323822`). However, the keeper does *not* kill or restart the hung process. | **Finding 1 (Claim Accuracy):** The draft states "hung loop not caught". More precisely, the hung loop is *detected and alerted*, but *unrecovered* (never terminated or restarted). |
| Section 13, Check commands (Rows 766, 768) | Pathspecs written as `orc/run/spl-watchdog.func.sh`, `orc/run/spl-wd-ensure.func.sh` | Fails from repository root. The real path is `csi-spl-orc/src/bash/run/spl-watchdog.func.sh`. | **Finding 2 (Pathspec):** Section 13 check commands omit the `csi-spl-orc/src/bash/` prefix (similarly in `tasks.md` T023..T026). |
| Section 13, Row 767 (`watchdog code update on git move`) | `none: desk-cron checkout moves on master, but loop runs old code until killed by hand` | Holds. A running loop `while :; do spl_wd_tick; sleep ...; done` retains its in-memory process loop; no reload trigger exists on checkout HEAD advance. | Verified. |
| Section 13, Row 768 (`keeper alert`) | `keeper sends owner DM on crashloop / hung; no admin message` | Holds. `grep -c ASKS_OWNER csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh` returns 4. | Verified. |
| Section 13, Row 769 (`cross-box monitoring`) | `none: no box checks another box's watchdog or agents` | Holds. `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats` returns 0. | Verified. |
| Section 10.4.1 (`Arbitration via T003 id lock`) | Watchdog must acquire `spl_agent_id_lock` before acting on an agent | Today's code only acquires `spl_agent_id_lock` inside `spl-wd-takeover.func.sh:86`, `spl-peer-restart.func.sh:169`, `spl-lane-restart.func.sh:308`, and `agent-id-reap.sh:146`. Non-takeover actions (`spl_wd_ring`, `spl_wd_send`, `spl_wd_s9_pokes`) do not take the lock today. | Verified: Expanding `spl_agent_id_lock` to cover all watchdog actions (pokes, snapshots, DM notes) is required for multi-daemon safety. |

---

## 3. Deep Technical Analysis

### 3.1 Can 3 Active Watchdogs Act Twice on One Agent, or All Stop at Once?

#### A. Acting Twice on One Agent
- **Lock Coverage vs Lock Lifespan**: `spl_agent_id_lock` successfully prevents simultaneous actions while held. However, if Watchdog 1 detects an issue (e.g. S9 stuck pane), takes the id lock, takes a snapshot, sends a notification, and releases the lock, Watchdog 2 ticking 2 seconds later might inspect the same agent before the agent or model has reacted.
- **Shared Debounce Speedup**: In `spl-watchdog.func.sh:471-480`, hits are counted in `$WD_DIR/$id.hits`. If 3 daemons tick independently, an agent hitting code S3 will have its hit count incremented by each daemon. A 2-tick debounce intended to span 120 seconds will be satisfied in under 20 seconds if 3 daemons inspect it in rapid succession.
- **Shared Working Directory Corruption**: In today's `spl_wd_one`, `ctx="$WD_DIR/ctx/$id"` is wiped with `rm -rf "$ctx" && mkdir -p "$ctx"`. If Watchdog 1 and Watchdog 2 inspect the same agent concurrently, Watchdog 2 will wipe out the context directory while Watchdog 1's situation scripts are actively writing or reading from it. Likewise, `tick="$WD_DIR/tick"` is wiped with `rm -rf "$tick"` at the start of each tick.
- **Verdict**: Without per-instance working directories and debouncing isolation, 3 active daemons will corrupt each other's state and accelerate debounces, leading to duplicate actions.

#### B. All Three Stopping at Once
- **Bad Update / Shared Checkout**: Running 3 daemons out of a single shared worktree (`/opt/csi/csi-spl-desk-cron`) does *not* protect surviving daemons if a bad commit lands. Interpreted shell scripts load subshells (`bash "$s"` for situation scripts) and sourced files (`source spl-rotate-lib.func.sh`) directly from disk. A broken script or syntax error in a shared function on disk immediately breaks running daemons on their next subshell invocation, crashing all 3 daemons regardless of whether their main loop process was restarted.
- **Disk Full (ENOSPC)**: All 3 daemons write heartbeats, logs, context files, and pids to `<spool root>/dispatch/wd/`. If the filesystem fills up, `mkdir`, `echo "$now" > ...`, and lock file operations fail with fatal errors, causing all 3 daemons to exit simultaneously.
- **Supervisor Split-Brain**: If systemd and the cron keeper both attempt to manage daemon lifecycles without a strict hierarchy, systemd restart backoffs fight with detached processes spawned by `do_spl_wd_ensure`. Systemd rate limits (`StartLimitBurst`) can permanently disable units while detached processes hold instance locks.

---

### 3.2 Is the Rolling Self-Update Really Never Below 1 Live Watchdog?

The draft proposes:
1. Instance 1 restarts with new code.
2. Instance 1 must complete one full healthy check tick.
3. Instance 2 restarts, then Instance 3.

**Vulnerabilities**:
1. **Shared Code on Disk**: As noted in 3.1B, `git checkout` moves the entire worktree at once. Instances 2 and 3 do *not* run a hermetic snapshot of the old code; they execute helper scripts directly from disk. True canary isolation requires versioned staging or an atomic staging directory.
2. **Failure at Step 2 or 3**: The draft's stop/rollback rule (10.4.4) explicitly specifies what happens if *Instance 1* fails. It fails to define behavior if Instance 1 succeeds but Instance 2 or 3 crashes. The stop/rollback rule must apply to failures at *any* stage of the rollout.
3. **Coordination Actor**: The draft mentions `dispatch/wd/update.lock` but does not specify which actor initiates the update. If each instance polls git HEAD, all 3 might detect the commit simultaneously and compete. A designated rolling coordinator or instance ordering (Instance 1 always leads updates under lock) is necessary.

---

### 3.3 Does "Hung = 3 Missed Checks" Race with a Slow but Healthy Tick?

- `WD_TICK_INTERVAL` is 60 s. "3 missed checks" equals 180 s.
- In `spl-watchdog.func.sh`, a single tick walks every local agent (`WD_JOBS` = 8 parallel jobs). For each agent, situation scripts run under `timeout 5s`, tmux capture-pane is invoked, and inbox files are parsed.
- Under heavy load (e.g., 25+ active agents during an incident, slow disk I/O, or unresponsive tmux server), a single tick can exceed 60–90 seconds. If a transient delay pushes tick execution to 181 seconds, peer daemons will judge a completely healthy, working watchdog "hung" and terminate it with `SIGKILL`.
- **Verdict**: 180 s is too aggressive without progressive heartbeat telemetry. A daemon must update a heartbeat phase (`tick_start`, `agents_in_progress`, `tick_done`) or peers must verify that process CPU time (`/proc/<pid>/stat`) has ceased advancing before sending `SIGKILL`.

---

### 3.4 Is Systemd as Box User / Root Right for This Box Model?

- **Box Privilege Model**: Fleet agents operate under unprivileged accounts (`<box user>` / `<agent user>`). The fleet avoids requiring root access for routine operational components.
- **Who Installs the Unit?**: Installing `/etc/systemd/system/spl-watchdog@.service` and executing `systemctl daemon-reload` requires root privileges. This cannot be performed by unprivileged agents and becomes an owner-only, host-provisioning prerequisite.
- **Supervision Redundancy**: If 3 active daemons already monitor each other and immediately restart dead peers (WD4), process crashes are recovered within seconds. The minute cron keeper `do_spl_wd_ensure` already acts as an outer recovery net for host reboots or total failure.
- **Verdict**: Systemd introduces root privilege dependencies, installation friction across heterogeneous environments, and supervisor conflicts. Supervision should rely on WD4 peer recovery and the unprivileged cron keeper (Option b of Q13).

---

## 4. Section-by-Section Review (Subsections 10.4.1 .. 10.4.6)

### 10.4.1 Three Active Daemons, Supervision, and Lock Arbitration (WD1, WD2)
- **Status**: Agree in principle, with **Concrete Replacement** for directory isolation and tick staggering.
- **Replacement Text**:
  > Every host runs 3 watchdog daemon processes simultaneously (`INSTANCE` 1, 2, 3) as the unprivileged box user (`<box user>`). Each instance operates within an isolated state directory `<spool root>/dispatch/wd/inst.<inst>/` containing its private `tick/`, `ctx/`, and `run.<inst>.pid` to eliminate state collisions. Each instance holds an exclusive flock on `<spool root>/dispatch/wd/run.<inst>.lock`.
  >
  > To prevent simultaneous lock contention, the 3 instances operate with a staggered 60 s tick interval: Instance 1 ticks at offset 0 s, Instance 2 at offset 20 s, and Instance 3 at offset 40 s. This provides continuous host coverage every 20 s.
  >
  > Before taking any action on an agent (restart, takeover, poke, pane snapshot, or DM note), the watchdog must acquire the T003 per-agent id lock (`spl_agent_id_lock <id>`). If held, the watchdog skips action on that agent for that tick. Hits are tracked per-agent in `<spool root>/dispatch/wd/debounces/<id>.hits` under a lightweight debounce flock to ensure consistent hit counting across staggered instances.

---

### 10.4.2 Heartbeat and Peer Monitoring (WD4)
- **Status**: Agree in principle, with **Concrete Replacement** for progressive heartbeats and safe lock handling.
- **Replacement Text**:
  > On every tick, each watchdog instance writes `<spool root>/dispatch/wd/heartbeat.<inst>.json` containing `{"instance": <inst>, "pid": <pid>, "ts": <epoch>, "tick_seq": <seq>, "phase": "idle|gathering|judging", "status": "ok", "git_sha": "<sha>"}`. The timestamp is updated at tick start and at tick completion.
  >
  > At the start of its tick, each watchdog checks peer status:
  > 1. **Dead Peer**: If `kill -0 <peer_pid>` fails or the pid file is missing, the surviving peer acquires `<spool root>/dispatch/wd/run.<inst>.start.lock` (`flock -n`) and spawns the missing instance immediately.
  > 2. **Hung Peer**: If `kill -0 <peer_pid>` succeeds but the peer's heartbeat timestamp has not advanced for 180 s (`3 * WD_TICK_INTERVAL`), the inspecting peer checks `/proc/<peer_pid>/stat` to verify CPU time is not advancing. If confirmed hung, the peer terminates the process (`SIGTERM`, wait 30 s `ROTATE_TERM_WAIT`, then `SIGKILL`) and restarts the instance under `run.<inst>.start.lock`.
  > 3. **Lock Cleanup**: Stale instance locks are released automatically by the kernel when the process terminates; peers must never execute `rm -f` on active lock files.

---

### 10.4.3 Cross-Box Watchdog Liveness and Relation to `box_beats` (WD1, 10.2)
- **Status**: **Agree**.
- **Assessment**: The separation between observation and action is clean. Local watchdogs take zero action on remote agents. Reporting `wd_count` in `box_beats` allows the hub and peer hosts to observe remote redundancy loss. Emitting an orchestrator warning note when a remote host has 0 active watchdogs is correct and should be debounced to once per 15 minutes.

---

### 10.4.4 Watchdog Self-Update on Desk-Cron Changes (WD3)
- **Status**: Agree in principle, with **Concrete Replacement** for code staging and multi-stage rollback.
- **Replacement Text**:
  > When the periodic cron updates `/opt/csi/csi-spl-desk-cron` to a new commit, a coordinated rolling update begins under `<spool root>/dispatch/wd/update.lock`:
  > 1. **Pre-flight Syntax Validation**: Before restarting any instance, a syntax and sanity check is executed against the updated codebase (`bash -n` on all scripts and libraries). If validation fails, the update is rejected, master is not adopted, and an admin alert is dispatched.
  > 2. **Staged Execution**: Code is executed from a versioned directory `<spool root>/dispatch/wd/code/<sha>/` symlinked to runtime paths, ensuring running instances do not load partially checked-out or broken files from disk.
  > 3. **Rolling Sequence**: Instance 1 restarts on the new code first. Instances 2 and 3 continue running on the previous code.
  > 4. **Verification Tick**: Instance 1 must successfully complete one full check tick (`tick_seq` incremented, `status: ok`).
  > 5. **Sequential Rollout**: Upon Instance 1 verification, Instance 2 is updated, followed by Instance 3 upon Instance 2 verification. The entire sequence completes within 120 s (`WD_UPDATE_MAX_WAIT`).
  > 6. **Universal Stop Rule**: If *any* instance fails during its startup or initial verification tick, the rollout halts immediately. Upgraded instances are rolled back to the prior known-good SHA, remaining instances stay on the prior SHA, and an admin alert is triggered naming the faulty commit.

---

### 10.4.5 Admin Alerts (WD5)
- **Status**: Agree in principle, with **Concrete Replacement** for episode debouncing.
- **Replacement Text**:
  > Admin alerts (web app message in the operator workspace + email via `internal/mail`, per Section 11.2) are triggered under two conditions:
  > 1. Any watchdog instance remains down (dead or hung) and cannot be recovered within 5 minutes (`WD_ALERT_DOWN_WAIT` = 300 s).
  > 2. Simultaneous failures: 2 of 3 watchdogs on a host are down simultaneously (Q12 safe default).
  >
  > Alerts are debounced per failure episode: once an alert is dispatched for a host, duplicate alerts are suppressed for 30 minutes (`WD_ALERT_DEBOUNCE` = 1800 s) unless the down count increases.

---

### 10.4.6 Tests and Controls
- **Status**: **Agree**.
- The test table in 10.4.6 is comprehensive. To ensure coverage of the findings identified in this review, the following test controls must be explicitly included in T023:
  1. *Per-instance directory isolation*: Verify two instances running ticks simultaneously write to separate `tick/` directories and produce 0 directory collision errors.
  2. *Staggered tick arbitration*: Verify staggered execution offsets (0s, 20s, 40s) maintain continuous 20 s host coverage.
  3. *Debounce consistency*: Verify hit debounces require distinct time windows rather than being satisfied instantaneously by multiple concurrent daemons.

---

## 5. Holes Analysis (WD1..WD5 Compliance)

| Requirement | Owner Text | Draft Status | Hole / Defect in Draft |
|---|---|---|---|
| **WD1** | "Actually let's make them 3 per box - so 3 on [box-1] and 3 on [box-2] - running as daemon" | Adopted in 10.4.1 | Draft equates "running as daemon" with systemd system units requiring root privileges. Fails to account for an unprivileged box user daemon supervised by peers + cron. |
| **WD2** | "All 3 active" | Adopted in 10.4.1 | Draft makes all 3 active but does not isolate state directories (`$WD_DIR/tick`, `$WD_DIR/ctx`), causing concurrent instances to corrupt each other's temporary files. |
| **WD3** | "Yes restart them" (rolling within 2 min) | Adopted in 10.4.4 | Draft assumes running shell processes are immune to on-disk git checkout changes. Does not stage code or run syntax pre-flight checks, risking multi-instance failure on bad commits. Rollback rule only covers Instance 1. |
| **WD4** | "hung watchdog: another restarts it after 3 missed checks" | Adopted in 10.4.2 | 180 s timeout risks killing healthy daemons during slow ticks under heavy load. Needs progressive heartbeat phases and CPU activity checks. |
| **WD5** | "admin alert: only when a watchdog cannot be brought back within 5 min, or both on one box are down at once" | Adopted in 10.4.5 | Alert debounce mechanism is missing from the spec text of 10.4.5, risking alert storms during flapping failures. |

---

## 6. Verdicts on Open Questions Q12, Q13, Q14

### Q12: Admin Alert Threshold for Simultaneous Watchdog Failures
- **Options**: (a) 2 of 3 down; (b) all 3 down.
- **Draft Default**: (a) 2 of 3 down.
- **Verdict**: **Keep default (a) - 2 of 3 down**.
- **Rationale**: When 2 of 3 watchdogs are down, redundancy is completely eliminated; the host is operating with a single point of failure (N=1). Alerting immediately gives operators time to intervene before the final instance fails and leaves the host unmonitored.

### Q13: Watchdog Daemon Supervisor Mechanism
- **Options**:
  - (a) Systemd system service template (`spl-watchdog@.service`) as primary supervisor, cron keeper `do_spl_wd_ensure` as outer fallback.
  - (b) Cron keeper `do_spl_wd_ensure` alone supervises all 3 detached loops directly (augmented by WD4 peer restart).
- **Draft Default**: (a).
- **Verdict**: **Pick (b) - Cron keeper + WD4 peer restart alone (Reject systemd primary)**.
- **Rationale**:
  1. *Privilege & Portability*: Systemd system units require root access for installation in `/etc/systemd/system/`. The box model operates under unprivileged user accounts. Option (b) requires zero root permissions and runs uniformly across bare-metal hosts, containers, and development workspaces.
  2. *Supervisor Split-Brain*: Having systemd (`Restart=always`, `RestartSec=5s`), WD4 peer processes, and the cron keeper all actively managing process lifecycles causes race conditions, cgroup tracking loss, and service flapping.
  3. *Redundancy Already Achieved*: WD4 peer monitoring already provides near-instantaneous crash detection and recovery without systemd. The minute cron keeper provides the outer fallback.

### Q14: Cross-Box Watchdog Liveness Alert Threshold
- **Options**: (a) Alert admin when another host has 0 active watchdogs; (b) alert when any single remote watchdog instance is down.
- **Draft Default**: (a) 0 active watchdogs.
- **Verdict**: **Keep default (a) - 0 active watchdogs**.
- **Rationale**: Single watchdog failures are recovered locally by peer daemons and rolling update mechanics. Alerting across hosts for N=2 would create frequent false alarms during normal rolling deployments. Alerting only on N=0 ensures alerts represent true host-level watchdog outages.

---

## 7. Review of Tasks T023..T027

| Task | Priority / Dependencies | Scope & Files | Test & Control Completeness |
|---|---|---|---|
| **T023** | P2 (after T003) | 3 watchdog daemons + peer heartbeat & restart. Files: `csi-spl-orc/src/bash/run/spl-watchdog.func.sh`, `spl-wd-ensure.func.sh`, test `orc/tests/wd-multi-daemon.tst.sh`. | **Order and files correct.** Must include per-instance state directory isolation and staggered tick offsets. If Q13 picks (b), systemd installer is omitted. |
| **T024** | P3 (after T017, T023) | Cross-box watchdog liveness via `box_beats`. Files: `spl-watchdog.func.sh`, `api/internal/hub/box_beat.go`, test `orc/tests/wd-cross-box.tst.sh`. | **Complete.** Well decoupled from agent migration; observation only. |
| **T025** | P3 (after T023) | Watchdog self-update on desk-cron changes. Files: `spl-watchdog.func.sh`, `spl-wd-self-update.func.sh`, test `orc/tests/wd-self-update.tst.sh`. | **Complete.** Needs staged execution directory / pre-flight syntax checks and universal stop rule for all instances. |
| **T026** | P2 (after T012, T023) | Admin alerts for watchdog failures (WD5). Files: `spl-watchdog.func.sh`, `spl-wd-ensure.func.sh`, `api/internal/hub/agent_admin.go`, test `orc/tests/wd-admin-alert.tst.sh`. | **Complete.** Tests verify 2-of-3 kill immediate alert and 5-min single failure wait; debounce control verified. |
| **T027** | Drill (after T023..T026) | End-to-end drill on both hosts. | **Complete.** Exercises peer restart, hung process kill, rolling update, and faulty update rollback while maintaining live agent surveillance. |

Dependency chain `T023 (P2) -> T025 (P3) / T024 (P3) -> T027 (drill)` is clean and correctly ordered.
