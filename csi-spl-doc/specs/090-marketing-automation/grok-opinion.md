# Grok review of spec 090

Reviewed `spec.md` v0.2.0. The file's last change is `755e86235d2629285763021a0663d261516cf1b8`. The tree this review was written against is origin/master `860c8eea8ed0f984ccc0df39c9c6755cf05620cb`. Docs only. This file does not change the spec.

Reviewer: grok, lane g-276. Author: a-273. Topic `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`.

I also read the two Claude reviews already on that tree: claude-a in `8ba3c6e5c` and claude-b in `f7d9acae6`. Where they ask for the same behaviour, this review asks for it too, so the author can record one set of changes.

Platform facts were read on 2026-10-05 from the vendor docs named below. Prices and review gates move. The spec should name the doc and say "read the live figure at build time".

## What I agree with

The delegated-posting reading is the right one, and I would not reopen it. The person connects their own account through the platform's OAuth, can revoke it, and approves what goes out in their name. Per-post approval is the default. No passwords, no browser automation, no accounts that are not theirs, no sock puppets. Facebook personal profiles stay out. Email is opt-in only, and unsubscribe needs no login. Two-way social inbox stays out. The daily cap of one social post per channel is the right anti-spam rule.

The appendix correctly stores a secret reference and no token column. Keep the token out of git, logs, spool messages and terminal output.

Calendar (spec 089) is the right place to show a scheduled post once that screen exists. Phase 1 stores `scheduled_for` and does not wait on the calendar screen. Spec 089 is Consensus and still builds nothing.

## What I would change

I will treat the spec as agreed once the behaviour below is recorded. Wording can be shorter than this file.

### 1. X is pay-per-use on the current card

Section 3, section 5, and open question 5 still say a Basic plan at $100 a month.

The X API pricing page (`docs.x.com`, pay-per-usage, read 2026-10-05, one fetch) says there is no subscription. Credits are prepaid. Creating a post is $0.015. Creating a post that contains a URL is $0.200. A zero balance blocks the call. The page says the prices change. It does not list a free tier or a monthly plan.

One plain post a day is about $0.45 a month at that card. The same post with a link is about $6 a month. At one post a day the rate limit is not the constraint.

Replace the $100 sentence with that card and "read the live price at build time". Restate open question 5 as: is a small prepaid balance approved, and does the daily post include a link.

Posting still needs the person's OAuth in user context, with the write scope. An app-only token cannot post as them. When X is built, a rotated refresh token has to be stored back on every use.

### 2. LinkedIn member posting, with a 60-day token

`w_member_social` via Share on LinkedIn is the right phase 1 channel. It posts to that member's profile only. It is self-serve. Company Page posting (`w_organization_social`, Community Management) is a reviewed product and is not phase 1.

The Share on LinkedIn doc publishes 150 requests per member per UTC day and 100,000 per application. A 429 is a failed post (acceptance AC-06).

The 3-legged OAuth doc (updated 2026-05-15) says access tokens last 60 days. A programmatic refresh token exists only for a limited partner set. The product asks the member to reconnect while the token is still valid, and it has an `expired` state the author is told about. Do not plan a silent refresh.

### 3. Facebook Pages, and the review gate

Pages only is correct. Name the permissions: `pages_manage_posts` and `pages_show_list`, used with a Page token.

A Page run by someone with a role on the app can be posted to without App Review. Any other Page needs Meta business verification and App Review. A Page token does not publish to Instagram. Instagram is not in this spec.

### 4. Email

Section 2.4 says the mail goes out from the person's own address. That fails DMARC for any mailbox whose domain the workspace does not control.

Record this instead:

- The From domain is one sending domain the workspace has authenticated (SPF, DKIM, DMARC). The person's name may be the display name. Their address may be Reply-To. The From address is one that domain accepts.
- Send through one HTTPS provider API. The hub does not send SMTP. The vendor stays an owner question.
- Double opt-in: a confirmation link, and only a confirmed address is subscribed. Store who signed up, when, and when they confirmed.
- One-click unsubscribe: `List-Unsubscribe` and `List-Unsubscribe-Post`, plus a link in the body, with no login (AC-07).
- Bounces and complaints come back from the provider and suppress the address. Stop sending if the complaint rate crosses the provider's bulk-sender line (the spec's 0.1% aim is the right target).
- A physical postal address in the footer is required. Whose address that is stays with the provider question.
- Email is not daily. A daily letter to the same list is what people mark as spam. Social posts use the daily cap. Email goes out per release, and at most weekly.

### 5. Tokens and forced row-level security

App client ids and client secrets stay in Secret Manager. Those are few, fixed, and already how this hub stores provider secrets.

