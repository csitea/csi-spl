# 102 Opinion: agy-2

- **Panelist**: agy-2 (AntiGravity panelist 2)
- **Role**: Independent opinion on `102 Agent lifetime: 1 h rebirth, 2 h hard end, one restart path, generic stuck detection` v0.1 (commit `8f32ffd8cedac8f8e48fcea604c1ab6126e6db9a`)
- **Topic**: t1 `637269bb-d97b-4861-b45e-87200652b169` (HUM-10)

## 1. Executive Summary & Scores (v0.1)

Scores (1-5):
- **robust**: 4/5 — Grounding stuck detection in absent model progress and unconsumed inputs (S9) eliminates dialog whitelist blind spots, though pane hash stability across terminal echo needs decoupling from poke delivery.
- **failover-proof**: 4/5 — Cross-box CAS on `running_box` and encrypted hub handoffs provide solid failover, but partition split-brain handling needs explicit local watchdog fencing when hub connectivity is lost.
- **simple**: 4/5 — Reusing 093's takeover pipeline for both planned rebirths and crashes collapses two divergent restart mechanisms into one unified path with minimal new primitives.
- **uninterruptible**: 4/5 — The soft 1 h rebirth request with hard 2 h cutoff guarantees continuous agent momentum without aborting active tool turns prematurely, backed by `wip/<id>` preservation.

## 2. Code Claims and Verification Findings

The check commands cited in v0.1 sections 1 and 13 were executed against the live tree and system state:

| Spec Claim / Citation | Cited Command / Target | Verification Result |
|---|---|---|
| Section 1 Row 3: Wall-clock lane restart disabled by default | `grep -n lane_restart_wall_min csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` | **Holds**: Line 49 confirms `Default: 0 ... ZeroOff: true`. |
| Section 1 Row 4 / Section 13 Row 8: S7 whitelist matching | `sed -n 1,9p csi-spl-orc/src/bash/features/watchdog/situations/s7.sh` | **Holds**: Lines 1-9 confirm `modal=2` handles specific auto mode dialog by exact text. |
| Section 1 Row 5 / Section 13 Row 14: In-place version accumulation | `ls ~/.local/share/claude/versions` | **Holds**: 4 versions present (2.1.289 through 2.1.292); active processes run 2.1.292. |
| Section 1 Row 6 / Section 13 Row 5: Launch flag helper missing | `grep -rn 'spool_claude_perm_flags()' csi-spl-orc/src/bash` | **Holds**: 0 definitions; 1 caller with literal fallback in `spl-lane-restart.func.sh:222`. |
| Section 13 Row 1: Crontab rotation entries | `crontab -l \| grep -c 'csi-spl:\(orch\|dispatch\)-rotate'` | **Holds**: Exactly 2 jobs present in the box user crontab. |
| Section 13 Row 2: `spl_rotate_quiesce` function | `grep -n '^spl_rotate_quiesce' csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` | **Holds**: Defined at line 249. |
| Section 13 Row 3: `spl_rotate_handoff` function | `grep -n '^spl_rotate_handoff' csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` | **Holds**: Defined at line 272. |
| Section 13 Row 4: Lane restart on size | `sed -n 1,10p csi-spl-orc/src/bash/run/spl-lane-restart.func.sh` | **Holds**: Lines 1-10 confirm restart on size/compaction. |
| Section 13 Row 6: `WD_TAKEOVER_MAX` limit | `grep -n 'WD_TAKEOVER_MAX:=' csi-spl-orc/src/bash/run/spl-watchdog.func.sh` | **Holds**: Defined as 2 at line 70. |
| Section 13 Row 7: Takeover limit handler | `sed -n 666,690p csi-spl-orc/src/bash/run/spl-watchdog.func.sh` | **Holds**: Holds out id and sends blocker after `WD_TAKEOVER_MAX`. |
| Section 13 Row 8: S2 limit handling | `sed -n 1,8p csi-spl-orc/src/bash/features/watchdog/situations/s2.sh` | **Holds**: Matches banner texts for login and quota limits. |
| Section 13 Row 9: S3 bare shell situation | `cat csi-spl-orc/src/bash/features/watchdog/situations/s3.sh` | **Holds**: Detects bare shell with no running agent process. |
| Section 13 Row 10: Situations inventory | `ls csi-spl-orc/src/bash/features/watchdog/situations/` | **Holds**: Contains `lib.inc.sh` and `s1.sh` through `s8.sh`. |
| Section 13 Row 11: Human idle guard | `grep -n WD_HUMAN_IDLE csi-spl-orc/src/bash/run/spl-watchdog.func.sh` | **Holds**: Line 472 checks `WD_HUMAN_IDLE:=120`. |
| Section 13 Row 12: Takeover implementation | `sed -n 1,30p csi-spl-orc/src/bash/run/spl-wd-takeover.func.sh` | **Holds**: Implements GATE, HOLD, LOOP, HANDOFF, SEED, SPAWN, RETIRE. |
| Section 13 Row 13: Absence of `box_beats` table | `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats` | **Holds**: Count is 0. |
| Section 13 Row 14: Keeper owner alerts | `grep -c ASKS_OWNER csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh` | **Holds**: Count is 4. |
| Section 13 Row 15: Boot restore implementation | `sed -n 1,16p csi-spl-orc/src/bash/run/spl-agent-boot-restore.func.sh` | **Holds**: Restores agent sessions on reboot as agent user. |
| Section 13 Row 17: Fleet settings template | `cat csi-spl-orc/src/bash/features/spool-install/assets/claude/settings/00-fleet.json` | **Holds**: Sets `bypassPermissions` and `disableAutoMode`. |
| Section 13 Row 18: Lifecycle config keys | `grep -c 'Key: "' csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` | **Holds**: Count is 11. |

