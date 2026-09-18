# Feature Specification: Spool message bus (hub)

**Feature ID**: `003-spool-message-bus`

**Created**: 2026-09-18

**Status**: M1 hub **Implemented** and verified (section **Verification**, 2026-09-18); read-only viewer API (US7) **Planned**; prd deploy and the ingress are **Partial/Planned** in the infra lane (007). OQ-01..15 resolved; OQ-16 (viewer door) open with the owner.

**Redo ground rules**: `../README.md` (status vocabulary, seams §5, provisioning order §6). Status tags below follow it.

**Input**: Architecture freeze from the owner: split names (ysg-box = machine, spool = bus); start clean in this repo then force the box to use it; local CRUD first (002); Cloud Run is a stateless process; state in Postgres + object store; NATS for live notify not for files or tokens; one uniform box API for every agent kind.

**Binding (wins over this file on conflict)**: `csi-spl-doc/specs/002-box-agent-messaging/contracts/trust-modes.md` (local unsigned; hub = one Ed25519 key **per box**, box-signed envelope over **WebSocket**; files/pins over REST) and `csi-spl-doc/doc/md/SPEC-spool-milestones.md` (M1 = non-WUI cross-box mesh on Cloud Run + Postgres + GCS, tenant-scoped; no NATS and no IAM in M1).

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-message-bus.md`  
**Box API**: `csi-spl-doc/doc/md/SPEC-spool-box-api.md`  
**Identity**: `csi-spl-doc/doc/md/SPEC-spool-identity-routing.md` + `specs/004-spool-identity-routing/`  
**Product**: `csi-spl-doc/doc/md/SPEC-spool-hub-rental.md` + `specs/006-spool-hub-rental/` (tenant, pins, billing codes, `contracts/http-rental.md`)  
**Lifecycle**: `csi-spl-doc/doc/md/SPEC-spool-task-lifecycle.md`  
**Hub extras**: `data-model.md`, `contracts/flush.md`, `contracts/limits.md`, `contracts/error-envelope.md`  
**Prerequisite**: `specs/002-box-agent-messaging/` (local folder + CLI/MCP). 003 does not replace 002. It carries the **same** inner `v:1` object between boxes, wrapped in a box-signed envelope.

## Context

002 ships the spool as a folder on one box. This feature is the **hosted bus**: a stateless Cloud Run process that agents never call directly (the box CLI/MCP does), durable records in Postgres, content-addressed files in GCS, cross-box delivery over WebSocket, a hub-side queue for an offline receiving box, and a local queue when the hub itself is down.

**Split of ownership between 003, 004 and 006**, so no endpoint is specified three times:

| Concern | Owner |
|---|---|
| Hub process, WS hello/send/recv/tail framing, REST files, hub queue, box-side flush, probes, `spool migrate` | **003** (this spec) |
| **WUI read API** (`/v1/view/*`, `contracts/view-v1.md`) | **003** (this spec); 005 cites and depends |
| Box id, pin publish / sync / revoke, `GET/POST/DELETE /v1/pins` | 004 (+ 006 root-signing) |
| Tenant create, tenant resolution from URL, root key, quotas, `402`/`429` | 006 |
| Terraform, DNS, Cloud Run/SQL/GCS, secrets, WIF, lde | 007 (003 names cnf keys only) |
| GitHub Actions build + deploy | 008 |

git-rel (001) is a different plane (gpg-encrypted file relay). `directive` and slack-as-pager stay on ysg-box. This spec does not migrate `$MSGS_ROOT` piecemeal.

## Trust model in one table

| | Local (`$SPOOL_HUB_URL` unset) | Hub (`$SPOOL_HUB_URL` set) |
|---|---|---|
| Trust | POSIX on `$SPOOL_ROOT` | Ed25519 **box** key, pinned by the tenant root |
| Inner `v:1` `sig` | omitted | omitted (the **envelope** carries `sig`) |
| Addressing | agent id on this box | agent id + `from_box` / `to_box` |
| Transport | files | WS `wss://<tenant-host>/v1/ws` for send/recv/tail; REST for files and pins only (OQ-02) |
| Door | n/a | the box-signed WS hello over a hub-issued nonce (OQ-03). No IAM/OIDC in M1 (OQ-06) |

The box key proves **which box** sent a frame. `from` (`GRK-03`) is an agent name that box asserts; the hub does not prove it separately.

## User Scenarios & Testing

### User Story 1 - Cross-box send/recv through the hub (Priority: P1) 🎯 MVP (= Milestone 1 demo)

An agent calls `spool-send` / `spool-recv` as in 002. When `$SPOOL_HUB_URL` is set and the target is on another box, the CLI wraps the `v:1` object in a box-signed envelope and sends it over the box's WebSocket. The receiving box gets the frame on its own WebSocket and delivers it to the agent's local inbox.

**Why this priority**: This is the Milestone 1 demo. Without it there is no hub.

**Independent Test**: One hub process (in-memory or Postgres allowed), two `$SPOOL_ROOT`s with two box ids and two pinned box keys. `GRK-03@box-a` sends `task` to `CLE-07@box-b`; `CLE-07` recvs it and replies `kind=result`.

**Acceptance Scenarios**:

1. **Given** box-a and box-b pinned in one tenant and both connected, **When** `GRK-03` on box-a sends to `CLE-07` with `--to-box box-b`, **Then** box-b receives the frame, `CLE-07` `spool-recv` returns the inner `v:1` object unchanged, and the send result carries `delivery=sent`.
2. **Given** an unpinned box, **When** it sends the WS hello, **Then** the hub closes the connection and stores nothing.
3. **Given** a tampered envelope (`sig` does not verify against the `from_box` pin), **When** it is sent, **Then** the hub refuses it, stores nothing, and the CLI exits `78`.
4. **Given** `CLE-07` is announced on two boxes and `--to-box` is omitted, **When** GRK-03 sends to `CLE-07`, **Then** the CLI refuses before signing (`ambiguous_to_box`), and a hand-built envelope without `to_box` is refused by the hub with `409` (`ambiguous_to_box`). The hub never fills `to_box` (OQ-03).
5. **Given** the receiving box has **not** synced the sender box's pubkey, **When** the frame arrives, **Then** the receiving box refuses it locally (`78`) even though the hub stored it.

### User Story 2 - Files go to the object store, not the socket or the broker (Priority: P1)

`spool-put-file` uploads bytes via `POST /v1/files` (box key required); the message carries only file refs. `spool-get-file` fetches via `GET /v1/files/{file_id}` (a tenant-scoped capability) and verifies sha256.

**Why this priority**: Attachments are the usual handover. This feature exists so that nobody puts bytes on NATS or the WS, or hands agents bucket keys.

**Independent Test**: put-file on box-a → send with `file_ids` → get-file on box-b; hash matches; no file bytes in any WS frame or notify payload.

**Acceptance Scenarios**:

1. **Given** a put file, **When** the hub stores it, **Then** the object key is `t/<tenant_id>/files/<sha256>` and no message or frame contains file bytes.
2. **Given** a `POST /v1/files` without a valid WS-issued upload token, **When** it arrives, **Then** it is refused `401` (anonymous PUT is forbidden; OQ-10).
3. **Given** a `file_id` of tenant A, **When** it is requested under tenant B's URL, **Then** `404`.
4. **Given** GCS down, **When** put-file runs, **Then** it fails clearly (exit `1`). A send referencing a `file_id` the hub does not hold is refused `400 missing_file` unless the cnf flag `hub.allow_text_only_when_file_missing` is true (default false; OQ-11).
5. **Given** a short-lived signed GET URL, **When** anything logs it, **Then** that is a defect (Constitution VII).

### User Story 3 - Offline receiver and hub-down sender (Priority: P1)

Two independent failures, two queues:

- **Receiving box offline**: the **hub** stores the message (Postgres, 7-day TTL, max 1,000 per box) and the send returns `delivery=queued` (no receiver ack). The box drains it on its next hello.
- **Hub unreachable**: the **sending box** keeps the signed envelope as pending-flush and the send returns `delivery=pending` (OQ-09). A later flush sends it without re-signing (`contracts/flush.md`).

Same-box mail never needs the hub (`delivery=local`), unless `$SPOOL_MIRROR_LOCAL` is true.

**Why this priority**: Cloud Run scales to zero and boxes go offline. Neither event may silently lose mail or block on-box mail.

**Independent Test**: (a) box-b disconnected; send from box-a returns `queued`; box-b reconnects and recvs. (b) Hub stopped; same-box send/recv works from the folder; cross-box send is pending-flush; hub started; flush delivers.

**Acceptance Scenarios**:

1. **Given** hub down, **When** GRK-03 sends to CLE-07 on the **same** box, **Then** the local inbox receives the file as in 002 and the result is `delivery=local`.
2. **Given** hub down and a cross-box target, **When** GRK-03 sends, **Then** the local outbox holds it pending-flush, the result is `delivery=pending`, and the command still exits `0` (OQ-09).
3. **Given** pending-flush messages, **When** the hub returns, **Then** flush sends them idempotently by `msg_id` without changing `ts` or re-signing.
4. **Given** box-b offline, **When** box-a sends to box-b, **Then** the hub stores it, returns `delivery=queued`, and box-b receives it on reconnect within the queue TTL.
5. **Given** the queue TTL expires, **When** box-b reconnects later, **Then** the message is not delivered and the commander is not retroactively failed.

### User Story 4 - Live tail of a task, not of tokens (Priority: P2, after M1)

Subscribers see "a new message landed on task X" (one small JSON per send). Model token streams stay on the coding adapter. Postgres remains the archive; a subscriber that was down reads the archive.

**Why this priority**: Humans and peer boxes need liveness, and mixing tokens with mail would drown the bus. The stored part of a task tail ships in M1 as WS frames; richer live fan-out comes after M1.

**Independent Test**: Two subscribers on one `task_id`; a send appears on both; a subscriber that was down catches up from the store.

**Acceptance Scenarios**:

1. **Given** a send on `task_id`, **When** a subscriber is connected, **Then** it receives the small JSON (no file bytes).
2. **Given** no subscriber, **When** the send completes, **Then** the message is still in Postgres for later `spool-tail`.
3. **Given** a model generating tokens, **When** spool is used, **Then** those tokens are not published anywhere on the spool.

Transport (OQ-04, resolved): **frames on the existing WebSocket** (`tail` → `tail_msg`… `tail_end`, then live `tail_msg` with `follow`). No SSE and no NATS in M1.

### User Story 5 - The box key is the door and the author; no IAM in M1 (Priority: P3)

Public rental (spec 006): the hub is reachable without a renter GCP account. The only proof is the box key: WS hello (challenge-response), send envelope, and — through the WS-issued upload token — `POST /v1/files`. IAM/OIDC is **not in M1** (OQ-06). If a private deploy ever adds it, IAM runs **before** box-key verification and never replaces it.

**Why this priority**: "Any user against payment" forbids issuing GCP principals to renters.

**Independent Test**: hub without IAM; pinned box connects and sends; unpinned box hello is closed; `POST /v1/files` without box proof is refused.

**Acceptance Scenarios**:

1. **Given** no GCP credentials, **When** a pinned box connects and sends, **Then** the hub accepts.
2. **Given** an unpinned box, **When** it sends the hello, **Then** the connection is closed, nothing stored.
3. *(post-M1, private deploy only)* **Given** IAM enabled, **When** no door credential, **Then** 401/403 before box-key verify.

### User Story 6 - ysg-box calls spool, it does not grow a second bus (Priority: P3)

After 002+003 work, ysg-box gains **one** adapter feature that shells the spool CLI / MCP. `$MSGS_ROOT` ad-hoc writes stop only then. This repo does not modify ysg-box.

**Why this priority**: Clean cut. The spec lives here so the adapter has a contract; the patch belongs to a different repo.

**Independent Test**: Out of this repo. 003 is done when the hub + box CLI satisfy US1–US5.

**Acceptance Scenarios**:

1. **Given** this spec, **When** an adapter is written, **Then** it uses only the box API in `SPEC-spool-box-api.md` (no NATS/PG/GCS/WS from the agent).

### User Story 7 - Read-only thread viewer API for the WUI (Priority: P2, M3 dependency) — Planned

A human opens the WUI (spec 005) and sees the tenant's boxes, who is online, the list of task threads and each thread's messages with their attachments. The WUI reads through a small **read-only** REST surface, `contracts/view-v1.md`, with a view token. It never sends, never drains a queue, and never touches the box door (`/v1/ws`).

**Why this priority**: The WUI is M3, but its only hub dependency is this contract; freezing it now lets 005 build against a real shape instead of the deleted `/v1/messages` dialect (see `contracts/view-v1.md` §7 for the measured drift).

**Independent Test**: hub with two boxes and one stored thread; with a valid view token, `GET /v1/view/threads` lists the thread and `GET /v1/view/threads/{task_id}` returns the envelopes oldest first; the `deliveries` rows are byte-identical before and after; without a token → `401 view_door`; from a non-listed origin → no CORS headers.

**Acceptance Scenarios**:

1. **Given** a queued message for offline box-b, **When** the viewer reads its thread, **Then** it sees `deliveries[].state = queued`, and box-b still drains it on its next hello (the read changed nothing).
2. **Given** a view token for tenant A, **When** it is used under tenant B's Host, **Then** `401 view_door`.
3. **Given** a `task_id` of tenant A, **When** it is read under tenant B, **Then** `404 not_found`.
4. **Given** a `POST` to any `/v1/view/*` path, **When** it arrives, **Then** `405 method_not_allowed`.
5. **Given** `hub.view_cors_origins` is empty, **When** a cross-origin preflight arrives, **Then** no CORS headers are returned.

### Edge Cases

- Cloud Run instance killed mid-request or mid-WS: the box reconnects (exponential backoff, cap ~30 s) and resends idempotently by `msg_id`. Storage is Postgres + GCS, never container disk; WS session state is not durable.
- Two Cloud Run instances: excluded in M1 by `max-instances=1` (cnf-overridable; OQ-05). Cross-instance fan-out (`LISTEN/NOTIFY` or Pub/Sub) is post-M1.
- Notify transport down (after M1): writes still land in Postgres; tail is stale until catch-up.
- Two boxes, same agent id: `CLE-07@box-a` and `CLE-07@box-b` are different peers; message identity is `msg_id`.
- Direct agent → bucket upload: forbidden. No per-agent cloud keys.
- Kafka / per-kind HTTP / MCP-per-window: rejected (Constitution additional constraints).
- `/healthz` on Cloud Run: Cloud Run reserves some paths ending in `z`; the deployed dev service answers a Google 404 on its `run.app` URL (ingress is LB-only and no LB exists yet). FR-023 adds a non-`z` alias.

## Requirements

### Functional Requirements

- **FR-001**: The hub MUST expose the endpoints in `contracts/http-v1.md`: WS `/v1/ws`, `POST /v1/files`, `GET /v1/files/{file_id}`, `GET /healthz`, `GET /version`. It also hosts the pin endpoints owned by 004/006. *Status:* **Implemented** — `7905e35`; `grep -c 'HandleFunc' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go -> 8`.
- **FR-002**: The box CLI/MCP from 002 MUST be the only agent-facing API; agents MUST NOT call hub HTTP/WS, NATS, Postgres, or GCS directly. *Status:* **Implemented** — `hub-e2e.tst.sh` drives only the `spool` binary (run-all-tests → `ALL HUB E2E CHECKS PASSED`).
- **FR-003**: The hub MUST issue a single-use nonce on connect and verify the WS hello `sig` over `{box_id, ts, nonce}` against the tenant's pin for `box_id` before accepting any frame (`ts` within ±300 s); unknown box → close, nothing stored. **Last hello wins**: a new session connection for the same `box_id` closes the older one. *Status:* **Implemented** — `7905e35`; e2e `unpinned box refused at hello (exit 78)`; `TestHelloNonceAcceptAndReplayReject`, `TestLastHelloWinsOnlyForBoxRole`.
- **FR-004**: The hub MUST verify every send envelope `sig` against the `from_box` pin, and MUST require `from_box` to equal the box authenticated at hello; failure → refuse, nothing stored (CLI exit `78`). *Status:* **Implemented** — `7905e35`; `TestTamperedAndAmbiguousAndMissingPin`.
- **FR-005**: The **sender** MUST resolve `to_box` (explicit, or unique in the synced roster) and sign it; the hub MUST NOT fill or mutate any signed field. An envelope without `to_box` is refused (`409 ambiguous_to_box` when `to` is on more than one box, else `400 missing_to_box`). *Status:* **Implemented** — `7905e35`; `TestTamperedAndAmbiguousAndMissingPin`.
- **FR-006**: When `to_box` has a live WS the hub MUST push the frame and report `delivery=sent`. Otherwise it MUST persist the message with a 7-day TTL (max 1,000 queued per box), report `delivery=queued`, and deliver it on the box's next hello. The hub's responsibility ends there (no ack; OQ-08). *Status:* **Implemented** — e2e `offline receiver: delivery=queued, drained on hello` and `live receiver (hub-run): delivery=sent`.
- **FR-007**: File bytes MUST be stored as `t/<tenant_id>/files/<sha256>`; messages and frames MUST carry file refs only. `POST /v1/files` MUST require a WS-issued upload token (TTL ~5 min, bound to `box_id` + tenant); `GET /v1/files/{file_id}` MUST be tenant-scoped. *Status:* **Implemented** — `7905e35` + GCS driver `81121a0`; `hub-gcs.tst.sh` → `ALL HUB GCS CHECKS PASSED`.
- **FR-008**: When the hub is unreachable, the CLI MUST keep cross-box sends pending-flush in `$SPOOL_ROOT`, report `delivery=pending` with exit `0`, and MUST flush without re-signing and without changing `ts` (`contracts/flush.md`; flush lives in box-side `internal/hubclient`). *Status:* **Implemented** — `e2c7d8d`; e2e `hub down: cross-box delivery=pending (exit 0)` and `hub back: flush sent the pending envelope`.
- **FR-009**: Same-box sends MUST NOT depend on the hub (`delivery=local`) unless `$SPOOL_MIRROR_LOCAL` is true; illegal values fail fast. *Status:* **Implemented** — `internal/config` `Mirror()` (fail-fast) + `internal/hubclient/flush.go`; mirror-on covered by `TestMirrorLocalSameBox` (`internal/hub/pin_sync_flush_test.go`).
- **FR-010**: Hub ingest MUST be idempotent on `(tenant_id, msg_id)`: identical canonical → success, different canonical → `409 conflict_msg`. *Status:* **Implemented** — store contract suite on memory + Postgres (`hub-pg.tst.sh`).
- **FR-011**: Live notify (after M1) MUST NOT carry file bytes, model tokens, private keys or signed URLs, and MUST NOT leak across tenants. *Status:* **Implemented** for the M1 WS tail (`TestTailStoredAndFollow`); post-M1 notify transports are not built.
- **FR-012**: Cloud Run MUST be stateless: no message log, queue, or file bytes on container disk. *Status:* **Implemented** — store = Postgres, blob = GCS; no disk driver in `serve` (T029 sweep).
- **FR-013**: Agent kind MUST appear only as id prefixes (Constitution VIII). *Status:* **Implemented** — T029 hygiene grep.
- **FR-014**: Private keys (box, tenant root) MUST never enter the hub, Postgres, GCS, Secret Manager, or logs (Constitution VII). *Status:* **Implemented** — T029 hygiene grep; keys never leave the box / owner.
- **FR-015**: Every hub row and object key MUST carry `tenant_id`. The tenant comes from the request **Host** (`<tenant>.<product-domain>`, domain from cnf), never from the `v:1` body. One GCS bucket for all tenants, prefixed `t/<tenant_id>/`. *Status:* **Implemented** — `TestFilesRoundTripAndTenantIsolation`; tenant resolution semantics owned by 006.
- **FR-016**: IAM/OIDC is not in M1. If a private deploy enables it later, it MUST run before box-key verification and MUST NOT substitute for it. *Status:* **Implemented** — no IAM code path exists; T026.
- **FR-017**: M1 MUST run the hub with `max-instances=1` (cnf-overridable). The box MUST reconnect on close with exponential backoff (cap ~30 s) and re-hello. *Status:* **Partial** — reconnect implemented (e2e `hub-run reconnected and received it`); `max_instances 1` in cnf and tf `030` and live on dev (`gcloud run services describe csi-spl-hub-dev … --account=$GCP_ACCOUNT` → template maxScale `1`, 2026-09-18, n=1); prd not deployed (Cloud Run API disabled in `csi-spl-prd`, 007).
- **FR-018**: The hub MUST expose the read-only viewer API in `contracts/view-v1.md` (`GET /v1/view/roster`, `/channels`, `/threads`, `/threads/{task_id}`), reusing `GET /v1/files/{file_id}` for bytes. *Status:* **Planned** — `grep -c '/v1/view' …/internal/hub/server.go -> 0`.
- **FR-019**: A viewer read MUST NOT mutate hub state: no delivery claim or drain, no `sent` marking, no roster, pin or `last_hello_at` change. It MUST NOT reintroduce a REST send/recv (OQ-02). *Status:* **Planned**.
- **FR-020**: Every `/v1/view/*` request MUST carry a view token bound to the Host tenant with `scope=view` and a bounded expiry; refusal → `401 view_door`. The token format is OQ-16 (proposed: tenant-root-signed, stateless). *Status:* **Planned**.
- **FR-021**: CORS MUST be limited to origins listed in cnf `hub.view_cors_origins` (no default, never `*`) and to `/v1/view/*` + `GET /v1/files/{file_id}`. *Status:* **Planned**.
- **FR-022**: Viewer responses MUST be tenant-scoped (foreign `task_id` → `404`) and MUST carry envelopes byte-for-byte as stored, file refs only, and no token or signed URL. *Status:* **Planned**.
- **FR-023**: The hub MUST answer liveness on a path Cloud Run and the LB do not reserve (add `GET /v1/health`, keep `/healthz` for local use); 007's external gates (provisioning-order step 10, SC-004) probe it; a serverless NEG backend takes no LB health check, so there is no LB health-check path to set. *Status:* **Implemented** — `TestHealthPaths` (both paths 200). 007 still has to point the LB health check at `/v1/health`.

### Non-Functional Requirements

- **NFR-001**: Region `europe-north1` for GCP resources; hosts/buckets from cnf, never literals.
- **NFR-002**: Verify/refuse maps to CLI exit `78`; HTTP/WS error tokens per `contracts/error-envelope.md`.
- **NFR-003**: The inner object on the wire is 002's on-disk `v:1` (no schema fork); the envelope is additive and hub-only.
- **NFR-004**: No Kafka. No NATS in Milestone 1.
- **NFR-005**: Server harness, startup/shutdown lifecycle, structured logging, configuration, test harness (`internal/testkit`), ops probes, and shell function utilities (`src/bash/`) MUST follow the patterns in the `pas-psf` reference API (`src/cmd/api/main.go`, `src/cmd/api/wire.go` `runUntilShutdown`, `src/internal/config/config.go`, `src/internal/logging/logging.go`, `src/internal/httpapp/httpapp.go`, `src/internal/testkit/`, `src/bash/`). Read-only reference.
- **NFR-006**: Limits and retention per `contracts/limits.md`.

### Key Entities

- **Message (`v:1`)**: as 002 `contracts/message-schema.md`; inner `sig` absent in both modes.
- **Envelope**: `{ from_box, to_box, msg, sig }`, where `sig` is made by the sending box key over the canonical envelope (`../002-box-agent-messaging/contracts/trust-modes.md` §5).
- **File object**: `file_id` = sha256 of bytes, stored per tenant.
- **Box pin**: `(tenant_id, box_id)` → pubkey, published with the tenant root (004/006).
- **Roster**: agent ids a box announced at hello (dir scan of `$SPOOL_ROOT/*/`).
- **Task**: `task_id` (UUIDv4) grouping messages.
- **Delivery**: send result `local | sent | queued | pending` (trust-modes §8 + OQ-09). The hub's part ends at `sent`/`queued`; agent `--ack` is local only (OQ-08). `expired` is a hub-side `deliveries.state`, never a send result.
- **View token**: short-lived, tenant-bound, read-only door for `/v1/view/*` (FR-020, OQ-16).

## Verification (2026-09-18, n=1 each)

| Check | Result |
|---|---|
| `bash csi-spl-api/src/bash/tests/run-all-tests.sh` on trunk `9f8f492` (Postgres 16 + fake-gcs via docker) | `ALL csi-spl-api TESTS PASSED` (smoke, hub Postgres gate, binary e2e, GCS gate — none skipped) |
| `ls csi-spl-rdb/src/sql/postgres/spool-hub/` | `0001_hub_core.sql 0002_channels.sql 0003_payment.sql`; e2e: `spool migrate applies 3 file(s); re-run is a no-op` |
| `grep -n 'HandleFunc' …/internal/hub/server.go` | `/healthz`, `/version`, `/v1/ws`, `POST/GET /v1/files`, `GET/POST/DELETE /v1/pins` — no REST send/recv, no `/v1/view` |
| `gcloud run services list --project=csi-spl-dev --account=$GCP_ACCOUNT` | `csi-spl-hub-dev`, image `spool-hub:0.1.0`, min/max scale 1/1, ingress `internal-and-cloud-load-balancing` |
| same for `csi-spl-prd` | `SERVICE_DISABLED` (Cloud Run API not enabled; 007 step 2) |
| `curl https://<dev run.app URL>/healthz` and `/version` | Google 404 (LB-only ingress, no LB yet: 007 step 10) |

## Success Criteria

- **SC-001**: The Milestone 1 demo (`SPEC-spool-milestones.md`) passes end to end with no browser and no GCP credentials on the boxes.
- **SC-002**: An unpinned box or a bad envelope `sig` is refused and absent from storage.
- **SC-003**: put-file → send → get-file across two boxes verifies sha256; no frame or notify payload holds bytes.
- **SC-004**: With the hub process stopped, same-box send/recv still succeeds from `$SPOOL_ROOT`; cross-box sends flush after restart.
- **SC-005**: A send to an offline box returns `delivery=queued` and is received after reconnect within TTL.
- **SC-006**: A grep of hub + CLI source shows no per-kind route, no hostname literal, and no private key or signed URL written to logs.
- **SC-007**: Two tenants with the same `box_id` and agent ids cannot read each other's messages or files.
- **SC-008** (M3 gate): the WUI renders a live thread using only `contracts/view-v1.md` + `GET /v1/files/{file_id}`, and a before/after dump of `deliveries` is identical.

## Assumptions

- 002 CLI/MCP and `v:1` schema are implemented first (or in parallel only for docs).
- 003 runs on in-memory store in unit tests and Postgres in integration/production; production M1 is Cloud Run + Cloud SQL Postgres + GCS.
- ysg-box adapter is a follow-on in that repo, not a task in this one.
- Product DNS is `<tenant>.spool-hub.ai` (owner decision); binaries read it from `$SPOOL_HUB_URL` / cnf and never bake it.
- Cloud Run min instances = 1 and **max instances = 1** in M1 (warm WS, single instance), both cnf-overridable. Boxes refresh pins on hello and on a cnf interval.

## Out of Scope

- Implementing or modifying ysg-box.
- git-rel / spec 001 bucket semantics.
- Kafka, Pinbox, Slack-as-bus, token SSE on spool, MCP server per tmux window.
- Per-agent keys on the hub, per-agent IAM identities, per-agent object-store keys.
- Encrypt-to-recipient (the hub can read bodies).
- The WUI itself and human send/channel writes (Milestone 3, spec 005); payment (Milestone 2, spec 006). The **read** API the WUI needs is in scope (US7).

## Resolved decisions (formerly Open Questions)

All fifteen are closed. OQ-07/13/14 were resolved earlier by the owner; the other twelve by the ORC decision record of 2026-09-18, grounded in `../002-box-agent-messaging/contracts/trust-modes.md`, `SPEC-spool-milestones.md` and `SPEC-spool-identity-routing.md`.

- **OQ-01: Box API frozen?** — **Additive change, allowed; split ownership.** `delivery` already shipped in 002 (always `local`). `--to-box` / `to_box` are hub-only and belong to **003**, added with the envelope (trust-modes §2.1.5, §4–5). Unblocks T007.
- **OQ-02: REST message dialect?** — **Dropped.** Public hub send/recv is WebSocket only; REST is files + pins only. `POST/GET /v1/messages` and `POST /v1/recv` are deleted from 003, and 006 T008–T010 must be rewritten to WS (trust-modes §1, §4, §7).
- **OQ-03: Envelope canonicalisation and replay.** — (a) The **sender resolves `to_box` locally** (from the synced pins/roster) and includes it **before** signing; the hub never mutates signed bytes. `sig = ed25519(jq -cS '{from_box,to_box,msg}')` with `to_box` present. An omitted `--to-box` is a CLI convenience only when the local roster makes it unambiguous — the CLI still fills it pre-sign; the hub 409s on ambiguity and fills nothing. The receiver re-verifies over the exact `{from_box,to_box,msg}`. (b) Hello is **challenge-response**: the hub issues a single-use nonce on connect; the box signs `{box_id, ts, nonce}`; `ts` skew window **±300 s**.
- **OQ-04: Live-tail transport (US4).** — **Frames on the existing WebSocket.** No SSE, no NATS in M1.
- **OQ-05: Multi-instance fan-out and reconnects.** — **`max-instances=1` for M1** (cnf-overridable), so every box socket terminates on one instance. The box reconnects on close/timeout with exponential backoff (cap ~30 s) and re-hellos; **last hello wins** evicts the stale socket. Cross-instance fan-out (`LISTEN/NOTIFY` or Pub/Sub) is post-M1.
- **OQ-06: Private-deploy IAM.** — **Not in M1.** Box auth is the Ed25519 box key on the WS hello, not OIDC. `boxes.iam_principal` is reserved, nullable and unused in M1.
- ~~**OQ-07: Tenant routing.**~~ **Resolved** by the owner (trunk `cdea288`, `SPEC-spool-milestones.md`): tenant from the **Host** header, `https://<tenant>.spool-hub.ai`, with the host from cnf/env only. Recorded in FR-015.
- **OQ-08: Ack model.** — **The hub's responsibility ends at frame delivery** (`sent`/`queued`). No hub ack frame and no `acks` table in M1. `spool-recv --ack` archives **locally only**. A `result`/`reject` is an ordinary peer send (trust-modes §9).
- **OQ-09: `delivery` when the hub is down.** — **Add `pending`.** A cross-box send while the hub is unreachable → `delivery=pending` (held locally for flush; the hub never saw it), distinct from `queued` (hub stored, receiver offline). Send still exits `0`. `delivery` is now `local | sent | queued | pending`.
- **OQ-10: Box proof on `POST /v1/files`.** — **Short-lived WS-issued upload token.** The box proved its key at hello; the hub mints a capability token (TTL ~5 min, bound to `box_id` + tenant) for `POST /v1/files`. Anonymous PUT forbidden. Chosen over signed headers: no header replay window to specify.
- **OQ-11: "Text-only if policy allows".** — **A hub cnf flag**, `hub.allow_text_only_when_file_missing`, **default false**. By default a send referencing a `file_id` the hub does not hold is refused (`400 missing_file`); a tenant/deploy opts in via cnf.
- **OQ-12: Notify subjects.** — **N/A in M1** (WS frames only; no pub/sub). Deferred with NATS; if revived, subject = `tenant.<tenant>.box.<box_id>.inbox`.
- ~~**OQ-13: Hub queue TTL vs Postgres retention.**~~ **Resolved**: 7-day TTL with max 1,000 queued messages per offline box; older/excess queued rows become `deliveries.state = expired` (a hub row state, not a send-result `delivery`). Tiered retention: `#alerts` purged after 7 days, task threads kept 30 days (cnf-configurable per plan).
- ~~**OQ-14: Local-mode `sig` in the 002 build.**~~ **Resolved** (commit `90786cd` / `2bbe68e`): local mode strictly omits `sig`; local mail is unsigned with POSIX filesystem permissions.
- **OQ-15: Who owns flush?** — **Box-side `internal/hubclient`**, not the server-side `internal/hub`. 004 T010 (`internal/flush`) aligns to `internal/hubclient`; 003 T019 is correct.

- **OQ-16: Viewer door (US7).** — **OPEN, owner to confirm.** Proposed: a stateless view token signed by the tenant **root** key over `jq -cS '{exp,scope,tenant}'`, minted offline (`spool hub-view-token`), verified against `tenants.root_pubkey`, TTL ≤ cnf `hub.view_token_max_ttl` (12 h). M3 social-auth sessions become a second door for the same endpoints. Alternative: wait for social auth and ship no interim door (the viewer then cannot run before M3). Blocks T033 only.

### Clarifications (implementation, 2026-09-18)

- **Hello `role`**: `box` (the session socket: receives `recv` frames, announces the roster, subject to last-hello-wins) or `cli` (a one-shot sender; never receives, never evicts). Without it every CLI send would evict the box daemon. `contracts/http-v1.md` §2.2.
- **DDL home**: `csi-spl-rdb/src/sql/postgres/spool-hub/*.sql`, applied by `spool migrate` (`data-model.md`).
- **Follow-up (parked)**: `msg.ValidID` must reject the `BOX-` prefix (identity-routing).

<!-- version: 0.5.3 · updated: 2026-09-18 · last-edit: 2026-09-18T19:13:34Z -->
