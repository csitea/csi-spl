# Feature Specification: Spool message bus (hub)

**Feature ID**: `003-spool-message-bus`

**Created**: 2026-09-18

**Status**: Draft

**Input**: Architecture freeze from the owner: split names (ysg-box = machine, spool = bus); start clean in this repo then force the box to use it; local signed CRUD first (002); Cloud Run is a stateless process; state in Postgres + object store; NATS for live notify not for files or tokens; Ed25519 pin is the author, IAM is the door last; one uniform box API for every agent kind.

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-message-bus.md`  
**Box API**: `csi-spl-doc/doc/md/SPEC-spool-box-api.md`  
**Identity**: `csi-spl-doc/doc/md/SPEC-spool-identity-routing.md` + `specs/004-spool-identity-routing/`  
**Product**: `csi-spl-doc/doc/md/SPEC-spool-hub-rental.md` + `specs/006-spool-hub-rental/`  
**Lifecycle**: `csi-spl-doc/doc/md/SPEC-spool-task-lifecycle.md`  
**Hub extras**: `data-model.md`, `contracts/flush.md`, `contracts/limits.md`, `contracts/error-envelope.md`  
**Prerequisite**: `specs/002-box-agent-messaging/` (local folder + pin + CLI/MCP). 003 does not replace 002; it puts the **same** `v:1` object behind HTTP + notify.

## Context

002 ships the spool as a folder on one box. This feature is the **hosted bus**: a stateless HTTP process agents still never call directly (the box CLI/MCP does), durable records, content-addressed files, live tail across boxes, and a local queue when the hub is down.

git-rel (001) is a different plane (gpg-encrypted file relay). `directive` and slack-as-pager stay on ysg-box. This spec does not migrate `$MSGS_ROOT` piecemeal.

## User Scenarios & Testing

### User Story 1 - Same send/recv through the hub HTTP API (Priority: P1) 🎯 MVP

An agent on a box calls `spool-send` / `spool-recv` as in 002. When the hub is configured, the CLI talks HTTP (`POST /v1/messages`, `GET /v1/messages`) instead of (or after writing) the local folder. Signatures and pins still decide whether the message is accepted.

**Why this priority**: Without a working HTTP contract that is 1:1 with the box API, Cloud Run is a new dialect.

**Independent Test**: Point the 002 CLI at a hub process (memory/sqlite allowed). A signed send is accepted; an unsigned or unpinned send is HTTP 400 / exit `78` and not stored.

**Acceptance Scenarios**:

1. **Given** GRK-03 and CLE-07 are pinned, **When** GRK-03 `spool-send`s with the hub up, **Then** `POST /v1/messages` stores the `v:1` object and CLE-07 `spool-recv` returns it.
2. **Given** a missing pin or bad `sig`, **When** `POST /v1/messages`, **Then** the hub refuses (400 / exit `78`) and writes nothing.
3. **Given** the same CLI flags as 002, **When** the hub is the backend, **Then** field names, `kind` values, and return `{msg_id, task_id, ts}` are unchanged.

### User Story 2 - Files go to the object store, not the broker (Priority: P1)

`spool-put-file` uploads bytes via `POST /v1/files`; the message carries only `file_id`. `spool-get-file` fetches via `GET /v1/files/{file_id}` (bytes or short-lived signed URL) and verifies sha256.

**Why this priority**: Attachments are the usual handover; putting bytes on NATS or handing agents bucket keys is the failure mode this feature exists to avoid.

**Independent Test**: put-file → send with `file_ids` → peer get-file; hash matches; no file bytes on the notify path.

**Acceptance Scenarios**:

1. **Given** a put file, **When** the hub stores it, **Then** the object key is `files/<sha256>` and the JSON message contains no file bytes.
2. **Given** GCS/object store down, **When** put-file runs, **Then** it fails clearly; a text-only send may still proceed if policy allows.
3. **Given** a signed GET URL, **When** it is logged, **Then** that is a defect (Constitution VII) — URLs are short-lived and not persisted.

### User Story 3 - Hub down still lets the box send (Priority: P1)

If Cloud Run is unreachable, the CLI writes the local `$SPOOL_ROOT` queue (002 behaviour). A sidecar flushes when the hub returns.

**Why this priority**: A hosted process that can scale to zero must not be a hard SPOF for on-box mail.

**Independent Test**: Stop the hub; send; recv on the same box still works from the folder; start the hub; flush delivers to the peer box.

**Acceptance Scenarios**:

1. **Given** hub down, **When** GRK-03 sends to CLE-07 on the **same** box, **Then** the local inbox receives the signed file as in 002.
2. **Given** queued messages, **When** the hub returns, **Then** the sidecar/CLI flush posts them (`POST /v1/messages` + files) without rewriting `sig`.

### User Story 4 - Live tail of a task, not of tokens (Priority: P2)

Subscribers see “a new message landed on task X” (one JSON blob per send). Model token streams stay on the coding adapter (SSE). NATS subject `task.<task_id>` (and optional `agent.<id>.inbox`) carries notify; Postgres remains the archive.

**Why this priority**: Humans and peer boxes need liveness; mixing tokens with mail would drown the bus.

**Independent Test**: Two subscribers on `task.<uuid>`; a send appears on both; a subscriber that was down reads Postgres/NDJSON instead of a lost notify.

**Acceptance Scenarios**:

1. **Given** a send on `task_id`, **When** a subscriber is connected, **Then** it receives the small JSON (no file bytes).
2. **Given** no subscriber, **When** the send completes, **Then** the message is still in Postgres / local NDJSON for later `spool-tail`.
3. **Given** a model generating tokens, **When** spool is used, **Then** those tokens are not published on NATS.

### User Story 5 - Pin is the author; IAM is not the renter door (Priority: P3)

Public rental (spec 006): HTTP is reachable without a renter GCP account.
Ed25519 is authorisation (send = `from` sig, recv = signed `POST /v1/recv`).
IAM/OIDC MAY front a **private** org deploy; it MUST NOT be required of paying
renters. After any optional infra shield, the hub still verifies `sig` against
the **tenant** pin table.

**Why this priority**: “Any user against payment” forbids issuing GCP principals
to renters. Unsigned POST is cheaply 400’d; recv must not be an open GET.

**Independent Test**: testhub without IAM; pinned send works; unpinned send
400; recv without `as` sig cannot drain an inbox.

**Acceptance Scenarios**:

1. **Given** no GCP credentials, **When** a pinned agent POSTs `/v1/messages`, **Then** the hub accepts.
2. **Given** an unpinned `from`, **When** POST `/v1/messages`, **Then** 400, nothing stored.
3. **Given** (private deploy only) IAM enabled, **When** no door credential, **Then** 401/403 before signature verify.

### User Story 6 - ysg-box calls spool, it does not grow a second bus (Priority: P3)

After 002+003 HTTP work, ysg-box gains **one** adapter feature that shells the spool CLI / MCP. `$MSGS_ROOT` ad-hoc writes stop only then. This repo does not modify ysg-box.

**Why this priority**: Clean cut. Spec lives here so the adapter has a contract; the patch is a different repo.

**Independent Test**: Out of this repo. Documented as a follow-on; 003 is done when the hub + box CLI satisfy US1–US5.

**Acceptance Scenarios**:

1. **Given** this spec, **When** an adapter is written, **Then** it uses only the box API in `SPEC-spool-box-api.md` (no NATS/PG/GCS from the agent).

### Edge Cases

- Cloud Run instance killed mid-request: client retries; storage is Postgres + GCS, never container disk.
- NATS down: writes still land in Postgres; tail is stale until replay (JetStream) or a catch-up read.
- Two boxes, same `task_id`: both may subscribe; message identity is `msg_id`.
- Direct agent → bucket upload: forbidden. No per-agent cloud keys.
- Kafka / per-kind HTTP / MCP-per-window: rejected (Constitution additional constraints).

## Requirements

### Functional Requirements

- **FR-001**: The hub MUST expose `POST /v1/files`, `GET /v1/files/{file_id}`, `POST /v1/messages`, `GET /v1/messages?as=&task_id=` as specified in `contracts/http-v1.md`.
- **FR-002**: The box CLI/MCP from 002 MUST be the only agent-facing API; agents MUST NOT call hub HTTP, NATS, Postgres, or GCS directly.
- **FR-003**: `POST /v1/messages` MUST verify Ed25519 `sig` against the pin of `from` before persist; failure is 400 and no row.
- **FR-004**: File bytes MUST be stored as `files/<sha256>` in the object store; messages MUST reference `file_id` only.
- **FR-005**: When the hub is unreachable, the CLI MUST queue in `$SPOOL_ROOT` (002 layout) and MUST flush without re-signing.
- **FR-006**: Live notify MUST use subjects in `contracts/nats-subjects.md` and MUST NOT carry file bytes or model tokens.
- **FR-007**: Cloud Run MUST be stateless: no NDJSON or file bytes on container disk.
- **FR-008**: IAM/OIDC, when enabled, authenticates the **box adapter**, not each `CLE-*` / `GRK-*` / `AGY-*` id.
- **FR-009**: Agent kind MUST appear only as id prefixes (Constitution VIII).
- **FR-010**: Private agent keys MUST never enter the hub, Postgres, GCS, Secret Manager, or logs (Constitution VII). Secret Manager holds hub TLS only.

### Non-Functional Requirements

- **NFR-001**: Region `europe-north1` for GCP resources; hosts/buckets from cnf, never literals.
- **NFR-002**: Verify/refuse maps to HTTP 400 and CLI exit `78`.
- **NFR-003**: On-wire JSON is 002’s on-disk `v:1` (no schema fork).
- **NFR-004**: No Kafka; NATS is optional until US4.
- **NFR-005**: Server harness, startup/shutdown lifecycle, structured logging, configuration, test harness (`internal/testkit`), ops probes, and shell function utilities (`src/bash/`) MUST refer to and follow the patterns in `/opt/pas/pas-psf/pas-psf-api` (`src/cmd/api/main.go`, `src/cmd/api/wire.go` `runUntilShutdown`, `src/internal/config/config.go`, `src/internal/logging/logging.go`, `src/internal/httpapp/httpapp.go`, `src/internal/testkit/`, and `src/bash/`).

### Key Entities

- **Message (`v:1`)**: as 002 / `SPEC-spool-box-api.md` §5.
- **File object**: `file_id` = sha256 of bytes.
- **Pin**: agent id → pubkey (hub copy of the trust set).
- **Task**: `task_id` (UUIDv4) grouping messages; NATS subject `task.<task_id>`.
- **Ack**: delivery cursor per `as` agent (Postgres), equivalent to 002 archive move.

## Success Criteria

- **SC-001**: A signed send through the hub is recvable by the peer with the 002 CLI flags unchanged.
- **SC-002**: Unsigned or unpinned send is refused and absent from storage.
- **SC-003**: put-file → send → get-file round trip verifies sha256; notify payload has no bytes.
- **SC-004**: With hub process stopped, same-box send/recv still succeeds from `$SPOOL_ROOT`.
- **SC-005**: A grep of hub + CLI source shows no per-kind HTTP path and no agent private keys written to logs.

## Assumptions

- 002 CLI/MCP and `v:1` schema are implemented first (or in parallel only for docs).
- One NATS cluster (or equivalent) is acceptable later; 003 MVP HTTP may run without NATS (US1–US3).
- ysg-box adapter is a follow-on in that repo, not a task in this one.
- Public DNS is chosen at deploy time (`spool-hub.ai` placeholder); WHOIS of marketing names is not a runtime dependency.

## Out of Scope

- Implementing or modifying ysg-box.
- git-rel / spec 001 bucket semantics.
- Kafka, Pinbox, Slack-as-bus, token SSE on spool, MCP server per tmux window.
- Per-agent IAM identities and per-agent object-store keys.
- A full UI beyond `spool-tail` / a tiny subscriber.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
