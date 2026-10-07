# 102 Agent lifetime: opinion of panelist agy-1

**Reviewer**: agy-1 (AntiGravity panelist 1, lane `a-473`)  
**Topic**: t1 `637269bb-d97b-4861-b45e-87200652b169` (HUM-10)  
**Spec author**: c-471 (Claude panelist 1; `csi-spl-doc/specs/102-agent-lifetime/spec.md`, commit `8f32ffd8cedac8f8e48fcea604c1ab6126e6db9a`, v0.1 draft)  
**Target File**: `csi-spl-doc/specs/102-agent-lifetime/opinions/agy-1.md`  

---

## 1. Codebase Verification of Spec Claims & Findings

Panelist agy-1 verified the claims in Section 1 and Section 13 against the codebase and live environment:

| Claim / Check | Spec assertion | Codebase verification | Finding |
|---|---|---|---|
| 1.1 / 1.2 Over-2h agents | `spool tail --task 637269bb...` shows ~30 agents over 2h; c-101 ran 21h; seat rows reflect first registry entry | Topic record at 04:56:05Z confirms c-002/c-003 rotated hourly while c-101 ran 21h; ~30 agents exceeded 2h | **Verified**. |
| 1.3 `lane_restart_wall_min` | `Default: 0 ... ZeroOff: true` in `internal/store/agent_lifecycle.go` | Inspected line 49: `{Key: "lane_restart_wall_min", Default: 0, Min: 10, Max: 240, ZeroOff: true}` | **Verified**. |
| 1.4 Stuck dialog modal=2 | `csi-spl-orc/src/bash/features/watchdog/situations/s7.sh` lines 1–9 checks modal=2 for "Make auto mode your default?" | Lines 1–9 match description; modal=2 is hardcoded to regex matching that specific prompt | **Verified**. |
| 1.5 Claude versions | `~/.local/share/claude/versions` contains 2.1.289..292; live processes run mixed versions | Directory contains all 4 binary releases; live processes span versions | **Verified**. |
| 1.6 Flag helper missing | `spool_claude_perm_flags()` missing definition; caller in `spl-lane-restart.func.sh:222` falls back | Grep returns 0 definitions; line 222 has fallback literal `--dangerously-skip-permissions` | **Verified**. |
| 13.1 Seat rotate crons | Crontab has 2 rotate crons on `<pc box>` | Inspected crontab under `<box user>`: lines `5 * * * *` and `15 * * * *` present | **Verified**. Under `<agent user>` count is 0 (crons belong to `<box user>`). |
| 13.2 / 13.3 Quiesce & handoff | `spl_rotate_quiesce` and `spl_rotate_handoff` in `spl-rotate-lib.func.sh` | Present at lines 249 and 272 | **Verified**. |
| 13.4 Lane size restart | `spl-lane-restart.func.sh` restarts lanes on context size | Present lines 1–10 | **Verified**. |
| 13.5 `WD_TAKEOVER_MAX` | Default 2 in `spl-watchdog.func.sh` | Present line 70 | **Verified**. |
| 13.7 Takeover alert cite | `sed -n 666,690p csi-spl-orc/src/bash/run/spl-watchdog.func.sh` | Lines 666–690 send `spl_wd_send orchestrator blocker` | **Finding**: The citation in the spec claims this sends an owner DM. Lines 666–690 send a blocker to the orchestrator; the owner DM is actually triggered in `spl-wd-takeover.func.sh:153` via `spl_wdt_alert`. |
| 13.8 / 13.9 S2 / S3 | `s2.sh` and `s3.sh` situation checks | `s2.sh` lines 1–8 and `s3.sh` present and active | **Verified**. |
| 13.10 Situations list | `lib.inc.sh`, s1..s8 in situations directory | Files exist as listed | **Verified**. |
| 13.11 Human guard | `WD_HUMAN_IDLE` 120s in `spl-watchdog.func.sh` | Present line 472 | **Verified**. |
| 13.12 Takeover phases | `spl-wd-takeover.func.sh` lines 1–30 | Present lines 1–30 | **Verified**. |
| 13.13 `box_beats` table | Table does not exist in `csi-spl-rdb` | 0 occurrences in `csi-spl-rdb/src/sql/postgres/spool-hub` | **Verified**. |
| 13.14 `ASKS_OWNER` | 4 occurrences in `spl-wd-ensure.func.sh` | Grep confirms count is 4 | **Verified**. |
| 13.15 Boot restore | `spl-agent-boot-restore.func.sh` lines 1–16 | Present lines 1–16 | **Verified**. |
| 13.16 Settings | `00-fleet.json` contains bypass permissions and auto mode disabled | File verified | **Verified**. |
| 13.17 Lifecycle keys | 11 keys in `agent_lifecycle.go` | Grep confirms 11 keys | **Verified**. |
| 8.3 Fixture path | Cites `tests/fixtures/wd-situations/modal-default-mode.pane` | Fixture is located at `csi-spl-orc/src/bash/tests/fixtures/wd-situations/modal-default-mode.pane` | **Finding**: Path in spec text omitted the `csi-spl-orc/src/bash/` prefix. |

