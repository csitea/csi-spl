# 090: Marketing Automation (delegated social and email posting)

**Feature ID**: `090-marketing-automation` · **Milestone**: M4 · **Status**: Draft (v0.2.0)  
**Created**: 2026-10-05 · **Lane**: a-273 · **Topic**: `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`  
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

Per the owner's standing instruction ("present me with simple specs"), this document delivers a simple, readable specification focused on core user stories, clear requirements, and concrete acceptance criteria.

---

## 2. Core Architectural Principle: Delegated Posting with Consent

To comply with platform policies and protect account reputation, posting "on behalf of a person" is framed strictly as **delegated posting with consent**, rather than credential impersonation or browser session hijacking:

1. **Official OAuth 2.0 Authorization**:
   - The user connects their own account once through each platform's standard OAuth flow (e.g. LinkedIn Member Posting, X User Context, Meta Graph API).
   - The system never asks for, stores, or handles user account passwords.
2. **Explicit Consent & Granular Revocation**:
   - The user clearly sees what permissions the system holds and can disconnect or revoke access at any time with a single click.
   - The user can switch automated posting on or off, choosing between **per-post approval** (default) or **standing automated publishing**.
3. **Authentic Attribution & Audit Trail**:
   - Every post is published in that person's own name, from their authentic account.
   - An immutable audit trail records who authorized the post, who approved it (or whether published via standing rule), the timestamp, the exact message body, target channel, and the platform post ID.
4. **Email on Behalf of a Person**:
   - Outbound marketing emails sent on behalf of a person are sent from the person's own verified email address and domain.
   - Domains must be authenticated with valid SPF, DKIM, and DMARC records. Header spoofing or unverified `From:` headers are strictly prohibited.

---

## 3. Review of the Dispatcher Outline & Platform Realities

Starting from the initial outline proposed by dispatcher c-002, this specification adopts the core ideas while clarifying practical platform constraints:

| Topic | c-002 Initial Outline | Specification Decision & Challenge |
|---|---|---|
| **Channels** | LinkedIn, X, Facebook, email | **LinkedIn**: Supported via `w_member_social`.<br>**X**: Supported via OAuth 2.0, but **requires paid API tier** (Basic $100/mo minimum for posting).<br>**Facebook**: Meta API allows automated posting **only to Pages**, strictly prohibiting personal profile automation.<br>**Email**: Supported via verified transactional/marketing provider. |
| **Flow** | Agent drafts -> Person approves -> Published at planned time | Adopted. Agent creates a draft; reviewer can approve, edit, or reject. An optional standing mode permits automated publishing for routine release announcements. |
| **Content** | Release notes, new features, tips, demos | Adopted. Release announcements derive directly from release notes (spec 065); tips and demos highlight CLI/MCP capabilities. |
| **Plan** | Posts planned in time; ties in with Calendar | Adopted. Marketing events and scheduled posts link directly with the Calendar (spec 089) as coordinated timed events. |
| **Results** | Published/failed status, link, reach numbers | Adopted. System records post status, live post URL, diagnostic errors, and basic reach metrics (impressions, clicks) where exposed by the API. |
| **Email** | Opt-in list, release newsletter, 1-click unsubscribe | Adopted. Pure opt-in subscriber list; complies with GDPR and CAN-SPAM with mandatory one-click unsubscribe headers. |

---

## 4. Anti-Spam Policy & Daily Cadence Rule

Per owner msg `fd72a794` (*"The aim is not to be spamming anyone. The aim is to have scheduled posts every day..."*), the system enforces strict cadence controls:

1. **Daily Frequency Cap**:
   - Strict maximum of **one scheduled automated post per day per channel** (e.g., 1 on LinkedIn, 1 on X, 1 on Facebook).
   - If multiple drafts are generated on the same day, they are staggered across subsequent calendar days.
2. **High-Signal Focus**:
   - Content is drawn exclusively from verified release notes (spec 065), concrete feature launches, and practical usage demos.
   - Generic filler, repetitive hashtag dumps, and automated @-mention spam are strictly barred.
3. **Audience Protection**:
   - Social posts publish only to the user's own connected feeds/pages.
   - Email delivers only to explicit opt-in subscribers. Cold scraping, purchased email lists, and unsolicited outreach are barred.

---

## 5. Platform API Limits & Compliance Basics

