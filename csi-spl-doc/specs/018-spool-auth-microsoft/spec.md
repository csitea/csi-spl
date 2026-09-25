# Feature Specification: Spool sign-in with Microsoft (Entra ID / Microsoft identity platform)

**Feature ID**: `018-spool-auth-microsoft` · **Milestone**: M3 (WUI login) · **Status**: Partial (code Implemented; live after the owner's Azure registration)
**Created**: 2026-09-19 · **Lane**: CLE-3386 · **Parent**: `../010-spool-social-auth` (FR-012, OQ-I1)
**Donor**: csi-rel `csi-rel-api/src/internal/auth/oidc_idp.go` + `social_providers.go` (Microsoft on the generic OIDC client, `common` authority)

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

Owner brief (2026-09-19, verbatim): *"start the specifications for creating
auth similar to Google Auth but with Microsoft Azure: all auth with Microsoft
Azure. First do the Git spec then start the actual implementation."*

---

## 0. Starting point (re-measured)

010 T040 (`f17210e`) put `microsoft` on the generic OIDC client
(`internal/auth/oidc.go`): authorization code without PKCE, identity from
Graph `/oidc/userinfo`, authority `SPOOL_HUB_AUTH_MICROSOFT_TENANT` default
`consumers` (personal accounts only). Any other tenant was refused at boot unless
`SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL=true`, which trusted a work tenant's
unverified `email` as-is. It was tested only against the fake IdP, and it is
listed in no env (`yq '.env.auth.social.env.SPOOL_HUB_AUTH_PROVIDERS' csi-spl-cnf/csi-spl/dev.env.yaml` → `google`).

What "all auth with Microsoft Azure" adds on top:

1. **Every kind of Microsoft account** can sign in: personal (Outlook, Hotmail,
   Live, Xbox) **and** work/school (any Entra ID tenant). The old code offered
   either personal only, or work accounts with an unverified email trusted.
2. The protocol is the one Microsoft recommends for a confidential web app:
   **authorization code + PKCE (S256)**, and the identity comes from a
   **validated `id_token`** (signature, issuer per tenant, audience, nonce,
   lifetime), not from a userinfo call.
3. A work account's email is accepted only when **the tenant has verified the
   domain it claims** (`xms_edov`), which closes the cross-tenant email
   take-over ("nOAuth").
4. The owner's app registration and secret path are written as runbooks and named actions.

## 1. User stories

- **US-1 (P1)** — As a person with a personal Microsoft account, I press
  *Sign in with Microsoft* on the WUI login page, sign in at Microsoft, and
  land back in the WUI signed in, like with Google.
- **US-2 (P1)** — As a person with a work/school account in any Entra tenant, I
  do the same. If my organisation has not verified the domain of my email
  address, I am refused with `auth_error=email_unverified` and no session.
- **US-3 (P1)** — As the owner, I register one app per env in the Azure portal
  by following a runbook, save two values in a 0600 file, run one named action,
  and flip one cnf list. Nothing else is by hand.
- **US-4 (P2)** — As an operator, I can see from the hub log why a Microsoft
  sign-in failed (bad state, token error, id_token check, unverified email).
  The log never includes the code, token or secret.

## 2. Functional requirements

- **FR-001 — Authority / tenant mode (OQ-M1).** `SPOOL_HUB_AUTH_MICROSOFT_TENANT`
  is `common` (default), `consumers`, `organizations` or a tenant GUID.
  Anything else fails the boot. Every URL is built from
  `https://login.microsoftonline.com/<tenant>/…`. After the id_token checks, the
  `tid` claim must fit the mode: `consumers` → `tid` = the personal-account
  tenant `9188040d-6c67-4c5b-b112-36a304b66dad`; `organizations` → any other
  `tid`; a GUID → exactly that `tid`; `common` → any.
  **Implemented** (T010).
- **FR-002 — Authorization code + PKCE.** `start` redirects to
  `/<tenant>/oauth2/v2.0/authorize` with `response_type=code`,
  `response_mode=query`, `scope`, `state`, `nonce`,
  `code_challenge=<S256(verifier)>`, `code_challenge_method=S256` and
  `prompt=select_account`. The verifier is **never sent to the browser**. It is
  `base64url(HMAC-SHA256(subkey(SESSION_KEY,"spool-auth-pkce-v1"), nonce))`,
  so the callback can compute it again from the nonce in the signed state. No
  server-side store is needed. The token request sends `code_verifier` and the
  client secret (`client_secret_post`). **Implemented** (T011).
- **FR-003 — id_token validation.** The token response must contain an
  `id_token`. The hub accepts it only if all of these hold: alg `RS256`, a `kid`
  found in the JWKS `https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys`
  (cached 24 h, refetched on an unknown `kid` at most once per minute, body ≤ 1 MiB),
  a valid signature; `aud` = client id; `iss` =
  `https://login.microsoftonline.com/<tid>/v2.0` with `tid` a GUID;
  `exp` in the future and `nbf`/`iat` not in the future (5 min skew);
  `nonce` = the flow's nonce; FR-001's tenant rule. Any failure →
  `auth_error=exchange_failed`, and no session. **Implemented** (T012).
- **FR-004 — Identity.** `Identity.Subject` = `<tid>/<oid>`, which is
  Microsoft's stable per-person key across app registrations. `sub` is
  pairwise per app, so re-registering the app would turn every person into a
  new `HUM-*` (010 T012 never links by email). `Name` = `name`. The email is
  `email` in lower case. There is no fallback to `preferred_username` or `upn`,
  because Microsoft documents both as mutable and unverified.
  **Implemented** (T012).
- **FR-005 — Email trust (the nOAuth rule, OQ-M2).** The email is accepted when
  `tid` is the personal-account tenant (Microsoft verified the address), or when
  the optional claim `xms_edov` ("email domain owner verified") is true (JSON
  `true`, `"true"` or `1`). Otherwise the result is `auth_error=email_unverified`.
  `SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL=true` is the owner's override that
  skips the `xms_edov` requirement. It is refused in `prd` whenever `microsoft`
  is an enabled provider (`config.go` checks it in `validateProvider`, which runs
  only for listed providers). **Implemented** (T010, T012).
- **FR-006 — Avatar.** None from Microsoft in this feature. The Graph photo
  needs `User.Read` and an authenticated fetch, so the WUI shows initials.
  **Planned** (T030, only if the owner asks).
- **FR-007 — Config fail-fast** (010 FR-007 rules, unchanged). While
  `microsoft` is listed, `CLIENT_ID`, `CLIENT_SECRET` and `REDIRECT_URI` must be
  real values. The redirect path must be `/api/v1/auth/microsoft/callback`, and
  `https` in dev/prd. `SCOPES` must include `openid` and `email`.
  **Implemented** (T010).
- **FR-008 — Fake IdP parity.** `fakeidp` serves the Microsoft-shaped paths
  (`/<tenant>/oauth2/v2.0/{authorize,token}`, `/<tenant>/discovery/v2.0/keys`).
  It signs RS256 id_tokens with a per-process key, checks PKCE, and can play a
  personal account, a work account with or without `xms_edov`, and a wrong
  `tid`/`aud`/`nonce`. The id_token checks are then exercised end to end in
  `go test`, lde and the auth-demo. **Implemented** (T013).
- **FR-009 — Owner registration, per env (OQ-M3).** One app registration per env
  (`spool-hub-dev`, `spool-hub-prd`) with *Supported account types* = the
  tenant mode (FR-001), platform **Web**, redirect URIs as in §3, a client
  secret, the `xms_edov` optional claim on the ID token, and delegated Graph
  permissions `openid email profile`. Runbook: `azure-registration-runbook.md`.
  **Planned** (owner, T040-T041).
- **FR-010 — Secret path.** The owner writes
  `$HOME/.gcp/.csi/.spl/microsoft-client-<env>.json` (0600,
  `{"client_id":"…","client_secret":"…"}`, the secret **Value**, not the
  Secret ID). The shared action
  `IDP=microsoft ENV=<env> DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed`
  (csi-spl-orc, owned by the LinkedIn lane CLE-3387, spec 019) then adds the
  Secret Manager version `csi-spl-hub-auth-microsoft-client-secret`, running
  as the env's project service account. It refuses a client id that differs
  from cnf, a bare-GUID secret (the Secret ID) and a non-0600 file. The slot is
  terraform step 030 (010 T021). **Implemented by CLE-3387** (T020 records the sha).
- **FR-011 — WUI button.** The login page shows *Sign in with Microsoft* with
  Microsoft's four-square mark, following Microsoft's sign-in branding (light
  theme: white `#FFFFFF`, 1px `#8C8C8C` border, text `#5E5E5E`). It shows only
  when `/api/v1/auth/providers` lists `microsoft`. The WUI lane owns the code
  (CLE-55). **Implemented** (e8c2f75, T025: `social-logo-microsoft` in
  `SocialAuthButtons.vue`, `continue_microsoft` in 19/19 locales).
- **FR-012 — Rollout.** dev first, then prd. A provider is listed only after
  (1) its app exists, (2) the client id is in cnf, (3) the secret has a
  version. The hub image must carry this feature's code (deploy lane). See
  `plan.md` §5. **Planned** (T042-T045).

## 3. Redirect URIs (register byte for byte)

The redirect URI is what cnf renders into `SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI`
(010 T022: `<APP_URL>/api/v1/auth/microsoft/callback`, derived from
`env.dns.fqdn`). Print it rather than copying it from here:

```bash
yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI' csi-spl-cnf/csi-spl/dev.env.json
```

On 2026-09-19 that is `https://dev.spool-hub.ai/api/v1/auth/microsoft/callback`
(dev) and `https://spool-hub.ai/api/v1/auth/microsoft/callback` (prd).
**Decided** (010 OQ-A2, 019 FR-L5): the callback stays on the WUI apex, which
Firebase Hosting rewrites to the hub (`csi-spl-wui/firebase.json`:
`"source": "/api/v1/auth/**"`); `csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh`
derives `<APP_URL>/api/v1/auth/<p>/callback`. Register the apex URI. The
api-host URI below is optional: the hub never sends it (Entra allows up to
256 per app):

| env | redirect URIs on that env's app |
|---|---|
| dev | `https://dev.spool-hub.ai/api/v1/auth/microsoft/callback` · `https://dev.api.spool-hub.ai/api/v1/auth/microsoft/callback` |
| prd | `https://spool-hub.ai/api/v1/auth/microsoft/callback` · `https://api.spool-hub.ai/api/v1/auth/microsoft/callback` |

The hub sends exactly one of them, the cnf value. Entra refuses a
`redirect_uri` that is not registered (`AADSTS50011`).

## 4. Open questions (owner) — each has a recommended default, already implemented

- **OQ-M1 — Which Microsoft accounts?** (a) **Recommended, cnf default:**
  `common`, meaning personal accounts and every work/school tenant. Azure
  setting: *"Accounts in any organizational directory (Any Microsoft Entra ID
  tenant - Multitenant) and personal Microsoft accounts (e.g. Skype, Xbox)"*.
  (b) `consumers`, personal only (the 010 default). (c) `organizations`, work/school
  only. (d) a single tenant GUID, your own organisation only. The Azure setting
  and the cnf value must match, or Entra answers `AADSTS50194` / `AADSTS9002331`.
