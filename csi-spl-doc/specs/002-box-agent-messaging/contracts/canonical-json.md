# Contract: Canonical JSON for signatures

Feature: `002-box-agent-messaging`  
The Go encoder MUST match this, not “whatever `encoding/json` does”.

Local files carry no `sig`; this canonical form is what the hub envelope signs
with the box key (`trust-modes.md` §5, implemented in 003).

Reference command: `jq -cS 'del(.sig)'`.

## Rules

1. UTF-8. No BOM.
2. Object keys sorted lexicographically by Unicode code point.
3. No insignificant whitespace (`-c`).
4. `del(.sig)` — the `sig` key is absent, not `null`.
5. Integers (`v`, `bytes`) as JSON numbers without a fraction (`1` not `1.0`).
6. Strings: JSON escaped; `/` is **not** escaped (jq default). Use the golden
   vectors below as the lock, not a prose reading of RFC 8259.
7. Array order in `files` is significant and **not** sorted.
8. Unknown keys already rejected before signing.

## Golden vector

Input object (pretty, `sig` omitted):

```json
{
  "v": 1,
  "body": "review this",
  "files": [],
  "from": "GRK-03",
  "kind": "task",
  "msg_id": "11111111-1111-4111-8111-111111111111",
  "task_id": "22222222-2222-4222-8222-222222222222",
  "to": "CLE-07",
  "ts": "2026-09-18T12:00:00Z"
}
```

Canonical bytes MUST equal exactly (one line, no trailing newline in the
hash input — jq `-c` has no newline if piped via `-j` / Go must not append
`\n`):

Implementations add a `go test` that `Canonical(msg) == golden` and that
`ed25519.Verify` using a fixture key matches a fixture `sig`. If jq on the
box differs, the **Go golden file in the repo** wins; jq is the explanatory
reference.

A second vector MUST include one `files[]` entry and a `body` containing
`"` and newline, so escaping is locked.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:30:00Z -->
