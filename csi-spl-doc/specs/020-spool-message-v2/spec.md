# Feature Specification: Spool Message Schema `v:2`

**Feature ID**: `020-spool-message-v2` · **Milestone**: M3 consolidation · **Status**: Partial
**Created**: 2026-09-19 · **Lane**: MESSAGE-V2
**Builds on**: `002-box-agent-messaging` (frozen `v:1`), `003-spool-message-bus` (hub envelope, WS frames), `014-spool-wui-dispatch`, `008-spool-cicd-logs`.
**Authority**: `./contracts/message-schema-v2.md`, `./contracts/canonical-json-v2.md`, `./contracts/migration.md`

Status vocabulary follows `../README.md` §2.3: **Implemented** (cited), **Partial** (missing part named), **Planned**.

## Clarifications

### Session 2026-09-19 (owner decision)

- 002 SC-006 was left OPEN by CLE-3397 (`f47a404`): since 002 shipped,
  `files[]` also carries `mode`, `kind` and `path`, which the frozen `v:1`
  contract does not list. The owner was offered (A) amend 002 in place,
  (B) bump to `v:2`, (C) strip the fields. **The owner chose B.**
- 002 stays frozen: it describes `v:1`. 002 gets one pointer to this spec and
  nothing else.
- The `v:2` object is `v:1` **as shipped**: same keys, same rules, now written
  down. No field is added, removed or tightened (`contracts/message-schema-v2.md` §5
  lists what was considered and left alone).
- Canonical bytes and signatures reuse CLE-3388's rules unchanged; `v` is an
  ordinary signed integer key (`contracts/canonical-json-v2.md` §1).
- Readers first, writers last. Writers keep emitting `v:1` until every reader
  (hub dev + prd, the boxes, the WUI) is deployed (`contracts/migration.md`).

## User stories

### US1 — a box keeps working through the migration (P1)

A box on an older binary keeps sending and receiving `v:1` at every phase,
and never silently loses a message that another box wrote as `v:2`.

**Acceptance**: a `v:1` fixture (inbox file and signed envelope) still
parses, validates, verifies and delivers. A hub holds a `v:2` row for a
session that did not advertise `v:2`, and delivers it after that box
reconnects with an upgraded binary.

### US2 — a `v:2` message round-trips (P1)

**Acceptance**: `Canonical`, `Marshal`, `Parse` and `Validate` round-trip a
`v:2` object with `blob` and `path` refs. The envelope signature matches the
golden vector and verifies; the same message crosses the hub between two
boxes.

### US3 — mixed fleet (P1)

A box writing `v:1` and a box writing `v:2` exchange messages both ways
through one hub.

## Functional requirements

- **FR-001** Readers accept `v ∈ {1,2}` and apply one rule set to both
  (`message-schema-v2.md` §3). **Planned** (T005): `internal/msg/msg.go` `Validate`, `Supported`.
- **FR-002** Writer version is a knob, default `1`: box `SPOOL_MSG_VERSION`,
  hub `SPOOL_HUB_MSG_VERSION`; any value other than `1` or `2` fails fast.
  **Planned** (T006, T007): `internal/config/config.go`, `spool.Compose`, `hub/wui.go`, `cicdlogs`.
- **FR-003** Canonical bytes and signatures cover both versions with the
  unchanged `jq -cS` rules; golden vectors for both versions are locked in
  tests. **Partial**: vectors in `contracts/canonical-json-v2.md` §2; missing the test lock `TestGoldenV1V2Envelopes` (T009).
- **FR-004** Boxes advertise `msg_versions` in `hello`. The hub never pushes a
  `recv` frame whose inner `v` the session did not advertise; the row stays
  `queued` (`migration.md` §3). **Planned** (T008): `internal/hub/ws.go` `push`, `internal/hubclient/hubclient.go` hello.
- **FR-005** The legacy `.md` bridge keeps synthesising `v:1`. **Planned** (T007): made explicit as `msg.V1`; asserted by `TestLegacyMDBridge`.
- **FR-006** The WUI type admits `v: 1 | 2`. The WUI gates on no `v`
  (`grep -rn "\.v ==\|\.v !=" csi-spl-wui/src` → 0). **Planned**: CLE-55 (UI lane).
- **FR-007** Writers switch to `v:2` only after the gates in `migration.md` §2
  are met, each switch with the owner's go. **Planned**.

## Success criteria

- **SC-001** Every pre-020 `v:1` golden vector and fixture is byte-identical
  and green (`TestCanonicalGoldenVectors`, `TestEnvelopeLegacyBytes`,
  `TestEnvelopeEscapedInnerStillVerifies`, `TestLegacyMDBridge`).
- **SC-002** `v:2` round-trip plus envelope golden vectors are green.
- **SC-003** Mixed-fleet hub test: `v:1` box ↔ `v:2` box, both directions, delivered.
- **SC-004** Guard test: a session without `msg_versions` gets no `v:2`
  `recv` frame; after reconnecting with `[1,2]` it is delivered.
- **SC-005** After P2, 0 rows stuck `queued` by the guard for 24 h on dev.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T15:10:00Z -->
