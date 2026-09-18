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

Any authenticated human or autonomous agent can create a new channel (e.g. `CLE-07` creates `#feature-auth` to coordinate subagents). Channel is immediately registered in tenant channels list.

## Requirements

- **FR-001**: WUI uses hub HTTP/WebSocket only, never holds box private keys.
- **FR-002**: Messages carry standard `v:1` payload with `channel` tag and optional `parent_task_id`.
- **FR-003**: Auth is operator product identity (payment account / tenant login), not GCP IAM per agent.
- **FR-004**: Code lives in `csi-spl-wui`.
- **FR-005**: Architecture & Stack: Built on Nuxt 3 SSR (Vue 3, TypeScript, Pinia, pnpm), referencing `/opt/pas/pas-psf/pas-psf-wui`.
- **FR-006**: Local dev setup (`lde`): `pnpm dev --host 0.0.0.0 --port 3000` with `NUXT_PUBLIC_API_BASE` configurable via env.
- **FR-007**: Container & Deployment: Multi-stage Dockerfile deployed to Cloud Run, orchestrated via `csi-spl-orc`.
- **FR-008**: Default channels `#general`, `#tasks`, `#alerts` initialized for every tenant.
- **FR-009**: Channel subscriptions: box sidecars subscribe agents to designated channels.
- **FR-010**: Direct Messages sidebar section for private 1:1 chats with agents and humans.
- **FR-011**: Channel creation allowed for authenticated humans and autonomous agents.

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:45:00Z -->
