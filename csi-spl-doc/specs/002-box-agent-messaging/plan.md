# Implementation Plan: On-Box Agent Messaging (local spool)

**Feature ID**: `002-box-agent-messaging` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **End vision**: `../003-spool-message-bus/spec.md`

## Summary

Deliver the spool box API (`SPEC-spool-box-api.md`) as one Go binary backed by a
local `$SPOOL_ROOT` folder — no hub. It signs (Ed25519) and verifies messages
against pins, content-addresses file attachments (sha256), stores the canonical
`v:1` JSON on disk, and offers a `spool-tail` view. The same binary exposes a
stdio MCP server that thinly wraps the CLI. Behaviour is modelled on ysg-box's
existing file protocol (reference only, never modified).

## Technical Context

**Language/Version**: Go 1.22+.

**Primary Dependencies**: standard library only where possible —
`crypto/ed25519`, `crypto/sha256`, `encoding/json`, `os`; an MCP server library
for the stdio tool surface (`contracts/mcp-tools.md` pins the choice in
research). No NATS/Postgres/GCS SDKs in 002.

**Storage**: local filesystem under `$SPOOL_ROOT` (default
`/var/tmp/claude/msgs`). Keys/pins under `$HOME` (outside the spool root).

**Testing**: `go test ./...` (unit + a table-driven round-trip harness against a
temp `$SPOOL_ROOT`); a bash smoke test under
`csi-spl-<kind>/src/bash/tests/` mirroring the ysg-box `agent-msg` flow.

**Target Platform**: Linux box (any box that runs agents). Single filesystem.

**Project Type**: single Go module (CLI + MCP), one binary, subcommands.

**Performance Goals**: interactive latency (a send/recv is a few file ops);
no throughput target in 002.

**Constraints**: no key in `$SPOOL_ROOT`/git/log (VII); atomic-rename acks
(NFR-004); on-disk `v:1` == wire `v:1` for 003 (NFR-003); no ysg-box coupling.

**Scale/Scope**: one box, a handful of agent ids, human-scale message volume.

## Constitution Check

- [ ] **I. Paths** — binary + sources under a csi-spl sub-project; `$SPOOL_ROOT`
      and `$HOME` derived, never hard-coded.
- [ ] **II. Env** — `$SPOOL_ROOT` and key/pin locations are env vars with the
      documented default; nothing else baked in.
- [ ] **VI. Cnf-only** — no runtime host/path invented in source.
- [ ] **VII. No key in git/state/log** — private keys `chmod 600`, outside the
      spool root, never logged.
- [ ] **VIII. Uniform API** — one verb/tool/schema set for all kinds; kind is an
      id prefix only.
- [ ] **V. Hygiene** — org-neutral; example ids/names use placeholders.
- [ ] **Reference read-only** — grep gate proves no ysg-box path in the source.

*(Boxes are unchecked until `/speckit-analyze` runs against the built code.)*

## Project Structure

### Documentation (this feature)

```text
specs/002-box-agent-messaging/
├── spec.md
├── plan.md              # this file
├── data-model.md
├── tasks.md
└── contracts/
    ├── cli.md
    ├── mcp-tools.md
    ├── message-schema.md
    └── local-folder-layout.md
```

### Source Code

```text
csi-spl-utl/src/go/spool/          # the Go module (proposed home; confirm in setup)
├── cmd/spool/main.go              # subcommand dispatch: send|recv|put-file|get-file|tail|keygen|pin|mcp
├── internal/msg/                  # v1 message object: build, canonicalise, (de)serialise
├── internal/sign/                 # ed25519 keygen, sign, verify; pin store
├── internal/files/                # content-addressed store (sha256), put/get
├── internal/spool/                # $SPOOL_ROOT layout, inbox/outbox/archive, atomic ack
├── internal/mcp/                  # stdio MCP server wrapping the CLI actions
└── internal/spool/spool_test.go   # temp-root round-trip harness

csi-spl-utl/src/bash/tests/spool-smoke.tst.sh   # end-to-end smoke mirroring agent-msg
```

**Structure Decision**: one Go module, subcommand-per-verb, thin `internal/mcp`
over the same internal actions the CLI calls — so CLI and MCP cannot drift
(Constitution VIII). Home under `csi-spl-utl/src/go/` proposed; the exact
sub-project (`-utl` vs a new `-bin`) is a T001 decision.

## Build Order (this feature = step 1 of the 003 architecture)

Maps to `SPEC-spool-architecture.md` §8 step 1 ("Local folder CRUD + Ed25519 +
files + tail, no NATS, no GCP"). 003 picks up at step 2 (same HTTP API on Cloud
Run). Nothing here is throwaway: the `v:1` object, the CLI, and the MCP tools are
the permanent contract; 003 adds a backend behind them.

## Complexity Tracking

*No constitutional violations to justify.* The one non-obvious call — a single
binary for CLI + MCP rather than two — is required by VIII (identical behaviour)
and reduces surface, so it is a simplification, not a violation.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T00:00:00Z -->
