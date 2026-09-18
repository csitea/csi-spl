# Contract: Message Schema (`v: 1`)

Canonical, permanent. `003` puts this exact object on the wire; `002` writes it
to disk. Any change is a `v` bump, never an in-place edit.

## Object

| field | type | rule |
|---|---|---|
| `v` | int | MUST be `1` |
| `msg_id` | string | UUIDv4, unique per message |
| `task_id` | string | UUIDv4, groups a thread |
| `ts` | string | RFC3339 with `Z` (UTC) |
| `from` | string | agent id (`^[A-Z]{2,4}-\d+$`), MUST be pinned |
| `to` | string | agent id |
| `kind` | string | one of `task` `result` `note` `reject` |
| `body` | string | UTF-8; MAY be empty |
| `files` | array | 0..N file refs (below); MAY be empty |
| `sig` | string | base64 Ed25519 over the canonical payload |

### File ref

| field | type | rule |
|---|---|---|
| `file_id` | string | sha256 hex of bytes |
| `name` | string | display name only, not a path |
| `bytes` | int | byte length |
| `sha256` | string | equals `file_id` |

## Signing

1. Build the object with all fields EXCEPT `sig`.
2. Canonicalise: `jq -cS 'del(.sig)'` (sorted keys, compact). The Go
   implementation MUST produce byte-identical output (sorted keys, no spaces).
3. `sig = base64( ed25519.Sign(privkey(from), canonical_bytes) )`.

## Verifying

1. Look up `from`'s pinned pubkey; absent → refuse (exit `78`).
2. Recompute the canonical payload (`del(.sig)`, sorted, compact).
3. `ed25519.Verify(pub, payload, base64decode(sig))`; false → refuse (exit `78`).

## Validation rules

- Unknown top-level keys → reject (strict).
- `kind` outside the enum → reject.
- Any `files[i].sha256 != files[i].file_id` → reject.
- `from`/`to` not matching the id regex → reject.
- Limits (`body` 64 KiB, 16 files, 32 MiB/file): `../../../003-spool-message-bus/contracts/limits.md`.
- `kind` / `task_id` meaning: `kind-lifecycle.md` and `doc/md/SPEC-spool-task-lifecycle.md`.
- Canonical bytes: `canonical-json.md`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
