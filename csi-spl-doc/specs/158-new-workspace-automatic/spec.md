# Spec 158: a new workspace works automatically

**Feature ID**: `158-new-workspace-automatic` · **Status**: Draft v0.5 (for R7) ·
**Epic**: SPL-2398 · **Issue**: SPL-3504 · **Created**: 2026-10-26 · **Lead**: c-456 ·
**Placement slug**: `c002-s158-new-workspace-automatic`

Related: [spec 074 operator workspace](../074-operator-workspace/),
[spec 108 workspace-owned boxes](../108-workspace-owned-boxes/spec.md),
[fleet roles](../../doc/md/SPEC-spool-fleet-roles.md) (the 3-minute rule).

## 1. The owner's order

Owner HUM-10, typed in an orchestrator (c-001) terminal on 2026-10-26 at about 09:2xZ
(relayed in c-001 msgs 1a1ff276, 150a1232 and 52ca9ef6),
verbatim: "WHEN THERE IS A NEW WORKSPACE EVERYTHING MUST WORK AUTOMATICALLY".

The cause: members posted in a prd workspace from 08:57Z, and no agent
could answer because no agent was seated there. The sweep did escalate it
(ESC to c-001 at 09:11Z, msg 80249346), but no seat existed to answer.

Corrected in v0.3 (c-001 msg b8845a1e, re-measured in M11-M12): the
workspace was created on 2026-09-26 by the shell action, and its create
JSON, the root key included, WAS kept in one box's tenant store. Nothing
read it. A desk is seated only when someone runs `do_spl_desk_pin` /
`do_spl_desk_up` with that file by hand, and in a month nobody did. On the
day, two orchestrators searched for the key and missed the file. c-001
then seated the workspace by hand with it, at about 10:4xZ. So the failure
is not a lost key. It is that **nothing seats the fleet in a workspace
automatically**, whether or not a key exists.

**No human step.** No root-key download, no join token by hand, no
`do_spl_desk_up` typed for that workspace.

Follow-up, folded in v0.5: HUM-10 msg e0510945, in the item-01 discussion
(relayed c-002 msg a60d93e8), verbatim: "also make sure the existing
workspaces get the same configs and stay "up-to-date" with the latest
versoin". Rows R5 and R6, section 7.

## 2. What happens today (measured on tree 46fe77794, 2026-10-26)

Paths are relative to the repo root. `hub` = `csi-spl-api/src/go/spool-hub-api/internal/hub`,
`orc/run` = `csi-spl-orc/src/bash/run`.

