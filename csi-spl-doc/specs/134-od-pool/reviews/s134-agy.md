signed against 18cafa8f66f58ff0ddec4ad73f3938d0aa0a4880

## 1. Section Agreements
- **1. Today**: Agree; accurately summarizes the single-lease bottlenecks and the earlier attempts (068, 101).
- **2. The owner's model**: Agree; a shared table naturally avoids memory-based context buildup.
- **3. Data, Lock, and Expiry**: Agree; reusing `fleet_asks` is efficient and builds on proven atomic locking.
- **4. Migration**: Agree; phasing out the lease loops simplifies the architecture significantly.
- **5. Robust code rules**: Agree; deterministic expiry without agent judgement prevents hung states.
- **6. Build plan**: Agree; the steps are logical, shippable individually, and cover the necessary components.

## 2. The owner's three asks
- **(a) No single failure point**: The pool meets this by having 4 stateless OD workers (2 Claude, 2 Grok) per box. Any free worker can lock and process a row, meaning the work is distributed naturally without a central coordinator.
- **(b) Broken peer detection and replacement**: A broken peer stops renewing its locks. `do_spl_asks_tick` deterministically checks `NOW() - acked_at > ASKS_LOCK_MIN` and releases the lock back to `open`, allowing another peer to take it. The watchdog or peer-ensure cron handles replacing the dead session.
- **(c) One kind out**: If all Claude agents hit a usage limit, they stall and stop taking locks. The Grok agents, still polling, will naturally lock and process all new and expired rows, effectively taking over all available work until Claude recovers.

## 3. The row
- **Fields**: The row uses `fleet_asks` fields: `id`, `kind` (`route_post`, `lane_verify`, `box_op`), `state` (`open`, `acked`, `done`), `acked_by` (`<id>@<box>`), `acked_at`, and `raised_n`.
- **States**: `open` (available), `acked` (locked by a peer), `done` (completed).
- **Atomic lock**: `UPDATE fleet_asks SET state = 'acked', acked_by = $1, acked_at = NOW() WHERE id = $2 AND state = 'open'`.
- **Expiry**: `do_spl_asks_tick` releases locks where `NOW() - acked_at > ASKS_LOCK_MIN`.
- **Conversion to rows**: Owner posts, spawn requests, and lane closes are inserted as rows into `fleet_asks` instead of relying on in-memory or single-lease queues.

## 4. Migration
1. **Schema & API**: Add new job kinds to `fleet_asks` and WUI endpoints (rollback: ignore new kinds).
2. **CLI**: Add `spool ask lock-next` (rollback: simply do not use the new verb).
3. **Consumers**: Update orchestrator inbox scripts to poll via `lock-next` instead of monolithic reads (rollback: revert to old `do_spl_orch_inbox`).
4. **Cut-over**: Disable single-lease crons and enable pool polling (rollback: restore single-lease crons).

## 5. Risks
- **Flapping/Ping-pong**: Seen in 068 F5 where a half-applied rank flipped the orchestrator 203 times in 3h. The OD pool avoids this by removing ranks entirely.
- **Static SPOFs**: Spec 101 rejected static partitioning ("re-creates one SPOF per box"). The OD pool's dynamic row-locking solves this.
- **Mass Freezes**: Today's lease F2 incident showed all seats freezing due to a shared limit. Using mixed harnesses (Claude/Grok) mitigates this risk.

## 6. Owner questions
- **Q1: Rename `fleet_asks` to `od_jobs`?** Recommendation: Keep `fleet_asks` in DB, alias in WUI. Avoids a massive, risky database migration while satisfying the UX need.
- **Q2: Optimal lock duration?** Recommendation: 5 minutes for routing, 60 minutes for box ops. Routing is quick and should fail over fast if stalled; box ops are inherently long-running.
