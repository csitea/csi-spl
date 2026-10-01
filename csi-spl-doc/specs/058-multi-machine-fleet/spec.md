# 058: the fleet on many machines (one to many)

Status: **analysis done; fixes F1-F5 + N1 on trunk; the rest is assigned** (2026-10-02; CLE-77913, N1 CLE-77919).
Owner decisions on topic t1 `2efb3e78` (19:50Z, 19:51Z) are folded in: names `<ID>@<box>`, satellite box `sat`, ids 001-003 reserved on every box.
Plan: [plan.md](plan.md). Related: [057 the satellite](../057-satellite/spec.md),
rdb `0094_fleet_leases.sql` (CLE-77911), the satellite ansible port (CLE-77912).

## 1. What the owner asked for (verbatim)

> "the final /goal is to have as many agents running exactly the same way as
> those running on those box, but on the vm in the cloud, this might mean also
> some kind of checks on the actual concurrency model we have in the code now,
> because till now the connection was one to one, and now it becomes one to
> many which is always problematic in architectural changes like this one"

and earlier: "slowly take the execution on them and remove it from the
<home box>".

Words used below: the **home box** is the box PC that runs the whole fleet
today; the **satellite** is the GCP VM of spec 057 (box tag `sat`). A
**machine** is one of them. A **box id** is what the hub sees (`box-desk`,
`box-wui`, ...). These are different things, and conflating them is the root
of most of the risks below.

## 2. The one-machine assumptions, measured

Tree: origin/master at `f7efacbf`. Each row was read in the code, and each
verdict cites a test or the code line. **SAFE** means it works with two machines
under the target model of section 3. **BROKEN** means it fails with two machines
today. **FIXED** means it was broken and is now fixed on trunk by this lane.

### 2.1 The hub (Go, `csi-spl-api/src/go/spool-hub-api/internal`)

| # | what | today | verdict | proof |
|---|---|---|---|---|
| H1 | one live socket per **(tenant, box id)** | `hub/server.go`: `boxes map[[2]string]*session`; `hub/ws.go` `register`: the last hello wins and the old socket is closed **4409 superseded**. The loser's `hub-run` exits (`hubclient/flush.go` `ErrSuperseded`) | **BROKEN** when both machines seat the same box id: they evict each other in a loop. On two Cloud Run revisions, though, BOTH sockets stay live, and `ClaimSent` splits the box's queue at random between the machines | `TestLastHelloWinsOnlyForBoxRole`; `TestTwoMachinesOneTenantOwnBoxIDs` (own ids: no eviction) |
| H2 | box pin = one key per (tenant, box id) (`0001_hub_core.sql` pins PK) | a second machine that mints its own key for `box-desk` gets `pin_conflict` (`hub/rest.go`); sharing the key leads straight to H1 | **SAFE with own box ids**, each with its own key and pin | `TestPinRevokeAndForce` |
| H3 | roster replaced per box on every hello | `store/postgres.go` `SetRoster`: `DELETE ... WHERE tenant_id AND box_id`, then insert | **BROKEN** with a shared box id: presence flaps between the two machines' agent lists. **SAFE** with own ids | code |
| H4 | an agent id is unique only per box (`roster` PK `(tenant, box, agent)`) | the same id on two boxes gives `ambiguous_to_box` 409 to a send without `to_box` and to WUI `@agent` dispatch | **FIXED by F1** (disjoint id bands per machine) | `TestTamperedAndAmbiguousAndMissingPin`, `TestWUIDispatchRefusals`; `test-next-agent-id.sh` (control: two fresh roots both hand out `QWN-01`) |
| H5 | delivery, dedup and queue | `messages` PK `(tenant, msg_id)`, `deliveries` PK `(tenant, msg_id, to_box)`, `Enqueue ... ON CONFLICT DO NOTHING`; the queue relay (`hub/relay.go`) is per box, and `push` claims (`state='queued'`) before it writes | **SAFE**: a message goes to exactly one box, once. With a box id moved serially it is also SAFE: nothing is lost or doubled | `TestTwoMachinesOneTenantOwnBoxIDs`, `TestBoxTakeoverMidMessageLosesNothing` (msgs before, during and after the move, plus probes sent while the socket closes), `TestOfflineQueueAndHubDownFlush`, `TestRelayDeliversReplyStoredOnAnotherProcess` |
| H6 | unheard human post -> fallback responder (rdb 0067) | picks ONE agent across all live boxes of the tenant (responders list, then longest online); `ClaimFallback` PK `(tenant, msg_id)` | **SAFE**. Residual: the post-time path writes before it records, so it could race a sweep in another hub process. The 15 s `relaySweepGrace` covers that | `TestFallbackLongestOnlineAndOldClientSkipped`, `TestRelaySweepFallsBackAcrossProcesses` |
| H7 | channel post | one delivery per **member box** (`hub/channels.go` `routeChannel`) | **by design**: when agents on both machines are seated in a channel, both machines get the post. "Handled once" therefore comes from WHO is seated where (section 3.4), not from the hub | code |
| H8 | channel back-fill (rdb 0066) | its in-flight guard is an in-process `sync.Map` keyed by box, and it stamps only after sending | **BROKEN** only with a shared box id on two hub processes. **SAFE** with own ids | code |
| H9 | catch-up / replay (`acd575ad`) | keyed by tenant + msg; it signs in place only while the row is still unsigned, then routes like a fresh post | **SAFE** | code |
| H10 | WUI revision reload | browser sockets only (`/v1/wui/revision`) | **not affected** | code |
| H11 | box operator binding (`box_operators`) | per (tenant, box, human) | **SAFE**; the satellite's box needs its own grant | code |

