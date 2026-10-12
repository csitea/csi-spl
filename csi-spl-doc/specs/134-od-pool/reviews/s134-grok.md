signed against 18cafa8f66f58ff0ddec4ad73f3938d0aa0a4880

# s134-grok: review of spec 134 (draft)

Seat g-887. The draft is `csi-spl-doc/specs/134-od-pool/spec.md` on that sha. Code citations are that tree.

## 1. Agree / disagree

One line per draft section.

1. **Today.** Disagree: the picture of one lease, a 60 s tick and a 180 s failover is right, and three of its citations are the wrong lines. `do_spl_dispatch_lease` line 89 is the `fleet` verb, the period is `LEASE_PERIOD` default 60 at line 102, and `LEASE_PRIORITY_ORCH` is applied in `spl_fleet_rank` at lines 1041-1046. The draft's line 512 sits inside `spl_lease_limit_until`, which starts at line 510 (the usage-limit reset parser). Stale is age greater than 180 s: `dispatch-lease.tst.sh` case 4 (line 120) says 180 s exactly does not promote. Fleet mode stores `<ID>@<box> <epoch>` (`spl-dispatch-lease.func.sh` lines 33-34); the bare `<holder> <epoch>` line is the local lease (`SPEC-spool-fleet-roles.md` line 277).
2. **The owner's model.** Disagree: one row per job, locked by any free seat, with the context off the seat's transcript, is the right shape, and the draft never says how the three owner asks are met (two Claude and two Grok, a dead peer killed and replaced, one vendor out so the other becomes four).
3.1 **Reuse `fleet_asks`.** Disagree: keep the ask book as the ask book. Its kind check is `blocker|task|escalation` (`0097_fleet_asks.sql` line 44, `fleet_ask.go` line 190), its states include `queued` and `dead` (`0180_fleet_asks_queue.sql` lines 30-32), and an ack of an already-acked row steals the holder (`applyAskOp`, `fleet_ask.go` lines 224-225). A pool row is a different record.
3.2 **New kinds on `fleet_asks`.** Disagree: `route_post`, `lane_verify` and `box_op` belong on a new table `od_jobs`. Widening the ask-book check couples the pool to the 60-minute ask lock.
3.3 **The lock and the expiry.** Disagree: the statement in the draft is not what the hub runs. `UpdateFleetAsk` (`fleet_ask_postgres.go` lines 70-86) does `SELECT ... FOR UPDATE` and then `UPDATE` by primary key, with no `AND state = 'open'`. There is no `acked_at` column (`0097_fleet_asks.sql` lines 39-59). Quiet time is `now - updated_at` (`fleet_ask.go` lines 169-176). The release runs only on the machine that holds the orch role (`spl-asks-tick.func.sh` lines 78-86); with no holder the tick returns at line 80 and releases nothing. `ASKS_LOCK_MIN` defaults to 60 minutes (line 52).
3.4 **CLI and WUI.** Agree that the worker's only lock call is "give me one free row", and the WUI list waits until that call is real. `do_spl_od_pool_tick` does not replace the lease by itself: a supervisor has to keep the seats alive.
4. **Migration.** Disagree: retiring the lease in step 1 removes the only actor before a pool exists. The hourly restart stays. Each kind cuts over on its own flag, with the lease holder still doing the kinds that are off.
5. **Robust code rules.** Agree: the database decides the lock, the tests carry a negative control, and the agent does not choose whether a row is free. Add one rule: "able" is `spl_lease_agent_able` (a live pid on a usage-limit banner is not able), and the process that kills and spawns is a script.
6. **Build plan.** Disagree: the order below puts the table, the compare-and-set, and the supervisor first, and turns the lease off last. The WUI list is not on that path.
7. **Draft owner questions.** Q1: a new table, recorded below as Q1. Q2: short per-kind leases with a heartbeat renew, recorded as Q2. Sixty minutes on a box op is a single waiter for that op.

## 2. The owner's three asks

The owner's words (t1 `e799211c`, 2026-10-11): at least two Grok and two Claude doing the work; a peer that is not functioning is detected, killed and replaced; if the Claude seats hit a limit, the Grok seats become four and take the work, and the reverse.