| # | fact | where |
|---|---|---|
| M1 | A workspace is created by an admin of the operator workspace: `POST /v1/operator/workspaces`, which the WUI operator pane calls. The shell twin is `do_spl_tenant_create`. | `hub/operator_workspaces.go:280-330`, `orc/run/spl-tenant-create.func.sh` |
| M2 | With no `root_pubkey` in the request, the hub generates a root key pair. The private half is in the 201 body ONCE and is "never stored or logged". The shell action prints it once on stdout. | `hub/operator_workspaces.go:256-262, 283-285, 318-320` |
| M3 | A desk is seated by `do_spl_desk_up` (ENV, TENANT_ID, DESK_AGENT). Its first run needs `ROOT_KEY_JSON`, the create JSON at mode 0600, or `SPOOL_JOIN_TOKEN`. With neither, an unpinned box exits 3 and prints the admin command. Later runs reuse `<state>/desk/<ws>/<box>/pinned`. | `orc/run/spl-desk-up.func.sh:30-41, 216-264` |
| M4 | A spec 108 join token is minted only by a member holding `agents.join` in that workspace (Admin only). `box_join_enabled` defaults to false. A shared box (the fleet desks) is refused anyway: 403 `box_mode_shared`. No operator route mints for another workspace. | `hub/join_tokens.go:129-137, 183, 370-379`; rdb `0170_box_join_switch.sql:32` |
| M5 | The set of workspaces a box serves is the desk dirs on its disk. The reconcile cron re-ups `$SPL_STATE_DIR/desk/*/` with `DESK_SEATED_ONLY=1`, and nothing lists the hub's workspaces to find a new one. | `orc/run/spl-desk-up-tenants.func.sh:36-42`; `csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh:82, 456` |
| M6 | A box announce puts no agent into any channel. Agents join a channel by invite (`POST /v1/channels/{channel}/agents`, or `do_spl_channel_agent_add_op`). The one automatic add, `do_spl_dispatch_tick`, subscribes the role seats to every channel, but only in workspaces with a pinned desk dir and only where the roster already holds the seat. | `hub/channel_members.go:343-346, 399`; `orc/run/spl-dispatch-subscribe.func.sh:3-28` |
| M7 | The unanswered sweep reads EVERY workspace of the env in one operator-scope query. There is no list: test workspaces are skipped by `SWEEP_SKIP_TENANTS` / `SWEEP_SKIP_RE`. It runs every minute. | `orc/run/spl-unanswered-sweep.func.sh:8-9, 351-365`; `spl-unanswered-sweep-install-cron.func.sh:40-64` |
| M8 | Nothing alarms on a workspace that has member posts and 0 agent seats. The delivery probe reads a workspace with no seat on this machine as `remote`, which never alerts. `store.CountBots` counts agent roster rows, but no route or action calls it. | `orc/run/spl-workspace-delivery-probe.func.sh:18-23`; `internal/store/seats_postgres.go:64` |
| M9 | `spool hub-pin --root-key <path>`, where no file is at that path, said "the --root-key text is not a base64 ed25519 private key (nor a readable file)". A missing file falls into the key-text branch. | `internal/action/pin.go:66-88` |
| M10 | `agents.join` is in the Admin role only, by design: `BizOwner` (the workspace owner) lacks it and `withAgents()` adds only DM/start/mention/post/reply. rdb 0119 seeds `('admin', 'agents.join')` only, so code and DB agree. A biz_owner who is not admin gets no join-token panel (WUI `mayJoin = canJoinAgents`) and cannot seat agents. On 2026-10-26 the first-case workspace was unblocked by hand, on the owner's order: `box_join_enabled` set on, and the owner made admin there (c-001 msgs e96aa466, d2815aa9). | `internal/rbac/rbac.go:217-225`; rdb `0119_agent_join_tokens.sql:66-67` |
| M11 | Measured on ONE box (n=1; the other box not measured), 2026-10-26: its tenant store held 12 create JSONs (one per workspace, mode 0600, the box user's). The same box had 11 desk dirs. 4 workspaces with a kept key had no desk (5 before the hand seating of the day), and 3 workspaces with a desk had no kept key. The hub and WUI create keeps no key at all (M2); a file exists only when an operator saved the shell action's output there. | `ls -l` of the store and of `<state>/desk/` (names and modes only, never contents) |
| M12 | `do_spl_desk_up` and `do_spl_desk_pin` never look in the tenant store: the key comes only from `ROOT_KEY_JSON` given by hand. `spl_newest_tenant_key`, the one reader of the store, is used only by e2e and rebox actions. | `grep -l spl_newest_tenant_key csi-spl-orc/src/bash/run/*` -> `spl-invite-e2e`, `spl-desk-rebox`, `spl-m3-e2e` |
| M13 | The dispatcher and failover briefs list "a desk in every workspace: {TENANTS}", rendered ONCE by `do_spl_dispatch_setup` from `DISPATCH_TENANTS` (the pinned desk dirs at that moment). A workspace seated later is not in the list. On 2026-10-26, after the hand seating, the failover brief still listed 8 workspaces without the new one, and the failover seat did not see the owner's posts there (c-003 msg 5a9f8050 via c-001 msg 896823ae, n=1). | `csi-spl-orc/src/bash/features/dispatch/brief-dispatcher.tpl.md:54`; `csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh:305-309` |
| M14 | Existing workspaces get nothing of the above: the 4.2 migration leaves `fleet_seating` false on every existing row, and only a hand switch per workspace would change it. Each box already reports its spool binary's version in its host report (the spool entry of `Runtimes`). The hub serves it (`hub/box_facts.go`, `hub/view.go`) and the WUI box pages display it (`MonitoringBoxFacts.vue`, `BoxStatsPane.vue`), but nothing compares it with the newest release. Nothing compares a workspace's seats, channel members or dispatcher listing with what a new workspace gets. | `internal/hubclient/host.go:133-135`; section 7.3 of v0.4 |

## 3. Requirements (each one a testable row)

| id | requirement | test that proves it |
|---|---|---|
| R1 | Within 5 minutes of a workspace's create, the fleet's desks are seated in it: every desk box listed for fleet seating has a live pin and its role seats are in the roster. | e2e on dev: create a workspace through the operator route, then poll `GET /v1/view/roster` until the role seats are listed (5 min budget). |
| R2 | The fleet agents are members of every channel of that workspace, including channels created later. | Same e2e: the role seats are in `#general`'s members, and in a channel created after the seating within one tick. |
| R3 | The unanswered sweep covers the new workspace, and so do the dispatcher and failover seats: their brief and their desks follow a new workspace with no re-setup. | The sweep part is already true (M7); its unit test proves a new tenant id appears in the rows with no list change. The seats part is row T10b (M13). |
| R4 | A member's first post gets a first agent answer within the 3-minute rule. | e2e on dev: an invited member posts, and an agent message lands in that topic within 180 s. |
| R5 | Every existing workspace (not a test one, not suspended or archived) gets the same fleet seating and configuration as a new one, the baseline of section 7.1, with no step per workspace. | orc test of the backfill (row T12): three planted workspaces with `fleet_seating` false are switched in one run, and a test workspace is skipped. Control: a second run changes nothing. On dev: the drift check (R6) reports 0 workspaces off the baseline. |
| R6 | A recurring check keeps every workspace on the baseline and every fleet desk on the latest released spool version. It repairs the drift its box owns, and the rest reaches the orchestrator as a blocker within 15 minutes, repeated hourly while it lasts. | orc test with planted drift (a role seat missing from one channel, a desk on an older version, `fleet_seating` off on a non-test workspace): each one is repaired or reported. Red control: the same rows on the baseline send nothing. |
| A | Nothing human is needed to seat the fleet, whether or not a root key was kept (M11-M12). The end state needs no root key (section 4). No root key is stored anywhere new. | Hub unit tests of 4.2 and 4.3; a grep gate: no root private key in any new table, log line or file. |
| B | A workspace with member posts and 0 agent seats reaches the orchestrator as a blocker within 5 minutes, and repeats hourly while it lasts. | `orc` test with a planted row set (red control: the same rows with 1 seat send nothing). |
| C | `--root-key <path>` with no file there says in plain words that the file does not exist, without echoing the value. | `internal/action/rootkey_test.go` `TestReadRootKeyMissingFile` (red on the old code, shown in the commit). |

## 4. Design for A: fleet seating, with no root key

### 4.1 Options

| option | how | verdict |
|---|---|---|
| A-keep | The create writes the root private key to the box operator's tenant store (0600). | **Rejected.** The create runs on Cloud Run or in the browser, not on a box, so the key would have to travel to a box (a new secret channel) or sit in the hub DB. Both are new places a root key lives. |
| A-store | The desk cron seats every workspace whose create JSON is already in this box's tenant store and has no desk dir yet (`do_spl_desk_store_seat`, reusing `spl_newest_tenant_key` and `do_spl_desk_up`). | **Interim only (row T3b), on its own GO.** It would have seated the 2026-10-26 workspace a month early, with keys that already sit on the box (no new copy). It cannot seat a WUI-created workspace (no key kept, M2), so it is not the end state. On prd its first run seats the 4 kept-key workspaces with no desk (M11): a seat change, so its first `DRY_RUN=0` on prd is c-001's, with the owner's go. |
| A-token | The operator route mints a spec 108 join token for the new workspace and hands it to the fleet. | **Rejected.** It still moves a secret to the boxes, and spec 108 refuses shared boxes by design (M4). |
| **A-fleet** | The hub trusts the fleet desk boxes the operator workspace has already pinned. A listed desk box proves itself with its operator-workspace box key and enrols a fresh per-workspace key into every workspace marked for fleet seating. | **Chosen.** No root key moves or is kept. The trust already exists today: the same fleet desks serve every workspace. |

### 4.2 Hub (A-fleet)

1. **rdb**: `tenants.fleet_seating boolean NOT NULL DEFAULT false`. Every
   workspace create sets it to true unless told false: the insert itself
   (`store.CreateTenant`, `Tenant.FleetSeatingOff`) writes it, so the
   operator route (`fleet_seating` in the request, default true),
   `spool hub-tenant` / `do_spl_tenant_create` (`--fleet-seating`, default
   true) and any later create path get it with no second write that could
   fail on its own. The operator can flip it with
   `PATCH /v1/operator/workspaces/{id}` (audited), as with `box_join_enabled`.
   A workspace's own admin cannot write it.

   What was wrong in the first build of T5 (SPL-4295): only the operator
   route wrote the switch, in a second write after the insert whose failure
   was only logged. a prd workspace was created on 2026-10-29 13:54Z by
   `do_spl_tenant_create`, which inserts through `spool hub-tenant` and never
   calls that route (no `operator_audit` create row for it on prd), so it
   kept the column default false.
2. **rdb**: `fleet_desk_boxes (box_id, added_by, added_at)`. These are the
   desk boxes of the operator workspace that may self-enrol. The operator
   manages them through `PUT/DELETE /v1/operator/fleet-desks/{box}` and the
   twin action `do_spl_fleet_desk_box`. A box can be listed only while it
   holds a live pin in the operator workspace.
3. **`GET /v1/fleet/workspaces`**: signed by a listed desk box's
   operator-workspace key. It lists the workspaces with `fleet_seating` true
   that are not suspended or archived, and says whether this box is already
   pinned in each one.
4. **`POST /v1/fleet/enrol`** `{tenant, box_id, pubkey, ts, sig_op, sig_new}`:
   `sig_op` is made by the operator-workspace box key and `sig_new` by the new
   key, each over the same payload, which proves possession. The hub pins
   `pubkey` in `tenant` as `box_id` with `box_mode = 'fleet'`. The usual
   rules hold: the live pubkey is unique (spec 108 3.2), `ts` is later than
   the last pin op, and a revoked pin is never re-enrolled until the operator
   lists the box again. One `operator_audit` row is written.
5. Revoking a box's pin in the operator workspace, or removing it from
   `fleet_desk_boxes`, stops new enrolments. Its pins elsewhere stay until
   they are revoked (spec 108 3.7).

### 4.3 Box (A-fleet)

1. `spool fleet-workspaces` and `spool fleet-enrol --tenant <ws>` are signed
   with the operator-workspace desk key the box already holds.
2. `do_spl_desk_fleet_seat` (orc, new) runs in the desk-reconcile cron. It
   lists the fleet workspaces, and for each one with no desk dir on this box
   it runs `do_spl_desk_up` in a new `DESK_PIN_MODE=fleet`. The desk makes
   its per-workspace key and enrols it through `spool fleet-enrol`, with no
   `ROOT_KEY_JSON` and no token, then seats the role seats.
3. The dispatch tick already takes `DISPATCH_TENANTS` from the pinned desk
   dirs (M6), so the role seats join every channel of the new workspace on
   the next tick. That gives R2 with no new code: the tests in rows T9-T10
   prove it.
3a. The dispatcher and failover briefs stop carrying a frozen list (M13).
   `{TENANTS}` becomes a command the seat runs,
   `./run -a do_spl_dispatch_tenants` (the same `DISPATCH_TENANTS` the tick
   uses, printed). `do_spl_desk_fleet_seat` seats every role seat (the
   orchestrator, master and failover dispatchers) in the new workspace, not
   only the first one. Row T10b. The list is the fleet's workspaces, not
   this box's desk dirs: `DISPATCH_TENANTS` today is the box's own desks,
   so a re-run of the setup on a box without the new desk still leaves it
   out (measured on the second box, n=1: setup rc 0, the new workspace
   listed 0 times). `do_spl_dispatch_tenants` reads `GET /v1/fleet/workspaces`
   (row T7) and falls back to the desk dirs only when the hub is unreachable.
4. One box enrols a workspace's role seats and the rest stand by, per the
   fleet lease (spec 101). The orchestrator and dispatch seats follow the
   lease holder's box.

### 4.4 Threat model (A-fleet)

| threat | answer |
|---|---|
| A fleet desk box key is stolen. | The thief can enrol a key into every fleet-seated workspace. This is no wider than today, where that box already serves them all. Revoking the box's operator-workspace pin plus removing it from `fleet_desk_boxes` stops new enrolments (4.2.5). Every enrolment writes an audit row. |
| A customer wants no fleet in its workspace. | `fleet_seating` false (an operator PATCH). Spec 108's dedicated boxes are unchanged. |
| A workspace admin turns fleet seating on for itself, or lists a box. | No workspace route writes either; operator admin only (spec 074). |
| Replay of an enrol request. | `ts` must be later than the last pin op (004 pin semantics section 5); `sig_new` binds the key. |
| Root key exposure. | None new: A-fleet never reads, stores or moves a root key. The create still answers it once, for a workspace's own admin to keep. The interim A-store reads keys already in the box store (0600, box user) through `do_spl_desk_up`'s existing path (a 0600 mktemp copy, deleted after the pin) and writes no new copy. |

### 4.5 Seating with neither switch (M4, M10)

A-fleet does not use spec 108's join path. It needs neither `agents.join`
in any member's role nor `box_join_enabled` on the workspace: the
enrolment is authorised by the box's operator-workspace pin plus
`fleet_seating` (4.2), which the create sets. So a workspace whose owner
is biz_owner only, and whose `box_join_enabled` is false (the default),
is still seated with no human step. The hand fix of 2026-10-26 (M10) is
then not needed for the next workspace.

Kept as is, deliberately: `agents.join` stays admin-only, and
`box_join_enabled` keeps its default false. Both belong to spec 108's
workspace-owned boxes, which the owner made a switched, paid feature
(spec 108 3.8). Whether a TenantOwner should also get `agents.join` is a
spec 108 permission question, not needed for R1-R4. It is listed for the
dispatcher to route, with the built default "no change".

Test (row T7): enrolment into a workspace with `box_join_enabled` false
and no member holding `agents.join` succeeds. Control: the same
workspace with `fleet_seating` false is refused.

## 5. Design for B: the 0-seat alarm

`do_spl_workspace_seat_alarm` (orc, new) runs from the unanswered sweep's
cron script, so it runs every minute, before the sweep. It makes one
read-only operator-scope query: each workspace, not a test one, not suspended
or archived, with at least one `HUM-*` post in the last `SEAT_ALARM_DAYS`
(default 7) and no roster row whose `agent_id` is not `HUM-*`. Each such
workspace is one row in ONE spool blocker to the orchestrator
(`--to orchestrator`, task `seat-alarm`; spool-send journals it as an ask).
A row repeats only when it is new, or after `SEAT_ALARM_REALERT` (default
3600 s). The memory file is `<lease dir>/seat-alarm.state`. In fleet mode
only the lease holder's machine sends, as the sweep does. `DRY_RUN=1` (the
default) prints the plan only.

