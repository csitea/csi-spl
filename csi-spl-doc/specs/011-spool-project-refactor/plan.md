# Refactoring Plan: Spool Whole-Project Refactoring (011)

**Feature**: `specs/011-spool-project-refactor` · **Milestone**: M1–M3 Consolidation · **Created**: 2026-09-18
**Narrative (binding)**: `../../doc/md/SPEC-spool-project-refactor.md`

---

## 1. Executive Summary & Strategy

The whole-project refactoring establishes clean architectural boundaries across `csi-spl` without altering any public contract, wire format, or operational invariant. The execution strategy follows an **outside-in, layer-isolated sequence** with mandatory verification gates between phases.

```
Phase 1: WUI Client Adapter & Store Unification
   ↓
Phase 2: WUI 3-Pane Reverse Prepend & Omnibox Layout
   ↓
Phase 3: Go Backend Domain Decoupling & Test Decomposition
   ↓
Phase 4: Config Schema Validation & Orchestration Namespacing
   ↓
Phase 5: Cross-Spec Reconciliation & Verification Gates
```

---

## 2. Technical Blueprint by Domain

### 2.1 Domain 1: `csi-spl-api` (Go Clean Architecture)
- **Current State**: `cmd/spool` uses manual string branching for 14 subcommands. `internal/hub` blends connection routing, tenant validation, and message broadcasting. Monolithic tests (`hub_test.go`, 1474 lines).
- **Refactored Topology**:
  - `cmd/spool/commands/`: Dedicated subcommand packages implementing a standard `Command` interface (`Execute(ctx context.Context, args []string) error`).
  - `internal/domain/`: Pure Go types for Message, Thread, Channel, Tenant, Envelope without external serialization tags or DB concerns.
  - `internal/transport/`: Clear protocol adapters for WebSocket (`ws/`), REST (`http/`), and MCP (`mcp/`).
  - `internal/store/`: Database access objects with clean domain mapper interfaces.
  - Decomposed tests: Split `hub_test.go` into `hub_auth_test.go`, `hub_ws_test.go`, `hub_view_test.go`, `hub_limits_test.go`.

### 2.2 Domain 2: `csi-spl-wui` (3-Pane Reverse Layout & Adapter Pattern)
- **Current State**: Read-only viewer (`/t/[task_id]`) and legacy mock channel (`/channel/[name]`) operate with mismatched layout philosophies. `spool-client.mjs` branches on `if (this.mock)`. 6 distinct Pinia stores with duplicate data.
- **Refactored Topology**:
  - `utils/client/`:
    - `SpoolClient`: Abstract interface definition.
    - `HttpSpoolClient`: Live implementation talking to `/v1/view/*` and `/v1/ws`.
    - `MockSpoolClient`: Isolated test/mock implementation managing in-memory fixtures.
  - `stores/`:
    - `workspace.ts`: Manages active context (channel vs DM), layout geometry, active thread drawer.
    - `feed.ts`: Manages reverse-ordered stream (newest prepended), pagination cursors, Omnibox input.
    - `thread.ts`: Manages Pane 3 thread replies, verbosity filter (`minimal`, `normal`, `verbose`).
    - `roster.ts`: Manages online status, agent robot avatars, tenant directory.
    - `session.ts`: Manages signed session cookie, CSRF state, authentication routes.
  - `components/`:
    - `SpoolShell.vue`: 3-pane master layout container (Left 260px, Middle flex, Right 380px collapsible).
    - `TopOmnibox.vue`: Pinned top composer, type-and-enter ambient messaging, `@mention` commands, `/search` query trigger.
    - `MessageFeed.vue`: Reverse prepend stream with scroll-down history paging.
    - `ThreadPane.vue`: Side-panel thread drill-down with pinned root prompt and prepended replies.

### 2.3 Domain 3: `csi-spl-iac` & `csi-spl-cnf` (Config Hardening)
- **Current State**: YAML configs lack automated schema checking before `tpl-gen` execution.
- **Refactored Topology**:
  - `csi-spl-cnf/schema/`: Formal JSON/YAML schema definitions for `all.env.yaml`, `dev.env.yaml`, `prd.env.yaml`.
  - `csi-spl-cnf/src/bash/validate-config.sh`: Fast pre-commit / pre-render validator catching missing keys and invalid types.
  - Standardized outputs across all 10 Terraform step directories.