### 2.1 No single failure point

Steady target, one hub row `od_pool_target` per tenant and fleet: `claude_n = 2`, `grok_n = 2`, `min_boxes = 2`. Any able seat of either vendor calls `lock-next` and may take any free row. The lease holders `c-001`, `c-002` and `c-003` are not the pool. Pool seats are new ids, so a lease failover is not what moves the work.

The lock is one statement. A second caller gets zero rows:

```sql
UPDATE od_jobs
   SET state = 'acked', acked_by = $seat, acked_at = now(),
       session_gen = $gen, updated_at = now()
 WHERE job_id = (
   SELECT job_id FROM od_jobs
    WHERE tenant_id = $tenant AND fleet = $fleet AND state = 'open'
      AND (vendor_allow = '' OR vendor_allow = $vendor)
    ORDER BY created_at, job_id
    FOR UPDATE SKIP LOCKED
    LIMIT 1)
RETURNING *;
```

Renew, by the holding session only, every supervisor period while the seat is able:

```sql
UPDATE od_jobs SET acked_at = now(), updated_at = now()
 WHERE job_id = $id AND state = 'acked'
   AND acked_by = $seat AND session_gen = $gen;
```

Zero rows means the lock was lost. The seat stops.

Expiry is the same statement from any box, not from the orch holder:

```sql
UPDATE od_jobs
   SET state = 'open', raised_n = raised_n + 1, updated_at = now()
 WHERE state = 'acked'
   AND acked_at < now() - make_interval(secs => lease_s);
```

`raised_n` counts lost locks. At 4 the row goes `dead` and one note goes to the dispatch holder. The owner is told only when no able pool seat remains (the same bar as `ASKS_ALERT` today).

A degraded box (hub beats, `spl-dispatch-lease.func.sh` lines 1049-1058, the 2026-10-11 uplink) is not given new seats and its seats are not offered new rows. An existing lock keeps renewing until the seat finishes or the lease expires. Beats alone do not kill a session.

**Test (a).** Store test, n >= 20 races, 4 seats, 1 open row: exactly one `acked`. Control: 2 rows, 2 seats, both `acked`. Then SIGKILL the holder. The supervisor releases that `acked_by`. A seat of the other vendor locks the same `dedupe_key` and closes it: exactly one `done`. The fixture runs the release from a box that does not hold the orch role.

### 2.2 A broken peer is detected, killed and replaced

`do_spl_od_pool_supervise` runs every 30 s on every box. It kills and spawns only seats whose home box is this one. Able means `spl_lease_agent_able`: the pid is live and `spl_lease_stall` printed nothing (`spl_lease_stall` at line 468, `spl_lease_agent_able` at line 593). The stall regex is `LEASE_STALL_RE` (line 310): usage limit, `/login`, invalid key.

- First failed able check: the seat is not offered. `lock-next` will not hand it a row. Its current row stays until release.
- Second consecutive failed check (~60 s): kill. The sequence is the rotation's retire (`spl-orch-rotate.func.sh` lines 16-19): ask the session to exit, wait `ROTATE_TERM_WAIT` (default 30 s), then KILL.
- Pid gone: one hub call releases every row with that `acked_by` and `session_gen`.
- Spawn one replacement of the same vendor so the target count holds. The new session's `session_gen` is the old gen plus one. Renew with the old gen affects zero rows (spec 101 D13: two sessions of one seat must not both pass).

A seat with a fresh heartbeat and a clear pane is left alone, including one inside a tool call.

**Test (b).** Plant the usage-limit banner on one Grok seat. Repeat the fixture n >= 10. Within two ticks that pid is gone and a new Grok pid of the same target exists. `od_pool_target` stays 2 and 2. Control: a seat with a fresh heartbeat and no banner keeps its pid.

### 2.3 One vendor out, the other takes every seat

A vendor is out when every seat of that vendor has failed the able check for two ticks, and at least one failure is a `LEASE_STALL_RE` banner (the weekly limit, or a login wall). One seat down and its partner still able is section 2.2: replace the one, leave the target at 2 and 2.

