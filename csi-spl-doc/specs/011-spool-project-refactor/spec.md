# Feature Specification: Spool Whole-Project Refactoring (011)

**Feature ID**: `011-spool-project-refactor` · **Milestone**: M1–M3 Consolidation · **Status**: Planned
**Created**: 2026-09-18 · **Lane**: Core Architecture · **Narrative (binding)**: `../../doc/md/SPEC-spool-project-refactor.md`

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial** (missing part named), **Planned**.

---

## 0. Current Reality & Codebase Audit (Baseline)

As of commit `c912a05` (master trunk), the `csi-spl` project consists of five active sub-systems spanning Go backend services, Nuxt 3 frontend application, Terraform GCP infrastructure, local orchestration tooling, and git-spec documentation:

| Subsystem | Tech Stack | Measured Size | Test Suite Status | Architectural Role |
|---|---|---|---|---|
| `csi-spl-api` | Go 1.22+ (`spool-hub-api`) | 54 Go files, 13,967 LOC | 100% green (unit, smoke, Postgres gate, fake-gcs gate) | Box CLI (`cmd/spool`), MCP server, Cloud Run hub API |
| `csi-spl-wui` | Nuxt 3, Vue 3, Pinia, TypeScript | 14 TS/Vue components, 16 `.mjs` modules | 45 unit tests pass, e2e `no-x-scroll` pass | Slack-like WUI (3-pane layout, reverse prepend feed) |
| `csi-spl-iac` | Terraform, Google Cloud Platform | 10 step dirs (`000`–`050`) | `./run` actions green, DNS delegated, LB live | Remote state, Cloud SQL, Cloud Run, GCS, Cloud Armor |
| `csi-spl-cnf` | YAML (`all`, `dev`, `prd`, `lde`) | 4 environment configs | Rendered via `tpl-gen` | Single source of truth for infrastructure & app vars |
| `csi-spl-orc` | Bash 5, Docker | ~40 function & run scripts | Agent spawn tests green, LDE operational | Local dev environment, test runners, container runners |
| `csi-spl-doc` | Markdown, Spec-Kit | 10 spec folders (`001`–`010`), 17 `doc/md` specs | Cross-spec consistency verified (`specs/README.md`) | System blueprints, wire contracts, task matrices |

### 0.1 Identified Structural Debt & Refactoring Pressure Points

While all functional regression gates are strictly green, rapid iterative delivery across ~30 parallel agent lanes during milestones M1, M2, and M3 has generated architectural fragmentation:

1. **`csi-spl-api`: Monolithic Command Router & Domain Coupling**:
   - `cmd/spool/main.go` (315 lines) and `cmd/spool/hub.go` (311 lines) manually switch on string arguments without standardized flag parsing, context cancellation trees, or structured CLI error wrapping.
   - Leaky domain types: `wire.Envelope` (`internal/wire`), `msg.Message` (`internal/msg`), and database entities (`internal/store`) duplicate fields (`v`, `task_id`, `msg_id`, `parent_task_id`, `kind`, `body`, `files`) with custom bidirectional mapping routines scattered across packages.
   - Testing monolith: `internal/hub/hub_test.go` spans 1,474 lines, convolving WebSocket protocol handshake, tenant isolation, quota enforcement, and REST file routes in single test flows.
   - Dual file abstractions: `internal/blob` (GCS client) and `internal/files` (file metadata validation) have overlapping responsibilities with `internal/spool` local attachment handling.

2. **`csi-spl-wui`: Hybrid Component Duality & Client Branching**:
   - The frontend currently contains an unresolved tension between the Phase 2 read-only viewer (`pages/index.vue`, `pages/t/[task_id].vue`, `stores/viewer.ts`) and the newly specified M3 3-pane reverse layout (`SPEC-spool-wui-layout.md`, `SPEC-spool-chat-reverse.md`).
   - `pages/channel/[name].vue` retains the legacy bottom composer and downward append stream, conflicting with the top Omnibox and reverse prepend architecture.
   - `utils/spool-client.mjs` embeds `if (this.mock)` conditionals throughout every method instead of cleanly isolating mock state behind a polymorphic client adapter interface.
   - State fragmentation: 6 Pinia stores (`channel`, `viewer`, `thread`, `roster`, `session`, `notification`) maintain independent caching lifetimes and duplicate message lookup maps.

