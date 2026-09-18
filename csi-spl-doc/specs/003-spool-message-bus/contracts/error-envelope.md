# Contract: Errors

CLI and hub must be mappable 1:1.

## CLI exit

| code | meaning |
|---|---|
| `0` | ok, including `delivery=queued` (not an error; trust-modes §8) |
| `78` | verify/refuse: unpinned box, bad envelope sig, pin conflict, hash mismatch, revoked pin, sender box pubkey not synced locally |
| `1` | usage, IO, hub 5xx after retries, missing file bytes, limits exceeded |

MCP: `78` → tool error with `code: "verify"`. `1` → `code: "error"`.

## Hub HTTP (REST) and WS

| status | when |
|---|---|
| 200 / 201 | ok (200 for idempotent replay of the same `msg_id` + same canonical) |
| 400 | bad JSON, schema, limits, bad envelope sig, `from_box` ≠ hello box |
| 401 / 403 | door: IAM/OIDC on a **private** deploy only (OQ-06); missing box proof on `POST /v1/files` |
| 402 | tenant unpaid (006) |
| 404 | unknown `file_id`, or a `file_id` of another tenant |
| 409 | `msg_id` exists with a different canonical body; ambiguous `to` without `to_box`; duplicate agent id in one box's roster; `box_id` pinned with a different key (004/006) |
| 413 | file too large |
| 429 | tenant quota (006) |
| 500 | bug; client may retry flush |

WS: an unknown box at hello **closes** the socket. The close codes, and whether
per-frame errors travel as a reply frame carrying the body below, are not yet
specified (OQ-03 / OQ-08 in `../spec.md`).

Body (JSON):

```json
{ "error": "unpinned_box", "detail": "no pin for box-a" }
```

`error` is a stable token. `detail` is for humans and never contains keys or signed URLs.

Stable tokens: `unpinned_box`, `bad_sig`, `bad_json`, `limit_body`,
`limit_file`, `limit_files`, `pin_conflict`, `conflict_msg`,
`ambiguous_to_box`, `roster_duplicate`, `not_found`, `door`, `unpaid`,
`quota`.

Retired with the per-agent-key model (0.1.0): `unpinned_from`,
`id_collision` (agent ids now collide across boxes on purpose).

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:24:00+03:00 -->
