# 102 Agent lifetime: 1 h rebirth, 2 h hard end, one restart path, generic stuck detection

Status: **v1.2, owner decision, 2026-10-07.** Amendment for no separate keeper;
cron starter in source; watchdog setup doc (HUM-10 msgs `a606118a`, `25731cc9`,
`575c9d19`). v1.0 consensus in 15.1..15.4; v1.1 consensus in 15.5; v1.2 owner
decision in 15.6. Spec only: no code, cron, table, setting or seat was touched
by this lane. Build: [tasks.md](tasks.md). Topic: t1 `637269bb-d97b-4861-b45e-87200652b169`
(HUM-10). Dispatcher and topic owner: c-002. Author: a-497 (v1.2 amendment; v1.1 author
a-487; v1.0 author c-471).
Extends: [060 role rotation](../060-role-rotation/spec.md) (handoff, fresh
session under the same id, ack), [093 agent watchdog](../093-agent-watchdog/spec.md)
(heartbeat, situations S1..S8, takeover 8; replaced in 102 v1.2 by crontab starter + watchdog self-supervision),
[063 agent context lifecycle](../063-agent-context-lifecycle/spec.md) (lane
restart, the per-workspace numbers table), [101 four orchestrator-dispatchers](../101-four-orchestrator-dispatchers/spec.md),
[SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md).

`<pc box>` and `<box B>` stand for box tags (box tags are banned literals in
this tree, as in specs 064, 068, 093 and 101). "Machine" in the owner's
answers is a box. Paths: `orc/` = `csi-spl-orc/src/bash/`.

## 0. What the owner asked (HUM-10, t1 637269bb, verbatim where the owner wrote words)

### 0.1 The order

