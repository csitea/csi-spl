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
| `threads.read` | read roster, channels, threads; open the WUI socket | view door (`/v1/view/*`), `GET /v1/wui/ws` upgrade, channel-create door |
| `notes.send` | post a note from the WUI (no agent named) | WUI socket `send` |
| `agents.command` | command an agent: a `kind=task`/`note` send that dispatches through `box-wui` (014) | WUI socket `send` with an agent `to` / `@AGENT` |
| `channels.manage` | create channels | `POST /v1/channels` |
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

| permission | biz_owner (tenant owner) | product_owner | admin | developer | tester | pure_agent |
|---|---|---|---|---|---|---|
| threads.read | Y | Y | Y | Y | Y | Y |
| notes.send | Y | Y | Y | Y | Y | Y |
| agents.command | Y | Y | Y | Y | — (OQ-1) | Y |
| channels.manage | Y | Y | Y | Y | — (OQ-5) | — (OQ-5) |
| members.invite | Y | — (OQ-2) | Y | — | — | — |
| members.roles | Y | — | Y | — | — | — |
| billing.manage | Y | — | — | — | — | — |
| tenant.settings | Y | — | Y | — | — | — |
| keys.manage | Y | — | Y | — (OQ-3) | — | — |
| audit.read | Y | Y (OQ-4) | Y | — | — | — |

- **biz_owner** holds every permission. It is the tenant owner.
- **product_owner** steers the work: reads, writes, tasks agents, makes
  channels, sees audit; no member, billing or key administration.
- **admin** runs the tenant for the owner: members, roles, settings, keys,
  audit; not billing.
- **developer** does the work: read, write, command agents, make channels.
- **tester** reads and reports: read and notes, no agent commands by default.
- **pure_agent** — see §3.3.

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
  view door and WUI socket upgrade `threads.read`; WUI note `notes.send`;
  WUI dispatch `agents.command`; channel create `channels.manage`; invite and
  remove `members.invite`; role change `members.roles`; plus §3.4.
  With `SPOOL_HUB_VIEW_DOOR=off` (lde only) a request without a session keeps
  today's guest behaviour; a request WITH a member session is still checked.
- **FR-006** `GET /v1/view/me` answers the caller's `{human_id, role,
  tenant_owner, permissions[]}` for the Host tenant (door-off guest: all
  `null`). The WUI reads it.
- **FR-007** Members API (session, Host tenant, JSON, CORS like channels):
  `POST /v1/members/invites {email, role?, ttl_hours?}` → 201;
  `PUT /v1/members/{human_id}/role {role, from_role?}` → 200;
  `DELETE /v1/members/{human_id}` → 204. Errors: 400 `bad_role` / `bad_json`,
  403 `forbidden`, 404 `not_found`, 409 `last_owner` / `role_changed`.
- **FR-008** The WUI shows the signed-in member's role in the user menu and
  hides what the role may not do: the channel "+" without `channels.manage`.
  Every phase-1 role holds `notes.send`, so the composer is not gated yet; a
  tester's `@agent` send is refused by the hub (`forbidden`). Hiding is
  convenience and fails open (no `/v1/view/me` answer = everything shown);
  the hub check is the control.
- **FR-009** Operator tooling carries the roles: `spool hub-invite --role`,
  `do_spl_hub_invite INVITE_ROLE=`, `do_spl_tenant_member_role MEMBER_ROLE= /
  FROM_ROLE=` accept the six ids (and the two legacy names).
- **FR-010** In-tenant billing (M4 seat purchase, plan changes) gates on
  `billing.manage` through the same authorizer (M4 lane).

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
- **Several roles per member**: a `tenant_member_roles (tenant_id, human_id,
  role_id)` table; the authorizer takes the union. `tenant_memberships.role`
  becomes the primary role.
- **Role editor in the WUI** (members page, invite dialog with a role
  picker) on top of FR-007.
- **Scoped grants** (per channel / per box), and an **audit trail** table the
  `audit.read` permission reads.
- **Agent-side permissions** (a box agent's allowed kinds / targets).

<!-- version: 1.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T17:10:00Z -->
