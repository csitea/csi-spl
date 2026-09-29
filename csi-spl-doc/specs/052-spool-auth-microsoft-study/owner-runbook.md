# Owner runbook: turn on "Sign in with Microsoft"

**Feature**: `052-spool-auth-microsoft-study` · **Who**: the owner. Registering
the Azure app is an owner action an agent cannot click through.
**Time**: about 20 minutes per env. **Result**: one Application (client) ID
(public, may be posted) and one client secret (never posted anywhere: §4).

**The code is already done and tested** (spec `../018-spool-auth-microsoft`,
`microsoft.go`). `microsoft` is **off** in every env until
`SPOOL_HUB_AUTH_PROVIDERS` lists it. The full click-by-click portal guide is
`../018-spool-auth-microsoft/azure-registration-runbook.md`; this page is the
short checklist with the recommended answers. Do **dev first, then prd**.

Recommended answers (study §7): `common` (work **and** personal accounts);
refuse work accounts whose domain is not verified; one app per env; a client
secret; publisher verification before advertising work sign-in on prd.

## 1. Before you start

You need an **Entra ID tenant** (you have one — the org runs Microsoft 365) and
an account in it with at least the **Application Developer** role. It is free
(study §1). Print the redirect URI the hub will send, from the repo root:

```bash
yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI' csi-spl-cnf/csi-spl/dev.env.json
```

## 2. Register the dev app

<https://entra.microsoft.com> → *App registrations* → *New registration*:

| field | value |
|---|---|
| Name | `spool-hub-dev` (users see it on the consent screen) |
| Supported account types | **Any organizational directory (multitenant) + personal Microsoft accounts** (= cnf `SPOOL_HUB_AUTH_MICROSOFT_TENANT: common`) |
| Redirect URI | platform **Web**, the URI printed in §1 |

*Register*. The **Overview** page shows the **Application (client) ID** — that is
`client_id`. Leave *Implicit grant* ID/access tokens **unchecked** (the hub uses
authorization-code + PKCE).

Then, on the same app:

1. *Certificates & secrets* → **New client secret**, expiry **12 months**. Copy
   the **Value** column at once (shown once). Do **not** copy the *Secret ID*.
2. *API permissions* → Microsoft Graph → **Delegated**: `openid`, `email`,
   `profile` (add any missing; `User.Read` may stay; no admin consent needed).
3. *Token configuration* → *Add optional claim* → type **ID** → tick `email`
   **and** `xms_edov`. Without `xms_edov`, every work account is refused
   (`email_unverified`); personal accounts still work.

## 3. Hand over the values

- **Application (client) ID**: public — reply with it in the topic.
- **client secret**: never in spool, chat, mail or git (the repo is public).
  Write it on the box, as the box user, mode 0600:

```bash
install -m 600 /dev/null "$HOME/.gcp/.csi/.spl/microsoft-client-dev.json"
```

```json
{"client_id":"<Application (client) ID>","client_secret":"<the secret Value>"}
```

Tell ORC "microsoft dev file is in place". From here the agent does §4 with
named actions only.

## 4. What the agent does next (named actions only)

1. Set the client id in `csi-spl-cnf/csi-spl/dev.env.yaml`
   (`SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID`).
2. Seed the secret (runs as the env's project service account; value on stdin
   only), from `csi-spl-orc`:

```bash
IDP=microsoft ENV=dev DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed
```

3. `SPOOL_HUB_AUTH_PROVIDERS: google,facebook,microsoft` in `dev.env.yaml`,
   render (`ENV=dev ./run -a do_tpl_gen` from `csi-spl-iac`), commit, deploy,
   then verify `curl -s https://dev.spool-hub.ai/api/v1/auth/providers` lists
   `microsoft` and a real personal + work sign-in logs
   `auth.login_ok provider=microsoft`.

## 5. prd

Repeat §2–§4 with name `spool-hub-prd`, the prd redirect URI, file
`microsoft-client-prd.json`, and `ENV=prd`.
`SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL` must stay `"false"` (the hub refuses
`true` in prd). Before advertising **work** sign-in on prd, do publisher
verification (free MPN ID + verified publisher domain,
`../018-spool-auth-microsoft/azure-registration-runbook.md` §5).

## 6. Rotation and troubleshooting

Both are in `../018-spool-auth-microsoft/azure-registration-runbook.md` §7–§8
(secret rotation every 12 months; `AADSTS50011`/`50194`/`7000215`,
`email_unverified`, "Need admin approval" causes and fixes).

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T19:24:35Z -->
