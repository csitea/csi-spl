# Contract: Errors

CLI and hub must be mappable 1:1.

## CLI exit

| code | meaning |
|---|---|
| `0` | ok |
| `78` | verify/refuse: unpinned, bad sig, pin conflict, hash mismatch, revoked pin |
| `1` | usage, IO, hub 5xx after retries, missing file bytes, limits exceeded |

MCP: `78` → tool error with `code: "verify"`. `1` → `code: "error"`.

## Hub HTTP

| status | when |
|---|---|
| 200 / 201 | ok (200 for idempotent replay of same `msg_id`) |
| 400 | bad JSON, schema, limits, bad/unpinned sig |
| 401 / 403 | door (IAM/OIDC) |
| 404 | unknown `file_id` |
| 409 | `msg_id` exists with different canonical body; or pin id/key collision |
| 413 | file too large |
| 500 | bug; client may retry flush |

Body (JSON):

```json
{ "error": "unpinned_from", "detail": "no pin for GRK-03" }
```

`error` is a stable token. `detail` is human, no keys, no signed URLs.

Stable tokens: `unpinned_from`, `bad_sig`, `bad_json`, `limit_body`,
`limit_file`, `limit_files`, `pin_conflict`, `id_collision`, `not_found`,
`door`, `conflict_msg`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