3. **`csi-spl-iac` & `csi-spl-cnf`: Fragmented State & Unvalidated Configs**:
   - 10 distinct Terraform directories require procedural orchestration via bash `./run` scripts rather than structured Terraform module composition.
   - Configuration files in `csi-spl-cnf` lack a formal schema validation gate, allowing missing or misspelled keys to slip into `tpl-gen` execution until terraform validation fails.
   - WIF deploy step `017-github-wif-deploy` remains unapplied, requiring manual deployment overrides.

4. **`csi-spl-orc`: Script Sprawl & Inconsistent Function Signatures**:
   - Bash functions in `lib/bash/funcs` and `src/bash/run` mix direct global variable inspection with positional parameter parsing.
   - Agent spawner scripts (`spawn-claude.sh`, `spawn-agy.sh`, `spawn-grok.sh`) lack unified pre-flight checks for mailbox directory permissions and daemon liveness.

5. **`csi-spl-doc`: Historical Spec Inconsistencies**:
   - Earlier draft specifications retain references to superseded concepts (e.g. Gandi parking prior to Cloud DNS delegation, deprecated `/v1/messages` REST routes, and residual mentions of `#general` before the `#lobby` standardization).

---

## 1. Problem Statement & Motivation

As the project scales from prototype M1 into production-grade multi-tenant operations (M2 rental/payments and M3 Slack-like real-time WUI), the accumulated duplication and boundary erosion create operational friction:
- Adding features (such as social auth human registration, reverse message prepending, or robot avatar rendering) requires editing multiple loosely-coupled stores and packages.
- Testing requires navigating oversized integration files rather than fast, isolated unit boundaries.
- Onboarding human developers and autonomous AI coding agents is hampered by discrepancies between older design docs and trunk implementations.

A unified, whole-project refactoring specification is necessary to cleanly establish modular boundaries, eliminate tech debt, harmonize frontend and backend contracts, and guarantee sustainable development across future milestones (M4 seats, BYO-GCP).

---

## 2. Goals & Non-Goals

### 2.1 Goals
1. **API Clean Architecture**: Refactor `csi-spl-api` into crisp domain boundaries (Domain Models, Application Use Cases, Transport Adapters, Infrastructure Repositories), modularize `cmd/spool`, and split monolithic test suites into focused, parallelizable test files.
2. **Unified WUI 3-Pane Reverse Chat**: Complete the migration of `csi-spl-wui` into the 3-pane architecture (Left: Channels/Roster with `#lobby`, Middle: Reverse Prepend Feed with pinned Top Omnibox, Right: Collapsible Thread Pane), replacing `if (mock)` branching with a clean Client Adapter pattern.
3. **Consolidated Store & Composable Layer**: Unify frontend stores into cohesive domain stores (`workspace`, `feed`, `thread`, `roster`, `session`), eliminating duplicate state and normalizing real-time WebSocket event ingestion.
4. **Configuration & Script Hardening**: Introduce automated JSON/YAML schema validation for `csi-spl-cnf`, standardize bash library namespaces in `csi-spl-orc`, and ensure idempotent Terraform workflows.
5. **Spec & Doc Alignment**: Cleanse all 10 existing spec directories and `doc/md` narratives of legacy references, establishing a single source of architectural truth.
6. **Zero Behavioral Regression**: Maintain 100% green status across all existing verification gates (`run-all-tests.sh`, smoke, Postgres gate, fake-gcs gate, WUI unit & e2e).

