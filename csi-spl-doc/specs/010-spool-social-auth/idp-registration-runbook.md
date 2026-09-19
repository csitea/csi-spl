# Runbook: register the sign-in apps (owner) — Google, Meta, Microsoft, LinkedIn, xAI

**Feature**: `010-spool-social-auth` · tasks T030–T034 · **Who**: the owner. An agent cannot
click through these consoles, and creating an app is an owner action.
**Code state**: all five providers are implemented and tested against the fake IdP
(`go test ./internal/auth/...`); auth is **off** in every env until
`SPOOL_HUB_AUTH_PROVIDERS` lists a provider.

Order: **dev first, then prd**, one provider at a time. A provider may only be listed once
(1) its app exists, (2) its client id is in cnf and (3) its secret has a version in Secret
Manager — otherwise the hub refuses to boot (FR-007) or Cloud Run refuses the revision (a
referenced secret with no version).

## 1. What goes where

### 1.1 Callback (redirect) URIs — register these byte for byte

The WUI origin rewrites `/api/v1/auth/**` to the hub (FR-010), so the callback host is the
WUI host. The values live in cnf; print them rather than copy from here:

```bash
yq '.env.auth.social.env | with_entries(select(.key | test("REDIRECT_URI")))' csi-spl-cnf/csi-spl/dev.env.json
```

```bash
yq '.env.auth.social.env | with_entries(select(.key | test("REDIRECT_URI")))' csi-spl-cnf/csi-spl/prd.env.json
```

Shape: `https://<env host>/api/v1/auth/<provider>/callback`, with `<provider>` one of
`google`, `facebook`, `microsoft`, `linkedin`, `xai`.

### 1.2 Per provider: scopes, the cnf keys, the secret slot

| provider | console | scopes (cnf default) | public id → cnf key (`<env>.env.yaml` under `env.auth.social.env`) | secret → Secret Manager slot |
|---|---|---|---|---|
| google | Google Cloud console → APIs & Services | `openid email profile` | `SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID` | `csi-spl-hub-auth-google-client-secret` |
| facebook | Meta for Developers | `email,public_profile` | `SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID` (the App ID) | `csi-spl-hub-auth-facebook-client-secret` (the App Secret) |
| microsoft | Microsoft Entra admin center → App registrations | `openid email profile` | `SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID` (Application (client) ID) | `csi-spl-hub-auth-microsoft-client-secret` (a client secret *Value*) |
| linkedin | LinkedIn Developers | `openid profile email` | `SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID` | `csi-spl-hub-auth-linkedin-client-secret` |
| xai | xAI (see §2.5) | `openid profile email` | `SPOOL_HUB_AUTH_XAI_CLIENT_ID` | `csi-spl-hub-auth-xai-client-secret` |
| (all) | — | — | — | `csi-spl-hub-auth-session-key` (48 random bytes, §3.1) |

Client ids are public (they appear in the browser redirect) and belong in cnf. Secrets
never go into git, terraform state or a log. The slots are created empty by iac step 030
(`06-auth-secret-slots.tf`); you add their **versions**.

## 2. Register the apps

### 2.1 Google (T030)

1. Cloud console, project `csi-spl-<env>` → *APIs & Services* → *OAuth consent screen*:
   External, app name, support email, scopes `openid`, `email`, `profile`.
2. *Credentials* → *Create credentials* → *OAuth client ID* → *Web application*.
3. *Authorised redirect URIs*: the env's `SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI` (§1.1).
4. Keep the client id for §3.2 and the client secret for §3.1.
5. Publish the consent screen (*In production*) before prd.

### 2.2 Meta / Facebook (T031, T043)

One **Consumer** app serves dev and prd.

1. Create the app, add the *Facebook Login* product / use case, permissions `email` and
   `public_profile`.
2. *Facebook Login → Settings*: Client OAuth login **on**, Web OAuth login **on**, Enforce
   HTTPS **on**, Strict mode **on**; *Valid OAuth Redirect URIs* = the dev **and** prd
   `SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI`.
3. The two callbacks Meta requires before it publishes the app (implemented, FR-013):
   - *Deauthorize callback URL*: `https://<prd host>/api/v1/auth/facebook/deauthorize`
   - *Data deletion request URL* (choose "Data deletion callback URL"):
     `https://<prd host>/api/v1/auth/facebook/data-deletion`

   Both answer only a request carrying Meta's `signed_request` signed with the App
   Secret; anything else is `400`. They answer `404` until `facebook` is listed in that env.
4. *Settings → Basic*: App domains, Privacy Policy URL, category, icon.
5. App Review for `email` and `public_profile` (standard access), then **Publish** (Live).
   Donor checklist: csi-rel `specs/052-social-authentication-google-facebook/facebook-live-runbook.md` §3.