### 2.2 The harness and the run actions (`csi-spl-orc`)

| # | what | today | verdict | owner |
|---|---|---|---|---|
| O1 | agent id allocation (`next-agent-id.sh`) | floor = max(local registry, local tmux, local dirs). A fresh satellite starts at `CLE-01` | **FIXED by F1**: `SPOOL_AGENT_ID_RANGE=<lo>-<hi>` in box.env | this lane |
| O2 | desk box id | `${DESK_BOX:-box-desk}` in 27 actions/scripts; `spool-install` builds a unique id but saves it nowhere, and 057 bootstraps with `--no-seat` | **FIXED by F2**: `SPOOL_DESK_BOX` in box.env is the default everywhere (`lib/bash/funcs/spl-desk-box.func.sh`). It is still a literal in `spl-dispatch-lease.func.sh` and `spl-dispatch-setup.func.sh` | this lane; the 2 lease files: CLE-77911 |
| O3 | local-mode `spool send` to an agent that lives on the other machine | `internal/spool/spool.go` `ensureAgent` `MkdirAll`ed an orphan inbox and reported `delivery: local` | **FIXED by N1**: the binary refuses an unknown local id (exit 3); `spool-send.sh` / `agent-send.sh` relay it through this machine's desk and the hub, and the receiving sidecar copies it into that machine's `/var/spool-hub` inbox (`SPOOL_FLEET_ROOT`) | CLE-77919 |
| O4 | `SPOOL_ORCHESTRATOR_ID` (default `CLE-00`) | a satellite agent's reports landed in the satellite's own `CLE-00` dir | **FIXED by N1**: `--to orchestrator` resolves to the orch fleet-lease holder (`lease.orch`), relayed when it is on the other machine; the seed prompt uses it | CLE-77919 |
| O5 | dispatch lease | local `/proc` liveness check | being moved to the hub: `fleet_leases` (0094) | CLE-77911 |
| O6 | dispatch post-drop dir `$SPOOL_ROOT/dispatch/posts` | local | must follow the lease holder | CLE-77911 |
| O7 | unanswered sweep | local state, but reads the hub DB | **BROKEN** if installed on both machines: the same nags go out twice | CLE-77911 (gate on the lease holder) |
| O8 | gap feed | reads the local `/var/spool-hub/agents/<id>.json`, so a dispatcher on the other machine shows as a GAP | **BROKEN** across machines | CLE-77911 (read the hub roster) |
| O9 | desk-reconcile cron | its header says "It runs on ONE box". Seat up/retire is per machine | **SAFE** with own box ids. Its side-effect steps (dispatch tick, welcome, responder sweep) need the lease gate | CLE-77911 |
| O10 | lobby welcome ledger `<state>/welcome/...` | local claim file | **BROKEN** if a greeter is set on both machines: the same person is greeted twice | CLE-77911 (lease gate) |
| O11 | mirror hooks (036), `SPOOL_POKE` sidecar, tmux and notify paths | per machine (local glob, local socket) | **SAFE** with own box ids | — |
| O12 | box.env written by the satellite setup | — | the satellite must set `SPOOL_DESK_BOX` + `SPOOL_AGENT_ID_RANGE` (+ `SPOOL_AGENT_USER`) | CLE-77912 |