## 6. Design for C: a plain error

`ReadRootKey` (`internal/action/pin.go`): a value that is not a valid key and
looks like a path says "the root key file does not exist: no file at the
--root-key path. Save the workspace root key there (mode 0600), or pass the
key text, or - to read it from stdin". A value looks like a path when it
starts with `/`, `~`, `./` or `../`, or holds a character outside the base64
alphabet. A directory says it is a directory. The value is never echoed.

## 7. Design for R5 and R6: existing workspaces and drift

### 7.1 The baseline

The baseline is one list in code, `spl_workspace_baseline` (orc). The
create path, the backfill and the drift check all read it, so they cannot
disagree about what a seated workspace has:

1. Hub: `fleet_seating` true, plus the create-time seeds (the public notice,
   rdb 0173).
2. Each fleet desk box has a desk dir with a live pin (R1), and the role
   seats are in the roster.
3. The role seats are members of every channel (R2).
4. The workspace is printed by `do_spl_dispatch_tenants` (R3, row T10b).
5. Each fleet desk box runs the latest released spool binary: the version
   in its host report equals the newest release. Row T16 first measures
   what that field holds today and which release it should equal; the
   version check is built only on that measurement.

A row added to the baseline later applies to every workspace on the next
drift run. That is how "stay up-to-date" holds for config added after
this spec.

