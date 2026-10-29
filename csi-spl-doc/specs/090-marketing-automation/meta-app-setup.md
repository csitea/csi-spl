# 090 Meta app: add Page + Instagram publishing to the existing app (Owner Step / Prerequisites)

**Feature ID**: `090-marketing-automation` · **Scope**: Meta Graph API (Facebook Pages & Instagram Professional)  
**Authority**: Owner runbook for the Meta app's Page + Instagram use cases, Business Verification and App Review.

There is no second Meta app. Page + Instagram publishing reuses the app that
already serves "Sign in with Facebook" (spec 049): the cnf
`auth.social.env.SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID` of dev and prd, its secret
in the existing Secret Manager slot `csi-spl-hub-auth-facebook-client-secret`
(owner msg 0aad8975: "There is a Meta app. We probably should modify
the settings for that one"). The work is to ADD the Page + Instagram products
and permissions to that app. Nothing that sign-in uses today (its redirect
URI, its `email,public_profile` scopes) is changed or removed.

---

## 1. What the app has (read 2026-10-29, Graph API v26.0, app token)

Read by T030 (SPL-4164) with the app's own access token; the token never left
the box and is not in any log.

| Item | Read value |
|---|---|
| Name, platform | `spool-hub`, `WEB` |
| App domains | `<BASE_DOMAIN>` (covers `dev.<BASE_DOMAIN>`) |
| Privacy / terms URLs | `https://<BASE_DOMAIN>/privacy`, `https://<BASE_DOMAIN>/terms` |
| Deauthorize callback | `https://<BASE_DOMAIN>/api/v1/auth/facebook/deauthorize` |
| Roles | 1 administrator (the owner); no developers, testers or test users |
| Permissions (`/{app-id}/permissions`) | `email` live, `public_profile` live, `user_payment_tokens` live; no `pages_*` and no `instagram_*` |
| Products (`/{app-id}/products`) | empty list |
| Webhook subscriptions | none |
| Valid OAuth redirect URIs | NOT readable with an app token (`(#100) Tried accessing nonexisting field`) |
| Business portfolio, Business Verification, App Review state | NOT readable with an app token (`nonexisting field` / `A user access token is required`) |
| Linked Page and Instagram account | NOT readable without a user token of a Page admin (that is what T033's connect does) |

Sign-in today (dev, `GET <api host>/api/v1/auth/facebook/start`): 302 to
`https://www.facebook.com/v25.0/dialog/oauth` with the same client id,
`redirect_uri=https://dev.<BASE_DOMAIN>/api/v1/auth/facebook/callback` and
`scope=email,public_profile`.

## 2. What publishing needs, and the gap

| # | Step | Who |
|---|---|---|
| 1 | Add the use cases **"Manage everything on your Page"** (Facebook Login for Business) and **"Manage messaging & content on Instagram"** (Instagram API with Facebook Login) to the app, in the App Dashboard (use-case names as Meta words them; the API cannot list them, so check the wording there). If the dashboard does not offer them, first connect the app to the business portfolio (App settings -> Basic -> Business portfolio). | (b) owner, Meta UI: no Graph API adds a product or use case |
| 2 | Under those use cases, add the permissions `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish` (Standard Access). | (b) owner, Meta UI |
| 3 | Add the T033 callbacks to **Valid OAuth Redirect URIs** (Facebook Login for Business -> Settings), next to the sign-in ones, which stay: `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback` and `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback`. | (b) owner, Meta UI: the list is neither readable nor writable with the app token, so an API write could not be proven add-only |
| 4 | Link the company Facebook Page to an Instagram Professional (Business or Creator) account, if not linked yet. | (b) owner, Meta Business Suite / Instagram app |
| 5 | Business Verification of the portfolio (Security Center). Needed only for Advanced Access (step 6). | (b) owner, Meta UI |
| 6 | App Review for Advanced Access to the five permissions (section 4). Needed only to publish to Pages of people who hold no role on the app; with Standard Access the app's admins (the owner) can connect their own Page. | (b) owner, Meta UI |
| 7 | Hub cnf: `marketing.facebook` reuses the app id and the secret slot; 030 injects `SPOOL_HUB_MARKETING_FACEBOOK_*` once `inject` is `"true"` (T030, done). The WUI host forwards `/api/v1/marketing/facebook/callback` to the hub. | (a) agents, done |
| 8 | Flip `marketing.facebook.inject` to `"true"` per env when T033 reads the values, after steps 1-3 (step 030 apply, owner go). | (a) agents, with T033 |

No agent changed the Meta app on 2026-10-29: every additive change it needs
(steps 1-3) is UI-only, and nothing was deleted.

### 2.1 Redirect URLs (step 3)

| Environment | Redirect URL |
|---|---|
| Production | `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback` |
| Development | `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback` |

The Firebase Hosting rewrite in `render-wui-firebase-json.sh` forwards
`/api/v1/marketing/facebook/callback` to the Cloud Run hub ahead of the SPA
fallback, as for the LinkedIn flow. Meta matches redirect URIs exactly
(Strict Mode), so the sign-in URI does not cover this path.

---

## 3. Where the app id and secret live

Nothing new is stored: the app id is public cnf, the secret is the sign-in
slot.

| Store | Location | Written by |
|---|---|---|
| **cnf** | `auth.social.env.SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID` (dev, prd); `marketing.facebook` in `all.env.yaml` names the slot | git |
| **Secret Manager** | Project `csi-spl-<env>`, secret `csi-spl-hub-auth-facebook-client-secret`, the version pinned in `hub.secret_versions` | `do_spl_auth_idp_secret_seed` (spec 049) |

030 hands the hub the same secret twice, as `SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET`
(sign-in) and, while `marketing.facebook.inject` is `"true"`, as
`SPOOL_HUB_MARKETING_FACEBOOK_CLIENT_SECRET`, with `SPOOL_HUB_MARKETING_FACEBOOK_APP_ID`,
`_API_VERSION` and `_SCOPES`. Test: `csi-spl-iac/src/bash/tests/hub-marketing-facebook-030.tst.sh`.

---

## 4. Meta App Review submission package (step 6)

While the five permissions have Standard Access only, only users with a role
on the app (admin, developer, tester) can connect their Pages and publish. To
let any workspace administrator connect a Page, Meta requires App Review for
Advanced Access, which requires Business Verification (step 5).

### 4.1 Permissions to request
Under **App Review** -> **Permissions and Features**, request Advanced Access for:

1. **`pages_show_list`**:
   - *Justification*: "Allows Spool Hub users to view a list of their managed Facebook Pages so they can choose which business Page to connect to their workspace for automated content updates."
2. **`pages_read_engagement`**:
   - *Justification*: "Required by Meta Graph API to read Page feed metadata and confirm successful publication of scheduled status updates and blog releases."
3. **`pages_manage_posts`**:
   - *Justification*: "Allows authorized workspace users to publish approved product announcements, release notes, and camp updates directly to their business Page feed."
4. **`instagram_basic`**:
   - *Justification*: "Allows Spool Hub to discover the Instagram Professional account linked to the user's selected Facebook Page."
5. **`instagram_content_publish`**:
   - *Justification*: "Enables Spool Hub to create media containers and publish approved photo announcements and carousels to the user's Instagram Professional feed."

### 4.2 Video screencast requirements
Meta requires a 2–3 minute video demonstrating the end-to-end user experience. The screencast must show:
1. The user navigating to Spool Hub workspace settings.
2. Clicking "Connect Facebook & Instagram" and logging in through Meta's OAuth dialog.
3. Explicitly showing the permissions requested during login.
4. The user selecting the specific Page and connected Instagram account.
5. The creation of a draft post in Spool Hub.
6. The human user clicking "Approve & Publish".
7. Switching to Facebook and Instagram in a live browser to show the published post appearing on the Page and Profile feeds.

### 4.3 Test user credentials for Meta reviewers
- Create a Test User in **App Dashboard** -> **Roles** -> **Test Users**.
- Create a test Facebook Page owned by that test user.
- Provide the test user login credentials and detailed reproduction instructions in the App Review submission notes.

> [!CAUTION]
> Test user credentials are entered directly into Meta's web portal during App Review submission. Never commit test user passwords to git, never log them, and never post them in spool messages.

---

## 5. Token renewal and error handling

1. **Long-Lived User Tokens**: Last ~60 days. The hub checks expiration daily. If within 7 days of expiry, the hub queues an in-app and email reminder to the delegating member with a 1-click renewal link.
2. **Page Access Tokens**: Derived from long-lived user tokens, Page Access Tokens do not expire unless revoked.
3. **Revocation / Permission Drop**:
   - If an API call fails with Meta OAuth error `OAuthException` (code `190`, subcode `458`, `460`, `463`, or `467`), the hub marks the channel status as `expired` in `marketing_channels` and logs an audit event.
   - The user is notified in WUI with a direct link to reconnect.

<!-- version: 0.6.0 · updated: 2026-10-29 · last-edit: 2026-10-29T03:34:54Z -->