- **OQ-M2 — Work accounts whose domain is not verified.** (a) **Recommended,
  implemented:** refused (`email_unverified`). (b) Trust them
  (`SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL=true`, dev only, refused in prd). With
  (a), the `xms_edov` optional claim must be added in *Token configuration*
  (runbook §2.5). Without it every work account is refused, and personal
  accounts still work.
- **OQ-M3 — One app for both envs, or one per env?** (a) **Recommended:** one
  per env. A dev secret then cannot redeem prd codes, and each secret rotates on
  its own. (b) One app with all four redirect URIs. Everything works the same,
  but there is one secret for both envs.
- **OQ-M4 — Client secret or certificate?** (a) **Recommended:** a client secret
  (24-month maximum; the runbook rotates it at 12 months), on the same rails as
  every other provider. (b) A certificate (`private_key_jwt`) needs new code
  (a signed client assertion). Planned only on request (T031).
- **OQ-M5 — Publisher verification.** In tenants whose admins allow user
  consent only for *verified publishers* (Microsoft's recommended setting),
  work users of an unverified multitenant app see *"needs admin approval"*.
  Personal accounts are not affected. (a) **Recommended:** go live on dev
  unverified; before advertising work sign-in on prd, verify the publisher
  (Microsoft AI Cloud Partner Program ID + a verified domain on the app,
  runbook §5). (b) Live without verification; some work users will need their
  admin to consent.

## 5. Success criteria

- **SC-001** — Implemented (fake IdP): personal account, and work account with
  `xms_edov=true`, each complete start → callback → `/session` = 200
  (`go test -run TestMicrosoft ./internal/auth/`).
- **SC-002** — Implemented (fake IdP): forged `aud`, `iss`, `tid` (per mode),
  `nonce`, expired token, unknown `kid`, a bad signature, a missing or wrong
  PKCE verifier, and a work account without `xms_edov` are each refused. The
  valid token passes, which is the positive control of the same test.
- **SC-003** — Planned (owner values): `curl -s https://<dev host>/api/v1/auth/providers`
  lists `microsoft`. The `start` Location carries the real client id, the cnf
  redirect URI and `code_challenge_method=S256`. A real personal-account sign-in
  on dev logs `auth.login_ok provider=microsoft`. Then the same on prd.

## 6. Non-goals

Graph API access beyond sign-in, Entra app roles or groups as privilege (an IdP
never mints privilege, 010), Azure AD B2C / External ID customer tenants, the
device-code flow for the CLI, and single sign-out.

<!-- version: 0.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:40:00Z -->