### Verification Findings
1. **Fixture relative path (Section 8.3)**: The cited path `tests/fixtures/wd-situations/modal-default-mode.pane` is located at `csi-spl-orc/src/bash/tests/fixtures/wd-situations/modal-default-mode.pane`.
2. **Autoupdate suppression setting (Section 9.1)**: Section 9.1 assumes `env.DISABLE_AUTOUPDATER=1` inside `settings/00-fleet.json` disables native Claude Code self-updates ("I believe, unchecked, that the native installer honours it"). Inspection shows that `00-fleet.json` currently has no `env` block, and `spool-harness.sh` does not export `DISABLE_AUTOUPDATER`. Claude Code reads `DISABLE_AUTOUPDATER` as a process environment variable, not a settings JSON property.

## 3. Deep Dive: Sections 7-12 and 17 vs Real Incidents & Safe Rollout

### 3.1 Section 7: Out of Quota and Login Screens
- **Real Incident Evaluation**: On 2026-10-05, an orchestrator seat expired with `Login expired · Please run /login`. Situation S2 already detects the banner, but previously produced unhandled stalls and owner DMs. Spec 102 routes S2 to admin notifications (web app DM + email) with actionable buttons ("login reset" and "no tokens left").
- **Holes and Refinements**:
  1. *Restart count burning*: If the admin presses "login reset" before new credentials or tokens are active on the box, the restarted agent will immediately trigger S2 again. Spec Section 7 states: "one restart each, counted in 6.1". Re-triggering S2 would quickly exhaust the 3-restarts-per-hour limit (`restart_max_per_hour`) and shift the agent into an administrative hold-out (6.1), obscuring the authentication root cause. Re-hitting S2 must re-arm the S2 hold-out without consuming crash quota.
  2. *WIP branch scoping*: The spec specifies that pressing "no tokens left" pushes `wip/<id>`. This must be explicitly scoped to lanes; seats do not operate in feature worktrees and must not attempt WIP branch pushes.

