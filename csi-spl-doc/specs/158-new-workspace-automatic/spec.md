# Spec 158: a new workspace works automatically

**Feature ID**: `158-new-workspace-automatic` · **Status**: Draft v0.6 (for R7) ·
**Epic**: SPL-2398 · **Issue**: SPL-3504, v0.6 SPL-4990 · **Created**: 2026-10-26 · **Lead**: c-456 ·
**Placement slug**: `c002-s158-new-workspace-automatic`

v0.6 adds section 10: a workspace created in the UI reaches usable with no
agent step (the web address, the box-wui pin, the seats, the proof).

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

## 10. Amendment v0.6: created in the UI, usable with no agent step

Owner HUM-10, t1 topic d6c53e6f, msg 72a94e67, 2026-11-07, verbatim, the
workspace name replaced: "I created manually via the ui the `<drill workspace>`
workspace ... what is the status for it ... want to ensure that workspaces
could be created up till usability without any agents interventions".

Two real cases, by placeholder (a hidden workspace is never named here):
`<drill workspace>`, the owner's live drill, read only; and `<older gap
workspace>`, an older workspace with the same pin gap.

### 10.1 Usable, as testable rows

| id | usable means | test |
|---|---|---|
| U1 | The create answers 201 and the first admin's invite is stored and mailed. | The 201 body's `invite.status` is `invited` and its `invite.mail` is neither `not_sent`, `not_configured` nor `send_failed`. |
| U2 | That person accepts the invite. | `tenant_invites.accepted_at` is set. |
| U3 | They log in on the web address `https://<workspace>.<fqdn>`, with no hop to another host. | `tenant_hosts.status` = `ready`, and a browser signs in there. Target 60 min from the create (unmeasured: the WUI text says 15-30 min; row E1 measures it, then this target is set). |
| U4 | Docs works on that address. | The workspace's Docs answers 200, not 503 (its 052 bucket exists). |
| U5 | They post, and the post is signed for the boxes. | The stored post has a non-empty `env_sig`, so a box can receive it. |
| U6 | An agent answers. | An agent message lands in that topic within 180 s of the post (R4). Seats arrive within R1's 5 minutes of the create. |
| U7 | A stuck step shows with no agent looking. | The operator page shows each of U1..U6's states for the workspace (row V2). |

### 10.2 What was measured (2026-11-07, 13:5xZ)

Read only; nothing in a live workspace changed. Tree: origin/master
`a27e25136`. n=1 per row unless it says otherwise.

