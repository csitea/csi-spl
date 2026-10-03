# 063: agent context lifecycle (compact, restart, hand over)

Status: **Q1..Q4 APPROVED by the owner** (2026-10-03, t1 `64576223`,
section 8), with two changes: no threshold is hard-coded; every number lives
in a per-workspace DB config table the admin edits (section 11), and every
restart, compact and hand-over is logged so the numbers can be tuned
empirically, in a table used for that only and at most 3 % slower
(section 12). Nothing is built yet; the implementation split is
section 13. Draft 2026-10-03, c-079.
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
  `<ts> <kind> <one line>`, kinds `task|decided|tried|failed|next|waiting`;
  a `failed` line says what was tried, that it failed, and why);
- the handoff copies the last 40 lines into a new section 1b, and EVERY
  `tried` / `failed` line of the task (not only the tail) into section 1c.

Two rules from a-086's review (`csi-spl-doc/doc/md/agy-opinion-b.md`,
`572f4156`), accepted by the orchestrator:

- **Negative knowledge is a required section.** Every hand-over (seat
  rotation, lane restart, hold) carries section 1c "tried and failed". An
  empty one says `none recorded` explicitly, so a reader can tell "nothing
  failed" from "the section was dropped". Reason: the costliest repeat after
  a restart is a dead end tried again.
- **No raw pane scrape.** The distil carries structured git and spool state
  instead of the old pane's last terminal lines (ANSI codes, banners,
  half tool outputs, tmux wraps). This replaces 060 section 6 row 2, whose
  D1 named "the last terminal lines"; the capture stays available as a
  local debug file next to the handoff, never read by the seed.

Template (sections in order; 1b, 1c and 6b are new, 2 is replaced, the
rest is 060 section 6):

| # | section | source | cap |
|---|---|---|---|
| 1 | header: rid, role or task, `<ID>@<box>`, age, context at restart, reason (`clock`, `size`, `fail-compact`) | `/proc`, transcript | 12 lines |
| 1b | **NOTES: the task and its done-criteria, decisions + why, tried and failed, the next step, what it waits on** | `NOTES.md` tail | 40 lines |
| 1c | **tried and failed (required): every `tried`/`failed` line of the task, or `none recorded`** | `NOTES.md` | 30 lines |
| 2 | in flight, structured: `git status --short`, the unpushed commits (`git log origin/master..HEAD --oneline`), the branch; the last spool message sent and received (header + first 160 chars) | git, spool | 40 lines |
| 3 | open asks | `do_spl_asks_open` | 40 rows |
| 4 | the old session's outbox, last 60 min | outbox | 40 rows |
| 5 | unread inbox | inbox | 20 rows |
| 6 | live lanes | `do_spl_lane_map` | 60 rows |
| 6b | **tmux windows: name, pane id, command** | `tmux list-windows -a` | 60 rows |
| 7 | hold notes | hold dir | 20 topics |
| 8 | session tail | transcript | 20 blocks |
| 9 | memory files by name | memory dir | names |

A LANE distil skips sections 3, 6, 6b and 7 (it stays scoped to its own
worktree, branch, commits, NOTES and spool), and adds the brief path.

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

