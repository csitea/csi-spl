# SPEC: Google and Facebook auth on the spool web UI

Status: **M3 WUI** (login to the Slack-like UI). Optional on the M2 thin
checkout page. Not M1 (IAP/IP allowlist; no public login).  
Copy from **pas-psf**, do not invent a second OIDC stack.

---

## 1. What to copy (read-only)

pas-psf already ships Google + Facebook on the **web UI** (`SocialAuthButtons`
on login, register, checkout) against API
`GET /api/v1/auth/{google,facebook}/start` → callback → session cookie.

| pas-psf path | Take |
|---|---|
| `pas-psf-wui/src/components/SocialAuthButtons.vue` | Buttons; cnf-driven provider list |
| `pas-psf-wui/src/composables/useSocialProviders.ts` | Fetch enabled IdPs; start URLs |
| `pas-psf-api/src/internal/auth/` (`google_idp.go`, `facebook_idp.go`, `oauth_handlers.go`) | Server-side code exchange; never put the client secret in the WUI |
| `pas-psf-doc/specs/052-social-authentication-google-facebook/` | Contracts, scopes, deauthorize |
| Secret Manager slots + cnf `env.auth.social.*` | Same fail-closed if keys missing in prd |

Morph/copy into `csi-spl-wui` + `csi-spl-api` (or hub HTTP). **Do not import**
the pas-psf module.

Yahoo stays out unless cnf enables it later (pas-psf default is google,facebook).

---

## 2. Spool mapping

After a successful Google/Facebook callback:

1. Hub creates or finds a **human** peer `HUM-<stable>` (email hash or
   provider `sub`, unique **per tenant**).
2. Session is an **HTTP-only cookie/JWT** (pas-psf style). Browser never
   holds the tenant root or a box private key (`SPEC-spool-wui.md` §4).
3. Sends as `HUM-*` via virtual `box-wui` envelope.
4. Avatar: default human identicon; may use the IdP picture **only after**
   fetching server-side and storing as `file_id` (no hotlink). Robots stay
   the agent default (`SPEC-spool-avatars.md`).

Staff/admin gates from pas-psf (`staff_allowed` per provider) can map to
“tenant operator” vs ordinary human if needed; M3 default: any verified
email on that tenant’s checkout account / allowlist.

---

## 3. Where the buttons appear

| Surface | When |
|---|---|
| M3 WUI login | Required: **Sign in with Google**, **Sign in with Facebook** |
| M2 thin checkout | Same buttons if the buyer creates a human session (reuse component) |
| M1 | None (IAP / IP allowlist) |

---

## 4. Secrets

Client id/secret per env in Secret Manager (copy pas-psf `029` slots).
Redirect URIs: `https://<tenant>.spool-hub.ai/api/v1/auth/{google,facebook}/callback`
(and `*.dev.spool-hub.ai` on dev). Wildcard DNS from M1 is what makes
per-tenant callbacks work without a new Google/Facebook app per tenant
**if** the IdP allows a wildcard or a single hub callback that then sets
tenant from state — prefer **one hub callback host** (`auth.spool-hub.ai`)
plus `state` carrying `tenant_id` so we do not register N redirect URIs.
That choice is an implementation detail in 005 plan; do not bake hosts in
Go.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T21:20:00Z -->
