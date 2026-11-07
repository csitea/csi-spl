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
| T5 | every create sets `fleet_seating` true in the insert (`store.CreateTenant`; request field / `hub-tenant --fleet-seating`, default true); PATCH flips it; audited. Fix SPL-4295: the first build set it only on the operator route, so `do_spl_tenant_create` (a prd workspace, 2026-10-29) left it false | `operator_workspaces_test.go`, `store/create_tenant_fleet_test.go` |
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

## 6. Usable with no agent step (spec section 10), in order

One lane per row. Every row gets its issue under SPL-2398 when this amendment
lands, status `todo` (spec 10.3). `go` names the owner's go that the row's run
needs; `-` needs none beyond the review and landing rules.

| order | row | what | files | test | go | status |
|---|---|---|---|---|---|---|
| 1 | H1 | M20: wf 40 masks every hidden and open slug before its first log line; fix `private-overlay.md` section 5 | `spl-tenant-host-reconcile.func.sh`, the overlay doc's Qto source | orc test: a planted hidden slug is absent from the output; control: without the mask it is there | - | todo |
| 2 | H2 | M19: print the dev plan's error, measure, then the fix (expected: the prd job writes the dev key) | `40_tenant-host-reconcile.yml`, `tenant-host-workflow-40.tst.sh` | contract test; then one real wf 40 prd run past the gate, n and sha in the body | - | todo |
| 3 | H3 | 10.5: a `wait` list; one stuck row holds no other; `HOST_WAIT_LIMIT` | `spl-tenant-host-reconcile.func.sh`, `tenant-host.tst.sh` | orc test: a hidden row with no placeholder plus a visible add -> the add goes, the run is green; control: past the limit -> `failed` | - | todo |
| 4 | H4 | 10.4: `do_spl_tenant_host_reserve` + its cron on the master box + a lock in `spl_private_add` | `spl-tenant-host-reserve.func.sh`, `spl-private-cnf.func.sh` | orc test with a stub `gh`: order line, sync, secret, detail; refused on another box; control: a visible, `e2e*` or unpaid row -> nothing | OD2, the token | todo |
| 5 | H5 | M27: the overlay pull cron on every other box; wf 40 takes a reservation only at 10 minutes old | `spl-private-overlay-pull.func.sh` and its cron install, `spl-tenant-host-reconcile.func.sh` | orc test: a 5-minute-old reservation waits, an 11-minute-old one is an add | - | todo |
| 6 | P1 | 10.6 items 1-2: `ensureWUIPin` in the operator create, `box_wui_pin` in the 201 body, audit row; amend spec 014 2.2; read spec 136's case first | `hub/operator_workspaces.go`, a new `hub/wui_pin.go`, `openapi.json` | hub + Postgres tests: generated key and operator's key both pinned; control: a revoked row and a foreign key stay | - | todo |
| 7 | P2 | 10.6 items 3-4: the sweep behind `hub.box_wui_pin_sweep`; `system` exempt in the check | `hub/wui_pin.go`, store, cnf, `spl-check-box-wui-pins.func.sh` | hub test: the same controls; dev: the switch on -> `do_spl_check_box_wui_pins` reads 0 gaps | dev: -. **prd: owner's go**, then the check reads 0 gaps | todo |
| 8 | P3 | M24: `paidTx` sets `fleet_seating`, per OD1 | `store/payments_postgres.go` | Postgres test: a paid create -> true | OD1 | todo |
| 9 | S1 | T8 | as T8 | as T8 | - | todo |
| 10 | S2 | T9, with spec 10.7's three additions | as T9 | as T9, plus: a moved desk is skipped; a claimed box seats nothing; a new dir seats the role seats | - | todo |
| 11 | S3 | List the desk boxes on dev; run S2 there | `do_spl_fleet_desk_box`, no code | the roster holds the role seats within 5 minutes | **owner's go** | todo |
| 12 | S4 | T10 | as T10 | as T10 | - | todo |
| 13 | S5 | T10b | as T10b | as T10b | - | todo |
| 14 | V1 | 10.8: the readiness route | a new `hub/operator_readiness.go`, `openapi.json` | hub + Postgres tests: each state of each step; control: a workspace admin gets 403 | - | todo |
| 15 | V2 | 10.8: the operator page row; every locale; agy's final word | `OperatorPane.vue`, `operator-console.mjs`, locale files | `pnpm run typecheck`, unit, an e2e with the mock's states, a Chrome screenshot | - | todo |
| 16 | E1 | 10.8: the e2e on dev, U1..U6; sets U3's target from its measured time | a new orc action + its test | one dev run with each step's time in the body; control: the reserve cron off -> stops at U3, V2 names it | - | todo |
| 17 | S6 | List the desk boxes on prd | `do_spl_fleet_desk_box`, no code | a new workspace is seated | **owner's go** | todo |
| 18 | T12 | The backfill (section 4) | as T12 | as T12 | **owner's go** | todo |
| 19 | T13 | The 10-26 workspace's switch, if T12 has not covered it (spec 10.7) | as T13 | as T13 | **owner's go** | todo |
| 20 | T14 | The guide section | as T14 | - | - | todo |
| 21 | T15, T16 | Drift, as in section 5; the pin and the host join the baseline's list (spec 7.1) | as T15, T16 | as T15, T16, plus: a missing pin and a stuck host -> reported | - | todo |

Status of the earlier rows: T1, T2, T3, T4, T5 (with its fix), T6, T7 landed. T8,
T9, T10, T10b are S1, S2, S4, S5 above. T11 is replaced by E1. T3b is dropped once
S3 lands, unless the holder objects.
