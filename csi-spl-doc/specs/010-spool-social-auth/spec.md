# Feature Specification: Spool social sign-in (Google + Facebook first)

**Feature ID**: `010-spool-social-auth` · **Milestone**: M2 (registration) / M3 (WUI login) · **Status**: Partial
**Created**: 2026-09-18 · **Lane**: CLE-3346 · **Narrative (binding)**: `../../doc/md/SPEC-spool-social-auth.md`
**Donor**: csi-rel `specs/052-social-authentication-google-facebook` (Google + Facebook on one set of federated rails)

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

---

## 0. What is built today (read first)

The hub has a self-contained sign-in package, `internal/auth`, on trunk at
`9be4b71`, and its configuration block in cnf at `b5d0a9d`. The hub mounts
it since `bc6a6a1` (003, `tasks.md` T010) with auth **off** in every env:
**no provider app is registered** yet (`tasks.md` T030–T034). What exists and
is verified:

| Piece | Where | Check |
|---|---|---|
| Google (OIDC) + Facebook (Graph v25.0) authorization-code clients | `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go` | `go test ./internal/auth/...` → ok |
| Signed `state` bound to a browser cookie (CSRF) | `internal/auth/token.go`, `handler.go` | `TestStateCSRF` (5 cases) |
| Stateless signed session cookie, `/session`, `/logout` | `internal/auth/handler.go` | `TestSignInEachProvider` |
| Fail-fast config, PLACEHOLDER refusal | `internal/auth/config.go` | `TestConfigFailFast` (8 vars × unset/placeholder) |
| Fake Google + Facebook for a local run | `internal/auth/fakeidp`, `internal/auth/cmd/auth-demo` | `go run ./internal/auth/cmd/auth-demo` → `OK - both providers signed in` |
| cnf names, placeholders, secret slot ids | `csi-spl-cnf/csi-spl/all.env.yaml` `env.auth.social` | `yq '.env.auth.social.env \| keys \| length' csi-spl-cnf/csi-spl/all.env.yaml` → 13 |

Deliberate differences from the csi-rel donor:

