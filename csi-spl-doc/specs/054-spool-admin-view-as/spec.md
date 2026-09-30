# Feature Specification: Admin "act as a user" via a temporary clone

**Feature ID**: `054-spool-admin-view-as` · **Milestone**: M3 · **Status**: In progress (`tasks.md`), 3 open points (`§8`)
**Created**: 2026-09-30 · **Lane**: ADMIN-ACT-AS (hub + DB + WUI) · **Issue**: TBD (owner topic `18597eaa-89f9-4cf9-a3ef-ef7999659146`)
**Authority**: this file. It extends `025-spool-tenant-rbac` (roles + permissions), reuses the human/membership
model of `006`/`028`, the tenant-scope RLS of the store, and the Users page of `046-spool-tenant-settings`.

> **Security-sensitive, public repo, live multi-tenant product.** The owner has DECIDED the mechanism (`§1`); only
> the three narrow points in `§8` remain open. Build proceeds on the decided parts with the recommended defaults,
> made configurable where `§8` could change them.

## 1. The owner's decision, verbatim

prd t1 topic `18597eaa-89f9-4cf9-a3ef-ef7999659146` (HUM-10):

> the admins should be able to impersonate a user to find out whether or not some permissions work etc.

> so the Admins of the tenants should have this sign-as feature ..

> ok, then the function should be **not view-as, but act as**, that is a **new temporary user should be created /
> cloned** so that this new **technical user will have exactly the same access to permissions and objects** as the
> person the admin will act on

> And when all of the security context is loaded and the use cases tested, the admin should be able to **logout
> from this person security context and then login once again** to the app via the regular login

So: **"Act as" via a temporary CLONE technical user.** Not view-as, not an overlay on the admin's own session.
The admin acts inside a real, separate, throwaway identity that is a snapshot of the target; leaving it is a plain
**sign-out** back to the login page.

## 2. What already exists (measured on trunk)

The model this feature builds on — nothing here is weakened:

| concern | today | file |
|---|---|---|
| a person | `humans(human_id 'HUM-<n>' via humans_seq, display_name, email, created_at, disabled_at)` — no technical flag yet | `csi-spl-rdb/.../0006_users_and_memberships.sql` |
| how a HUM is minted | `recordIdentity()` → `INSERT INTO humans … RETURNING human_id` | `internal/store/humans_postgres.go` L129 |
| tenant membership | `tenant_memberships(tenant_id, human_id, role, created_at, admitted_by, last_active_at)` | `.../0006`, `.../0044` |
| RBAC role → perms | roles `biz_owner..regular_user`; `MemberRole()`, `rbac.Access{Role, Perms}`; guard `Server.permit(w,r,tenant,hum,perm)` | `internal/rbac/rbac.go`, `internal/hub/rbac.go` L70 |
| channel membership | `channel_humans(tenant_id, channel_id, human_id, joined_at, added_by)`; `HumanChannels()`, `AddChannelHumans()` | `.../0028`, `internal/store/channel_humans.go` |
| session | HMAC-signed cookie; `Session{Provider, Subject, Email, Name, HumanID, Tenant, IssuedAt, Exp}`; `signToken()`, `sessionCookie()` | `internal/auth/token.go`, `handler.go` L1280 |
| how a login sets the cookie | callback → `signToken()` → `http.SetCookie(w, sessionCookie(tok, ttl))` | `internal/auth/handler.go` L375 |
| sign-in identities | `human_identities(provider, subject, …)` — a clone gets **none**, so it cannot be signed into | `csi-spl-rdb/.../0006` |
| RLS | `inTenant(tenant, fn)` sets `app.tenant_id`; `FORCE ROW LEVEL SECURITY` on tenant tables; `asOperator()` for cross-tenant | `internal/store/rls.go` |
| periodic expiry hook | `Sweep(ctx, now)` under `asOperator()` (queued→expired deliveries, expired messages), chunked | `internal/store/postgres.go` L458 |
| audit permission | `audit.read` (biz_owner/admin/product_owner) — exists; no audit table yet | `internal/rbac/rbac.go` L29 |
| WUI session/role | `useSessionStore()`, `useAccessStore()` (`/v1/view/me`); sticky-bar precedent `BuildUpdateBar.vue` | `csi-spl-wui/src/...` |

There is **no existing impersonation/act-as concept** — greenfield.

