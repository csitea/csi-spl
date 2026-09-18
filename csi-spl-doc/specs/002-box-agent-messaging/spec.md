# Feature Specification: On-Box Agent Messaging (local spool)

**Feature ID**: `002-box-agent-messaging`

**Created**: 2026-09-18

**Status**: Draft

**Input**: "Before the cloud spool bus (003) can exist, implement the messaging
between agents on a single box the way it already works on ysg-box today — the
file-based `inbox/outbox/archive` protocol — but as a clean, uniform, signed,
content-addressed spool with the box API from `SPEC-spool-box-api.md`. Use the
ysg-box implementation as a REFERENCE ONLY; do not touch it."

## Context

This is the **near-term, implementable-now** slice of the spool. The end vision
(cloud hub: Cloud Run + Postgres + GCS + NATS) is `003-spool-message-bus`; this
feature delivers the same **box API** backed only by a **local folder** — the
`003` architecture's "fallback (hub down)" path made first-class and shipped
first. Every agent kind (`CLE-*`, `GRK-*`, `AGY-*`) uses one set of verbs, one
JSON schema, one MCP tool set.

**Reference, not a dependency.** ysg-box already runs a working on-box protocol:
`$MSGS_ROOT/<id>/{inbox,outbox,archive}/` with `<ts>--<from>--<slug>.md` files,
a file leg (source of truth) plus a notification doorbell (`SendMessage` for
live peers, tmux poke / `inbox-send.sh` for shell-side senders), `ListAgents`
for liveness, and the `agent-msg` skill describing the protocol. spec 002 mirrors
that behaviour in a fresh Go implementation under `csi-spl`. **It MUST NOT
modify, import, or depend on ysg-box code** (Constitution: "Reference
implementation is read-only"). ysg-box is read to learn the contract; the spool
owns its own copy.

**What 002 adds over the ysg-box protocol** (so 002 → 003 needs no re-cut):
signed messages (Ed25519 + pins), content-addressed file attachments
(`file_id` = sha256), the canonical `v:1` JSON message object on disk, and a
`spool-tail` view — all defined so the identical CLI/MCP/JSON work unchanged when
a hub is later added.

## User Scenarios & Testing

### User Story 1 - Two agents exchange a signed message on one box (Priority: P1) 🎯 MVP

Agent `GRK-03` sends a signed `task` message to `CLE-07`; `CLE-07` receives it,
verifies the signature against `GRK-03`'s pin, acts, and acks.

**Why this priority**: This is the irreducible spool — signed message in, signed
message out, on one box, no hub. Everything else builds on it.

**Independent Test**: In a temp `$SPOOL_ROOT`, `spool-keygen` + `spool-pin` two
ids, `spool-send --from GRK-03 --to CLE-07 --kind task --body ...`, then
`spool-recv --as CLE-07` returns the message with a verified signature; a
tampered body fails verification with exit `78`.

**Acceptance Scenarios**:

1. **Given** `GRK-03` and `CLE-07` are pinned, **When** `GRK-03` sends a `task`,
   **Then** a `v:1` JSON message lands in `CLE-07`'s inbox with a valid `sig` and
   `spool-recv --as CLE-07` returns it.
2. **Given** a received message, **When** its body is altered on disk, **Then**
   `spool-recv` reports signature failure and exits `78`; the message is not
   returned as valid.
3. **Given** `from` is not pinned or its private key is missing, **When**
   `spool-send` runs, **Then** it refuses (exit `78`) and writes nothing.
4. **Given** `spool-recv --as CLE-07 --ack`, **When** it returns messages,
   **Then** those files move aside (archive) and a second `--ack` run does not
   re-return them.

### User Story 2 - Attach a file by content address (Priority: P2)

An agent puts a file into the spool (getting a `file_id` = sha256), sends a
message referencing it, and the peer fetches it back with hash verification.

**Why this priority**: Handovers routinely carry a patch/zip; content addressing
gives dedupe and integrity for free and matches the `003` GCS model exactly.

**Independent Test**: `spool-put-file ./patch.zip` → `{file_id, sha256, bytes,
name}`; `spool-send ... --file-id <id>`; peer `spool-get-file <id> /tmp/out.zip`
verifies the sha256.

**Acceptance Scenarios**:

1. **Given** a put file, **When** the peer `spool-get-file`s it, **Then** the
   written file's sha256 equals `file_id`.
2. **Given** a `file_id` whose bytes are absent locally, **When**
   `spool-get-file` runs, **Then** it fails clearly (no hub in 002 to fall back
   to) rather than writing a partial file.

### User Story 3 - Human/agent tails a task thread (Priority: P3)

`spool-tail --task <uuid>` shows the messages on a thread in order; `--json`
emits raw NDJSON `v:1` objects.

**Why this priority**: Observability of a running handover; the same view the
hub's NATS tail will later feed.

**Independent Test**: Two messages sharing a `task_id`; `spool-tail --task <id>`
prints both in send order; `--json` round-trips through `jq`.

**Acceptance Scenarios**:

1. **Given** two messages on one `task_id`, **When** `spool-tail --task <id>`,
   **Then** both appear oldest-first.

### User Story 4 - Same behaviour through MCP (Priority: P3)

A Claude/agy agent calls `spool_send` / `spool_recv` / `spool_put_file` /
`spool_get_file` / `spool_tail` as MCP tools and gets byte-identical results to
the CLI (MCP is a thin wrapper).

**Why this priority**: Claude and agy prefer tools; but the CLI is the contract,
so MCP is additive and lower priority than a working CLI.

**Acceptance Scenarios**:

1. **Given** the MCP server, **When** `spool_send` is called with the schema
   args, **Then** it produces the same file + return `{msg_id, task_id, ts}` as
   the CLI, and refuses identically (exit `78` ↔ tool error) on an unpinned
   `from`.

### Edge Cases

- **Name vs id collision**: ids (`CLE-07`) are the address; a display name is
  not. 002 addresses only by id, so two live `CLE-00`s are two distinct dirs.
- **Notification is a doorbell, not the payload**: the file is the source of
  truth. In 002 the notification leg is out of scope for delivery guarantees —
  a receiver drains its inbox dir; a lost poke never loses a message. (Live
  `SendMessage`/tmux poke integration is deferred; see §Out of scope.)
- **Ack races**: two `--ack` receivers on the same inbox must not both claim a
  message; the move-aside must be atomic (rename), last-writer-safe.
- **Clock**: timestamps are `RFC3339 Z`; filenames use `yyyymmddThhmmssZ`. Two
  messages in the same second must not collide (tie-break by `msg_id`).
- **Corrupt/foreign file in a dir**: a non-conforming file in `inbox/` is
  surfaced, not silently skipped, so a malformed drop is visible.

## Requirements

### Functional Requirements

- **FR-001**: The spool MUST expose the CLI verbs `spool-keygen`, `spool-pin`,
  `spool-send`, `spool-recv`, `spool-put-file`, `spool-get-file`, `spool-tail`
  with the arguments in `contracts/cli.md`, backed by a local `$SPOOL_ROOT`.
- **FR-002**: `$SPOOL_ROOT` MUST default to `/var/tmp/claude/msgs` and be
  overridable by env var (Constitution II/VI). No other path is baked in.
- **FR-003**: Messages MUST be the canonical `v:1` JSON object
  (`contracts/message-schema.md`), stored one-per-file under the recipient's
  `inbox/`, named `<yyyymmddThhmmssZ>--<from>--<slug>.json`.
- **FR-004**: `spool-send` MUST sign the canonical payload
  (`jq -cS 'del(.sig)'`, Ed25519) with `from`'s private key and MUST refuse
  (exit `78`) when `from` is unpinned or its key is missing.
- **FR-005**: `spool-recv` MUST verify each message's `sig` against the pinned
  pubkey of its `from`; a failed verification MUST NOT be returned as valid and
  MUST exit `78`.
- **FR-006**: `spool-recv --ack` MUST move returned messages to `archive/`
  atomically (rename), so a message is delivered at most once per ack.
- **FR-007**: `spool-put-file` MUST content-address bytes by sha256, returning
  `{file_id, sha256, bytes, name}`, storing bytes at `files/<file_id>`.
- **FR-008**: `spool-get-file` MUST verify the written file's sha256 equals the
  requested `file_id` and MUST fail (not write a partial) when bytes are absent.
- **FR-009**: `spool-keygen` MUST create an agent Ed25519 keypair with the
  private key `chmod 600`, never inside `$SPOOL_ROOT` and never logged.
- **FR-010**: `spool-pin` MUST record an agent id → pubkey mapping; an unpinned
  author MUST be untrusted (Constitution VIII / trust model).
- **FR-011**: `spool-tail --task <uuid>` MUST list a thread oldest-first;
  `--json` MUST emit raw `v:1` NDJSON.
- **FR-012**: An MCP server MUST expose `spool_put_file`, `spool_send`,
  `spool_recv`, `spool_get_file`, `spool_tail` (`contracts/mcp-tools.md`) as a
  thin wrapper over the CLI with identical behaviour and exit-code mapping.
- **FR-013**: Agent kind MUST appear only as an id prefix on `from`/`to`
  (`CLE-*`/`GRK-*`/`AGY-*`); there MUST be no per-kind field, verb, or tool.
- **FR-014**: The implementation MUST be self-contained under `csi-spl`; it MUST
  NOT read, write, import, or shell out to ysg-box code.

### Non-Functional Requirements

- **NFR-001**: Language Go 1.22+; Ed25519 and sha256 from the standard library.
- **NFR-002**: No private key in `$SPOOL_ROOT`, in git, or in any log
  (Constitution VII).
- **NFR-003**: On-disk `v:1` JSON MUST be byte-for-byte the schema `003` will
  put on the wire, so no migration is needed when the hub arrives.
- **NFR-004**: All file moves that convey delivery (ack) MUST be atomic renames
  within one filesystem.
- **NFR-005**: Go configuration, structured logging, test harness (`internal/testkit`), and shell function utilities (`run-bsh` conventions, `src/bash/`) MUST refer to and follow the patterns in `/opt/pas/pas-psf/pas-psf-api` (`src/internal/config/config.go`, `src/internal/logging/logging.go`, `src/internal/testkit/`, and `src/bash/`).

### Key Entities

- **Agent id**: `CLE-07` / `GRK-03` / `AGY-01` — prefix = kind, the routing key.
- **Message (`v:1`)**: `msg_id`, `task_id`, `ts`, `from`, `to`, `kind`
  (`task`|`result`|`note`|`reject`), `body`, `files[]`, `sig`.
- **File object**: `file_id`(=sha256), `name`, `bytes`, `sha256`.
- **Pin**: agent id → Ed25519 pubkey (trusted authors).
- **Spool root**: `$SPOOL_ROOT/<id>/{inbox,outbox,archive}/` + `files/` + pins.

## Success Criteria

- **SC-001**: In a clean temp `$SPOOL_ROOT`, a full US1 round trip
  (keygen→pin→send→recv→ack) passes end-to-end via the CLI.
- **SC-002**: A tampered message body is rejected with exit `78` and never
  returned as valid.
- **SC-003**: A put→send→get-file round trip verifies sha256 and dedupes
  identical bytes to one `files/<id>` object.
- **SC-004**: MCP `spool_*` calls produce results and files identical to the CLI
  for the same inputs.
- **SC-005**: `go test ./...` for the spool binary is green; a grep proves no
  reference to a ysg-box path in the shipped source.
- **SC-006**: The on-disk `v:1` object validates against
  `contracts/message-schema.md` unchanged (the schema `003` reuses).

## Assumptions

- One box, one filesystem: atomic rename is available for ack moves.
- **Rely on the OS for local security and permissions**: The local model relies on standard POSIX filesystem permissions (`0664`/`0775`), OS user boundaries, and file ownership rather than re-inventing security or access control mechanisms locally. Private keys are protected by standard OS permissions (`chmod 600` under `$HOME/.spool/keys/`).
- The notification/doorbell leg (live poke to a running peer) is delivered by the
  existing box harness; 002 guarantees only the durable file leg. Wiring the
  spool to a live notifier is a later, additive step.
- Private keys live outside `$SPOOL_ROOT` under `$HOME` (`chmod 600`); shared public pins live under `$SPOOL_ROOT/pins/` (`mode 0644`).

## Out of Scope (belongs to 003 or later)

- Cloud Run hub, Postgres, GCS upload, NATS live tail/replay, IAM/OIDC.
- Cross-box delivery and the signed-URL file relay (that is git-rel / 001 + 003).
- A live `SendMessage`/tmux notification integration with delivery semantics.
- Any change to ysg-box.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T00:00:00Z -->
