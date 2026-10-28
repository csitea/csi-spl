# Orchestration panel: mistral seat review

Status: **v0.1, mistral review**
Epic SPL-1308, issue SPL-3935, spec home [101](../../../specs/101-four-orchestrator-dispatchers/spec.md) and [134](../../../specs/134-od-pool/spec.md).
Panel task `dispatch-orch-grok-again`.
Read on tree `8f1eca452` (origin/master at the editor's start).

## 1. Scope

- Review the editor's v0.1 plan (`orch-panel-plan.md`) as an expert.
- Re-measure ≥4 facts or root causes.
- Agree, change, or reject per row, with evidence.
- No mistral coding rows.
- Sign v1.0 when the editor asks.

## 2. Re-measured facts

| fact | command | reading |
|---|---|---|
| F6 seat dirs are links | `readlink /var/spool-hub/{a,g,m,q}-001` | `a-001 -> c-001`, `g-001 -> c-001`, `m-001 -> c-001`, `q-001 -> c-001`, `c-002 -> g-002` |
| F8 queue stands still | `cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && ./run -a do_spl_spawn_queue` | `57 queued, 0 placing`; 35 rows `WAIT ... its brief <slug>.md is not under .../dispatch/briefs on <PC>: it was queued on sat` |
| F8 why | `sed -n 143p csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` | `the orch role is held on <box>: its machine places` |
| F9 load flipped | `uptime` on PC and sat | PC: 21 / 16 / 10 on 16 cpus; sat: 74 / 83 / 89 on 16 cpus |
| F11 bare pane | `grep -ah 'HIT S3' /opt/csi/csi-spl-desk-cron/csi-spl-orc/wd.log.1 /opt/csi/csi-spl-desk-cron/csi-spl-orc/wd.log \| grep 'runs only'` | 18 hits, 10-26..27 (11 takeovers on 10-27) |
| F4 restore skip | `sed -n 171,181p csi-spl-orc/src/bash/run/spl-agent-identity-restore.func.sh` + live panes | The restore skips a window whose pane pid is not a plain shell; a dead seat's pane pid is still `sh -c env ... spawn-claude.sh <id> ...` |
| F6 heartbeat | `sed -n 591,598p /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent-hook.sh` | The hook writes `<spool root>/<AGENT_ID>/heartbeat.json`; through a link, two sessions write one file |
| Relay (B4) | `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh --from m-125 --to c-002@sat --kind note --task dispatch-orch-grok-again --body "Test relay logging"` + `grep -r "rc.*failed" /var/spool-hub/dispatch/ --include="*.log"` | The relay log (`/var/spool-hub/dispatch/relay.log`) does not exist; the test message was sent, but no failure cause was logged |

## 3. Verdicts per row

| row | verdict | evidence |
|---|---|---|
| **B1** | Agree | The restore must treat a window as live only if a harness process carries the id. A dead seat's window must get `respawn-pane -k` in place. Red control: pane pid cmdline `sh -c env ... spawn-claude.sh c-9xx ...`, no harness child -> `START` in the same pane. |
| **B2** | Agree | One seat, one session. The hook must refuse to write a heartbeat into a dir whose real name is not its `AGENT_ID`. The failover must end the old session before starting the new one. Red control: `c-001 -> g-001` link, a hook run as `AGENT_ID=c-001` -> `REFUSE` line. |
| **B3** | Agree | Briefs must travel with the row. The placer must write the brief to its local `dispatch/briefs` before placing. The "holder's box places" gate must go. Red control: a row queued on box A, no file on box B, B places -> placed, brief sha256 equal on both boxes. |
| **B4** | Agree | The relay must log failure causes. The relay must append rc, the hub's answer, and the target to `dispatch/relay.log`. Red control: stub hub that exits 1 with `from_not_announced` -> one `relay.log` line naming it, exit 1. |
| **B5** | Agree | The limit lifted early must be seen. A parked seat must wake when a peer of the same vendor and login finishes a good turn. Red control: seat A parked until 16:00Z, seat B (same login) writes a good-turn heartbeat at 14:20Z -> A woken at the next tick. |
| **O1** | Agree | The grok runbook must have a cadence table of every recurring orchestrator task. The drill fixture must hold exactly the tasks of the table. Red control: `do_spl_orch_drill --list` vs the table's rows -> equal. |
| **O2** | Agree | `do_spl_orch_drill` must measure grok's lock-to-first-act per task. The pass line: per task the median within 2x claude's, no task over 600 s, at least 90% right. Red control: stub seat that never acks -> `FAIL timeout`. |
| **O3** | Agree | The chain lock must enforce one actor per chain. A child row must be lockable only by the root's holder while the root lock lives. Red control: two seats, one chain of 3 rows, concurrent: seat B's `done` on a child of A's chain -> 409 naming A, n ≥ 50 races, exactly one actor per chain. |
| **O4** | Agree | Three seats (2 claude + 1 grok) must be the pool target. The supervisor must refuse a placement that puts all three on one login. Red control: claude out -> 3 grok seats within one supervise tick. |
| **O5** | Agree | The time slots must rotate every 900 s. The intake gate must allow only the intake seat to lock a row younger than 60 s. Red control: fake clock: intake seat A; B's lock-next on a 10 s old row -> 0 rows; at 61 s -> B gets it. |
| **O6** | Agree | The lock must be visible in the WUI and tmux. The issue card and topic header must show `orchestrator: <seat>, locked until <time>`. The seat loop must set a window option `@od` (chain count, oldest age). Red control: e2e on the mock: a locked chain shows its seat. |
| **O7** | Agree | The hub must refuse a renew past `lock_at + OD_SLOW_S[kind]` with no act stamp. The seat loop must drop the job on that 409. Red control: fake clock: no act by 601 s -> renew 409, row open, seat B locks it and acts. |

## 4. Open points

1. **Three seats vs 134's 2+2**: Agree with three seats (2 claude + 1 grok). The owner's "3 of those" is clear, and three seats spread risk across two logins.
2. **600 s line**: Keep 600 s for `route_post`. Grok's median first reply (481 s) fits, and the 27-min turn (1620 s) would have lost it. The O2 drill will re-measure.
3. **Slot length 900 s**: Agree. 900 s is short enough to avoid context budget overruns and long enough to fit grok's turn lengths.

## 5. Files disjoint per batch

- Batch 1: `orc/run/spl-agent-identity-restore.func.sh`, `sa/scripts/role-seat-switch.sh`, `sa/scripts/spool-agent-hook.sh`, `orc/run/spl-watchdog.func.sh`, `orc/run/spl-role-failover.func.sh`
- Batch 2: `orc/run/spl-spawn-place.func.sh`, `orc/run/spl-spawn-enqueue.func.sh`, `api/internal/store/fleet_ask*.go`, `orc/run/spl-relay-check.func.sh`
- Batch 3: `csi-spl-doc/doc/md/runbook-orchestrator.md`, `orc/run/spl-orch-drill.func.sh`, `orc/tests/orch-drill.tst.sh`, `orc/run/spl-watchdog.func.sh`
- Batch 4: `api/internal/store/fleet_ask_od.go`, `orc/run/spl-od-pool-supervise.func.sh`, `orc/tests/od-pool-vendor.tst.sh`
- Batch 5: `api/internal/store/fleet_ask_od.go`, `orc/run/spl-od-slots-rotate.func.sh`, `csi-spl-wui/` (UI components), `orc/run/spl-od-seat.func.sh`
- Batch 6: `api/internal/store/fleet_ask_od.go`, `orc/run/spl-od-seat.func.sh`

## 6. Owner gates named

| gate | rows | why |
|---|---|---|
| a new rdb migration reaches the prd database on the CI deploy | B3 (queue brief column), O3 (`chain_id`), O5/O7 if they add a column | a hub migration is a GCP mutation |
| the OD pool supervisor's cron on a box | O4, O7 (134 P3 `do_spl_od_pool_supervise_install_cron`) | a box crontab |
| a live seat started, switched or retired by the cut-over | O7 (134 P6 per kind, P8) | a live seat and the lease |
| `od_pool` row written on prd (targets, kinds, slots) | O4, O5, O7 | fleet config on prd |
| `do_spl_relay_check` sending on prd | B4 | a prd write (two notes); read only otherwise |
| none (lands and runs without a go) | B1, B2, B5, O1, O2 (dev drill), O6 (UI, behind the cut-over) | box-local code with tests; the drill runs on dev |

## 7. No mistral coding rows

All rows are docs, orchestration, or UI. No mistral coding rows.

## 8. Signature

```
v1.0 signed: mistral seat (m-125), 2026-10-28, plan sha ed2b5f74b
```
