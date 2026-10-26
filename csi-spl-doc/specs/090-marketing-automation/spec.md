# 090: Marketing Automation (delegated social and email posting)

**Feature ID**: `090-marketing-automation` · **Milestone**: M4 · **Status**: Consensus (v0.5.0)  
**Created**: 2026-10-05 · **Updated**: 2026-10-26 (v0.5.0 Meta publishing, Viber/WhatsApp evaluations, draft handover) · **Lane**: a-273 (v0.1-v0.3), c-286 (v0.3.3), c-334 (v0.4.0), a-292 (v0.5.0) · **Topics**: `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`, `69b50b6c-4c6d-401e-8bf0-b325b3abe53a`, `55fd7531-5079-43c2-af38-ea0bf3692d4f`, `44a37f81-e98f-49ee-9374-970a3e7ef592`, `665401a9-bd36-46b5-8c5b-39c134669e53`  
**Authority**: this file for behaviour and requirements. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4). Organised as unified specification sections (§1–§21), with implementation tasks in `tasks.md` and owner app setup guide in `meta-app-setup.md`.

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, task lifecycle)
- [005 WUI](../005-spool-wui/spec.md) (Slack-like interface, layout, theming)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles and permissions)
- [065 release notes table](../065-release-notes-table/spec.md) (release version tags `v<X.Y.Z>`)
- [089 calendar section](../089-calendar-section/spec.md) (time coordination and scheduled events)

`<BASE_DOMAIN>`, `<workspace_id>`, `<human_id>`, `<agent_id>`, and `<env>` are placeholders. No estate value appears as a literal to copy.  
Per the owner's rule, this specification uses the term **workspace** throughout and avoids legacy tenancy terms.

---

## 1. Why and The Owner's Ask

Marketing automation enables the Spool Hub to publicize releases, new features, short tips, and product demos across social networks and email without repetitive manual authoring and posting.

The owner defined the requirement in topic `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`:

1. Owner HUM-10, msg `c66b267a`:
   > "We need to start a discussion for building the specifications for a broader feature for automating marketing that is posting to LinkedIn, X, Facebook, and social media, and also on emails, to popularize the Spool Hub."

2. Owner HUM-10, msg `1c305ead`:
   > "The system should be able to impersonate a specific person and send or make posts on behalf of this person in an automated fashion."

3. Owner HUM-10, msg `fd72a794`:
   > "The aim is not to be spamming anyone. The aim is to have scheduled posts every day, which bring the new features and the new ways to use the Spool Hub system."

4. Owner HUM-10, msg `c6daa209`:
   > "Did you reach a consensus? At least one AGI, at least one Gobot, and a couple of Claude agents should reach a consensus on this specification first. After that, you can start with the implementation."

5. Owner HUM-10, msg `e76278e3`:
   > "once you reach consensus start wit hthe implemetation , no need for go from me - I will reveal the result and iterate from there ..."

Per the owner's standing preference ("present me with simple specs"), this document delivers a clean, focused specification aligned across the author and review panel.

---

## 2. Core Architectural Principle: Delegated Posting with Consent

To comply with platform policies and protect account reputation, posting "on behalf of a person" is framed strictly as **delegated posting with consent**, rather than credential impersonation or browser session hijacking:

1. **Official OAuth 2.0 Authorization**:
   - The user connects their own account once through each platform's standard OAuth flow (e.g. LinkedIn Member Posting, X User Context, Meta Graph API).
   - The system never asks for, stores, or handles user account passwords.
2. **Explicit Consent & Granular Revocation**:
   - The user clearly sees what permissions the system holds.
   - **Disconnect**: Deletes our local token record immediately and calls the platform's revocation endpoint where supported; the WUI also displays direct instructions for removing the app in that platform's settings.
   - **Token Expiry**: LinkedIn member tokens expire after ~60 days with no automatic refresh; the system sends a re-consent notification 7 days prior to expiration.
3. **Approval Authority & Standing Grants**:
   - **Per-Post Approval (Default)**: For personal feeds, only the member who connected the personal account (or their explicit standing grant) may approve. A designated workspace reviewer may edit and recommend drafts, but publishing into a personal feed strictly requires the account holder's click or grant. A workspace admin cannot unilaterally publish into someone else's personal feed.
   - **Standing Delegation**: Narrow, finite, and revocable. Strictly bounded: one person, one channel, release announcement template only (no free text), maximum 30-day lifetime, with an active grant ID logged on every post.
4. **Authentic Attribution & Immutable Audit Trail**:
   - Every post is published in that person's own name, from their authentic account.
   - An append-only audit log records every event: channel connect, revoke, draft, edit, approve, reject, dispatch, publish, and failure.
5. **Email on Behalf of a Person**:
   - Outbound marketing emails are sent from a **verified workspace subdomain** (e.g. `mail.<BASE_DOMAIN>`) authenticating SPF, DKIM, and DMARC.
   - The person's name is used as the friendly display name, and their address is set as `Reply-To`. (Sending directly from a personal third-party email domain fails DMARC).

---

## 3. Channels, Platform Realities & Constraints

| Channel | Delegation Mechanism | API Reality & Constraints | Phase |
|---|---|---|---|
| **LinkedIn (Member)** | OAuth 2.0 (`w_member_social`) | Personal profile feed. Self-serve, free, no app review required. ~60-day token lifetime, no refresh token; re-consent reminder required. | **Phase 1** |
| **Email Newsletter** | Transactional Provider (SMTP / API) | Authenticated workspace subdomain with SPF/DKIM/DMARC. Double opt-in, RFC 8058 one-click headers, bounce/complaint suppression. | Phase 2 |
| **Facebook Pages** | Meta Graph API (`pages_manage_posts`, `pages_read_engagement`, `pages_show_list`) | **Facebook Pages only** (personal profiles barred). Requires Meta Business App Review & Business Verification. Page Access Token has no expiration. | **Phase 3a** |
| **Instagram Professional** | Meta Graph API (`instagram_content_publish`, `instagram_basic`) | **Instagram Business/Creator accounts** linked to a Facebook Page. 2-step media container publishing. Max 25 posts/24h, 400 containers/24h. | **Phase 3a** |
| **Draft Handover (Manual)** | WUI Handover Card (clipboard + asset pack) | Direct customer control (HUM-23). 1-click caption copy, asset selector/download, deep link open. Zero external API credentials required. | **Phase 3b** |
| **Viber / WhatsApp Pre-fill** | Client Deep Links (`viber://forward`, `wa.me/?text=`) | One-click prefill links. Author taps send in app. Does not preselect channel/group; zero server tokens needed. | **Phase 3b** |
| **LinkedIn (Company)** | OAuth 2.0 (`w_organization_social`) | Company brand page. Requires LinkedIn Community Management API access, business verification, and formal app review (weeks). | Phase 4 |
| **X (Twitter)** | OAuth 2.0 PKCE (`tweet.write`) | Pay-per-use / developer tier with prepaid credits (vendor card checked 2026-10-05: ~$0.015 per post, ~$0.200 with link). Live price verified at build time. Rotating refresh tokens. | Phase 4 |

