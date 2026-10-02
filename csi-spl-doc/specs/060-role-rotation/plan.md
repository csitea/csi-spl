# 060: hourly role rotation: plan

Spec: [spec.md](spec.md). Tasks: [tasks.md](tasks.md).

## 1. Two lanes, one shared library

| lane | owns | must NOT touch |
|---|---|---|
| CLE-77939, orchestrator | `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` (the shared helpers below), `spl-orch-rotate.func.sh`, `spl-rotate-status.func.sh`, `features/spawn-agents/scripts/tmux-close-window.sh` (FR-016), their tests | `spl-dispatch-*.func.sh`, `lease.conf` handling |
| CLE-77940, dispatchers | `spl-dispatch-rotate.func.sh`, the hold check in `spl_lease_agent_able` (`spl-dispatch-lease.func.sh`, FR-023/024), the `rotation` row in `spl-dispatch-check.func.sh` (FR-072), their tests | `spl-orch-rotate.func.sh`, `tmux-close-window.sh` |

The shared library (CLE-77939 lands it first, CLE-77940 sources it):

| function | does | FR |
|---|---|---|
| `spl_rotate_log RID PHASE RESULT DETAIL` | one line to `rotate.log`, plus the `.state` file | FR-002, FR-003 |
| `spl_rotate_quiesce PANE` | the grace wait, `Escape`, re-wait; prints `idle` or `busy-rotated` | FR-011 |
| `spl_rotate_handoff ROLE ID RID OUT` | section 6 of the spec | FR-012, FR-025 |
| `spl_rotate_retire PANE PID` | `/exit-clean`, 300 s, TERM, 30 s, KILL | FR-015 |
| `spl_rotate_spawn ID SEED` | rename the old window, `SPAWN_REUSE_ID=1 spawn-window.sh claude <ID>`, wait for the pid, check `ai_pane_of` | FR-006, FR-007, FR-013 |
| `spl_rotate_restore ID OLD_PANE NEW_PANE` | the failure path: kill the new session, restore the old name | FR-013, FR-014, FR-027 |
| `spl_rotate_ack_wait ID RID TIMEOUT` | wait for the `<ID>/outbox` result on task `<role>-rotate-<rid>` | FR-041 |
| `spl_rotate_alert ROLE RID PHASE REASON` | `do_spl_ask_put` blocker + an immediate owner DM | FR-075 |
| `spl_rotate_conf` | reads `rotate.conf`, the switches and the timeouts | FR-074, FR-090 |

Until the library lands, CLE-77940 writes against these names and signatures
and rebases onto it. If CLE-77940 lands first, the functions it needs go into
the shared file under these names, and CLE-77939 extends that file instead.

## 2. Order

1. spec 060 (this lane, CLE-77941).
2. shared library + tests (CLE-77939).
3. orchestrator rotation + `tmux-close-window.sh` retiring rule + status
   action (CLE-77939). DRY_RUN live (L1).
4. hold in `spl_lease_agent_able` + dispatcher rotation + check row
   (CLE-77940). DRY_RUN live (L1).
5. cron installers. Install on the home box `DRY_RUN=0` only after L2 and
   L3 have passed by hand.
6. live proofs L2..L5. Report to `CLE-001` with the `rid`s.
7. the owner applies the FR-061 flag line (FR-062). Until then the fallback
   applies.

## 3. Risks

| risk | guard |
|---|---|
| `/exit-clean` from the retiring window closes the NEW window (`--agent` resolves by window name) | FR-016 + T-EXITCLEAN-RETIRING; CLOSE closes by pane id |
| the identity map still points at the old pid after a spawn, so pokes reach the retiring session | FR-006: the rotation checks `ai_pane_of` before ACK |
| `Escape` in QUIESCE stops a half-done tool call (a push, a prd write) | the handoff's section 2 shows the stopped screen. Every csi-spl action is re-runnable, and git landing is verified by `merge-base --is-ancestor`, never by output. Accepted by the owner (D1) |
| the new session on the same login hits the usage limit | FR-009 skips a stalled pane; a stall that starts after SPAWN is a missing ack, so the old session is kept (D2) |
| a hold left behind by a crash pins F as the acting dispatcher | FR-024: the hold ages out after 1800 s, with a WARN |

<!-- last-edit: 2026-10-02T04:40:00Z — CLE-77941 -->
