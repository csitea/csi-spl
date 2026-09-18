# Data Model: On-Box Agent Messaging (002)

All structures are local-filesystem artefacts. The JSON shapes here are the
**permanent** wire/disk contract reused unchanged by `003-spool-message-bus`.

## 1. Agent id

`<KIND>-<NN>` where `KIND ∈ {CLE, GRK, AGY}` (extensible: a new vendor = a new
prefix, same everything else). The id is the routing key, unique on one box.
It is not a signing subject: keys are per box (`contracts/trust-modes.md` §3). A
display name is NOT an identity (ysg-box lesson: collisions happen); 002
addresses only by id.

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
  ]
}
```

- `kind ∈ {task, result, note, reject}`.
- **No `sig` locally.** The canonical form (`canonical-json.md`) is what the
  hub envelope signs with the box key (trust-modes §5, 003).
- `files[]` may be empty. Each entry duplicates `file_id` and `sha256` (equal)
  for defence-in-depth on read.
- On disk one message = one file named
  `<yyyymmddThhmmssZ>--<from>--<slug>.json`; tie-break same-second collisions by
  appending a short `msg_id` fragment to the slug.

## 3. File object (content-addressed)

`file_id = sha256hex(bytes)`. Bytes stored once at `$SPOOL_ROOT/files/<file_id>`.
Identical bytes from any agent dedupe to one object. `spool-get-file` re-hashes
on read and refuses a mismatch or an absent object (no partial write).

## 4. Box pin store (hub mode)

Maps box id → Ed25519 public key, at `$SPOOL_ROOT/pins/box-<box_id>.pub` (or
`$SPOOL_PINS_DIR`, mode `0644`). Local send/recv never consult it; hub mode
verifies envelopes from `from_box` against it (trust-modes §3–§4).

## 5. Box keypair (hub mode)

One Ed25519 keypair per box (`$SPOOL_BOX_ID`), shared by every agent on it.
Private key `chmod 600` strictly under `$HOME`
(`$HOME/.spool/keys/box-<box_id>.key` or `$SPOOL_KEYS_DIR`). Optional in 002
and unused while `$SPOOL_HUB_URL` is unset. It never enters `$SPOOL_ROOT`, a
message, or a log.

## 6. Spool root layout

```text
$SPOOL_ROOT/                     # default /var/tmp/claude/msgs
├── <AGENT-ID>/
│   ├── inbox/    <ts>--<from>--<slug>.json   # delivered, unread
│   ├── outbox/   <ts>--<self>--<slug>.json   # sent record
│   └── archive/  <ts>--<from>--<slug>.json   # acked / processed
├── files/        <file_id>                   # content-addressed bytes (shared)
└── pins/         box-<box_id>.pub            # box pubkeys, hub mode (mode 0644)
```

Mirrors ysg-box's `<id>/{inbox,outbox,archive}/` (reference only). Differences:
`.json` `v:1` objects (ysg-box uses `.md` with frontmatter), a shared
content-addressed `files/` store. Like ysg-box, no signatures locally.

## 7. State transitions

```
send:  build v1 (no sig) → write outbox/<self> + write recipient inbox/<to>
recv:  read inbox/* → parse + validate → return well-formed; (--ack) rename to archive/
       a malformed file stays in inbox/ and fails the call (exit 1)
ack:   atomic rename inbox/<f> → archive/<f>   (at-most-once per ack)
put:   sha256(bytes) → files/<id> (idempotent)
get:   files/<id> → dest, re-hash == id else fail
```

## 8. Exit codes

`0` success · `1` usage, IO, or a malformed inbox file · `78` verify/refuse —
locally only a content-hash mismatch on get-file/get-dir; hub mode adds a missing
or failing box signature. The same `78` ysg-box's `directive-verify` uses, so
tooling reads one convention.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:30:00Z -->