### 3.2 Section 8: Generic Stuck Detection
- **Real Incident Evaluation**: On 2026-10-06, a CLI update introduced the prompt `"Make auto mode your default permission mode? [y/n]"`, freezing six seats for hours because S7 only matched pre-listed dialog texts (`c-003-f9112852-generic.md`).
  - *Detector evaluation*:
    - Condition 1 (harness alive in `/proc`): **Fires** (process running).
    - Condition 2 (`progress_ts` older than `stuck_min`): **Fires** (no progress for >10m).
    - Condition 3 (not in tool within cap): **Fires** (idle prompt state).
    - Condition 4 (pane unchanged on every tick): **Fires** (static dialog prompt).
    - Condition 5 (input delivered but no `UserPromptSubmit`): **Fires** (poke delivered to pane, but swallowed by interactive prompt without reaching the model).
  - *Verdict*: S9 **would fire reliably** on the 2026-10-06 incident.
- **Holes and Edge Cases**:
  - *Poke echo resetting pane hash*: Condition 4 requires identical pane hashes across every tick of the window. Condition 5 requires input (such as a poke) to have been delivered. When `spool-send.sh` pokes an agent via `tmux send-keys`, text is typed into the pane buffer, changing `capture-pane -p`. If a poke arrives at minute 3 of the 10-minute window, Condition 4 resets. If peers poke periodically, Condition 4 would never reach `stuck_min`.
  - *Concrete Replacement*: Condition 4 must evaluate pane hash stability *since the arrival of the input* that satisfied Condition 5, or filter out inert shell comments (`: 'SPOOL ...'`) from the pane hash calculation.

### 3.3 Section 9: CLI Updates Under Control
- **Real Incident Evaluation**: Section 9 directly prevents the 2026-10-06 incident by eliminating unmanaged in-place updates.
- **Rollout Mechanism**: Nightly window (02:00-05:00 UTC), single box lease, side-by-side binary installation, scratch test agent running `do_spl_cli_selftest` and verifying S9 for 5m before symlink switch, graceful uptake at next rebirth.
- **Holes and Refinements**:
  - `DISABLE_AUTOUPDATER=1` must not rely on `00-fleet.json`. It must be explicitly exported in `spool-harness.sh`, `spool-env.inc.sh`, and `/etc/environment` for the agent user.

### 3.4 Section 10: Boxes: Reboot, Down, Back
- **Reboot Handling**: Watchdog keeper restores watchdog, which restarts agents with open registry rows where `running_box` is the local box. Cleanly replaces `@reboot` boot-restore cron.
- **Down & Failover**: `box_beats` table in hub with `box_down_min` (2m default) timeout. Live boxes attempt CAS on `running_box` in fleet lane row. Winner restarts agent from encrypted hub handoff blob (5.3) and `wip/<id>` (5.4).
- **Return Home**: Returning box does not steal running agents; agents move back at their next rebirth if home box is healthy (R6).
- **Holes and Refinements**:
  1. *Network partition / Split-brain*: If a box loses connection to the hub, the hub marks it down after 2 minutes, allowing another box to take over. If the disconnected box continues running locally, two live instances of the same agent run concurrently. The local watchdog must fence or pause its agents if it cannot beat to the hub for `box_down_min`.
  2. *Missing WIP branch fallback*: If a lane crashes before its first WIP push, remote takeover must fall back to the task's base branch.

### 3.5 Section 11: The Admin
- Operator workspace configuration via `agent_lifecycle_config` table.
- Notifications sent via web app DM and email with direct response buttons.
- Fully aligns with owner answers R8 and R10.

### 3.6 Section 12: Shared Memory
- Hub-level shared memory restricted to operational conventions, commands, and traps (R9).
- Title normalization avoids duplicate accumulations.
- Seeds receive lightweight title indexes; full details fetched on demand.

