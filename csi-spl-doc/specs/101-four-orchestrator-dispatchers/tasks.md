# 101 Four orchestrator-dispatchers: tasks

What gets built, in order. [spec.md](spec.md) v0.4.1 holds the behaviour
(consensus on v0.4 `7ca00033`, 4 of 4 seats, section 11); this file only
splits it into lanes. Each task is one lane: one agent, one small task, the
files it owns (and so the files no other task may touch while it runs), what
it depends on, and a measurable done-when. Panel spool task
`cc7726e7-55b7-43a7-865b-eeeab5c75c3a`; owner topic t1 `e05fb2f8`. Owner rule
(2026-10-05): consensus, then tasks, then build lanes, no further go; a GCP
mutation still needs an explicit go.

Written on tree `0f23fa7b` (spec v0.4.1). Paths: `orc/` =
`csi-spl-orc/src/bash/`, `sa/` = `orc/features/spawn-agents/`, `api/` =
`csi-spl-api/src/go/spool-hub-api/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `doc/` = `csi-spl-doc/`.

## Rules for every task

- **Gate before every push and again after the rebase** (repo `CLAUDE.md`):
  `cd csi-spl-iac && ./run -a do_check_pre_push`; `orc/` -> `bash
  csi-spl-orc/src/bash/tests/run-all-tests.sh` (and `sa/tests/run-all-tests.sh`
  for `sa/`) plus `./run -a do_check_pre_push_lint`; `api/`, `rdb/` ->
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres)
  and the clean-code gate for new Go functions; `doc/` -> `do_check_dist_hygiene`.
- **Inert until seats**: every orc change before the cut-over is a no-op while
  `<spool root>/peer/seats` is absent (068 order A), and its test proves the
  no-op as well as the behaviour.
- **Each fixture has a control**: an input flipped so the check DOES fire,
  so no test passes vacuously (spec 8.5). The regression test for each
  failure in spec 3.2 and 8.5 lives in the task that closes it (Coverage, below).
- **Nothing ad hoc**: every step is a `do_<verb>_<noun>` action in
  `orc/run/<verb>-<noun>.func.sh` plus its test in the same commit.
- **Measurements** (done-when numbers) carry the tree sha, the switch states
  (`PEER_SHADOW`, `SPOOL_TO_PEERS`) and n (spec 8.5).
- **Live changes on a box** (a cron, a hook entry, `peer/seats`, `lease.conf`)
  are orchestrator steps: the lane lands the action, the orchestrator of that
  box runs it with the exact command. No lane edits a live box.
- **Migration numbers**: on `0f23fa7b` the last is
  `0139_calendar_full_edit.sql`; check again at build time
  (`ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1`).
- Commits: the repo's canonical author (repo `CLAUDE.md`), no AI trailers,
  explicit pathspecs; no personal names, box tags or hosts in shipped files.

### Lane kinds

| kind | for |
|---|---|
| **grok** | bounded bash: one action or one function plus its test (owner mix: grok is the default lane, tests too) |
| **claude** | concurrency- or correctness-critical code: hub store transactions, the poll loop, the cut-over |
| **orch** | an orchestrator step on a live box: install, measure, drill, flip. No code commit; at most a doc commit of the numbers |
| **doc** | docs only |

### Marks

- **owner go**: the owner's explicit go is needed before the task acts.
- **GCP**: landing the task changes GCP state (a hub deploy by CI rolls a new
  Cloud Run revision on dev and prd; a migration changes the database).
- **orch**: an orchestrator step (see lane kinds).

## Order and parallelism

```
M0.5  T001 lanes on sat
      T002 dispatcher spawns its own lanes + ask warning ──► (spool-send.sh next: T011)
      T003 lane reports to its spawner ──► (spawn-core.inc.sh next: T016)
      T004 OD hooks installed (orch)
      T005 orch-load report ──► T006 M0.5 one-day numbers (orch, after T001..T005)
