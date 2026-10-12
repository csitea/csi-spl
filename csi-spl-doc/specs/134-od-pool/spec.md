# 134: OD pool (orchestrators and dispatchers)

Status: **Draft** (2026-10-12)

## 1. Today: how roles work now

Today, the fleet relies on single-lease roles across machines, measured and managed by code:
- **One lease per role**: `do_spl_dispatch_lease` (fleet mode) runs every minute (`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh:89`). The lease is one line (`<holder> <epoch>`) in `$SPOOL_ROOT/dispatch/lease` (or `lease.orch`). Only the holder of the lease dispatches.
- **Ranked boxes**: `LEASE_PRIORITY_ORCH` and `LEASE_PRIORITY_DISPATCH` (`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh:512`, `csi-spl-orc/src/bash/tests/spl-lease-rank.tst.sh`) rank the boxes. The lease watcher fails over if the holder stalls for 180s.
- **Hourly role rotations**: `do_spl_orch_rotate` and `do_spl_dispatch_rotate` (`csi-spl-orc/src/bash/run/spl-orch-rotate.func.sh` and `spl-dispatch-rotate.func.sh`) replace the session every hour under the same id, mitigating context buildup.
- **The asks book**: Asks to the orchestrator are tracked in `fleet_asks` (`csi-spl-api/internal/store/ask.go`, `csi-spl-orc/src/bash/run/spl-asks.func.sh`). They are fire-and-forget, driven by `do_spl_asks_tick` (`csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`), which locks them (`ack`) and re-raises them if the lock expires (`ASKS_LOCK_MIN`).

**The 3 earlier attempts** at multi-orchestrator/HA did not become reality:
1. **068 peer seats ("four per box, each dispatches and orchestrates")**: Did not advance beyond a draft. As cited in spec 101 section 3.1, the partition mechanism caused issues (068's F5: "a half-applied rank flipped the orch 203 times in 3 h"), and it lacked a reliable common lock mechanism across all the seats.
2. **101 four orchestrator dispatchers**: Explored static partitioning per box and claim per message. Static partitioning was rejected ("no: re-creates one SPOF per box; sat idle, PC overloaded stays so", spec 101 3.1). The two-phase hub claim was recommended but ultimately didn't stick because of the lack of shared contextual state.
3. **The leader-seats HA spec of 2026-10-11** (referenced in the vendor load balancing blog post, 2026-10-11): Proposed a flexible arrangement of Claude and Grok seats. It never became reality because, as the owner identified, context buildup inside the individual seat's memory makes sharing routing logic complex without a shared topic state ("the reason is probably the context").

## 2. The owner's model: OD pool

The owner's principle: "more working and robust code and less intelligence with this priniciple in mind".

Every OD job—an owner post to route, a spawn request, an `ACCEPTED` to verify, a lane to close, a box op—is **ONE row/topic in a shared table**, similar to the Flow. 

There are N free OD seats (orchestrator or dispatcher, on any box). Any free OD seat:
1. Locks one row atomically (compare-and-set with a lease time).
2. Works it.
3. Closes it.

If the holder goes silent, the lock expires and another free OD takes it. **Context is the row, not the seat's memory**: each row carries everything needed to act (the topic history, the brief, the repo state).

## 3. Data, Lock, and Expiry

### 3.1 Reusing `fleet_asks` (rdb 0097)
We will expand the existing `fleet_asks` table rather than creating a new one, as it already implements the exact locking and expiration mechanism needed. 
**Reasons**:
- `fleet_asks` already tracks jobs with states (`open`, `acked`, `done`, `declined`).
- It has atomic locks (`acked_by`), lock timeouts via `do_spl_asks_tick` (`ASKS_LOCK_MIN`), and delivery counters (`raised_n`).
- The `spool ask` CLI verbs already exist and interact with it.

### 3.2 Schema Additions (Migration)
We will add new job `kind`s to `fleet_asks` (currently it holds `blocker`, `task`, `escalation`):
- `route_post`: An owner post to route.
- `lane_verify`: Verify an `ACCEPTED` or closed lane.
- `box_op`: A generic box operation.

### 3.3 Atomic Lock and Expiry
The lock is an atomic `UPDATE fleet_asks SET state = 'acked', acked_by = $1, acked_at = NOW() WHERE id = $2 AND state = 'open'` (compare-and-set).
Expiry is driven deterministically by code (`do_spl_asks_tick`). If `NOW() - acked_at > ASKS_LOCK_MIN`, the tick releases it back to `open`. No agent judgement is involved.

### 3.4 CLI Verbs and WUI
- **CLI**: `spool ask lock <id>`, `spool ask done <id>`, `spool ask list --free`.
- **Orc Actions**: `do_spl_od_pool_tick` (to poll for free jobs and lock one), replacing the monolithic `do_spl_orch_inbox` and `do_spl_take`.
- **WUI**: The OD pool will be displayed in a Flow-like list named "OD Jobs", showing open, locked, and recently closed tasks, filtered by `tenant_scope` (RLS).

## 4. Migration from single lease

1. The single-lease loops (`do_spl_dispatch_lease LEASE_CMD=fleet`) are retired. `lease.conf` priorities are ignored for OD roles.
2. The orchestrator (`c-001`) and dispatchers (`c-002`, `c-003`) on all boxes become stateless workers polling the shared table.
3. Leases are removed. The hourly rotation (`spl-orch-rotate`) is simplified to just restart the stateless worker, as there is no longer a need to hand off the monolithic inbox.

## 5. Robust code rules

1. **Deterministic lock/expiry in code**: The agent never decides if a job is locked. The database constraint and the tick script enforce it.
2. **Tests with red controls**: Every lock transition and expiry will be covered by hermetic bash tests with negative controls.
3. **No agent judgement in the locking path**: The agent simply asks `spool ask lock-next`, and if it gets a row, it acts.

## 6. Build plan (lanes)

1. **Store/Hub**: Add new job kinds to `fleet_asks`, WUI endpoints for the "OD Jobs" list.
2. **CLI**: Add `spool ask lock-next` and enhance `spool ask list`.
3. **Orc Actions**: Rewrite `do_spl_take` and `do_spl_orch_inbox` to consume from the pool.
4. **WUI**: Build the OD Jobs list view.
5. **Cut-over**: Disable single-lease cron, enable pool polling cron.

### Owner Questions
1. **Q: Should we rename `fleet_asks` to `od_jobs`?**
   *Proposal*: Keep `fleet_asks` in the database to avoid a massive migration, but alias it as `OD Jobs` in the WUI.
2. **Q: What is the optimal lock duration for a routing job vs a box op?**
   *Proposal*: 5 minutes for routing, 60 minutes for box ops.
