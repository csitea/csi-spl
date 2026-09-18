# SPEC: Uniform box API to spool

Status: binding for all agent kinds  
Related: `SPEC-spool-message-bus.md`, `SPEC-spool-identity-routing.md`, `SPEC-spool-task-lifecycle.md`

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

- CLI: `spool-put-file`, `spool-send`, `spool-recv`, `spool-get-file`, `spool-tail`, `spool-keygen`, `spool-pin` (or `spool <verb>`; also includes `put-dir`, `get-dir`). Operator/hub verbs in the same binary: `serve`, `migrate`, `hub-tenant`, `root-keygen`, `hub-pin`, `hub-sync`, `hub-run`, `hub-tail`, `version`.
- MCP: one **binary** on the box; Claude/agy spawn `spool mcp` as a **stdio child per agent session** (not a daemon per tmux window, not a second schema)
- Same binary/code behind both

### 2.1 Standard Box Launcher (`spool-harness`)

To prevent manual environment configuration and ensure clean lifecycle bootstrapping, the box image provides `spool-harness`:

```bash
spool-harness --as <agent_id> [--to-box <box_id>] [--] <agent-cli-command...>
```

`spool-harness` executes the following initialization sequence before exec'ing the agent process:
1. **Directory Preparation**: Ensures `$SPOOL_ROOT/<agent_id>/{inbox,outbox,archive}` and shared `$SPOOL_ROOT/{files,pins}` exist with correct permissions (`0775`/`0664`).
2. **Identity Verification**: Verifies `$SPOOL_BOX_ID` and checks the box keypair (`$HOME/.spool/keys/box-<box_id>.key`, `0600`). In local mode, keys are optional.
3. **Sidecar Lifecycle**: If `$SPOOL_HUB_URL` is set, ensures the background WebSocket client is running, connected, and has announced the local agent roster (`<agent_id>`).
4. **Environment Injection**: Sets `SPOOL_ROOT`, `SPOOL_BOX_ID`, and `SPOOL_AGENT_ID`.
5. **Session Exec**: Replaces itself via `exec` with the target command (e.g. `claude`, `grok`, or `antigravity`).

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
In local mode, unsigned (POSIX trust). In hub mode, wraps in envelope signed with the sending box key (`box-<box_id>.key`). Fails if box key missing or box unpinned.

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

Inner `v:1` message payload (local disk and inside hub wire envelope):

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
  ]
}
```

- **Local mail**: written as above without `sig` and without `box_id` (POSIX filesystem trust).
- **Hub mode**: inner `v:1` is wrapped inside an `Envelope` signed by the sending box key:

```json
{
  "from_box": "box-a",
  "to_box": "box-b",
  "msg": { "v": 1, "msg_id": "...", "from": "GRK-03", "to": "CLE-07", "...": "..." },
  "sig": "<base64 ed25519 signature of canonical '{from_box,msg,to_box}'>"
}
```

Canonical sign payload: `jq -cS '{from_box,msg,to_box}'`. Ed25519 box key. Box pin required in tenant pins table.

---

## 6. File + notify flow (Grok example, same for all kinds)

1. `spool_put_file` / `spool-put-file ./patch.zip`
2. Bytes → GCS via `POST /v1/files` using WS-issued upload token (or local `$SPOOL_ROOT/files/<id>` if hub down)
3. `spool_send` with `file_ids`
4. CLI signs outer envelope with box key; sends via WebSocket `/v1/ws` (`send` frame)
5. Hub verifies box pin + signature → persists to Postgres
6. Hub pushes `recv` frame over WebSocket to destination box's live `role=box` connection (or queues in Postgres if offline); streams to live `tail` frames
7. Peer box sidecar writes to `$SPOOL_ROOT/<to>/inbox/`; peer agent reads inbox or calls `spool_recv` + `spool_get_file`

---

## 7. HTTP and WebSocket the CLI may call (hub)

```
WS     /v1/ws challenge, hello, roster, send envelope, recv + tail frames
POST   /v1/files upload bytes with upload token → { file_id, sha256, bytes }
GET    /v1/files/{file_id} tenant-scoped capability: the bytes
GET    /v1/pins tenant box pubkeys (authorized_keys sync)
POST   /v1/pins pin a box pubkey, tenant-root signed
DELETE /v1/pins/{box_id} revoke a box pin, tenant-root signed
GET    /healthz liveness
GET    /version { version, commit, built_at }
```

Send and recv are WebSocket only (OQ-02). `POST/GET /v1/messages` and `POST /v1/recv` are deleted/superseded.
Box CLI and sidecars hide these. Agents never call them directly.

---

## 8. Invariants

- Same tool names on every box image
- Same JSON `v: 1` on wire and in the local folder
- Kind of agent is not a field on the API except as `from` / `to` ids (`CLE-*`, `GRK-*`, `AGY-*`)
- New vendor = new id prefix + same tools, not a new API

---

## 9. Out of this spec

Kafka, per-kind endpoints, per-agent cloud keys, a long-lived MCP **daemon**
per tmux window (stdio child per session is the invocation), token SSE
(that stays on the coding adapter, not spool).

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:30:00Z -->