### 2.2 Non-Goals
1. **No Wire Breaking Changes**: The `v:1` message schema, WebSocket challenge-response handshake, signed envelope format, and REST view contracts (`view-v1`) must remain strictly backward-compatible.
2. **No Premature Cloud Migration**: Terraform will remain on standard Google Cloud Provider modules; no external orchestration framework (e.g., Terragrunt or Pulumi) will be introduced.
3. **No Framework Switching**: The hub remains Go `net/http` (no Fiber, Gin, or external router framework); the WUI remains Nuxt 3 / Vue 3 / Pinia.

---

## 3. Refactoring Target Architecture

```
+-----------------------------------------------------------------------------+
|                             csi-spl REFACTOR TARGET                         |
+-----------------------------------------------------------------------------+
|  csi-spl-api (Go)          csi-spl-wui (Nuxt 3)       csi-spl-iac & cnf     |
|  +---------------------+   +---------------------+   +--------------------+ |
|  | CLI / Subcommands   |   | 3-Pane Shell Layout |   | Schema-Validated   | |
|  | (Modular CLI Engine)|   | - Left: Roster/Lobby|   | Configs (YAML)     | |
|  |                     |   | - Mid: Reverse Feed |   |                    | |
|  | Domain Entities     |   |   + Top Omnibox     |   | Standardized TF    | |
|  | - Message / Thread  |   | - Right: ThreadPane |   | Step Composition   | |
|  | - Channel / Roster  |   |                     |   |                    | |
|  |                     |   | Client Adapters     |   | Zero-Trust Secret  | |
|  | Transports          |   | - LiveSpoolClient   |   | Lifecycle          | |
|  | - WS Engine / REST  |   | - MockSpoolClient   |   +--------------------+ |
|  | - MCP Stdio Server  |   |                     |   csi-spl-orc          |
|  |                     |   | Unified Stores      |   +--------------------+ |
|  | Repositories        |   | - workspace / feed  |   | Namespaced Bash    | |
|  | - Postgres / Memory |   | - thread / session  |   | Modular Runners    | |
|  +---------------------+   +---------------------+   +--------------------+ |
+-----------------------------------------------------------------------------+
```

### 3.1 Domain 1: `csi-spl-api` (Go Clean Architecture)
- **`cmd/spool` Modularization**: Replace string-switch dispatching in `main.go` with dedicated command handlers in `cmd/spool/commands/` (`serve.go`, `send.go`, `recv.go`, `tail.go`, `sync.go`, `flush.go`, `pin.go`, `mcp.go`, `migrate.go`).
- **Core Domain Separation (`internal/domain`)**:
  - `domain/message`: Unified definition of `Message`, `Kind`, `Validation`, and `Attachment`.
  - `domain/envelope`: Wire envelope, cryptographic signature metadata, box provenance.
  - `domain/tenant`: Tenant identity, membership rules, quota limits, channel permissions.
- **Service/Use-Case Layer (`internal/service`)**:
  - Encapsulate business logic independent of transport: `MessageDispatcher`, `ThreadAggregator`, `PinManager`, `AuthSessionService`.
- **Decoupled Transports (`internal/transport`)**:
  - `transport/ws`: Connection lifecycle, heartbeat, frame encoder/decoder, subscription registry.
  - `transport/http`: REST view routes, health endpoints, blob streaming, CORS middleware.
  - `transport/mcp`: Stdio protocol adapter translating MCP tool calls to service invocations.
- **Modular Test Suites**: Break `internal/hub/hub_test.go` into targeted test suites: `ws_auth_test.go`, `ws_dispatch_test.go`, `view_api_test.go`, `quota_test.go`.

### 3.2 Domain 2: `csi-spl-wui` (Frontend Architecture)
- **3-Pane Master Layout (`components/layout/`)**:
  - Standardize master layout container in `layouts/default.vue` and `components/SpoolShell.vue`.
  - Grid geometry: `260px` (Left Pane) | `minmax(400px, 1fr)` (Middle Pane) | `380px` (Collapsible Right Pane).
  - Enforce zero horizontal scroll guard across all viewports (`tests/e2e/no-x-scroll.test.mjs`).