*Note on Reach Metrics*: Public post URLs and published status are recorded in Phase 1. API reach analytics (impressions, clicks) are best-effort where exposed without extra paid tiers, and deferred from Phase 1.

---

## 4. Anti-Spam Policy, Content Queue & Cadence Rules

Per owner msg `fd72a794` (*"The aim is not to be spamming anyone. The aim is to have scheduled posts every day..."*), the system enforces strict cadence controls:

1. **Daily Frequency Cap**:
   - Strict maximum of **one scheduled automated post per day per channel** (e.g. 1 on LinkedIn).
   - "Per day" is evaluated against the calendar day of the workspace's configured time zone.
2. **Source-Backed Content Queue ("No Source, No Post")**:
   - Every draft post must link directly to an authentic source:
     - Official release version tag from `release_notes` (spec 065 `v<X.Y.Z>`).
     - Product usage tips and demos drawn from verified documentation (`csi-spl-doc/doc/help/*.md`).
   - If there is no new release and no unused documentation tip, **the day is skipped**. The system never generates hallucinated or repetitive filler copy to meet a quota.
   - No duplicate posts: identical text is never dispatched twice to the same channel.
3. **Stale Draft Expiry**:
   - A draft post that sits unapproved for more than 7 days is marked stale and returned to the review queue rather than posting obsolete news.
4. **Idempotent Single-Flight Dispatcher**:
   - A scheduled worker claims a due post via a row transition (`approved` -> `scheduled` -> `published`) before calling the external platform API.
   - Retries back off cleanly and stop after 3 attempts, preventing duplicate public broadcasts.

---

## 5. Email Marketing Standards & Compliance

1. **Double Opt-In**:
   - Subscription requires email address confirmation via an activation link. The subscription record captures `opt_in_at` and `confirmed_at` timestamps as legal proof of consent.
2. **One-Click Unsubscribe (RFC 8058)**:
   - Outbound marketing emails include both the `List-Unsubscribe` header and the RFC 8058 `List-Unsubscribe-Post: List-Unsubscribe=One-Click` header.
   - Unsubscribing requires no login and takes effect immediately.
3. **Reputation & Delivery Protection**:
   - Bounce and complaint notifications via provider webhooks immediately mark addresses as `bounced` or `unsubscribed`.
   - Dispatch automatically halts if spam complaint rates exceed 0.1% (well below the 0.3% mailbox provider threshold).
4. **Email Cadence**:
   - While social posts may publish daily, **email is never daily**. Outbound newsletters are sent strictly per release milestone or as a weekly digest.

---

## 6. Security, Secrets & Per-Workspace Storage

1. **Token Storage in PostgreSQL under FORCE RLS**:
   - Connected user tokens are stored as **ciphertext in a PostgreSQL table** (`marketing_channel_tokens`), encrypted using Cloud KMS envelope encryption.
   - Follows the established pattern in `0091_member_activity.sql`: tokens inherit strict workspace row-level security.
   - Database dumps without access to the Cloud KMS key reveal zero credentials.
2. **Secret Manager Scope**:
   - Secret Manager stores only static, project-wide platform application credentials (OAuth client IDs and client secrets).
3. **Strict Zero Leakage**:
   - Plaintext tokens are never written to logs, terminal output, git commits, or spool messages.
   - Plaintext tokens are decrypted strictly in memory by the background dispatcher immediately prior to API invocation and are never exposed over public APIs.

---

## 7. Phased Implementation Plan

- **Phase 1: Single-Channel Member Loop (Immediate Focus)**
  - Scope: Spool Hub project workspace.
  - Channel: LinkedIn personal member feed (`w_member_social`, self-serve, free).
  - Workflow: Queue fed by release notes (spec 065) and help docs; per-post approval in WUI (no standing grant).
  - Security & Infrastructure: KMS envelope-encrypted tokens in PostgreSQL under FORCE RLS, append-only `marketing_post_events` audit table, idempotent single-flight dispatcher, 1 post/day cap, 60-day token expiry reminder.
- **Phase 2: Email Newsletter & Standing Grants**
  - Hosted transactional email provider with double opt-in, RFC 8058 headers, webhook suppression.
  - Release-based email cadence (weekly / per-release).
  - 30-day standing delegation grant for routine release announcements.
- **Phase 3a: Meta Graph API Publishing (Facebook Pages & Instagram Professional)**
  - Scope: Any allow-listed workspace with business social accounts.
  - Channels: Facebook Page feed (`POST /{page-id}/feed`) and Instagram Professional Content Publishing API (2-step container creation `POST /{ig-user-id}/media` and `POST /{ig-user-id}/media_publish`).
  - Auth & Security: Meta OAuth app (`pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish`), long-lived user token exchange, non-expiring Page Access Token storage sealed in KMS envelope under FORCE RLS.
  - Controls: Per-post human approval, daily cap enforcement, Instagram 25 posts/24h rate limit guard.
  - Owner Gates: Meta Business Portfolio verification, Developer App creation, App Review submission.
- **Phase 3b: Customer Manual Draft Handover & Messaging Deep Links**
  - Scope: Workspaces where owners prefer manual control (HUM-23) or messaging broadcast.
  - Customer Handover: WUI card with 1-click caption copy, photo download pack, and direct app launcher buttons. Status marked `published` (manual).
  - Messaging Pre-fills: 1-click deep links for Viber (`viber://forward?text=`) and WhatsApp (`https://wa.me/?text=`).
- **Phase 4: Brand Pages & Extended Platforms**
  - X (Twitter) posting integration with live pay-per-use price verification.
  - LinkedIn Organization (Company) Page posting via Community Management API.
  - Viber Channels 1-Way Post API for high-volume broadcast channels.

---

## 8. User Stories

| ID | Role | Story | Benefit |
|---|---|---|---|
| **US1** | Member | Connect my LinkedIn account via OAuth in workspace settings | Enables Spool Hub to publish on my behalf safely without credential sharing |
| **US2** | Author | Receive a re-consent reminder before my 60-day LinkedIn token expires | Prevents unexpected dispatch failures and maintains continuous service |
| **US3** | Agent | Draft a daily tip from help docs or an announcement from a `v<X.Y.Z>` release tag | Automates marketing copy generation directly from verified project sources |
| **US4** | Reviewer | Review, edit, approve, or reject draft posts in the WUI | Ensures tone, formatting, and quality before public broadcast |
| **US5** | Member | View scheduled marketing posts in the Calendar (spec 089) | Visualizes upcoming marketing outreach alongside deployment events |
| **US6** | Subscriber | Confirm subscription via double opt-in and unsubscribe in one click | Protects subscriber privacy and complies with international anti-spam standards |

---

## 9. Functional Requirements & Acceptance Matrix

### 9.1 Functional Requirements

