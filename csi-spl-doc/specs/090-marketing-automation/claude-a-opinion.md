# 090 review: claude-a opinion

**Reviewer**: c-277 (claude-a) · **Author**: a-273 (agy) · **Topic**: `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`  
**Read**: `spec.md` v0.2.0 at spec sha `755e86235` (origin/master `31c04371c`).

Platform facts below are what I know as of mid-2026. Prices and review rules change often, so whoever builds a channel checks that platform's current developer terms first.

## 1. What I agree with

- **Delegated posting, not impersonation** (section 2). This is the only reading that keeps every account within its platform's terms. The person connects their own account through official OAuth, sees the scopes, can revoke, and every post carries their own name. No passwords, no browser automation, no fake accounts (section 9).
- **Per-post approval is the default**, with a standing grant as an opt-in, and an audit trail.
- **Facebook only to Pages.** Meta removed posting to personal profiles years ago.
- **Opt-in only email** with one-click unsubscribe, no bought or scraped lists.
- **A daily cap per channel** and content drawn only from real releases and features (section 4). This matches the owner's "not spamming anyone".
- **Two-way inbox out of scope.**

## 2. What I would change

### 2.1 Platform API reality (sections 3 and 5)

| Platform | What the spec should say |
|---|---|
| LinkedIn, person | Posting as a member uses the self-serve "Share on LinkedIn" product (`w_member_social`), no app review, free. Member access tokens last about 60 days and most apps get **no refresh token**, so the person re-consents about every two months. The spec needs a "token expires soon" reminder and an `expired` state the author is told about (AC-06 covers only the failure). |
| LinkedIn, company page | Posting as a page needs `w_organization_social` from the Community Management API, which requires LinkedIn's review of a registered business. Weeks, not days. Not phase 1. |
| X | The "$100/month Basic" figure is out of date: Basic went to $200/month in late 2024, and X has since trialled pay-per-use pricing. The free tier has allowed a small monthly number of write-only posts, which may be enough for one post a day. State the need ("about 30 posts a month, write only") and let the build check the current price. X uses OAuth 2.0 with PKCE and its refresh tokens rotate on every use, so the store must save the new one each time. |
| Facebook Page | Needs `pages_manage_posts` and `pages_read_engagement`, Meta App Review and Business Verification. Page tokens can be long-lived. Not phase 1. |
| Email | See 2.5. |

Reach metrics (impressions, clicks) are not available on every tier: LinkedIn member post analytics need extra products, and X reads cost money. Make metrics "where the API returns them, best effort", and leave them out of phase 1.

### 2.2 Consent, revoke and audit

- **Revoke** (AC-02): call the platform's revoke endpoint where one exists; where it does not, delete our copy and tell the person to remove the app in that platform's settings. Say this in AC-02 so nobody claims "revoked" when only our copy is gone.
- **The audit trail must be append-only and survive the channel.** The appendix has no audit table, the post row is mutable, and `ON DELETE CASCADE` from channels would erase the history of a disconnected account. Add a `marketing_post_events` table (insert only: created, edited, approved, rejected, scheduled, sent, failed, revoked; who, when, the exact body sent, platform post id). The runtime database role gets INSERT and SELECT on it, never UPDATE or DELETE. Channels are marked `revoked`, never deleted.
- **A standing grant is narrow and visible**: per channel, per content kind (for example "release announcement only"), with an end date, and a single "pause all" switch per workspace. The audit row says "published under standing grant <id>".
- Only the person who connected an account may grant standing posting on it. Who may approve a single post is an owner question (spec Q2), but the account holder must always be able to see and veto what goes out in their name.

### 2.3 How daily content is produced

The spec says where content comes from but not how a day gets filled. Proposal:

1. **Sources**: the release notes table (spec 065) for each new `v<X.Y.Z>` tag, and the help pages in `csi-spl-doc/doc/help/` for "how to use it" tips.
2. **A content queue**: an agent drafts from a source and links the draft to it (release tag or help page). A draft with no source is refused. No invented numbers, no claims the source does not make.
3. **One draft per channel**, sized to the channel (X length limit, LinkedIn longer).
4. **A human approves** (default), edits or rejects in the WUI. Approved drafts go into the next free day slot.
5. **Quiet days are fine.** On days without a release the queue takes an approved evergreen tip; if the queue is empty, nothing is posted. Never generate filler to meet a quota.
6. **No duplicates**: the same text is not posted twice to a channel (LinkedIn and X both reject or penalise duplicates).

### 2.4 Scheduling and the daily cap