### 2.3 Git and deploys

| # | what | verdict |
|---|---|---|
| G1 | each machine has its own clone and worktrees (`satellite-bootstrap.func.sh`), and pushes go `HEAD:master` with the fetch + rebase + `merge-base --is-ancestor` loop | **SAFE**: the git remote is the lock, and trunk stays linear |
| G2 | the version tag is claimed by pushing it (`do_release_version`), and CI has its own concurrency groups | **SAFE**: the remote is the lock |
| G3 | pre-push green cache `~/.cache/csi-spl/pre-push.*` | **SAFE**, per machine (it just re-runs more often) |
| G4 | `git worktree list` is the "who owns what" map every brief tells agents to read | **FIXED by N2**: it saw one machine's lanes only. The fleet-wide lane map on the hub (rdb `0096_fleet_lanes`, `spool lane`) has one row per agent `<ID>@<box>` with repo, branch, scope, files, topic and state. The spawn writes it, exit-clean sets it done, and the seed prompt's scope check and `/spawn-an-agent` read it (`lane-map.sh`, `do_spl_lane_map`; `--check` exits 3 on an owned path). `lane-map.tst.sh` covers two simulated machines; its control shows the local-only map is blind |

### 2.4 Operations only the home box can run

| # | what | verdict |
|---|---|---|
| P1 | the tenant root key (`ROOT_KEY_JSON`), needed for a box's first pin | **SAFE without moving it**: `do_spl_desk_pin` admin mode (`BOX_PUBKEY` + `ROOT_KEY_JSON`) pins the satellite's public key FROM the home box. The root key never leaves it |
| P2 | per-env SA keys, GitHub token | copied by `do_satellite_creds_push` (057) |
| P3 | Cloud SQL proxy ports | per machine |
| P4 | the operator role of the orchestrator (prd mutations, owner-gated) | follows the fleet lease's orchestrator role. The owner's go is still per call |

## 3. The target model

### 3.0 Naming (owner, t1 2efb3e78)

> "so let's change the naming convention of the sessions names to be
> CLE-<<id>>@<<box> where box shold be preferably a 3 letter ... aka the new
> boxname should be just sat"
>
> "let's establish the rule that the 001 , 002 and 003 id's will "special" for
> now for the orchestrator and for the master and the fail-over dispatchers"

| thing | format | where it is enforced |
|---|---|---|
| an agent, everywhere (address, tmux window, claude `--name`, lease holder) | `<ID>@<box>`, e.g. `CLE-002@sat` | windows/sessions: `spool_decorate`, `an_decorate`, `agent-identity.py want_name` (F5); lease: rdb 0095 (CLE-77911); WUI commands: F3 |
| `<ID>` | `^[A-Z]{2,4}-[0-9]+$`, unchanged | `msg.ValidID`, `spool_valid_id` |
| `<box>` | the machine's desk box id, `^[a-z0-9][a-z0-9-]{0,31}$`, 3 letters preferred, from box.env `SPOOL_DESK_BOX` | `spl_desk_box_default` (F2), `box-config.sh` |
| reserved on every box | `CLE-001` orchestrator, `CLE-002` master dispatcher, `CLE-003` failover | the allocator never hands out 1-3 (F4); they are only `--claim`ed |

Every parser reads both `<ID>@<box>` and the older `<tag>: <ID>` during the
switch. `SPOOL_NAME_STYLE=colon` writes the old shape.

The owner's point, "the cle<<n>> will never have collision", holds for the hub:
it routes on `(box, ID)`. A send or WUI command that NAMES the box (`--to-box`,
`to_box`, `@ID@box`) reaches exactly that agent (`TestWUIDispatchToBoxPinsTheSameIDOnTwoBoxes`).
What still keys on the bare id:
1. a send or WUI `@ID` command WITHOUT a box. When the id is live on two
   boxes it is refused with `ambiguous_to_box` (409), never delivered to the
   wrong agent. The reserved ids 001-003 are such ids by design, so commands
   to them must name the box.
