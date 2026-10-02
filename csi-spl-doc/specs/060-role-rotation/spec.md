# 060: hourly role rotation (orchestrator and dispatchers)

Status: **specified** (2026-10-02, CLE-77941). Being built in two lanes:
orchestrator rotation CLE-77939, dispatcher rotation CLE-77940.
Plan: [plan.md](plan.md). Tasks: [tasks.md](tasks.md).
Related: [SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md)
(the roles, the leases, the ask book), [058 the fleet on many machines](../058-multi-machine-fleet/spec.md)
(names `<ID>@<box>`, ids 001-003 reserved per box), CLE-77935 (a stalled
master gives up its lease).

## 1. What the owner asked for (verbatim, 2026-10-02 ~04:25Z)

> "create proper specs for this because it is crucial for the operation of the whole system"

| # | owner requirement | FRs |
|---|---|---|
| R1 | "on HOURLY basis the orchestrator creates a summary of this role and current session and spawns another orchestrator with the new CLE-001 (some how renames itself) and there is a new claude code instance doing the work of the orchestrator ... because you blow off your token limits all the time" | FR-001..FR-004, FR-010..FR-019, FR-040..FR-043, section 6 |
| R2 | "the same should happen on hourly basis to the master dispatcher and the fail-over dispatcher ... so it should be the failover who should take this responsibilities and that the orchestrator should re-create the failover too" | FR-020..FR-031 |
| R3 | "this could be triggered with cron on hourly basis, but starting at the 5th minute of each hour" | FR-050..FR-053 |
| R4 | "the new instances should be started with auto mode on and dangerously skip permissions" | FR-060..FR-063 |
| R5 | "this should be scripted as much as possible - it should be mechanical - and not strong decision making requiring tokens" | FR-001, FR-005, FR-040, FR-070..FR-074 |
| R6 | standing rules: agents run as the agent user only (`SPOOL_AGENT_USER`); one agent = one small task; `<ID>@<box>` naming, CLE-001/002/003 reserved per box (058); a multi-machine fleet (the home box + `sat`) under ONE fleet lease (orch + dispatch roles, CLE-77911) | FR-006, FR-007, FR-044, FR-045, section 7 |

The owner answered four design questions through CLE-001 (2026-10-02
~04:30Z, msg `db90b283`). These answers are binding:

| # | decision | FRs |
|---|---|---|
| D1 | a session that is busy at the trigger is rotated ANYWAY, on schedule, even mid-task. The new session picks up from the handoff, so the handoff captures in-flight work mechanically: open asks, the last outbox and inbox items, and the last terminal lines | FR-011, section 6 |
| D2 | a new session that fails to start or never acks: KEEP THE OLD session in the role, and ALERT (an ask in the ask book plus a DM to the owner) | FR-013, FR-014, FR-027, FR-075 |
| D3 | orchestrator at `:05`, dispatchers at `:15` (`5 * * * *`, `15 * * * *`), so the new orchestrator is in place when the failover is re-created | FR-050, FR-051 |
| D4 | the old session ends with `/exit-clean`, and is force-killed if it is not gone after 5 min | FR-015, FR-016 |

Why it matters: a role session re-reads its whole context on every turn, and
the orchestrator and master dispatcher run all day. Measured on the home box
2026-10-02 04:00Z (`ps -o etimes`, n=1 each): `CLE-001`, `CLE-002` and
`CLE-003` had each been up about 34 200 s, roughly 9.5 h on one resumed
session. All three were already on their second login after the first hit
its weekly limit on 2026-10-01.

## 2. Words

| word | means |
|---|---|
| **role** | `orch` (`CLE-001`), `master` (`CLE-002`), `failover` (`CLE-003`); the ids come from `lease.conf` (`LEASE_ORCH`, `LEASE_MASTER`, `LEASE_FAILOVER`) |
| **old / new session** | the claude process holding the role id before the rotation / the one the rotation starts under the SAME id |
| **acting** | the session named by the role's local lease file (`lease.orch`, `lease`): its own id and box, at most 180 s old (fleet-roles 4.1). Only the acting session routes, spawns or posts |
| **handoff** | the markdown file the script writes for the new session (section 6) |
| **ack** | the new session's one command saying it has read the handoff and its inbox (FR-041) |
| **run id (`rid`)** | `<UTC yyyymmddThhmmZ>-<role>`, one per attempt; every log line and file of the attempt carries it |
| **idle pane** | `classify_screen` (`agent-state.inc.sh`) = `idle` and the visible screen byte-identical over `ROTATE_IDLE_SEC` (10 s) |
| **stalled pane** | the CLE-77935 rule: the pane footer matches `LEASE_STALL_RE` (usage limit, `/login`, invalid key, onboarding, trust screen) |
| **retiring window** | the old session's window after the rename of FR-007 |

