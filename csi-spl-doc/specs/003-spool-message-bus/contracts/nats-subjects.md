# Contract: NATS subjects

Feature: `003-spool-message-bus`  
NATS is the radio. Spool JSON is the meaning. Optional until US4.

## Subjects

| Subject | Payload | When |
|---|---|---|
| `task.<task_id>` | `v:1` JSON **without file bytes** (same object as Postgres, `files[]` metadata only) | after a message is persisted |
| `agent.<agent-id>.inbox` | same JSON | directed notify to `to` |

`task_id` and `agent-id` are the spool ids (`UUIDv4`, `CLE-07`). No per-kind subject tree.

## Core vs JetStream

- **Core NATS**: live tail. If you were not subscribed, you missed it — read Postgres / `spool-tail`.
- **JetStream**: durable inbox per agent, replay, ack, retention. Same subjects.

## Forbidden on NATS

- File bytes
- Model tokens / SSE of a coding run
- Private keys
- Signed object URLs

## Clients

One NATS client per **box** (sidecar) and one publisher in Cloud Run. Not inside each agent window. Agents call `spool-tail` / MCP `spool_tail`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T12:50:00Z -->
