# 101: four orchestrator-dispatchers acting at once

Status: **v0.4.1, panel consensus, 2026-10-06** (v0.1 `366acebe`, v0.2 `56783cf5`, v0.3 `055a0cf6`, v0.4 `7ca00033`). Build: lanes start on consensus (owner rule 2026-10-05); M2 and M4 still need the owner's go (section 10). Spec only: no code, cnf,
`lease.conf`, crontab or seat was touched by this lane.
Author: c-387@sat (the pen; claude, standing in for the agy seat: no agy
binary on sat). Reviewers: r1, r2, r3 (claude, standing in for agy and grok),
notes under [research/](research/).
Topic: owner DM t1 `e05fb2f8-cba5-46f8-b101-0a5a57cdb8e8`; panel spool task
`cc7726e7-55b7-43a7-865b-eeeab5c75c3a`.
Builds on: [068 peer seats](../068-peer-seats/spec.md) (four ODs per box, the
per-message claim, the mutexes, the hourly seat restart),
[093 agent watchdog](../093-agent-watchdog/spec.md) (heartbeat, the two-phase
claim, the 2-minute takeover), [060 role rotation](../060-role-rotation/spec.md),
[SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md) (what runs
today).

`<pc box>` stands for the PC's box tag (box tags are banned literals in this
tree, as in specs 064, 068 and 093).

## 0. What the owner asked (HUM-10, DM t1 `e05fb2f8`, ~17:00Z, verbatim, in order)

> msg `1b75c810`: "the tank-001 is overwhelmed and probably the single bottle neck"

> msg `8d517a39`: "now that we have the watchdog service could we start
> introducing more orchestrators"

> msg `f166b118` (after c-002@sat offered to flip `LEASE_PRIORITY_ORCH` to sat
> first now, then a spec for one orchestrator per box): "the DOs - 4 of them"

Reading (c-002@sat, accepted by c-001@sat): **four orchestrator-dispatchers
(ODs) acting at the same time**, replacing today's one orchestrator + one
master dispatcher (+ a standby failover). "DOs" is read as "ODs", the
glossary word of 068.

## 1. The finding: the owner already decided this design on 2026-10-03, and most of it is on trunk