### 7.2 Backfill (R5)

`do_spl_fleet_seating_switch ALL=1` (row T12) sets `fleet_seating` true for
every workspace except test, suspended and archived ones. It uses the
sweep's skip rule (`SWEEP_SKIP_TENANTS` / `SWEEP_SKIP_RE`). The desk cron
(row T9) then seats each one, exactly as for a new workspace. Dry run by
default. On prd it is a member/seat change: c-001 runs it once, after 4.3
is on prd, with the owner's go for that run. The owner's order e0510945 is
the policy for all of them. A workspace created after that needs nothing
(row T5 defaults `fleet_seating` to true).

### 7.3 Drift check (R6)

`do_spl_workspace_drift` (orc, new) runs from the desk-reconcile cron every
5 minutes. It is read-only except for the repairs below. For each
workspace from `GET /v1/fleet/workspaces`, and each baseline item:

- What this box owns, it repairs: its own missing desk or pin is re-seated
  through row T9, and a missing channel membership through the dispatch
  tick's subscribe.
- Everything else is reported: `fleet_seating` off on a non-test
  workspace, another box's missing seat, a desk box on an older spool
  version, and a repair that did not hold on the next run. The check never
  restarts a desk on another box and never flips `fleet_seating` itself:
  that is the backfill's named action.

