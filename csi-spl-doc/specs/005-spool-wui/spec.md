# Feature Specification: Spool WUI (read-only thread viewer)

**Feature ID**: `005-spool-wui`

**Created**: 2026-09-18

**Status**: Draft

**Input**: Architecture diagram “tiny UI / spool-tail”. Specify a read-only
human viewer of `v:1` threads. No send, no pins, no token SSE.

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
- **FR-002**: v1 is read-only (no POST messages from the browser).
- **FR-003**: Auth is operator door identity, not `CLE-*` pins.
- **FR-004**: Code lives in `csi-spl-wui`.

## Out of Scope

Send/ack/pin, Slack, model tokens, per-kind UI.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
