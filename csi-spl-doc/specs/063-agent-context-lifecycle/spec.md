# 063: agent context lifecycle (compact, restart, hand over)

Status: **DRAFT, for the owner's decision** (2026-10-03, c-079). Nothing
here is built. Every rule below is a recommendation with its measured
reason and the alternative; the owner picks (section 8).
Related: [060 hourly role rotation](../060-role-rotation/spec.md) (the
handoff file, section 6), [SPEC-spool-fleet-roles.md section 1.1](../../doc/md/SPEC-spool-fleet-roles.md)
(one agent, one small task). Token minimisation per turn is measured
separately (c-077) and is out of scope here.

## 1. What the owner asked (t1 topic `64576223`, verbatim)

> "Opinions needed for specs, how often to do /compact, to start new
> agents, to distil essentials and self restart?!"

## 2. Words

| word | meaning |
|---|---|
| **context** | the tokens one turn re-reads: `input + cache_read + cache_creation` of an assistant turn's `usage` |
| **lane** | an agent spawned for one small task, in its own worktree |
| **role seat** | the orchestrator and the two dispatchers (ids 001..003 per box) |
| **compact** | Claude Code's `/compact` (manual) or its auto-compaction: the same process goes on with a model-written summary in place of its history |
| **restart** | a NEW Claude Code process in the same tmux window, never `--resume`, seeded from a distil |
| **distil** | the file the restart reads first (section 6) |

## 3. What was measured

Source: the agent user's transcripts, `~/.claude/projects/*/<sid>.jsonl`
with an mtime in the 24 h before 2026-10-03T02:45Z (169 sessions with at
least one turn), plus `<spool root>/dispatch/rotate.log` and
`<spool root>/dispatch/handoff/`. Counts and file names only; no message
content went into this spec. Tree: trunk at `81a5db82`. A session is
classified by its agent name (`(c|CLE)-00[1-3]` = role seat; otherwise a
lane when its cwd is a worktree; 5 sessions fit neither and are left out).
How to re-run: section 10.

### 3.1 How big contexts got

| | n sessions | median peak context | p90 | max | > 400k | > 600k | compactions |
|---|---|---|---|---|---|---|---|
| lanes | 130 | 191k | 354k | 630k (`CLE-77915`) | 11 | 2 | **0** |
| role seats | 34 | 185k | 374k | 967k (`CLE-002` `2343912f`) | 3 | 2 | **1** |

- The one compaction in 24 h was AUTOMATIC: `CLE-002` session `2343912f`,
  8.2 h on one process, `preTokens 967 154 -> postTokens 7 141`. It kept
  0.7 % of its context. No session ran `/compact` by hand.
- Both role sessions over 800k (`2343912f` 967k, `CLE-001` `b97f92e5`
  818k) started before rotation was live (060 went in 2026-10-02 ~05Z).
- Tokens re-read over the 24 h, all turns: lanes 4 588 M over 22 514 turns
  (mean 204k per turn), role seats 1 686 M over 7 352 turns (229k). Of the
  role seats' tokens, **31 % were context above 200k and 20 % above 300k**;
  for lanes 20 % and 7 %.

### 3.2 Role seats under 060 (n = 31 rotated sessions)

| | fresh session's first context | context at end of its hour (median) | range |
|---|---|---|---|
| orchestrator (n=15) | 57k..60k | 213k | 107k..286k, one outlier 565k |
| dispatchers (n=16) | 72k..75k | 124k | 96k..366k |

- The fresh floor (59k orch, 74k dispatcher) is paid by every rotation
  before any work. Rotating much more often than hourly buys little.
- rotate.log, same 24 h: orch 15 DONE, 2 FAIL, 6 GATE SKIP; master
  8 DONE, 3 FAIL, 2 GATE SKIP; failover 1 DONE. The 5 FAILs were 3 SPAWN
  and 2 HOLD (`SPAWN: no claude carrying CLE-001 started in %466 within
  120s; the old session ... keeps the role`).
- The cost of a FAIL: the 14:05Z orch session `e7590e09` was kept by the
  15:05Z and 16:05Z FAILs (060 D2: keep the old session), lived **8.0 h**
  and reached **565k**, twice any rotated hour. The clock alone has no
  answer for "the rotation failed and the seat keeps growing".

### 3.3 What the 060 handoff loses (n = 31)

Handoffs: 34 files, 18..40 KB, 201..282 lines, an `UNAVAILABLE` section
in 2 of 34. In each rotated session's FIRST 20 tool calls (which also
hold real work, so these are upper bounds):

