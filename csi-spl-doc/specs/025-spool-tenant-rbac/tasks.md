# Tasks: tenant roles and permissions (025)

**Feature**: `specs/025-spool-tenant-rbac` · **Created**: 2026-09-19 · **Lane**: CLE-3414

`[x]` Implemented (sha + check) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1: model

- [x] T001 rdb `0021_tenant_rbac.sql` (FR-001, SEC-RBAC-4) + a legacy-name trigger (old images / scripts writing owner|member). 714f3cb. Check: `TestRBACSeedMatchesDefaults`, `TestRBACRLSSystemRolesReadOnly`, `TestRBACLegacyRoleTrigger`, CLE-3416's `TestRLSPoliciesFailClosed` (pg 16, non-superuser). Note: shares the 0021 prefix with `0021_rls_fail_closed.sql` (CLE-3416, pushed concurrently); mine was already applied live, so it keeps its filename; both apply orders verified.
- [x] T002 `internal/rbac`: `Defaults`, `Authorizer` (FR-004), `Covers` (§3.4), `Fixed` (rig seam). 714f3cb. Check: `TestDefaultsMatrix`, `TestAuthorizerCacheAndFailClosed`, `TestCoversNoEscalation`.
- [x] T003 store: role ids, legacy mapping, bootstrap = biz_owner, `TenantRoles`, `SetMemberRole`, `RemoveMember` with the last-owner guard under the tenant lock (FR-002, FR-003), memory + Postgres. 714f3cb. Check: `TestTenantRolesAndLastOwner` (both drivers).

## Phase 2: hub enforcement

- [x] T010 every browser door (`humanTenant`: view, files, search, WUI socket, channels) `threads.read`; WUI note `notes.send`; dispatch `agents.command` (per send, so a demotion bites on an open socket); channel create `channels.manage` (FR-005). Check: `TestRBACPerRoleEntryPoints` (CONTROL mutation: `allowed` forced true turns it red).
- [x] T011 `GET /v1/view/me` (FR-006). Check: `TestRBACPerRoleEntryPoints`.
- [x] T012 members API: invite, role change, remove (FR-007) + CORS preflight. Check: `TestRBACMembersAPI` (20 cases incl. escalation, stronger target, last owner, cross-tenant owner). Invitation email from the hub route: not wired (operator `hub-invite-mail` resends), phase 2.

## Phase 3: tooling + WUI

- [x] T020 `spool hub-invite --role` (714f3cb), `do_spl_hub_invite`, `do_spl_tenant_member_role` take the new ids (FR-009). 0c7a4a7. Check: `adhoc-harvest-actions.tst.sh`, `hub-invite-email-send.tst.sh`.
- [x] T021 WUI: `stores/access` reads `GET /v1/view/me` (fails open), the role under the name in the user menu (`user_menu.role`, `role.*` in 19 locales), channel "+" only with `channels.manage` (FR-008). Check: `tests/unit/access.test.mjs` (CONTROL: tester is offered neither channel create nor agent commands), unit runner 35/35, `nuxi typecheck` rc 0.

## Phase 4: M4 seam

- [ ] T030 In-tenant billing / seat purchase gates on `billing.manage` (FR-010; M4 lane).

## Phase 5: deploy + t1

- [x] T040 0021 applied dev 16:51Z then prd 16:52Z (`do_spl_db_bootstrap`, env SAs). Hub 0.1.12 (253d5d0, contains 3ab2dd6) rolled dev + prd by CLE-3355 (`/version` both, n=1). WUI 977a080 deployed dev + prd (30 run 35457072338).
- [x] T042 `do_spl_rbac_probe` (aaff4db): dev t1 live, 17:17Z, n=1: HUM-4 role developer, channels.manage gate passes (400 bad_channel on an invalid name), members.roles gate 403 forbidden - agrees with `/v1/view/me`. prd: anonymous only (t1 is a real tenant): `/v1/view/me` and `PUT /v1/members/HUM-0/role` 401 on both api hosts.
- [~] T041 t1 seating (§8): tenant-owner invite sent dev + prd with `do_spl_hub_invite INVITE_ROLE=owner` (env SAs, 16:38Z; now `biz_owner` via 0021); personal account set to developer dev + prd with `do_spl_tenant_member_role MEMBER_ROLE=developer FROM_ROLE=biz_owner` (16:57Z). Open: the tenant owner accepts by signing in (until then t1 has no biz_owner member).

## Phase 6: owner orders 2026-09-25 (spec §1.1, CLE-34967)

- [x] T050 roles `biz_customer`, `regular_user` (= developer's grants) and `members.invite` admin-only: rdb 0039 + `rbac.Defaults`/`RoleIDs` + CLI help + orc `SPL_ROLE_IDS` + WUI `ROLE_IDS`, `role.*` in 19 locales, DM-row "Remove" gated on members.invite. Check: `TestDefaultsMatrix` (only admin holds members.invite; both new roles = developer), `TestRBACMembersAPI` (biz_owner cannot invite, remove or make an admin; admin invites both new roles), `hub-pg.tst.sh` (`TestRBACSeedMatchesDefaults` against 0039), `sidebar-row-menu.test.mjs`.
- [ ] T051 0039 applied dev + prd (`do_spl_db_bootstrap`), hub + WUI rolled on both.
- [ ] T052 prd t1 memberships (named actions only): invites as biz_customer / regular_user, a developer -> biz_customer, the owner's second account developer -> admin.

<!-- version: 1.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T15:05:00Z -->
