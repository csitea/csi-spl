signed against 18cafa8f66f58ff0ddec4ad73f3938d0aa0a4880

# 134 seat s134-claude (claude, EDITOR): the OD pool

Seat file of the spec 134 panel. Every claim about today cites file:line or
the command that shows it, on the tree above. Paths: `api/` =
`csi-spl-api/src/go/spool-hub-api/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `orc/` = `csi-spl-orc/src/bash/`.
Box tags are banned literals in this tree: `<box-1>` and `<box-2>` stand for
the two boxes of the fleet.

## 0. The finding that changes the draft

The draft says the earlier attempts "did not become reality". Two of them
are mostly ON TRUNK, and inert:

| piece | evidence |
|---|---|
| 068 L1..L6: the per-message claim columns, answer-once, the poll loop, mutexes, seat restart | `ls rdb/ \| grep -E '0110\|0111\|0132'` -> `0110_messages_claim.sql`, `0111_message_answers.sql`, `0132_messages_claim_round.sql`; `ls orc/run \| grep -c spl-peer-` -> 11 |
| 093 two-phase claim (offer round + accept) | `api/internal/store/message_claim.go:593` (`roundAccept`), test `TestMessageRoundAcceptRace` (`message_claim_test.go:436`) |
| 101 M1 build (the cut-over plan for 068 + 093) | `specs/101-four-orchestrator-dispatchers/tasks.md`: 3 of the 18 M1 tasks carry a done mark (T007 `e4d033d8`, T011 `e650b2a7`, T014 `0e1b35f3`); M2..M6 none |
| none of it live | `sudo -u <box user> crontab -l \| grep -o 'csi-spl:[a-z-]*'` on `<box-1>` lists `orch-rotate`, `dispatch-rotate`, `unanswered-sweep`, no `peer-*`; `ls <spool root>/peer` has no `seats` file |

So the earlier attempts did not stall for lack of an idea. They stalled
because the design grew to ~30 build tasks (offer rounds, parks, rebinds,
topic guards, D1..D16) and the cut-over never got built. The owner's
principle for this spec, "more working and robust code and less
intelligence", is the lesson: **the pool must be small enough to ship in a
week**. My review below keeps the draft's model and cuts every part that is
not needed for the owner's three asks.

## 1. Agree / disagree, per draft section

| draft section | verdict | reason |
|---|---|---|
| 1 Today: one lease per role, ranks, rotation, asks book | agree | matches `orc/run/spl-dispatch-lease.func.sh:1-60` (fleet mode, `LEASE_STALE` 180 s at :54) and the asks book |
| 1 "3 earlier attempts did not become reality" | **disagree** | 068 is v0.4.2 with L1..L6 on trunk and 093's claim on trunk (section 0); it must say "built, inert, cut-over never done", and name 093 as a fourth attempt |
| 1 101 "rejected because of the lack of shared contextual state" | **disagree** | 101 3.1 rejected static partitioning only; it RECOMMENDED the per-message claim (row d). Its build stopped at 3/18 M1 tasks (section 0) |
| 2 The model: one row per job, any free seat locks, works, closes | agree | it is the owner's model, and it moves the unit from the ROLE to the ITEM, the common cause of 068's F1..F7 (068 1.2) |
| 2 "Context is the row" | agree, with a change | 500 bytes of summary (`rdb/0097_fleet_asks.sql`, `summary ... <= 500`) is not context: the row carries a pointer to the spec 135 issue card (`issue_key`, spec 135 7.1), and the topic id; the worker reads `spool issue get` + `spool tail --task` |
| 3.1 Reuse `fleet_asks` | agree | its grain is right: a spawn request, a lane close, a box op are not messages, so 068's claim on `messages` needed D5/D12 to stretch it to topics and lanes (101 3.1). `fleet_asks` is 315 + 127 lines of store (`wc -l api/internal/store/fleet_ask*.go`); the message claim is far larger |
| 3.2 New kinds `route_post`, `lane_verify`, `box_op` | agree, plus | add `spawn` (today a `task` with `placement`, rdb 0180) and `lane_close`; the kind CHECK (`0097_fleet_asks.sql`, `kind IN ('blocker','task','escalation')`) needs a migration |
| 3.3 "The lock is an atomic UPDATE ... WHERE state = 'open'" | **disagree: that lock does not exist** | `fleet_ask.go:70` `AskAck = "ack" // open\|acked -> acked`, and `:224-225` set `acked_by` on an ACKED row too: a second seat's ack silently overwrites the first holder. Two seats both "hold" the job |
| 3.3 "Expiry is driven deterministically by do_spl_asks_tick" | **disagree** | the tick acts only on the orch holder's machine (`orc/run/spl-asks-tick.func.sh:83-84`, "its machine raises the asks"): expiry depends on the very lease the pool removes. And there is no `acked_at`: the lock age is `quiet_s` from `updated_at` (`:89-90`), default 60 min (`:52`) |
| 3.4 CLI `lock <id>`, `done`, `list --free`; WUI "OD Jobs" | agree, change one verb | no `lock <id>`: a seat that picks its own row is agent judgement in the lock path, against the draft's own rule 5.3. Only `lock-next`, `renew`, `release`, `done`, `decline`. The WUI list is after the cut-over, not on its path |
| 4 Migration: retire leases, everyone polls, simplify rotation | **disagree** | one step, no shadow, no rollback: 101 D3 shows why two deciders on prd during a hand edit is the failure; 068 F5 shows a half-applied config flapping for 3 h. Section 5 below gives shippable steps |
| 5 Robust code rules | agree, plus one | add: **the lock is renewed by a shell loop, never by the model** (068 4.1 option c: a model cannot poll and work at once) |
| 6 Build plan | agree on the shape | missing: the seat supervisor (kill + respawn, owner ask b) and the vendor fill (owner ask c), each with its test |
| Owner Q1 keep `fleet_asks`, label "OD jobs" in the WUI | agree | a rename buys nothing and costs a migration across every caller |
| Owner Q2 5 min routing / 60 min box op | **disagree** | a fixed per-kind lock either kills a long job or keeps a dead seat's job for an hour. One short lease, renewed while the seat is able (section 3.3) |

