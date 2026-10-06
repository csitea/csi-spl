# 101 four orchestrator-dispatchers: reviewer r3 (c-390), migration, rollout risk, test plan

Seat r3, claude, standing in for the agy and grok seats of the owner's panel
rule (agy has no binary on sat, grok is at its weekly limit). Task
`cc7726e7`. Scope: migration and rollout risk from today's roles, the
watchdog (093) and rotation (060) interplay, the test plan, and today's
failure modes as regression tests. Written on sat; reviews spec.md **v0.1
(`366acebe`)**; code read on tree `ccd87045`. Box files quoted below were read
on sat, 2026-10-06 ~17:05Z, read-only, as the agent user. `<pc box>` stands
for the PC's box tag.

**Position.** I reached the author's core finding independently before
v0.1 landed: 101 is the **activation** of 068 + 093, not a second mechanism.
**Agree** with it. My changes are about the cut-over and about three of
today's failures that the per-message claim does NOT close on its own.

## 0. Verdict per v0.1 section

| v0.1 section | verdict | why (detail in the section named) |
|---|---|---|
| 1 finding (068 + 093, mostly on trunk, inert) | **agree** | same reading; my section 1 confirms the live state independently |
| 3 partition, option d | **agree** with d; **change** 3.2 rows 1 and 3 | the claim is one owner per MESSAGE, not per ASK: two messages carrying one ask are two claims, and the `spawn` mutex serialises spawns but does not dedupe them (F1, 3.1). A bare `c-001` still resolves locally after L4: only `--to orchestrator` moves; briefs and lanes say `c-001` (F2, 3.2) |
| 4 lease model, D1 | **agree** | checked: `sed -n 60,75p internal/hub/role_group.go`: a role not in `roleNumbers` falls back to `agentid.Number(id)` of the holder, so a `spawn` row held by `c-002@sat` adds a 002 seat on sat |
| 5 prd, D2 | **change** | the capability is a property of the SESSION, not the seat: it must be re-probed after every hourly restart, not only in the L7 drill (F3, 3.3) |
| 6 takeover | **agree**, one addition | the investigation blocker (093 8.2) should list the dead seat's OWNED TOPICS, not only its jobs: a follow-up in a topic whose last job is `done` reaches a new owner with no context (4.2) |
| 7 rotation, asks | agree on rotation and asks; **change** on the sweep | keep `do_spl_unanswered_sweep` through the soak: it is the only check that does not trust the claim, so it is what would see a claim bug (F4, 3.4) |
| 8.1 placement A | **change** | four claude seats on ONE agent user share ONE login: 04:27:02Z today sat's c-002 and c-003 were both `stalled ... Please run /login` at once (F5). A needs two logins (two agent users) or a second harness before cut-over, and with sat down and the PC at 0 seats there is no OD at all once M6 deletes the lease (4.4) |
| 8.2 cost | **agree** | |
| 8.3 migration, D3 | **change** (one item close to block) | (a) the seat ids ARE the role ids on sat: `c-001@sat` role session and `c-001@sat` seat cannot both run (`spl_peer_pids` refuses a duplicate), so "an OD acks the role session's handoff" cannot be the same-id OD: the hand-over per id must be a 060 rotation whose new session is seeded as a seat (4.1); (b) add a **prd shadow** step before the one-action cut-over: seats poll and record who WOULD own each job, accept nothing: no second decider, and the cut-over gets a measured go instead of a drill on dev only (4.1) |
| 9 deltas | **change**: add D5..D7 | D5 ask key on spawns (3.1); D6 bare role ids rewritten / refused (3.2); D7 the sweep kept through the soak (3.4) |
| 10 owner questions | add two | section 7 below |

## 1. Where today's roles actually stand