- **FR-001**: System shall provide OAuth 2.0 connection flow for LinkedIn personal profile posting (`w_member_social`).
- **FR-002**: System shall store user tokens as KMS envelope-encrypted ciphertext in PostgreSQL under `FORCE ROW LEVEL SECURITY`.
- **FR-003**: System shall store platform application client credentials in Secret Manager.
- **FR-004**: System shall maintain an append-only `marketing_post_events` table (INSERT and SELECT only for application role).
- **FR-005**: System shall enforce that only the connected account owner (or their narrow grant) may approve posts to their personal feed.
- **FR-006**: System shall maintain a source-backed content queue drawing from release notes and help articles, enforcing "no source, no post".
- **FR-007**: System shall enforce a hard daily frequency cap of at most one automated post per day per channel based on workspace time zone.
- **FR-008**: System shall track post status in strict lifecycle order: `draft` -> `approved` -> `scheduled` -> `published` (or `failed` / `rejected`).
- **FR-009**: System shall implement an idempotent single-flight dispatcher that claims posts via atomic state transition prior to platform dispatch.
- **FR-010**: System shall display scheduled marketing posts on the Calendar (spec 089) with bidirectional time synchronization.
- **FR-011**: Outbound marketing email shall use verified workspace subdomains, double opt-in verification, and RFC 8058 one-click unsubscribe headers.

### 9.2 Acceptance Scenarios

- **AC-01 (OAuth Connection)**: Member clicks "Connect LinkedIn" -> completes OAuth consent -> system stores ciphertext token in `marketing_channel_tokens` -> UI displays connected status and token expiry date.
- **AC-02 (Delegation Revocation)**: Member clicks "Disconnect" -> platform revoke endpoint called if supported -> token ciphertext purged -> channel status updated to `revoked` -> pending drafts canceled.
- **AC-03 (Source-Backed Drafting)**: Agent generates draft from release `v1.4.0` -> draft records source tag -> reviewer edits and approves -> post status moves to `approved`.
- **AC-04 (Calendar Linkage)**: Post scheduled for release date appears on `/calendar`; adjusting time in Calendar updates post `scheduled_for`.
- **AC-05 (Single-Flight Dispatch)**: At scheduled hour, background worker claims post -> status moves to `scheduled` -> dispatches to LinkedIn -> receives success ID -> status becomes `published` with post link.
- **AC-06 (Failure & Token Expiry)**: If token is expired or API fails -> status marked `failed`, diagnostic recorded in audit table, and notification sent to author.
- **AC-07 (Anti-Spam Daily Cap)**: Two posts approved for the same channel on the same day -> system schedules the first for today and staggers the second to the next calendar day.
- **AC-08 (Stale Draft Cleanup)**: A draft pending approval for >7 days keeps status `draft` (there is no separate stale or expired state), gets a `draft_stale` audit event, and its reviewer and the account holder are told. It is never scheduled or published until it is edited and approved again, and the daily queue skips it.
- **AC-09 (Email Double Opt-In & Unsubscribe)**: Subscriber enters email -> receives confirmation link -> clicks link -> status becomes `subscribed`. Clicking unsubscribe header or link immediately sets status to `unsubscribed`.

---

## 10. What is NOT in Scope

1. **Password-Based Impersonation**: Handling or storing user passwords or session cookies.
2. **Fake or Sock-Puppet Accounts**: Creating, managing, or automating unverified bot accounts.
3. **Browser Scraping & Headless Automation**: Using browser drivers (e.g. Puppeteer) to bypass official APIs or ToS.
4. **Facebook Personal Profile Automation**: Posting to personal Facebook profiles (prohibited by Meta API; only Facebook Pages are supported).
5. **Instagram Personal Profile Automation**: Posting to personal Instagram profiles (Meta API supports only Instagram Professional Business/Creator accounts linked to a Facebook Page).
6. **Unofficial Messaging Automation**: Unofficial reverse-engineered APIs for WhatsApp or Viber (violates ToS, risks number bans). WhatsApp and Viber use official client-side deep links or official partner APIs.
7. **Cold / Unsolicited Email Blasts**: Sending marketing emails to individuals who have not explicitly double opted-in.
8. **Two-Way Social CRM**: Managing inbound comments, mentions, or direct messages inside the Spool WUI.
9. **Reach Analytics in Phase 1 & Phase 3a**: Paid API metrics and engagement dashboards (deferred).

---

## 11. Open Questions for the Owner (Max 6)

*Informational questions; per owner instruction (msg `e76278e3`), implementation of Phase 1 proceeds without waiting for answers.*

1. **Workspace Scope**: Is marketing automation initially built for the Spool Hub project workspace to market the product, or multi-workspace from day one? (Phase 1 assumes project workspace first).
2. **Target Accounts**: Should marketing in Phase 1 focus solely on the founder's personal LinkedIn profile, or should company brand pages be queued for Phase 3?
3. **Email Cadence & Schedule**: Confirm that social posts are daily (max 1/day) but email newsletter is sent per release milestone or weekly digest.
4. **Email Delivery Provider**: Which transactional email provider should be provisioned for Phase 2 (e.g. AWS SES, Postmark, SendGrid), and what sending subdomain (e.g. `mail.<BASE_DOMAIN>`)?
5. **Physical Postal Address**: What official business address should be populated in the CAN-SPAM compliant email footer?
6. **Standing Delegation Expiry**: Confirm the 30-day maximum lifetime for standing delegation grants covering routine release announcement templates.

---

## 12. Appendix: Data Model Reference (PostgreSQL with FORCE RLS)

*Architectural reference for Phase 1 implementation; this specification builds no database tables.*

