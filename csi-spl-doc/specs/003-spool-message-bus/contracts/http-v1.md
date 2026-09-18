# Contract: Hub HTTP API v1 (box CLI hides this; agents never call it)

Stateless Cloud Run. The box CLI/MCP is the only client; agents never call these
endpoints directly (Constitution VIII). Message and file shapes are the frozen
`002` contracts (`../../002-box-agent-messaging/contracts/`). Live-notify
subjects are in `./nats-subjects.md`.

```
POST /v1/files                 # upload bytes → { file_id, sha256, bytes }
GET  /v1/files/{file_id}       # download bytes (or short-lived signed URL); caller re-hashes == file_id
POST /v1/messages              # submit a v1 message (verify pin+sig → PG, notify NATS)
GET  /v1/messages?as=&task_id= # list messages for an agent / thread
GET  /healthz                  # liveness / health probe (returns 200 OK)
GET  /version                  # build / version metadata (version, commit, built_at)
```

## POST /v1/messages

1. Body is a `v:1` message object (`../../002-box-agent-messaging/contracts/message-schema.md`).
2. Hub looks up `from`'s pin; absent → **400**, nothing persists.
3. Hub recomputes the canonical payload (`jq -cS 'del(.sig)'`) and verifies `sig`;
   invalid → **400**.
4. Valid → insert a row in Postgres; publish `task.<task_id>` on NATS (JSON only).
5. → `{ "msg_id", "task_id", "ts" }`.

## POST /v1/files / GET /v1/files/{id}

- Bytes stored in GCS keyed by `file_id` (=sha256). No metadata in GCS.
- GET streams bytes or hands back a short-lived signed URL; the URL is never
  logged or persisted (Constitution VII). The box CLI re-hashes and refuses a
  mismatch (never writes a partial) — same guarantee as `002` `spool-get-file`.

## Trust & ingress

- **IAM/OIDC** gates who may reach Cloud Run (the door — the box adapter identity). IAM/OIDC auth applies **strictly between boxes and Cloud Run across the network**. Communication on a single local box does not use IAM.
- **Ed25519 pin** gates who authored the message (the author), both locally on-box and across boxes.
- Never conflated: a valid signature does not grant ingress, and ingress does not substitute for a signature.

## Failure semantics

| Failure | Response |
|---|---|
| bad / unpinned signature | HTTP 400, no persist (== exit `78` at the CLI) |
| no ingress IAM | refused at the door before signature verify (401/403) |
| NATS down | row still lands in PG; tail stale until replay |
| GCS down | refuse file send; text-only MAY proceed if policy allows |
| hub unreachable | box CLI writes the local `002` queue; sidecar flushes later |

## Invariants

- Same `v:1` JSON on the wire as `002` writes to disk (no migration).
- Cloud Run is stateless: no file bytes on container disk.
- Kind of agent is not a field — only the `from`/`to` id prefix.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T12:55:00Z -->
