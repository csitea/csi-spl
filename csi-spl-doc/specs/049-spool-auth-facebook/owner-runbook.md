# Owner runbook: register the Facebook (Meta) app

**Feature**: `049-spool-auth-facebook` · **Who**: the owner. Creating the Meta app and
going Live are owner actions in a console an agent cannot click through.
**Time**: about 20 minutes. **Result**: one App ID (public, may be posted) and one App
Secret (never posted anywhere: §5).

Recommended (spec OQ-F1): **one app for dev and prd**.

## 1. Before you start

Meta checks these URLs when you switch the app to Live. They must answer 200 (T020 ships
them):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://spool-hub.ai/privacy
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://spool-hub.ai/terms
```

## 2. Create the app

1. https://developers.facebook.com/apps → **Create app**.
2. Use case: **Authenticate and request data from users with Facebook Login**. If the
   console asks for an app type, choose **Consumer** (not Business).
3. App name: `spool-hub`. App contact email: the product's support address. Business
   portfolio: none needed (see §6).
4. **Create app** (Meta asks for your Facebook password).

## 3. Facebook Login settings

*Use cases → Authenticate and request data from users with Facebook Login → Customize*:

1. **Permissions**: `public_profile` (always there) and add **`email`**. They start at
   standard access ("Ready for testing"), which serves only people with a role on the app.
2. **Settings** (Facebook Login → Settings):
   - Client OAuth login: **Yes** · Web OAuth login: **Yes** · Enforce HTTPS: **Yes** ·
     Use Strict Mode for redirect URIs: **Yes** · Login with the JavaScript SDK: No.
   - **Valid OAuth Redirect URIs**, both lines, byte for byte:
     - `https://dev.spool-hub.ai/api/v1/auth/facebook/callback`
     - `https://spool-hub.ai/api/v1/auth/facebook/callback`
   - **Deauthorize callback URL**: `https://spool-hub.ai/api/v1/auth/facebook/deauthorize`

## 4. App settings → Basic

| field | value |
|---|---|
| App icon | the spool-hub emblem, 1024 × 1024 px |
| App domains | `spool-hub.ai` (covers `dev.spool-hub.ai`) |
| Privacy Policy URL | `https://spool-hub.ai/privacy` |
| Terms of Service URL | `https://spool-hub.ai/terms` |
| User data deletion | **Data deletion callback URL**: `https://spool-hub.ai/api/v1/auth/facebook/data-deletion` |
| Category | Business and pages (or Productivity) |
| + Add platform → Website | Site URL `https://spool-hub.ai/` |

**Save changes.** Here you also find the **App ID** (top) and the **App Secret** (Show,
asks your password).

## 5. Hand over the values

- **App ID**: public. Reply with it in the topic, or write it into the file below.
- **App Secret**: never in spool, chat, mail or git (the repo is public). Either:
  - **(a) a file for the agent** (the agent seeds Secret Manager with a named action and
    never prints it): on the box, as the box user, create both files with the same
    content, mode `0600`:

    ```text
    $HOME/.gcp/.csi/.spl/facebook-client-dev.json
    $HOME/.gcp/.csi/.spl/facebook-client-prd.json
    ```

    ```json
    {"client_id": "<App ID>", "client_secret": "<App Secret>"}
    ```

    ```bash
    chmod 600 $HOME/.gcp/.csi/.spl/facebook-client-dev.json $HOME/.gcp/.csi/.spl/facebook-client-prd.json
    ```

  - **(b) Secret Manager yourself**, once per project (the value comes from stdin, so it
    stays out of your shell history):

    ```bash
    gcloud secrets versions add csi-spl-hub-auth-facebook-client-secret --project=csi-spl-dev --data-file=-
    ```

    ```bash
    gcloud secrets versions add csi-spl-hub-auth-facebook-client-secret --project=csi-spl-prd --data-file=-
    ```

    Paste the secret, press Enter, then Ctrl-D.

## 6. Go Live

1. While the app is in Development mode only people with a role on it can sign in. For
   the dev test: *App roles → Roles → Add people* (or *Test users*), and sign in with that
   account.
2. **App Review → Permissions and features**: click **Get advanced access** on
   `public_profile` and on `email`. A **Live** app with only standard access shows every
   visitor "Feature Unavailable - Facebook Login is currently unavailable for this app,
   since we are updating additional details" (measured 2026-09-29 on dev and prd; Meta's
   own forum answer, developers.facebook.com/community/threads/518949739253025/).
3. Dashboard → **Publish** (App Mode: **Live**). Meta checks the privacy URL, the data
   deletion URL and the icon.
4. **Business verification**: if Meta requires it to grant advanced access, it is the
   owner's step (the business portfolio's documents); nothing on the spool side changes.

## 7. What the agent does next (named actions only)

1. The App ID goes into `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml`
   (`SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID`).
2. With (a): `IDP=facebook ENV=dev DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed`
   (csi-spl-orc), then prd.
3. `SPOOL_HUB_AUTH_PROVIDERS: google,facebook` in dev, render, 030 plan + apply, a real
   sign-in with a test Facebook account; then prd.

## 8. Rotating the secret

*App settings → Basic → App Secret → Reset*, then repeat §5 and step 2 of §7 for both
envs. The previous secret stops working at once: do it right before the seed.

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T05:00:00Z -->
