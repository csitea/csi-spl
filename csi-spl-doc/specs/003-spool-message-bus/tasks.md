# Tasks: Spool message bus (hub)

**Feature**: `specs/003-spool-message-bus` · **Spec**: `./spec.md` · **Plan**: `./plan.md`

**Gate**: spec `002-box-agent-messaging` CLI + `v:1` schema exist (002 US1). Do not implement hub handlers against a forked JSON.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [ ] T001 Confirm 002 module path `csi-spl-api/src/go/spool-hub-api/` and add `internal/httpapp`, `internal/testkit`, `internal/hub`, `internal/store`, `internal/objects` packages with tests that compile empty.
- [ ] T002 [P] Add `contracts/http-v1.md` and `contracts/nats-subjects.md` to the test fixture loader (golden request/response files under `internal/hub/testdata/`).

## Phase 2: Foundational

- [ ] T003 Implement canonical `v:1` verify-on-decode in `internal/hub` using 002 `internal/sign` (no new schema). (depends on T001, 002 US1)
- [ ] T004 [P] Fail-fast env for hub listen address, `$SPOOL_ROOT`, store DSN, object bucket — no hostname literals (`internal/config`, pas-psf pattern).
- [ ] T004b [P] Server harness in `internal/httpapp` and `cmd/hub`: Fiber app, recovery/request ID middleware, ops probes (`/healthz`, `/version`), and `runUntilShutdown` graceful drain within timeout (`wire.go` pas-psf pattern).

## Phase 3: User Story 1 — HTTP send/recv (P1) 🎯 MVP

- [ ] T005 [US1] `POST /v1/messages` accepts signed `v:1`, refuses unpinned/bad sig with HTTP 400 in `internal/hub/messages.go`.
- [ ] T006 [US1] `GET /v1/messages?as=&task_id=` lists messages for `as` in `internal/hub/messages.go` (memory/sqlite store).
- [ ] T007 [US1] CLI `spool-send` / `spool-recv` gain a hub base-URL mode without changing flags (`cmd/spool`). (depends on T005, T006)
- [ ] T008 [US1] Table tests using `internal/testkit` (pas-psf pattern): pinned send round-trip; unsigned; tampered body — `internal/hub/messages_test.go`.

## Phase 4: User Story 2 — Files to object store (P1)

- [ ] T009 [US2] `POST /v1/files` stores bytes at `files/<sha256>` in `internal/objects` (local dir in tests).
- [ ] T010 [US2] `GET /v1/files/{file_id}` returns bytes or a short-lived signed URL; never logs the URL.
- [ ] T011 [US2] CLI `spool-put-file` / `spool-get-file` use hub file routes when configured (`cmd/spool`).
- [ ] T012 [US2] Round-trip test: put → send with `file_ids` → get; notify path (when present) contains no bytes.

## Phase 5: User Story 3 — Hub-down queue (P1)

- [ ] T013 [US3] When hub HTTP fails, CLI writes 002 `$SPOOL_ROOT` layout unchanged (`internal/spool` + `cmd/spool`).
- [ ] T014 [US3] Flush command/sidecar posts queued messages **without re-signing** (`internal/hub/flush.go`).
- [ ] T015 [US3] Test: stop hub, send, same-box recv; start hub, flush, peer recv.

## Phase 6: User Story 4 — Live tail (P2)

- [ ] T016 [US4] Publish small JSON to `task.<task_id>` and `agent.<id>.inbox` after persist (`internal/notify`).
- [ ] T017 [US4] `spool-tail` can subscribe (hub up) or read store (hub/NATS down) (`cmd/spool`).
- [ ] T018 [US4] Test: subscriber sees send; down subscriber still reads Postgres/sqlite; no token payloads.

## Phase 7: User Story 5 — IAM door (P3)

- [ ] T019 [US5] Document Cloud Run IAM/OIDC for the **adapter** identity in `csi-spl-iac` (no apply without owner go).
- [ ] T020 [US5] Hub rejects unauthenticated ingress before signature verify (integration test or Cloud Run contract note).

## Phase 8: User Story 6 — Adapter is another repo (P3)

- [ ] T021 [US6] Write a one-page adapter contract in `doc/md/SPEC-spool-box-api.md` (already the API) stating ysg-box MUST only shell these verbs — no code in ysg-box from this repo.

## Phase 9: Polish

- [ ] T022 Hygiene grep: no per-kind routes, no private keys in logs, no baked hosts.
- [ ] T023 `go test ./...` green for hub packages; link this spec from `csi-spl-doc/README.md`.

## Dependencies

002 US1 → T003+. US1 (T005–T008) gates US2 files. US3 flush needs US1 HTTP. US4 notify needs persist (US1). US5 after HTTP exists. US6 is documentation only here.

## Implementation strategy

MVP of 003 = US1 + US3 (HTTP + local fallback) on sqlite. Then US2 (GCS). Then US4 (NATS). IAM last.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T12:50:00Z -->