On vendor-out, one update of `od_pool_target`, taken under the `fleet-config` mutex (spec 068, the mutex that exists so a rank change cannot land on one machine): the out vendor's `n` becomes 0, the other becomes 4, `until` is `spl_lease_limit_until` of the banner (`spl_lease_limit_until`, `spl-dispatch-lease.func.sh` lines 510-531) or empty when the banner has no reset time. Seats of the out vendor are killed and not respawned. The other vendor is spawned up to 4, spread so `min_boxes` holds when a second box can run that vendor. When it cannot, the supervisor sends one note to the dispatch holder and the target stays what was spawned.

Back to 2 and 2 when `until` is in the past, or when a process of the out vendor is able again. Extra seats are not offered new rows. Each is retired when it holds zero rows, so a seat inside a job finishes that job.

This is fleet-wide, not two of each per box. Spec 068 F2 (line 71): one login froze every seat on that box, and the re-raise (F3, line 72) kept delivering to the frozen holder.

**Test (c).** Both Claude seats show `usage limit` with a reset in the future. After two ticks `claude_n = 0`, `grok_n = 4`, and a new `route_post` is `acked_by` a Grok seat. Advance the clock past `until`: the target returns to 2 and 2, a Grok seat that holds a row is still alive, a Grok seat that holds none is gone. Control: one Claude able and one stalled leaves the target at 2 and 2 and replaces only the stalled pid.

## 3. The row

New table `od_jobs`. The ask book stays `fleet_asks`. The tick pattern (release on quiet, dead-letter on a delivery count, idempotent put) is what the new table copies.

### 3.1 Fields

The row is the job. The history stays on the hub topic, and the restart card stays on the issue (spec 135 section 7). The worker reads both at lock time. `summary` on the ask book is already capped at 500 bytes (`0097_fleet_asks.sql` line 47); a copied transcript would be stale at the next post.

| field | what it holds |
|---|---|
| `tenant_id`, `fleet`, `job_id` | identity. `job_id` is a uuid. |
| `kind` | `route_post`, `spawn`, `lane_verify`, `box_op` |
| `dedupe_key` | partial unique index on `(tenant_id, fleet, kind, dedupe_key)` WHERE state IN (`open`, `acked`, `needs_owner`). A second open insert of the same job conflicts. A closed row does not block the next one. |
| `topic` | the task id. `spool tail` is the history. |
| `source_msg` | the human or lane message that opened it |
| `issue_key` | empty until the issue exists. A `route_post` files it first (spec 135: the issue is the context). |
| `acceptance` | one line, at most 500 bytes: what `done` means |
| `repo_sha`, `scope`, `must_not` | the tree the job was opened against, and the paths |
| `vendor_allow` | empty, `claude`, or `grok`. Empty means either. |
| `summary` | at most 500 bytes: the owner's line, or the command |
| `state` | `open`, `acked`, `needs_owner`, `done`, `declined`, `dead` |
| `acked_by`, `acked_at`, `lease_s`, `session_gen` | the lock. Renew moves `acked_at`. |
| `raised_n`, `reason`, `closed_by` | lost locks, and the close |
| `created_at`, `updated_at` | order and audit |

`needs_owner` is not lockable. It is spec 135 Q2: the row waits for a human answer, and no seat retries it.

### 3.2 States

`open` to `acked` is `lock-next` or a renew. `acked` to `open` is expiry or a release after a kill, and `raised_n` grows by one. `acked` to `done` or `declined` is the holder, with `session_gen` matched. `open` or `acked` to `dead` is `raised_n >= 4`. `open` or `acked` to `needs_owner` is a prd mutation the safety check refuses, or a job whose acceptance says a human decides. A human answer moves `needs_owner` to `open` (try again) or `declined`.

### 3.3 What inserts each job

Code inserts. A seat never notices a post by reading its pane. That is the missed doorbell in spec 101 (section 1, E4).

