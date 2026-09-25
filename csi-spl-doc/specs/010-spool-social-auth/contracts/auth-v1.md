# Contract: hub sign-in routes `auth-v1` (spec 010)

Owner: 010 (CLE-3346). Consumers: the WUI (005, CLE-3342) and the hub
mount (003, CLE-3340). Error bodies reuse the hub's shared envelope
`{"error":"<token>","detail":"…"}` (003 `./../../003-spool-message-bus/contracts/http-v1.md`,
`wire.ErrorBody`). Code: `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go`
(`9be4b71`).

## 1. Routes

All under `RoutePrefix = /api/v1/auth/`. The WUI calls them on the **auth
base** = the hub's API origin (`NUXT_PUBLIC_AUTH_BASE`: prd
`https://api.<BASE_DOMAIN>`, dev `https://dev.api.<BASE_DOMAIN>`),
**cross-origin** from the WUI host, with `credentials: 'include'`. The hub
answers them with credentialed CORS for the WUI origin (T050). `''` =
same-origin, used only in lde, where the Nitro devProxy serves the routes.
The Hosting rewrite (`/api/v1/auth/**`, FR-010) now carries only what the
IdP sends to the WUI host, `/{p}/callback`: Firebase Hosting forwards no
request cookie but `__session` to Cloud Run, so dev/prd name the OAuth state
cookie `__session` (T056). Every other auth route is called cross-origin. Start is a link, not
`fetch`: `<auth base>/api/v1/auth/<p>/start?redirect=<WUI path>`. The hub lands
on `<APP_URL><redirect>`, and APP_URL is the WUI origin. Code:
`csi-spl-wui/src/utils/auth-client.mjs` + `src/composables/useAuthClient.ts`
(`e5a4ace`).

| Method + path | Answer |
|---|---|
| `GET /api/v1/auth/providers` | `200 {"providers":["google","facebook"]}` — the enabled list, in cnf order; `[]` when auth is off. Render one button per entry, in this order. |
| `GET /api/v1/auth/{provider}/start?redirect=<path>&tenant=<id>` | `302` to the IdP; sets `spool_oauth_state` (HttpOnly, Path `/api/v1/auth/`, SameSite=Lax, Max-Age = state TTL). `redirect` = same-site path to land on (anything else → `/`). `tenant` optional, DNS-label, else dropped. Unknown/disabled provider → `404 not_found`. |
| `GET /api/v1/auth/{provider}/callback?code&state` (IdP only) | success: sets `spool_session`, `302 <APP_URL><redirect>`. failure: no session, `302 <APP_URL>/login?auth_error=<code>&redirect=<path>`. Unknown provider → `404`. |
| `GET /api/v1/auth/session` | `200` session claims (§3) or `401 unauthenticated`. `Cache-Control: no-store`. |
| `GET /api/v1/auth/avatar` | CLE-3406: the signed-in human's own stored IdP picture (010 T044), membership NOT required. `200` image bytes (`Content-Type` sniffed: png/jpeg/gif/webp), `ETag` = sha256, `Cache-Control: private, no-cache`, `304` on a matching `If-None-Match`; `401 unauthenticated` without a session; `404 not_found` when there is none (the WUI then draws the identicon). The picture is re-fetched and stored hub-wide (`avatars/<sha256>`) on every sign-in, with or without a tenant; a tenant sign-in also puts the tenant file the roster names. |
| `POST /api/v1/auth/logout` | `204`, `spool_session` cleared. |
| `POST /api/v1/auth/tenant` `{"tenant":"<id>"}` | 026 §6 workspace switch (hub 0.5.8): the session cookie is re-issued with `t=<id>` (same expiry) when the human is a member of `<id>`, and the membership's `last_active_at` (rdb 0044) is stamped; `200` = the GET session answer for the new cookie. `401 unauthenticated`, `400 bad_tenant` / `bad_request`, `415` without JSON, `409 no_human`, `403 not_member` (also for an unknown tenant), `503 unavailable`. Idempotent. |
| `POST /api/v1/auth/facebook/deauthorize` (Meta only) | form `signed_request`; valid → `200`, the Facebook identity is unlinked (`Options.Unlinker`); bad/missing signature → `400 bad_request`; Facebook not enabled → `404`. |
| `POST /api/v1/auth/facebook/data-deletion` (Meta only) | same verification; `200 {"url":"<APP_URL>/api/v1/auth/facebook/data-deletion?code=<c>","confirmation_code":"<c>"}`. |
| `GET /api/v1/auth/facebook/data-deletion?code=<c>` | `200 {"confirmation_code":"<c>","status":"completed"}` for a code this hub issued, else `404`. |

Providers (010 FR-001, FR-012): `google`, `facebook`, `microsoft`, `linkedin`, `xai`; `/providers` lists only the enabled ones.

## 2. `auth_error` codes (the login page renders these)

| code | meaning | suggested copy |
|---|---|---|
| `cancelled` | the person denied consent at the IdP | "Sign-in was cancelled." |
| `invalid_state` | state forged, expired (15 min), for another provider, or started in another browser | "That sign-in link expired — try again." |
| `exchange_failed` | the IdP refused the code / was unreachable | "The provider could not confirm you — try again." |
| `email_unverified` | no verified email from the IdP | "Your account has no verified email with this provider — try another." |
| `not_allowed` | the hub refused the person (Registrar) | "This account cannot sign in here." |
| `unavailable` | the hub could not finish (registration store down) | "Sign-in is unavailable right now." |

Unknown codes → a generic "Sign-in failed". After showing one, the page drops
`auth_error` from the URL so a reload does not repeat it.

## 3. Session

