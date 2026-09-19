# Tasks: tenant roles and permissions (025)

**Feature**: `specs/025-spool-tenant-rbac` · **Created**: 2026-09-19 · **Lane**: CLE-3414

`[x]` Implemented (sha + check) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1: model

- [ ] T001 rdb `0021_tenant_rbac.sql` (FR-001, SEC-RBAC-4).
- [ ] T002 `internal/rbac`: `Defaults`, `Authorizer` (FR-004), grant rules (§3.4).
- [ ] T003 store: role ids, legacy mapping, bootstrap = tenant-owner role, `RolePermissions`, `SetMemberRole`, `RemoveMember` with the last-owner guard (FR-002, FR-003), memory + Postgres; `TestRBACSeedMatchesDefaults`.

## Phase 2: hub enforcement

- [ ] T010 view door + WUI socket `threads.read`; WUI note `notes.send`; dispatch `agents.command`; channel create `channels.manage` (FR-005).
- [ ] T011 `GET /v1/view/me` (FR-006).
- [ ] T012 members API: invite, role change, remove (FR-007) with CONTROL tests per role.

## Phase 3: tooling + WUI

- [ ] T020 `spool hub-invite --role`, `do_spl_hub_invite`, `do_spl_tenant_member_role` take the new ids (FR-009).
- [ ] T021 WUI: role in the user menu; channel "+" and composer hidden without the permission (FR-008).

## Phase 4: M4 seam

- [ ] T030 In-tenant billing / seat purchase gates on `billing.manage` (FR-010; M4 lane).

## Phase 5: deploy + t1

- [ ] T040 0021 applied dev then prd (`do_spl_db_bootstrap`, env SA), then hub roll (tag + 030) and WUI.
- [~] T041 t1 seating (§8): tenant-owner invite sent dev + prd with `do_spl_hub_invite INVITE_ROLE=owner` (env SAs, 2026-09-19T16:38Z); personal account -> developer after T040 (`do_spl_tenant_member_role`).

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T17:10:00Z -->
