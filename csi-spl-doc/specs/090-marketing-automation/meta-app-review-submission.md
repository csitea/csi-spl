# 090 Meta App Review Submission Package & Live Verification Guide (T038)

**Feature ID**: `090-marketing-automation` · **Task**: `T038` (`SPL-4805`, Epic `SPL-2400`)  
**Scope**: Meta Graph API `v26.0` App Review submission package for Facebook Pages & Instagram Professional Content Publishing  
**Companion docs**: [`meta-app-setup.md`](./meta-app-setup.md) (Meta App Dashboard setup) · [`spec.md`](./spec.md) (§16, §20, §21) · [`tasks.md`](./tasks.md)

This document provides the complete Meta App Review submission package for the `spool-hub` Meta app:
1. What code is deployed (T030..T035, T037), what stays dark until `marketing.facebook.inject` is `"true"`, and what is not built.
2. Copy-paste permission justification text for all five requested scopes (`pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish`).
3. Test user, test Facebook Page, and linked Instagram Professional account setup instructions, reviewer reproduction steps, and the credential security rule.
4. A 2-minute scene-by-scene video screencast script matching the live Web UI.
5. An owner checklist for recording the screencast and clicking **Submit for Review** in the Meta Developer Portal.

---

## 1. What Is Deployed, What Stays Dark, and What Is Not Built

The screencast and reviewer steps describe the deployed code. They can be recorded only after owner checklist step 2 has turned the flow on for the target env.

### 1.1 Code on `origin/master` and deployed (the Meta flow is dark until owner checklist step 2)

| Task | Status | What Is Deployed |
|---|---|---|
| **T030** (`SPL-4164`, `2089ad421`) | **Live** (code & cnf landed; `inject: "false"` until owner step) | Reuses the existing sign-in Meta app (`spool-hub`, `WEB`, `auth.social.env.SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID` and Secret Manager slot `csi-spl-hub-auth-facebook-client-secret`). Graph API version pinned to `v26.0`. Firebase Hosting rewrite forwards `/api/v1/marketing/facebook/callback` to the Cloud Run hub. In `csi-spl-cnf/csi-spl/all.env.yaml`, `marketing.facebook.inject` is held at `"false"` until the owner completes the Meta App Dashboard prerequisites (`meta-app-setup.md` §2 steps 1–3) and approves the Terraform step `030` apply. |
| **T031** (`SPL-3873`, `4798d4e0c`) | **Live** (`0236_marketing_meta.sql`) | PostgreSQL schema supports `facebook_page` and `instagram_business` in `marketing_channels`, `awaiting_approval` status hold in `marketing_posts`, channel `metadata` (`jsonb`), post `media_assets` (`jsonb`), and audit events `post_held`, `post_approved`, and `post_handed_over` under `FORCE ROW LEVEL SECURITY`. |
| **T032** (`SPL-3875`, `47a3790dd`) | **Live** (`internal/marketing/meta_*.go`) | Meta Graph API `v26.0` client: exchanges the authorization code for a long-lived user token (`fb_exchange_token`), lists managed Pages and linked Instagram accounts (`GET /v26.0/me/accounts`), publishes Page feed/photo posts (`POST /v26.0/{page-id}/feed`), runs the two-step Instagram container workflow (`POST /v26.0/{ig-user-id}/media` -> poll `GET /v26.0/{container-id}?fields=status_code` -> `POST /v26.0/{ig-user-id}/media_publish`), and reads permalinks. Sends tokens only in the `Authorization` header with `appsecret_proof`. |
| **T033** (`SPL-4254`, `74c3625d1`) | **Live** (`internal/hub/marketing_meta_channels.go`) | Hub OAuth routes: `GET` and `POST /v1/marketing/facebook/connect`, `GET /v1/marketing/facebook/callback` (and `/api/v1/marketing/facebook/callback`), and `GET /v1/marketing/facebook/pages`. Verifies the 15-minute HMAC-signed `state`, seals each Page Access Token with Cloud KMS (`T005`), never stores the user token, and sets `auto_publish = false` on every connected `facebook_page` and `instagram_business` channel. |
| **T034** (`SPL-4424`, `328ab0094`; `SPL-4564`, `457fc9196`) | **Live** (`internal/hub/marketing_meta_dispatch.go`) | Human approval and single-flight dispatcher: `POST /v1/marketing/posts/{id}/publish?channel=<channel_id>` records the live blog post `{id}` as `awaiting_approval` (`post_held`), transitions it to `scheduled` (`post_approved`) when approved by the connecting member (`delegated_by`) or a workspace member holding `tenant.settings`, and claims and dispatches it under the channel row lock. Enforces the 1 post / 24h rolling channel cap, Instagram's 100 posts / 24h limit, and Instagram's JPEG-only image check (`422 instagram_needs_jpeg`). |
| **T035** (`SPL-4494`, `299209e48`; `SPL-4520`, `ec10e4333`; `SPL-4496`, `e8e02f87e`) | **Deployed** (shows 'not set up on this hub yet' until inject is true) (`MarketingAccounts.vue`, `MarketingPublish.vue`) | In **Workspace settings -> General** under the **Marketing** switch, the **Facebook and Instagram** section lists connected Facebook Pages and linked Instagram Professional accounts with status badges, shows a permission banner when Page `tasks` lack `MANAGE` or `CREATE_CONTENT`, opens **Connect Facebook**, disconnects via `DELETE /v1/marketing/channels/{channel_id}` (with a confirmation dialog and Meta revocation instructions), and expands `Publish to <name>` (`GET /v1/marketing/posts?channel=<channel_id>`) showing unshared live blog posts with 48x48 image previews, character counters (`63 206` for Facebook Page, `2 200` for Instagram, grouped by a narrow no-break space), the JPEG check, and the **Publish** button. |
| **T037** (`SPL-3872`, `8a87f0dac`) | **Live on `prd`** (`marketing_share_links.go`, `BlogShareRow.vue`) | Hub endpoint `GET /v1/marketing/posts/{id}/share-links` and WUI utility `marketing-share-links.mjs` render RFC 3986 share links on the public blog post share bar (`BlogShareRow.vue`): Facebook sharer (`https://www.facebook.com/sharer/sharer.php?u=<url>`, deprecated `quote=` removed), Instagram (copies `<title>\n\n<url>` to the clipboard: `instagramCaption` appends a summary only when one is passed, and the share bar passes none, and opens `https://www.instagram.com/`), Viber (`viber://forward?text=` clamped to `<= 200` characters with headline and link intact), and WhatsApp (`https://wa.me/?text=`). |