> 26db0bb6: "There should not be a box running more than 2h at once ..."
> (c-002 read "box" as "agent", from the box page's agent list the owner
> pasted next, 57bc53b8: "c-002 Claude Online 2d / c-003 Claude Online 2d /
> c-101 Claude Online 21h")
>
> 9596fee0: "so the watch dog should take care of this as well .."
>
> 9bc777da: "and each agent WHEN is instantiated , MUST Know that it's life
> time is max 2h ... aka it shoud be "reborn" on the 1h and if this does not
> succeed than from the 1h till the 2nd hour it should attempt to do that
> "proper dying " and if even this one does not succeed the watch dog will
> kill it"
>
> 0900d5ec: "now build a proper discussion around these constraints with agy
> - 2 agents and claude 2 agents"
>
> 56e95fbe: "reach a consensus and than based on it start with the
> implementation"
>
> 83cc2671: "now ask me any questions if anything on this topic is unclear
> first before going to work"
>
> 0749893d (on "who starts the next session"): "the watchdog starts it !!!"
>
> 14f0ff9e: "you probably need to ask me more questions though"; 3ffbec3e:
> "so ask me now"
>
> 42a90ada (in t1 0de14fdf): "do you have more questions ?! or can you get t
> owork"

And the required part from t1 `f9112852` (the stuck-dialog incident):

> f7352f5e: "we must find a generic solution which takes also this aspect
> into consideration"

### 0.2 The answers (letter choices to the dispatchers' questions)

The owner answered by number and letter. The question texts are in
`/var/spool-hub/dispatch/c-003-637269bb-q1.md` (round A),
`c-003-637269bb-q2.md` (round H), `c-002-637269bb-q3.md` (round W) and
`c-002-637269bb-q4.md` (round R); the dispatcher's reading of each answer is
`spec102-owner-answers.md`. Every answer gets an id here, and section 14
traces each id to the section that implements it.

| id | msg | question | answer |
|---|---|---|---|
| A1 | 86fd48f9 | does the clock reset at rebirth | the 2 h is **per session**; a reborn agent gets a new 2 h |
| A2 | 86fd48f9 | seats and watchers too | **every agent**, seats and watchers included, learns at start how long it lives and how to hand over |
| A3 | 86fd48f9 | unfinished work at the kill | push the **wip branch** and report it; **no new lane** |
| A4 | 86fd48f9 | the agents over 2 h today | closed **only once the watchdog rule is live** |
| A5 | 86fd48f9 | panel | 2 agy + 2 claude, no grok |
| H1 | 0749893d | what the handoff holds | the brief, what is done (shas, pushed or not), what is in flight, the next step, open questions and who has them, the topics it owns |
| H2 | 0749893d | who writes it | **both**: the script always, the agent adds notes when it can |
| H3 | 0749893d | when | **continuously**, after every step, so even a kill leaves a usable one |
| H4 | 0749893d | where | the agent's **own spool folder**, not git |
| H5 | 0749893d | who starts the next session | **the watchdog** ("!!!") |
| H6 | 0749893d | lessons learned | yes, to the **shared memory** too |
| W1 | e227e1f5 | who stops the session at 2 h | **both**: the agent knows its end time, writes its handoff and exits by itself; the watchdog stops it at 2 h if it has not, and starts the new session |
| W2 | e227e1f5 | one path for rebirth and crash | **yes**, the same restart; only the handoff's freshness differs |
| W3 | e227e1f5 | restart limit | a planned rebirth **counts**; **3 per agent per hour**, set by an admin only; login screens still get no restart |
| W4 | e227e1f5 | lanes too | **yes**: same id, worktree and branch, from the pushed wip branch |
| W5 | e227e1f5 | telling people | **silent**: the handoff file and one line to the orchestrator |
| W6 | e227e1f5 | out of quota | **tell the admin and wait**: the admin resets the login or says no tokens are left; no switch to another login or harness |
| W7 | e227e1f5 | machine down or reboot | **both, coordinated**: after a reboot the box's own watchdog brings its agents back; while a box is down, another box's watchdog restarts them there from a copy of their handoff |
| R0 | 1aef1edf | 1 h or 2 h | **(a)** the 1 h rebirth stays, 2 h is the hard end |
| R1 | 1aef1edf | warning before 2 h | **(a)** at 1 h 50 no new work, final handoff; the watchdog stops it at 2 h |
| R2 | 1aef1edf | busy at 2 h | **(b)** stops at 2 h sharp, whatever is running |
| R3 | 1aef1edf | a person typing in the window | **(b)** the 2 h end applies anyway |
| R4 | 1aef1edf | restart limit reached | **(b)** it stops and only tells the admin |
| R5 | 1aef1edf | when a box is down | **(c)** an admin setting, **default 2 min** |
| R6 | 1aef1edf | the box comes back | **(b)** its agents move back home at their next rebirth |
| R7 | 1aef1edf | the handoff copy | **(a)** in the hub, next to the agent's record, encrypted |
| R8 | 1aef1edf | the admin | **yes** to all three: the workspace settings page; a web app message plus an email; a "login reset" button |
| R9 | 1aef1edf | shared memory | **(a)** one shared memory in the hub, merged, scoped to **how to work in the spool hub**; what to do, and its context, come from the web app |
| R10 | 1aef1edf | which setting applies | **(a)** one fleet-wide setting in the operator workspace; each cloud instance has its own |
| R11 | (dispatcher) | the always-on seats | **(a), the dispatcher's reading, the owner may still flip it**: the seats move to the same path as every other agent (from W2 "one restart path" and 42a90ada "get to work") |
| R12 | 1aef1edf | a task that never ends | **(a)** configurable, **default 7 rebirths**, then wip push, report, stop for the owner |
| R13 | 1aef1edf | when an agent counts as stuck | **(b)** an admin setting, **default 10 min** |
| R14 | 1aef1edf | CLI updates | **(b)** nightly, one box at a time, a test agent first; after an update the settings are checked against the launch flags, and the most permissive mode is ensured: `--dangerously-skip-permissions` plus auto-approve |
| G1 | f7352f5e (t1 f9112852) | the stuck dialog | detect ANY stuck agent without a list of dialog texts; a known dialog gets the fleet's answer (bypass); an unknown one sends the pane to the orchestrator and triggers a rebirth; re-check settings vs launch flags after every CLI update; controlled updates; a fixture control |

R1..R14 were posted by mistake in t1 `0de14fdf` and recorded in 637269bb as
msg `ad749994`. Where round R differs from round W, **R wins** (the brief).

### 0.3 Watchdog redundancy and self-update (round WD, HUM-10 msgs c38146c2, 5684a64c, be5fcf4b)

Following the implementation of T004 and T005, the owner identified that the watchdog itself was a single point of failure and did not track code updates:

> c38146c2: "mm we must take also the update of the watchdog into consideration and the fact that it cannot be a single point of failure neither - aka they have to be 2 or more watchdogs running at the same itme"
>
> 5684a64c: "this might be too much for a change of th requirements , so ask me some more questions if needed"

Dispatcher c-002 proposed options in blocker msg `fac7bf7d-af3e-4316-8769-fa7510564d73` (`/var/spool-hub/dispatch/c002-637269bb-wd-spof.md`), answered by the owner in msg `be5fcf4b-f162-4c36-8af1-e635eb037a7f`:

| id | msg | question | proposal | owner answer, verbatim | decision |
|---|---|---|---|---|---|
| WD1 | be5fcf4b | where the 2+ watchdogs run | 2 on every box; each box checks the other boxes' watchdogs are alive (does not act on their agents) | "Actually let's make them 3 per box - so 3 on <pc box> and 3 on <box B> - running as daemon" | **3 per box, as daemons**; cross-box liveness check stays |
| WD2 | be5fcf4b | all active or active/standby | both active; T003 per-agent id lock makes only one act | "All 3 active" | **all 3 active**, T003 id lock arbitrates |
| WD3 | be5fcf4b | updates | restart automatically one at a time, next only after the previous is back and checked once; within 2 min of code arriving | "Yes restart them." | **rolling restart within 2 min**, sequential verification |
| WD4 | be5fcf4b | hung watchdog | another restarts it after 3 missed checks | "yes" | **peer restarts hung after 3 missed checks**, dead at once |
| WD5 | be5fcf4b | admin alert | only when a watchdog cannot be brought back within 5 min, or both on one box are down at once | "YES" | **admin alert** if not back within 5 min, or simultaneous failure (safe default: 2 of 3 down, Q12) |

## 1. Why: what the fleet looked like, and why the guards missed it

| fact | check |
|---|---|
| about 30 agents were over 2 h on 2026-10-07 04:56Z, the oldest 3 days (c-097..c-102, q-100, q-101); c-101 had run 21 h | c-002@sat's task in topic 637269bb, 04:56:05Z (`spool tail --task 637269bb-...`) |
| the box page's "Online 2d" for c-002 / c-003 was the id's first registry row, not the session: both rotate hourly | same message |
| nothing ends a lane by age today: 063's wall-clock restart is off by default | `grep -n lane_restart_wall_min csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` -> `Default: 0 ... ZeroOff: true` |
| the 2026-10-06 stuck dialog: a Claude Code self-update left the settings on auto while agents started with bypass, and the "Make auto mode your default?" dialog froze six seats for hours. S7 caught it only after the dialog was added to its list | `/var/spool-hub/dispatch/c-003-f9112852-generic.md`; `sed -n 1,9p orc/features/watchdog/situations/s7.sh` (modal=2 is that one dialog, by its words) |
| the CLI updates itself in place, and a box runs mixed versions | as the agent user: `ls ~/.local/share/claude/versions` -> 2.1.289 (10-04 02:10Z), 2.1.290 (10-06 02:33Z), 2.1.291 (10-06 06:56Z), 2.1.292 (10-06 22:10Z); `readlink /proc/<pid>/exe` over the live claude processes -> 12 on 2.1.292, 1 on 2.1.289 (2026-10-07, n = 13) |
| the single launch-flag helper of 060 FR-061 is gone: `spl-lane-restart` still asks for it and falls back to a literal | `grep -rn 'spool_claude_perm_flags()' orc/` -> 0 definitions; `orc/run/spl-lane-restart.func.sh:222` -> 1 caller with a fallback |
| four actors start or stop agents today, under three different locks or none (claude-2 R-a, R-b) | `grep -c 'restart\.lock' orc/run/spl-lane-restart.func.sh` -> 0; the orch and dispatch rotations hold `rotate.orch.lock` / `rotate.dispatch.lock`; the takeover holds `peer/restart.lock` (`orc/run/spl-wd-takeover.func.sh:78`) |
| ids are unique only as `<id>@<box>` (spec 061) | `grep -n 'PRIMARY KEY' csi-spl-rdb/src/sql/postgres/spool-hub/0102_agent_at_box_key.sql` -> `(tenant_id, fleet, agent_id, agent_box)` |

**Lesson, the core of this spec:** a list of known bad screens cannot catch
the next one. Stuck must be defined by what is ABSENT (progress, input
reaching the model), not by what text is present (section 8). And one
restart path means one lock that every actor takes (4.2).

## 2. Words

| word | means |
|---|---|
| **agent** | any spool agent: a seat (ids 001..004 of a box) or a lane (005..999), any harness |
| **session** | one run of an agent from one restart to the next. A `--resume` of the same transcript (a restore script) is the SAME session |
| **session age** | now minus `started` in `<spool root>/<id>/lifetime/session.json`, written by the SEED step of 4.1 with a session number. `/proc/<pid>/stat` is only a cross-check: on a mismatch the older wins (claude-2 H5: a resume would otherwise reset the 2 h) |
| **rebirth** | a planned end of a session followed by the next session (section 3) |
| **crash** | an unplanned end or a stuck session: S1, S3, S4, S5 of 093, the new S9 (section 8) |
| **restart** | what the watchdog does after a rebirth or a crash: ONE path (section 4) |
| **id lock** | `<spool root>/<id>/lifetime/restart.lock`: the one lock every actor that starts or stops a session takes (4.2) |
| **handoff** | `<spool root>/<id>/handoff.md`, composed after every step (section 5) |
| **done** | the agent is finished: its rundir is gone (today's `/exit-clean`, `s3.sh` `rundir_gone`) or `lifetime/done` is newer than the session start. Never restarted |
| **wip ref** | `wip/<lane branch>`: the lane's uncommitted and unpushed work, pushed by the watchdog's job (5.4). Lane branches are fleet-unique; ids are not |
| **home box / running box** | the box an agent was spawned on / where its session runs now (section 10) |
| **guest** | a lane running on a box other than its home box, under `<spool root>/guest/<id>@<home>/` (10.2) |
| **fenced** | a box whose own beat has not been acknowledged by the hub for `box_down_min`: it starts nothing (10.2) |
| **the lifetime settings** | the fleet-wide admin numbers of section 11 |

## 3. The lifetime of one session (A1, A2, R0, R1, R2, R3, W1)

| session age | what happens | who |
|---|---|---|
| 0 | the seed says: "your session lives at most 2 h: at 1 h you are asked to hand over and exit; at 1 h 50 you take no new work; at 2 h you are stopped. After every step write your next step with `do_spl_agent_handoff_note`." | the spawn's seed (every harness, every agent) |
| every step | the agent writes its own handoff parts (5.2); the script composes the file | agent + hook + watchdog |
| 30 min, 1 h, 1 h 50 | a lane's dirty tree is pushed to its wip ref when it changed since the last push (5.4) | watchdog job |
| **1 h** (`REBIRTH_AT`, 60 min) | **rebirth asked**: the hook injects (and the watchdog pokes an idle agent once) "rebirth: finish the current step, land what is green, write your notes, then run `/exit-clean --rebirth`" | watchdog |
| 1 h .. 1 h 50 | the agent exits by itself at a step boundary (`--rebirth` writes `lifetime/rebirth`, never `done`); the watchdog sees no process with a fresh rebirth marker and restarts it (section 4). A busy agent may finish its step: the 1 h is soft | agent, then watchdog |
| **1 h 50** (`FINAL_AT`) | **final notice**: injected at every hook from now on: "no new work; final handoff; exit now". An idle agent is poked once | watchdog |
| **2 h** (`HARD_END`, 120 min) | **hard end** for a lane: TERM, then KILL after `ROTATE_TERM_WAIT`, whatever is running (R2), even with a human typing (R3); then the restart (section 4) with the handoff as it stands, `hard_killed: true` in its header | watchdog |
| seat | a seat's restart is start-first (4.1), so it STARTS at `HARD_END - WD_START_WAIT - ROTATE_ACK_TIMEOUT` at the latest and the old session is gone by 2 h (claude-2 H8) | watchdog |

- "Rebirth does not succeed" (9bc777da) has two cases, and both fall through
  to the next row: the agent does not exit by 1 h 50, or the next session
  does not start or ack (4.3). A failed lane start leaves nothing running, so
  the restart is retried at the next tick within the limits (6).
- Each session gets a new 2 h (A1). A task that spans many sessions is capped
  by rebirths and total restarts, not by time (6.2).
- 060 D1 (rotate a busy session mid-task at once) is replaced: the 1 h is a
  request, the 2 h is the forced end.
- R3 overrides 093 6.2's human guard **for the 2 h end only**: the watchdog
  still sends no keys and no other takeover to a pane with a human active in
  the last 120 s or with a `.human-hold`. At 2 h a human hold is not
  honoured (R3).

## 4. One restart path (H5, W1, W2, W4, W5, R11)

### 4.1 The action

`do_spl_agent_restart ID=<id> CAUSE=<rebirth|hard-end|S1|S3|S4|S5|S9|reboot|box-down|login-reset>`
(`orc/run/spl-agent-restart.func.sh`). The watchdog is its only automatic
caller; a seat may request it as it may request a takeover today (093 6.3,
exit 3 when nothing hits). It is **new code built from the takeover's
phases** (`orc/run/spl-wd-takeover.func.sh`, whose steps are 060's
functions): today's takeover is start-first for every agent
(`spl_wdt_steps`, claude-2 C17), so the lane order below is new and has its
own failure handling.

**Lane** (stop first; two sessions never share one worktree):

| # | step | what |
|---|---|---|
| 1 | GATE | the id lock (4.2); a restart slot (4.2); the 6.2 guards (except R3 at 2 h); the limits of 6; done = refuse (exit 3); for a crash cause, re-run the situation and refuse when it no longer hits |
| 2 | RETIRE | TERM, KILL after `ROTATE_TERM_WAIT`; wait until the pid is gone. Nothing to retire when the agent already exited (rebirth, S3) |
| 3 | CLEANUP | remove a stale `.git/index.lock` (no git process alive in the worktree); note a rebase or merge in progress (`.git/rebase-merge`, `rebase-apply`, `MERGE_HEAD`) |
| 4 | WIP | push the wip ref (5.4) from the now quiet tree. Mid-rebase or mid-merge: push `ORIG_HEAD` and put the dirty diff in the handoff as a patch file, never the conflicted tree (claude-2 R-f) |
| 5 | HANDOFF | the final compose (5.2) and, for a crash, a `## watchdog` section (code, evidence, `heartbeat.json`, `heartbeat.log` tail, the transcript's last entry types and error texts). A rebirth marker younger than 5 min = "fresh", else "stale since <ts>" (W2: only freshness differs). The rebirth marker is **consumed** here (moved to `lifetime/last-rebirth`), so a crash of the next session is never read as a rebirth (agy-1) |
| 6 | SEED | the brief + the handoff + the lifetime text of section 3 row 0 + the rebirth and restart counts; writes a new `lifetime/session.json` |
| 7 | SPAWN | same id, harness, workdir (`SPAWN_REUSE_ID=1`); a guest gets a fresh worktree (10.2). Not started within `WD_START_WAIT`: nothing runs; counted (6.1); the next tick retries |
| 8 | REPORT | crash: a blocker `wd-<id>-<rid>` to the peers (093 8.2). Rebirth: ONE line to the orchestrator, nothing in topics (W5): `REBORN <id>@<box> #<n> cause=<c> handoff=<path>` |
| 9 | LOG | `rotate.log`, phases `RS-*`; one `agent_lifecycle_events` row (063 section 12) |

**Seat** (start first; 060 I1/I3: never zero acting orchestrators or
dispatchers): GATE, then a role id under the fleet lease writes
`rotate.hold`, then HANDOFF, SEED, SPAWN, the ack (060 FR-041), RETIRE the
old session (TERM, KILL), REPORT, LOG. A failed start or ack keeps the old
session (060 D2) until `HARD_END`; at `HARD_END` the old one is retired
anyway (R2) and the next tick starts a fresh one. No WIP step: seats have no
lane worktree.

### 4.2 One id lock, and slots for throughput (claude-2 H4, H6)

- **Every** actor that starts or stops a session takes the id lock
  (`flock -n`, refuse = exit 4) for its whole run: this action,
  `do_spl_lane_restart` (063), `do_spl_orch_rotate`,
  `do_spl_dispatch_rotate`, `do_spl_peer_restart`, the boot / identity
  restore and the reaper `do_spl_agent_id_reap`. Each also logs its phases to
  `rotate.log`, so `spl_wd_rotating` sees every one of them.
- Box-wide, the single `peer/restart.lock` becomes `RESTART_SLOTS` (default
  4) slot locks `peer/restart.slot.<n>`; lanes take any free slot; a seat
  takes slot 0. Measured need: one lane restart is about `WD_START_WAIT`
  120 s + `ROTATE_TERM_WAIT` 30 s, so one slot does about 24 an hour and a
  box of 30 agents reborn hourly needs at least 2 (claude-2 R-c).

### 4.3 Done or died

| state the watchdog sees | meaning | action |
|---|---|---|
| rundir gone (today's `/exit-clean`), or `lifetime/done` newer than `session.json` | finished | nothing. A `done` older than the session start is a stale one from the previous task under a reused id and is ignored |
| no process, `lifetime/rebirth` present | planned rebirth | restart, cause `rebirth` |
| no process, no marker, rundir present, registry row open, pane on a shell or gone | crash | restart, cause `S3` (093's bare shell, widened to a gone pane) |
| process alive, session age >= `HARD_END` | hard end | restart, cause `hard-end` |
| new session not started in `WD_START_WAIT`, or a seat's ack not in `ROTATE_ACK_TIMEOUT` | failed restart | counted (6.1); retried at the next tick |

The rundir rule is P0 (section 17): without it every lane that finished
under today's `/exit-clean` would be resurrected on the first tick.

### 4.4 The seats join this path (R11, dispatcher reading; the owner may flip it)

The hourly crons `csi-spl:orch-rotate` (`:05`), `csi-spl:dispatch-rotate`
(`:15`) and, where a box has them, `csi-spl:dispatch-heal` and 068's
`csi-spl:peer-restart` stop being the trigger: the watchdog's session-age
rule (section 3) triggers every seat's restart, staggered so no two seats of
one box start within `SEAT_STAGGER` (15 min) of each other. The 060
mechanics stay (hold, ack, start-first, I1..I8); only the trigger moves, and
only after the rotations take the id lock (4.2), else the old cron and the
watchdog both fire at `:05`. The crons differ per box (claude-2 C16): the
task measures each box's crontab before removing lines. If the owner picks
(b), the seats keep their own hourly crons and this section is dropped;
nothing else in the spec depends on it.

## 5. The handoff (H1..H4, R7, W2)

### 5.1 Files, one writer each

All under `<spool root>/<id>/`, mode 0640, owned by the agent user, in the
agent's own spool folder (H4), never in git:

| file | writer | how |
|---|---|---|
| `handoff.d/next.md`, `handoff.d/notes.md`, `handoff.d/lessons.md` | the agent only, through `./run -a do_spl_agent_handoff_note SECTION=<next\|notes\|lesson> TEXT=...` | tmp + rename |
| `handoff.md` (composed) | the script only, `do_spl_agent_handoff ID=<id>` | under `lifetime/handoff.lock` (`flock -x`, 10 s), written to `handoff.md.tmp.$$`, the old one renamed to `handoff.prev.md`, then the tmp renamed in |

One writer per file and an atomic rename: a kill at any moment leaves the
previous complete file (H3; claude-2 R-d, R-e; agy-1). The script reads the
agent's files and never writes them. The rotation's
`dispatch/handoff/<rid>-<id>.md` (060 section 6) becomes a snapshot of
`handoff.md` at restart time.

### 5.2 Sections

| # | section | source | refreshed |
|---|---|---|---|
| 1 | header: id, box, harness, session number and start, age, rebirth and restart counts, freshness, `hard_killed` | `lifetime/` | every compose |
| 2 | **the brief** (H1) | the seed's brief path | once |
| 3 | **done**: commits since the base, sha, pushed or not | `git log origin/master..HEAD`, `git branch -r --contains` | every compose |
| 4 | **in flight**: dirty files, the running tool, the last 30 terminal lines | `git status --porcelain`, `heartbeat.json`, `capture-pane -J` | every compose |
| 5 | **next step** | `handoff.d/next.md` | as the agent writes it |
| 6 | **open questions and who has them** | the outbox (kind blocker or msg without a reply) + `handoff.d/notes.md` | every compose |
| 7 | **owned topics** | the outbox's task ids + the hub's held set (093 4.5) | every compose |
| 8 | NOTES | `handoff.d/notes.md` | as the agent writes it (H2) |
| 9 | lessons sent to the shared memory (titles) | `handoff.d/lessons.md` | as the agent writes it |

The compose runs from the PostToolUse hook at most once per `HANDOFF_EVERY`
(60 s), detached so it never blocks the agent; from the watchdog when the
file is older than 5 min; and in the restart (4.1). Cap: about 250 lines.
Terminal lines (section 4) are scrubbed as 5.3 before they are written.

### 5.3 The hub copy (R7, W7)

After a compose whose content changed, the box sends `handoff.md` to the hub
next to the agent's record (the fleet lane row, rdb 0096) as one blob,
**sealed with the hub's KMS key**. The seal moves from
`internal/marketing/seal_kms.go` into a shared package first, so lifecycle
code does not import marketing (claude-2). It is **scrubbed first**: the
hygiene sweep's secret patterns (keys, tokens, PEM blocks, `password=`)
become `[scrubbed]`, and a file that still matches is not sent (one WARN).
Only a box's watchdog acting under 10.2 and the operator workspace's admin
may read it back. Retention: the last 3 copies per agent, deleted 7 days
after the agent is done.

### 5.4 The wip ref (A3, W4)

- **Name**: `wip/<lane branch>` (claude-2 H2: `wip/<id>` collides across
  boxes; lane branch names are fleet-unique).
- **When**: at 30 min, 1 h and 1 h 50 of a session when the dirty diff
  changed since the last push (agy-1's midpoint push), and in the restart's
  WIP step (4.1). Never from a hook (a hook must not block on the network).
- **How**: the watchdog's detached job commits the dirty tree on top of HEAD
  in a temporary index (never the lane's own index, never `git stash`), under
  the repo's canonical author, message `wip(<id>): <ts> handoff`, and pushes
  `--force-with-lease` to `refs/heads/wip/<lane branch>` ONLY. The push
  wrapper refuses any other refspec.
- **The pre-push gate**: the hook skips refs that are all
  `refs/heads/wip/*` (a scoped exemption read from the hook's stdin), not
  the global `SPL_PREPUSH_OVERRIDE` and not `--no-verify` (agy-2, claude-2).
  CI does not run on them: the push-triggered workflows filter on branches
  and tags (`grep -A4 '^  push:' .github/workflows/*.yml`, claude-2).
- **Use**: the next session (same box or a guest) starts from the lane
  branch and applies the wip ref when it is newer; no wip ref = the lane
  branch alone (agy-2). A lane that finishes deletes its wip ref in
  `/exit-clean`.

## 6. Limits (W3, R4, R12)

### 6.1 Restarts per hour

`restart_max_per_hour` (default 3, admin only) counts every restart of an id
in a rolling hour, rebirths included (W3). It replaces 093's
`WD_TAKEOVER_MAX` (2) and its two counters (`spl_wd_takeover` in
`spl-watchdog.func.sh` and `spl_wdt_limit` in `spl-wd-takeover.func.sh`,
claude-2 C6) with ONE counter in `lifetime/restarts`. Past it (R4): the id
is **held out**, nothing else happens automatically (no new lane, no other
harness), and the admin gets ONE message (11.2) naming the id, the box, the
causes of the restarts and the handoff. **The hold does not expire** (today
it does after 3600 s, `spl-watchdog.func.sh:474`, claude-2 H7); the admin's
"restart" button clears it.

An S2 hit right after a "login reset" restart re-arms the S2 hold and does
not count (agy-2): the login, not the agent, is what failed.

### 6.2 Per task (R12)

| cap | default | counts | applies to |
|---|---|---|---|
| `rebirth_max` | 7 | planned rebirths of one task (R12) | lanes (16 Q3) |
| `task_restart_max` | 12 | every restart of one task, rebirths and crashes (agy-1: a lane that crashes every 25 min never hits 3/hour and never counts a rebirth) | lanes |

The counts live in `lifetime/` and in the fleet lane row. At either cap the
restart does not start a new session: it pushes the wip ref, sends the
orchestrator `TASK CAP <id> <cap> <n> wip=<sha>`, puts one message to the
admin (11.2), and holds the id out until the admin acts.

## 7. Out of quota and login screens (W6, R8)

| case | today (093 S2) | 102 |
|---|---|---|
| login or access screen | ONE owner DM, no restart | ONE admin message (web app + email, 11.2) with a **"login reset"** button; no restart until it is pressed |
| usage limit with a reset time | out until the reset + 120 s, then back by itself; no DM unless every seat of that harness is out | the admin gets ONE message with two buttons, **"login reset"** and **"no tokens left"**; with no answer the agent is restarted after the reset time + 120 s as today (16 Q4) |
| "no tokens left" pressed | - | the id stays held out; a lane's wip ref is pushed (seats: none); the orchestrator gets one line; no switch of login or harness (W6) |
| "login reset" pressed | - | the hub writes a `login-reset` event for that OS user and box; that box's watchdog restarts every held-out agent of that OS user and harness, cause `login-reset` (6.1's exception applies) |

## 8. Generic stuck detection (G1, R13)

### 8.1 The rule: what is absent, never what text is present

**S9 "stuck"** is a new situation script, `orc/features/watchdog/situations/s9.sh`.
An agent is stuck when ALL of these hold for `stuck_min` (default 10 min,
admin only):

| # | condition | source | why it is text-free |
|---|---|---|---|
| 1 | the harness process is alive | `/proc` | - |
| 2 | no progress: `heartbeat.progress_ts` older than `stuck_min` (093 5.2) | heartbeat | a model event, not a screen |
| 3 | not in a tool within its cap (`state != in-tool`, or past 093 S4's cap) | heartbeat | - |
| 4 | the pane did not change **since the input of condition 5 was delivered**: the same hash of `capture-pane -p` on every tick, after removing poke lines (`: 'SPOOL ...'`) and the bottom `WD_S9_STATUS_ROWS` (default 1) status row | tmux | a moving spinner, timer or output breaks it; a poke's echo or a ticking clock does not (agy-2, claude-2) |
| 5 | **a keystroke reached the pane and not the model**: a poke or a 1 h / 1 h 50 notice was typed (each sender logs it with its ts in `<id>/lifetime/input.log`), and no `UserPromptSubmit` followed it | `input.log` + `heartbeat.log` | a dialog of any wording swallows the keystroke: the prompt never reaches the model |

- Condition 5 asks "did what we typed reach the model", which no dialog can
  fake. An idle agent at its prompt with nothing typed into it fails 5 and
  is left alone.
- An unread inbox file that nobody poked (a plain `spool send`, a hub relay)
  is not input yet: the watchdog pokes it ONCE, and that poke starts the
  window (claude-2 R-g).
- A harness whose hook does not emit `UserPromptSubmit` (agy, grok, qwen
  until their ping proves it, 093 7.3) uses conditions 1-4 with `2 x
  stuck_min`.

### 8.2 The action

| what S9 sees on the screen | action |
|---|---|
| a **known** dialog (S7's list: modal=0/1/2) | S7's answer, as today: the fleet's choice is bypass, never auto (the modal=2 path writes `defaultMode=bypassPermissions` and answers "No, keep bypass permissions") |
| anything else | send the orchestrator the pane snapshot ONCE (`<spool root>/dispatch/wd/<id>.s9.pane`, scrubbed as 5.3, path in the note), then `do_spl_agent_restart CAUSE=S9`. Nothing is typed into an unknown dialog |

S7 stays as the fast path for known dialogs (1 tick); S9 is the net for the
rest (`stuck_min`). The known list may grow from S9's snapshots, but nothing
depends on it growing.

### 8.3 The proof (G1's fixture control)

Fixtures under `orc/tests/fixtures/wd-situations/`:

| case | fixture | expected |
|---|---|---|
| hit | the 2026-10-06 frozen pane (`modal-default-mode.pane`) with its dialog words replaced by words no list contains, a heartbeat whose `progress_ts` is 11 min old, a poke in `input.log` 10 min ago and no UserPromptSubmit after it | S9 HIT; the action is snapshot + restart |
| control 1 (the old guard) | the same fixture through today's S7 | no hit: the list-based check misses it |
| control 2 | the same, but a UserPromptSubmit after the poke | no hit |
| control 3 | the same, but the pane body changes once after the poke | no hit |
| control 4 | an idle pane, empty inbox, nothing typed, progress 3 h old | no hit |
| control 5 | an idle pane with an unread inbox file and nothing typed | no hit; the watchdog pokes once |
| control 6 | the hit fixture with a status row whose clock changes every tick, and a second poke echo mid-window | still a hit |

## 9. CLI updates under control (G1, R14)

### 9.1 Who updates

Self-update is turned off for every agent user and harness, in the process
environment: `DISABLE_AUTOUPDATER=1` exported by the launch path
(`orc/features/spawn-agents/lib/spool-env.inc.sh`, which the spawn and
restore scripts source) and in the `env` block of `settings/00-fleet.json`;
the mode check (9.2) asserts it in each live process's
`/proc/<pid>/environ` (agy-1, agy-2). The first task proves that it stops
the update (a box with a newer version published and the variable set:
`ls ~/.local/share/claude/versions` unchanged after 24 h, n = 1 box per
harness) before anything relies on it.

`do_spl_cli_update` (csi-spl-orc) updates the CLIs, run nightly by its cron
(`csi-spl:cli-update`, `UPDATE_WINDOW` 02:00-05:00 UTC):

1. **one box at a time**: a hub lease `cli-update` (one row, CAS, 30 min) so
   two boxes never update in the same window;
2. on that box: install the new version beside the old (the native installer
   keeps both), **without** switching the live agents;
3. **a test agent first**: spawn a scratch lane on the new version with a
   one-line brief ("run `./run -a do_spl_cli_selftest`, report,
   exit-clean"); it must start, show no dialog, carry the 9.2 flags and
   settings, and pass S9 for 5 min. Fail: roll back, one admin message, stop;
4. pass: switch the symlink; live agents pick the new version at their next
   rebirth (no mass restart);
5. the next box takes the lease the next night (or the same night after
   `UPDATE_BOX_GAP`, 30 min).

### 9.2 The settings check after every update (and at every start)

`do_spl_agent_mode_check` compares, for every agent user and harness:

| what | must be | source today |
|---|---|---|
| launch flags of each live process | `--dangerously-skip-permissions` (claude); the harness's own auto-approve flag otherwise | `/proc/<pid>/cmdline` (060 FR-063) |
| `DISABLE_AUTOUPDATER` in each live process | `1` | `/proc/<pid>/environ` |
| `permissions.defaultMode` | `bypassPermissions` | `settings/00-fleet.json` |
| `skipDangerousModePermissionPrompt` | `true` | same |
| `permissions.disableAutoMode` | `disable` | same |
| auto-approve of the other harnesses (agy, grok, qwen) | on | their spawn scripts (`spawn-<harness>.sh`) |

It runs after every update (steps 3 and 4) and **before every spawn and
restart** (the spawn re-asserts the settings file from `00-fleet.json`
first, and refuses with one note if it still differs). Any mismatch is
re-asserted to the most permissive mode (R14) and reported once. The flags
come from ONE helper again (060 FR-061's `spool_claude_perm_flags`,
restored in `orc/features/spawn-agents/lib/spool-env.inc.sh`), used by
spawn, restore, rotation, lane restart and the restart path.

## 10. Boxes: reboot, down, back, watchdog redundancy (W7, R5, R6, WD1..WD5)

### 10.1 Reboot

After a reboot, the box user's crontab starter (`@reboot`, invoking
`spl_wd_inst_start`) starts the 3 watchdog instances, and the watchdog restarts
every agent whose registry row is open, that is not done (4.3) and whose
`running_box` is this box (10.2), cause `reboot`, through section 4: a new session
from the handoff, not a `--resume`. The `@reboot` `do_spl_agent_boot_restore` and
the `--resume` restore scripts stop being a path: once the reboot path has
passed its drill (tasks T014) their cron line is removed, and the scripts
stay only as a manual tool that also takes the id lock (claude-2: two
automatic paths are the R-b race again). 093 6.2's suspend guard stays.

### 10.2 Down, and the fence

- **Box beat**: every box's watchdog writes one row per tick into a new hub
  table `box_beats` (box, `beat_at` at the hub's clock, watchdog pid); the
  hub's reply carries the beat's ack. Not the fleet lease table: 093 6.4
  showed a lease row would re-route an agent's channel posts.
- **Down** = no beat for `box_down_min` (default 2 min, admin only, R5).
- **The fence** (all three reviewers): a box whose own beat has not been
  acked for `box_down_min` is **fenced**. It starts and restarts nothing,
  and it TERMs its own **lanes** (the wip job pushes first when origin is
  reachable), because another box will start copies of them. Its seats keep
  running: seats never move (next point). Once it reaches the hub again, it
  reads `running_box` for each of its agents: a lane now running elsewhere
  is not started here (10.3); the rest restart through section 4.
- **What moves**: only lanes. A seat is a slot of its box (001..004); the
  other boxes' seats take its jobs by the 093 claim (093 10), so a down
  box's seats simply wait for their box.
- **Takeover of a down box's lanes**: each live box's watchdog, on the tick
  it sees a down box, tries ONE hub CAS per lane of that box: `running_box`
  from the down box to itself, in the lane's fleet row (keyed by its HOME
  box, `agent_box = home`). The CAS also requires a second witness: the lane
  branch on origin has not moved for `box_down_min` (claude-2 H3). The
  winner restarts the lane as a **guest**: rundir
  `<spool root>/guest/<id>@<home>/`, tmux window `<id>@<home>`, a fresh
  worktree from the lane branch plus its wip ref, the handoff from the hub
  copy (5.3). The hub routes messages for `<id>@<home>` to `running_box`. A
  box that lacks the lane's harness does not CAS it (16 Q6).
- **Never two copies**: a box starts a lane only while it is that lane's
  `running_box` in the hub, and a fenced box starts nothing.

### 10.3 Back (R6)

- A box returning from **down** (it was off) reads `running_box` before it
  restarts anything: a lane now running elsewhere is not started at home. At
  that lane's next rebirth the restart runs on the home box when the home
  box is beating (CAS `running_box` back), and the guest box retires its
  session and removes its worktree after the push.
- A box returning from a **partition** that finds its own copy of a lane
  still running (it should have been fenced; e.g. its watchdog was dead)
  kills that copy at once, pushes its tree to
  `wip/<lane branch>-fenced-<ts>`, and sends the orchestrator one line
  (claude-2). The guest stays until its next rebirth.

### 10.4 Watchdogs: 3 per box, self-update (WD1, WD2, WD3, WD4, WD5)

#### 10.4.1 Three active daemons, supervision, and lock arbitration (WD1, WD2)

- **Three daemons**: Every box runs 3 watchdog daemon processes
  simultaneously (`INSTANCE` 1, 2, 3), running as the box user (`<box user>`).
  Each instance runs detached with `setsid` (today's `spl_lease_detach`).
  Each holds an exclusive instance file lock
  `<spool root>/dispatch/wd/run.<inst>.lock` (`flock -n`) for its entire lifecycle
  and writes its pid to `<spool root>/dispatch/wd/run.<inst>.pid`.
  Instance lock files are **never unlinked or removed** (`rm -f` is forbidden);
  an instance process exiting automatically releases the OS kernel flock.
- **User-space supervision model (v1.2: no separate keeper, owner decision 15.6)**:
  - *Systemd units rejected*: Systemd system service units require privileged
    root installation in `/etc/systemd/system/` (breaking unprivileged box
    deployment and "consensus, then build, no go"), while systemd user units
    require lingering sessions and fail across headless cron/sudo hops.
    Furthermore, `Restart=always` creates supervisor warfare against peer
    restart and starter loops, resulting in service flapping and cgroup thrashing.
  - *Mutual peer monitoring (WD4, 10.4.2)*: Primary supervision is performed
    directly in user space by surviving peers detecting dead (< 30 s) or hung
    daemons and restarting them.
  - *The crontab starter* (`spl_wd_inst_start`): The crontab line (`* * * * *`
    and `@reboot`, box user) only runs the watchdogs' OWN start command: "if
    fewer than 3 instances run, start the missing ones" (`spl_wd_inst_start`),
    nothing else. Requires zero root permissions. No separate keeper logic,
    daemon, heartbeat (`inst = 0`) or alerts.
  - *Watchdog crontab self-healing*: The watchdogs carry crontab line checking.
    On each tick, an instance checks that the crontab starter line exists in the
    box user's crontab and restores it via `do_spl_wd_ensure_install_cron`
    (the named idempotent action in source) if it is missing.
  - *Watchdog cron daemon failure monitoring*: The watchdogs detect when the
    crontab starter has not run (starter timestamp file not touched, cron daemon
    dead) while the watchdogs still run. Because restarting cron itself needs
    root, the watchdogs raise an admin alert (Section 11.2, WD5), not an
    automatic fix.
- **Reboot start**: Crontab `@reboot` invokes the watchdog start command
  (`spl_wd_inst_start`), launching instances 1, 2, 3 from the verified `good`
  snapshot (10.4.4) under their respective start locks.
- **One judge per agent per tick (judge lock)**:
  - All 3 instances run active, independent inspection loops (`WD_TICK` = 30 s).
  - Before evaluating any agent, an instance attempts to acquire a non-blocking
    agent judge lock: `<spool root>/dispatch/wd/<id>.judge.lock` (`flock -n`).
  - If `<id>.judge.lock` is held by a peer instance, or if `<id>.judged`
    (epoch timestamp) is younger than `WD_TICK - 5` s, the instance skips
    evaluating that agent on this tick.
  - All per-agent situation state, debounce counters, and episode flags
    (`<id>.hits`, `<id>.ep.<code>.<tag>`, `<id>.since`, `<id>.takeovers`,
    `<id>.heldout`, `<id>.s9.poked`) are written **strictly under the judge
    lock**. This guarantees that the 3-daemon pool functions as a single
    consistent evaluation engine: debounces count real time, situations are
    evaluated once per tick period, and duplicate actions are eliminated at source.
- **Per-instance scratch workspaces**:
  - Each instance operates within isolated scratch directories:
    `<spool root>/dispatch/wd/tick.<inst>/`, `ctx.<inst>/`, `last.tick.<inst>`,
    `resume.<inst>`, `heartbeat.<inst>.json`.
  - Under no circumstances may an instance delete or touch another instance's
    scratch directories.
- **Arbitration via T003 per-agent id lock**:
  - The watchdog evaluation loop does **not** hold the T003 per-agent id lock
    (`spl_agent_id_lock <id>`, `<spool root>/<id>/lifetime/restart.lock`) during
    agent inspection or judging. Holding T003 inside the watchdog would deadlock
    the takeover/restart process, which is launched detached under `setsid` and
    independently requests the T003 lock.
  - T003 remains where Section 4.2 placed it: in the executing start/stop actors
    (`do_spl_agent_restart`, `spl-wd-takeover`, `do_spl_lane_restart`,
    `spl-agent-id-reap`). The watchdog triggers the action detached, and exit 4
    from `spl_agent_id_lock` arbitrates cleanly against any concurrent non-watchdog
    actors.
- **Inside-lock deduplication**:
  - Deduplication evaluations are performed inside the judge lock.
  - For S9 stuck panes: after taking `<id>.judge.lock`, the watchdog checks
    `<spool root>/<id>/lifetime/s9.reported`. If the current pane hash matches
    and the reported timestamp is within `WD_NOTE_DEBOUNCE` (300 s), snapshot
    creation and orchestrator notification are suppressed.
  - For pokes: `<id>/lifetime/input.log` records poke timestamps; an un-poked
    inbox file receives a poke only if no poke was recorded within 60 s.
  - For restarts: in-flight restarts log to `rotate.log`; `spl_wd_rotating`
    inspects `rotate.log` under the judge lock and suppresses redundant triggers.

#### 10.4.2 Heartbeat and peer monitoring (WD4)

- **Watchdog heartbeats**: On every tick, each watchdog instance writes
  `<spool root>/dispatch/wd/heartbeat.<inst>.json` containing `{"instance":
  <inst>, "pid": <pid>, "ts": <epoch>, "tick_seq": <seq>, "tick_phase":
  "<start|agents|done>", "last_progress_ts": <epoch>, "progress_seq": <seq>,
  "status": "ok", "git_sha": "<sha>"}`. Heartbeats are written at tick start
  and updated after every evaluated agent (`last_progress_ts`, `progress_seq`),
  ensuring that long ticks under heavy system load advance progress and are not
  falsely declared hung.
- **Peer dead check**: At the start of its tick, each watchdog checks process
  liveness (`kill -0 <peer_pid>`) of the other two instances. If a peer process
  is dead or its pid file is missing, the surviving peer restarts the dead
  watchdog at once under `<spool root>/dispatch/wd/run.<peer_inst>.start.lock`
  (`flock -n`) via `spl_wd_inst_start <peer_inst>`.
- **Peer hung check**:
  - Hung timeout floor: `WD_HUNG = max(3 * WD_TICK, 180 s)` (180 s at the
    default 30 s tick).
  - A peer is judged hung only if `kill -0 <peer_pid>` succeeds but
    `last_progress_ts` has not advanced for $\ge \text{WD\_HUNG}$.
  - The detecting peer acquires `run.<peer_inst>.start.lock`, issues `kill -TERM
    <peer_pid>`, waits `ROTATE_TERM_WAIT` (30 s) for the instance to finish its
    current agent evaluation, and issues `kill -KILL <peer_pid>` if still alive.
  - The terminating peer then restarts the instance via `spl_wd_inst_start
    <peer_inst>` under the start lock.
- **Healthy judge requirement**:
  - An instance evaluates peer health **only if**:
    1. It successfully wrote its own heartbeat during the current tick (guards
       against disk full / ENOSPC triggering circular mutual kills).
    2. The elapsed time since its own previous tick is $< 3 \times \text{WD\_TICK}$
       (guards against spurious kills following host sleep, suspend, or CPU freeze).
- **Single restart authority**:
  - All instance starts (by peers or the crontab starter) call a single function:
    `spl_wd_inst_start <inst>`. It acquires `run.<inst>.start.lock`, verifies
    `run.<inst>.lock` is free, launches the instance detached from the `good`
    code snapshot (10.4.4), and releases the start lock.

#### 10.4.3 Cross-box watchdog liveness and relation to box_beats (WD1, 10.2)

- **Beat reporting in `box_beats`**:
  - Each watchdog instance reports its local beat to the hub `box_beats` table
    with row `(box, inst, beat_at, pid, code_sha)` for `inst` = 1, 2, 3.
  - **No keeper beat (`inst = 0`)**: The separate keeper is eliminated; only
    active watchdog instances (1..3) beat to `box_beats`.
- **Hub-derived `wd_count`**:
  - The hub computes `wd_count` as the number of active instance rows (1..3)
    updated within `box_down_min`.
  - If `wd_count = 0` (no watchdog instance beating from that box):
    - The hub classifies the box as **UP with watchdogs down** (or all 3 dead +
      cron dead).
    - In this state, the hub sends **one** debounced admin message (Section 11.2).
    - **Zero agent migration occurs**: lanes remain running on the home box and
      remote boxes are forbidden from CAS-ing lanes away based on `wd_count = 0`.
      Failover remains exclusively gated by Section 10.2 box-down detection.
- **Box down vs Watchdog down**:
  - A box is declared **DOWN** (Section 10.2) only when **no row of any instance**
    has arrived for `box_down_min`.
  - When a box is partitioned and cannot reach the hub, the local watchdogs
    detect the unacknowledged beat and apply the local fence (TERMs lanes after
    wip push, Section 10.2).
- **Cross-box observation (Q14 consensus: option a)**:
  - Each box reads the fleet watchdog matrix returned in the hub's beat ack.
  - If a remote box shows `wd_count: 0`, the observing box logs a warning note.
  - Local watchdogs take **strictly zero action on remote agents**. Failover
    remains exclusively gated by Section 10.2 box-down detection.

#### 10.4.4 Watchdog self-update on desk-cron changes (WD3)

- **Code snapshots (`code/<sha>/` and `good`)**:
  - Watchdogs **never** execute directly from the moving desk-cron checkout,
    preventing in-place git pulls from modifying sourced situation scripts
    (`s9.sh`, `lib.inc.sh`) under running daemons.
  - When the checkout advances, code is exported via `git archive <sha> csi-spl-orc`
    into `<spool root>/dispatch/wd/code/<sha>/`.
  - Symlink `<spool root>/dispatch/wd/code/good` points to the last verified sha;
    `<spool root>/dispatch/wd/code/candidate` points to the sha being rolled out.
  - `spl_wd_inst_start` always starts daemons from `code/good`. The last 3
    snapshots are retained; older snapshots are pruned.
- **Update trigger & detect**:
  - Periodic crons fetch master into `/opt/csi/csi-spl-desk-cron`.
  - On each tick, an instance compares checkout HEAD against `code/good`.
  - If the commit changed but the `csi-spl-orc/` directory is byte-identical,
    the instance updates the `good` symlink without restarting any daemons.
- **Pre-flight health quorum**:
  - Before starting a rolling restart, the update coordinator verifies that
    **all 3 watchdog instances are currently alive and reporting `status: ok`**.
    If any instance is dead or hung, the update is deferred and an alert raised.
- **Rolling restart sequence (< 120 s)**:
  - Managed under `<spool root>/dispatch/wd/update.lock`.
  - Instance 1 (or lowest live instance) acts as coordinator:
    1. Pre-flight check: runs the fast fixture subset of `wd-situations.tst.sh`
       from the candidate snapshot directory.
    2. Self-exec: at its tick boundary, Instance 1 executes `exec` into the
       candidate code, preserving its lock file descriptors, PID, and session.
    3. Accelerated self-check tick: Instance 1 executes an accelerated self-check
       tick ($\le 20\text{ s}$) that verifies syntax, environment, and evaluates
       at least 1 agent with zero script errors, writing `status: ok`.
    4. Baton handoff: Instance 1 writes `update.next = 2`. Instances 2 and 3
       sleep in 5 s slices; Instance 2 detects the baton, self-execs into candidate,
       and completes its self-check tick ($\le 20\text{ s}$).
    5. Instance 2 passes baton (`update.next = 3`); Instance 3 self-execs and
       completes its self-check tick ($\le 20\text{ s}$).
    6. Candidate becomes `good` (`ln -sfn candidate good`).
    7. Total rollout duration: detection ($\le 30\text{ s}$) + $3 \times (\le 5\text{ s} \text{ baton} + \le 20\text{ s} \text{ tick}) < 70\text{ s}$,
       comfortably inside WD3's 2-minute deadline (`WD_UPDATE_MAX_WAIT` = 120 s).
- **Rollback and stop rule**:
  - If candidate fails pre-flight, or if Instance 1 fails its self-check tick:
    - Rollout is **immediately halted**.
    - Instance 1 self-execs back into `code/good`.
    - Candidate is marked `bad` (quarantined; never rolled again).
    - An admin alert is dispatched naming the failed commit and error output.
    - Instances 2 and 3 remain alive on `good`. Bad code never runs on more than
      1 instance; active watchdog monitoring never drops below 2.
- **Crontab starter interaction**: Crontab starter executes from checkout but
  only calls `spl_wd_inst_start`, which launches `code/good`.

#### 10.4.5 Admin alerts (WD5)

- **Alert conditions**:
  1. Any watchdog instance is down (dead or hung) and unrecovered for $> 5\text{ min}$
     (`WD_ALERT_DOWN_WAIT` = 300 s).
  2. Simultaneous watchdog failures: **2 of 3 watchdogs on a box are down at once**
     (Q12 consensus: option a). When 2 are down, redundancy is lost; the admin
     is alerted immediately before total fleet coverage is lost.
  3. Complete watchdog outage (`wd_count: 0`) detected via hub `box_beats` (10.4.3).
  4. Crontab starter failure / cron daemon dead: watchdogs detect that the
     crontab starter has not run (timestamp file not updated) while watchdogs
     continue running. Restarting cron requires root, so this is an alert, not a fix.
  5. Rolling self-update failure / stop rule triggered (10.4.4).
- **Sender & Delivery**:
  - Alerts are dispatched **directly by the surviving watchdogs** (replacing the
    legacy keeper): watchdogs track `wd/inst.<n>.down_since` and starter status,
    and dispatch Section 11.2 admin messages (web app DM + email).
  - The hub dispatches the fleet-wide `wd_count: 0` / box-down alert.
  - All alerts are debounced by 300 s (`WD_ENSURE_DEBOUNCE`). If the hub API is
    temporarily unreachable, a local spool blocker is sent to the orchestrator.

#### 10.4.6 Tests and controls

| case | fixture / condition | expected | control |
|---|---|---|---|
| multi-daemon arbitration | 2 watchdogs evaluate same stuck agent simultaneously | exactly one acquires `<id>.judge.lock`; exactly one snapshot and action taken; streak counter counts 1 | judge lock free -> single actor succeeds; judge lock held -> peer skips cleanly without error |
| scratch directory isolation | instances 1 and 2 tick concurrently | instance 1 and 2 write separate `tick.1/` and `tick.2/` directories; zero state clobbering | shared tick directory (seam) -> collision caught |
| snapshot deduplication | watchdog 1 writes hash to `s9.reported`; watchdog 2 evaluates same pane | watchdog 2 checks `s9.reported` under judge lock and suppresses duplicate note | different pane hash -> new snapshot taken and reported |
| dead peer restart | kill instance 2 (`kill -9`) | surviving peer acquires `run.2.start.lock` and restarts instance 2 at once from `code/good` | instance 2 alive -> zero restart action taken |
| hung peer restart | freeze instance 2 heartbeat for $\ge 180\text{ s}$ | surviving peer acquires start lock, terminates instance 2 (`TERM`/`KILL`), and restarts it | heartbeat advancing normally (`last_progress_ts` fresh) -> zero action taken |
| heavy load slow tick | tick iterates 30 agents over 120 s updating `last_progress_ts` per agent | zero hung verdict; peers see advancing `last_progress_ts` and do not kill instance | progress frozen for 180 s -> hung verdict triggers |
| disk full guard | filesystem full (ENOSPC on heartbeat write) | heartbeat write failure logged; instances do NOT mutually terminate peers; watchdogs alert admin | normal disk write -> heartbeats advance cleanly |
| crontab starter recovery | all 3 watchdogs killed simultaneously | crontab starter (`spl_wd_inst_start`) restores missing instances within ~60 s | instances alive -> starter starts 0 |
| crontab line self-healing | crontab starter line deleted from crontab | watchdog detects missing line and restores it via `do_spl_wd_ensure_install_cron` | crontab line intact -> zero modification |
| cron daemon failure | cron stopped / crontab starter timestamp stale | surviving watchdogs detect stale starter timestamp and dispatch Section 11.2 admin alert | starter running normally -> zero alert |
| rolling self-update timing | desk-cron HEAD advances to new sha | rolling restart of instances 1, 2, 3 completes in $< 120\text{ s}$ ($< 70\text{ s}$); active coverage never drops below 2 live instances | desk-cron HEAD unchanged -> 0 restarts |
| self-update stop rule | new commit fails pre-flight or check 1 | instance 1 rolls back to `good`; rollout halts; instances 2 and 3 remain alive on `good`; admin alerted | clean commit -> rollout proceeds sequentially across all 3 |
| killed instance restarts on good | bad candidate halted; kill instance 2 (`kill -9`) | instance 2 restarts from `code/good` snapshot, never candidate | valid update -> restarts on candidate sha |
| cross-box observation | remote box reports `wd_count: 0` (no heartbeat at all) | hub derives `wd_count: 0`, sends one admin alert; box stays UP, zero agent CAS/migration | remote box healthy (3 watchdogs) -> zero alert; remote box partitioned (> 2 min absent) -> 10.2 fence activates |
| admin alert threshold | 2 watchdogs killed simultaneously | admin alert triggered immediately (2 of 3 down) | single watchdog killed and restored in $< 5\text{ min}$ -> logged only, zero admin alert |

## 11. The admin (R8, R10)

### 11.1 One fleet-wide setting

The lifetime settings live in the **operator workspace** of each cloud
instance (R10: dev and prd each have their own), as new columns of 063's
`agent_lifecycle_config` (rdb 0105), read from the operator workspace's row
only (`hub/operator_workspaces.go`), edited on its Workspace settings page
by an admin only (R8). NULL = default, as 063 section 11.

| column | default | allowed | drives |
|---|---|---|---|
| `restart_max_per_hour` | 3 | 1..10 | 6.1 (W3) |
| `rebirth_max` | 7 | 1..50 | 6.2 (R12) |
| `task_restart_max` | 12 | 1..100 | 6.2 (agy-1) |
| `stuck_min` | 10 | 2..60 | 8.1 (R13) |
| `box_down_min` | 2 | 1..30 | 10.2 (R5) |

`REBIRTH_AT` (60), `FINAL_AT` (110) and `HARD_END` (120) are the owner's
fixed numbers (9bc777da, R0, R1), not settings. The box reads the settings
through the existing lifecycle read (063) and caches them for 5 min.

### 11.2 Messages to the admin

One message type, **agent needs the admin**, from the hub: a web app message
in the operator workspace (a DM to each admin) plus an email through
`internal/mail`, with buttons:

| cause | buttons |
|---|---|
| login or access screen (7) | login reset |
| usage limit (7) | login reset, no tokens left |
| restart limit reached (6.1) | restart, leave stopped |
| task cap reached (6.2) | one more cycle, leave stopped |
| a fenced box, or a lane that cannot move (10.2, 16 Q6) | none (information) |
| CLI test agent failed (9.1) | none (information) |

Each button writes one hub event; the box's watchdog reads its events at
every tick. One message per (id, cause) until it is answered. Watchdog failure
alerts of 093 6.4 move to this type (sent directly by the watchdogs, replacing
the legacy keeper owner DMs).

## 12. Shared memory (H6, R9)

One shared memory per cloud instance, in the hub, scoped to **how to work in
the spool hub** (R9): traps, commands, conventions. Not task state: what to
do and its context come from the web app (topics, briefs).

- An agent adds a lesson with `spool memory add --title <t> --text <t>`; the
  hub **merges** it into an existing lesson with the same normalised title
  (or an admin merges two) instead of piling up.
- Each agent's seed gets the index (titles + one line), never the bodies;
  `spool memory show <title>` reads one.
- The per-user memory files under the agent user's
  `.claude/projects/<slug>/memory/` stay as they are; moving them in is a
  later task (16 Q7).

## 13. What changes in 060, 063 and 093, and what exists today

| spec rule | today (code) | 102 | check |
|---|---|---|---|
| 060 hourly seat rotation at `:05` / `:15`, its crons | `spl-orch-rotate.func.sh`, `spl-dispatch-rotate.func.sh`; the cron set differs per box | trigger moves to the watchdog's session age once the rotations take the id lock (4.4, R11) | as the box user: `crontab -l \| grep -oE 'csi-spl:[a-z-]+' \| sort -u` per box |
| 060 D1 busy rotated at once | `spl_rotate_quiesce` (grace, Escape) | 1 h is a request; 2 h is the forced end (3) | `grep -n '^spl_rotate_quiesce' orc/run/spl-rotate-lib.func.sh` |
| 060 section 6 handoff written at rotation, in place | `spl_rotate_handoff`; the takeover writes `> "$hand"` | continuous, composed, atomic, one writer per file, hub copy (5) | `grep -n '^spl_rotate_handoff' orc/run/spl-rotate-lib.func.sh` |
| 060 9 "rotating lane agents: out of scope" | 063's `do_spl_lane_restart` restarts lanes on size, no shared lock, its own log | lanes are in (W4); the lane restart takes the id lock and logs to `rotate.log` (4.2) | `grep -c 'restart\.lock' orc/run/spl-lane-restart.func.sh` -> 0 |
| 060 FR-061 one flag helper | gone; a caller falls back to a literal | restored, used by every start (9.2) | section 1 row 6 |
| 093 6.3 `WD_TAKEOVER_MAX` 2, two counters, hold expires in 1 h | `spl-watchdog.func.sh:74`, `:534`, `:786`; `spl-wd-takeover.func.sh` `spl_wdt_limit` | ONE counter, `restart_max_per_hour` 3, rebirths count, the hold does not expire (6.1) | `grep -n 'WD_TAKEOVER_MAX' csi-spl-orc/src/bash/run/spl-watchdog.func.sh csi-spl-orc/src/bash/run/spl-wd-takeover.func.sh` |
| 093 6.3 past the limit | the watchdog sends an orchestrator blocker; the takeover sends an ask + owner DM (`spl_rotate_alert`) | one admin message + email + button (11.2) | `sed -n 666,690p orc/run/spl-watchdog.func.sh`; `grep -n '^# spl_wdt_limit' -A4 orc/run/spl-wd-takeover.func.sh` |
| 093 S2 limit: back after reset, no DM | `situations/s2.sh` | the admin is told; buttons (7) | `sed -n 1,8p orc/features/watchdog/situations/s2.sh` |
| 093 S3 bare shell; `rundir_gone` = finished | `situations/s3.sh:11` | + a gone pane with an open registry row (4.3); `rundir_gone` stays the done rule | `grep -n rundir_gone orc/features/watchdog/situations/s3.sh` |
| 093 S7 list of dialogs | `situations/s7.sh`, `spl_lease_modal_hit` | kept as the fast path; S9 is the net (8) | `ls orc/features/watchdog/situations/` -> `lib.inc.sh`, s1..s9 |
| 093 6.2 human guard | `spl_wd_gate` (`WD_HUMAN_IDLE` 120 s) | not for the 2 h end (R3) | `grep -n WD_HUMAN_IDLE orc/run/spl-watchdog.func.sh` |
| 093 8 takeover, start-first for every agent | `spl_wdt_steps` (spawn, then kill) | `do_spl_agent_restart`: lanes stop-first (new code, 4.1), seats start-first; slots instead of one box lock (4.2) | `sed -n 217,258p orc/run/spl-wd-takeover.func.sh` |
| 093 10 "no watchdog needs to reach another box" | no box beat; `box_stats` every 5 min (rdb 0117) | `box_beats`, the fence, lane CAS on `running_box`, guests (10.2) | `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats` -> 0 |
| 093 6.4 owner DM via `ASKS_OWNER` | `spl-wd-ensure.func.sh` | admin messages (11.2) | `grep -c ASKS_OWNER csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh` -> 4 |
| the reaper | `spl-agent-id-reap.func.sh` retires ids dead for 6 h (cron `*/15`, dry run today) | skips ids held out or with a hub handoff and no done; takes the id lock (claude-2 R-h) | `sed -n 1,20p orc/run/spl-agent-id-reap.func.sh` |
| boot restore | `spl-agent-boot-restore.func.sh` (@reboot, `--resume`) | the watchdog's reboot path; the cron line removed after the drill (10.1) | `sed -n 1,16p orc/run/spl-agent-boot-restore.func.sh` |
| the pre-push hook | runs `do_check_pre_push` on every push | skips `refs/heads/wip/*`-only pushes (5.4) | `orc/features/spawn-agents/hooks/pre-push` |
| CLI version | self-updates in place (section 1 row 5) | off; `do_spl_cli_update` nightly, one box, test agent (9) | `ls ~/.local/share/claude/versions` as the agent user |
| settings | `00-fleet.json`: `defaultMode=bypassPermissions`, `disableAutoMode=disable`, no `env` block | + `DISABLE_AUTOUPDATER` in the env and the launch path; re-checked before every start (9.2) | `cat orc/features/spool-install/assets/claude/settings/00-fleet.json` |
| per-workspace numbers | `agent_lifecycle_config` (063, rdb 0105), 11 keys | + 5 keys, read from the operator workspace only (11.1) | `grep -c 'Key: "' csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` -> 11 |
| fleet lane row | PK `(tenant_id, fleet, agent_id, agent_box)` | + `running_box`, keyed by the home box (10.2) | `grep -n 'PRIMARY KEY' csi-spl-rdb/src/sql/postgres/spool-hub/0102_agent_at_box_key.sql` |
| 093 6.4 watchdog loops per box | ONE loop per box, pid in `dispatch/wd/run.pid`; minute cron keeper restarts dead loop in ~60 s; hung loop detected (>180 s) and alerted via owner DM but unrecovered | 3 active daemons per box; per-instance locks; peer restarts dead at once and hung after 3 missed checks / 180 s floor; crontab starter (`spl_wd_inst_start`) restores missing instances; no separate keeper daemon (10.4) | `grep -n 'run\.pid' csi-spl-orc/src/bash/run/spl-watchdog.func.sh` |
| watchdog code update on git move | none: desk-cron checkout moves on master, but loop runs old code while sourced scripts run mixed versions | rolling self-update of 3 daemons from `code/<sha>` snapshots within 2 min (<70 s), accelerated self-check tick, stop/rollback to `good` on failure (10.4) | `git -C /opt/csi/csi-spl-desk-cron rev-parse HEAD; ps -o pid,lstart,cmd -C bash` |
| 093 6.4 watchdog keeper alert | keeper sends owner DM on crashloop / hung; no admin message | admin message (11.2) sent by watchdogs when an instance cannot be restored in 5 min, or 2 of 3 down on a box (debounced 300 s, replaces legacy keeper `ASKS_OWNER` DM) (10.4, 16 Q12); alert when cron starter has not run | `grep -c ASKS_OWNER csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh` -> 4 |
| cross-box watchdog monitoring | none: no box checks another box's watchdog or agents | each instance beats `box_beats` (inst 1..3); hub derives `wd_count`; remote box with 0 active watchdogs produces one hub admin alert; observer only, zero action on remote agents (10.4, 16 Q14) | `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats` |

## 14. Trace: every owner answer to its section

| answer | section |
|---|---|
| 26db0bb6, 9596fee0, 9bc777da | 3 |
| A1 | 2 (session age), 3, 6.2 |
| A2 | 3 row 0 (every seed, seats included) |
| A3 | 4.1 WIP, 5.4 |
| A4 | 17 (rollout), 16 Q9 |
| A5 | 15 |
| H1, H2, H3, H4 | 5.1, 5.2 |
| H5 | 4 |
| H6 | 12 |
| W1 | 3, 4.3 |
| W2 | 4 |
| W3 | 6.1, 7 |
| W4 | 4.1, 5.4, 10.2 |
| W5 | 4.1 REPORT |
| W6 | 7 |
| W7 | 10 |
| R0, R1, R2, R3 | 3 |
| R4 | 6.1 |
| R5 | 10.2, 11.1 |
| R6 | 10.3 |
| R7 | 5.3 |
| R8 | 11 |
| R9 | 12 |
| R10 | 11.1 |
| R11 | 4.4 (the owner may flip it) |
| R12 | 6.2 |
| R13 | 8.1, 11.1 |
| R14 | 9 |
| G1 | 8, 9 |
| WD1 | 10.4 |
| WD2 | 10.4 |
| WD3 | 10.4 |
| WD4 | 10.4 |
| WD5 | 10.4, 11.2, 16 Q12 |

## 15. Opinion panel and consensus

Owner 0900d5ec asked for 2 agy + 2 claude; 56e95fbe for consensus, then the
build. Each reviewer read v0.1 (`8f32ffd8`) and the code it cites,
independently.

| panelist | agent | file | sha |
|---|---|---|---|
| claude 1 | c-471 | v0.1 of this file | `8f32ffd8` |
| claude 2 | c-459 | [opinions/claude-2.md](opinions/claude-2.md) | `f479f4a6` |
| agy 1 | a-473 | [opinions/agy-1.md](opinions/agy-1.md) | `de123a46` |
| agy 2 | a-474 | [opinions/agy-2.md](opinions/agy-2.md) | `4f99a6c6` |

### 15.1 Verdicts

| panelist | verdict | biggest findings |
|---|---|---|
| claude 2 | shape right, not yet failover-proof | no id lock across four restart actors; ids unique only as `<id>@<box>` (guest collisions, `wip/<id>`); no fence for a partitioned box; one box lock cannot do 30 rebirths an hour; takeover is start-first today, so lane stop-first is new code; the hold expires in 1 h; a resume resets `/proc` age; S9 fires on an un-poked inbox file; the reaper; two handoff writers; `rundir_gone` = done belongs in P0 |
| agy 1 | agree with replacements in 4, 5, 6, 9, 10 | split brain on a partition; handoff race without a lock; stale `.git/index.lock` after a 2 h kill; WIP before RETIRE; the rebirth marker read again after a crash; slow crash loops under 3/hour; set `DISABLE_AUTOUPDATER` in the process environment |
| agy 2 | agree with replacements in 5.4, 7, 8.1, 9.1, 10.2 | the pre-push gate blocks wip pushes; a poke's echo resets S9's pane hash; the partition fence; an S2 re-hit after "login reset" must not burn the limit; `DISABLE_AUTOUPDATER` is read from the process environment; no wip ref = fall back to the lane branch |

All three verified section 1 and 13's check commands; two found the 8.3
fixture path missing its `orc/` prefix, and agy-1 and claude-2 found that
the 093 limit's owner DM is in `spl-wd-takeover.func.sh`, not the watchdog
lines cited. Both are fixed here.

### 15.2 Scores (1 weak .. 5 strong), v0.1 as each scored it

| property | agy 1 | agy 2 | claude 2 |
|---|---|---|---|
| robust | 4 | 4 | 3 |
| failover-proof | 3 | 4 | 2 |
| simple | 4 | 4 | 4 |
| uninterruptible | 4 | 4 | 3 |

**This spec v1.0**, scored by c-471 against the same yardstick:

| property | score | why |
|---|---|---|
| robust | 4 | one id lock for every actor; one writer per handoff file with atomic renames; stuck = absent progress and a swallowed keystroke. Open: a harness without `UserPromptSubmit` relies on conditions 1-4 at 2 x `stuck_min` |
| failover-proof | 4 | a fenced box starts nothing and stops its lanes; only lanes move, by one CAS with a second witness, as guests under their home id. Not 5: the hub is the one arbiter, and a 2 min hub blip fences every box (16 Q11) |
| simple | 4 | one action, one lock, one handoff, one admin message type, five settings |
| uninterruptible | 4 | soft 1 h, final notice, hard 2 h; wip pushed at 30 min, 1 h, 1 h 50 and every restart; seats start-first. Open: up to 30 min of work lost when a box dies between wip pushes |

### 15.3 What was agreed, and where it landed

| # | agreed change | proposed by | section |
|---|---|---|---|
| C1 | one id lock that every start/stop actor takes; all log to `rotate.log` | claude 2 | 4.2 |
| C2 | `RESTART_SLOTS` (4) instead of one box lock | claude 2 | 4.2 |
| C3 | lanes: RETIRE, CLEANUP (`index.lock`, rebase state), WIP, HANDOFF, SPAWN; lane stop-first is new code with its own failure handling | agy 1, claude 2 | 4.1 |
| C4 | consume the rebirth marker before the spawn; ignore a `done` older than the session | agy 1, claude 2 | 4.1, 4.3 |
| C5 | `rundir_gone` stays the done rule, in P0 | claude 2 | 4.3, 17 |
| C6 | session age from `lifetime/session.json`, survives a resume | claude 2 | 2 |
| C7 | a seat's restart starts early enough to end the old session by 2 h | claude 2 | 3 |
| C8 | handoff: agent files and script file separate, one writer each, flock + tmp + rename | agy 1, claude 2 | 5.1 |
| C9 | wip ref = `wip/<lane branch>`, pushed by the watchdog's job, never a hook; exempt from the pre-push gate by refspec; fall back to the lane branch | claude 2, agy 2 | 5.4 |
| C10 | a 30 min wip push | agy 1 | 3, 5.4 |
| C11 | ONE restart counter; the hold does not expire | claude 2 | 6.1 |
| C12 | `task_restart_max` (12) caps rebirths + crashes per task | agy 1 | 6.2, 11.1 |
| C13 | an S2 re-hit after "login reset" does not count | agy 2 | 6.1, 7 |
| C14 | S9 condition 5 counts keystrokes from `input.log`; an un-poked inbox file gets one poke first; condition 4 ignores poke echoes and the status row and starts at the input | claude 2, agy 2 | 8.1, 8.3 |
| C15 | `DISABLE_AUTOUPDATER` in the process environment, asserted by the mode check | agy 1, agy 2 | 9.1, 9.2 |
| C16 | the fence: a box without an acked beat for `box_down_min` starts nothing and stops its lanes; on return a surviving copy is killed and pushed to a `-fenced-` ref | agy 1, agy 2, claude 2 | 10.2, 10.3 |
| C17 | guests run as `<id>@<home>`; the lane row keyed by the home box gains `running_box`; a second witness (branch not moved) on the CAS | claude 2 | 10.2 |
| C18 | the `--resume` boot restore stops being an automatic path once the reboot drill passes | claude 2 | 10.1 |
| C19 | the reaper and the 063 lane restart take the id lock; the reaper skips held-out ids | claude 2 | 4.2, 13 |
| C20 | the KMS seal moves to a shared package | claude 2 | 5.3 |

### 15.4 Where the panel differed, and the choice made

| question | positions | chosen | why |
|---|---|---|---|
| Q5 wip push frequency | (a) 1 h, 1 h 50, restart (agy 2, claude 2); + a 30 min push (agy 1) | 30 min, 1 h, 1 h 50, restart, only when the diff changed | the objection to (b) was churn every 60 s; one more push per session costs little and halves the loss window on a dead box |
| Q9 the over-2 h agents at rollout | 1 per box per minute (agy 1, agy 2); `RESTART_SLOTS` at a time, oldest first (claude 2) | `RESTART_SLOTS` at a time, oldest session first, starts at least 60 s apart | both goals hold: no herd, and the backlog clears within about 2 h |
| Q10 the wip ref | `wip/<id>` with a refspec assertion (agy 1, agy 2); `wip/<lane branch>` (claude 2) | `wip/<lane branch>`, `--force-with-lease`, the wrapper refuses any other refspec | ids collide across boxes; the agy concern (never a force push elsewhere) is kept by the assertion |
| handoff concurrency | flock on one file (agy 1); separate files per writer (claude 2) | both: separate files, and the script's own compose under flock | one writer per file removes the agent/script race; the flock covers the hook, watchdog and restart all composing |
| boot restore | keep as fallback (v0.1, agy 2); retire it (claude 2) | its cron line goes after the reboot drill; the scripts stay as a manual tool under the id lock | two automatic paths race; a manual tool under the lock does not |

No reviewer disagreed with sections 0, 1, 3 (beyond C7), 7 (beyond C13),
11, 12, 14 or the 17 phase order. All kept the defaults of Q1-Q4 and Q6-Q8.

### 15.5 Watchdog panel and consensus (v1.1)

Dispatcher c-002 seated an independent three-member panel on the v1.1-draft
(`8ee516f2`) for Section 10.4 (Watchdogs: 3 per box, self-update) and its
tasks T023..T027:

| panelist | agent | file | sha |
|---|---|---|---|
| claude 2 | c-493 | [opinions/wd-claude-2.md](opinions/wd-claude-2.md) | `c7b79a24` |
| agy 2 | a-492 | [opinions/wd-agy-2.md](opinions/wd-agy-2.md) | `95bb07f3` |
| agy 1 | a-491 | [opinions/wd-agy-1.md](opinions/wd-agy-1.md) | `5f7477d2` |

#### 15.5.1 Panel verdicts and scores

| panelist | verdict | biggest findings |
|---|---|---|
| claude 2 | agree with goal; replace 10.4.1, 10.4.2, 10.4.4 | shared per-agent state and keys unlocked (corrupts ticks, double-counts debounces, C-c exits session); id lock deadlocks takeover; 0 watchdogs = 0 beats = box read as down (lanes move while old run); no rollback target; 180 s hung floor; baton update |
| agy 2 | agree with goal; replace 10.4.1, 10.4.2, 10.4.4, 10.4.6 | shared tick dir clobbered (`rm -rf $tick`); 120 s vs 180 s update timing contradiction; systemd vs keeper vs peer supervisor fights; in-place git pull modifies executing bash scripts |
| agy 1 | agree with goal; replace 10.4.1, 10.4.2, 10.4.4 | per-instance state isolation missing; unprivileged box model vs root systemd units; shared checkout risks peer disruption on bad commit; accelerated verification tick needed |

**Scores (1 weak .. 5 strong)**:

| property | agy 1 | agy 2 | claude 2 | **v1.1 consensus** (why) |
|---|:---:|:---:|:---:|:---:|
| **robust** | 3 | 3 | 2 | **4** (per-agent judge lock serializes evaluation; per-instance scratch dirs eliminate file clobbering; T003 lock in actors prevents takeover self-deadlock) |
| **failover-proof** | 4 | 4 | 2 | **4** (keeper beats as inst 0, ensuring box stays UP with 0 instances; hub derives wd_count; observer only across boxes with zero remote agent action) |
| **simple** | 3 | 3 | 2 | **4** (root-free user-space supervision via cron keeper + WD4 peers; no systemd units; single start function `spl_wd_inst_start`) |
| **uninterruptible** | 3 | 4 | 3 | **4** (versioned `code/<sha>` snapshots + `good` symlink; self-exec baton roll in < 70 s; bad commit halted with rollback to `good`; never drops below 2 live instances) |

#### 15.5.2 Agreed changes (C21..C28)

| # | agreed change | proposed by | section |
|---|---|---|---|
| C21 | **Per-agent judge lock & scratch isolation**: `<spool root>/dispatch/wd/<id>.judge.lock` (`flock -n`) taken during evaluation; per-instance scratch dirs (`tick.<n>/`, `ctx.<n>/`, `heartbeat.<n>.json`); episode/state files written only under judge lock. T003 agent ID lock remains in takeover/restart actions (detached takeover takes T003, avoiding self-deadlock) | claude 2, agy 1, agy 2 | 10.4.1 |
| C22 | **User-space supervision alone (v1.2: no separate keeper)**: crontab starter (`* * * * *` and `@reboot` running `spl_wd_inst_start`) + WD4 peer monitoring. Reject systemd system units (no root required, avoids supervisor warfare with `Restart=always`, fully portable). Watchdogs self-heal crontab line and alert if cron stops; no separate keeper daemon | claude 2, agy 1, agy 2, owner | 10.4.1, 15.6, 16 Q13 |
| C23 | **Watchdog heartbeats & hung floor**: heartbeats include `last_progress_ts` and `progress_seq`; hung threshold `WD_HUNG = max(3 * WD_TICK, 180 s)` (180 s floor at 30 s tick). Single start function `spl_wd_inst_start <n>`. Never delete flock files (`run.<n>.lock`). Disk full / suspend guards | claude 2, agy 1, agy 2 | 10.4.2 |
| C24 | **Hub-derived `wd_count` (v1.2: no inst=0)**: instances beat `box_beats` as `inst = 1..3` (no separate keeper beat). Hub derives `wd_count`. If `wd_count = 0` (all 3 watchdogs dead), hub sends admin alert; box stays UP, zero agent CAS/migration. Box down requires absence of ANY row for `box_down_min` | claude 2, agy 1, agy 2, owner | 10.4.3, 15.6, 16 Q14 |
| C25 | **Code snapshots & good symlink**: version-pinned snapshots (`dispatch/wd/code/<sha>/` via `git archive`) and `good` symlink. Surviving peers, crontab starter, and reboot always start from `good` | claude 2, agy 1, agy 2 | 10.4.4 |
| C26 | **Rolling self-update (< 120 s) & rollback**: pre-flight health quorum; instance 1 self-execs (`exec`) into candidate at tick boundary, runs accelerated self-check tick ($\le 20\text{ s}$), hands baton to 2, then 3; total rollout $< 70\text{ s}$. Stop rule: failure halts rollout, instance 1 re-execs into `good`, candidate marked `bad`, admin alerted | claude 2, agy 1, agy 2 | 10.4.4 |
| C27 | **Admin alert routing & debouncing (v1.2: watchdogs alert)**: surviving watchdogs track peer down time and dispatch Section 11.2 admin alerts (replacing legacy `ASKS_OWNER` DM) on single instance down > 5 min or 2 of 3 down simultaneously, and when cron starter has not run. Hub dispatches cross-box / 0-watchdog alert. Both debounced by 300 s (`WD_ENSURE_DEBOUNCE`) | claude 2, agy 1, agy 2, owner | 10.4.5, 15.6, 16 Q12 |
| C28 | **Zero-gap rollout**: managed in user space without systemd; multi-instance code started from `good` snapshot, legacy loop cleanly TERMed once all 3 instances tick, crontab starter updated to `spl_wd_inst_start` | claude 2, agy 1, agy 2, owner | 17.5 |

#### 15.5.3 Resolution of Open Questions Q12, Q13, Q14

All three panelists reached identical conclusions:
- **Q12**: Unanimously **Keep (a)** (2 of 3 down on a box triggers admin alert, debounced 300 s).
- **Q13**: Unanimously **Flip to (b)** (User space alone without systemd; v1.2 owner decision 15.6 refines this to crontab starter `spl_wd_inst_start` + WD4 peer restarts directly in user space as `<box user>`, eliminating the separate keeper daemon).
- **Q14**: Unanimously **Keep (a)** (Alert admin when remote box has 0 active watchdogs via hub `box_beats` with instances 1..3, no keeper inst 0 in v1.2; observer only, zero action on remote agents).

### 15.6 v1.2 owner decision: no separate keeper

On 2026-10-07, following discussion of the v1.1 watchdog keeper architecture in topic `637269bb-d97b-4861-b45e-87200652b169`, the owner decided (HUM-10):
- msg `a606118a`: *"what is the keeper - there should not be any single point of failure ?!"*
- msg `25731cc9`: *"... why we need a separate keeper .. why not move this responsibility to the wather services"*
- msg `575c9d19`: *"yes , go for it , of course add all of the cron things to the source code and document the setup properly ... otherwise , next time we are in trouble , we would not know how it is supposed to be working"*

"yes, go for it" approved the dispatcher's proposal (c-002), establishing the v1.2 model:
1. **Drop the keeper as a separate piece**: The crontab line (`@reboot` and `* * * * *`, box user) only runs the watchdogs' OWN start command: "if fewer than 3 instances run, start the missing ones" (`spl_wd_inst_start`), nothing else. No separate keeper logic, heartbeat (`inst = 0`) or alerts.
2. **Watchdogs carry everything else**: Restart each other (WD4); check that the crontab line exists and put it back via `do_spl_wd_ensure_install_cron` if missing; alert admins (Section 11.2) on instance down > 5 min or 2 of 3 down (debounced 300 s); and alert when the cron starter has not run (cron daemon dead) while watchdogs still run - restarting cron itself needs root, so that is an alert, not a fix.
3. **Hub observer alert**: The hub alerts when a box sends no watchdog heartbeat at all (covers all 3 dead + cron dead, and box down); observer only, zero action on remote agents.
4. **Cron in source**: Every cron line lives in source, installed by one named action (`do_spl_wd_ensure_install_cron`), re-runnable, idempotent.
5. **Setup documentation**: Documented in `csi-spl-doc/doc/md/watchdog-setup.md`.

## 16. Open questions (a safe default is chosen and marked; nothing waits)

| # | question | options | **default** (why) |
|---|---|---|---|
| Q1 | does the 1 h rebirth force a busy agent | (a) ask, the agent picks the step boundary until 1 h 50; (b) Escape at 1 h like 060 D1 | **(a)**, all reviewers: R1/R2 put the force at 2 h |
| Q2 | the seats' order | (a) start-first with ack (060); (b) stop-first like lanes | **(a)**, all reviewers, with C7's timing |
| Q3 | does `rebirth_max` apply to seats | (a) lanes only; (b) seats too | **(a)**, all reviewers: a seat's role never ends; 6.1 still guards seats |
| Q4 | usage limit with a reset time and no admin answer | (a) restart after the reset + 120 s, as 093; (b) wait for the button | **(a)**, all reviewers |
| Q5 | how often the wip ref is pushed | see 15.4 | **30 min, 1 h, 1 h 50, restart** |
| Q6 | a lane whose harness exists only on the down box (agy today) | (a) it waits for its box, with one admin message; (b) it moves to another harness | **(a)**, all reviewers: W6 forbids switching harness |
| Q7 | the per-user memory files | (a) stay, the hub memory takes new lessons only; (b) imported once | **(a)**, all reviewers |
| Q8 | where the box beat lives | (a) a new `box_beats` table; (b) the fleet lease table | **(a)**, all reviewers |
| Q9 | the agents over 2 h when the rule goes live (A4) | see 15.4 | **`RESTART_SLOTS` at a time, oldest first, 60 s apart** |
| Q10 | the wip ref | see 15.4 | **`wip/<lane branch>`** |
| Q11 | a 2 min hub blip fences every box and stops every lane | (a) accept, 2 min is the owner's default (R5) and an admin can raise it; (b) fence only after 2 x `box_down_min` | **(a)**: the owner chose 2 min; a fenced box's lanes restart within a tick of the hub's return, from their wip ref |
| Q12 | admin alert threshold for simultaneous watchdog failures on a box | (a) 2 of 3 down; (b) all 3 down | **(a)**, all panelists (claude-2, agy-1, agy-2): 2 of 3 down indicates loss of redundancy and active risk (OOM, disk full); debounced by 300 s (`WD_ENSURE_DEBOUNCE`) |
| Q13 | watchdog daemon supervisor mechanism | (a) systemd system service template (`spl-watchdog@.service`) as primary supervisor, crontab starter as outer fallback; (b) crontab starter (`spl_wd_inst_start` at `* * * * *` and `@reboot`) + WD4 peer restarts directly in user space as `<box user>` | **(b)**, all panelists (claude-2, agy-1, agy-2) and owner (15.6): reject systemd primary; crontab starter (`spl_wd_inst_start`) + WD4 peer restarts alone directly in user space as `<box user>`; no separate keeper daemon. Root-free, zero supervisor warfare with `Restart=always`, container/dev portable |
| Q14 | cross-box watchdog liveness alert threshold | (a) alert admin when another box has 0 active watchdogs, with zero action on its agents; (b) alert when any single remote watchdog instance is down | **(a)**, all panelists (claude-2, agy-1, agy-2) and owner (15.6): alert admin via hub `box_beats` when another box has 0 active watchdogs (`wd_count: 0`); observer only, strictly zero action on remote agents; avoids alert storms during routine rolling updates |

## 17. Rollout (A4)

1. **P0** (the 2026-10-06 class, and the base everything else needs): the id
   lock in every actor (4.2), `rundir_gone` = done (4.3), S9 + its fixture
   controls (8), the settings check, `DISABLE_AUTOUPDATER` and the restored
   flag helper (9.2).
2. **P1**: the handoff files (5.1, 5.2), the wip job and the pre-push
   exemption (5.4), the restart action with lanes stop-first and slots (4),
   the session-age rule (3) for lanes, one restart counter and the caps (6);
   the over-2 h agents are reborn only now (A4, Q9).
3. **P2**: the admin settings and messages (11), the hub handoff copy (5.3),
   S2's buttons (7), the seats onto the path (4.4), multi-daemon watchdog
   redundancy (10.4, T023a, T023b), and watchdog failure alerts (10.4, T026).
4. **P3**: the box beat, the fence and guests (10), controlled CLI updates
   (9.1), cross-box watchdog liveness (10.4, T024), watchdog self-update on
   desk-cron changes (10.4, T025), the shared memory (12), the reboot path
   replacing the boot restore (10.1).
5. **Watchdog redundancy rollout (how 1 loop becomes 3 without a gap)**:
   - Multi-instance support added to watchdog code (instances 1, 2, 3 with
     instance IDs, instance locks `run.<inst>.lock`, non-blocking judge lock
     `<id>.judge.lock`, and per-instance scratch dirs `tick.<inst>/`).
     Initial release packaged into `code/<sha>` and symlinked as `good`.
   - Zero-gap transition sequence:
     1. Instance 1 starts from `good` with multi-instance code while legacy single
        loop (`run.lock`) is still ticking. Instance 1 uses `<id>.judge.lock` and
        `tick.1/`, avoiding state collision with legacy loop.
     2. Legacy single loop is cleanly TERMed (`kill $(cat <spool root>/dispatch/wd/run.pid)`).
        Instance 1 continues uninterrupted coverage.
     3. Instance 2 is started from `good`, completes accelerated self-check tick,
        and verifies peer heartbeat with instance 1.
     4. Instance 3 is started from `good`, completes accelerated self-check tick,
        and verifies peer heartbeat with instances 1 and 2.
     5. Crontab starter is updated to ensure all 3 instances run (calling
        `spl_wd_inst_start` at `* * * * *` and `@reboot`). No separate keeper
        daemon or `inst = 0` beat (15.6). Zero systemd units required (Q13 consensus b).
   At no point during the transition is the box left with zero active watchdogs.

Tasks: [tasks.md](tasks.md).

<!-- version: 1.2.0 · updated: 2026-10-07 · last-edit: 2026-10-07T14:45:00Z -->
