# Marketing

> Generated from qto doc `dce0e088-8630-4242-b201-c0ced5ad763b`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Marketing lets a workspace share its live blog posts on **Facebook Pages**, **Instagram** professional accounts, **LinkedIn** and **X**. The share row on every blog post page also shares to WhatsApp, Viber, X, Telegram, Reddit, Substack and e-mail, or copies the link.

Three rules apply across every channel:

- **Nothing is posted without a person pressing Publish.** Connecting a Facebook Page, an Instagram account, LinkedIn or X never publishes anything on its own. Each post goes out only when someone allowed to approve it presses **Publish** in the queue, or shares it from the blog post page. A Facebook, Instagram or X post is approved by the member who connected the channel, by a workspace admin or business owner (`tenant.settings`), or by an agent for one of them. A LinkedIn post is approved by a workspace admin or business owner (`tenant.settings`), or by an agent for one of them, and always goes out on the LinkedIn profile of the member who connected it; that member, once no longer an admin or business owner, cannot publish.
- **No plaintext tokens.** Every OAuth access token is envelope-encrypted with Cloud KMS (`AES-256-GCM`) before it is stored, and is decrypted in memory only for the duration of an outbound API call.
- **One API post per channel per 24 hours.** For a connected Facebook Page, Instagram account or X account, the hub sends at most one post per channel per rolling 24-hour window (and never exceeds Instagram's 100-post daily limit). LinkedIn has no such cap.

---

<a id="ws-doc-0a82ea36-9d45-4018-b350-25b015eab7e7"></a>
## 1. Workspace settings -> General (`/tenant-settings/general`): Connect Facebook Pages and Instagram, publish from the queue, and disconnect

Open the avatar menu (or the gear icon at the bottom-left of the sidebar on desktop) and choose **Workspace settings -> General** (`/tenant-settings/general`). Only workspace administrators and business owners (`tenant.settings`) can open this screen.

<a id="ws-doc-dd009549-2b39-4d27-82e8-da299e5d529a"></a>
### 1.1 Turn on Marketing for the workspace

1. In **Workspace settings -> General**, scroll to the **Marketing** section.
2. Tick **Marketing is on for this workspace**.
   - By default this box is unchecked (*"Off by default. While it is off, nothing is drafted or posted on anyone's behalf."*).
   - If the workspace is not enabled on the hub (`marketing.workspaces`), the section reads *"Marketing is not available in this workspace."*
   - Every workspace except the demo workspace may turn Marketing on (`marketing.workspaces: all`). The hub picks this up after its next terraform step 030 apply; until then only the workspaces it listed before can.

<a id="ws-doc-577340a6-3692-4f1d-b1a9-ebd243651496"></a>
### 1.2 Connect Facebook Pages and Instagram accounts

1. In **Workspace settings -> General**, find the **Facebook and Instagram** section (*"Connect the Facebook Pages you manage; the Instagram professional account linked to a Page comes with it. Nothing is posted without your approval."*).
   - If the hub administrator has not enabled Facebook on the hub yet (`marketing.facebook.inject: "false"`), the section reads *"Facebook and Instagram are not set up on this hub yet."* This is the case on dev and prd today (section 4.2).
   - When no Page is connected yet, the list reads *"No Facebook Page is connected yet."*
2. Click **Connect Facebook** (`POST /v1/marketing/facebook/connect`).
3. Your browser redirects to the Meta OAuth consent screen (`facebook.com/<api_version>/dialog/oauth`, v26.0 today):
   - Sign in with the Facebook account that manages your Facebook Page(s).
   - Choose the Facebook Page(s) and any linked Instagram professional (Business or Creator) account(s) you want to grant access to, and approve the requested permissions.
4. Meta redirects back to the hub callback (`/api/v1/marketing/facebook/callback`), which exchanges the code for a long-lived user token (~60 days), fetches each Page's never-expiring Page access token and any linked `instagram_business_account`, encrypts the tokens with Cloud KMS, and shows a confirmation page:
   - **Facebook connected** — *"Connected N Facebook Page(s) and M Instagram account(s) for workspace `<id>`. Nothing is published on them without your approval."*
   - Click **Back to spool-hub**, then open **Workspace settings -> General** again.
5. In the **Facebook and Instagram** list, each connected account now appears as a row:
   - Each **Facebook Page** row shows a two-letter avatar, the Page name, the platform label **Facebook Page**, and its status badge: **Connected**, **Expired: connect again**, or **Not active**.
   - If a Facebook Page has a linked Instagram Business or Creator account, an indented child row appears directly beneath that Page showing `@username`, the platform label **Instagram**, and its status badge.
   - If your Facebook account does not hold the `MANAGE` (Full control) or `CREATE_CONTENT` (Content) task on a connected Page, that Page row hides the **Publish** button and shows a warning instead: *"You cannot post on this Page: your role on it gives no right to create content. Ask a Page admin on Facebook for full control or content access, then connect again."*

<a id="ws-doc-94e20746-71bd-4252-a1f8-da6895d3ddd9"></a>
### 1.3 Publish a blog post from the queue

1. In the **Facebook and Instagram** list on **Workspace settings -> General**, click **Publish** on the active **Facebook Page** or **Instagram** row you want to post to.
2. The per-account queue opens below the list with the heading **Publish to `<Account Name>`** (*"Live blog posts not shared on this account yet. Each one goes out only when you press Publish."*).
   - The queue and its buttons are for the member who connected the channel and for workspace admins and business owners (`tenant.settings`); anyone else sees a line saying they cannot publish on this account.
   - When every live blog post has already been shared on that account, the queue reads *"Every live blog post is already shared."*
3. Each unshared blog post row in the queue shows:
   - A 48×48 thumbnail preview of the post's image (when the post has one).
   - The post title.
   - A character counter **`<count> / <limit> characters`**:
     - **Facebook Page**: limit is **63,206** characters. The post title and summary are sent as the `message` and the blog post URL as the `link`, so Facebook builds a clickable link card.
     - **Instagram**: limit is **2,200** characters. Because Instagram feed captions do not turn links into clickable cards, the hub appends the blog post URL to the caption (`<title>\n\n<summary>\n\n<url>`) and publishes an image container with the post's hero image (`image_url`).
   - If the caption is longer than the channel's limit, the row displays *"Too long: the summary is shortened to fit."* and the hub shortens the summary to fit (a plain cut, no ellipsis); the title and the post URL are kept whole.
   - If the selected account is **Instagram** and the blog post's hero image is missing or is not a `.jpg` / `.jpeg` file, the row displays *"Instagram takes only a JPEG picture, and this post has none."* and the **Publish** button is disabled for that post.
4. Click **Publish** on the post row (`POST /v1/marketing/posts/{id}/publish?channel=<channel_id>`):
   - While the request is in flight, the **Publish** buttons are disabled.
   - When the post goes out immediately, the notice reads **Published.** and the post leaves the unshared queue.
   - Whatever the result, the post leaves the queue on screen. A deferred or retried post stays scheduled on the hub, but you will not find it in the list.
   - If the account has already published a post within the last 24 hours, the post stays scheduled and the notice reads: *"This account has reached its daily post; this one goes out when the 24-hour window frees up."*
   - If Meta is busy or rate-limits the call (`HTTP 429`, `HTTP 503`, a Graph throttling code such as `4`, `17`, `32` or `613`, or an Instagram container that is not ready yet), the notice says it is retried automatically, and the hub retries it later (at most 3 tries in all). A `500`, `502` or `504` after the post was sent is not retried, because the post may already be on Meta: it is never sent twice.
   - After the last try, or on an error that is never retried, the row says *"The publish failed. Try again later."*, and the member who connected the channel gets a mail saying the post will not be retried and can be posted by hand (section 5).
   - If the token was revoked (`code 190`), the channel status changes to **Expired: connect again**, the member who connected the channel gets a mail with the re-connect link, and the channel's posts wait, unsent, for the re-connect.

<a id="ws-doc-ff24a4f2-a7ff-411a-abae-a67926a069da"></a>
### 1.4 Disconnect a Facebook Page or Instagram account

1. In the **Facebook and Instagram** list on **Workspace settings -> General**, find the **Facebook Page** or **Instagram** row you want to remove and click **Disconnect**.
2. A confirmation dialog opens titled **Disconnect `<Account Name>`?**:
   - The dialog explains: *"Nothing more is published on it from this workspace, and its stored access token is deleted."*
   - If you are disconnecting a **Facebook Page** that has a linked **Instagram** account in the list, the dialog also warns: *"Its linked Instagram account is disconnected too."*
   - The dialog includes the step to revoke access on Meta's side as well: *"To remove the app's access on Meta as well: on Facebook open Settings and privacy, Settings, Business integrations, and remove the app."*
3. Click **Disconnect** to confirm (`DELETE /v1/marketing/channels/{id}`), or **Cancel** to keep the account connected.
4. The hub deletes the stored KMS-encrypted token (`encrypted_tokens = NULL`), marks the channel `disconnected` (cascading to the linked Instagram channel when a Facebook Page is disconnected), removes the row from the list, and shows **Disconnected.**

<a id="ws-doc-d4755944-bf98-4575-85de-858348bd9493"></a>
### 1.5 Connect LinkedIn and publish from the LinkedIn queue

1. There is no Connect LinkedIn button yet. To connect LinkedIn for the first time, a workspace administrator (`tenant.settings`) who is signed in to spool-hub opens `<hub API>/v1/marketing/linkedin/connect?workspace=<workspace_id>` in the same browser while Marketing is switched on, and approves the LinkedIn consent screen (`openid`, `profile`, `w_member_social`). To renew, use the same link, which the hub mails to the member who connected LinkedIn 7 days before the token expires.
   - On the first connect, all existing blog posts are baselined as `skipped` so connecting never floods your LinkedIn profile with old articles.
   - LinkedIn access tokens last about 60 days; 7 days before expiry, the hub mails the member who connected LinkedIn a one-click re-connect link.
2. In **Workspace settings -> General**, under **Publish to LinkedIn** (*"Live blog posts not shared on LinkedIn yet. An admin or business owner of the workspace can publish them."*), review the list of unshared live blog posts. Anyone else sees *"Only an admin or business owner of the workspace can publish."* instead.
3. Click **Publish to LinkedIn** next to a post (`POST /v1/marketing/posts/{id}/publish`). The post goes out on the LinkedIn profile of the member who connected LinkedIn: when that is someone else, the button reads **Publish on the LinkedIn profile of `<Name>`**. When LinkedIn accepts the post, the notice reads **Published on LinkedIn.**

<a id="ws-doc-b5cad6e4-970c-43e0-9e3c-78d4f586bd20"></a>
### 1.6 Connect X and publish from the X queue

1. In **Workspace settings -> General**, find the **X** section (*"Connect the X account you post from. Nothing is posted without a member pressing Publish."*).
   - If the hub administrator has not enabled X on the hub yet (`marketing.x.inject: "false"`), the section reads *"X is not set up on this hub yet."* This is the case on dev and prd today (section 4.4).
   - When no X account is connected yet, the list reads *"No X account is connected yet."*
2. Click **Connect X** (`POST /v1/marketing/x/connect`). Your browser goes to X's consent screen (OAuth 2.0 with PKCE; scopes `tweet.read`, `tweet.write`, `users.read`, `offline.access`). Sign in with the X account you post from and allow the app.
3. X sends you back to the hub (`/api/v1/marketing/x/callback`), which stores the access and refresh tokens encrypted with Cloud KMS and shows **X connected** (*"Connected `<account>` for workspace `<id>`. Nothing is posted on it until a member presses Publish."*). If you declined on X or the exchange failed, the page reads **X was not connected** and nothing is stored.
4. The account appears in the **X** list with the platform label **X** and its status badge: **Connected** or **Expired: connect again**. The access token lasts 2 hours; the hub refreshes it before a publish, so you do not connect again unless X refuses the refresh. Then the badge reads **Expired: connect again**, the member who connected the account gets a mail with the re-connect link, and the account's posts wait, unsent.
5. Click **Publish** on a **Connected** row. The queue opens as in section 1.3, with these X rules:
   - Only the member who connected the account, a workspace admin or a business owner (`tenant.settings`) can publish on it. Anyone else who presses **Publish** is refused with *"Only the member who connected this account, a workspace admin or a business owner can publish on it."*
   - The post is the title, the summary and the blog post link. The counter reads **`<count> / 280 characters, as X counts them`**: a link counts as 23 characters, and CJK characters and emoji count as 2.
   - If it is longer, the row reads *"Too long for X: the summary is shortened to fit."* and the hub shortens the summary with "…". A post that does not fit even so is refused when you press **Publish** (*"This post does not fit X's 280 characters, even shortened."*), and nothing is recorded.
   - The 24-hour rule, the retries (`HTTP 429` or `503` from X, at most 3 tries in all) and the failure mail are as in section 1.3. X bills every post from the owner's prepaid credits; with no credit left X refuses the post, and the publish fails like any other failure.
6. To disconnect, click **Disconnect** on the row and confirm, as in section 1.4. The dialog adds: *"To remove the app's access on X as well: on X open Settings and privacy, Security and account access, Apps and sessions, Connected apps, and revoke the app."*

---

<a id="ws-doc-31cae723-45e8-4397-8e58-c252ebec2919"></a>
## 2. Blog post page (`/blog/<post-id>`): Share a blog post to WhatsApp, Viber, Facebook, and Instagram

Every public blog post page renders a share bar at the top and bottom of the article (`aria-label="Share"`). Sharing from this bar uses native intent URLs and your clipboard — no OAuth connection or API token is needed, and you choose the recipient chat, group, or channel yourself inside each app.

<a id="ws-doc-8f4c4c59-168d-4082-b733-08379ac6e024"></a>
### 2.1 Open the share row on a blog post

1. Open any live blog post at `https://{{site}}/blog/<post-id>`.
2. Locate the **Share** row just under the post title, or at the foot of the article. Its buttons are icons; each icon's tooltip names it (for example **Share on WhatsApp**).

<a id="ws-doc-303674c3-068b-4205-9c14-29b13bb11748"></a>
### 2.2 Share on WhatsApp

1. Click the WhatsApp icon (tooltip **Share on WhatsApp**) in the blog post's share row.
2. Your browser opens `https://wa.me/?text=<title>%20<url>` in a new tab (percent-encoded with `%20` for spaces):
   - **On a phone**: the WhatsApp app opens its share sheet with `<Post Title> <Post URL>` pre-filled in the message field.
   - **On a computer**: `api.whatsapp.com` opens a **Share on WhatsApp** handoff page that launches WhatsApp Desktop or WhatsApp Web with the message pre-filled.
3. Pick the target chat, **Group**, or **WhatsApp Channel** inside WhatsApp and press **Send**.
   - WhatsApp share URLs (`wa.me`) do not allow a link to pre-select a group or channel ID; you always pick the destination inside WhatsApp.

<a id="ws-doc-95bef34f-74a4-45dc-9750-39b8a55b10b3"></a>
### 2.3 Share on Viber

1. Click the Viber icon (tooltip **Share on Viber**) in the blog post's share row.
2. Your browser triggers the `viber://forward?text=<short_title_and_url>` deep link:
   - Because the Viber client silently trims forwarded text longer than **200 characters**, Spool automatically shortens long headlines with an ellipsis (`…`) and keeps the full blog post URL intact so the combined text never exceeds 200 characters.
   - **On a phone**: the Viber app opens its forward picker with the text and link pre-filled.
   - **On a computer**: **Viber Desktop** must be installed (`viber://` is a custom protocol scheme with no web fallback).
3. Select the target **Viber Channel**, **Group**, or contact in Viber and press **Send**.

<a id="ws-doc-fe8e87ab-0dae-4c55-b135-86d6eeef8ef8"></a>
### 2.4 Share on Facebook

1. Click the Facebook icon (tooltip **Share on Facebook**) in the blog post's share row.
2. Your browser opens `https://www.facebook.com/sharer/sharer.php?u=<url>` in a new tab.
   - Only the post URL (`u`) is passed because Meta deprecated the `quote` parameter; Facebook scrapes the blog post's Open Graph tags (`og:title`, `og:description`, `og:image`) to render the link preview card.
3. Choose where to post on Facebook (your Feed, a Group, or a Page you manage), add an optional comment above the card, and publish.

<a id="ws-doc-883f28e5-6b21-45aa-b870-49adde50d3c5"></a>
### 2.5 Share on Instagram

1. Click the Instagram icon (tooltip **Share on Instagram**) in the blog post's share row.
2. Because Instagram has no web share URL (`instagram.com/share` does not exist) and does not render clickable link cards in feed posts, clicking it does two things at once:
   - It copies the formatted caption (`<Post Title>\n\n<Post URL>`) to your clipboard — the Instagram button icon turns into a checkmark for 1.6 seconds to confirm the copy.
   - It opens `https://www.instagram.com/` in a new tab.
3. In Instagram, start a new post, upload a photo from the article, paste the copied caption from your clipboard, and share.

<a id="ws-doc-b849431d-1da0-4902-8ae8-67ee5cceece6"></a>
### 2.6 Read share links from the Hub API

Signed-in workspace members can also fetch the pre-built share links for any known marketing post from `GET /v1/marketing/posts/{id}/share-links`:

- `whatsapp`: `https://wa.me/?text=<title>%20<url>`
- `viber`: `viber://forward?text=<200-char-capped-title-and-url>`
- `facebook`: `https://www.facebook.com/sharer/sharer.php?u=<url>`
- `instagram`: `{ "caption": "<title>\n\n<summary>\n\n<url>", "images": [...], "open": "https://www.instagram.com/" }`

---

<a id="ws-doc-4cf39bea-3697-410c-9204-825cb20b31e7"></a>
## 3. Meta App Dashboard (`developers.facebook.com`): What the Meta app administrator must set

Spool reuses a single Meta app (`spool-hub`, platform `WEB`) for both Facebook sign-in and Facebook Page / Instagram marketing. Before a workspace administrator can connect a Page in section 1.2, the Meta app administrator must complete the setup below in the [Meta App Dashboard](https://developers.facebook.com/apps/) (documented in full in `csi-spl-doc/specs/090-marketing-automation/meta-app-setup.md`).

<a id="ws-doc-9bda2a84-ea78-4e2c-a378-4ff3aebe98c8"></a>
### 3.1 Add the Facebook and Instagram use cases and permissions

1. Open the `spool-hub` app in `developers.facebook.com/apps` and ensure it is connected to the organization's **Meta Business Portfolio** (under **App settings -> Basic -> Business Manager**).
2. In the left sidebar, open **Use cases**, click **Add use cases**, and add:
   - **Manage everything on your Page** (Facebook Login for Business)
   - **Manage messaging & content on Instagram** (Instagram API with Facebook Login)
   - Keep the existing **Authentication and account creation** use case (`email`, `public_profile`) unchanged.
3. Under **Use cases -> Customize**, add the five marketing permissions so the OAuth consent dialog can request them:
   - `pages_show_list` — list the Facebook Pages the connecting user administers (`/me/accounts`).
   - `pages_read_engagement` — required alongside `pages_manage_posts` to read Page metadata and verify publishing state.
   - `pages_manage_posts` — publish link and photo posts to the Facebook Page (`/{page-id}/feed`, `/{page-id}/photos`).
   - `instagram_basic` — read the Instagram Professional (`instagram_business_account`) profile linked to a Facebook Page.
   - `instagram_content_publish` — create and publish media containers on that Instagram account (`/{ig-user-id}/media`, `/{ig-user-id}/media_publish`).

<a id="ws-doc-de0be1f6-c3f8-4e5d-953a-4ead3ad11b34"></a>
### 3.2 Add the OAuth redirect URIs and link the Instagram account

1. In the Meta App Dashboard sidebar, open **Facebook Login for Business -> Settings** (or **Use cases -> Authentication and account creation -> Customize -> Settings**).
2. In **Valid OAuth Redirect URIs**, keep the existing sign-in callback (`/api/v1/auth/facebook/callback`) and add the marketing callback URIs:
   - Production: `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback`
   - Development: `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback`
   - `<BASE_DOMAIN>` is `env.dns.BASE_DOMAIN` in `csi-spl-cnf/csi-spl/all.env.yaml`.
3. Check that **Client OAuth Login**, **Web OAuth Login**, and **Enforce HTTPS** are all set to **Yes**, then click **Save changes**.
4. To publish to Instagram as well, link the Facebook Page to an **Instagram Professional** (**Business** or **Creator**) account in **Meta Business Suite -> Settings -> Accounts -> Instagram accounts** (or in the Instagram mobile app under **Edit profile -> Page**). Personal Instagram accounts are not returned by the Instagram Graph API.

<a id="ws-doc-0da35730-d4bf-464a-96e8-cd046e9d91cb"></a>
### 3.3 Enable Facebook and Instagram on the hub

1. Ensure the Meta App Secret is stored in GCP Secret Manager (`csi-spl-hub-auth-facebook-client-secret`). The KMS key (`marketing.kms_key`) is already configured.
2. Flip `marketing.facebook.inject` to `"true"` per environment in `csi-spl-cnf/csi-spl/<env>.env.yaml`, include the workspace in `marketing.workspaces`, then apply terraform step 030 (owner go).

<a id="ws-doc-227dc355-c121-4528-afad-3307921bac29"></a>
### 3.4 Standard Access vs. Advanced Access (Meta App Review)

Meta grants every permission at **Standard Access** first:

- **With Standard Access (current state)**: only Facebook accounts that hold a role directly on the `spool-hub` Meta app (**Administrator**, **Developer**, or **Tester** under **App roles -> Roles** in the Meta App Dashboard) can grant the five permissions in section 3.1 and publish to the Facebook Pages and Instagram accounts they manage.
- **With Advanced Access**: any workspace administrator on the hub can connect their own Facebook Pages and Instagram accounts without needing a role on the `spool-hub` Meta app. Moving the five permissions to **Advanced Access** requires completing **Meta Business Verification** in Meta Business Suite (**Security Center**) and submitting an **App Review** with screen recordings of the connect, publish, and disconnect flows.

---

<a id="ws-doc-03b61ebf-59bf-4adf-aed7-9075673d1a4f"></a>
## 4. What is not built or not switched on yet

The following parts of spec `090-marketing-automation` are not live on production yet; do not look for them in the UI:

<a id="ws-doc-de8c7ec7-07ca-467b-8de2-f3761a3c4337"></a>
### 4.1 Meta App Review submission for Advanced Access (`T038`)

The Meta App Review submission package (`T038`) has **not been submitted or approved by Meta yet**. The `spool-hub` Meta app operates under **Standard Access** (section 3.4): once Facebook and Instagram are switched on (section 4.2), connecting a Facebook Page or Instagram account and publishing from the queue works only for the Pages of people who hold a role on the Meta app, and opens to other workspace administrators only after Meta approves **Advanced Access**.

<a id="ws-doc-80265184-501c-4bc8-8cb5-7b705fab7a76"></a>
### 4.2 Facebook and Instagram are not switched on yet

`marketing.facebook.inject` is `"false"` on dev and prd (`csi-spl-cnf/csi-spl/all.env.yaml`, with no override in `dev.env.yaml` or `prd.env.yaml`). Until it is switched on (section 3.3), sections 1.2 to 1.4 show only the line *"Facebook and Instagram are not set up on this hub yet."*

<a id="ws-doc-55dd7060-67d3-453e-95ca-06cb753d5a95"></a>
### 4.3 LinkedIn is not switched on on dev

`marketing.linkedin.inject` is `"false"` in `dev.env.yaml`, so section 1.5 does not work on dev; on prd it is switched on.

<a id="ws-doc-794f6658-bdbd-4c80-b412-f829aa1cf415"></a>
### 4.4 X is not switched on yet

`marketing.x.inject` is `"false"` on dev and prd, so section 1.6 shows only *"X is not set up on this hub yet."* Turning it on needs the owner's X developer app and prepaid credits: the steps are in `csi-spl-doc/specs/090-marketing-automation/x-app-setup.md`.

<a id="ws-doc-109e2a47-7c72-40d7-96ed-4c16e41594f8"></a>
## 5. Post a blog post by hand

To post a blog post yourself, with your own choice of photos, press **Post by hand** next to the post in the publish queue. The steps: [Post a blog post yourself: the draft hand-over](marketing-hand-over.md).

## 6. Workspace settings -> Posts (`/tenant-settings/posts`): Write your own post and publish it

Besides the blog, a workspace can write its own posts. Open **Workspace settings -> Posts**. Only workspace administrators and business owners (`tenant.settings`) see this screen, and Marketing must be on for the workspace (section 1.1); otherwise the screen says so.

### 6.1 Write a draft

1. Type the post in **Text** (up to 3,000 characters; the counter below the box shows how many you used).
2. Optionally give a **Picture address**: a public `https://` address of a JPEG picture. Instagram needs one; Facebook posts it as a photo with your text as its caption; LinkedIn and X get the text only.
3. Press **Save draft**. The draft appears in the list below, marked *Draft*.

Every administrator and business owner of the workspace sees every draft. A draft written by someone else is marked *Written by another admin or business owner*: only its author can edit, delete or publish it.

### 6.2 Edit or delete a draft

Press **Edit** on your draft, change it in the form above, and press **Save changes** (or **Cancel**). **Delete** removes the draft after you confirm. Once a post is published it can no longer be edited or deleted: it stays as it went out.

### 6.3 Publish

1. Under your draft, tick the accounts in **Publish on**: every connected LinkedIn profile, Facebook Page, Instagram account and X account of the workspace (connect them in section 1).
2. Press **Publish**. There is no approval step: the post goes out at once, on each account once.
3. A line per account says what happened: *published*, *waits for the daily limit* (Facebook, Instagram and X send at most one post per account per 24 hours), *will be tried again*, or why it was refused: Instagram needs a JPEG picture or at most 2,200 characters, X takes at most 280 characters, or the post is already published there.
4. The draft is now marked *Published* and lists where it went. You can still publish it on an account it has not gone to yet.

A LinkedIn post goes out on the LinkedIn profile of the member who connected LinkedIn, as for blog posts.
