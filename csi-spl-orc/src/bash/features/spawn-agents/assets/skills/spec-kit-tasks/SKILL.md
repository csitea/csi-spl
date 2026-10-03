---
name: spec-kit-tasks
description: >-
  Generate a concrete, dependency-ordered tasks.md for a Spec-Kit feature from
  its existing design docs (spec.md, plan.md, data-model.md, contracts/,
  research.md, quickstart.md). Use when the user wants to turn spec-kit
  specs/plans into actionable implementation tasks, run "/spec-kit-tasks", or
  asks to create tasks for a concrete implementation. Works from any project
  that has a Spec-Kit `specs/<NNN>-<slug>/` directory — it does not require the
  project-scoped speckit-tasks command to be loaded.
argument-hint: "[feature dir or slug, e.g. specs/001-render-and-publish] [constraints]"
user-invocable: true
disable-model-invocation: false
---

# /spec-kit-tasks — generate a dependency-ordered tasks.md from a Spec-Kit feature's design docs

Produce `tasks.md` for a Spec-Kit feature by reading whatever design artifacts
already exist and decomposing them into concrete, independently-testable,
dependency-ordered implementation tasks.

## User input

```text
$ARGUMENTS
```

Treat `$ARGUMENTS` as an optional feature selector (a `specs/<NNN>-<slug>` path
or bare slug/number) and/or extra constraints (e.g. "include tests",
"backend only"). Consider it before proceeding.

## 1. Locate the feature directory

1. If `$ARGUMENTS` names a feature dir or slug, resolve it under `specs/`.
2. Else, if a Spec-Kit helper exists, prefer it:
   `.specify/scripts/bash/setup-tasks.sh --json` (parse `FEATURE_DIR` /
   `TASKS`). It also copies the tasks template into place.
3. Else, pick the active feature: the `specs/<NNN>-<slug>/` directory matching
   the current git branch, or — if unambiguous — the only/highest-numbered one.
4. `FEATURE_DIR` must contain `spec.md`. `plan.md` is optional: without it,
   take the structure and the paths from `spec.md`'s Requirements and
   Acceptance sections (the shape of `.specify/templates/spec-template.md`)
   and the repo tree, and say in the report that there was no plan.
5. A repo that ran the spec toolkit's installer and carries its own
   `speckit-tasks` skill uses that one; this skill is for repos without it.

Set `TASKS_FILE = FEATURE_DIR/tasks.md`.

## 2. Load all available design context

Read every artifact that exists (absence is fine — adapt, don't fail):

- `spec.md` — **required**: user stories + priorities (P1/P2/P3), functional
  requirements (FR-###), success criteria (SC-###), edge cases, entities.
- `plan.md` — optional: tech stack, real source-tree paths, structure
  decision, constitution gates. Without it, paths come from `spec.md` and the
  repo tree.
- `data-model.md` — entities → model/creation tasks.
- `contracts/` — each contract/interface → one implementation task (+ a test
  task if tests are requested).
- `research.md` — decisions that pin libraries/versions/setup tasks.
- `quickstart.md` — end-to-end steps → integration/validation tasks.
- `.specify/templates/tasks-template.md` — follow its format if present.

Also read `.specify/memory/constitution.md` when present and respect its gates
(e.g. env-driven/fail-fast, deterministic output, no secrets) as task
acceptance criteria.

## 3. Decompose into tasks

Group tasks into phases so that **each user story is an independently testable,
shippable slice** (P1 alone = MVP):

1. **Phase 1 — Setup**: project/toolchain prep shared by all stories
   (dependencies, pinned versions, lint/format, fixtures/scaffolding).
2. **Phase 2 — Foundational (blocking)**: prerequisites every story needs
   (shared config/env resolution, base entities, error/logging scaffolding,
   framework wiring). Keep this minimal — only true cross-story prerequisites.
3. **Phase 3..N — one phase per User Story**, in priority order (P1 first,
   marked 🎯 MVP). Within each story: optional tests first (only if the user
   asked for tests), then implementation tasks derived from its acceptance
   scenarios, the FRs it satisfies, the entities it touches, and the contracts
   it realizes.
4. **Final Phase — Polish / cross-cutting**: docs, end-to-end validation
   against `quickstart.md`, success-criteria verification, cleanup.

## 4. Task format

One checklist line per task using `[ID] [P?] [Story] Description (file path)`:

```text
- [ ] T001 [P] [US1] <imperative description> in <concrete/repo/relative/path>
```

Rules:
- **IDs**: `T001`, `T002`, … sequential across the whole file.
- **`[P]`**: include only when the task touches different files **and** has no
  unmet dependency — i.e. it can run in parallel. Omit for serialized work.
- **`[US#]`**: tag every story-phase task with its user story; Setup/Foundational/
  Polish tasks have no story tag.
- **Concrete paths**: use the real directories from `plan.md`'s structure
  decision (or the repo tree when there is no plan) — never placeholders. Every task names the file(s) it creates/edits.
- **Dependencies**: when a task depends on others, say so (`(depends on T0xx)`).
- Make each task small enough to complete and verify on its own.

## 5. Assemble `tasks.md`

Start from `tasks-template.md` if present; otherwise emit this structure:

```markdown
# Tasks: <Feature Name>

**Feature**: <FEATURE_DIR>  |  **Spec**: ./spec.md  |  **Plan**: ./plan.md

## Format: `[ID] [P?] [Story] Description`
- [P] = parallelizable (different files, no unmet deps)
- [US#] = the user story a task serves

## Phase 1: Setup
...
## Phase 2: Foundational (blocking)
...
## Phase 3: User Story 1 — <title> (P1) 🎯 MVP
...
## Phase N: Polish & cross-cutting
...

## Dependencies & parallelism notes
<short prose: which phases gate which; which [P] groups can run together>

## Implementation strategy
<MVP = finish Phase 3; then layer P2, P3>
```

Add a final mapping note tying tasks back to FR-### / SC-### / contracts so
coverage is auditable. Append a `last-edit:` marker only if the repo's
conventions (e.g. CLAUDE.md) require it for merges.

## 6. Write, report, and offer next step

- Write `TASKS_FILE`.
- Report: feature dir, task count, phase/story breakdown, and any FR/contract
  left uncovered (flag gaps explicitly rather than silently dropping them).
- Offer the next Spec-Kit step (`/speckit-implement` or `/speckit-analyze`).
- Do **not** start implementing unless the user asks — this skill produces the
  task plan only.