Each marketing channel is governed by specific platform constraints and legal rules (one-line summaries):

- **LinkedIn**: Member posting via `w_member_social` enforces standard developer rate limits and strictly prohibits duplicate or spam content.
- **X (Twitter)**: Automated tweeting via v2 API requires a paid developer subscription (Basic tier minimum) and enforces per-user and per-app daily limits.
- **Facebook**: Meta Graph API permits automated publishing exclusively to Facebook Pages managed by the user; personal user profile automation is forbidden.
- **Email Delivery**: Deliverability requires authenticated domain records (SPF, DKIM, DMARC) and strict monitoring to keep spam complaints below 0.1%.
- **Email Compliance (GDPR & CAN-SPAM)**: Requires verifiable opt-in consent, clear sender identification, valid physical postal address, and instant one-click unsubscribe (`List-Unsubscribe` header and link).

---

## 6. Security & Token Lifecycle

- **Secret Manager Storage**: All OAuth access tokens, refresh tokens, and API secrets are stored securely in Secret Manager, encrypted at rest.
- **Zero Secret Exposure**: Tokens are never committed to git, never written into logs, never printed in terminal outputs, and never transmitted in spool messages.
- **Strict Workspace Isolation**: Credentials and tokens are scoped strictly to the owning workspace. Cross-workspace access or token sharing is prohibited.

---

## 7. User Stories

| ID | Role | Story | Benefit |
|---|---|---|---|
| **US1** | Member | Connect my social account (e.g. LinkedIn) via OAuth in workspace settings | Enables the Spool Hub to publish on my behalf safely without credential sharing |
| **US2** | Author | Toggle between per-post approval and standing automated posting | Retain fine-grained editorial control or choose hands-free publication for releases |
| **US3** | Agent | Generate a multi-platform draft and newsletter from a new release tag `v<X.Y.Z>` | Automates tedious marketing copy creation immediately upon deployment |
| **US4** | Reviewer | Review, edit text, approve, or reject pending post drafts in the WUI | Ensures public communication meets brand quality and accuracy standards |
| **US5** | Member | View scheduled post publication times on the Calendar (spec 089) | Visualizes upcoming marketing outreach alongside releases and deployments |
| **US6** | Subscriber | Unsubscribe from the release email newsletter with a single click | Ensures compliance with privacy standards and avoids spam reports |

---

## 8. Functional Requirements & Acceptance Matrix

### 8.1 Functional Requirements

- **FR-001**: System shall provide OAuth 2.0 connection flows for social channels with official delegation scopes.
- **FR-002**: System shall support Facebook posting strictly to authorized Facebook Pages.
- **FR-003**: System shall store platform credentials and tokens in Secret Manager with strict workspace isolation.
- **FR-004**: System shall support both Per-Post Approval mode (default) and Standing Delegation mode.
- **FR-005**: System shall maintain an immutable audit log of all outbound posts (author, approver, timestamp, content, platform post ID).
- **FR-006**: System shall display scheduled marketing posts as timed events in the Calendar (spec 089).
- **FR-007**: Outbound email shall be sent from verified domains with SPF/DKIM authentication and one-click unsubscribe headers.
- **FR-008**: System shall track post status (`draft`, `scheduled`, `approved`, `published`, `failed`) and capture live post links and errors.
- **FR-009**: System shall enforce a hard daily frequency cap of at most one automated post per day per channel.

### 8.2 Acceptance Scenarios

- **AC-01 (Account Connection)**: User initiates connection -> completes OAuth consent -> system stores tokens in Secret Manager -> settings page indicates connected account status.
- **AC-02 (Access Revocation)**: User clicks "Disconnect" -> tokens are immediately revoked and deleted from Secret Manager -> pending drafts for that channel are suspended.
- **AC-03 (Draft Review & Approval)**: Agent drafts announcement for `v1.4.0` -> draft appears in WUI -> reviewer edits text and clicks "Approve" -> post status updates to `approved`.
- **AC-04 (Calendar Visualization)**: Post scheduled for a release date appears on `/calendar`; rescheduling the calendar event updates the target post dispatch time.
- **AC-05 (Successful Dispatch)**: At scheduled time, background dispatcher transmits payload to platform API -> receives success ID -> updates status to `published` and records URL.
- **AC-06 (Error Handling)**: If platform rejects post due to rate limit or expired token -> status marked `failed`, diagnostic message recorded, and author notified.
- **AC-07 (Email Unsubscribe)**: Recipient clicks unsubscribe link -> email address status updated to `unsubscribed` immediately without requiring account login.
- **AC-08 (Anti-Spam Daily Cap)**: Two release posts drafted on the same day -> system schedules the first for today and automatically staggers the second to the following day.

