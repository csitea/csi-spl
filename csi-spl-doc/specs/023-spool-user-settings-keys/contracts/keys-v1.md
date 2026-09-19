# Contract: human public keys — keys-v1 (023)

Implemented: `internal/hub/keys.go`. Mounted by the hub under the auth prefix, so the credentialed CORS of
`/api/v1/auth/*` (allow-list `SPOOL_HUB_VIEW_CORS_ORIGINS`, methods
`GET, POST`, header `Content-Type`) covers it with no CORS change.

Every route: a valid 010/015 session cookie whose claims carry a HUM-*
(`hum`), else `401 {"error":"unauthenticated"}`. `Cache-Control: no-store`.
No route accepts or returns private key material.

## 1. Key object

```json
{
  "id": 7,
  "fingerprint": "SHA256:3q2+7w…",
  "public_key": "base64-32-bytes=",
  "openssh": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI… spool:HUM-12",
  "source": "generated",
  "label": "",
  "created_at": "2026-09-19T16:40:00Z",
  "revoked_at": null,
  "revoked_reason": "",
  "active": true
}
```

`source`: `generated` (the WUI made it, 023 FR-002) or `uploaded`.
`revoked_reason`: `""`, `replaced` or `revoked`.

## 2. Routes

| method + path | body | answer |
|---|---|---|
| `GET /api/v1/auth/keys` | — | `200 {"active": Key or null, "keys": [Key…]}` newest first, history included |
| `GET /api/v1/auth/keys/{id}/public` | — | `200 Key`; not yours / unknown → `404 not_found`. (`/{id}/public`, not `/{id}`: the auth mux's `GET /api/v1/auth/{provider}/start` would overlap.) |
| `POST /api/v1/auth/keys` | `{"public_key": "<b64 or ssh-ed25519 line>", "source": "generated" or "uploaded", "label": "<≤80 chars>"}` | `201 Key` (now active; the previous active key → `revoked_reason: replaced`) |
| `POST /api/v1/auth/keys/{id}/revoke` | `{}` | `200 Key`; already revoked → `200` unchanged; not yours → `404` |

## 3. Errors (`{"error": "<token>", "detail": "…"}`)

| status | token | when |
|---|---|---|
| 400 | `bad_public_key` | not 32 Ed25519 bytes in base64 or an `ssh-ed25519` line |
| 400 | `private_key_refused` | 64 decoded bytes, or a `PRIVATE KEY` block |
| 400 | `bad_request` | invalid JSON, an unknown field (e.g. `private_key`), bad `source` / `label` |
| 401 | `unauthenticated` | no session, or a session with no HUM-* |
| 404 | `not_found` | key id unknown or another human's |
| 409 | `duplicate_key` | that public key is registered already (any human, any state) |
| 415 | `unsupported_media_type` | POST without `application/json` |
| 429 | `rate_limited` | more writes than the per-human window allows; `Retry-After` set |
| 503 | `unavailable` | store error, or a store without human keys |

## 4. Audit

One zerolog line per write: `keys.added` / `keys.revoked` with `human_id`,
`key_id`, `fingerprint`, `source` / `reason`. Never key bytes beyond the
fingerprint. The rows themselves (rdb `human_keys`) are the durable history.

<!-- last-edit: 2026-09-19T16:40:00Z -->
