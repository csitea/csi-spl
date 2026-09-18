# Data Model: On-Box Agent Messaging (002)

All structures are local-filesystem artefacts. The JSON shapes here are the
**permanent** wire/disk contract reused unchanged by `003-spool-message-bus`.

## 1. Agent id

`<KIND>-<NN>` where `KIND ∈ {CLE, GRK, AGY}` (extensible: a new vendor = a new
prefix, same everything else). The id is the routing key and the signing/pinning
subject. A display name is NOT an identity (ysg-box lesson: collisions happen);
002 addresses only by id.

## 2. Message object (`v: 1`)

```json
{
  "v": 1,
  "msg_id": "<uuidv4>",
  "task_id": "<uuidv4>",
  "ts": "<RFC3339 Z>",
  "from": "GRK-03",
  "to": "CLE-07",
  "kind": "task",
  "body": "review this",
  "files": [
    { "file_id": "<sha256hex>", "name": "patch.zip", "bytes": 12044, "sha256": "<sha256hex>" }
  ],
  "sig": "<base64 ed25519>"
}
```

- `kind ∈ {task, result, note, reject}`.
- **Canonical sign payload**: `jq -cS 'del(.sig)'` — sorted keys, compact, `sig`
  removed. Ed25519 over those bytes; `sig` is base64.
- `files[]` may be empty. Each entry duplicates `file_id` and `sha256` (equal)
  for defence-in-depth on read.
- On disk one message = one file named
  `<yyyymmddThhmmssZ>--<from>--<slug>.json`; tie-break same-second collisions by
  appending a short `msg_id` fragment to the slug.

## 3. File object (content-addressed)

`file_id = sha256hex(bytes)`. Bytes stored once at `$SPOOL_ROOT/files/<file_id>`.
Identical bytes from any agent dedupe to one object. `spool-get-file` re-hashes
on read and refuses a mismatch or an absent object (no partial write).

## 4. Pin store

Maps agent id → Ed25519 public key. An id with no pin is **untrusted**:
`spool-send` refuses to sign as an unpinned `from`; `spool-recv` refuses to
accept a message whose `from` is unpinned or whose `sig` fails. Location is under
`$HOME` (per-user state), never inside `$SPOOL_ROOT`, never in git.

## 5. Keypair

Ed25519. Private key `chmod 600` under `$HOME` (e.g. `$HOME/.spool/keys/<id>.key`
— exact path is an env var with a documented default, T-level decision). The
private key never enters `$SPOOL_ROOT`, a message, or a log.

## 6. Spool root layout

```text
$SPOOL_ROOT/                     # default /var/tmp/claude/msgs
├── <AGENT-ID>/
│   ├── inbox/    <ts>--<from>--<slug>.json   # delivered, unread
│   ├── outbox/   <ts>--<self>--<slug>.json   # sent record
│   └── archive/  <ts>--<from>--<slug>.json   # acked / processed
└── files/        <file_id>                   # content-addressed bytes (shared)
```

Mirrors ysg-box's `<id>/{inbox,outbox,archive}/` (reference only). Differences:
`.json` `v:1` objects (ysg-box uses `.md` with frontmatter), a shared
content-addressed `files/` store, and mandatory signatures.

## 7. State transitions

```
send:  build v1 → sign → write outbox/<self> + write recipient inbox/<to>
recv:  read inbox/* → verify sig vs pin → return valid; (--ack) rename to archive/
ack:   atomic rename inbox/<f> → archive/<f>   (at-most-once per ack)
put:   sha256(bytes) → files/<id> (idempotent)
get:   files/<id> → dest, re-hash == id else fail
```

## 8. Exit codes

`0` success · `78` verify/refuse (unpinned, bad sig, mismatched hash) — the same
`78` ysg-box's `directive-verify` uses, so tooling reads one convention.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T00:00:00Z -->
