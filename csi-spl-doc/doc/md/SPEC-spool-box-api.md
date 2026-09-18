# SPEC: Uniform box API to spool

Status: binding for all agent kinds  
Related: `SPEC-agent-spool-mvp.md`, `SPEC-spool-architecture.md`

---

## 1. Rule

Every AI agent on a box talks to spool through **the same API**.
Kind (`claude` / `grok` / `agy`) must not change field names, URLs, or tool names.

How they invoke may differ:

| Kind | Invocation |
|---|---|
| Claude Code | MCP tools (preferred) or CLI |
| Antigravity (`agy`) | MCP tools or CLI |
| Grok CLI / scripts | CLI (same verbs) |

No per-kind HTTP dialect. No per-kind JSON.

---

## 2. Box surface

On each box that may run an agent:

- CLI: `spool-put-file`, `spool-send`, `spool-recv`, `spool-get-file`, `spool-tail`, `spool-keygen`, `spool-pin`
- **One** MCP server per box exposing the tools below
- Same binary/code behind both

Agents do not import NATS, Postgres, GCS, or Cloud Run SDKs.

---

## 3. MCP tools (canonical names)

### `spool_put_file`

```json
{ "path": "/abs/or/rel/file" }
```

Returns:

```json
{ "file_id": "<sha256 hex>", "sha256": "<same>", "bytes": 12044, "name": "patch.zip" }
```

### `spool_send`

```json
{
  "from": "GRK-03",
  "to": "CLE-07",
  "task_id": "<uuid>",
  "kind": "task",
  "body": "review this",
  "file_ids": ["<sha256 hex>"]
}
```

`kind`: `task` | `result` | `note` | `reject`.  
Signs with `from`’s key. Fails if `from` is not pinned or key missing.

Returns: `{ "msg_id", "task_id", "ts" }`

### `spool_recv`

```json
{ "as": "CLE-07", "ack": false }
```

Returns a list of message objects (schema v1). Optional `ack: true` moves them aside.

### `spool_get_file`

```json
{ "file_id": "<sha256 hex>", "dest": "/tmp/patch.zip" }
```

Returns `{ "path", "bytes", "sha256" }`. Verifies hash.

### `spool_tail`

```json
{ "task_id": "<uuid>", "json": false }
```

Human lines by default; `json: true` for raw NDJSON objects.

Do not add `spool_send_claude` / `spool_send_grok`. One send.

---

## 4. CLI mapping (must stay 1:1)

```
spool-put-file <path>
spool-send --from --to --task --kind --body [--file-id ...]
spool-recv --as [--ack]
spool-get-file <file_id> <dest>
spool-tail [--task] [--json]
```

MCP is a wrapper around these. Behaviour and exit codes match.

Verify/refuse: exit `78` (same as ysg-box `directive-verify`).

---

## 5. Message object (shared)

```json
{
  "v": 1,
  "msg_id": "<uuid>",
  "task_id": "<uuid>",
  "ts": "<RFC3339 Z>",
  "from": "GRK-03",
  "to": "CLE-07",
  "kind": "task",
  "body": "review this",
  "files": [
    { "file_id": "<sha256>", "name": "patch.zip", "bytes": 12044, "sha256": "<sha256>" }
  ],
  "sig": "<base64>"
}
```

Canonical sign payload: `jq -cS 'del(.sig)'`. Ed25519. Pin required.

---

## 6. File + notify flow (Grok example, same for all kinds)

1. `spool_put_file` / `spool-put-file ./patch.zip`
2. Bytes → GCS/S3 via `POST /v1/files` (or local `$SPOOL_ROOT/files/<id>` if hub down)
3. `spool_send` with `file_ids`
4. CLI signs; `POST /v1/messages`
5. Hub verifies pin+sig → Postgres
6. NATS notify `task.<task_id>` and `agent.CLE-07.inbox` (JSON only, no bytes)
7. Peer `spool_recv` + `spool_get_file`

---

## 7. HTTP the CLI may call (hub)

```
POST /v1/files
GET  /v1/files/{file_id}
POST /v1/messages
GET  /v1/messages?as=&task_id=
```

Box CLI hides these. Agents never call them directly.

---

## 8. Invariants

- Same tool names on every box image
- Same JSON `v: 1` on wire and in the local folder
- Kind of agent is not a field on the API except as `from` / `to` ids (`CLE-*`, `GRK-*`, `AGY-*`)
- New vendor = new id prefix + same tools, not a new API

---

## 9. Out of this spec

Kafka, per-kind endpoints, per-agent cloud keys, MCP server per tmux window,
token SSE (that stays on the coding adapter, not spool).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T12:50:00Z -->
