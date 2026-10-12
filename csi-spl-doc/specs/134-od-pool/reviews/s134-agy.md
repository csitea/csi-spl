signed against 18cafa8f66f58ff0ddec4ad73f3938d0aa0a4880

## 1. Section Agreements
- **1. Today**: Disagree; the draft states 068 and 101 "did not become reality". In fact, 068/093 are merged on trunk (e.g. `csi-spl-orc/src/bash/run/spl-peer-poll.func.sh`, `csi-spl-rdb/src/sql/postgres/spool-hub/0110_messages_claim.sql`) but currently inert behind the `peer/seats` switch, so the mechanism is already real.
- **2. The owner's model**: Agree; a shared table naturally avoids memory-based context buildup.
- **3. Data, Lock, and Expiry**: Disagree; the draft claims `fleet_asks` uses `acked_at` and compare-and-set for locks. However, `csi-spl-rdb/src/sql/postgres/spool-hub/0097_fleet_asks.sql:40` has no `acked_at` column, and `csi-spl-api/src/go/spool-hub-api/internal/store/fleet_ask.go:70` and `:224-225` show an ack of an ACKED row unconditionally overwrites `acked_by` without checking `state = 'open'`. We must migrate to the `messages` claim model (068) or add `acked_at` and CAS to `fleet_asks`.
- **4. Migration**: Agree; phasing out the single-lease loops simplifies the architecture.
- **5. Robust code rules**: Agree; deterministic expiry without agent judgement is required.
- **6. Build plan**: Agree; the plan aligns with the migration.

## 2. The owner's three asks
- **(a) No single failure point**: Mechanism: 4 OD workers (2 Claude, 2 Grok) per box. Any free worker can lock a row. Test: `peer-poll.tst.sh` (simulates 8 ODs on 2 boxes, locks exactly once). Control: 068 F1 where the single lease holder went silent.
- **(b) Broken peer detection and replacement**: Mechanism: The tick script releases expired locks. Since `csi-spl-orc/src/bash/run/spl-asks-tick.func.sh:83-84` currently limits the tick to the single orch holder's machine, the tick must be updated to run unconditionally from every box once the lease is gone. Test: `peer-poll.tst.sh` where a dead peer's lock expires in 125s. Control: 068 F1 (orch silent 193s).
- **(c) One kind out**: Mechanism: `not_by` array or `prd` capability routes messages away from refusing harnesses, and the free Grok seats take the locks. Test: `TestMessageClaimPoll` `not_by` routes to the next harness. Control: 068 F2 (`sat` seats froze at the claude usage limit).

## 3. The row
- **Fields & States**: As proposed, but must use a true `locked_until` or `acked_at` with compare-and-set.
- **Atomic lock**: Must be a true CAS: `UPDATE ... WHERE id = $2 AND state = 'open'`, unlike the current `fleet_asks` implementation (`fleet_ask.go:224-225`).
- **Expiry**: `do_spl_asks_tick` releases locks past `ASKS_LOCK_MIN` (or `locked_until`).

## 4. Migration
1. **Schema & API**: Fix `fleet_asks` to add `acked_at` (or use `messages.locked_until`) and enforce CAS. Add new job kinds.
2. **CLI**: Add `spool ask lock-next`.
3. **Consumers**: Update orchestrator scripts to poll via `lock-next`.
4. **Cut-over**: Disable single-lease crons and enable pool polling.

## 5. Risks
- **Flapping/Ping-pong**: Evidence: 068 F5 (`csi-spl-doc/specs/068-peer-seats/spec.md:74`) where a half-applied rank flipped the orch 203 times in 3h.
- **Static SPOFs**: Evidence: 101's rejection (`csi-spl-doc/specs/101-four-orchestrator-dispatchers/spec.md:122`): "re-creates one SPOF per box; sat idle, PC overloaded stays so".
- **Lease Takeovers**: Evidence: Today's lease takeovers average around 3-10 per day, peaking at 206 on 2026-10-03 (`grep -c "takes over" /var/spool-hub/dispatch/lease.log`), proving that the single lease is highly volatile and disrupts work.

## 6. Owner questions
- **Q1: Rename `fleet_asks` to `od_jobs`?** Recommendation: Keep `fleet_asks` in DB, alias in WUI.
- **Q2: Optimal lock duration?** Recommendation: 5 minutes for routing, 60 minutes for box ops.
