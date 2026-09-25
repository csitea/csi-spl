# Tasks: Spool WUI top bar + global search (022)

**Feature**: `specs/022-spool-wui-top-bar-search` · **Created**: 2026-09-19

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1 — Spec + pure helpers

- [x] T001 (FR-001..FR-026) Spec (`spec.md`).
- [x] T002 (FR-011, FR-012, FR-022, FR-024) `utils/search.mjs` (mode, URL, operators, highlights, groups, keyboard) + `tests/unit/search.test.mjs`. Check: `node tests/unit/search.test.mjs` → pass 28 at the time (43 on trunk `28442ef6`).
- [x] T003 (FR-026) `spool-client.mjs` `search()` (live `GET /v1/view/search`, mock matcher). Check: `node tests/unit/search.test.mjs` → pass 31 at the time (43 on trunk `28442ef6`).

## Phase 2 — Layout + Omnibox

- [x] T010 (FR-001, FR-002) `TopBar.vue` in `layouts/default.vue`; `.app-corner` folded into it; shell below the bar; the sidebar brand yields to the bar's.
- [x] T011 (FR-010) `stores/omnibox.ts` send target; lobby / channel / dm register and drop their inline Omnibox. Check: `channel-reverse.test.mjs` (incl. CONTROL: no inline `<MessageComposer` in the pages).
- [x] T012 (FR-011, FR-012) `MessageComposer.vue` `global` mode: `/search` chip + Search button, operator picker (ArrowUp/Down, Tab/Enter, Esc), ArrowDown → results, Esc clears / dismisses; code blocks (4c204d0) untouched outside search mode.
- [x] T013 (FR-003) Mobile collapse to an icon, close button, overlay above the corner.

## Phase 3 — Results

- [x] T020 (FR-020, FR-021, FR-022, FR-024, FR-025) `pages/search.vue` + `stores/search.ts`: grouped sections, highlights, one listbox, states (help, loading, empty, bad_query with the token marked, 401 door, 429, 503), per-section Load more, `?q=` restored in the Omnibox.
- [x] T021 (FR-023) Open-at-message in the thread pane (`MessageCard` `data-msg-id`, pane-local scroll + `.search-focus`).

## Phase 4 — Contract + proof

- [x] T006 (FR-012, FR-021, FR-022) Align with `search-v1.md` v1.0 (f28a6ee): per-group `{results,next}`, `boxes`, `snippet`/`title`/`name` display text, `{token,pos,detail}` warnings, `sort`, operators endpoint (`normalizeOperators`, `searchOperators()`). Check: `node tests/unit/search.test.mjs` → pass 37 at the time (43 on trunk `28442ef6`).
- [x] T030 (FR-004) no-x-scroll (+ `/search`, `/search?q=`) 24/24 and CSP (+ `/search?q=deploy`) 8 routes 0 violations, control blocked.
- [x] T031 (FR-001..FR-025) Headless-Chrome proof `tests/e2e/top-bar-search.proof.mjs` (WUI a820b68, hub 0.1.11 (tree `c4a77d6`), n=1 run each): lde mock 13/13 (`/var/tmp/CLE-3410-proof/lde-mock/`); dev signed in as the test member: `from:EZB-1 is:task` 11/11 (honest empty state, no EZB-1 sender on dev t1), `code proof` 13/13 (threads 1 + messages 2, 6 marks, `<script>` payload rendered as text, opened in the thread pane), `type:robot` 13/13 (robots 4, opened `/dm/EZA-1@box-e2e-a`); prd anonymous 10/10 (bar, autocomplete, view-door state, mobile). No signed-in prd run: prd t1 is the owner's real tenant.
- [x] T032 (FR-001) dev + prd `build.json` == 63e37dc (run 35455922444).
- [x] T033 (FR-010, FR-025) dev finding (proof on 63e37dc): the hub answers the not-yet-deployed route with a 404 without CORS headers, so the page saw status 0 and printed an empty detail; a status-0 failure now says the search service is unreachable. The page Omnibox placeholder says "/search to search everything" (`search.placeholder_target`, 19 locales) instead of 013's "to filter"; `pages.message_placeholder` is now unused (still in the catalogues: removal is 021 T041).
- [ ] T034 (FR-021, FR-023) Align the group / type / operator names with `search-v1.md`: the code says `topics` / `topic:` since `57f8a670`, the contract says `threads` / `thread:`. Status: open, integrator/owner decision (asked in topic 582f7895). Either the contract moves to `topics` (with `thread` kept as an alias) or `internal/search/grammar.go` restores the `thread` aliases.
- [ ] T035 (FR-001..FR-025) Signed-in prd run of `tests/e2e/top-bar-search.proof.mjs` on prd tenant `e2e` (T031 skipped prd signed-in only because prd t1 is a real tenant; 023 T042 already used `e2e`).

<!-- version: 1.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:33:59Z -->