### 1.2 Not Built (Do Not Claim or Record in App Review)

| Task | Status | What Is Not Built |
|---|---|---|
| **T007 / T008 / T010 / T012** | **Not built** | The standalone free-form draft queue (`queue.go`), `PATCH /v1/marketing/posts/{id}` in-app text editor, `/v1/marketing/events` audit log read endpoint, and `MarketingPostQueue.vue` / `MarketingPostEvents.vue` are **not built**. In the live system, publishable posts are the workspace's live blog posts (`<app>/blog-md/index.json`, `source_type = 'blog'`) listed per channel in `MarketingPublish.vue`. |
| **T036** (`MarketingDraftHandover.vue`, `manual-publish`) | **Not built** | The customer manual draft handover card (`MarketingDraftHandover.vue`), multi-photo 1–10 checkbox selector, ZIP photo pack download, and `POST /v1/marketing/posts/{id}/manual-publish` endpoint are **not built**. |
| **Page Selection Modal During OAuth Callback** | **Not built** | `T033` connects every Facebook Page (and linked Instagram Professional account) that the user selects inside Meta's own OAuth dialog. To remove an unwanted Page in Spool Hub after connecting, the user clicks **Disconnect** next to that Page in **Workspace settings -> General** (`T035`). |

---

## 2. Permission Submission Text (Copy-Paste for Meta App Review)

In the Meta App Dashboard under **App Review -> Permissions and Features** (or **Use Cases -> Customize**), request **Advanced Access** for the five permissions below. Copy and paste the justification text under each heading into the corresponding Meta portal field.

### 2.1 `pages_show_list`

- **Graph API Endpoint**: `GET https://graph.facebook.com/v26.0/me/accounts?fields=id,name,access_token,tasks,instagram_business_account{id,username,name}`
- **Spool Hub Route & UI**: `GET /api/v1/marketing/facebook/callback`, `GET /v1/marketing/facebook/pages`, rendered in **Workspace settings -> General -> Facebook and Instagram** (`MarketingAccounts.vue`).
- **Justification**:
  > Spool Hub uses `pages_show_list` during the OAuth callback (`GET /v26.0/me/accounts`) to retrieve the list of Facebook Pages that the authenticating workspace administrator manages, along with the user's assigned Page tasks (`MANAGE`, `CREATE_CONTENT`) and any linked Instagram Professional account. Spool Hub displays the connected Facebook Pages in the workspace's **Workspace settings -> General -> Facebook and Instagram** panel so the administrator can verify which business Page is connected, see whether their Page role permits publishing, or disconnect a Page at any time.