## 3. User stories

- **US1 (owner).** Every hour the orchestrator's work moves to a fresh claude
  session under the same `CLE-001@<box>`, so no session re-reads a 9-hour
  transcript. I do nothing, and no ask I sent is dropped.
- **US2 (owner).** Every hour the master dispatcher is replaced by a fresh
  session while the failover covers for it. The failover is then re-created
  too, so no dispatcher session lives much beyond an hour.
- **US3 (lane agent).** I keep sending to `CLE-001`, `CLE-002` or
  `--to orchestrator` as before. My message reaches whichever session holds the id, and
  nothing is lost across a rotation.
- **US4 (operator).** One command shows each role's last rotation, its phase
  and its last skip reason. One switch turns rotation off on a machine.
- **US5 (fleet).** With two machines, rotation never moves a lease to the
  other machine, never has two acting orchestrators and never has two masters.

## 4. Functional requirements

### 4.1 Common to every role

- **FR-001** Rotation is a bash run action per role in `csi-spl-orc`:
  `do_spl_orch_rotate` (orch) and `do_spl_dispatch_rotate` (master +
  failover). No step calls a model to decide, summarise or write. The only
  model work is the new session reading what it is given and running the ack
  command.
- **FR-002** Every step writes ONE log line
  `<UTC ts> <rid> <PHASE> <OK|SKIP|WAIT|FAIL|PLAN|ABORT> <detail>` to
  `<spool root>/dispatch/rotate.log`. Both roles write to this one file, so
  a single tail shows the whole hour. The current phase is also kept in
  `<spool root>/dispatch/rotate.<orch|dispatch>.state` (`<rid> <phase> <epoch>`).
