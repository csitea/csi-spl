# Feature Specification: Sign in with Facebook

**Feature ID**: `049-spool-auth-facebook` · **Status**: Implemented and live on dev + prd since 2026-09-29 (a real prd sign-in, 18:28Z); per-tenant method policy (T040) Planned
**Created**: 2026-09-29 · **Lane**: CLE-35097 · **Parent**: `../010-spool-social-auth/` (FR-003, FR-013, T031, T043)
**Siblings**: `../018-spool-auth-microsoft/`, `../019-spool-auth-linkedin/` (same rails) · **Donor**: csi-rel `csi-rel-api/src/internal/auth/` (`facebook_idp.go`, `facebook_callbacks.go`, `method_policy.go`, `social_registry.go`)

Owner order (2026-09-29, prd t1 topic `c11f5c1e`, verbatim): *"implement the
authentication with Facebook - use the same code as csi-rel, but adapt. I will do the
registrations in Facebook in the afternoon."*

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

---

## 0. What exists today (measured 2026-09-29, tree `add8f743`)

Spec 010 already ported the donor's Facebook client and Meta callbacks onto spool's
`IdP` interface (`f17210e`); nothing was pasted over spool's structure. Measured:

| Piece | Where | Check |
|---|---|---|
| `Facebook` IdP: dialog, code exchange, Graph `/me` with `appsecret_proof` | `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go` | `grep -c 'func (f \*Facebook)' idp.go` → 4 |
| Graph version pinned `v25.0` (as the donor) | `idp.go` `FacebookGraphVersion` | `grep -c '"v25.0"' idp.go` → 1 |
| Deauthorize + data-deletion callbacks, self-verifying confirmation code (010 T043) | `internal/auth/facebook_callbacks.go` | `go test -run TestFacebookMetaCallbacks ./internal/auth/` → ok |
| Identity unlink behind those callbacks | `store.AuthHooks.Unlink` → `DELETE FROM human_identities` | `grep -c UnlinkIdentity internal/store/humans_postgres.go` → 1 |
| Link to an existing human by a verified email (CLE-3451) | `store.Admit` | `go test -run 'TestHumansAdmit' ./internal/store/` → ok |
| Fake Graph for lde and tests | `internal/auth/fakeidp` | `grep -c FacebookMePath fakeidp/fakeidp.go` → 1 |
| cnf slots, callback derived from the fqdn | `csi-spl-cnf/csi-spl/all.env.yaml` `env.auth.social` | `grep -c FACEBOOK all.env.yaml` → 4 |
| Secret slot `csi-spl-hub-auth-facebook-client-secret` (empty, terraform 030) | `csi-spl-iac/src/terraform/030-cloud-run-hub/06-auth-secret-slots.tf` | `for_each = var.auth_secret_ids` |
| Seed action | `IDP=facebook ENV=<env> ./run -a do_spl_auth_idp_secret_seed` (csi-spl-orc, 019 T020) | `bash csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh` → ALL PASS |
| Button: the "f" mark on Facebook blue `#1877F2`, 19 locales | `csi-spl-wui/src/components/SocialAuthButtons.vue`, `i18n/locales/*.json` `social_auth.continue_facebook` | `grep -l continue_facebook csi-spl-wui/i18n/locales/*.json \| wc -l` → 19 |
| Live state | dev + prd list only Google | `curl -s https://spool-hub.ai/api/v1/auth/providers` → `{"native":true,"providers":["google"]}` |

This spec adds a Facebook-shaped contract test with controls, an HTML status page for a
deletion request, the public privacy and terms pages that Meta requires before an app
goes Live, the per-tenant method policy, and the owner's checklist (`owner-runbook.md`).

## 1. The flow

1. The WUI calls `GET /api/v1/auth/providers`; the button shows only when the hub lists
   `facebook` (the list is registry-driven, 010 FR-009).
2. `GET /api/v1/auth/facebook/start` → 302 to
   `https://www.facebook.com/v25.0/dialog/oauth?client_id&redirect_uri&response_type=code&scope=email,public_profile&auth_type=rerequest&state`.
   `state` is HMAC-signed (provider, nonce, redirect, expiry 15 min) and bound to the
   browser by the `__session` state cookie (010 FR-002, T056). Facebook Login has no
   id_token, so there is no OIDC nonce; like the donor it uses no PKCE: the app secret
   stays server-side (a confidential client).
3. Facebook returns to `https://<fqdn>/api/v1/auth/facebook/callback` on the WUI host;
   Firebase Hosting rewrites `/api/v1/auth/**` to the hub (010 FR-010).
