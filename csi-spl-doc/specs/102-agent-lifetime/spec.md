# 102 Agent lifetime: 1 h rebirth, 2 h hard end, one restart path, generic stuck detection

Status: **v0.1, author draft, 2026-10-07.** For the panel (2 agy + 1 more
claude); section 15 will record their verdicts. Spec only: no code, cron,
table, setting or seat was touched by this lane.
Topic: t1 `637269bb-d97b-4861-b45e-87200652b169` (HUM-10). Dispatcher and
topic owner: c-002. Author: c-471 (claude panelist 1).
Extends: [060 role rotation](../060-role-rotation/spec.md) (handoff, fresh
session under the same id, ack), [093 agent watchdog](../093-agent-watchdog/spec.md)
(heartbeat, situations S1..S8, takeover 8, keeper 6.4),
[063 agent context lifecycle](../063-agent-context-lifecycle/spec.md) (lane
restart, the per-workspace numbers table), [101 four orchestrator-dispatchers](../101-four-orchestrator-dispatchers/spec.md),
[SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md).

`<pc box>` and `<box B>` stand for box tags (box tags are banned literals in
this tree, as in specs 064, 068, 093 and 101). "Machine" in the owner's
answers is a box.

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

## 1. Why: what the fleet looked like, and why the guards missed it

| fact | check |
|---|---|
| about 30 agents were over 2 h on 2026-10-07 04:56Z, the oldest 3 days (c-097..c-102, q-100, q-101); c-101 had run 21 h | c-002@sat's task in topic 637269bb, 04:56:05Z (`spool tail --task 637269bb-...`) |
| the box page's "Online 2d" for c-002 / c-003 was the id's first registry row, not the session: both rotate hourly | same message |
| nothing ends a lane by age today: 063's wall-clock restart is off by default | `grep -n lane_restart_wall_min csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` -> `Default: 0 ... ZeroOff: true` |
| the 2026-10-06 stuck dialog: a Claude Code self-update left the settings on auto while agents started with bypass, and the "Make auto mode your default?" dialog froze six seats for hours. S7 caught it only after the dialog was added to its list | `/var/spool-hub/dispatch/c-003-f9112852-generic.md`; `sed -n 1,9p csi-spl-orc/src/bash/features/watchdog/situations/s7.sh` (modal=2 is that one dialog, by its words) |
| the CLI updates itself in place, and a box runs mixed versions | as the agent user: `ls ~/.local/share/claude/versions` -> 2.1.289 (10-04 02:10Z), 2.1.290 (10-06 02:33Z), 2.1.291 (10-06 06:56Z), 2.1.292 (10-06 22:10Z); `readlink /proc/<pid>/exe` over the live claude processes -> 12 on 2.1.292, 1 on 2.1.289 (2026-10-07, n = 13) |
| the single launch-flag helper of 060 FR-061 is gone: `spl-lane-restart` still asks for it and falls back to a literal | `grep -rn 'spool_claude_perm_flags()' csi-spl-orc/src/bash` -> 0 definitions; `grep -n spool_claude_perm_flags csi-spl-orc/src/bash/run/spl-lane-restart.func.sh` -> 1 caller with a fallback |

**Lesson, the core of this spec:** a list of known bad screens cannot catch
the next one. Stuck must be defined by what is ABSENT (progress, input
reaching the model), not by what text is present (section 8).

## 2. Words

| word | means |
|---|---|
| **agent** | any spool agent: a seat (ids 001..004 of a box) or a lane (005..999), any harness |
| **session** | one harness process under an agent id, from its start to its end. A rebirth ends one session and starts the next under the same id |
| **session age** | now minus the session's start (the harness process's start time, `/proc/<pid>/stat`), never the id's first registry row |
| **rebirth** | a planned end of a session followed by the next session (section 3) |
| **crash** | an unplanned end or a stuck session: S1, S3, S4, S5 of 093, the new S9 (section 8) |
| **restart** | what the watchdog does after a rebirth or a crash: ONE path (section 4) |
| **handoff** | `<spool root>/<id>/handoff.md`, kept current after every step (section 5) |
| **done marker** | `<spool root>/<id>/lifetime/done`, written by `/exit-clean` when the task is finished: the one thing that tells the watchdog "do not restart" |
| **wip branch** | `wip/<id>`: the lane's uncommitted and unpushed work, pushed by the script (5.4) |
| **home box** | the box an agent was spawned on; **running box** = where its session runs now (section 10) |
| **the lifetime settings** | the fleet-wide admin numbers of section 11 |

