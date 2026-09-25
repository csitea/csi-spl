# Runbook: register "Sign in with Microsoft" (owner) — dev first, then prd

**Feature**: `018-spool-auth-microsoft` · tasks T040–T045 · **Who**: the owner. An agent
cannot click through the Azure portal, and creating an app is an owner action.
**Code state**: implemented and tested against the fake IdP (`go test -run TestMicrosoft ./internal/auth/`).
`microsoft` is **off** in every env until `SPOOL_HUB_AUTH_PROVIDERS` lists it.

**What I need from you, per env:** a single file, and nothing else.

| env | file (mode 0600) | contents |
|---|---|---|
| dev | `$HOME/.gcp/.csi/.spl/microsoft-client-dev.json` | `{"client_id":"<Application (client) ID>","client_secret":"<client secret Value>"}` |
| prd | `$HOME/.gcp/.csi/.spl/microsoft-client-prd.json` | the same, for the prd app |

Send the answers to spec OQ-M1..M5 only if they differ from the defaults this
runbook uses. The defaults are: all Microsoft accounts (`common`), work accounts
only with a verified domain, one app per env, a client secret, and publisher
verification before prd work sign-in.

## 1. Before you start

1. You need an **Entra ID tenant** to own the app registrations. Any Azure or
   Microsoft 365 organisation account works; a free Azure account creates one.
   Personal Microsoft accounts can no longer register apps outside a directory.
2. Your account needs a role that can register apps. *Application Developer*
   is enough, and it is the default for members unless the tenant turned it off.
3. Print the redirect URI the hub will send for the env (from the repo root):

```bash
yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI' csi-spl-cnf/csi-spl/dev.env.json
```

## 2. Register the dev app (T040)

### 2.1 New registration

Go to <https://entra.microsoft.com>, then *Identity* → *Applications* → *App registrations* → *New registration*:

| field | value |
|---|---|
| Name | `spool-hub-dev` (users see it on the consent screen) |
| Supported account types | **Accounts in any organizational directory (Any Microsoft Entra ID tenant - Multitenant) and personal Microsoft accounts (e.g. Skype, Xbox)** (OQ-M1 (a), cnf `SPOOL_HUB_AUTH_MICROSOFT_TENANT: common`) |
| Redirect URI | platform **Web**, `https://dev.spool-hub.ai/api/v1/auth/microsoft/callback` |

Press *Register*. The *Overview* page shows **Application (client) ID**. That value is the `client_id` in your file.

If you choose another OQ-M1 answer, the account type and cnf must match:
*personal only* ↔ `consumers`, *any organizational directory only* ↔ `organizations`,
*this organizational directory only* ↔ the **Directory (tenant) ID** GUID.

### 2.2 Authentication — the second redirect URI

*Authentication* → *Web* → *Add URI*: `https://dev.api.spool-hub.ai/api/v1/auth/microsoft/callback`
(optional; the hub sends only the apex URI, spec §3). Leave these alone:
- *Access tokens* and *ID tokens* under *Implicit grant and hybrid flows*: **unchecked**
  (the hub uses the authorization-code flow with PKCE)
- *Front-channel logout URL*: empty
- *Allow public client flows*: **No**

Press *Save*.

### 2.3 Client secret

*Certificates & secrets* → *Client secrets* → *New client secret*:
- Description: `spool-hub-dev-2026-09`
- Expires: **12 months** (recommended; the maximum is 24)

Copy the **Value** column right away. It is shown only once, and it is the `client_secret` in your file.
Do **not** copy the *Secret ID* (a GUID): the seed action refuses it. Put the expiry date in your calendar (§7).

### 2.4 API permissions

*API permissions*: Microsoft Graph, **Delegated**: `openid`, `email`, `profile`.
Add any of them that are missing (*Add a permission* → *Microsoft Graph* → *Delegated*).
The default `User.Read` can stay. No admin consent is needed for these.

### 2.5 Token configuration — the verified-domain claim (OQ-M2)

*Token configuration* → *Add optional claim* → Token type **ID**, then tick:
- `email`
- `xms_edov`

Press *Add*. When asked *"Turn on the Microsoft Graph email permission"*, tick it and press *Add*.

If `xms_edov` is not in the list, open *Manifest* and make `optionalClaims.idToken` read:

```json
"idToken": [ { "name": "email", "essential": false }, { "name": "xms_edov", "essential": false } ]
```

Without `xms_edov`, **every work/school account is refused** (`email_unverified`).
Personal accounts still work.

### 2.6 Branding (optional on dev, needed before §5)

*Branding & properties*: Home page URL `https://dev.spool-hub.ai`, plus the Terms of service and Privacy statement URLs if the site has them.

### 2.7 Write the file

On the box, as the box user. The editor writes the file without echoing the secret to a terminal log:

```bash
install -m 600 /dev/null "$HOME/.gcp/.csi/.spl/microsoft-client-dev.json"
```