### 2.2 `pages_read_engagement`

- **Graph API Endpoint**: `GET https://graph.facebook.com/v26.0/{post-id}?fields=permalink_url` and `GET https://graph.facebook.com/v26.0/me/accounts`
- **Spool Hub Route & UI**: `POST /v1/marketing/posts/{id}/publish?channel=<channel_id>` (`internal/hub/marketing_meta_dispatch.go`).
- **Justification**:
  > Spool Hub uses `pages_read_engagement` required alongside `pages_show_list` and `pages_manage_posts` to read Facebook Page metadata and to query the published post's canonical `permalink_url` (`GET /v26.0/{post-id}?fields=permalink_url`) immediately after an authorized user publishes a blog release to their Facebook Page. This confirms delivery and records the public permalink in the workspace's append-only publishing audit log.

### 2.3 `pages_manage_posts`

- **Graph API Endpoint**: `POST https://graph.facebook.com/v26.0/{page-id}/feed` (and `POST https://graph.facebook.com/v26.0/{page-id}/photos`)
- **Spool Hub Route & UI**: `POST /v1/marketing/posts/{id}/publish?channel=<channel_id>`, triggered by clicking **Publish** in `MarketingPublish.vue`.
- **Justification**:
  > Spool Hub uses `pages_manage_posts` to publish blog articles and release announcements to a workspace's connected Facebook Page feed (`POST /v26.0/{page-id}/feed` with the post summary and canonical link). Every connected Facebook Page channel is configured with `auto_publish = false`: Spool Hub never posts automatically in the background without human consent. A post is published only when the workspace administrator who connected the Page (or a workspace administrator holding `tenant.settings`) explicitly clicks the **Publish** button next to a blog post in **Workspace settings -> General -> Facebook and Instagram**.

### 2.4 `instagram_basic`

- **Graph API Endpoint**: `GET https://graph.facebook.com/v26.0/me/accounts?fields=id,name,access_token,tasks,instagram_business_account{id,username,name}` and `GET https://graph.facebook.com/v26.0/{media-id}?fields=permalink`
- **Spool Hub Route & UI**: `GET /api/v1/marketing/facebook/callback`, `GET /v1/marketing/facebook/pages`, rendered in `MarketingAccounts.vue`.
- **Justification**:
  > Spool Hub uses `instagram_basic` to discover the Instagram Professional (Business or Creator) account linked to the user's Facebook Page (`instagram_business_account{id,username,name}` on `GET /v26.0/me/accounts`) when the user connects Facebook in **Workspace settings -> General -> Facebook and Instagram**, and to read the published media's `permalink` (`GET /v26.0/{media-id}?fields=permalink`) after a post is published. The linked Instagram account's username and connection status are displayed directly beneath its parent Facebook Page in workspace settings.

### 2.5 `instagram_content_publish`

- **Graph API Endpoint**: `POST https://graph.facebook.com/v26.0/{ig-user-id}/media`, `GET https://graph.facebook.com/v26.0/{container-id}?fields=status_code`, and `POST https://graph.facebook.com/v26.0/{ig-user-id}/media_publish`
- **Spool Hub Route & UI**: `POST /v1/marketing/posts/{id}/publish?channel=<channel_id>`, triggered by clicking **Publish** in `MarketingPublish.vue`.
- **Justification**:
  > Spool Hub uses `instagram_content_publish` to publish approved workspace blog announcements with a JPEG image and caption to the workspace's connected Instagram Professional account using Meta's two-step Container Publishing API (`POST /v26.0/{ig-user-id}/media`, polling `GET /v26.0/{container-id}?fields=status_code` until `FINISHED`, and calling `POST /v26.0/{ig-user-id}/media_publish`). Automated background posting is off (`auto_publish = false`); a post is sent to Instagram only when an authorized workspace administrator reviews the image preview and character counter (`<= 2 200` characters) in **Workspace settings -> General -> Facebook and Instagram** and clicks **Publish**.

---

## 3. Test User, Test Facebook Page & Instagram Setup Instructions

Meta App Review requires working test credentials and step-by-step reproduction instructions so Meta's human reviewer can log into Spool Hub, complete the Facebook Login for Business OAuth flow against a test Page and linked Instagram Professional account, and publish a test post.