### 3.7 Section 17: Rollout in Small Safe Steps
- **Phasing**:
  - **P0**: S9 situation script + fixture controls (8.3), settings check (9.2), restored flag helper (`spool_claude_perm_flags`). Closes the stuck modal vulnerability immediately with zero database schema changes.
  - **P1**: Local continuous handoff (5.1, 5.2), session-age 1h/2h lane lifetime rules, rate-limited rebirth of over-2h agents (1 per box per minute, Q9).
  - **P2**: Hub admin settings in `agent_lifecycle_config`, encrypted hub handoff sync (5.3), admin email/DM buttons.
  - **P3**: `box_beats` table, cross-box failover (10), controlled nightly CLI updates (9.1), shared memory (12).
- **Rollout Safety**: Highly incremental, safe, and testable at every boundary.
- **Crucial Prerequisite for P1**: The git pre-push deploy-gate must be configured to permit `refs/heads/wip/*` pushes (or WIP pushes must use `--no-verify`).

## 4. Section-by-Section Verdicts (Agree or Concrete Replacement)

- **Section 0 (What the owner asked)**: **Agree**. Accurate transcription and tracing of owner commands and Round 3 overrides.
- **Section 1 (Why: what the fleet looked like)**: **Agree**. Verified against live code and environment.
- **Section 2 (Words)**: **Agree**. Definitions are clear, consistent, and unambiguous.
- **Section 3 (The lifetime of one session)**: **Agree**. Soft 1 h rebirth request, 1 h 50 warning, and 2 h hard kill balances progress preservation and lifetime capping.
- **Section 4 (One restart path)**: **Agree**. Unifying planned rebirths and crash takeovers under `do_spl_agent_restart` avoids duplicate mechanics.
- **Section 5 (The handoff)**: **Agree with Concrete Replacement for 5.4**:
  - *Concrete Replacement (5.4)*: The automated push of `wip/<id>` must explicitly use `--no-verify` or the git pre-push hook must be updated to exempt `refs/heads/wip/*` refspecs on stdin. Otherwise, uncommitted or dirty WIP commits will trigger `do_check_pre_push` in the pre-push hook and fail on lint/test checks.
- **Section 6 (Limits)**: **Agree**. Rolling 3-restarts-per-hour limit and 7-rebirths-per-task cap prevent churn and runaway executions.
- **Section 7 (Out of quota and login screens)**: **Agree with Concrete Replacement**:
  - *Concrete Replacement (7)*: Re-triggering S2 immediately after an admin "login reset" must not consume a restart slot in `restart_max_per_hour`; it must re-arm the S2 hold-out state cleanly. Clarify that `wip/<id>` pushes apply to lanes only (seats notify orchestrator without WIP branch pushes).
- **Section 8 (Generic stuck detection)**: **Agree with Concrete Replacement for 8.1**:
  - *Concrete Replacement (8.1)*: In Condition 4, pane hash stability must be measured *since the arrival of the input* that satisfied Condition 5, or strip echoed inert shell comment pokes (`: 'SPOOL ...'`) from the pane hash buffer. This prevents incoming pokes from resetting the 10-minute stuck timer.
- **Section 9 (CLI updates under control)**: **Agree with Concrete Replacement for 9.1**:
  - *Concrete Replacement (9.1)*: In addition to `00-fleet.json`, `DISABLE_AUTOUPDATER=1` must be explicitly exported in `spool-harness.sh`, `spool-env.inc.sh`, and the agent user environment to ensure Node/CLI invocations strictly disable self-updates.
- **Section 10 (Boxes: reboot, down, back)**: **Agree with Concrete Replacement for 10.2**:
  - *Concrete Replacement (10.2)*: Introduce a local watchdog partition fence: if a box cannot contact the hub for `box_down_min`, it must pause its local agent sessions to prevent split-brain dual-master execution upon remote CAS takeover. Remote checkout must fall back to the lane branch if `wip/<id>` does not exist.
