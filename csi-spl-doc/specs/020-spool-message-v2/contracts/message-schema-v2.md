# Contract: Message Schema (`v: 2`)

Feature: `020-spool-message-v2`. Supersedes nothing: `v:1` stays defined by
`../../002-box-agent-messaging/contracts/message-schema.md` (frozen) and stays
readable forever. `v:2` is **the object that ships**, written down as it ships.
This contract changes no field anyone writes today; it corrects the text.

Owner decision 2026-09-19 (SC-006 in 002, options A / B / C): **B, bump to
`v:2`**.

## 1. Object

| field | type | rule |
|---|---|---|
| `v` | int | `2` |
| `msg_id` | string | UUID, lowercase `8-4-4-4-12` hex. Writers emit v4. Readers check **non-empty only** (§5) |
| `task_id` | string | same as `msg_id`; groups a thread |
| `ts` | string | RFC3339, UTC, `Z`, second precision. Readers do not parse it (§5) |
| `from` | string | agent id `^[A-Z]{2,4}-\d+$`, prefix `BOX-` forbidden |
| `to` | string | agent id, same rule. `ALL-0` = a channel / broadcast post (003 `channels-v1.md`) |
| `kind` | string | `task` \| `result` \| `note` \| `reject` |
| `body` | string | UTF-8, may be empty, ≤ 64 KiB (bytes) |
| `files` | array | 0..16 file refs (§2). Writers always emit an array (`[]` when empty) |
| `sig` | string | never written. A `sig` found on a local file is tolerated, not checked; the hub envelope carries the signature (`trust-modes.md` §5) |

Unknown keys → reject (strict decode, top level **and** inside `files[i]`),
unchanged from shipped `v:1`.

## 2. File ref (`files[i]`)

| field | type | required | rule |
|---|---|---|---|
| `mode` | string | **yes** | `blob` (bytes stored content-addressed, transferable through the hub) \| `path` (an on-box absolute path; nothing copied; meaningful on the same box only) |
| `kind` | string | **yes** | `file` \| `dir`. A `dir` blob is a deterministic tar; `file_id` is the sha256 of the tar |
| `file_id` | string | `blob`: yes · `path`: absent | sha256 hex of the stored bytes |
| `path` | string | `path`: yes · `blob`: absent | absolute path on the sending box |
| `name` | string | yes (writers) | display name, never a path to follow. A `spool send --file-id` ref uses the `file_id` as its name |
| `bytes` | int | optional | byte length. **Absent** for an empty file, a `path`+`dir` ref, and a `--file-id` ref whose blob is not in the local store. ≤ 32 MiB |
| `sha256` | string | optional | `blob`: when present it MUST equal `file_id`. `path`+`file`: the content hash at send time, for drift detection. `path`+`dir`: absent |

Unknown keys inside a file ref are rejected too: the strict decode applies to
nested objects (`encoding/json` `DisallowUnknownFields`), in both versions.
Test: `TestUnknownFileRefKeyRejected`.

## 3. Validation (identical for `v:1` and `v:2` readers)

Readers accept `v ∈ {1, 2}` and run the same rules on both:

- `v` not in `{1, 2}` → reject.
- `msg_id`, `task_id`, `ts` empty → reject.
- `from` / `to` not an agent id, or `BOX-` prefixed → reject.
- `kind` outside the enum → reject.
- `body` > 64 KiB, > 16 files, a file > 32 MiB → reject.
- `files[i].mode` not `blob|path`, `kind` not `file|dir` → reject.
- `blob` without `file_id`, or with `sha256 != file_id` → reject.
- `path` without `path` → reject.

Code: `csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go` `Validate`.

## 4. What `v:1`'s contract mis-describes (evidence)

Each line is something the frozen 002 contract says that the shipped code (and
every `v:1` object in the field) does not do. `v:2` writes the shipped
behaviour down. Tree: `dabd2d4`.

| # | 002 contract says | shipped | evidence |
|---|---|---|---|
| 1 | file ref = `{file_id,name,bytes,sha256}` | adds `mode`, `kind`, `path` | `sed -n '/^type Attachment/,/^}/p' internal/msg/msg.go \| grep -c 'json:"mode"\|json:"kind"\|json:"path,omitempty"'` → 3 |
| 2 | `file_id` always present | absent on `path` refs (`omitempty`) | `grep -n 'json:"file_id,omitempty"' internal/msg/msg.go` → 1 hit; `internal/files/files.go:164` builds a path-dir ref with no `FileID` |
| 3 | `sha256` always equals `file_id` | optional; equal only on `blob`; on `path`+`file` it is the content hash | `msg.go` `Attachment.validate` (`case "blob"` checks only when non-empty) |
| 4 | `bytes` always present | `omitempty`: absent for 0-byte files, path dirs, dangling `--file-id` | `grep -n 'json:"bytes,omitempty"' internal/msg/msg.go` → 1 hit; 002 spec.md Clarifications 2026-09-19 (SC-006 residuals) |
| 5 | a literal `v:1` ref without `mode`/`kind` is valid | **rejected** by every shipped reader (`kind "" is not file\|dir`) | `Attachment.validate`; test `TestContractLiteralV1RefRejected` (020) |
| 6 | id regex only | `BOX-` prefix also forbidden | `msg.ValidID` |
| 7 | `msg_id`/`task_id` are UUIDv4 | readers check non-empty only; the hub WUI path accepts any UUID shape | `msg.Validate`; `internal/hub/view.go:37` `uuidRe` has no version nibble |
| 8 | `ts` RFC3339 `Z` | writers comply; readers never parse it | `msg.Validate` |
| 9 | "Unknown top-level keys → reject" | unknown keys inside `files[i]` are rejected as well | `msg.Parse` uses `DisallowUnknownFields`, which recurses; test `TestUnknownFileRefKeyRejected` (020) |
| 10 | canonical-json.md: "Canonical bytes MUST equal exactly" — then gives no bytes; the required second vector is absent | the vectors live only in Go tests | `grep -c '^{"body"' ../../002-box-agent-messaging/contracts/canonical-json.md` → 0; `internal/msg/msg_test.go` `TestCanonicalGoldenVectors` |

Field data (this box, 2026-09-19, n=58 message files under the live spool
root): all `v:1`, 0 attachments. `find <spool-root> -name '*.json' -not -path '*/files/*' | xargs jq -c '[.v,(.files|length)]' | sort | uniq -c` → `58 [1,0]`.
So #5 has broken nothing observed; it is still a contract lie.

## 5. Deliberately NOT tightened in `v:2`

The brief is "files[] as shipped". Tightening a rule that shipped writers
already break would make `v:2` unreachable for those writers:

- `msg_id` / `task_id` format and `ts` parsing stay unchecked by readers.
- `name` non-empty is a writer rule, not a reader rule.

A later `v:3` may tighten these; each would need its own migration.

## 6. Signing

Unchanged. The canonical bytes and the envelope signature are version-blind
(`canonical-json-v2.md`): `v` is one more integer key in the sorted object.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T15:10:00Z -->
