# Tasks: Spool testability

**Feature**: `specs/016-spool-testability` · **Spec**: `./spec.md`

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). YAML changes are **008's**; named here so the gap is not lost.

## Already true (measured `35ed54c`)

- [x] T010 Implemented — hub quality gate: `run-all-tests.sh` + skip-fail for Postgres/GCS (`10_ci-quality.yml` hub-suite). FR-001.
- [x] T011 Implemented — WUI unit discovery + typecheck in `wui-suite`. FR-002.
- [x] T012 Implemented — store `drivers()` Memory + Postgres; hub-pg one DB per package. FR-006.
- [x] T013 Implemented — `internal/testkit` temp dirs; baked-host / ysg-box hygiene. FR-007.
- [x] T014 Implemented — 007 T070: missing terraform/tpl-gen is FAIL (not silent PASS). FR-010. Still local-only until T003.

## Phase 1 — Docs (016)

- [x] T001 Implemented (this dir) — `spec.md`, `plan.md`, `contracts/test-layers.md`. FR-001–FR-011 inventory.

## Phase 2 — Close skip-pass and CI holes

- [ ] T002 Planned (api) — `csi-spl-api/src/bash/tests/run-all-tests.sh`: `go test -race ./...` (or `-race` on `./internal/{hub,auth,store,hubclient}/`). FR-004. SC-002.
- [ ] T003 Planned (008) — `10_ci-quality.yml` job `iac-suite`: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` with terraform 1.9 and in-repo tpl-gen; **do not** set `SPL_TF_ALLOW_SKIP`. FR-003. SC-001.
- [ ] T004 Planned (008) — job `orc-suite`: hermetic orc `*.tst.sh` that need no live GCP / no full lde. Split out `lde-stack.tst.sh` if it cannot run on ubuntu-latest. FR-003.
- [ ] T005 Planned (008) — job `cnf-suite`: `bash csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` (install conf-validator poetry env first). FR-003.
- [ ] T006 Planned (005/wui) — `tests/e2e/live-interop.test.mjs`: if `CI` is set and `HUB_URL` is unset, exit 1 (not 0). FR-005. SC-003.
- [x] T007 Implemented — `specs/README.md` §4 lists 014, 015, 016 (this dir) and 017; seam “Test layers” → `016 contracts/test-layers.md`.

## Phase 3 — Out of the product gate (document only)

- [x] T020 Implemented as policy — spawn-agents tests are local (FR-011). Do not add them to `10_ci-quality.yml`.
- [ ] T021 Planned — optional later: WUI `test:e2e` on a browser-capable runner (OQ-016-2). Not required to close US2.

## FR → task

| FR | Tasks | Status |
|---|---|---|
| FR-001 | T010 | Implemented |
| FR-002 | T011 | Implemented |
| FR-003 | T003, T004, T005 | Planned |
| FR-004 | T002 | Planned |
| FR-005 | T006, T021 | Planned |
| FR-006 | T012 | Implemented |
| FR-007 | T013 | Implemented |
| FR-008 | (009/006 when those features grow tests) | Partial |
| FR-009 | hub-e2e via T010; cloud demo stays 006 T011c | Partial |
| FR-010 | T014, T003 | Partial (local yes, CI no) |
| FR-011 | T020 | Implemented |

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T12:55:31Z -->
