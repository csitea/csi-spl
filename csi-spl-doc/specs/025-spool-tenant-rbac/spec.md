# Spec 025: tenant roles and permissions (RBAC in the database)

**Feature**: `specs/025-spool-tenant-rbac` · **Created**: 2026-09-19 · **Lane**: CLE-3414
**Builds on**: 010 (sign-in, `tenant_memberships`, invites, OQ-A5 bootstrap),
014 (WUI dispatch), 017 FR-SEC-013 (rdb 0014 RLS), 009 (M4 seats).
**Amends**: 010 FR-012's two-role model (`owner` | `member`), which this spec
replaces. 010 stays the authority for admission (member | invite | bootstrap).

Status words follow `../README.md` §2.3.

## 1. Owner orders (verbatim, 2026-09-19)

> "...so we will have the roles product owner, biz owner, admin, developer,
> tester and pure agent"

> "so we would need some kind of RBAC in the db" · "we will start slowly
> adding complexity ..."

> "tenant owner = biz-owner"

The owner also asked for one human as the tenant owner of `t1` and another as
its developer (§8).

### 1.1 Owner orders (verbatim, 2026-09-25)

> "but figrure out a new role BizCustomer" · "which for now will have the same
> permissions as the Developer role"

> "so only the admin will be able to add users to the tenant"

> "add the role for regular user as sell , which should be the same as
> Developer" · "... as a new role User"

Implemented in rdb `0039_rbac_customer_and_user_roles.sql` and
`internal/rbac` Defaults in the same commit (§7: a changed answer is a new
migration):

- `biz_customer` ("Biz customer") and `regular_user` ("Regular user"): new
  system roles, grants copied from `developer` at apply time.
