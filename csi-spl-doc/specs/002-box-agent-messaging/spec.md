# Feature Specification: On-Box Agent Messaging (local spool)

**Feature ID**: `002-box-agent-messaging`

**Created**: 2026-09-18

**Status**: Draft

**Trust (2026-09-18)**: Local 002 is **unsigned** POSIX files (`contracts/trust-modes.md`, binding). Ed25519 box keys are **hub mode** (003/006). Earlier text that required local signatures is superseded.

**Input**: "Before the cloud spool bus (003) can exist, implement the messaging
between agents on a single box the way it already works on ysg-box today — the
file-based `inbox/outbox/archive` protocol — as a clean, uniform,
content-addressed spool (unsigned on one box) with the box API from `SPEC-spool-box-api.md`. Use the
ysg-box implementation as a REFERENCE ONLY; do not touch it."

## Clarifications

### Session 2026-09-18 (owner: follow the trust-modes contract)

- The binding trust-modes document now lives in this git-spec as
  `contracts/trust-modes.md` (moved from `doc/md/`, section numbers kept) and
  wins over any older text here.
- Local mail is unsigned: `spool send`/`recv`/`ack`/`put-*`/`get-*`/`tail`
  need no key and no pin; the stored `v:1` has no `sig`.
- Keys are **per box**, not per agent: `spool keygen [--box <id>]` writes
  `box-<id>.key` (`0600`) and `spool pin --box <id>` writes
  `pins/box-<id>.pub`. Both are optional and unused while `$SPOOL_HUB_URL` is
  unset; a box key never signs local mail.
- A `sig` already on a local file is tolerated, not checked.
- Local exit `78` (and the MCP tool error that mirrors it) is only a content-hash
  mismatch on `get-file`/`get-dir`. A malformed inbox file surfaces as exit `1`.
- `$SPOOL_BOX_ID` has no default; only keygen/pin need it
  (`contracts/trust-modes.md` §2.1).
- The send result gains `delivery` (`local` in 002; `sent`/`queued` in hub
  mode). **003 must consume this**, plus the box key files above;
  `from_box`/`to_box` stay in the hub envelope (trust-modes §5), not in the
  inner `v:1` object. This answers the 002 side of 003 OQ-01.

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

**What 002 adds over the ysg-box protocol**: content-addressed file attachments
(`file_id` = sha256), canonical `v:1` JSON on disk (no `sig` locally), and
`spool-tail`. Hub wrapping (box envelope + WS) is 006; inner JSON stays this
object.

## User Scenarios & Testing

### User Story 1 - Two agents exchange a message on one box (Priority: P1) 🎯 MVP

Agent `GRK-03` sends an **unsigned** `task` to `CLE-07` on the same
`$SPOOL_ROOT`; `CLE-07` recvs and acks. No keygen. Trust is POSIX.

**Why this priority**: One-box MVP must work like today’s msgs dirs.
Box keys wait for hub mode (`contracts/trust-modes.md`).

**Independent Test**: temp `$SPOOL_ROOT`, no keys, send/recv/ack round trip;
message JSON has no `sig`.

**Acceptance Scenarios**:

1. **Given** inbox dirs for GRK-03 and CLE-07, **When** GRK-03 sends a `task`,
   **Then** `v:1` without `sig` lands in CLE-07 inbox and recv returns it.
2. **Given** `$SPOOL_HUB_URL` unset, **When** send runs, **Then** it does not
   require pins or keys (exit `0`).
3. **Given** `spool-recv --as CLE-07 --ack`, **When** it returns messages,
   **Then** those files archive and a second `--ack` does not re-return them.

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
   args, **Then** it produces the same file + return
   `{delivery, msg_id, task_id, ts}` as the CLI, and `spool_get_file` refuses
   identically (exit `78` ↔ tool error) on a content-hash mismatch.

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
- **FR-004**: When `$SPOOL_HUB_URL` is unset, `spool-send` MUST write `v:1`
  **without** `sig` and MUST NOT require keys.
- **FR-005**: When `$SPOOL_HUB_URL` is unset, `spool-recv` MUST NOT require
  `sig`; a `sig` present on a local file is tolerated, not checked. (Hub-mode
  box-envelope verify is 003/006.)
- **FR-006**: `spool-recv --ack` MUST move returned messages to `archive/`
  atomically (rename), so a message is delivered at most once per ack.
- **FR-007**: `spool-put-file` MUST content-address bytes by sha256, returning
  `{bytes, file_id, kind, name, sha256}`, storing bytes at `files/<file_id>`.
- **FR-008**: `spool-get-file` MUST verify the written file's sha256 equals the
  requested `file_id` and MUST fail (not write a partial) when bytes are absent.
- **FR-009**: `spool-keygen` (hub prep) MUST create a **box** Ed25519 keypair
  (`box-<id>.key`, `chmod 600`) outside `$SPOOL_ROOT`. Unused while hub unset.
- **FR-010**: `spool-pin` in hub mode records **box_id → pubkey** (tenant root
  on the hub). Local mode does not consult pins for send/recv.
- **FR-011**: `spool-tail --task <uuid>` MUST list a thread oldest-first;
  `--json` MUST emit raw `v:1` NDJSON.
- **FR-012**: An MCP server MUST expose `spool_put_file`, `spool_send`,
  `spool_recv`, `spool_get_file`, `spool_tail` (`contracts/mcp-tools.md`) as a
  thin wrapper over the CLI with identical behaviour and exit-code mapping.
- **FR-013**: Agent kind MUST appear only as an id prefix on `from`/`to`
  (`CLE-*`/`GRK-*`/`AGY-*`); there MUST be no per-kind field, verb, or tool.
- **FR-014**: The implementation MUST be self-contained under `csi-spl`; it MUST
  NOT read, write, import, or shell out to ysg-box code.
- **FR-015**: Legacy `.md` Bridge (Option B): `spool-recv` MUST transparently ingest legacy `.md` messages found in `$SPOOL_ROOT/<id>/inbox/`, wrapping them in synthetic `v:1` envelopes (`kind: "note"`, no `sig`, parsed `ts` and `from`), and archive them atomically on `--ack` alongside `.json` messages.

### Non-Functional Requirements

- **NFR-001**: Language Go 1.25+ (the go-sdk v1.8.0 floor); Ed25519 and sha256
  from the standard library.
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
  (`task`|`result`|`note`|`reject`), `body`, `files[]`; no `sig` locally.
- **File object**: `file_id`(=sha256), `name`, `bytes`, `sha256`.
- **Box pin**: box id → Ed25519 pubkey (hub mode only; unused locally).
- **Spool root**: `$SPOOL_ROOT/<id>/{inbox,outbox,archive}/` + `files/` + pins.

## Success Criteria

- **SC-001**: In a clean temp `$SPOOL_ROOT`, a full US1 round trip
  (send→recv→ack, no keygen, no pin) passes end-to-end via the CLI.
- **SC-002**: Local recv returns unsigned `v:1`; hub-mode tamper/sig tests
  live in 006.
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

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:30:00Z -->