- **FR-003** A run can be resumed. The next run reads the `.state` file and
  either continues the phase, when its effect can be checked (such as "the
  new pid is live"), or runs that phase's failure path. A role never has two
  rotations at once.
- **FR-004** One `flock` per role (`rotate.orch.lock`, `rotate.dispatch.lock`).
  A busy lock = `SKIP locked`, exit 0.
- **FR-005** `DRY_RUN=1` is the default from a shell: one `PLAN` line per
  step, nothing touched. The cron line passes `DRY_RUN=0`.
- **FR-006** Every new session is started:
  - as the agent user (`SPOOL_AGENT_USER` from box.env);
  - through `spawn-window.sh claude <ID>` with `SPAWN_REUSE_ID=1`: the same
    spool dir, so the same inbox and archive.

  The spawn rewrites the identity map `agents/<ID>.json` for the new pid. The
  rotation checks that `ai_pane_of <ID>` resolves to the NEW pane before it
  waits for the ack. A session started as the box user is a `FAIL`: the
  `ps -u <box user>` check of the box CLAUDE.md must print nothing.
- **FR-007** Naming:
  - the new session's window is `<ID>@<box>` (058 F5), in the same tmux
    session as the old one, with the same claude `--name`;
  - when the new one starts, the old window becomes
    `<ID>-<UTC hhmm>Z-retiring`;
  - `spool_id_of_window_var` parses the retiring name as no id (it fails
    `SPOOL_ID_RE`), so pokes, `spool_pane_of` and `--agent <ID>` lookups by
    window name never land on it;
  - on a failure path the old window gets its name back.
- **FR-008** A role is rotated only when its old session is at least
  `ROTATE_MIN_AGE` (3300 s) old (`ps -o etimes`). That way the next `:05`
  catches a session started at the previous `:05`, despite a few minutes of
  drift. A younger session = `SKIP young`.
- **FR-009** A stalled pane (CLE-77935) is not rotated: the new session
  would run on the same login and stall too. The run logs
  `SKIP stalled <footer text>` and sends the orchestrator one note per
  distinct footer. The CLE-77935 lease rule already moves a stalled master's
  lease to the failover.

### 4.2 The orchestrator (`CLE-001`)

There is no standby orchestrator inside a machine, so the new session starts
while the old one still exists. The old one is first stopped mid-turn, so
it cannot act during the overlap.

- **FR-010** Gates, in order. Each failure is a `SKIP`, exit 0:
  1. the switch is on (FR-090);
  2. `lease.conf` names `LEASE_ORCH`;
  3. this machine holds the orch lease (FR-044): `lease.orch` names
     `<LEASE_ORCH>@<this box>` and is fresh;
  4. exactly ONE live claude process carries `SPOOL_AGENT_ID=<LEASE_ORCH>`.
     None = `SKIP absent`. Two or more = `SKIP duplicate`: a rotation is in
     flight or a stray is running, so the orchestrator gets a note;
  5. the FR-008 age;
  6. not stalled (FR-009).
- **FR-011** QUIESCE (owner D1: a busy session is rotated anyway):
  - wait up to `ROTATE_IDLE_GRACE` (60 s) for an idle pane;
  - still busy: send `Escape` to the old pane, which interrupts the current
    turn, and wait up to 30 s for idle;
  - a permission or choice dialog on screen: `Escape` as well;
  - still not idle: rotate anyway, and the log line says
    `QUIESCE WAIT busy-rotated`.

  QUIESCE runs BEFORE the handoff is written. The handoff therefore captures
  the screen where the turn stopped.
- **FR-012** HANDOFF: the script writes the handoff (section 6) before
  anything is spawned. A source that fails shows
  `UNAVAILABLE: <why>` and never blocks the rotation.
- **FR-013** SPAWN: the old window is renamed (FR-007), then the new
  session starts with the seed of FR-040. If no pid appears within
  `ROTATE_START_WAIT` (120 s), or `ai_pane_of` still points at the old pane:
  - the new window is closed;
  - the old window gets its name back;
  - `FAIL spawn` and an ALERT (FR-075).

  The old session keeps the role (owner D2).
- **FR-014** ACK: the script waits up to `ROTATE_ACK_TIMEOUT` (900 s) for the
  ack (FR-041). On a timeout:
  - `/exit` is typed into the NEW pane, and its process is killed after 30 s;
  - its window is closed and the old window gets its name back;
  - `FAIL ack` and an ALERT (FR-075).

  The old session keeps the role (D2). The script then types into the old
  pane one line naming the handoff path:
  `Rotation <rid> failed; you keep the role. Read <path> for anything you were interrupted on.`
- **FR-015** RETIRE (owner D4): after the ack, the script types `/exit-clean` +
  Enter into the OLD pane, then waits `ROTATE_EXIT_WAIT` (300 s) for its pid
  to go, then sends SIGTERM, waits 30 s, then SIGKILL. Each signal is logged.
  If the process is still alive after SIGKILL: `FAIL exit` and an ALERT, and
  the next run's duplicate gate (FR-010) refuses until a human clears it.
- **FR-016** `/exit-clean` from a retiring window must close ITS OWN window,
  never the new one. `tmux-close-window.sh --agent <ID>` resolves a window
  by the name that carries the id, which after FR-007 is the NEW window.
  So:
  - when the caller's own pane (`$TMUX_PANE`, `$CLE_TMUX_PANE`) sits in a
    retiring window of that id, the script closes that pane's window;
  - otherwise, if the caller's pane and the `--agent` window differ, it
    refuses.

  The exit-clean report goes to the orchestrator as usual. The
  `do_spl_lane_put` "done" step does nothing for a role id: role ids have no
  lane row.
- **FR-017** CLOSE: if the retiring window is still open (the deferred close
  did not run), the script closes it by pane id, never by name. It then
  checks three things:
  - one live process carries the id;
  - `lease.orch` names `<ID>@<box>`, and the fleet renew follows the new
    pid. The lease is keyed by id, so the rotation writes no lease and leaves
    no gap;
  - the identity map points at the new pid.

  Then `DONE`, and a `result` note to the new session on task
  `orch-rotate-<rid>` with the `rid`, the handoff path and the counts.
- **FR-018** After SPAWN the old session gets no new input: pokes resolve to
  the new window (FR-006, FR-007), and nothing is typed into the old pane
  except FR-014's failure line and FR-015's `/exit-clean`.
- **FR-019** An ask (fleet-roles 4.3) that the old session acked but did not
  close stays open in the ask book. The new session sees it in
  `do_spl_orch_inbox` and re-acks it as the same `<ID>@<box>`.

### 4.3 The dispatchers (`CLE-002` master, `CLE-003` failover)

The failover covers the master's rotation through the existing lease, and is
then re-created itself. **The ids stay bound to their roles.** `lease.conf`
is never rewritten to swap `LEASE_MASTER` and `LEASE_FAILOVER`:
- 058 3.0 reserves `CLE-002` = master on every box;
- every brief and agent sends owner text to `CLE-002`. After a swap, those
  messages would land in a standby session that reads them but never acts.

- **FR-020** PRECHECK. Each failure is a `SKIP`, exit 0:
  - the switch is on;
  - `lease.conf` names both ids;
  - this machine holds the dispatch lease (FR-044);
  - `rotate.dispatch.last` is older than `ROTATE_MIN_AGE`.

  If an orch rotation of this machine is between SPAWN and DONE, the run
  waits up to `ROTATE_SEQ_WAIT` (600 s) for it, then logs `SKIP orch-busy`
  (FR-051).
- **FR-021** HEAL: when M or F has no live claude process, the script spawns
  the missing one (same id, FR-006, with the dispatcher brief
  `do_spl_dispatch_setup` renders) and does nothing else this hour. This
  keeps the box from ever having zero dispatchers.
- **FR-022** A stalled M (FR-009) gives `SKIP stalled`: the CLE-77935 rule
  has already moved the lease to F, and a new M would stall too.
- **FR-023** HOLD: the script writes `<spool root>/dispatch/rotate.hold`
  (`<LEASE_MASTER> <epoch> <rid>`). While the hold is younger than
  `ROTATE_HOLD_MAX` (1800 s), `spl_lease_agent_able` (the CLE-77935 gate)
  treats M as unable, so:
  - the renew loop stops renewing for M;
  - the watch loop and the fleet loop's local-candidate pick skip M;
  - each of these logs one line.

  F takes the lease by the existing path: written under `lease.lock`
  locally, or by the fleet CAS `<M>@<box> -> <F>@<box>`, on the same
  machine. The script waits up to `ROTATE_PROMOTE_WAIT` (240 s) for the
  local lease file to name `<F>@<box>`. On a timeout it removes the hold,
  logs `FAIL promote`, and M keeps acting. F is told `ACTIVE` by the lease
  loop, as on any promotion, and works M's unread inbox. From here on, the
  old M stands by: the lease file no longer names it.
- **FR-024** A hold older than `ROTATE_HOLD_MAX` is ignored by the loops with
  one `WARN` in `lease.log`. A crashed rotation therefore cannot pin the
  lease on F.
- **FR-025** QUIESCE M (FR-011 rule), then HANDOFF for M (section 6). The
  handoff includes the list of messages still unread in M's inbox.
- **FR-026** SPAWN M:
  - the old M's window is renamed (FR-007);
  - a new session starts under the same id (FR-006) with the dispatcher brief
    as its seed. The brief's first step is "read your inbox";
  - the handoff reaches the new M as a spool `task` in its inbox, on task
    `dispatch-rotate-<rid>`, naming the handoff path and the ack command.

  The old M stays alive and idle until the ack. That lets D2 keep it.
- **FR-027** ACK M, within `ROTATE_ACK_TIMEOUT` (600 s), by FR-041. If no
  pid appears, or no ack arrives:
  - the new M is killed and its window closed;
  - the old window gets its name back;
  - the hold is removed, so the old M renews and takes the lease back by the
    existing handback;
  - `FAIL spawn|ack` and an ALERT (FR-075).

  The old M keeps the role (D2).
- **FR-028** RETIRE the old M (FR-015 and FR-016: `/exit-clean`, 300 s,
  TERM, KILL). Then RELEASE:
  - the hold is removed;
  - the new M (the only `CLE-002` process left) renews and takes the lease
    back by the existing handback (fleet-roles 4: "the master's own renewal
    is the handback");
  - F is told `STANDBY`;
  - the script waits up to `ROTATE_PROMOTE_WAIT` for the local lease file to
    name `<M>@<box>`. A timeout = `FAIL release` and an ALERT. F keeps
    acting, so dispatch never stops.
- **FR-029** REFRESH F (owner R2, "re-create the failover too"):
  - once M has held the lease for `ROTATE_SETTLE` (120 s), F is re-created
    when its process age is at least `ROTATE_MIN_AGE`;
  - the steps are FR-011 QUIESCE, a role-only handoff (a standby has no lane
    state), SPAWN, ACK, RETIRE, the same as for M, but without a hold;
  - a failure keeps the old F (D2) and sends an ALERT. M is acting
    throughout, so nothing stops.

  The script the orchestrator's machine runs at `:15` does all of this, with
  no model turn.
- **FR-030** DONE: `rotate.dispatch.last` is written, and a `result` note goes
  to the orchestrator on task `dispatch-rotate-<rid>`.
- **FR-031** No message is lost across the swap:
  - messages to `CLE-002` land in the same inbox throughout;
  - while the hold stands, F works M's unread inbox (the existing promotion
    rule, skipping what M's outbox shows as handled);
  - the new M reads its inbox first, and skips what F's outbox shows as
    handled since the hold.

### 4.4 Seed, ack and handoff delivery

- **FR-040** The seed of a new session is generated, never written by a model:
  1. the role text: `SPEC-spool-fleet-roles.md` section 1 for orch, or the
     dispatcher brief `do_spl_dispatch_setup` renders for master / failover;
  2. the rotation line. For orch it is printed in the seed:
     `You are the new <ID>@<box>, rotated at <rid>. Read <handoff path>, then run <inbox command>, then run <ack command>. Do not greet; post nothing about the rotation.`
     For a dispatcher it arrives as the inbox task of FR-026;
  3. the standing rules: the agent user only, one agent one small task, never spawn
     Grok.
- **FR-041** The ack is the new session running
  `ROTATE_CMD=ack ROTATE_ID=<rid> ./run -a do_spl_<orch|dispatch>_rotate`.
  The action checks that its caller carries `SPOOL_AGENT_ID=<ID>` and is the
  NEW pid. It then sends one `result` message from `<ID>` on task
  `<orch|dispatch>-rotate-<rid>`, so the message lands in `<ID>/outbox`.
  The rotation waits for exactly that outbox message. It does not wait for a
  task to leave the inbox, because F drains M's inbox while acting. An ack
  from the wrong pid, or for an unknown or finished rid, is refused (exit 3)
  and logged. The old session never sees the rid (it is created after
  QUIESCE), so it cannot ack by mistake.
- **FR-042** The inbox command: `./run -a do_spl_orch_inbox` (orch), or
  `spool recv --as <ID>` (dispatchers).
- **FR-043** The seed and the handoff name the old transcript's path only.
  Nothing copies it to another machine or to the hub.

### 4.5 Two machines

- **FR-044** Each machine rotates only its OWN trio, and only a role whose
  fleet lease this machine holds. A standby machine's sessions do almost no
  work, so they are not rotated (`SKIP standby`). A role whose lease returns
  to this machine is rotated at its next slot, if it is old enough.
- **FR-045** Rotation never writes the fleet row across machines. The HOLD
  moves the holder only between `<M>@<box>` and `<F>@<box>` of one machine.
  If the fleet loop flips a role to the other machine mid-rotation, the
  rotation finishes here (the new session just starts as standby) and logs
  `lease-moved`.

### 4.6 Schedule (owner D3)

- **FR-050** Cron, in the box user's crontab, each line ending in an exact
  tag:

  | schedule | action | tag |
  |---|---|---|
  | `5 * * * *` | `do_spl_orch_rotate DRY_RUN=0` | `# csi-spl:orch-rotate` |
  | `15 * * * *` | `do_spl_dispatch_rotate DRY_RUN=0` | `# csi-spl:dispatch-rotate` |

  The installers are `do_spl_orch_rotate_install_cron` and
  `do_spl_dispatch_rotate_install_cron`: `DRY_RUN=1` prints the crontab
  diff, a re-run is idempotent, and `CRON_REMOVE=1` removes the line.
- **FR-051** The two run in sequence. The `:15` run waits for an orch
  rotation that is still in flight (FR-020). The orch ack takes at most
  15 min from `:05`, so in the worst case the dispatch rotation starts at
  about `:20`. Every FAIL and DONE of the dispatch run then reaches the new
  orchestrator.
- **FR-052** No rotation within `ROTATE_BOOT_GRACE` (900 s) of boot, or of a
  session restore (the restore marker), while the panes are still churning.
- **FR-053** The cron lines are installed on every machine. FR-044 turns a
  standby machine's runs into no-ops.

### 4.7 Launch flags (owner R4)

- **FR-060** A rotated session starts with `--permission-mode auto
  --dangerously-skip-permissions` on the default model (the agent user's
  settings). It never uses `--resume`: that keeps the old session's model
  and context, the very thing rotation drops.
- **FR-061** The flags come from ONE helper (`spool_claude_perm_flags` in
  `lib/spool-env.inc.sh`), shared by spawn, restore, chain and rotation.
  `SPAWN_SKIP_PERMISSIONS=0` drops the second flag. Rotation never builds
  its own launch line.
- **FR-062** History and fallback:
  - on 2026-10-01 10:50Z, the lane told to add the flag (CLE-77870) was
    refused by its own permission layer (the auto-mode classifier, reason
    "Create Unsafe Agents"). It committed nothing (blocker to CLE-001);
  - CLE-77939 leaves it out today for the same reason;
  - so agents do NOT add the flag. The fallback is owner-applied: the owner
    makes the FR-061 one-line change, or allows it for one lane;
  - until then the helper prints `--permission-mode auto` only, and rotation
    works unchanged;
  - each implementing lane reports the exact one-line diff to `CLE-001`.
- **FR-063** `do_spl_rotate_status` shows the flags the live role sessions
  actually carry (from `/proc/<pid>/cmdline`), so anyone can see whether R4
  is in force.

### 4.8 Mechanical, observable, alerting

- **FR-070** Every input is a file, a run action or a process table:
  `lease.conf`, the lease files, `/proc`, tmux, the ask book, the lane map,
  hold notes, the spool inbox and outbox, the transcript. No step parses
  model prose to decide anything.
- **FR-071** `./run -a do_spl_rotate_status` prints one row per role:
  - id, pid, process age, pane state (idle / busy / stalled), launch flags;
  - the last `rid`, its phase and result, and when the last `DONE` was;
  - the next slot and the last skip reason;
  - the age of `rotate.hold`;
  - the switches.
- **FR-072** `do_spl_dispatch_check` gains a `rotation` row. It is a GAP when
  all of these hold:
  - a role's last `DONE` is older than 3 h;
  - the switch is on;
  - this machine holds that role's lease.
- **FR-073** The orchestrator hears only about FAILs, stalls (FR-009) and
  DONE results. Every other SKIP is logged and not sent.
- **FR-074** Every timeout and switch is an environment variable with the
  default named here. Any of them may sit in
  `<spool root>/dispatch/rotate.conf`.
- **FR-075** ALERT (owner D2) = two things:
  - an ask in the ask book: `do_spl_ask_put`, kind `blocker`, role `orch`,
    task `<role>-rotate-<rid>`, body `ROTATION FAILED <role> <phase> <reason>; old session kept: <ID>@<box> pid <n>`;
  - a DM to the owner through the asks owner leg (`ASKS_OWNER_CMD`, else
    `ASKS_OWNER` from the holder's desk), sent at once rather than after
    `ASKS_OWNER_MIN`.

  When neither owner setting exists: one `WARN`, and the ask alone.

### 4.9 Rollback

- **FR-090** `<spool root>/dispatch/rotate.conf` with `ROTATE=0` stops every
  rotation on that machine at its first gate. `ROTATE_ORCH=0` or
  `ROTATE_DISPATCH=0` stops one role. No file means on, once the cron lines
  are installed.
- **FR-091** `ROTATE_CMD=abort ./run -a do_spl_<orch|dispatch>_rotate` runs the
  current phase's failure path: the old session is kept, the new one closed,
  and the hold removed. It logs `ABORT`.
- **FR-092** Uninstalling is `CRON_REMOVE=1` on each installer. That removes
  only its own tagged line.

## 5. State machines

### 5.1 Orchestrator

```text
GATE --skip--> exit 0
GATE --> QUIESCE (grace 60 s, Escape, busy-rotated) --> HANDOFF --> SPAWN
SPAWN --no pid 120 s / wrong pane--> RESTORE-OLD --> FAIL spawn + ALERT
SPAWN --> ACK --timeout 900 s--> KILL-NEW --> RESTORE-OLD --> FAIL ack + ALERT
ACK --> RETIRE (/exit-clean, 300 s, TERM, 30 s, KILL) --> CLOSE --> DONE
RETIRE --alive after KILL--> FAIL exit + ALERT (next run: SKIP duplicate)
```

| phase | acting | alive | pokes go to |
|---|---|---|---|
| GATE, QUIESCE, HANDOFF | old (stopped mid-turn by QUIESCE) | old | old |
| SPAWN, ACK | old by lease, but it gets no input | old + new | new |
| RETIRE | new | new + old exiting | new |
| CLOSE, DONE | new | new | new |

### 5.2 Dispatchers

```text
PRECHECK --skip--> exit 0
PRECHECK --> HEAL (spawn a missing M or F; exit)
PRECHECK --> HOLD --F not holder in 240 s--> UNHOLD --> FAIL promote
HOLD --> QUIESCE-M --> HANDOFF --> SPAWN-M --> ACK-M
ACK-M --fail--> KILL-NEW-M, RESTORE-OLD, UNHOLD --> FAIL + ALERT (old M takes the lease back)
ACK-M --> RETIRE-OLD-M --> RELEASE --M not holder in 240 s--> FAIL release + ALERT (F keeps acting)
RELEASE --> SETTLE 120 s --> REFRESH-F (QUIESCE, HANDOFF, SPAWN, ACK, RETIRE) --> DONE
REFRESH-F --fail--> keep old F, ALERT --> DONE
```

| phase | lease holder | M | F |
|---|---|---|---|
| PRECHECK | M | old | old, standby |
| HOLD .. ACK-M | F | old, standing by; new from SPAWN-M | old, ACTIVE |
| RETIRE-OLD-M | F | new | old, ACTIVE |
| RELEASE | F -> M | new, ACTIVE | old, STANDBY |
| REFRESH-F | M | new | old + new, then new |

### 5.3 Failure paths

| failure | orch | dispatch |
|---|---|---|
| the new session fails to start | close new, restore the old name, `FAIL spawn` + ALERT; old keeps the role | the same for M, and UNHOLD, so the old M takes the lease back |
| the new session never acks | `/exit` + kill the new one, restore, ALERT; the old one is told it keeps the role | the same, plus UNHOLD |
| the old session will not exit | `/exit-clean`, 300 s, TERM, KILL; still alive = `FAIL exit` + ALERT, and the duplicate gate refuses next hour | the same; RELEASE waits until the old M's pid is gone |
| lease contention (the role flips to the other machine mid-rotation) | finish here, `lease-moved`; the new session starts as standby | the same; the HOLD only affects this machine's candidate |
| two machines | each rotates only the roles it holds (FR-044) | the same |
| usage-limit stall (CLE-77935) | `SKIP stalled`, one note | `SKIP stalled`; the lease has already gone to F |
| a message arrives mid-rotation | it lands in the same inbox and its poke rings the new window from SPAWN on; the new session reads the inbox before it acks | it lands in M's inbox; F works it under the hold; the new M skips what F's outbox shows handled |
| the script is killed | the `.state` file resumes or fails the phase (FR-003) | the same; a dead hold ages out (FR-024) |
| the hub is unreachable | the local `lease.orch` mirror rules apply (fleet-roles 4.1) | in fleet mode the HOLD CAS cannot land: `FAIL promote`, and M keeps acting |

## 6. The handoff file

Path: `<spool root>/dispatch/handoff/<rid>-<ID>.md`, owned by the agent user,
mode 0640, pruned after 7 days by the next rotation. It is written AFTER
QUIESCE by one shared function, `spl_rotate_handoff ROLE ID RID OUT`. The
sections come in this order, each capped, so a handoff stays around 250
lines:

| # | section | source | cap |
|---|---|---|---|
| 1 | header: `rid`, role, `<ID>@<box>`, old pid and its age, whether QUIESCE interrupted a turn, the transcript path, the lease lines (`lease`, `lease.orch`, the fleet holder) | `/proc`, lease files | 12 lines |
| 2 | **in flight: the last terminal lines** of the old pane, after QUIESCE (`capture-pane -p -J`; memory: tmux hard-wraps, so `-J`) | tmux | 60 lines |
| 3 | open asks of the role, oldest first: id, from, kind, age, state (acked by whom), first 120 chars | `do_spl_asks_open` | 40 rows |
| 4 | the old session's outbox for the last 60 min: ts, to, kind, task, first 160 chars | `<spool root>/<ID>/outbox` | 40 rows |
| 5 | the unread inbox: count, plus the 20 newest (from, kind, task, first 120 chars) | `<spool root>/<ID>/inbox` | 20 rows |
| 6 | live lanes: `<ID>@<box>`, branch, scope, age | `do_spl_lane_map` | 60 rows |
| 7 | hold notes: per `dispatch/hold/<topic>/`, its title line and its `NEXT` lines | files | 20 topics |
| 8 | the session tail: the last 10 user lines and the last 10 assistant text blocks of the old transcript, 300 chars each (`jq` over the jsonl, tool calls skipped) | the transcript | 20 blocks |
| 9 | memory files by name only | the agent user's memory dir | names |

A source that errors prints `UNAVAILABLE: <reason>`, and the rotation goes
on. The handoff is a local file. It is never posted and never sent through
the hub.

## 7. Invariants

| # | invariant | how | test |
|---|---|---|---|
| I1 | never zero acting orchestrators | the old session keeps the role until the new one acks; a failure keeps the old one (D2) | T-ORCH-ACK-TIMEOUT |
| I2 | never two acting orchestrators | QUIESCE stops the old turn; after SPAWN the old one gets no pokes and no input; RETIRE comes right after ACK; the duplicate gate refuses a third | T-ORCH-POKE-ROUTE, T-ORCH-DUP |
| I3 | never zero acting dispatchers | HEAL first; the HOLD gives the lease to F before anything is retired; a failure UNHOLDs to the kept old M | T-DISP-ACK-FAIL |
| I4 | never two masters | one lease file under `lease.lock`; the lease names one holder at every step; old and new M overlap only under the hold, where neither is the holder | T-DISP-ONE-HOLDER |
| I5 | no lost message | same id = same inbox; the ask book outlives sessions; F works M's unread inbox under the hold; the new session reads its inbox before it acks | T-MSG-IN-FLIGHT |
| I6 | no model call needed | the script reads files, `/proc` and tmux only; the one model action is the ack command | T-NO-MODEL |
| I7 | no lease crosses machines because of a rotation | no fleet CAS except the same-machine `M -> F -> M` | T-TWO-MACHINES |
| I8 | the ids never change role | `lease.conf` is never rewritten by a rotation | T-DISP-HAPPY (`lease.conf` sha unchanged) |

## 8. Acceptance

Shell tests go in `csi-spl-orc/src/bash/tests/`, with a stub tmux, a stub
`/proc` and a stub `claude`, following the pattern of `dispatch-lease.tst.sh`
and `fleet-lease.tst.sh`. Each negative test has a control that fails on the
broken shape.

| id | case |
|---|---|
| T-ORCH-HAPPY | orch age 3600 s, idle: every phase to DONE; one pid at the end; the identity map shows the new pid; one log line per phase |
| T-ORCH-BUSY | the old session is busy through the grace: `Escape` is sent, the handoff's section 2 holds the stopped screen, the rotation goes on (D1) |
| T-ORCH-GATES | each gate gives its SKIP: disabled, standby, absent, duplicate, young, stalled (the 2026-10-02 usage-limit footer) |
| T-ORCH-ACK-TIMEOUT | the new session never acks: new killed, old name restored, old pid untouched, ALERT = one ask + one owner DM |
| T-ORCH-SPAWN-FAIL | no new pid: restored, `FAIL spawn`, ALERT |
| T-ORCH-EXIT-HANG | the old one ignores `/exit-clean` for 300 s, then TERM: KILL logged; it ignores KILL (stub): `FAIL exit`, the next run `SKIP duplicate` |
| T-ORCH-POKE-ROUTE | after SPAWN, `spool_pane_of CLE-001` = the new pane, and the retiring name parses as no id |
| T-EXITCLEAN-RETIRING | `tmux-close-window.sh --agent CLE-001 --defer` called from the retiring pane closes the retiring window, never the new one (control: today's code resolves to the new one) |
| T-ORCH-RESUME | the script is killed in each phase: the next run resumes or fails cleanly, and there are never two rotations |
| T-DISP-HAPPY | HOLD -> F holder -> SPAWN-M -> ack -> RETIRE-OLD-M -> RELEASE -> M holder -> REFRESH-F -> DONE; the sha of `lease.conf` is unchanged |
| T-DISP-HEAL | F dead: F spawned, nothing else done |
| T-DISP-ACK-FAIL | the new M never acks: killed, the old M back as holder, ALERT |
| T-DISP-ACK-SOURCE | an ack task drained from M's inbox by F does not count; only the `<ID>/outbox` result on `dispatch-rotate-<rid>` does |
| T-DISP-HOLD-STALE | a hold older than 1800 s is ignored, with one WARN |
| T-DISP-ONE-HOLDER | at every step there is one lease holder, and at most one pid per id outside the hold |
| T-MSG-IN-FLIGHT | 50 messages to the role id spread over every phase: all 50 end up in the inbox or archive, none in an orphan dir |
| T-TWO-MACHINES | two simulated machines on the hub stub: only the holder's machine rotates; no cross-machine CAS |
| T-SEQ | an orch rotation still in ACK: the `:15` run waits, then `SKIP orch-busy` |
| T-ACK-FORGED | an ack from the wrong pid, or for an unknown rid: refused, exit 3 |
| T-CRON | installers: idempotent, tagged, `CRON_REMOVE=1` |
| T-NO-MODEL | a stub claude that only runs the ack line passes every phase |

Live proofs on the home box after landing, run by the implementing lanes
(owner: autonomous). Each one reports the `rid`, the old and new pids and its
`rotate.log` lines:

| id | proof |
|---|---|
| L1 | `DRY_RUN=1` of both actions: the full PLAN, nothing touched (the lease files' mtimes unchanged) |
| L2 | one live orch rotation: `CLE-001@<box>` replaced; a probe ask sent during ACK is answered by the new session; `ps` shows one `CLE-001` process with the new start time and the FR-060 flags (or the FR-062 fallback) |
| L3 | one live dispatch rotation: `lease.log` shows `CLE-002 -> CLE-003 -> CLE-002`; a WUI post during the hold is routed by `CLE-003`, and one after RELEASE by the new `CLE-002`; then F is refreshed |
| L4 | `do_spl_rotate_status` after three cron hours: a `DONE` per role per hour, or a named skip |
| L5 | `ROTATE=0`: the next `:05` and `:15` are `SKIP disabled` |

## 9. Out of scope

- Rotating lane agents: their one small task already caps their life.
- Lease protocol changes beyond the hold (FR-023, FR-024).
- An agent adding `--dangerously-skip-permissions` (FR-062).
- The satellite trio's first seating (CLE-77911, 057).

<!-- last-edit: 2026-10-02T04:40:00Z — CLE-77941 -->
