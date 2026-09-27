# Spec: Spool WUI top bar + global search (022)

**Feature**: `specs/022-spool-wui-top-bar-search` · **Created**: 2026-09-19 · **Lane**: WUI-TOPBAR-SEARCH
**Depends on**: the hub search contract `search-v1.md` (HUB-SEARCH-API lane — owns the grammar, the parser and the backend)

> Owner, 2026-09-26 06:21Z, PRD #spool-hub-devel (topic `6a7a6c73`), verbatim: "in the omnibox we need to have
> synthax for searching for every object which is in the ui to list the filtered objects , those are - tenants ,
> channels , messges , topics , event logs etc. , so the normal search should be by content , but there should be
> a synthax to be able to search by specific names as well ... Overall the omnibox should be really really smart ,
> we need to improve the indexsing and searching capabliities of it once the data in the db starts grwoing and
> take into the considerations the existing languages as well ..." — §8, §9 (CLE-34992, CLE-34973, GRK-3518).

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

## 8. Smart omnibox: every UI object, content first, names by syntax (2026-09-26)

Owner quote at the top of this file. One grammar, parsed in the hub (`internal/search`, `search.Version` 1.1); the
WUI never parses a query (FR-011 unchanged).

- **FR-040** Object kinds, `type:` (alias `kind:`): message, topic (alias thread), file, channel, user (alias
  person), robot (alias agent), box, **tenant** (the reader's own memberships; a row switches workspace and reads
  nothing of that tenant) and **event** (the reader's OWN event log, rdb 0045, the privacy of `/api/v1/auth/events`).
- **FR-041** Plain words search CONTENT: message bodies, topic titles, file names, the names of channels, people,
  agents and boxes. tenant and event are **opt-in** (`type:tenant`, `type:event`): with them in the default set,
  `GET /v1/view/search?q=seed` cost 14 DB round trips against the budget of 9 (`TestRoundTripsPerRequest`, local
  pg16, n=5; CLE-34973, 393c5a87).
- **FR-042** Names by syntax: `name:<text>` matches only the object's NAME (a topic's title, a channel, tenant,
  person, agent, box or file name, an event's code), never its content. `title:` stays for topics.
- **FR-043** As you type: the query's last bare word is a prefix while nothing is typed after it (`deplo` finds
  deploy, deployed; `deplo ` and `-deplo` do not). `word*` and `title:word*` force a prefix anywhere (393c5a87).
  The user text reaches Postgres only as `plainto_tsquery`'s bind parameter; `:*` is appended to its OUTPUT.
- **FR-044** Languages: one language-neutral match for all 19 locales. Case and accents fold (`cafe` = Café,
  `strasse` = Straße, `resume` = résumé, `lodz` = Łódź, Greek tonos); a mark that is part of the letter stays
  (й, Hangul). Postgres: rdb 0048 `spool_search` = the `simple` parser behind `unaccent`; Go: `search.Fold`
  (memory store, highlights, name matching). No stemmer per language: a message has no language tag, and one
  language's stemmer on another's text loses matches; FR-043's prefix covers inflection for every language.
  CJK has no word breaks, so a CJK run matches by prefix only; `pg_trgm` is the follow-up if a locale needs
  substring search, measured first.
- **FR-045** Scopes: `in:` (alias `channel:`), `from:`, `to:`, `box:`, `topic:`, `is:`, `has:`, `ext:`,
  `larger:`/`smaller:`, and `before:`/`after:`/`on:` (also on events). Space = AND, `OR`, `-`, `( )`.
- **FR-046** The read door is unchanged: nothing the reader cannot open comes back (rdb 0028 channels, a DM's two
  ends, own events, own tenants); content search stays in the tenant the reader is in.
- **FR-047** Scale: the topic section finds candidate topics through the message index (`topicCandidates`)
  before it aggregates, when the query has a top-level positive text / `title:` / `in:` term; §9 measures it.
- **FR-048** WUI (GRK-3518): operator help popover and autocomplete from `GET /v1/view/search/operators`,
  tenant rows switch workspace, event rows open `/events#<event_id>`, 19 locales (9123919f, abbe819b).

## 9. Scale, measured (dev, 2026-09-26, CLE-34992)

**Setup.** `do_spl_search_seed` put 400 000 messages / 10 000 topics / 950 channels into one throwaway dev
tenant (`seed-search`), on the dev Cloud SQL `db-f1-micro` (the prd tier; no bigger tier, owner rule). The 1M
target stopped at 400k: batches 1-3 took about 1 min each and batch 4 took 8+ min on the shared-core CPU. 400k is
235x prd's whole message table (1 696 rows, 06:45Z). `do_spl_search_measure` then ran the store's SQL as the
hub's runtime login (`spool_hub_rt`, tenant RLS scope, `jit` off, read-only session), n=3 per query, 60 s
ceiling, trunk `f3e48bd1` + the measure fixes. `do_spl_search_seed_purge` deleted the seed at 07:44Z (0 rows,
0 channels, 0 `seed-*` tenants left).