> [!CAUTION]
> **Security Rule — Never Commit or Log Credentials**: Test user emails, passwords, session cookies, and access tokens must **never** be committed to git, written to logs, stored in Terraform state, or posted in Spool messages or issues. Use placeholders (`<TEST_USER_EMAIL>`, `<TEST_USER_PASSWORD>`) in all repository files and enter the real test credentials **only** inside Meta's encrypted App Review web form at submission time.

### 3.1 Setting Up the Test User, Test Facebook Page & Linked Instagram Account

Before submitting for App Review, the owner prepares the reviewer accounts:

1. **Meta Reviewer Account / Test User**:
   - In the Meta App Dashboard (`developers.facebook.com/apps/`), open **App Roles -> Roles** (or **App Roles -> Test Users**).
   - Assign a dedicated test Facebook account a role on the `spool-hub` app (or create a Meta Test User) that will be provided to Meta reviewers in the App Review portal.
2. **Test Facebook Page**:
   - Logged in as that test Facebook account, create or assign a dedicated test Facebook Page (for example, `Spool Hub Review Test Page`).
   - Verify that the test account has full Page control (`MANAGE` and `CREATE_CONTENT` tasks in `/me/accounts`). If those tasks are missing, Spool Hub's `MarketingAccounts.vue` intentionally hides the **Publish** button and shows the warning banner: *"You cannot post on this Page: your role on it gives no right to create content."*
3. **Linked Test Instagram Professional Account**:
   - Create a dedicated test Instagram account and switch it to a **Professional** (**Business** or **Creator**) account in Instagram settings.
   - Link the test Instagram Professional account to the Test Facebook Page (in Facebook Page **Settings -> Linked accounts -> Instagram**).
4. **Spool Hub Test Account & JPEG Blog Post**:
   - Ensure the target environment (`https://dev.<BASE_DOMAIN>` or `https://<BASE_DOMAIN>`) has `marketing.facebook.inject: "true"` applied via Terraform step `030` (`SPOOL_HUB_MARKETING_FACEBOOK_APP_ID`, `_CLIENT_SECRET`, `_API_VERSION`, `_SCOPES`, and `SPOOL_HUB_MARKETING_KMS_KEY` active on the Cloud Run hub).
   - In an allow-listed workspace (`marketing.workspaces`), grant the reviewer's Spool Hub test user (`<TEST_USER_EMAIL>`) a role holding `tenant.settings` (Workspace Admin or Owner) and switch the **Marketing** toggle **On** in **Workspace settings -> General**.
   - Ensure at least one live blog post on that environment has a `.jpg` or `.jpeg` image asset (`<app>/blog/img/<file>.jpg`) and has not yet been published to the test channels, so the reviewer can test both Facebook Page publishing and Instagram JPEG container publishing.

### 3.2 Reviewer Reproduction Steps (Copy-Paste into Meta App Review Notes)

Copy the block below into the **Testing Instructions / Notes for Reviewer** field in the Meta App Review portal, replacing `<BASE_DOMAIN>`, `<WORKSPACE_ID>`, `<TEST_USER_EMAIL>`, `<TEST_USER_PASSWORD>`, `<FB_TEST_USER_EMAIL>`, and `<FB_TEST_USER_PASSWORD>` only inside Meta's web form:

