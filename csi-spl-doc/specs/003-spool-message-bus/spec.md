# Feature Specification: Spool message bus (hub)

**Feature ID**: `003-spool-message-bus`

**Created**: 2026-09-18

**Status**: Draft — reconciled 2026-09-18 against the binding trust model; read **Open Questions** before implementing

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
| Hub process, WS send/recv/ack framing, REST files, hub queue, flush, probes, notify | **003** (this spec) |
| Box id, pin publish / sync / revoke, `GET/POST/DELETE /v1/pins` | 004 (+ 006 root-signing) |
| Tenant create, tenant resolution from URL, quotas, `402`/`429` | 006 |

git-rel (001) is a different plane (gpg-encrypted file relay). `directive` and slack-as-pager stay on ysg-box. This spec does not migrate `$MSGS_ROOT` piecemeal.

## Trust model in one table

| | Local (`$SPOOL_HUB_URL` unset) | Hub (`$SPOOL_HUB_URL` set) |
|---|---|---|
| Trust | POSIX on `$SPOOL_ROOT` | Ed25519 **box** key, pinned by the tenant root |
| Inner `v:1` `sig` | omitted | omitted (the **envelope** carries `sig`) |
| Addressing | agent id on this box | agent id + `from_box` / `to_box` |
| Transport | files | WS `wss://<tenant-host>/v1/ws` for send/recv/ack; REST for files and pins |
| Door | n/a | the box-signed WS hello. The public product does not use IAM/OIDC (private deploys: OQ-06) |

The box key proves **which box** sent a frame. `from` (`GRK-03`) is an agent name that box asserts; the hub does not prove it separately.

## User Scenarios & Testing

### User Story 1 - Cross-box send/recv through the hub (Priority: P1) 🎯 MVP (= Milestone 1 demo)

An agent calls `spool-send` / `spool-recv` as in 002. When `$SPOOL_HUB_URL` is set and the target is on another box, the CLI wraps the `v:1` object in a box-signed envelope and sends it over the box's WebSocket. The receiving box gets the frame on its own WebSocket and delivers it to the agent's local inbox.

**Why this priority**: This is the Milestone 1 demo. Without it there is no hub.

**Independent Test**: One hub process (sqlite / memory allowed), two `$SPOOL_ROOT`s with two box ids and two pinned box keys. `GRK-03@box-a` sends `task` to `CLE-07@box-b`; `CLE-07` recvs it and replies `kind=result`.

**Acceptance Scenarios**:

1. **Given** box-a and box-b pinned in one tenant and both connected, **When** `GRK-03` on box-a sends to `CLE-07` with `--to-box box-b`, **Then** box-b receives the frame, `CLE-07` `spool-recv` returns the inner `v:1` object unchanged, and the send result carries `delivery=sent`.
2. **Given** an unpinned box, **When** it sends the WS hello, **Then** the hub closes the connection and stores nothing.
3. **Given** a tampered envelope (`sig` does not verify against the `from_box` pin), **When** it is sent, **Then** the hub refuses it, stores nothing, and the CLI exits `78`.
4. **Given** `CLE-07` is announced on two boxes and `--to-box` is omitted, **When** GRK-03 sends to `CLE-07`, **Then** the hub refuses with `409` (`ambiguous_to_box`).
5. **Given** the receiving box has **not** synced the sender box's pubkey, **When** the frame arrives, **Then** the receiving box refuses it locally (`78`) even though the hub stored it.

### User Story 2 - Files go to the object store, not the socket or the broker (Priority: P1)

`spool-put-file` uploads bytes via `POST /v1/files` (box key required); the message carries only file refs. `spool-get-file` fetches via `GET /v1/files/{file_id}` (a tenant-scoped capability) and verifies sha256.

**Why this priority**: Attachments are the usual handover. This feature exists so that nobody puts bytes on NATS or the WS, or hands agents bucket keys.

