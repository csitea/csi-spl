# Feature Specification: Admin "view as / sign in as" a user (impersonation)

**Feature ID**: `054-spool-admin-view-as` · **Milestone**: M3 · **Status**: Blocked on owner (`§8`)
**Created**: 2026-09-30 · **Lane**: ADMIN-VIEW-AS (hub + DB + WUI) · **Issue**: TBD (owner topic `18597eaa-89f9-4cf9-a3ef-ef7999659146`)
**Authority**: this file. It extends `025-spool-tenant-rbac` (roles + permissions), `026-spool-tenant-from-identity`
(the tenant-switch cookie re-issue it mirrors) and `046-spool-tenant-settings` (the Users page that hosts the entry point).

> **Security-sensitive, public repo, live multi-tenant product. SPEC FIRST — nothing is built until the owner
> answers `§8`.** This document is the design and the blocker only.

## 1. The owner's requests, verbatim

prd t1 topic `18597eaa-89f9-4cf9-a3ef-ef7999659146` (HUM-10):

> the admins should be able to impersonate a user to find out whether or not some permissions work etc.

> so the Admins of the tenants should have this sign-as feature ..

So: a feature for **tenant admins** (`biz_owner` / `admin` of a tenant), scoped to **their own tenant**, that lets
them experience the product as one of their members — primarily to verify that permissions/roles behave as intended.

## 2. What already exists (measured on trunk, `csi-spl-api/.../internal`)

The session, RBAC and RLS model this feature must not weaken:

| concern | today | file |
|---|---|---|
| session | HMAC-signed cookie; claims `sub, email, name, hum (HUM-*), t (tenant), iat, exp` | `internal/auth/token.go` §`Session` L81 |
| who am I | `SessionFromRequest()` verifies MAC + expiry | `internal/auth/handler.go` L1240 |
| active tenant | `ActiveTenant()` resolves `t` claim, checks membership | `internal/auth/tenant.go` L62 |
| tenant switch (the template) | `switchTenant()` re-issues the cookie with a new `t`, **keeps the old expiry**, refuses non-members | `internal/auth/tenant.go` L197 |
| per-tenant role | `rbac.Access{HumanID, Role, TenantOwner, Perms}`; roles `biz_owner..regular_user` | `internal/rbac/rbac.go` L35, L119 |
| permission guard | `Server.permit(w, r, tenant, hum, perm)` → 403 naming the missing perm | `internal/hub/rbac.go` L70 |
| RLS | `inTenant(tenant, fn)` sets `app.tenant_id` GUC; `FORCE ROW LEVEL SECURITY` on every tenant table | `internal/store/rls.go` L18 |
| operator (cross-tenant) | `app.rls_scope='operator'` + `operatorAuth()` bearer allowlist — **separate identity, not a tenant role** | `internal/store/rls.go` L159, `internal/hub/operator.go` L43 |
| WUI session | `useSessionStore()` (claims), `useAccessStore()` (`/v1/view/me` role+perms), `accessAllows()` | `csi-spl-wui/src/stores/{session,access}.ts` |
| sticky banner precedent | `BuildUpdateBar.vue` (global, high z-index) | `csi-spl-wui/src/components/BuildUpdateBar.vue` |
| audit | permission `audit.read` exists (biz_owner/admin/product_owner); **no audit table or endpoint built yet** | `internal/rbac/rbac.go` L29 |
| secrets never in session | password argon2 hash, reset/verify tokens (sha256), private keys (browser-only) — never leave the server | `csi-spl-rdb/.../0009,0018` |

**There is no existing impersonation/view-as/act-as concept** — this is greenfield.

## 3. Two modes (the core decision, `§8` Q1)

### Mode A — read-only "View as X" (**recommended**)

The admin's cookie gains a **scoped overlay**: it keeps the admin as the *actor* and adds the target's HUM as the
*viewed* identity. Every **read** (permission eval, `/v1/view/me`, topics, roster, settings render) is evaluated as
the **target** — so the admin sees exactly the UI and the 403s the user sees. Every **write** (any
`POST/PUT/PATCH/DELETE`) is refused `403 view_as_read_only` by one hub middleware, keyed off the overlay claim —
**server-side, never the WUI**. This directly answers "find out whether some permissions work" with the smallest
possible blast radius: no side-effects can occur as the user, because no write can occur at all.

