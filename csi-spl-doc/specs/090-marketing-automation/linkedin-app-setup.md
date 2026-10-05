# 090 LinkedIn developer app: how it was set up (T002 owner step / T006 prerequisite)

Done 2026-10-05, topic `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa` (blocker `1acec2d8`: "create the LinkedIn developer app, add its client id and secret as secret versions, say done"). This page says what exists, where every value lives, and how to redo or rotate it. The prompt that would have produced all of it in one go is [`prompt-linkedin-app.md`](./prompt-linkedin-app.md).

## 1. What exists

| item | value |
|---|---|
| LinkedIn app | **Spool Hub**, app id `264972293`, type Standalone app, created by the owner's LinkedIn member account |
| LinkedIn Page | the company Page of Csitea (fixed for good: LinkedIn cannot change it after the app is saved) |
| privacy policy URL | `https://spool-hub.ai/privacy` |
| logo | `csi-spl-wui/src/public/icons/icon-512.png` |
| products | **Share on LinkedIn** (Default Tier, `w_member_social`) and **Sign In with LinkedIn using OpenID Connect** (Standard Tier, `openid profile email`); both self-serve, granted at once |
| access token lifetime | 2 months (5184000 s), no refresh token: T006 re-consent reminder |
| client id / secret | never in git; see section 2 |

### 1.1 Authorized redirect URLs

All four are registered. The callback route is built by T006; whichever path form it ends up serving, LinkedIn already accepts it. Remove the unused pair once T006 is live.

| env | URL |
|---|---|
| prd | `https://spool-hub.ai/api/v1/marketing/linkedin/callback` |
| dev | `https://dev.spool-hub.ai/api/v1/marketing/linkedin/callback` |
| prd | `https://spool-hub.ai/v1/marketing/linkedin/callback` |
| dev | `https://dev.spool-hub.ai/v1/marketing/linkedin/callback` |

The `/api/v1/...` form matches the existing sign-in callback (`SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI` = `https://<host>/api/v1/auth/linkedin/callback`, the WUI host proxying `/api` to the hub). The `/v1/...` form is the one `tasks.md` T002 names.

## 2. Where the client id and secret live

One app serves every env, so the same two values are stored in each place below. The values never passed through a chat, a spool post, a log or a commit: they were read from the LinkedIn page and piped straight into each store, then checked by comparing sha256 hashes only.

| store | where | written by |
|---|---|---|
| Secret Manager, dev | project `csi-spl-dev`, secrets `csi-spl-hub-marketing-linkedin-client-id` and `csi-spl-hub-marketing-linkedin-client-secret`, version 1 | the dev env SA (`key-csi-spl-dev.json`) |
| Secret Manager, prd | project `csi-spl-prd`, same two secrets, version 1 | the prd env SA |
| Secret Manager, all | project `csi-spl-all`, same two secrets, version 1, labels `spec=090,app=spool-hub` | the all SA (`key-csi-spl-all.json`) |
| agent box file | `~<AGENT_USER>/.linked-in/.csi/client_id` and `client_secret` (dirs 0700, files 0600) | the `~/.<runtime>/.<org>/` secrets layout |
| owner's KeePassXC DB | entry `LinkedIn-app-Spool-Hub-csi-spl`: username = client id, password = client secret, URL = the app's Auth page, notes point here | the owner, with the master password (section 3.4) |

The dev and prd slots were created empty by step 030 (T002, no version resource, so no value is in terraform state). The `csi-spl-all` secrets are **not** owned by any terraform step: on 2026-10-05 `secretmanager.googleapis.com` was enabled there and the two secrets were created with `gcloud` as the all SA. Nothing at runtime reads them; they are the estate-level copy the owner asked for.

## 3. How to redo it

### 3.1 Open a browser the owner can log in to

The `chrome` / `firefox` MCP servers are headless, so a person cannot sign in through them. Start a visible Chrome on the owner's desktop with a debug port, as the owner's OS user. The owner logs in to LinkedIn with their own password and code; the agent never sees either.

```bash
DISPLAY=:0 XAUTHORITY=$(ls -t /run/user/$(id -u)/.mutter-Xwaylandauth.* | head -1) XDG_RUNTIME_DIR=/run/user/$(id -u) nohup google-chrome --user-data-dir=/var/tmp/linkedin-090/chrome-profile --remote-debugging-address=127.0.0.1 --remote-debugging-port=9333 --no-first-run --new-window https://www.linkedin.com/developers/apps >/dev/null 2>&1 &
```

The agent then drives that window with playwright-core `chromium.connectOverCDP('http://127.0.0.1:9333')`.

### 3.2 Create the app (LinkedIn Developers)

1. **Create app**: name, LinkedIn Page, privacy policy URL, logo, tick the API Terms of Use. The Page and the terms are owner decisions; ask before saving.
2. **Products** tab: **Request access** on "Share on LinkedIn" and on "Sign In with LinkedIn using OpenID Connect", each with its own terms tick.
3. **Auth** tab: the pencil next to "Authorized redirect URLs", **Add redirect URL** per URL, **Update**. Reload and read the list back.

### 3.3 Store the values in Secret Manager

Read the client id (text input) and the Primary Client Secret (password input) from the Auth page and pipe them, never print them, into a loop over the envs. Each env uses only its own SA key, in a throwaway `CLOUDSDK_CONFIG`, with `--account` on every call.

```bash
printf '%s' "$VALUE" | gcloud secrets versions add csi-spl-hub-marketing-linkedin-client-secret --project=csi-spl-<env> --account=<env SA email> --data-file=-
```

Verify without printing: `gcloud secrets versions access latest ... | sha256sum` must equal the input's `sha256sum`.

### 3.4 Store the values in KeePassXC

`keepassxc-cli` 2.7 needs the database master password, so the **owner** runs this in their own terminal. The script asks only for the master password (hidden), reads the two values from the 0600 files and checks the stored password by hash:

```bash
keepassxc-cli add -q -u "$CLIENT_ID" --url https://www.linkedin.com/developers/apps/264972293/auth --notes "<pointer to this page>" -p <OWNER_KDBX> LinkedIn-app-Spool-Hub-csi-spl
```

stdin carries two lines: the master password, then the client secret. If the KeePassXC GUI has the same database open, it reloads the file on change; save any pending GUI edits first.

## 4. Rotating the client secret

1. Auth tab, **Generate a new Client Secret**. LinkedIn keeps the old one valid for a grace period.
2. Add a new version to all six secrets (section 3.3), update the 0600 file and the KeePassXC entry.
3. Redeploy the hub (030) on dev and prd so Cloud Run picks up `latest`, then remove the old secret in LinkedIn.

## 5. What is left after this page

1. Flip cnf `marketing.linkedin.inject` to `"true"` on dev and prd and apply 030 (Cloud Run refuses a revision whose secret has no version; both now have one).
2. Owner decision, still open: `marketing.workspaces` (the workspaces marketing is ON for). It is `[]`, so marketing is off everywhere.
