# Tasks: On-Box Agent Messaging (002-box-agent-messaging)

**Input**: Design documents from `/specs/002-box-agent-messaging/`

**Prerequisites**: plan.md, spec.md, data-model.md, contracts/

**Tests**: requested — the spec's SCs are testable; include `go test` tasks.

**Organization**: grouped by user story (US1 P1 = MVP). This feature is step 1
of the `003` architecture build order; nothing here is throwaway.

## Format: `[ID] [P?] [Story] Description`

- **[P]** = parallelisable (different files, no dep). Paths are proposals from
  plan.md; T001 confirms the module home.

## Phase 1: Setup

- [ ] T001 Decide + create the Go module home (`csi-spl-utl/src/go/spool/`
      proposed) and `go.mod` (Go 1.22+); wire a `do_build_spool` run-bsh action
- [ ] T002 [P] Add `go test`/`go vet`/`gofmt` to
      `csi-spl-iac/src/bash/tests/run-all-tests.sh` (or the owning sub-project)
- [ ] T003 [P] Add a reference-hygiene test: grep the shipped source for any
      ysg-box path and fail if found (enforces Constitution "read-only reference")

## Phase 2: Foundational (blocking — shared by every story)

- [ ] T004 [P] `internal/spool`: resolve `$SPOOL_ROOT` (default
      `/var/tmp/claude/msgs`), create `<id>/{inbox,outbox,archive}` + `files/`,
      mode 0664; atomic-rename helper
- [ ] T005 [P] `internal/msg`: `v:1` struct, strict JSON (reject unknown keys),
      canonicaliser byte-identical to `jq -cS 'del(.sig)'`, filename builder
      `<ts>--<from>--<slug>.json` with same-second tie-break
- [ ] T006 [P] `internal/sign`: ed25519 keygen (priv `chmod 600` under `$HOME`),
      sign, verify; pin store (id→pubkey) with `--force` guard on re-pin
- [ ] T007 `cmd/spool/main.go`: subcommand dispatch + exit-code convention
      (`0`/`78`/`1`) shared by all verbs

## Phase 3: User Story 1 — signed message round trip (P1) 🎯 MVP

**Goal**: keygen → pin → send → recv → ack works on one box, no hub.
**Independent Test**: SC-001, SC-002 in a temp `$SPOOL_ROOT`.

- [ ] T008 [US1] `spool-keygen --as <id>` (contracts/cli.md)
- [ ] T009 [US1] `spool-pin --id --pubkey [--force]`
- [ ] T010 [US1] `spool-send --from --to --task --kind --body`: build+sign+write
      inbox+outbox; refuse (78) unpinned/missing key
- [ ] T011 [US1] `spool-recv --as [--ack]`: verify vs pin, return valid array,
      atomic ack move; report+`78` on bad sig
- [ ] T012 [P] [US1] `go test` round trip: keygen→pin→send→recv→ack; tampered
      body → 78; unpinned from → 78; double-ack returns once
- [ ] T013 [P] [US1] `spool-smoke.tst.sh` bash end-to-end mirroring the agent-msg
      flow (two ids, send, recv, ack)

**Checkpoint**: US1 shippable — the MVP spool.

## Phase 4: User Story 2 — content-addressed files (P2)

**Goal**: attach and fetch files by sha256. **Independent Test**: SC-003.

- [ ] T014 [P] [US2] `internal/files`: put (sha256 → `files/<id>`, idempotent),
      get (re-hash, no partial write, fail on absent)
- [ ] T015 [US2] `spool-put-file <path>` → `{file_id, sha256, bytes, name}`
- [ ] T016 [US2] `spool-get-file <file_id> <dest>` with hash verify
- [ ] T017 [US2] `spool-send --file-id ...` embeds file refs into the `v:1` object
- [ ] T018 [P] [US2] `go test`: put→send→get round trip verifies sha256; identical
      bytes dedupe to one object; absent id fails cleanly

## Phase 5: User Story 3 — tail a thread (P3)

**Goal**: observe a task thread. **Independent Test**: two msgs one `task_id`.

- [ ] T019 [US3] `spool-tail --task <uuid>` oldest-first; `--json` raw `v:1` NDJSON
- [ ] T020 [P] [US3] `go test`: ordering + `--json` round-trips through `jq`

## Phase 6: User Story 4 — MCP wrapper (P3)

**Goal**: identical behaviour via MCP. **Independent Test**: SC-004.

- [ ] T021 [US4] Phase-0 research decision: Go stdio MCP server library
      (record in a short `research.md`)
- [ ] T022 [US4] `internal/mcp`: expose `spool_put_file`/`spool_send`/`spool_recv`/
      `spool_get_file`/`spool_tail` calling the SAME internal actions as the CLI
- [ ] T023 [US4] `spool mcp` subcommand starts the stdio server (one per box)
- [ ] T024 [P] [US4] `go test`: an MCP call and its CLI verb produce identical
      files + return values for the same inputs; unpinned from → tool error

## Phase 7: Polish & release gate

- [ ] T025 [P] `quickstart.md`: the temp-root walkthrough an operator can paste
- [ ] T026 Distribution-hygiene sweep (no org/name/host/key leaks) + `gofmt`
- [ ] T027 Wire the spool binary onto the box image install path (docs only in
      002; no ysg-box edit) and record how a box gets it
- [ ] T028 `/speckit-analyze` clean; tick the plan Constitution Check boxes

## Dependencies

- Phase 1 → Phase 2 → (Phase 3 = MVP). Phases 4/5/6 depend only on Phase 2 and
  can proceed in parallel after US1. Phase 7 last.
- Within US1: T008/T009 before T010; T010 before T011; tests (T012/T013) after.

## Notes

- Nothing in this feature touches ysg-box (T003 enforces it).
- The `v:1` object, CLI verbs, and MCP tools are the permanent contract `003`
  reuses — resist adding a hub flag here.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T00:00:00Z -->
