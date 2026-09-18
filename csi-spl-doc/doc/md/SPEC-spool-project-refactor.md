# Spool Whole-Project Refactoring Architecture

**Doc ID**: `SPEC-spool-project-refactor` · **Milestone**: M1–M3 Consolidation · **Status**: Binding Architecture
**Implementation Spec**: `../../specs/011-spool-project-refactor/spec.md` · **Created**: 2026-09-18

---

## 1. Context & Motivation

Spool (`csi-spl`) has successfully demonstrated its technical prototype (M1) and built foundational multi-tenant infrastructure (M2 rental/payments, M3 Slack-like real-time WUI). Through rapid development across ~30 parallel agent lanes, all core verification gates (unit tests, end-to-end browser tests, Postgres store gates, GCS emulator gates) are fully green.

However, rapid feature accretion resulted in structural coupling, duplicated representations, and hybrid frontend paradigms. This document establishes the binding architectural blueprint for a whole-project refactoring that hardens modular boundaries, establishes a clean polymorphic client layer in the frontend, standardizes the Go backend onto clean domain architecture, and cleanses documentation of legacy drift.

---

## 2. Core Refactoring Pillars

### 2.1 Pillar 1: Backend Domain Clean Architecture (`csi-spl-api`)
1. **Modular Subcommand Architecture**: Replace the manual argument switch in `cmd/spool/main.go` and `cmd/spool/hub.go` with structured command packages (`cmd/spool/commands/`).
2. **Domain Model Purity**: Isolate internal business entities (`internal/domain`) from wire transport protocols (`internal/wire`) and database persistence models (`internal/store`).
3. **Transport Separation**: Maintain clear boundaries between WebSocket sessions (`transport/ws`), REST endpoints (`transport/http`), and Model Context Protocol stdio tools (`transport/mcp`).
4. **Test Suite Decomposition**: Split oversized test files (such as the 1474-line `hub_test.go`) into focused, single-concern unit and integration suites.

### 2.2 Pillar 2: Slack-Like 3-Pane Reverse Prepend UI (`csi-spl-wui`)
1. **Canonical 3-Pane Geometry**:
   - **Left Pane (260px fixed)**: People & Channels directory. Hosts `#lobby` as the universal public common room (Slack's `#general` equivalent), user presence, and deterministic robot avatars for AI agents.
   - **Middle Pane (flex: 1, min 400px)**: Primary conversation stream featuring the pinned **Top Omnibox** and the **Reverse Prepend Stream** (newest messages at the top, scrolling down fetches older history).
   - **Right Pane (380px collapsible)**: Deep-dive thread view displaying pinned root prompt, prepended execution notes, verbosity selector (`minimal`, `normal`, `verbose`), and thread composer.
2. **Top Omnibox Dual Mode**:
   - Default typing and hitting `Enter` sends an ambient message or agent command (`@agent <task>`).
   - Typing `/search <query>` activates stream filtering mode. `Esc` restores live stream.
3. **Polymorphic Client Adapter**:
   - Replace all `if (this.mock)` branches with an explicit `SpoolClient` interface implemented by `HttpSpoolClient` and `MockSpoolClient`.
4. **Unified Pinia Stores**:
   - Consolidate 6 fragmented stores into 5 distinct domain stores: `workspace`, `feed`, `thread`, `roster`, `session`.

### 2.3 Pillar 3: Infrastructure & Configuration Hardening (`csi-spl-iac` & `csi-spl-cnf`)
1. **Automated Schema Validation**: Enforce JSON/YAML schema validation on all `csi-spl-cnf/csi-spl/*.env.yaml` configs before any `./run` or `tpl-gen` invocation.
2. **Terraform Step Interface Normalization**: Standardize variable contracts and output bindings across all 10 GCP Terraform step directories.
3. **Zero-Trust Secrets Lifecycle**: Automate secret version rotation and integrate Workload Identity Federation (WIF) deploy identities.

### 2.4 Pillar 4: Local Dev Orchestration & Spawner Rigor (`csi-spl-orc`)
1. **Namespaced Bash Libraries**: Reorganize helper functions into modular namespaces (`spl_cfg_*`, `spl_gcp_*`, `spl_test_*`).
2. **Pre-Flight Mailbox Checks**: Add automated environment verification to agent spawner scripts (`spawn-claude.sh`, `spawn-agy.sh`, `spawn-grok.sh`) ensuring spool directories, socket permissions, and box credentials exist before launch.

### 2.5 Pillar 5: Documentation & Specification Alignment (`csi-spl-doc`)
1. **Universal `#lobby` Access**: Ensure all specifications, tasks, contracts, and design docs reflect `#lobby` as the universal common room.
2. **Historical Terminology Scrub**: Clarify or retire references to pre-delegation Gandi records, deprecated REST message routes, and early M1 draft proposals.
3. **Central Git-Spec Authority**: Maintain `specs/README.md` as the definitive status and seam registry.

---

## 3. Invariants & Guarantees

1. **Wire Compatibility**: The `v:1` message schema, WebSocket challenge-response protocol, and `view-v1` REST contracts remain completely unchanged.
2. **Zero Regression**: Every refactoring phase must maintain 100% pass status across:
   - `node --test csi-spl-wui/tests/unit/*.test.mjs`
   - `node csi-spl-wui/tests/e2e/no-x-scroll.test.mjs`
   - `bash csi-spl-api/src/bash/tests/run-all-tests.sh`
3. **Distribution Hygiene**: Strict compliance with CI quality sweeps; no personal credentials, developer names, or home paths.

---

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:34:00Z -->