1. **Sign in to Spool Hub**: Open `https://<BASE_DOMAIN>` in a desktop browser and sign in with the provided Spool Hub reviewer account (`Email: <TEST_USER_EMAIL>`, `Password: <TEST_USER_PASSWORD>`). Select workspace `<WORKSPACE_ID>`.
2. **Open Workspace Marketing Settings**: Click the settings icon on the left sidebar rail (on a phone, or with the channels panel collapsed: avatar menu at the top right -> **Workspace settings**), and stay on the **General** tab. Scroll down to the **Marketing** section (switched **On**) and locate the **Facebook and Instagram** subsection (`Connect the Facebook Pages you manage; the Instagram professional account linked to a Page comes with it. Nothing is posted without your approval.`).
3. **Connect Facebook Page & Linked Instagram Account (`pages_show_list`, `instagram_basic`)**: Click the **Connect Facebook** button. When redirected to Meta's OAuth dialog (`https://www.facebook.com/v26.0/dialog/oauth`), sign in with the provided test Facebook account (`<FB_TEST_USER_EMAIL>` / `<FB_TEST_USER_PASSWORD>`), select the test Facebook Page and its linked test Instagram Professional account, and grant the five requested permissions (`pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish`). After Meta redirects back to `/api/v1/marketing/facebook/callback`, click the link on the confirmation page (`Facebook connected`) to return to **Workspace settings -> General**.
4. **Review Connected Channels & Unshared Blog Posts**: In the **Facebook and Instagram** list, verify that both the test Facebook Page (`Facebook Page · Connected`) and its linked Instagram account (`Instagram · Connected`) appear with **Publish** and **Disconnect** buttons. Click **Publish** next to the Facebook Page row to expand the `Publish to <Page Name>` list of live blog posts, each showing its thumbnail preview, title, and character counter (`{count} / 63 206 characters`).
5. **Approve & Publish to Facebook Page (`pages_manage_posts`, `pages_read_engagement`)**: Click the **Publish** button next to a blog post in the Facebook Page queue. Verify that the status message reads `Published.` and that the post appears on the test Facebook Page feed on Facebook.
6. **Approve & Publish to Instagram (`instagram_content_publish`, `instagram_basic`)**: Click **Publish** next to the linked `Instagram · Connected` row to open `Publish to <Instagram Username>` (showing `{count} / 2 200 characters` and the JPEG image preview). Click **Publish** on a blog post with a JPEG image. Verify that the status message reads `Published.` and that the photo and caption appear on the test Instagram Professional profile feed.
7. **Disconnect & Clean Up (Optional)**: Click **Disconnect** next to the Facebook Page, confirm in the `Disconnect <Page Name>?` dialog, and verify that both the Facebook Page and its linked Instagram account are removed from the workspace and their stored token is deleted.

---

## 4. Video Screencast Script (2-Minute End-to-End Walkthrough)

Meta requires a 2-to-3 minute screencast (`1080p` MP4 or MOV, English interface, browser address bar visible) demonstrating every requested permission end to end in the real UI. Record the following five scenes in one continuous take (`~2:00` total):

### Scene 1 (`0:00–0:20`) — Workspace Settings & Marketing Switch
- **Visual**: Browser is signed in to Spool Hub (`https://dev.<BASE_DOMAIN>` or `https://<BASE_DOMAIN>`) with the UI language set to **English**.
- **Action**:
  1. Open **Workspace settings -> General**.
  2. Point the cursor at the **Marketing** toggle (switched **On**).
  3. Scroll to the **Facebook and Instagram** section showing:
     - Heading: `Facebook and Instagram`
     - Hint: `Connect the Facebook Pages you manage; the Instagram professional account linked to a Page comes with it. Nothing is posted without your approval.`
     - Empty state: `No Facebook Page is connected yet.`
     - Button: **Connect Facebook**

### Scene 2 (`0:20–0:50`) — Meta OAuth Consent Dialog & Callback (`pages_show_list`, `instagram_basic`)
- **Visual**: Navigating from Spool Hub to `https://www.facebook.com/v26.0/dialog/oauth` and back to `/api/v1/marketing/facebook/callback`.
- **Action**:
  1. Click **Connect Facebook** (`POST /v1/marketing/facebook/connect`).
  2. In the Meta OAuth dialog, pause for 3 seconds on each step so the reviewer can read:
     - The app name (`spool-hub`).
     - The selected Facebook Page and linked Instagram Professional account.
     - The five requested permissions (`pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish`).
  3. Click **Continue / Save** in Meta's dialog.
  4. Show the hub callback page (`Facebook connected — Connected 1 Facebook Page(s) and 1 Instagram account(s) for workspace ... Nothing is published on them without your approval.`) and click back to Spool Hub **Workspace settings -> General**.

### Scene 3 (`0:50–1:15`) — Connected Accounts & Human Review Queue (`T035`)
- **Visual**: **Workspace settings -> General -> Facebook and Instagram** (`MarketingAccounts.vue` and `MarketingPublish.vue`).
- **Action**:
  1. Show the connected Facebook Page row (`<Page Name> · Facebook Page · Connected`) and, indented beneath it, the linked Instagram account row (`<IG Username> · Instagram · Connected`), each with **Publish** and **Disconnect** buttons.
  2. Click **Publish** on the Facebook Page row to expand `Publish to <Page Name>` (`Live blog posts not shared on this account yet. Each one goes out only when you press Publish.`).
  3. Point out the blog post's 48x48 thumbnail preview, post title, and character counter (`<count> / 63 206 characters`).

