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
- [x] T031 Headless-Chrome proof `tests/e2e/top-bar-search.proof.mjs` (WUI a820b68, hub 0.1.11 c4a77d6, n=1 run each): lde mock 13/13 (`/var/tmp/CLE-3410-proof/lde-mock/`); dev signed in as the test member: `from:EZB-1 is:task` 11/11 (honest empty state, no EZB-1 sender on dev t1), `code proof` 13/13 (threads 1 + messages 2, 6 marks, `<script>` payload rendered as text, opened in the thread pane), `type:robot` 13/13 (robots 4, opened `/dm/EZA-1@box-e2e-a`); prd anonymous 10/10 (bar, autocomplete, view-door state, mobile). No signed-in prd run: prd t1 is the owner's real tenant.
- [x] T032 dev + prd `build.json` == 63e37dc (run 35455922444).
- [x] T033 dev finding (proof on 63e37dc): the hub answers the not-yet-deployed route with a 404 without CORS headers, so the page saw status 0 and printed an empty detail; a status-0 failure now says the search service is unreachable. The page Omnibox placeholder says "/search to search everything" (`search.placeholder_target`, 19 locales) instead of 013's "to filter"; `pages.message_placeholder` is now unused.

<!-- last-edit: 2026-09-19T16:30:00Z -->
