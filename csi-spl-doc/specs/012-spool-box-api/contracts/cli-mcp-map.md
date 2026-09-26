# Contract: CLI verb ↔ MCP tool (012)

Binding source: `../../../doc/md/SPEC-spool-box-api.md` §3-§4. Field-level
detail of each verb stays in `../../002-box-agent-messaging/contracts/cli.md`
and `mcp-tools.md`; this table is the 1:1 check, not a restatement.

## 1. Mapping

| CLI | MCP tool | MCP input (JSON) | Result (JSON) |
|---|---|---|---|
| `spool put-file <path>` | `spool_put_file` | `path` | `file_id`, `sha256`, `bytes`, `name` (+ `kind`) |
| `spool send --from --to [--task] --kind --body [--file-id …] [--to-box]` | `spool_send` | `from`, `to`, `task_id`, `kind`, `body`, `file_ids`, `to_box` | `msg_id`, `task_id`, `ts` (+ `delivery`) |
| `spool recv --as [--ack]` | `spool_recv` | `as`, `ack` | array of messages. Readers accept `v:1` and `v:2` (020 FR-001). The MCP description string still says `v:1` |
| `spool get-file <file_id> <dest>` | `spool_get_file` | `file_id`, `dest` | `path`, `bytes`, `sha256` (+ `file_id`) |
| `spool tail [--task] [--json]` | `spool_tail` | `task_id`, `json` | human lines, or NDJSON of the stored object (`v:1` or `v:2`) |

`(+ …)` marks additive fields (003 OQ-01): allowed, never renamed.
`--to-box` / `to_box` are hub-mode only.

CLI-only by design: `send --file-ref|--dir-blob|--dir-ref|--put-file`,
`put-dir`, `get-dir`, `keygen`, `pin` and the hub/operator verbs. The narrative
names five tools. The one addition is `spool_issue` (hub mode, == `spool issue
<op> --as`, specs/039 issues-v1 §6, 2026-09-26): the canonical-names check
lists six, and a seventh would break it.

## 2. Exit codes

| code | CLI | MCP |
|---|---|---|
| 0 | ok | result |
| 78 | verify/refuse: hash mismatch, unpinned box, bad signature | tool error, text ends `(exit 78)` |
| 1 | anything else | tool error, text ends `(exit 1)` |

## 3. What pins this

| Row | Test |
|---|---|
| every row of §1, identical files and text | `TestSC004MCPEqualsCLI` (`internal/mcp/mcp_test.go`) |
| exactly five names + `spool_issue` | `TestToolNamesAreCanonical` |
| 78 on the CLI and as a tool error | `TestSC004MCPEqualsCLI` (corrupted blob) |
| partial recv output + error | `TestRecvMalformedIsToolError` |

<!-- version: 1.0.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:18:58Z -->