Cookie `spool_session` (cnf `SPOOL_HUB_AUTH_COOKIE_NAME`; dev: `spool_session_dev`, spec OQ-A4): HttpOnly, Secure
(dev/prd), SameSite=Lax, Path `/`, Domain = cnf `SPOOL_HUB_AUTH_COOKIE_DOMAIN`
(empty = host-only). The WUI never reads it; it asks `GET /api/v1/auth/session`:

```json
{ "v": 1, "p": "google", "sub": "<idp subject>", "email": "person@example.com",
  "name": "FirstName LastName", "hum": "HUM-…", "t": "<tenant>", "iat": 1789759591, "exp": 1789802791,
  "preferred_locale": null, "diagnostics_enabled": false, "active_tenant": null, "tenants": [] }
```

`hum` appears once the hub's Registrar is wired (T012). `t` is the tenant the
sign-in **started** from; it is not an authorisation (spec SEC-001).

`name` — CLE-34968. The display name the human set in WUI Settings → Profile
(`humans.display_name`), read from the store on every call; the cookie's name
(the IdP's, or the one given at native registration) only while none is
stored. The native `POST /login` answer carries the same. The IdP name seeds
`humans.display_name` at the first sign-in and never replaces a stored one.

The last four are **not** cookie claims: they are read per call and answered
alongside the signed ones. `preferred_locale` (spec 021), `active_tenant` +
`tenants` (specs/026 §3), and:

`diagnostics_enabled` — 005 T035, CLE-3440, CLE-34963. The signed-in
human's OWN "Debug pane" checkbox (WUI Settings → Appearance), which shows the
diagnostics panel at the bottom of the app. Stored per human in
`humans.diagnostics_enabled` (rdb 0038, `NOT NULL DEFAULT false`, so nobody
has it until they tick it). Always present, always a boolean, and the WUI
admits only the literal `true` (`csi-spl-wui/src/composables/debugAudience.mjs`).
It is `false` for a session with no registered human, when no preferences
store is wired, and when the store read fails (fail shut).

The checkbox is the **sole** gate. The operator list
`SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS` it replaced is retired (removed from cnf;
the hub no longer reads it): under "list OR checkbox" unticking the box would
change nothing for a listed address.

It is written by `PUT /api/v1/auth/preferences` (signed session cookie,
`application/json` only, like the native POSTs):

```json
{ "diagnostics_enabled": true }
```

Each key of that body is optional but one is required: `preferred_locale` (a
supported code, or `null` to clear), `diagnostics_enabled` (the JSON
literal `true` or `false` — `"true"`, `1` and `null` are `400 bad_request`)
and `display_name` (CLE-34968: a JSON string, trimmed, 1..200 characters, no
control character and no line/paragraph separator; anything else, `null`
included, is `400 invalid_display_name` — a name cannot be cleared).
The whole body is validated before anything is stored, and the `200` answer
echoes exactly the keys that were stored. `401` without a session, `409
no_human` for a session with no registered human, `503` when the store is not
wired or fails.

Why it is not in the cookie: `Session` has no such field, so **a browser
cannot assert it** — a cookie whose payload names it and whose MAC verifies is
still read back as the stored value — and unticking hides the panel at the
next probe rather than at the end of a 12h session. The native `POST /login`
answer carries the same field, because the WUI adopts those claims with no
second probe. Code: `internal/auth/handler.go` (`diagnosticsGrant`,
`putPreferences`), `internal/store/humans_postgres.go`; tests
`internal/auth/diagnostics_test.go`, `internal/store/humans_test.go`
(`TestHumansDiagnosticsEnabled`), `csi-spl-wui/tests/unit/diagnostics-claim.test.mjs`.

## 4. Login component (for 005)

- Page `/login`: on mount `GET /api/v1/auth/providers`; render one large
  primary button per provider ("Continue with Google", "Continue with
  Facebook"), first on the page (narrative §0). The native email + password
  form shows when `/providers` answers `"native": true` (015).
- Button = plain link `href="<auth base>/api/v1/auth/<p>/start?redirect=<encoded current target>"`
  (plus `&tenant=<id>` when the page knows it). No provider SDK or script.
- Empty list → a neutral "Sign-in is not available yet" (auth off in that env).
- `?auth_error=` present → §2 message above the buttons, keep `redirect`.
- Signed-in probe: `GET /api/v1/auth/session` — `200` signed in; `401` signed
  out; anything else = unknown (keep state, show "session unavailable"; the
  csi-rel 052 runbook incident is exactly this case).
- Sign out: `POST /api/v1/auth/logout`, then route to `/login`.

## 5. Hub mount (003) — Implemented `bc6a6a1`

`spool serve` runs `auth.Load(hc.Env)` (fail fast) and passes
`auth.New(ac, log, auth.Options{})` as `hub.Options.Auth`; `Server.Handler`
registers it before the middleware, so `/api/v1/auth/*` answers on any Host
(`TestAuthMountedWithoutTenant`).

## 6. Tenant-scoped door (003 T033b; 026) — Implemented

```go
s, tenant, err := ah.ActiveTenant(r, hostTenant)   // internal/auth/tenant.go
```

The human door (`internal/hub/resolve.go`) reads the session's active tenant
`t` and re-checks it against `Options.Membership` on every request (T013;
wired in `cmd/spool/hub.go` as `auth.Options{…Membership: hooks}`). It needs
a valid session and a `HUM-*` in it (Registrar, T012). Refusals: no or
non-member session → `401 view_door`; the host or `X-Spool-Tenant` names
another tenant → `403 tenant_mismatch`; several tenants and none selected →
`409 tenant_required`; the role lacks the permission (025) → `403 forbidden`
with `permission`. `SessionForTenant(r, tenant)` (seam `5e8ecb1`) is the
legacy helper.

<!-- version: 0.5.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:45:00Z -->
