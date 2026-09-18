# csi-spl-api

Holds the Go codebase (`src/go/spool-hub-api`) for:
- The uniform spool box CLI (`spool-send`, `spool-recv`, `spool-put-file`, `spool-get-file`, `spool-tail`, `spool-keygen`, `spool-pin`)
- The stdio MCP server exposing `spool_*` tools for Claude Code and Antigravity
- The stateless Cloud Run HTTP hub API (`POST /v1/messages`, `GET /v1/messages`, `POST /v1/files`, `GET /v1/files/{file_id}`)
- Local fallback queue and flush helpers
