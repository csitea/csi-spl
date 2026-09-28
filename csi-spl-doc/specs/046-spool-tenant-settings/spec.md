# Feature Specification: Tenant settings (admins only)

**Feature ID**: `046-spool-tenant-settings` · **Milestone**: M3 · **Status**: In progress (`tasks.md`)
**Created**: 2026-09-28 · **Lane**: TENANT-SETTINGS (hub + DB + browser) · **Issue**: SPL-1037 (epic 43)
**Authority**: this file. It extends `025-spool-tenant-rbac` (the roles and permissions) and reuses
`023` §3.4 (the Settings layout) and the CLE-34969 Users page (`025` FR-012).

## 1. The owner's requests, verbatim

prd t1 topic `3b826d0d-37cf-4b5c-bfb9-4e96259898cb`, 2026-09-28:

> we do not seem to have a UI to change the settings of the tenant, such as adding users etc.

> the UI should behave similarly to how the personal settings work, but the icon should be in the
> bottom-left corner of the screen on desktop

> it should have a section for users where the admins and the biz_owners of the tenant can CRUD users

## 2. What the hub already exposed (measured on trunk `f19fba67`)

`grep -rn 'mux.HandleFunc("' internal/hub` lists every route. Of the tenant administration that
existed only as csi-spl-orc actions, this is what a browser could already reach:

| need | orc action today | hub route before 046 | 046 |
|---|---|---|---|
| list members + pending invites | `do_spl_hub_member_list` | `GET /v1/members` (members.invite) | adds `last_seen` |
| invite by email (mails it) | `do_spl_hub_invite` | `POST /v1/members/invites` | resend = the same POST (upsert re-mails) |
| change a role | `do_spl_tenant_member_role` | `PUT /v1/members/{id}/role` | - |
| remove a member | - | `DELETE /v1/members/{id}` | - |
| revoke an invite | - | `DELETE /v1/members/invites?email=` | - |
| create an account directly | `do_spl_tenant_member_add` (existing human only) | none | `POST /v1/members` |
| edit name / locale / disable | `do_spl_human_locale` | none | `PATCH /v1/members/{id}` |
| seated agents + online | `do_spl_desk_up` | `GET /v1/view/roster` (topics.read) | reused as is |
| fallback responders (SPL-997) | `do_spl_tenant_responders` | none | `GET/PATCH /v1/tenant/settings` |
| tenant display name (SPL-959) | `do_spl_tenant_display_name` | none | `GET/PATCH /v1/tenant/settings` |
| default locale | none (no column) | none | rdb `0074`, `GET/PATCH /v1/tenant/settings` |
| every channel, private ones too | - | `GET /v1/view/channels` (the caller's own only) | `GET /v1/tenant/channels` |
| a channel's no-fallback flag | `do_spl_channel_fallback` | none | `PATCH /v1/tenant/channels/{ch}` |
| archive a channel | - | `DELETE /v1/channels/{ch}` (creator only) | `DELETE /v1/tenant/channels/{ch}` |

## 3. Permissions (first)

The hub checks a PERMISSION, never a role name (`025` FR-005). 046 adds no permission; it uses
the two that already exist and grants one of them to one more role.

| permission | biz_owner | admin | product_owner | developer, tester, others |
|---|---|---|---|---|
| `tenant.settings` | yes | yes | - | - |
| `members.invite` | **yes (new, rdb 0074)** | yes | - | - |
| `members.roles` | yes | yes | - | - |

`members.invite` returns to biz_owner: rdb `0039` had made it the admin's only ("only the admin will
be able to add users", 2026-09-25); the 2026-09-28 order above names admins AND biz_owners. With it a
biz_owner holds every permission, so it may manage every role; an admin still cannot manage a
biz_owner (biz_owner holds `billing.manage`, admin does not: `025` §3.4 rule 2).

| route | permission | extra rule |
|---|---|---|
| `GET /v1/tenant/settings` | `tenant.settings` | - |
| `PATCH /v1/tenant/settings` | `tenant.settings` | responder ids are agent ids, at most 20 |
| `GET /v1/tenant/channels` | `tenant.settings` | private channels the caller is not in are listed too |
| `PATCH /v1/tenant/channels/{ch}` | `tenant.settings` | - |
| `DELETE /v1/tenant/channels/{ch}` | `tenant.settings` | a default channel is refused (409) |
| `GET /v1/members` | `members.invite` | (existing) |
| `POST /v1/members` | `members.invite` | the role must be grantable; an existing account is 409 `account_exists` (invite it) |
| `PATCH /v1/members/{id}` | `members.invite` | the caller's role covers the member's; not self for `disabled`; name and locale only for an account that belongs to this tenant alone (409 `shared_account`) |

Every route answers 403 `forbidden` with the missing `permission` to anyone else - a plain member
included. The WUI hiding the entry is convenience only.

## 4. Behaviour

### 4.1 Entry and layout

- Desktop: a building icon in the **bottom-left corner** (the sidebar footer), shown only when
  `/v1/view/me` lists `tenant.settings` or `members.invite`. It opens `/tenant-settings`.
- Phones: the avatar (user) menu has a "Tenant settings" row under the same rule.
- `/tenant-settings` is the Settings layout (`023` §3.4, SPL-993): a section list on the left, the
  section on the right; on a phone (<= 820 px) the list is level 2 and a section opens at level 3.
- Sections: **Members**, **Agents**, **Channels**, **General**. A section the caller has no
  permission for is not listed.

### 4.2 Members (users CRUD)

- **Read**: the list (name, email, role, joined, last seen, disabled) and pending invites.
- **Create**: invite by email with a role (the invite mail), or create an account directly with a
  name, email, role and an optional initial password the admin passes on themselves (never mailed).
  Without a password the person signs in with a provider on that address or uses "forgot password".
- **Update**: role; name and locale (only for an account that is in this tenant alone: a person who
  is in other tenants owns their own profile); disable / enable - a per-tenant suspension
  (`tenant_memberships.disabled_at`, rdb 0074): the member keeps their account and other tenants,
  and holds no role here while disabled.
- **Delete**: remove from the tenant, after a confirm. Resend or revoke a pending invite.

### 4.3 Agents

The tenant's boxes and their agents with online state (`/v1/view/roster`), and the fallback
responder list (SPL-997) - an ordered list of agent ids, editable (add, remove, move up / down).

### 4.4 Channels

Every channel of the tenant: name, visibility (default / public / private), members, agents, the
no-fallback flag (editable), and Archive (soft delete, `041`-style, with a confirm). Default
channels cannot be archived.

### 4.5 General

The tenant display name (the tenant switcher and the tab title) and the default locale (one of the
19 WUI locales, or unset = the hub default). The default locale is the language of the invite mail
when the admin's own locale is not sent.

## 5. Proof

- Hub: per-route tests, including a developer control that gets 403 on every 046 route.
- WUI: e2e on the mock hub; a live proof in prd tenant `e2e`: an admin invites, changes the role,
  removes; a plain member sees no Tenant settings entry and gets 403 from the routes (the control).