- **Top Omnibox & Reverse Prepend Stream**:
  - Convert `MessageFeed.vue` to native reverse flow: newest items prepended at the top; scrolling down fetches older history via cursor.
  - Pin `TopOmnibox.vue` permanently at the top of the middle pane.
  - Default typing posts message on `Enter` (`to: "@channel"`, or `@agent` for tasks); typing `/search <query>` activates search filter mode; `Esc` clears.
- **Client Adapter Architecture (`utils/client/`)**:
  - Define `SpoolClient` interface (`listChannels`, `listMessages`, `getThread`, `sendMessage`, `roster`, `session`).
  - Implement `HttpSpoolClient` (calls `/v1/view/*` and `/v1/ws`) and `MockSpoolClient` (operates on immutable fixtures).
  - Eliminate all `if (this.mock)` branches from application logic.
- **Consolidated Pinia Store Hierarchy**:
  - `workspace`: Selected channel/DM, UI layout mode, active thread ID.
  - `feed`: Reverse-ordered message list for active channel/DM, cursors, loading state.
  - `thread`: Focused thread replies, verbosity filter (`minimal`, `normal`, `verbose`).
  - `roster`: Online status, agent robot avatars, user directory.
  - `session`: Authentication state, signed cookie probe, CSRF tokens.

### 3.3 Domain 3: `csi-spl-iac` & `csi-spl-cnf` (Infrastructure & Configs)
- **Config Schema Validation**: Add a JSON Schema validator for `csi-spl-cnf/csi-spl/*.env.yaml` executed before any `./run` or `tpl-gen` invocation.
- **Terraform Module Normalization**: Standardize provider declarations, variable types, and output exports across all 10 step directories.
- **Secret & DNS Hardening**: Complete step `017-github-wif-deploy` configuration; document and automate Cloud Armor allowlist transition from M1 allow-all to M2 tenant-gated ingress.

### 3.4 Domain 4: `csi-spl-orc` (Local Dev & Agent Automation)
- **Library Namespacing**: Refactor `csi-spl-orc/lib/bash/funcs` into namespaced files: `spl_cfg.func.sh`, `spl_gcp.func.sh`, `spl_gandi.func.sh`, `spl_test.func.sh`.
- **Robust Agent Spawners**: Add mailbox initialization, permission checks, and graceful teardown traps in `spawn-agents/scripts/`.

### 3.5 Domain 5: `csi-spl-doc` (Documentation & Git-Specs)
- **Cross-Spec Consistency Scrub**: Update all references in `csi-spl-doc/doc/md/` and `specs/001-010/` to ensure `#lobby` is consistently documented as the universal public room.
- **Retire Historical Stubs**: Mark obsolete draft files in `csi-spl-doc/doc/md/draft/` with formal deprecation notices pointing to binding M3 specs.

---

## 4. Functional Requirements

- **FR-R01** — API: Modular CLI Command Architecture.
  `cmd/spool` MUST dispatch subcommands via structured command definitions with standard flag parsing, shared context propagation, and structured exit-code mapping.
- **FR-R02** — API: Decoupled Domain & Wire Types.
  Internal domain message representation MUST be decoupled from `wire.Envelope` wire models and SQL persistence structs through explicit mapper functions.
- **FR-R03** — API: Test Suite Decomposition.
  Monolithic test files in `internal/hub` and `internal/store` exceeding 500 lines MUST be split into single-concern test files without reducing coverage.
- **FR-R04** — WUI: Complete 3-Pane Slack-like Layout.
  The WUI MUST implement the canonical 3-pane layout: Left (People & Channels directory with `#lobby`), Middle (Reverse Prepend Message Feed with Top Omnibox), Right (Collapsible Thread View).
