# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]

**Input**: Feature specification from `/specs/[###-feature-name]/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

[Extract from feature spec: primary requirement + technical approach from research]

## Technical Context

<!--
  ACTION REQUIRED: Replace the content in this section with the technical details
  for the project. The structure here is presented in advisory capacity to guide
  the iteration process.
-->

**Language/Version**: [e.g., Python 3.11, Swift 5.9, Rust 1.75 or NEEDS CLARIFICATION]

**Primary Dependencies**: [e.g., FastAPI, UIKit, LLVM or NEEDS CLARIFICATION]

**Storage**: [if applicable, e.g., PostgreSQL, CoreData, files or N/A]

**Testing**: [e.g., pytest, XCTest, cargo test or NEEDS CLARIFICATION]

**Target Platform**: [e.g., Linux server, iOS 15+, WASM or NEEDS CLARIFICATION]

**Project Type**: [e.g., library/cli/web-service/mobile-app/compiler/desktop-app or NEEDS CLARIFICATION]

**Performance Goals**: [domain-specific, e.g., 1000 req/s, 10k lines/sec, 60 fps or NEEDS CLARIFICATION]

**Constraints**: [domain-specific, e.g., <200ms p95, <100MB memory, offline-capable or NEEDS CLARIFICATION]

**Scale/Scope**: [domain-specific, e.g., 10k users, 1M LOC, 50 screens or NEEDS CLARIFICATION]

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- [ ] **2.1–2.2 Core principles & clean code limits** — truth first, stay in lane, dev equals or leads prd; functions <= 75 lines, depth <= 4, params <= 7 (Go) / 5 (TS/Vue), no `SELECT *`, folded helpers used once
- [ ] **2.3.1 Canonical path layout** — no hard-coded `BASE_PATH` / `ORG` / `APP` or box paths; derive from the tree
- [ ] **2.3.2 Fail fast, no default host** — every external URL/host/bucket/account is read from an env var or cnf (`BASE_DOMAIN`); missing required vars fail fast
- [ ] **2.3.3 Cnf single source of truth** — no hardcoded runtime values in source. New settings
      live in `csi-spl-cnf/csi-spl/<env>.env.yaml` (and `all.env.yaml`), with generated twins
      re-rendered via `do_tpl_gen` in the same commit. Tests may use example hosts; runtime MUST NOT
      invent a hostname, cookie domain, origin, or flag from another URL.
- [ ] **2.4 Shell scripting & run actions** — named `do_<verb>_<noun>` actions with `@description`, `@param`, `@example` tags and their test in the same commit
- [ ] **2.5 Public distribution hygiene** — org-neutral (`csi` / `csitea` / `csitea.net` only); no personal names, literal OS users, box names, or `/home/<user>` paths (git commit authorship metadata is the carve-out, 2.5.3)
- [ ] **2.6 Security, secrets & cloud access** — per-env SA keys outside git, no secrets in code/state/logs, pinned `gcloud` calls, RLS on every tenant table, Terraform in `tf-runner` with owner go
- [ ] **2.7–2.12 UI/i18n, lint & migrations, trunk workflow, issue/spec delivery, uniform agent messaging, testing standards** — translation keys only, forward-only PG16 migrations, small rebased commits citing issue key, red controls and real PostgreSQL for store tests

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)
<!--
  ACTION REQUIRED: Replace the placeholder tree below with the concrete layout
  for this feature. Delete unused options and expand the chosen structure with
  real paths (e.g., apps/admin, packages/something). The delivered plan must
  not include Option labels.
-->

```text
# [REMOVE IF UNUSED] Option 1: Single project (DEFAULT)
src/
├── models/
├── services/
├── cli/
└── lib/

tests/
├── contract/
├── integration/
└── unit/

# [REMOVE IF UNUSED] Option 2: Web application (when "frontend" + "backend" detected)
backend/
├── src/
│   ├── models/
│   ├── services/
│   └── api/
└── tests/

frontend/
├── src/
│   ├── components/
│   ├── pages/
│   └── services/
└── tests/

# [REMOVE IF UNUSED] Option 3: Mobile + API (when "iOS/Android" detected)
api/
└── [same as backend above]

ios/ or android/
└── [platform-specific structure: feature modules, UI flows, platform tests]
```

**Structure Decision**: [Document the selected structure and reference the real
directories captured above]

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