### Mode B — full "Sign in as X" (act as the user)

The cookie's *effective* identity becomes the target; the admin is recorded as `acting_via`. Writes are **allowed**
and attributed "X via admin Y". This is what the owner's second line ("sign-as feature") leans toward, and it is
strictly more powerful — and strictly more dangerous on a live product. It needs every safeguard in `§5` plus
**write attribution** and **outbound-side-effect suppression** (`§5.6`). Recommendation: only if the owner
explicitly wants admins to *act*, not just *verify*; and even then, ship Mode A first (it is a subset).

Both modes share one mechanism (`§4`); Mode B only removes the write-guard and adds attribution + suppression.

## 4. Mechanism (shared)

Mirror `switchTenant()` exactly — no new session infrastructure:

1. `Session` gains two optional claims: `va` (viewed/acting HUM-*) and `by` (the real admin HUM-*, the actor).
   A normal session has neither. `SessionFromRequest()` is unchanged; a new helper `EffectiveHuman(s)` returns
   `s.HumanID` normally, `s.va` when the overlay is set, and `Actor(s)` returns `s.by`.
2. **Start** — `POST /v1/admin/view-as {"human_id":"HUM-…"}`:
   - resolve the admin's active tenant + role (`humanTenant`), require the new permission `members.impersonate`
     (`§6`); refuse otherwise `403`.
   - the target must be a **member of the same tenant** (reuse `members.Member(ctx, target, tenant)`; the same
     opaque `403 not_member` as `switchTenant`, so no other tenant is revealed).
   - **role ceiling** (`§8` Q5): refuse if the target is a tenant owner, or holds any permission the actor lacks
     (a strict-subset rule ⇒ admin cannot view-as another admin or a biz_owner; biz_owner cannot view-as another
     biz_owner). Refuse self.
   - re-issue the cookie with `va=target, by=admin`, `t` unchanged, and a **fresh, shorter expiry** =
     `min(oldExp, now+30m)` (`§8` Q3). Write the audit start row (`§7`).
3. **Exit** — `POST /v1/admin/view-as/exit`: re-issue the cookie with `va`/`by` cleared and the admin's original
   expiry restored (the actor is `by`, so exit needs no DB; the original expiry is re-derived from the live
   membership session, or we carry `oxp` = original exp as a third claim). Write the audit stop row. One click.
4. **Expiry**: when the overlay cookie passes its 30-min `exp`, it is simply an expired session → the admin is
   bounced to their normal login, landing as themselves (the overlay never outlives its window).

RLS is untouched: the overlay stays within the **same tenant**, so `app.tenant_id` is identical; only the
*effective HUM* fed to permission checks changes.

## 5. Safety (both modes)

1. **Unmissable banner.** A permanent, sticky, high-z-index bar (the `BuildUpdateBar` pattern): "Viewing as
   **{name}** — Exit". Re-renders on every route; cannot be permanently dismissed; the Exit button hits
   `POST /v1/admin/view-as/exit`. In Mode B the bar is red and reads "Signed in as **{name}** (admin {you}) — Exit".
2. **Auto-expiry** 30 min (`§8` Q3), independent of and never longer than the admin's own session.
3. **One-click exit**, always reachable from the banner.
4. **No secrets.** The overlay never exposes the target's password hash, reset/verify tokens, private keys, or
   session — none of these are in the session or any read endpoint today, and the credential/key-management
   endpoints (`/api/v1/auth/keys` mutations, password change, session list) are **refused under any overlay**
   regardless of mode. Public keys (already public) are fine.
5. **DMs / private content** (`§8` Q2): a privacy decision for the owner. Recommendation for Mode A: **redact
   private 1:1 message bodies** — the admin sees the target's channel structure, membership and permission-gated
   UI (enough to verify permissions) but not the substance of their private conversations.