| re-fetched | sessions | already in the handoff? |
|---|---|---|
| tmux window list | 15 / 31 | **no** |
| open asks (`do_spl_ask*`) | 10 / 31 | yes, section 3 |
| the OLD transcript (`*.jsonl`) | **6 / 31** | only its tail, section 8 |
| lane map | 4 / 31 | yes, section 6 |
| another pane's screen | 2 / 31 | own pane only, section 2 |

Reading: the mechanical sections are mostly trusted (the lane map was
re-run in 4/31). What is missing is the WHY: 6 of 31 new sessions went
back into the old transcript, the expensive move, because the handoff holds
the last lines but not the decisions, the plan in progress, or what was
already tried.

### 3.4 Lanes and "one task"

- 0 of 130 lanes received a second brief (a second seed line).
- 17 of 130 lanes saw two or more distinct task ids in their typed lines.
  An upper bound: a seed that names a related task counts too.
- 10 of 130 lanes lived more than 4 h; 15 had more than 10 typed lines.
- Lane life is short: median 1.1 h, p90 3.1 h. 119 of 130 lanes peaked
  below 400k, without any compaction.

## 4. Lanes: compact, or exit and be replaced

**R-L1 (recommended) A lane never compacts. It exits on task done
(section 1.1, unchanged), and at a context of 400k it restarts.**

At 400k the lane lands everything green (the push rule), writes the
distil (section 6) into its hold dir, and is replaced by a fresh process
seeded from that distil: same id, same worktree (section 7.2).

- Measured reason: 0 lane compactions in 24 h and a median lane peak of
  191k, so the rule fires rarely (11 of 130 lanes crossed 400k). A lane
  that crosses it is usually over-scoped (`CLE-77911` 10.4 h, `CLE-77930`
  34 typed lines). Auto-compaction only starts near 967k and keeps 0.7 %
  of the context, chosen by the model and audited by nobody.
- Why 400k and not 200k: 58 of 130 lanes crossed 200k doing ordinary
  one-task work; a 200k trigger would restart nearly half the fleet, each
  restart paying a fresh floor plus re-orientation.
- Alternative A: manual `/compact <focus>` at 400k. Cheaper (no new
  process, no spawn failure), but the summary is model-written and
  invisible to the orchestrator. Recommended only as the fallback when a
  restart fails (section 7.3).
- Alternative B: no trigger, rely on auto-compaction. Rejected: nothing
  stops a 900k lane, and every turn above 400k costs twice a median turn.

**R-L2 A lane that crosses 400k tells the orchestrator** (kind note, its
context and age). Two restarts of the same task mean the brief was too
big: the orchestrator splits it instead of allowing a third.

## 5. Role seats: when to self-restart

**R-R1 (recommended) Keep 060's hourly clock as the MAXIMUM age, and add
a size trigger: rotate early when the seat's context passes 300k.**

- Measured reason: rotated hours end at 213k (orch) and 124k (dispatcher)
  median, so 300k fires only on a heavy hour (orch 0 of 14 normal hours
  plus the 565k failed-rotation session; dispatchers 2 of 16). It targets
  the 20 % of role-seat tokens that were context above 300k.
- It closes the gap from 3.2: after a FAIL the size trigger retries at
  300k instead of waiting for the next `:05` while the seat grows.
- How: a check every 10 min (one more cron line) reads the seat
  transcript's last `usage` and calls the existing `do_spl_orch_rotate` /
  `do_spl_dispatch_rotate` with `ROTATE_REASON=size`. One rotation path,
  no new mechanics.
- Alternative A: size only, no clock. Rejected: dispatchers rarely reach
  200k in an hour, so a size-only seat would run for many hours on one
  process, which is what 060 was written to stop (9.5 h sessions, two
  logins spent).
- Alternative B: clock only (today). Simple, but a failed rotation leaves
  the seat unbounded (565k at 8 h).
- Alternative C: rotate every 30 min. Rejected: each rotation pays a
  59k..74k floor and a 1..5 min gap; the measured hour-end sizes do not
  justify it.

**R-R2 After two failed rotations in a row, compact instead.** When a seat
is over 400k and its last two rotations FAILed, the script sends
`/compact keep: open asks, live lanes, in-flight topic` into the seat's
pane. The only place a role seat compacts. Alternative: the ask-book alert
only (060 D2 today); the seat then grows until a human acts.

## 6. "Distil the essentials": the template

**R-D1 (recommended) The distil = the 060 handoff (mechanical, unchanged)
+ two additions: a running NOTES file the agent keeps, and the tmux window
list.**

060's R5 is "mechanical, not decision-making tokens", and its D1 rotates a
busy seat mid-task, so the old session cannot be asked to write a summary
at the moment of rotation. The why has to be written AS THE AGENT GOES,
cheaply, and picked up mechanically:

- every agent appends one line to `<state>/<ID>/NOTES.md` when it decides
  something, starts a sub-step, or abandons an approach (append-only,
  `<ts> <kind> <one line>`, kinds `task|decided|tried|next|waiting`);
