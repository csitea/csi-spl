# 090 marketing automation: claude-b opinion

**Reviewer**: c-292 (claude-b) · **Topic**: `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`
**Reviewed**: `spec.md` v0.2.0, last changed at `755e8623` (origin/master `31c04371`), 2026-10-05.

Platform facts below are from my knowledge as of mid-2026, not re-measured
against each vendor's live docs. Prices and limits move often; whoever builds a
channel re-checks that channel's terms first.

## 1. Verdict

I agree with the core of the spec: **delegated posting, not impersonation**.
The person connects their own account through the platform's OAuth, sees what
is held, can revoke it, and every post is approved and audited. That is the
only reading of owner msg `1c305ead` that does not break a platform's terms,
and I would not change it.

I would change the things in section 2 before implementation starts. The most
important: a separate append-only audit table, tokens under the same FORCE RLS
as every other workspace row, a narrow standing grant, and a smaller phase 1.

## 2. What I would change

### 2.1 Platform API reality (spec §3, §5)

| Channel | What the spec says | What I would write |
|---|---|---|
| LinkedIn, person | `w_member_social`, supported | Agree. Self-serve "Share on LinkedIn" product. Member tokens last about 60 days and refresh tokens are not given to every app, so plan a **re-consent reminder** before expiry, not a silent failure. |
| LinkedIn, company page | not covered | Needs `w_organization_social` through the Community Management API: app review and a verified legal entity. Weeks, not days. Keep it out of phase 1. |
| X | "requires paid tier, Basic $100/mo minimum" | Do not state a price as fact. X has changed its API pricing several times (free write-only tier with a small monthly cap, then Basic, then pay-per-use). One post a day is about 30 a month, which a write-only tier has historically covered. Make it an owner question with "verify the current price", not a design constraint. |
| Facebook | Pages only | Agree. Personal profile publishing has been gone since 2018. `pages_manage_posts` needs Meta app review **and** business verification. Not phase 1. |
| Rate limits | one line each | Fine. At 1 post/day/channel we sit far below every limit; the real failure modes are **expired tokens and app-review rejections**, so AC-06 should name those first. |

### 2.2 Consent, revoke and audit (spec §2, FR-005, §11)

- FR-005 says "immutable audit log", but §11 keeps the audit fields on
  `marketing_posts`, a row that is updated as its status changes. Add a
  separate **append-only** `marketing_audit` table (insert only; no UPDATE or
  DELETE grant to the app role): connect, revoke, grant created or ended,
  draft, edit, approve, reject, publish, fail. Each row: actor (human or agent
  id), a hash of the exact body, channel, grant id if any, platform post id.
- **Disconnect** (AC-02): delete our copy of the token at once, and call the
  platform's revoke endpoint where one exists. Not every platform offers one,
  so the WUI also tells the person how to remove the app on the platform side.
- A **standing grant** (FR-004) must be narrow and finite: one person, one
  channel, one content kind (release announcement from the template only, not
  free text), an expiry (I suggest 30 days), revocable, and its id written on
  every post it published. Per-post approval stays the default.
- The approver of a post published in a person's name is **that person**, or a
  grant that person signed. A workspace admin must not approve a post into
  someone else's personal feed. This answers half of the spec's open question 2.

### 2.3 How the daily content is produced (spec §3 "Content", US3)

- Sources, in order: the release notes table (spec 065, a new `v<X.Y.Z>`),
  then the help docs (`csi-spl-doc/doc/help/*.md`) as a queue of "one way to
  use the hub" tips, one per day, no tip repeated within a set window.
- An agent writes the draft; a human approves it in the WUI. The draft keeps a
  link to its source (release tag or help file path) so the reviewer can check
  every claim against it.
- **No source, no post.** On a day with no new release and no unused tip, the
  system skips the day. It never invents filler to keep a streak; that is what
  owner msg `fd72a794` forbids.

### 2.4 Scheduling (spec §4, FR-006, AC-04, AC-08)

- Agree with the cap of one post per day per channel and with staggering.
- Add: the dispatcher is **idempotent**: one publish attempt per post id, the
  attempt recorded before the platform call, so a retry or a second dispatcher
  instance never posts twice. A double post is the most visible spam signal.
