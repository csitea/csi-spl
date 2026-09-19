# Quickstart: spool social sign-in (010) — local run and registration day

Commands assume the repo root as the working directory and Go on `PATH`.
Nothing here needs a real Google or Facebook app until §3.

## 1. Tests (no credentials)

```bash
cd csi-spl-api/src/go/spool-hub-api && go test -race -count=1 ./internal/auth/...
```

Covers: fail-fast config (every required var unset and `PLACEHOLDER-*`),
the state/CSRF checks, the code → token exchange and userinfo / Graph `/me`
against the fake IdP, session issue, logout, tampering, open redirects.

## 2. Local run of the whole flow (fake Google + Facebook)

### 2.1 Walk the flow once

```bash
cd csi-spl-api/src/go/spool-hub-api && go run ./internal/auth/cmd/auth-demo
```

Expected: for each provider, `start` → `302` to the fake IdP → `302` to
`/api/v1/auth/<p>/callback` → `302` to the stub WUI `/c/general`, then
`GET /api/v1/auth/session -> 200 {…}`; last line
`OK - both providers signed in against the fake IdP`.

### 2.2 Keep it up and drive it with curl

```bash
cd csi-spl-api/src/go/spool-hub-api && go run ./internal/auth/cmd/auth-demo -serve
```

It prints the hub URL. In a second shell, with `HUB` set to it:

```bash
curl -s -c /tmp/spool-auth.jar -b /tmp/spool-auth.jar -L -o /dev/null -w '%{url_effective}\n' "$HUB/api/v1/auth/google/start?redirect=/c/general"
```

```bash
curl -s -b /tmp/spool-auth.jar "$HUB/api/v1/auth/session"
```

### 2.3 With the real WUI (lde)

The WUI's dev server proxies `/api/v1/auth/**` to the hub
(`NUXT_DEV_AUTH_PROXY`, `csi-spl-wui/nuxt.config.ts`), so the callback and the
cookie live on the WUI origin. Start the demo hub on a fixed port, pointing the
landing and the IdP callbacks at the WUI:

```bash
cd csi-spl-api/src/go/spool-hub-api && go run ./internal/auth/cmd/auth-demo -addr 127.0.0.1:58181 -app-url http://localhost:3000 -public-url http://localhost:3000
```

Then, in `csi-spl-wui`:

```bash
NUXT_DEV_AUTH_PROXY=http://127.0.0.1:58181 pnpm dev
```

Open `http://localhost:3000/login`: both buttons sign in against the fake IdP
and land back on the WUI, signed in.

### 2.4 Fail-fast check

Listing a provider while its values are still the cnf placeholders must stop
the process with the variable's name:

```bash
cd csi-spl-api/src/go/spool-hub-api && go test -run TestConfigFailFast -v ./internal/auth/ | tail -3
```

## 3. Registration day (owner) — flip from placeholders to real apps

All five providers, the Meta callbacks and the secret slots are covered, step by step, in
`idp-registration-runbook.md`. The section below is the original Google + Facebook
walk-through.

Order per env: **dev first, then prd**. Nothing below is done by an agent
without the owner's go (repo CLAUDE.md: nothing mutates GCP without the owner).

### 3.1 Prerequisites (other lanes, `tasks.md`)

- T020 + T021 applied: the three Secret Manager slots exist and 030 renders
  `env.auth.social` into the hub's env.
- T010: the hub mounts `internal/auth`.
- T016: the WUI Hosting rewrite `/api/v1/auth/**` → hub is deployed, so the
  callback host in cnf answers (OQ-A2 decides the host).

### 3.2 Register the apps

1. **Google** — Cloud console, the env's project → *APIs & Services* → OAuth
   consent screen (External, scopes `openid email profile`) → *Credentials* →
   *Create OAuth client ID* → Web application. Authorised redirect URI =
   exactly the value of:

```bash
yq '.env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI' csi-spl-cnf/csi-spl/dev.env.json
```

2. **Facebook** — Meta for Developers → create a **Consumer** app, add the
   *Facebook Login* use case, permissions `email` + `public_profile`. *Valid
   OAuth Redirect URIs* = the dev **and** prd values of
   `SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI`; Client + Web OAuth login on,
   Strict mode on. Basic settings: app domains, privacy policy URL,
   data-deletion instructions URL (T043 tracks the callback). App Review for
   `email`, `public_profile`, then **Publish** (csi-rel
   `facebook-live-runbook.md` §3 is the donor checklist).

### 3.3 Load the secrets (never into git)

Session key, 48 random bytes:

```bash
head -c 48 /dev/urandom | base64 | tr -d '\n' | gcloud secrets versions add csi-spl-hub-auth-session-key --data-file=- --project=csi-spl-dev --account="$GCP_ACCOUNT"
```

Google client secret (paste it on stdin, then Ctrl-D):

```bash
gcloud secrets versions add csi-spl-hub-auth-google-client-secret --data-file=- --project=csi-spl-dev --account="$GCP_ACCOUNT"
```

Facebook app secret (paste it on stdin, then Ctrl-D):

```bash
gcloud secrets versions add csi-spl-hub-auth-facebook-client-secret --data-file=- --project=csi-spl-dev --account="$GCP_ACCOUNT"
```

### 3.4 Flip the cnf placeholders

In `csi-spl-cnf/csi-spl/dev.env.yaml` under `env.auth.social.env`, set
`SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID`, `SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID` to the
registered ids and `SPOOL_HUB_AUTH_PROVIDERS: google,facebook`; re-render:

```bash
ENV=dev ./run -a do_tpl_gen
```

Confirm no placeholder is left in a listed provider (must print nothing):

```bash
yq '.env.auth.social.env | to_entries | .[] | select(.value | test("PLACEHOLDER")) | .key' csi-spl-cnf/csi-spl/dev.env.json
```

Commit, push, deploy (008 pipeline / the apply lane).

### 3.5 Verify on the env

```bash
curl -s https://dev.spool-hub.ai/api/v1/auth/providers
```

Expect `{"providers":["google","facebook"]}`. Then:

```bash
curl -s -i https://dev.spool-hub.ai/api/v1/auth/google/start | grep -i '^location'
```

Expect a `302` to `accounts.google.com` whose `redirect_uri` is the registered
value and `client_id` the real id. Finally sign in with a browser, and read
the hub log for `auth.login_ok` (a `auth.callback_fail` line names the
reason: `invalid_state`, `exchange_failed`, `email_unverified`, …).

If the hub does not start after the flip, its log names the first
`SPOOL_HUB_AUTH_*` still unset or `PLACEHOLDER-*` — that is FR-007 working.

Repeat §3.3–§3.5 for prd (`csi-spl-prd`, apex host).

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:58:00Z -->
