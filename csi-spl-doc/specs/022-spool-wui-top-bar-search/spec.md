# Spec: Spool WUI top bar + global search (022)

**Feature**: `specs/022-spool-wui-top-bar-search` · **Created**: 2026-09-19 · **Lane**: WUI-TOPBAR-SEARCH
**Depends on**: the hub search contract `search-v1.md` (HUB-SEARCH-API lane — owns the grammar, the parser and the backend)

## 1. Owner ask (verbatim, 2026-09-19)

> "the whole WUI layout should be changed so that there will be a horizontal strip on the top which will stay
> and the omnibox will be in it, the omnibox will start a global search by typing /search and the rest will be
> the search items ... this will enable some search syntax gmail wise"

> "figure out gmail wise syntax for the searching of robots, searching of users, search of threads by title,
> search by attachment etc. you could use the same syntax"

## 2. Layout

- **FR-001** A persistent horizontal top bar (`TopBar.vue`, `data-test="top-bar"`) spans the whole WUI on every
  page of the default layout. It never scrolls away and holds, in reading order: the brand, the **Omnibox**, and
  at the end the language switcher (spec 021) and the user avatar menu (CLE-3402). The old fixed `.app-corner`
  cluster moves into the bar; headers no longer reserve `--app-corner-w`.
- **FR-002** The 3-pane shell (sidebar | feed | thread, with the draggable dividers) sits below the bar and fills
  the remaining viewport height.
- **FR-003** Mobile (≤ 640px): the bar stays; the Omnibox collapses to a search icon button that expands the
  Omnibox over the bar (Esc on an empty line collapses it again).
- **FR-004** No document x-scroll at any width (the no-x-scroll gates stay green); no inline script
  (CSP SEC-06 stays green).
- **FR-005** The bar's start cluster also holds the theme toggle (`TopBar.vue:10` `<ThemeToggle />`), and `/`
  outside a text field focuses the Omnibox (`utils/slash-focus.mjs`). Recorded from the code, not from an owner ask.

## 3. Omnibox