```sql
-- Connected marketing channels
CREATE TABLE marketing_channels (
    channel_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    platform        text NOT NULL CHECK (platform IN ('linkedin', 'x', 'facebook', 'email')),
    account_name    text NOT NULL,
    account_type    text NOT NULL CHECK (account_type IN ('personal', 'page', 'newsletter')),
    delegated_by    text NOT NULL, -- human user ID
    auto_publish    boolean NOT NULL DEFAULT false,
    status          text NOT NULL CHECK (status IN ('active', 'revoked', 'expired')),
    expires_at      timestamptz NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- KMS envelope-encrypted channel tokens
CREATE TABLE marketing_channel_tokens (
    channel_id      uuid PRIMARY KEY REFERENCES marketing_channels(channel_id),
    workspace_id    text NOT NULL,
    ciphertext      text NOT NULL,
    kms_key_id      text NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Drafted and dispatched marketing posts
CREATE TABLE marketing_posts (
    post_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    channel_id      uuid NOT NULL REFERENCES marketing_channels(channel_id),
    source_type     text NOT NULL CHECK (source_type IN ('release', 'help_doc')),
    source_ref      text NOT NULL, -- release tag v<X.Y.Z> or help doc path
    content_text    text NOT NULL,
    media_urls      text[] NOT NULL DEFAULT '{}',
    status          text NOT NULL CHECK (status IN ('draft', 'approved', 'scheduled', 'published', 'failed', 'rejected')),
    author_type     text NOT NULL CHECK (author_type IN ('human', 'agent')),
    author_id       text NOT NULL,
    approved_by     text NULL,
    standing_grant_id uuid NULL,
    scheduled_for   timestamptz NULL,
    published_at    timestamptz NULL,
    platform_post_id text NULL,
    platform_url    text NULL,
    last_error      text NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Append-only audit log (INSERT and SELECT only for application role)
CREATE TABLE marketing_post_events (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    post_id         uuid NULL REFERENCES marketing_posts(post_id),
    channel_id      uuid NOT NULL REFERENCES marketing_channels(channel_id),
    event_type      text NOT NULL CHECK (event_type IN ('channel_connect', 'channel_revoke', 'draft_created', 'post_edited', 'post_approved', 'post_rejected', 'draft_stale', 'post_scheduled', 'post_dispatched', 'post_published', 'post_failed')),
    actor_type      text NOT NULL CHECK (actor_type IN ('human', 'agent', 'system')),
    actor_id        text NOT NULL,
    standing_grant_id uuid NULL,
    body_sha256     text NULL,
    platform_post_id text NULL,
    details         jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Double opt-in email newsletter subscribers
CREATE TABLE marketing_email_subscribers (
    subscriber_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    email           text NOT NULL,
    status          text NOT NULL CHECK (status IN ('pending_confirmation', 'subscribed', 'unsubscribed', 'bounced')),
    opt_in_at       timestamptz NOT NULL DEFAULT now(),
    confirmed_at    timestamptz NULL,
    opt_in_ip       text NULL, -- masked or omitted for privacy
    unsubscribed_at timestamptz NULL,
    UNIQUE (workspace_id, email)
);

-- Strict Row Level Security with Workspace & Operator Isolation Policies
-- (Matches csi-spl-rdb/src/sql/postgres/spool-hub/0091_member_activity.sql shape;
-- note: workspace_id in this prose sketch corresponds to the hub database tenant_id column)
ALTER TABLE marketing_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_channels FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_scope ON marketing_channels
    USING (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_channels
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_channel_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_channel_tokens FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_scope ON marketing_channel_tokens
    USING (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_channel_tokens
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_posts FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_scope ON marketing_posts
    USING (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_posts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_post_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_post_events FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_scope ON marketing_post_events
    USING (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_post_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_email_subscribers ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_email_subscribers FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_scope ON marketing_email_subscribers
    USING (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (workspace_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_email_subscribers
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

---

## 13. Consensus Section (agy author `a-273`, grok peer `g-276`, claude peers `c-277` & `c-292`)

Per owner msg `c6daa209` (*"At least one AGI, at least one Gobot, and a couple of Claude agents should reach a consensus on this specification first."*), the four-agent panel conducted review on topic `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`.

### 13.1 Panel Participants
- **Author**: `a-273` (Antigravity)
- **Reviewer (Grok)**: `g-276` (Opinion: `grok-opinion.md`, commits `01c9618e7`, `20fe85a67`)
- **Reviewer (Claude-A)**: `c-277` (Opinion: `claude-a-opinion.md`, commits `8ba3c6e5c`, `537b7e5b7`)
- **Reviewer (Claude-B)**: `c-292` (Opinion: `claude-b-opinion.md`, commit `f7d9acae6`)

### 13.2 Consensus Statement: Full Agreement Reached
Following Round 1 review, author `a-273` and reviewers `g-276`, `c-277`, and `c-292` reached **unanimous architectural consensus** on all eight core points:

1. **Delegated Posting with Consent**: Unanimously affirmed. No password storage, no session scraping. Revocation purges local token and calls platform revoke endpoint.
2. **Append-Only Audit & Approver Authority**: Dedicated immutable `marketing_post_events` table (INSERT/SELECT only). No cascade delete. The personal feed approver is strictly the connected account holder or their narrow grant.
3. **KMS Envelope-Encrypted Token Storage**: User tokens stored as KMS ciphertext in PostgreSQL rows under `FORCE ROW LEVEL SECURITY`, matching `0091_member_activity.sql`. Platform app client secrets remain in Secret Manager.
4. **Finite Standing Grants**: Narrow 30-day lifetime, release announcement templates only, explicit grant ID logged on each post.
5. **Dynamic Platform Realities**: X pricing verified as pay-per-use on vendor pricing card ($0.015/post, $0.200 with link); live price verified at build time. LinkedIn member tokens last ~60 days with re-consent reminder. Facebook Pages only (`pages_manage_posts`, `pages_show_list`).
6. **Anti-Spam & Source-Backed Queue**: Hard daily cap of at most 1 post/day/channel. Queue strictly drawn from release notes (spec 065) and help documentation (`csi-spl-doc/doc/help/*.md`). "No source, no post" (quiet days send nothing, zero filler). Stale drafts >7 days returned to reviewer.
7. **Email Standards**: Authenticated workspace subdomain (not personal gmail domains) with personal display name and Reply-To. Double opt-in with timestamp, RFC 8058 one-click headers, bounce/complaint webhooks. Cadence is per release or weekly, never daily.
8. **Phased Rollout**: Phase 1 limited to LinkedIn personal feed for the Spool Hub project workspace, human click approval, no standing grant, no reach metrics. Phase 2 introduces email newsletter and standing grants. Phase 3 introduces X and brand pages.

### 13.3 Disputed Points
- **None**. All items resolved and aligned across all four panel participants.

---

## 14. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-05 | a-273 | Initial draft specification for marketing automation (delegated social and email posting). |
| v0.2.0 | 2026-10-05 | a-273 | Folded owner msg `fd72a794` into spec: added anti-spam policy with strict 1 post/day/channel cap, high-signal focus, FR-009, and AC-08. |
| v0.3.0 | 2026-10-05 | a-273 | Full panel consensus harmonized with grok peer `g-276` (`grok-opinion.md`) and claude peers `c-277` (`claude-a-opinion.md`) and `c-292` (`claude-b-opinion.md`): append-only audit table, KMS envelope-encrypted tokens under FORCE RLS, dynamic X pricing, double opt-in email, source-backed queue ("no source, no post"), idempotent single-flight dispatcher, 3-phase rollout, and formal Consensus section. |
| v0.3.1 | 2026-10-05 | a-273 | Round 2 consensus refinements: aligned personal feed approval authority in §2.3 with FR-005, clarified AC-08 stale draft rejection, quoted SQL enum/array literals, and added workspace isolation RLS policies in appendix data model. |
| v0.3.2 | 2026-10-05 | a-273 | Harmonized appendix RLS policies with csi-spl-rdb 0091_member_activity.sql shape (NULLIF empty guard on app.tenant_id and operator_scope). |
| v0.3.3 | 2026-10-05 | c-286 | claude-a's third edit, completed: AC-08 no longer uses `rejected` (a final state) for a draft that is sent back. The stale draft stays `draft`, and the `draft_stale` audit event is added. Claude-a's other edits were already in v0.3.1/v0.3.2: quoted SQL literals, per-workspace FORCE RLS policies, and §2.3 matching FR-005. Added the build plan in `tasks.md`. |
| v0.4.0 | 2026-10-05 | c-334 | Added §15, the per-workspace switch (owner msgs `37bcb88b` item 4 and `5cd2e544`): the cnf allow-list AND the db flag `tenants.marketing_enabled`, which defaults off; the flag never widens the list; `all` is supported but unused; the demo workspace is never on. |
| v0.4.1 | 2026-10-14 | c-516 | §15 item 5: the WUI says why Marketing is missing (one line on the switch's `404`, one on the Publish list's `403`) instead of hiding it silently (SPL-1856). |
| v0.5.0 | 2026-10-26 | a-292 | Added §16–§21 for Meta Publishing (Facebook Pages & Instagram Professional Content Publishing API v21.0), customer manual draft handover (HUM-23), Viber API evaluation and one-click deep link feasibility, WhatsApp Cloud API evaluation and one-click deep link feasibility, Meta app setup/review runbook, formats and limits, and updated Phase 3 channels. |

---

## 15. Per-Workspace Switch

Owner HUM-10, msg `37bcb88b` item 4:
> "Make marketing SWITCHABLE per workspace: a workspace admin can turn it on/off at runtime (db flag + workspace settings toggle), with cnf marketing.workspaces as the outer allow-list."

Owner HUM-10, msg `5cd2e544`, on letting dev use "all":
> "well , no even on dev nobody should be spamming LinkedInn on Csitea Oy's behalf"

1. **Effective value**: marketing is on for a workspace only when **both** of these hold:
   - the cnf allow-list `marketing.workspaces` names the workspace, or is the literal `all`. The hub reads it as `SPOOL_HUB_MARKETING_WORKSPACES`.
   - the workspace's database flag `tenants.marketing_enabled` (rdb `0129`) is true.
2. **Default OFF**: the flag starts `false`. A workspace on the allow-list posts nothing until one of its admins turns marketing on.
3. **The flag never widens the allow-list**: outside the list the flag is never read, and every `/v1/marketing` route answers `404`, the switch included. The demo workspace (spec 077) never gets marketing, even under `all`: it gets `403`.
4. **`all`** is supported but no environment sets it: dev is `[t1, <WORKSPACE>]`, prd is `[<WORKSPACE>]`. `all` must stand alone in the list; the hub refuses to start otherwise.
5. **Who may switch**: a member holding `tenant.settings` (the workspace admin), through `GET` / `PATCH /v1/marketing/settings {enabled}`. Anyone else gets `403`. The WUI shows the toggle in Tenant settings -> General. On `404` (outside the allow-list) it shows, instead, one plain line: "Marketing is not available in this workspace." On `403` (not an admin) it hides the toggle. The owner's Publish to LinkedIn list below it shows "Only the workspace owner who connected LinkedIn can publish." on its own `403`, and stays hidden on its `404`, which the switch's line already explains (SPL-1856, owner msg `d657f49d`: a silent gap read as "do I have the wrong role").
6. **Every marketing route honours it**: every later route (T006..T010) is registered through the hub's `marketingRoute` gate, which answers `404` unless the effective value is on. `GET /v1/marketing` is the member probe, and it is `200` only while marketing is on.

---

## 16. Meta Publishing Architecture: Facebook Pages & Instagram Content Publishing

Building on owner instructions (topic `69b50b6c` msg `620011f4` and `55fd7531` msg `914e6d4e`), this section specifies the end-to-end architecture for automated and delegated publishing to **Facebook Pages** and **Instagram Professional accounts** (Business and Creator).

### 16.1 Official Publishing APIs & Endpoints

All calls target Meta Graph API version `v21.0`, evaluated on **2026-10-26**.

#### 16.1.1 Facebook Pages API
- **Target Surface**: Business and Organization Facebook Pages only. Automated posting to personal Facebook profiles was permanently deprecated by Meta on August 1, 2018.
- **Core Endpoints**:
  - `POST https://graph.facebook.com/v21.0/{page-id}/feed` (feed text posts and link preview cards).
  - `POST https://graph.facebook.com/v21.0/{page-id}/photos` (photo posts with captions; parameters: `url`, `caption`, `published=true`).
- **Required Permissions**:
  - `pages_show_list`: Allows the app to list the user's managed Facebook Pages via `GET /me/accounts`.
  - `pages_read_engagement`: Allows reading Page metadata and verifying post delivery.
  - `pages_manage_posts`: Allows creating, scheduling, and publishing content as the Page.
- **Official Documentation URLs (Verified 2026-10-26)**:
  - `https://developers.facebook.com/docs/graph-api/reference/v21.0/page/feed`
  - `https://developers.facebook.com/docs/pages-api/posts`
- **Authentication & Token Hierarchy**:
  - Facebook requires a **Page Access Token** to publish to a Page's feed.
  - Step 1: Member completes Facebook Login -> Hub receives short-lived User Access Token.
  - Step 2: Hub exchanges short-lived User Token for a **Long-Lived User Access Token** (~60 days validity) via:
    `GET https://graph.facebook.com/v21.0/oauth/access_token?grant_type=fb_exchange_token&client_id={app-id}&client_secret={app-secret}&fb_exchange_token={short-lived-user-token}`
  - Step 3: Hub requests user's accounts via:
    `GET https://graph.facebook.com/v21.0/me/accounts?fields=id,name,access_token,tasks,instagram_business_account{id,username,name}`
  - Step 4: When requested using a long-lived User Token, the returned Page Access Token **does not expire** (it remains valid indefinitely until the user changes their password, revokes app permissions, or is removed as Page Admin).

#### 16.1.2 Instagram Professional Content Publishing API
- **Target Surface**: Instagram Professional accounts (Business or Creator) linked directly to a Facebook Page. (Personal accounts lack API access).
- **Mandatory Two-Step Container Publishing Workflow**:
  - **Step 1: Container Creation (`POST /{ig-user-id}/media`)**
    - Parameters:
      - `image_url`: Public HTTPS URL of the media asset (must be publicly reachable by Meta's CDN crawlers; JPEG format required for single images, 8 MB maximum).
      - `caption`: Formatted text with hashtags (maximum 2,200 characters, maximum 30 hashtags).
      - `media_type`: `IMAGE` (or `REELS`, `STORIES`, `CAROUSEL`).
    - Response: `{ "id": "<creation_container_id>" }`.
    - **Container Expiration**: The container ID expires after **24 hours** if not published.
    - **Multi-Image Carousel Support**: For multi-image posts, the dispatcher creates child containers (`POST /{ig-user-id}/media` with `is_carousel_item=true` and `image_url`), collects their IDs, then creates the parent container with `media_type=CAROUSEL` and `children=<child_id_1>,<child_id_2>...`.
  - **Step 1b: Status Verification (`GET /{creation_container_id}?fields=status_code`)**
    - Before triggering publish, the dispatcher polls status code: `FINISHED` (ready), `IN_PROGRESS` (media downloading/transcoding), `ERROR` (failed), or `EXPIRED`. For static images, transition is near-instantaneous (<2 seconds).
  - **Step 2: Media Publishing (`POST /{ig-user-id}/media_publish`)**
    - Parameter: `creation_id=<creation_container_id>`.
    - Response: `{ "id": "<instagram_media_id>" }`.
- **Required Permissions**:
  - `instagram_basic`: Read profile info and connected Instagram account ID.
  - `instagram_content_publish`: Create containers and publish content to Instagram.
  - `pages_show_list` & `pages_read_engagement`: Access the linked Facebook Page metadata to discover the Instagram account.
- **Official Documentation URLs (Verified 2026-10-26)**:
  - `https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/content-publishing`
  - `https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media`
  - `https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media_publish`
- **Rate Limits & API Quotas**:
  - **Publishing Limit**: Strictly **25 API-published posts** per Instagram Professional account within a rolling 24-hour window.
  - **Container Creation Limit**: Maximum **400 media containers** in a rolling 24-hour window.

### 16.2 Account Connection (OAuth & Personal Settings)

Mirroring the LinkedIn personal settings pattern (spec 019 / spec 090 T006):

1. **User Flow**:
   - In WUI (`SettingsDialog.vue` -> Personal Settings -> Social Accounts or Tenant Settings -> Marketing), the user sees "Connect Facebook & Instagram".
   - Initiates `GET /v1/marketing/facebook/connect?workspace=<id>`.
   - The browser redirects to Meta OAuth dialog:
     `https://www.facebook.com/v21.0/dialog/oauth?client_id={app-id}&redirect_uri={redirect-url}&scope=pages_show_list,pages_read_engagement,pages_manage_posts,instagram_basic,instagram_content_publish&state={signed_state}&response_type=code`
   - Signed state (`marketing.State{Tenant, Member, Exp}`) expires in 15 minutes.
2. **Callback Handling (`/api/v1/marketing/facebook/callback`)**:
   - Hub verifies HMAC signature on `state`.
   - Hub exchanges authorization code for user token, exchanges for 60-day user token, and queries `GET /me/accounts` with fields `id,name,access_token,tasks,instagram_business_account{id,username}`.
   - For each authorized Page, the hub discovers:
     - Facebook Page: ID, Page Name, Page Access Token.
     - Linked Instagram Business: ID, Username (if connected to the Page).
   - If multiple Pages are returned, the WUI presents a selection dialog: "Select which Pages and Instagram accounts to connect to workspace <name>".
3. **Token Security & Storage**:
   - Plaintext tokens are **never written to logs, console output, git, or spool messages**.
   - Each Page Access Token is envelope-encrypted using Cloud KMS key (`marketing.kms_key`) via `marketing.Sealer.Seal()`.
   - Ciphertext and KMS Key ID are stored in `marketing_channel_tokens` table under PostgreSQL `FORCE ROW LEVEL SECURITY`.
   - Channel records are created in `marketing_channels` (`platform='facebook_page'` or `platform='instagram_business'`).
   - Disconnecting an account immediately deletes the database row and its encrypted token, and attempts a revocation call to `DELETE https://graph.facebook.com/v21.0/{user-id}/permissions`.

### 16.3 Publishing Approval Pipeline (Draft -> Approve -> Publish)

1. **Strict 4-State Machine**:
   `draft` -> `approved` -> `scheduled` -> `published` (or `failed` / `rejected`).
2. **Per-Post Approval Authority**:
   - Publishing to a Facebook Page or Instagram Business account is strictly gated.
   - Even when `auto_publish` is true for routine release notes, any post featuring external campaign media or custom marketing narratives requires explicit human approval in WUI.
   - For multi-tenant workspaces, only the user who connected the account (or a workspace administrator with `tenant.settings`) may approve publishing.
3. **Single-Flight Dispatcher**:
   - A single-flight background dispatcher claims due posts using atomic Postgres row locking (`FOR UPDATE SKIP LOCKED`).
   - The dispatcher retrieves the KMS-sealed Page Access Token, decrypts it in memory, executes container creation/publishing against Meta Graph API, stores the resulting `platform_post_id` and permalink URL, and marks status as `published`.
   - The decrypted token is wiped from memory immediately upon request completion.

### 16.4 Fallback when No Account Connection Exists

When a workspace does not have an active Meta OAuth connection or when a user prefers manual posting:

1. **Facebook Web Sharer Fallback**:
   - Link format: `https://www.facebook.com/sharer/sharer.php?u=<encoded_blog_url>`
   - **Crucial Platform Reality**: Meta has officially **deprecated and removed** the `quote=` parameter in `sharer.php`. Any text passed in query parameters is silently ignored. Facebook's scraper reads the target URL's Open Graph metadata (`og:title`, `og:description`, `og:image`).
   - WUI Action: The WUI presents a "Share to Facebook" button opening the sharer URL, and provides a 1-click "Copy recommended caption" button so the user can paste additional campaign text into the Facebook web composer.
2. **Instagram Web Fallback**:
   - **Crucial Platform Reality**: Instagram has **NO web share intent URL** (no `instagram.com/share?text=...`). Instagram feed captions also **do not support clickable hyperlinks**.
   - WUI Action: The WUI provides the Customer Draft Handover Card (§17): 1-click "Copy Caption & Hashtags" + "Download Image(s)", with a shortcut button to open `https://www.instagram.com/` or mobile app.

---

## 17. Draft Handover & Customer-Driven Manual Publishing (HUM-23 Input)

Customer HUM-23 (workspace `<CUSTOMER_WORKSPACE>`, msg `2063e977`, verbatim):
> "аз и не искам...аз ще си го постна...все пак трябва да си избера снимки и т.н"  
> *("I do not even want it, I will post it myself, I have to pick the photos etc.")*

### 17.1 Core Principle: Automated Publishing is Opt-In, Never Default

The platform acknowledges that business owners and marketing leads often require creative control over their visual assets, photo selection, and final social copy. Automated API publishing is therefore **strictly opt-in per channel**, and the system defaults to a **Manual Draft Handover** model.

### 17.2 The Draft Handover Workflow

When a marketing campaign, release notice, or customer story is generated:

1. **Agent Preparation**:
   - AI agent prepares:
     - Platform-tailored copy (character-constrained, localized into workspace language).
     - Curated hashtag cluster (relevant to topic, e.g. youth camps, language learning, AI tools).
     - Gallery of candidate images stored in the workspace media bucket (dev/prd GCS buckets).
2. **The WUI Handover Card (`MarketingDraftHandover.vue`)**:
   - **Platform Badges**: Indicates target format (Facebook, Instagram, LinkedIn, Viber, WhatsApp).
   - **Interactive Photo Selector**: Thumbnails of all candidate photos with checkboxes; author can select 1 to 10 images.
   - **Download Button**: "Download Selected Photos" (individual or zipped bundle).
   - **1-Click Copy Caption**: Copies full localized text + hashtags to OS clipboard with instant feedback toast ("Caption copied!").
   - **Platform Launch Buttons**:
     - "Open Instagram Web / App"
     - "Open Facebook Composer"
     - "Open WhatsApp Web / App"
     - "Open Viber Desktop / App"
3. **Status Confirmation ("Mark as Posted Manually")**:
   - Once the owner posts the content, they click "Mark as Posted Manually".
   - The post moves to `published` (or `handed_over`), setting `platform_post_id = 'manual'` and logging audit event `post_handed_over`.
   - Prevents stale queue alerts and avoids duplicate drafting.

---

## 18. Viber Integration Evaluation & One-Click Deep Link Feasibility

Owner Follow-Up (HUM-10, topic `44a37f81`, msg `11574dec-4da9-495c-bf88-83533da0b24b` and `fd1a5764`):
> "evaluate integration with Viber .."  
> "check it is possible to integrate on user level settings the posts to a viber channel or group so that the author could respectively to the LinkedInn just click on a link , get to a draft tab with the post and just click on the post button .."

### 18.1 Evaluation of Official Viber APIs

Evaluated on **2026-10-26** against official documentation on `developers.viber.com`:

| API / Mechanism | Official Doc URL (Read 2026-10-26) | Channel / 1-Way Support | Cost & Commercial Model | Fit with Spool Hub |
|---|---|---|---|---|
| **Viber Channels 1-Way Post API** | `https://developers.viber.com/docs/api/rest-bot-api/#channels-post-api` | **Yes**: 1-way broadcast feed to unlimited subscribers | **Free**: Channel Super Admin uses Channel Auth Token. Requires SSL webhook setup. | **High**: Clean fit for automated 1-way post publishing into a business Viber Channel. |
| **Viber REST Bot API** | `https://developers.viber.com/docs/api/rest-bot-api/` | Partial (2-way chatbot model; messages to subscribers who chatted with bot) | Commercial terms apply for new business bots via partners. | **Low**: 2-way bot is designed for interactive chat, not public broadcasting. |
| **Viber Business Messages** | `https://www.viber.com/en/business/business-messages/` | No (sends to phone numbers, not channels) | **Cost-prohibitive**: Requires official CPaaS partner (Infobip, Dexatel, GMS). Minimum Monthly Commitment (MMC) of **€100 to €175 per month** per active Sender ID, plus €0.02–€0.05/message. | **None**: Completely unfit for social broadcasting. |

### 18.2 One-Click Deep Link Feasibility (The "Just Click Post" Question)

- **Owner Ask**: Can a per-user setting give the author ONE link that opens Viber's composer with the post already filled in (a channel or a group), so the author just presses post?
- **Feasibility Verdict**: **PARTLY**.
- **The Deep Link URI Scheme**:
  - Format: `viber://forward?text=<urlencoded_text>`
  - Official specification: Supported natively on Viber iOS, Android, and Desktop.
- **Can a Target Group or Channel be Preselected?**:
  - **NO**. The Viber URI scheme (`viber://forward`) does **not** accept a `channel_id`, `group_id`, or `chat_id` parameter.
  - When the link is triggered, Viber opens the application and displays a **forward/share picker** containing the user's recent chats, groups, and channels.
  - The author must tap their target Channel or Group, whereupon the prefilled draft appears in the text area, and then press Send.
- **Mobile vs Desktop Behavior**:
  - **Mobile (iOS / Android)**: Works seamlessly. Clicking the link opens native Viber app, prompts channel selection, and pre-fills text.
  - **Desktop (Windows / macOS / Linux)**: Works only if Viber Desktop is installed and the OS has registered the `viber://` protocol handler. If Viber Desktop is not installed, the browser shows a protocol error. Unlike WhatsApp (`wa.me`), Viber does not provide an official universal HTTPS web redirect fallback for generic text prefill.
- **Account Connection Needed?**:
  - **NO**. The deep link operates purely client-side; no server-side bot, token, or account registration is required.
- **Tested Link Example**:
  `viber://forward?text=Spool%20Hub%20Release%20Update%3A%20https%3A%2F%2Fspool-hub.ai%2Fblog%2F2026-10-26-kids-human-experience`

### 18.3 Recommendation:
1. **Phase 3b (Immediate)**: Deliver the **Viber One-Click Deep Link** in WUI Draft Handover. Zero cost, zero API credentials, enables 2-click publishing on mobile and desktop.
2. **Phase 4 (Later)**: If a workspace maintains an official high-volume Viber Channel, implement the **Viber Channels 1-Way Post API** using the Channel Auth Token.
3. **Reject**: Reject Viber Business Messages due to the €100–€175/month minimum commitment per sender ID.

---

## 19. WhatsApp Integration Evaluation & One-Click Deep Link Feasibility

Owner Follow-Up (HUM-10, topic `665401a9-bd36-46b5-8c5b-39c134669e53`, msg `9d7b3868-ea10-49b0-9a14-d27c81bcf4bb`):
> "check it is possible to integrate on user level settings the posts to a WhatsApp Group or group so that the author could respectively to the LinkedInn just click on a link , get to a draft tab with the post and just click on the post button .."

### 19.1 Evaluation of Official WhatsApp APIs

Evaluated on **2026-10-26** against official documentation on `developers.facebook.com`:

- **Official WhatsApp Cloud API**:
  - Doc URL: `https://developers.facebook.com/docs/whatsapp/cloud-api` (read 2026-10-26).
  - Scope: Cloud API is strictly designed for 1-on-1 business messaging, transactional notifications, and customer support with opted-in phone numbers.
  - **Channels Limitation**: Meta's official Cloud API **does NOT support creating or publishing posts to WhatsApp Channels**. WhatsApp Channels are currently managed exclusively via the native WhatsApp mobile/desktop applications.
  - **Unofficial Wrappers**: Unofficial APIs (e.g. headless web scraping) violate WhatsApp Terms of Service and risk immediate, permanent phone number blacklisting. They are prohibited by Spool Hub architecture rules.

### 19.2 One-Click Deep Link Feasibility (The "Just Click Post" Question)

- **Owner Ask**: Can a per-user setting give the author ONE link that opens WhatsApp's composer with the post already filled in (a channel or a group), so the author just presses post?
- **Feasibility Verdict**: **PARTLY**.
- **The Universal HTTPS Share URL**:
  - Format: `https://wa.me/?text=<urlencoded_text>`
  - HTTP Behavior (empirically verified 2026-10-26):
    `https://wa.me/?text=...` returns HTTP 302 redirecting to:
    `https://api.whatsapp.com/send/?text=...&type=custom_url&app_absent=0`
- **Can a Target Group or Channel be Preselected?**:
  - **NO**.
  - `https://wa.me/?text=` opens WhatsApp's universal share sheet ("Share on WhatsApp"). The user must select the destination chat, group, or channel from their WhatsApp contact list.
  - Specifying a phone number (`https://wa.me/<phone>?text=...`) preselects a 1-on-1 chat, but WhatsApp does **not** support preselecting a group ID or channel ID via URL parameters.
  - WhatsApp Group Invite links (`https://chat.whatsapp.com/<invite-code>`) open the group preview to join, but **ignore** any `?text=` parameters.
  - WhatsApp Channel links (`https://whatsapp.com/channel/<channel-id>`) open the channel feed, but **ignore** any `?text=` parameters.
- **Mobile vs Desktop Behavior**:
  - **Mobile (iOS / Android)**: Tapping `https://wa.me/?text=...` immediately launches the native WhatsApp app with the share sheet open and text prefilled.
  - **Desktop**: Opens `api.whatsapp.com`, which presents a clean intermediate landing page ("Share on WhatsApp") with buttons for "Open WhatsApp" (desktop app) and "use WhatsApp Web" (`https://web.whatsapp.com/send?text=...`).
- **Account Connection Needed?**:
  - **NO**. Operates entirely client-side without API keys, phone numbers, or server-side WhatsApp tokens.
- **Tested Link Example (Empirically verified)**:
  `https://wa.me/?text=Spool%20Hub%20Release%20Update%3A%20https%3A%2F%2Fspool-hub.ai%2Fblog%2F2026-10-26-kids-human-experience`
  (Verified via `curl -sIL`: HTTP 302 -> HTTP 200 `content-type: text/html`, title "Share on WhatsApp").

---

## 20. Meta App Setup, Business Verification & App Review Runbook (Owner Steps)

Meta developer integration has strict legal and administrative gates. Setting up Meta apps and submitting for App Review are **OWNER-ONLY** steps requiring organization legal identity and real credentials. Autonomous agents must never attempt to create Meta apps or impersonate the owner.

### 20.1 Owner Prerequisites
1. **Meta Business Account (Business Portfolio)**: Verified business organization in Meta Business Suite (`business.facebook.com`).
2. **Meta Developer Account**: Registered owner account on `developers.facebook.com`.
3. **Organization Verification**: Legal documents (business registration, domain ownership verification, corporate phone number/address) submitted and approved by Meta.

### 20.2 Meta Developer App Configuration
- **App Name**: Spool Hub (or workspace-branded app).
- **App Type**: **Business** (Required for Pages and Instagram Graph APIs).
- **Products Added**:
  1. **Facebook Login for Business** (Configured with OAuth redirect URIs).
  2. **Instagram Graph API**.
- **Authorized Redirect URIs**:
  - Production: `https://<BASE_DOMAIN>/api/v1/marketing/facebook/callback`
  - Development: `https://dev.<BASE_DOMAIN>/api/v1/marketing/facebook/callback`

### 20.3 Secret Manager Slots
Client credentials generated in the Meta Developer Portal are stored in Google Cloud Secret Manager (mirrors LinkedIn T002 layout):
- `csi-spl-hub-marketing-facebook-client-id`
- `csi-spl-hub-marketing-facebook-client-secret`
Injected into Cloud Run hub via cnf flag `marketing.facebook.inject: "true"`.

### 20.4 Meta App Review Submission Package
To graduate from Development Mode (test users only) to Live Mode (any authorized Page admin):
- **Requested Permissions**:
  - `pages_show_list`: To enumerate business Pages.
  - `pages_read_engagement`: To verify published posts.
  - `pages_manage_posts`: To publish feed posts to Facebook Pages.
  - `instagram_basic`: To read linked Instagram account metadata.
  - `instagram_content_publish`: To create media containers and publish posts to Instagram.
- **Review Screencast Requirement**:
  - Owner must provide a 2–3 minute video screencast demonstrating:
    1. Member clicking "Connect Facebook & Instagram" in Spool Hub settings.
    2. Meta OAuth consent dialog showing permissions clearly.
    3. Creation of a draft post in Spool Hub.
    4. Review and approval by the authorized human user.
    5. Successful publish and appearance on the Facebook Page and Instagram feed.
- **Reference Runbook**: Full step-by-step screenshots and submission prompts are documented in [`meta-app-setup.md`](./meta-app-setup.md).

---

## 21. Formats, Character Limits, Media Constraints, Failure & Retry Policies

### 21.1 Cross-Platform Content & Formatting Comparison

| Platform | Text / Caption Cap | Media Constraints | Hyperlink Behavior | Tagging & Hashtags |
|---|---|---|---|---|
| **Facebook Pages** | 63,206 chars | Single/multi image: JPEG, PNG, GIF, WebP. Recommended 1200x630 (1.91:1) or 1080x1080 (1:1). Max 10 MB (API limit 30 MB). | Full URL parsed into Open Graph preview card. | Max 50 tags. Plain text hashtags supported. |
| **Instagram Professional** | 2,200 chars | Strict aspect ratios: 4:5 (0.8) to 1.91:1. Single image or Carousel (up to 10 items). JPEG/PNG only. Max 8 MB. Min 320x320, max 1440x1800. | **URLs in feed captions are NOT clickable**. Use "Link in Bio" or Stories. | Maximum **30 hashtags**, maximum 20 user tags. |
| **LinkedIn (Member)** | 3,000 chars (target 1,300 chars) | Single image: PNG/JPEG, max 8 MB. Aspect ratio 1.91:1 (1200x627) or 1:1. | Full clickable URL with link card generation. | Hashtags fully indexed; profile @mentions supported. |
| **Viber (Deep Link)** | Practical limit ~1,000 chars for clean URI | Attached separately in native Viber composer. | Clickable links in Viber chats. | No hashtag indexing. |
| **WhatsApp (Deep Link)** | Practical limit ~2,000 chars for clean URI | Attached separately in native WhatsApp composer. | Clickable links in WhatsApp chats. | No hashtag indexing. |

### 21.2 Failure & Retry State Machine

The single-flight background dispatcher enforces strict failure handling to protect account reputation and prevent duplicate public posts:

```
[Claim Due Post] ──► [Evaluate Status]
                           │
       ┌───────────────────┴───────────────────┐
       ▼                                       ▼
[Transient Network / 5xx]           [Terminal / Auth Error]
- HTTP 500, 502, 503, 504           - OAuthException code 190 (token expired/revoked)
- Exponential backoff:              - Subcodes: 458 (app uninstalled), 463 (expired), 467 (invalid)
  1m -> 5m -> 15m                   - Media validation failure (unsupported aspect ratio)
- Max 3 retry attempts              - Missing Page Admin permission
- Audit: post_failed (retryable)    - Immediate transition: status = 'failed'
                                    - If token error: channel status = 'expired'
                                    - Audit: post_failed (terminal)
                                    - In-app notification sent to channel author
```

1. **Idempotency**:
   - Every post carries `body_sha256`. A unique database constraint prevents the same content from being scheduled twice on the same channel.
   - Posts are claimed via `UPDATE marketing_posts SET status='scheduled' WHERE status='approved' AND scheduled_for <= now() RETURNING post_id` to guarantee single-flight execution across multi-instance hubs.
2. **Instagram Container Polling**:
   - For Instagram image publishing, container creation returns `creation_id`. The dispatcher verifies container status via `GET /{creation_id}?fields=status_code` before calling `media_publish`. If `status_code == 'ERROR'`, the post fails immediately without retry, logging Meta's diagnostic error message into `marketing_post_events`.

<!-- version: 0.5.0 · updated: 2026-10-26 · last-edit: 2026-10-26T12:45:00Z -->