M1    T007 D1 hub router ignores mutex rows
      T008 D12 topic guard ──► T009 D13a claim --rebind (hub) ──► T010 D13b restart/takeover rebind
      T011 D14 one msg_id (after T002)
      T012 D15 mutex release ──► T013 D5 ask key + intent before act ──► T019 D10 spawn mutex for all
      T014 093 T010 poll loop rounds ──► T015 D2 capability + needs=prd ──► T017 D8 shadow
      T016 D6 bare c-00N rewrite (after T011, T003)
      T018 D9 rotations skip seats (before T010: shares spl-wd-takeover)
      T020 D7 sweep from every box as a peers note
      T021 068 L7 do_spl_peer_setup + drill tooling (after T014, T015, T017)
      T022 D3 do_spl_fleet_od_cutover + ROLLBACK (after T010, T016, T018..T021)
      T023 D16 interim guards (only if M4 is more than a few days away)
      T024 U4 token cost of one seat (orch, measure)
M2    T025 migration rows 0110/0111/0132 on dev + prd (orch; owner go only if one is missing)
M3    T026 dev drill, n >= 5 per case (orch)
M3b   T027 prd shadow, 24 h (orch)
M4    T028 prd cut-over, ONE action, rollback ready (orch, OWNER GO)
M5    T029 7-day soak (orch)
M6    T030 delete the role code (068 L10) ──► T031 fleet-roles rewrite (068 L9 + 093 T012)
```

Start together (disjoint files): T001, T002, T003, T004, T005, T007, T008,
T012, T014, T018, T020, T024. T025 can run at any time before T028.

## Tasks

### Phase M0.5: routing first (no owner go, no migration, no cut-over)

| id | task | kind | owns (no other task touches these while it runs) | depends on | done when | marks |
|---|---|---|---|---|---|---|
| **T001** | **R1 lanes on sat by default.** Confirm `do_spl_box_pick` places a new lane on sat while the `<pc box>` is above its load target, and close the gap if not (a weight, never a box name: placement reads the hub's load) | grok | `orc/run/spl-box-pick.func.sh`, `orc/tests/spl-box-pick.tst.sh` | - | fixture with today's loads (the PC far above its cores, sat ~17 on 16) -> `pick=sat`; control: loads swapped -> `pick=<pc box>`; live: where each of the next 10 lanes spawned without `SPAWN_BOX` went, from the registry (n = 10) | - |
| **T002** | **R2 the taking dispatcher spawns its own lanes.** The dispatcher seed says real lane work is spawned by the dispatcher that took it (fleet-roles 3), not asked of the orch; `spool-send.sh` prints one WARN (and still sends) for a `--kind task` from `c-002` / `c-003` to `orchestrator` whose body asks for a new lane | grok | `orc/run/spl-dispatch-setup.func.sh` (seed text only), `sa/scripts/spool-send.sh` (one new warn function only), `sa/tests/test-spool-send.sh` (new section), `orc/tests/dispatch-seed-alias.tst.sh` (new assertion) | - | test: a "new lane please" task from 002 -> WARN on stderr, message delivered; controls: the same from a lane -> no WARN; a `note` from 002 -> no WARN | - |
| **T003** | **R3 a lane reports to its spawner.** The spawn seed writes `--to <SPAWN_REQUESTER>@<box>` for results and notes; `orchestrator` stays for decisions and prd. No requester -> today's text | grok | `sa/scripts/spawn-core.inc.sh` (the `SPOOL_PROTO` sentence on reports only), `sa/tests/test-spawn-requester.sh` | - | test: `SPAWN_REQUESTER=c-002` on box `b` -> the seed contains `--to c-002@b`; control: no requester -> `--to orchestrator`; `test-spawn-seed-size.sh` still green | - |
| **T004** | **R5 the 093 hooks installed for the OD seats** (the inject hook shows asks mid-turn): `do_spl_agent_hooks_install DRY_RUN=0` on sat, then the `<pc box>` | orch | none (live: the agent user's settings on each box) | - | `<spool root>/c-00{1,2,3}/heartbeat.json` exists on each box; a message sent mid-turn to `c-001` shows in its context within one tool call (n >= 3) | orch |
| **T005** | **The orch-load report as a named action**: r1's E6..E8 commands ([research/r1-grok-standin.md](research/r1-grok-standin.md) section 2) as `do_spl_orch_load_report` over a `SINCE` / `UNTIL` window: messages to the orch by sender kind, asks raised by dispatchers, dead rate, re-raise share, wait per `raised_n` | grok | `orc/run/spl-orch-load-report.func.sh` (new), `orc/tests/orch-load-report.tst.sh` (new) + fixtures | - | on a fixture spool root it prints E6..E8's columns; control: a fixture with no dispatcher asks -> 0%; on sat it reproduces r1's E6..E8 for 2026-10-04..05 within 1% | - |
| **T006** | **M0.5 one-day numbers**: T005 for the 24 h before T001..T004 landed and the 24 h after, recorded in a doc commit | orch | `doc/specs/101-four-orchestrator-dispatchers/research/m05-numbers.md` (new) | T001..T005 | spec 8.5 M0.5 row: asks to the orch down by at least half; dead rate and re-raise share down. A miss is reported to the owner as a miss; it does not hold M1 | orch |

### Phase M1: build (inert without `peer/seats`; no owner go unless marked)

| id | task | kind | owns | depends on | done when | marks |
|---|---|---|---|---|---|---|
| **T007** ✓ `e4d033d8` | **D1 the hub router reads only `orch` / `dispatch` rows**, never a mutex row (`roleSeats` in `role_group.go`) | claude | `api/internal/hub/role_group.go`, `api/internal/hub/role_group_test.go` | - | test: a live `spawn` row held by `c-002@sat` leaves agent 002's channel routing unchanged; control: an `orch` row does change it (today's behaviour) | GCP (hub deploy) |
| **T008** | **D12 topic guard in the accept**: T2 refuses while another seat holds a live owned or parked job of the same `(tenant, task_id)`, the topic's open rows locked in `msg_id` order or a topic advisory lock; T1 opens no non-sticky round for a held topic. Prefer the advisory lock (no migration); an index means a new migration and the owner's go | claude | `api/internal/store/message_claim.go`, `api/internal/store/message_claim_postgres.go`, `api/internal/store/message_claim_test.go`; a new `rdb/0140_*.sql` only if the index is chosen | - | Postgres test: two seats, two rows in one topic, concurrent accepts -> exactly one topic owner (n >= 50 races); control: two topics -> two owners; a follow-up whose owner is dead waits <= 125 s, then moves | GCP (hub deploy); **owner go only if it adds a migration** |
| **T009** | **D13a hub op `spool claim --rebind <seat>`**: one transaction bumps `responsible_gen` on every job the seat holds and returns the new gens | claude | `api/internal/store/message_claim*.go` (a new rebind function only, after T008), the claim frame handler in `api/internal/hub/` (rebind case only), `api/cmd/spool/claim.go`, `api/cmd/spool/claim_test.go` | T008 (same store files) | test: after a rebind the old gen's fence says lost and its answer gets 409, the new gen passes; control: a seat with no jobs -> 0 rows, exit 0 | GCP (hub deploy) |
| **T010** | **D13b the restart and the takeover rebind before they spawn**: `spl_peer_restart_seat` and `do_spl_wd_takeover` call `--rebind` before the new session starts; a failed spawn re-bumps and frees the jobs | claude | `orc/run/spl-peer-restart.func.sh`, `orc/run/spl-wd-takeover.func.sh` (the seat path only, after T018), `orc/tests/peer-restart.tst.sh`, `orc/tests/wd-takeover.tst.sh` | T009, T018 (same takeover file) | test: inside the 330 s two-session window the old session's fence check fails (r2 3.3 replay, the same-id hand-over); control: a role id with no seat file takes today's path, no rebind call | - |
| **T011** ✓ `e650b2a7` | **D14 one msg_id across both legs** of a peers send: minted before the hub leg, reused by the local leg (`send_peers_local`) | grok | `sa/scripts/spool-send.sh` (`send_peers_local` + the relay leg only, after T002), `sa/tests/test-spool-send.sh` (new section) | T002 (same files) | test: a hub stub that commits and drops its reply -> one id on both legs, one row; control: today's code mints two | - |
| **T012** | **D15 a release for the mutex**: a CAS to an explicit free holder on the won gen; `spawn` held only for the count-and-create step | grok | `orc/run/spl-peer-gate.func.sh` (`spl_peer_mutex` + a new release function), `orc/tests/spawn-mutex.tst.sh` | - | test (fake clock): two spawns 5 s apart both pass when the first releases; control: no release -> the second waits for the 120 s expiry; a stale gen cannot release | - |
| **T013** | **D5 ask key + intent before act**: every spawn carries `ask=<topic>:<slug>`, checked under the `spawn` mutex against the registry and `fleet_asks`; the lane id derived from `(task_id, slot)` is parked on the job (`--park --wait <lane id>`) BEFORE the spawn; the spawn refuses an existing lane or worktree, naming its `<ID>@<box>` | claude | `orc/run/spl-peer-gate.func.sh` (the spawn gate, after T012), `sa/scripts/spawn-window.sh` (the gate hook only), `orc/tests/spawn-mutex.tst.sh` (new section, after T012) | T012 (same files); 093 T009 (on trunk) | tests: one ask in two messages -> one lane, the repeat refused naming the first; two relays to one lane -> one instruction; a death between park and spawn -> the next owner inherits `wait_token`, no second lane (r2 2.2); control: two slugs -> two lanes | - |
| **T014** | **093 T010 the poll loop on the two-phase claim**: rounds (idle first, `BUSY_DELAY`, `OFFER_K`, harness mix), stubs to the round's seats only, anchor renew, inbox reconcile, park renew on able; `PEER_PROGRESS_MAX` removed | claude | `orc/run/spl-peer-poll.func.sh`, `orc/tests/peer-poll.tst.sh` | 093 T008 / T009 (on trunk) | 093 T010's own done-when: 4 seats on 2 simulated boxes, FR-001 (125 s, n >= 20), FR-005, FR-006, FR-008; a stub reaches at most `OFFER_K` seats (spec 8.2) | - |
| **T015** | **D2 capability per session**: at every seat start and hourly a read-only probe through `do_spl_peer_prd` with a no-op action writes `prd=yes\|no` into `peer/seats/<id>`; a `needs=prd` job opens its first round only among capable seats; none capable -> the ask book's owner leg at once; `not_by` stays the authority | grok | `orc/run/spl-peer-prd.func.sh` (the probe), `orc/run/spl-peer-poll.func.sh` (round filter only, after T014), `orc/tests/peer-prd-probe.tst.sh` (new), `orc/tests/peer-poll.tst.sh` (new section, after T014) | T014 (same files) | tests: a refusing harness stub -> `prd=no` and the `needs=prd` job skips it; none capable -> owner leg within one tick; the re-probe after a restart flips a stale flag; control: a capable seat gets round 1 | - |
| **T016** | **D6 a bare `c-00[1-4]` from a lane** is rewritten to `peers` with one WARN while `peer/seats` exists (refused after L10, T030); the spawn seed stops writing a bare orchestrator id | grok | `sa/scripts/spool-send.sh` (the `--to` resolve only, after T011), `sa/scripts/spawn-core.inc.sh` (after T003), `sa/tests/test-spool-send.sh` (new section) | T011, T003 (same files) | test: a lane's `--to c-001` with seats -> `to_id = peers` + WARN; a result sent during a role flip lands in `peers`, not an old role inbox; controls: `--to c-001@sat` untouched; no seats file -> today's local resolve | - |
| **T017** | **D8 `PEER_SHADOW=1`**: rounds logged with the seat that WOULD own each job; no stub, no ring, every accept refused | grok | `orc/run/spl-peer-poll.func.sh` (the shadow switch only, after T015), `orc/tests/peer-poll.tst.sh` (new section) | T015 (same files) | test: with the switch, 20 posts -> 20 log lines, 0 stubs, 0 accepted rows; control: switch off -> stubs sent | - |
| **T018** | **D9 two schedulers**: `do_spl_orch_rotate` / `do_spl_dispatch_rotate` skip an id with a seat file (`SKIP seat`); a watchdog takeover of a seat writes no `rotate.hold` | grok | `orc/run/spl-orch-rotate.func.sh`, `orc/run/spl-dispatch-rotate.func.sh`, `orc/run/spl-wd-takeover.func.sh` (the `rotate.hold` write only), `orc/tests/orch-rotate.tst.sh`, `orc/tests/dispatch-rotate.tst.sh` | - | test: an id that is both a lease role and a seat -> `SKIP seat`, no second session; control: no seat file -> today's rotation | - |
| **T019** | **D10 from M4 the spawn launchers take the `spawn` mutex for EVERY caller**, not only seats, behind the switch the cut-over writes | grok | `sa/scripts/spawn-window.sh` (the caller check only, after T013), `orc/tests/spawn-mutex.tst.sh` (new section, after T013) | T013 (same files) | test: with the switch, a non-seat caller without the mutex is refused (r1 E10 replay); control: switch off -> today's spawn | - |
| **T020** | **D7 the unanswered sweep stays, from every box**, its note a `to: peers` message while seats exist | grok | `orc/run/spl-unanswered-sweep.func.sh`, `orc/tests/unanswered-sweep.tst.sh` | - | test: with seats -> one `peers` note per item; a planted claim bug (an owned row whose holder's gen is dead) is still reported; control: no seats -> today's recipient | - |
| **T021** | **068 L7 `do_spl_peer_setup` + drill tooling**: writes `peer/seats` (harness and login per seat, the D2 flag), the seat spawn as an action, and `do_spl_peer_drill` (kill one OD, SIGSTOP a box's ODs, expire a login fixture, 20 posts, each delay of 068 section 7) | claude | `orc/run/spl-peer-setup.func.sh` (new), `orc/run/spl-peer-drill.func.sh` (new), `orc/tests/peer-setup.tst.sh` (new), `orc/tests/peer-drill.tst.sh` (new) | T014, T015, T017 | test: setup is idempotent and a dry run by default; four seats on one login -> refused unless `ACCEPT_ONE_LOGIN=1` (spec 8.1 condition 1); the drill on stubs prints one delay line per case | - |
| **T022** | **D3 `do_spl_fleet_od_cutover` + `ROLLBACK=1`** under the `fleet-config` mutex, every box or none, in spec 8.3 M4's order: stop the lease loops, move `lease.conf` aside, remove `orch-rotate` / `dispatch-rotate` (the sweep stays), write `peer/seats`, install the peer crons; then per id the 060 hand-over with T009's rebind, one id at a time, `c-004` a plain spawn; the D6 and D10 switches on | claude | `orc/run/spl-fleet-od-cutover.func.sh` (new), `orc/tests/fleet-od-cutover.tst.sh` (new) | T010, T016, T018, T019, T020, T021 | tests on 2 simulated boxes: afterwards exactly one decider class exists; control: box 2 unreachable -> nothing written on box 1 (the half-applied control); `ROLLBACK=1` restores `lease.conf`, the crons and `LEASE_CMD=ensure`; dry run by default | - |
| **T023** | **D16 interim guards** (only if T028 lands more than a few days after T022): a `lease.orch` older than `LEASE_STALE` is unknown and relayed through the hub; the desk check alerts on a role agent with no lease loop | grok | `sa/lib/spool-fleet.inc.sh` (`spool_fleet_orchestrator` only), `orc/run/spl-desk-check.func.sh`, `sa/tests/test-fleet-send.sh` (new section) | - | test: a stale `lease.orch` -> relayed, not resolved locally; control: a fresh one -> today's resolve | - |
| **T024** | **U4 the fixed token cost of one active seat in a quiet hour** (spec 8.2), from transcripts with r1's E5 method | orch | `doc/specs/101-four-orchestrator-dispatchers/research/u4-seat-cost.md` (new) | - | cache-read tokens per hour for n >= 3 quiet hours of one seat session, with the tree sha; in hand before T028 (owner question 9) | orch |

### Phase M2..M6: proof, cut-over, soak, deletion

| id | task | kind | owns | depends on | done when | marks |
|---|---|---|---|---|---|---|
| **T025** | **M2 confirm rdb 0110 / 0111 / 0132** in the migration table on dev and prd, through the per-env SA (a named read action, new only if none reads the table). Only a missing row needs applying | orch | none, or `orc/run/spl-db-migration-check.func.sh` + its test if no action reads the table | - | the three files listed as applied on dev and on prd (n = 2 envs). A missing one: the **owner's go** before applying | orch; **owner go only if a row is missing**; GCP if one is applied |
| **T026** | **M3 dev drill**: four seats on sat against the dev hub, `do_spl_peer_setup` then `do_spl_peer_drill` | orch | `doc/specs/101-four-orchestrator-dispatchers/research/m3-drill.md` (new: the numbers) | T021, T022 (dry run read), T007..T009 deployed on dev | spec 8.5 M3: each job moves within 125 s for kill / SIGSTOP / login expiry, n >= 5 each. Rollback: remove the dev `peer/seats` | orch |
| **T027** | **M3b prd shadow, 24 h**: `peer/seats` on sat with `PEER_SHADOW=1`; the lease still decides everything | orch | `doc/specs/101-four-orchestrator-dispatchers/research/m3b-shadow.md` (new) | T017, T024, T026 | spec 8.5 M3b: every human post has exactly one shadow owner; median shadow pickup <= 5 s; prd jobs with no capable seat counted. Rollback: delete `peer/seats` on sat | orch |
| **T028** | **M4 prd cut-over, ONE action**: `do_spl_fleet_od_cutover DRY_RUN=0`, `ROLLBACK=1` ready. Needs spec 8.1's placement condition: two logins, or A' (3 + 1), or the owner's words accepting one login | orch | none (live: every box) | T022, T024, T025, T026, T027 | `do_spl_dispatch_check` reports four seats and no lease role; the first poll of each seat lists the open asks once | orch; **OWNER GO** (owner question 4) |
| **T029** | **M5 soak, 7 days** on prd, the sweep still running (D7); `do_spl_dispatch_check` reports the seats instead of the lease | orch | `doc/specs/101-four-orchestrator-dispatchers/research/m5-soak.md` (new) | T028 | spec 8.5 M5: 0 reports in an old role inbox; first agent reply per human post p95 <= 180 s; 0 double answers; sweep items not above the 7 days before M4; every prd job with no capable seat at the owner leg within one tick. Rollback: T022's `ROLLBACK=1` | orch |
| **T030** | **M6 068 L10: delete the role code** (the lease roles' renew / watch loops, `orch-rotate`, `dispatch-rotate`, `fleet-lease.tst.sh` and the fixtures retired with them); D6 turns from rewrite into refusal | claude | the files 068 L10 names; `sa/scripts/spool-send.sh` (the refusal, after T016) | T029 passed AND a second box holds a seat (spec 8.1 condition 2) | every suite green with the role code gone; `grep -rn 'LEASE_ORCH' csi-spl-orc/src/bash` -> 0 | - |
| **T031** | **068 L9 + 093 T012: rewrite SPEC-spool-fleet-roles.md** for the seats; spec 101 status line | doc | `doc/doc/md/SPEC-spool-fleet-roles.md`, `doc/specs/101-four-orchestrator-dispatchers/spec.md` (status line only) | T030 | `do_check_dist_hygiene` and `lint-mdlinks` green | - |

## Dependencies

| task | depends on | shares a file with (so runs after it) |
|---|---|---|
| T001..T005, T007, T008, T012, T014, T018, T020, T023, T024, T025 | - | - |
| T006 | T001..T005 | - |
| T009 | T008 | T008 (`message_claim*.go`) |
| T010 | T009, T018 | T018 (`spl-wd-takeover.func.sh`) |
| T011 | T002 | T002 (`spool-send.sh`, `test-spool-send.sh`) |
| T013 | T012 | T012 (`spl-peer-gate.func.sh`, `spawn-mutex.tst.sh`) |
| T015 | T014 | T014 (`spl-peer-poll.func.sh`, `peer-poll.tst.sh`) |
| T016 | T011, T003 | T011 (`spool-send.sh`), T003 (`spawn-core.inc.sh`) |
| T017 | T015 | T015 (`spl-peer-poll.func.sh`, `peer-poll.tst.sh`) |
| T019 | T013 | T013 (`spawn-window.sh`, `spawn-mutex.tst.sh`) |
| T021 | T014, T015, T017 | - |
| T022 | T010, T016, T018, T019, T020, T021 | - |
| T026 | T021, T022, T007..T009 on dev | - |
| T027 | T017, T024, T026 | - |
| T028 | T022, T024, T025, T026, T027 | - |
| T029 | T028 | - |
| T030 | T029, a second box with a seat | T016 (`spool-send.sh`) |
| T031 | T030 | - |

Six hot files, each owned by one serial chain, so lanes in different chains
never share a file: `spool-send.sh` (T002 -> T011 -> T016 -> T030),
`spawn-core.inc.sh` (T003 -> T016), `spl-peer-poll.func.sh` (T014 -> T015 ->
T017), `spl-peer-gate.func.sh` + `spawn-window.sh` + `spawn-mutex.tst.sh`
(T012 -> T013 -> T019), `message_claim*.go` (T008 -> T009),
`spl-wd-takeover.func.sh` (T018 -> T010).

## Marks at a glance

| mark | tasks |
|---|---|
| **owner go** | T028 (M4 prd cut-over); T025 only if a migration row is missing; T008 only if it adds a migration |
| **changes GCP state when it lands** | T007, T008, T009 (hub deploy to dev and prd by CI); T025 if a migration is applied; T008's migration if chosen |
| **orchestrator steps** | T004, T006, T024, T025, T026, T027, T028, T029 |

## Coverage

| spec item | task |
|---|---|
| M0.5 R1 / R2 / R3 / R5 (D11) | T001 / T002 / T003 / T004; the numbers T005, T006 |
| D1 | T007 |
| D2 | T015 (the flag written at setup by T021) |
| D3 | T022 |
| D4 placement | T021 (one-login refusal), T028 (precondition) |
| D5 | T013 |
| D6 | T016 (rewrite), T030 (refusal) |
| D7 | T020 |
| D8 | T017 |
| D9 | T018 |
| D10 | T019 |
| D12 / D13 / D14 / D15 | T008 / T009 + T010 / T011 / T012 |
| D16 | T023 (conditional) |
| 093 T010 | T014 |
| 068 L7 | T021 |
| U4 | T024 |
| M2 / M3 / M3b / M4 / M5 / M6 | T025 / T026 / T027 / T028 / T029 / T030 + T031 |

The regression tests of spec 8.5 (one per failure seen):

| failure | task |
|---|---|
| dup ask over two messages; two relays to one lane | T013 |
| a bare `c-001` from a lane; a result during a role flip | T016 |
| a prd job with and without a capable seat; the re-probe after restart | T015 |
| the one-decider cut-over and its half-applied control | T022 |
| shadow decides nothing | T017 |
| the same-id hand-over | T010 |
| four seats on one login | T021 |
| a seat that is also a lease role; two schedulers | T018 |
| the sweep still seeing a claim bug | T020 |

Not in this file: 093 T011 (hub-down `.offer` / `.accept` files; spec 1.2:
hub-down safety, not the cut-over) stays in 093's tasks.md.

<!-- version: 0.1 · updated: 2026-10-06 · last-edit: 2026-10-06T19:30:00Z -->
