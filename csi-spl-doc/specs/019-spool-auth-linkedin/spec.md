# Feature Specification: Sign in with LinkedIn (OpenID Connect)

**Feature ID**: `019-spool-auth-linkedin` · **Status**: Partial (010 T041 client Implemented; 019 guards, seed action and rollout Planned; live only after the owner registers the apps)
**Created**: 2026-09-19 · **Lane**: AUTH-LINKEDIN CLE-3387 · **Parent**: `../010-spool-social-auth/` (FR-012, T041)
**Sibling**: `../018-spool-auth-microsoft/` (CLE-3386, same rails) · **Donor**: csi-rel `csi-rel-api/src/internal/auth/social_providers.go` (LinkedIn descriptor), `oidc_idp.go`, `csi-rel-orc/src/bash/run/provision-social-provider-secrets.func.sh`

Owner order (2026-09-19, verbatim): *"Ditto for LinkedIn authentication."* — i.e. auth
like Google Auth, with LinkedIn: git-spec first, then the implementation.

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

---

## 0. What exists today (re-measured 2026-09-19, tree `6089590`)

| Piece | Where | Check |
|---|---|---|
| `linkedin` on the generic OIDC client (`f17210e`, 010 T041) | `csi-spl-api/src/go/spool-hub-api/internal/auth/oidc.go` | `grep -c linkedin oidc.go` → 4 (3 consts + the `newOIDC` case) |
| `email_verified` required for LinkedIn | `oidc.go` `Exchange` (`EmailTrusted=false`) | `go test -run TestOIDCEmailVerification ./internal/auth/` → ok |
| Fail-fast config for the LinkedIn keys | `internal/auth/config.go` | `go test -run TestConfigOIDC ./internal/auth/` → ok |
| cnf slots | `csi-spl-cnf/csi-spl/all.env.yaml` `env.auth.social` | `grep -c LINKEDIN csi-spl-cnf/csi-spl/all.env.yaml` → 4 (id, redirect, scopes, secret slot) |
| WUI label | `csi-spl-wui/src/utils/auth-client.mjs` `NAMES.linkedin` | `grep -c "linkedin: 'LinkedIn'" csi-spl-wui/src/utils/auth-client.mjs` → 1 |
| Tested only against the fake IdP | `internal/auth/fakeidp` | never against LinkedIn itself: no app is registered |

Not there before this spec: a LinkedIn-shaped contract test, a scope guard, a
seed action for a non-Google client secret, a LinkedIn brand mark in the WUI,
and an owner runbook naming the files the agent needs.

## 1. LinkedIn facts this spec relies on (measured, n=1, 2026-09-19)

`curl -s https://www.linkedin.com/oauth/.well-known/openid-configuration`:

| field | value |
|---|---|
| `issuer` | `https://www.linkedin.com/oauth` |
| `authorization_endpoint` | `https://www.linkedin.com/oauth/v2/authorization` |
| `token_endpoint` | `https://www.linkedin.com/oauth/v2/accessToken` |
| `userinfo_endpoint` | `https://api.linkedin.com/v2/userinfo` |
| `jwks_uri` | `https://www.linkedin.com/oauth/openid/jwks` (→ 200) |
| `response_types_supported` | `code` |
| `subject_types_supported` | **`pairwise`** |
| `id_token_signing_alg_values_supported` | `RS256` |
| `scopes_supported` | `openid`, `profile`, `email` |
| `claims_supported` | `iss aud iat exp sub name given_name family_name picture email email_verified locale` |

The three endpoints are byte-identical to the Go consts in `oidc.go` and to the
csi-rel donor. `curl -s -o /dev/null -w '%{http_code}' https://api.linkedin.com/v2/userinfo` → 401 without a token.

Consequences:

- **Product**: the app needs the self-serve LinkedIn product *"Sign In with LinkedIn
  using OpenID Connect"*, which grants exactly `openid profile email`. No other
  LinkedIn product (Marketing, Community, legacy `r_liteprofile`/`r_emailaddress`) is used.