- **Section 11 (The admin)**: **Agree**. Operator workspace configuration and direct action buttons match requirements.
- **Section 12 (Shared memory)**: **Agree**. Dedicated hub shared memory for conventions and traps with deduplication is properly bounded.
- **Section 13 (What changes in 060 and 093)**: **Agree**. Verified against live codebase.
- **Section 14 (Trace)**: **Agree**. Complete end-to-end mapping from owner instructions to sections.
- **Section 15 (Opinion panel)**: **Agree**. Placeholder for synthesis.
- **Section 16 (Open questions)**: **Agree** (detailed below).
- **Section 17 (Rollout)**: **Agree**. Phased P0..P3 deployment is safe and modular.

## 5. Holes and Discrepancies with Owner Instructions

1. **Deploy-gate blocks WIP branch pushes (Section 5.4 vs Repo Pre-Push Hook)**:
   The owner mandated pushing WIP branches on rebirth/kill (A3, W4). Pushing dirty/uncommitted WIP states will be blocked by `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push` unless `wip/*` refs are exempted or `--no-verify` is used.
2. **Terminal echo resetting S9 pane hash stability (Section 8.1 vs Incident G1)**:
   Poking an agent mutates the tmux terminal pane. Requiring identical hashes across every tick of a 10-minute window while simultaneously requiring a poke to have been delivered in that window creates a contradiction unless the hash check accounts for the poke arrival time.
3. **Partition split-brain protection (Section 10.2 vs Owner W7/R5)**:
   A box disconnected from the hub must fence its local agents when the hub considers it down, avoiding dual-master execution.
4. **Re-hitting S2 depleting restart-per-hour quota (Section 7 vs Owner W3/W6)**:
   If an admin presses "login reset" before credentials or tokens are fully restored, the restarted agent will immediately trigger S2 again. This must not burn the 3/hour crash limit.

## 6. Verdicts on the 10 Open Questions (Section 16)

- **Q1 (1 h rebirth forcing busy agent)**: **Default (a)** — Soft request until 1 h 50. Forcing at 1 h via Escape risks aborting active tool turns or uncommitted file edits when 50 minutes remain for graceful completion.
- **Q2 (Seats order)**: **Default (a)** — Start-first with ack (060). Preserves 060 invariants I1 and I3, ensuring zero downtime for critical fleet roles (orchestrator, dispatcher).
- **Q3 (`rebirth_max` on seats)**: **Default (a)** — Lanes only. Seats are permanent operational daemons; capping them at 7 rebirths would terminate orchestrators after 7 hours.
- **Q4 (Usage limit with reset time)**: **Default (a)** — Restart after reset + 120 s if admin has not answered. Prevents unnecessary idle delays when provider quota has already replenished.
- **Q5 (WIP branch push frequency)**: **Default (a)** — Push at 1 h, 1 h 50, and restart. Pushing on every handoff refresh (every 60 s) causes excessive git ref churn and remote rate limiting.
- **Q6 (Harness available only on down box)**: **Default (a)** — Wait for home box with admin alert. Switching harnesses violates owner directive W6 and introduces prompt/harness incompatibility.
- **Q7 (Per-user memory files)**: **Default (a)** — Keep local files as-is; hub memory takes new lessons only. Avoids bulk importing noisy or obsolete local notes.
- **Q8 (Box beat table)**: **Default (a)** — New dedicated `box_beats` table. Prevents lease table churn from altering message routing.
- **Q9 (Over-2h backlog at rollout)**: **Default (a)** — Rate-limit watchdog restarts to at most 1 per box per minute. Prevents a thundering herd across ~30 agents.
- **Q10 (`--force-with-lease` to `wip/<id>`)**: **Default (a)** — Allowed for `wip/<id>` refs only, combined with `--no-verify` or pre-push hook exemption. Keeps remote git refs clean without branch explosion.
