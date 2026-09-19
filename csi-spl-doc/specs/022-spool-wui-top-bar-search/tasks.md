# Tasks: Spool WUI top bar + global search (022)

**Feature**: `specs/022-spool-wui-top-bar-search` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — Spec + pure helpers

- [x] T001 Spec (`spec.md`).
- [ ] T002 `utils/search.mjs` (mode, URL, operators, highlights, groups, keyboard) + `tests/unit/search.test.mjs`.
- [ ] T003 `spool-client.mjs` `search()` (live `GET /v1/view/search`, mock matcher).

## Phase 2 — Layout + Omnibox

- [ ] T010 `TopBar.vue` in `layouts/default.vue`; `.app-corner` folded into it; shell below the bar.
- [ ] T011 `stores/omnibox.ts` send target; lobby / channel / dm register and drop their inline Omnibox.
- [ ] T012 `MessageComposer.vue` search mode + operator autocomplete.
- [ ] T013 Mobile collapse to an icon.

## Phase 3 — Results

- [ ] T020 `pages/search.vue`: grouped sections, highlights, keyboard, states, `?q=`.
- [ ] T021 Open-at-message in the thread pane.

## Phase 4 — Contract + proof

- [ ] T006 Align with `search-v1.md` (HUB-SEARCH-API lane) — record the delta.
- [ ] T030 no-x-scroll + CSP e2e green with the bar.
- [ ] T031 Headless-Chrome proof on dev → `/var/tmp/CLE-3410-proof/`.
- [ ] T032 dev + prd `build.json` == the sha.

<!-- last-edit: 2026-09-19T16:30:00Z -->
