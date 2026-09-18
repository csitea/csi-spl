# Contract: Local folder layout (and how it maps to the ysg-box reference)

`$SPOOL_ROOT` default `/var/spool-hub`, overridable by env.

```text
$SPOOL_ROOT/
├── <AGENT-ID>/
│   ├── inbox/    <yyyymmddThhmmssZ>--<from>--<slug>.json
│   ├── outbox/   <yyyymmddThhmmssZ>--<self>--<slug>.json
│   └── archive/  <yyyymmddThhmmssZ>--<from>--<slug>.json
├── files/        <file_id>                       # content-addressed, shared
└── pins/         box-<box_id>.pub                # box pubkeys for hub mode (mode 0644); unused locally
```

The one per-box private key (hub mode only) lives strictly under
`$HOME/.spool/keys/box-<box_id>.key` (`chmod 0600`), outside `$SPOOL_ROOT`.

## Mapping to the ysg-box reference (READ-ONLY — do not modify ysg-box)

| ysg-box (today, reference) | spool 002 (new, in csi-spl) |
|---|---|
| `$MSGS_ROOT/<id>/{inbox,outbox,archive}/` | same three dirs, under `$SPOOL_ROOT` |
| `<ts>--<from>--<slug>.md` + YAML frontmatter | `<ts>--<from>--<slug>.json`, one `v:1` object |
| body is free markdown | `body` is a `v:1` string field |
| file leg = source of truth | unchanged — the file is the record |
| notification = doorbell (`SendMessage`/tmux/`inbox-send.sh`) | out of scope for 002 delivery; drained by reading `inbox/` |
| no signatures | no signatures locally (POSIX trust); one box key only for hub mode |
| files carried inline / ad hoc | content-addressed `files/<sha256>`, referenced by `file_id` |
| liveness via `ListAgents` | N/A in 002 (single box, id-addressed dirs) |
| ack = `mv` inbox → archive | ack = atomic rename inbox → archive |

## Invariants

- The file leg is the source of truth; a lost notification never loses a message.
- Address by **id**, never by display name (ysg-box collision lesson).
- **Rely on the OS for security**: Use standard POSIX file permissions (`0664` for message files, `0775` for directories, `0644` for shared pins, `0600` for private keys) and standard Unix user/group boundaries. Do not re-invent auth/access control machinery locally.
- `files/` is shared across agents on the box; identical bytes = one object.
- Mode `0664` on message files so the box user and the agent user can both read
  (matches the ysg-box convention).
- Nothing in this tree is a private key; the box private key lives under `$HOME/.spool/keys/box-<box_id>.key` (`chmod 600`). Box public pins live under `$SPOOL_ROOT/pins/box-<box_id>.pub` (`chmod 644`).

## Why re-implement instead of reuse ysg-box

ysg-box's protocol is battle-tested and is the behavioural spec, but it is bash
+ `.md` frontmatter wired into the box harness. 002 needs content
addressing and a `v:1` JSON object that `003` can put on a wire unchanged — so
the spool owns a clean Go implementation and treats ysg-box strictly as the
reference contract (Constitution: "Reference implementation is read-only").

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T16:15:00Z -->
