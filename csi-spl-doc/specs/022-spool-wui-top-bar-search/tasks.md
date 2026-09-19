# Tasks: Spool WUI top bar + global search (022)

**Feature**: `specs/022-spool-wui-top-bar-search` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — Spec + pure helpers

- [x] T001 Spec (`spec.md`).
- [x] T002 `utils/search.mjs` (mode, URL, operators, highlights, groups, keyboard) + `tests/unit/search.test.mjs`. Check: `node tests/unit/search.test.mjs` → pass 28.
- [x] T003 `spool-client.mjs` `search()` (live `GET /v1/view/search`, mock matcher). Check: `node tests/unit/search.test.mjs` → pass 31.

## Phase 2 — Layout + Omnibox

- [x] T010 `TopBar.vue` in `layouts/default.vue`; `.app-corner` folded into it; shell below the bar; the sidebar brand yields to the bar's.
- [x] T011 `stores/omnibox.ts` send target; lobby / channel / dm register and drop their inline Omnibox. Check: `channel-reverse.test.mjs` (incl. CONTROL: no inline `<MessageComposer` in the pages).
- [x] T012 `MessageComposer.vue` `global` mode: `/search` chip + Search button, operator picker (ArrowUp/Down, Tab/Enter, Esc), ArrowDown → results, Esc clears / dismisses; code blocks (4c204d0) untouched outside search mode.
- [x] T013 Mobile collapse to an icon, close button, overlay above the corner.

## Phase 3 — Results

- [x] T020 `pages/search.vue` + `stores/search.ts`: grouped sections, highlights, one listbox, states (help, loading, empty, bad_query with the token marked, 401 door, 429, 503), per-section Load more, `?q=` restored in the Omnibox.
- [x] T021 Open-at-message in the thread pane (`MessageCard` `data-msg-id`, pane-local scroll + `.search-focus`).

## Phase 4 — Contract + proof

- [x] T006 Align with `search-v1.md` v1.0 (f28a6ee): per-group `{results,next}`, `boxes`, `snippet`/`title`/`name` display text, `{token,pos,detail}` warnings, `sort`, operators endpoint (`normalizeOperators`, `searchOperators()`). Check: `node tests/unit/search.test.mjs` → pass 37.
- [x] T030 no-x-scroll (+ `/search`, `/search?q=`) 24/24 and CSP (+ `/search?q=deploy`) 8 routes 0 violations, control blocked.
- [~] T031 Headless-Chrome proof `tests/e2e/top-bar-search.proof.mjs`: lde mock bundle 13/13 PASS (`/var/tmp/CLE-3410-proof/lde-mock/`); dev run waits for the hub route (HUB-SEARCH-API lane).
- [ ] T032 dev + prd `build.json` == the sha.

<!-- last-edit: 2026-09-19T16:30:00Z -->
