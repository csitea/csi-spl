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

## 3. Omnibox

- **FR-010** The per-page Omnibox (lobby, `/channel/*`, `/dm/*`) moves into the bar. It is the same
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
  threads, files, channels, messages. A flat `results[]` response renders as the messages section.
- **FR-022** Snippets show match highlights from **offsets** (never HTML from the server): the WUI splits the
  text into plain / `<mark>` segments rendered as text nodes.
- **FR-023** Click (or Enter on the active row) opens: message → its thread in the right pane, scrolled to the
  message; thread → the thread pane; robot / user → `/dm/<id>`; channel → `/channel/<id>`; file → the thread
  of the message that carries it.
- **FR-024** Keyboard: ArrowUp/ArrowDown move the active row across all sections (wrapping), Home/End jump,
  Enter opens; the list is a `listbox` with `aria-activedescendant`.
- **FR-025** States: empty query (help with operator examples), loading, no results, error (400 `bad_query`
  shows the hub's detail), `next_cursor` → "Load more".
- **FR-026** Mock mode (lde, no hub) searches the local mock corpus with a tiny free-text + `from:` / `in:` /
  `is:` matcher so the UI and tests run offline. The live path never uses it.

## 5. Contract assumptions (until `search-v1.md` lands)

`GET /v1/view/search?q=<raw>&cursor=<opaque>&limit=<n>` on the view door →
`{ query, warnings[], next_cursor, groups: { robots, users, threads, files, channels, messages } }` or
`{ results[] }`; message rows `{ msg_id, task_id, channel, from, from_box, to, kind, created_at|ts,
snippet: { text, highlights: [[start,end]] } }`; `400 { error: "bad_query", detail, pos }`.
The normaliser (`utils/search.mjs`) accepts `[s,e]`, `{start,end}` and `{offset,length}` highlights and
clamps them; the delta to the real contract is recorded in `tasks.md` T006 when it lands.

## 6. Tests

Unit (`tests/unit/search.test.mjs`): mode detection, query → URL, operator token at caret + completion,
highlight segmentation incl. CONTROLS (overlapping / out-of-range / reversed offsets; `<script>` in a snippet
stays text), grouped normalisation, keyboard index. E2E: no-x-scroll with the bar, CSP. Proof: headless Chrome
on dev — type `/search from:EZB-1 is:task`, results, open one → `/var/tmp/CLE-3410-proof/`.

<!-- last-edit: 2026-09-19T16:30:00Z -->