- **FR-R05** — WUI: Top Omnibox Dual-Mode Input.
  The top Omnibox MUST act as the primary message composer on plain `Enter`, format `@mention` prompts as `kind=task`, and trigger search filtering only upon `/search <query>`.
- **FR-R06** — WUI: Reverse Prepend Stream.
  The middle feed and thread replies MUST prepend new incoming messages to the top; downward scrolling MUST retrieve older chronological history.
- **FR-R07** — WUI: Client Adapter Pattern.
  All client interactions MUST execute against a unified client interface with distinct `LiveSpoolClient` and `MockSpoolClient` implementations, eliminating inline `if (mock)` logic.
- **FR-R08** — WUI: Streamlined Store Hierarchy.
  State management MUST be consolidated into 5 domain stores (`workspace`, `feed`, `thread`, `roster`, `session`) with zero redundant caching.
- **FR-R09** — WUI: Avatar & Presence Integration.
  Avatars MUST follow `SPEC-spool-avatars.md` (initials/identicon for humans; deterministic robot avatars tinted by family for bots) with live presence indicators.
- **FR-R10** — IAC: Automated Config Schema Validation.
  `csi-spl-cnf` MUST provide a validation script enforcing schema compliance for all YAML environment configurations prior to template generation.
- **FR-R11** — IAC: Standardized Terraform Step Interfaces.
  Each Terraform step MUST expose standard outputs and accept standardized variables documented in a central interface matrix.
- **FR-R12** — ORC: Bash Function Namespacing.
  Local dev orchestration functions in `csi-spl-orc` MUST follow standard prefixes and fail-fast parameter validation.
- **FR-R13** — DOC: Spec Alignment & Terminology Scrub.
  All specifications and architectural narratives MUST strictly reflect `#lobby` universal access, dropped REST message endpoints, and the M1-M4 milestone roadmap.
- **FR-R14** — DOC: Refactoring Indexing in Specs README.
  `specs/README.md` MUST index `011-spool-project-refactor` with clear ownership, scope, and cross-spec seams.
- **FR-R15** — Cross-Cutting: 100% Behavioral Regression Invariant.
  Every phase of the refactoring MUST maintain full pass status across all unit tests, end-to-end tests, Postgres gates, and fake-GCS emulator gates.

---

## 5. Non-Functional & Safety Requirements

- **NFR-01: Zero Regression**: No existing CLI command, MCP tool, WebSocket frame, or HTTP route may alter its wire format, error envelope, or status code during refactoring.
- **NFR-02: Strict Distribution Hygiene**: No personal identifiers, developer usernames, owner emails, or absolute home directory paths may be introduced into code or docs (`10_ci-quality.yml` sweep compliance).
- **NFR-03: Performance & Memory**: Go memory allocation profiles and WUI bundle sizes must not degrade; Nuxt production build must maintain zero horizontal document scroll at 390px and 1280px viewports.
- **NFR-04: Fail-Fast Configuration**: Any missing required environment variable or placeholder in production configuration must continue to fail the hub boot immediately.

---

## 6. Success Criteria

- **SC-R01**: `csi-spl-api` test suite completes with 100% green pass in under 15 seconds, with all monolithic test files successfully decomposed into modular test units.
- **SC-R02**: `csi-spl-wui` renders the 3-pane reverse prepend layout with Top Omnibox in both live and mock modes, passing all 45+ unit tests and e2e viewport tests.
- **SC-R03**: Polymorphic client architecture in WUI replaces all inline `if (this.mock)` checks with zero test regressions.
- **SC-R04**: Config validation script in `csi-spl-cnf` validates dev, prd, and lde environments against an explicit schema with exit code 0.
- **SC-R05**: `csi-spl-orc` agent spawn suite passes clean dry-run and live validation tests.
- **SC-R06**: `csi-spl-doc/specs/` and `doc/md/` pass consistency audits with 0 broken internal links and 100% terminology reconciliation.

---

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:31:00Z -->