---

## 2. In-Depth Analysis: Sections 3–6 (Lifetime, Restart Path, Handoff, Limits)

### 2.1 The Lifetime of a Session (Section 3): 1 h / 2 h Edge Dynamics
- **Soft 1 h Rebirth**:
  At 1 h (`REBIRTH_AT`), the hook injects a rebirth request and the watchdog pokes an idle agent. This is properly soft: if an agent is executing a multi-minute step or waiting on test completion, it can complete its step, commit, push green work, and initiate `/exit-clean --rebirth`.
  *Edge Hazard*: If an agent is running a long-running external process (e.g., compile or test suite), PostToolUse hooks do not fire until the tool returns, and pokes to tmux are buffered. The agent will not see the notice until the command finishes. This is acceptable provided the command completes before 2 h.
- **The 1 h 50 Notice (`FINAL_AT`)**:
  Signals an immediate freeze on accepting new work. Idle agents are poked. Active agents must cease spawning tools and commit handoff notes immediately.
- **The 2 h Hard End (`HARD_END`)**:
  Enforces an ungraceful shutdown (SIGTERM, followed by SIGKILL after `ROTATE_TERM_WAIT`), even if a process is active (R2) or a human is typing (R3).
  *Edge Hazard 1 (Git Index Lock)*: If SIGKILL strikes while an agent process is executing `git add` or `git commit`, `.git/index.lock` remains on disk. A subsequent restart that immediately attempts a `wip/<id>` commit or git check will fail with `fatal: Unable to create '.git/index.lock': File exists`. The restart path must clean stale `.git/index.lock` files before performing git operations.
  *Edge Hazard 2 (Marker Cleanup)*: When an agent exits via `/exit-clean --rebirth`, it leaves `lifetime/rebirth`. If the watchdog spawns a new session and that new session immediately crashes (e.g. S1 syntax error or S3 dead process), the watchdog must not observe the previous session's `lifetime/rebirth` marker and falsely categorize the crash as a planned rebirth. The restart path must atomically consume (delete/archive) `lifetime/rebirth` prior to spawning the replacement session.

### 2.2 The One Restart Path (Section 4): Is There Exactly One Path?
- **Unified Action vs. Bifurcated Mechanics**:
  The spec routes all restarts through `do_spl_agent_restart ID=<id> CAUSE=<...>`. While this provides a clean entry point, lanes and seats follow opposite execution invariants:
  - *Seats (001..004)*: Must start the new session first, verify acknowledgment (FR-041), and only then retire the old session to maintain the never-zero invariant (I1/I3).
  - *Lanes (005..999)*: Must stop the old session first, ensure worktree quiescence, commit/push WIP, and then start the new session so two processes never collide on one worktree.
- **Ordering Bug in Table 4.1 vs. Table 4.2**:
  In Table 4.1, the WIP step (`commit dirty tree and push wip/<id>`) is placed *before* RETIRE. For a lane, executing WIP before RETIRE means committing the worktree while the previous agent process is still active and potentially writing files. For lanes, RETIRE must execute *before* WIP.
- **Cross-Box Takeover (`cause=box-down`)**:
  Restarting an agent on another box requires cloning/worktree creation from `wip/<id>` and loading the handoff from the hub. It is functionally a remote reprovisioning path rather than an in-place session refresh.

### 2.3 The Continuous Handoff (Section 5): Can It Be Lost or Doubled?
- **Can a handoff be lost? YES, under the v0.1 draft**:
  Section 5.2 states: "*The script rewrites sections 1-4, 6, 7 and keeps 5, 8, 9 byte for byte... The agent writes 5, 8 and 9 with do_spl_agent_handoff_note... never by editing the file, so the script and the agent never race on one write.*"
  This claim is incorrect without OS-level file locking. Both `do_spl_agent_handoff` (invoked via PostToolUse hook or watchdog) and `do_spl_agent_handoff_note` (invoked by the agent) read `handoff.md`, modify content, and write it back. If a background hook triggers while the agent is executing `do_spl_agent_handoff_note`, an interleaved read-modify-write will silently clobber the agent's notes or the script's mechanical status.
  *Remedy*: All handoff reads and writes must acquire an exclusive `flock` on `<spool root>/<id>/handoff.lock` and write via atomic rename (`handoff.md.tmp.$$` -> `handoff.md`).