## 2. The owner's three asks vs the pool

The pool runs N seats (cnf `od_pool.seats`, default 4) with a vendor mix
(cnf `od_pool.mix`, default `claude:2, grok:2`), spread over the boxes
(cnf `od_pool.boxes`, default one claude + one grok seat per box). Seat ids
stay the role ids `c-001`, `c-002`, `g-001`, `g-002` on each box (`<id>@<box>`).

### 2.1 (a) No single failure point: at least 2 Grok + 2 Claude doing the work

- **How**: any seat locks any row. No seat is "the orchestrator", no box is
  ranked. The lease ranks (`LEASE_PRIORITY_*`) and handback go.
- **Mechanism**: the lock is one hub statement (3.3); the hub is the only
  shared component, and it is already the one every lane needs to post.
  One box down leaves the other box's 2 seats working; one vendor down
  leaves 2 seats while the supervisor refills (2.3).
- **What stays single** (stated, not hidden): the hub (Cloud Run + its
  database). Hub down = no row can be locked; lanes keep working, seats wait.
  068 4.1's local-lock fallback and 093 4.6 both ended at "no local-only job
  acts until the hub confirms" (101 3.1, A3): the pool keeps that rule.
- **Test** `od-pool-spof.tst.sh` (hermetic, hub stub): 4 seats, 40 rows;
  each row locked exactly once; kill any one seat -> its rows locked by
  another within `OD_LOCK_TTL + OD_TICK` (120 + 15 s); stop both seats of
  one box -> every row still done by the other box. Control: with
  `OD_POOL=off`, nothing is locked (proves the test sees the switch).

### 2.2 (b) A broken peer is detected quickly, killed and replaced

- **Detect**: each seat's shell loop (`do_spl_od_seat`, one per seat,
  every `OD_TICK` = 15 s) renews its locks and writes its heartbeat ONLY
  while the seat is able: the process lives and the pane shows no stall
  (the existing `spl_lease_agent_able`, `spl-dispatch-lease.func.sh:593`,
  which already reads the usage-limit and login screens, `:468-533`), AND the
  transcript grew within `OD_PROGRESS_MAX` (15 min) while it holds a row.
  Not able = no renew: its rows go free in 120 s, without anyone deciding.
