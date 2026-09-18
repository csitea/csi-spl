# Feature Specification: Spool social sign-in (Google + Facebook first)

**Feature ID**: `010-spool-social-auth` · **Milestone**: M2 (registration) / M3 (WUI login) · **Status**: Partial
**Created**: 2026-09-18 · **Lane**: CLE-3346 · **Narrative (binding)**: `../../doc/md/SPEC-spool-social-auth.md`
**Donor**: csi-rel `specs/052-social-authentication-google-facebook` (Google + Facebook on one set of federated rails)

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

---

## 0. What is built today (read first)

The hub has a self-contained sign-in package, `internal/auth`, on trunk at
`9be4b71`, and its configuration block in cnf at `b5d0a9d`. **It is not
mounted on the running hub yet** and **no provider app is registered**: both
are listed tasks (`tasks.md` T010, T030–T034). What exists and is verified:

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
| Facebook avatar fetch, deauthorize callback | not yet | Avatar → `file_id` is narrative §3.4 (Planned T044); deauthorize/data-deletion is Planned T043. |
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
3. **Given** it is the first sign-in, **then** a `HUM-*` is created. *(Planned: T012, hub + 004.)*

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
Narrative §1. *(Planned: T040–T042; listing one today fails the boot with
"planned but not implemented".)*

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
- **FR-008** — Partial: a `Registrar` hook receives the verified identity and
  the start `tenant`, returns `HUM-*` or `ErrNotAllowed`. Missing: the hub's
  implementation (T012).
- **FR-009** — Planned: the session is accepted as the M3 door for
  `/v1/view/*` (003 `contracts/view-v1.md` §2 "M3 successor"). Open: OQ-A1.
- **FR-010** — Planned: the WUI reaches `/api/v1/auth/**` same-origin through
  a Hosting rewrite to the hub (as csi-rel), so the callback host is the WUI
  origin and one redirect URI per provider per env is registered (narrative §5).
- **FR-011** — Implemented: no token, secret, code or raw subject is logged;
  `auth.login_ok` / `auth.callback_fail` carry provider, reason and a 12-hex
  digest of the subject.

## 3. Security requirements

- **SEC-001** — `session.t` (tenant) is **where the flow started, not an
  authorisation**: it is caller-supplied. Tenant access is decided by the hub
  from `HUM-*` membership (T013), never from `t`.
- **SEC-002** — An IdP response never mints privilege: the session carries
  identity only.
- **SEC-003** — Client secrets and the session key live in Secret Manager
  (`env.auth.social.secret_env`); never in git, tf state or a log.

## 4. Open questions

- **OQ-A1 (003, CLE-3340)** — How does the session reach `/v1/view/*` on
  `<tenant>.<fqdn>` from the WUI origin? The cookie is HttpOnly, so the WUI
  cannot turn it into a header, and the hub cannot mint a view-v1 token (those
  are signed by the tenant ROOT key, which the hub never holds). Options:
  (a) `SPOOL_HUB_AUTH_COOKIE_DOMAIN=<env.dns.fqdn>` so every tenant host
  receives the cookie (same-site, SameSite=Lax holds), plus view-v1 CORS with
  `Access-Control-Allow-Credentials: true` for the allowlisted origins only and
  `credentials: 'include'` in the WUI; (b) serve the viewer same-origin on each
  tenant host. Recommended: (a) — one cnf value and one CORS header; view-v1
  §3's "no credentials mode" then changes, which is 003's text to change.
- **OQ-A2 (owner)** — Which host is the registered callback host per env:
  the WUI origin with a rewrite (FR-010, cnf default today) or a dedicated
  hub host.
- **OQ-A3 (004)** — `HUM-*` stable id derivation from `(provider, sub)` vs
  verified email, and per-tenant uniqueness (narrative §3.1).

## 5. Success criteria

- **SC-001** — Implemented (fake IdP): both providers complete
  start → callback → `/session` = 200 (`go run ./internal/auth/cmd/auth-demo`).
- **SC-002** — Implemented: 100 % of callbacks verify state + cookie
  (`TestStateCSRF`).
- **SC-003** — Planned: the same on dev against the registered apps (T034).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:31:00Z -->