## 3. The clone (core)

When admin **Y** starts "act as" on member **X** in tenant **T**, the hub, in one transaction under the tenant scope:

1. **Mints a technical clone human** `C` — a fresh `HUM-*` with `humans.technical = true` (new column, `§5`),
   `display_name = "{X's name} (test clone by {Y's name})"`, `email = NULL`. It is given **no `human_identities`
   row**, so no provider (password, Google, keys, Microsoft…) can ever authenticate as `C`. The only way a session
   for `C` ever exists is this endpoint.
2. **Copies X's security context at that instant** (a snapshot, never a live link):
   - the **tenant role** X holds in T (so `C` resolves the exact same `rbac.Access` / permissions);
   - X's **channel memberships** (`channel_humans` rows), **minus private DMs** per `§8` Q1 (recommended: DMs not
     copied — the clone sees channels and issues, not X's 1:1 conversations);
   - anything else access is derived from is role + channel membership (there is no per-human scope table today),
     so role + channels is the whole context.
3. **Records the clone** in `member_clones` (`§6`): `clone_hum=C, tenant_id=T, target_hum=X, created_by=Y,
   role=<snapshot>, created_at, expires_at=now+TTL`. This row is the durable **audit** of the act-as session.
4. **Issues the browser a session cookie for `C`** — `signToken()` over `Session{HumanID:C, Tenant:T, …}` with
   `Exp = now+TTL` — **replacing** Y's own session cookie. No token for Y is kept anywhere in the browser
   (owner's rule). Y is now, in this browser, the clone.

Everything `C` does is attributed to `C`. **X's real history is never touched.** Because `C` is a real member with
X's role, it can *act* (writes are allowed and land as `C`), which is what "act as" means — but on a throwaway
identity, so nothing lands on X.

## 4. Leaving is a sign-out (owner's rule)

There is **no silent switch back** and **no admin token in the browser while acting**. Exit is
**"Stop acting as {X}"** — offered in two places in the WUI: the sticky banner button, and the avatar menu entry
directly above **Sign out**. It calls `POST /v1/act-as/stop`, which:

1. writes `member_clones.ended_at = now, end_reason = 'stop'` (the audit stop row);
2. **ends the clone**: `humans.disabled_at = now` on `C`, deletes its `tenant_memberships` and `channel_humans`
   rows and any live session state — **its messages are kept**, clearly marked as test (`§8` Q2, recommended
   keep), since they already belong to the visibly-named clone;
3. **clears the cookies** and returns a redirect to the **regular login page**.

The admin then **signs in normally** as themselves. The full journey the e2e must cover: **start → act → stop →
login page → normal login.**

## 5. Safeguards (all server-side; the WUI only mirrors them)

- **Who may**: permission `members.impersonate` (`§6`), held by **biz_owner and admin only**.
- **Own tenant only**: X must be a member of Y's active tenant (same opaque `403 not_member` as tenant-switch, so
  no other tenant is revealed). The clone lives in that one tenant; RLS is unchanged.
- **Role ceiling**: never onto another **admin** or a **biz_owner**, never onto self. Enforced as a strict
  permission-subset rule: Y may clone X only if X is not a tenant owner and X's permission set ⊆ Y's.
- **Auto-expiry** `§8` Q3 (recommended **60 min**): after which the clone is disabled and removed exactly as `§4`
  step 2 (via the `Sweep` hook, `end_reason='expired'`), and the now-expired clone cookie is a dead session that
  lands the browser on login.
- **No secrets/identities**: the clone has no password, no keys, no `human_identities` — nothing of X's
  credentials is exposed or reachable, and the clone itself cannot be logged into.
- **No outbound side-effects as a real person**: mail and notifications are **not sent to real people as the
  clone** unless explicitly allowed. The hub recognises a clone by `humans.technical` and suppresses its outbound
  mail/notification by default.
- **Sticky banner + one-click stop**: a permanent high-z-index bar (the `BuildUpdateBar` pattern),
  "**Acting as {X}** (test clone) — **Stop**", on every route, not dismissible; Stop = the sign-out of `§4`.
- **Technical clones are excluded** from member lists, seat/billing counts and rosters (filtered on
  `humans.technical`), so a clone never looks like a real seat.

## 6. Data + permission (rdb `0088`, next migration)