---

## 9. What is NOT in Scope

1. **Password-Based Impersonation**: Storing user passwords or logging into platforms without official OAuth delegation.
2. **Fake or Sock-Puppet Accounts**: Creating, managing, or automating unverified bot accounts.
3. **Browser Scraping & Session Automation**: Using headless browsers (e.g. Puppeteer) to automate user sessions or bypass APIs.
4. **Facebook Personal Profile Automation**: Posting to personal Facebook profiles (prohibited by Meta API).
5. **Cold / Unsolicited Email Blasts**: Sending marketing emails to individuals who have not explicitly opted in.
6. **Two-Way Social Inbox**: Managing inbound comments, mentions, or direct messages inside the Spool WUI.

---

## 10. Open Questions for the Owner (Max 6)

1. **Target Accounts**: Should social marketing target the personal profiles of team members/founders (via member OAuth), dedicated Spool Hub brand pages, or both?
2. **Approval Authority**: Who inside a workspace has authority to approve draft posts (any workspace member, or only workspace admins)?
3. **Unapproved Autonomous Releases**: May official release announcements (e.g. triggered on a new `v*` tag) be published automatically under standing delegation, or must every single post require a human approval click?
4. **Email Delivery Tool**: Which transactional/marketing email service should be configured for the newsletter (e.g. AWS SES, Postmark, SendGrid, or direct SMTP)?
5. **API Budget for X (Twitter)**: Automated posting on X v2 API requires a paid developer tier ($100/month). Is this budget approved, or should initial rollout prioritize LinkedIn and email?
6. **First Channel to Build**: Which single channel should be implemented and verified first in Phase 1 (e.g. LinkedIn personal delegated posting, Email release newsletter, or X)?

---

## 11. Appendix: Data Model Reference

*Architectural reference for future implementation; this specification builds no database tables.*

```sql
-- Connected workspace marketing channels
CREATE TABLE marketing_channels (
    channel_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    platform        text NOT NULL CHECK (platform IN (linkedin, x, facebook, email)),
    account_name    text NOT NULL,
    account_type    text NOT NULL CHECK (account_type IN (personal, page, newsletter)),
    delegated_by    text NOT NULL, -- human member ID
    secret_key_ref  text NOT NULL, -- reference in Secret Manager
    auto_publish    boolean NOT NULL DEFAULT false,
    status          text NOT NULL CHECK (status IN (active, revoked, expired)),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Drafted and dispatched marketing posts
CREATE TABLE marketing_posts (
    post_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    channel_id      uuid NOT NULL REFERENCES marketing_channels(channel_id) ON DELETE CASCADE,
    content_text    text NOT NULL,
    media_urls      text[] NOT NULL DEFAULT {},
    status          text NOT NULL CHECK (status IN (draft, approved, scheduled, published, failed, rejected)),
    author_type     text NOT NULL CHECK (author_type IN (human, agent)),
    author_id       text NOT NULL,
    approved_by     text NULL,
    scheduled_for   timestamptz NULL,
    published_at    timestamptz NULL,
    platform_post_id text NULL,
    platform_url    text NULL,
    last_error      text NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Opt-in email newsletter subscribers
CREATE TABLE marketing_email_subscribers (
    subscriber_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    text NOT NULL,
    email           text NOT NULL,
    status          text NOT NULL CHECK (status IN (subscribed, unsubscribed, bounced)),
    opt_in_at       timestamptz NOT NULL DEFAULT now(),
    opt_in_ip       text NULL,
    unsubscribed_at timestamptz NULL,
    UNIQUE (workspace_id, email)
);
```

---

## 12. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-05 | a-273 | Initial draft specification for marketing automation (delegated social and email posting). |
| v0.2.0 | 2026-10-05 | a-273 | Folded owner msg `fd72a794` into spec: added anti-spam policy with strict 1 post/day/channel cap, high-signal focus, FR-009, and AC-08. |

<!-- version: 0.2.0 · updated: 2026-10-05 · last-edit: 2026-10-05T04:24:00Z -->