| # | fact | where |
|---|---|---|
| M15 | `<drill workspace>`: invite stored about 11:19Z (its expiry less 7 days), 1 mail, accepted 11:44Z; one admin member. U1 and U2 hold. | `do_spl_hub_member_list` |
| M16 | `<drill workspace>`: no host. `tenant_hosts` stayed `pending` with no detail, then went `failed` once a run got past M18. U3 and U4 fail: the plan of that run still had its docs bucket to create. | `do_spl_tenant_host_reconcile` (dry run); job log |
| M17 | wf 40 is enabled and on schedule, against `private-overlay.md` section 5, which says it is disabled. All 10 finished runs from 11:23Z to 13:38Z failed; the 5 before them were green. | `gh workflow list`; `gh run list` |
| M18 | One new hidden workspace fails the whole env's run, confirmed in code. `spl_th_token ... new` refuses it in CI. `spl_th_reconcile_apply` runs `spl_th_tenant_set ... \|\| return 1` in its add loop, before the render. So every other add and every remove of that env waits, and that path marks no row, so its detail stays empty. Rows that only need a check run first and are not held. dev and prd do not hold each other (`fail-fast: false`). What moved it: the overlay line was written on this box at 13:24Z and the secret at 13:25Z; by whom is not read. | `spl-tenant-host-provision.func.sh:166-180`; `spl-tenant-host-reconcile.func.sh:89-118`; `gh secret list`; the overlay's mtime |
| M19 | **A second stop, not known before this read:** with the overlay line in place, the prd run pushed its cnf (`a27e25136`), and the apply of the first step was REFUSED by the order gate: `the dev plan of 052-gcs-workspace-docs failed, so dev's state is unknown`. The workflow writes the dev key only in the dev job (line 126), so the prd job likely cannot plan dev. **Likely, not proven:** the plan's own error is in a log file the job never prints. Since the gate landed (`aa7664339`, 10-15), every prd host but this one came from the box action: `git log --since=2026-10-15` -> 1 `cnf(024): prd` (this one), 4 `cnf(orc): prd tenant host`. So wf 40 may never have added a prd host under the gate. | job log; `40_tenant-host-reconcile.yml:126`; `check-dev-leads-prd.func.sh:45-52` |
| M20 | **The hidden slug reaches the wf 40 job log.** The prd job's log held the drill's slug on 3 lines in two failed runs, and on 5 in the run past the overlay (`reconcile: ... add [...]`, the FATAL, the plan's resource addresses, `tenant_hosts ... ->`). So it still prints with its line in the secret. The repo is public: `gh repo view` -> PUBLIC. An anonymous API read of the log answers 403, and of the run's metadata 200; I believe, unchecked, that any signed-in GitHub account can read the log. `private-overlay.md` section 5 made clean logs the condition for enabling the workflow. | `grep -c` on the job logs of 4 runs: 3 prd failures, 1 green run with 0 |
| M21 | Box-wui pin: prd 23 workspaces, 3 gaps: both real cases, each with 0 unsigned human posts in 7 days, and `system`, also 0. dev 28 workspaces, 23 gaps (their kinds not read). The other 20 prd workspaces hold the same hub key, so one key across workspaces is accepted. | `do_spl_check_box_wui_pins` |
| M22 | Only `do_spl_tenant_create` pins box-wui. The UI create does not, and no workflow or cron calls the pin (`grep` on `.github` and `csi-spl-orc/src/bash/scripts`: 0). Spec 014 2.2 has the tenant operator pin it with the root key. | `spl-tenant-create.func.sh:231-243`; `specs/014-*/contracts/wui-dispatch.md` |
| M23 | The hub's pin route needs the root signature, and accepts for box-wui only the hub's own key (`wui_key_mismatch`). What boxes read has no root signature to check: `wire.PinEntry` is the box id and the key (plus a sealing flag on the POST answer), so a box already trusts the hub's list. | `hub/rest.go:443-470`; `wire/wire.go:1130` |
| M24 | The paid checkout is a separate create: `paidTx` inserts into `tenants` with no `fleet_seating`, so it takes the column default false (rdb 0230). T5's "every create path" does not hold for it. Whether checkout is in use on prd: not read. | `store/payments_postgres.go:184`; `grep -c fleet_seating` on that file -> 0 |
| M25 | Seats: `fleet_desk_boxes` is empty on dev and on prd. `spool fleet-workspaces`, `spool fleet-enrol`, `do_spl_desk_fleet_seat`, `DESK_PIN_MODE`, `do_spl_workspace_drift`: 0 non-test files. No action file for `do_spl_dispatch_tenants`, `do_spl_fleet_seating_switch`, `do_spl_desk_store_seat`. T8..T10b, T12, T15, T16 and T3b are unbuilt. | `do_spl_fleet_desk_box`; `git grep`; `ls csi-spl-orc/src/bash/run` |
| M26 | The operator page cannot show a stuck step: `workspaceBody` is id, display name, billing, plan, created / suspended / archived and the operator flag. Read in the code; the live page was not opened. | `hub/operator_workspaces.go`; `OperatorPane.vue` |
| M27 | The overlay has no cron: `crontab -l \| grep -c private_overlay` -> 0 for the box owner user on this box, `git grep` in `scripts` and `features` -> 0. A box whose overlay lacks a placeholder the cnf names FATALs on resolve (`spl_private_resolve`, SPL-2677). | `spl-private-cnf.func.sh` |
| M28 | Not read: first login on the address (it does not exist yet), the mail's text, the live operator page, the master box's token and crontab. | |

### 10.3 Why the build stopped at T7

No decision to stop was found. Nothing queued the next row.

- Landed: T1-T3 and T4 on 10-26, T5 on 10-28, T6 on 10-29, T7 and the T5 fix
  on 10-30 (ACCEPTED about 07:50Z).
- This box's lane briefs: those naming T8 are the T4, T5 and T7 ones, as a next
  step; none builds it (titles read). c-001's critical path of 10-26 and 10-28
  names T8 as next. A c-001 note of 10-31 still says "until spec 158 fleet seating
  lands".
- Likely cause, inferred, the issue's own record not read: `SPL-3504` was closed
  by its first `fix(api, SPL-3504)` commits on 10-26 (the landing rule), and T4..T7
  each got an issue only when a lane was placed. So T8 onward had no open issue,
  and nothing in the tracker said work was left.
- Not read: the other box's message archive.

The fix is in the process, not the code: every row of `tasks.md` section 6 gets
its issue under SPL-2398 when this amendment lands, status `todo`, not when a
lane starts. `tasks.md` carries a status column.

### 10.4 Host: address and placeholder with no person

**Design: a small reserve action on the overlay's master box; wf 40 stays the
only thing that applies.**

1. `do_spl_tenant_host_reserve` (orc, new, cron every 5 minutes, refuses on any
   other box through `spl_th_overlay_box_ok`). It reads the open `tenant_hosts`
   rows of dev and prd, with the reconcile's own filters (not unpaid, not
   suspended or archived, not an `e2e*` slug). For each new hidden slug, under a
   lock, in this order: `spl_private_add`, `do_spl_private_overlay_sync`,
   `gh secret set SPL_PRIVATE_CNF_YAML`, read the secret's `updated_at` back, then
   write the row's `detail` as `placeholder reserved <ts>`. The master stays the
   one writer, so no copy loses a line.