- **Owner post.** The hub transaction that stores a human message inserts `route_post` when that topic has no open `route_post`. `dedupe_key` is that message's id. A relay of the same hub row inserts nothing. Two messages for one ask are spec 101's F1 (section 3.2, line 155); the unique key is what closes it here.
- **Spawn.** `od enqueue` with `kind = spawn` and `dedupe_key = <topic>:<slug>` (spec 101 D5). The caller is the seat that closed a `route_post`, or a lane. The spawn launcher takes the existing `spawn` mutex and refuses a second lane for that key. Today's queued asks (`0180_fleet_asks_queue.sql`, `placement` is `<vendor>:<slug>`) are copied into `spawn` rows at the cut-over of this kind, one row per queued ask.
- **ACCEPTED and lane close.** One kind, `lane_verify`, `dedupe_key` = the issue key. Inserted when a result body starts with `ACCEPTED`, and by the lane exit hook when the session ends without one. The holder checks the landed sha, the issue state, and that the worktree is gone, then tells the dispatch holder. Seats do not post in the owner topic.
- **Box op.** Inserted by the ingest of an owner-signed directive, or by a named action that already exists. `summary` is the exact command. A seat does not invent a box op. A prd mutation the safety check refuses becomes `needs_owner` with that command in `summary`, and no seat runs it.

The unanswered sweep stays (`spl-unanswered-sweep.func.sh`). Today it sends one note to the lease holder (lines 37-38), which is the single waiter spec 101 r3 kept the sweep to watch. After ingest is on, the sweep inserts a `route_post` for a human post the ingest missed, and it keeps listing. It is the check that does not trust the pool.

## 4. Migration

Each step ships alone. The lease loops stay through M6.

| step | ships | rollback |
|---|---|---|
| M1 | `od_jobs` and `od_pool_target`. No reader. | Leave the tables. Nothing calls them. |
| M2 | Hub ops `lock-next`, `renew`, `release`, `enqueue`, with the store tests in section 2. | Stop exposing the ops. `fleet_asks` is untouched. |
| M3 | Human-message ingest inserts `route_post`, flag `OD_POOL_INGEST`, default off. | Flag off. Open rows are declined by one admin op. |
| M4 | Supervisor on, flag `OD_POOL_SUPERVISE`. It keeps 2 and 2 alive. `OD_POOL_KINDS` empty, so `lock-next` is not called. | Flag off. The supervisor kills the seats it spawned. |
| M5 | One kind per push, in order `lane_verify`, `spawn`, `route_post`, `box_op`. `OD_POOL_KINDS` names the kinds the pool consumes. The lease holder skips those kinds. Spawn's step copies the `queued` asks across. | Remove the kind from the flag. The holder does that kind again. In-flight locks release on `lease_s` and come back to `open`. |
| M6 | The sweep inserts a `route_post` for a miss, and still lists. | Sweep recipient returns to the lease holder. |
| M7 | After a soak the owner names, the lease loops stop doing OD work. Pool seats keep the hourly restart (spec 060): staggered, handoff is "renew your `acked` rows under the new `session_gen`". `lease.conf` stays for anything left outside the pool. | `LEASE_CMD=ensure` again, `OD_POOL_KINDS` empty. |

M7 is the first step that turns a loop off. The draft's step 1 does that first, and its step 3 drops the hourly restart because the inbox is no longer one seat's. The restart exists because a session's transcript grows (spec 060, and the owner's reason the 2026-10-11 seat design did not hold). A short row does not keep a long session small.

## 5. Risks