2. each machine's local spool dirs (`$SPOOL_ROOT/<ID>`). These are per
   machine, so a bare id is enough there.
Lane ids therefore keep the per-machine band (F1) during the switch, so that
older tools sending a bare id still find exactly one agent.

### 3.1 One machine = one box id per tenant

- Each machine answers from its own desk box. During the switch the home box
  keeps its hub box `box-desk`, so no live DM URL, pin or seat changes; its
  3-letter name goes into its own box.env at migration step M5. The
  satellite's box is `sat`. It is set once in the machine's box.env
  (`SPOOL_DESK_BOX`, F2), with its own key minted on the satellite and pinned
  from the home box (P1).
- A box id is never live on two machines at once. It moves only as a serial
  takeover (3.5).

### 3.2 Per-machine vs hub-shared

| per machine (local disk) | shared (the hub) |
|---|---|
| `$SPOOL_ROOT`, registry.tsv, the identity map `agents/`, box.env | messages, deliveries, queue (per box id) |
| desk state + box keys (`~/.local/share/<org>-<app>/cloud/<env>/desk/<tenant>/<box>`) | pins, roster, presence, box operators |
| tmux, notifier, mirror hooks, the hub-run sidecar | fleet leases (0094): orchestrator, dispatcher, and every cron that has a side effect |
| clones, worktrees, the pre-push cache | git trunk, version tags |

### 3.3 Agent ids

Every machine allocates fresh ids inside its own **band**
(`SPOOL_AGENT_ID_RANGE`, F1). Bands are written in this spec and are disjoint:

| machine | band | note |
|---|---|---|
| home box | `1-99999` | the current floor is in the 77000s; raise it here when it nears 99999 |
| satellite | `100000-199999` | |
| next machine | `200000-299999` | one line per machine |

The role ids `CLE-001`/`002`/`003` exist on EVERY box (section 3.0). The
allocator never hands out the numbers 1-3; the role ids are claimed
explicitly (`--claim`), and an explicit claim outside the band works but warns.
The fleet lease decides which machine's trio acts.

A hub-issued id (one counter per tenant) was considered and not chosen. It
needs a hub round trip on every spawn, and a spawn while the hub is down would
fail. Bands keep spawning offline and need no new table.

### 3.4 One post, handled once fleet-wide

1. A DM / `agent@box` send goes to exactly one box (H5). A WUI command names
   the box with the frame's `to_box` or an `@ID@box` mention (F3).
2. An unheard human post goes to ONE responder across all boxes (H6).
3. A channel post fans out per seated box (H7). So the rule is that a role
   which ACTS on posts (orchestrator, dispatcher, greeter, sweeps) is
   seated and run **only on the machine holding that role's fleet lease**.
   Lane agents are seated only on their own machine's box.
4. Crons with side effects (O7-O10) run their step only where
   `fleet_leases` names this machine as the holder. Every machine still runs
   its own seat reconcile.

### 3.5 Handover

- **A role** (orchestrator, dispatcher): moves by the fleet lease (CAS on
  `gen`, hub clock). The new holder seats the role's agent on its own box. The
  old holder's loop sees that it lost and stops acting.
- **A lane agent** moving machines: on the new machine, `--claim <its id>`
  (outside the band, so it warns, by design) and `--resume`. Seat it on the new
  box, then `do_spl_desk_down` it on the old one. Messages already queued for
  `<id>@<old box>` stay with the old box until that box drains them, so finish
  the move BEFORE retiring the old box.
- **A whole box id** (retiring the home box while keeping `box-desk`):
  stop the old machine's sidecar FIRST, copy the desk key, then the new machine
  says hello. The queue drains to it, and nothing is lost or doubled.
  `TestBoxTakeoverMidMessageLosesNothing` proves this, including a takeover
  while the old socket is still live (it gets 4409). Two live holders are what
  H1 forbids: never run both sidecars.

### 3.6 Migration: satellite primary, home box retired

