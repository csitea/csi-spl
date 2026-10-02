# 060: hourly role rotation: tasks

Spec: [spec.md](spec.md). Plan: [plan.md](plan.md).
The owner wants this built autonomously (CLE-001, 2026-10-02 ~04:30Z): the
lanes ask nothing more unless they are blocked.

## 1. Specification (CLE-77941)

- [x] T001 Spec, plan, tasks; owner requirements R1-R6 and decisions D1-D4 mapped to FRs
- [x] T002 Design notes from CLE-77939 and CLE-77940 folded in (no id swap, hold, outbox ack)

## 2. Shared library (CLE-77939)

- [x] T010 `spl-rotate-lib.func.sh`: `spl_rotate_log`, `spl_rotate_conf` (FR-002..FR-005, FR-074, FR-090) + test
- [x] T011 `spl_rotate_quiesce` (FR-011) + test with a busy stub pane (T-ORCH-BUSY)
- [x] T012 `spl_rotate_handoff`, all 9 sections, `UNAVAILABLE` per failing source (spec 6) + test
- [x] T013 `spl_rotate_spawn`, `spl_rotate_restore` (FR-006, FR-007, FR-013) + T-ORCH-POKE-ROUTE
- [x] T014 `spl_rotate_retire` (FR-015) + T-ORCH-EXIT-HANG
- [x] T015 `spl_rotate_ack_wait` + the `ROTATE_CMD=ack` sender (FR-041) + T-ACK-FORGED
- [x] T016 `spl_rotate_alert` (FR-075): an ask + an immediate owner DM

## 3. Orchestrator (CLE-77939)

- [x] T020 `do_spl_orch_rotate`: gates, QUIESCE, HANDOFF, SPAWN, ACK, RETIRE, CLOSE, DONE (FR-010..FR-019) + T-ORCH-HAPPY, T-ORCH-GATES, T-ORCH-ACK-TIMEOUT, T-ORCH-SPAWN-FAIL, T-ORCH-RESUME
- [x] T021 `tmux-close-window.sh`: a caller in a retiring window closes its own window (FR-016) + T-EXITCLEAN-RETIRING
- [x] T022 `do_spl_rotate_status` (FR-063, FR-071)
- [x] T023 `do_spl_orch_rotate_install_cron` at `5 * * * *` (FR-050) + T-CRON
- [x] T024 `ROTATE_CMD=abort` (FR-091)
- [ ] T025 Live L1 (DRY_RUN) and L2 (one real rotation of `CLE-001`), then install the cron
- [ ] T026 Send `CLE-001` the FR-061 one-line flag diff (FR-062)

## 4. Dispatchers (CLE-77940)

- [ ] T030 The hold in `spl_lease_agent_able` (renew, watch, fleet candidate) and its ageing out (FR-023, FR-024) + T-DISP-HOLD-STALE
- [ ] T031 `do_spl_dispatch_rotate`: PRECHECK, HEAL, HOLD, QUIESCE, HANDOFF, SPAWN-M, ACK-M, RETIRE, RELEASE, REFRESH-F, DONE (FR-020..FR-031) + T-DISP-HAPPY, T-DISP-HEAL, T-DISP-ACK-FAIL, T-DISP-ACK-SOURCE, T-DISP-ONE-HOLDER
- [ ] T032 Sequencing behind an orch rotation (FR-020, FR-051) + T-SEQ
- [ ] T033 The `rotation` row in `do_spl_dispatch_check` (FR-072)
- [ ] T034 `do_spl_dispatch_rotate_install_cron` at `15 * * * *` (FR-050) + T-CRON
- [ ] T035 Live L1 and L3 (one real rotation of `CLE-002`, then refresh `CLE-003`), then install the cron

## 5. Both lanes

- [ ] T040 T-MSG-IN-FLIGHT, T-TWO-MACHINES, T-NO-MODEL
- [ ] T041 SPEC-spool-fleet-roles.md: a short section pointing to this spec (no restatement)
- [ ] T042 L4 (three cron hours) and L5 (`ROTATE=0`), reported to `CLE-001`
- [ ] T043 Owner: apply the FR-061 flag line, or allow it for one lane (FR-062)

<!-- last-edit: 2026-10-02T04:40:00Z — CLE-77941 -->
