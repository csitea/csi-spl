# 134: OD pool (orchestrators and dispatchers)

Status: **v1.0-rc1, panel fold, 2026-10-12**: awaiting the four seats' signatures (section 9).
Editor s134-claude (c-886). Merged from the four seat files in `reviews/`
against origin/master 84fdd62ae. The owner decides the questions in
section 10. Build lanes make every code change after v1.0; this spec changes
no code. Issue: SPL-1562.

Paths: `api/` = `csi-spl-api/src/go/spool-hub-api/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `orc/` = `csi-spl-orc/src/bash/`.
Box tags are banned literals in this tree: `<box-1>` and `<box-2>` stand for
the two boxes of the fleet.

## 0. The owner's words (HUM-10, verbatim)

t1 topic `e799211c`, 2026-10-11:

> 12:22Z "We need to change the architecture to have more than one failure
> point orchestrator/dispatcher, so there need to be at least two Grok agents
> and two Cloud agents doing this work."

> 12:23Z "And they should be able to quickly detect whether or not one of
> their working pairs is not functioning properly, then kill him and spawn
> another one."

> 12:24Z "Yes, and the way it should behave is that if, let's say, the
> Claude agents get a weak limit, then the Grok agents will become 4, and they
> will take over."

The principle: "more working and robust code and less intelligence with this
priniciple in mind".

t1 `ee1e58d5`, msg `66be69c2`, 2026-10-12: "Wait for spec 134." He was
offered a sooner path (the lease counts grok and vibe holders,
`orc/run/spl-dispatch-lease.func.sh:214`, plus `ROTATE_ORCH_SPLIT=1`,
`orc/run/spl-orch-rotate.func.sh:144-179`). He chose to let this spec bring
Grok into the OD roles. That vendor check is migration step P0 (section 5).

## 1. Today: how roles work now

Today the fleet runs single-lease roles across machines, managed by code:
- **One lease per role.** `do_spl_dispatch_lease LEASE_CMD=fleet` (`orc/run/spl-dispatch-lease.func.sh:89`) loops every `LEASE_PERIOD`, default 60 s (`:102`). The hub holds one lease per role; each box mirrors it into `$SPOOL_ROOT/dispatch/lease` and `lease.orch` as `<ID>@<box> <epoch>` (`:33-34`). Only the holder dispatches or orchestrates.
- **Ranked boxes.** `LEASE_PRIORITY_ORCH` and `LEASE_PRIORITY_DISPATCH` (`:59`) are applied in `spl_fleet_rank` (`:1041-1046`), demoted by beat health since 2026-10-11 (`:1049-1058`). Failover happens when the holder is silent for more than `LEASE_STALE`, 180 s (`:54`; exactly 180 s does not promote, `orc/tests/dispatch-lease.tst.sh` case 4).
- **Only a claude process holds a lease.** `spl_lease_agent_pid` counts only `comm == claude` (`:214`). A grok orchestrator would hold the role but not the lease (`orc/run/spl-orch-rotate.func.sh:168-170`).
- **Hourly role rotations.** `do_spl_orch_rotate` and `do_spl_dispatch_rotate` replace the session every hour under the same id (handoff, spawn, retire by `/exit-clean`, TERM, then KILL; `orc/run/spl-orch-rotate.func.sh:14-20`), against context buildup (spec 060).
- **The asks book.** Asks to the orchestrator are rows in `fleet_asks` (`rdb/0097_fleet_asks.sql`, 0099, 0180; store `api/internal/store/fleet_ask.go`, `fleet_ask_postgres.go`; actions `spl-asks-tick`, `spl-asks-open`, `spl-ask-ack`, `spl-ask-close`, `spl-ask-put`). `do_spl_asks_tick` re-raises an unacked ask and releases an ack whose holder has been quiet for `ASKS_LOCK_MIN` (default 60 min, `orc/run/spl-asks-tick.func.sh:52`).

**Two defects of today's book** (all four seats):
- **The ack is not a compare-and-set.** `UpdateFleetAsk` reads the row `FOR UPDATE` and writes it back by primary key with no `AND state = 'open'` (`fleet_ask_postgres.go:70-86`). `applyAskOp` sets `acked_by` on an already ACKED row (`fleet_ask.go:70`, `:224-225`), so a second seat's ack silently replaces the first holder.
- **Expiry needs the lease.** There is no `acked_at` column (`rdb/0097_fleet_asks.sql`); the lock age is quiet time from `updated_at` (`fleet_ask.go:169-176`). The release runs only on the orch holder's machine (`spl-asks-tick.func.sh:78-86`); with no holder the tick returns and releases nothing.

**The earlier attempts.** They did not fail for lack of an idea. Two are
mostly built on trunk and were never switched on (s134-claude, s134-agy,
s134-grok):

1. **068 peer seats** (v0.4.2, owner-answered 2026-10-03): the per-message
   claim (`rdb/0110_messages_claim.sql`), answer-once (`0111`), the poll
   loop, mutexes and seat restart (`ls orc/run | grep -c spl-peer-` -> 11).
   On trunk but inert: no `peer/seats` file and no `peer-*` cron.
2. **093 agent watchdog** (v0.2, 2026-10-05): the two-phase claim (offer
   round + accept, `rdb/0132_messages_claim_round.sql`,
   `api/internal/store/message_claim.go:593`) and the box watchdog
   (`do_spl_wd_takeover`, `orc/run/spl-wd-takeover.func.sh`). The watchdog is
   live (`wd-start` cron).
3. **101 four orchestrator-dispatchers** (v0.4.1, 2026-10-06) rejected
   static partitioning ("no: re-creates one SPOF per box; sat idle, PC
   overloaded stays so", `specs/101-four-orchestrator-dispatchers/spec.md:122`)
   and recommended the 068 + 093 claim per job. It did not go live for two
   reasons. The seats switch was never turned on (101 section 1.3). The built
   claim works per message, not per ask, topic or lane (101 3.2), and a
   follow-up reaches a new owner with nothing to read (r3), which is the
   "shared context" gap. The build stopped at 3 of 18 M1 tasks (T007
   `e4d033d8`, T011 `e650b2a7`, T014 `0e1b35f3`, `tasks.md`).
4. **The leader-seats arrangement** of 2026-10-11 (the vendor
   load-balancing blog post): two Claude and two Grok seats, with one vendor
   filling all four. It was never specified.

The lesson, which is also the owner's principle: the design grew to about 30
build tasks (offer rounds, parks, rebinds, topic guards, D1..D16) and never
cut over. **The pool must be small enough to build in about a week, and must
switch on one kind of job at a time.**

## 2. The owner's model: OD pool

Every OD job (an owner post to route, a spawn request, an `ACCEPTED` to
verify, a lane to close, a box op) is **ONE row in a shared table**, like
the Flow.

There are N OD seats, each orchestrator and dispatcher at once, on any box.
Any free seat:
1. Locks one row atomically (compare-and-set with a lease).
2. Works it.
3. Closes it.

If the holder goes silent, the lock expires and another free seat takes the
row. **Context is the row, not the seat's memory**: the row holds pointers,
not copies. These are its topic, its spec 135 issue card (`issue_key`, spec
135 7.1: scope, must-not-touch, test, next step) and its source message. A
seat reads `spool issue get <key>` and `spool tail --task <topic>` when it
locks the row. A copy in the row would be stale at the next post
(s134-grok, s134-claude; owner question Q4).

## 3. Data, lock and expiry

### 3.1 The table: `fleet_asks`, role `od`

Pool rows live in `fleet_asks` with `role = 'od'` (s134-claude, s134-agy,
s134-mistral; s134-grok wants a new `od_jobs` table, owner question Q1).
The ask book's `orch` and `dispatch` rows keep their 60-minute lock and tick
until the cut-over. The new ops touch only `role = 'od'` rows, so the two
lock regimes never mix.
- It already has job states, a delivery counter (`raised_n`), a dead letter,
  the spawn queue (rdb 0180) and the `spool ask` CLI.
- Its grain is right: a spawn request, a lane close and a box op are not
  messages, which is why 068's claim on `messages` needed D5 and D12 (101
  3.1).
- It is small: `wc -l api/internal/store/fleet_ask*.go` -> 315 + 127 lines.

One more row per tenant and fleet, `od_pool` (new, tiny): the target
`claude_n`, `grok_n`, `min_boxes`, the vendor-out `until`, and `kinds` (the
job kinds the pool consumes, section 5). It is written only under the
`fleet-config` mutex (068 section 5), so a config line on one box cannot
move it (068 F5) (s134-grok).

### 3.2 Schema additions (one migration, constant defaults, catalog-only)

| column | type | why |
|---|---|---|
| `lock_until` | timestamptz NULL | the lease on the hub clock; free when `lock_until < now()` |
| `lease_s` | integer NOT NULL DEFAULT 120 | the lease length of this row, from cnf per kind (owner question Q2) |
| `gen` | bigint NOT NULL DEFAULT 0 | +1 on every lock, and on every session change of the holder (101 D13): the fence. `renew`, `done`, `decline` and every outward act carry it; a stale gen gets 409 |
| `dedupe_key` | text NOT NULL DEFAULT '' | partial unique index on `(tenant_id, fleet, kind, dedupe_key) WHERE state IN ('open','acked','needs_owner') AND dedupe_key <> ''`: a second open insert of the same job conflicts; a closed one does not block the next (s134-grok) |
| `issue_key` | text NOT NULL DEFAULT '' | the spec 135 card; empty until the issue exists (a `route_post` files it first) |
| `vendor_allow` | text NOT NULL DEFAULT '' | `''`, `claude` or `grok` |
| `needs` | text NOT NULL DEFAULT '' | `box:<box>` (only that box's seats lock it), `prd` (only a seat with the prd capability, 101 D2) |
| `not_by` | text[] NOT NULL DEFAULT '{}' | harnesses that refused it (068 F6); `lock-next` skips them (s134-mistral, s134-claude) |

New `kind`s (the CHECK in `rdb/0097_fleet_asks.sql` allows `blocker`,
`task`, `escalation` today): `route_post`, `spawn`, `lane_verify`, `box_op`.
`lane_verify` covers the ACCEPTED check and the lane close as one job
(s134-grok).

New state `needs_owner` (s134-grok): not lockable. The row waits for a human
answer, as in spec 135 Q2: a prd mutation the safety check refuses, or a job
whose acceptance says a human decides. A human answer moves it to `open` or
`declined`.

### 3.3 Atomic lock and expiry

The lock is ONE hub statement, the `lock-next` frame (s134-claude,
s134-grok, s134-mistral):

```sql
UPDATE fleet_asks SET state = 'acked', acked_by = $seat, gen = gen + 1,
       lock_until = now() + make_interval(secs => lease_s),
       raised_n = raised_n + CASE WHEN state = 'acked' THEN 1 ELSE 0 END,
       updated_at = now()
 WHERE (tenant_id, fleet, ask_id) = (
   SELECT tenant_id, fleet, ask_id FROM fleet_asks
    WHERE tenant_id = $t AND fleet = $f AND role = 'od'
      AND kind = ANY ($pool_kinds)
      AND (state = 'open' OR (state = 'acked' AND lock_until < now()))
      AND (vendor_allow = '' OR vendor_allow = $vendor)
      AND ($harness <> ALL (not_by))
      AND (needs = '' OR needs = ANY ($caps))
    ORDER BY created_at, ask_id
    LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING ...;
```

- `SKIP LOCKED`: two seats in the same millisecond take different rows; a
  second caller on the last free row gets zero rows.
- **Expiry is lazy, inside the statement** (`lock_until < now()`), so no
  tick, holder or box has to run for a dead seat's row to go free. That
  removes the single runner of section 1. A lock lost by expiry counts in
  `raised_n`; at 4 the row goes `dead` and one note goes to a pool seat (the
  owner is told only when no able seat remains, as `ASKS_ALERT` today).
- **Renew** by the holding session only, every `OD_TICK` (15 s), while the
  seat is able: `UPDATE ... SET lock_until = now() + make_interval(secs =>
  lease_s) WHERE ask_id = $id AND state = 'acked' AND acked_by = $seat AND
  gen = $gen`. Zero rows = the lock was lost; the seat stops that job. A
  long job stays locked because it is renewed, not because its lease is
  long.
- **Release on kill**: when the supervisor kills a seat (4.2), one hub call
  frees every row with that `acked_by` and gen (s134-grok).
- The existing `ack` op gets the compare-and-set it lacks: an ack of a row
  acked by another seat with a live lock is 409 naming the holder (fixes
  `fleet_ask.go:224-225` for the ask book too).

### 3.4 CLI, actions and WUI

- **CLI**: `spool ask lock-next`, `renew`, `release`, `done`, `decline`,
  `enqueue`, `list --free`. There is no `lock <id>`: a seat that picks its
  own row puts agent judgement in the lock path (rule 6.3).
- **Orc actions**: `do_spl_od_seat` (the seat's shell loop: renew,
  heartbeat, `lock-next`, hand the row to its agent's inbox and ring the
  pane) and `do_spl_od_pool_supervise` (section 4.2). Per kind, they replace
  the lease holder's `do_spl_orch_inbox` and `do_spl_take`.
- **WUI**: the "OD jobs" list (open, locked, needs owner, recently closed;
  RLS `tenant_scope`) comes after the cut-over, not on its path (all four
  seats).

### 3.5 What inserts each job

Code inserts rows. A seat never notices a post by reading its pane: that was
the missed doorbell in spec 101 (section 1, E4) (s134-grok).

| job | inserted by | `dedupe_key` | done when |
|---|---|---|---|
| owner post (`route_post`) | the hub transaction that stores a human post in a seated workspace, when that topic has no open `route_post` | the post's msg_id | answered (the `answers=` guard, rdb 0111), or handed to a lane with its issue filed |
| spawn request (`spawn`) | `spool ask enqueue`, by the seat that closed a `route_post`, or by a lane | `<topic>:<slug>` (101 D5) | the lane exists; the launcher takes the `spawn` mutex and refuses a second lane for that key; `placement` = vendor:slug (rdb 0180) |
| ACCEPTED check and lane close (`lane_verify`) | a result body starting with `ACCEPTED`, and the lane exit hook when a session ends without one | the issue key | landed sha checked, issue state checked, worktree gone, window closed, id retired (`do_spl_agent_id_retire`); then the dispatch holder is told. Seats never post in the owner topic |
| box op (`box_op`, `needs = box:<box>`) | the ingest of an owner-signed directive, or an existing named action | the msg_id | the named action ran on that box. `summary` is the exact command; a seat never invents a box op; a prd mutation the safety check refuses becomes `needs_owner` |

The unanswered sweep (`orc/run/spl-unanswered-sweep.func.sh`) stays and
keeps listing. Once ingest is on, it also inserts a `route_post` for a human
post that ingest missed. It is the one check that does not trust the pool
(101 D7).

## 4. The owner's three asks: mechanism and proof

The pool's target is the `od_pool` row: `claude_n = 2`, `grok_n = 2`,
`min_boxes = 2` (placement, owner question Q3). Pool seats are **new agent
ids**, not the lease ids `c-001..c-003`, so the lease holders and the pool
run side by side during the per-kind migration, and a lease failover moves
no pool work (s134-grok).

### 4.1 (a) No single failure point

- **How**: any able seat of either vendor locks any free row. No seat is
  "the orchestrator", and no box is ranked for pool work.
- **Mechanism**: the lock (3.3). One box down leaves the other box's seats
  working. One vendor down leaves the other vendor's seats working while the
  supervisor refills (4.3). A box the hub's beats call degraded
  (`spl-dispatch-lease.func.sh:1049-1058`, the 2026-10-11 uplink) gets no
  new seats and its seats get no new rows. Its existing locks keep renewing:
  beats alone never kill a session (s134-grok).
- **What stays single, stated**: the hub (Cloud Run and its database). If
  the hub is down, no row can be locked; lanes keep working and seats wait
  (owner question Q6).
- **Test** `od-pool-spof.tst.sh` (hermetic, hub stub; store races in
  `TestFleetAskLockNext`): 4 seats, 1 open row, n >= 20 races -> exactly
  one `acked`. 40 rows -> each locked exactly once. SIGKILL the holder ->
  the row is released, a seat of the OTHER vendor locks it and closes it,
  exactly one `done`. The expiry runs from the box that does NOT hold the
  orch lease. Controls: 2 rows and 2 seats -> both `acked`; `kinds` empty
  -> nothing locked.

### 4.2 (b) A broken peer is detected quickly, killed and replaced

- **Able** is one function for "offer" and "kill": `spl_lease_agent_able`
  (`spl-dispatch-lease.func.sh:593`). It needs a live pid and nothing from
  `spl_lease_stall` (`:468`), whose `LEASE_STALL_RE` (`:310`) matches the
  usage limit, `/login` and an invalid key. Using one function for both
  avoids 068 F4, where the rotation gate said "stalled" while the lease loop
  still chose the seat. The seat's loop also stops renewing when the
  transcript has not grown for `OD_PROGRESS_MAX` (15 min) while it holds a
  row.
- **Who**: `do_spl_od_pool_supervise`, a shell action every 30 s on every
  box. It kills and spawns only seats whose home box is its own box. Agents
  never kill agents (093 6.3, six of six panelists; all four seats here).
- **Steps**:
  1. First failed able check: the seat gets no new rows (`lock-next`
     refuses it). Its current row stays until release.
  2. Second consecutive failed check (about 60 s): the gen of the seat's
     rows is bumped (101 D13), the rows are released (3.3), and the seat is
     killed and respawned through the existing path, `do_spl_wd_takeover`
     (`orc/run/spl-wd-takeover.func.sh`: handoff, spawn, then retire by
     `/exit-clean`, TERM, KILL, the rotation's retire,
     `spl-orch-rotate.func.sh:14-20`), same vendor, so the target count
     holds.
  3. `WD_TAKEOVER_MAX` is 2 per id per hour (`spl-wd-takeover.func.sh:12`,
     `:192`). Past it, the id is held out and one note goes to the dispatch
     holder (093 6.3).
- **Whole box gone** (every heartbeat of a box stale > 300 s): the other
  box's supervisor spawns the missing seats locally to meet `min_boxes` when
  it can. Two supervisors race for this through a `spawn` row with key
  `seat:<id>`, so exactly one spawns (s134-claude).
- **Times** (lease 120 s): a dead seat's row is free within 135 s, or
  within about 60 s when the supervisor kills it; the seat is replaced within
  about 2 min; a box's seats within about 6 min.
- **Test** `od-pool-replace.tst.sh`: plant the usage-limit banner on one
  Grok seat, n >= 10 -> within two ticks that pid is gone, a new Grok pid of
  the same target exists, the target stays 2 + 2, the old session's renew
  matches zero rows. A stale-box fixture with two supervisors racing, n >=
  20 -> exactly one spawn per missing seat. Controls: a seat in a 10-minute
  tool call with a live process and a growing transcript keeps its pid; a
  banner whose reset already passed is not a stall.

### 4.3 (c) One kind out -> the other kind takes all seats, and back

- **Detect** (s134-grok): a vendor is out when EVERY seat of that vendor
  failed the able check for two ticks and at least one failure is a
  `LEASE_STALL_RE` banner (weekly limit, login wall). One seat down while its
  partner is able is 4.2: replace that one seat, target unchanged.
- **Fill**: one update of `od_pool` under the `fleet-config` mutex: the out
  vendor's `n` becomes 0, the other's becomes 4, and `until` is the banner's
  reset (`spl_lease_limit_until`, `spl-dispatch-lease.func.sh:510-531`), or
  empty when the banner gives none. The out vendor's seats are killed and not
  respawned. The other vendor is spawned up to 4, spread so `min_boxes`
  holds where a second box can run it; where it cannot, one note goes to the
  dispatch holder. Rows need no move: a frozen seat stops renewing, its rows
  go free, and the working seats lock them (s134-agy, s134-mistral).
- **Back**: when `until` has passed, or a process of the out vendor is able
  again, the target returns to 2 + 2. Extra seats get no new rows, and each
  is retired once it holds zero rows, so a seat inside a job finishes it.
  One seat changes at a time.
- **Fleet-wide, not per box**: 068 F2 (`specs/068-peer-seats/spec.md:71`):
  one login froze every seat on a box, and the re-raise (F3, `:72`) kept
  going to the frozen holder.
- **Test** `od-pool-vendor.tst.sh`: both Claude seats show `usage limit`
  with a future reset -> after two ticks `claude_n = 0`, `grok_n = 4`, and a
  new `route_post` is `acked_by` a Grok seat. Advance the clock past
  `until` -> back to 2 + 2; a Grok seat holding a row is still alive, one
  holding none is gone; 0 rows lost, no row held by two seats. Controls: one
  Claude able and one stalled -> target stays 2 + 2, only the stalled pid is
  replaced; a passed reset time -> no vendor-out.

## 5. Migration from the single lease

Each step ships alone and has its own rollback. The lease loops keep running
until P8. Nothing is a big bang (068 F5, 101 D3) (s134-grok, s134-claude).

| step | ships | who does OD work meanwhile | rollback |
|---|---|---|---|
| P0 | **the lease counts the seat's vendor** (owner, msg `66be69c2`): `spl_lease_agent_pid` (`spl-dispatch-lease.func.sh:214`) counts a `grok` or `vibe` process with the holder's `SPOOL_AGENT_ID`, so a grok holder keeps its lease until P8 and after any rollback. `ROTATE_ORCH_SPLIT` stays 0 until P5 passes | the lease | revert; claude-only again |
| P1 | store + migration: the columns, kinds, `needs_owner`, `od_pool`, the dedupe index, the `ack` compare-and-set. Memory + Postgres tests | the lease (no `od` rows) | leave the columns; nothing reads them |
| P2 | hub ops + CLI: `lock-next`, `renew`, `release`, `enqueue`, `done`, `decline` | the lease | stop exposing the ops |
| P3 | `do_spl_od_seat` + `do_spl_od_pool_supervise`, flag `OD_POOL_SUPERVISE`: keeps 2 + 2 alive with `kinds` empty, so no seat locks anything | the lease | flag off; the supervisor retires the seats it spawned |
| P4 | ingest: the inserts of 3.5, flag `OD_POOL_INGEST`; the rows wait unlocked | the lease | flag off; one admin op declines the open rows |
| P5 | dev drill: the three tests of section 4 live on dev, n >= 5 each, and the token cost of one active seat in a quiet hour (101 U4) | prd: the lease | `kinds` empty on dev |
| P6 | per-kind cut-over on prd, ONE kind per push, in the order `lane_verify`, `spawn`, `route_post`, `box_op`: add it to `od_pool.kinds`; the lease holder skips the kinds listed there. The `spawn` step copies today's `queued` asks (rdb 0180) into `spawn` rows | the pool for the listed kinds, the lease for the rest | remove the kind; the holder does it again; in-flight locks expire back to `open` |
| P7 | the sweep inserts a `route_post` for a miss, and still lists | the pool | the sweep's recipient returns to the lease holder |
| P8 | after a soak the owner names: the lease loops stop doing OD work (`do_spl_od_cutover`, every box or none). Pool seats keep the hourly restart (spec 060), staggered; the handoff is "renew your `acked` rows under the new gen" | the pool | `do_spl_od_cutover ROLLBACK=1`: `LEASE_CMD=ensure`, `kinds` empty |
| P9 | delete the lease role code and the inert 068/093 claim code (owner question Q8) | the pool | git revert |

## 6. Robust code rules

1. **Deterministic lock and expiry in code**: the agent never decides
   whether a job is locked; the hub statement does.
2. **Tests with red controls**: every lock transition, expiry, kill and
   vendor swap has a hermetic test with a negative control.
3. **No agent judgement in the locking path**: the seat's loop calls
   `lock-next`, and when it gets a row its agent acts.
4. **The lock is renewed by a shell loop, never by the model** (068 4.1
   option c: a model cannot poll and work at once).
5. **One "able" function, and a script kills**: `spl_lease_agent_able`
   decides both offering and killing; only `do_spl_od_pool_supervise` kills,
   and only on its own box. Agents never kill agents.

## 7. Risks, with evidence

| risk | evidence | in the pool |
|---|---|---|
| the build grows and never cuts over | 101 M1: 3 of 18 tasks six days after consensus (section 1) | 10 small steps, each live on its own; one kind at a time |
| a half-applied switch flaps the fleet | 068 F5 (`specs/068-peer-seats/spec.md:74`): 203 take-overs in about 3 h from one rank line | no ranks; the target and the kinds are one hub row under the `fleet-config` mutex |
| one login freezes every seat | 068 F2, F3 (`:71-72`); the 2026-10-01 fleet stop | two vendors, fleet-wide target; 4.3 fills from the other vendor |
| two judges of "able" disagree | 068 F4 (`:73`): 48 take-overs in one hour by a stalled seat | one function for offer and kill (rule 6.5) |
| the single lease fails over today | `grep -c "^<day>.*takes over" <spool root>/dispatch/lease.log` on `<box-1>`: 10-10 3, 10-11 8, 10-12 9; silences 45..249 s (s134-claude); 206 on 2026-10-03 (s134-agy) | no lease for OD work; a silent seat loses only its rows |
| static partitioning re-creates a SPOF per box | 101 3.1 (`specs/101-four-orchestrator-dispatchers/spec.md:122`) | no partition: any seat, any row |
| two seats both hold a job | `fleet_ask.go:224-225`; 101 E10 (two orchestrators spawned 20 lanes) | compare-and-set + gen; the spawn key under the `spawn` mutex |
| two sessions of one seat | 101 D13: the restart runs both for up to 330 s | the gen is bumped before the new session starts; the old renew matches zero rows |
| expiry depends on the role it replaces | `spl-asks-tick.func.sh:78-86` | lazy expiry in `lock-next`, any box |
| degraded uplink | `spl-dispatch-lease.func.sh:1049-1058` (2026-10-11, 3.5 h) | a degraded box gets no new seats or rows; kill only on a stall banner or a dead pid |
| queued spawns stranded | rdb 0180 queues spawn asks in `fleet_asks` | P6's spawn step copies them |
| 4 active seats cost more tokens | 101 8.2: about 20 M cache-read tokens per active orchestrator hour; U4 unmeasured | a seat reads only the rows it locks; U4 measured in P5 |
| hub down stops the pool | the hub carries every post; spec 093's 2026-10-05 incident (s134-mistral) | stated (4.1); owner question Q6 |

## 8. Tasks for the build lanes

| id | step | lane | files | test |
|---|---|---|---|---|
| T0 | P0 | orc | `orc/run/spl-dispatch-lease.func.sh` (`spl_lease_agent_pid` only) | a grok process with the holder's id renews the lease; control: a grok process with another id does not |
| T1 | P1, P2 | hub/store | the next free `rdb/` migration; `api/internal/store/fleet_ask*.go`; the ask frame; the `spool ask` CLI | `TestFleetAskLockNext` (Memory + Postgres): races, expiry, gen fence, ack compare-and-set, dedupe, `needs_owner`, `not_by`, `needs`, `vendor_allow` |
| T2 | P3 | orc | `orc/run/spl-od-seat.func.sh` (new) | `od-pool-spof.tst.sh` |
| T3 | P3 | orc | `orc/run/spl-od-pool-supervise.func.sh` (new) + its `_install_cron`; calls `do_spl_wd_takeover`, never kills by pattern | `od-pool-replace.tst.sh`, `od-pool-vendor.tst.sh` |
| T4 | P4, P7 | hub + orc | the hub post insert; `spawn-agents/scripts/spool-send.sh`; the lane exit hook; `orc/run/spl-unanswered-sweep.func.sh` | one row per job, idempotent on replay; a missed post gets one row |
| T5 | P6 | orc | the lease holder's skip of `od_pool.kinds` (`spl-orch-inbox`, `spl-take`) | a listed kind is never handled by the holder; control: an unlisted one is |
| T6 | P8 | orc | `orc/run/spl-od-cutover.func.sh` (new) | every box or none; rollback restores the crontab fixture byte for byte |
| T7 | P5 | orch | `specs/134-od-pool/research/` | the section 4 times, n >= 5; U4 |
| T8 | after P8 | doc | `csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md` sections 1..4 | `do_check_dist_hygiene` |

T0 and T1 run in parallel; T2..T4 need T1; T5 needs T2..T4; T7 needs T5 on
dev; T6 is last before T8.

## 9. Panel and consensus

Seat files: `reviews/s134-claude.md` (c-886, a9a496765),
`reviews/s134-grok.md` (g-887, 84fdd62ae), `reviews/s134-mistral.md` (m-888,
6c7e3b305, signed against 28484d78a), `reviews/s134-agy.md` (a-354, 8ec9900b2, revised 42cc572a0 after
the editor's send-back for citations). Each commit is its own one file
(`git show --stat`).

| decision | claude | grok | mistral | agy | in v1.0 |
|---|---|---|---|---|---|
| one row per job, any able seat locks (draft 2) | agree | agree | agree | agree | yes |
| draft 1 "earlier attempts did not become reality" | disagree: built, inert | disagree | agree | disagree: built, inert | corrected (section 1) |
| today's ack is a compare-and-set (draft 3.3) | no (`fleet_ask.go:224`) | no | proposes one | no | no: fixed in P1 |
| expiry by the tick on the holder's box | no: lazy in the lock | no: any box | the tick | tick on every box | lazy in `lock-next` (3.3) |
| table | `fleet_asks` | new `od_jobs` | `fleet_asks` | `fleet_asks` | `fleet_asks`, role `od` (Q1, 3:1) |
| lease length | 120 s renewed | per kind, renewed | 5 / 60 min | 5 / 60 min | per-kind `lease_s`, default 120 s, renewed (Q2, 2:2) |
| who kills | box supervisor via the watchdog | box supervisor, every 30 s | the 093 watchdog | the watchdog | a box supervisor every 30 s, via `do_spl_wd_takeover` |
| one vendor out | fill to 4 | target row to 4 | other vendor takes the rows | other vendor takes the rows | target row to 4, and back (4.3) |
| placement | fleet-wide | fleet-wide, `min_boxes` 2 | 4 per box | 4 per box | fleet-wide (Q3, 2:2) |
| context | issue card pointer | pointers | `payload` copy | n/a | pointers (Q4) |
| migration | shadow + one switch | per kind, flags | one switch | one switch | per kind (P6), one switch only for the lease loops (P8) (Q7) |
| hourly restart | n/a | keep | draft: simplify | draft: simplify | keep, staggered (Q5) |
| hub down | wait | n/a | local fallback | n/a | wait (Q6) |

Not folded, with the reason:

- s134-mistral and s134-agy, "4 seats per box (8)" as settled: the
  owner's words make "the Grok agents will become 4" a fleet number; kept
  as owner question Q3.
- s134-mistral, the row `payload` with the topic history and the brief:
  stale at the next post, and the issue card is the restart context (spec
  135 7.3); kept as owner question Q4.
- s134-mistral, local `O_EXCL` lock while the hub is down: 101 3.1 settled
  that no local-only job acts until the hub confirms; kept as owner
  question Q6.
- s134-agy, "migrate to the `messages` claim model (068)" as an
  alternative: it is the build that stalled (section 1); kept as owner
  question Q8.
- s134-grok, "pool seats keep the 60-minute ask lock out": done by `role =
  'od'` instead of a new table (3.1); kept as owner question Q1.

Signatures on v1.0-rc1 (replies on `dispatch-e799211c`):

| seat | signed |
|---|---|
| s134-claude | SIGN (editor, c-886) |
| s134-grok | pending |
| s134-mistral | pending |
| s134-agy | pending |

## 10. Owner questions

| Q | question | A | B | C | panel | recommendation |
|---|---|---|---|---|---|---|
| Q1 | Where do the pool rows live? | `fleet_asks` with `role = 'od'` and the new columns; the WUI calls it "OD jobs" | a new table `od_jobs`; `fleet_asks` stays the ask book | - | A: claude, mistral, agy; B: grok | **A**: the smallest working code; `role = 'od'` keeps the ask book's 60-minute lock apart |
| Q2 | How long is a lock? | fixed per kind: 5 min routing, 60 min box op | one lease, 120 s, renewed every 15 s while the seat is able | per kind, renewed: `route_post` 3, `lane_verify` 5, `spawn` 10, `box_op` 15 min | A: mistral, agy; B: claude; C: grok | **B, with C's per-kind override in cnf** (`lease_s`): a renewed lease frees a dead seat's job in minutes; a fixed 60 min lock is one waiter for an hour |
| Q3 | Where do the two Claude and two Grok seats sit? | fleet-wide, at least 2 boxes; one vendor out -> the other becomes 4 | 2 Claude + 2 Grok on every box (8, spec 068) | - | A: claude, grok; B: mistral, agy | **A**: "the Grok agents will become 4" is a fleet number; per box repeats 068 F2 |
| Q4 | Where does a job's context live? | a copy in the row (topic history, brief, repo state) | pointers: topic, issue key, source message; the seat reads the issue card | - | A: mistral; B: claude, grok | **B**: the card is already the restart context (spec 135 7.3); a copy goes stale |
| Q5 | Does the hourly session restart stay? | drop it once the inbox is not one seat's | keep spec 060 for pool seats, staggered | - | A: the draft (mistral, agy agreed with it); B: grok, claude | **B**: the transcript still grows inside one session |
| Q6 | Hub down? | the pool waits; lanes keep working; one alert after 10 min | a local `O_EXCL` lock per box for local-origin jobs | - | A: claude; B: mistral | **A**: no local-only job acts (101 3.1) |
| Q7 | How does the pool go live on prd? | one kind at a time (`lane_verify`, `spawn`, `route_post`, `box_op`), each with its own rollback, after the dev drill | one switch for everything (the draft) | - | A: grok, claude; B: mistral, agy | **A** |
| Q8 | The inert 068/093 claim code on `messages` (rdb 0110/0111/0132, `spl-peer-*`)? | keep it inert, delete at P9 | build the pool on it instead | delete it now | A: claude; B: offered by agy | **A** |

Not a question: who kills a broken seat. All four seats agreed on a box
supervisor, never a peer (section 4.2).

<!-- version: 1.0.0-rc1 · updated: 2026-10-12 · last-edit: 2026-10-12T20:10:25Z -->
