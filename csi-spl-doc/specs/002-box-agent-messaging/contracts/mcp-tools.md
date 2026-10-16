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

## `spool_read_link`
```json
{ "url": "https://<workspace host>/t/<uuid>", "json": false }
```
(== `spool tail --url <link> [--desks <dir> --desk-box <box>]`, SPL-2112.)
Reads the discussion a WUI link names. Link forms: `/t/<uuid>[#<msg>]`,
`/m/<id>` (taken as a topic id), any page with `?topic=<uuid>` (`/`,
`/channel/<name>`, `/dm/<peer>`), each with an optional locale prefix
(`/fi/t/<uuid>`), and a bare topic uuid. The workspace comes from the link,
not from the seat: the server tries this box's hub desks
(`<desks>/<tenant>/<desk box>`, each a live `spool hub-run` whose settings it
takes) with the link host's first label first, then its own workspace, then
the others by name, and reads the topic as that desk box (`hub-tail`): the
hub serves a box only what it may read, so nothing new is exposed. Output: a
header `topic <uuid> in workspace <t>, read through desk <box>: <n>
message(s), oldest first`, then `ts  msg_id  from@box -> to@box  [kind]
body` per message; `json: true` → NDJSON, no header. No desk holds a
message of it → `IsError`: `topic <uuid>: no messages visible to <seat> in
workspace <tried, ...>; if the link is from another workspace, this box
cannot read it: a seat in <label>: ask the orchestrator (exit 1)`. Reading
changes no seat.

## `spool_reply`
```json
{ "url": "https://<workspace host>/t/<uuid>", "body": "<markdown>", "kind": "msg" }
```
Posts into the linked topic as the server's seat (a seated server only; it
never posts as a person). It reads the topic as `spool_read_link` does, then,
when the seat has no seat dir on that workspace's desk, seats it with the
server's `--seat-cmd` (spool-mcp.sh `--seat`: `do_spl_desk_up`, the existing
desk action; the call is the request). The post goes to the topic's newest
human (`to_box` box-wui), else its first other sender, with `task_id` = the
topic: spec 067 rule 2's shape. Result: `spool_send`'s JSON. No `--seat-cmd`
and no seat → `IsError` naming the workspace to ask for.

## A session the spool did not start (SPL-2112)

The owner starts a plain `claude` on a box by hand (no spawn window, no
`AGENT_ID`, no lane worktree), pastes a WUI discussion link, and the session
reads it and posts in it. The box's `spool-<env>` registration
(`do_spl_agent_mcp_install`) runs `spool-mcp <env>`, which since SPL-2112:

1. **Mints an id** when it finds none (`MCP_BOT_AGENT_ID`, `SPOOL_AGENT_ID`,
   the tmux window): the box half claims the next free id of the CLI's kind
   with the fleet's allocator (`next-agent-id.sh` of the checkout the desk
   sidecar runs from, in its fleet root), records `<fleet root>/<id>/minted`,
   and retires the id (`agent-id-retire.sh`, desk seats included) when the
   server exits. It never takes a person's identity or another agent's id.
   `SPOOL_MCP_MINT=0` refuses instead (exit 4, as before).
2. **Takes the workspace from the link**: with no tenant named it no longer
   refuses 0 or 2+ seats (exit 5); it serves from the fleet tenant's desk,
   else the first seated, else the first live one, and passes the box's desk
   dir (`--desks`), so `spool_read_link` / `spool_reply` follow a link into
   any workspace this box has a desk in. A named tenant with no seat still
   refuses (5).
3. **Joins on request**: `spool_reply` into a workspace the id has no seat in
   runs `spool-mcp --seat <env> <box> <tenant> <id>`, which is
   `do_spl_desk_up` (`DESK_POKE=0`) of the sidecar's checkout: no operator
   step. The post takes spec 067 rule 2's shape: in the topic, to its
   newest human on box-wui (the way a desk answers in a channel topic).

Only on a box that has a desk in that workspace; elsewhere the read and the
reply refuse with the reason above.

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
- **Seated server** (`spool mcp --as <ID>`, or `$SPOOL_MCP_AS`; added
  2026-09-25): the server acts for that one agent. `spool_send.from` and
  `spool_recv.as` are then optional and default to the seat; any OTHER value
  is refused as `spool: from "<x>": this server is seated as <ID> ... (exit 78)`
  before a file is read or written. In hub mode a seated `spool_send` to a
  human (`HUM-*`) with no `to_box` goes to `box-wui`. It is how a desk agent
  gets the tools without a key of its own: the box user runs the server once
  per session, the server holds the box key, and the agent names no inbox but
  its own. The five tool names and their unseated behaviour are unchanged.
- **Library:** `github.com/modelcontextprotocol/go-sdk` (official, v1.7.0+),
  stdio via `mcp.StdioTransport`. See `../research.md`. Not `mark3labs/mcp-go`.

<!-- version: 0.3.0 · updated: 2026-10-16 · last-edit: 2026-10-16T08:30:00Z -->