Reports work as in row B (section 5): one spool blocker per run to the
orchestrator (task `workspace-drift`), each row repeated only when it is
new or after an hour, sent only from the lease holder's machine,
`DRY_RUN=1` by default.

## 8. Rollout

1. B and C land first, small, each through R7, the GO, land, then dev AND prd.
2. A lands in rows 4.2 then 4.3, migration first on dev and prd (the DDL-first
   rule), each through R7.
3. **Existing workspaces.** The migration leaves `fleet_seating` false for
   every existing row. The backfill (section 7.2) turns it on for all of
   them in one named run. On prd that is a member/seat change: c-001 runs
   it with the owner's go, never a lane. The drift check (section 7.3) is
   switched on with it and keeps every workspace on the baseline after
   that.
4. **First case: the workspace of 2026-10-26.** Once 4.3 is on prd, c-001 runs the switch for
   that workspace with the owner's go, and the desk cron seats it with no other
   step. Until then it stays blocked on the owner's root key (c-001's ask
   0139e006).
5. The queued DevOps guide row on workspace root keys (ask ce366e73) stays
   disjoint: it documents the manual root-key path, which A-fleet does not
   remove. This lane adds one guide section for fleet seating when 4.3 lands.

## 9. Not in scope

- Spec 108 dedicated boxes and their join tokens (unchanged).
- Agent quality of the first answer: R4 measures time to the first agent
  message, not its content.