Spec 068 ("orchestrator dispatchers (ODs) - four per box, each dispatches and
orchestrates", v0.4.2) is the owner's own answer to the same bottleneck. Its
owner answers (068 section 1.3, t1 `1068e306`) fixed: four ODs **per box**,
ids `001..004` reserved for them, two claude + two grok per box, every OD
polls the hub every 5 s and locks what it takes, a responsible agent on every
message, a fresh session per seat every hour, build first then hand over
(order A). Spec 093 (v0.2, panel consensus 2026-10-05) then split 068's
one-step claim into a round by code and an accept by the agent (093 section
4), so a seat whose model is dead never owns a job.

**What the numbers say the bottleneck is** (r1, measured on sat, tree
`ccd87045`, read from the local spool root and transcripts; detail and
commands: [research/r1-grok-standin.md](research/r1-grok-standin.md) section 2):

| # | measured | n |
|---|---|---|
| E4 | the orch session on sat was idle (gaps over 60 s) 54% of 2026-10-05 00..13Z: not out of time | 9569 transcript entries, 13 h |
| E6 | 92% of the messages to `c-001@sat` came from lanes; 70% were results and notes | 1656 messages, 48 h |
| E7 | 82% of the asks were raised by a dispatcher to the orchestrator; 124 of the 147 dead asks too | 700 asks |
| E8 | 45% of the done asks needed a re-raise; each raise roughly triples the wait (median 8.3 -> 18.8 -> 56 min) | 506 done asks |
| E10 | two orchestrators already act: `c-001@sat` spawned 20 lanes 15:34..17:01Z while `lease.orch` named `c-001@<pc box>` | 20 registry rows |

So the bottleneck is **attention and routing**, not seat count: a doorbell
missed on a busy pane, and a queue fed by dispatchers and lane reports that
fleet-roles section 3 and 093 4.4 already send elsewhere. More seats do not
fix a missed doorbell. This spec therefore does both, in order: the routing
fixes first (step M0.5, no owner go, measurable in a day), then the seats
(the owner's ask, and the fix for availability: one hung decider).

So this spec does **not** design a second mechanism. It answers the brief's
seven questions against 068 + 093, names the few deltas that today's request
and today's failures add (section 9), and orders the remaining build and the
cut-over (section 8).

### 1.1 What is on trunk (tree `ccd87045`, `git log --oneline origin/master | grep -E '<lane>'`)

| piece | spec | trunk sha | state |
|---|---|---|---|
| claim columns, box frame `claim`, `spool claim` | 068 L1 | `18bd0356`, `51b006f6` (rdb 0110) | on trunk |
| answer once (responsible + gen + unique) | 068 L2 | `05ec062d` (rdb 0111) | on trunk |
| poll loop, peer-ensure, local lock, fence | 068 L3 | `65a3280b` | on trunk, inert |
| `--to orchestrator` -> `peers`, ask lock on the message | 068 L4 | `b41e3a6b` | on trunk, behind the seats switch |
| mutexes `spawn` / `prd-<target>` / `fleet-config` + fence | 068 L5 | `de225638` | on trunk, inert |
| seat restart, distill, `do_spl_peer_crons` | 068 L6 | `89b149e4` | on trunk, crons not installed |
| responsible seat in the WUI | 068 L8 | `43be56e6`, `f48f765f` | on trunk |
| login-expired seat not able (P0) | 093 T001 | `976e6f94` | on trunk |
| hooks: heartbeat, inject, Stop block | 093 T002/T003 | `1dd69389`, `c7bd865b` | on trunk |
| box watchdog S1..S8, takeover, keeper, lease reads `wd.<id>` | 093 T004..T007 | `65fed4cd`, `ff30ad81`, `cf379d0a`, `b11e0aca` | on trunk; keeper cron live on sat |
| claim rounds: rdb 0132, store T1..T10, frames + CLI | 093 T008/T009 | `3e0765e4`, `952edb75`, `4e8a5fff` | on trunk |

### 1.2 What is missing

| piece | spec | blocks |
|---|---|---|
| seats setup (`do_spl_peer_setup`) + the live drill | 068 L7 | the cut-over |
| poll loop on the two-phase claim (rounds, anchor renew, reconcile, `PEER_PROGRESS_MAX` removed) | 093 T010 | the cut-over (without it the loop claims in one step, the 2026-10-05 failure) |
| hub-down `.offer` / `.accept` files | 093 T011 | hub-down safety only; not the cut-over |
| fleet-roles doc rewrite | 068 L9, 093 T012 | nothing (lands after) |
| staged hand-over + delete the role code | 068 L10 | nothing (the last step) |

### 1.3 What is live (measured on sat, 2026-10-06T17:04Z, as the agent user, n = one box)

| check | result |
|---|---|
| `ls /var/spool-hub/peer` | `restart.lock` only: **no `seats` file**, so every peer piece is inert (the switch, 068 L4/L5) |
| `crontab -l` of the box user, `# csi-spl:` tags | `orch-rotate`, `dispatch-rotate`, `unanswered-sweep` present; no `peer-restart`, `peer-distill`, `peer-ensure`; `wd-ensure` present |
| `lease.conf` (`LEASE_*` keys) | `LEASE_ORCH=c-001`, `LEASE_MASTER=c-002`, `LEASE_FAILOVER=c-003`, `LEASE_PRIORITY_ORCH=<pc box>,sat,...`: **the interim flip had not landed on sat yet** |
| `dispatch/lease`, `dispatch/lease.orch` | both held by the `<pc box>` (`c-002@<pc box>`, `c-001@<pc box>`) |
| 093 hooks for the OD seats on sat (r1) | not live: `ls /var/spool-hub/c-001/heartbeat.json` -> no such file; `crontab -l \| grep -cE 'csi-spl:(wd\|peer)'` -> 1 (`wd-ensure` only). The inject hook (093 7.2), the fix for the missed doorbell, is not running |
| rdb 0110 / 0111 / 0132 applied on dev and prd | **yes, inferred** (c-001@sat, msg `ca4e9399`, ~17:1xZ, n = 1): hub `/version` on dev and prd reports `schema_head 0139_calendar_full_edit.sql` (commit `351d63e8`, v2.1.5), and the deploy's migrate step applies every file in order. Not checked: the migration table rows (a prd DB read). M2 re-checks them before M4 |
| interim flip (M0) | **done** on both boxes after this reading (c-001, msg `ca4e9399`): `LEASE_PRIORITY_ORCH` sat first; sat has held the orch role since 17:06:08Z |

## 2. Words

068 section 2 and 093 section 2 hold them; this spec adds none. **OD** = one
of the seats `001..004` on a box, each a dispatcher AND an orchestrator.
**Seat** = the slot (`<id>@<box>`, harness); the session in it is replaced
hourly. **Job** = a `messages` row that needs an OD.

## 3. Partition: exactly one OD decides each item (brief question 1)

### 3.1 Options

| option | how the work is split | a dead OD | 2026-10-06's duplicate spawns | verdict |
|---|---|---|---|---|
| a. static, per box (each box's OD owns its box's lanes) | by origin box | its box's items wait for a takeover | still possible across boxes for a web post (every OD seat is in every channel) | no: re-creates one SPOF per box; sat idle, PC overloaded stays so |
| b. static, per workspace / tenant / channel | a hash or a table of ownership | that partition starves until reassigned | prevented only if the table is right everywhere at once (068's F5: a half-applied rank flipped the orch 203 times in 3 h) | no: a reassignment is exactly the lease problem, times N |
| c. claim per topic, first writer wins on the hub | per topic | the topic is stuck until its claim expires | prevented | partly: this IS (d) for the opening post |
| **d. claim per message, two-phase, on the hub (068 4.1 + 093 4)** | per job: the first accept wins; a follow-up's first round goes to the topic's owner seat (093 4.3 stickiness) | its jobs go free at `anchor + 120 s` and the next round goes to another seat | prevented per job by the claim (r2 2.1), per topic by D12, per lane by D5 (intent before act) | **recommended: it is the owner's 068 design, and it is built** |

**Recommendation: d.** Exactly one decider per job is a database property
(one `UPDATE ... WHERE claim_state = 'offered' AND offer_n = $n`), not an
agreement between sessions.

**But d alone is exclusive per MESSAGE, not per topic, ask or lane** (r2,
[research/r2-claude.md](research/r2-claude.md) sections 2..3, proof in its
section 7). What is proven and what is added:

| unit | exclusive by | proof / delta |
|---|---|---|
| a message, hub actions (post, answer, forward, park, done) | the accept row lock + gen-checked holder calls + answer-once's key | proven on trunk (r2 2.1: `message_claim.go` 594, 608; `answer_once_postgres.go` 19); `go test ./internal/store/ -run 'Claim\|Round\|Lease\|Answer'` -> ok (tree `ccd87045`, n = 1) |
| a topic | **D12**: the accept (T2) is refused while another seat holds a live owned or parked job of the same `(tenant, task_id)`, the topic's open rows locked in `msg_id` order (or an advisory lock on the topic) before the check; T1 opens no non-sticky round for a row whose topic is held, so a follow-up waits for its owner (at most 125 s when the owner is dead) instead of lapsing away after 20 s | stickiness alone is a preference: a fresh owner inside a 10-min tool call misses its 20 s round, and another seat owns the follow-up (r2 3.1) |
| a lane (and any local side effect: spawn, kill, deploy) | **D5 as merged with r2's D11**: intent before act. Before the spawn, the holder writes the lane id (derived from `(task_id, slot)`) to the job under its gen (`--park --wait <lane id>`); the spawn refuses when that lane or worktree exists; the next owner inherits `wait_token` | the gate is check-then-act: a pause past the 120 s mutex, or a death between spawn and park, gives a duplicate lane (r2 2.2) |
| a seat across a restart or takeover | **D13**: before the new session starts, one hub op (`spool claim --rebind <seat>`) bumps `responsible_gen` on every job the seat holds and seeds the new gens; a failed spawn re-bumps and hands them back | the restart and the takeover SPAWN before they RETIRE (`sed -n 202,215p csi-spl-orc/src/bash/run/spl-peer-restart.func.sh`): two sessions hold one seat at one gen for up to 330 s and both pass the fence (r2 3.3) |
| one message sent while the hub is unreachable | **D14**: one `msg_id` minted before the hub leg and reused by the local leg | a hub commit with a lost reply makes the local leg mint a second id (`spool-send.sh:138`): two rows, two owners (r2 3.5) |

**Assumptions** (r2 1): A1 Postgres row locks and the `READ COMMITTED`
re-check of an `UPDATE ... WHERE`; A2 "the hub's clock" is each Cloud Run
instance's wall clock (`internal/hub/server.go:252`, `o.Now = time.Now`), not
the database's `now()`: milliseconds of skew against 20 s / 120 s margins,
acceptable, stated here as an assumption; A3 a process may pause for any time
at any instruction (092: power loss is routine). **093 4.6's local fence is
settled as exit 2**: no local-only job acts until the hub confirms.

### 3.2 Today's failure modes, and what closes each

| failure seen 2026-10-06 | cause | closed by |
|---|---|---|
| the same task spawned twice by two orchestrators | two role holders acted on one ask; and one ask can arrive as two MESSAGES (an owner post plus its relay, a blocker sent to two ids, a `cc:`) | the claim gives one owner per message only; the `spawn` mutex orders spawns but does not drop a repeat. Closed by **D5**: an ask key `ask=<topic>:<slug>` on every spawn, checked under the `spawn` mutex against the registry and `fleet_asks`; a repeat is refused naming the first lane's `<ID>@<box>`. Only the topic's owner seat instructs a running lane; any other seat forwards to the owner (r3 F1) |
| owner posts nobody answered | a post reached a seat that was not the lease holder, or arrived in a gap | a job is a row with `handled_at IS NULL`: every poll sees it until it closes; T10 dead-letters with an owner DM after 6 rounds / 4 owners |
| results landed in the wrong orchestrator's inbox (`c-001` resolves locally) | a bare `c-001` means this box's | `--to orchestrator` becomes `to_id = 'peers'` on the hub (068 L4), claimed like a human post; a lane's report goes first to the seat that spawned it (093 4.4). Not enough alone: briefs and lanes write a bare `c-001`, which still resolves locally. **D6**: from the first seat, `spool-send.sh --to c-00[1-4]` without `@box` from a lane is rewritten to `peers` with one warning; after L10 it is refused; the brief templates stop writing "report to c-001" in the same build step (r3 F2) |
| two orchestrators acting at once (r1 E10: `c-001@sat` spawned c-373..c-393 while the lease named `c-001@<pc box>`; this panel was spawned that way) | a human-relayed order acted on by a non-holder; nothing checks the lease before a spawn | in the seat world the claim + fence; until then the cut-over (D3) must stop every non-seat from spawning: from M4 the spawn launchers take the `spawn` mutex for EVERY caller, not only for seats (**D10**) |
| a prd-read request routed to a seat whose harness refuses it | the role decided the actor, not the capability | release with `--reason harness-refused:<step>` puts the harness in `not_by`; the next round skips it (068 F6). Section 5 adds a per-session capability (D2) so the first round is right |

## 4. The lease model (brief question 2)

The `orch` and `dispatch` roles of `fleet_leases` go away (068 6.3, at L10).
The table and the `lease cas` frame stay, under new role names, as **short
mutexes** for the few resources that need one actor at a time: `spawn` (the
40-window ceiling is a count), `prd-<target>`, `fleet-config` (068 section 5).
A dead holder's mutex runs out in 120 s. No ranking, no handback, no standby.

**The mutex gets a release** (r2 4.2): today it is never released
(`grep -n 'The mutex is never released' csi-spl-orc/src/bash/run/spl-peer-gate.func.sh`
-> 18), so one `spawn` row lets the fleet spawn about once per 120 s - against
the owner's "bottleneck". With D5's idempotent spawn the `spawn` mutex guards
only the 40-window count-and-create step (seconds), released at once by a CAS
to an explicit free holder on the won gen (**D15**).

Until L10 the roles and the seats live side by side; section 8 says who acts
in each step so there is never a window with two deciders.

**Delta D1 (a hub defect the build must fix first, section 9).** The hub's
channel router reads every live `fleet_leases` row as a seat
(`internal/hub/role_group.go`: `nums := roleNumbers[l.Role]`; a role it does
not know falls back to the holder's own agent number). A `spawn` mutex held
by `c-002@sat` would therefore route every channel post for agent number 002
to sat only, for as long as the mutex is fresh. 093 section 6.4 met the same
trap for a watchdog row and chose not to write one. The mutexes of 068 L5
would write exactly such rows: `spl_peer_mutex` CASes role `<mutex>` in the
same `LEASE_FLEET` and tenant, and `FleetLeases` returns every row of the
tenant. Check: `sed -n 64,72p csi-spl-api/src/go/spool-hub-api/internal/hub/role_group.go`;
`grep -n 'spl_fleet_hub --fleet' csi-spl-orc/src/bash/run/spl-peer-gate.func.sh`
-> 2 (tree `ccd87045`). Inert today only because no seat takes a mutex
without `peer/seats`.

## 5. prd operations (brief question 3)

Today only `c-001` runs the prd operations other harnesses refuse (prd reads,
prd desk and issue writes, deploys the owner pre-approved). Under 068 any
seat runs them through `do_spl_peer_prd` (mutex `prd-<target>` + fence), and
the owner allowed grok seats the same powers (068 1.3, `220915e8`).

What 068 lacks is a way to send a prd job to a seat that CAN run it on the
first round, rather than learning it from a refusal (the 2026-10-06 failure).

**Delta D2: a capability per session, re-probed** (r3: a refusal is a
property of the SESSION - harness, settings, the model's judgement - not of
the seat). At every seat start, the L7 setup and every hourly restart alike,
a read-only probe through `do_spl_peer_prd` with a no-op action (e.g.
`do_spl_dispatch_check`) writes `prd=yes|no` into `peer/seats/<id>` before
the seat's first poll, and again hourly (r1: the auto-mode classifier judges
each call, so a recorded capability goes stale). The flag is a **first-round
preference only; the refusal path (`not_by`) stays the authority**. The seats file carries it; a job tagged `needs=prd`
(a message whose sender asked for a prd step: the ask book's `--ask` kinds,
or a lane's blocker naming a prd action) opens its first round only among
seats that hold the capability. No seat on any box holds it: the job goes to
the ask book's owner leg at once instead of cycling through refusals.

How a lane finds the right one: it does not. It sends to `orchestrator`
(= `peers`) as today; the round picks the seat.

## 6. Takeover per OD (brief question 4)

093 already carries the takeover per id, not per role; nothing new is needed.

| layer | what happens to a dead or stalled OD | max delay (093 section 7 / FR-001) |
|---|---|---|
| its jobs | the poll loop stops renewing (heartbeat not fresh); `locked_until = anchor + 120 s` passes; the next poll of any seat on any box frees it and opens a round | 125 s from the last progress |
| its open topics | a follow-up in its topic: the first round goes to it only while it is fresh; stale, the row starts `free`, the new accepter becomes the topic's owner (093 4.3, 8.4) | the same |
| its open asks | the ask's lock is the message's lock (068 L4): the ask moves with the job | the same |
| its owned topics' context | the investigation blocker (093 8.2) lists the dead seat's owned TOPICS, not only its jobs: a follow-up in a topic whose last job is `done` reaches a new owner who must read the topic on the hub (r3 4.2) | with the blocker |
| its session | the box watchdog: S1..S8, then `do_spl_wd_takeover` (a fresh session under the same id from the 060 handoff); at most 2 per id per hour | per situation, 093 6.1 |
| the old session of a restarted or taken-over seat | its gen is dead before the new session exists (D13): its fence says lost, its answers 409. **Section 6 was blocked by r2 until D13; D13 is now a build item of M1** | 0 s |
| a parked job (waiting on a lane) | renewed only while the holder is able; not able: free within 120 s, the next owner inherits `wait_token` | 125 s |

## 7. Rotation and the asks book per OD (brief question 5)

- **Rotation**: 068 6.1, per seat: sat restarts 001 at `:00`, 002 `:15`, 003
  `:30`, 004 `:45`; the PC 7 minutes later. Each seat writes its own distilled
  summary 5 minutes before its slot. One seat per box at a time, so three of
  four keep polling. `orch-rotate` and `dispatch-rotate` are removed.
- **Asks book** (fleet-roles 4.3): the ask rows, `raised_n`, the owner leg and
  the dead-letter stay. The handover blocker and the re-raise to ONE holder go:
  an ask is a job, and a job is offered to every ready seat. The book stays
  fleet-wide, not per OD: an ask belongs to whoever holds its message.
- **Unanswered sweep: kept through the soak (D7, changes 068 6.2).** It is
  the only check that does not trust the claim, so it is what sees a claim
  bug. From M4 it runs from every box; its note is itself a `to: peers`
  message, so one seat takes it. It is retired only by a separate decision
  after the M5 numbers (owner question 7).
- **Two schedulers** (r3 4.3): while an id has a seat file,
  `do_spl_orch_rotate` / `do_spl_dispatch_rotate` skip it (`SKIP seat`), and a
  watchdog takeover of a seat writes no `rotate.hold` (**D9**). This matters
  in M3b and after a rollback, when an id is both a lease role and a seat.

## 8. Where the four run, the cost, the migration and the rollback (brief questions 6, 7)

### 8.1 Placement

068 put four ODs on EACH box (eight). The owner's "4 of them" and "the
tank-001 is overwhelmed" read most simply as **four ODs in the fleet, on sat
now**: 068 3.1 already holds that each box carries the whole job alone.

| option | seats | fits "4 of them" | load on the `<pc box>` | survives one box down |
|---|---|---|---|---|
| **A. four on sat now; the PC's four only when its load allows (recommended)** | sat 001..004; the PC none | yes | drops: its three role sessions go | no OD while sat is down; the PC's seats are a config step away (`peer/seats` on that box), not a build |
| B. 068 as written: four per box | sat 4 + the PC 4 | no (8) | grows by one session | yes |
| C. two per box | sat 2 + the PC 2 | yes | unchanged | yes, at half strength |

Recommendation A, with B as the target once the PC is not overloaded: the
design takes N boxes and nothing in it names one. Owner question 1.

**Two conditions on A before the cut-over** (r3 4.4, F5: at 04:27:02Z today
sat's c-002 and c-003 were both stalled on `/login` at once, one login):

1. **Two logins.** The four seats split over two agent users (two claude
   accounts), or two harnesses once grok is back, so one expired login stops
   at most two. If no second login is available: **A' = three on sat + one on
   the PC** (the PC's agent user is a different login, and one seat costs the
   PC less than today's three role sessions). Owner question 5.
   Or (c): the owner accepts the one-login risk in words (r1). Without one
   of the three, no consensus on A.
2. **M6 waits until a second box holds a seat.** Until M6 a rollback brings
   the PC's role trio back; after it, sat down = no OD at all.

**Harness mix.** 068 fixed two claude + two grok per box against one login
freezing every seat (068 F2). Today agy has no binary on sat and grok is at
its weekly limit (this panel's brief). Until grok is back: four claude seats,
accepting F2's risk, with `g-003` / `g-004` swapped in when it is. Owner
question 2.

### 8.2 Cost: tokens and quota, not RAM

RAM is not the limit: on sat 2026-10-06T17:04Z (n = 24 live claude sessions)
load 17 / 15 / 11 on 16 cores, 28 GiB of 62 available, RSS 323 MiB per
session on average. The cost is **acting** (r1 E5, n = 13 active hours on
sat): an active orch makes ~98..148 model calls an hour at ~150 k tokens of
context each, ~12..23 M cache-read tokens an hour; a standby seat makes
0..20 calls. Today six role sessions exist but two act.

| | cache-read tokens / h |
|---|---|
| 1 active orch today | ~20 M |
| 4 seats, jobs split by the claim (093 rounds: only the round's seats are told) | ~20 M + 3 x the fixed share per active seat (rotation, re-briefing) - **unmeasured (U4)** |
| 4 seats each reading every post (fleet-roles 2.1 delivery) | up to ~80 M |

So the seats must be told only by the round (093 4.3: a stub to at most
`OFFER_K` seats), never by a channel delivery to all four, and **U4 (the fixed
token cost of one active seat in a quiet hour) is measured before M4**. Quota
is the ceiling: one login's weekly limit stopped the whole fleet on
2026-10-01 (owner question 8).

### 8.3 Migration, one step at a time, each with its rollback

| step | what | who acts during it | rollback |
|---|---|---|---|
| M0 | flip `LEASE_PRIORITY_ORCH` to sat first (**done** 17:06Z, c-001; the PC flipped first, then sat) | the fleet lease, as today | flip back |
| M0.5 | **routing first** (r1 R1..R3, R5; no owner go, no migration, no cut-over): (R1) lanes placed on sat by default, the spawn box pick weighing load; (R2) the taking dispatcher spawns real lane work itself, as fleet-roles 3 already says, instead of a `task` ask "new lane please" - `spool-send.sh` warns on such an ask from 002/003; (R3) a lane reports to its spawner (`--to <spawner>@<box>` written into its brief), `orchestrator` stays for decisions and prd; (R5) the 093 hooks installed for the OD seats, so the inject hook shows asks mid-turn | the fleet lease, as today | revert the brief template / the warning |
| M1 | build: D1 (hub router ignores mutex rows), 093 T010 (two-phase poll loop), 068 L7 (`do_spl_peer_setup` + drill tooling), D2 (capability per seat), D3 (the cut-over action, below), D5 + D12..D15 (r2: topic guard, intent before act, gen rotation, one msg_id, mutex release) | the fleet lease | none needed: all inert without `peer/seats` |
| M2 | confirm rdb 0110 / 0111 / 0132 in the migration table on dev and prd (inferred applied from `schema_head` 0139, 1.3); only a missing one needs applying (**owner go**: a hub migration is a GCP mutation) | the fleet lease | the migrations are additive columns with constant defaults (093 4.1) |
| M3 | drill on dev: four seats on sat against the dev hub, 068 L7's drill (kill one OD, SIGSTOP the box, 20 posts, each delay of 068 section 7, n >= 5) | prd: the fleet lease | remove the dev `peer/seats` |
| M3b | **prd shadow, 24 h** (r3): `peer/seats` on sat with `PEER_SHADOW=1` (**D8**): the seats poll and log which seat WOULD own each job; no stub, no ring, every accept refused. The lease still decides everything | the fleet lease only: a shadow seat decides nothing | delete `peer/seats` on sat |
| M4 | **cut-over on prd, ONE action** `do_spl_fleet_od_cutover` (D3) under the `fleet-config` mutex: on every box, in this order: stop the lease loops (`LEASE_CMD=stop`) and move `lease.conf` aside, remove `orch-rotate` / `dispatch-rotate` (the sweep stays, D7), then write `peer/seats` and install the peer crons. **Per id the hand-over is a 060 rotation** (r3: the seat ids ARE the role ids, and the two sessions share one inbox. Corrected by r2: the 060 / restart path DOES run two sessions of one id for up to 330 s - only the gate's `spl_peer_pids` refuses a duplicate - so the hand-over carries D13's gen bump before the new session starts): the role session writes its handoff and exits, the new session under the same id is seeded as a seat (the seat seed + the handoff), one id at a time, the next after the new one acks; `c-004` is a plain spawn. The first poll of each seat lists the open asks once. D6's rewrite is on from here | from the first seats write: the seats only | `do_spl_fleet_od_cutover ROLLBACK=1`: remove `peer/seats` on every box (every peer piece goes inert at once), restore `lease.conf` and the crons, `LEASE_CMD=ensure`; the PC's trio carries the roles while sat's seat sessions are rotated back into role sessions (the same 060 path, reversed) |
| M5 | soak: a week of the seats on prd, the sweep still running (D7); `do_spl_dispatch_check` reports the seats instead of the lease | the seats | M4's rollback |
| M6 | 068 L10 + L9 + 093 T012: delete the role code, rewrite fleet-roles. Only after the M5 numbers pass AND a second box holds a seat (8.1) | the seats | git revert + `do_spl_dispatch_setup` on both boxes |

### 8.4 The interim (M0..M4) runs on the fleet lease, which is not a fence

r2 section 5: a takeover leaves a double-act window until the old agent reads
its STANDBY note; a dead lease loop with a live agent never tells it STANDBY;
`spool_fleet_orchestrator` ignores the epoch of `lease.orch`
(`spool-fleet.inc.sh:76`). Accepted while M4 lands within days. If the
interim runs longer, two cheap guards (**D16**): a `lease.orch` older than
`LEASE_STALE` is treated as unknown and relayed through the hub; the desk
reconcile alerts on a box with a role agent and no lease loop.

### 8.5 Pass numbers per step (r3 5.3)

Every number carries the tree sha, the switch states (`PEER_SHADOW`,
`SPOOL_TO_PEERS`) and n.

| step | measured | pass |
|---|---|---|
| M3 dev drill | kill one OD, SIGSTOP a box's ODs, expire one login (fixture) | each job moves within 125 s, n >= 5 each |
| M3b prd shadow, 24 h | per human post: the lease holder that answered vs the seat the shadow picked; rounds per job; lapses; prd jobs with no capable seat | every post has exactly one shadow owner; median shadow pickup <= 5 s |
| M0.5 routing, 1 day | asks per hour to the orch, dead rate, re-raise share (r1's E6..E8 scripts), before vs after | asks to the orch down by at least half; dead rate and re-raise share down |
| M5 soak, 7 days | lane reports in an old role inbox; first agent reply per human post; posts with two agent answers; sweep items | 0 reports in an old role inbox; p95 <= 180 s; 0 double answers; sweep items not above the 7 days before M4; every prd job with no capable seat at the owner leg within one tick |

The build carries one regression test per failure seen, each with a control
(r3 section 5.1, R1..R12): dup ask over two messages, two relays to one lane,
a bare `c-001` from a lane, a result during a role flip, a prd job with and
without a capable seat, the re-probe after restart, the one-decider cut-over
and its half-applied control, shadow decides nothing, the same-id hand-over,
four seats on one login, a seat that is also a lease role, two schedulers,
and the sweep still seeing a claim bug.

**Delta D3: the cut-over is one fleet action, not a sequence of hand edits.**
While the PC's role sessions hold the lease and sat's seats claim from the
hub, a web post reaches both: the role holder answers it through the
delivery, the seat through the claim. The answer-once guard (068 L2) fences
only posts that carry `answers=`, which the role sessions do not send. So the
two must never run together on prd, and the switch must be one action that
writes every machine or none (068 section 5's `fleet-config` rule, born of
068 F5).

## 9. Deltas this spec adds to 068 + 093

| id | what | where | why |
|---|---|---|---|
| D1 | the hub's channel router reads only the `orch` / `dispatch` roles, never a mutex row | `internal/hub/role_group.go` (`roleSeats`) + its test | 4: a `spawn` mutex would re-route an agent number's channel posts |
| D2 | a capability per seat (`prd-read`, `prd-write`, `deploy`), recorded by the seat drill, read by the first round of a `needs=prd` job | 068 L7's setup + 093 T010's round | 3.2: the 2026-10-06 prd-read misroute |
| D3 | one cut-over action with a rollback, under the `fleet-config` mutex | a new `do_spl_fleet_od_cutover` in csi-spl-orc | 8.3: two deciders on prd during a hand edit |
| D4 | placement A: four on sat over two logins (else A': 3 + 1), the PC's four when its load allows | the seats file per box | 8.1, owner questions 1, 5 |
| D16 | interim guards if M4 is more than a few days away: stale `lease.orch` = unknown; alert on a role agent without a lease loop | `spool-fleet.inc.sh`, desk reconcile | 8.4 (r2 5) |
| D10 | from M4 the spawn launchers take the `spawn` mutex for every caller, so no non-seat (a leftover role session, a human-relayed order) spawns beside the seats | spawn launchers | 3.2 (r1 E10) |
| D11 | M0.5: lanes on sat, dispatcher spawns its own lanes, lane reports to the spawner, OD hooks installed | spawn box pick, brief template, `spool-send.sh` warning, the hook installer | 1, 8.3 (r1) |
| D5 | ask key `ask=<topic>:<slug>` on every spawn; **intent before act** (r2 D11 merged): the lane id, derived from `(task_id, slot)`, is written to the job under the holder's gen (`--park --wait`) BEFORE the spawn, and the spawn refuses an existing lane or worktree; only the topic's owner instructs a lane (enforced by D12) | spawn launchers, `spawn-window.sh`, `spl-peer-gate.func.sh`, 093 T010 | 3.2 row 1 (r3), 3.1 (r2 2.2) |
| D12 | topic guard in the accept (r2 D10) | `roundAccept` / `roundOpen` + maybe an index on `(tenant_id, task_id) WHERE claim_state IN ('owned','parked')` | 3.1 (r2 3.1) |
| D13 | rotate the gen with the session (r2 D12) | `spl_peer_restart_seat`, `do_spl_wd_takeover`, a hub op `spool claim --rebind` | 3.1, 6 (r2 3.3) |
| D14 | one msg_id across both legs of a peers send (r2 D13) | `spool-send.sh` `send_peers_local` + the relay | 3.1 (r2 3.5) |
| D15 | a release for the mutex; `spawn` held only for count-and-create | `spl-peer-gate.func.sh` + the lease frame | 4 (r2 4.2) |
| D6 | a bare `c-00[1-4]` from a lane is rewritten to `peers` (M4..M6), refused after L10; brief templates stop writing it | `spool-send.sh`, the spawn seeds | 3.2 row 3 (r3) |
| D7 | the unanswered sweep stays through the soak, from every box, as a `to: peers` note | `do_spl_unanswered_sweep` | 7 (r3) |
| D8 | `PEER_SHADOW=1`: rounds logged, no stub, no ring, no accept | `spl-peer-poll.func.sh` (`grep -rn PEER_SHADOW csi-spl-orc/src/bash` -> 0 on `ccd87045`) | 8.3 M3b (r3) |
| D9 | the 060 rotations skip an id with a seat file; a seat's takeover writes no `rotate.hold` | `spl-orch-rotate`, `spl-dispatch-rotate`, `spl-wd-takeover` | 7 (r3) |

## 10. Owner questions (one list, to c-001@sat)

1. "4 of them": four ODs in the whole fleet, all on sat for now (option A),
   or four on EACH box as 068 decided on 2026-10-03 (option B, eight)?
2. Harness mix while grok is at its weekly limit and agy has no binary on
   sat: four claude seats now, the two grok seats swapped in when grok is
   back?
3. ~~rdb 0110 / 0111 / 0132 applied?~~ Answered by c-001: applied on dev and
   prd, inferred from `schema_head` 0139 (1.3). No go needed unless M2's row
   check finds one missing.
4. The cut-over (M4) retires the PC's role sessions and the fleet lease
   roles on prd in one step: go when the dev drill (M3) and the 24 h prd
   shadow (M3b) pass their numbers (8.5)?
5. May the four seats run under two logins (a second agent user with its own
   claude account), so one expired login stops at most two? If not: three on
   sat + one on the PC.
6. Is a standing read-only prd probe per seat session acceptable (D2)? It is
   how a seat learns, after each hourly restart, whether its harness runs prd.
7. Keep the unanswered sweep until a week after the cut-over, and retire it
   only by a separate decision (D7)?
8. Is the pain **throughput** (asks wait: E8) or **availability** (a hung
   orchestrator: 093's incident)? M0.5 answers the first within a day; the
   seats answer both, after M1..M4.
9. What weekly token quota should the OD seats stay within (8.2)?

## 11. Panel

| seat | agent | note | sha | verdict |
|---|---|---|---|---|
| author | c-387 | this file | - | - |
| r1 | c-388 | [research/r1-grok-standin.md](research/r1-grok-standin.md) | `b96a1de3` | agree on the finding; changes 1, 3.2, 5, 7, 8.1 (near block), 8.2, 8.3 - folded in v0.3 |
| r2 | c-389 | [research/r2-claude.md](research/r2-claude.md) | `b727a5bc` | agree on the finding; changes 3, 4, 7, 8; **blocked 6 until D13** - all folded in v0.4 (r2's D10..D13 = this spec's D12, D5, D13, D14) |
| r3 | c-390 | [research/r3-claude.md](research/r3-claude.md) | `b4cbe0ce` | agree on the finding; changes 3.2, 5, 7, 8.1, 8.3 - all folded in v0.2 |

**Consensus: recorded 2026-10-06 on v0.4 (`7ca00033`), 4 of 4 seats.**
Author c-387; r2 c-389 "sign v0.4" (spool msg `ac56ee50`); r3 c-390
"re-sign v0.4" (msg `89c03da0`, after r2 corrected its M4 claim). r1 c-388
exited at 17:13:45Z, before v0.3, so it signed no version. Its note's verdict
was "no section is blocked, but 8.1 is close ... should not record consensus
on A without (a), (b) or (c)" (msg `cccccd65`). v0.3 took that condition word
for word (8.1), so r1 is counted as agreeing on its own stated terms. Every
change any seat asked for is in; none was declined.

**What was agreed:**
1. The four ODs are 068 + 093 P2, already mostly on trunk. No second
   mechanism is built.
2. Routing comes first (M0.5). Then the build: D1, D2, D3, D5, D12..D15, T010,
   L7. Then a dev drill, a 24 h prd shadow, and a one-action cut-over with a
   rollback.
3. Placement: four seats on sat, only with two logins, or 3 + 1 with the PC,
   or the owner accepting the one-login risk in words.

<!-- version: 0.4.1 · updated: 2026-10-06 · last-edit: 2026-10-06T18:55:00Z -->
