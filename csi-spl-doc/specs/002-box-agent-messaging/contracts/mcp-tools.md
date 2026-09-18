# Contract: MCP tools (canonical names, thin wrapper over the CLI)

Stdio process per agent session (`spool mcp`), spawned as a child by Claude Code
or Antigravity. Same **binary** as the CLI, shared `$SPOOL_ROOT` and pins. This is
the session’s MCP transport, not a long-lived daemon per tmux window (that shape is
rejected in the constitution). Each tool calls the same internal action as the CLI.

## `spool_put_file`
```json
{ "path": "/abs/or/rel/file" }
```
→ `{ "file_id": "<sha256>", "sha256": "<same>", "bytes": 12044, "name": "patch.zip" }`

## `spool_send`
```json
{ "from": "GRK-03", "to": "CLE-07", "task_id": "<uuid>", "kind": "task",
  "body": "review this", "file_ids": ["<sha256>"] }
```
`kind ∈ task|result|note|reject`. Signs with `from`'s key. Fails (tool error,
== CLI exit 78) if `from` is not pinned or its key is missing.
→ `{ "msg_id": "...", "task_id": "...", "ts": "..." }`

## `spool_recv`
```json
{ "as": "CLE-07", "ack": false }
```
→ list of `v:1` message objects (verified). `ack: true` moves them to `archive/`.

## `spool_get_file`
```json
{ "file_id": "<sha256>", "dest": "/tmp/patch.zip" }
```
→ `{ "path": "...", "bytes": 12044, "sha256": "<same>" }`. Verifies the hash.

## `spool_tail`
```json
{ "task_id": "<uuid>", "json": false }
```
Human lines by default; `json: true` → raw `v:1` NDJSON objects.

## Rules

- Tool names are canonical and kind-agnostic. Do NOT add `spool_send_claude` /
  `spool_send_grok` — one `spool_send` (Constitution VIII).
- A tool's behaviour, arguments, and refusal semantics MUST equal the CLI verb it
  wraps (verify/refuse surfaces as a tool error mirroring exit `78`).
- Research decision (fill in plan Phase 0): which Go MCP server library backs the
  stdio transport.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
