# Contract: Errors

CLI and hub must be mappable 1:1.

## CLI exit

| code | meaning |
|---|---|
| `0` | ok, including `delivery=queued` and `delivery=pending` (not errors; trust-modes §8, OQ-09) |
| `78` | verify/refuse: unpinned box, bad envelope sig, pin conflict, hash mismatch, revoked pin, sender box pubkey not synced locally |
| `1` | usage, IO, hub 5xx after retries, missing file bytes, limits exceeded |

MCP: `78` → tool error with `code: "verify"`. `1` → `code: "error"`.

## Hub HTTP (REST) and WS

| status | when |
|---|---|
| 200 / 201 | ok (200 for idempotent replay of the same `msg_id` + same canonical) |
| 400 | bad JSON, schema, limits, bad envelope sig, `from_box` ≠ hello box |
| 401 | `door`: missing, expired or foreign upload token on `POST /v1/files` / `GET /v1/pins` (OQ-10). IAM/OIDC is not in M1 (OQ-06) |
| 402 | tenant unpaid (006) |
| 404 | unknown `file_id`, or a `file_id` of another tenant; unknown tenant (Host); `to_box` not pinned |
| 409 | `msg_id` exists with a different canonical body; ambiguous `to` without `to_box`; duplicate agent id in one box's roster; `box_id` pinned with a different key (004/006) |
| 413 | file too large |
| 429 | tenant quota (006) |
| 500 | bug; client may retry flush |

WS: a refused hello **closes** the socket with a `44xx` close code
(`./http-v1.md` §2.5; the close reason is the stable token). After an accepted
hello every per-frame error is an `error` frame
`{ "type": "error", "error", "status", "detail", "msg_id"? }` and the socket
stays open. There is no ack frame (OQ-08).

Body (JSON):

```json
{ "error": "unpinned_box", "detail": "no pin for box-a" }
```

`error` is a stable token. `detail` is for humans and never contains keys or signed URLs.

Stable tokens: `unpinned_box`, `bad_sig`, `bad_json`, `bad_frame`,
`bad_nonce`, `stale_hello`, `hello_timeout`, `superseded`, `unknown_tenant`,
`limit_body`, `limit_file`, `limit_files`, `pin_conflict`, `conflict_msg`,
`ambiguous_to_box`, `missing_to_box`, `missing_file`, `roster_duplicate`,
`not_found`, `door`, `unpaid`, `quota`.

CLI mapping of hub tokens: `bad_sig`, `unpinned_box`, `bad_nonce`,
`stale_hello`, `pin_conflict` → exit `78`; the rest → exit `1`.

Retired with the per-agent-key model (0.1.0): `unpinned_from`,
`id_collision` (agent ids now collide across boxes on purpose).

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:55:00Z -->