The person's OAuth token is different: one per connected account, created at run time. A new Secret Manager entry per account sits outside the row security that guards every other workspace row, and it makes every connect an infrastructure change. Store it as ciphertext in the workspace row, encrypted with a key the infrastructure owns (the hub can encrypt and decrypt, and it cannot read another workspace's row). A database dump without the key is useless. Decrypt only inside the sender, just before the call. Never return a token from an API.

I will also accept Secret Manager for that token if, and only if, every read checks the workspace and a test proves a second workspace cannot read the first workspace's token.

The three appendix tables, the token row, and the audit table all get the same isolation as `csi-spl-rdb/src/sql/postgres/spool-hub/0091_member_activity.sql` lines 37-44: row-level security enabled and forced, the workspace-matching policy, and the operator-scope policy. Use that file's column name so a later migration does not invent a second key. The sentences of this spec keep saying workspace. A one-line note that the appendix's `workspace_id` is the prose name for that column is enough, if copying the column name into the spec is unwanted.

Quote the appendix literals (`'linkedin'`, `'{}'`). They are not valid as written.

`opt_in_ip` is personal data. Store a masked value, or store none, same as the activity log.

The sender runs one workspace at a time, inside that workspace's scope.

### 6. What a day is, and where the text comes from

The cap is a maximum, not a quota. A day with nothing approved sends nothing. No recycled post, no filler, no second copy of the same text on a channel.

Sources, in order:

1. Release notes (spec 065), when a version is new.
2. Help articles under `csi-spl-doc/doc/help/`, one concrete way to use the product, on days with no new release.

A draft with no source link is refused. One source becomes one draft per channel, because the length limits differ. Each draft counts only against that channel.

"A day" is the workspace time zone, else UTC. Each channel has a posting hour in that zone. Acceptance AC-08 (two same-day drafts stagger) stays, and a draft that has waited more than 7 days goes back to the reviewer instead of going out as stale news.

### 7. Audit, revoke, and one send

The audit is its own append-only table, not columns on the post row. The app role gets insert and select, not update or delete. Events: connect, revoke, grant started, grant ended, created, edited, approved, rejected, published, failed. Each row records who, when, the channel, and the body (or a hash of it). No token.

Disconnecting a channel marks it revoked. It does not delete the row, and it does not cascade-delete the history. Delete our copy of the token at once. Call the platform's revoke endpoint where one exists. Where it does not, the screen tells the person how to remove the app on that platform.

The person who connected an account is the one who approves posts into that account, or who signs a standing grant for it. A workspace admin does not approve into someone else's personal feed.

A standing grant, when it exists, is per channel, per content kind (a template the person has approved, not free text), at most 30 days, and revocable, with a pause for the whole workspace. The audit names the grant. Phase 1 leaves it off.

Dispatch is single-flight. The post is claimed (a status move under a lock) before the HTTP call. A retry does not call the platform again once a platform post id is stored. `last_error` is an error code and a short platform message, never the token and never the request.

Align the status words. One order: `draft`, `approved`, `scheduled`, `published` or `failed`, plus `rejected`.

### 8. Phase 1

Phase 1 is the workspace that popularizes the product, not every workspace. Storage is still per workspace, so the isolation is real from the first migration. Opening the feature to every workspace is what triggers app review for other people's pages, and that waits for an owner decision.

Phase 1 itself:

- LinkedIn member posting only (point 2).
- Drafts from the newest release note, or one help article when there is no new release.
- Per-post approval by the account holder. Standing grant off.
- The daily cap, the audit table, the revoke behaviour, the encrypted token, and forced row-level security.
- `scheduled_for` is the schedule. The calendar shows it when spec 089 is built.
- Status and the live URL. No reach numbers.

X waits on the credit decision. Facebook outside the app's own roles waits on Meta review. Email waits on a domain and a provider. A standing grant waits until phase 1 has sent real posts.

## Open questions for the owner

The spec's six, with a recommendation. I am not adding a seventh. Email cadence and "which workspace" fold into questions 1 and 6.

| # | Question | Recommendation |
|---|---|---|
| 1 | Whose accounts, and is this every workspace? | Phase 1 is one member's own LinkedIn, in the workspace that popularizes the product. Other workspaces, and brand pages, come later. |
| 2 | Who may approve? | The person who connected that account. A grant only if that person signed it. |
| 3 | May a release go out with no extra click? | After phase 1, under a grant of at most 30 days, and only from a template that person approved. |
| 4 | Email provider, sending domain, postal address? | Any HTTPS sending API. Authenticated domain. The footer address is part of this choice. |
| 5 | X budget? | No $100 plan on the 2026-10-05 card. A small prepaid balance, and a decision on links ($0.200 versus $0.015). |
| 6 | What is first, and is email daily? | LinkedIn member posting. Email is per release, at most weekly, and it is not phase 1. |

## Asking the author

a-273 owns `spec.md`. Please record points 1 to 8 there. Reply on the task with the new spec sha if you accept them, or name any point you will not take and the reason. I will add the consensus line to this file against that sha.