- **Can a handoff or session be doubled? YES, under the v0.1 draft (Split-Brain Hole)**:
  Section 10.2 line 408 states: "*A box that cannot reach the hub restarts only its own agents whose running_box was itself at its last good read.*"
  This creates a severe split-brain failure mode:
  1. Box A suffers a network partition isolating it from the hub.
  2. After `box_down_min` (2 min), Box B detects that Box A is absent from `box_beats`.
  3. Box B executes CAS on the hub, steals `running_box` for Agent A, and spawns Agent A on Box B from the hub handoff copy.
  4. Concurrently, Box A cannot reach the hub, falls back to its last cached read, sees that it previously owned Agent A, and restarts Agent A locally.
  5. Both Box A and Box B are now running live instances of Agent A concurrently. Both can push commits, overwrite `wip/<id>`, and post to spool channels.
  *Remedy*: A box isolated from the hub must enter node fencing: if it cannot refresh its beat with the hub within `box_down_min`, it must refuse to start or restart any agents until hub communication is re-established and CAS verified.

### 2.4 Limits (Section 6): Unbounded Crash Loop Loophole
- Section 6.1 caps restarts at 3 per rolling hour (`restart_max_per_hour`).
- Section 6.2 caps planned rebirths at 7 per task (`rebirth_max`), but explicitly notes: "*Crashes do not count toward this cap (they count in 6.1).*"
- *Loophole*: If a defective lane crashes once every 25 minutes, it experiences ~2.4 restarts per hour (never hitting the 3/hour limit) and accumulates zero planned rebirths (since crashes are excluded). Such an agent will crash-loop indefinitely across days, burning resources.
- *Remedy*: Introduce a total task restart ceiling `task_total_restart_max` (default 12) combining both planned rebirths and crash restarts.

---

## 3. Section-by-Section Verdicts & Concrete Replacements

### Section 0: What the owner asked
- **Verdict**: **AGREE**. Accurate transcription and mapping of owner orders across rounds.

### Section 1: Why: what the fleet looked like, and why the guards missed it
- **Verdict**: **AGREE with findings**. Accurately diagnoses why static text pattern matching failed during the 2026-10-06 incident. Findings noted in Section 1 above should be corrected in v1.0.

### Section 2: Words
- **Verdict**: **AGREE with additions**.
- **Additions**:
  - `handoff lock`: `<spool root>/<id>/handoff.lock`, an exclusive advisory lock file managing serialized updates between hooks and agent notes.
  - `node fence`: State entered by a box watchdog when disconnected from the hub for >= `box_down_min`, forbidding local agent restarts.

### Section 3: The lifetime of one session
- **Verdict**: **AGREE with concrete operational requirements**.
- **Concrete Requirements**:
  1. At 2 h hard kill, the restart sequence must check for and remove stale `.git/index.lock` before touching git state.
  2. The restart sequence must clear/archive `lifetime/rebirth` before launching the new session to prevent false rebirth attribution on an immediate crash.
  3. Worktree status must be recorded in handoff header with flag `hard_killed: true` when terminating at 2 h sharp.

### Section 4: One restart path
- **Verdict**: **REPLACEMENT of Section 4.1 execution order for lanes**.
- **Concrete Replacement**:
  In Table 4.1, reorder the execution phases for lane agents so that RETIRE precedes WIP:
  ```
  GATE    -> 6.2 guards, locks, check limit (3/hr and task_total_restart_max).
  RETIRE  -> For lanes: TERM, KILL after ROTATE_TERM_WAIT. Wait until PID is dead.
  CLEANUP -> Clear stale .git/index.lock in lane worktree.
  WIP     -> Commit dirty tree to temporary index; push refs/heads/wip/<id>.
  HANDOFF -> Mechanical refresh under flock; consume lifetime/rebirth marker.
  SEED    -> Combine brief, handoff, rebirth count, and lifetime rules.
  SPAWN   -> Start new session with SPAWN_REUSE_ID=1.
  RETIRE  -> For seats: Retain start-first, verify ack, then retire old session.
  REPORT  -> Blocker for crash; single-line REBORN for planned rebirth.
  LOG     -> Append to rotate.log (phase RS-*); record lifecycle event.
  ```

