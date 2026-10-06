# 101: four orchestrator-dispatchers acting at once

Status: **v0.1, draft for the panel, 2026-10-06.** Spec only: no code, cnf,
`lease.conf`, crontab or seat was touched by this lane.
Author: c-387@sat (the pen; claude, standing in for the agy seat: no agy
binary on sat). Reviewers: r1, r2, r3 (claude, standing in for agy and grok),
notes under `research/`.
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
| rdb 0110 / 0111 / 0132 applied on dev and prd | **unknown to this lane** (prd reads refused to its harness): asked of c-001, section 10 |

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
| **d. claim per message, two-phase, on the hub (068 4.1 + 093 4)** | per job: the first accept wins; a follow-up's first round goes to the topic's owner seat (093 4.3 stickiness) | its jobs go free at `anchor + 120 s` and the next round goes to another seat | prevented by the claim + the fence + the `spawn` mutex | **recommended: it is the owner's 068 design, and it is built** |

**Recommendation: d.** Exactly one decider per job is a database property
(one `UPDATE ... WHERE claim_state = 'offered' AND offer_n = $n`), not an
agreement between sessions. A topic has one owner because its follow-ups go
first to the seat that owns its opening job.

### 3.2 Today's failure modes, and what closes each

| failure seen 2026-10-06 | cause | closed by |
|---|---|---|
| the same task spawned twice by two orchestrators | two role holders acted on one ask (no per-item owner) | the claim (one owner per job), the fence before the spawn, the `spawn` mutex (068 L5) |
| owner posts nobody answered | a post reached a seat that was not the lease holder, or arrived in a gap | a job is a row with `handled_at IS NULL`: every poll sees it until it closes; T10 dead-letters with an owner DM after 6 rounds / 4 owners |
| results landed in the wrong orchestrator's inbox (`c-001` resolves locally) | a bare `c-001` means this box's | `--to orchestrator` becomes `to_id = 'peers'` on the hub (068 L4), claimed like a human post; a lane's report goes first to the seat that spawned it (093 4.4) |
| a prd-read request routed to a seat whose harness refuses it | the role decided the actor, not the capability | release with `--reason harness-refused:<step>` puts the harness in `not_by`; the next round skips it (068 F6). Section 5 adds a per-seat capability so the first round is right |

## 4. The lease model (brief question 2)

The `orch` and `dispatch` roles of `fleet_leases` go away (068 6.3, at L10).
The table and the `lease cas` frame stay, under new role names, as **short
mutexes** for the few resources that need one actor at a time: `spawn` (the
40-window ceiling is a count), `prd-<target>`, `fleet-config` (068 section 5).
A dead holder's mutex runs out in 120 s. No ranking, no handback, no standby.

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

**Delta D2: a capability per seat.** The seat drill (068 L7) records, per
seat, which of `prd-read`, `prd-write`, `deploy` its harness ran (one dry or
read-only probe each). The seats file carries it; a job tagged `needs=prd`
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
| its session | the box watchdog: S1..S8, then `do_spl_wd_takeover` (a fresh session under the same id from the 060 handoff); at most 2 per id per hour | per situation, 093 6.1 |
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
- **Unanswered sweep**: removed (068 6.2): an unanswered human post is a row
  with `handled_at IS NULL`, which every poll sees.

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

**Harness mix.** 068 fixed two claude + two grok per box against one login
freezing every seat (068 F2). Today agy has no binary on sat and grok is at
its weekly limit (this panel's brief). Until grok is back: four claude seats,
accepting F2's risk, with `g-003` / `g-004` swapped in when it is. Owner
question 2.

### 8.2 Cost

Measured on sat 2026-10-06T17:04Z (n = 24 live claude sessions of the agent
user): load 17 / 15 / 11 on 16 cores, 28 GiB of 62 available, claude RSS 323
MiB on average. Four OD sessions = about 1.3 GiB and four context windows,
each reset hourly (068 6.1). Today's fleet runs six role sessions (three per
box), so option A runs **fewer** decider sessions than today, not more.

### 8.3 Migration, one step at a time, each with its rollback

| step | what | who acts during it | rollback |
|---|---|---|---|
| M0 | flip `LEASE_PRIORITY_ORCH` to sat first (in progress, c-001; the PC flips first, then sat) | the fleet lease, as today | flip back |
| M1 | build: D1 (hub router ignores mutex rows), 093 T010 (two-phase poll loop), 068 L7 (`do_spl_peer_setup` + drill tooling), D2 (capability per seat), D3 (the cut-over action, below) | the fleet lease | none needed: all inert without `peer/seats` |
| M2 | confirm rdb 0110 / 0111 / 0132 are applied on dev and prd; apply what is not (**owner go**: a hub migration is a GCP mutation) | the fleet lease | the migrations are additive columns with constant defaults (093 4.1) |
| M3 | drill on dev: four seats on sat against the dev hub, 068 L7's drill (kill one OD, SIGSTOP the box, 20 posts, each delay of 068 section 7, n >= 5) | prd: the fleet lease | remove the dev `peer/seats` |
| M4 | **cut-over on prd, ONE action** `do_spl_fleet_od_cutover` (D3) under the `fleet-config` mutex: on every box, in this order: stop the lease loops (`LEASE_CMD=stop`) and move `lease.conf` aside, remove `orch-rotate` / `dispatch-rotate` / `unanswered-sweep`, then write `peer/seats` on sat and install the peer crons; the old role sessions write their 060 handoff, an OD acks it, they exit one at a time | from the first seats write: the four seats only | `do_spl_fleet_od_cutover ROLLBACK=1`: remove `peer/seats` on every box (every peer piece goes inert at once), restore `lease.conf` and the three crons, `LEASE_CMD=ensure`; the lease elects a holder within one tick |
| M5 | soak: a week of the seats on prd; `do_spl_dispatch_check` reports the seats instead of the lease | the seats | M4's rollback |
| M6 | 068 L10 + L9 + 093 T012: delete the role code, rewrite fleet-roles | the seats | git revert |

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
| D4 | placement A: four on sat, the PC none until its load allows | the seats file per box | 8.1, owner question 1 |

## 10. Owner questions (one list, to c-001@sat)

1. "4 of them": four ODs in the whole fleet, all on sat for now (option A),
   or four on EACH box as 068 decided on 2026-10-03 (option B, eight)?
2. Harness mix while grok is at its weekly limit and agy has no binary on
   sat: four claude seats now, the two grok seats swapped in when grok is
   back?
3. (c-001, prd read) Are rdb 0110, 0111 and 0132 applied on dev and prd? If
   not: the go to apply them (M2).
4. The cut-over (M4) retires the PC's role sessions and the fleet lease
   roles on prd in one step, after the dev drill (M3): go when M3 is green?

## 11. Panel

| seat | agent | note | sha | verdict |
|---|---|---|---|---|
| author | c-387 | this file | - | - |
| r1 | - | research/r1.md | - | - |
| r2 | - | research/r2.md | - | - |
| r3 | - | research/r3.md | - | - |

Consensus: not yet.

<!-- version: 0.1.0 · updated: 2026-10-06 · last-edit: 2026-10-06T17:20:00Z -->
