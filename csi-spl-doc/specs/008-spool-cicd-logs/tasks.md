# Tasks: CI/CD logs in spool chat (M1 stub)

**Feature**: `specs/008-spool-cicd-logs`  |  **Spec**: ./spec.md  |  **Contract**: ./contracts/fetch-deliver.md

No plan.md beyond the contract: M1 is a flagged-off hub-side stub on the
existing v:1 bus. `gh` in the image is after M3.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [x] T001 Contract `contracts/fetch-deliver.md`: hub-side fetch+deliver,
      flag default off, prd fail-closed, per-tenant allowlist, 32 MiB file,
      no `gh` in M1.
- [ ] T002 [P] Publish `SPOOL_HUB_CICD_LOGS_ENABLED=false` in
      `csi-spl-cnf/csi-spl/all.env.yaml` `hub.env` (names only; token is a
      secret, never a value). Do not tpl-gen / rewrite other steps.

## Phase 2: Foundational

- [ ] T003 `internal/cicdlogs`: parse allowlist + tokens, placeholder
      detect, prd fail-closed, URL/`owner`+`repo`+`run_id` parse.
      (`csi-spl-api/src/go/spool-hub-api/internal/cicdlogs`)
- [ ] T004 [P] HTTP fetcher (configurable API base, strip `Authorization`
      on redirect, scrub token from errors). No `gh`, no baked host.
- [ ] T005 Fetch+deliver: blob put, `kind=note` + file, 32 MiB truncate +
      body line, `CI not configured` when no tenant token, empty allowlist
      denies. Memory bus in unit tests.

## Phase 3: User Story 1 — hub bus (stub) 🎯

- [ ] T006 [US1] `config.LoadHub` reads the 008 env names; fail-closed in
      prd when enabled and the token is missing/placeholder.
      (`internal/config`)
- [ ] T007 [US1] `POST /v1/cicd-logs` registered only when enabled; upload
      token; `to_box` = token box; commit on the existing envelope path;
      404 when the flag is off. (`internal/hub`)
- [ ] T008 [US1] Hub tests: flag off → 404; unconfigured note; allowlist
      403; fake GitHub → note+file on the bus; cross-tenant isolation;
      token absent from body and error detail. (`internal/hub/hub_test.go`)
- [ ] T009 [P] M1 Dockerfile still has no `gh`
      (`csi-spl-orc/src/docker/spool-hub-api/Dockerfile` — assert only).

## Phase 4: Polish

- [ ] T010 `go test ./...` and `bash csi-spl-api/src/bash/tests/run-all-tests.sh`
      green. No wui, no 031, no token in git.

## Out of this stub (later)

T011 `gh` in the Cloud Run image (FR-001 after M3). T012 Secret Manager
slot + 029. T013 MCP/CLI. T014 WUI. T015 streaming tail.

## Traceability

| FR | Tasks |
|---|---|
| FR-001 (no gh in M1) | T009 |
| FR-002 token / optional / secret | T003, T006, T008 |
| FR-003 per-tenant allowlist | T003, T005, T008 |
| FR-004 v:1 note + file | T005, T007, T008 |
| FR-005 no token leak | T004, T008, T010 |
| FR-006 flag off, prd fail-closed, 32 MiB | T002, T005, T006 |

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:53:00Z -->
