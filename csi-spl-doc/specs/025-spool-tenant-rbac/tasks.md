# Tasks: tenant roles and permissions (025)

**Feature**: `specs/025-spool-tenant-rbac` · **Created**: 2026-09-19 · **Lane**: CLE-3414

`[x]` Implemented (sha + check) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1: model

- [x] T001 rdb `0021_tenant_rbac.sql` (FR-001, SEC-RBAC-4) + a legacy-name trigger (old images / scripts writing owner|member). 714f3cb. Check: `TestRBACSeedMatchesDefaults`, `TestRBACRLSSystemRolesReadOnly`, `TestRBACLegacyRoleTrigger`, CLE-3416's `TestRLSPoliciesFailClosed` (pg 16, non-superuser). Note: shares the 0021 prefix with `0021_rls_fail_closed.sql` (CLE-3416, pushed concurrently); mine was already applied live, so it keeps its filename; both apply orders verified.
- [x] T002 `internal/rbac`: `Defaults`, `Authorizer` (FR-004), `Covers` (§3.4), `Fixed` (rig seam). 714f3cb. Check: `TestDefaultsMatrix`, `TestAuthorizerCacheAndFailClosed`, `TestCoversNoEscalation`.
- [x] T003 store: role ids, legacy mapping, bootstrap = biz_owner, `TenantRoles`, `SetMemberRole`, `RemoveMember` with the last-owner guard under the tenant lock (FR-002, FR-003), memory + Postgres. 714f3cb. Check: `TestTenantRolesAndLastOwner` (both drivers).

## Phase 2: hub enforcement

- [x] T010 every browser door (`humanTenant`: view, files (session read), search, WUI socket, channels) `threads.read` (renamed `topics.read`, rdb 0029); WUI note `notes.send`; dispatch `agents.command` (per send, so a demotion bites on an open socket); channel create `channels.manage` (FR-005). Check: `TestRBACPerRoleEntryPoints` (CONTROL mutation: `allowed` forced true turns it red).
- [x] T011 `GET /v1/view/me` (FR-006). Check: `TestRBACPerRoleEntryPoints`.
- [x] T012 members API: invite, role change, remove (FR-007) + CORS preflight. Check: `TestRBACMembersAPI` (20 cases incl. escalation, stronger target, last owner, cross-tenant owner). Invitation mail from the hub route: wired by T060 (151915b, `hub/rbac.go` `mailInvite`).

## Phase 3: tooling + WUI

- [x] T020 `spool hub-invite --role` (714f3cb), `do_spl_hub_invite`, `do_spl_tenant_member_role` take the new ids (FR-009). 0c7a4a7. Check: `adhoc-harvest-actions.tst.sh`, `hub-invite-email-send.tst.sh`.
- [x] T021 WUI: `stores/access` reads `GET /v1/view/me` (fails open), the role under the name in the user menu (`user_menu.role`, `role.*` in 19 locales), channel "+" only with `channels.manage` (FR-008). Check: `tests/unit/access.test.mjs` (CONTROL: tester is offered neither channel create nor agent commands), unit runner 35/35, `nuxi typecheck` rc 0.

## Phase 4: M4 seam

- [ ] T030 In-tenant billing / seat purchase gates on `billing.manage` (FR-010; M4 lane).

## Phase 5: deploy + t1

