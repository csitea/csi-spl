# Contract: Search API v1 (one Gmail-style grammar over every entity the viewer sees)

Feature: `003-spool-message-bus`, User Story 9 (FR-029 – FR-032). Consumer:
the WUI top-bar omnibox (`/search <query>`, lane CLE-3410; it cites this file
and does not restate it). Owner (2026-09-19): *"the omnibox will start a
global search by typing /search and the rest will be the search items … this
will enable some search syntax gmail wise"* and *"figure out gmail wise syntax
for the searching of robots, searching of users, search of threads by title,
search by attachment etc. you could use the same syntax"*.

Normative order: `./view-v1.md` (door, tenant, CORS, cursors, retention),
then this file, then `./error-envelope.md`.

**Status: v1.0 — Implemented (tasks T048 – T053).** Tests:
`TestOperators`, `TestParseErrors`, `TestWarnings`, `TestHighlights`
(`internal/search`), `TestSearch`, `TestSearchP95` (`internal/store`, memory +
Postgres), `TestSearchAPI`, `TestSearchDoorAndRate` (`internal/hub`). Code: grammar + parser `internal/search`, route
`internal/hub/search.go`, store `internal/store/search*.go`, rdb
`0020_message_search.sql`.

## 0. What this is, and what it is not

- **One grammar, one parser, server-side.** The browser sends the raw text
  after `/search ` as `q` and never parses it; the hub answers with results,
  warnings, or a `400` that points at the bad token. The WUI may use
  `GET /v1/view/search/operators` (§6) for autocomplete; it never re-implements
  the grammar.
- **Read-only**, like every `/v1/view/*` route (view-v1 §0, FR-019): a search
  never delivers, claims, marks or touches roster, pins or `last_hello_at`.
- **Seven entity types, one query**: `message`, `thread`, `file`, `robot`,
  `user`, `channel`, `box`. A query without `type:` searches every type its
  operators apply to and answers **grouped sections** (Slack / Gmail style).
- **Same door and scope as the viewer.** The view door (`view-v1.md` §2:
  member session, or `off` in lde/dev), the Host tenant, the same CORS
  allow-list. Every row comes from the Host tenant only — Postgres RLS scoped
  per statement (rdb 0014, 017 FR-SEC-013) **and** `WHERE tenant_id`. DMs are
  private: with a member session, a message / file / thread with no channel is
  returned only when the reader (`HUM-*`) is a party of that thread
  (view-v1 §4.3). Only messages in retention (`expires_at > now`).

## 1. Endpoints

```
GET  /v1/view/search?q=<raw query>&limit=&sort=&cursor=     FR-029
GET  /v1/view/search/operators                              FR-031 (machine-readable grammar)
```

`OPTIONS` → the view preflight (view-v1 §3). Any other method → `405`.

| param | meaning |
|---|---|
| `q` | the raw query (§2). Required; empty / whitespace only → `400 bad_query`. Max **512** UTF-16 code units, max **32** terms (operators + words) → else `400 bad_query`. |
| `limit` | per section. Grouped (no `type:`, no `cursor`): default **5**, max **20**. One type (`type:` with one value, or `cursor`): default **50**, max **200**. Above max → clamped, like view-v1. |
| `sort` | `newest` (default) or `relevance`. `relevance` ranks **messages** by Postgres `ts_rank_cd` over the positive text terms, newest first on ties; every other type always sorts by its own order (§4). Anything else → `400 bad_query`. |
| `cursor` | a section's `next` from an earlier answer **for the same `q` and `sort`**. With a cursor the hub answers **that one section only**. A cursor it cannot decode, or one minted for another `q` / `sort` → `400 bad_cursor`. |

## 2. Grammar

### 2.1 Tokens and precedence (Gmail's)

