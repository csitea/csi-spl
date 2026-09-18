# Contract: hub sign-in routes `auth-v1` (spec 010)

Owner: 010 (CLE-3346). Consumers: the WUI (005, CLE-3342) and the hub
mount (003, CLE-3340). Error bodies reuse the hub's shared envelope
`{"error":"<token>","detail":"…"}` (003 `./../../003-spool-message-bus/contracts/http-v1.md`,
`wire.ErrorBody`). Code: `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go`
(`9be4b71`).

## 1. Routes

All under `RoutePrefix = /api/v1/auth/`. The WUI calls them **same-origin**
(Hosting rewrite `/api/v1/auth/**` → hub, 010 FR-010); links, not `fetch`,
for start.

| Method + path | Answer |
|---|---|
| `GET /api/v1/auth/providers` | `200 {"providers":["google","facebook"]}` — the enabled list, in cnf order; `[]` when auth is off. Render one button per entry, in this order. |
| `GET /api/v1/auth/{provider}/start?redirect=<path>&tenant=<id>` | `302` to the IdP; sets `spool_oauth_state` (HttpOnly, Path `/api/v1/auth/`, SameSite=Lax, Max-Age = state TTL). `redirect` = same-site path to land on (anything else → `/`). `tenant` optional, DNS-label, else dropped. Unknown/disabled provider → `404 not_found`. |
| `GET /api/v1/auth/{provider}/callback?code&state` (IdP only) | success: sets `spool_session`, `302 <APP_URL><redirect>`. failure: no session, `302 <APP_URL>/login?auth_error=<code>&redirect=<path>`. Unknown provider → `404`. |
| `GET /api/v1/auth/session` | `200` session claims (§3) or `401 unauthenticated`. `Cache-Control: no-store`. |
| `POST /api/v1/auth/logout` | `204`, `spool_session` cleared. |

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
  "name": "FirstName LastName", "hum": "HUM-…", "t": "<tenant>", "iat": 1789759591, "exp": 1789802791 }
```

`hum` appears once the hub's Registrar is wired (T012). `t` is the tenant the
sign-in **started** from; it is not an authorisation (spec SEC-001).

## 4. Login component (for 005)

- Page `/login`: on mount `GET /api/v1/auth/providers`; render one large
  primary button per provider ("Continue with Google", "Continue with
  Facebook"), first on the page (narrative §0). No password form.
- Button = plain link `href="/api/v1/auth/<p>/start?redirect=<encoded current target>"`
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

## 6. Tenant-scoped door (003 T033b) — seam Implemented `5e8ecb1`

```go
s, err := ah.SessionForTenant(r, hostTenant)   // nil error = may read hostTenant
```

Requires a valid session, a `HUM-*` in it (Registrar, T012) and
`Options.Membership.Member(ctx, hum, hostTenant) == true` (T013). Errors:
`ErrNoSession`, `ErrNoHuman`, `ErrNoMembership` (none configured — the
default, so today every call refuses), `ErrNotMember`, or the lookup error;
the view door maps all of them to `401 view_door`. `session.t` is never read.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:48:00Z -->
