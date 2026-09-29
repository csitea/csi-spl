# Study: free "Sign in with Microsoft" (Office 365 / Entra ID), like Google and Facebook

**Feature ID**: `052-spool-auth-microsoft-study` · **Milestone**: M3 (WUI login) · **Status**: Study (investigation only — no code, no Azure, no secrets)
**Created**: 2026-09-29 · **Lane**: CLE-35115 · **Parent**: `../010-spool-social-auth`
**Answers**: owner HUM-10, prd t1 `#spool-hub-ops` topic `53bbbcc6-eb9a-4993-ae54-bfc406a6fb8e`

Owner ask (verbatim): *"just investigate how-to implement some office 365 based
OAuth from Microsoft — to be free and just recognize that the person who claims
an email has this email similarly to how now Google and Facebook auth work."*

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

---

## 0. Headline finding (verified against the artifacts, not reports)

**The how-to is already designed and coded.** Spec `../018-spool-auth-microsoft`
specifies it, and the hub already carries a complete, tested Microsoft
identity-platform (Entra ID v2.0) client. The email-trust rule the owner asks
for — *"recognize that the person who claims an email has this email"* — is
already the strictest of the three social providers. What is **not** done is the
owner's one-time Azure app registration and the provider-list flip; both are
`Planned` in 018 and need no new code.

Verified 2026-09-29 (worktree `CLE-35115`, off `a4c073cf`):

| claim | artifact | evidence |
|---|---|---|
| Microsoft OIDC client exists | `csi-spl-api/src/go/spool-hub-api/internal/auth/microsoft.go` | 274 lines: PKCE S256, JWKS RS256 verify, `iss/aud/nonce/exp` checks, tenant-mode rule, nOAuth email rule |
| config validated + fail-fast | `.../internal/auth/config.go` | `SPOOL_HUB_AUTH_MICROSOFT_{CLIENT_ID,CLIENT_SECRET,REDIRECT_URI,SCOPES,TENANT,TRUST_EMAIL}`; `TRUST_EMAIL=true` refused in prd |
| tests green (fake IdP) | `.../internal/auth/microsoft_test.go`, `fakeidp/` | personal + work-with-`xms_edov` pass; forged `aud/iss/tid/nonce`, expired, unknown `kid`, bad PKCE, work-without-`xms_edov` refused (018 SC-001/002) |
| WUI button + i18n | `csi-spl-wui/src/components/SocialAuthButtons.vue` | `social-logo-microsoft`; `continue_microsoft` in **19/19** locale files |
| cnf keys wired (placeholders) | `csi-spl-cnf/csi-spl/{dev,prd}.env.{yaml,json}` | client id `PLACEHOLDER-microsoft-client-id`, redirect URIs set, `TENANT: common`, secret slot `csi-spl-hub-auth-microsoft-client-secret` |
| **provider OFF** everywhere | same cnf | `SPOOL_HUB_AUTH_PROVIDERS: google,facebook` — `microsoft` not listed in dev or prd |

So this study is a **decision record**, not a build order: it answers the six
questions with current Microsoft Learn sources and dates, confirms the code
already matches those answers, and states the small remainder as one blocker
(§7). Sizing of any *new* work is in §6 (answer: near-zero code; owner portal
work only).

---

## 1. Cost — is it free?

**Yes, free for our use.** Registering an app and signing users in with OpenID
Connect is part of **Microsoft Entra ID Free**; there is no per-sign-in or
per-app charge, and no Azure compute/subscription spend is incurred by the
sign-in itself.

- What the owner needs: an **Entra ID tenant** (directory) to *own* the app
  registration, and an account in it with at least the **Application Developer**
  role. A free Azure account creates such a tenant. Personal Microsoft accounts
  can no longer register apps outside a directory.
- The one prerequisite Microsoft Learn lists on the register-app quickstart is
  *"An Azure account that has an active subscription"* with a *"Create an account
  for free"* link — i.e. the account/tenant is the cost gate, not the app or the
  sign-ins. We already meet this: the owner has an Entra tenant (the org runs
  Office 365 / Microsoft 365).
- Only *extra* things cost money and we use **none** of them: Entra ID P1/P2
  features (Conditional Access, Identity Protection), Azure AD B2C / External ID
  paid MAU tiers, or Graph data beyond `openid email profile`.
- Who creates it: the **owner** (an agent cannot click the Azure portal, and
  creating a registration is an owner action — 018 runbook §0).