### Section 5: The handoff
- **Verdict**: **REPLACEMENT of Section 5.2 concurrency model**.
- **Concrete Replacement**:
  Replace Section 5.2 paragraph 4 with:
  "All operations modifying `<spool root>/<id>/handoff.md` (both `do_spl_agent_handoff` and `do_spl_agent_handoff_note`) must acquire an exclusive lock via `flock -x <spool root>/<id>/handoff.lock` with a 10s timeout. Writes must be written to `<spool root>/<id>/handoff.md.tmp.$$` and atomically renamed to `<spool root>/<id>/handoff.md`. Concurrent writes without locks are strictly prohibited."

### Section 6: Limits
- **Verdict**: **REPLACEMENT of Section 6.2 crash exclusion**.
- **Concrete Replacement**:
  Add `task_total_restart_max` (default 12, admin configurable):
  "While `rebirth_max` (default 7) caps planned rebirths, `task_total_restart_max` caps the total combined sum of planned rebirths and unplanned crash restarts for a single task brief. Reaching either cap halts automated restarts, pushes `wip/<id>`, and escalates to the admin."

### Section 7: Out of quota and login screens
- **Verdict**: **AGREE**. Faithfully implements owner answers W6 and R8 with admin notification, "login reset", and "no tokens left" workflows.

### Section 8: Generic stuck detection
- **Verdict**: **AGREE**. Defining stuck by absence of progress (Condition 2), absence of pane movement (Condition 4), and failure to consume input (Condition 5: delivered prompt without `UserPromptSubmit`) successfully addresses the root cause of the 2026-10-06 stall without fragile screen-scraping. Fixture controls (8.3) provide rigorous verification.

### Section 9: CLI updates under control
- **Verdict**: **REPLACEMENT of Section 9.1 auto-updater disablement mechanism**.
- **Concrete Replacement**:
  Do not rely solely on `env.DISABLE_AUTOUPDATER=1` in `00-fleet.json`, as CLI binary distributions often ignore environment blocks within JSON settings files.
  Mandate:
  "Auto-updates must be disabled at the operating system and process level by exporting `DISABLE_AUTOUPDATER=1` and `CLAUDE_DISABLE_AUTO_UPDATER=1` in `/etc/environment` and inside the harness launcher scripts (`spawn-claude.sh`). The presence of these environment variables must be asserted by `do_spl_agent_mode_check`."

### Section 10: Boxes: reboot, down, back
- **Verdict**: **REPLACEMENT of Section 10.2 split-brain fallback**.
- **Concrete Replacement**:
  Delete line 408 (*"A box that cannot reach the hub restarts only its own agents whose running_box was itself at its last good read."*).
  Replace with:
  "**Node Fencing**: A box watchdog that cannot successfully update its `box_beats` row or contact the hub for >= `box_down_min` is fenced. It MUST NOT restart, spawn, or adopt any agents locally. It must pause local agent lifecycle actions until hub communication is restored and `running_box` ownership is re-validated via CAS."

### Section 11: The admin
- **Verdict**: **AGREE**. Centralizing lifetime configuration in the operator workspace table `agent_lifecycle_config` adheres to R8 and R10.

### Section 12: Shared memory
- **Verdict**: **AGREE**. Scoping shared memory strictly to operational conventions and commands while delegating task state to briefs and topics aligns with H6 and R9.

### Section 13: What changes in 060 and 093, and what exists today
- **Verdict**: **AGREE with findings noted in Section 1**.

### Section 14: Trace: every owner answer to its section
- **Verdict**: **AGREE**. Complete mapping.

### Section 15: Opinion panel
- **Verdict**: **AGREE**. (Target for panel evaluations).

### Section 16: Open questions
- **Verdict**: Detailed verdicts in Section 5 below.

### Section 17: Rollout
- **Verdict**: **AGREE**. P0 (S9 + mode check) through P3 sequencing is sound and minimizes risk.

---

## 4. Summary of Major Holes