- [x] T040 0021 applied dev 16:51Z then prd 16:52Z (`do_spl_db_bootstrap`, env SAs). Hub 0.1.12 (253d5d0, contains 3ab2dd6) rolled dev + prd by CLE-3355 (`/version` both, n=1). WUI 977a080 deployed dev + prd (30 run 35457072338).
- [x] T042 `do_spl_rbac_probe` (aaff4db): dev t1 live, 17:17Z, n=1: HUM-4 role developer, channels.manage gate passes (400 bad_channel on an invalid name), members.roles gate 403 forbidden - agrees with `/v1/view/me`. prd: anonymous only (t1 is a real tenant): `/v1/view/me` and `PUT /v1/members/HUM-0/role` 401 on both api hosts.
- [~] T041 t1 seating (§8): tenant-owner invite sent dev + prd with `do_spl_hub_invite INVITE_ROLE=owner` (env SAs, 16:38Z; now `biz_owner` via 0021); personal account set to developer dev + prd with `do_spl_tenant_member_role MEMBER_ROLE=developer FROM_ROLE=biz_owner` (16:57Z). prd: closed by T052 (HUM-10 is prd t1's biz_owner). Open: dev t1's biz_owner seat is unverified in this file.

## Phase 6: owner orders 2026-09-25 (spec §1.1, CLE-34967)

- [x] T050 roles `biz_customer`, `regular_user` (= developer's grants) and `members.invite` admin-only: rdb 0039 + `rbac.Defaults`/`RoleIDs` + CLI help + orc `SPL_ROLE_IDS` + WUI `ROLE_IDS`, `role.*` in 19 locales, DM-row "Remove" gated on members.invite. Check: `TestDefaultsMatrix` (only admin holds members.invite; both new roles = developer), `TestRBACMembersAPI` (biz_owner cannot invite, remove or make an admin; admin invites both new roles), `hub-pg.tst.sh` (`TestRBACSeedMatchesDefaults` against 0039), `sidebar-row-menu.test.mjs`.
- [x] T051 0039 applied dev 14:54Z then prd 14:55Z (`do_spl_db_bootstrap` DRY_RUN=0, env SAs); `rbac_roles` on both reads 8 roles, members.invite on admin only, biz_customer = regular_user = developer (n=1 query per env). Hub 0.5.0 (0bf7bdd) on dev + prd (`/version`, 20 run 36150599840); WUI 0bf7bdd dev + prd (30 run 36150599381).
- [x] T052 prd t1 (named actions only, 14:56-14:58Z, as the prd SA): `do_spl_tenant_member_role` HUM-23 developer -> biz_customer, HUM-13 developer -> regular_user, HUM-5 developer -> admin (one role per membership, §1.1: the owner's second account; HUM-10 stays biz_owner). `do_spl_hub_invite` six invites (one biz_customer, five regular_user), each mailed once (`delivered:true`, mail_count 1); one accepted at 14:58Z as regular_user.

## Phase 7: the admin's Users page (spec §1.2, CLE-34969)

- [x] T060 hub: `GET /v1/members`, `DELETE /v1/members/invites?email=`, the invitation mail on `POST /v1/members/invites`, `409 last_admin` (memory + Postgres) and `409 self` (FR-011, FR-012). 151915b. Check: `TestMembersAdminAPI` (CONTROL: every role but admin 403 `members.invite` on list, invite, revoke, remove; anonymous and another tenant's admin 403), `TestMemberDirectory` (CONTROL: another tenant's rows never listed nor revocable, a revoked invite no longer admits), `TestTenantRolesAndLastOwner` last-admin controls - memory and Postgres (local postgres:16, n=1).
- [x] T061 WUI: Users icon + `/users` + `UserEditPane`, 19 locales (FR-012). 71ffc23. Check: `tests/unit/tenant-users.test.mjs` (CONTROL: no `/v1/view/me` answer shows NO Users entry), `tests/e2e/users-admin.test.mjs` 12/12 on the mock bundle (`PROVE_RED=no-remove` -> check 8 FAILs), in `test:e2e`.
- [x] T062 live 2026-09-25: hub 0.5.2 (e7453c6, contains 151915b) on dev + prd (`/version`); WUI 0da770f on dev + prd (`build.json`, 30 run 36157471180). dev t1, `tests/e2e/users-admin-live.proof.mjs` 13/13 (n=1, 16:00Z): the dev test account m3-e2e-outsider (seated admin by `do_spl_hub_invite INVITE_ROLE=admin`, it stays the dev t1 admin) sees Users, opens HUM-4's row, re-roles it and back, removes it, invites it back (mail sent), invites + revokes a throwaway address; CONTROL: HUM-4 (developer) sees no Users icon, `GET /v1/members` 403 `members.invite`. prd (read-only): `do_spl_hub_member_list` t1 reads HUM-5 = admin (the owner's admin account: its `/v1/view/me` lists members.invite, so the entry renders; not signed in by an agent); CONTROL_ONLY=1 in the prd test tenant `e2e` 3/3: no Users icon, 403 `members.invite`. The first dev run was 11/12: the proof raced an older open invite, and the invite notice was wiped when the pane moved to the new row (fixed in 0da770f).

## Spec sync 2026-09-25 (CLE-34983, tree bbe04d26)

- [x] T070 spec <-> code audit, n = 10 permissions + every FR and task row. Implemented claims with no code: none. Fixed in the docs: `threads.read` -> `topics.read` (0029); §3.1/FR-005 list the edit, reaction, channel-member-remove and channel fan-out gates the code enforces (`grep -rn 'rbac\.' internal/hub`); FR-006 `tenant_id`; FR-007 `bad_email`; FR-009 eight ids; §9 role picker shipped; T012 mail wired (T060). Status: FR-010 / T030 stays **Planned** (no in-tenant billing route: `internal/payments/handler.go` registers only plan, checkout, claim and webhooks). `billing.manage`, `tenant.settings`, `keys.manage`, `audit.read` are seeded and checked nowhere, as §3.1 says.

<!-- version: 1.3.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:30:00Z -->
