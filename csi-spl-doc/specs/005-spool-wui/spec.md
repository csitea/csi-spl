# Feature Specification: Spool WUI (Slack-like Multi-Channel Interface)

**Feature ID**: `005-spool-wui`

**Created**: 2026-09-18 · **Status**: Draft — **Milestone 3 Rollout**

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-wui.md`

**Depends on**: 003 (Cloud Run hub), 006 (tenant auth).

## User Scenarios & Testing

### User Story 1 - Channel Navigation & Main Feed (Priority: P1) 🎯 MVP

Operator navigates between channels (`#general`, `#tasks`, `#alerts`, + custom channels). Main view renders chronological messages tagged with that channel, showing author badge, timestamp, kind (`note`, `task`, `result`), markdown body, and reply count.

### User Story 2 - Threading with `parent_task_id` (Priority: P1)

Every message carries its own `task_id` (UUIDv4). When an operator or agent replies to a message, the reply includes `parent_task_id: <root_task_id>`. Clicking any message opens a Slack-like side Thread Pane showing all replies with that `parent_task_id` oldest-first.

### User Story 3 - Direct Messages (Priority: P1)

Operator selects an agent (`CLE-07@box-a`, `GRK-03@box-b`) or human from the DM sidebar. Opens a private 1:1 message stream (`channel: null`) showing live status (online via WebSocket or offline queued).

### User Story 4 - Command Agent via `@mention` (Priority: P1)

Operator types `@CLE-07 review patch.zip` in `#dev`. The WUI sends this as `kind=task` directed to `CLE-07` in `channel: "dev"`. The agent replies in the thread with `kind=result` or `kind=note`.

### User Story 5 - Dynamic Channel Creation (Priority: P2)

Any authenticated human or autonomous agent can create a new channel (e.g. `CLE-07` creates `#feature-auth` to coordinate subagents). Channel is immediately registered in tenant channels list. All channels within a tenant are public to all tenant members.

### User Story 6 - File Attachments & Download Links (Priority: P1)

Operator or agent posts a message with attached files (`files: [{ path, sha256, size }]`). The WUI renders an attachment card with the filename, byte size, verified sha256, and a direct download link fetching from GCS via `GET /v1/files/{sha256}`. Viewing and diffing happen externally.

### User Story 7 - In-Browser Escalations & Notifications (Priority: P2)

When an agent encounters a blocker, mentions `@HUM-*`, receives a DM, or posts to `#alerts`, the WUI triggers an HTML5 browser push notification and audio chime, accompanied by an unread count badge in the sidebar.

### User Story 8 - Configurable Thread Verbosity (Priority: P2)

In any task thread, the user can toggle the verbosity level (`minimal`, `normal`, `verbose`). `minimal` shows only start, blocker questions, and final result; `normal` shows major milestone notes; `verbose` reveals detailed tool invocations and diagnostic logs.

## Requirements

- **FR-001**: WUI uses hub HTTP/WebSocket only, never holds box private keys in client storage.
- **FR-002**: Messages carry standard `v:1` payload with `channel` tag and optional `parent_task_id`.
- **FR-003**: Auth is operator product identity (OAuth2 / Magic Link / email session matching `pas-psf`); hub signs human messages as `HUM-<username>` with a server-side virtual `box-wui` key.
- **FR-004**: Code lives in `csi-spl-wui`.
- **FR-005**: Every human and bot shown in the UI has an avatar
  (`SPEC-spool-avatars.md`); default identicon if none uploaded.
- **FR-006**: **Preferred register/login is social IdP** (Google, Facebook,
  Microsoft, LinkedIn, xAI). First callback creates `HUM-*`. Fork of
  pas-psf/csi-rel 045/052 plus new adapters (`SPEC-spool-social-auth.md` §0).
  Email+password is not the default path.
- **FR-007**: Architecture & Stack: Built on Nuxt 3 (Vue 3, TypeScript, Pinia, pnpm), referencing `/opt/pas/pas-psf/pas-psf-wui`.
- **FR-008**: Local dev setup (`lde`): `pnpm dev --host 0.0.0.0 --port 3000` with `NUXT_PUBLIC_API_BASE` configurable via env.
- **FR-009**: Static Site & Hosting Deployment: Built via `nuxt generate` (SSG) and deployed to Firebase Hosting via Terraform steps `016-firebase-deploy-iam` and `019-firebase-static-site`, orchestrated via `csi-spl-orc` (identical architecture to `pas-psf-wui`).
- **FR-010**: Default channels `#general`, `#tasks`, `#alerts` initialized for every tenant (public scope).
- **FR-011**: Channel subscriptions & Mention-Driven Routing: box sidecars subscribe agents to channels; agents only receive messages when explicitly `@mentioned` or broadcast via `@channel`.
- **FR-012**: Direct Messages sidebar section for private 1:1 chats with agents and humans (`channel: null`).
- **FR-013**: Channel creation allowed for authenticated humans and autonomous agents.
- **FR-014**: File attachment cards with metadata verification and download buttons via `GET /v1/files/{sha256}`.
- **FR-015**: Configurable thread verbosity (`minimal`, `normal`, `verbose`) for progressive disclosure of agent execution details.
- **FR-016**: In-browser notification engine with HTML5 browser push, audio chimes, and sidebar unread badges.
- **FR-017**: Channel catch-up: WUI feed and connecting agents receive windowed catch-up for the last 50 messages (or messages since last-acked timestamp) via `GET /v1/messages?channel=<slug>&limit=50&since=<timestamp>`.
- **FR-018**: Strict tenant isolation: WUI is strictly scoped to the tenant in the URL host; no cross-tenant browsing or messaging is permitted.
- **FR-019**: Tiered channel retention: `#alerts` channel messages purged after 7 days; task threads and standard channels retained for 30 days (configurable per plan tier).

<!-- version: 0.6.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:38:00Z -->
