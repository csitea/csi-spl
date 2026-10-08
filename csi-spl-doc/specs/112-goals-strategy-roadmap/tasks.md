# 112 Goals, strategy and roadmap: tasks

Authority for what is built. `spec.md` holds the behaviour; this file follows its sections.
Each task names its layer, its dependency, the files it owns, and a Done line.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

Version **v0.2**.

## 1. Documentation & Storage
- [ ] **DOC**: Strategy-doc template.
  - Owns: `csi-spl-doc/goals/template-strategy.md`
  - Done: Template is merged on master, passes distribution hygiene, and supports mistral authoring and agy review guidelines.
  - Test: Validation of frontmatter schema and distribution hygiene gate passes.

## 2. API & Data Model
- [ ] **API**: Data model and hub API for Goals.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/goals/`
  - Done: Database schema supports goal tracking, API exposes list of goals and specs parsed from repository.
  - Test: Integration test `TestGoalsAPIList` returns seeded goals from repository fixture.
- [ ] **API**: Calendar link & two-way interlinking.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/calendar/roadmap_sync.go`
  - Done: Repository definition (source of truth) syncs deadlines/milestones to calendar DB, embedding roadmap permalinks.
  - Test: `TestCalendarSyncFromRoadmap` verifies created events have correct roadmap `LinkedEntityId`.

## 3. UI / WUI
- [ ] **WUI**: WUI roadmap page and filter.
  - Owns: `csi-spl-wui/src/routes/roadmap/`
  - Done: UI shows rows of specs with percentage ticked, implements "this week / this month" filter, links to calendar events.
  - Test: Playwright e2e test verifies filter toggle updates displayed roadmap items.

## 4. Backfill Operations (Actions)
- [ ] **ORC**: Git backfill action.
  - Owns: `csi-spl-orc/src/bash/features/goals-backfill/git-backfill.sh`
  - Done: Reads v* tags, release notes, and specs, filtering by "major" rule starting from 2026-09-17, inserting past events into calendar DB.
  - Test: Action executes on test repository fixture and produces expected set of major calendar events.
- [ ] **ORC**: DB backfill action (Discussions).
  - Owns: `csi-spl-orc/src/bash/features/goals-backfill/db-backfill.sh`
  - Done: Extracts owner decisions under RLS, generates candidate list for agent wording, inserts into calendar upon owner prune.
  - Test: `bash csi-spl-orc/src/bash/tests/goals-backfill-db.tst.sh` verifies output respects RLS and workspace isolation.

## 5. Agents & Automation
- [ ] **ORC**: Retrospective cron.
  - Owns: `csi-spl-orc/src/bash/features/goals-retrospective/retrospective-cron.sh`
  - Done: Cron detects passed deadlines, triggers mistral to draft reflection doc, and agy to review language.
  - Test: Mock calendar deadline triggers spool task creation for mistral agent lane.