## 3. The lifetime of one session (A1, A2, R0, R1, R2, R3, W1)

| session age | what happens | who |
|---|---|---|
| 0 | the seed says: "your session lives at most 2 h: at 1 h you are asked to hand over and exit; at 1 h 50 you take no new work; at 2 h you are stopped. Keep `<handoff path>` current after every step." | the spawn's seed (every harness, every agent) |
| every step | the agent's notes go into the handoff's NOTES section; the script refreshes the mechanical sections (5.2) | agent + hook + watchdog |
| **1 h** (`REBIRTH_AT`, 60 min) | **rebirth asked**: the hook injects (and the watchdog pokes an idle agent once) "rebirth: finish the current step, land what is green, add your notes to the handoff, then run `/exit-clean --rebirth`" | watchdog |
| 1 h .. 1 h 50 | the agent exits by itself at a step boundary (`--rebirth` writes `lifetime/rebirth`, never `done`); the watchdog sees the empty pane with a fresh rebirth marker and restarts it (section 4). A busy agent may finish its step: the 1 h is soft | agent, then watchdog |
| **1 h 50** (`FINAL_AT`) | **final notice**: injected at every hook from now on: "no new work; final handoff; exit now". An idle agent is poked once | watchdog |
| **2 h** (`HARD_END`, 120 min) | **hard end**: TERM, then KILL after `ROTATE_TERM_WAIT`, whatever is running (R2), even with a human typing (R3); then the restart (section 4) with the handoff as it stands | watchdog |

- "Rebirth does not succeed" (9bc777da) has two cases, and both fall through
  to the next row: the agent does not exit by 1 h 50, or the next session
  does not start or ack (4.3). A failed new session leaves nothing running,
  so the restart is retried at the next tick within the limit (6.1).
- Each session gets a new 2 h (A1). A task that spans many sessions is capped
  by rebirths, not by time (6.2).
- 060 D1 (rotate a busy session mid-task at once) is replaced: the 1 h is a
  request, the 2 h is the forced end.
- R3 overrides 093 6.2's human guard **for the 2 h end only**: the watchdog
  still sends no keys and no other takeover to a pane with a human active in
  the last 120 s or with a `.human-hold`. At 2 h a human hold is not
  honoured (R3).

## 4. One restart path (H5, W1, W2, W4, W5, R11)

### 4.1 The action

