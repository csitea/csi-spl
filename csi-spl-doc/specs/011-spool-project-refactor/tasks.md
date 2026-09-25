# Tasks: Spool Whole-Project Refactoring (011)

**Feature**: `specs/011-spool-project-refactor` · **Milestone**: M1–M3 Consolidation · **Created**: 2026-09-18
**Narrative (binding)**: `../../doc/md/SPEC-spool-project-refactor.md`

Status vocabulary follows `../README.md` §2.3: `[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned.

---

## Phase 1 — WUI Client Adapter & Store Unification (FR-R07, FR-R08)

**Planned (deferred by owner 2026-09-19)** — T001–T008 are not to be started: the client adapter and the 5-store refactor rewrite exactly the files the A1–A5, H4 and X3 gap rows just changed (`src/utils/spool-client.mjs`, `src/stores/*.ts`, the channel/lobby pages). Revisit after M3. No code was changed for this decision. Audit 2026-09-25 (`28442ef6`): the target store names predate the thread→topic rename (`57f8a670`, `stores/topic.ts`) and the verbosity dropdown removal (`d1648dd0`); 11 stores exist. Rewrite or retire Phase 1: open, owner decision (asked in topic 582f7895).

- [ ] T001 Planned (deferred by owner 2026-09-19) — Define `utils/client/interface.mjs`: declare `SpoolClient` contract (`listChannels`, `listMessages`, `getThread`, `sendMessage`, `roster`, `session`, `healthz`). FR-R07.
- [ ] T002 Planned (deferred by owner 2026-09-19) — Implement `utils/client/mock-client.mjs`: encapsulate `mock-data.mjs` state and simulated network latency inside `MockSpoolClient`. FR-R07.
- [ ] T003 Planned (deferred by owner 2026-09-19) — Implement `utils/client/http-client.mjs`: migrate live API calls (`/v1/view/*`, `/v1/ws`) from `spool-client.mjs` into `HttpSpoolClient`, removing all `if (this.mock)` branches. FR-R07.
- [ ] T004 Planned (deferred by owner 2026-09-19) — Refactor `utils/spool-client.mjs`: export factory `createSpoolClient(opts)` returning either `MockSpoolClient` or `HttpSpoolClient` based on configuration. Check: `node --test tests/unit/spool-client.test.mjs` -> pass. FR-R07.
- [ ] T005 Planned (deferred by owner 2026-09-19) — Unify stores into `stores/workspace.ts`: manage active channel slug (defaulting to `lobby`), selected DM peer, and Pane 3 drawer visibility. FR-R08.
- [ ] T006 Planned (deferred by owner 2026-09-19) — Unify message streaming in `stores/feed.ts`: maintain reverse-ordered message array, catch-up cursor pagination, and optimistic send insertion. FR-R08.
- [ ] T007 Planned (deferred by owner 2026-09-19) — Streamline thread state in `stores/thread.ts`: manage active `parent_task_id`, replies list, and verbosity selector state (`minimal`, `normal`, `verbose`). FR-R08.
- [ ] T008 Planned (deferred by owner 2026-09-19) — Harmonize `stores/roster.ts` and `stores/session.ts`: manage user directory, agent robot avatar styling, presence polling, and signed session lifecycle. FR-R08, FR-R09.
- [ ] T009 Planned — Verify Phase 1 regression gate: `node --test csi-spl-wui/tests/unit/*.test.mjs` -> all pass (1141/1141 at `28442ef6`, n=1, before any Phase 1 change). FR-R15.

---

## Phase 2 — WUI 3-Pane Reverse Prepend & Omnibox Layout (FR-R04, FR-R05, FR-R06, FR-R09)

T010–T016 checks re-run 2026-09-19 (audit CLE-3358, tree a2eac90) after the WUI `srcDir: 'src/'` move (`fff663d`): paths now carry `src/`, line numbers refreshed.

- [x] T010 Implemented (by 013 T003; Omnibox now in `TopBar.vue`, 022 `63e37dc`) (`csi-spl-wui/src/components/MessageComposer.vue` omnibox mode; `pages/lobby.vue`). No `TopOmnibox.vue`. Check: `command grep -c omnibox csi-spl-wui/src/pages/lobby.vue` -> 1; `ls csi-spl-wui/src/components/TopOmnibox.vue` -> no such file. FR-R05.
- [x] T011 Implemented (by 013 T004) (`csi-spl-wui/src/components/LiveFeed.vue`). `MessageFeed.vue` remains the legacy append feed. Check: `command grep -n '013: newest first' csi-spl-wui/src/components/LiveFeed.vue` -> line 71 (`28442ef6`). FR-R06.
- [x] T012 Implemented (by 013 T005; `csi-spl-wui/src/components/LiveTopicPane.vue`, renamed from `LiveThreadPane.vue` in `57f8a670`). `TopicPane.vue` (was `ThreadPane.vue`) is the channel pane. Check: `command grep -n 'pinned-root' csi-spl-wui/src/components/LiveTopicPane.vue` -> line 29. FR-R04, FR-R06.
- [x] T013 Implemented (by 013 T002) (`csi-spl-wui/src/components/ChannelSidebar.vue` roster + `SpoolAvatar`). Check: `command grep -n SpoolAvatar csi-spl-wui/src/components/ChannelSidebar.vue` -> line 72 (first of 3). FR-R04, FR-R09.
- [x] T014 Implemented (by 013 T006; `csi-spl-wui/src/layouts/default.vue` `.spool-shell`; `--topic-w: 380px` at `src/assets/css/variables.css:91`). No `SpoolShell.vue`. Check: `command grep -n spool-shell csi-spl-wui/src/layouts/default.vue` -> line 16; `ls csi-spl-wui/src/components/SpoolShell.vue` -> no such file. FR-R04.
- [x] T015 Implemented (by 013 T002) (`csi-spl-wui/src/components/SpoolAvatar.vue` + `utils/avatar.mjs`). Chassis tints: CLE teal (hue 175), GRK orange (hue 28), AGY purple (hue 275). No `RobotAvatar.vue`. Check: `command grep -n 'PREFIX_HUE' csi-spl-wui/src/utils/avatar.mjs` -> `const PREFIX_HUE = { CLE: 175, GRK: 28, AGY: 275 }`; `ls csi-spl-wui/src/components/RobotAvatar.vue` -> no such file. FR-R09.
- [x] T016 Implemented (by 013 T005 (`csi-spl-wui/src/pages/index.vue` opens `LiveThreadPane`) and 013 T003/T004 (`pages/lobby.vue` reverse feed inside `layouts/default.vue`). `pages/channel/[name].vue` uses `MessageFeed.vue`, which renders `LiveFeed` (013 T010; `command grep -c '<LiveFeed' csi-spl-wui/src/components/MessageFeed.vue` -> 1); the composer is the TopBar Omnibox (022), no bottom composer. Check: `command grep -n 'useLiveFeed' csi-spl-wui/src/pages/index.vue` -> 2; `command grep -n MessageFeed csi-spl-wui/src/pages/channel/[name].vue` -> 1. FR-R04.
- [x] T017 Implemented (by 013 T025) — Verify Phase 2 layout & e2e regression gate: `node csi-spl-wui/tests/e2e/no-x-scroll.test.mjs` -> 56/56 pass incl. 390x844 and 1280x800 (2026-09-21, n=1, recorded in 013 T025; not re-run in this audit). FR-R15.

---

## Phase 3 — Go Backend Domain Decoupling & Test Decomposition (FR-R01, FR-R02, FR-R03)

- [ ] T018 Planned — Modularize `cmd/spool`: create `cmd/spool/commands/` package; extract `serve`, `send`, `recv`, `tail`, `sync`, `flush`, `pin`, `keygen`, `mcp`, `migrate`, and `tenant` into individual command files. Current: 15 `flag.NewFlagSet` uses (main.go 7, hub.go 8) inside a 22-case string switch in `main.go` (`28442ef6`). FR-R01.
- [ ] T019 Planned — Extract core domain entities into `internal/domain/`: pure types for `Message`, `Envelope`, `Channel`, `Tenant`, and `Kind` with explicit domain validation. Whether to build `internal/domain`/`service`/`transport` at all: open, owner decision (asked in topic 582f7895). FR-R02.
- [ ] T020 Planned — Decouple wire representations: establish bidirectional mappers between `internal/domain` and `internal/wire` envelopes. FR-R02.
- [ ] T021 Planned — Consolidate file handling: align `internal/blob`, `internal/files`, and `internal/spool` attachment metadata validation on shared domain structures. FR-R02.
- [ ] T022 Planned — Decompose `internal/hub/hub_test.go` (1476 lines at `28442ef6`; six more hub test files exceed 500 lines, see FR-R03) into single-concern test files: `hub_auth_test.go`, `hub_ws_test.go`, `hub_view_test.go`, `hub_limits_test.go`. FR-R03.
- [ ] T023 Planned — Split `internal/store/store_test.go` (488 lines at `28442ef6`, under FR-R03's 500-line threshold) into memory store and postgres store test suites. Keep or drop: open, owner decision (asked in topic 582f7895). FR-R03.
- [ ] T024 Planned — Verify Phase 3 backend regression gate: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` -> 100% pass (unit, smoke, Postgres gate, fake-gcs gate). FR-R15.

---

## Phase 4 — Configuration & Local Dev Orchestration Hardening (FR-R10, FR-R11, FR-R12)

- [~] T025 Partial (`9c576311`) — Implement YAML schema validation for `csi-spl-cnf/csi-spl/*.env.yaml`. Built: pydantic `csi-spl-cnf/src/python/conf-validator` (EnvModels all/dev/prd) run before tpl-gen by `csi-spl-orc/src/make/generate-config-for-step.func.mk:13`, exit-code contract `csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` in CI `cnf-suite`. Missing: an `lde` model, a gate before `./run`. Whether pydantic replaces the planned `schema/env-schema.json`: open, owner decision (asked in topic 582f7895). FR-R10.
- [~] T026 Partial — Standardize Terraform step interfaces across `csi-spl-iac/src/terraform/*` (15 steps; `csi-spl-iac/bin/` is git-ignored build output): document and align standard variable inputs and output exports. Built: 13 steps use `01-providers.tf`/`02-variables.tf`/`05-outputs.tf`. Missing: `005` and `032` use the dotted layout (`99.outputs.tf`), `000` and `001` have no outputs file, no interface matrix. FR-R11.
- [ ] T027 Planned — Namespace bash helper libraries in `csi-spl-orc/lib/bash/funcs/`: rename and export functions under `spl_cfg_*`, `spl_gcp_*`, `spl_gandi_*`, `spl_test_*` (0 such functions at `28442ef6`; the namespace set, incl. `spl_gandi_*` with DNS on Cloud DNS: open, owner decision (asked in topic 582f7895)). FR-R12.
- [~] T028 Partial — Harden agent spawner scripts in `csi-spl-orc/src/bash/features/spawn-agents/scripts/`: add pre-flight mailbox verification and permission assertion in `spawn-core.inc.sh`. Built: `spawn-core.inc.sh:194-195` creates `{inbox,outbox,archive}` and sets 0775. Missing: both steps end `|| true` (no assertion), no daemon liveness check. FR-R12.
- [ ] T029 Planned — Verify Phase 4 orchestration regression gate: run `csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` -> pass (17 files in that dir; the suite is not in CI `orc-suite`, which runs `csi-spl-orc/src/bash/tests/*.tst.sh`). FR-R15.

---

## Phase 5 — Documentation & Cross-Spec Harmonization (FR-R13, FR-R14, FR-R15)

- [x] T030 Implemented (`fc3e198`) — Register `011-spool-project-refactor` in `csi-spl-doc/specs/README.md` index table (§4), dependency order, and seam definitions (§5). Check: `command grep -nE '011-spool-project-refactor|011 \(refactor|Whole-project refactoring boundaries' csi-spl-doc/specs/README.md` -> 3 (102 index, 139 order, 162 seam; re-measured `28442ef6`). FR-R14.
- [~] T031 Partial — Perform terminology audit across `csi-spl-doc/doc/md/`: ensure `#lobby` is consistently identified as the universal public room and historical Gandi parking references are clarified. Done: all 3 `#general` hits read "Slack's `#general` equivalent" (`git grep -n '#general' -- csi-spl-doc/doc/md`). Missing: "must stay on Gandi nameservers" at `SPEC-spool-hub-api-infra.md:92-100` and the 2026-09-17 Gandi reading at `csi-spl.feature.md:135-138` contradict `specs/README.md` §6 (Cloud DNS). FR-R13.
- [x] T032 Implemented (`d91d7997`) — Add deprecation headers to draft specs in `csi-spl-doc/doc/md/draft/` pointing to authoritative M3 specs. Check: `ls csi-spl-doc/doc/md/draft` -> `SPEC-spool-architecture.md` only, which reads "This draft moved. The binding document is `../SPEC-spool-message-bus.md`". FR-R13.
- [x] T033 Implemented (`fc3e198`) — Publish binding architecture narrative in `csi-spl-doc/doc/md/SPEC-spool-project-refactor.md`. Check: `wc -l` -> 64. FR-R13.
- [ ] T034 Planned — Execute full cross-project verification sweep: all backend tests, all WUI unit and e2e tests, config validation, and documentation links. FR-R15.

---

<!-- version: 1.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:32:11Z -->