- **FR-010** The per-page Omnibox (lobby, `/`, `/channel/*`, `/dm/*`, `/t/*`) moves into the bar. It is the same
  `MessageComposer` (so the ``` code-block behaviour of the code-blocks lane works in it). The page on screen
  registers its **send target** (placeholder, `send(text, files)`, busy) with the `omnibox` store; normal text is
  sent to that target exactly as before. A page with no target (settings, checkout, search) disables plain send
  and says "type /search …".
- **FR-011** `/search <query>` (alias `/s`) switches to global search: the WUI navigates to
  `/search?q=<query>` with the rest of the line **verbatim**. The WUI does **not** parse the grammar; the hub does.
- **FR-012** While the line starts with `/search `, the Omnibox is in *search mode*: a mode chip shows it, the
  send button reads "Search", @-mention autocomplete is off, and the operator at the caret is autocompleted from
  the operator catalogue (`utils/search.mjs` `SEARCH_OPERATORS`, mirroring `search-v1.md`). ArrowUp/Down move,
  Tab/Enter pick, Esc closes the list. An operator the hub does not know comes back as a `warnings[]` entry and
  is shown, never fatal.
- **FR-013** Thread-pane reply composers keep their local `/search` filter (unchanged, 013).

## 4. Results view (`/search?q=`)

- **FR-020** Deep-linkable: loading `/search?q=…` runs the query.
- **FR-021** Results render in **grouped sections** in this order, each only when non-empty: robots, users,
  channels, boxes, topics, files, messages (group `threads` renamed `topics` in `57f8a670`; seam below); each section has its own "Load more" (per-group cursor).
- **FR-022** Snippets show match highlights from **offsets** (never HTML from the server): the WUI splits the
  text into plain / `<mark>` segments rendered as text nodes.
- **FR-023** Click (or Enter on the active row) opens: message → its thread in the right pane, scrolled to the
  message; topic → the topic pane; robot / user → `/dm/<id>`; channel → `/channel/<id>`; box → `/search?q=box:<id>`;
  file → the thread of the message that carries it.
- **FR-024** Keyboard: ArrowUp/ArrowDown move the active row across all sections (wrapping), Home/End jump,
  Enter opens; the list is a `listbox` with `aria-activedescendant`.
- **FR-025** States: empty query (help with operator examples), loading, no results, errors (400 `bad_query`
  shows the hub's detail and the bad token, 429 / 503 their own line, 401 the view-door form).
- **FR-026** Mock mode (lde, no hub) searches the local mock corpus with a tiny free-text + `from:` / `in:` /
  `is:` matcher so the UI and tests run offline. The live path never uses it.

## 5. Contract

`csi-spl-doc/specs/003-spool-message-bus/contracts/search-v1.md` v1.0 (f28a6ee) — cited, not restated. What the WUI
relies on: `GET /v1/view/search?q=<raw>&sort=&cursor=&limit=` → `groups.<plural>.{results,next}` (seven types, a
cursor per group answers that group only → `mergeSearchPage`), display text in `snippet` / `title` / `name`
`{text, highlights:[[s,e)]}` in UTF-16 units (= `String.slice`), `warnings[{token,pos,detail}]`, `400 bad_query
{detail,pos,token}`, `429 rate_limited`, `503 search_budget`; autocomplete from `GET /v1/view/search/operators`
(`normalizeOperators`), with the built-in `SEARCH_OPERATORS` only as the offline / not-yet-deployed fallback.
Section order in the WUI: robots, users, channels, boxes, topics, files, messages (entities first, as Slack).

**Seam — topics vs threads: open, integrator/owner decision (asked in topic 582f7895).** `search-v1.md` still names the group `threads`, the type
`thread` and the operator `thread:`. The code does not: `csi-spl-wui/src/utils/search.mjs:20`
`SEARCH_GROUPS = [..., 'topics', ...]`; hub `internal/search/grammar.go:32` `TypeTopic Type = "topic"`, and
`git show 57f8a670 -- .../internal/search/grammar.go` removes `"thread": TypeThread, "threads": TypeThread` and
`OpThread = "thread"`. So `type:thread` / `thread:` from the contract no longer parse. Task T034.

## 6. Tests

Unit (`tests/unit/search.test.mjs`): mode detection, query → URL, operator token at caret + completion,
highlight segmentation incl. CONTROLS (overlapping / out-of-range / reversed offsets; `<script>` in a snippet
stays text), grouped normalisation, keyboard index. E2E: no-x-scroll with the bar, CSP. Proof: headless Chrome
on dev — type `/search from:EZB-1 is:task`, results, open one → `/var/tmp/CLE-3410-proof/`.

## 7. Status (trunk `28442ef6`, n=1)

| FR | status | evidence |
|---|---|---|
| FR-001, FR-002 | Implemented | T010; `TopBar.vue:7` `data-test="top-bar"`, `:64-66` switcher + user menu |
| FR-003 | Implemented | T013; `TopBar.vue` `@media (max-width: 640px)` |
| FR-004 | Implemented | T030 |
| FR-005 | Implemented | `TopBar.vue:10`, `utils/slash-focus.mjs`, `tests/unit/slash-focus.test.mjs` |
| FR-010 | Implemented | T011; `grep -rln omnibox src/pages` -> lobby, index, channel, dm, t, search |
| FR-011, FR-012 | Implemented | T002, T012; `search.mjs:82` also accepts `/search:` |
| FR-013 | Implemented | `TopicPane.vue:97` local `matchesSearch` filter |
| FR-020, FR-022, FR-024, FR-025, FR-026 | Implemented | T002, T003, T006, T020; `node --test tests/unit/search.test.mjs` -> pass 43 |
| FR-021, FR-023 | Partial | WUI side Implemented (T020, T021); missing: the contract still says `threads` (seam in §5, T034) |

Also in the bar, outside this spec: the inline send error with Retry (CLE-3433, `TopBar.vue:29-41`), the resizable
Omnibox (`utils/omnibox-size.mjs`), operators fetched only with a member session (`shouldLoadOperators`,
`operators-session.proof.mjs`), the `/search` view door (`tests/unit/search-door.test.mjs`, 010 FR-009), and the
800px sidebar rail (`tests/e2e/top-bar-rail-live.proof.mjs`).

<!-- version: 1.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:33:59Z -->