- Define "a day" as a calendar day in the **workspace's time zone**, and set a default posting hour.
- AC-08's "stagger to the next day" can build an endless backlog after a big release. Add a rule: a draft that has waited more than N days (say 7) goes back to the reviewer instead of posting stale news.
- The post row's `scheduled_for` is the single source of truth; the Calendar (spec 089) shows it and moving it there edits that field. One source of truth, not two copies kept in sync.
- The sender is a scheduled job that claims a due post once (row lock or status transition), so a retry or two hub instances never post twice. Retries back off and stop after a few tries.

### 2.5 Email

- **"From the person's own address" does not work for most people.** Sending as a `gmail.com` or similar address through any provider fails DMARC and lands in spam or is rejected. Send from the project's own authenticated sending domain (cnf, never a literal), with the person's name as the display name and their address as `Reply-To`.
- **Double opt-in**: the sign-up sends a confirmation link; only a confirmed address is subscribed. Keep the consent proof (time, source, confirmation time).
- **One-click unsubscribe** per RFC 8058 (`List-Unsubscribe` and `List-Unsubscribe-Post`), no login, honoured at once. Big mailbox providers require this, plus SPF, DKIM and DMARC alignment, and a spam complaint rate kept under 0.3% (aim for 0.1%).
- **Bounces and complaints** come back from the provider by webhook and suppress the address for good.
- **Email is not daily.** One email a day to a newsletter list is what people mark as spam. Social can be daily; email should be per release, at most weekly. I put this to the owner as a question.
- **Provider**: pick a hosted provider with bounce and complaint webhooks and a dedicated sending domain. Plain SMTP from our own servers is a deliverability trap. The choice is the owner's (spec Q4).
- A postal address in the footer is required by CAN-SPAM; whose address that is, is an owner question if the workspace is a person rather than a company.

### 2.6 Secrets

- Agree: tokens never in git, logs, spool messages or terminal output.
- **One Secret Manager secret per connected account is the wrong shape** for a value every member creates at run time: the hub's service account would need rights to create and delete secrets project-wide, which is far more than it has today, and every connect becomes an infra mutation outside terraform. I propose instead: the token is **encrypted with a Cloud KMS key** (key made by terraform, the hub may only encrypt and decrypt with it) and the ciphertext is stored in a `marketing_channel_tokens` row. The database never sees plain text; a database dump without the key is useless. The platform app secrets (our client id and secret per platform) are few and fixed, and those do belong in Secret Manager.
- Decrypt only inside the sender, just before the call; never return a token through any API.

### 2.7 Per-workspace storage and FORCE RLS

The appendix has `workspace_id` columns but no row security. Every new table (channels, tokens, posts, post events, subscribers) gets the same workspace key column and fail-closed policy as the existing workspace tables, with **FORCE ROW LEVEL SECURITY**, an isolation test per table, and the migration run by the owner role while the hub runs as the DML-only role. The sender job works workspace by workspace inside the workspace scope, never as a cross-workspace operator. The appendix SQL also needs its literals quoted (`'linkedin'`, `'{}'`) before anyone copies it.

Small consistency fixes: FR-008's status list lacks `rejected` and puts `scheduled` before `approved`; the appendix has both. Pick one order: `draft -> approved -> scheduled -> published | failed`, plus `rejected`.

### 2.8 A smaller phase 1

Phase 1 should prove the whole loop on **one channel with no app review and no cost**:

1. LinkedIn member posting (`w_member_social`) for the project's own workspace only.
2. Drafts from release notes, one per new release tag, plus help-page tips.
3. Per-post approval only. No standing grant, no metrics, no Calendar edit (read-only display is fine).
4. Encrypted token storage, revoke, append-only audit, FORCE RLS tables, the daily cap, the expiry reminder.

Phase 2: email newsletter (opt-in, per release). Phase 3: X (once the budget is decided) and Facebook Page and LinkedIn page (once app review is passed). Standing grants come after phase 1 has run cleanly for a while.

## 3. Open questions for the owner

1. **Who uses it**: is this a feature every workspace gets, or a tool for marketing the Spool Hub itself from the project's own workspace? Phase 1 above assumes the second.
2. **Email cadence**: social posts daily, but email per release and at most weekly. Agree?
3. **Sending identity for email**: the project's own sending domain with the person's name as display name. Agree, and whose postal address goes in the footer?
4. Spec Q1, Q4 and Q5 stand as written, with the X price updated.

## 4. Consensus

Pending: discussion with a-273 on the topic.

<!-- last-edit: 2026-10-05T05:00:00Z -->