```bash
${EDITOR:-vi} "$HOME/.gcp/.csi/.spl/microsoft-client-dev.json"
```

Contents (one line is fine):

```json
{"client_id":"00000000-0000-0000-0000-000000000000","client_secret":"<the Value from 2.3>"}
```

Check that the mode is `-rw-------`:

```bash
ls -l "$HOME/.gcp/.csi/.spl/microsoft-client-dev.json"
```

Tell ORC "microsoft dev file is in place". From here on, agents can do §3–§4.

## 3. Seed the secret into Secret Manager (agent or owner, T042)

This runs as the env's **project service account**, never the owner account.
The action is the shared one from spec 019 (CLE-3387). It checks that the file
is 0600, that `client_id` equals cnf, and that the secret is not a Secret ID.
It adds a version only when the value changed, and the value travels on stdin
only. Dry run first, from `csi-spl-orc`:

```bash
IDP=microsoft ENV=dev ./run -a do_spl_auth_idp_secret_seed
```

```bash
IDP=microsoft ENV=dev DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed
```

The cnf client id comes first (the action refuses a placeholder). In
`csi-spl-cnf/csi-spl/dev.env.yaml` under `env.auth.social.env`, set
`SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID: <Application (client) ID>`.

## 4. Turn it on for dev and verify (T042–T043)

1. `dev.env.yaml`: `SPOOL_HUB_AUTH_PROVIDERS: google,microsoft`. Then render, from `csi-spl-iac`:

```bash
ENV=dev ./run -a do_tpl_gen
```

2. Commit, push, and have the deploy lane apply 030. The hub image must already contain spec 018's code (`/version` sha ⊇ the 018 commits).
3. Verify:

```bash
curl -s https://dev.spool-hub.ai/api/v1/auth/providers
```

This must list `microsoft`.

```bash
curl -s -i https://dev.spool-hub.ai/api/v1/auth/microsoft/start | grep -i '^location'
```

The Location must be `https://login.microsoftonline.com/common/oauth2/v2.0/authorize?…` with your
client id, the cnf `redirect_uri`, `code_challenge_method=S256`, and **no** `code_verifier`.

4. Sign in in a browser with a personal account, then with a work account. The
   hub log shows `auth.login_ok provider=microsoft`, or
   `auth.callback_fail` with the reason (§8).

## 5. Publisher verification (OQ-M5, before advertising work sign-in on prd)

Work users in tenants that only allow consent to *verified publishers* see
"Need admin approval" until this is done. Personal accounts are not affected.

1. You need a Microsoft AI Cloud Partner Program (formerly MPN) ID for the organisation (<https://partner.microsoft.com>). It is free.
2. The app's *Branding & properties* → *Publisher domain* must be a domain you
   verified in the tenant (e.g. `spool-hub.ai` via a DNS TXT record).
3. *Branding & properties* → *Publisher verification* → *Add MPN ID*.

## 6. prd (T041, T044–T045)

Repeat §2 with name `spool-hub-prd` and redirect URIs
`https://spool-hub.ai/api/v1/auth/microsoft/callback` and
`https://api.spool-hub.ai/api/v1/auth/microsoft/callback`. Save the file as
`$HOME/.gcp/.csi/.spl/microsoft-client-prd.json`, then do §3–§4 with `ENV=prd` and
`prd.env.yaml`. `SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL` must stay `"false"`:
the hub refuses `true` in prd.

## 7. Rotation (every 12 months, or at once if a secret leaks)

1. §2.3: add a **new** client secret. Keep the old one until step 4.
2. Put the new Value into the env's file.
3. Re-run §3 with `DRY_RUN=0`. It adds a version because the hash changed.
   Redeploy or restart the hub so it reads the `latest` version.
4. Once a sign-in works, delete the old secret in the portal.

## 8. Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `AADSTS50011` redirect URI mismatch | the cnf URI is not on the app | §2.1/§2.2: add the exact printed URI |
| `AADSTS50194` / `AADSTS9002331` | account types and cnf `TENANT` disagree | make them match (§2.1) |
| `AADSTS7000215` invalid client secret | the Secret ID was pasted, or the secret expired | §2.3 + §7 |
| `auth_error=email_unverified` for a work account | no `xms_edov`, or the tenant has not verified that domain | §2.5; otherwise it is intended (OQ-M2) |
| `auth_error=exchange_failed` | the id_token check failed (log `detail`: aud/iss/tid/nonce/kid) | check the client id in cnf equals the app's |
| "Need admin approval" | publisher not verified (OQ-M5) | §5, or that tenant's admin consents |
| the hub does not start after the flip | a `SPOOL_HUB_AUTH_MICROSOFT_*` value is unset or `PLACEHOLDER-*` | the boot log names the variable |

<!-- version: 0.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:40:00Z -->