- the handoff copies the last 40 lines into a new section 1b.

Template (sections in order; 1b and 6b are new, the rest is 060 section 6):

| # | section | source | cap |
|---|---|---|---|
| 1 | header: rid, role or task, `<ID>@<box>`, age, context at restart, reason (`clock`, `size`, `fail-compact`) | `/proc`, transcript | 12 lines |
| 1b | **NOTES: the task and its done-criteria, decisions + why, tried and failed, the next step, what it waits on** | `NOTES.md` tail | 40 lines |
| 2 | in flight: the old pane's last terminal lines | tmux | 60 lines |
| 3 | open asks | `do_spl_asks_open` | 40 rows |
| 4 | the old session's outbox, last 60 min | outbox | 40 rows |
| 5 | unread inbox | inbox | 20 rows |
| 6 | live lanes | `do_spl_lane_map` | 60 rows |
| 6b | **tmux windows: name, pane id, command** | `tmux list-windows -a` | 60 rows |
| 7 | hold notes | hold dir | 20 topics |
| 8 | session tail | transcript | 20 blocks |
| 9 | memory files by name | memory dir | names |

A LANE distil skips sections 3, 6, 6b and 7, and adds two: the branch with
its unpushed commits (`git log origin/master..HEAD --oneline`), and the
brief path.

- Measured reason: 6/31 new seats went back into the old transcript and
  15/31 listed the tmux windows in their first 20 calls (3.3); 1b and 6b
  answer exactly those. The lane map (4/31) shows the mechanical sections
  are trusted, so they stay.
- Alternative: a model-written summary at rotation time ("write your
  handoff, then exit"). Richer, but it costs a turn on a 200k+ context,
  cannot run when the session is busy (D1) or wedged (the case that most
  needs it), and breaks R5.

**R-D2 The distil holds no secret and no message body beyond the 060
caps**, stays a local file (mode 0640), and is pruned after 7 days, as the
060 handoff is.

## 7. Self-restart mechanics

### 7.1 Role seats

Unchanged from 060 (QUIESCE -> HANDOFF -> SPAWN -> ACK -> RETIRE), with
`ROTATE_REASON` added to the rotate.log line and the handoff header. The
size check is a new named action plus its test (owner rule: nothing ad
hoc), e.g. `do_spl_seat_size_check`, installed by its own
`_install_cron`.

### 7.2 Lanes (new, proposed)

A named action, e.g. `do_spl_lane_restart ID=<lane>`:

1. the lane, at its 400k check, lands what is green and runs the action on
   itself (or the orchestrator runs it);
2. the action writes the lane distil to `dispatch/hold/<task>/<ID>.md`;
3. it starts a fresh process as the agent user in the SAME tmux window
   (`respawn-pane -k`), never `--resume`, seeded with
   `Read <distil path>, then continue the task`;
4. it runs the standing check that no agent process belongs to the
   human's own login, and logs one line per step, as rotate.log does.

The lane keeps its id, worktree and branch; only the process is new.

### 7.3 Fallbacks

- the restart's SPAWN fails -> a manual `/compact` into the old pane
  (R-L1 alternative A, R-R2), plus a note to the orchestrator;
- `/compact` fails too or the pane is wedged -> the orchestrator closes
  the lane and respawns it from the hold dir (section 1.1's hold rule).

## 8. Decisions for the owner

| # | question | recommended |
|---|---|---|
| Q1 | lanes: restart at 400k (R-L1), `/compact` at 400k, or nothing? | restart at 400k |
| Q2 | role seats: hourly clock + 300k size trigger (R-R1), size only, or clock only? | clock + 300k |
| Q3 | after two failed rotations: compact the seat (R-R2), or alert only? | compact |
| Q4 | the distil: 060 handoff + agent-kept NOTES + tmux list (R-D1), or a model-written summary at exit? | handoff + NOTES |
| Q5 | build order once approved: (1) seat size check, (2) NOTES section, (3) lane restart | as listed |

## 9. Out of scope

- How to spend fewer tokens per turn (c-077's measurement).
- Changing the 060 rotation steps; this spec only adds a trigger, a reason
  field and two handoff sections.
- Any harness script: nothing is built until Q1..Q5 are answered.

## 10. How to re-measure

The counts came from three throwaway Python passes over the jsonl files:
per session, the peak and last context from assistant `usage`, the
`compact_boundary` records and their `compactMetadata`, the agent name and
the typed user lines; per rotated session (seed names a
`dispatch/handoff/` path), the categories of its first 20 tool calls.
Re-running them is a named action to build with Q5 step 1 (e.g.
`do_spl_context_report`), so the numbers carry their own check.
