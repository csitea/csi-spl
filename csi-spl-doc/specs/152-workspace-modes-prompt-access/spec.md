# 152 Roles and permissions: a configurable role x action list per workspace

Version v0.3 draft (2026-10-23). This is step 1 of the owner rule for a big
change: the written spec. Nothing in it is built until the owner has checked
the action list (section 9) and the dispatcher has filed the build rows.

v0.3 replaces the v0.2 design (a fixed matrix per mode, `9b01369f4`) with the
owner's ask of 2026-10-23 15:36Z: a configurable list of what each role may
do, covering the whole life cycle of work with agents, edited in the admin
Settings, with the modes as pre-set fills of that list. EDITOR c-393
(claude) wrote it; the mistral seat reviews it ([panel.md](panel.md)).

Source: prd topic in the owner's workspace,
`topic:b4af24b2-65ec-4fde-bbaf-6350f24c025b`. Issues: SPL-3093 (this
version), SPL-3053 (v0.2), epic SPL-3035. Each build row in
[tasks.md](tasks.md) gets its own issue once the owner has checked
section 9.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`
- `hub/` = `api/hub/`, `store/` = `api/store/`, `rbac/` = `api/rbac/`,
  `msg/` = `api/msg/`, `action/` = `api/action/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`

Every `file:line` was read on origin/master `6af865c34`. The v0.2 citations
still hold there: `git diff --stat 15a982250 6af865c34 --` the files v0.2
cites (`hub/wui.go`, `hub/rbac.go`, `hub/sender_allow.go`,
`hub/tenant_settings.go`, `hub/topic_reply.go`, `store/tenant_kv.go`,
`rbac/rbac.go`, `wui/composables/useMentionPoke.ts`,
`wui/utils/send-failure.mjs`) -> one line changed, `hub/wui.go:1005` (a
comment in `fanoutWUI`, `337dc9a3b`), outside every cited range.

## 1. The owner's asks, verbatim

Owner HUM-10, 2026-10-23 UTC, in the topic above:

- `2c890f3f` (11:08Z): "we need the feature for access control for
  prompting .."
- `219f0105` (11:0xZ): "somthing like on certain modes - ageile ,
  corporate etc. the AC would work for different roles differnetly"
- On the v0.2 forms Q2, Q3 and Q4 (msgs `cfc9d48a`, `295de9d0`,
  `8a3a1440`, 15:36Z): "No no we want to have a configureable list of what
  can be done by which role - a comprehensive set of permisssion covering
  the whole Life Cycle done with this type of agenting system in the
  Settings of the Admin"
- On the v0.2 form Q1 (msg `0b047510`, 15:3xZ): "B - Agile, corporate and
  strict, where only owners and admins prompt agents".
- msg `9465ddb1` (15:4xZ): "with the capabiliy on this roles & permissions
  settings to -use those pre-set permission sets ( modes - strict ,
  agile , corporate , and move fast break things mode as this one )".

Read: each workspace holds a table of ROLE x ACTION. An admin edits any
cell in Workspace settings. Four presets fill the whole table at once:
`strict`, `corporate`, `agile`, `move_fast` ("move fast and break
things"). A workspace that never touches it works exactly as today.

## 2. What exists on master

### 2.1 Roles and permissions

- A member holds a SET of roles; the hub asks for a permission, never a
  role name (`rbac/rbac.go:1-8`; rdb `0021_tenant_rbac.sql`,
  `0201_tenant_member_roles.sql`). The exceptions are in 2.6.
- The member roles (`rbac/rbac.go:62-70`, `RoleIDs` at `:88`): `biz_owner`
  (O), `admin` (A), `product_owner` (P), `developer` (D), `tester` (T),
  `pure_agent` (G), `biz_customer` (C), `regular_user` (U). The one-letter
  codes are this spec's shorthand. Two exclusive non-member roles,
  `demo_user` and `channel_guest` (`rbac/rbac.go:71-85`), keep their own
  paths and are not in the list.
- 21 permission ids (`rbac/rbac.go:18-57`, catalogue `:104-126`). The
  grants (`Defaults`, `rbac/rbac.go:138-153`) are GLOBAL rows:
  `rbac_role_permissions` has no tenant column
  (`rdb/0021_tenant_rbac.sql:37-41`); no hub route writes a grant. An admin
  changes only a member's role SET.
- The schema already planned per-tenant roles: `rbac_roles.tenant_id` "a
  tenant id = that tenant's own role (phase 2, none yet)"
  (`rdb/0021_tenant_rbac.sql:8-9`), and the role table is read PER TENANT:
  `TenantRoles` selects `WHERE r.tenant_id IS NULL OR r.tenant_id = $1`
  under the tenant's RLS scope (`store/humans_rbac_postgres.go:14-32`).
- That per-tenant table is cached: `Authorizer.Roles` keeps it per tenant
  for `DefaultTTL` = 1 minute (`rbac/rbac.go:302-347`), `Invalidate(tenant)`
  drops it (`:349-354`). The member's role set is never cached (`:356-360`).
  `s.access` reads it once per request through the request memo
  (`hub/rbac.go:43-58`).
- The effective permissions reach the WUI on `GET /v1/view/me`
  (`permissions`, `hub/rbac.go:101`, filled at `:137`). The Workspace
  settings menu shows a section only when that list holds its permission
  (`wui/utils/tenant-settings-nav.ts:18-46`).

### 2.2 Prompting an agent today: one permission

Prompting is ONE permission, `agents.command` ("command an agent through
box-wui dispatch", `rbac/rbac.go:22`, `:107`), held by every member role
but `tester`. It is asked at three sites, all on a person's browser send
(`wuiSend`, `hub/wui.go:571`):

| send | check | refused how | where |
|---|---|---|---|
| DM to an agent, `@agent ...` dispatch | `agents.command` | 403 `forbidden` | `hub/wui.go:830-845` (perm at `:838-839`, refusal `:842`; a door-off guest, `c.member == ""`, is not checked, `:841`) |
| plain channel post (fan-out to the channel's agent members) | `agents.command` | NOT refused: stored and shown, no box delivery | `hub/wui.go:715-726` (owner rule 2026-09-22), `:769-770` |
| channel-less reply dispatched to the topic's agent | `agents.command` | not dispatched: stays a browser-only post | `hub/topic_reply.go:26-28` |

The WUI has no pre-check of it (`git grep -n "agents.command" origin/master
-- csi-spl-wui/src` -> 0 lines).

### 2.3 The per-agent sender allow-list (SPL-1018)

Contract `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md`,
rdb `0188_agent_sender_allow.sql`, hub `hub/sender_allow.go`, WUI
`wui/components/AgentSenders.vue`.

- One list per agent per workspace, of members; no list = every member,
  an empty list = nobody (contract `:8-17`).
- Covers a DM, an `@agent` dispatch, a bare `@agent` and a channel-less
  reply dispatched to an agent; NOT a channel post that names no agent
  (contract `:19-41`, `:30`).
- Runs only on a person's send; agents are never blocked from each other
  (`hub/sender_allow.go:35-39`, `:247-250`).
- Refusal: 403 `sender_not_allowed`, nothing stored
  (`hub/sender_allow.go:41-42`, `:268-290`); WUI line
  `composer.send_failed_not_allowed` (`wui/utils/send-failure.mjs:90`).
- Edited by `tenant.settings` holders in Workspace settings -> Agents
  (`hub/sender_allow.go:69`, `wui/pages/tenant-settings/agents.vue:46`).
- Order in `wuiSend`: route (`agents.command`, `hub/wui.go:589`), then the
  allow-list (`:593-595`), then demo, admit, token-budget and audit
  (`:596-611`).

### 2.4 Channels, the mention poke, and "new work"

- The per-channel "AI agents" switch: off = no fan-out, a DM and an
  `@agent` dispatch still go (`store/channel_ai_agents.go:11-27`). Who flips
  it: the channel's creator or a `tenant.settings` holder
  (`hub/channel_ai_agents.go:55-58`).
- Humans-only channel: an `@agent` there is a plain post (`hub/wui.go:733`).
- The mention poke: for each extra agent a post @mentions, the WUI sends a
  DM in a NEW task carrying `ref_task_id` = the topic it is about
  (`wui/composables/useMentionPoke.ts:86-91`; hub `hub/wui.go:136`, `:620`).
- There is no hub concept of "new work". The orchestrator and dispatcher
  seats are members of every channel
  (`csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh:3-16`), so any
  channel post that fans out reaches them.

### 2.5 Workspace settings storage

- `tenants.settings` jsonb (rdb `0136_tenant_settings_jsonb.sql`); a key is
  a `RegisterTenantSetting` call, no DDL (`store/tenant_kv.go:18-31`); a
  string value holds at most `MaxTenantSettingString` = 200 runes unless its
  key sets `MaxLen` (`store/tenant_kv.go:72`).
- `GET` / `PATCH /v1/tenant/settings` need `tenant.settings`
  (`hub/tenant_settings.go:93-104`, `:106-179`).

### 2.6 Every role check across the life cycle

Commands: `git grep -nE 'rbac\.(TopicsRead|NotesSend|...|CostsRead)\b'
-- api ':!*_test.go'` (the 21 ids) -> 152 lines outside `rbac/rbac.go`;
`git grep -nE 'rbac\.(BizOwner|ProductOwner|Admin|Developer|Tester|PureAgent|BizCustomer|RegularUser)\b|TenantOwner\b|workspaceOwner\('
-- api/hub ':!*_test.go'` -> the role-name sites. Each was read and put
in the stage of agent work it belongs to; the result is the catalogue in
3.1 ("today" and "enforced today at" columns). What the reading found
beyond v0.2:

- **Issues** are written through one gate, `issueWriter`: `notes.send` AND
  `topics.manage` (`hub/issues.go:866-888`), the same for a create
  (`:890`) and for EVERY field of a PATCH (`:913-934`): title, status,
  priority, level, assignee, labels, deadline, parent, kind
  (`hub/issues.go:156-180`). No field has its own check.
- **Sites that test a role name or the owner flag**, not a permission:
  another member's message kind (`hub/message_kind.go:34`, O or A),
  deleting or moving another's topic (`hub/topic_archive.go:166-174`, O or
  A), the archive policy "admins" (`:151-161`), a blocker into an issue
  (`hub/blocker_issue_make.go:38`, the owner flag), the roadmap switch
  (`hub/roadmap_switch.go:82` with `hub/calendar_sync.go:83`, O or A),
  marketing publishing (`hub/marketing_share.go:245`,
  `hub/marketing_posts.go:31`, the owner flag), embeds
  (`hub/embed_admin.go:92`, the owner flag; `hub/embed_staff.go:63`, O or
  A), reporting SQL (`hub/reporting_sql.go:333`, A only). Three more stay
  out of the list (3.2): `hub/wsdoc_tree.go:208`,
  `hub/operator_workspaces.go:103`, `hub/tenant_agent_caps.go:71`. The
  rest of that grep picks a target or a name list, not a right to act
  (`hub/actas.go:202`, `hub/demo_audit.go:140-143`, `hub/realm.go:53`,
  `hub/view.go:401`).
- **Ship has no member route.** A deploy runs in CI on the push to master;
  the hub's only deploy route is the operator's record
  (`POST /v1/operator/deploys`, `hub/operator_deploys.go:77`, operator
  auth). Release notes are ingested by the operator
  (`hub/release_notes.go:59`). A person "ships" by telling an agent: the go
  is text in a post.
- **Accepting a result has no member route either.** The `accepts` field
  that marks a line as accepting a result (spec 130, `msg/msg.go:109-114`)
  is set only by the box CLI (`action/action.go:146-151`, `:317-318`); no
  WUI send path sets it. A person's ACCEPTED is a post.
- **Topic priority** (spec 150, rdb `0214_topic_priorities.sql`) is in the
  store (`store/topic_priority*.go`) with no hub route on this sha
  (`git grep -nil topic_priorit -- api/hub` -> 0 files).
- **`keys.manage` is checked nowhere**: `git grep -nE 'KeysManage|"keys\.manage"'
  -- csi-spl-api ':!*_test.go'` -> only `rbac/rbac.go`.
- **`billing.manage` gates no route**: its one site picks who receives the
  token-budget alert frame (`hub/token_budget.go:114`).
- **The last-owner and last-admin guards** refuse a role change that would
  leave a workspace with no enabled owner, or no enabled member whose role
  set grants `members.invite` (`store/humans_rbac.go:113-124`, Postgres
  `store/humans_rbac_postgres.go:105-127`, `ErrLastOwner` at `:192`,
  `:240`).

## 3. The design

### 3.1 The action catalogue

Forty actions in five stages. 39 are cells of the list (one role x action
boolean each); `topics.archive` is the existing workspace setting and is
shown in the list, not stored in it (3.2). "new" = a permission id that
does not exist yet; its system grant is seeded to exactly the roles that
may do it today, so the default changes nothing (3.6).

**Start work (7)**

| id | the action | today | enforced today at |
|---|---|---|---|
| `notes.send` | post a message for people | all | `hub/wui.go:837-845` and every message write (`hub/edit.go:84`, `hub/reactions.go:81`, ...) |
| `channels.manage` | create a channel | O A P D C U | `hub/channels.go:452` |
| `issues.create` (new) | file an issue | all | `hub/issues.go:866-888` (`topics.manage`) |
| `agents.dm` (new) | DM an agent (a new or an existing DM) | all but T | `hub/wui.go:838-839` (`agents.command`) |
| `agents.start` (new) | open a NEW channel topic that addresses an agent | all but T | no check of its own (no concept, 2.4); `agents.command` |
| `agents.mention` (new) | address an agent in an existing topic: `@agent`, a bare `@agent`, the mention poke | all but T | `hub/wui.go:838-839` (`agents.command`) |
| `agents.post` (new) | a plain channel post reaches the channel's agents (fan-out) | all but T | `hub/wui.go:769-770`, not refused |

**Steer (10)**

| id | the action | today | enforced today at |
|---|---|---|---|
| `agents.reply` (new) | a reply in a channel-less topic goes on to its agent | all but T | `hub/topic_reply.go:26-28` (`agents.command`) |
| `issues.edit` (new) | change an issue's title, description, labels, deadline, parent, kind | all | `hub/issues.go:866-888` |
| `issues.assign` (new) | set an issue's assignee | all | same |
| `issues.prioritise` (new) | set an issue's priority or level, and a topic's priority once spec 150 has its route | all | same; topic: no route yet (2.6) |
| `topics.manage` | move, merge, promote one's own topic or message | all | `hub/message_move.go:80` |
| `docs.write` | create, edit, delete workspace docs | all | 25 sites, e.g. `hub/workspace_docs.go:277`, `hub/wsdoc_tree.go:326` |
| `files.write` | upload and delete files | all | `hub/demo.go:55` |
| `channels.edit` | add or remove channel members and agents; archive or delete a channel | all | `hub/channel_members.go:131` |
| `channels.ai_agents` (new) | switch the AI agents of a channel one did not create | O A | `hub/channel_ai_agents.go:55-58` (`tenant.settings`) |
| `messages.kind` (new) | set the kind of someone else's message | O A | `hub/message_kind.go:34` (role names) |

**Review and accept (6)**

| id | the action | today | enforced today at |
|---|---|---|---|
| `issues.status` (new) | change an issue's status: start, done, return, reopen | all | `hub/issues.go:866-888` |
| `issues.blocker` (new) | make a blocker message an issue | O | `hub/blocker_issue_make.go:38` (owner flag) |
| `topics.change_others` (new) | delete, move, merge or promote someone else's topic | O A | `hub/topic_archive.go:166-174` (role names) |
| `issues.remove_others` (new) | delete, archive or restore someone else's issue | O A | `hub/issues.go:939-944`, `:1003`, `:1056`, `:1087` (`tenant.settings`) |
| `results.accept` (new) | accept or return an agent's result | all but T | not checked: a post (2.6); agent-read bit (3.10) |
| `topics.archive` | archive a topic | the archive policy setting | `hub/topic_archive.go:146-161` |

**Ship (4)**

| id | the action | today | enforced today at |
|---|---|---|---|
| `ship.approve` (new) | give an agent the go to release or deploy | all but T | not checked: a post (2.6); agent-read bit (3.10) |
| `roadmap.publish` (new) | make the workspace roadmap public or private | O A | `hub/roadmap_switch.go:82` (role names) |
| `marketing.publish` (new) | publish a marketing post | O | `hub/marketing_share.go:245`, `hub/marketing_posts.go:31` (owner flag) |
| `embeds.manage` (new) | put a channel on a website (embeds and their keys) | O | `hub/embed_admin.go:92` (owner flag) |

**Administer (13)**

| id | the action | today | enforced today at |
|---|---|---|---|
| `members.invite` | invite and remove members, reset a password, sign-in emails | O A | `hub/rbac.go:325`, `:474`; `hub/members_admin.go:104`, `:193`; `hub/member_password_reset.go:55`; `hub/sign_in_emails.go:60`, `:111`; `hub/tenant_settings.go:496` |
| `members.roles` | change a member's roles | O A | `hub/rbac.go:379`, `:422` |
| `members.impersonate` | act as a member | O A | `hub/actas.go:182` |
| `agents.join` | mint and revoke agent join tokens, revoke a seat | A | `hub/join_tokens.go:183`, `:245`, `:276`, `:311` |
| `tenant.settings` | the Workspace settings sections (agents and their allow-lists, vendor split, takeover, lifecycle, channels, general, hours, performance, marketing) | O A | `hub/tenant_settings.go:94`, `:107`; `hub/sender_allow.go:69`; `hub/agent_split.go:79`, `:92`; `hub/takeover_ladder.go:79`; `hub/agent_lifecycle.go:69`; `hub/perf_summary.go:67`; `hub/marketing_switch.go:117` |
| `perms.edit` (new) | edit this list | O A | (new) |
| `billing.manage` | billing; today only the token-budget alert | O | `hub/token_budget.go:114` |
| `audit.read` | the audit trail, member activity, box stats | O A P | `hub/actas.go:82`, `hub/box_stats.go:105`, `hub/memberactivity.go:118` |
| `costs.read` | the workspace costs | O A | `hub/cost_read.go:121` |
| `hours.read` | every member's hours | O | `hub/hours_team.go:219`, `hub/hours_export.go:283` |
| `hours.approve` | approve or return an hours period | O | `hub/hours_team.go:291` |
| `reporting.sql` (new) | run reporting SQL | A | `hub/reporting_sql.go:333` (role name) |
| `embeds.visitors` (new) | see and handle website visitors (lead, block) | O A | `hub/embed_staff.go:63` (role names) |

Counts: start 7, steer 10, review and accept 6, ship 4, administer 13 =
40 actions; 39 cells x 8 roles = 312 cells. 16 ids exist, 23 are new.

### 3.2 What the list does not hold

- **Membership itself**: `topics.read`, `docs.read`, `self.keys`. Taking
  one away would make a member who cannot open the workspace; that is
  removing the member.
- **`keys.manage`**: no site checks it (2.6). Kept in the catalogue as it
  is.
- **`agents.command`**: after the build no site asks it (its three sites
  ask the five `agents.*` ids). The id and its grants stay, so an old
  script reading `/v1/view/me` sees what it saw.
- **`topics.archive`**: it already is a per-workspace setting,
  `topic_archive_policy` (everyone, starter, admins; CLE-77819), whose
  "starter" and "admins" values treat the AUTHOR differently
  (`hub/topic_archive.go:146-161`), which one cell per role cannot say.
  The list page shows its row with the current value and a link to its
  picker. Presets do not change it.
- **Author rights**: an author always edits, deletes and moves their own
  message or topic (`hub/topic_archive.go:166-169`); the cells say what a
  role may do to OTHERS' items.
- **Non-member and estate paths**: `demo_user` and `channel_guest` rows
  (their own paths, `hub/demo.go`, spec 121), operator routes
  (`/v1/operator/*`), the operator-workspace checks
  (`hub/wsdoc_tree.go:208`, `hub/operator_workspaces.go:103`,
  `hub/tenant_agent_caps.go:71`), demo moderation (demo workspace only,
  `hub/demo_moderation.go:28-34`), and the box owner lock (its owners'
  keys decide, `hub/box_lock_routes.go:307-325`).
- **Agents**: no cell ever applies to an agent (3.8).

### 3.3 Where the list is stored: a table (decided on evidence)

| | settings keys (`tenants.settings`) | a table `tenant_role_grants` |
|---|---|---|
| shape | 39 keys `perm.<id>` = a role list, or one key of 312 cells | one row per CHANGED cell: `(tenant_id, role_id, permission_id, granted, set_by, set_at)` |
| size | 39 x <= 120 chars; one key would exceed the 200-rune default (`store/tenant_kv.go:72`) | <= 312 rows per workspace; a preset writes its difference from today: strict 68, corporate 43, move_fast 41 rows, agile 0 |
| read path | the tenant row cache, a SECOND source beside the role cache that `s.access` reads | the role table `TenantRoles` already reads per tenant (`store/humans_rbac_postgres.go:14-32`), cached 1 min (`rbac/rbac.go:302-347`): one LEFT JOIN, no new query per request |
| fit with spec 025 | none: permissions would live outside `rbac` | "a changed grant is a row edit" (`rdb/0021_tenant_rbac.sql:4-5`); 0021 planned per-tenant roles |
| migration | none | one forward file: the 23 new permission rows and their system grants (mirroring today), the table, FORCE RLS with `tenant_scope` and `operator_scope` policies (as `rdb/0214_topic_priorities.sql:39-46`); about 60 lines |
| other cost | a custom decoder and `Valid` check per key | store memory + Postgres, a tenant-isolation test (a new tenant table needs one) |

**Decision D1: the table.** It puts the grant where the hub already reads
grants, costs no request a query, and stores only what a workspace
changed. The settings path would add a second cache and a decoder for no
saving. The preset row counts come from the fills in 3.5 (cells that
differ from the agile column). The migration's number is taken at build
time (numbers race).

### 3.4 The effective permission

- `TenantRoles(tenant)` returns each role's grants = the system grants,
  minus the tenant's rows with `granted = false`, plus its rows with
  `granted = true`. Everything above it is unchanged: `Access` is still the
  union over the member's role set (`rbac/rbac.go:356-382`), and
  `s.access`, `s.allowed`, `s.permit` and `/v1/view/me` work as they do.
- The sites of 3.1 that test `agents.command`, `topics.manage` (for
  issues), `tenant.settings` (for issues and channel AI agents), a role name
  or the owner flag switch to the action's own id. Every site after that
  inherits the list by asking for its id.
- `issueWriter` keeps `notes.send` and asks, per PATCH, the id of each
  field the body sets: `status` -> `issues.status`; `assignee` ->
  `issues.assign`; `priority`, `level` -> `issues.prioritise`; any other
  field -> `issues.edit`. A body that sets two fields needs both.
- The new-topic test for `agents.start` is v0.2's: one `EXISTS` on
  `messages (tenant_id, task_id)` (index `messages_task_received`,
  `rdb/0083_messages_task_received_covering.sql:36`), only on a send that
  addresses an agent; a mention poke is classified by its REFERENCED topic
  (v0.2 D9, D10). A new channel topic that names no agent is an
  `agents.post`, never an `agents.start`.
- A change lands on the hub instance that took it at once
  (`Invalidate(tenant)`) and on every other instance within `DefaultTTL`,
  1 minute (`rbac/rbac.go:302`).
- The act-as ceiling compares the two members' effective sets
  (`hub/actas.go:200-204`); it reads the same table, so it follows the list.

### 3.5 The four presets

A preset fills all 39 cells at once; an admin may then change any
unlocked cell. O = biz_owner, A = admin, P = product_owner, D = developer,
T = tester, G = pure_agent, C = biz_customer, U = regular_user.

| id | stage | agile = today | strict | corporate | move_fast |
|---|---|---|---|---|---|
| `notes.send` | start | all | all | all | all |
| `channels.manage` | start | O A P D C U | O A P | O A P D | all |
| `issues.create` | start | all | all | all | all |
| `agents.dm` | start | all but T | O A | all but T | all |
| `agents.start` | start | all but T | O A | O A P | all |
| `agents.mention` | start | all but T | O A | O A P D G | all |
| `agents.post` | start | all but T | O A | O A P D G | all |
| `agents.reply` | steer | all but T | O A | all but T | all |
| `issues.edit` | steer | all | O A P | O A P D G | all |
| `issues.assign` | steer | all | O A P | O A P | all |
| `issues.prioritise` | steer | all | O A P | O A P | all |
| `topics.manage` | steer | all | O A P | O A P D G | all |
| `docs.write` | steer | all | all | all | all |
| `files.write` | steer | all | all | all | all |
| `channels.edit` | steer | all | O A P | O A P D G | all |
| `channels.ai_agents` | steer | O A | O A | O A | all |
| `messages.kind` | steer | O A | O A | O A P | all |
| `issues.status` | review | all | O A P | O A P D G | all |
| `issues.blocker` | review | O | O | O | all |
| `topics.change_others` | review | O A | O A | O A P | all |
| `issues.remove_others` | review | O A | O A | O A | all |
| `results.accept` | review | all but T | O A | O A P | all |
| `ship.approve` | ship | all but T | O A | O A | all |
| `roadmap.publish` | ship | O A | O A | O A | O A P |
| `marketing.publish` | ship | O | O | O | O |
| `embeds.manage` | ship | O | O | O | O |
| the 13 administer ids | administer | as 3.1 | as 3.1 | as 3.1 | as 3.1 |

- **agile** is today, cell for cell: a workspace on agile stores 0 rows.
- **strict** (Q1 = B): only owners and admins prompt agents, accept
  results and give the go to ship; product owners keep the work's
  structure (issues, topics, channels); everyone still talks, files issues,
  writes docs and uploads files.
- **corporate**: owners, admins and product owners start work and accept
  it; developers and pure agents continue it (mention, post, reply, issue
  status); customers and regular users talk to agents in a DM only (a DM is
  `agents.dm`; their replies there are `agents.reply`), never in a channel.
- **move_fast** ("move fast and break things"): every member role,
  testers included, does every start, steer, review and ship action. It
  still guards: the whole administer stage (as today), what the outside
  world sees (marketing and embeds stay the owner's; the roadmap switch is
  owners', admins' and product owners'), the locked cells (3.7), the
  per-agent allow-lists (3.8), box locks, demo and guest paths, billing.
- **What a preset leaves alone**: the administer stage is the same in all
  four presets; an admin changes it cell by cell.

### 3.6 The default is today, and a red control proves it

- With no rows, `TenantRoles` returns the system grants (the SELECT of
  `store/humans_rbac_postgres.go:16-20` plus a LEFT JOIN that matches
  nothing), so every existing id answers as today.
- Each new id's system grant is seeded to exactly the "today" column of
  3.1: the five `agents.*` ids to every role that holds `agents.command`
  (`demo_user` included, so the demo is unchanged), the issue ids to every
  role that holds `topics.manage`, the role-name and owner-flag ids to the
  roles those sites name. `TestRBACSeedMatchesDefaults` keeps the migration
  and `rbac.Defaults` equal.
- **Control, Go**: `TestListDefaultIsToday` holds a frozen table of the 312
  "today" answers (3.1) and compares it with the answers through
  `TenantRoles` with no rows: 312 of 312 equal. Its red control: one tenant
  row (`developer`, `agents.start`, false) turns exactly one cell red.
- **Control, hub suite**: `go test ./internal/hub/ -run
  'SenderAllow|WUI|Wui' -count=1 -v` -> 59 PASS, 0 FAIL, memory store,
  n = 1 run on `6af865c34` (this editor, 2026-10-23). After each hub row:
  the same 59 PASS, plus that row's new tests.

### 3.7 The admin Settings page, who edits it, and the lock-out guard

- **Where**: Workspace settings -> Roles and permissions, a new section
  `permissions` in `wui/utils/tenant-settings-nav.ts`, shown when
  `/v1/view/me` lists `perms.edit` (the existing menu rule, `:18-46`).
- **What it shows**: one row per action, grouped by the five stages, each
  with a one-line meaning; one column per role; a checkbox per cell. Above
  the grid: the four presets as buttons and a chip saying which preset the
  table equals, or "custom". Applying a preset asks first and names how
  many cells change. The `topics.archive` row shows the archive policy in
  force with a link to its picker. On a phone (<= 820 px) the grid shows
  one role at a time with a role picker.
- **API**: `GET /v1/tenant/permissions` -> the catalogue (id, stage, the
  roles today, the roles in force, the locked cells) and the four preset
  fills; `PUT /v1/tenant/permissions` with `{preset: "<id>"}` (one
  transaction: drop the workspace's rows, write the preset's difference
  from today) or `{cells: {"<id>": {"<role>": true | false | null}}}`
  (null = back to today's). Both need `perms.edit`; refused in the demo
  workspace (as `hub/marketing_switch.go:42`). The handler logs the actor
  and every changed cell old -> new; `set_by` / `set_at` keep the last
  writer per cell.
- **Who edits it**: `perms.edit`, O and A by default. Changing a cell of
  the ADMINISTER stage needs `members.roles` as well: a grant there is as
  strong as giving someone a role (D6).
- **Lock-out guard**: the cells `perms.edit`, `members.roles` and
  `members.invite` of `biz_owner` and `admin` are LOCKED to true: no PUT and
  no preset changes them (400 `locked_cell`). The last-owner and last-admin
  guards (2.6) already keep an enabled O or A in every workspace, so some
  member can always edit the list. No new counting query.

### 3.8 Agents are never blocked, and the allow-list stays

- Every check above runs on a PERSON's request (`s.access` of a HUM id).
  Box frames and box CLI writes (agents, orchestrator and dispatcher seats)
  never run them, as for the allow-list (`hub/sender_allow.go:35-39`,
  `:247-250`). `pure_agent` is a person's role (a member who works mostly
  through agents), so it IS a column.
- The per-agent allow-list stays as the second layer, unchanged: the list
  says what a ROLE may do, the allow-list which MEMBERS may reach ONE
  agent. Order on a send: the action's id, then the allow-list, then the
  rest of `wuiSend` (2.3). The allow-list keeps covering DMs and mentions
  only (owner msg `e9ec66fa`, contract `:30`); v0.2's Q4 is withdrawn.

### 3.9 What a refused action shows

- A route action (every id but the prompting ones): today's 403
  `forbidden` naming the missing id (`hub/rbac.go:71-90`, 025 FR-005).
- `agents.dm`, `agents.mention`, `agents.start`: refused before anything is
  stored, 403 `forbidden` with the id, as a tester's `@agent` is refused
  today (`hub/wui.go:842`). The WUI maps it to a new line
  `composer.send_failed_permission` ("Not sent: in this workspace your role
  may not {action}. Your text is still here.").
- `agents.post`, `agents.reply`: NOT refused (owner rule 2026-09-22,
  `hub/wui.go:715-726`): stored and shown, no box delivery, ack
  `"agents_skipped": "permission"`, a quiet note under the card
  (`composer.agents_skipped_permission`).
- The composer reads the ids from `/v1/view/me` and shows
  `composer.permission_hint` before a send it knows will be refused; the
  hint never disables Send.

### 3.10 Accept and ship: the bits an agent reads

The hub cannot refuse a go or an ACCEPTED: both are text (2.6). So the
hub TELLS the agent: on every box delivery of a person's message it adds
the sender's `results.accept` and `ship.approve` bits as hub data, outside
the signed inner object (a new inner field breaks every older reader,
`msg/msg.go:102-114`). The agent seed rule: act on an accept or a release
or deploy go only when the sender carries the bit; otherwise answer that
the sender's role may not, and route it to the dispatcher. Which field of
the box delivery carries it is read at build time (row B8); this spec does
not claim it.

This enforcement is the AGENT's, not the hub's: a seat that ignores its
seed is not stopped. A go relayed by an agent carries the RELAYING agent
(never blocked), so the seed rule also says a relayed go names the
original message, whose bits the receiver reads.

### 3.11 i18n

The page and the composer lines are translation keys in
`csi-spl-wui/i18n/locales/en.json` and the other 18 locale files
(`ls csi-spl-wui/i18n/locales | wc -l` -> 19), translated, never English
copies (developer guide 2.4):

- `tenant_settings.permissions.title`, `.hint`, `.locked`, `.custom`,
  `.matches`, `.apply_confirm`, `.archive_row`, the five stage names, the
  four preset names and hints, and one label and one hint per action
  (`tenant_settings.permissions.action.<id>`, 39 x 2): about 100 keys.
- `composer.send_failed_permission`, `composer.agents_skipped_permission`,
  `composer.permission_hint`.

agy reviews every locale as the LAST step before the WUI rows ship (fleet
language rule, row B12).

## 4. Red controls

Each `R` case FAILS on `6af865c34` and passes once its row lands; (C) is a
control that passes on both. c-007 is any agent member of the channel.

| # | case | on `6af865c34` | expected |
|---|---|---|---|
| R1 | `GET /v1/tenant/permissions` as admin | 404 | 200, 39 cells x 8 roles, `matches: "agile"` |
| R2 | the same as a `developer` | 404 | 403 `forbidden`, `permission: perms.edit` |
| R3 | `PUT {preset: "strict"}` as admin, then `GET` | 404 | 200; 68 rows stored; `matches: "strict"` |
| R4 | strict: a `developer` DMs c-007 | delivered | 403 `forbidden`, `permission: agents.dm`, nothing stored |
| R5 | strict: a `developer` plain post in a channel with agents | fan-out built | stored, no box delivery, ack `agents_skipped: permission` |
| R6 | corporate: a `developer` opens a NEW channel topic `@c-007 build x` | delivered | 403, `permission: agents.start` |
| R7 | corporate: the same developer replies `@c-007 ...` in an EXISTING topic | delivered | delivered (C) |
| R8 | corporate: the developer's mention poke (new task, `ref_task_id` = an existing topic) | delivered | delivered: an `agents.mention` of that topic |
| R9 | corporate: a `regular_user` DMs c-007 | delivered | delivered (C) |
| R10 | corporate: a `regular_user` posts `@c-007 ...` in a channel | delivered | 403, `permission: agents.mention` |
| R11 | no rows (agile): the hub suite of 3.6 | 59 PASS | the same 59 PASS (C) |
| R12 | no rows: `TestListDefaultIsToday` | absent | 312 of 312 equal; one row turns one cell red |
| R13 | a box frame from c-001 to c-007 in strict | delivered | delivered (C: agents never blocked) |
| R14 | `PUT {cells: {"perms.edit": {"admin": false}}}` | 404 | 400 `locked_cell` |
| R15 | a `product_owner` given `perms.edit` changes `members.invite` for `developer` | 404 | 403 `forbidden`, `permission: members.roles` |
| R16 | corporate: a `developer` PATCHes an issue's `assignee` | 200 | 403, `permission: issues.assign` |
| R17 | corporate: the same developer PATCHes the issue's `status` | 200 | 200 (C) |
| R18 | move_fast: a `tester` sets another member's message kind | 403 | 200 |
| R19 | move_fast: a `tester` publishes a marketing post | 403 | 403 (C: move_fast still guards it) |
| R20 | strict, c-007's allow-list without the admin: the admin sends `@c-007` | 403 `sender_not_allowed` | the same (C: the allow-list still refuses after the list) |
| R21 | a cell changed on hub instance 1 is read on instance 2 | - | in force within 60 s (the role cache TTL) |
| R22 | `GET /v1/view/me` of a strict developer | `permissions` has `agents.command` | no `agents.dm`, `agents.start`, `agents.mention`, `agents.post` |
| R23 | WUI: Workspace settings -> Roles and permissions, `data-test="tenant-permissions"`; a preset click PUTs and the chip follows | absent | present |
| R24 | WUI: a refusal naming `agents.start` shows `composer.send_failed_permission` | the generic line | the new line |
| R25 | i18n parity: the new keys in all 19 locales | missing | present; the `i18n-untranslated` count not raised |
| R26 | the demo workspace: `PUT /v1/tenant/permissions` | 404 | 403 |
| R27 | strict: a box delivery of a `developer`'s message carries `ship.approve: false` | absent | present (B8) |

## 5. Rollout

Additive. With no rows every workspace is on today's table (3.6). Order:
the migration (B1), rbac and store (B2, B3), the API (B4), the site rows
(B5-B8), each proving R11 and R12 still green, the WUI (B9, B10), docs
(B11); agy reviews the locales before B9 and B10 ship (B12). A hub with the
sites converted and an old WUI already enforces the list; the old WUI shows
its generic refusal line.

## 6. Out of scope

- Workspace-made roles (`rbac_roles.tenant_id`, phase 2 of spec 025): the
  columns are the eight system roles.
- Per-channel lists: the list is per workspace.
- Agents prompting agents: never checked (3.8).
- A history of list changes beyond the log line and `set_by` / `set_at`.

## 7. Risks

- **A grant is a power**: `perms.edit` lets its holder give any role any
  unlocked cell; the administer stage also needs `members.roles` (3.7), so
  only those who may give roles may give admin powers.
- **Instances lag up to 1 minute** after a change (3.4, R21).
- **Accept and ship are enforced by agents, not the hub** (3.10): a seat
  that ignores its seed is not stopped.
- **The new-topic probe** is one indexed `EXISTS` per send that addresses
  an agent; B5 measures the send p95 on dev before and after, with n.
- **`TestRoundTripsPerRequest`** must stay unchanged: the overrides ride
  `TenantRoles`, which the role cache serves.

## 8. Decisions settled from the code

| # | decision | evidence |
|---|---|---|
| D1 | The list is a table of changed cells, read inside `TenantRoles` | 3.3; `store/humans_rbac_postgres.go:14-32`; `rbac/rbac.go:302-347` |
| D2 | One permission id per action; the role-name and owner-flag sites become ids | 2.6; spec 025 "the hub asks for a PERMISSION ... never for a role name" (`rbac/rbac.go:1-3`) |
| D3 | The default is today: new ids seeded to today's roles; agile stores 0 rows | 3.6 |
| D4 | The modes are fills of the list, not a separate check; v0.2's `prompt.mode` key and fixed matrix are dropped | owner msgs `cfc9d48a`, `9465ddb1` |
| D5 | `agents.command` splits into five ids (`dm`, `start`, `mention`, `post`, `reply`) | its three sites, 2.2; v0.2 3.1, D9, D10 |
| D6 | Administer cells need `members.roles` too | 3.7, R15 |
| D7 | Lock-out: six cells locked; the existing last-owner and last-admin guards do the rest | `store/humans_rbac.go:113-124` |
| D8 | Agents never checked; the allow-list unchanged, after the list | `hub/sender_allow.go:35-39`; 3.8 |
| D9 | A plain post or a reply is never refused, only not delivered to agents | `hub/wui.go:715-726` |
| D10 | Accept and ship are agent-read bits on the delivery, outside the signed object | 2.6; `msg/msg.go:102-114` |
| D11 | `topics.archive` stays its own setting, shown in the list | `hub/topic_archive.go:146-161` |
| D12 | An issue PATCH checks the id of each field it sets | `hub/issues.go:156-180`, `:866-888` |

## 9. Owner questions

Recorded: Q1 = B, "Agile, corporate and strict, where only owners and
admins prompt agents" (msg `0b047510`); the owner then added the fourth
preset, move fast and break things (msg `9465ddb1`). v0.2's Q2, Q3 and Q4
are withdrawn (msgs `cfc9d48a`, `295de9d0`, `8a3a1440`: the list replaces
them).

The owner's next form is ONE poll: the action list to check. Each ticked
action goes into the list; an unticked one is left out of this build;
"Chat about this" says what to change. The last question is the four
presets' fills (3.5).

```poll
Start work: tick each action the list should have
[S1] Post a message for people
[S2] Create a channel
[S3] File an issue
[S4] DM an agent
[S5] Open a new channel topic that prompts an agent
[S6] Address an agent in an existing topic (@agent)
[S7] A plain channel post reaches the channel's agents
Steer: tick each action the list should have
[T1] A reply in a DM-style topic goes on to its agent
[T2] Edit an issue (title, description, labels, deadline)
[T3] Assign an issue
[T4] Set an issue's or a topic's priority
[T5] Move, merge or promote one's own topic
[T6] Write workspace docs
[T7] Upload files
[T8] Add or remove channel members and agents
[T9] Switch the AI agents of someone else's channel
[T10] Set the kind of someone else's message
Review and accept: tick each action the list should have
[R1] Change an issue's status (done, return, reopen)
[R2] Make a blocker an issue
[R3] Delete or move someone else's topic
[R4] Delete or archive someone else's issue
[R5] Accept or return an agent's result
Ship: tick each action the list should have
[P1] Give an agent the go to release or deploy
[P2] Make the roadmap public
[P3] Publish a marketing post
[P4] Put a channel on a website (embed)
Administer: tick each action the list should have
[A1] Invite and remove members
[A2] Change a member's roles
[A3] Act as a member
[A4] Add agents to the workspace (join tokens)
[A5] Workspace settings
[A6] Edit this roles and permissions list
[A7] Billing
[A8] Read the audit trail
[A9] Read costs
[A10] Read everyone's hours
[A11] Approve hours
[A12] Run reporting SQL
[A13] Handle website visitors
Presets: tick each preset whose fill (spec section 3.5) you approve as written
[ST] Strict: only owners and admins prompt, accept and ship
[CO] Corporate: owners, admins, product owners start; developers continue; customers DM only
[AG] Agile: exactly today
[MF] Move fast and break things: every role does all work; admin, marketing and embeds stay guarded
```
