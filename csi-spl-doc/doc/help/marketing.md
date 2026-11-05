# Marketing

Marketing lets a workspace share its live blog posts on **Facebook Pages**, **Instagram** professional accounts and **LinkedIn**. The share row on every blog post page also shares to WhatsApp, Viber, X, Telegram, Reddit, Substack and e-mail, or copies the link.

Three rules apply across every channel:

- **Nothing is posted without human approval.** Connecting a Facebook Page, an Instagram account, or LinkedIn never publishes anything on its own. Each post goes out only when someone allowed to approve it presses **Publish** in the queue, or shares it from the blog post page. A Facebook Page or Instagram post is approved by the member who connected the channel, by a workspace admin (`tenant.settings`), or by an agent for one of them. A LinkedIn post is approved only by the member who connected LinkedIn, or by an agent for that member.
- **No plaintext tokens.** Every OAuth access token is envelope-encrypted with Cloud KMS (`AES-256-GCM`) before it is stored, and is decrypted in memory only for the duration of an outbound API call.
- **One API post per channel per 24 hours.** For a connected Facebook Page or Instagram account, the hub sends at most one post per channel per rolling 24-hour window (and never exceeds Instagram's 100-post daily limit). LinkedIn has no such cap.

---

## 1. Workspace settings -> General (`/tenant-settings/general`): Connect Facebook Pages and Instagram, publish from the queue, and disconnect

Open the avatar menu (or the gear icon at the bottom-left of the sidebar on desktop) and choose **Workspace settings -> General** (`/tenant-settings/general`). Only workspace administrators and business owners (`tenant.settings`) can open this screen.

### 1.1 Turn on Marketing for the workspace

1. In **Workspace settings -> General**, scroll to the **Marketing** section.
2. Tick **Marketing is on for this workspace**.
   - By default this box is unchecked (*"Off by default. While it is off, nothing is drafted or posted on anyone's behalf."*).
   - If the workspace is not enabled on the hub (`marketing.workspaces`), the section reads *"Marketing is not available in this workspace."*

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
   - Click **Back to spool-hub** to return to **Workspace settings -> General**.
5. In the **Facebook and Instagram** list, each connected account now appears as a row:
   - Each **Facebook Page** row shows a two-letter avatar, the Page name, the platform label **Facebook Page**, and its status badge: **Connected**, **Expired: connect again**, or **Not active**.
   - If a Facebook Page has a linked Instagram Business or Creator account, an indented child row appears directly beneath that Page showing `@username`, the platform label **Instagram**, and its status badge.
   - If your Facebook account does not hold the `MANAGE` (Full control) or `CREATE_CONTENT` (Content) task on a connected Page, that Page row hides the **Publish** button and shows a warning instead: *"You cannot post on this Page: your role on it gives no right to create content. Ask a Page admin on Facebook for full control or content access, then connect again."*

### 1.3 Publish a blog post from the queue

1. In the **Facebook and Instagram** list on **Workspace settings -> General**, click **Publish** on the active **Facebook Page** or **Instagram** row you want to post to.
2. The per-account queue opens below the list with the heading **Publish to `<Account Name>`** (*"Live blog posts not shared on this account yet. Each one goes out only when you press Publish."*).
   - The queue and its buttons are for the member who connected the channel and for workspace admins (`tenant.settings`); anyone else sees a line saying they cannot publish on this account.
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
   - If the account has already published a post within the last 24 hours, the post stays scheduled and the notice reads: *"This account has reached its daily post; this one goes out when the 24-hour window frees up."*
   - If Meta is busy or rate-limits the call (`HTTP 429`, `HTTP 503`, a Graph throttling code such as `4`, `17`, `32` or `613`, or an Instagram container that is not ready yet), the notice says it is retried automatically, and the hub retries it later (at most 3 tries in all). A `500`, `502` or `504` after the post was sent is not retried, because the post may already be on Meta: it is never sent twice.
   - If the token was revoked (`code 190`), the channel status changes to **Expired: connect again**, the member who connected the channel gets a mail with the re-connect link, and the channel's posts wait, unsent, for the re-connect.

### 1.4 Disconnect a Facebook Page or Instagram account

1. In the **Facebook and Instagram** list on **Workspace settings -> General**, find the **Facebook Page** or **Instagram** row you want to remove and click **Disconnect**.
2. A confirmation dialog opens titled **Disconnect `<Account Name>`?**:
   - The dialog explains: *"Nothing more is published on it from this workspace, and its stored access token is deleted."*
   - If you are disconnecting a **Facebook Page** that has a linked **Instagram** account in the list, the dialog also warns: *"Its linked Instagram account is disconnected too."*
   - The dialog includes the step to revoke access on Meta's side as well: *"To remove the app's access on Meta as well: on Facebook open Settings and privacy, Settings, Business integrations, and remove the app."*
3. Click **Disconnect** to confirm (`DELETE /v1/marketing/channels/{id}`), or **Cancel** to keep the account connected.
4. The hub deletes the stored KMS-encrypted token (`encrypted_tokens = NULL`), marks the channel `disconnected` (cascading to the linked Instagram channel when a Facebook Page is disconnected), removes the row from the list, and shows **Disconnected.**

### 1.5 Connect LinkedIn and publish from the LinkedIn queue

1. To connect LinkedIn for the first time (or renew an expiring token), a workspace administrator opens the connect link the hub mails (`<hub API>/v1/marketing/linkedin/connect?workspace=<workspace_id>`) while Marketing is switched on and approves the LinkedIn OAuth consent screen (`openid`, `profile`, `w_member_social`).
   - On the first connect, all existing blog posts are baselined as `skipped` so connecting never floods your LinkedIn profile with old articles.
   - LinkedIn access tokens last about 60 days; 7 days before expiry, the hub mails the member who connected LinkedIn a one-click re-connect link.
2. In **Workspace settings -> General**, under **Publish to LinkedIn** (*"Live blog posts not shared on LinkedIn yet. Only the workspace owner who connected LinkedIn can publish them."*), review the list of unshared live blog posts.
3. Click **Publish to LinkedIn** next to a post (`POST /v1/marketing/posts/{id}/publish`). When LinkedIn accepts the post, the notice reads **Published on LinkedIn.**

---

## 2. Blog post page (`/blog/<post-id>`): Share a blog post to WhatsApp, Viber, Facebook, and Instagram

Every public blog post page renders a share bar at the top and bottom of the article (`aria-label="Share"`). Sharing from this bar uses native intent URLs and your clipboard — no OAuth connection or API token is needed, and you choose the recipient chat, group, or channel yourself inside each app.

### 2.1 Open the share row on a blog post

1. Open any live blog post at `https://{{site}}/blog/<post-id>`.
2. Locate the **Share** row just under the post title, or at the foot of the article. Its buttons are icons; each icon's tooltip names it (for example **Share on WhatsApp**).

### 2.2 Share on WhatsApp

1. Click the WhatsApp icon (tooltip **Share on WhatsApp**) in the blog post's share row.
2. Your browser opens `https://wa.me/?text=<title>%20<url>` in a new tab (percent-encoded with `%20` for spaces):
   - **On a phone**: the WhatsApp app opens its share sheet with `<Post Title> <Post URL>` pre-filled in the message field.
   - **On a computer**: `api.whatsapp.com` opens a **Share on WhatsApp** handoff page that launches WhatsApp Desktop or WhatsApp Web with the message pre-filled.
3. Pick the target chat, **Group**, or **WhatsApp Channel** inside WhatsApp and press **Send**.
   - WhatsApp share URLs (`wa.me`) do not allow a link to pre-select a group or channel ID; you always pick the destination inside WhatsApp.

### 2.3 Share on Viber

1. Click the Viber icon (tooltip **Share on Viber**) in the blog post's share row.
2. Your browser triggers the `viber://forward?text=<short_title_and_url>` deep link:
   - Because the Viber client silently trims forwarded text longer than **200 characters**, Spool automatically shortens long headlines with an ellipsis (`…`) and keeps the full blog post URL intact so the combined text never exceeds 200 characters.
   - **On a phone**: the Viber app opens its forward picker with the text and link pre-filled.
   - **On a computer**: **Viber Desktop** must be installed (`viber://` is a custom protocol scheme with no web fallback).
3. Select the target **Viber Channel**, **Group**, or contact in Viber and press **Send**.

### 2.4 Share on Facebook

1. Click the Facebook icon (tooltip **Share on Facebook**) in the blog post's share row.
2. Your browser opens `https://www.facebook.com/sharer/sharer.php?u=<url>` in a new tab.
   - Only the post URL (`u`) is passed because Meta deprecated the `quote` parameter; Facebook scrapes the blog post's Open Graph tags (`og:title`, `og:description`, `og:image`) to render the link preview card.
3. Choose where to post on Facebook (your Feed, a Group, or a Page you manage), add an optional comment above the card, and publish.

### 2.5 Share on Instagram

1. Click the Instagram icon (tooltip **Share on Instagram**) in the blog post's share row.
2. Because Instagram has no web share URL (`instagram.com/share` does not exist) and does not render clickable link cards in feed posts, clicking it does two things at once:
   - It copies the formatted caption (`<Post Title>\n\n<Post URL>`) to your clipboard — the Instagram button icon turns into a checkmark for 1.6 seconds to confirm the copy.
   - It opens `https://www.instagram.com/` in a new tab.
3. In Instagram, start a new post, upload a photo from the article, paste the copied caption from your clipboard, and share.

### 2.6 Read share links from the Hub API

Signed-in workspace members can also fetch the pre-built share links for any known marketing post from `GET /v1/marketing/posts/{id}/share-links`:

- `whatsapp`: `https://wa.me/?text=<title>%20<url>`
- `viber`: `viber://forward?text=<200-char-capped-title-and-url>`
- `facebook`: `https://www.facebook.com/sharer/sharer.php?u=<url>`
- `instagram`: `{ "caption": "<title>\n\n<summary>\n\n<url>", "images": [...], "open": "https://www.instagram.com/" }`

---

## 3. Meta App Dashboard (`developers.facebook.com`): What the Meta app administrator must set

Spool reuses a single Meta app (`spool-hub`, platform `WEB`) for both Facebook sign-in and Facebook Page / Instagram marketing. Before a workspace administrator can connect a Page in section 1.2, the Meta app administrator must complete the setup below in the [Meta App Dashboard](https://developers.facebook.com/apps/) (documented in full in `csi-spl-doc/specs/090-marketing-automation/meta-app-setup.md`).

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

### 3.2 Add the OAuth redirect URIs and link the Instagram account

1. In the Meta App Dashboard sidebar, open **Facebook Login for Business -> Settings** (or **Use cases -> Authentication and account creation -> Customize -> Settings**).
2. In **Valid OAuth Redirect URIs**, keep the existing sign-in callback (`/api/v1/auth/oauth/facebook/callback`) and add the marketing callback URIs:
   - Production: `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback`
   - Development: `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback`
   - `<BASE_DOMAIN>` is `env.dns.BASE_DOMAIN` in `csi-spl-cnf/csi-spl/all.env.yaml`.
3. Check that **Client OAuth Login**, **Web OAuth Login**, and **Enforce HTTPS** are all set to **Yes**, then click **Save changes**.
4. To publish to Instagram as well, link the Facebook Page to an **Instagram Professional** (**Business** or **Creator**) account in **Meta Business Suite -> Settings -> Accounts -> Instagram accounts** (or in the Instagram mobile app under **Edit profile -> Page**). Personal Instagram accounts are not returned by the Instagram Graph API.

### 3.3 Enable Facebook and Instagram on the hub

1. Ensure the Meta App Secret is stored in GCP Secret Manager (`csi-spl-hub-auth-facebook-client-secret`). The KMS key (`marketing.kms_key`) is already configured.
2. Flip `marketing.facebook.inject` to `"true"` per environment in `csi-spl-cnf/csi-spl/<env>.env.yaml`, include the workspace in `marketing.workspaces`, then apply terraform step 030 (owner go).

### 3.4 Standard Access vs. Advanced Access (Meta App Review)

Meta grants every permission at **Standard Access** first:

- **With Standard Access (current state)**: only Facebook accounts that hold a role directly on the `spool-hub` Meta app (**Administrator**, **Developer**, or **Tester** under **App roles -> Roles** in the Meta App Dashboard) can grant the five permissions in section 3.1 and publish to the Facebook Pages and Instagram accounts they manage.
- **With Advanced Access**: any workspace administrator on the hub can connect their own Facebook Pages and Instagram accounts without needing a role on the `spool-hub` Meta app. Moving the five permissions to **Advanced Access** requires completing **Meta Business Verification** in Meta Business Suite (**Security Center**) and submitting an **App Review** with screen recordings of the connect, publish, and disconnect flows.

---

## 4. What is not built or not switched on yet

The following parts of spec `090-marketing-automation` are not live on production yet; do not look for them in the UI:

### 4.1 Meta App Review submission for Advanced Access (`T038`)

The Meta App Review submission package (`T038`) has **not been submitted or approved by Meta yet**. The `spool-hub` Meta app operates under **Standard Access** (section 3.4): once Facebook and Instagram are switched on (section 4.2), connecting a Facebook Page or Instagram account and publishing from the queue works only for the Pages of people who hold a role on the Meta app, and opens to other workspace administrators only after Meta approves **Advanced Access**.

### 4.2 Facebook and Instagram are not switched on yet

`marketing.facebook.inject` is `"false"` on dev and prd (`csi-spl-cnf/csi-spl/all.env.yaml`, with no override in `dev.env.yaml` or `prd.env.yaml`). Until it is switched on (section 3.3), sections 1.2 to 1.4 show only the line *"Facebook and Instagram are not set up on this hub yet."*

## 5. Post a blog post by hand

To post a blog post yourself, with your own choice of photos, press **Post by hand** next to the post in the publish queue. The steps: [Post a blog post yourself: the draft hand-over](marketing-hand-over.md).