- **068 F5** (`specs/068-peer-seats/spec.md` line 74). A rank line applied on one machine flipped the single orchestrator 203 times in about 3 h. The pool target is one hub row, written under the `fleet-config` mutex. A `lease.conf` on one box cannot move it.
- **068 F2 and F3** (lines 71-72). One vendor login froze every seat on the box, and the ask tick kept re-raising to that holder. Section 2.3 treats the vendor as the unit, and a stalled seat is not offered.
- **068 F4** (line 73). The rotation gate said stalled and the lease loop still handed the role to that seat, 48 times in one hour. The pool uses `spl_lease_agent_able` for both "offer" and "kill", so the two judges are one function.
- **Spec 101 section 3.1** (lines 120-125). Static partition per box, and per tenant, was rejected: one SPOF per box, and a reassignment is the lease problem again. The draft's "any free seat locks one row" matches 101's option (d), claim per job. 101 did not go live because the seats switch was never turned on (`spec.md` section 1.3: no `seats` file, peer crons not installed) and because the claim that is built is per message, not per ask, topic or lane (section 3.2). The draft's sentence that 101 failed for lack of shared context is one of those gaps (r3: a follow-up reaches a new owner with nothing to read), not the whole reason.
- **The ack steals.** `applyAskOp` AskAck overwrites `acked_by` on any open row, and `acked` is open (`fleet_ask.go` lines 63 and 224-225). Two pool seats must not be able to do that. Section 2.1's `WHERE state = 'open'` plus `SKIP LOCKED` is the fix, on the new table.
- **Expiry has a single runner.** `spl-asks-tick.func.sh` lines 78-86 return when this machine is not the orch holder. A pool release that kept that gate would bring the single runner back. Section 2.1's release has no holder check. Test (a) runs it from the other box.
- **Two sessions, one gen.** Spec 101 D13: the restart spawns the new session before the old one is gone, for up to 330 s. `session_gen` bumps before the new session starts. The old session's renew matches zero rows.
- **Two orchestrators already.** Spec 101 E10: one box's `c-001` spawned 20 lanes while the lease named the other box. Pool spawns take the `spawn` mutex and the `topic:slug` key before the launcher runs.
- **2026-10-11 uplink.** `spl-dispatch-lease.func.sh` lines 1049-1058: beats degraded for 3.5 h and dispatch was moved by hand. A degraded box gets no new pool seats. Kill stays tied to the stall banner and a dead pid, not to one bad beat window (the lease's own hold-down is 30 min for that reason).
- **Queued asks stranded.** `0180` already queues spawn requests in `fleet_asks`. Cutting spawn over without copying those rows drops the line the owner asked for on 2026-10-11 (the migration comment in that file). M5's spawn step copies them.

## 6. Owner questions

| Q | A | B | C | recommendation |
|---|---|---|---|---|
| **Q1.** Rename `fleet_asks` to `od_jobs`, or keep the table and alias it in the WUI? | Keep the table name. Alias it "OD Jobs" in the WUI. | New table `od_jobs`. `fleet_asks` stays the ask book. | | **B.** The ask book is a different lock (60 min, orch holder releases, kinds `blocker\|task\|escalation`). An alias hides that. |
| **Q2.** How long is a lock? | 5 min for a route, 60 min for a box op. | One lease, 10 min, for every kind. | Per kind, renewed by the heartbeat: `route_post` 3 min, `lane_verify` 5 min, `spawn` 10 min, `box_op` 15 min. A killed seat's rows release in the same action as the kill. | **C.** A 60 min box op is one waiter for an hour (068 F1 waited on 180 s and that was already the complaint). A long op renews. |
| **Q3.** Who kills a broken seat and spawns the next? | A peer OD decides. | `do_spl_od_pool_supervise`, every 30 s, using `spl_lease_agent_able`. | | **B.** The owner's rule for this design is more code and less judgement. Two seats deciding "able" is 068 F4. |
| **Q4.** Where do the two and two sit? | Fleet-wide, `min_boxes = 2`. On a vendor-wide limit the other vendor's target becomes 4, then returns to 2. | Two Claude and two Grok on every box (068 section 1.3). | | **A.** Per box repeats F2: one login takes every seat on that box. The 2026-10-11 words say the other kind becomes four, which is a fleet target. |
| **Q5.** Where does the context live? | Copy the topic, the brief and the repo state into the row. | The row holds pointers: topic, issue key, repo sha, scope, acceptance. The worker reads the hub topic and the issue card (spec 135 section 7). | | **B.** The issue card is already the restart context. A copy in the row goes stale when the next post lands. |
| **Q6.** Does the hourly restart stay? | Drop it once the inbox is not one seat's. | Keep spec 060 for pool seats, staggered. The handoff is the seat's `acked` rows and the new `session_gen`. | | **B.** The transcript still grows inside one session. The row keeps the job small. The session still needs a restart. |