Sources: [Register an app (Entra ID)](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
(ms.date 2026-05-14, updated 2026-06-15) · [OIDC on the Microsoft identity platform](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc)
(ms.date 2026-06-30).

## 2. Endpoint choice — who can sign in

To let **both** work/school (Office 365) **and** personal Microsoft accounts
sign in, use the `common` authority and a **multitenant + personal** app.

Microsoft Learn's authority table (v2 OIDC doc, ms.date 2026-06-30), verbatim:

| authority | who signs in |
|---|---|
| `common` | personal Microsoft account **and** work/school (Entra ID) accounts |
| `organizations` | work/school (Entra ID) only |
| `consumers` | personal Microsoft account only |
| tenant GUID / `contoso.onmicrosoft.com` | that one tenant only |

- **Recommended: `common`.** Azure *Supported account types* = *"Accounts in any
  organizational directory (Any Microsoft Entra ID tenant - Multitenant) and
  personal Microsoft accounts (Skype, Xbox)"*. The Azure setting and the cnf
  `SPOOL_HUB_AUTH_MICROSOFT_TENANT` **must match** or Entra answers `AADSTS50194`
  / `AADSTS9002331`. Our cnf is already `common`.
- **Consent prompt.** Personal accounts and users in most tenants see the normal
  first-time consent for *Sign you in and read your profile* (scopes `openid
  email profile`). In tenants whose admins restrict consent to **verified
  publishers**, work users of an *unverified* multitenant app see *"Need admin
  approval"* — personal accounts are unaffected. **Publisher verification** (a
  free Microsoft AI Cloud Partner Program ID + a verified publisher domain)
  removes that prompt; it is only needed before advertising *work* sign-in on
  prd (018 OQ-M5, runbook §5).

Source: [OIDC on the Microsoft identity platform](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc)
· [Publisher verification overview](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview).

## 3. The email-trust problem (the core of the ask)

**Microsoft's `email` claim is NOT verified by default.** Learn's optional-claims
reference warns, verbatim, that `email` *"isn't guaranteed to be correct, and is
mutable over time — never use it for authorization or to save data for a user"*,
and repeats: *"Never use `email` or `upn` claim values to store or determine
whether the user … should have access to data."* A tenant admin can put an
arbitrary, unverified address in a user's mail attribute — the **nOAuth** class
of account-takeover, where attacker-tenant "email = victim@othercorp.com" would
be silently trusted by a naive relying party.

### How we know the person really owns the address

The hub trusts `email` only when one of these holds (already coded in
`microsoft.go`, 018 FR-005):

1. **Personal Microsoft account** — `tid` equals the consumer tenant
   `9188040d-6c67-4c5b-b112-36a304b66dad`. Microsoft itself verified the
   address (Outlook/Hotmail/Live/Xbox).
2. **Work/school account with `xms_edov` = true** — the optional ID-token claim
   *"email domain owner verified"*. Learn defines it verbatim: *"Boolean value
   indicating whether the user's email domain owner has been verified. An email
   is considered domain verified if it belongs to the tenant where the user
   account resides and the tenant admin has done verification of the domain …
   For this claim to be returned in the token, the presence of the `email` claim
   is required."*

Otherwise the sign-in is refused with `auth_error=email_unverified` and no
session. `xms_edov` must be added as an optional ID-token claim on the app
registration (018 runbook §2.5); without it every work account is refused and
personal accounts still work.