**Independent Test**: put-file on box-a → send with `file_ids` → get-file on box-b; hash matches; no file bytes in any WS frame or notify payload.

**Acceptance Scenarios**:

1. **Given** a put file, **When** the hub stores it, **Then** the object key is `t/<tenant_id>/files/<sha256>` and no message or frame contains file bytes.
2. **Given** a `POST /v1/files` without a valid box proof, **When** it arrives, **Then** it is refused (anonymous PUT is forbidden).
3. **Given** a `file_id` of tenant A, **When** it is requested under tenant B's URL, **Then** `404`.
4. **Given** GCS down, **When** put-file runs, **Then** it fails clearly (exit `1`); a text-only send may still proceed (OQ-11).
5. **Given** a short-lived signed GET URL, **When** anything logs it, **Then** that is a defect (Constitution VII).

### User Story 3 - Offline receiver and hub-down sender (Priority: P1)

Two independent failures, two queues:

- **Receiving box offline**: the **hub** stores the message (Postgres, TTL from cnf) and the send returns `delivery=queued` (no receiver ack). The box drains it on its next hello.
- **Hub unreachable**: the **sending box** keeps the message in its `$SPOOL_ROOT` outbox as pending-flush. A later flush sends it without re-signing (`contracts/flush.md`).

Same-box mail never needs the hub (`delivery=local`), unless `$SPOOL_MIRROR_LOCAL` is true.

**Why this priority**: Cloud Run scales to zero and boxes go offline. Neither event may silently lose mail or block on-box mail.

**Independent Test**: (a) box-b disconnected; send from box-a returns `queued`; box-b reconnects and recvs. (b) Hub stopped; same-box send/recv works from the folder; cross-box send is pending-flush; hub started; flush delivers.

**Acceptance Scenarios**:

1. **Given** hub down, **When** GRK-03 sends to CLE-07 on the **same** box, **Then** the local inbox receives the file as in 002 and the result is `delivery=local`.
2. **Given** hub down and a cross-box target, **When** GRK-03 sends, **Then** the local outbox holds it pending-flush and the command still exits `0` (OQ-09: which `delivery` it reports).
3. **Given** pending-flush messages, **When** the hub returns, **Then** flush sends them idempotently by `msg_id` without changing `ts` or re-signing.
4. **Given** box-b offline, **When** box-a sends to box-b, **Then** the hub stores it, returns `delivery=queued`, and box-b receives it on reconnect within the queue TTL.
5. **Given** the queue TTL expires, **When** box-b reconnects later, **Then** the message is not delivered and the commander is not retroactively failed.

### User Story 4 - Live tail of a task, not of tokens (Priority: P2, after M1)

Subscribers see "a new message landed on task X" (one small JSON per send). Model token streams stay on the coding adapter. Postgres remains the archive; a subscriber that was down reads the archive.

**Why this priority**: Humans and peer boxes need liveness, and mixing tokens with mail would drown the bus. Not in Milestone 1 (M1 recv is WS frames / poll).

**Independent Test**: Two subscribers on one `task_id`; a send appears on both; a subscriber that was down catches up from the store.

**Acceptance Scenarios**:

1. **Given** a send on `task_id`, **When** a subscriber is connected, **Then** it receives the small JSON (no file bytes).
2. **Given** no subscriber, **When** the send completes, **Then** the message is still in Postgres for later `spool-tail`.
3. **Given** a model generating tokens, **When** spool is used, **Then** those tokens are not published anywhere on the spool.

This story's transport (SSE on Cloud Run, NATS Core/JetStream, or frames on the existing WS) is **OQ-04**.

### User Story 5 - The box key is the door and the author; IAM is optional (Priority: P3)

Public rental (spec 006): the hub is reachable without a renter GCP account. The only proof is the box key: WS hello, send envelope, and `POST /v1/files`. IAM/OIDC MAY front a **private** org deploy but MUST NOT be required of renters. When present, IAM runs **before** box-key verification and never replaces it.