6. **No side-effects as the target.** Mode A: guaranteed, because no write is allowed. Mode B: outbound emails and
   notifications are **suppressed or attributed** (never sent silently as the target); writes are attributed
   "X via admin Y" in the stored row (`created_by=target, via_admin=actor`).

## 6. Permissions (first — the hub checks a permission, never a role name: `025` FR-005)

Add one permission `members.impersonate` (rdb next migration). Granted to `biz_owner` and `admin` only.

| permission | biz_owner | admin | product_owner | others |
|---|---|---|---|---|
| `members.impersonate` (new) | yes | yes | – | – |

The **role ceiling** in `§4` is enforced in addition to the permission: holding `members.impersonate` lets you
*start*, but the strict-subset check decides *whom* — never a peer admin, never an owner, never cross-tenant.
The platform **operator** is out of scope here: it already has its own cross-tenant path (`operatorAuth`) and is
not a tenant role; a separate operator "inspect tenant" capability, if ever wanted, is a different spec.

## 7. Audit (visible to the tenant owner — `§8` Q4)

New tenant-scoped table (rdb next migration), RLS `FORCE`, readable via the existing `audit.read` permission:

```
impersonation_events(
  id, tenant_id, actor_hum, viewed_hum, mode ('view'|'act'),
  event ('start'|'stop'), reason (nullable, optional), at timestamptz, ...
)
```

`GET /v1/audit/impersonation` (perm `audit.read`) lists them for the tenant owner/admin. Start and stop are logged
now. Per-page-view logging (every route the admin viewed) is a heavier follow-up, noted not built. Whether the
**impersonated user** is actively notified is `§8` Q4 — recommendation: the event is visible in the tenant audit,
and the user can see the row about themselves; no active email by default.

## 8. Blocker — owner questions (each with a recommended answer)

1. **Mode.** Ship **Mode A (read-only "View as")** first — it fully answers "find out whether some permissions
   work", cannot cause any side-effect, and is a subset of B — then add **Mode B (full "sign in as")** if you want
   admins to *act* as the user? **Recommend: A now, B as a follow-up only if acting is required.**
2. **The target's private DMs while viewing-as: hidden or shown?** **Recommend: hidden** (redact 1:1 bodies;
   structure + permission UI still visible).
3. **Auto-expiry.** **Recommend: 30 minutes**, never longer than the admin's own session.
4. **Notify the impersonated user?** Audit is always visible to the tenant owner/admin. Additionally notify the
   user? **Recommend: no active email by default; the audit row is visible to them** (a tenant setting could turn
   active notification on later).
5. **Role ceiling.** Confirm: an admin may view-as any member **except** another admin or a biz_owner; a biz_owner
   may view-as any member except another biz_owner; never self; never cross-tenant. **Recommend: yes (strict
   permission-subset rule).**
6. **If Mode B is chosen:** confirm writes are attributed "**X via admin Y**" in stored rows, and outbound
   email/notifications are **suppressed** while acting. **Recommend: yes to both.**

## 9. Enforcement + tests (server-side; controls)

Everything is enforced in the hub, never only in the WUI. Tests (added with the build, all in
`run-all-tests.sh` + hub-pg + WUI unit + e2e):

- **cross-tenant refusal**: start view-as of a non-member → `403 not_member`.
- **role-ceiling refusal**: admin→admin, admin→biz_owner, →self → `403`.
- **permission refusal**: a member without `members.impersonate` → `403` naming the permission.
- **write refusal (Mode A)**: every `POST/PUT/PATCH/DELETE` under an overlay cookie → `403 view_as_read_only`.
- **secrets refusal**: key-management / password / session endpoints refused under any overlay.
- **expiry**: an overlay cookie past 30 min is an expired session (admin lands as themselves).
- **audit rows**: start and stop each write one `impersonation_events` row; `GET /v1/audit/impersonation` returns
  them only to `audit.read` holders of that tenant.
- **effective identity**: `/v1/view/me` under the overlay returns the **target's** role + permissions.

## 10. Out of scope

Platform-operator cross-tenant inspection; per-page-view audit trail; active email notification to the user;
Mode B unless `§8` Q1 selects it.