`verified_primary_email` / `verified_secondary_email` (optional claims sourced
from the user's `PrimaryAuthoritativeEmail` / `SecondaryAuthoritativeEmail`)
exist too, but `xms_edov` is the purpose-built domain-ownership signal and the
one Microsoft's nOAuth guidance points at; the hub uses `xms_edov` and does not
depend on the `verified_*` pair.

### The identity key never depends on email

`Identity.Subject = <tid>/<oid>` — the immutable tenant-id + object-id pair,
stable per person across time. The hub keys the account on that, never on the
mutable `email`/`upn`/`preferred_username`, and never merges two IdP subjects
because their emails happen to match. This is exactly Microsoft's nOAuth
mitigation: authorize on the immutable subject, treat email as a verified
attribute only.

### How this compares to our Google and Facebook paths (verified in code)

| provider | source of identity | how `email_verified` is decided (`internal/auth/idp.go`) |
|---|---|---|
| **Google** | OIDC userinfo (server-to-server) | requires `email` present **and** `email_verified == true`; else `errEmailUnverified` |
| **Facebook** | Graph `/me` (`appsecret_proof`) | Graph **omits** `email` unless Facebook has a confirmed address; a present address *is* the attestation; absent → refused |
| **Microsoft** | validated **id_token** (JWKS RS256) | personal-account `tid` **or** `xms_edov==true`; else refused. Strictest of the three, and immune to nOAuth by keying on `<tid>/<oid>` |

So Microsoft meets the owner's bar — *"recognize that the person who claims an
email has this email"* — at least as strongly as Google and Facebook, and adds
the immutable-subject rule the other two do not need because their subjects are
already global.

Sources: [Optional claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/optional-claims-reference)
(ms.date 2026-07-22, updated 2026-08-20) · [ID token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference)
· [Migrate off email-claim authorization (nOAuth guidance)](https://learn.microsoft.com/en-us/entra/identity-platform/migrate-off-email-claim-authorization).

## 4. Implementation plan in our code

**None required for the feature itself** — it is already built (§0). For
completeness, the files that make up "Sign in with Microsoft", each already
present:

| layer | file(s) | state |
|---|---|---|
| provider client | `internal/auth/microsoft.go` (registered in `newIdP`, `idp.go`) | Implemented |
| start / callback | shared `handler.go` flow; Microsoft is a `nonceExchanger` (PKCE verifier from the signed-state nonce) | Implemented |
| id_token validation via JWKS | `microsoft.go` `verifyRS256` + `jwksCache` (24 h cache, ≤1 MiB, refetch-on-unknown-kid ≤1/min) | Implemented |
| providers list endpoint | `/api/v1/auth/providers` (button shows only when it lists `microsoft`) | Implemented |
| cnf keys | `SPOOL_HUB_AUTH_MICROSOFT_*` in `{dev,prd}.env.{yaml,json}` | Implemented (client id is a placeholder) |
| secret in Secret Manager | `IDP=microsoft ENV=<env> ./run -a do_spl_auth_idp_secret_seed` (`csi-spl-orc/src/bash/run/spl-auth-idp-secret-seed.func.sh`, secret `csi-spl-hub-auth-microsoft-client-secret`) | action Implemented; no secret version yet |
| callback URLs | `https://dev.spool-hub.ai/api/v1/auth/microsoft/callback`, `https://spool-hub.ai/api/v1/auth/microsoft/callback` (Firebase rewrites `/api/v1/auth/**` to the hub) | Implemented |
| WUI button + 19 locales | `SocialAuthButtons.vue`, `continue_microsoft` ×19 | Implemented |
| tests | `microsoft_test.go`, `export_microsoft_test.go`, `fakeidp/` | Implemented, green |

**Size estimate of remaining *code*: 0.** Remaining *config* change: one line —
add `microsoft` to `SPOOL_HUB_AUTH_PROVIDERS` per env after the app exists — plus
setting the real client id in cnf. Remaining *owner* work: §5.

## 5. Owner steps (numbered) — go-live runbook

The detailed portal clicks already live in
`../018-spool-auth-microsoft/azure-registration-runbook.md`; this study adds only
the recommended answers and a condensed checklist in
[`owner-runbook.md`](owner-runbook.md). In short, per env (dev first, then prd):

1. Entra admin center → *App registrations* → *New registration*: name
   `spool-hub-<env>`, **Supported account types = multitenant + personal
   accounts** (= cnf `common`), platform **Web**, redirect URI = the cnf value.
2. *Certificates & secrets* → new **client secret** (12-month expiry); copy the
   **Value** (not the Secret ID).
3. *API permissions* → Microsoft Graph **Delegated**: `openid email profile`.
4. *Token configuration* → add optional **ID-token** claims `email` **and**
   `xms_edov` (without `xms_edov`, work accounts are refused).
5. Write `$HOME/.gcp/.csi/.spl/microsoft-client-<env>.json` (mode 0600,
   `{"client_id":"…","client_secret":"…"}`); tell ORC.
6. Agent seeds the secret (`do_spl_auth_idp_secret_seed`), sets the real client
   id in cnf, flips `SPOOL_HUB_AUTH_PROVIDERS` to add `microsoft`, renders,
   deploys, and verifies a real personal + work sign-in.
7. Before advertising **work** sign-in on prd: publisher verification (§2).

## 6. Success criteria (of this study)

- **SC-001** — Each owner question (1–5) answered with a current Microsoft Learn
  URL and its date. ✔ (§1–§3)
- **SC-002** — The claim "already implemented" is proven against artifacts, not
  reports (§0 table cites files/tests). ✔
- **SC-003** — The email-trust rule compared to Google and Facebook in code (§3
  table). ✔
- **SC-004** — Remainder stated as one blocker with a recommended answer each
  (§7). ✔

## 7. Risks and open questions (one blocker; each has a recommended answer)

1. **Turn it on?** The whole feature is dark behind `SPOOL_HUB_AUTH_PROVIDERS`.
   *Recommended:* yes — register the dev app, flip dev, verify, then prd. It is
   free (§1) and the code is done.
2. **Which accounts?** *Recommended:* `common` (both work and personal), matching
   the shipped cnf. Narrow to `organizations` only if personal accounts are
   unwanted.
3. **Unverified work-domain accounts?** *Recommended:* keep refusing them
   (`email_unverified`); it is the nOAuth-safe default and already enforced
   (`TRUST_EMAIL=false`, refused in prd). Requires the `xms_edov` claim on the
   app (step §5.4).
4. **One app per env or one shared?** *Recommended:* one per env (a dev secret
   cannot redeem prd codes; independent rotation).
5. **Publisher verification before prd work sign-in?** *Recommended:* yes (free
   MPN ID + verified publisher domain); otherwise some work users hit "Need
   admin approval". Personal accounts never do.
6. **Do we even want a *new* spec?** This is a study; the implementation
   authority stays `../018-spool-auth-microsoft`. *Recommended:* the integrator
   adds `052` to `README.md` §4 as a decision record and leaves 018 as the build
   spec. (This lane does not edit `README.md` — one dir per lane, README is the
   integrator's.)

## 8. Non-goals

Any code change (there is none to make), Azure resource creation, secret
handling, Graph access beyond sign-in, Entra roles/groups as privilege, B2C /
External ID customer tenants, device-code CLI flow, single sign-out. All are
out of scope for an investigation, and most are 018 non-goals too.

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T19:24:35Z -->