**Why this priority**: "Any user against payment" forbids issuing GCP principals to renters.

**Independent Test**: hub without IAM; pinned box connects and sends; unpinned box hello is closed; `POST /v1/files` without box proof is refused.

**Acceptance Scenarios**:

1. **Given** no GCP credentials, **When** a pinned box connects and sends, **Then** the hub accepts.
2. **Given** an unpinned box, **When** it sends the hello, **Then** the connection is closed, nothing stored.
3. **Given** (private deploy only) IAM enabled, **When** no door credential, **Then** 401/403 before box-key verify.

### User Story 6 - ysg-box calls spool, it does not grow a second bus (Priority: P3)

After 002+003 work, ysg-box gains **one** adapter feature that shells the spool CLI / MCP. `$MSGS_ROOT` ad-hoc writes stop only then. This repo does not modify ysg-box.

**Why this priority**: Clean cut. The spec lives here so the adapter has a contract; the patch belongs to a different repo.

**Independent Test**: Out of this repo. 003 is done when the hub + box CLI satisfy US1–US5.

**Acceptance Scenarios**:

1. **Given** this spec, **When** an adapter is written, **Then** it uses only the box API in `SPEC-spool-box-api.md` (no NATS/PG/GCS/WS from the agent).

### Edge Cases

- Cloud Run instance killed mid-request or mid-WS: the box reconnects and resends idempotently by `msg_id`. Storage is Postgres + GCS, never container disk; WS session state is not durable.
- Two Cloud Run instances: box-a's WS is on instance 1 and box-b's on instance 2. Instance 1 must still reach box-b (**OQ-05**).
- Notify transport down (after M1): writes still land in Postgres; tail is stale until catch-up.
- Two boxes, same agent id: `CLE-07@box-a` and `CLE-07@box-b` are different peers; message identity is `msg_id`.
- Direct agent → bucket upload: forbidden. No per-agent cloud keys.
- Kafka / per-kind HTTP / MCP-per-window: rejected (Constitution additional constraints).

## Requirements

### Functional Requirements

- **FR-001**: The hub MUST expose the endpoints in `contracts/http-v1.md`: WS `/v1/ws`, `POST /v1/files`, `GET /v1/files/{file_id}`, `GET /healthz`, `GET /version`. It also hosts the pin endpoints owned by 004/006.
- **FR-002**: The box CLI/MCP from 002 MUST be the only agent-facing API; agents MUST NOT call hub HTTP/WS, NATS, Postgres, or GCS directly.
- **FR-003**: The hub MUST verify the WS hello `sig` against the tenant's pin for `box_id` before accepting any frame; unknown box → close, nothing stored. **Last hello wins**: a new connection for the same `box_id` closes the older one.
- **FR-004**: The hub MUST verify every send envelope `sig` against the `from_box` pin, and MUST require `from_box` to equal the box authenticated at hello; failure → refuse, nothing stored (CLI exit `78`).
- **FR-005**: The hub MUST resolve `to_box`: required when `to` is announced on more than one box; filled by the hub when unique; `409` when ambiguous.
- **FR-006**: When `to_box` has a live WS the hub MUST push the frame and report `delivery=sent`. Otherwise it MUST persist the message with a TTL from cnf, report `delivery=queued`, and deliver it on the box's next hello.
- **FR-007**: File bytes MUST be stored as `t/<tenant_id>/files/<sha256>`; messages and frames MUST carry file refs only. `POST /v1/files` MUST require box proof; `GET /v1/files/{file_id}` MUST be tenant-scoped.
- **FR-008**: When the hub is unreachable, the CLI MUST keep cross-box sends pending-flush in `$SPOOL_ROOT` (002 layout) and MUST flush without re-signing and without changing `ts` (`contracts/flush.md`).
- **FR-009**: Same-box sends MUST NOT depend on the hub (`delivery=local`) unless `$SPOOL_MIRROR_LOCAL` is true; illegal values fail fast.
- **FR-010**: Hub ingest MUST be idempotent on `(tenant_id, msg_id)`: identical canonical → success, different canonical → `409 conflict_msg`.
- **FR-011**: Live notify (after M1) MUST NOT carry file bytes, model tokens, private keys or signed URLs, and MUST NOT leak across tenants.
- **FR-012**: Cloud Run MUST be stateless: no message log, queue, or file bytes on container disk.
- **FR-013**: Agent kind MUST appear only as id prefixes (Constitution VIII).
- **FR-014**: Private keys (box, tenant root) MUST never enter the hub, Postgres, GCS, Secret Manager, or logs (Constitution VII).
- **FR-015**: Every hub row and object key MUST carry `tenant_id`. The tenant comes from the request **Host** (`<tenant>.<product-domain>`, domain from cnf), never from the `v:1` body. One GCS bucket for all tenants, prefixed `t/<tenant_id>/`.
- **FR-016**: IAM/OIDC, when enabled on a private deploy, MUST run before box-key verification and MUST NOT substitute for it.

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
- **Delivery / ack**: per recipient `(box, agent)`: `queued` → `sent` → agent `--ack` (see OQ-08).

