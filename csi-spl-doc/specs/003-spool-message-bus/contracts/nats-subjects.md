# Contract: Live notify subjects — DEFERRED (post-M1)

Feature: `003-spool-message-bus`, User Story 4.
Status: **deferred / post-M1. Nothing in this file is implemented in M1.**

- OQ-04 (resolved): the M1 live tail is **frames on the existing WebSocket**
  (`tail` / `tail_msg` / `tail_end` in `./http-v1.md` §2.1). No SSE, no NATS.
- OQ-12 (resolved, N/A in M1): no pub/sub subjects exist in M1. If NATS is
  revived after M1, the inbox subject is `tenant.<tenant>.box.<box_id>.inbox`.

The rules below still bind **any** notify transport, including the M1 WS tail
frames.

NATS is the radio. Spool JSON is the meaning.

## Subject shape (post-M1 only)

The 0.1.0 draft used `task.<task_id>` and `agent.<agent-id>.inbox`. Both
predate two decisions:

- agent ids are unique **per box** only (`CLE-07@box-a` ≠ `CLE-07@box-b`), so
  an agent subject needs the `box_id`;
- the hub is multi-tenant from M1, so every subject needs the tenant or the
  tenants must be isolated by account/connection.

The post-M1 shape, if NATS is chosen, is `tenant.<tenant>.box.<box_id>.inbox`
(OQ-12). Whatever format is chosen MUST satisfy the rules below.

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

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:55:00Z -->
