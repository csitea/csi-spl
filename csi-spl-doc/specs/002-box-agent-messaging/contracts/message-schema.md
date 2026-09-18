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
| `sig` | string | **omitted in local mode**. Hub mode: not on this inner object — see box envelope in `SPEC-spool-trust-modes.md` |

### File ref

| field | type | rule |
|---|---|---|
| `file_id` | string | sha256 hex of bytes |
| `name` | string | display name only, not a path |
| `bytes` | int | byte length |
| `sha256` | string | equals `file_id` |

## Modes

- **Local** (`$SPOOL_HUB_URL` unset): this object is stored as-is **without**
  `sig`. No key ceremony. POSIX trust.
- **Hub:** the box wraps this object in an envelope signed with the **box**
  key (`SPEC-spool-trust-modes.md`). Inner `sig` stays absent.

## Signing (hub envelope only)


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
## Legacy `.md` Bridge (Option B: Transparent Coexistence)

When `spool recv` scans `$SPOOL_ROOT/<id>/inbox/` and encounters legacy `.md` files (from `ysg-box` `inbox-send.sh`):
1. Detects `.md` file format.
2. Ingests without error, wrapping into a synthetic `v:1` envelope:
   - `v`: 1
   - `msg_id`: deterministic UUID (derived from filename and content hash).
   - `task_id`: extracted from header/frontmatter if present, else fallback deterministic thread UUID.
   - `ts`: parsed from `<YYYYMMDD-HHMMSS>` in filename or file mtime (RFC3339 UTC).
   - `from`: parsed from `<from>` in filename `<ts>--<from>--<subject>.md`.
   - `to`: recipient whose inbox contains the file.
   - `kind`: `"note"`
   - `body`: raw file contents.
   - `files`: `[]`
   - `sig`: `"legacy-unsigned"`
3. On `--ack`, the `.md` file is moved to `archive/` identically to `.json` files.
4. Result: AI agents only need `spool recv` to receive all incoming mail regardless of sender version.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:36:00Z -->
