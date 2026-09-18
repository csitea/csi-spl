# SPEC: Google and Facebook auth on the spool web UI

Status: **M3 WUI** (login to the Slack-like UI). Optional on the M2 thin
checkout page. Not M1 (IAP/IP allowlist; no public login).  
**Forked from pas-psf and csi-rel.** Do not invent a second OIDC stack.
Copy those trees into `csi-spl-wui` / `csi-spl-api`, then adapt (HUM-*
session, tenant, no shop roles). Do **not** `go get` those modules.

---

## 1. Fork sources (read-only donors)

| Donor | What it already is |
|---|---|
| **csi-rel** spec `045-admin-login` + `052-social-authentication-google-facebook` | Google OIDC first (`google_idp.go`, `oauth_handlers.go`, `oauth_state.go`); Facebook on the same rails |
| **pas-psf** spec `052-social-authentication-google-facebook` | Same API + **WUI** `SocialAuthButtons.vue` / `useSocialProviders.ts` on login, register, checkout |

Wire: `GET /api/v1/auth/{google,facebook}/start` → IdP → `/callback` → session cookie.

| Donor path | Take |
|---|---|
| `csi-rel-api/src/internal/auth/google_idp.go` | Google OIDC |
| `csi-rel-api/src/internal/auth/facebook_idp.go` | Facebook Login |
| `csi-rel-api/src/internal/auth/oauth_handlers.go` | start/callback |
| `csi-rel-wui` login Google button (045) | Admin/customer Google |
| `pas-psf-wui/src/components/SocialAuthButtons.vue` | Both buttons; cnf list |
| `pas-psf-wui/src/composables/useSocialProviders.ts` | start URLs |
| `pas-psf-api/src/internal/auth/` | Same Go rails as csi-rel (morph) |
| both `052` specs | scopes, deauthorize, fail-closed secrets |

Yahoo stays out unless cnf enables it later.


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

Client id/secret per env in Secret Manager (fork pas-psf/csi-rel `029` slots).
Redirect URIs: `https://<tenant>.spool-hub.ai/api/v1/auth/{google,facebook}/callback`
(and `*.dev.spool-hub.ai` on dev). Wildcard DNS from M1 is what makes
per-tenant callbacks work without a new Google/Facebook app per tenant
**if** the IdP allows a wildcard or a single hub callback that then sets
tenant from state — prefer **one hub callback host** (`auth.spool-hub.ai`)
plus `state` carrying `tenant_id` so we do not register N redirect URIs.
That choice is an implementation detail in 005 plan; do not bake hosts in
Go.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T21:30:00Z -->