1. **Split-Brain / Dual-Session Execution (Section 10.2)**: Allowing a disconnected box to restart agents locally while another box assumes ownership via CAS after `box_down_min` violates the invariant "*Never two copies*".
2. **Handoff Clashing and Note Loss (Section 5.2)**: Unlocked concurrent execution of `do_spl_agent_handoff` (hooks) and `do_spl_agent_handoff_note` (agent) creates read-modify-write races that clobber handoff notes.
3. **Rebirth Marker Staling (Section 4.3)**: Failing to clear `lifetime/rebirth` prior to spawning a new session causes early crashes to be misattributed as planned rebirths.
4. **Infinite Crash Loop (Section 6.2)**: Excluding crashes from `rebirth_max` permits recurring crashes spaced >= 21 minutes apart to run indefinitely without hitting `restart_max_per_hour` (3/hr).
5. **Stale Git Index Locks on 2 h Kill (Section 3 / 4.1)**: SIGKILL at 2 h sharp can terminate git mid-execution, leaving `.git/index.lock` which breaks subsequent WIP commits and restarts unless cleaned.
6. **Execution Order Inversion (Section 4.1 Table 4.1)**: Executing WIP before RETIRE for lanes commits the worktree while the previous agent process is still active.

---

## 5. Verdict on the 10 Open Questions in Section 16

| # | Question | Choice | Rationale |
|---|---|---|---|
| **Q1** | Does 1 h rebirth force a busy agent | **Keep default (a)** | (a) allows the agent to reach a clean step boundary before exiting. Forcing an ungraceful Escape at 1 h contradicts owner answers R0/R1 (where 1 h is soft and 2 h is hard) and renders the 1 h 50 warning redundant. |
| **Q2** | Seats' restart order | **Keep default (a)** | (a) maintains start-first with ack (060 FR-041), preserving the never-zero invariant (I1/I3) for critical orchestrator/dispatcher roles. Lanes remain stop-first. |
| **Q3** | Does `rebirth_max` apply to seats | **Keep default (a)** | (a) restricts `rebirth_max` to lanes. Seats are perpetual roles designed to rotate continuously; capping them at 7 rebirths would terminate core infrastructure after 7 hours. |
| **Q4** | Usage limit with reset time and no admin response | **Keep default (a)** | (a) restarts after reset + 120s. Deterministic provider reset timestamps should not block on manual human approval when automatic recovery is safe. |
| **Q5** | Frequency of wip branch pushes | **DIFFER from default: Pick (a) with 30-min midpoint push** | Default (a) pushes only at 1 h, 1 h 50, and restart. If a catastrophic node hardware failure occurs at 50 min, up to 50 minutes of uncommitted progress is lost on failover. Adding a 30-minute midpoint push (or pushing when uncommitted diff exceeds 200 lines) bounds loss without overloading git refs. |
| **Q6** | Agent whose harness exists only on down box | **Keep default (a)** | (a) holds the agent and alerts the admin. Mandated by owner answer W6 ("no switch to another login or harness"). |
| **Q7** | Per-user memory files | **Keep default (a)** | (a) leaves existing per-user memory files intact and directs new lessons to hub memory, avoiding risky data migrations in initial rollout. |
| **Q8** | Location of box beat | **Keep default (a)** | (a) stores box beats in a dedicated `box_beats` table. Using the lease table causes channel post rerouting side-effects (093 6.4). |
| **Q9** | Handling agents over 2 h at live rollout | **Keep default (a)** | (a) staggers rebirths at at most 1 per box per minute via watchdog ticks. Prevents API rate-limiting spikes and thundering herd conditions. |
| **Q10** | `--force-with-lease` to `wip/<id>` | **Keep default (a) with strict path assertion** | (a) allows `--force-with-lease` strictly scoped to `refs/heads/wip/<id>`. The push wrapper must enforce an explicit assertion preventing any force push to `master` or release branches. |

---

## 6. Scores for Spec 102 Draft v0.1

- **Robust: 4/5** — Continuous handoff architecture and text-free S9 stuck detection are exceptionally strong, but docked 1 point for lack of file locking on `handoff.md` and unhandled `.git/index.lock` collisions on 2 h kills.
- **Failover-proof: 3/5** — Hub CAS failover and KMS handoff encryption are well-designed, but docked 2 points due to the severe split-brain vulnerability in Section 10.2 where partitioned boxes restart agents locally.
- **Simple: 4/5** — Consolidating disparate scripts into `do_spl_agent_restart` and unifying configuration in the operator workspace is clean, though bifurcated seat vs. lane semantics add necessary complexity.
- **Uninterruptible: 4/5** — The 1 h soft / 1 h 50 stop-work / 2 h hard kill structure guarantees bounded execution, but docked 1 point for the 50-minute data-loss window on sudden hardware crash and lack of total restart bounding on slow crash loops.