## Success Criteria

- **SC-001**: The Milestone 1 demo (`SPEC-spool-milestones.md`) passes end to end with no browser and no GCP credentials on the boxes.
- **SC-002**: An unpinned box or a bad envelope `sig` is refused and absent from storage.
- **SC-003**: put-file → send → get-file across two boxes verifies sha256; no frame or notify payload holds bytes.
- **SC-004**: With the hub process stopped, same-box send/recv still succeeds from `$SPOOL_ROOT`; cross-box sends flush after restart.
- **SC-005**: A send to an offline box returns `delivery=queued` and is received after reconnect within TTL.
- **SC-006**: A grep of hub + CLI source shows no per-kind route, no hostname literal, and no private key or signed URL written to logs.
- **SC-007**: Two tenants with the same `box_id` and agent ids cannot read each other's messages or files.

## Assumptions

- 002 CLI/MCP and `v:1` schema are implemented first (or in parallel only for docs).
- 003 MVP runs on sqlite/memory in tests; production M1 is Cloud Run + Postgres + GCS.
- ysg-box adapter is a follow-on in that repo, not a task in this one.
- Product DNS is `<tenant>.spool-hub.ai` (owner decision); binaries read it from `$SPOOL_HUB_URL` / cnf and never bake it.
- Cloud Run min instances = 1 by default (warm WS), cnf-overridable. Boxes refresh pins on hello and on a cnf interval.

## Out of Scope

- Implementing or modifying ysg-box.
- git-rel / spec 001 bucket semantics.
- Kafka, Pinbox, Slack-as-bus, token SSE on spool, MCP server per tmux window.
- Per-agent keys on the hub, per-agent IAM identities, per-agent object-store keys.
- Encrypt-to-recipient (the hub can read bodies).
- WUI (Milestone 3, spec 005); payment (Milestone 2, spec 006).

## Open Questions

Each item below is under-specified or contradicted across documents. This file answers none of them. Each needs an owner decision before the task that depends on it starts.

