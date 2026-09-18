# csi-spl-api

Holds the Go codebase (`src/go/spool-hub-api`) for:
- The uniform spool box CLI (`spool-send`, `spool-recv`, `spool-put-file`, `spool-get-file`, `spool-tail`, `spool-keygen`, `spool-pin`)
- The stdio MCP server exposing `spool_*` tools for Claude Code and Antigravity
- The stateless Cloud Run hub API (WebSocket `/v1/ws` for messages, tasks, and tail; REST for `/v1/files`, `/v1/pins`)
- Local fallback queue and flush helpers