```sql
ALTER TABLE humans ADD COLUMN technical BOOLEAN NOT NULL DEFAULT false;  -- clones (and future bots)

CREATE TABLE member_clones (
  clone_hum   TEXT PRIMARY KEY,                 -- the technical HUM-* C
  tenant_id   TEXT NOT NULL,
  target_hum  TEXT NOT NULL,                    -- X, cloned
  created_by  TEXT NOT NULL,                    -- admin Y
  role        TEXT NOT NULL,                    -- snapshot of X's role at start
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL,
  ended_at    TIMESTAMPTZ NULL,
  end_reason  TEXT NULL CHECK (end_reason IN ('stop','expired','admin'))
);
-- FORCE ROW LEVEL SECURITY, tenant_id policy + operator scope (for Sweep), mirroring 0021.
```

`member_clones` **is** the audit trail (start row on create, `ended_at`/`end_reason` on stop/expiry); rows persist
after the clone is gone. Read via `GET /v1/audit/clones` gated by the existing **`audit.read`** permission
(biz_owner/admin/product_owner), tenant-scoped — so the tenant owner sees who acted as whom, when.

Permission seed (same migration): add `members.impersonate`, granted to `biz_owner` and `admin`.

| permission | biz_owner | admin | others |
|---|---|---|---|
| `members.impersonate` (new) | yes | yes | – |

## 7. Endpoints (hub) + enforcement

| method + path | permission | does |
|---|---|---|
| `POST /v1/act-as {"human_id":"HUM-X"}` | `members.impersonate` + role ceiling | mint clone `C`, copy role + channels, insert `member_clones`, set `C`'s session cookie replacing Y's; body = `{clone_hum, target, expires_at}` |
| `POST /v1/act-as/stop` | a clone session | end the clone (`§4`), clear cookies, `303` → login |
| `GET /v1/audit/clones` | `audit.read` | list `member_clones` for the tenant (audit) |

- Enforcement is in the hub, never only the WUI. Start validates permission, same-tenant membership, and the role
  ceiling before minting anything.
- A **clone session** (`HumanID` whose `humans.technical` is true) is refused at the credential/key-management
  endpoints and has its outbound mail/notifications suppressed (`§5`).
- The **`Sweep`** path (operator scope) is extended to expire clones whose `expires_at <= now` and `ended_at IS
  NULL`: disable + remove exactly as stop, `end_reason='expired'`. This is the auto-expiry; no host cron.

## 8. Open points — short blocker (owner), with recommendations

1. **Are X's private DMs visible to the clone?** **Rec: no** — copy channels and issues only, not X's 1:1 DMs.
2. **At expiry, keep or delete the clone's messages?** **Rec: keep**, clearly marked as test (the clone's visible
   name already marks them; `humans.technical` lets the WUI badge them).
3. **Expiry length?** **Rec: 60 min.**

## 9. Tests (controls; all in `run-all-tests.sh` + hub-pg + WUI unit + e2e)

- **permission refusal**: a member without `members.impersonate` → `403` naming the permission.
- **cross-tenant refusal**: act-as of a non-member of Y's tenant → `403 not_member`.
- **role-ceiling refusal**: admin→admin, admin→biz_owner, →self → `403` (nothing minted).
- **clone fidelity**: `C` resolves exactly X's role + `rbac.Access`; `C`'s `channel_humans` = X's minus DMs.
- **no identity**: `C` has zero `human_identities`; no provider can authenticate as `C`.
- **attribution**: a write while acting lands as `C`, never as X; X's rows are untouched.
- **stop = sign-out**: `POST /v1/act-as/stop` disables `C`, removes memberships, keeps `C`'s messages, clears
  cookies, redirects to login; `member_clones.ended_at` set.
- **expiry**: after TTL the `Sweep` disables+removes `C` (`end_reason='expired'`); the clone cookie is dead.
- **audit**: start and stop each leave a `member_clones` row; `GET /v1/audit/clones` returns them only to
  `audit.read` holders of that tenant.
- **exclusion**: a clone never appears in member lists / seat counts / roster.
- **e2e (browser)**: start → act (a permission-gated action visibly behaves as X) → **Stop acting** → **login
  page** → normal admin login.

## 10. Out of scope

Platform-operator cross-tenant inspection (separate identity, separate spec); per-page-view audit; active email
notification to X; copying X's DMs (unless `§8` Q1 flips).
