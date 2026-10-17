# Data model: several roles per member, the DevOps and Operator roles (025 §10)

**Feature**: `specs/025-spool-tenant-rbac` · **Created**: 2026-10-16 · **Lane**: c-287 · **Issue**: SPL-2192
**Behaviour**: `spec.md` §10. This file holds the tables, the migrations and
the Go and API shapes only. Status: **row R1 built** (rdb
`0201_tenant_member_roles.sql`, the rbac and store shapes of §3; SPL-2203);
row R2 built (the §4 member routes and `/v1/view/me` `roles[]`; SPL-2293),
except `POST /v1/members/invites roles[]`: the store keeps one role per
invite, so `invites[].roles` answers `{role}`; R3-R7 planned, not built yet.

## 1. Today (measured on `bba5cedb6`)

| what | where | shape |
|---|---|---|
| a member's role | `tenant_memberships.role` | `text NOT NULL`, FK `rbac_roles.role_id` (rdb 0021): ONE role per membership |
| an invite's role | `tenant_invites.role`, PK `(tenant_id, email)` (rdb 0006) | `text NOT NULL`, FK as above |
| the role table | `rbac_roles (role_id, tenant_id NULL, tenant_owner, description)` | system roles have `tenant_id IS NULL` |
| the store's answer | `rbac.Source.MemberRole(ctx, hum, tenant) (string, error)` | `internal/rbac/rbac.go` |
| the authorizer's answer | `rbac.Access{HumanID, Role, TenantOwner, Perms}` | one role's grants |
| the operator workspace | `tenants.is_operator` (rdb 0116), unique partial index | t1 on prd (c-001, n=1) |

The highest migration prefix is `0200_fx_rates.sql`
(`ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1`); the build rows take
the next free prefixes when they land.

## 2. The model

### 2.1 Choice: a join table; the `role` column stays as the primary role

| option | for | against |
|---|---|---|
| `tenant_memberships.roles text[]` | one column, one read | no FK per array element (a trigger has to do it); every read of `m.role` (spec §10.4) changes at once |
| **`tenant_member_roles` join table, `role` kept as the primary** (chosen) | an FK per row to `rbac_roles`; RLS in the 0014 shape; every exclusive-role read (`demo_user`, `channel_guest`) stays correct unchanged; 025 §9 already named this table | two writes per change, kept in one transaction by the store and backed by a trigger |

So:

- `tenant_memberships.role` stays `NOT NULL` and keeps its meaning for every
  reader that asks "what KIND of member is this": the primary role, shown
  first, the one a demo, guest or bootstrap path sets.
- `tenant_member_roles` holds the member's FULL role set, the primary
  included. Invariant: `role ∈ set`, always.
- Permissions are the union over the set (spec §10.2).

### 2.2 Tables (row R1, one migration)

```sql
CREATE TABLE tenant_member_roles (
    tenant_id   text        NOT NULL,
    human_id    text        NOT NULL,
    role_id     text        NOT NULL REFERENCES rbac_roles (role_id),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    granted_by  text        NOT NULL DEFAULT '',
    PRIMARY KEY (tenant_id, human_id, role_id),
    FOREIGN KEY (tenant_id, human_id)
        REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE
);

CREATE TABLE tenant_invite_roles (
    tenant_id   text NOT NULL,
    email       text NOT NULL,
    role_id     text NOT NULL REFERENCES rbac_roles (role_id),
    PRIMARY KEY (tenant_id, email, role_id),
    FOREIGN KEY (tenant_id, email)
        REFERENCES tenant_invites (tenant_id, email) ON DELETE CASCADE
);
```

`granted_by` is a `HUM-*`, `operator` (the env service account path),
`migration` (the backfill), `primary` (a row trigger 1 wrote), `clone` (an
act-as clone's copy of its target's set, `StartClone`) or `''` (a store
write, which names no actor yet). Both tables carry `tenant_scope` + `operator_scope` policies in
the 0014 shape, `FORCE ROW LEVEL SECURITY` (SEC-RBAC-4). Backfill in the same
migration: one row per existing membership and per existing invite,
`role_id = role`, `granted_by = 'migration'`.

### 2.3 Triggers

1. **Primary kept in the set** (R1; `AFTER INSERT OR UPDATE OF role ON
   tenant_memberships`, the same on `tenant_invites`): insert
   `(tenant, human, NEW.role)` if absent; on an update from Q to R, delete Q
   from the set, insert R; every other role in the set is kept. This is the
   backstop for the operator shell actions that still write
   `tenant_memberships.role` with `psql` (074 T007): they cannot break the
   invariant.
2. **Exclusive roles** (R1; `BEFORE INSERT ON tenant_member_roles` and
   `tenant_invite_roles`): a set holding `demo_user` or `channel_guest` holds
   nothing else. A violation raises SQLSTATE `23514`; the store answers
   `400 bad_role`.
3. **Operator-only roles** (R3, once `rbac_roles.operator_only` exists): a
   row naming an `operator_only` role in a workspace that is not the
   `tenants.is_operator` row raises `23514`; the store answers
   `400 operator_only_role`.

