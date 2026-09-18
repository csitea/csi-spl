# Research: Go MCP library for `spool mcp`

Feature: `002-box-agent-messaging` · Date: 2026-09-18  
Decision: **use the official SDK** `github.com/modelcontextprotocol/go-sdk`.

Spool needs a **stdio** MCP server in the same binary as the CLI (`spool mcp`),
five tools, no HTTP MCP, no OAuth. Cleanliness and spec fidelity beat star
count.

## Candidates

| | Official `go-sdk` | Community `mcp-go` |
|---|---|---|
| Module | `github.com/modelcontextprotocol/go-sdk` | `github.com/mark3labs/mcp-go` |
| Stewards | MCP project + Google (gopls JSON-RPC) | mark3labs / community |
| License | Apache-2.0 (new) / MIT (legacy) | MIT |
| Popularity | ~5k stars, catching up | ~8–9k stars, most existing servers |
| Spec | v1.7.0+ → MCP **2026-07-28** | v0.58 / v1.0 line; 2026-07-28 in 1.0 |
| Stdio | `mcp.StdioTransport` first-class | yes, plus SSE / streamable HTTP |
| API | typed `AddTool`, schema from Go structs | more middleware/session kitchen sink |

`mcp-golang` and `ThinkInAIXYZ/go-mcp` are smaller; not worth a third option.

## Why official, not mcp-go

1. **Minimal surface.** Design doc (go-sdk `design/design.md`) explicitly
   diverges from mcp-go to stay small and track spec evolution. We wrap five
   tools; we do not want SSE, per-session tool filters, or HTTP MCP.
2. **JSON-RPC from gopls**, not a one-off. Cancellation and protocol edge
   cases are already paid for.
3. **Stdio is the example.** `server.Run(ctx, &mcp.StdioTransport{})` is the
   README. That is `spool mcp`.
4. **Spec owner.** New MCP revisions land here first. GitHub’s own
   `github-mcp-server` **migrated off mcp-go onto go-sdk** (PR 1428).
5. Popularity of mcp-go is inertia from before v1.0 of the official SDK. For a
   **new** binary, that is the wrong default.

We are not an MCP gateway. Extra transports in mcp-go are unused weight.

## Pin

```
github.com/modelcontextprotocol/go-sdk  v1.7.0 or newer (same major)
```

Import `github.com/modelcontextprotocol/go-sdk/mcp`. Floor **v1.7.0** so the
2026-07-28 spec is in range. Do not import `mark3labs/mcp-go`.

Resolved on 2026-09-18: **v1.8.0**, fetched once into the offline module
cache (owner-approved). It requires `go 1.25.0`, so the module's `go`
directive moved from 1.22 to 1.25.0; the box toolchain is go1.25.1.

## Shape in this repo

```go
server := mcp.NewServer(&mcp.Implementation{Name: "spool", Version: version}, nil)
mcp.AddTool(server, &mcp.Tool{Name: "spool_send", Description: "..."}, send)
// ... spool_recv, spool_put_file, spool_get_file, spool_tail
err := server.Run(ctx, &mcp.StdioTransport{})
```

Each handler calls the **same** `internal/` action as the CLI verb. Tool
errors map CLI exit `78` to `IsError` + message (`contracts/mcp-tools.md`).

## Rejected

- Hand-rolling JSON-RPC on stdio.
- mcp-go “because examples.”
- HTTP/SSE MCP (hub is WebSocket for mail, not MCP).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:00:00Z -->
