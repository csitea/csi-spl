# Tasks: 046 Tenant settings (SPL-1037)

Spec: `spec.md`. Lane CLE-35069. `[x]` = on trunk; the sha is the commit that landed it.

## Hub + DB

- [x] T001 spec with the measurement (§2) and the permission table first (§3) - `0fafdec2`
- [x] T002 rdb `0074_tenant_settings.sql`: `tenants.default_locale`, `tenant_memberships.disabled_at`,
      biz_owner regains `members.invite`; `rbac.Defaults` in step (TestRBACSeedMatchesDefaults).
      Applied dev + prd with `do_spl_db_bootstrap` BEFORE the hub code landed - `1936e47f`
- [x] T003 store `TenantSettings` (memory + postgres): `TenantConfig`, `SetTenantConfig`,
      `SetMemberDisabled` (last-owner / last-admin guards), `MemberState`; a suspended membership
      is not a member (`MemberRole`, `Memberships`, the guards' counts) - `1936e47f`
- [x] T004 hub `GET/PATCH /v1/tenant/settings`, `GET /v1/tenant/channels`,
      `PATCH/DELETE /v1/tenant/channels/{ch}`, `PATCH /v1/members/{id}`, `last_seen` +
      `suspended` on `GET /v1/members`, the invite mail falls back to the tenant default locale -
      `1936e47f`
- [x] T005 tests: `TestTenantSettingsForbidden` (every role without the permission gets 403 on
      every 046 route; another tenant's admin too), `...General`, `...Channels`, `...MemberPatch`;
      store `TestTenantRolesAndLastOwner` (suspension, per-tenant) - `1936e47f`
- [ ] T006 `POST /v1/members`: create an account directly (name, email, role, optional initial
      password). Open: an admin-set password on an address the admin does not own must not let
      the admin into that person's account once they sign in with a provider (identity linking,
      CLE-3451).

## WUI

- [x] T010 (`ef53505b`) `/tenant-settings` = the Settings layout (sections by permission), the bottom-left
      building icon (sidebar foot) + the avatar-menu row
- [x] T011 Members = `<TenantUsers embedded />` (the /users list and pane, shared): suspend /
      restore, name + language, last seen, resend invite
- [x] T012 Agents (roster + online, responder list editor), Channels (table, no-fallback,
      archive with a confirm), General (name, default locale)
- [x] T013 unit `tenant-settings.test.mjs`, e2e `tenant-settings.test.mjs` (mock bundle, 18/18; in the
      10 gate; `PROVE_RED=no-archive` turns check 11 red). Mocks load lazily
      (`tenant-users-mock.mjs`, `tenant-settings-mock.mjs`): initial JS 159.8 KB <= 160
- [x] T014 live proof in prd tenant `e2e` (`tests/e2e/tenant-settings-live.proof.mjs`, WUI
      `ef53505b`, hub `fc264bab`, 2026-09-28, 19/19): the biz_owner HUM-1 opens the bottom-left
      icon, all four sections load, invites the second test account as tester (the mail went
      out); that member signs in and is the CONTROL - no icon, no menu row, 403 `tenant.settings`
      on /v1/tenant/settings + /v1/tenant/channels, 403 `members.invite` on /v1/members, the page
      says not allowed; the biz_owner changes the role to developer (the hub agrees) and removes
      it; the member's /v1/view/me is 403 at once. The tenant ends as it began (1 member).