### 2.4 The role table (row R3, one migration)

```sql
ALTER TABLE rbac_roles ADD COLUMN operator_only boolean NOT NULL DEFAULT false;
```

R3 seeds `devops` ("DevOps") and `operator` ("Operator"): `tenant_id NULL`,
`tenant_owner false`, `operator_only true`; the `operator.*` permission rows
of spec §10.3; and their grants. `rbac.Defaults` changes in the same commit;
`TestRBACSeedMatchesDefaults` keeps the two equal.

### 2.5 Seating in the R3 migration (nobody loses a power)

In the operator workspace only, at apply time:

```sql
INSERT INTO tenant_member_roles (tenant_id, human_id, role_id, granted_by)
SELECT m.tenant_id, m.human_id, 'devops', 'migration'
  FROM tenant_memberships m
  JOIN tenants t    ON t.tenant_id = m.tenant_id AND t.is_operator
  JOIN rbac_roles r ON r.role_id = m.role
 WHERE m.disabled_at IS NULL
   AND (m.role = 'admin' OR r.tenant_owner)
ON CONFLICT DO NOTHING;
```

- Every enabled `admin` of the operator workspace holds the operator routes
  today (`internal/hub/operator_workspaces.go:103`); each keeps them, now as
  `devops`.
- The operator workspace's tenant owner (`biz_owner`; HUM-10 on prd t1 per
  `tasks.md` T052) gains `devops`: the owner loses nothing and holds it on
  the account they sign in with.
- Before the apply, the R3 lane reads the rows this select returns on dev and
  prd (read-only, `do_spl_hub_member_list`) and reports n and the HUM ids in
  its result. The migration seats nobody else.

## 3. Go shapes

| today | after |
|---|---|
| `rbac.Source.MemberRole(ctx, hum, tenant) (string, error)` | add `MemberRoles(ctx, hum, tenant) ([]string, error)`: primary first, the rest sorted; `ErrNotMember` when none. `MemberRole` stays and answers the primary, for the exclusive-role readers |
| `rbac.Access{Role}` | `Access{Role, Roles []string}`: `Role` = primary, `Roles` = the set, `Perms` = the union, `TenantOwner` = any role in the set is a tenant owner |
| — | `func (a Access) Has(role string) bool`; `func (a Access) HasAny(roles ...string) bool` |
| `store.SetMemberRole(ctx, tenant, hum, role, from)` | add `SetMemberRoles(ctx, tenant, hum string, roles []string, primary string, from []string)`; `from` is the optimistic check (`409 role_changed`), as `from_role` is today. `SetMemberRole` stays as a one-role wrapper |
| `store.Member{Role}`, `store.Membership{Role}` | add `Roles []string` |
| `rbac.Fixed("admin")` (test seam) | add `rbac.FixedSet{"developer", "devops"}` |
| `rbac.Source` | add `rbac.SetSource` (a `Source` that also answers `MemberRoles`): the `Authorizer` grants the union when its source is one (`store.RBACSource` is), the primary alone otherwise; `rbac.Exclusive(role)` names `demo_user` / `channel_guest` |

Built in R1 (SPL-2203): the set rides the door's one membership read (the
request memo and the 5 s door cache hold it), so `MemberRoles` after
`MemberRole` costs no round trip; the last-owner / last-admin guards
(`SetMemberRole(s)`, `RemoveMember`, suspension, `access_until`) count over
sets; `ListMembers` and `Memberships` carry `Roles`; the embed staff seating
and the hours sweep read the set (§10.4 A21, A22); `StartClone` copies the
target's set. The other checks of §10.4 A (A1-A20, W1-W6, O1) are rows R2-R5.

## 4. API shapes

| route | today | after |
|---|---|---|
| `GET /v1/view/me` | `role` | `role` (primary) + `roles[]`; also answered for a member who holds no `topics.read` (spec §10.3 rule 6) |
| `GET /v1/members` | `members[].role`, `invites[].role` | + `members[].roles[]`, `invites[].roles[]`, `roles[].operator_only` |
| `PUT /v1/members/{human_id}/role {role, from_role?}` | sets the one role | kept as a one-role call: the member's non-operator roles become `{role}`; operator-only roles in the set stay (only `operator.roles` touches them, spec §10.3 rule 4) |
| — | — | `PUT /v1/members/{human_id}/roles {roles[], primary?, from_roles?}` → 200; 400 `bad_role` / `operator_only_role`, 403 `forbidden`, 409 `last_owner` / `last_admin` / `role_changed` |
| `POST /v1/members/invites {email, role?}` | one role | + `roles[]?` (`role`, when given, is the primary) |
| — | — | `PUT /v1/operator/staff/{human_id} {add[], remove[]}` → 200: only `devops` / `operator`, permission `operator.roles`; 409 `last_devops` |

<!-- version: 1.0.1 · updated: 2026-10-17 · last-edit: 2026-10-17T01:22:20Z -->
