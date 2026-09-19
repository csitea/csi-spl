# Owner runbook: register Sign In with LinkedIn (dev, then prd)

**Feature**: `019-spool-auth-linkedin` · **Who**: the owner (creating a LinkedIn app and
associating it with a company page are owner actions; an agent cannot click through the
LinkedIn console). **Time**: ~10 minutes per env, plus the page admin's verification.

What the agent needs back from you, and nothing else: the two files in §3.

## 1. Before you start

1.1 A LinkedIn **company page** you administer (spec OQ-L3). If none exists: LinkedIn →
*For Business* → *Create a Company Page*.

1.2 The exact callback URL per env. The hub API host serves the callback (the WUI calls
the hub cross-origin; lane CLE-3380):

| env | Authorized redirect URL |
|---|---|
| dev | `https://dev.api.spool-hub.ai/api/v1/auth/linkedin/callback` |
| prd | `https://api.spool-hub.ai/api/v1/auth/linkedin/callback` |

Byte for byte: https, no trailing slash. Once CLE-3380 has landed, this prints the
rendered value (must equal the table):

```bash
yq '.env.auth.social.env.SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI' csi-spl-cnf/csi-spl/dev.env.json
```

## 2. Create the app (repeat per env — spec OQ-L1 (a); one app for both is allowed, see OQ-L1 (b))

2.1 Open <https://www.linkedin.com/developers/apps> → **Create app**.

2.2 Fill in:
- *App name*: `Spool Hub (dev)` / `Spool Hub` for prd.
- *LinkedIn Page*: your company page (§1.1).
- *Privacy policy URL*: the WUI's privacy page if one exists.
- *App logo*: required by LinkedIn.
- Accept the legal agreement → **Create app**.

2.3 *Settings* tab → *Verify* next to the LinkedIn Page → send the link to the page
admin (you) and approve it. The OIDC product cannot be added until the app is verified.

2.4 *Products* tab → **Sign In with LinkedIn using OpenID Connect** → *Request access*.
It is self-serve and is granted at once. Do **not** add other products.

2.5 *Auth* tab:
- *OAuth 2.0 scopes* now shows `openid`, `profile`, `email`. Nothing to change.
- *Authorized redirect URLs for your app* → add the URL for this env from §1.2 → *Update*.
  (With one app for both envs, add both URLs.)
- Copy the **Client ID** and the **Primary Client Secret** (the eye icon).

Keep the app for the life of the env: LinkedIn user ids are per app, so a replacement
app turns every returning LinkedIn user into a new person (spec OQ-L2).

## 3. Hand the values to the agent — two files, nothing in chat

On the box, as the box user, one file per env, mode 0600. Paste the values into an
editor, not into a command line (so they stay out of shell history):

```bash
install -m 600 /dev/null ~/.gcp/.csi/.spl/linkedin-client-dev.json
```

```bash
${EDITOR:-vi} ~/.gcp/.csi/.spl/linkedin-client-dev.json
```

Content (exactly these two keys):

```json
{"client_id": "<Client ID>", "client_secret": "<Primary Client Secret>"}
```

Repeat with `linkedin-client-prd.json`. Then tell ORC: *"linkedin-client-dev.json is in
place"* (and later prd). Do not send the secret anywhere.

## 4. What the agent does next (for your information)

4.1 Commits the env's Client ID (public) to `csi-spl-cnf/csi-spl/<env>.env.yaml` as
`SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID`.

4.2 Dry run, then the real seed, as the env's project service account (never your account):

```bash
IDP=linkedin ENV=dev ./run -a do_spl_auth_idp_secret_seed
```

```bash
IDP=linkedin ENV=dev DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed
```

4.3 Adds `linkedin` to `SPOOL_HUB_AUTH_PROVIDERS` for the env, pushes; the CI deploy rolls the hub.

4.4 Verifies:

```bash
curl -s https://dev.api.spool-hub.ai/api/v1/auth/providers
```

```bash
curl -s -i https://dev.api.spool-hub.ai/api/v1/auth/linkedin/start | grep -i '^location'
```

Then asks you to sign in once with LinkedIn on the dev WUI. prd follows the same steps.

## 5. Rotating the secret later

LinkedIn *Auth* tab → *Generate a new Client Secret*. Update the `client_secret` in the
env's file, then run §4.2 again: it adds a version only because the value changed. The
hub picks it up on its next revision (the deploy path). The old secret stays valid in
LinkedIn until you delete it there — delete it after the new revision serves.

<!-- version: 0.1.0 · updated: 2026-09-19 -->
