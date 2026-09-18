# Contract: MCP tools (canonical names, thin wrapper over the CLI)

Stdio process per agent session (`spool mcp`), spawned as a child by Claude Code
or Antigravity. Same **binary** as the CLI, shared `$SPOOL_ROOT` and pins. This is
the session’s MCP transport, not a long-lived daemon per tmux window (that shape is
rejected in the constitution). Each tool calls the same internal action as the CLI.

## `spool_put_file`
```json
{ "path": "/abs/or/rel/file" }
```
→ `{ "bytes": 12044, "file_id": "<sha256>", "kind": "file", "name": "patch.zip", "sha256": "<same>" }`

## `spool_send`
```json
{ "from": "GRK-03", "to": "CLE-07", "task_id": "<uuid>", "kind": "task",
  "body": "review this", "file_ids": ["<sha256>"] }
```
`kind ∈ task|result|note|reject`. Unsigned in local mode: no key or pin
needed (`trust-modes.md` §2).
→ `{ "delivery": "local", "msg_id": "...", "task_id": "...", "ts": "..." }`

## `spool_recv`
```json
{ "as": "CLE-07", "ack": false }
```
→ list of `v:1` message objects (verified). `ack: true` moves them to `archive/`.

## `spool_get_file`
```json
{ "file_id": "<sha256>", "dest": "/tmp/patch.zip" }
```
→ `{ "file_id": "<sha256>", "path": "..." }` (what `spool get-file` prints).
Verifies the hash.

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
- A tool's text content is byte-for-byte the CLI verb's stdout (without the
  trailing newline); object results are also returned as structured content.
  A failure is `IsError` with text `spool: <reason> (exit <code>)`, the CLI's
  stderr line plus its exit code; locally `78` is only a hash mismatch in
  `spool_get_file`. `spool_recv` with a malformed inbox file returns the good
  array and that error text (`exit 1`), flagged `IsError`, as the CLI prints
  the array and exits `1`.
- **Library:** `github.com/modelcontextprotocol/go-sdk` (official, v1.7.0+),
  stdio via `mcp.StdioTransport`. See `../research.md`. Not `mark3labs/mcp-go`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:30:00Z -->
