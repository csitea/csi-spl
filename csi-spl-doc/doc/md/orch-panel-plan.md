# Orchestration across boxes: the panel's fix plan

Status: **v1.0, signed by all three seats**, the v0.1 draft with the changes of the grok and mistral
seats folded in (`orch-panel-plan/seat-grok.md` `23bbc57c8`,
`orch-panel-plan/seat-mistral.md` `b464d3136`); section 8 records who signed.
Docs only: this file changes no code, cnf, crontab, lease or seat.
Epic SPL-1308, issue SPL-3906, spec home
[101](../../specs/101-four-orchestrator-dispatchers/spec.md) and
[134](../../specs/134-od-pool/spec.md).
Read on tree `8f1eca452` (origin/master at the editor's start); the
line cites the seats corrected were re-checked by the editor on `8b8834aa8`.
Panel task `dispatch-orch-grok-again`; the owner's topic is t1
`#spool-hub-ops` `6aeebb4d`, where the dispatcher posts this link.

## 0. The owner's order (HUM-10, 2026-10-27, verbatim fragments)

- "the discussion with all of the facts and the root cause analysis and than an expert panel how-to fix the situation"
- "we take the possibility for the grok ONCE AGAIN to do orchestration"
- "one of the options to consider is to have the antigravity start learning the orchestration"
- "I also would like to have multiple orchestrators"
- "that is a new locking mechanism from the msgs to the issues to the lanes which assign a certain orchestrator on certain topic and issues and work"
- "there should be 3 of those ... running simultaneously, but each one of them should do their own work, and take new according to a time based mechanism"
- "if an orchestrator is too slow the next orchestrator should take his job"
- "the time slots by the service should change periodically, but the expert panel should decide"
- "I MUST be able to see every agent on every lane both from the spool-hub ui and also from the tmux on the terminal"; "the tmux access Must NEVER DISAPPEAR"; "when a claude agent is killed its tmux window(s) should be closed too"

## 1. The finding in one paragraph

The owner has already chosen the multi-orchestrator design twice. On
2026-10-06 the panel reached consensus on spec 101 (four ODs on spec 068's
per-message claim). On 2026-10-12 spec 134 v1.0, an OD pool built on one
locked row per job (`fleet_asks`, role `od`), was signed by four seats, and
the owner answered all of its Q1..Q8. Spec 134 is the owner's "locking
mechanism": `lock-next` is a compare-and-set lease on the hub, with lazy
expiry and a gen fence. Its hub op and its seat loop are on trunk, but
turned **off**. So this plan builds no third mechanism. It finishes 134
and adds what 134 lacks for the owner's 2026-10-27 words: a lock that runs
**down the chain** from message to issue to lane, **time slots** for new
work, a **too-slow** handover, and making that lock **visible**. It also
fixes the four box-level defects that broke on 2026-10-27 (RC2, RC3, RC5,
the relay), whatever the design.

## 2. What spec 101 and spec 134 promised, and what landed

Each line was checked with `git log --format='%h %s' 8f1eca452 | grep -E '<task>'`
or `git cat-file -e 8f1eca452:<path>`.

### 2.1 Spec 101 (v0.4.1, 31 tasks): 8 landed, the cut-over never

| task | what | sha |
|---|---|---|
| T001 | lanes go to the box with room (`do_spl_box_pick` overflow weight) | `187301255` |
| T002 | the taking dispatcher spawns its own lanes | `08e0cc98b` |
| T003 | a lane reports to its spawner | `2634869dd` |
| T005 | `do_spl_orch_load_report` | `0a9dd73a2` |
| T007 | D1, the hub router reads only `orch` / `dispatch` rows | `e4d033d8d` |
| T011 | D14, one msg_id across both legs of a peers send | `e650b2a70` |
| T014 | 093 T010, the peer poll loop on the two-phase claim | `0e1b35f37` |
| T020 | D7, the unanswered sweep from every box | `76e32a994` |

Not on trunk: T008/T009/T010 (topic guard, `claim --rebind`), T012 (mutex
release: `grep -n 'never released' csi-spl-orc/src/bash/run/spl-peer-gate.func.sh`
-> line 18), T013, T015..T019, T021 (`spl-peer-setup.func.sh` missing),
T022 (`spl-fleet-od-cutover.func.sh` missing), and every orch measurement
(T006, T024, T026..T029: no `research/m05-numbers.md`, `u4-seat-cost.md`,
`m3-drill.md`). Live on the PC, 2026-10-27T23:15Z: `ls /var/spool-hub/peer`
-> `restart.lock` and `restart.slot.0..4`, **no `seats` file**, so every
101 piece is inert.

### 2.2 Spec 134 (v1.0, owner answered Q1..Q8): P0..P3 landed, off

| step | what | sha |
|---|---|---|
| P0 / T0 | the lease counts a grok or vibe holder | `744186fdc` |
| P1-P2 / T1 | rdb `0183_fleet_asks_od.sql`; `spool ask enqueue, lock-next, renew, release, reopen, pool` | `b9bef50a1` |
| P3 / T2-T3 | `do_spl_od_seat`, `do_spl_od_pool_supervise` (off by default) | `0f296c3fb`, `80907e4d7` |

Not on trunk: P4 ingest (`git grep -c OD_POOL_INGEST 8f1eca452 -- csi-spl-orc csi-spl-api`
-> 0), P5 drill, P6 per-kind cut-over (`spl-orch-inbox` / `spl-take` do not
read `od_pool.kinds`), P8 cut-over. Live: `crontab -l` of the box user
-> 0 lines naming `od`, so no pool seat runs on the PC.

**Why it stopped (the root of RC6):** each spec landed its inert half.
The live half (a drill, a shadow, a switch on prd) needed an orchestrator
step, and nobody owned that step after the lane closed. This plan gives
every live step a row, an owner gate, and a measure-after (section 6).

## 3. Facts re-measured by the editor

The dispatcher's post holds facts 1..12. The rows of this plan rest on
the facts below, each re-measured on the PC (or on sat over ssh) at
2026-10-27T23:15..23:25Z, n = 1 reading each, tree `8f1eca452`:

| fact | command | reading |
|---|---|---|
| F6 seat dirs are links | `readlink /var/spool-hub/{a,g,m,q}-001` | all `-> c-001`; `c-002 -> g-002` (the dispatch seat on the PC is grok's dir) |
| F8 queue stands still | `./run -a do_spl_spawn_queue` (PC) | `57 queued, 0 placing`; 35 rows `WAIT ... its brief <slug>.md is not under .../dispatch/briefs on <PC>: it was queued on sat` |
| F8 why | `sed -n 143p csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` | `the orch role is held on <box>: its machine places`: only the role holder's box places |
| F9 load flipped | `uptime` on both | PC 21 / 16 / 10 on 16 cpus; **sat 74 / 83 / 89 on 16 cpus**: the reverse of fact 9 six hours earlier |
| F11 bare pane | `grep -ah 'HIT S3' wd.log.1 wd.log \| grep 'runs only'` | 18 hits, 10-26..27 (11 takeovers on 10-27); the older days are rotated out, so the 5-day count of 54 is **not re-measured** |
| F4 restore skip | `sed -n 171,181p csi-spl-orc/src/bash/run/spl-agent-identity-restore.func.sh` + the live panes | the restore skips a window whose pane pid is not a plain shell; a dead seat's pane pid is still `sh -c env ... spawn-claude.sh <id> ...` (seen on 4 live panes) because the launcher ends in `exec env HISTSIZE=-1 ... bash --norc` (`spawn-core.inc.sh`, the fallback after `_sp_live`; line 735 on `8b8834aa8`) under that `sh` |
| F6 heartbeat | `sed -n 591,598p .../spool-agent-hook.sh` | the hook writes `<spool root>/<AGENT_ID>/heartbeat.json`; through a link, two sessions write one file |
| lease now | `LEASE_CMD=show ./run -a do_spl_dispatch_lease`; `cat dispatch/lease.orch` | dispatch `c-002@sat`, orch `c-001@sat` |
| F10 relay | `sed -n 165,177p .../spool-fleet-relay.sh`; `grep -n 'hub relay failed' .../spool-send.sh`; `ls /var/spool-hub/dispatch/relay.log` | rc 1 = "send via <box> failed": `say` writes stderr, `spool-send.sh` prints the rc without the hub's body, and `relay.log` does not exist, so no log names the cause. **Not reproduced**: this lane's one live send PC -> sat (msg `73559f4a`) arrived, n = 1; neither seat reproduced a failure |
| grok speed | [grok-dispatch-grade-2026-10-25.md](grok-dispatch-grade-2026-10-25.md) section 5 | first reply within 3 min: grok 19.3%, claude 79.4%; median 481 s vs 40 s (matched hours) |
| grok turn | the dispatcher's post, fact 5 | one 27-min turn, 26..37 messages queued: **taken from the post, not re-measured**; the grok seat found 0 lines for 2026-10-27T13..14Z in `g-001/heartbeat.log` (rotated), so no per-task list of that turn exists |

The seats re-measured further facts on their own trees (both files,
section 2): the seat links, the restore skip, the heartbeat path, the
place gate, the early-limit function, the supervisor defaults 2 / 2, and
no pool line in the box crontab. Their readings agree with the table
above; the corrected line cites are in the rows of section 5.

## 4. Decisions the panel must take (the editor's proposal)

### 4.1 Three orchestrators, one lock per chain

- **Three OD seats** in `od_pool` (spec 134 3.1): today `claude_n = 2,
  grok_n = 1`, `min_boxes = 2` (one box down leaves at least one seat).
  The seats are spread over two logins, so one vendor limit stops at most
  two of the three. agy joins after its drill (row O2), not before
  2026-10-30, and **replaces** a seat: the live count stays 3.
- **The chain.** A human post becomes a `route_post` row. Every row it
  causes (`spawn`, `lane_verify`, `box_op`) carries the root's
  `chain_id` = the root's `ask_id`. The **chain lock** is the root row's
  lock: whoever holds the root holds the chain. A child row is lockable
  only by the chain holder while the root's lock lives, and by anyone once
  it lapses (spec 101 D12's topic guard, moved from `messages` to
  `fleet_asks`). The issue card and the lane's registry row get a pointer,
  `od=<seat> chain=<ask_id>`, never a copy: the authority is the hub row
  (134 Q4 = B).
- **Taken / held / handed over / released.** Taken: `lock-next` (one SQL
  statement, 134 3.3). Held: the seat loop renews every 15 s while able.
  Handed over: by lapse or by a too-slow revoke (4.3), which bumps `gen`, so
  the old holder's next act is refused with a 409. Released: `done` /
  `decline`, or the supervisor's release-on-kill (134 3.3), when a seat dies
  or rotates (spec 060). Rotation keeps the chain: the new session renews
  under the new gen (134 P8).
- **Never two actors.** Every outward act (post, spawn, close) carries
  `(ask_id, gen)`; the hub refuses a stale gen. Red control in row O3.

### 4.2 Time slots for new work

- **Slot length `OD_SLOT_S` = 900 s.** In each slot one seat is the
  *intake* seat: a row younger than `OD_SLOT_GRACE` = 60 s may be locked
  only by that seat. An older row may be locked by any able seat, so a
  dead or slow intake seat delays new work by 60 s at most, never more.
- **The order rotates every slot**, round robin over the able seats, so
  each seat takes new work about one slot in three. Work a seat already
  holds is unaffected: "each one of them should do their own work".
- **Per-vendor shares change every 24 h** (`do_spl_od_slots_rotate`, under
  the `fleet-config` mutex). The shares follow the last 24 h's median
  lock-to-first-act per vendor: a vendor twice as slow gets half the
  intake slots. The floor is one slot in six, so a vendor is never starved
  of the measurement that could restore it.
- **Why these periods:** 24 h holds about 70..190 human posts (the grade
  measured 2.8 posts/h in grok-held hours and 8.1 in claude-held hours,
  section 3), enough n for a median per vendor. A
  shorter period re-weights on noise. Spec 068 F5 is the warning: a
  half-applied rank flipped the orch 203 times in 3 h. 900 s is short
  enough that a seat's intake never runs past its context budget between
  two hourly rotations (spec 060). It is the **intake window** for new
  rows, not a turn budget: a grok turn can run longer than a slot, and the
  next slot simply takes the new rows.

### 4.3 Too slow: the threshold

- **`OD_SLOW_S` per kind**, counted from lock to the first act: a reply,
  a park, an enqueue or `done`. `route_post` 600 s, `lane_verify` 900 s,
  `spawn` 900 s, `box_op` 1800 s. No act by then: the hub refuses the next
  renew. The row goes back to `open` with `gen + 1` and `raised_n + 1`, and
  the next lock-next (any seat but the slow one, for that row) takes the
  whole chain.
- **Why 600 s for `route_post`:** grok's median first reply was 481 s,
  so the normal grok case keeps its job. The 27-min turn (1620 s) of
  2026-10-27 would have lost it at 600 s, and the queue it held (26..37
  rows) would have been with the other two seats from the start: a seat
  locks one row at a time (134 3.4), so a queue cannot build behind one
  seat. The SLA is 3 min (fleet roles section 3). 600 s is the
  hand-over line, not the SLA.
- **Back-off:** a seat with 2 revokes in 60 min gets no intake slot for
  the next 2 slots, and the supervisor logs it. 3 revokes = the seat is
  replaced (134 4.2). Each number is a cnf key, re-measured at the drill.

### 4.4 grok and agy learn the role

- **The runbook exists** ([runbook-orchestrator.md](runbook-orchestrator.md)
  v0.3.0: 22 of its lines carry a `cd ...` or `./run -a ...` command; section 9 lists the gaps for a non-claude
  seat). What it lacks is a **cadence table**: every recurring task with
  how often it runs, its exact command and its expected time. It also needs
  a timed **drill** that measures it.
- **The drill** (`do_spl_orch_drill`): one hour, the same fixture of
  recurring tasks (ask open/ack/close, a spawn placement, a lane verify,
  a hang check, a prd read refusal path) given to a claude seat and a
  grok seat at once on dev. Per task: time to done, and right or wrong
  against a known answer. n >= 5 per task per vendor.
- **What a grok seat does differently** (grok seat, section 5). A grok turn
  runs its tool chain to the end before it yields, so the cadence table
  (row O1) says, for every seat: one task per turn, never a whole inbox
  in one serial chain; re-read `LEASE_CMD=show` right before each outward
  act (the chain gen does not cover the dispatch lease); ack only the set
  just acted on, and only while a fresh recv still shows that set; the
  hang check reads the vendor's own session dir (`~/.grok/sessions` for
  grok; the runbook's transcript reader looks only under
  `~/.claude/projects` today). Expected times include the tool cost and
  get an orchestrator median only from the drill.
- **agy** runs the same drill after 2026-10-30. It joins `od_pool` only
  when its drill passes the line grok's must pass (row O2).

### 4.5 The tmux pane never disappears, and a dead harness is never bare

The owner's two tmux words read together: a window stays while its agent
id lives. When the session dies, the window gets a **new session in place**
(`respawn-pane -k`); a pane is never left on a bare shell. When the agent
is **retired** (killed on purpose), its windows close first: the close
path `tmux-close-window.sh --agent <id> --retire` does that today, and
`agent-id-retire.sh:125` refuses to retire an id while a window carries
it. Rows B1, B2.

## 5. The fix rows

Paths: `orc/` = `csi-spl-orc/src/bash/`, `sa/` =
`orc/features/spawn-agents/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`.
Vendor per the fleet's kind table: `complex_coding` and `simple_coding`
main claude, backup grok. No mistral coding row.

| row | RC | owner point | what | sites (tree `8f1eca452`) | red control (seen RED, then GREEN) | measure-after | vendor | batch |
|---|---|---|---|---|---|---|---|---|
| **B1** | RC2 | d | The restore treats a window as live only if a harness process carries the id (`spl_lease_agent_pid`), not if the pane pid is "not a plain shell". A dead seat's window gets `respawn-pane -k` in place: no close needed first, no window lost | `orc/run/spl-agent-identity-restore.func.sh:171-181`; `sa/scripts/spawn-core.inc.sh` (read only: the `exec env HISTSIZE=-1 ... bash --norc` fallback, lines 94 and 735 on `8b8834aa8`) | fixture: pane pid cmdline `sh -c env ... spawn-claude.sh c-9xx ...`, no harness child -> today `SKIP a live window already carries it`, after: `START` in the same pane; control: the same with a claude child carrying `SPOOL_AGENT_ID=c-9xx` -> `SKIP` | the next limit episode: restored / dead = 9/9 with 0 windows closed by hand (2026-10-27: 5 of 9 needed one) | claude (simple) | 1 |
| **B2** | RC3 | e | One seat, one session. `role-seat-switch.sh` stops linking the seat's other letters to one dir; mail to an old letter is forwarded by the registry alias. The hook refuses to write a heartbeat into a dir whose real name is not its `AGENT_ID`. The watchdog reads a heartbeat only when `.id` and `.pid` match the process it judges. The failover ends the old session **before** it starts the new one: today `spl_rotate_spawn` runs first (line 265) and `spl_role_failover_end_old` follows at 269 only when the new id is the seat id, else the old pid is ended at 295-306 after the new seat acks; the end moves before line 265 | `sa/scripts/role-seat-switch.sh:87-121`; `sa/scripts/spool-agent-hook.sh:111, 591-598` (no realpath of the dir); `orc/run/spl-watchdog.func.sh:876`; `orc/run/spl-role-failover.func.sh:214-217, 265-269, 295-306` | fixture: `c-001 -> g-001` link, a hook run as `AGENT_ID=c-001` -> today it rewrites g-001's heartbeat, after: unchanged + one `REFUSE` line; control: `AGENT_ID=g-001` -> written. Failover fixture: the old pid is gone before the new spawn's first tick | `readlink /var/spool-hub/*-00[1-3]` -> 0 links after the next switch; no lease `ABLE` line for a seat whose pid has another vendor (`lease.log`, 7 days) | claude (complex) | 1 |
| **B3** | RC5 | f | Briefs travel with the row, and any box places. `spawn enqueue` stores the brief text (cap 64 KiB) in the queue row; the placer writes it to its local `dispatch/briefs` before it places. The "holder's box places" gate goes, and the `spawn` mutex orders the placers | `orc/run/spl-spawn-place.func.sh:143` (the gate), `:461` (the no-brief hand), `spl_spawn_place_away_hold` (:725), `spl_spawn_place_brief` (:741); `orc/run/spl-spawn-enqueue.func.sh`; `api/internal/store/fleet_ask.go`, `fleet_ask_postgres.go`, `fleet_ask_queue_test.go`, `fleet_ask_test.go` (the queue's brief column; **never** `fleet_ask_od*.go`, which O3/O5/O7 own) + a new rdb migration | fixture: a row queued on box A, no file on box B, B places -> today `WAIT its brief ... is not under`, after: placed, brief sha256 equal on both boxes; control: no brief text in the row and no file -> `WAIT` | `do_spl_spawn_queue` on both boxes: `0 WAIT ... not under` rows, and placed per hour > 0 whenever the queue is not empty (24 h) | claude (complex) | 2 |
| **B4** | RC6 | g | The cross-box relay says why it failed. The relay appends rc, the hub's answer and the target to `dispatch/relay.log`. A named check `do_spl_relay_check` sends one `note` per direction to the probe inbox of the other box's role seat and reads it back. The cause a logged failure names is fixed in a **follow-up row**, filed once one failure has been reproduced and named: no fix is guessed before that | `sa/scripts/spool-fleet-relay.sh:165-177`; `sa/scripts/spool-send.sh:450-460`; new `orc/run/spl-relay-check.func.sh` + test | stub hub that exits 1 with `from_not_announced` -> one `relay.log` line naming it, exit 1; control: a stub that commits -> no line, exit 0 | 20 sends PC -> sat and 20 sat -> PC, each found on the hub by msg_id: 40/40 | claude (simple) | 2 |
| **O1** | RC4 | a | grok runbook: a cadence table of every recurring orchestrator task (how often, exact command, expected time) in the orchestrator runbook (a Qto export: edit the Qto doc, then re-export), plus the four grok rules of section 4.4 (one task per turn, the lease re-read before each act, the narrow ack, the vendor's own session dir in the hang check). No orchestrator median goes in before the O2 drill | `csi-spl-doc/doc/md/runbook-orchestrator.md` via `do_spl_doctree_export_md` | (doc row) the drill fixture of O2 holds exactly the tasks of the table: `do_spl_orch_drill --list` vs the table's rows -> equal; control: a task removed from the table -> the check fails | every task in section 2 of the runbook has a cadence and a time | claude (docs; agy main is out until 2026-10-30, agy reviews the text after) | 3 |
| **O2** | RC4 | a, b | `do_spl_orch_drill`: the timed drill of section 4.4, claude vs grok in the same dev hour. Later agy, with the same pass line: per task the median within 2x claude's and at least 90% right. 600 s is the lock rule of O7, **not** a drill cap: a task whose tool cost is long but within 2x claude passes | new `orc/run/spl-orch-drill.func.sh` + `orc/tests/orch-drill.tst.sh` | stub seat that never acks -> that task `FAIL timeout` and the vendor fails; control: a stub that acks in 5 s -> `PASS 5s` | grok drill: n >= 5 per task, the pass line met or the miss named per task; agy: the same after 2026-10-30 | claude (simple) | 3 |
| **B5** | RC2, RC1 | d | The limit lifted early is seen. When a seat of the same vendor and login on the box finishes a good turn while other seats of that login are parked on S2 `kind=limit`, the parked seats get their wake (or a restore if their pane is bare) at the next tick, not at the banner's reset | `orc/run/spl-watchdog.func.sh:1204-1236` (`spl_wd_s2_limit`) | fixture: seat A parked until 16:00Z, seat B (same login) writes a good-turn heartbeat at 14:20Z -> A woken at the next tick; control: no able peer -> A waits | the next early lift: every parked seat able within 2 ticks of the first good turn (2026-10-27: all waited for a hand restore) | claude (simple) | 3 |
| **O3** | RC6 | c | The chain lock (4.1): a `chain_id` on `od` rows, child rows lockable only by the root's holder while the root lock lives, and every act op checked on `(ask_id, gen)` | `api/internal/store/fleet_ask_od.go` (`odLockable` :229, `LockNextOdJob` :106-109, :332), its Postgres twin, `fleet_ask_od_test.go`; a new rdb migration (`chain_id`) | two seats, one chain of 3 rows, concurrent: seat B's `done` on a child of A's chain -> 409 naming A, n >= 50 races, exactly one actor per chain; control: A's root lock lapses -> B locks the root and then the child | the dev drill: 0 chains with two acting seats in 100 posts | claude (complex) | 4 |
| **O4** | RC1 | c | Three seats, two vendors, two logins: the supervisor keeps `od_pool` targets 2 claude + 1 grok over `min_boxes = 2`, refuses a placement that puts all three on one login, and fills from the other vendor when one is out (134 4.3) | `orc/run/spl-od-pool-supervise.func.sh` (target and placement only), `orc/tests/od-pool-vendor.tst.sh` | fixture: one claude seat dies, claude not wholly out -> refilled to 2 + 1 within one supervise tick; claude wholly out with `OD_ACCEPT_ONE_LOGIN` unset -> the pool stays at 1 grok (never three seats on one login), with the flag set -> 3 grok; control: claude back -> 2 + 1 again. The supervisor defaults (2 / 2 today) change to 2 / 1 | in the dev drill: every claude-out case has at least one able seat within 5 min, n >= 5 | claude (complex) | 4 |
| **O5** | - | c | The time slots of 4.2: the intake gate in `lock-next`, and `do_spl_od_slots_rotate` writing the order and the vendor shares | `api/internal/store/fleet_ask_od.go` (the lock statement, after O3); new `orc/run/spl-od-slots-rotate.func.sh` + test | fake clock: intake seat A; B's lock-next on a 10 s old row -> 0 rows; at 61 s -> B gets it; control: A at 1 s -> gets it. Rotate: a vendor with 2x the median -> half the slots, never under 1 in 6 | in the dev drill: no new row waits more than 60 s for an able seat; each seat's intake share within 10% of its slot share over 24 h | claude (complex) | 5 |
| **O6** | - | c, d | Make the lock visible: in the WUI, the issue card and the topic header show `orchestrator: <seat>, locked until <time>`, and the "OD jobs" list (134 3.4) lists every live chain. In tmux, the seat loop sets a window option `@od` (chain count, oldest age), which the status line shows | the issue card and topic header components under `csi-spl-wui/` (i18n keys in every locale); `orc/run/spl-od-seat.func.sh` (the tmux option only) | e2e on the mock: a locked chain shows its seat; control: a free chain shows "free". tmux fixture: the option is set on lock and cleared on done | the owner sees every chain's seat from both, checked on dev and prd after the cut-over | claude (UI: never mistral) | 5 |
| **O7** | RC4, RC6 | c | Too slow (4.3): the hub refuses a renew past `lock_at + OD_SLOW_S[kind]` with no act stamp, and re-opens the row for the other seats; the seat loop drops the job on that 409; the 2-revoke back-off. Because a grok turn does not yield until its tool chain ends, the revoke also **interrupts the live pane** of the slow seat, and the gen fence refuses any late outward act on the old gen. Then the live half of 134: P4 ingest on dev, the P5 drill with this plan's numbers, P6 one kind at a time on prd | `api/internal/store/fleet_ask_od.go` (renew, after O5); `orc/run/spl-od-seat.func.sh` (the 409 path, after O6); 134 P4..P6 | fake clock: no act by 601 s -> renew 409, row open, the slow seat's pane gets the interrupt, seat B locks it and acts, and the slow seat's late post on the old gen -> 409; control: an act at 300 s -> renew OK past 600 s | grok as one of the three on prd: p95 lock-to-first-act <= 600 s, 0 rows held past `OD_SLOW_S`, 0 double answers, 7 days | claude (complex); P5/P6 = orch steps | 6 |

Twelve rows: B1..B5 fix the box, whatever the design; O1..O7 build the
owner's design.

### 5.1 Batches: two lanes at a time, files disjoint within a batch

| batch | lanes | why this order |
|---|---|---|
| 1 | B1 ∥ B2 | the 2026-10-27 breaks first: a dead seat comes back, and one seat is one session |
| 2 | B3 ∥ B4 | the queue moves and the relay says why, before any seat runs on the other box |
| 3 | O1 + O2 (one lane: the table and the drill that checks it) ∥ B5 | grok's role proof starts while the build goes on |
| 4 | O3 ∥ O4 | the chain lock and the three-seat pool |
| 5 | O5 ∥ O6 | O5 follows O3 (`fleet_ask_od.go`); O6 is UI plus the seat loop's tmux option |
| 6 | O7 | after O5 (`fleet_ask_od.go`) and O6 (`spl-od-seat.func.sh`); then the live steps |

`fleet_ask_od.go` is the one hot file: O3 -> O5 -> O7 in that order,
never two at once. B3 adds a column to the queue rows in `fleet_ask.go`
and `fleet_ask_postgres.go` only (batch 2, before O3), so batch 2 and the
od lock files stay disjoint.

### 5.2 Spec 101 is closed by this plan

Spec 101's open tasks build on the `messages` claim, which 134 Q8
(owner: A) keeps inert until it is deleted. They are not built. The
spec 101 deltas this plan carries over: D12 (topic guard) -> O3, D13 (gen
rotation) -> 134 P8's renew-under-new-gen, D2 (a capability per seat) ->
134's `needs = prd`. One doc commit after v1.0 marks spec 101 "superseded
by 134 + orch-panel-plan" (status line only).

## 6. Owner gates

| gate | rows | why |
|---|---|---|
| a new rdb migration reaches the prd database on the CI deploy | B3 (queue brief column), O3 (`chain_id`), O5/O7 if they add a column | a hub migration is a GCP mutation |
| the OD pool supervisor's cron on a box | O4, O7 (134 P3 `do_spl_od_pool_supervise_install_cron`) | a box crontab |
| a live seat started, switched or retired by the cut-over | O7 (134 P6 per kind, P8) | a live seat and the lease |
| `od_pool` row written on prd (targets, kinds, slots) | O4, O5, O7 | fleet config on prd |
| `do_spl_relay_check` sending on prd | B4 | a prd write (two notes); read only otherwise |
| none (lands and runs without a go) | B1, B2, B5, O1, O2 (dev drill), O6 (UI, behind the cut-over) | box-local code with tests; the drill runs on dev |

No row touches IAM.

## 7. Open points: how the panel decided

1. **Relay (B4):** still not reproduced (one PC -> sat send arrived,
   n = 1; neither seat sent one that failed). B4 builds the log and the
   check; the fix of the cause is a follow-up row once a failure is named.
2. **Three seats, not 134's 2 + 2:** both seats agree. The owner's "3 of
   those" is the pool target; agy replaces a seat after its drill, so the
   live count stays 3.
3. **The 600 s line:** both seats keep it as the `route_post` hand-over
   line (O7). It is not a drill cap (O2). The 481 s median is a dispatch
   grade, not an orchestrator median; the drill brings the first one.
4. **Slot length 900 s:** both seats keep it, as the intake window for
   new rows, not as a turn budget (section 4.2).

## 8. Panel

| seat | agent | file | verdict | signed |
|---|---|---|---|---|
| editor | c-871 (claude) | this file | v1.0 folds both reviews | yes, `ed2b5f74b` |
| grok | g-119 (`c001-orch-panel-seat-grok`) | `orch-panel-plan/seat-grok.md` `23bbc57c8` | agree the shape; 9 changes (B1, B2, B3, B4, O1, O2, O4, O5, O7), all folded; no reject | yes, `93e74bbb5` (plan `ed2b5f74b`) |
| mistral | m-125 (`c001-orch-panel-seat-mistral`) | `orch-panel-plan/seat-mistral.md` `b464d3136` | agree all 12 rows; no change | yes, `5219fe84b` (plan `ed2b5f74b`) |

<!-- version: 1.0 · updated: 2026-10-28 · last-edit: 2026-10-28T02:50:00Z -->