| step | what | gate |
|---|---|---|
| M0 | now: the home box is primary; the satellite runs the standby trio under the fleet lease | CLE-77911 |
| M1 | satellite box.env: `SPOOL_DESK_BOX=sat`, `SPOOL_AGENT_ID_RANGE=100000-199999`, `SPOOL_AGENT_USER`; key minted on the satellite; pin from the home box via `do_spl_desk_pin` admin mode, per tenant and env; box operator grant | box.env: done by CLE-77912 (`0fda3b8f`, playbook role 08); owner go for each prd pin |
| M2 | the side-effect crons are gated on the lease holder (O6-O10); new lanes spawn on the satellite | CLE-77911 |
| M3 | cross-machine reports via the hub (O3, O4: done, N1), plus the lane map on the hub (G4) | N1 done (CLE-77919); N2 open. Live needs M1 (the satellite desk pinned) and `SPOOL_FLEET_ENV`/`SPOOL_FLEET_TENANT` (or `LEASE_ENV`/`LEASE_TENANT`) on each machine |
| M4 | the roles flip: the fleet lease is handed to the satellite | owner go |
| M5 | home box retired: its lanes finish or move (3.5); then EITHER `box-desk` is taken over serially by the satellite, OR the home box re-seats under its own 3-letter box and `box-desk` is unpinned | owner choice |

## 4. Fixes made in this lane

| id | fix | commit | test |
|---|---|---|---|
| F1 | per-machine agent-id band `SPOOL_AGENT_ID_RANGE` (box.env); allocator floor, band full = exit 1, explicit claims outside the band warn | `d8905f7a` | `spawn-agents/tests/test-next-agent-id.sh` (two simulated machines: no common id; the control shows the collision without bands) |
| F2 | per-machine desk box `SPOOL_DESK_BOX` (box.env) is the default of every `DESK_BOX`/`AGENT_BOX` | `f7efacbf` | `spawn-agents/tests/test-desk-box-default.sh` |
| N1 | cross-machine sends and reports: unknown local id refused (`unknown_local_agent`, exit 3); `spool-send.sh` relays a non-local id via the desk sidecar + hub roster (`spool-fleet-relay.sh`); the receiving sidecar copies agent DMs into `SPOOL_FLEET_ROOT`; `--to orchestrator` = the orch lease holder. Details: `SPEC-spool-fleet-roles.md` 4.2 | CLE-77919 | `internal/hub/fleet_send_test.go` (two machines, both ways, reports while the lease flips), `internal/spool/fleet_test.go`, `spawn-agents/tests/test-fleet-send.sh` |
| F3 | a WUI command names its agent's box: frame `to_box` or `@ID@box` pins the route; a bare id on two boxes stays `ambiguous_to_box` | `d02b84d3` | `TestWUIDispatchToBoxPinsTheSameIDOnTwoBoxes` |
| F4 | the allocator never hands out 1-3 (reserved role ids) | `761ddac9` | `test-next-agent-id.sh` |
| F5 | windows and claude sessions are named `<ID>@<box>`; every parser reads both shapes; `SPOOL_NAME_STYLE=colon` | `94ced000` | `test-agent-top.sh`, `test-restore.sh`, `test-spawn-window-riname.sh`, `test-tmux-close-window.sh`, `test-agent-identity*.sh` |
| T1 | hub tests for the one-to-many cases | `d5b5a8bd` | `internal/hub/multimachine_test.go`: two machines seated in one tenant, routed once; takeover mid-message loses nothing (memory, `-race` x15, Postgres x5) |
| N2 | the fleet-wide lane map (G4): hub table + `lane` frame + `spool lane`; `do_spl_lane_map` (read, joined with this machine's worktrees; `LANE_CHECK` = the collision check) and `do_spl_lane_put` (spawn: live, exit-clean: done); the seed prompt SCOPE block and the spawn commands read it instead of `git worktree list`. Shared once the machine has a fleet (`LANE_FLEET`, else lease.conf `LEASE_FLEET` / `LEASE_ENV` / `LEASE_TENANT`); without one it is the local worktrees | CLE-77920 `6f9f50ac` (hub) + the orc commit | `internal/hub/box_lane_test.go`, `internal/store/fleet_lane_test.go` (memory + Postgres), `csi-spl-orc/src/bash/tests/lane-map.tst.sh`, `spawn-agents/tests/test-spawn-dry-run.sh` |

## 5. Out of scope

- Changing the hub's one-socket-per-box rule (H1). It is the right rule. The
  fix is to never share a box id, not to fan out to two sockets.
- Any GCP or prd mutation (pins, operator grants, lease handover): owner go per call.