```
query    = conj
conj     = disj { [ "AND" ] disj }          implicit AND between terms
disj     = unary { "OR" unary }             OR binds TIGHTER than AND (Gmail)
unary    = [ "-" ] atom                     "-" negates the atom right after it
atom     = "(" conj ")"  |  operator  |  phrase  |  word
operator = name ":" ( phrase | word )       name is case-insensitive, from §3
phrase   = '"' { any char but '"' } '"'
word     = run of chars other than space, '(' , ')' and '"'
```

- `from:CLE-07 OR from:GRK-03 deploy` = `(from:CLE-07 OR from:GRK-03) AND deploy`.
- `OR` and `AND` are operators **only in upper case** and only as whole words;
  `or`, `and` are text. `|` is text.
- `-` negates only at the **start** of a token: `-from:CLE-07`, `-"dry run"`,
  `-(a OR b)`. `box-a`, `x-y` are words. A lone `-` → `400`.
- A word that looks like an operator but whose name is not in §3 (`foo:bar`)
  is **text**, and the answer carries a warning (§5.2). A word containing
  `://` (a URL) is text with no warning.
- Parentheses nest; at most **8** deep.

### 2.2 Text

A **word** or **phrase** term applies to every type; what it matches is per
type (the "text" row of §3.2). For messages it is Postgres full-text search
(`to_tsvector('simple', body)`, GIN index): a word matches whole lexemes,
case-insensitively, with no stemming (the `simple` configuration, so every
locale of `021-spool-wui-i18n` behaves the same; language-specific configs
wait until a locale needs stemming). A **phrase** matches its words adjacent
and in order (`phraseto_tsquery`). A word with no letter or digit (`!!!`)
matches nothing: it is dropped with a warning.

Every user string reaches SQL as a **bind parameter** of `plainto_tsquery`,
`phraseto_tsquery`, `=`, or `strpos(lower(…), lower($n))` — never
concatenated, never passed to `to_tsquery`, never used as a `LIKE` pattern.
A query shaped like SQL (`'; DROP TABLE messages; --`) is just text.

### 2.3 Dates

`before:` / `after:` / `on:` take `YYYY-MM-DD` (UTC day) or, for `before:` /
`after:`, a relative age `<n>h`, `<n>d`, `<n>w` (1 ≤ n ≤ 3650). They compare
the **hub receive time** (`received_at`, the time cursors and view-v1 use):

| operator | row matches when |
|---|---|
| `after:2026-09-01` | `received_at >= 2026-09-01T00:00Z` |
| `before:2026-09-01` | `received_at <  2026-09-01T00:00Z` |
| `on:2026-09-01` | `2026-09-01T00:00Z <= received_at < 2026-09-02T00:00Z` |
| `after:7d` | `received_at >= now − 7 d` |
| `before:24h` | `received_at <  now − 24 h` |

For a thread the time is its **last activity**.

### 2.4 Sizes

`larger:` / `smaller:` take `<n>`, `<n>K`, `<n>M`, `<n>G` (bytes, ×1024 each
step; case-insensitive; `n` an integer ≥ 0). `larger:1M` = `bytes > 1048576`,
`smaller:10K` = `bytes < 10240`. A file with no recorded size (a `path`
attachment without `bytes`, or a directory) matches neither.

## 3. Operators

### 3.1 Selecting the entity type

`type:<t>[,<t>…]` picks the sections. Values (aliases in brackets):
`message` [`msg`, `messages`], `thread` [`threads`], `file` [`attachment`,
`files`], `robot` [`agent`, `bot`, `robots`], `user` [`human`, `users`],
`channel` [`channels`], `box` [`boxes`].

- At most one `type:` term, at the **top level** of the AND (not inside `OR`,
  not negated) → else `400 bad_query`.
- Without `type:` the candidate types are all seven.
- **Applicability**: a section is searched only when **every** operator in
  the query applies to its type (§3.2). `from:CLE-07 report` searches
  messages, threads and files; `filename:plan` searches files only;
  `filename:plan is:online` applies to no type → `400 bad_query` pointing at
  the operator that emptied the set.

### 3.2 The operator table

