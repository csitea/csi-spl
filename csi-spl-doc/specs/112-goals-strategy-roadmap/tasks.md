# 112 Goals, strategy and roadmap: tasks

Authority for what is built. `spec.md` holds the behaviour; this file follows its sections.
Each task names its layer, its dependency, the files it owns, and a Done line.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

Version **v0.1**.

## 1. Documentation and Storage
- [ ] **DOC**: Create `csi-spl-doc/goals/` directory structure and `strategy.md` template.
  - Owns: `csi-spl-doc/goals/README.md`, `csi-spl-doc/goals/template-strategy.md`
  - Done: Template merged on master, passes distribution hygiene.

## 2. API & Data Model
- [ ] **API**: Add goal tracking parser to repository deploy pipeline.
  - Depends on: DOC
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/goals/`
  - Done: API parses `csi-spl-doc/goals/*` and calculates progress based on linked specs during deployment.
- [ ] **API**: Expose roadmap view and goal list to WUI.
  - Depends on: API (parser)
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/roadmap/`
  - Done: Endpoint returns 88+ specs and their goal associations.
- [ ] **API**: Calendar integration for goal deadlines and milestones.
  - Depends on: API (parser)
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/calendar/goal_events.go`
  - Done: Goal deadlines appear in calendar events.

## 3. Agents & Automation
- [ ] **ORC**: Retrospective trigger and draft generation.
  - Depends on: API (calendar)
  - Owns: `csi-spl-orc/src/bash/features/goals-retrospective/`
  - Done: Calendar triggers a mistral lane on deadline pass, agy reviews language, message posted to owner.

## 4. UI / WUI
- [ ] **WUI**: Roadmap and Goal View components.
  - Depends on: API (endpoints)
  - Owns: `csi-spl-wui/src/routes/roadmap/`, `csi-spl-wui/src/routes/goals/`
  - Done: UI shows rows of specs with percentage ticked, dark/light theme supported, initial chunk budget preserved.