| piece | state on sat | how I know |
|---|---|---|
| fleet lease (`lease.orch`, `lease`) | both held on the `<pc box>`: `c-001@<pc box>`, `c-002@<pc box>` | `cat /var/spool-hub/dispatch/lease.orch lease`, epoch 24 s old |
| sat's ranking | `LEASE_PRIORITY_ORCH=<pc box>,sat,box-desk` still: the interim flip has not reached sat's `lease.conf` yet (the order is: `<pc box>` first, then sat) | `grep PRIORITY /var/spool-hub/dispatch/lease.conf` |
| 068 seats | **off**: `/var/spool-hub/peer/` holds only `restart.lock`, no `seats`; `/var/spool-hub/peers/` absent | `ls -la /var/spool-hub/peer /var/spool-hub/peers` |
| 068 code on trunk | `spl-peer-{poll,ensure,gate,prd,restart,distill,crons}.func.sh`, `store/message_claim*.go`, `answer_once*.go`, rdb `0132_messages_claim_round.sql`, `spawn-mutex.tst.sh`, `peer-poll.tst.sh` | `ls csi-spl-orc/src/bash/run \| grep peer`, `grep -rl claim_state csi-spl-*` (5 files) |
| `--to orchestrator` | resolves to `lease.orch` while no seat exists; with a seat it becomes ONE `to: peers` message, claimed by one seat | `spool-send.sh:178-187`, `send_to_peers_on` |
| 093 watchdog | live on both boxes (sat's loop up 8 h 15 min at 17:05Z); it has already taken over a lane (`a-368` S3, held out) | `ps -o etime= -p $(cat /var/spool-hub/dispatch/wd/run.pid)`; `ls dispatch/wd` |
| 093 P2 (the two-phase claim) | not live: it rides on the 068 seats | 093 section 9 |

So the system the owner calls "the single bottleneck" is today's lease
(one orch, one master), and the leaderless replacement exists in code but has
never carried a message. **That gap is the main rollout risk**: every piece of
068 was proven against stubs (`peer-poll.tst.sh`: 8 simulated ODs on 2 boxes),
none on live traffic.

## 2. Failure modes seen in the last three days, and what each needs from 101

Each row is a regression test the build must carry (section 5). n is the
number of cases I found, not a rate.

| # | failure | evidence | root cause | what 068 already covers | gap |
|---|---|---|---|---|---|
| F1 | **two deciders on one ask** (the "duplicate spawn" class) | 2026-10-04, spec 074: one blocker sent to both ODs of the `<pc box>`; one closed lane A and kept B, the other stopped B: zero lanes (n=1). Same day, t1 9f0d751c: orch and dispatcher each relayed a different reading of one owner post to lane c-252, four contradicting messages (n=1) | the same ask reached two ODs as two **different messages** (or one message to two ids) | the claim makes one message have one owner; `spawn` mutex makes one spawn at a time (`spawn-mutex.tst.sh` section 2, n=10) | the claim is **per message, not per ask**: two messages carrying one ask (an owner post plus its relay, a blocker sent to two ids, a `cc:`) are two claims. The mutex serialises spawns but does not dedupe them: the second spawn of the same brief waits 120 s and then runs. Needs a dedupe key (topic + slug) checked under the mutex |
| F2 | **result in the wrong orchestrator's inbox** | briefs written by `c-001@<pc box>` today say "Report your result to c-001 (`spool-send.sh --to orchestrator ...`)" (spawn-request at 11:27:24Z, 11:43:19Z, n>=2). On sat a bare `c-001` is `c-001@sat` (fleet-roles 4.2: "a bare `c-001` always means this machine's") while the orch was `c-001@<pc box>` all day except 13:05:58..13:14:54Z | an id names a session; a role moves between boxes, the id does not | `--to orchestrator` -> peers removes the role id from the send | the bare id still works and still lands locally. A lane, a brief template and every memory line say `c-001`. With 4 ODs there is no "the orchestrator" id to keep; a bare `c-00N` must be refused or rewritten |
| F3 | **prd operations routed to a seat whose harness refuses them** | 13:06:41Z c-001@sat (the orch seat) to c-002: "My harness refuses prd reads. Please post this to HUM-10" (n=1 today); an agent note of 2026-10-04: the c-001@sat harness also refuses prd desk posts | the refusal is a property of the **session** (harness, user settings, model judgement), not of the role id. Fleet-roles section 1 assigns prd to "c-001", i.e. to a role | `not_by` (068): a refused job moves to another harness; `spl-peer-prd.func.sh`: one prd action at a time per target, behind the fence | nothing records WHICH seats can run prd. A refused job re-rounds blindly until it finds one (or dies at `OFFER_MAX` 6 / `CLAIM_MAX` 4). Needs a capability flag per seat (section 3.3) |
| F4 | owner posts nobody answers | sat: `dispatch-gaps` 13:06:41Z "unanswered sweep: GAP stale ... last 98070s ago"; the sweep runs only on the lease holder's machine (fleet-roles 4.1) | the sweep and the 3-minute backstop are tied to a role | the claim's T3/T5 move an unowned job by time with no leader | 068 L10 deletes the sweep. Keep it until the 4 ODs have answered real traffic for a week: it is the only check that does not trust the claim (a control that would see a claim bug) |
| F5 | both seats of a box stalled at once | 04:27:02Z sat: `c-002` and `c-003` both "stalled ... Please run /login, no spinner" (one login, n=1) | seats on one box share one agent user and one login | 093 4.4: a takeover goes to "a different harness first" | 4 claude ODs on one user = one login = one failure. Placement must split ODs across agent users or harnesses (section 4) |
| F6 | rotation flaps the dispatch role every hour | sat `lease.log`, 2026-10-06: 13 master->failover->master windows on the `<pc box>`, 127..444 s each, median 252 s | 060's `:15` dispatcher rotation hands the lease to the failover and back | 068 L6: `do_spl_peer_restart` restarts one seat per 15-min slot; no lease moves | none, once the lease is gone. Until then each flap is a window where a new post waits for the failover (section 4.2) |

## 3. What 101 must add to 068 + 093 beyond v0.1

### 3.1 D5: one ask, one decider (F1)

The claim is the right primitive; it needs a second key. Proposal for the
author: every spawn and every lane instruction carries `ask = <topic id>:<slug>`
(the slug is already in every spawn request), checked under the `spawn`
mutex against the live registry and `fleet_asks`. A second spawn with the
same key is refused with the first lane's `<ID>@<box>`; the refused OD tells
its topic "already running as X". Relays to a running lane: only the topic's
owner seat (068 4.3 stickiness) may instruct a lane; a non-owner seat
forwards to the owner. This turns the 2026-10-04 lesson ("one decider per
decision") into a guard.

### 3.2 D6: no bare role ids (F2)

From the moment the first seat exists: `spool-send.sh --to c-00[1-4]` (no
`@box`) from a lane is either refused (exit, "use --to peers or --to
<ID>@<box>") or rewritten to `peers` with one warning. I prefer the rewrite
during the migration (old briefs still say `c-001`) and the refusal after
L10. The brief templates (`spawn-agents` seeds, `spawn-remote` requests) must
stop writing "report to c-001" in the same build step, or the rewrite fires
on every lane.

### 3.3 D2, changed: prd capability per session, re-probed (F3)

Not "OD 1 keeps prd". A seat file `peer/seats/<id>` carries `prd=yes|no`,
written by a probe at seat start (a read-only prd call through
`do_spl_peer_prd` with a no-op action, e.g. `do_spl_dispatch_check`), and
re-probed after every restart, because a fresh session may decide
differently. A prd job's first round goes only to `prd=yes` seats; with none,
it goes to the owner as a blocker at once instead of six rounds of
refusals. Owner question: is the probe itself acceptable as a standing prd
read?

### 3.4 D7: keep the sweep (F4)

Do not delete `do_spl_unanswered_sweep` in L10. Run it from every box (one
note per box, deduped by the hub's claim: the sweep's note is itself a
`to: peers` message), and retire it only by a separate decision after the
measurement in section 5.3.

## 4. Rollout risk, step by step

### 4.1 The migration order

068 chose "build first, then spawn, then a staged hand-over"; v0.1 8.3 makes
the switch one action (D3), which I agree with for the DECIDING part. The
risky part is the **co-existence window**: lease roles and seats acting at
the same time. Below, v0.1's steps with the risk each carries; rows marked
**new** are my additions.

| v0.1 step | risk while it runs | rollback | my change |
|---|---|---|---|
| M0 priority flip | flipped in the wrong order the boxes hand the role back and forth (c-001@sat 16:58:57Z) | the `lease.conf.bak-*` file | none |
| M1 build (D1, T010, L7, D2, D3) | none to traffic while `peer/seats` is absent | none needed | add D5 (ask key), D6 (bare ids), D7 (keep the sweep), and a `PEER_SHADOW=1` mode in the poll loop: rounds opened and logged, no stub, no ring, accept refused |
| M2 rdb 0110/0111/0132 on dev + prd (owner go) | additive columns with constant defaults (093 4.1) | none needed | none |
| M3 dev drill | dev only | remove dev `peer/seats` | run the regression tests of 5.1 live where they can be (R1, R3, R5, R8) with n >= 5 each |
| **M3b new: prd shadow, 24 h** | none: the seats decide nothing (the lease still does), they cost 4 hub polls per 5 s | delete `peer/seats` on sat | measures on REAL prd traffic what the dev drill cannot: who would have owned each job, rounds per job, lapses, prd jobs with no capable seat (5.3). It is the evidence for owner question 4 |
| M4 one-action cut-over (D3) | (a) **same-id collision**: the seat ids are the role ids (`c-001..003@sat`); a seat session cannot start while the role session runs under that id (`spl_peer_pids` refuses duplicates) and they share one inbox dir. (b) a lane spawned before M4 still sends `--to c-001` (F2). (c) asks in flight: `fleet_asks` holds them | `ROLLBACK=1` as v0.1 says; it works because the lease code and `lease.conf` are still on disk | (a) per id the hand-over IS a 060 rotation (`spl_rotate_handoff`, new session under the same id, `SPAWN_REUSE_ID=1`) whose seed is the seat seed; `c-004@sat` is a plain spawn. One id at a time, the next after the new session acks. (b) D6's rewrite is on from M4. (c) the first poll of each seat lists the open asks once (the handover blocker kept for this one step) |
| M5 soak, 7 days | a claim bug is invisible to a check that trusts the claim | M4's rollback | keep the sweep running (D7); pass/fail numbers in 5.3 |
| M6 delete role code | after it, rollback is a revert + `do_spl_dispatch_setup` on both boxes | git revert | M6 waits for the M5 numbers AND for the PC (or a second sat login) to hold at least one seat, else sat down = no OD and no lease to fall back on |

**The rule that makes this safe: a role and a seat never decide the same
message.** v0.1's D3 gets that by switching in one action, and I agree; the
shadow step keeps the rule (a shadow seat decides nothing) while buying a
measured go. Check that nothing like a shadow mode exists today:
`grep -rn 'PEER_SHADOW' csi-spl-orc/src/bash` -> 0 lines (tree `ccd87045`).

### 4.2 The watchdog (093) during the migration

- **Takeover of an OD seat.** 093 P1 already takes over role ids 001..003
  and writes `rotate.hold` so the lease skips them. A seat is not a lease
  role: its takeover must not touch `rotate.hold`, and its jobs move by T5
  (120 s) without the watchdog. Risk: the seats reuse 001..004 (068 Q3), so in
  M3b (shadow) and after a rollback an id is BOTH a lease role and a seat.
  Then one takeover writes a hold that also takes the id out of the lease.
  Test R9: a seat that is also `LEASE_MASTER` is taken over; the lease fails
  over to the failover once, and comes back once.
- **Limits per seat**: 093 6.3 caps takeovers at 2 per id per hour. With 4
  ODs on one login (F5) a login expiry trips all four at once; S2 (login) is
  never a takeover, so all four sit out together. The 4 must not share one
  login.
- **Dead OD's open topics** (v0.1 section 6: agree, one addition): covered by T5 (each job free at anchor + 120 s,
  the next owner inherits `wait_token`). What is NOT covered: a topic owned by
  a dead OD whose last job is `done` gets a follow-up. 093 4.3 stickiness
  sends its first round to the dead seat X only while X is fresh; stale X ->
  free -> normal rounds. Good, but the follow-up then has no context: the
  new owner must read the topic on the hub. The investigation blocker (8.2)
  should list the dead seat's owned topics, not just its jobs.

### 4.3 Rotation (060) per OD

- 060 rotates the orch at `:05` and the dispatchers at `:15`, each a lease
  move (F6: median 252 s per hour of failover, n=13). With 4 seats, 068 L6's
  `do_spl_peer_restart` restarts one seat per 15-minute slot: each seat once
  an hour, never two at once, no lease move. During M3b and after a
  rollback **both schedulers exist**: a seat that is also a lease role could be restarted by
  both in one hour. Rule for the build: while a seat file exists for an id,
  `do_spl_orch_rotate` / `do_spl_dispatch_rotate` skip it (`SKIP seat`).
- The asks book (fleet-roles 4.3) moves from "the orch holder re-raises" to
  per-ask locks (068 L4: "asks.sh lock moved to the message"). Until L4 is
  live, the re-raise runs on the lease holder's machine only; with seats it
  must run once fleet-wide (the hub decides who), or every box re-raises.

### 4.4 Placement and cost (v0.1 8.1, 8.2)

- Cost: agree with v0.1 8.2's measurement (four seats are fewer decider
  sessions than today's six); I did not measure it again.
- Placement A (four on sat, the PC none) is right for the load, with two
  conditions before M4:
  1. **two logins**: the four seats split over two agent users (or two
     harnesses once grok is back), so one expired login stops at most two.
     Today all four would be claude on one agent user: F5 happened on sat at
     04:27:02Z with two seats.
  2. **sat down is covered until M6**: while the lease code exists, a
     rollback brings the PC's trio back. After M6 it does not, so M6 waits
     until the PC (or a second always-on box, spec 092) holds at least one
     seat. Until then, sat down = no OD at all.
- If condition 1 cannot be met (no second account), I would place **3 on sat
  and 1 on the PC**: the PC's agent user is a different login, and one seat
  costs the PC less than today's three role sessions.

## 5. Test plan

### 5.1 Regression tests (one per failure, each with a control)

| test | file (new section) | fixture | expect | control (flip one input, it must fail) |
|---|---|---|---|---|
| R1 dup ask, two messages | `spawn-mutex.tst.sh` | two seats each own a different message carrying the same `ask=<topic>:<slug>`; both spawn | exactly one spawn; the other refused naming the first `<ID>@<box>`; n=20 races | without the ask key: two spawns (today's behaviour) |
| R2 two relays to one lane | `peer-poll.tst.sh` | an owner post in a topic owned by seat A reaches A and B; both try to instruct lane L | only A's instruction is delivered; B's is forwarded to A | B as owner: B's is delivered |
| R3 bare `c-001` from a lane | `test-fleet-send.sh` | two simulated roots; seats on; orch-equivalent on box 2; lane on box 1 sends `--to c-001` | rewritten to `peers` with one warning (M4..M5), refused after L10 | seats off: delivered locally, as today |
| R4 result after a role flip | `test-fleet-send.sh` | lane sends a result while the orch lease flips mid-send (the existing "reports while the orch lease flips" case) plus seats on | exactly 1 responsible seat, 0 copies in a lease inbox | `SPOOL_TO_PEERS=0` on one box only: the test detects the split (2 owners) |
| R5 prd refused | `spawn-mutex.tst.sh` (prd wrapper) | 4 seats, 2 `prd=no`; a prd job | first round only `prd=yes`; with 0 `prd=yes`, one owner blocker within one tick, no rounds | `prd` flags absent: rounds go to all, `not_by` grows (today) |
| R6 prd probe after restart | `peer-restart.tst.sh` | a seat restarted by `do_spl_peer_restart`; the probe stub refuses | the seat file flips to `prd=no` before its first poll | probe skipped: stays `prd=yes` |
| R7 cut-over leaves one decider | `fleet-lease.tst.sh` + the D3 action's test | after `do_spl_fleet_od_cutover` on 2 simulated boxes, one new post reaches the old role ids and 4 seats | exactly one answer (a seat's); no lease file younger than 180 s on either box | the action run on one box only (a half-applied cut-over): the test sees two answers |
| R7b shadow decides nothing | `peer-poll.tst.sh` | `PEER_SHADOW=1`, 4 seats, 20 posts | 20 shadow-owner log lines, 0 stubs, 0 accepts, 0 rings | `PEER_SHADOW` unset: stubs written |
| R12 same-id hand-over | `orch-rotate.tst.sh` (060 seams) | role session `c-001` running; the cut-over hands id 001 to a seat | the seat session starts only after the role session's handoff and exit; one `c-001` process at every instant; the inbox is drained by the new session | spawn the seat with the role session alive: refused (`spl_peer_pids`) |
| R8 one login, four seats | `wd-situations.tst.sh` | 4 seats, same agent user, login-expired fixture (093 FR-000) | all four S2 (no takeover), one owner DM, not four | seats on two users: two stay ready |
| R9 seat is also a lease role | `wd-takeover.tst.sh` | id is a seat and `LEASE_MASTER`; S3 takeover | one lease failover and one handback, seat jobs move by T5 | seat file absent: today's role takeover |
| R10 two schedulers | `orch-rotate.tst.sh`, `dispatch-rotate.tst.sh` | a seat file for the id due at `:05` / `:15` | `SKIP seat`, no lease move | no seat file: rotates as today |
| R11 sweep still sees a claim bug | sweep fixture tests | a human post whose job the claim marked `done` with no agent reply in the topic | the sweep lists it | an agent reply present: not listed |

### 5.2 Stub-level acceptance (before M3)

- `peer-poll.tst.sh` with **4** seats (not 8) on 2 boxes, split 3/1: pickup
  within 5 s, a dead seat's jobs free at 125 s, n >= 20 each (093 FR-001).
- Every test above runs in the CI gate; `bash
  csi-spl-orc/src/bash/tests/run-all-tests.sh` green on the build sha.

### 5.3 Live acceptance, per migration step

| step | measured | pass |
|---|---|---|
| M3b prd shadow, 24 h | for each human post: the lease holder that answered vs the seat the shadow would have picked; rounds per message; lapses | 0 messages with 0 shadow owners; >= 1 owner for every message; median shadow pickup <= 5 s |
| M5 soak, 7 days | lane reports in any old role inbox; first agent reply delay per human post (the 3-minute rule); posts with 2 agent answers; sweep items | 0 reports in an old role inbox; p95 <= 180 s; 0 double answers; sweep items not above today's count (baseline: the 7 days before M4); prd jobs with no capable seat: each reached the owner leg within one tick |
| drill (068 L7) | kill one OD, SIGSTOP the PC's OD, expire one login | each job moves within 125 s, n >= 5 each |

Every number reported from these carries the tree sha, the switch states
(`SPOOL_TO_PEERS`, `PEER_SHADOW`, `peers.takes-new`) and n.

## 6. Rollback

The whole move is reversible until M6, because the lease code and
`lease.conf` stay on disk: before M4 delete `peer/seats` (nothing else
changed); after M4 `do_spl_fleet_od_cutover ROLLBACK=1` (v0.1 8.3), and the
lease elects a holder within one fleet tick (60 s). One cost v0.1 does not
name: on rollback the ids 001..003 on sat hold SEAT sessions, which must be
rotated back into role sessions (the same 060 path, reversed) before the
lease's able check counts them; until then the PC's trio carries the roles. After M6 the rollback is a revert
of the delete commit plus `do_spl_dispatch_setup` on both boxes. Hence:
**M6 waits for the M5 week, not for consensus.**

## 7. Owner questions to add to v0.1's list

v0.1's questions 1..4 cover mine on placement and the cut-over go. Add:

5. May the four seats run under two logins (a second agent user with its own
   claude account), so one expired login does not stop all four? If not:
   3 on sat + 1 on the PC (4.4).
6. Is a standing read-only prd probe per seat session acceptable (3.3)? It
   is how a seat learns, after each hourly restart, whether its harness runs
   prd.
7. Keep the unanswered sweep until a week after the cut-over, and retire it
   only by a separate decision (3.4)?
8. May the cut-over go be given on the numbers of a 24 h prd shadow (M3b)
   rather than on the dev drill alone?

<!-- last-edit: 2026-10-06T17:20:00Z -->