2. A pull cron on every other box (`do_spl_private_overlay_pull`, every 5
   minutes), so no box FATALs on a placeholder (M27).
3. wf 40 changes only in what it does with such a row (10.5). It takes a
   reserved row once the reservation is 10 minutes old, so the pull has run
   before the cnf names the placeholder. A box that was off longer FATALs until
   its first pull, with today's message.

Rejected: writing the line in CI (the copy is a secret: the master never gets
it, which is the reason for the refusal today); `do_spl_tenant_host_provision`
from a cron on the box (a second applier beside wf 40, one infra stack per box,
and the owner's standing go covers the workflow only); public by default
(against owner poll 6c701ac9); moving the overlay into the hub DB (the gates and
every box read it, and dev and prd have separate DBs).

**The order gate (M19).** First step of its row: print the failed dev plan's
error, and measure. Expected fix: the prd job also writes the dev key, as the
dev job already carries both, and a prd-only change plans clean on dev, so the
gate passes with no override. The gate itself stays as it is.

**Logs (M20).** Before its first log line, under `GITHUB_ACTIONS=true`, the
reconcile emits `::add-mask::` for every overlay slug and every open row's slug
that is not visible, so later lines of the job print `***`, the terraform plan's
addresses included. Control: a planted hidden slug is absent from a test run's
output. **What has already been logged stays:** deleting those logs is the owner's
choice (10.9, OD3).

Threat model:

| threat | answer |
|---|---|
| A hostile slug reaches the overlay or a shell. | Slugs pass the DB's `CHECK` and `spl_private_add`'s regex: lowercase, digits, dashes. |
| Anyone with a create floods the overlay. | Only an operator admin or a paid checkout can create; unpaid rows are left alone. Placeholder numbers are cheap. |
| The token that writes the secret is stolen from the master box. | That box already holds the overlay and SA keys, so the slugs add nothing, but a broad token would add much. So: a fine-grained token, this repo, `secrets: write` only (OD2). |
| Two writers race on the overlay (the cron and a person). | Both go through `spl_private_add`, which gets a lock in this row. A hand edit outside it is still possible; the sync already refuses a newer differing target. |
| The hidden name reaches git. | Unchanged: commits and cnf carry only the placeholder (`git show a27e25136 \| grep -c` of the slug -> 0). |
| The master box is down. | Rows wait in `pending` with their reason, wf 40 stays green, and V2 and the 10.5 limit show it. Nothing else is held. |

### 10.5 One stuck workspace holds up no other

Today it does (M18). It should not: the reconcile classifies a new hidden row
with no placeholder, or one reserved under 10 minutes ago, into a new `wait` list
before anything is edited.

- A `wait` row is not an add: it stays `pending` with `detail` saying what it
  waits for, it does not count in `apply` (no infra stack built for it), and the
  run stays green with its adds and removes done.
- Past `HOST_WAIT_LIMIT` (default 30 minutes) it is marked `failed` with that
  reason, and the run reports it as it does a failed check. Red is then earned:
  the master box's cron is not working.
- A failed apply still marks every add of that run failed and retries: terraform
  applies them together, so one bad row can hold others for one run. The detail
  says so. Splitting the apply per tenant is not worth its cost.

### 10.6 Pin: the hub pins its own key

**Design: the hub writes the box-wui pin itself, with no root signature.** No
create path then needs a root key, and an operator-supplied public key (where
the hub holds no private key) is the same case.

1. `ensureWUIPin(ctx, tenant)` (hub, new): when the workspace has **no pin row**
   for box-wui and the hub has a key, `PutPin` it with the hub's own key, not
   forced, and write one `operator_audit` row. It never touches a live pin of
   another key or a revoked pin.
2. The operator create calls it, and reports `box_wui_pin` in the 201 body; a
   failure there does not fail the create, as with the invite (the root key is
   answered only once).
3. A sweep beside `PostPublicNotices` (same shape) pins every workspace with no
   box-wui pin row, except `system`, suspended, archived and unpaid. Its switch is
   cnf `hub.box_wui_pin_sweep`, default false.
4. `do_spl_check_box_wui_pins` exempts `system` (no fleet seats, 0 unsigned
   posts, M21), so its GAP count means something.

| create path | today | with this |
|---|---|---|
| Operator route, key generated (the WUI) | no pin | pinned in the create |
| Operator route, operator's public key | no pin | pinned in the create; no private key needed |
| Paid checkout (`paidTx`) | no pin, `fleet_seating` false (M24) | pinned by the sweep; `fleet_seating` by row P3, OD1 |
| `spool hub-tenant` / `do_spl_tenant_create` | pinned with the root key | unchanged; the sweep catches a failed pin. `TENANT_PIN_WUI=0` is used only by its own test (`git grep`) |
| `auth-demo` | a local demo | not in scope |

**Old gaps.** Switching the sweep on repairs them: `<older gap workspace>`, the
drill, and dev's rows. It changes pins in live workspaces, so on prd it is the
owner's go (row P2, on dev first). `do_spl_check_box_wui_pins` must then read 0
gaps. Then `do_spl_replay_unsigned` for any workspace with unsigned posts in the
window (both real cases read 0 in 7 days, M21). A pin revoked or not the hub's
key stays a reported GAP: re-keying needs the root key or an operator's decision,
and a key rotation (014 2.3) is not changed here.

Threat model:

| threat | answer |
|---|---|
| The pin no longer carries the root key's consent. | True, and the change to spec 014 2.2. It adds no power: boxes read their pins from the hub with no root signature (M23), so a hostile hub could already list a key. The key is only ever the hub's own, and box-wui keeps its role (`task` and `note`). |
| A customer holding its own root key does not want browser posts to reach its boxes. | It revokes the pin with its root key; the hub never re-pins a revoked row (a row exists). |
| A sealed workspace (spec 136). | Not read. Row P1's first step reads whether a hub-written pin changes anything there, and says so in the commit body. |
| An attacker makes the hub pin another key. | `ensureWUIPin` takes no key input: only the loaded hub key. |
| The sweep overwrites something. | It writes only where no pin row exists, not forced. Control: a revoked row and a foreign key both stay as they are. |
| A silent failure. | `box_wui_pin` in the 201 body, the audit row, V2, and the dispatch tick's existing `UNSIGNED` report. |

### 10.7 Seats: T8..T11 against today's code

The hub half is landed and still fits: `routeFleet` and the store rules are as
4.2 says (T7, `688f46ad7`). The box half is unbuilt (M25) and needs these changes,
all read from code landed after the spec:

| row | still fits? | change |
|---|---|---|
| T8 | Yes. | None. Payloads are in `wire/fleet_enrol.go`. |
| T9 | Yes, with three additions. | (a) `spl_desk_moved_to` (SPL-4699): a desk moved to the desk user belongs to that user, so the seat runs as the OS user holding the operator-workspace key and skips a moved desk. (b) `spl_box_ws_claim`: a box enrolled in one workspace seats nothing. (c) A new desk dir has no seated agents, and `DESK_SEATED_ONLY=1` would seat none, so the action names the role seats itself (`spl_role_seat`, lease.conf). The enrol's box id must be the id pinned in the operator workspace. |
| T10 | Yes. | `spl-dispatch-subscribe` works from the pinned workspaces; a test is all it needs. |
| T10b | Yes. | `do_spl_dispatch_setup` still renders the list once (M13). |
| T11 | Replaced. | Row E1 is its superset. |
| T3b | Not needed. | Unbuilt, interim, and on its own GO. Dropped once S3 lands, unless the holder objects. |

Two corrections to the text above:

- R1 says every listed desk box is seated; 4.3.4 says one box enrols the role
  seats and the rest stand by. Read together: **every listed box holds a desk dir
  and a live pin; the role seats follow the lease holder's box.** E1 tests that.
- Section 8 item 4 says the 10-26 workspace "stays blocked on the owner's root
  key". Section 1 says it was seated by hand. T13 is then only the switch for
  that workspace.

**What lists a desk box:** `FLEET_DESK_CMD=add BOX_ID=<box> DRY_RUN=0 ./run -a
do_spl_fleet_desk_box` (`PUT /v1/operator/fleet-desks/{box}`), refused 409
`no_live_pin` without a live pin in the operator workspace, one audit row. It is
per box and once, never per workspace, so "no agent step per workspace" holds. It
stays a decision on trust: the orchestrator runs it with the owner's go, on dev,
then prd. Both lists are empty today (M25), so T9 does nothing until then.

### 10.8 The proof

**E1, one e2e on dev**, from the create to an answered post, through the operator
route: U1..U6 in order, each with its time in the commit body. Its workspace is a
non-`e2e*` hidden slug, or it would skip the reserve path; it deprovisions its host
and its overlay line at the end. It needs the secret write, so it runs on the
master box. Red control: the same run with the reserve cron off stops at U3 and V2
names it.

**V1 + V2, the operator page.** `GET /v1/operator/workspaces/{id}/readiness`
answers each step's state and its detail: `invite` (not sent, sent, accepted),
`host` (waiting with the reason, ready, failed with the reason, from
`tenant_hosts`), `docs` (with the host), `pin` (ok, missing, revoked, other key),
`seats` (listed boxes pinned of listed, role seats in the roster) and `first_answer`
(no member post yet, waiting since, answered). It is read-only and operator admin
only. The row shows them as one line of states with the reason for a stuck one, in
every locale, in the rem and focus rules, with agy's final word on the text. A stuck
step then reads in the page, with no agent.

### 10.9 Choices for the owner

The holder puts these to the owner; each has a recommendation.

| id | choice | recommended | why |
|---|---|---|---|
| OD1 | A paid checkout's workspace gets `fleet_seating` true, like every other create? | Yes. | Section 1's order names no exception, and `fleet_seating` is a PATCH away. The other answer: a customer who bought it gets the fleet only on request. |
| OD2 | A fine-grained token (this repo, `secrets: write`) on the overlay's master box, for the reserve cron? | Yes, the owner mints it once. | Without a secret write, wf 40 cannot learn a new placeholder and a person stays in the loop. Which token the master box holds today is not read. |
| OD3 | Delete the wf 40 job logs that hold a hidden slug? | Yes, once row H1 is live. | M20. The holder has the run ids; this public spec does not list them. A deleted log does not come back. |

### 10.10 Rollout

In the order of `tasks.md` section 6. H1 goes first because the log is written on
every run. Named owner's go, each for its one call: the token (OD2), listing a real
desk box on dev and on prd, the sweep on prd, the seat backfill T12 on prd, T13.
wf 40's applies keep the standing go they have. None of these rows touches the drill
workspace by hand: after H2 its host should finish by itself, and after the prd
sweep and S6 its pin and seats. That is the owner's own test.