4. The hub checks the state and its cookie, then exchanges the code:
   `GET https://graph.facebook.com/v25.0/oauth/access_token` (client id, secret,
   redirect URI, code), then
   `GET /v25.0/me?fields=id,email,name,picture.width(256).height(256)&access_token&appsecret_proof`,
   where `appsecret_proof = HMAC-SHA256(app secret, access token)`.
5. The identity is `(facebook, <app-scoped id>)`, the lower-cased email, the name, and the
   picture through `fetchAvatar` (skipped when Graph marks it a silhouette).
6. `Registrar.Admit` decides admission (invite, membership, bootstrap; 010 FR-006) and
   the hub sets the session cookie. A failure lands on `/login?auth_error=<code>`.

## 2. Requirements

- **FR-F1** — Implemented (`f17210e`): the flow in §1. Scopes are cnf
  (`SPOOL_HUB_AUTH_FACEBOOK_SCOPES`, default `email,public_profile`).
- **FR-F2** — Implemented (`f17210e`; contract test T010): **no email, no sign-in.**
  Graph omits `email` when the person declined the permission, has no email (a phone-only
  account) or never confirmed it. The hub refuses with `auth_error=email_unverified` and
  writes nothing. The WUI says *"Your account has no verified email with this provider —
  try another."* (19 locales). A present email is Facebook's attestation that its holder
  confirmed it (Graph never returns an unconfirmed address; the donor relies on the same
  rule). So the invariant `Identity.Email != "" ⇒ verified` holds at the boundary
  (CLE-3451), and nothing is merged on an unverified address.
- **FR-F3** — Implemented (CLE-3451, `5ebca8f`): **account linking.** A Facebook sign-in
  whose verified email matches an existing human whose stored email is verified links the
  new `(facebook, id)` identity to that human (the address lock is taken before the
  identity lock). A human with an unverified stored email is never linked.
- **FR-F4** — Implemented (`f17210e`; contract test T010): consent denied
  (`error=access_denied&error_reason=user_denied`) → `auth_error=cancelled`; a state or
  state-cookie mismatch → `auth_error=invalid_state`; a Graph error → `exchange_failed`.
- **FR-F5** — Implemented (010 T043, `f17210e`): **Meta's data-deletion and deauthorize
  callbacks**, `POST /api/v1/auth/facebook/data-deletion` and
  `POST /api/v1/auth/facebook/deauthorize`. Both verify Meta's `signed_request`
  (HMAC-SHA256 with the app secret) before anything else, sever the `(facebook, user_id)`
  link, and are idempotent. Data deletion answers Meta's fixed shape
  `{"url": "<status page>", "confirmation_code": "<code>"}`. Both are 404 while
  `facebook` is not listed.
- **FR-F6** — Implemented (T011): **the status page.** `GET
  /api/v1/auth/facebook/data-deletion?code=<code>` returns a small self-contained HTML
  page when the client asks for `text/html` (what was removed, the confirmation code),
  and the JSON `{"confirmation_code","status":"completed"}` otherwise. An unknown code is
  404 in both forms. The code is `<32 hex>-<20 hex HMAC>` under a session-key subkey, so
  the page needs no table.
