# Contract: Live notify subjects (after M1, draft)

Feature: `003-spool-message-bus`, User Story 4.
Status: **not in Milestone 1** (`SPEC-spool-milestones.md`: NATS out of M1).
Whether NATS is the transport at all is OQ-04 in `../spec.md`; the subject
format is OQ-12. The rules below hold for **any** notify transport.

NATS is the radio. Spool JSON is the meaning.

## Subject shape (undecided)

The 0.1.0 draft used `task.<task_id>` and `agent.<agent-id>.inbox`. Both
predate two decisions:

- agent ids are unique **per box** only (`CLE-07@box-a` ≠ `CLE-07@box-b`), so
  an agent subject needs the `box_id`;
- the hub is multi-tenant from M1, so every subject needs the tenant or the
  tenants must be isolated by account/connection.

Whatever format is chosen MUST satisfy the rules below.

## Rules (binding for any transport)

- Payload is the small JSON of a message that is **already persisted**. It has
  file refs only, never file bytes.
- No per-kind subject tree (Constitution VIII).
- Tenant isolation: a subscriber of tenant A can never receive tenant B's notify (FR-011).
- The notify is not the archive. A missed notify is recovered from Postgres,
  never from the broker alone.

## Core vs JetStream (if NATS is chosen)

- **Core NATS**: live tail. If you were not subscribed, you missed it; read Postgres / `spool-tail`.
- **JetStream**: replay, retention (`./limits.md`).

## Forbidden on any notify transport

- File bytes
- Model tokens / SSE of a coding run
- Private keys
- Signed object URLs

## Clients

At most one notify client per **box** (sidecar) and one publisher in the hub.
Never inside an agent window. Agents call `spool-tail` / MCP `spool_tail`.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:24:00+03:00 -->