| Donor (csi-rel 052) | Here | Why |
|---|---|---|
| Fiber, JWT, `users` table with `google_sub` / `facebook_sub` | `net/http` ServeMux (the hub's), an HMAC-signed session cookie, **no table in this package** | The hub is `net/http`; the human row is `HUM-*` (004) and is created through a `Registrar` hook the hub implements (T012), so this package never touches the store. |
| State: HMAC-signed only, 30 min | HMAC-signed **and** bound to an HttpOnly nonce cookie, single use, 15 min (cnf) | A state lifted from another browser, or replayed, is refused (`TestStateCSRF`). |
| Facebook avatar fetch, deauthorize callback | deauthorize + data-deletion Implemented (T043, stateless confirmation code); avatar Implemented (`5d7be9c`, hub wiring `e23fae5`; T044 `[x]` in `585faaa`) | Avatar → `file_id` is narrative §3.4. Check: `command grep -c fetchAvatar csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go` → 5; `command grep -n 'func fetchAvatar' csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go` → `305`. |
| Provider "omitted when unconfigured" in prd | a listed provider that is unset or PLACEHOLDER **fails the boot** | Owner brief 2026-09-18: fail-fast env vars. The provider list itself is the switch: `""` = off. |

---

## 1. User stories

### US1 — Register / sign in with Google (P1)
A person on the WUI login page clicks **Continue with Google**, consents, and
lands back on the page they came from, signed in. The first successful
callback registers them (`HUM-*`, narrative §0).

1. **Given** `/login`, **when** they click Google, **then** the browser goes
   to `GET /api/v1/auth/google/start` → Google consent. *(Implemented, fake IdP.)*
2. **Given** consent, **when** Google redirects to
   `/api/v1/auth/google/callback`, **then** the hub exchanges the code
   server-side, requires `email_verified`, sets `spool_session`, and redirects
   to `<APP_URL><redirect>`. *(Implemented, fake IdP.)*
3. **Given** it is the first sign-in, **then** a `HUM-*` is created. *(Implemented: T012, `store.Registrar`, rdb `0006`.)*

### US2 — Register / sign in with Facebook (P1)
Same as US1 through `/api/v1/auth/facebook/{start,callback}`; identity from
Graph `/me` signed with `appsecret_proof`. *(Implemented, fake IdP.)*

### US3 — A failed sign-in says why (P1)
Denied consent, a forged/expired/foreign `state`, a failed exchange, an
unverified email or a refused registration lands on
`<APP_URL>/login?auth_error=<code>&redirect=<path>` and sets no session.
*(Implemented: `TestCallbackFailuresLandOnLogin`, `TestStateCSRF`.)*

### US4 — The WUI knows who is signed in (P1)
`GET /api/v1/auth/session` → `200` claims or `401`; `POST /api/v1/auth/logout`
→ `204`, cookie cleared. *(Implemented.)*

### US5 — Microsoft, LinkedIn, xAI on the same rails (P3)
Narrative §1. One generic OIDC client (`internal/auth/oidc.go`, donor csi-rel
`oidc_idp.go`) serves all three: code → token → userinfo, the same state /
cookie checks, the same session. *(Implemented against the fake IdP: T040–T042;
live only after the owner registers each app, `idp-registration-runbook.md`.)*

### US6 — Meta's deauthorize + data-deletion callbacks (P1 for a live Meta app)
Meta will not publish a Facebook Login app without a *Deauthorize callback
URL* and a *Data deletion request URL*. The hub answers both, authorised only
by Meta's HMAC `signed_request` (FR-013). *(Implemented: T043.)*

---

## 2. Functional requirements

- **FR-001** — Implemented (`9be4b71`): authorization-code flow for `google`
  (scopes `openid email profile`) and `facebook` (`email,public_profile`),
  confidential server-side client; the browser never holds a client secret.
  Scopes are cnf (`SPOOL_HUB_AUTH_<P>_SCOPES`).
- **FR-002** — Implemented: `state` = HMAC-SHA256-signed
  `{provider, nonce, redirect, tenant, exp}`; the 256-bit nonce is also an
  HttpOnly `spool_oauth_state` cookie (Path `/api/v1/auth/`, SameSite=Lax);
  the callback requires signature, expiry, provider match **and** cookie match,
  then clears the cookie (single use).
- **FR-003** — Implemented: the redirect URI is cnf, per provider, and must
  have the path `/api/v1/auth/<provider>/callback`; https in dev/prd.
- **FR-004** — Implemented: Google identity = userinfo with
  `email_verified=true`; Facebook identity = Graph `/me` with a present email.
  Otherwise `auth_error=email_unverified`. Email is lower-cased.
- **FR-005** — Implemented: session = `spool_session` cookie, HttpOnly,
  Secure (cnf; off only in lde), SameSite=Lax, Path `/`, optional Domain
  (cnf), Max-Age = `SPOOL_HUB_AUTH_SESSION_TTL` (12 h). Value =
  HMAC-signed `{v,p,sub,email,name,hum,t,iat,exp}`; state and session use
  separate subkeys of `SPOOL_HUB_AUTH_SESSION_KEY`.
- **FR-006** — Implemented: the post-login `redirect` is a same-site path;
  absolute, `//host`, backslash and CR/LF forms collapse to `/`.
- **FR-007** — Implemented: config fails fast. `SPOOL_HUB_AUTH_PROVIDERS=""`
  = auth off. A listed provider needs `CLIENT_ID`, `CLIENT_SECRET`,
  `REDIRECT_URI` set and not `PLACEHOLDER-*`; plus a ≥32-byte session key and
  `APP_URL`. `SPOOL_HUB_AUTH_IDP_BASE_URL` (fake IdP) is refused in prd.
- **FR-008** — Implemented (HUMANS CLE-3351, `tasks.md` T012): the hub's
  `Registrar` is store-backed (`store.Registrar` over `store.Humans`, rdb
  `0006`). A callback upserts the human by `(provider, subject)`
  (`human_identities`): first time → a new `HUM-<n>`; again → the same id
  (idempotent). When the sign-in started from a tenant (`?tenant=`), the
  human must also be **admitted** (FR-014) or the callback is refused with
  `auth_error=not_allowed` and nothing is written. `password` (NATIVE-AUTH,
  spec 015) is a provider slug like any other.
- **FR-009** — Implemented: the session is the M3 door for `/v1/view/*` and
  `/v1/wui/ws` (003 `contracts/view-v1.md` §2) through
  `Handler.SessionForTenant`, backed by the store `Membership` (T013). Door
  mode `SPOOL_HUB_VIEW_DOOR=session` admits member sessions only and turns on
  credentialed CORS (`Access-Control-Allow-Credentials: true` for the exact
  allow-listed origins only, never reflected, never `*`; OQ-A1 (a)). It needs
  auth on (a provider listed) or the hub refuses to boot. `token` (the
  default) also admits a member session, without credentialed CORS.
- **FR-010** — Amended 2026-09-19 (owner: no LB; the WUI on Firebase
  `https://<fqdn>`, the hub on the Cloud Run API host `api.<BASE_DOMAIN>` /
  `<env_subdomain>.api.<BASE_DOMAIN>`; owner: "no console change", the
  redirect URIs are config as csi-rel; T050–T056). The WUI calls
  `/api/v1/auth/{providers,session,logout,login,...}` CROSS-ORIGIN on the API
  host with `credentials: 'include'`; the hub answers credentialed CORS for
  the `SPOOL_HUB_VIEW_CORS_ORIGINS` allow-list on every auth route, with a 204
  preflight (GET, POST; Content-Type). The OAuth callback stays on the WUI
  host (`https://<fqdn>/api/v1/auth/<p>/callback`, what the IdP clients
  authorise, measured 2026-09-19: the API-host URI gets
  `redirect_uri_mismatch`), and Firebase Hosting rewrites `/api/v1/auth/**`
  to the hub's Cloud Run service (csi-rel `firebase.json`), which needs hub
  ingress `all`. Firebase forwards only the `__session` request cookie, so the
  OAuth state cookie is `__session` with the session cookie's Domain (T056).
  `SPOOL_HUB_AUTH_APP_URL` stays the WUI origin.

- **FR-011** — Implemented: no token, secret, code or raw subject is logged;
  `auth.login_ok` / `auth.callback_fail` carry provider, reason and a 12-hex
  digest of the subject.

- **FR-012** — Implemented (T040–T042): `microsoft`, `linkedin` and `xai`
  are generic OIDC authorization-code clients (`oidc.go`). Each has the block
  `SPOOL_HUB_AUTH_<P>_{CLIENT_ID,CLIENT_SECRET,REDIRECT_URI,SCOPES}` under the
  same FR-007 fail-fast rules. Identity = the userinfo `sub` + email;
  `email_verified=true` is required (bool or `"true"`), except Microsoft,
  where no such claim exists and trust comes from OQ-I1. Endpoints:
  Microsoft = `login.microsoftonline.com/<SPOOL_HUB_AUTH_MICROSOFT_TENANT>/oauth2/v2.0/{authorize,token}`
  + `graph.microsoft.com/oidc/userinfo`; LinkedIn = its published OIDC
  endpoints (`www.linkedin.com/oauth/.well-known/openid-configuration`);
  xAI = **cnf only** (`SPOOL_HUB_AUTH_XAI_{AUTH_URL,TOKEN_URL,USERINFO_URL}`,
  narrative §1 "never baked"), no Go default, required when `xai` is listed.
  The fake IdP serves all three at `/oidc/<p>/{authorize,token,userinfo}`.
- **FR-013** — Implemented (T043): `POST /api/v1/auth/facebook/deauthorize`
  and `POST /api/v1/auth/facebook/data-deletion` (form field
  `signed_request`) verify `HMAC-SHA256(app secret, <raw payload segment>)`
  first and fail closed (`400`) on any defect, then call the optional
  `Options.Unlinker` hook with `("facebook", user_id)` — the hub deletes the
  stored `human_identities` row (rdb 0006, HUMANS lane); nil = the hub stores
  nothing from Facebook beyond the stateless session. Data-deletion answers
  Meta's fixed shape `{"url","confirmation_code"}`; the code is
  self-verifying (an HMAC under a subkey of the session key), so
  `GET /api/v1/auth/facebook/data-deletion?code=` answers `200` for a code
  the hub issued and `404` otherwise, with no table. Facebook not enabled →
  `404`.

- **FR-014** — Implemented (the OQ-A5 default): tenant admission. A human is
  admitted to tenant T when (1) they are already a member; else (2) an
  unexpired, unaccepted invite for T matches their verified email, and they
  become a member with the invite's role and the invite is marked accepted;
  else (3) bootstrap (`SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true`) is on **and** T
  has zero members, and they become owner. Otherwise they are refused.
  Bootstrap is a trust change: it is `true` on dev and `false` (the default)
  on prd until the owner decides OQ-A5. On prd the first owner comes from an
  operator invite (`spool hub-invite`).
- **FR-015** — Implemented: on `/v1/wui/ws`, a member session's `HUM-*`
  **overrides** the browser-asserted `hello.as` / `?as=` (gap F8), so a
  signed-in human cannot post as someone else. With the door `off`
  (lde/dev only) the asserted id is used as before.
- **FR-016** — Implemented (CLE-3411, tasks T060–T066; owner 2026-09-19 "send him an email
  invite", "to both the environments"): **the invitation email.** Creating an
  invite (`spool hub-invite`, operator; and any later in-app owner invite,
  which calls the same `invitemail.Send`) sends ONE mail through the existing
  relay (`internal/mail`, cnf `env.mail`; prd and dev = the csi-rel Gmail
  relay, From name `SPOOL-HUB.AI NO-REPLY`). No in-app owner-invite endpoint
  exists in the hub today (measured: `grep -rln PutInvite --include=*.go`
  outside tests names only `cmd/spool/hub.go` and the auth demo), so the
  operator path is the only caller until one is built.
  - **Content** (template `tenant_invite`, all 19 locales): the tenant that
    invites (its id is the tenant name today), the role, the address to sign
    in with, the sign-in URL `https://<env fqdn>/login?tenant=<tenant>`, how
    to accept (Google, or native sign-up + verify with THAT address;
    admission is FR-014's verified-email match), and the expiry (UTC).
  - **No bearer secret.** The invite is matched on the provider-verified
    email (FR-014), so the link carries only the tenant id: forwarding the
    mail grants nothing. No token is minted, stored or mailed.
  - **Locale.** The invitee has no stored locale and tenants have none, so
    the mail renders in the hub default `env.i18n.default_locale`
    (`SPOOL_HUB_DEFAULT_LOCALE`; `bg` today) unless the operator passes
    `--locale`; `en` is the fallback for a missing variant (`mail.Render`).
  - **Only an open invite is mailed.** Accepted or expired → no mail
    (`skipped_accepted` / `skipped_expired`); unknown → `not_found`.
  - **Resend rate limit** (rdb `0019`: `tenant_invites.mailed_at`,
    `mail_count`): a send is claimed atomically in the DB before the relay is
    called, and refused (`rate_limited`) while the last send is younger than
    `--min-gap` (default 10m) or the invite was already mailed `--max-sends`
    times (default 5). Re-inviting (`PutInvite`) resets the count, not
    `mailed_at`, so the gap still holds.
  - **Logs** carry `mail.Digest(email)` only, never the address or the body.
  - Resend: `ENV= TENANT_ID= EMAIL= ./run -a do_spl_hub_invite_email_send`
    (csi-spl-orc; DRY_RUN=1 default) as the per-env SA; the relay password
    is read from `env.mail.secret_env` into the child's environment only.

## 3. Security requirements

- **SEC-001** — `session.t` (tenant) is **where the flow started, not an
  authorisation**: it is caller-supplied. Tenant access is decided by the hub
  from `HUM-*` membership (T013), never from `t`. **026 (2026-09-19):** `t` is now the session's *active tenant* (a selection, re-checked against membership on every request); it replaces the Host as the tenant of a human request.
- **SEC-002** — An IdP response never mints privilege: the session carries
  identity only.
- **SEC-003** — Client secrets and the session key live in Secret Manager
  (`env.auth.social.secret_env`); never in git, tf state or a log.

## 4. Open questions

- **OQ-A1 — DECIDED (a)** by 003 (`bc6a6a1`, view-v1 0.3.0 §2): cookie
  Domain = the env fqdn (`SPOOL_HUB_AUTH_COOKIE_DOMAIN`) plus
  `Access-Control-Allow-Credentials: true` for the exact allow-listed origins
  only (never reflected, never `*`). Switched on together with the session
  door, only after T013.
- **OQ-A4 (owner / 007)** — prd serves the apex, so a prd cookie with
  `Domain=<BASE_DOMAIN>` is also sent to every `dev.<BASE_DOMAIN>` host. The
  dev hub cannot verify it (different session key: `401`), but the prd token
  still reaches dev infrastructure. cnf gives dev its own cookie name
  (`spool_session_dev`), so the two cookies never shadow each other on dev
  hosts. Hub logs never record `Cookie` headers
  (`TestAccessLogCarriesNoCredentials`). Options: **(a) recommended** — prd
  sets `SPOOL_HUB_AUTH_COOKIE_DOMAIN=""`, a host-only cookie on the apex. The
  WUI reaches the hub same-origin through the Hosting rewrite (FR-010), so no
  subdomain needs the cookie; a tenant subdomain that needs a session signs
  in on its own host. (b) keep `Domain=<apex>` and move dev to a separate
  registrable domain. **Not changed here:** the prd cookie domain stays as
  cnf has it until the owner answers.
- **OQ-A2 (owner) — answered 2026-09-19:** the callback host stays the WUI
  origin with the Hosting rewrite (FR-010); auth reads and native forms go to
  the API host cross-origin. dev's API host `dev.api.<BASE_DOMAIN>` sits
  outside `dev.<BASE_DOMAIN>`, so the dev session cookie takes
  `Domain=<BASE_DOMAIN>` (its distinct name `spool_session_dev` keeps it from
  shadowing prd's; prd hosts cannot verify it: different session key).
- **OQ-A3 (004) — default implemented (rdb `0006`).** (a) **Recommended,
  implemented:** `HUM-<n>` is an opaque hub-wide sequence (`humans_seq`),
  keyed by `(provider, subject)` in `human_identities`. One human may hold
  several identities. Email is an attribute, never a key, and a new identity
  is never auto-linked to an existing human by email (otherwise an IdP that
  lets a user change their email could take over an account). The id is
  unique hub-wide, not per tenant; tenancy lives in `tenant_memberships`.
  (b) Derive the id from the verified email — not the default, because email
  changes and provider email reuse break a stable id.
- **OQ-A5 (owner) — admission; default implemented (FR-014).** (a)
  **Recommended, implemented:** the first human on a zero-member tenant
  becomes its owner (`SPOOL_HUB_AUTH_BOOTSTRAP_OWNER`, dev only), and everyone
  else needs an owner/operator invite matched on verified email. (b) Also
  allow a per-tenant email-domain allow-list that auto-admits `@<domain>` as
  member. Not built; it would be a `tenant_admit_domains` table in a later
  migration. On prd bootstrap stays **off** until the owner answers, because
  otherwise any first visitor could claim a fresh tenant.
- **OQ-A6 (owner, = 003 OQ-16)** — view token or session only. (a)
  **Recommended:** the session is the only browser door (`session` mode) and
  no view token is built. (b) Define a view-token format (OQ-16) for
  non-browser readers. Until this is decided, `token` mode admits member
  sessions and accepts no token.

- **OQ-I1 (owner) — Microsoft email trust.** Entra's userinfo carries no
  `email_verified`, and in a work/school tenant the `email` is set by that
  tenant's admin, unverified (the "nOAuth" class): trusting it lets another
  tenant claim a person's address. (a) **Recommended, implemented default:**
  `SPOOL_HUB_AUTH_MICROSOFT_TENANT=consumers` — personal Microsoft accounts
  only, whose address Microsoft has verified; any other tenant is refused at
  boot unless (b) `SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL=true`, which accepts
  `common` / `organizations` / a tenant id and trusts the email as-is. The
  flag is `"false"` in every env until the owner answers.
- **OQ-I2 (owner) — xAI client registration.** xAI publishes a full OIDC
  issuer (`curl -s https://auth.x.ai/.well-known/openid-configuration` → `200`,
  n=1, 2026-09-19: authorize/token/userinfo endpoints, scopes `openid profile
  email`, claim `email_verified`, `client_secret_post`). The code is done;
  what is **not** known is whether xAI registers third-party web clients (no
  self-service console was found). (a) Recommended: keep `xai` out of
  `SPOOL_HUB_AUTH_PROVIDERS` until the owner holds a client id + secret from
  xAI; (b) drop xAI from the narrative.

## 5. Success criteria

- **SC-001** — Implemented (fake IdP): both providers complete
  start → callback → `/session` = 200 (`go run ./internal/auth/cmd/auth-demo`).
- **SC-002** — Implemented: 100 % of callbacks verify state + cookie
  (`TestStateCSRF`).
- **SC-003** — Planned: the same on dev against the registered apps (T034).

<!-- version: 0.4.0 · updated: 2026-09-19 · last-edit: 2026-09-19T16:55:00Z -->