- Add: each channel has a posting time and time zone; "per day" means that
  zone's calendar day.
- Calendar (spec 089) shows scheduled posts: agree.

### 2.5 Email (spec §2.4, §5, FR-007)

- Agree: opt-in only, unsubscribe without login, sender authentication.
- Change: **double opt-in** (a confirmation link), so nobody is subscribed by
  someone else typing their address. Store the confirmation time.
- Change: send from **one verified sending subdomain per workspace**, with the
  person's name as the display name if wanted, rather than "the person's own
  domain". Verifying every person's domain is heavy and gains nothing.
- Add: the RFC 8058 one-click `List-Unsubscribe-Post` header (large mailbox
  providers require it from bulk senders), bounce and complaint webhooks that
  set `bounced` or `unsubscribed`, and a send stop when complaints pass 0.1%.
- Change: **email is not daily.** A daily social post is fine; a daily email
  to the same list reads as spam. I suggest one email per release, or a weekly
  digest at most. Owner question.
- Provider: this estate runs on GCP, which has no native bulk mail sender, so
  it is a third-party provider either way. Owner question (the spec has it).

### 2.6 Secrets (spec §6, FR-003)

- One Secret Manager secret per person per channel turns Secret Manager into a
  per-user data store, outside the RLS that guards every other workspace row,
  and the hub service account can read all of them anyway.
- I would rather keep the token as **ciphertext in Postgres**, encrypted with a
  Cloud KMS key (envelope encryption), in a row under the same workspace RLS.
  One isolation mechanism, not two. Terraform manages the KMS key, never a
  token.
- Either way, keep the spec's rules: never in git, logs, terminal output,
  spool messages or terraform state; errors carry a redacted form only.
- I can live with Secret Manager if a-273 prefers it, as long as code checks
  the workspace on every read and a test proves a second workspace cannot read
  the first one's token.

### 2.7 Per-workspace storage with FORCE RLS (spec §11)

- §11 has `workspace_id` on every table but no RLS. Every marketing table
  (channels, posts, subscribers, audit) gets `ENABLE` **and** `FORCE ROW LEVEL
  SECURITY` with the workspace policy the hub store already uses, plus a
  fail-closed test like the store's existing RLS tests.
- Small fixes to the sketch: the `CHECK (... IN (linkedin, x, ...))` lists need
  quoted literals, and `DEFAULT {}` should be `DEFAULT '{}'`. `ON DELETE
  CASCADE` from channel to posts would delete evidence when a channel is
  removed: use a `revoked` status instead of a delete.

### 2.8 A small phase 1

1. **LinkedIn, one person, personal feed** (self-serve scope, no app review).
2. Drafts from release notes (spec 065) and help-doc tips, per-post approval
   in the WUI, no standing grant yet.
3. Audit table, daily cap, idempotent dispatcher, tokens encrypted under RLS.

Phase 2: email (after the provider choice), then the standing grant.
Phase 3: X (after the price check) and Facebook or LinkedIn pages (after app
review).

## 3. Open questions for the owner

1. **Whose accounts?** Your own personal LinkedIn first, a Spool Hub brand page,
   or both? A brand page needs company-page app review.
2. **Email cadence**: one email per release or a weekly digest, given that the
   daily rule is for social posts?
3. **Email provider**, and the sending subdomain to verify.
4. **X budget**: approve whatever the current write tier costs, once checked,
   or defer X to phase 3?
5. **Standing grant**: may release announcements go out without a click,
   under a 30-day grant you sign, or does every post need your approval?

## 4. Consensus

Round 1: a-273 took all nine points into v0.3.0 (`8da4613e`). Round 2 asked
for two text fixes: the approver rule in §2.3 contradicted FR-005, and the
appendix SQL had unquoted literals and no RLS policy. Both are fixed in v0.3.1.
The owner questions are in spec §11.

Consensus reached at `350e2b9b0a57b0a9074f706cd14dcb08a0753ad1` (spec v0.3.1).
