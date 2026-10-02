# 058: the fleet on many machines: plan

Spec: [spec.md](spec.md).

## 1. Order of work

| # | task | owner | state |
|---|---|---|---|
| 1 | inventory of the one-machine assumptions (spec section 2) | CLE-77913 | done |
| 2 | F1 agent-id band per machine (`SPOOL_AGENT_ID_RANGE`) + two-machine test | CLE-77913 | done `d8905f7a` |
| 3 | T1 hub tests: two machines in one tenant, routed once; takeover mid-message | CLE-77913 | done `d5b5a8bd` |
| 4 | F2 desk box per machine (`SPOOL_DESK_BOX`) + test | CLE-77913 | done `f7efacbf` |
| 5 | (done CLE-77911 `e23be5d4`) the two desk-box literals left in `spl-dispatch-lease.func.sh` / `spl-dispatch-setup.func.sh` read `spl_desk_box_default`; drop their exclusion in `test-desk-box-default.sh` check 8 | CLE-77911 | asked |
| 6 | gate every side-effect cron step (unanswered sweep, welcome, responder sweep, dispatch tick, gap feed) on "this machine holds the fleet lease"; gap feed reads the hub roster, not the local identity map; post-drop follows the lease | CLE-77911 | asked |
| 7 | the satellite's box.env: `SPOOL_DESK_BOX=sat`, `SPOOL_AGENT_ID_RANGE=100000-199999`, `SPOOL_AGENT_USER` (box-config.sh) | CLE-77912 | done `0fda3b8f` |
| 7a | owner naming: `<ID>@<box>`, 001-003 reserved (spec 3.0): allocator F4 `761ddac9`, WUI command box F3 `d02b84d3`, window/session names F5 `94ced000`, lease holder rdb 0095 (CLE-77911 `2b061000`, `99a8fe61`) | CLE-77913, CLE-77911 | done |
| 7b | the WUI sends `to_box` for a DM peer `<ID>@<box>` (live send frame) | CLE-77913 | done `ed3d9208` |
| 7c | the home box re-seats under its own 3-letter box (M5): `do_spl_desk_rebox` (spec 6.5); then its mailboxes move to `<ID>@<box>` (`do_spl_naming_migrate`, spec 6.2); one window, runbook spec 6.6 | CLE-77924 | code done (C1-C5); the window waits for CLE-001 (after the satellite trio + CLE-77911's drill) |
| 8 | N1: a local-mode `spool send` to an id with no local dir refuses (or routes through the hub) instead of minting an orphan inbox; satellite agents report to the orchestrator through the hub | CLE-77919 | done (spec section 4, N1) |
| 9 | N2: the lane map ("who owns what") readable across machines: hub table `fleet_lanes` (rdb 0096), written at spawn, done at exit-clean, read by `do_spl_lane_map` / `lane-map.sh` in the spawn path's scope check | CLE-77920 | done (hub `6f9f50ac`; live once a machine sets its fleet in lease.conf, M2) |
| 10 | M1 pins: mint `sat` on the satellite, pin it from the home box with `do_spl_desk_pin` admin mode, per tenant and env; box operator grant | owner go (prd) | waiting |

## 2. Test register (spec section 2 cases)

| case | test | result |
|---|---|---|
| two simulated machines seated in the same tenant | `TestTwoMachinesOneTenantOwnBoxIDs` | pass |
| a post routed once | `TestTwoMachinesOneTenantOwnBoxIDs` (DM, re-sync delivers 0), `TestFallbackLongestOnlineAndOldClientSkipped` (unheard post -> one agent) | pass |
| two machines' lanes visible to each other; a path owned on the other machine collides | `lane-map.tst.sh` (control: the local-only map is blind), `TestBoxFleetLaneMap` | pass |
| agent ids never collide | `test-next-agent-id.sh` (bands; the control shows the no-band collision) | pass |
| a takeover mid-message loses nothing | `TestBoxTakeoverMidMessageLosesNothing` | pass |
| a send to an agent of the other machine, both ways; no orphan inbox; reports while the orch lease flips | `TestFleetSendAcrossMachinesAndReportsFollowTheLease`, `test-fleet-send.sh` | pass |
| the same box id on two machines | `TestLastHelloWinsOnlyForBoxRole` (4409), spec H1 | the documented hazard |
| the same agent id on two boxes | `TestTamperedAndAmbiguousAndMissingPin` (`ambiguous_to_box`) | the documented hazard |

Not yet covered: the same box id live on two hub PROCESSES at once (H1, the
Cloud Run revision overlap). The model forbids that state, so no test plants
it. A guard would be a hub-side refusal of a second live hello across
processes, which needs shared state (a row lease per box). Spec section 5
keeps the rule as it is; reopen this only if the "never share a box id" rule
turns out to be unenforceable.