### 2.3 Microsoft (T040)

1. Entra admin center → *App registrations* → *New registration*.
2. **Supported account types** — this is spec OQ-I1:
   - (a) **Recommended, the default cnf**: *Personal Microsoft accounts only*
     (`SPOOL_HUB_AUTH_MICROSOFT_TENANT: consumers`). Microsoft verifies these addresses.
   - (b) Work/school accounts too (`common`, `organizations` or a tenant id). Their `email`
     claim is set by each tenant's admin and is **not verified**; the hub refuses to boot
     with such a tenant unless `SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL: "true"`. Choose this
     only as a deliberate owner decision, and tell ORC.
3. *Redirect URI*, platform **Web**: the env's `SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI`.
   Add both envs' URIs to the one registration, or register one app per env.
4. *Certificates & secrets* → *New client secret*; copy the **Value** (not the Secret ID)
   for §3.1. Note its expiry: the secret needs rotating before then.
5. *API permissions*: Microsoft Graph delegated `openid`, `email`, `profile` (default
   `User.Read` may stay).

### 2.4 LinkedIn (T041)

1. LinkedIn Developers → *Create app* (needs a LinkedIn company page).
2. *Products* → request **Sign In with LinkedIn using OpenID Connect**.
3. *Auth* → *Authorized redirect URLs for your app*: the dev and prd
   `SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI`.
4. Copy the Client ID (§3.2) and the Primary Client Secret (§3.1). The OIDC product grants
   `openid profile email`; the hub requires `email_verified=true` from userinfo.

### 2.5 xAI (T042) — spec OQ-I2

xAI publishes an OIDC issuer (`https://auth.x.ai/.well-known/openid-configuration`; its
endpoints are already in cnf as `SPOOL_HUB_AUTH_XAI_{AUTH,TOKEN,USERINFO}_URL`). No
self-service console for registering a third-party web client was found (2026-09-19).
If xAI issues you a confidential client (client id + secret, redirect URIs = the
`SPOOL_HUB_AUTH_XAI_REDIRECT_URI` values, scopes `openid profile email`), continue with §3;
otherwise leave `xai` unlisted.

## 3. Load secrets and flip cnf (per env)

`<env>` is `dev` or `prd`; the project is `csi-spl-<env>`. Terraform step 030 must be
applied first so the empty slots exist.

### 3.1 Secret versions (never into git)

Session key, once per env, 48 random bytes:

```bash
head -c 48 /dev/urandom | base64 | tr -d '\n' | gcloud secrets versions add csi-spl-hub-auth-session-key --data-file=- --project=csi-spl-dev --account="$GCP_ACCOUNT"
```

A provider's client secret: paste it on stdin, then Ctrl-D (replace `google` with the
provider's slug from §1.2):

```bash
gcloud secrets versions add csi-spl-hub-auth-google-client-secret --data-file=- --project=csi-spl-dev --account="$GCP_ACCOUNT"
```

Confirm the version exists:

```bash
gcloud secrets versions list csi-spl-hub-auth-google-client-secret --project=csi-spl-dev --account="$GCP_ACCOUNT"
```

### 3.2 cnf

In `csi-spl-cnf/csi-spl/<env>.env.yaml` under `env.auth.social.env`: set the provider's
`SPOOL_HUB_AUTH_<P>_CLIENT_ID`, and add its slug to `SPOOL_HUB_AUTH_PROVIDERS`
(e.g. `google,facebook`). Re-render, from `csi-spl-iac`:

```bash
ENV=dev ./run -a do_tpl_gen
```

The 030 tfvars now inject the session key and exactly the listed providers' secrets:

```bash
grep '^secret_environment_variables' csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars
```

No placeholder may remain on a listed provider (must print nothing for its keys):

```bash
yq '.env.auth.social.env | to_entries | .[] | select(.value | test("PLACEHOLDER")) | .key' csi-spl-cnf/csi-spl/dev.env.json
```

Commit, push, then 030 plan + apply / deploy by the DEPLOY path (spec 008).

## 4. Verify (T034, SC-003)

```bash
curl -s https://dev.spool-hub.ai/api/v1/auth/providers
```

Expect the listed slugs. Then the start redirect must carry the real client id and the
registered redirect URI:

```bash
curl -s -i https://dev.spool-hub.ai/api/v1/auth/google/start | grep -i '^location'
```

Sign in with a browser; the hub log shows `auth.login_ok` (or `auth.callback_fail` with
the reason). For Facebook, Meta's dashboard can send a test deauthorize callback; the log
shows `auth.facebook_unlinked`. If the hub does not start after a flip, its log names the
first `SPOOL_HUB_AUTH_*` still unset or `PLACEHOLDER-*`.

Repeat §3–§4 for prd.

<!-- version: 0.1.0 · updated: 2026-09-19 -->