- **Kill and replace**: never by another agent (093 6.3: all six panelists
  agreed: a seat may not kill a process, only the box's watchdog may). The
  kill + respawn is the 093 box watchdog that is already built:
  `do_spl_wd_takeover` (`orc/run/spl-wd-takeover.func.sh`, a fresh session
  under the same id from the spec 060 handoff, `WD_TAKEOVER_MAX` 2 per id per
  hour, `:12`, `:192`). New is only a thin supervisor per box
  (`do_spl_od_supervise`, cron every minute) that reads the hub's seat
  heartbeats and calls the takeover for a seat of ITS OWN box stale > 180 s;
  the respawned seat reads its rows' issue cards, not the old memory. A whole box stale > 300 s
  (all its seats): the other box's supervisor writes ONE `seat_replace` row
  per missing seat and the pool's own lock makes exactly one supervisor
  spawn it locally. Past the takeover cap the id is held out and the owner
  gets one alert (093 6.3).
- **Times**: job free <= 135 s; seat respawned <= 4 min; box replaced
  <= 7 min.
- **Test** `od-pool-replace.tst.sh`: SIGSTOP one seat -> its row free at
  <= 135 s, a respawn logged at <= 240 s, the new seat's heartbeat fresh;
  stale box fixture -> exactly one `seat_replace` per seat over two
  supervisors racing (the row lock), n >= 20 races. Controls: a seat in a
  10-min tool call with a live process and a growing transcript is NOT
  killed; a stale banner whose reset already passed is NOT a stall.

### 2.3 (c) One kind out -> the other kind takes all seats, and back

- **Detect**: the able check reads the limit footer and its reset epoch
  (`spl_lease_limit_until`, `spl-dispatch-lease.func.sh:510`) and the login
  screen (093 FR-000). Two seats of one vendor not able for that reason ->
  the supervisor writes `vendor_out <vendor> until <epoch>` on the hub
  (one row, kind `vendor_out`, so every box reads the same fact).
- **Fill**: the effective mix is `od_pool.mix` minus the out vendors, scaled
  back to `od_pool.seats`: `claude:2, grok:2` with claude out = `grok:4`.
  The supervisor of each box spawns the missing seats with the other vendor
  (`g-003`, `g-004`), through the same `seat_replace` rows.
- **Back**: past the reset epoch plus one able probe, the supervisor drains
  one fill seat at a time: it stops locking (`lock-next` refused for a
  draining seat), finishes or releases its rows, exits; then the vendor's
  own seat starts. Never two seats changing at once.
- **Test** `od-pool-vendor.tst.sh`: both claude seats show a limit banner
  with a future reset -> within 3 min 4 grok seats, 0 rows lost; fake clock
  past the reset -> back to 2 + 2, one seat at a time, 0 rows lost, no row
  held by two seats. Controls: one claude seat out only -> it is replaced by
  claude (the other claude login is fine), not by grok; a passed reset time
  -> no `vendor_out`.

## 3. The row

### 3.1 Fields

The existing columns (`rdb/0097_fleet_asks.sql`, 0099, 0180) stay. Added
(one migration, all with constant defaults, catalog-only):

| column | type | why |
|---|---|---|
| `lock_until` | timestamptz NULL | the lease on the hub clock; the lock is free when `lock_until < now()` |
| `gen` | bigint NOT NULL DEFAULT 0 | +1 on every lock: the fence. `done`, `decline`, `renew` and every outward act carry it; a stale gen is 409 |
| `issue_key` | text NOT NULL DEFAULT '' | the spec 135 card (`SPL-n`): the self-contained context |
| `needs` | text NOT NULL DEFAULT '' | `box:<box>` (only that box's seats lock it), `prd` (only a seat that holds the prd capability, 101 D2) |
| `not_by` | text[] NOT NULL DEFAULT '{}' | harnesses that refused it (068 F6); `lock-next` skips them |

Role is `od` for every pool row; `orch` and `dispatch` rows keep working
until the cut-over.

### 3.2 States

`open -> acked (locked: acked_by, gen, lock_until) -> done | declined`;
`acked -> open` on expiry (lazy, 3.3) or `release`; `open -> dead` after
`ASKS_MAX_RAISES` locks without a close (the existing limit,
`spl-asks-tick.func.sh:53`), with one owner alert; `queued` stays for spawn
requests waiting for room (rdb 0180).

### 3.3 The atomic lock

One statement, the hub's `lock-next` frame:

```sql
UPDATE fleet_asks SET state = 'acked', acked_by = $seat, gen = gen + 1,
       lock_until = now() + $ttl, raised_n = raised_n + 1, updated_at = now()
 WHERE (tenant_id, fleet, ask_id) = (
   SELECT tenant_id, fleet, ask_id FROM fleet_asks
    WHERE tenant_id = $t AND fleet = $f AND role = 'od'
      AND (state = 'open' OR (state = 'acked' AND lock_until < now()))
      AND ($harness <> ALL (not_by))
      AND (needs = '' OR needs = ANY ($caps))
    ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING ...;
```

- `SKIP LOCKED` = two seats in the same millisecond take different rows.
- **Expiry is lazy, inside the statement** (`lock_until < now()`): no tick,
  no holder, no box needs to run for a dead seat's row to go free. This is
  what removes the tick's dependence on the orch lease (1, row 3.3).
- `OD_LOCK_TTL` = 120 s, renewed every `OD_TICK` (15 s) by the seat's shell
  loop (`renew` frame: `lock_until = now() + ttl WHERE acked_by = $seat AND
  gen = $gen`). The lock length is one number for every kind; a long job
  stays locked because it is renewed, not because its lock is long.
- The existing `ack` op gets the CAS it lacks: an ack of a row acked by
  another seat with a live lock is 409 naming the holder (fixes
  `fleet_ask.go:224-225`).

### 3.4 Each job kind becomes a row

| job | who writes the row | key (idempotent) | done when |
|---|---|---|---|
| owner post to route (`route_post`) | the hub, at insert of a human post in a seated workspace (where 0110's `needs_peer` trigger sits today) | the post's msg_id | the seat answered (`answers=` guard, rdb 0111) or handed it to a lane |
| spawn request (`spawn`) | `spool-send.sh --kind task` to `orchestrator` (today's ask) | the msg_id | the lane exists (registry row); `placement` carries vendor:slug (0180) |
| ACCEPTED check (`lane_verify`) | `spool-send.sh --kind result` from a lane | the msg_id | ACCEPTED or a send-back sent, under the gen |
| lane close (`lane_close`) | the ACCEPTED send | `close:<lane id>` hashed to a uuid | window closed and id retired (`do_spl_agent_id_retire`) |
| box op (`box_op`, `needs = box:<box>`) | the asker | the msg_id | the named action ran on that box |
| seat replace (`seat_replace`) | a box supervisor | `seat:<id>@<box>:<hour>` | the new seat's heartbeat is fresh |

## 4. Migration: each step ships alone, each has a rollback

| step | what | who decides during it | rollback |
|---|---|---|---|
| P1 | store + hub: the 5 columns, `lock-next` / `renew` / `release` frames, the `ack` CAS, the new kinds; `spool ask lock-next\|renew\|release` CLI. Memory + Postgres tests | the lease, as today (nothing writes `role = od`) | revert; the columns are additive |
| P2 | orc: `do_spl_od_seat` (loop) and `do_spl_od_supervise` (cron), both inert unless cnf `od_pool.enabled` | the lease | revert |
| P3 | producers dual-write: owner posts, results, spawn asks, closes also write `od` rows | the lease (no seat locks them) | stop the dual write |
| P4 | dev drill: 4 seats against the dev hub, the three tests of section 2 live, n >= 5 each | prd: the lease | `od_pool.enabled=false` on dev |
| P5 | prd shadow 24 h: seats lock in `OD_SHADOW=1` (lock, log, release at once, act never) | the lease only | `od_pool.enabled=false` |
| P6 | cut-over, ONE action `do_spl_od_cutover` (101 D3 shape): every box or none: stop the lease loops, move `lease.conf` aside, remove `orch-rotate` / `dispatch-rotate`, enable the pool | the seats | `do_spl_od_cutover ROLLBACK=1` restores `lease.conf`, the crons, `LEASE_CMD=ensure` |
| P7 | soak 7 days, the unanswered sweep kept (101 D7: the one check that does not trust the lock) | the seats | P6's rollback |
| P8 | delete: the lease role code, the two rotations, and (owner Q5) the inert 068/093 claim code | the seats | git revert |

## 5. Risks, with evidence

| risk | evidence | in the pool |
|---|---|---|
| the build grows and never cuts over | 101 M1: 3 of 18 tasks done six days after consensus (section 0) | 8 steps, no offer rounds, no parks, no topic guard; P1..P3 are ~1 lane each |
| a half-applied switch flaps the fleet | 068 F5: 203 take-overs in 3 h from one rank line | no ranks; the cut-over is one action, every box or none |
| one login freezes every seat | 068 F2 (all seats of a box at the usage limit at once); global CLAUDE.md, 2026-10-01 fleet stop | the mix is two vendors over two boxes; 2.3 fills the other way |
| the single lease still fails over today | `grep -c "^2026-10-1[0-2].*takes over" <spool root>/dispatch/lease.log` on `<box-1>` -> 20 (3 + 8 + 9), silences 45..249 s | no lease to fail over; a silent seat loses only its rows, in 120 s |
| re-raises go to a frozen holder | 068 F3: 57 re-raise blockers to one frozen seat | no "holder": an unlocked row is offered to every able seat by `lock-next` |
| two seats both believe they hold a job | `fleet_ask.go:224-225` (ack overwrites); 101 E10 (two orchs spawned 20 lanes) | the lock CAS + gen fence; spawn refuses an existing lane id (101 D5, reused) |
| expiry depends on the role it replaces | `spl-asks-tick.func.sh:83-84` | lazy expiry in `lock-next` |
| tokens: 4 active seats cost more than 1 | 101 8.2: ~20 M cache-read tokens per active orch hour; U4 unmeasured | a seat sees only the rows it locks (no channel fan-out to all four); measure U4 in P4 |
| the hub is still one point | it is the delivery path for every post today | stated in 2.1; owner Q7 |

## 6. Owner questions

1. **Which table carries the jobs?** A: `fleet_asks` with 5 new columns
   (the draft, this seat). B: the 068/093 claim on `messages` (built, inert,
   ~15 tasks from live). C: a new `od_jobs` table. **Recommend A**: smallest
   working code, the right grain for spawns and box ops.
2. **Where do the four seats run?** A: one claude + one grok seat on each
   of two boxes. B: all four on one box. C: four per box (eight, 068).
   **Recommend A**: one box or one vendor down still leaves two working.
3. **Lock length.** A: one 120 s lease, renewed every 15 s by the seat's
   shell loop while the seat is able. B: fixed per kind (draft: 5 min
   routing, 60 min box op). **Recommend A**.
4. **Who kills a broken seat?** A: a shell supervisor on the seat's own box;
   the other box only respawns a missing seat through a row. B: the peer
   agents kill each other. **Recommend A** (093 6.3, six of six).
5. **The inert 068/093 claim code** (rdb 0110/0111/0132 columns,
   `spl-peer-*`). A: keep inert, delete at P8. B: delete now. C: build the
   pool on it instead (owner Q1 B). **Recommend A**.
6. **Rename `fleet_asks`?** A: keep the name, label it "OD jobs" in the WUI
   (the draft). B: rename. **Recommend A**.
7. **Hub down.** A: the pool waits; lanes keep working; the owner alert
   comes from the box supervisor after 10 min. B: a local fallback lock per
   box. **Recommend A** (101 3.1 A3: no local-only job acts).
8. **Cut-over go.** A: P6 runs when P4 and P5 pass their numbers (2.1..2.3
   tests live, n >= 5; shadow: every row exactly one locker). B: the owner
   gives a separate go after reading the numbers. **Recommend A**, with the
   numbers posted to the owner either way.

## 7. Tasks for the build lanes (input to the editor's fold)

| id | lane | files | test |
|---|---|---|---|
| T1 | hub/store | next free `rdb/` migration; `api/internal/store/fleet_ask*.go`; the ask frame + `spool ask` CLI | `TestFleetAskLockNext` (Memory + Postgres): 4 seats x 100 rows, each locked once; expiry; gen fence; ack CAS; `not_by`, `needs` |
| T2 | orc seat loop | `orc/run/spl-od-seat.func.sh` (new) | `od-pool-spof.tst.sh` |
| T3 | orc supervisor + vendor fill (calls the existing `do_spl_wd_takeover`, never kills itself) | `orc/run/spl-od-supervise.func.sh` (new) + its `_install_cron` | `od-pool-replace.tst.sh`, `od-pool-vendor.tst.sh` |
| T4 | producers dual-write | `spawn-agents/scripts/spool-send.sh`, the hub post insert | one row per send, idempotent on replay |
| T5 | cut-over + rollback | `orc/run/spl-od-cutover.func.sh` (new) | every box or none; rollback restores the crontab fixture byte for byte |
| T6 | drill + shadow numbers | `specs/134-od-pool/research/` | section 2 times, n >= 5 |
| T7 | docs | `SPEC-spool-fleet-roles.md` sections 1..4 | `do_check_dist_hygiene` |