### 2.4 Domain 4: `csi-spl-orc` (Orchestration Namespacing)
- **Current State**: Bash library functions in `lib/bash/funcs` have inconsistent names and global variable handling.
- **Refactored Topology**:
  - Prefix-namespaced function libraries: `spl_cfg_*`, `spl_gcp_*`, `spl_gandi_*`, `spl_test_*`.
  - Strict parameter validation with `require_var` and `require_bin` guards.
  - Spawner pre-flight verification: `spawn-core.inc.sh` verifies local mailbox paths, permissions, and daemon connectivity before launching agents.

### 2.5 Domain 5: `csi-spl-doc` (Spec Harmonization)
- **Current State**: Multiple specs developed in parallel retain minor terminology drift (e.g., `#general` vs `#lobby`, historical Gandi records, dropped REST endpoints).
- **Refactored Topology**:
  - Single architectural authority registered in `specs/README.md`.
  - All specs citing `#lobby` as the universal public room.
  - Formal deprecation headers on legacy draft markdown files.

---

## 3. Phased Implementation Roadmap

### Phase 1: WUI Client Adapter & Store Unification
1. Create `utils/client/interface.mjs` defining the unified `SpoolClient` contract.
2. Implement `HttpSpoolClient` and `MockSpoolClient`, removing all inline `if (this.mock)` branches from `spool-client.mjs`.
3. Consolidate Pinia stores into the 5 target stores (`workspace`, `feed`, `thread`, `roster`, `session`).
4. Validate all 45 existing unit tests continue to pass without modification.

### Phase 2: WUI 3-Pane Reverse Prepend & Omnibox Layout
1. Implement `TopOmnibox.vue` supporting default typing on `Enter`, `@mention` task routing, and `/search` mode.
2. Refactor `MessageFeed.vue` to reverse prepend order with entrance transitions and downward scroll pagination.
3. Build `ThreadPane.vue` as a collapsible 380px drawer bound to `parent_task_id`.
4. Compose the 3 panes in `SpoolShell.vue` and `layouts/default.vue`.
5. Run `no-x-scroll.test.mjs` to ensure zero horizontal scroll across mobile and desktop viewports.

### Phase 3: Go Backend Domain Decoupling & Test Decomposition
1. Refactor `cmd/spool` to dispatch commands via modular command handlers in `cmd/spool/commands/`.
2. Cleanly isolate `internal/domain` message entities from `internal/wire` transport models.
3. Decompose `internal/hub/hub_test.go` into single-concern test files (`hub_auth_test.go`, `hub_ws_test.go`, `hub_view_test.go`).
4. Verify backend test suite (`run-all-tests.sh`, smoke, Postgres gate, fake-GCS gate) passes 100% green.

### Phase 4: Config Schema Validation & Orchestration Namespacing
1. Create config validation schema in `csi-spl-cnf/schema/` and validation script.
2. Namespace bash functions in `csi-spl-orc/lib/bash/funcs/` with standard error checking.
3. Update agent spawner scripts with pre-flight mailbox verification.

### Phase 5: Cross-Spec Reconciliation & Verification Gates
1. Update `csi-spl-doc/specs/README.md` to index `011-spool-project-refactor`.
2. Audit all specs for terminology consistency (`#lobby`, `view-v1`, signed challenge-response).
3. Execute end-to-end multi-agent integration verification.

---

## 4. Verification & Rollback Guarantees

- **Continuous Verification**: Each phase must land in master as a self-contained, green commit verified by:
  - `node --test csi-spl-wui/tests/unit/*.test.mjs` (45/45 pass)
  - `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (100% pass across all gates)
  - `csi-spl-wui/tests/e2e/no-x-scroll.test.mjs` (8/8 pass)
- **Rollback Guarantee**: If any phase introduces behavioral regressions or breaks existing wire contracts, the phase can be cleanly reverted using atomic git commits without impacting other subsystems.

---

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:32:00Z -->