| operator | value | applies to | matches |
|---|---|---|---|
| *word*, `"phrase"` | text | all | message: body FTS (§2.2); thread: title FTS; file: `name`; robot: agent id or box id; user: `HUM-*` or display name; channel: slug; box: box id (the non-FTS ones are case-insensitive substrings) |
| `type:` | §3.1 | — | selects sections |
| `from:` | `<agent>`, `<agent>@<box>`, `HUM-<n>`, `<box>` | message, thread, file | the sender: `from_id` = value, or `from_box` = value; `<agent>@<box>` needs both. thread: any message of the thread; file: the carrying message |
| `to:` | same | message, thread, file | the recipient, like `from:` |
| `box:` | `<box>` | message, thread, file, robot, box | message / file: `from_box` or `to_box`; thread: any message; robot: its box; box: its id |
| `in:` | `#<channel>`, `<channel>`, `dm` | message, thread, file | the channel (`general` = `lobby`); `in:dm` = no channel (a DM) |
| `is:` | `task`, `note`, `result`, `reject` | message | the message kind |
| `is:` | `root` | thread | `parent_task_id` is null |
| `is:` | `online`, `offline` | robot, user, box | presence now (a live box socket; a human's open browser socket) |
| `is:` | `revoked` | robot, box | the box pin is revoked |
| `has:` | `file` [`attachment`] | message | `files[]` is not empty |
| `has:` | `code` | message | the body has a fenced code block (a line starting with ```` ``` ````, CLE-3407) |
| `thread:` | `<task_id>` (UUID) | message, thread, file | `task_id` = value |
| `before:` `after:` `on:` | §2.3 | message, thread, file | receive time (thread: last activity) |
| `title:` [`subject:`] | text | thread | the thread title (first line of its first message, ≤ 140 chars, view-v1 §4.3), FTS |
| `name:` | text | file, robot, user, channel, box | the entity's name only (substring) |
| `filename:` | text | file | the attachment `name` (substring) |
| `ext:` | `[a-z0-9]{1,16}`, leading `.` allowed | file | `name` ends with `.<ext>` (case-insensitive) |
| `larger:` `smaller:` | §2.4 | file | attachment `bytes` |

Values are case-insensitive except ids (`CLE-07`, `HUM-3`, box ids, task
ids), which are compared as given. An operator value may be a phrase:
`title:"release plan"`, `filename:"q3 report"`.

### 3.3 Examples

```
/search deploy                                   every section that mentions "deploy"
/search "dry run" from:CLE-07 after:7d           messages / threads / files of CLE-07 this week
/search in:#tasks is:result -is:reject           results posted in #tasks
/search from:HUM-3 OR from:HUM-4 has:file        messages with attachments from two humans
/search type:robot is:online                     every robot online now
/search type:user ops                            humans whose id / display name contains "ops"
/search title:migration                          threads titled with "migration"
/search type:file ext:pdf larger:1M              PDFs over 1 MiB
/search filename:"q3 report" in:dm               attachments named "q3 report…" in DMs
/search has:code (golang OR rust) -in:#alerts    code snippets about go or rust outside #alerts
/search thread:<task-uuid> before:2026-09-01     one thread's messages before September
/search type:channel,box a                       channels and boxes whose name contains "a"
```

## 4. Response `200`

```json
{ "query": "deploy from:CLE-07",
  "sort": "newest",
  "types": ["message", "thread", "file"],
  "warnings": [ { "token": "foo:bar", "pos": 19, "detail": "unknown operator foo: searched as text" } ],
  "groups": {
    "messages": { "results": [ … ], "next": "<cursor or null>" },
    "threads":  { "results": [ … ], "next": null },
    "files":    { "results": [ … ], "next": null } } }
```

- `types` lists the sections searched, in this fixed order: `message`,
  `thread`, `file`, `robot`, `user`, `channel`, `box`. `groups` has one key
  per searched type, plural (`messages`, `threads`, `files`, `robots`,
  `users`, `channels`, `boxes`), each `{results, next}`; an empty section is
  `{"results": [], "next": null}`. There is no total count (it would cost a
  second scan).
- With a `cursor`, `types` and `groups` hold that one section.
- **Offsets**: every `highlights` is a list of `[start, end)` pairs in
  **UTF-16 code units** of its `text` (what JavaScript `String.slice` takes),
  sorted, non-overlapping. `pos` (warnings, errors) is a UTF-16 offset into
  `q`. Text is plain text, **never HTML**: the WUI escapes it and wraps the
  ranges itself.
- Order: messages and files newest `received_at` first (`sort=relevance`:
  messages by rank); threads by last activity, newest first; robots by
  `agent@box`, users by `HUM-*`, channels and boxes by id.

### 4.1 `message`

```json
{ "msg_id": "…", "task_id": "…", "parent_task_id": null, "channel": "tasks",
  "kind": "note", "from": "CLE-07", "from_box": "box-a", "to": "HUM-3", "to_box": "box-wui",
  "created_at": "2026-09-19T12:00:00Z", "received_at": "2026-09-19T12:00:00.123456Z",
  "files": 1,
  "snippet": { "text": "… we deploy the hub after the migration …", "highlights": [[5, 11]] } }
```

`channel` null = a DM. `created_at` is the message's own signed `ts`;
`received_at` the hub time. `snippet.text` is at most **200** characters of
the body around the first highlighted term (the whole body when shorter; `…`
marks a cut; newlines become spaces). Highlights mark each positive text term
(not negated, not operator values) wherever it occurs in the snippet as a
whole word, case-insensitively. To open it: `GET /v1/view/threads/{task_id}`.

### 4.2 `thread`

```json
{ "task_id": "…", "parent_task_id": null, "channel": "tasks",
  "title": { "text": "Migrate the hub to 0017", "highlights": [[0, 7]] },
  "first_ts": "…", "last_ts": "…", "count": 4 }
```

Same fields and meaning as view-v1 §4.3 (`title.text` = its `subject`).

### 4.3 `file`

```json
{ "file_id": "<sha256 hex or null>", "kind": "file", "mode": "blob", "bytes": 20480,
  "name": { "text": "q3 report.pdf", "highlights": [[0, 2]] },
  "msg_id": "…", "task_id": "…", "channel": null,
  "from": "CLE-07", "from_box": "box-a", "received_at": "…" }
```

One row per attachment of a matching message (`files[]` entry of the stored
message). `file_id` is null for a `path` attachment; the on-box `path` is
never returned here. Bytes: `GET /v1/files/{file_id}` (view-v1 §1). `bytes`
is null when not recorded.

### 4.4 `robot`

```json
{ "id": "CLE-07", "box": "box-a", "online": true, "revoked": false,
  "name": { "text": "CLE-07@box-a", "highlights": [[0, 3]] } }
```

One row per agent in a box's last announcement (the roster, view-v1 §4.1).

### 4.5 `user`

```json
{ "id": "HUM-3", "display_name": "FirstName LastName", "avatar_file_id": null, "online": false,
  "name": { "text": "FirstName LastName (HUM-3)", "highlights": [] } }
```

Member humans of this tenant only (disabled excluded), as view-v1 §4.1.
`display_name` is the name from sign-in, or null (`name.text` is then the
`HUM-*` id alone). **Email is never searched and never returned**: a search on
it would be an oracle for addresses the roster does not show.

### 4.6 `channel`

```json
{ "channel": "tasks", "default": true, "count": 12, "last_ts": "…",
  "name": { "text": "tasks", "highlights": [] } }
```

### 4.7 `box`

```json
{ "box_id": "box-a", "online": true, "revoked": false, "agents": ["CLE-07"],
  "last_hello_at": "…", "name": { "text": "box-a", "highlights": [] } }
```

## 5. Errors and warnings

### 5.1 Errors

```json
{ "error": "bad_query", "detail": "unbalanced ')'", "pos": 14, "token": ")" }
```

| status | token | when |
|---|---|---|
| 400 | `bad_query` | empty `q`, too long, too many terms, nesting > 8, unbalanced `(` / `)`, unterminated `"`, `OR` with nothing on one side, a lone `-`, an operator with an empty value, a value the operator does not accept (`is:urgent`, `before:yesterday`, `thread:xyz`, `larger:big`), a misplaced or unknown `type:`, operators that apply to no common type, an unknown `sort` |
| 400 | `bad_cursor` | a cursor this API did not mint, or one minted for another `q` / `sort` |
| 401 | `view_door` | the view door (view-v1 §2) |
| 404 | `unknown_tenant` | no tenant for the Host |
| 405 | `method_not_allowed` | anything but `GET` / `OPTIONS` |
| 429 | `rate_limited` | more than **30** searches per minute per (tenant, reader); the reader is the member `HUM-*`, else the client IP (017 FR-SEC-006). `Retry-After` in seconds |
| 503 | `search_budget` | the query exceeded its time budget (**2 s**, Postgres `statement_timeout` set per transaction); narrow the query |

Every answer, errors included, carries the view CORS headers (view-v1 §3)
for an allow-listed `Origin`; the `429` adds
`Access-Control-Expose-Headers: Retry-After` so the browser can read it.
`pos` / `token` are present on `bad_query` only (`pos` is a UTF-16 offset into
`q`, `token` the offending text). Other bodies are `./error-envelope.md`.

### 5.2 Warnings

`200` with `warnings[]` (`token`, `pos`, `detail`) for: an unknown operator
searched as text; a text term with no letter or digit, dropped. Warnings never
change what was searched beyond what they say.

## 6. `GET /v1/view/search/operators`

The grammar as data, generated from the parser's own table (the WUI builds
autocomplete from it and never hard-codes the list):

```json
{ "version": "1.0",
  "types": [ { "type": "message", "group": "messages", "aliases": ["msg", "messages"] } ],
  "operators": [
    { "name": "from", "aliases": [], "values": "id",
      "applies_to": ["message", "thread", "file"],
      "example": "from:CLE-07", "doc": "sender: agent, agent@box, HUM-n or box" },
    { "name": "is", "aliases": [], "values": "enum",
      "enum": { "task": ["message"], "root": ["thread"], "online": ["robot", "user", "box"] },
      "applies_to": ["message", "thread", "robot", "user", "box"], "example": "is:task", "doc": "…" } ] }
```

(`enum` abridged here.) `values` ∈ `text | id | box | enum | date | size |
uuid | channel | ext | type`. Door and CORS as every `/v1/view/*` route; not
rate-limited beyond the edge limits.

## 7. Performance and budget

- Messages: `messages.search_tsv` = `to_tsvector('simple', body)` (generated,
  stored) with a GIN index (rdb `0020_message_search.sql`); files and threads
  read the same tenant's rows through the existing `(tenant_id, …)` indexes.
- Budget: 2 s per search statement (`SET LOCAL statement_timeout`), plus the
  request context. Rate: §5.1.
- Measured (`TestSearchP95`, Postgres 16 in docker, 20,000 messages per
  tenant x 2 tenants, 12 words each, `ANALYZE`d, member viewer, limit 21,
  10 queries x 5 rounds after one warm-up round = n 110 statements, under
  `go test -race` with the hub / store / auth suites running in parallel,
  2026-09-19): **p95 197 – 201 ms** over two runs (messages p95 ≈ 51 ms,
  files ≈ 46 ms, threads ≈ 227 ms: the thread section aggregates every live
  task of the tenant, the slowest part and the first to optimise). Before
  `ANALYZE` on a freshly bulk-loaded table one message query ran past the
  2 s budget and answered `search_budget` (n 1): the budget works, and a
  fresh bulk load needs statistics.

## 8. Not in v1

Saved searches, search inside file **contents**, per-language stemming,
fuzzy / prefix matching (`deplo*`), `label:`, total counts, cross-tenant
search (never).

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T16:45:00Z -->
