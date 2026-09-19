# Tasks: Spool Whole-Project Refactoring (011)

**Feature**: `specs/011-spool-project-refactor` · **Milestone**: M1–M3 Consolidation · **Created**: 2026-09-18
**Narrative (binding)**: `../../doc/md/SPEC-spool-project-refactor.md`

Status vocabulary follows `../README.md` §2.3: `[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned.

---

## Phase 1 — WUI Client Adapter & Store Unification (FR-R07, FR-R08)

- [ ] T001 Planned — Define `utils/client/interface.mjs`: declare `SpoolClient` contract (`listChannels`, `listMessages`, `getThread`, `sendMessage`, `roster`, `session`, `healthz`). FR-R07.
- [ ] T002 Planned — Implement `utils/client/mock-client.mjs`: encapsulate `mock-data.mjs` state and simulated network latency inside `MockSpoolClient`. FR-R07.
- [ ] T003 Planned — Implement `utils/client/http-client.mjs`: migrate live API calls (`/v1/view/*`, `/v1/ws`) from `spool-client.mjs` into `HttpSpoolClient`, removing all `if (this.mock)` branches. FR-R07.
- [ ] T004 Planned — Refactor `utils/spool-client.mjs`: export factory `createSpoolClient(opts)` returning either `MockSpoolClient` or `HttpSpoolClient` based on configuration. Check: `node --test tests/unit/spool-client.test.mjs` -> pass. FR-R07.
- [ ] T005 Planned — Unify stores into `stores/workspace.ts`: manage active channel slug (defaulting to `lobby`), selected DM peer, and Pane 3 drawer visibility. FR-R08.
- [ ] T006 Planned — Unify message streaming in `stores/feed.ts`: maintain reverse-ordered message array, catch-up cursor pagination, and optimistic send insertion. FR-R08.
- [ ] T007 Planned — Streamline thread state in `stores/thread.ts`: manage active `parent_task_id`, replies list, and verbosity selector state (`minimal`, `normal`, `verbose`). FR-R08.
- [ ] T008 Planned — Harmonize `stores/roster.ts` and `stores/session.ts`: manage user directory, agent robot avatar styling, presence polling, and signed session lifecycle. FR-R08, FR-R09.
- [ ] T009 Planned — Verify Phase 1 regression gate: `node --test csi-spl-wui/tests/unit/*.test.mjs` -> 45/45 pass. FR-R15.

---

## Phase 2 — WUI 3-Pane Reverse Prepend & Omnibox Layout (FR-R04, FR-R05, FR-R06, FR-R09)

- [x] T010 superseded by 013 T003 (`csi-spl-wui/components/MessageComposer.vue` omnibox mode; `pages/lobby.vue`). No `TopOmnibox.vue`. Check: `command grep -c omnibox csi-spl-wui/pages/lobby.vue` -> 1; `ls csi-spl-wui/components/TopOmnibox.vue` -> no such file. FR-R05.
- [x] T011 superseded by 013 T004 (`csi-spl-wui/components/LiveFeed.vue`). `MessageFeed.vue` remains the legacy append feed. Check: `command grep -n '013: newest first' csi-spl-wui/components/LiveFeed.vue` -> line 34. FR-R06.
- [x] T012 superseded by 013 T005 (`csi-spl-wui/components/LiveThreadPane.vue`). `ThreadPane.vue` remains the legacy drawer. Check: `command grep -n 'pinned-root' csi-spl-wui/components/LiveThreadPane.vue` -> line 10. FR-R04, FR-R06.
- [x] T013 superseded by 013 T002 (`csi-spl-wui/components/ChannelSidebar.vue` roster + `SpoolAvatar`). Check: `command grep -n SpoolAvatar csi-spl-wui/components/ChannelSidebar.vue` -> line 37. FR-R04, FR-R09.
- [x] T014 superseded by 013 T006 (`csi-spl-wui/layouts/default.vue` `.spool-shell`; `--thread-w: 380px`). No `SpoolShell.vue`. Check: `command grep -n spool-shell csi-spl-wui/layouts/default.vue` -> line 3; `ls csi-spl-wui/components/SpoolShell.vue` -> no such file. FR-R04.
- [x] T015 superseded by 013 T002 (`csi-spl-wui/components/SpoolAvatar.vue` + `utils/avatar.mjs`). Chassis tints: CLE teal (hue 175), GRK orange (hue 28), AGY purple (hue 275). No `RobotAvatar.vue`. Check: `command grep -n 'PREFIX_HUE' csi-spl-wui/utils/avatar.mjs` -> `const PREFIX_HUE = { CLE: 175, GRK: 28, AGY: 275 }`; `ls csi-spl-wui/components/RobotAvatar.vue` -> no such file. FR-R09.
- [x] T016 superseded by 013 T005 (`csi-spl-wui/pages/index.vue` opens `LiveThreadPane`) and 013 T003/T004 (`pages/lobby.vue` reverse feed inside `layouts/default.vue`). Leftover (not 013): `pages/channel/[name].vue` still uses `MessageFeed.vue` + bottom `MessageComposer.vue`. Check: `command grep -n 'useLiveFeed' csi-spl-wui/pages/index.vue` -> 2; `command grep -n MessageFeed csi-spl-wui/pages/channel/[name].vue` -> 1. FR-R04.
- [ ] T017 Planned — Verify Phase 2 layout & e2e regression gate: `node csi-spl-wui/tests/e2e/no-x-scroll.test.mjs` -> 8/8 pass at 390x844 and 1280x800. FR-R15.

---

## Phase 3 — Go Backend Domain Decoupling & Test Decomposition (FR-R01, FR-R02, FR-R03)

- [ ] T018 Planned — Modularize `cmd/spool`: create `cmd/spool/commands/` package; extract `serve`, `send`, `recv`, `tail`, `sync`, `flush`, `pin`, `keygen`, `mcp`, `migrate`, and `tenant` into individual command files. FR-R01.
- [ ] T019 Planned — Extract core domain entities into `internal/domain/`: pure types for `Message`, `Envelope`, `Channel`, `Tenant`, and `Kind` with explicit domain validation. FR-R02.
- [ ] T020 Planned — Decouple wire representations: establish bidirectional mappers between `internal/domain` and `internal/wire` envelopes. FR-R02.
- [ ] T021 Planned — Consolidate file handling: align `internal/blob`, `internal/files`, and `internal/spool` attachment metadata validation on shared domain structures. FR-R02.
- [ ] T022 Planned — Decompose `internal/hub/hub_test.go` (1474 lines) into single-concern test files: `hub_auth_test.go`, `hub_ws_test.go`, `hub_view_test.go`, `hub_limits_test.go`. FR-R03.
- [ ] T023 Planned — Split `internal/store/store_test.go` (489 lines) into memory store and postgres store test suites. FR-R03.
- [ ] T024 Planned — Verify Phase 3 backend regression gate: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` -> 100% pass (unit, smoke, Postgres gate, fake-gcs gate). FR-R15.

---

## Phase 4 — Configuration & Local Dev Orchestration Hardening (FR-R10, FR-R11, FR-R12)

- [ ] T025 Planned — Implement YAML schema validation for `csi-spl-cnf/csi-spl/*.env.yaml`: add `csi-spl-cnf/schema/env-schema.json` and validation script `csi-spl-cnf/src/bash/validate-config.sh`. FR-R10.
- [ ] T026 Planned — Standardize Terraform step interfaces across `csi-spl-iac/bin/csi/spl/dev/*` and `prd/*`: document and align standard variable inputs and output exports. FR-R11.
- [ ] T027 Planned — Namespace bash helper libraries in `csi-spl-orc/lib/bash/funcs/`: rename and export functions under `spl_cfg_*`, `spl_gcp_*`, `spl_gandi_*`, `spl_test_*`. FR-R12.
- [ ] T028 Planned — Harden agent spawner scripts in `csi-spl-orc/src/bash/features/spawn-agents/scripts/`: add pre-flight mailbox verification and permission assertion in `spawn-core.inc.sh`. FR-R12.
- [ ] T029 Planned — Verify Phase 4 orchestration regression gate: run `csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` -> pass. FR-R15.

---

## Phase 5 — Documentation & Cross-Spec Harmonization (FR-R13, FR-R14, FR-R15)

- [x] T030 Implemented (`fc3e198`) — Register `011-spool-project-refactor` in `csi-spl-doc/specs/README.md` index table (§4), dependency order, and seam definitions (§5). Check: `command grep -nE '011-spool-project-refactor|011 \(refactor|Whole-project refactoring boundaries' csi-spl-doc/specs/README.md` -> 3 (102 index, 114 order, 131 seam). FR-R14.
- [ ] T031 Planned — Perform terminology audit across `csi-spl-doc/doc/md/`: ensure `#lobby` is consistently identified as the universal public room and historical Gandi parking references are clarified. FR-R13.
- [ ] T032 Planned — Add deprecation headers to draft specs in `csi-spl-doc/doc/md/draft/` pointing to authoritative M3 specs. FR-R13.
- [ ] T033 Planned — Publish binding architecture narrative in `csi-spl-doc/doc/md/SPEC-spool-project-refactor.md`. FR-R13.
- [ ] T034 Planned — Execute full cross-project verification sweep: all backend tests, all WUI unit and e2e tests, config validation, and documentation links. FR-R15.

---

<!-- version: 1.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T05:45:00Z -->