`do_spl_agent_restart ID=<id> CAUSE=<rebirth|hard-end|S1|S3|S4|S5|S9|reboot|box-down>`
(csi-spl-orc). The watchdog is its only automatic caller; a seat may request
it as it may request a takeover today (093 6.3, exit 3 when nothing hits).
It is today's `do_spl_wd_takeover` with the cause widened: every step below
already exists there (`csi-spl-orc/src/bash/run/spl-wd-takeover.func.sh`,
whose phases are 060's functions).

| step | today (093 takeover) | change |
|---|---|---|
| GATE | 6.2 guards, `peer/restart.lock`, duplicates, `WD_TAKEOVER_MAX` (2), re-run the situations | the limit becomes the admin's `restart_max_per_hour` (3) and **counts rebirths** (W3); a planned cause (rebirth, hard-end) skips the situation re-run; the done marker refuses (exit 3) |
| HANDOFF | `spl_rotate_handoff` + a `## watchdog` section, written at takeover time | the continuous handoff (section 5) is the base; the script adds its final mechanical refresh and, for a crash, the `## watchdog` section. A rebirth marker younger than 5 min = "fresh"; else "stale since <ts>" in the header (W2: only freshness differs) |
| WIP | none | a lane: the script pushes `wip/<id>` (5.4) before RETIRE when the tree differs from the last push (A3) |
| SEED | the old session's first prompt + the handoff | the same, plus the lifetime text of section 3 row 0 and the rebirth count (6.2) |
| SPAWN | same id, harness, workdir (`SPAWN_REUSE_ID=1`) | a lane on another box gets a fresh worktree from `wip/<id>` (10.2) |
| RETIRE | TERM, KILL after `ROTATE_TERM_WAIT` | unchanged; nothing to retire when the agent already exited (rebirth, S3) |
| REPORT | a blocker `wd-<id>-<rid>` to the peers | **crash only**. A rebirth sends ONE line to the orchestrator and posts nothing in topics (W5): `REBORN <id>@<box> #<n> cause=<c> handoff=<path>` |
| LOG | `rotate.log`, phases `WD-*` | phases `RS-*`; one `agent_lifecycle_events` row per restart (063 section 12) |

### 4.2 Order: lanes stop first, seats start first

| agent | order | why |
|---|---|---|
| lane | stop the old session, then start the new one | two sessions must never share one worktree |
| seat (001..004) | start the new one, wait for its ack (060 FR-041), then retire the old one; a role id under the fleet lease writes `rotate.hold` first, as 093's takeover does | 060's I1/I3: never zero acting orchestrators or dispatchers |

### 4.3 Done or died

| state the watchdog sees | meaning | action |
|---|---|---|
| no process, `lifetime/done` present | finished | nothing; the registry row is closed; the window closes as `/exit-clean` asked |
| no process, `lifetime/rebirth` present | planned rebirth | restart, cause `rebirth` |
| no process, no marker, pane on a shell or gone | crash | restart, cause `S3` (093's bare shell, widened to a gone pane while the registry row is open) |
| process alive, session age >= `HARD_END` | hard end | restart, cause `hard-end` |
| new session not started in `WD_START_WAIT`, or no ack in `ROTATE_ACK_TIMEOUT` | failed restart | counted against the limit; retried at the next tick; past the limit: 6.1 |

### 4.4 The seats join this path (R11, dispatcher reading; the owner may flip it)

The hourly crons `csi-spl:orch-rotate` (`:05`), `csi-spl:dispatch-rotate`
(`:15`), `csi-spl:dispatch-heal` and 068's `csi-spl:peer-restart` stop being
the trigger: the watchdog's session-age rule (section 3) triggers every
seat's rebirth, staggered so no two seats of one box are reborn within
`SEAT_STAGGER` (15 min) of each other. The 060 mechanics stay (hold, ack,
start-first, I1..I8); only the trigger moves. If the owner picks (b), the
seats keep their own hourly crons and this section is dropped; nothing else
in the spec depends on it.

## 5. The handoff (H1..H4, R7, W2)

### 5.1 One file, kept current

`<spool root>/<id>/handoff.md`, mode 0640, owned by the agent user, in the
agent's own spool folder (H4), never in git. One previous copy is kept as
`handoff.prev.md`. The rotation's `dispatch/handoff/<rid>-<id>.md` (060
section 6) becomes a snapshot of this file at restart time.

### 5.2 Sections and writers

| # | section | source | writer | refreshed |
|---|---|---|---|---|
| 1 | header: id, box, harness, session start, age, rebirth count, freshness | `/proc`, `lifetime/` | script | every refresh |
| 2 | **the brief** (H1) | the seed's brief path | script | once |
| 3 | **done**: commits since the base, sha, pushed or not | `git log origin/master..HEAD`, `git branch -r --contains` | script | every refresh |
| 4 | **in flight**: dirty files, the running tool, the last 30 terminal lines | `git status --porcelain`, `heartbeat.json`, `capture-pane -J` | script | every refresh |
| 5 | **next step** | the agent | agent | after every step |
| 6 | **open questions and who has them** | the agent's outbox (kind blocker or msg without a reply) + the agent | script + agent | every refresh |
| 7 | **owned topics** | the outbox's task ids + the hub's held set (093 4.5) | script | every refresh |
| 8 | NOTES (free text, the agent's own words) | the agent | agent | when it can (H2) |
| 9 | lessons sent to the shared memory (names only) | section 12 | agent | when it has one |

- **The script** is `do_spl_agent_handoff ID=<id>`, run by the PostToolUse
  hook at most once per `HANDOFF_EVERY` (60 s), by the watchdog when the
  file is older than 5 min, and by the restart (4.1). It rewrites sections
  1-4, 6, 7 and keeps 5, 8, 9 byte for byte (H3: a kill leaves a usable one).
- **The agent** writes 5, 8 and 9 with `./run -a do_spl_agent_handoff_note
  SECTION=<next|notes|lesson> TEXT=...`, never by editing the file, so the
  script and the agent never race on one write.
- Cap: about 250 lines, like 060's handoff.

### 5.3 The hub copy (R7, W7)

After every refresh whose content changed, the box sends the file to the hub
next to the agent's record (the fleet lane row, rdb 0096) as one blob,
**sealed with the hub's KMS key** the way `internal/marketing/seal_kms.go`
seals, and **scrubbed first**: the hygiene sweep's secret patterns (keys,
tokens, PEM blocks, `password=`) are replaced by `[scrubbed]`, and a file
that still matches after the scrub is not sent (one WARN). Only another
box's watchdog, acting under 10.2, and the operator workspace's admin may
read it back. Retention: the last 3 copies per agent, deleted 7 days after
the agent's done marker.

### 5.4 The wip branch (A3, W4)

For a lane, the handoff refresh at 1 h, at 1 h 50 and at every restart
pushes `wip/<id>`: a commit of the dirty tree on top of HEAD, made in a
temporary index (never the lane's own index, never `git stash`), under the
repo's canonical author with message `wip(<id>): <ts> handoff`, pushed with
`--force-with-lease` **to `wip/<id>` only** (never master; 16 Q10). The next
session (same box or another) starts from the lane branch and applies
`wip/<id>` if it is newer than the branch. A lane that finishes deletes its
wip branch in `/exit-clean`.

## 6. Limits (W3, R4, R12)

### 6.1 Restarts per hour

`restart_max_per_hour` (default 3, admin only) counts every restart of an id
in a rolling hour, rebirths included (W3). It replaces 093's
`WD_TAKEOVER_MAX` (2). Past it (R4): the id is **held out**, nothing else
happens automatically (no new lane, no other harness), and the admin gets
ONE message (11.2) naming the id, the box, the causes of the three restarts
and the handoff. The admin's "restart" button clears the hold.

S2 (a login, limit or access screen) still never restarts (W3, W6): it goes
to section 7.

### 6.2 Rebirths per task (R12)

`rebirth_max` (default 7, admin only) caps the planned rebirths of one task
(a lane's brief). The count lives in `lifetime/rebirths` and in the fleet
lane row. At the cap the restart does not start a new session: it pushes the
wip branch, sends the orchestrator `REBIRTH CAP <id> <n> wip=<sha>`, puts one
message to the admin (11.2), and holds the id out until the admin acts.
Crashes do not count toward this cap (they count in 6.1). Seats: 16 Q3.

## 7. Out of quota and login screens (W6, R8)

| case | today (093 S2) | 102 |
|---|---|---|
| login or access screen | ONE owner DM, no restart | ONE admin message (web app + email, 11.2) with a **"login reset"** button; no restart until it is pressed |
| usage limit with a reset time | out until the reset + 120 s, then back by itself; no DM unless every seat of that harness is out | the admin gets ONE message with two buttons, **"login reset"** and **"no tokens left"**; with no answer the agent is restarted after the reset time + 120 s as today (16 Q4) |
| "no tokens left" pressed | - | the id stays held out; the script pushes the wip branch and sends the orchestrator one line; no switch of login or harness (W6) |
| "login reset" pressed | - | the hub writes a `login-reset` event for that OS user and box; that box's watchdog restarts every held-out agent of that OS user and harness (one restart each, counted in 6.1) |

## 8. Generic stuck detection (G1, R13)

### 8.1 The rule: what is absent, never what text is present

**S9 "stuck"** is a new situation script, `situations/s9.sh`. An agent is
stuck when ALL of these hold for `stuck_min` (default 10 min, admin only):

| # | condition | source | why it is text-free |
|---|---|---|---|
| 1 | the harness process is alive | `/proc` | - |
| 2 | no progress: `heartbeat.progress_ts` older than `stuck_min` (093 5.2) | heartbeat | a model event, not a screen |
| 3 | not in a tool within its cap (`state != in-tool`, or past 093 S4's cap) | heartbeat | - |
| 4 | the pane did not change: the same hash of `capture-pane -p` (the spinner line included) on every tick of the window | tmux | any moving spinner, timer or output breaks it |
| 5 | **there was input for the model**: an unread inbox file, a poke, or a 1 h / 1 h 50 notice was delivered in the window, and no `UserPromptSubmit` followed it | spool dir + `heartbeat.log` | a dialog of any wording swallows the poke: the prompt never reaches the model. An idle agent with nothing to do is never stuck |

Condition 5 is the key: it asks "did what we typed reach the model", which no
dialog can fake. An idle agent at its prompt with an empty inbox fails 5 and
is left alone (093 6.2 row "idle agent").

### 8.2 The action

| what S9 sees on the screen | action |
|---|---|
| a **known** dialog (S7's list: modal=0/1/2) | S7's answer, as today: the fleet's choice is bypass, never auto (the modal=2 path writes `defaultMode=bypassPermissions` and answers "No, keep bypass permissions") |
| anything else | send the orchestrator the pane snapshot ONCE (`<spool root>/dispatch/wd/<id>.s9.pane`, scrubbed as 5.3, path in the note), then `do_spl_agent_restart CAUSE=S9`. Nothing is typed into an unknown dialog |

S7 stays as the fast path for known dialogs (1 tick); S9 is the net for the
rest (`stuck_min`). The known list may grow from S9's snapshots, but nothing
depends on it growing.

### 8.3 The proof (G1's fixture control)

| case | fixture | expected |
|---|---|---|
| hit | the 2026-10-06 frozen pane (`tests/fixtures/wd-situations/modal-default-mode.pane`) with its dialog words replaced by words no list contains, a heartbeat whose `progress_ts` is 11 min old, a poke delivered 9 min ago and no UserPromptSubmit after it | S9 HIT; the action is snapshot + restart |
| control 1 (the old guard) | the same fixture through today's S7 | no hit: the list-based check misses it |
| control 2 | the same, but a UserPromptSubmit after the poke | no hit |
| control 3 | the same, but the pane hash changes once in the window | no hit |
| control 4 | an idle pane, empty inbox, no poke, progress 3 h old | no hit |

## 9. CLI updates under control (G1, R14)

### 9.1 Who updates

Self-update is turned off on every agent user (the setting
`env.DISABLE_AUTOUPDATER=1` in `settings/00-fleet.json`; I believe, unchecked,
that the native installer honours it, and the first task proves it before
anything relies on it). `do_spl_cli_update` (csi-spl-orc) updates the CLIs,
run nightly by its cron (`csi-spl:cli-update`, `UPDATE_WINDOW` 02:00-05:00 UTC):

1. **one box at a time**: a hub lease `cli-update` (one row, CAS, 30 min) so
   two boxes never update in the same window;
2. on that box: install the new version beside the old (the native installer
   keeps both), **without** switching the live agents;
3. **a test agent first**: spawn a scratch lane on the new version with a
   one-line brief ("run `./run -a do_spl_cli_selftest`, report, exit-clean");
   it must start, show no dialog, carry the 9.2 flags and settings, and pass
   S9 for 5 min. Fail: roll back the symlink, one admin message, stop;
4. pass: switch the symlink; live agents pick the new version at their next
   rebirth (no mass restart);
5. the next box takes the lease the next night (or the same night after
   `UPDATE_BOX_GAP`, 30 min).

### 9.2 The settings check after every update (and at every start)

`do_spl_agent_mode_check` compares, for every agent user and harness:

| what | must be | source today |
|---|---|---|
| launch flags of each live process | `--dangerously-skip-permissions` (claude); the harness's own auto-approve flag otherwise | `/proc/<pid>/cmdline` (060 FR-063) |
| `permissions.defaultMode` | `bypassPermissions` | `settings/00-fleet.json` |
| `skipDangerousModePermissionPrompt` | `true` | same |
| `permissions.disableAutoMode` | `disable` | same |
| auto-approve of the other harnesses (agy, grok, qwen) | on | their spawn scripts (`spawn-<harness>.sh`) |

It runs after every update (steps 3 and 4) and **before every spawn and
restart** (the spawn re-asserts the settings file from `00-fleet.json`
first, and refuses with one note if it still differs). Any mismatch is
re-asserted to the most permissive mode (R14) and reported once. The flags
come from ONE helper again (060 FR-061's `spool_claude_perm_flags`,
restored), used by spawn, restore, rotation, lane restart and the restart
path.

## 10. Boxes: reboot, down, back (W7, R5, R6)

### 10.1 Reboot

After a reboot, the box's own watchdog keeper (`do_spl_wd_ensure`, every
minute) starts the watchdog, and the watchdog restarts every agent whose
registry row is open, whose running box is this box (10.2) and that has no
done marker, cause `reboot`, through section 4. This replaces the `@reboot`
`do_spl_agent_boot_restore` and the restore scripts as the path; they stay
for one release as a fallback behind `BOOT_RESTORE=1`. 093 6.2's suspend
guard (a tick gap over 3 x `WD_TICK` resets debounces) stays.

### 10.2 Down

- **Box beat**: every box's watchdog writes one row per tick into a new hub
  table `box_beats` (box, `beat_at` at the hub's clock, watchdog pid). Not the
  fleet lease table: 093 6.4 showed a lease row would re-route an agent's
  channel posts.
- **Down** = no beat for `box_down_min` (default 2 min, admin only, R5).
- **Takeover of a down box's agents**: each live box's watchdog, on the tick
  it sees a down box, tries ONE hub CAS per agent of that box: `running_box`
  from the down box to itself, in the fleet lane row. The CAS winner restarts
  that agent from the hub copy of its handoff (5.3) and, for a lane, a fresh
  worktree from its pushed branch and `wip/<id>` (5.4). A box that lacks the
  agent's harness does not CAS that agent (16 Q6).
- **Never two copies**: a box restarts an agent only while it is the
  `running_box` in the hub. A box that cannot reach the hub restarts only its
  own agents whose `running_box` was itself at its last good read.

### 10.3 Back (R6)

A returning box reads `running_box` before it restarts anything (10.1): an
agent now running elsewhere is not started at home. At that agent's next
rebirth, the restart path runs on the home box when the home box is beating
(CAS `running_box` back), and the remote box retires its session. A lane's
remote worktree is removed after its push.

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
| rebirth cap reached (6.2) | one more rebirth cycle, leave stopped |
| CLI test agent failed (9.1) | none (information) |

Each button writes one hub event; the box's watchdog reads its events at
every tick. One message per (id, cause) until it is answered.

## 12. Shared memory (H6, R9)

One shared memory per cloud instance, in the hub, scoped to **how to work in
the spool hub** (R9): traps, commands, conventions. Not task state: what to
do and its context come from the web app (topics, briefs).

- An agent adds a lesson with `spool memory add --title <t> --text <t>`; the
  hub **merges** it into an existing lesson with the same normalised title
  (or an admin merges two) instead of piling up.
- Each agent's seed gets the index (titles + one line), never the bodies;
  `spool memory show <title>` reads one.
- The per-user memory files under the agent user's `.claude/projects/<slug>/memory/`
  stay as they are for now; moving them in is a later task (16 Q7).

## 13. What changes in 060 and 093, and what exists today

| spec rule | today (code) | 102 | check |
|---|---|---|---|
| 060 hourly seat rotation at `:05` / `:15`, its crons | `spl-orch-rotate.func.sh`, `spl-dispatch-rotate.func.sh`, crons `csi-spl:orch-rotate`, `csi-spl:dispatch-rotate`, `csi-spl:dispatch-heal` | trigger moves to the watchdog's session age; mechanics kept (4.4, R11) | `crontab -l \| grep -c 'csi-spl:\(orch\|dispatch\)-rotate'` as the box user -> 2 on the `<pc box>` |
| 060 D1 busy rotated at once | `spl_rotate_quiesce` (grace, Escape) | 1 h is a request; 2 h is the forced end (3) | `grep -n '^spl_rotate_quiesce' csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` |
| 060 section 6 handoff written at rotation | `spl_rotate_handoff` | continuous `<id>/handoff.md` + hub copy; the rotation's file is its snapshot (5) | `grep -n '^spl_rotate_handoff' csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` |
| 060 9 "rotating lane agents: out of scope" | 063's `do_spl_lane_restart` restarts lanes on size | lanes are in (W4) | `sed -n 1,10p csi-spl-orc/src/bash/run/spl-lane-restart.func.sh` |
| 060 FR-061 one flag helper | the helper is gone; a caller falls back to a literal | restored, used by every start (9.2) | section 1 row 6 |
| 093 6.3 `WD_TAKEOVER_MAX` 2 | `spl-watchdog.func.sh` | `restart_max_per_hour` 3, rebirths count (6.1) | `grep -n 'WD_TAKEOVER_MAX:=' csi-spl-orc/src/bash/run/spl-watchdog.func.sh` |
| 093 6.3 third takeover -> owner DM | `spl_wd_takeover` | admin message + email + button (11.2) | `sed -n 666,690p csi-spl-orc/src/bash/run/spl-watchdog.func.sh` |
| 093 S2 limit: back after reset, no DM | `situations/s2.sh` | the admin is told; buttons (7) | `sed -n 1,8p csi-spl-orc/src/bash/features/watchdog/situations/s2.sh` |
| 093 S3 bare shell | `situations/s3.sh` | + a gone pane with an open registry row and no marker (4.3) | `cat csi-spl-orc/src/bash/features/watchdog/situations/s3.sh` |
| 093 S7 list of dialogs | `situations/s7.sh`, `spl_lease_modal_hit` | kept as the fast path; S9 is the net (8) | `ls csi-spl-orc/src/bash/features/watchdog/situations/` -> `lib.inc.sh`, s1..s8 |
| 093 6.2 human guard | `spl_wd_gate` (`WD_HUMAN_IDLE` 120 s) | not for the 2 h end (R3) | `grep -n WD_HUMAN_IDLE csi-spl-orc/src/bash/run/spl-watchdog.func.sh` |
| 093 8 takeover | `spl-wd-takeover.func.sh` | becomes `do_spl_agent_restart`, cause widened (4) | `sed -n 1,30p csi-spl-orc/src/bash/run/spl-wd-takeover.func.sh` |
| 093 10 "no watchdog needs to reach another box" | no box beat; `box_stats` every 5 min (rdb 0117) | `box_beats` + CAS on `running_box` (10.2) | `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats` -> 0 |
| 093 6.4 owner DM via `ASKS_OWNER` | `spl-wd-ensure.func.sh` | the keeper's alerts become admin messages (11.2) | `grep -c ASKS_OWNER csi-spl-orc/src/bash/run/spl-wd-ensure.func.sh` -> 4 |
| boot restore | `spl-agent-boot-restore.func.sh` (@reboot) | the watchdog's reboot path; the old one behind a switch (10.1) | `sed -n 1,16p csi-spl-orc/src/bash/run/spl-agent-boot-restore.func.sh` |
| CLI version | self-updates in place (section 1 row 5) | off; `do_spl_cli_update` nightly, one box, test agent (9) | `ls ~/.local/share/claude/versions` as the agent user |
| settings | `00-fleet.json`: `defaultMode=bypassPermissions`, `disableAutoMode=disable`, no autoupdate key | + `DISABLE_AUTOUPDATER`; re-checked before every start (9.2) | `cat csi-spl-orc/src/bash/features/spool-install/assets/claude/settings/00-fleet.json` |
| per-workspace numbers | `agent_lifecycle_config` (063, rdb 0105), 11 keys | + 4 keys, read from the operator workspace only (11.1) | `grep -c 'Key: "' csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` -> 11 |

## 14. Trace: every owner answer to its section

| answer | section |
|---|---|
| 26db0bb6, 9596fee0, 9bc777da | 3 |
| A1 | 3, 6.2 |
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

## 15. Opinion panel

To be filled in v1.0: the opinions of agy-1, agy-2 and claude-2
(`opinions/<seat>.md`), each verdict, and the agreement.

## 16. Open questions (a safe default is chosen and marked; nothing waits)

| # | question | options | **default** (why) |
|---|---|---|---|
| Q1 | does the 1 h rebirth force a busy agent | (a) ask, the agent picks the step boundary until 1 h 50; (b) Escape at 1 h like 060 D1 | **(a)**: R1/R2 put the force at 2 h; a forced 1 h would make the 1 h 50 notice pointless |
| Q2 | the seats' order (4.2) | (a) start-first with ack (060); (b) stop-first like lanes | **(a)**: keeps 060's never-zero invariants |
| Q3 | does `rebirth_max` apply to seats | (a) lanes only; (b) seats too | **(a)**: a seat's role never ends by design; 7 rebirths would stop the orchestrator after 7 h |
| Q4 | usage limit with a reset time and no admin answer | (a) restart after the reset + 120 s, as 093; (b) wait for the button | **(a)**: the button is the fast path; waiting for a human on a known reset time loses hours |
| Q5 | how often the wip branch is pushed | (a) at 1 h, 1 h 50 and every restart; (b) at every handoff refresh | **(a)**: bounds pushes; a box that dies between pushes loses at most the work since the last one (the hub handoff still says what it was) |
| Q6 | an agent whose harness exists only on the down box (agy today) | (a) it waits for its box, with one admin message; (b) it moves to another harness | **(a)**: W6 forbids switching harness |
| Q7 | the per-user memory files | (a) stay, the hub memory takes new lessons only; (b) imported once | **(a)**, import as a later task |
| Q8 | where the box beat lives | (a) a new `box_beats` table; (b) the fleet lease table | **(a)**: 093 6.4 showed (b) re-routes channel posts |
| Q9 | the agents over 2 h when the rule goes live (A4) | (a) the watchdog's first ticks reborn them, at most one per box per minute; (b) the orchestrator closes them by hand | **(a)**: no box restarts 30 at once, and nothing is done by hand |
| Q10 | `--force-with-lease` to `wip/<id>` | (a) allowed, wip branches only; (b) a new branch name per push | **(a)**: the repo rule bans force pushes to master; one moving wip ref per lane keeps the remote clean. Panel to confirm |

## 17. Rollout (A4)

1. P0: S9 + its fixture control (8.3), the settings check (9.2) and the
   restored flag helper: these close the 2026-10-06 class alone.
2. P1: the continuous handoff (5.1, 5.2), the restart path (4) with the
   session-age rule (3) for lanes; the over-2 h agents are reborn only now
   (A4, Q9).
3. P2: the admin settings and messages (11), the hub handoff copy (5.3),
   S2's buttons (7).
4. P3: the box beat and cross-box restart (10), the seats onto the path
   (4.4), controlled CLI updates (9.1), the shared memory (12).

Tasks: `tasks.md` (written with v1.0).

<!-- version: 0.1.0 · updated: 2026-10-07 · last-edit: 2026-10-07T08:30:00Z -->