### Scene 4 (`1:15–1:45`) — Human Approval & Publishing (`pages_manage_posts`, `pages_read_engagement`, `instagram_content_publish`)
- **Visual**: Publishing one post to the Facebook Page and one JPEG-backed post to Instagram.
- **Action**:
  1. In `Publish to <Page Name>`, click **Publish** on the target blog post (`POST /v1/marketing/posts/{id}/publish?channel=<page_channel_id>`).
  2. Show the confirmation line `Published.` and the post disappearing from that Page's unshared list.
  3. Click **Publish** on the linked `Instagram · Connected` row to expand `Publish to <IG Username>`.
  4. Point out the Instagram character counter (`<count> / 2 200 characters`) and JPEG thumbnail preview, then click **Publish** (`POST /v1/marketing/posts/{id}/publish?channel=<ig_channel_id>`).
  5. Wait ~2–5 seconds while the hub creates the Instagram media container, polls `status_code`, and publishes the container; show the confirmation line `Published.`.

### Scene 5 (`1:45–2:00`) — Live Verification on Facebook & Instagram + Disconnect Dialog
- **Visual**: Browser tabs open to the Facebook Page and the Instagram profile, followed by Spool Hub's Disconnect confirmation dialog.
- **Action**:
  1. Switch to the Facebook Page tab, reload, and show the newly published link post on the Page feed (`pages_manage_posts`, `pages_read_engagement`).
  2. Switch to the Instagram Professional profile tab, reload, and show the newly published photo and caption with the blog URL (`instagram_content_publish`, `instagram_basic`).
  3. Switch back to Spool Hub **Workspace settings -> General**, click **Disconnect** next to the Facebook Page to display the `Disconnect <Page Name>?` confirmation modal (showing the token deletion notice, linked Instagram notice, and Meta Business Integrations revocation hint), and end the recording.

---

## 5. Owner Checklist (Record Screencast & Submit for Review)

Autonomous agents cannot modify Meta App Dashboard settings, handle reviewer passwords, or submit legal App Review forms. Complete the checklist below in order:

- [ ] **1. Complete Meta App Dashboard Prerequisites (`meta-app-setup.md` §2 steps 1–5)**:
  - Add the use cases **"Manage everything on your Page"** (Facebook Login for Business) and **"Manage messaging & content on Instagram"** (Instagram API with Facebook Login) to the existing `spool-hub` Meta app.
  - Add the five permissions (`pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish`) under those use cases.
  - Add `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback` and `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback` to **Valid OAuth Redirect URIs** alongside the existing sign-in callback.
  - Confirm **Business Verification** is approved in Meta Business Suite -> Security Center.
- [ ] **2. Enable `marketing.facebook.inject` on the Target Environment**:
  - Give the go to flip `marketing.facebook.inject: "true"` in `csi-spl-cnf/csi-spl/` and apply Terraform step `030` (`030-cloud-run-hub`) so the Cloud Run hub receives `SPOOL_HUB_MARKETING_FACEBOOK_APP_ID`, `_CLIENT_SECRET`, `_API_VERSION`, and `_SCOPES`.
- [ ] **3. Prepare Reviewer Test Accounts & JPEG Blog Post (Section 3.1)**:
  - Verify the test Facebook user holds `MANAGE` and `CREATE_CONTENT` on the Test Facebook Page, the Test Facebook Page is linked to a Test Instagram Professional account, and a live blog post with a `.jpg` image is unshared in the test workspace.
- [ ] **4. Record the 2-Minute Video Screencast (Section 4)**:
  - Record a `1080p` MP4/MOV following Scenes 1–5 on the live environment with the UI in English and no plaintext passwords visible on screen.
- [ ] **5. Fill Out the Meta App Review Submission Portal (Section 2 & Section 3.2)**:
  - In **App Dashboard -> App Review -> Requests**, create/open the submission request for `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, and `instagram_content_publish`.
  - Paste the five permission justifications from **Section 2**.
  - Paste the reviewer reproduction steps from **Section 3.2** and enter the real reviewer credentials directly into Meta's portal fields (never in git or Spool).
  - Upload the 2-minute screencast video file.
- [ ] **6. Click "Submit for Review"**:
  - Verify all required checkboxes in the Meta App Review portal are green and click **Submit for Review**.

<!-- version: 0.1.2 · updated: 2026-11-05 · last-edit: 2026-11-05T01:45:00Z (R7 W1, W2, N1..N4; round 2 N7, N8) -->
