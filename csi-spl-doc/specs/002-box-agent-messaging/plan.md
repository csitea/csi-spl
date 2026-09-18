# Implementation Plan: On-Box Agent Messaging (local spool)

**Feature ID**: `002-box-agent-messaging` · **Status**: Draft · **Date**: 2026-09-18

**Spec**: `./spec.md` · **End vision**: `../003-spool-message-bus/spec.md`

## Summary

Deliver the spool box API (`SPEC-spool-box-api.md`) as one Go binary backed by a
local `$SPOOL_ROOT` folder — no hub. It writes unsigned messages (local trust is
POSIX, `contracts/trust-modes.md`), content-addresses file attachments (sha256), stores the canonical
`v:1` JSON on disk, and offers a `spool-tail` view. The same binary exposes a
stdio MCP server that thinly wraps the CLI. Behaviour is modelled on ysg-box's
existing file protocol (reference only, never modified).

## Technical Context

**Language/Version**: Go 1.25+ (go-sdk v1.8.0 floor).

**Primary Dependencies**: standard library (`crypto/ed25519`, `crypto/sha256`, `encoding/json`, `os`); `github.com/rs/zerolog` for structured logging (modeled on `pas-psf`); MCP stdio: `github.com/modelcontextprotocol/go-sdk` v1.8.0 (`research.md`). No NATS/Postgres/GCS SDKs in 002.

**Logging & Config Pattern**: Adopts the `pas-psf` convention:
- `internal/config`: fail-fast loading of env vars (`$SPOOL_ROOT`, `$SPOOL_KEYS_DIR`, `$SPOOL_BOX_ID`, log settings).
- `internal/logging`: `zerolog.Logger` with RFC3339 timestamps, service tag, log levels, console formatting for CLI, JSON formatting when deployed.

**Storage**: local filesystem under `$SPOOL_ROOT` (default
`/var/tmp/claude/msgs`). The optional box key under `$HOME` (outside the spool root).

**Testing & Harness**:
- `go test ./...`: unit tests + table-driven round-trip harness using `internal/testkit` (assertions, fixture loaders, isolated temp spool roots), modeled on `/opt/pas/pas-psf/pas-psf-api/src/internal/testkit/`.
- Shell function utilities and tests: under `csi-spl-api/src/bash/` following the `run-bsh` conventions and test scripts (`*.tst.sh`) from `/opt/pas/pas-psf/pas-psf-api/src/bash/`.

**Local Dev Setup (`lde`) Reference**:
Follows the local development conventions from `/opt/pas/pas-psf`:
- Host and containerized Go development (`go run`, `go test ./...`, `go mod tidy`) matching `/opt/pas/pas-psf/pas-psf-api`.
- Shell function utilities and test runners executed via `./run` actions matching `pas-psf-utl` / `pas-psf-iac`.

**Target Platform**: Linux box (any box that runs agents). Single filesystem.

**Project Type**: single Go module (`csi-spl-api/src/go/spool-hub-api`), one binary, subcommands.

**Performance Goals**: interactive latency (a send/recv is a few file ops);
no throughput target in 002.

**Constraints**: rely on OS filesystem permissions for local security (no custom auth wheel); no key in `$SPOOL_ROOT`/git/log (VII); atomic-rename acks
(NFR-004); on-disk `v:1` == wire `v:1` for 003 (NFR-003); no ysg-box coupling.

**Scale/Scope**: one box, a handful of agent ids, human-scale message volume.

## Constitution Check

- [x] **I. Paths** — binary + sources under `csi-spl-api/src/go/spool-hub-api`; `$SPOOL_ROOT`
      and `$HOME` derived, never hard-coded.
- [x] **II. Env** — `$SPOOL_ROOT` and key/pin locations are env vars with the
      documented default; nothing else baked in.
- [x] **VI. Cnf-only** — no runtime host/path invented in source.
- [x] **VII. No key in git/state/log** — private keys `chmod 600`, outside the
      spool root, never logged.
- [x] **VIII. Uniform API** — one verb/tool/schema set for all kinds; kind is an
      id prefix only.
- [x] **V. Hygiene** — org-neutral; example ids/names use placeholders.
- [x] **Reference read-only** — grep gate proves no ysg-box path in the source.

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
csi-spl-api/src/go/spool-hub-api/  # the Go module home
├── cmd/spool/main.go              # subcommand dispatch: send|recv|put-file|get-file|tail|keygen|pin|mcp
├── internal/config/               # fail-fast typed config (pas-psf pattern)
├── internal/logging/              # zerolog structured logger (pas-psf pattern)
├── internal/testkit/              # test harness, assertions, temp-root fixtures (pas-psf pattern)
├── internal/msg/                  # v1 message object: build, canonicalise, (de)serialise
├── internal/sign/                 # per-box ed25519 keygen, sign, verify; box pin store (hub mode)
├── internal/action/               # the one verb layer the CLI and MCP both call
├── internal/files/                # content-addressed store (sha256), put/get
├── internal/spool/                # $SPOOL_ROOT layout, inbox/outbox/archive, atomic ack
├── internal/mcp/                  # stdio MCP server wrapping the CLI actions
└── internal/spool/spool_test.go   # temp-root round-trip harness

csi-spl-api/src/bash/              # shell scripts and function utils (pas-psf pattern)
├── scripts/                       # helper scripts
└── tests/spool-smoke.tst.sh       # end-to-end smoke mirroring agent-msg
```

**Structure Decision**: one Go module, subcommand-per-verb, thin `internal/mcp`
over the same internal actions the CLI calls — so CLI and MCP cannot drift
(Constitution VIII). Home is `csi-spl-api/src/go/spool-hub-api`. Invocation is Option A (stdio process per agent session via `spool mcp`).

## Build Order (this feature = step 1 of the 003 architecture)

Maps to `SPEC-spool-architecture.md` §8 step 1 ("Local folder CRUD + Ed25519 +
files + tail, no NATS, no GCP"). 003 picks up at step 2 (same HTTP API on Cloud
Run). Nothing here is throwaway: the `v:1` object, the CLI, and the MCP tools are
the permanent contract; 003 adds a backend behind them.

## Complexity Tracking

*No constitutional violations to justify.* The one non-obvious call — a single
binary for CLI + MCP rather than two — is required by VIII (identical behaviour)
and reduces surface, so it is a simplification, not a violation.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:30:00Z -->
