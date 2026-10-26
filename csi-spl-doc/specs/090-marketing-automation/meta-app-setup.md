# 090 Meta developer app: setup and App Review runbook (Owner Step / Prerequisites)

**Feature ID**: `090-marketing-automation` · **Scope**: Meta Graph API (Facebook Pages & Instagram Professional)  
**Authority**: Owner runbook for Meta Developer Portal setup, Business Verification, and App Review submission.

Setting up a Meta developer application and submitting it for App Review are **OWNER-ONLY** steps requiring verified business identity and legal entity documentation. Autonomous agents must never attempt to create Meta apps or handle credentials.

---

## 1. What is Needed

| Item | Value / Requirement |
|---|---|
| **Meta Business Account** | Verified Business Portfolio in Meta Business Suite (`business.facebook.com`) |
| **Developer App** | App Name: **Spool Hub** (or workspace brand), App Type: **Business** |
| **Connected Facebook Page** | Company Facebook Page (e.g. Csitea / Workspace Company Page) |
| **Connected Instagram** | Instagram Professional (Business or Creator) account linked to the Facebook Page |
| **Privacy Policy URL** | `https://<BASE_DOMAIN>/privacy` |
| **Terms of Service URL** | `https://<BASE_DOMAIN>/terms` |
| **App Icon** | 1024x1024 PNG logo (`csi-spl-wui/src/public/icons/icon-512.png` scaled) |
| **Products Added** | 1. **Facebook Login for Business**<br>2. **Instagram Graph API** |
| **Permissions Required** | `pages_show_list`<br>`pages_read_engagement`<br>`pages_manage_posts`<br>`instagram_basic`<br>`instagram_content_publish` |
| **Token Lifetimes** | User Token: exchanged to Long-Lived (~60 days); Page Access Token: **Indefinite (no expiry)** |
| **Client ID / Secret** | Stored exclusively in Secret Manager; never in git or logs |

---

### 1.1 Authorized Redirect URLs

Register the following redirect URLs under **Facebook Login for Business** -> **Settings**:

| Environment | Redirect URL |
|---|---|
| Production | `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback` |
| Production (direct) | `https://<BASE_DOMAIN>/v1/marketing/facebook/callback` |
| Development | `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback` |
| Development (direct) | `https://dev.<BASE_DOMAIN>/v1/marketing/facebook/callback` |

Firebase Hosting rewrite in `render-wui-firebase-json.sh` forwards `/api/v1/marketing/facebook/callback` directly to Cloud Run hub ahead of the SPA routing fallback, matching the LinkedIn flow.

---

## 2. Where Client ID and Secret Live

Client credentials must never pass through chat, spool messages, terminal logs, or git commits.

| Store | Location | Written By |
|---|---|---|
| **Secret Manager, dev** | Project `csi-spl-dev`, secrets `csi-spl-hub-marketing-facebook-client-id` and `csi-spl-hub-marketing-facebook-client-secret`, version 1 | Dev project SA (`key-csi-spl-dev.json`) |
| **Secret Manager, prd** | Project `csi-spl-prd`, same two secrets, version 1 | Prd project SA (`key-csi-spl-prd.json`) |
| **Secret Manager, all** | Project `csi-spl-all`, same two secrets, version 1, labels `spec=090,app=spool-hub` | All project SA (`key-csi-spl-all.json`) |
| **Agent Box File** | `~<AGENT_USER>/.facebook/.csi/client_id` and `client_secret` (dirs 0700, files 0600) | Standard secrets layout |
| **Owner KeePassXC** | Entry `Facebook-app-Spool-Hub-csi-spl`: username = client id, password = client secret | `keepassxc-cli` with owner key file |

---

## 3. Step-by-Step Owner Setup Guide

### 3.1 Business Verification
1. Navigate to **Meta Business Suite** -> **Settings** -> **Security Center** (`https://business.facebook.com/settings/security`).
2. Click **Start Verification** under Business Verification.
3. Submit official company registration certificate, utility bill/bank statement matching the business name, and verify domain ownership via DNS TXT record.
4. Business verification approval typically takes 1–3 business days.

### 3.2 Create the Meta Developer App
1. Go to **Meta for Developers** (`https://developers.facebook.com/apps/`).
2. Click **Create App**.
3. Select **Other** -> Next -> Select **Business** as the app type -> Next.
4. Fill in:
   - **App Name**: `Spool Hub` (or workspace brand).
   - **App Contact Email**: Owner contact email.
   - **Business Account**: Select the verified Business Portfolio from §3.1.
5. Click **Create App**.

### 3.3 Add Products and Configure OAuth
1. In the App Dashboard, locate **Facebook Login for Business** and click **Set Up**.
2. Go to **Facebook Login for Business** -> **Settings**:
   - Enable **Client OAuth Login**: Yes.
   - Enable **Web OAuth Login**: Yes.
   - Add all four Authorized Redirect URIs listed in §1.1.
   - Save Changes.
3. In the App Dashboard, click **Add Product** and locate **Instagram Graph API** -> click **Set Up**.

### 3.4 Store Credentials in Secret Manager
Piped straight into Secret Manager without echoing or printing:

```bash
# Example for prd
printf '%s' "$FACEBOOK_CLIENT_SECRET" | gcloud secrets versions add csi-spl-hub-marketing-facebook-client-secret \
  --project=csi-spl-prd \
  --account=$GCP_ACCOUNT \
  --data-file=-
```

Verify storage integrity using SHA256 checksum comparison:
```bash
gcloud secrets versions access latest --secret=csi-spl-hub-marketing-facebook-client-secret --project=csi-spl-prd --account=$GCP_ACCOUNT | sha256sum
```

---

## 4. Meta App Review Submission Package

While in **Development Mode**, only users with developer, tester, or admin roles on the app can connect their Pages and publish. To allow any workspace administrator to connect their Pages, Meta requires formal **App Review**.

### 4.1 Permissions to Request in App Review
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

### 4.2 Video Screencast Requirements
Meta requires a 2–3 minute video demonstrating the end-to-end user experience. The screencast must show:
1. The user navigating to Spool Hub workspace settings.
2. Clicking "Connect Facebook & Instagram" and logging in through Meta's OAuth dialog.
3. Explicitly showing the permissions requested during login.
4. The user selecting the specific Page and connected Instagram account.
5. The creation of a draft post in Spool Hub.
6. The human user clicking "Approve & Publish".
7. Switching to Facebook and Instagram in a live browser to show the published post appearing on the Page and Profile feeds.

### 4.3 Test User Credentials for Meta Reviewers
- Create a Test User in **App Dashboard** -> **Roles** -> **Test Users**.
- Create a test Facebook Page owned by that test user.
- Provide the test user login credentials and detailed reproduction instructions in the App Review submission notes.

---

## 5. Token Renewal and Error Handling

1. **Long-Lived User Tokens**: Last ~60 days. The hub checks expiration daily. If within 7 days of expiry, the hub queues an in-app and email reminder to the delegating member with a 1-click renewal link.
2. **Page Access Tokens**: Derived from long-lived user tokens, Page Access Tokens do not expire unless revoked.
3. **Revocation / Permission Drop**:
   - If an API call fails with Meta OAuth error `OAuthException` (code `190`, subcode `458`, `460`, or `463`), the hub marks the channel status as `expired` in `marketing_channels` and logs an audit event.
   - The user is notified in WUI with a direct link to reconnect.

<!-- version: 0.5.0 · updated: 2026-10-26 · last-edit: 2026-10-26T12:48:00Z -->
