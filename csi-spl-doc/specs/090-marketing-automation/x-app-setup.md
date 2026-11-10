# 090 X developer app: the owner's steps (T040, SPL-5194)

The hub code for X ships dark: cnf `marketing.x.inject` is `"false"`, and while it is, every `/v1/marketing/x/*` route answers 503 `not_configured` and Tenant settings -> General says "X is not set up on this hub yet." in one line. These steps turn it on. Steps 1, 2 and 7 need the owner (an X login, a card); steps 3 to 6 are agents' work on the owner's go.

## 1. What the hub expects

| item | value |
|---|---|
| X app type | OAuth 2.0, **Web App, Automated App or Bot** (a confidential client: it has a client secret) |
| app permissions | **Read and write** |
| scopes the hub asks for | `tweet.read tweet.write users.read offline.access` (`marketing.XScopes`) |
| callback URI, prd | `https://<prd WUI host>/api/v1/marketing/x/callback` |
| callback URI, dev | `https://<dev WUI host>/api/v1/marketing/x/callback` |
| website URL | the prd WUI host |
| secret slot, client id | `csi-spl-hub-marketing-x-client-id` (the step 3 apply of 030 creates it empty) |
| secret slot, client secret | `csi-spl-hub-marketing-x-client-secret` (the step 3 apply of 030 creates it empty) |

The WUI host forwards `/api/v1/marketing/x/callback` to the hub ahead of the SPA fallback (`csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`; `wui-actions.tst.sh` fails if it is missing). X matches the callback URI exactly: register both hosts as they are served, with no trailing slash.

## 2. The steps

| # | step | who |
|---|---|---|
| 1 | On `developer.x.com`, sign in with the X account the app belongs to, open a project and an app in it. App settings -> **User authentication settings** -> Set up: permissions **Read and write**, type **Web App, Automated App or Bot**, both callback URIs of section 1, the website URL. Save. Copy the **OAuth 2.0 Client ID** and **Client Secret** (Keys and tokens tab); X shows the secret once. | owner |
| 2 | Buy **prepaid credits** in the developer console (Billing). X bills each post from them; with no credit X refuses the post and the publish reports the failure as on the other channels. | owner |
| 3 | Plan and apply step 030 on dev, then on prd (`make do-tf-plan`, `make do-provision`), with `marketing.x.inject` still `"false"`: it only creates the two empty secret slots of section 1 (wf 20 rolls the image and never applies 030). Each apply with the owner's go. Never create the slots by hand: the apply then fails on a secret that already exists. | agent, owner's go |
| 4 | Add the two values as version 1 of the two slots in `csi-spl-dev` and `csi-spl-prd`, each env with its own project SA key in a throwaway `CLOUDSDK_CONFIG`, the value on stdin only, checked by sha256, never printed (the recipe of [linkedin-app-setup.md](./linkedin-app-setup.md) section 3.3). | agent, owner's go |
| 5 | Pin both versions in `hub.secret_versions` of `csi-spl-cnf/csi-spl/<env>.env.yaml` and set `marketing.x.inject: "true"` per env, then `ENV=<env> ./run -a do_tpl_gen` and commit the rendered 030 tfvars. | agent |
| 6 | Plan and apply step 030 on dev, then on prd (`make do-tf-plan`, `make do-provision`) again, now with the pinned versions and inject on, each apply with the owner's go. | agent, owner's go |
| 7 | Connect: a member with Tenant settings opens Tenant settings -> General, marketing on, **Connect X**, allows the app on X, then **Publish** on one live post. | owner |

Cloud Run refuses a revision whose secret has no version, so step 5 comes only after step 4 for that env, and step 4 only after step 3.

## 3. The price (read 2026-11-10)

From `https://docs.x.com/x-api/getting-started/pricing`, pay-per-use with prepaid credits:

| request | price |
|---|---|
| a post (`POST /2/tweets`) with a URL in it | $0.200 |
| a post without a URL | $0.015 |

Every post the hub sends carries the blog post's link, so each X publish costs $0.200 at that price. The hub also reads the member (`GET /2/users/me`) once per connect. Re-read the page before buying credits: the price is X's to change.

## 4. How the hub uses the app

- **Connect** (`POST /v1/marketing/x/connect`): OAuth 2.0 authorization code with PKCE (S256) and a signed state; the callback swaps the code for an access token (2 h) and a refresh token, reads the member (`GET /2/users/me`), and stores the pair sealed with the marketing KMS key, like the LinkedIn and Meta tokens.
- **Refresh**: an access token within a minute of its end is refreshed before a publish, and the new pair (X may rotate the refresh token) is sealed back at once with a compare-and-swap. A refused token or refresh expires the account and mails the re-connect link; its posts wait, unsent.
- **Publish**: only on a member's press, from the same queue as the other channels (`POST /v1/marketing/posts/{id}/publish?channel=<id>`). Allowed for the member who connected the account or a holder of Tenant settings. The text is the title, the summary and the link, counted as X counts it (a link weighs 23) and shortened with "…" to fit 280; a text that cannot fit even so is refused with 422 and nothing is recorded. A 429 or 503 from X is retried by the dispatch sweep; any other failure (a 402 with no credit, too) fails at once, is never sent again, and is mailed to the holder.
- **Disconnect** (`DELETE /v1/marketing/channels/{id}`): drops the sealed tokens. To revoke the app on X as well: Settings and privacy -> Security and account access -> Apps and sessions -> Connected apps.

## 5. Rotating the client secret

Keys and tokens -> **Regenerate** the client secret, add it as a new version (step 4), pin it (step 5) and apply 030 on dev then prd, in one sitting: a refresh sends the client secret, so until the new one is served a refresh can be refused and expire the account (the member then connects again).
