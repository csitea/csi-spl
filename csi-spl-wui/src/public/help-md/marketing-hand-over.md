# Post a blog post yourself: the draft hand-over

You can post a workspace blog post on Facebook, Instagram, LinkedIn, Viber or
WhatsApp yourself, with your own choice of photos, instead of letting Spool
publish it. Spool prepares the post: the photos, the text, a short Viber
version and the links that open each app. You post it, then you tell Spool it
is posted.

Nothing is posted for you on this path. Spool posts only when you press
**Publish** on a connected account.

## 1. Before you start

- Marketing is switched on for the workspace: **Workspace settings ->
  General -> Marketing**. Only a workspace admin can switch it on.
- The post is live on the workspace blog.
- To record a post as posted (step 7), the account must be connected in the
  same section: a LinkedIn account, a Facebook Page or an Instagram account.
  Viber and WhatsApp need no connection: you only open them.

## 2. Open the hand-over card

1. Open **Workspace settings -> General**.
2. Find the list of posts:
   - **Publish to LinkedIn** lists the posts not yet shared on LinkedIn.
   - Under **Facebook and Instagram**, press **Publish** next to a Page
     or an Instagram account to list the posts not yet shared there.
3. Press **Post by hand** next to a post. The card opens under it. Press it
   again to close the card.

The card shows the formats it prepares: Facebook, Instagram, LinkedIn, Viber
and WhatsApp.

## 3. Pick the photos

The card shows the post's pictures with a checkbox each. The post's own
picture is picked first.

- Tick the photos you want and untick the others. You can pick up to 10.
- The heading shows how many are picked.

## 4. Download the photos

Press **Download selected photos**.

- One photo is downloaded as it is.
- Two or more are downloaded as one ZIP file named after the post.
- Only the ticked photos are in the download.

If the photos cannot be packed into one file, the card says so and downloads
each photo on its own.

## 5. Copy the text

1. Type your hashtags in **Hashtags**, for example `#camp #kids`. You may
   leave out the `#` and separate them with spaces or commas. Each hashtag is
   used once, and at most 30 are kept (Instagram's limit).
2. The box under it shows the full text: the title, the summary, the link to
   the post and your hashtags.
3. Press **Copy caption & hashtags**. "Caption copied!" confirms it.

If your browser blocks the copy, the card says so: select the text in the box
and copy it by hand.

## 6. Open the app and post

| Button | What it opens | What to do there |
|---|---|---|
| **Open Instagram Web / App** | instagram.com, or the app on a phone | Create a post, add the downloaded photos, paste the text. Instagram has no web share link, and a link in an Instagram caption cannot be clicked. |
| **Open Facebook Composer** | Facebook's share window with the post's link | Paste the text if you want it, then post. |
| **Open WhatsApp Web / App** | WhatsApp with the title and link filled in | Pick the chat or group and send. Add the photos there if you want them. |
| **Open Viber Desktop / App** | Viber with the short version filled in | Pick the chat and send. |

**Viber's short version.** Viber cuts a shared text after 200 characters. The
card shows a short version, the title and the link, within 200 characters,
with its length. A long title is shortened and ends with "…"; the link is
never cut.

## 7. Mark it as posted

When the post is up, press **Mark as posted by hand** in the card.

- Spool records the post as published on that account, posted by hand. The
  post leaves that account's list.
- A post that Spool would have published on that account is then never sent.
- A post posted by hand does not count against the account's daily post
  limit.

The button is shown only on a list of a connected account: on a Facebook
Page's or Instagram account's list, and on the LinkedIn list when the
workspace has a connected LinkedIn account.

Who can mark a post: the member who connected the account, or a member who
may change the workspace settings (an admin or the business owner).

| Message | Meaning |
|---|---|
| Recorded as posted by hand. | Done. |
| This post is already published on this account. | It was published or recorded before, it is being sent, or sending it failed. Nothing changed. A post that failed on this account cannot be marked as posted by hand. |
| It could not be recorded. Try again later. | Nothing was recorded. Try again later. |

## 8. For developers

- Hub route: `POST /v1/marketing/posts/{id}/manual-publish?channel=<channel id>`,
  `{id}` the blog post. It answers 200 with
  `{post, channel, status: "published", platform_post_id: "manual", published_at}`;
  403 for a member who may not, 404 while marketing is off, for an unknown
  channel or a post not on the blog, 409 once the post is published, being
  sent or failed on that channel (a failed post is never handed over).
  Audit event: `post_handed_over`.
- The links come from `GET /v1/marketing/posts/{id}/share-links`.
- Spec: `csi-spl-doc/specs/090-marketing-automation` (section 17, task T036).
