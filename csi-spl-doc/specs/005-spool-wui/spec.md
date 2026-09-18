# Feature Specification: Spool WUI (read-only thread viewer)

**Feature ID**: `005-spool-wui`

**Created**: 2026-09-18

**Status**: Draft — **explicitly out of rental MVP** (owner 2026-09-18).
Final product: Slack-like chat + command, not read-only.

**Input**: Post-MVP Slack-like WUI: authenticated human chats and commands
any agent. Do not implement in 002/006.

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-wui.md`

**Depends on**: 003 US1 (GET messages), optionally US4 (live notify).

## User Story 1 - Operator opens a task thread (Priority: P1) 🎯 MVP

Operator authenticates at the door (IAP/IAM), opens `task_id`, sees messages
oldest-first and file names.

**Independent Test**: fixture messages in testhub; UI or HTTP client used by
the WUI lists them in order.

**Acceptance Scenarios**:

1. **Given** two messages on a task, **When** the thread view loads, **Then**
   both appear oldest-first with `from`, `kind`, `body`.
2. **Given** a file ref, **When** the operator clicks it, **Then** bytes
   download via hub GET (hash verified by client) and the signed URL is not
   stored in app logs.

## User Story 2 - Live update (Priority: P2)

New send appears without full page reload (SSE from hub or NATS-to-SSE
bridge on Cloud Run). Fallback poll.

## Requirements

- **FR-001**: WUI uses hub HTTP only, never agent keys.
- **FR-002**: Final WUI **does** send (`note` / `task`) as a `HUM-*` peer.
  That send path is out of the rental MVP.
- **FR-003**: Auth is operator door identity (Google IAP / Cloud Run IAM), not `CLE-*` pins.
- **FR-004**: Code lives in `csi-spl-wui`.
- **FR-005**: Architecture & Stack: Built on Nuxt 3 SSR (Vue 3, TypeScript, Pinia, pnpm), referencing `/opt/pas/pas-psf/pas-psf-wui`.
- **FR-006**: Local dev setup (`lde`): `pnpm dev --host 0.0.0.0 --port 3000` with `NUXT_PUBLIC_API_BASE` configurable via env, matching the `pas-psf` local development pattern.
- **FR-007**: Container & Deployment: Multi-stage Dockerfile deployed to Cloud Run or Firebase Hosting, orchestrated via `csi-spl-orc`.

## Out of Scope

Send/ack/pin, Slack, model tokens, per-kind UI.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:20:00Z -->
