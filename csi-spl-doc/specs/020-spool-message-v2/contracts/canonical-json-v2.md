# Contract: Canonical bytes and signatures for `v:1` and `v:2`

Feature: `020-spool-message-v2`. Reuses the canonical rules exactly as fixed by
CLE-3388 (`d7b08da`): `jq -cS` semantics, keys sorted by code point, compact,
exact integers, **no HTML escaping** (`<`, `>`, `&` stay literal), `/` not
escaped, `files[]` order significant, `sig` absent (not `null`).

## 1. Decision

**One canonicaliser for both versions.** `v` is an ordinary integer key; the
canonical form of a `v:2` object is the `v:1` form with `"v":2`. Nothing about
signing is versioned:

- Inner object: `msg.Canonical(m)` == `jq -cjS 'del(.sig)'`.
- Envelope signature: `wire.(*Envelope).SigningPayload()` ==
  `jq -cjS '{from_box,to_box,msg}'` (+ `channel`, `parent_task_id` only when
  present, `003 channels-v1 §2`).
- The hub never re-encodes a signed inner object: it keeps the raw `msg` bytes
  and re-canonicalises them only as a JSON value, so a `v:1` envelope signed
  before this spec verifies after it byte for byte.

Rejected alternative: a version-tagged signing domain (e.g. prefix
`spool-msg-v2\n`). It would make every `v:2` signature fail on a `v:1` hub
**for a reason other than the version**, which is harder to diagnose, and it
buys nothing: `v` is already inside the signed bytes, so a signed `v:1` cannot
be replayed as `v:2`.

## 2. Golden vectors

Fixture key: Ed25519 seed = bytes `0x00..0x1f`
(`ed25519.NewKeyFromSeed([0,1,…,31])`). Envelope `from_box=box-a`,
`to_box=box-b`. The same message in both versions: body `a<b & c` (the
no-HTML-escape control), one `blob`+`file` ref and one `path`+`dir` ref (the
`v:2` shape: `mode`, `kind`, `path`, no `file_id`, no `bytes`).

### 2.1 Inner canonical, `v:1`

```text
{"body":"a<b & c","files":[{"bytes":4,"file_id":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","kind":"file","mode":"blob","name":"test.txt","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"},{"kind":"dir","mode":"path","name":"out","path":"/srv/work/out"}],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1}
```

### 2.2 Inner canonical, `v:2`

```text
{"body":"a<b & c","files":[{"bytes":4,"file_id":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","kind":"file","mode":"blob","name":"test.txt","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"},{"kind":"dir","mode":"path","name":"out","path":"/srv/work/out"}],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":2}
```

jq cross-check (the `v:2` line from a key-shuffled input):
`jq -cjS 'del(.sig)' | sha256sum` → `4436eabf8eed62de842c09e5ef98eb894c31170c17092b61dc0a6ccecdf05289`,
identical to `printf '%s' '<2.2>' | sha256sum`.

### 2.3 Envelope signatures

| version | `sig` (base64) |
|---|---|
| `v:1` | `ZFXGuw9LY63ygB6xIDCH9GOxsHI0cHz6KqmGe7hgh55n7hyiiQE4T/6Wid2FiRxVlvsluQzj0Q6VBKMvJQnxDQ==` |
| `v:2` | `hj2/6umTFaBw+/iV6wI5ioSTCgjUDv9BfB7l16DiCmz/hsjZp4anZB7uTZqd+5x4+DGYVeENt0xkXZnr+AtGDg==` |

The pre-existing `v:1` vectors stay locked unchanged: `internal/wire/wire_test.go`
`legacyEnv` (pre-M3 envelope, sig `EVsoo/…BQ==`) and
`internal/msg/msg_test.go` `TestCanonicalGoldenVectors` (3 vectors).

Lock: `internal/wire/wire_test.go` `TestGoldenV1V2Envelopes` asserts the four
byte strings above, that each sig verifies with the fixture key, that the `v:1`
sig does **not** verify over the `v:2` payload (no cross-version replay), and
that parse → marshal returns the same bytes.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T15:10:00Z -->
