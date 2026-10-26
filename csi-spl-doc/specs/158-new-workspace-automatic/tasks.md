# Spec 158 tasks: a new workspace works automatically

Issue SPL-3504, epic SPL-2398. Each row is one commit, tests red first. Each
row goes review branch -> non-claude R7 -> GO -> land -> dev AND prd
deployed. Store rows run `PRE_PUSH_TIER=full`.

## 1. Small rows first

| row | what | files | test |
|---|---|---|---|
| T1 | C: `ReadRootKey` says a missing file does not exist, never echoes the value | `csi-spl-api/src/go/spool-hub-api/internal/action/pin.go` | `internal/action/rootkey_test.go` `TestReadRootKeyMissingFile` (red on the old code) |
| T2 | B: `do_spl_workspace_seat_alarm`, one blocker to the orchestrator for workspaces with member posts and 0 agent seats; re-alert hourly; lease holder only | `csi-spl-orc/src/bash/run/spl-workspace-seat-alarm.func.sh` | `csi-spl-orc/src/bash/tests/workspace-seat-alarm.tst.sh` (planted rows; red control: 1 seat sends nothing) |
| T3 | B: the sweep's cron script runs the alarm every minute | `csi-spl-orc/src/bash/scripts/unanswered-sweep-cron.sh` | T2's test drives the cron script with stubs |
| T3b | Interim A-store (spec 4.1): `do_spl_desk_store_seat` in the desk-reconcile cron seats every workspace with a kept create JSON and no desk dir; dry run by default; built only on its own GO; first prd `DRY_RUN=0` is c-001's with the owner's go | `csi-spl-orc/src/bash/run/spl-desk-store-seat.func.sh` | orc test: a store file with no desk dir -> `do_spl_desk_up` called with it; control: a desk dir present -> nothing; a test workspace skipped |

## 2. Hub rows (A-fleet, spec section 4.2)

| row | what | test |
|---|---|---|
| T4 | rdb: `tenants.fleet_seating` (default false) + `fleet_desk_boxes`, RLS / operator-only | migration lint; `rls_test.go` covers the new table |
| T5 | create sets `fleet_seating` true (request field, default true); PATCH flips it; audited | `operator_workspaces_test.go` |
| T6 | `PUT/DELETE /v1/operator/fleet-desks/{box}` + `do_spl_fleet_desk_box` | hub test: a box with no live operator pin is refused |
| T7 | `GET /v1/fleet/workspaces` and `POST /v1/fleet/enrol` (two signatures, `box_mode = 'fleet'`, audit row) | hub tests: unlisted box 403, bad `sig_new` 401, replayed `ts` 409, `fleet_seating` false 403; enrol succeeds with `box_join_enabled` false and no `agents.join` holder (spec 4.5); Postgres twin |

## 3. Box rows (A-fleet, spec section 4.3)

| row | what | test |
|---|---|---|
| T8 | `spool fleet-workspaces`, `spool fleet-enrol` | `cmd/spool` tests against a fake hub |
| T9 | `do_spl_desk_up` `DESK_PIN_MODE=fleet` + `do_spl_desk_fleet_seat` in the desk-reconcile cron | orc test: a listed new workspace gets a desk dir and a pin with no `ROOT_KEY_JSON` |
| T10 | R2 proof: the dispatch tick subscribes the role seats in the new workspace's channels | orc test on `spl-dispatch-subscribe` with the new tenant |
| T10b | R3 seats part (M13): the dispatcher brief names `do_spl_dispatch_tenants` instead of a list rendered once; the fleet seat seats every role seat | orc test: a desk dir added after setup is printed by `do_spl_dispatch_tenants`, a workspace listed by the hub with no local desk dir is printed too, and the rendered brief carries no workspace list; control: the old template rendered the list frozen |
| T11 | e2e on dev: create -> seated (R1) -> channels (R2) -> member post answered within 180 s (R4) | dev run, numbers in the commit body |

## 4. Rollout rows

| row | what | who |
|---|---|---|
| T12 | R5 backfill (spec 7.2): `do_spl_fleet_seating_switch` (dry run default), one workspace or `ALL=1` for every non-test, non-suspended, non-archived one; orc test: three planted workspaces switched, a test one skipped; control: a second run changes nothing | lane builds it; c-001 runs it on prd with the owner's go |
| T13 | the first case workspace: switch on, desk cron seats it | c-001, owner's go |
| T14 | DevOps guide: a fleet seating section | lane, with T9 |

## 5. Drift rows (R6, spec section 7)

| row | what | test |
|---|---|---|
| T15 | `spl_workspace_baseline` (7.1 items 1-4) + `do_spl_workspace_drift` in the desk-reconcile cron: repairs this box's own items, one blocker per run for the rest, hourly repeats, lease holder only, `DRY_RUN=1` default | orc test with planted drift: a role seat missing from one channel -> repaired; another box's seat missing and `fleet_seating` off -> one blocker; red control: the same rows on the baseline send nothing |
| T16 | 7.1 item 5: measure what the host report's spool version holds and which release it must equal; then add the version item to the baseline | n and tree in the commit body; orc test: a desk box one release behind -> reported; control: on the newest -> nothing |