- `members.invite` (invite AND remove, `POST /v1/members/invites`,
  `DELETE /v1/members/{human_id}`) is held by `admin` ONLY. Measured before
  the change on dev and prd (`rbac_role_permissions`, 2026-09-25 14:45Z):
  `admin` and `biz_owner`. **`biz_owner` lost it**; it keeps every other
  permission and stays the tenant owner. Taken literally, so by the
  no-escalation rule (§3.4) a `biz_owner` can no longer grant, change or
  remove the `admin` role either (admin's grants include members.invite),
  nor remove itself. The owner keeps inviting through an `admin` membership.
  Operator actions (`do_spl_hub_invite`, `do_spl_tenant_member_role`) are
  outside the hub's RBAC and unaffected.
- A membership holds ONE role (`tenant_memberships.role`; §9 "several roles
  per member" is not built), so "add the role of Admin as well" is served by
  changing the owner's second account's role, not by a second role.

### 1.2 Owner orders (verbatim, 2026-09-25 ~15:08Z, CLE-34969)

> "ok , the admin role owning user should see besides direct messages
> channels , topics and flow the users" · "to be able to CRUD users to the
> system"

> "and the users should work similarly to the messages ... each of the users
> should be listed and when clicking on it , on the left most pane the user
> edit form should appear"

Decisions taken (FR-011, FR-012):

- The Users entry follows `members.invite`, the admin's only permission
  (§1.1), so the entry, the list and the writes go together. Role change
  stays `members.roles` (FR-007), so a `biz_owner` keeps re-roling from the
  operator side; it sees no Users entry.
- Self-removal is refused (`409 self`): another admin removes you, so nobody
  locks themselves out by a misclick. A self role change stays allowed (a
  `biz_owner` stepping down, FR-007), because the last-owner and the new
  last-admin guards already keep the tenant manageable.
- "left most pane": the pane opens where a message opens its topic pane
  (right) until the owner confirms the side; `USER_PANE_SIDE` in
  `csi-spl-wui/src/utils/tenant-users.mjs` is the one switch.

## 2. What existed before this spec (measured on `aa8ac96`)

| aspect | before | where |
|---|---|---|
| roles | `CHECK (role IN ('owner','member'))` on memberships and invites | rdb `0006_users_and_memberships.sql` |
| hub use of the role | none: the view door asks only "is a member" | `internal/store/humans_auth.go` `Member` |
| who may dispatch | any member session | `internal/hub/dispatch.go` `dispatchCheck` |
| who may create a channel | anyone past the view door | `internal/hub/channels.go` |
| invites | operator only: `spool hub-invite`, `do_spl_hub_invite` (`owner`/`member`) | `cmd/spool/hub.go`, `csi-spl-orc/.../spl-hub-invite.func.sh` |
| role change | operator only: `do_spl_tenant_member_role` (`owner`/`member`) | `csi-spl-orc/.../spl-tenant-member-role.func.sh` |
| billing in a tenant | none: checkout (006) is anonymous and creates a NEW tenant | `internal/payments/handler.go` `checkout` |

## 3. The model (phase 1)

Permissions, roles and the role → permission grant are **rows**, not Go
constants. The hub checks a **permission**, never a role name, at every entry
point, through one small cached authorizer (`internal/rbac`).

| table (rdb 0021) | holds | RLS |
|---|---|---|
| `rbac_permissions (permission_id, description)` | the catalogue of permission ids | none: hub-wide, no tenant column (like `humans`) |
| `rbac_roles (role_id, tenant_id NULL, tenant_owner, description)` | `tenant_id IS NULL` = a system role, seen by every tenant; a tenant id = that tenant's own role (phase 2) | yes: a tenant reads system rows + its own; only the operator scope writes system rows |
| `rbac_role_permissions (role_id, permission_id)` | the grant | yes: follows the visibility of its role |
| `tenant_memberships.role`, `tenant_invites.role` | FK → `rbac_roles.role_id` (was a CHECK) | unchanged (0014) |

- One role per membership in phase 1 (the column the rest of the code
  already reads). Several roles per membership is phase 2 (§9).
- `tenant_owner` marks the role that makes a member **the tenant owner**. By
  the owner's decision that is `biz_owner`; there is no separate owner flag
  on the membership.
- The seed is also Go data (`rbac.Defaults`): the memory store runs on it, and
  the Postgres suite asserts that the migrated seed equals it
  (`TestRBACSeedMatchesDefaults`), so the two cannot drift.

### 3.1 Permissions

| id | allows | enforced at (today) |
|---|---|---|
| `topics.read` (rdb 0029; seeded as `threads.read` by 0021) | read roster, channels, threads; open the WUI socket | every `humanTenant` door: view (`/v1/view/*`), `GET /v1/wui/ws` upgrade, search, session `GET /v1/files/{id}`, channels, members |
| `notes.send` | post a note from the WUI (no agent named); edit, delete and react | WUI socket `send`; `PATCH`/`DELETE /v1/messages/{msg_id}` (`hub/edit.go`); `PUT`/`DELETE /v1/messages/{msg_id}/reactions` (`hub/reactions.go`) |
| `agents.command` | command an agent: a `kind=task`/`note` send that dispatches through `box-wui` (014) | WUI socket `send` with an agent `to` / `@AGENT`; the fan-out of a plain channel post to the channel's agent members (`hub/wui.go`, 64bc9fe) |
| `channels.manage` | create channels; remove another member from a channel | `POST /v1/channels`; `DELETE /v1/channels/{channel}/members/{human_id}` when the target is not the caller (`hub/channel_members.go`) |
| `members.invite` | invite and remove members | `POST /v1/members/invites`, `DELETE /v1/members/{human_id}` |
| `members.roles` | change a member's role | `PUT /v1/members/{human_id}/role` |
| `billing.manage` | billing, checkout and seats of the tenant | no in-tenant endpoint yet (006 checkout is pre-tenant); M4 seat purchase inside a tenant MUST gate on it (T030, M4 lane) |
| `tenant.settings` | tenant settings | no endpoint yet; reserved |
| `keys.manage` | tenant-level keys (box pins, the `box-wui` pin) from a session | no session endpoint yet (pins are tenant-root-key signed, 004); reserved. A human's OWN keys (023) are not tenant-scoped and need no permission |
| `audit.read` | see the tenant audit trail | no endpoint yet; reserved |

A reserved permission is seeded and granted now, so the endpoint that later
needs it gates on data that already exists.

### 3.2 Roles and the permission matrix

Y = granted by the seed. Every cell that is a judgement is an OQ in §7 with
this table as its recommended default.

| permission | biz_owner (tenant owner) | product_owner | admin | developer | tester | pure_agent | biz_customer | regular_user |
|---|---|---|---|---|---|---|---|---|
| topics.read (0029; was threads.read) | Y | Y | Y | Y | Y | Y | Y | Y |
| notes.send | Y | Y | Y | Y | Y | Y | Y | Y |
| agents.command | Y | Y | Y | Y | — (OQ-1) | Y | Y | Y |
| channels.manage | Y | Y | Y | Y | — (OQ-5) | — (OQ-5) | Y | Y |
| members.invite | — (§1.1, 2026-09-25) | — (OQ-2) | Y | — | — | — | — | — |
| members.roles | Y | — | Y | — | — | — | — | — |
| billing.manage | Y | — | — | — | — | — | — | — |
| tenant.settings | Y | — | Y | — | — | — | — | — |
| keys.manage | Y | — | Y | — (OQ-3) | — | — | — | — |
| audit.read | Y | Y (OQ-4) | Y | — | — | — | — | — |

- **biz_owner** holds every permission but `members.invite` (admin only
  since 2026-09-25, §1.1). It is the tenant owner.
- **product_owner** steers the work: reads, writes, tasks agents, makes
  channels, sees audit; no member, billing or key administration.
- **admin** runs the tenant for the owner: members, roles, settings, keys,
  audit; not billing.
- **developer** does the work: read, write, command agents, make channels.
- **tester** reads and reports: read and notes, no agent commands by default.
- **pure_agent** — see §3.3.
- **biz_customer**, **regular_user** — for now exactly developer's grants
  (§1.1); each is its own row so a later change to one is a row edit.

### 3.3 `pure_agent`

A `pure_agent` is a **HUM-\* account operated by software, not by a person**:
an automation or an AI that signs in (native 015 or an IdP) and drives the WUI
or the API. It is a member like any other (so it is admitted by invite and
audited under its own HUM-\*), but it holds only the working permissions:
read, notes, command agents. It can never administer anything. It is **not**
an agent id (`CLE-*`, 004): those live on boxes and never sign in.

Seat accounting is unchanged in phase 1: a `pure_agent` membership is a user
seat like any other membership (009 D-3). Moving it to a bot seat is OQ-6.

### 3.4 Granting rules (no escalation)

1. An actor may give role R only when `perms(R) ⊆ perms(actor)`.
2. An actor may change or remove a member currently holding role Q only when
   `perms(Q) ⊆ perms(actor)`. So an admin can never touch a biz_owner (it
   lacks `billing.manage`) and never make one.
3. A tenant always keeps at least one member holding a `tenant_owner` role:
   demoting or removing the last one is `409 last_owner`, in the store, under
   the tenant row lock.
4. The operator paths (`spool hub-invite`, the orc actions) are outside RBAC:
   they are the operator, run as the env service account, and are how the
   first tenant owner is seated (010 OQ-A5).

## 4. Functional requirements

- **FR-001** rdb `0021_tenant_rbac.sql` creates the three tables, seeds §3.1
  and §3.2, maps `owner` → `biz_owner` and `member` → `developer` in
  `tenant_memberships` and `tenant_invites`, replaces both CHECKs by FKs, and
  puts RLS on the tenant-scoped RBAC tables. Forward-only.
- **FR-002** The store keeps the role as data: an invite or role change naming
  an unknown role is refused (Postgres: the FK; memory: `rbac.Defaults`).
  Legacy input names `owner` / `member` are accepted and mapped (so old
  scripts keep working); stored values are always the new ids.
- **FR-003** Bootstrap (010 OQ-A5, dev only) seats the first human as the
  tenant-owner role (`biz_owner`). An invite without a role is `developer`.
- **FR-004** `internal/rbac.Authorizer`: `Access(human, tenant)` answers
  role + permission set; the role → permission table is cached per tenant for
  a short TTL (60 s); the MEMBERSHIP lookup is never cached, so a removed or
  demoted member loses access on the next request, as the 010 door does.
  Any lookup error denies (fail closed).
- **FR-005** Enforcement (a denied check answers `403 forbidden` with the
  missing `permission`, or a socket `error` frame with the same token):
  view door and WUI socket upgrade `topics.read`; WUI note, edit, delete and
  reaction `notes.send`; WUI dispatch and channel agent fan-out
  `agents.command`; channel create and removing another channel member
  `channels.manage`; invite and remove `members.invite`; role change
  `members.roles`; plus §3.4. The §3.4 escalation refusals answer
  `403 forbidden` WITHOUT a `permission` field (`hub/rbac.go`
  `writeForbidden(w, "", …)`): no single permission would lift them.
  With `SPOOL_HUB_VIEW_DOOR=off` (lde only) a request without a session keeps
  today's guest behaviour; a request WITH a member session is still checked.
- **FR-006** `GET /v1/view/me` answers the caller's `{human_id, tenant_id,
  role, tenant_owner, permissions[]}` for the Host tenant (door-off guest: all
  `null`). The WUI reads it.
- **FR-007** Members API (session, Host tenant, JSON, CORS like channels):
  `POST /v1/members/invites {email, role?, ttl_hours?}` → 201;
  `PUT /v1/members/{human_id}/role {role, from_role?}` → 200;
  `DELETE /v1/members/{human_id}` → 204. Errors: 400 `bad_role` / `bad_json` / `bad_email`,
  403 `forbidden`, 404 `not_found`, 409 `last_owner` / `role_changed`.
- **FR-008** The WUI shows the signed-in member's role in the user menu and
  hides what the role may not do: the channel "+" without `channels.manage`.
  Every phase-1 role holds `notes.send`, so the composer is not gated yet; a
  tester's `@agent` send is refused by the hub (`forbidden`). Hiding is
  convenience and fails open (no `/v1/view/me` answer = everything shown);
  the hub check is the control.
- **FR-009** Operator tooling carries the roles: `spool hub-invite --role`,
  `do_spl_hub_invite INVITE_ROLE=`, `do_spl_tenant_member_role MEMBER_ROLE= /
  FROM_ROLE=` accept the eight ids of §3.2 (`rbac.RoleIDs`, orc `SPL_ROLE_IDS`) and the two
  legacy names.
  `do_spl_tenant_member_role` REPLACES the primary role (0201 trigger 1 then
  drops the old one from the set); `do_spl_tenant_member_role_add
  MEMBER_ROLE=` ADDS one role to a member's set and keeps the primary
  (SPL-2588; refuses a non-member: an open invite gains it on acceptance
  only).
- **FR-010** In-tenant billing (M4 seat purchase, plan changes) gates on
  `billing.manage` through the same authorizer (M4 lane).
- **FR-011** Last admin (§1.2): a change that would leave the tenant with no
  enabled member whose role grants `members.invite` is refused
  (`409 last_admin`, store-level under the tenant row lock, like
  `last_owner`). `DELETE /v1/members/{self}` is `409 self`.
- **FR-012** The admin's Users page (§1.2). Hub, each route `members.invite`
  checked per request, rows scoped to the session's tenant (RLS):
  `GET /v1/members` → `{tenant_id, you, members[{human_id, display_name,
  email, role, since, disabled, you, manageable}], invites[{email, role,
  invited_by, created_at, expires_at, expired, mail_count}],
  roles[{id, grantable}]}`; `DELETE /v1/members/invites?email=` → 204 /
  404 `not_found`; `POST /v1/members/invites` also mails the invitation
  (`invitemail.Send`, the `spool hub-invite` path; answer field `mail`).
  WUI: a Users icon after Flow ONLY when `/v1/view/me` lists
  `members.invite` (this gate does not fail open, unlike FR-008); `/users`
  lists one row per member and per pending invite, a click opens the edit
  pane (role, remove, revoke - destructive ones confirmed; invite by email +
  role). Strings in all 19 locales.

Per-FR status lives in `tasks.md`.

## 5. Security requirements

- **SEC-RBAC-1** Deny by default: no membership, an unknown role, a missing
  grant or any lookup error is a deny.
- **SEC-RBAC-2** The WUI never decides: every write re-checks in the hub.
- **SEC-RBAC-3** No escalation (§3.4 rules 1-2) and no ownerless tenant
  (rule 3), both enforced in the hub and the store, with CONTROL tests.
- **SEC-RBAC-4** RLS: `rbac_roles` and `rbac_role_permissions` carry
  `tenant_scope` + `operator_scope` policies in the 0014 shape, FORCEd, so a
  tenant never sees another tenant's custom role (phase 2) and cannot write a
  system role.

## 6. Deploy order

1. Apply rdb 0021 (`do_spl_db_bootstrap`, env SA) **before** the hub roll.
   The running (old) image keeps working on it: it only asks "is a member",
   and its writes of the legacy names happen only on the operator path.
2. Roll the hub image (tag bump + 030 via make, the deploy lane).
3. Ship the WUI (it tolerates a hub without `/v1/view/me`: it then shows no
   role and hides nothing).

The other order breaks every request: a new hub on the old schema cannot read
the RBAC tables, and the authorizer fails closed.

## 7. Open questions (recommended default implemented)

| OQ | question | default |
|---|---|---|
| OQ-1 | May a tester command agents? | No |
| OQ-2 | May a product_owner invite / remove members? | No |
| OQ-3 | May a developer manage tenant keys (box pins incl. `box-wui`)? | No |
| OQ-4 | Who sees audit? | biz_owner, admin, product_owner |
| OQ-5 | Who creates channels? | all but tester and pure_agent |
| OQ-6 | Is a pure_agent a user seat or a bot seat? | user seat (unchanged M4 math); recommended later: bot seat |
| OQ-7 | Admin may grant any role within its own permissions; the last owner can never be removed or demoted | yes |
| OQ-8 | Legacy `member` → developer | yes |

A changed answer is a new migration that edits `rbac_role_permissions` rows
(and `rbac.Defaults` in the same commit), never a code change at the entry
points.

## 8. Tenant `t1` seating (owner order, 2026-09-19)

The tenant owner of `t1` is the owner's company address, the developer is the
owner's personal address (both relayed by ORC; not written here, per the
distribution hygiene rules). Done in dev and prd with the named actions only:
`do_spl_hub_invite` (tenant owner, before 0021: as `owner`, mapped to
`biz_owner` by 0021) and `do_spl_tenant_member_role MEMBER_ROLE=developer`
for the personal account after 0021. Evidence: `tasks.md` T040-T041.

## 9. Growth path (phase 2+, not built)

- **Custom roles per tenant**: rows in `rbac_roles` with `tenant_id` set and
  their grants; no model migration (the columns and RLS exist). Needs a
  composite FK or trigger so a membership can only name a role visible to its
  tenant.
- **Several roles per member**: specified in §10 (SPL-2192, 2026-10-16):
  a `tenant_member_roles` table, the authorizer takes the union,
  `tenant_memberships.role` stays as the primary role.
- **Custom-role editor in the WUI**. The per-member role picker and the
  invite dialog's role picker already shipped (FR-012, 71ffc23,
  `UserEditPane.vue`).
- **Scoped grants** (per channel / per box), and an **audit trail** table the
  `audit.read` permission reads.
- **Agent-side permissions** (a box agent's allowed kinds / targets).

## 10. Several roles per member; the DevOps and Operator roles (SPL-2192, 2026-10-16)

Status: **R1 built** (several roles per member: rdb 0201, the rbac and
store shapes; SPL-2203); **R2 built** (the hub checks of §10.4 A5-A18 and
A20 read the set; the members API reads and writes it, `PUT
/v1/members/{human_id}/roles`; SPL-2293), except an invite's `roles[]` on
`POST /v1/members/invites`, which needs the store to keep invite sets (it
keeps one role per invite, so `invites[].roles` is `{role}`); R3-R7 planned,
not built yet. Tables, migrations and shapes:
[`data-model.md`](data-model.md). The operator-workspace side:
[074 §12](../074-operator-workspace/spec.md#12-devops-and-operator-who-holds-the-operator-routes-spl-2192).
Code facts below were read on `bba5cedb6`.

### 10.1 Owner orders (HUM-10, the owner's terminal, 2026-10-16 ~08:3x-08:5xZ, relayed verbatim by c-001)

The new member's address is left out on purpose (public repository).

> "add also <a new person> as admin of the t1 workspace" / "and to all of the
> channels" / "<he> should be admin as me ..." / "but it is the case that we
> could make it so that he will not see the csitea workspace" / "even if he ia
> sadmin" / "or do we need a new role root ;o) !?!" / "no we should invent a
> new role - DevOps" (msg e9bd19c9)

> "so he should be both Developer , Operator , Regular User and DevOps"
> (msg beb3f52a)

> "DevOps would be like admin , but cannot actually SEE what is the workspace
> , but CAN manipulate workspaces as big objects .." (msg e5a7b7fe)

> "Operator is a differnt role than DevOps - imagine it like off shore support
> - less "wise tasks"" (msg 40333594)

Interim, owner pick A (c-001 msg b7abdb91): the new member's open t1
invite is role `developer` until this is built (row R6).

Measured by c-001 on prd, n=1, and re-read in the code here:

- One membership holds ONE role: `tenant_memberships.role` (rdb 0006/0021).
- Every t1 member whose role is exactly `admin` gets every `/v1/operator/*`
  session route: `internal/hub/operator_workspaces.go:103`
  (`a.Role != rbac.Admin` → 403). `GET /v1/operator/workspaces` lists every
  workspace of the instance. No per-workspace hide flag exists, so a second t1
  admin sees csitea and every customer workspace. This is the problem.
- No role named `operator` exists (`rbac.RoleIDs`, `internal/rbac/rbac.go:83`).

### 10.2 Several roles per member

1. A member holds a SET of one or more roles in a workspace. Its permissions
   are the UNION of the set's grants; it is the tenant owner when any role in
   the set is a `tenant_owner` role.
2. One role of the set is the **primary**: `tenant_memberships.role`, kept as
   a column. It is shown first and is what the exclusive-role code reads.
3. `demo_user` and `channel_guest` are **exclusive**: a set holding one holds
   nothing else (trigger, data-model §2.3). So every check on those two
   (§10.4 list B) stays correct unchanged.
4. **No escalation over sets** (§3.4 extended): an actor may give a set S only
   when `perms(⋃S) ⊆ perms(actor)`, and may change or remove a member whose
   current set is Q only when `perms(⋃Q) ⊆ perms(actor)`. The tenant owner
   covers everyone, as `Access.Covers` does today. Operator-only roles are
   outside this rule: §10.3 rule 4.
5. The last-owner and last-admin guards (§3.4 rule 3, FR-011) count members
   whose SET holds a tenant-owner role / grants `members.invite`.
6. API: `PUT /v1/members/{human_id}/roles {roles[], primary?, from_roles?}`;
   the one-role `PUT .../role` stays for old clients and scripts;
   `GET /v1/view/me` and `GET /v1/members` add `roles[]`; an invite takes
   `roles[]` (data-model §4).
7. WUI: the role picker in `UserEditPane.vue` and in the invite form becomes
   a multi-select (checkboxes) with a "primary" pick; a role the actor may not
   grant is shown disabled, as today (`grantable`). The user menu shows every
   role, the primary first.
8. Operator tooling: `do_spl_tenant_member_role MEMBER_ROLES=a,b[,c]`
   (`MEMBER_ROLE=` stays, one role), `do_spl_hub_invite INVITE_ROLES=`,
   `spool hub-invite --role a,b`. `SPL_ROLE_IDS`
   (`csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:684`) gains `devops`
   and `operator`; the actions refuse those two outside the operator
   workspace.

### 10.3 The DevOps and Operator roles

Two new system roles, both **operator-only** (`rbac_roles.operator_only`):
valid ONLY in the operator workspace (`tenants.is_operator`, t1 on prd).
Granting either elsewhere is `400 operator_only_role` (store and trigger).

| role id | display | what it is |
|---|---|---|
| `devops` | DevOps | "like admin, but cannot actually SEE what is the workspace, but CAN manipulate workspaces as big objects": every operator operation of the table in 074 §12.2, and no workspace content |
| `operator` | Operator | "off shore support - less wise tasks": a routine subset of the same operations (074 §12.2, the owner picks by the poll there), and no workspace content |

Rules:

1. **Only these roles carry the operator routes.** Every `/v1/operator/*`
   SESSION route checks its own `operator.*` permission (074 §12.3), granted
   to `devops` and, for the subset, to `operator`. No other role holds an
   `operator.*` permission. The id-token / env service account routes of
   `internal/hub/operator.go` (invites, replay, repairs) stay outside RBAC as
   §3.4 rule 4 says.
2. **A t1 `admin` becomes a plain workspace admin.** It keeps every §3.2
   grant inside t1 and loses the operator routes, unless its set also holds
   `devops` or `operator`. The 074 rule "admin of the operator workspace, not
   biz owner" (074 §4.1, FR-012) is replaced by "devops of the operator
   workspace"; a `biz_owner` without devops is still refused.
3. **No workspace content.** Neither role holds any §3.1 / §3.2 permission:
   not `topics.read`, `notes.send`, `docs.read`, `members.invite`, nothing.
   So a member holding ONLY `devops` and/or `operator` cannot read or write a
   channel, topic, message, doc, issue, file or the member list in t1 or in
   any workspace it manages; in a workspace it is not a member of, the door
   refuses before RBAC (`403 tenant_mismatch` / `not_member`). A member who
   ALSO holds e.g. `developer` in t1 sees t1's content through that role,
   never another workspace's. 074 D4 ("metadata and members only") narrows
   to metadata only for these roles: 074 §12.4.
4. **Only a devops grants or removes `devops` or `operator`**, through
   `PUT /v1/operator/staff/{human_id} {add[], remove[]}`, permission
   `operator.roles` (devops only). The members API (`PUT .../roles`) never
   adds or removes an operator-only role: a t1 `admin` or `biz_owner` cannot
   make a devops (`403 forbidden`, permission `operator.roles`), and its role
   edits keep the operator-only roles already in the set.
5. **Never without a devops**: removing or disabling the last enabled member
   holding `devops` is `409 last_devops` (store, under the tenant row lock,
   like `last_owner`).
6. **The door.** Today every operator route enters through `humanTenant`,
   which demands `topics.read` (`internal/hub/resolve.go:109`); `GET
   /v1/view/me` does too (`internal/hub/rbac.go:122`). A devops-only member
   holds no `topics.read`, so both move to an `operatorDoor`: a member
   session whose active workspace is the operator workspace, no `topics.read`
   asked, then the route's `operator.*` permission. `/v1/view/me` answers such
   a member `{role, roles[], permissions[]}` and nothing else.
7. **The migration keeps every current power** (data-model §2.5): every
   enabled t1 `admin` and the t1 tenant owner (HUM-10 on prd) get `devops`
   added at apply time. Nobody loses the operator routes on the day it lands;
   HUM-10 gains them on the owner's own account.
8. **Self-hosted first run** (074 FR-016): the first account of a fresh
   instance gets `biz_owner` + `admin` + `devops` in the first workspace.

The new member (§10.1): `developer` + `operator` + `regular_user` + `devops`
in t1 (row R6). In the devin and demo workspaces the new member holds "the same roles ...
as in the spool-hub" (owner, c-001 msg 9e598b09) MINUS the two
operator-only ones, which are invalid there: `developer` + `regular_user`.
Same rule for anyone: a role set copied to another workspace drops
`devops` and `operator`.

### 10.4 Every role-by-name check, and what it becomes

Measured on `bba5cedb6`; commands:
`grep -rnE 'rbac\.(BizOwner|ProductOwner|Admin|Developer|Tester|PureAgent|BizCustomer|RegularUser|DemoUser|ChannelGuest)\b' --include=*.go csi-spl-api | grep -v _test.go`
→ 46 lines;
`grep -rnE '\.Role (==|!=)' --include=*.go csi-spl-api | grep -v _test.go`
plus the `m.role` reads of `internal/store`. Lines that compare
`wire.RoleBox`, `store.OdRole` or a fleet ask's role are not workspace roles
and are left out.

**A. Checks that change** (a member may now hold the role as a NON-primary
one; 22 Go sites + WUI + orc):

| # | file:line | today | after | row |
|---|---|---|---|---|
| A1 | `internal/hub/operator_workspaces.go:103` | `a.Role != rbac.Admin` → 403 | `operatorDoor` + the route's `operator.*` permission | R3 |
| A2 | `internal/hub/fleet_load.go:122` | session path via `operatorActor` (A1) | `operator.fleet.read` / `operator.fleet.write` | R3 |
| A3 | `internal/hub/operator_workspaces.go:244` | `first_admin_role` ∈ `rbac.RoleIDs` | also refuse an operator-only role (a new workspace is never the operator one) | R3 |
| A4 | `internal/hub/members_admin.go:156` | grantable = every `rbac.RoleIDs` | operator-only roles listed `grantable:false`, `operator_only:true` | R3 |
| A5 | `internal/hub/demo_audit.go:143` | operator workspace and `a.Role == rbac.Admin` | `a.Has(rbac.Admin)` (stays the t1 admin's: the demo audit is post content, not an object op) | R2 |
| A6 | `internal/hub/wsdoc_tree.go:206` | `a.Role == rbac.Admin` | `a.Has(rbac.Admin)` (writes t1 docs: content) | R2 |
| A7 | `internal/hub/embed_staff.go:63` | `TenantOwner \|\| a.Role == rbac.Admin` | `TenantOwner \|\| a.Has(rbac.Admin)` | R2 |
| A8 | `internal/hub/topic_archive.go:156` | same | same | R2 |
| A9 | `internal/hub/topic_archive.go:173` | same | same | R2 |
| A10 | `internal/hub/calendar_sync.go:253` | `slices.Contains(roadmapApproverRoles, a.Role)` | `a.HasAny(roadmapApproverRoles...)` | R2 |
| A11 | `internal/hub/roadmap_switch.go:83` | same | same | R2 |
| A12 | `internal/hub/message_kind.go:128` | `kindSetterRoles[a.Role]` | `a.HasAny(rbac.BizOwner, rbac.Admin)` | R2 |
| A13 | `internal/hub/view.go:380` | `m.Role == rbac.BizOwner` | `slices.Contains(m.Roles, rbac.BizOwner)` | R2 |
| A14 | `internal/hub/actas.go:195` | `targetAcc.Role == ""` | `len(targetAcc.Roles) == 0`; the act-as ceiling (`CoversAccess`) already works on permissions | R2 |
| A15 | `internal/hub/rbac.go:133` | `/v1/view/me` `role` | + `roles[]` | R2 |
| A16 | `internal/hub/realm.go:52`, `:129` | `realmNotPerson[m.Role]` | not a person only when EVERY role of the set is in the map | R2 |
| A17 | `internal/hub/realm_hours_write.go:108`, `:131` | `m.Role != realmTimeAccountant` | `!slices.Contains(m.Roles, realmTimeAccountant)` | R2 |
| A18 | `internal/hub/realm_hours_read.go:236` | same | same | R2 |
| A19 | `internal/hub/roadmap_goal_docs.go:132` | goal `OwnerRole` ∈ `rbac.RoleIDs` | refuse an operator-only role as a goal owner | R3 |
| A20 | `internal/invitemail/invitemail.go:193` | `rbac.Legacy(role) == rbac.BizOwner` | any role of the invite's set | R2 |
| A21 | `internal/store/embed_staff.go:119`, `:123` | `m.role = ANY (biz_owner, admin)` | `EXISTS` on `tenant_member_roles` | R1 |
| A22 | `internal/store/hours_sweep.go:91` | `hoursNoRow[role]` | no row only when every role of the set is in the map | R1 |
| W1 | `csi-spl-wui/src/utils/access.mjs:15` | `ROLE_IDS` (8 ids) | + `devops`, `operator`; `me.roles` | R5 |
| W2 | `csi-spl-wui/src/stores/operator-pane.ts:30` | probe skipped when `role !== 'admin'` | probe when `me.roles` holds `devops` or `operator`; read from the access store, so `ChannelSidebar.vue:887` needs no edit | R5 |
| W3 | `csi-spl-wui/src/components/ActAsPicker.vue:75`, `:76` | `m.role === 'biz_owner' / 'admin'` | on `roles[]` | R5 |
| W4 | `csi-spl-wui/src/utils/sidebar-row-menu.mjs:70` | `me.role === 'admin'` | `me.roles.includes('admin')` | R5 |
| W5 | `csi-spl-wui/src/components/UserEditPane.vue:37-38`, `:84-86`, `:92` | one `<select>` | multi-select + primary | R5 |
| W6 | `csi-spl-wui/src/utils/tenant-users-mock.mjs:59,79,86,107,108,115,117,135,137` | mock on `role` | mock on `roles[]` | R5 |
| O1 | `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:684` | `SPL_ROLE_IDS` | + `devops\|operator`; multi-role actions (§10.2 rule 8) | R4 |

**B. Exclusive-role reads that stay unchanged** (`demo_user`,
`channel_guest`: alone in their set by §10.2 rule 3; the primary is the only
role): `internal/auth/tenant.go:327`, `internal/auth/demo_pseudonym.go:20`,
`internal/hub/demo.go:26`, `:66`, `internal/hub/demo_quota.go:43`,
`internal/hub/sign_in_emails.go:96`, `internal/hub/rbac.go:389`,
`internal/store/demo_stay.go:68`, `:166`, `:197`, `:202`, `:258`,
`internal/store/demo_pseudonym_auth.go:18`,
`internal/store/humans_memory.go:116`, `:231`, `:252`,
`internal/store/humans_postgres.go:274`, `:353`, `:363`, `:789`,
`internal/store/memberships.go:64`, `:148`,
`internal/store/member_directory.go:84`, `:168`,
`internal/store/search_postgres.go:654`, `internal/store/seats_postgres.go:60`,
`internal/store/embed_visitors.go:108`, `internal/store/embed_signin.go:86`,
`internal/store/embed_visitor_messages.go:127`, rdb `0172_embed_staff.sql:59`.
30 sites. R1's test proves the premise (a second role next to either is
refused).

**C. Store reads and writes of the role that move to the set** (row R1):
`internal/store/humans_rbac.go:49`, `:64`, `:100`, `:103`, `:106`, `:109`,
`:128`, `:131` (memory guards: owner, admin, from-role, set);
`internal/store/humans_rbac_postgres.go:42-43`, `:55`, `:75` (the joins on
`m.role`); `internal/store/clones.go:65`;
`internal/store/tenant_settings.go:225`, `:256`, `:264` and
`internal/store/access_until.go:93` (`memLockoutGuard`: last owner / admin
over the set); `internal/store/memberships.go:65`, `:142`,
`internal/store/member_directory.go:87`, `:162`,
`internal/store/humans_postgres.go:258`, `:539`,
`internal/store/humans_memory.go:380` (add `Roles`). 23 sites.

### 10.5 Tests that prove it (each with a red control)

| test | row | proves | red control |
|---|---|---|---|
| `TestTenantMemberRolesUnion` (memory + POSTGRES) | R1 | a member with `tester` + `developer` holds `agents.command`; removing `developer` drops it on the next request (no membership cache) | the authorizer reads the primary only → red |
| `TestTenantMemberRolesTriggers` (POSTGRES) | R1 | a legacy `UPDATE tenant_memberships SET role` keeps the extra roles; `demo_user` + another role is refused | drop the trigger in the test db → red |
| `TestRBACMembersAPIRoles` | R2 | set escalation: an admin cannot give `{developer, biz_owner}`; last owner / last admin over sets; `409 role_changed` on `from_roles` | `Covers` on the primary only → red |
| `TestOperatorRoutesDevOpsOnly` (POSTGRES) | R3 | t1 `admin` without devops: 403 naming the route's `operator.*` permission on every `/v1/operator/*` session route; `devops`: 200; `operator`: 200 on its subset, 403 on the rest; `biz_owner` 403 | restore `a.Role == rbac.Admin` as an alternative gate → red |
| `TestDevOpsNoContent` (POSTGRES) | R3 | a devops-only (and an operator-only) session gets 403 `topics.read` on `GET /v1/view/channels`, the WUI socket upgrade, search, `GET /v1/members`, the docs and files routes of t1; and 403 `tenant_mismatch` / `not_member` on another workspace's content routes; `GET /v1/operator/workspaces/{id}` answers no member, channel or message field | grant `topics.read` to `devops` in the test's `Defaults` → red |
| `TestOperatorOnlyRoleOutsideOperatorWS` (POSTGRES) | R3 | `devops` / `operator` refused (`400 operator_only_role`) in any other workspace, by the store AND by the trigger on a raw insert | remove the trigger → the raw insert passes → red |
| `TestOperatorStaffGrant` | R3 | only `operator.roles` adds / removes devops or operator; a t1 admin or biz_owner 403; `409 last_devops` | grant `operator.roles` to `admin` → red |
| `TestDevOpsMigrationSeating` (POSTGRES) | R3 | after the migration, every t1 admin and the t1 tenant owner hold `devops`; nobody else does | seat only admins → the owner case red |
| WUI unit + e2e (mock bundle) | R5 | multi-select saves `roles[]`; a devops-only reader sees the operator pane and no channel list; a t1 admin without devops sees no operator pane | `operatorConsoleVisible` on `role === 'admin'` → red |

### 10.6 Build rows (one lane each, disjoint files, in this order)

| row | kind | files | depends | test (red control in §10.5) |
|---|---|---|---|---|
| **R1** multi-role data + store | complex_coding | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_tenant_member_roles.sql`; `internal/rbac/rbac.go` (`Access.Roles`, `Has`, `HasAny`, union, `FixedSet`); `internal/store/humans.go`, `humans_rbac.go`, `humans_rbac_postgres.go`, `humans_memory.go`, `humans_postgres.go`, `memberships.go`, `member_directory.go`, `clones.go`, `tenant_settings.go`, `access_until.go`, `embed_staff.go`, `hours_sweep.go` | — | `TestTenantMemberRolesUnion`, `TestTenantMemberRolesTriggers`, `TestRBACSeedMatchesDefaults`; `PRE_PUSH_TIER=full` (POSTGRES) |
| **R2** the rbac checks + members API | complex_coding | `internal/hub/rbac.go`, `members_admin.go` (roles only, not A4), `view.go`, `actas.go`, `embed_staff.go`, `topic_archive.go`, `calendar_sync.go`, `roadmap_switch.go`, `message_kind.go`, `demo_audit.go`, `wsdoc_tree.go`, `realm.go`, `realm_hours_write.go`, `realm_hours_read.go`; `internal/invitemail/invitemail.go` | R1 | `TestRBACMembersAPIRoles`, the existing `TestRBACPerRoleEntryPoints` / `TestRBACMembersAPI` / `TestMembersAdminAPI` green |
| **R3** devops + operator roles, the operator gate | complex_coding | `csi-spl-rdb/.../<next>_devops_operator_roles.sql` (perms, roles, `operator_only`, trigger 3, seating); `internal/rbac/rbac.go` (ids, `Defaults`, `RoleIDs`, `operator.*` perms); `internal/hub/operator_workspaces.go`, `fleet_load.go`, new `operator_staff.go`, `resolve.go` (`operatorDoor` only), `members_admin.go` A4, `roadmap_goal_docs.go` A19; store last-devops guard | R1, R2 | `TestOperatorRoutesDevOpsOnly`, `TestDevOpsNoContent`, `TestOperatorOnlyRoleOutsideOperatorWS`, `TestOperatorStaffGrant`, `TestDevOpsMigrationSeating`; POSTGRES. Reports the seating list (data-model §2.5) for dev and prd before the apply |
| **R4** orc + CLI | simple_coding | `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` (`SPL_ROLE_IDS`), `spl-tenant-member-role.func.sh`, `spl-hub-invite.func.sh` and their tests; `cmd/spool/hub.go` (`--role a,b`) | R1 (R3 for the two new ids) | orc tests: `MEMBER_ROLES=developer,devops` refused outside the operator workspace (red control: drop the check) |
| **R5** WUI picker + operator pane + i18n | complex_coding, then i18n | `csi-spl-wui/src/utils/access.mjs`, `stores/operator-pane.ts`, `utils/operator-console.mjs`, `components/UserEditPane.vue`, `components/ActAsPicker.vue`, `utils/sidebar-row-menu.mjs`, `utils/tenant-users-mock.mjs`, the devops-only shell (no socket, the operator pane alone), `role.devops` / `role.operator` + picker strings in all 19 locales. NOT `ChannelSidebar.vue` (c-635) nor `pages/issues.vue` | R2, R3 on dev | unit + e2e on the mock bundle; `pnpm run typecheck`; agy review of the strings LAST (`LANE_MIX_KIND=i18n`) |
| **R6** seat the new member | operator action, no code | none: c-001 runs `do_spl_tenant_member_role MEMBER_ROLES=developer,operator,regular_user,devops` for the new member in t1, and `MEMBER_ROLES=developer,regular_user` in devin and demo, dev then prd, with the owner's go (msg id) for prd. If the t1 invite is still open then, re-issue it with `do_spl_hub_invite INVITE_ROLES=…` instead | R3 + R4 live on dev and prd | `GET /v1/view/me` as that member lists the four roles in t1 (or `do_spl_hub_member_list`), n=1 per env |
| **R7** docs | specs_and_docs | `025/tasks.md` and `074/tasks.md` ticks, `074/spec.md` FR status, the roles help page and the API doc (`x-role: operator` routes name their `operator.*` permission) | R1-R5 | links and greps in the commit |

The operator poll (074 §12.2) changes only the `operator` grants in R3's
migration and `rbac.Defaults`. If R3 has landed when the answer comes, the
change is a new migration (§7: "a changed answer is a new migration").

### 10.7 Open

| # | decision | recommendation |
|---|---|---|
| OPEN-1 | Which operations may an Operator do, apart from DevOps? (074 §12.2, the poll) | list, read, rename/settings, fleet-load read; not create, billing, suspend/resume, archive, box-join, fleet-load write, staff grants |
| OPEN-2 | The demo post audit (A5) and the t1 repo-docs writer (A6) are t1-admin powers today, not object operations: do they stay with the t1 `admin`? | yes, they stay with `admin` (content, not objects) |
| OPEN-3 | The estate cost view (`internal/hub/cost_read.go:140`, `costs.read` in the operator workspace) is instance-wide money data: move it to devops? | no change now (it reads costs, not workspace content); ask when R3 lands |

## 11. Pending channel membership: add a person before they join (SPL-3686, 2026-10-27)

Owner HUM-10, t1 #spool-hub-bugs topic b602f8b4 (msg 4a3ec33a, 2026-10-26):
"it should be possible to add persons to channels even if they have not yet
joined the spool-hub".

Before: `POST /v1/channels/{channel}/members` took only `{human_id}` and
refused anyone with no membership in the workspace (404 `not_a_member`), and
a person who holds only an invite has no `HUM-*` id yet. The picker offered
workspace members only ("They have to be a member of the workspace first").

### 11.1 The rule

- **Who may add**: the same people as for a member, `mayInviteChannel` (the
  channel owner; any member when `members_open_invite` is on; any member of a
  channel created by `hub`/`wui`), after `channels.edit` and billing.
- **By address**: the body is `{"human_id"}` or `{"email"}`, never both.
  - The address of a live member of the workspace is the plain add
    (`channel_humans`, 201 `{human_id}`).
  - The address of an OPEN workspace invite (unaccepted, unexpired) gets a
    pending row: 201 `{email, pending: true, invite: "existing"}`.
  - An address with no open invite gets one first, under the rule of
    `POST /v1/members/invites` (`members.invite`, the default role, the
    default 7-day ttl, the invitation mail), then the pending row:
    `invite: "created"`, `mail`. The invite records `ordered_via = "#<channel>"`.
    A caller without `members.invite` gets that route's 403
    (`permission: members.invite`) and nothing is written. Why create rather
    than refuse: the owner asked for adding people who have not joined, and an
    invite is the only way a person who has not joined can join; the
    permission that guards inviting stays the one that decides it.
- **The pending row grants nothing**: the read door reads `channel_humans`
  only. Accepting the invite (sign-in admission, `acceptInviteTx`; or an
  operator seat, `ProvisionMember`) moves every pending row of the address to
  `channel_humans` for the new member, in the same transaction.
- **Nothing is left behind**: revoking the invite deletes its pending rows
  (FK `ON DELETE CASCADE` to `tenant_invites`); deleting the channel deletes
  them too. An expired invite leaves them inert: not listed, not moved; a
  re-invite of a lapsed or accepted address clears them first, a re-invite of
  an open one keeps them. So a typo still leaves no membership behind.
- **Undo**: `DELETE /v1/channels/{channel}/members/{email}` drops one
  pending row; whoever may add may, and `channels.manage` (the rule for
  removing someone else).
- **Listing**: `GET /v1/channels/{channel}/members` carries `invited`, the
  open pending addresses (`[]` on a default channel).

### 11.2 Store and schema

rdb `0231_channel_invites.sql`: `channel_invites (tenant_id, channel_id,
email, added_by, created_at)`, PK `(tenant_id, channel_id, email)`, FKs to
`channels` and `tenant_invites`, FORCE RLS with the fail-closed tenant policy.
It is exempt from the channel_scope policy (no visitor route reads it).
Store interface `ChannelInvites` (Memory and Postgres).

### 11.3 Web UI

The channel's People picker offers a typed email address as "Invite
<address>"; Add lists it under the members with an "invited" label until the
person joins, and its minus takes the pending add back. New keys
`channels.properties.{invite_email, invited, invited_hint, remove_invited}`,
`invite_empty` reworded, in all 19 locales (agy has the final word on the text).
Not built: picking from the workspace's pending invites (listing them needs
`members.invite`); typing the address covers that case.

### 11.4 Tests

- `internal/store/channel_invites_test.go` (memory and Postgres): the add
  needs an open invite; accept and operator seat join; revoke, expiry,
  re-invite and undo.
- `internal/hub/channel_invites_test.go`: the HTTP rule above. Red on
  origin/master: `POST {"email"}` answered 400 `bad_json`.
- `csi-spl-wui/tests/e2e/channel-people.test.mjs`: type an address, Add, it is
  listed as invited, the minus removes it.

<!-- version: 1.4.0 · updated: 2026-10-27 · last-edit: 2026-10-27T01:14:13Z -->