- the restart's SPAWN fails -> what `seat_fail_action` says (section 11):
  `compact` (default) types `/compact` into the old pane (R-L1 alternative
  A, R-R2); `respawn` kills the pane's process and spawns fresh from the
  hold state (a-086's option); either way a note to the orchestrator;
- `/compact` fails too or the pane is wedged -> the orchestrator closes
  the lane and respawns it from the hold dir (section 1.1's hold rule).

## 8. Decisions

The owner, t1 `64576223` (relayed by the dispatcher, posted as `7e6feb05`),
verbatim: *"Q1:yes, q2: yes:q3:yes,q4:ye, BUT have those in a db config
table in the tenant config section for the admin to be able to config and
experiment emoirically. Also some logging for the empirics on that would be
needed"*. So Q1..Q4 are approved as recommended, and every number in them
is a default of the section 11 table, not a constant. Q5 (the build order)
is section 13.

| # | question | recommended (Q1..Q4: approved) |
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
- The wall-clock limit per lane (c-077's practice 11, `agent-token-focus-plan.md`
  section 2.4) is decided in c-077's plan; this spec only carries its
  number as a config key (section 11) so it is tuned in the same place.

## 10. How to re-measure

The counts came from three throwaway Python passes over the jsonl files:
per session, the peak and last context from assistant `usage`, the
`compact_boundary` records and their `compactMetadata`, the agent name and
the typed user lines; per rotated session (seed names a
`dispatch/handoff/` path), the categories of its first 20 tool calls.
Re-running them is a named action to build in section 13 (brief 03,
`do_spl_context_report`), so the numbers carry their own check; once the
section 12 log exists, the same report reads it instead of the jsonl.

## 11. The config table (owner change to Q1..Q4)

One row per workspace (the user-facing word is **workspace**; tenant is the
internal name), in the hub DB, editable by an admin in Workspace settings.
A NULL column means "the default", and the default lives in ONE place, the
hub (`store` constants), so a new key needs no backfill and "reset to
default" is writing NULL, as `tenants.topic_archive_policy` does (rdb 0093).

Table `agent_lifecycle_config`, primary key `tenant_id`, RLS in the 0021
fail-closed NULLIF shape (the `fleet_lanes` 0096 policy pair), plus
`updated_by` (the human id) and `updated_at`:

| column | default | allowed | rule it drives |
|---|---|---|---|
| `lane_restart_ctx_k` | 400 | 100..950 | R-L1: a lane restarts when its context passes N thousand tokens |
| `lane_restarts_before_split` | 2 | 1..5 | R-L2: after N restarts of one task the orchestrator splits it |
| `seat_restart_ctx_k` | 300 | 100..950 | R-R1: a role seat rotates early above N k |
| `seat_max_age_min` | 60 | 15..240 | R-R1: the clock; a seat older than this rotates |
| `seat_compact_after_fails` | 2 | 0..5 | R-R2: compact after N failed rotations in a row (0 = never compact) |
| `seat_compact_min_ctx_k` | 400 | 100..950 | R-R2: ...and only when the seat is above N k |
| `size_check_every_min` | 10 | 5..60 | how often the size check runs (the cron line fires every 5 min; the check skips runs until N is due) |
| `notes_tail_lines` | 40 | 0..200 | R-D1: lines of `NOTES.md` copied into handoff section 1b (0 = section off) |
| `seat_fail_action` | `compact` | `compact`, `respawn` | R-R2 / 7.3: after `seat_compact_after_fails` failures, compact in place, or kill and respawn from the hold state (a-086's option) |
| `lane_restart_wall_min` | 0 (off) | 0, 10..240 | restart a lane after N min of wall time, independent of context (a-086's option: 30) |
| `lane_checkpoint_min` | 0 (off) | 0, 10..240 | c-077 practice 11: at N min of wall time a lane lands what is green and posts one status line; off until c-077's plan is decided |

- `lane_checkpoint_min` is c-077's limit, owned here as a number only:
  c-077 measured (`agent-token-focus-plan.md` section 2.4, tree
  `3f9c9dff`, n=50 lanes, 24 h) lane wall time from spawn to last result
  median 73 min, p90 191 min, 41 of 50 lanes over 30 min. Wall time
  includes CI waits, so it is a time limit, not a context one; the
  context rules above stay the trigger for restarts.
- a-086's dissent (`agy-opinion-b.md`) is two settings, not defaults: a
  stricter lane restart is `lane_restart_ctx_k = 200` plus
  `lane_restart_wall_min = 30`, and "never type /compact into a wedged
  pane" is `seat_fail_action = respawn`. The defaults stay the approved
  Q1..Q3 values; the admin can switch per workspace and section 12 shows
  the effect. Measured cost of the 200k option: 58 of 130 lanes crossed
  200k (section 4).
- Validation: the CHECK on each column = the "allowed" range, and the hub
  refuses a PATCH outside it with 400 and the key name. One Go table of
  `{key, default, min, max}` is the source for the hub; its test pins the
  rdb CHECKs to it (the way `ArchivePolicy*` pins rdb 0093).
- Who edits: the `tenant.settings` permission, the one the Agents section
  already gates on.
- Every change is an event in the section 12 log (`config_change`, old and
  new value), so an experiment has a start time.
- Who reads it: the box harness, through the authenticated box hello (the
  `spool lane` path, `writer_box` audit), never through a human session.
  It caches the answer for 10 min in its state dir and, when the hub is
  unreachable, uses the cached copy, then the built-in defaults. A rotation
  is never blocked by a config read.

## 12. The log for the empirics

Second owner requirement (t1 `64576223`, after `a2f9a949`), verbatim:
*"Lets enable our internal gathering into dedicated for this purpose only
lodding table. Note logging must not decrease performance more than 3%"*.

- **Dedicated:** `agent_lifecycle_events` holds the restart, compact and
  hand-over empirics and NOTHING else. No other feature writes or reads
  it; these events never go into `human_events`, `flow_events`, a general
  log or the message tables.
- **Budget: at most 3 % slower**, measured, not argued (section 12.1).

Table `agent_lifecycle_events` (RLS as above, append-only, pruned after
90 days by the hub's existing sweep), one row per event:

| column | meaning |
|---|---|
| `at`, `tenant_id`, `fleet`, `agent_id`, `agent_box`, `writer_box` | who and when (`writer_box` from the hello, as in 0096) |
| `role` | `lane`, `orch`, `master`, `failover` |
| `event` | `restart`, `rotate`, `rotate_fail`, `compact`, `handoff`, `settled`, `session_end`, `checkpoint`, `split`, `config_change` |
| `reason` | `size`, `clock`, `fail-compact`, `done`, `checkpoint`, `manual` |
| `rid` | the rotation or restart id; links `rotate` -> `handoff` -> `settled` |
| `ctx_before_k`, `ctx_after_k` | context before (last turn of the old session, or compact `preTokens`) and after (first turn of the new one, or `postTokens`) |
| `age_s`, `turns`, `tokens_read_m` | the old session's age, its turns, and the tokens it re-read (millions) |
| `handoff_lines`, `handoff_bytes`, `notes_lines` | the size of the distil |
| `refetch` | the new session's re-fetches in its first 20 tool calls (the 3.3 categories), e.g. `{"lane_map":1,"old_transcript":0}` |
| `config` | the section 11 values in force at that moment (small json) |
| `outcome`, `detail` | `ok` / `fail`, and at most 200 chars (a step name, never a message body) |

Where each row comes from: the rotate and restart actions write `rotate`,
`rotate_fail`, `handoff`, `restart`, `compact`; the size check writes
`settled` (it sees the new session's first turn) and `session_end` (a
transcript whose process has gone: peak context, turns, tokens read,
compactions from `compact_boundary`); the hub writes `config_change`. A
failed write goes to a local `<state>/lifecycle-events.jsonl` and is resent
on the next run, so a hub outage loses nothing and never blocks a step.

### 12.1 The 3 % budget

The rows are rare (section 3: ~170 sessions and ~70 rotations a day, so a
few thousand rows a day at most), so the budget is spent by WHERE a write
happens, not by how many. Rules:

- No event is written on a hot path: never inside a message send, a hello
  or a WUI view read. The box writes its events off the step that caused
  them (fire and forget, the local jsonl spool on failure), and a rotation
  or restart step never waits on the hub. `LIFECYCLE_EVENTS=0` switches
  every writer off (the A arm, and the rollback).
- The hub appends with one single-row INSERT, no trigger, one index; the
  admin view's aggregates are computed on read, only by that view.
- Each implementing lane measures before and after, n >= 5 per arm,
  interleaved A/B, and fails its own gate above 3 %:

| lane | benchmark | arm A / arm B | pass |
|---|---|---|---|
| hub (brief 01) | `go test -bench BenchmarkOnSend -count 5` with `benchstat`, plus `do_spl_hub_route_latency` p50/p95 on dev for the send and view routes | events table + writer absent / present and writing at 10x the measured rate | each median within 3 % |
| harness (brief 03) | wall time of `do_spl_orch_rotate DRY_RUN=1` and of one `do_spl_seat_size_check` pass, 5 timed runs each | `LIFECYCLE_EVENTS=0` / on | median within 3 %, and one size-check pass under 3 % of its interval |
| lane restart (brief 05) | wall time of `do_spl_lane_restart DRY_RUN=1`, 5 timed runs | `LIFECYCLE_EVENTS=0` / on | median within 3 % |
| handoff (brief 04) | wall time of `spl_rotate_handoff`, 5 timed runs | before / after 1b + 6b | median within 3 % |
| WUI (brief 02) | the perf harness on the `/tenant-settings` routes other than Context lifecycle | before / after | within 3 %; the new block loads lazily |

Each lane posts both arms, n and its tree in its result.

How the admin reads it: Workspace settings -> Agents -> **Context
lifecycle**: the editable numbers of section 11 (each with "reset to
default"), then, per role, for the last 24 h / 7 days: count per event,
median and p90 `ctx_before_k` and `ctx_after_k`, failed rotations, mean
re-fetches, and the 50 newest events. The question it answers: "after I
changed a number, did peak context, failed rotations and re-fetches move?"
On the box, `do_spl_context_report` prints the same aggregates.

## 13. Implementation split

Five small briefs, under `/var/tmp/claude/briefs/ctx-063/`, each with its
own files; c-001 runs them. 01, 04 and 05 can start at once; 02 needs 01's
API shape (it can build on a mock first); 03 can land first on built-in
defaults and switch to the hub read when 01 is live.

| brief | builds | files (only) |
|---|---|---|
| `01-hub-config-and-log.md` | rdb: the two tables; store: get/patch config, append/list/aggregate events (memory + Postgres); hub: `GET/PATCH /v1/tenant/agent-lifecycle`, `GET /v1/tenant/agent-lifecycle/events`, the box read and write; `spool lifecycle` CLI | `csi-spl-rdb/.../spool-hub/<next>_agent_lifecycle.sql`, new `internal/store/agent_lifecycle*.go`, new `internal/hub/agent_lifecycle*.go`, one route-registration line, new `cmd/spool/lifecycle.go` + its case in `main.go` |
| `02-wui-context-lifecycle.md` | Workspace settings -> Agents -> Context lifecycle: the form and the event aggregates | new `ContextLifecycle*.vue`, new `utils/agent-lifecycle.mjs` (+ mock), one mount in `pages/tenant-settings/agents.vue`, catalogue keys |
| `03-harness-config-and-events.md` | `do_spl_lifecycle_config` (read, cache, fallback), `do_spl_lifecycle_event` (write, local spool, resend), `do_spl_seat_size_check` + its `_install_cron`, `do_spl_context_report`; event calls in the 060 rotate steps | new orc `run/spl-lifecycle-*.func.sh`, `spl-seat-size-check*.func.sh`, `spl-context-report.func.sh` + tests; event-call lines in `spl-rotate-lib.func.sh` (not `spl_rotate_handoff`) |
| `04-handoff-notes-and-windows.md` | R-D1: the `NOTES.md` convention in the seed, handoff sections 1b and 6b | `spl_rotate_handoff` in `spl-rotate-lib.func.sh`, the seed text in `spawn-core.inc.sh`, their tests |
| `05-lane-restart.md` | R-L1 / R-L2: `do_spl_lane_restart` (distil to hold, respawn in the same window as the agent user, never `--resume`) | new `run/spl-lane-restart.func.sh` + test |

03 and 04 both touch `spl-rotate-lib.func.sh`, in disjoint functions; 04
goes after 03 is on trunk.