- **`sub` is pairwise**: it is per LinkedIn app. The hub keys an identity on
  `(provider, subject)` and never links by email (010 T012). So replacing an env's
  LinkedIn app later gives every returning LinkedIn user a **new** `HUM-*`. The app,
  once created, is kept for the life of the env; only its secret rotates (OQ-L2).
- **`email_verified`** is a declared claim; LinkedIn's userinfo returns it as a JSON
  boolean. The hub keeps requiring it truthy (fail closed; the csi-rel donor instead
  trusts LinkedIn's email by default — deviation D1, §5).
- **`picture`** is an https URL on LinkedIn's media CDN; it goes through the existing
  avatar policy (`fetchAvatar`: https, ≤3 https redirects, 5 s, 256 KiB, sniffed type).

## 2. User stories

- **US-1** — A visitor on the WUI login page clicks **Continue with LinkedIn**, signs
  in at linkedin.com, and lands back on the WUI signed in, with the same session,
  tenant admission (invite / membership) and avatar as a Google sign-in.
- **US-2** — A LinkedIn account whose primary email is not verified is refused with
  `auth_error=email_unverified`; nothing is written.
- **US-3** — The owner registers one LinkedIn app per env from a runbook, drops one
  0600 file per env, and an agent takes it live with named actions only.

## 3. Functional requirements

- **FR-L1** — Implemented (`f17210e`): `linkedin` is an authorization-code
  confidential client (client_secret_post) on the generic OIDC client, endpoints
  from §1, identity from userinfo fetched with the fresh access token (same as
  Google, 010 FR-004). The `state` is signed and bound to the browser cookie (010 FR-002).
- **FR-L2** — Planned (T010): the configured scopes must contain `openid` and
  `email`; otherwise the hub refuses to boot while `linkedin` is listed (a scope set
  without `email` makes every sign-in fail `email_unverified`).
- **FR-L3** — Planned (T011): a LinkedIn-shaped userinfo is accepted only with
  `email_verified: true` (bool or `"true"`); `false`, missing, or an empty email is
  `email_unverified`; the name is `name`; `picture` is fetched through `fetchAvatar`.
- **FR-L4** — Planned (T020): the client secret reaches Secret Manager only through
  `IDP=linkedin ENV=<env> ./run -a do_spl_auth_idp_secret_seed` (csi-spl-orc), from the
  owner file `$HOME/.gcp/.csi/.spl/linkedin-client-<env>.json` (§4). Same action serves
  `microsoft` (018), `facebook`, `xai`.
- **FR-L5** — Owned by CLE-3380 (A7 cross-origin): the callback is on the **hub API
  host**, `https://api.<fqdn>/api/v1/auth/linkedin/callback`, derived by
  `do_spl_merged_cnf`; `SPOOL_HUB_AUTH_APP_URL` stays the WUI origin. Values:
  dev `https://dev.api.spool-hub.ai/api/v1/auth/linkedin/callback`,
  prd `https://api.spool-hub.ai/api/v1/auth/linkedin/callback`.
  Today (`yq .env.auth.social.env.SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI csi-spl-cnf/csi-spl/dev.env.json`)
  the render still says the WUI host `https://dev.spool-hub.ai/...`; 019 does not
  change the derivation.
- **FR-L6** — Owned by CLE-55 (WUI): the login page shows a LinkedIn brand mark next to
  "Continue with LinkedIn" (the button itself already appears when the hub lists
  `linkedin`: the list is registry-driven).
- **FR-L7** — Planned (T051/T052, blocked on the owner): `linkedin` is listed in
  `SPOOL_HUB_AUTH_PROVIDERS` for dev, then prd, only after that env's client id is in
  cnf and its secret version exists (010 FR-007: otherwise the hub refuses to boot).

## 4. What the owner provides (the only inputs the agent needs)

Per env (`dev`, `prd`), one file, mode `0600`, owned by the box user:

```
$HOME/.gcp/.csi/.spl/linkedin-client-dev.json
$HOME/.gcp/.csi/.spl/linkedin-client-prd.json
```

Content, exactly two keys:

```json
{"client_id": "<LinkedIn Client ID>", "client_secret": "<LinkedIn Primary Client Secret>"}
```

The client id is public and is committed to `csi-spl-cnf/csi-spl/<env>.env.yaml`
(`SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID`). The secret never enters git, a log or a message.
Console steps: `owner-runbook.md`.

## 5. Deliberate deviations from the csi-rel donor

| # | csi-rel | here | why |
|---|---|---|---|
| D1 | `EmailVerifiedByDefault: true` for LinkedIn | `email_verified` truthy required | LinkedIn declares the claim (§1); fail closed like Google (010 FR-004). |
| D2 | `do_provision_social_provider_secrets` takes the secret in an env var, creates the secret and grants IAM | `do_spl_auth_idp_secret_seed` reads a 0600 file, only adds a **version** to the slot 030 made, compares sha256, dry run by default | the value never sits in argv/env/shell history; slots + IAM are terraform here (010 T021). |
| D3 | secret ids `csi-rel-linkedin-client-{id,secret}` | client id in cnf, one slot `csi-spl-hub-auth-linkedin-client-secret` | the id is public (010 cnf convention). |

## 6. Success criteria

- **SC-L1** — `go test ./internal/auth/...` green including the LinkedIn contract test.
- **SC-L2** — `bash csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh` green (dry run
  default, idempotent, refuses wrong mode / wrong client id / placeholder cnf, no value
  in argv or output).
- **SC-L3** (per env, after the owner's file) — `curl -s https://<api host>/api/v1/auth/providers`
  lists `linkedin`; `curl -s -i https://<api host>/api/v1/auth/linkedin/start | grep -i ^location`
  shows `www.linkedin.com/oauth/v2/authorization` with the cnf client id and the
  registered redirect URI; a browser sign-in logs `auth.login_ok` with `p=linkedin`.

## 7. Open questions (owner) — each with the recommended default

- **OQ-L1 — one app for both envs, or one per env?** Recommended **(a) one app per
  env** (`csi-spl dev`, `csi-spl prd`), both on the same company page: a leaked dev
  secret does not reach prd, and dev can be deleted without touching prd users. (b) One
  app with both redirect URLs is allowed by LinkedIn and halves the console work; then
  put the same values in both files. Because `sub` is pairwise per app, (b) makes a
  person the same `sub` in dev and prd — harmless, the envs have separate databases.
- **OQ-L2 — app lifetime.** Recommended: **never replace an env's app** once users
  exist (pairwise `sub`, §1); rotate only its secret (runbook §5). If it must be
  replaced, the affected humans have to be re-linked by an operator.
- **OQ-L3 — company page.** LinkedIn requires the app to be associated with a LinkedIn
  company page that the owner administers, and the page admin verifies the app.
  Recommended: the product's own page (create one if none exists). Blocking until done.
- **OQ-L4 — id_token.** LinkedIn also returns an RS256 `id_token`. Recommended **(a)
  userinfo only**, like Google here: the identity comes server-to-server over TLS with
  the token just issued to our confidential client. (b) Also verify the `id_token`
  (issuer `https://www.linkedin.com/oauth`, `aud` = client id, JWKS) and its `nonce`,
  reusing 018's `idtoken.go` once it lands. Not needed for correctness; revisit if an
  auditor asks.
- **OQ-L5 — prd rollout timing.** Recommended: prd only after one owner sign-in on dev
  succeeds end to end (T051), and after CLE-3380's api-host callbacks are live in prd.

<!-- version: 0.1.0 · updated: 2026-09-19 -->
