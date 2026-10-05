# 090: Marketing Automation (delegated social and email posting)

**Feature ID**: `090-marketing-automation` · **Milestone**: M4 · **Status**: Consensus (v0.3.3)  
**Created**: 2026-10-05 · **Lane**: a-273 (author), c-286 (owner from v0.3.3) · **Topic**: `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`  
**Authority**: this file for behaviour and requirements. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

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
| **LinkedIn (Company)** | OAuth 2.0 (`w_organization_social`) | Company brand page. Requires LinkedIn Community Management API access, business verification, and formal app review (weeks). | Phase 3 |
| **X (Twitter)** | OAuth 2.0 PKCE (`tweet.write`) | Pay-per-use / developer tier with prepaid credits (vendor card checked 2026-10-05: ~$0.015 per post, ~$0.200 with link). Live price verified at build time. Rotating refresh tokens. | Phase 3 |
| **Facebook Pages** | Meta Graph API (`pages_manage_posts`, `pages_show_list`) | **Facebook Pages only**. Automated posting to personal Facebook profiles has been barred since 2018. Requires Meta App Review & Business Verification. Instagram is excluded. | Phase 3 |
| **Email Newsletter** | Transactional Provider (SMTP / API) | Authenticated workspace subdomain with SPF/DKIM/DMARC. Double opt-in, RFC 8058 one-click headers, bounce/complaint suppression. | Phase 2 |

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
- **Phase 3: Expanded Channels & Brand Pages**
  - X (Twitter) posting integration with live pay-per-use price verification.
  - Facebook Page and LinkedIn Organization Page posting following platform App Review and Business Verification.

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
3. **Browser Scraping & Headless Automation**: Using browser drivers (e.g. Puppeteer) to bypass official APIs.
4. **Facebook Personal Profile Automation**: Posting to personal Facebook profiles (prohibited by Meta API).
5. **Instagram Automation**: Social automation on Instagram.
6. **Cold / Unsolicited Email Blasts**: Sending marketing emails to individuals who have not explicitly double opted-in.
7. **Two-Way Social CRM**: Managing inbound comments, mentions, or direct messages inside the Spool WUI.
8. **Reach Analytics in Phase 1**: Paid API metrics and engagement dashboards.

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

<!-- version: 0.3.3 · updated: 2026-10-05 · last-edit: 2026-10-05T05:30:00Z -->
