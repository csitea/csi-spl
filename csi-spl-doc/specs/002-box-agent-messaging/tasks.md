# Tasks: On-Box Agent Messaging (002-box-agent-messaging)

**Input**: Design documents from `/specs/002-box-agent-messaging/`

**Prerequisites**: plan.md, spec.md, data-model.md, contracts/

**Tests**: requested — the spec's SCs are testable; include `go test` tasks.

**Organization**: grouped by user story (US1 P1 = MVP). This feature is step 1
of the `003` architecture build order; nothing here is throwaway.

## Format: `[ID] [P?] [Story] Description`

- **[P]** = parallelisable (different files, no dep). Paths are proposals from
  plan.md; T001 confirms the module home.

## Progress (2026-09-18)

**Phases 1–5 implemented and green** (US1 MVP + US2 files/dirs + US3 tail) in
`csi-spl-api/src/go/spool-hub-api/`. `bash csi-spl-api/src/bash/tests/run-all-tests.sh`
= gofmt + vet + `go test ./...` + hygiene gate + a 10-check end-to-end smoke, all
passing. Phase 6 (US4): `spool mcp` on go-sdk v1.8.0; CLI verbs and MCP tools
both call `internal/action`, and `internal/mcp` tests prove SC-004. Phase 7
docs: `quickstart.md` (T025), hygiene sweep + gofmt (T026), box install path
(T027). **Remaining**: T028.

## Phase 1: Setup

- [x] T001 Go module home `csi-spl-api/src/go/spool-hub-api/` + `go.mod` (Go
      1.22, offline via module cache). Build via `csi-spl-api/src/bash/build.sh`
      (a `do_build_spool` run-bsh action in `-iac` remains a follow-up)
- [x] T002 [P] `csi-spl-api/src/bash/tests/run-all-tests.sh` runs gofmt / go vet
      / go test / hygiene gate / smoke
- [x] T003 [P] `csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` fails on any
      `/ysg-box`, `ysg-box/`, or `MSGS_ROOT` in the Go source

## Phase 2: Foundational (blocking — shared by every story)

- [x] T004a [P] `internal/config`: fail-fast loader (`caarlos0/env`) for `$SPOOL_ROOT`, `$SPOOL_KEYS_DIR`, `$SPOOL_PINS_DIR`, log level (`pas-psf` pattern)
- [x] T004b [P] `internal/logging`: `zerolog` structured logger, console/JSON, service tag, RFC3339 (`pas-psf` pattern)
- [x] T004c [P] `internal/testkit`: temp spool root fixtures + keygen/pin helper (no import cycle)
- [x] T004 [P] `internal/spool`: `$SPOOL_ROOT` layout `<id>/{inbox,outbox,archive}` + shared `files/`/`pins/`, mode 0664; atomic-rename helper
- [x] T005 [P] `internal/msg`: `v:1` struct, strict JSON, canonicaliser == `jq -cS 'del(.sig)'`, filename builder with same-second tie-break, schema limits
- [x] T006 [P] `internal/sign`: ed25519 keygen (priv `chmod 600` under `$HOME`), sign, verify; shared pin store (`--force` guard)
- [x] T007 `cmd/spool/main.go`: subcommand dispatch + exit-code convention (`0`/`78`/`1`)

## Phase 3: User Story 1 — signed message round trip (P1) 🎯 MVP

**Goal**: keygen → pin → send → recv → ack works on one box, no hub.
**Independent Test**: SC-001, SC-002 in a temp `$SPOOL_ROOT`.

- [x] T008 [US1] `spool keygen --as <id> [--force]`
- [x] T009 [US1] `spool pin --id --pubkey [--force]`
- [x] T010 [US1] `spool send --from --to [--task] --kind --body`: build+sign+write
      inbox+outbox; refuse (78) unpinned/missing key
- [x] T011 [US1] `spool recv --as [--ack]`: verify vs pin, return valid array,
      atomic ack move; report+`78` on bad sig
- [x] T012 [P] [US1] `go test` round trip via `internal/testkit`: keygen→pin→send→recv→ack;
      tampered body → 78; unpinned from → 78; double-ack returns once
- [x] T013 [P] [US1] `spool-smoke.tst.sh` bash end-to-end (10 checks) mirroring agent-msg
- [x] T013a [US1] Legacy `.md` bridge (Option B): `spool recv` transparently ingests legacy markdown messages from `$SPOOL_ROOT/<id>/inbox/`, wrapping into synthetic `kind="note"` `v:1` envelopes and archiving on `--ack`

**Checkpoint**: US1 shippable — the MVP spool.

## Phase 4: User Story 2 — content-addressed files (P2)

**Goal**: attach and fetch files by sha256. **Independent Test**: SC-003.

- [x] T014 [P] [US2] `internal/files`: blob put/get (sha256, dedupe, no partial
      write) **plus dir blobs** (deterministic tar) and **path-mode refs** (file & dir)
- [x] T015 [US2] `spool put-file` / `spool put-dir` → `{file_id, sha256, bytes, name, kind}`
- [x] T016 [US2] `spool get-file` / `spool get-dir <file_id> <dest>` with hash verify
- [x] T017 [US2] `spool send` attachments: `--file-id`, `--put-file`, `--file-ref`,
      `--dir-blob`, `--dir-ref` (blob & path modes × file & dir)
- [x] T018 [P] [US2] `go test`: blob file/dir round trips + dedupe + determinism;
      path-ref resolves & signed message still verifies; absent id fails

## Phase 5: User Story 3 — tail a thread (P3)

**Goal**: observe a task thread. **Independent Test**: two msgs one `task_id`.

- [x] T019 [US3] `spool tail --task <uuid>` oldest-first; `--json` raw `v:1` NDJSON
- [x] T020 [P] [US3] `go test`: thread ordering (oldest-first, dedupe across boxes)

## Phase 6: User Story 4 — MCP wrapper (P3)

**Goal**: identical behaviour via MCP. **Independent Test**: SC-004.

- [x] T021 [US4] Phase-0 research decision: Go stdio MCP server library
      (record in a short `research.md`)
- [x] T022 [US4] `internal/mcp`: expose `spool_put_file`/`spool_send`/`spool_recv`/
      `spool_get_file`/`spool_tail` calling the SAME internal actions as the CLI
- [x] T023 [US4] `spool mcp` subcommand starts the stdio server (one per box)
- [x] T024 [P] [US4] `go test`: an MCP call and its CLI verb produce identical
      files + return values for the same inputs; unpinned from → tool error

## Phase 7: Polish & release gate

- [x] T025 [P] `quickstart.md`: the temp-root walkthrough an operator can paste
- [x] T026 Distribution-hygiene sweep (no org/name/host/key leaks) + `gofmt`
      (clean; the only hits are `ysg-box`, the named behavioural reference)
- [x] T027 Wire the spool binary onto the box image install path (docs only in
      002; no ysg-box edit) and record how a box gets it (`quickstart.md` section 6)
- [ ] T028 `/speckit-analyze` clean; tick the plan Constitution Check boxes

## Dependencies

- Phase 1 → Phase 2 → (Phase 3 = MVP). Phases 4/5/6 depend only on Phase 2 and
  can proceed in parallel after US1. Phase 7 last.
- Within US1: T008/T009 before T010; T010 before T011; tests (T012/T013) after.

## Notes

- Nothing in this feature touches ysg-box (T003 enforces it).
- The `v:1` object, CLI verbs, and MCP tools are the permanent contract `003`
  reuses — resist adding a hub flag here.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:00:00Z -->