- **FR-F7** — Implemented (T020): **policy pages.** `/privacy` and `/terms` are static
  HTML in the WUI bundle (no JavaScript, so Meta's crawler reads them). They say what
  spool-hub keeps from Facebook (the app-scoped id, email, name, picture) and how to have
  it removed (remove the app in Facebook's settings, which calls FR-F5).
- **FR-F8** — Implemented (010): **behind a flag, OFF until the credentials exist.**
  `facebook` is listed in `SPOOL_HUB_AUTH_PROVIDERS` only after the App ID is in
  `<env>.env.yaml` and `csi-spl-hub-auth-facebook-client-secret` has a version. The hub
  fails fast at boot on a listed provider with a `PLACEHOLDER-*` value, and terraform 030
  injects only the listed providers' secrets. The secret never enters git (the repo is
  public), terraform state, a log or a spool message.
- **FR-F9** — Planned (T040): **method policy per tenant**, §4.

## 3. Callback URLs (rendered by `do_spl_merged_cnf`, never literals in cnf)

| env | Valid OAuth Redirect URI |
|---|---|
| dev | `https://dev.spool-hub.ai/api/v1/auth/facebook/callback` |
| prd | `https://spool-hub.ai/api/v1/auth/facebook/callback` |

Data deletion: `https://spool-hub.ai/api/v1/auth/facebook/data-deletion`. Deauthorize:
`https://spool-hub.ai/api/v1/auth/facebook/deauthorize`. Print the redirect URIs rather
than copying them from here:

```bash
source csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh && do_spl_merged_cnf csi-spl-cnf/csi-spl prd /tmp/prd.yaml && yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI' /tmp/prd.yaml
```

One Meta app serves both envs (OQ-F1). A Meta app has one deletion URL and one
deauthorize URL, so both point at prd; a dev identity is removed from dev by an operator
on request.

## 4. Method policy per tenant (FR-F9, Planned)

Today the policy is per env: every method the hub lists (`SPOOL_HUB_AUTH_PROVIDERS` plus
native) opens a session for every tenant the human belongs to. The donor's `MethodPolicy`
is per USER (`users.auth_methods`) with a staff rule. Spool has no staff role and admits
per tenant, so the policy moves to the tenant:

- `tenants.auth_methods text[] NULL` (a new rdb migration). `NULL` = every method the hub
  lists: today's behaviour and the default for every existing tenant.
- The session already records the method that minted it (`p`). Where the hub resolves a
  human's tenant (`auth.ActiveTenant`, spec 026), a tenant whose list does not name `p`
  answers `403 method_not_allowed`, and the tenant switcher shows it greyed out with
  "sign in with <method> to open this workspace". Nothing is deleted or unlinked.
- Tenant settings (spec 046, General) show one checkbox per method the hub lists,
  editable by `biz_owner`. Unticking the method of the editor's own session is refused
  (no self-lock-out).
- A method the hub does not list is never usable, whatever a tenant row says.

## 5. Deliberate deviations from the csi-rel donor

| # | csi-rel | here | why |
|---|---|---|---|
| D1 | `/me?fields=id,email,first_name,last_name,picture.type(large)` | `id,email,name,picture.width(256).height(256)` | spool stores one display name; 256 px fits `AvatarMaxBytes`. |
| D2 | Facebook is customer-only; a staff row is refused unless `staff_allowed` | no staff concept; per-tenant policy (§4) | spool admits per tenant (025 RBAC). |
| D3 | `DefaultFacebookCustomerMethods` on the user row | per tenant, `NULL` = all listed | same reason. |
| D4 | the secret in an env var at provisioning | an owner file (0600) read by the seed action, value on stdin only; or a version the owner adds himself | 019 D2. |
| D5 | the deletion status is a WUI route | a hub-rendered page on the same rewrite | one route, no WUI state. |

## 6. Success criteria

- **SC-F1** — `go test -race ./internal/auth/...` green, including the Facebook contract
  test (success, no email, denied consent, state mismatch, Graph error, silhouette) and
  its controls.
- **SC-F2** (per env, after the owner's step) — `curl -s https://<fqdn>/api/v1/auth/providers`
  lists `facebook`; `curl -s -o /dev/null -w '%{redirect_url}' https://<fqdn>/api/v1/auth/facebook/start`
  names `www.facebook.com/v25.0/dialog/oauth` with the cnf App ID and the §3 redirect URI;
  a real sign-in with a test Facebook account logs `auth.login_ok provider=facebook`.
- **SC-F3** — `curl -s -o /dev/null -w '%{http_code}' https://spool-hub.ai/privacy` → 200,
  the same for `/terms`; a POST to the deletion URL without a `signed_request` → 400 once
  `facebook` is listed.

## 7. Open questions (owner) — each with the recommended default

- **OQ-F1 — one Meta app or one per env?** Recommended **one app** (type Consumer), both
  redirect URIs, Live. The app-scoped id is then the same for a person in dev and prd
  (separate databases, harmless). Two apps double the console work.
- **OQ-F2 — accounts without an email.** Recommended **refuse** (FR-F2) now. A later
  option: "add an email", which sends the native verify link (spec 015) and admits only
  after it is clicked; never admit on the unverified address.
- **OQ-F3 — per-tenant policy (§4).** Recommended default `NULL` (all listed methods) for
  every tenant; build T040 when a tenant asks to restrict sign-in.
- **OQ-F4 — access level.** Corrected 2026-09-29: a **Live** app needs **advanced access**
  for `public_profile` and `email`; with standard access ("Ready for testing") Facebook
  shows "Feature Unavailable ... updating additional details" to everyone (measured on
  dev + prd, no callback reached the hub). Unverified: whether Meta grants advanced access for
  these two without App Review or Business verification (owner step if it asks).

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T05:00:00Z -->
