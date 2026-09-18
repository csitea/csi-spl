# SPEC: Social auth on the spool web UI

Status: **preferred registration and login** for humans (M2 checkout +
M3 WUI). Not M1 (IAP/IP allowlist).

**Google and Facebook are forked from pas-psf and csi-rel.** Microsoft
(Azure / Entra ID), **LinkedIn**, and **xAI** use the **same federated
rails** (new IdP adapters, not a second stack). Do **not** `go get` the
shop modules.

---

## 0. Preferred way to register

**People register by signing in with an IdP** (Google, Facebook, Microsoft,
LinkedIn, xAI). The **first successful callback is registration**: create
`HUM-<stable>` if none exists. There is **no** preferred email+password
sign-up form.

- Login pages lead with the social buttons (large, first). Email/password
  or magic link, if present at all, is **secondary** (collapsed / “other”)
  and is **not** required for M2/M3.
- Same buttons on M2 thin checkout: pay can complete after or before the
  IdP session; the **human account** is the social identity. Tenant root
  key remains the one-time operator secret from payment (`SPEC-spool-milestones.md` M2) — that is not the HUM login.
- IdP must yield a **verified email** (or a stable `sub` if email is
  withheld); otherwise refuse and ask another provider.

## 1. Providers

| Slug | Kind | Source |
|---|---|---|
| `google` | OIDC | Fork csi-rel 045 + pas-psf/csi-rel 052 |
| `facebook` | OAuth 2.0 | Fork 052 (`facebook_idp.go`, deauthorize) |
| `microsoft` | OIDC (Azure AD / Entra ID) | Same `federatedSpec` / `oauth_handlers` as Google |
| `linkedin` | OAuth 2.0 | Same rails as Facebook (authorization code) |
| `xai` | OIDC (cnf issuer) | Same rails as Google; **issuer, authorize, token, jwks URLs from cnf** — never baked |

Enabled set is **cnf** (`env.auth.social.providers`, default
`google,facebook,microsoft,linkedin,xai`). A provider with a missing secret
in prd is **omitted from the button list** and start returns 404; prd boot
**fail-closes** only if a listed provider’s slot is a placeholder *and* the
operator marked it required. lde may run a subset.

Yahoo stays out unless cnf adds it.

Wire (all of them):

`GET /api/v1/auth/<slug>/start` → IdP → `/api/v1/auth/<slug>/callback` → session cookie.

---

## 2. Fork sources (Google / Facebook donors)

| Donor | What it already is |
|---|---|
| **csi-rel** `045-admin-login` + `052-social-authentication-google-facebook` | Google OIDC (`google_idp.go`, `oauth_handlers.go`, `oauth_state.go`); Facebook on the same rails |
| **pas-psf** `052-social-authentication-google-facebook` | Same API + WUI `SocialAuthButtons.vue` / `useSocialProviders.ts` |

| Donor path | Take |
|---|---|
| `csi-rel-api/src/internal/auth/google_idp.go` | Google OIDC |
| `csi-rel-api/src/internal/auth/facebook_idp.go` | Facebook Login |
| `csi-rel-api/src/internal/auth/oauth_handlers.go` | start/callback (extend `<slug>`) |
| `pas-psf-wui/src/components/SocialAuthButtons.vue` | Buttons; cnf list — **add Microsoft, LinkedIn, xAI** |
| `pas-psf-wui/src/composables/useSocialProviders.ts` | start URLs |
| both `052` specs | scopes, deauthorize, fail-closed secrets |

New files in the fork: `microsoft_idp.go`, `linkedin_idp.go`, `xai_idp.go`
(thin; share `federatedSpec`).

---

## 3. Spool mapping

After a successful callback (any slug):

1. Hub **registers or finds** **human** `HUM-<stable>` (verified email or
   provider `sub`, unique **per tenant**). First callback = sign-up.
2. HTTP-only session cookie/JWT. Browser never holds box keys.
3. Sends as `HUM-*` via `box-wui`.
4. Avatar: human default; IdP picture only after server-side fetch → `file_id`.

---

## 4. Where the buttons appear

| Surface | When |
|---|---|
| M3 WUI | **Primary:** Sign in / register with each cnf-enabled IdP. No password form required. |
| M2 thin checkout | **Primary:** same social register/login, then or with pay |
| M1 | None (IAP / IP allowlist) |

---

## 5. Secrets and URLs

Per provider, per env, Secret Manager (fork `029`): client id + secret.
xAI also needs issuer/jwks in cnf (not a secret).

Redirects: prefer **one** hub callback host plus `state` = `tenant_id` so
IdP consoles are not N-tenant. Do not bake hostnames in Go.

Scopes (cnf, no vendor defaults in code comments as URLs):

- google: openid email profile (as 052)
- facebook: email, public_profile (as 052)
- microsoft: openid email profile (Entra)
- linkedin: OpenID or `openid profile email` as the LinkedIn app allows
- xai: openid email profile if the IdP issues them; otherwise cnf

Deauthorize/data-deletion callbacks: Facebook required (052); others as the
IdP requires.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T22:00:00Z -->