- **OQ-01: Is the box API still frozen?** Hub mode needs `--to-box` on `spool-send` / `to_box` on `spool_send`, plus a `delivery` field in the send result (`../002-box-agent-messaging/contracts/trust-modes.md` §4, §8). None of these appears in 002 `contracts/cli.md`, `contracts/mcp-tools.md`, or `SPEC-spool-box-api.md`. Is this an additive, allowed change to the 002 contract, and does 002 or 003 own it? Blocks `tasks.md` T007.
- **OQ-02: Does the REST message dialect survive at all?** Earlier 003 text had `POST /v1/messages` + `GET /v1/messages?as=` for a "private org hub", verified per agent. The binding model has no per-agent keys and moves send/recv to WS. Should the REST dialect be deleted, or kept as a private-deploy variant with box-key auth? (006 `tasks.md` T008–T010 still build `POST /v1/messages` / `POST /v1/recv`.)
- **OQ-03: Envelope canonicalisation and replay.** `sig` covers `jq -cS '{from_box,to_box,msg}'`. If `to_box` is omitted and the hub fills it, is the signature over the envelope *without* `to_box`? Does the delivered frame carry the hub-filled value outside the signed bytes? The receiving box must be able to re-verify. Separately: does the hello `sig` cover a hub-issued nonce, or only `{box_id, ts}`? And what is the `ts` window?
- **OQ-04: Live tail transport (US4).** Candidates are SSE `GET /v1/events` (earlier plan), NATS Core/JetStream (`contracts/nats-subjects.md`), or frames on the existing WS. The milestone puts NATS out of M1 but names no replacement.
- **OQ-05: Multi-instance fan-out and reconnects.** The milestone sets **min** instances = 1 (cnf-overridable, including 0) but no maximum. With more than one Cloud Run instance, how does the instance holding box-a's socket reach box-b's socket? Candidates are Postgres `LISTEN/NOTIFY`, NATS, Pub/Sub, or `max-instances=1` for M1. Cloud Run's request timeout (max 60 min) forces WS reconnects, and no reconnect/resume contract exists yet.
- **OQ-06: Private-deploy IAM.** Is an IAM-fronted private deploy still a supported shape? If so, how do boxes present an OIDC token on a WS upgrade? The `boxes.iam_principal` column in `data-model.md` exists only for this case.
- ~~**OQ-07: Tenant routing.**~~ **Resolved** by the owner (trunk `cdea288`, `SPEC-spool-milestones.md`): tenant from the **Host** header, `https://<tenant>.spool-hub.ai`, with the host from cnf/env only. Recorded in FR-015.
- **OQ-08: Ack model.** Does the hub's responsibility end at `delivery=sent` (box got the frame)? Or does the box send an ack frame that moves the row to `acks`? In hub mode, does `spool-recv --ack` only archive locally, or also notify the hub?
- **OQ-09: `delivery` value when the hub is down.** Trust-modes §8 defines `local | sent | queued`. A cross-box send while the hub is unreachable fits none of them, because the hub never saw it. Should it get a new value (e.g. `pending`), or exit non-zero?
- **OQ-10: Box proof on `POST /v1/files`.** The docs offer "signed headers or a short-lived upload token from the WS" without choosing. The header format (which bytes are signed, replay window) is unspecified.
- **OQ-11: "Text-only may proceed if policy allows".** Whose policy is this, and where is it configured? If a message references a `file_id` the hub does not hold, is the send refused?
- **OQ-12: Notify subjects vs non-unique agent ids.** `agent.<agent-id>.inbox` assumed tenant-wide unique ids. Ids are now unique only per box (and per tenant), so the subject needs `tenant` and `box` components. The format is undecided and depends on OQ-04.
- **OQ-13: Hub queue TTL vs Postgres retention.** Queue TTL is "cnf" with no default, while message retention is 90 days. Are queued-but-undelivered rows subject only to the queue TTL? Does expiry leave any record the commander can see?
- **OQ-14: Local-mode `sig` in the 002 build.** 002 `message-schema.md` says local mode omits `sig`, but the current 002 Go code (`internal/spool/spool.go`) signs every send with a per-agent key. Which one is authoritative for 003's inner object?
- **OQ-15: Who owns flush?** The 0.1.0 003 `tasks.md` put flush in `internal/hub/flush.go` (now T019, box-side `internal/hubclient`); 004 `tasks.md` T010 puts it in `internal/flush`. Flush runs on the box, so `internal/hub` looks wrong in either case.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:24:00+03:00 -->