| query (400k messages, one tenant) | before p50 / p95 | after p50 / p95 |
|---|---|---|
| topic section, a rare word (`term4242`, 8 rows) | 48.0 s / >60 s | **5.3 s / 7.0 s** (`topicCandidates`) |
| topic section, a common word (`deploy`, ~10%) | 45.7 s / 53.5 s | 46.3 s / >60 s (no gain) |
| message section, a rare word | 589 ms / 1 860 ms | — |
| message section, a common word / `cafe` | 0.1 ms / 7.4 ms | — |

**Finding (the ceiling).** The hub never uses the GIN index on `messages.search_tsv`, not since rdb 0020:
`messages` has FORCE ROW LEVEL SECURITY and the tsvector match operator is not LEAKPROOF
(`pg_proc`: `ts_match_vq` `proleakproof = f`), so Postgres will not use it as an index condition under the
tenant policy. It scans the tenant's rows instead (EXPLAIN: `Index Scan Backward using messages_received ...
Rows Removed by Filter: 344312`; the prefilter: `Parallel Seq Scan on messages k`). A common word is fast (the
newest rows match at once); a rare word, and every topic query that must aggregate, costs a scan of the tenant.
On `db-f1-micro` the 2 s search budget is reached somewhere below 400k messages in ONE tenant (30-day retention).
Second, smaller: the store wraps every leaf in `COALESCE(..., false)` (for NOT), which also hides the match from
the planner's row estimate (it planned 199 018 rows for 7).

**Owner decisions (none taken here; each changes the tenant-isolation design, 017 FR-SEC-013/014):**
- D-S1 a SECURITY DEFINER search function whose owner may bypass RLS, taking the tenant from the session scope
  (one audited lift path, like `asOperator`);
- D-S2 marking the tsvector operators LEAKPROOF (needs a real superuser, which Cloud SQL does not give);
- D-S3 a per-tenant topic summary table kept by a trigger (title, channel, first/last, count), so the topic section
  stops aggregating messages at all;
- D-S4 accept the ceiling (prd is 1 696 messages today) and revisit when a tenant nears 100k.

## 10. Search refactor: Open original (owner 2026-09-27, CLE-35063)

> Owner, prd t1, topic `e615e3fd`: "the whole search use case must be refactored ..."; topic `58397faf`:
> "basically once a search listing is received and one clicks on it, the search listing's right menu should
> have the option 'open original', which will open the direct message or the channel etc."

### 10.1 Review of the flow as shipped (dev t1, WUI 1.1.1 `9eccd0ad`, 1440x900 and 390x844, n=1)

| # | step | what happens today | verdict |
|---|---|---|---|
| R1 | `/search deploy` in the Omnibox | `/search?q=deploy`, grouped sections, highlights from offsets | works |
| R2 | right-click a result | the browser's own menu; a search row has no menu and no row button | **missing** |
| R3 | click / Enter on a message hit | the hit's TOPIC opens in the right pane of the search page (`?topic=`); the pane opens at its top and the hit is focused with `preventScroll`, so a hit further down is not on screen | **awkward**: FR-023 "scrolled to the message" is not what the reader sees |
| R4 | reaching the DM / channel the hit lives in | only by a second step: right-click the line inside the right pane, then "Open parent section" (CLE-34996) | **missing on the row** |
| R5 | phone (<= 820 px, dock since SPL-1005) | a tap replaces the list with the topic pane (level 3); the hit is not scrolled to; there is no long-press sheet on a row | **awkward** |
| R6 | topic / file hits | the same preview as R3; a topic row carries no `from`/`to`, so its DM peer is unknown to the WUI | fallback needed |
| R7 | grammar, backend (`spool_search`, rdb 0048, counts of SPL-1008) | not changed by this section | keep |

### 10.2 Requirements

- **FR-050** Every search result row has a **right menu**: right-click, a row button (the ≡ of a sidebar row,
  shown on hover / focus / the active row, always on a phone) and, on a phone, a long press, which opens it as
  the bottom sheet (SPL-991). Items, in order: **Open original**, **Show here** (message, topic and file rows
  only: today's right-pane preview), **Copy link** (the original's address).
- **FR-051** **Open original is the default**: click, Enter on the active row and a tap all do it.
  - message / file → the place it was posted: `/channel/<id>` or `/dm/<peer>` with `?topic=` (and `?in=`) and
    `#<msg_id>`, the parent card revealed in the middle and the thread open on the right (the same
    `parentSection` / `openParentSection` as "Open parent section", one implementation); a message in the issue
    channel → `/issues?issue=<key>`.
  - topic → its channel with `?topic=`; a topic whose place the row cannot name (a DM topic: no peer on the
    row) → the topic page `/t/<task_id>`.
  - every other row type: its FR-023 target, unchanged (a user or robot IS its DM, a channel IS its channel).
- **FR-052** At the original, the hit is scrolled to and marked: the thread pane moves the `#<msg_id>` line to
  its top and focuses it (the existing hash rule of `LiveFeed`), and the line carries the `search-focus` flash.
- **FR-053** Back returns to `/search?q=` with the query and the results (the original is a `router.push`).
- **FR-054** No grammar, hub or rdb change. The menu is lazy (mounted on open), so the initial chunk
  (027 ceiling) does not grow.

<!-- version: 1.3.0 · updated: 2026-09-27 · last-edit: 2026-09-27T21:40:00Z -->
