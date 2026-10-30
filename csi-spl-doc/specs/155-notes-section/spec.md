# 155 Notes section, with quick links to anything

Version v1.1, 2026-10-24, by c-005@sat (claude). v1.0 (`471c55f24`) was
reviewed by the agy seat a-089: NOT SIGNED, four defects W1-W4
(`fafbb86d0`, `seat-agy.md`). v1.1 folds all four (section 9); it waits
for that seat's re-check.
The owner said "start with implementation" (2026-10-24, t1 topic
`5586fe0e`, msg `ebf3abad`), so there is no owner-question round: every
open choice is a default the owner may change (section 3). One reviewer
from another vendor reads it before build row B1 is placed. Nothing in it
is built.

Source: prd t1 topic `topic:5586fe0e-8230-4f47-b717-b99dc4d20312`. Issue
SPL-3213, epic SPL-2403. Each build row in section 8 gets its own issue
when it is placed. Parent spec: [005 spool WUI](../005-spool-wui/).

Paths used below:

- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`, `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `roles/` = `csi-spl-rdb/src/sql/postgres/spool-hub-roles/`
- `wui/` = `csi-spl-wui/src/`, `wui-tests/` = `csi-spl-wui/tests/`

Every `file:line` below was read on origin/master `2daeaf1fa` with
`grep -n` or `sed -n` on that tree; rows 30-32 (v1.1) on `fafbb86d0`.
Nothing was read from prd.

Builds on, and does not repeat:
[119 personal realm](../119-personal-realm/spec.md) (where the notes are
stored), [022 top-bar search](../022-spool-wui-top-bar-search/spec.md)
(the omnibox), [089 calendar section](../089-calendar-section/spec.md)
(how a rail section is added), [154 contacts](../154-contacts-section/spec.md)
(the newest realm table design). This spec says **workspace**; **tenant**
appears only in code identifiers. Examples use `FirstName LastName` and
`example.com` only.

## 0. The owner's ask, verbatim

HUM-10, prd t1 topic `5586fe0e`, 2026-10-24 (msg `6aae6e3e`):

> "We need an entirely new section for notes, which will work a little bit
> like Google Keep, but one will be able to quickly link anything within
> the system to the notes. It should be like a small task list/notepad,
> which is just a list. When you click each note, it should open. It
> should be extremely helpful to link issues, conversations, anything
> within the system, and also outside links."

Then (msg `ebf3abad`): "start with implementation".

## 1. What exists on master (measured)

### 1.1 Nothing of the feature is built

`git grep -niE 'personal\.notes|note_links' 2daeaf1fa -- csi-spl-rdb
csi-spl-api csi-spl-wui/src` -> no hit. There is no notes table, route,
page or rail entry. Every case in section 7 is red on master today unless
marked (C).

### 1.2 The code this spec stands on

| # | what | measured on `2daeaf1fa` | what it means here |
|---|---|---|---|
| 1 | the rail's tabs | `wui/utils/rail-order.ts:16` `type RailId` (10 ids), `:19` `RAIL_TABS`, one entry per section with `id`, `icon`, `labelKey` (`calendar` :52, `reporting` :63) | Notes is one more entry, `notes` |
| 2 | a rail id the hub does not admit yet | `wui/utils/rail-order.ts:80-90` `RAIL_HUB_PENDING` (empty today); `wireRailOrder` :96-99 drops a pending id from the saved order | the WUI can draw `notes` before the hub admits it; the commit after the hub lands empties the list again |
| 3 | the hub's rail list | `api/internal/auth/handler.go:1003` `var RailTabs` (13 ids, `reporting` last); the CHECK on `humans.rail_order` in `rdb/0209_human_rail_order_reporting.sql:41-42` (`<@` and `@>` the 13) | adding `notes` = one Go list + one migration that redefines the CHECK with 14 ids; the whole precedent is commit `2835ff381` (6 files: `handler.go`, `preferences_test.go`, `rail_order_test.go`, `hours_rls_test.go`, `humans_test.go`, the migration) |
| 4 | a WUI section shell | commit `8708821ac` (Reporting, SPL-2351): `ChannelSidebar.vue`, `utils/sidebar-tabs.mjs`, `utils/section-strip.mjs`, `utils/rail-order.mjs`, `utils/uiIcons.ts`, every locale file, `doc/help/reporting.md`, the rail tests | the file list of B5 |
| 5 | a "rail only" section (the sheet fills the page) | `wui/composables/useSidebarRailOnly.ts:21` `reportingRailOnly`, `:32` `railOnly`; `ChannelSidebar.vue:2` uses them | Notes is rail-only like Calendar and Reporting: the list is the page |
| 6 | the list-then-open pattern | `wui/pages/issues.vue:1-6`: one sheet; above 820 px an opened row is a modal, on a phone a level-3 full screen | the note list opens a note the same way (2.6) |
| 7 | the phone breakpoint | `wui/composables/useMobileStack.ts:32` "the place that decides which panel is on screen at <= 820 px", `:42` `stack.isMobile` | no new breakpoint |
| 8 | the written form of an internal object | `csi-spl-doc/doc/help/how-to-post.md:83-88` rule 11: `msg:<uuid>`, `topic:<uuid>`, linked on the object's workspace host; an unknown workspace stays text | a note link stores a typed ref, never a pasted host (2.3) |
| 9 | how the WUI links a typed ref | `wui/utils/id-links.mjs:37` `TYPED_RE` (`msg` and `topic` only); `:258-264` `resolveTyped` returns `origin + href` from the rows the WUI holds; `:22-23` "No workspace, no link" | the note link opener reuses `resolveTyped` for `msg` and `topic`; the other kinds get their own href builder (2.3) |
| 10 | a workspace's host | `wui/utils/tenant-host.mjs:22` `tenantOrigin(tenant, siteUrl, apexTenant)` | a link into another workspace opens on that workspace's host |
| 11 | an issue's address | `wui/utils/issue-key-links.mjs:39-42`: `<PREFIX>-<n>` opens `/issues?issue=<KEY>`; the prefix is the workspace's (`issueKeyPrefix` :24) | link kind `issue`, ref = the key |
| 12 | a calendar entry's address | `wui/utils/calendar-event-link.mjs:3`: `<origin>/calendar?d=<day>&event=<id>` | link kind `event`, ref = the event id, the day kept with it |
| 13 | a doc's address | `wui/utils/docs.mjs:24` `'/docs/' + path` | link kind `doc`, ref = the doc path |
| 14 | a topic's, a message's and a channel's own pages | `wui/pages/t/[task_id].vue`, `wui/pages/m/[id].vue` (finds the message's place), `wui/pages/channel/[name].vue` | the fallback target for `topic` and `msg` when the row is not in the WUI's lists; a channel link is by name |
| 15 | the message menu | `wui/utils/msg-menu.mjs:67` `msgMenuItems`; `copy` :71, `make-issue` :97; `wui/components/MessageMenu.vue:140-160` `choose(id)` emits one event per id | "Add to note" is one more item and one more emit (B8) |
| 16 | the shortcut keys | `wui/utils/msg-shortcuts.mjs:35-50` `MSG_SHORTCUTS`: H R E A O P B U L C K T M D; `:310-320` `ISSUE_SHORTCUTS`: R E A O P L K M D | `N` is free in both: Shift+N = Add to note |
| 17 | the issue actions | `wui/components/IssueDetailActions.vue:38-46` buttons copy, archive, delete; `wui/components/IssueRowMenu.vue` | "Add to note" goes before Archive (B8) |
| 18 | the other row menus | `wui/components/SidebarRowMenu.vue:138` `type RowItem`, `:230` `choose`; `wui/components/CalendarEventDialog.vue:221-222` the entry's Copy link button | "Add to note" on a channel or topic row and on a calendar entry (B8) |
| 19 | the omnibox | `wui/components/TopBar.vue:1-6` one composer, `/search <q>` opens `/search?q=`; `wui/utils/search.mjs:21` `SEARCH_CMD_RE`, `:136` `omniboxMode(text)` returns `'search'` or `'send'`; `wui/stores/omnibox.ts:5-7` | `/note <text>` becomes a third mode (2.5, B9) |
| 20 | the command palette | `wui/composables/usePaletteItems.ts:40` `PALETTE_GROUPS = ['sections', 'channels', 'people', 'topics', 'docs', 'settings']`, client-side over the stores' lists | a `notes` group over the notes store (B9) |
| 21 | the hub search types | `api/internal/search/grammar.go:31-45`: message, topic, file, robot, user, channel, box, tenant, event, issue | no `note` type: the hub search runs in a workspace scope, notes live in the person scope (2.5) |
| 22 | per-person storage with RLS | `rdb/0168_personal_realm.sql:16-23`: a realm table has `person_id` first (FK to `humans`, ON DELETE CASCADE), no column named `tenant_id`, no FK to a table carrying one, ENABLE + FORCE RLS and one policy `person_scope`; the policy :138-149 (`person_id = app.person_id`, `app.tenant_id` unset, not operator) | the three notes tables follow that rule exactly (section 4) |
| 23 | the realm's grants | `roles/runtime-grants.sql:38-51`: no default privileges in `personal`; each table granted by name | B2 grants the three tables by name |
| 24 | the realm's catalogue test | `store/personal_catalogue_test.go:30-42` pins the exact table list and policy list of `personal` | B2 adds the three tables to both lists |
| 25 | the person scope in Go | `store/rls.go:59` `pgScopePerson`, `:82` `func (s *Postgres) inPerson`; `store/personal_scope_test.go:25` `personCallers`, `:36` `realmTenantCallers` (must stay empty) | B3 names each notes method in `personCallers` |
| 26 | the realm route gate | `hub/realm.go:62-70` `realmCaller`: refuses a workspace header (`tenant_named`) and a `member` query; `:108-123` `realmRefuses`: refuses act-as, a live clone, a non-`HUM-` id, seats that are all agent or time-accountant; it loads the person's seats (`ml.Memberships`, :119) | notes routes use `realmCaller`; the seats give the person's current workspaces (2.4) |
| 27 | realm routes today | `hub/realm.go:431-438` `routeRealm`: `GET /v1/me/realm/settings`, `/profile`, `/receipts`; `hub/channel_order.go:119-120` registers 118's realm hours routes inside `routeMe` | notes routes go under `/v1/me/realm/notes`, registered by one line in `routeMe` |
| 28 | the settings sections | `wui/utils/settings-nav.mjs:6` `SETTINGS_SECTIONS`; the page `wui/pages/settings/[[section]].vue` | Settings -> Notes is one more section (B10) |
| 29 | the next migration | `ls rdb/ \| tail -1` -> `0222_hours_v2_terminals.sql` | `<next>` = 0223 today; each build row fixes its number at build time |
| 30 | the realm's RLS seeds (v1.1, W1) | `store/personal_rls_test.go:274-277` `realmSeedPG` seeds P and Q with a row in every personal table, then `:317` loops over `personalTables`; `store/personal_catalogue_test.go:256` `seedRealm` plants the rows of the policy test | widening `personalTables` without seed rows for the three notes tables fails both tests: B2 seeds them |
| 31 | how a hub flag is read (v1.1, W2) | `api/internal/config/config.go:281-283` struct fields with `env:"SPOOL_HUB_…"` tags; `api/cmd/spool/hub.go:319` builds `hub.Options`; `hub/server.go:42` `type Options struct`; a cnf hub env value, e.g. `csi-spl-cnf/csi-spl/all.env.yaml:748` `SPOOL_HUB_AUTH_NATIVE_ENABLED` | the kill switch is one env var through those three files (section 6) |
| 32 | the help coverage gates (v1.1, W3, W4) | `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs:32` `RAIL_HELP` (every `RAIL_TABS` id needs a help mapping, :117-121) and `:66-69` (every `SETTINGS_SECTIONS` id must be named as `/settings/<id>` in the user settings help); `csi-spl-wui/tests/unit/help-sync.test.mjs` compares `wui/public/help-md/` (with `pages.json`) to `csi-spl-doc/doc/help/`, rewritten by `node src/node/help/sync-help.mjs` | B5 maps `notes` in `RAIL_HELP` and syncs `notes.md`; B10 names `/settings/notes` in `user-settings.md` and syncs it |

## 2. The design

### 2.1 Scope

In: a person's own list of notes, shown in a new rail section **Notes**.
A note is a title, a text and optional checklist lines, plus a list of
links. The list shows pinned notes first; a click opens the note. From
anywhere in Spool a person adds the object on screen (a message, a topic,
an issue, a calendar entry, a doc, a channel) to a note in two clicks or
one key (2.3). A note also holds outside `https://` links. Search inside
Notes, pin, reorder, archive, delete, export and erase.

Out (each can get its own spec): sharing a note with another person, a
note owned by a workspace, colours, labels, images or files in a note,
reminders and due dates, a note in the hub search (`/search`), live
updates between two open tabs (the list refetches on focus instead),
offline editing.

### 2.2 Where a note lives: the person's realm

Default D1 (section 3): a note is its writer's own, and the same list
shows in every workspace the person belongs to. So the notes are stored
in spec 119's realm, schema `personal`, isolated by the `person_scope`
policy (1.2 row 22). An admin, another member and the operator scope read
0 rows. A note survives leaving a workspace; it is erased with the person
(`humans` FK cascade).

### 2.3 A link

A link is a typed ref, never a stored page address:

| kind | ref | its workspace | opens |
|---|---|---|---|
| `msg` | message uuid | yes | `resolveTyped('msg', …)` (1.2 row 9), else `<origin>/m/<id>` |
| `topic` | topic uuid | yes | `resolveTyped('topic', …)`, else `<origin>/t/<id>` |
| `issue` | issue key, e.g. `SPL-12` | yes | `<origin>/issues?issue=<KEY>` |
| `event` | event id + day | yes | `<origin>/calendar?d=<day>&event=<id>` |
| `doc` | doc path | yes | `<origin>/docs/<path>` |
| `channel` | channel name | yes | `<origin>/channel/<name>` |
| `url` | an `https://` or `http://` address | no | that address, in a new tab, `rel="noopener noreferrer"` |

`<origin>` is `tenantOrigin(workspace, …)` (1.2 row 10): a link into
another of the person's workspaces opens on that workspace's host, where
that page's own access check applies. A note never reads an object's
content through the realm: the hub stores the ref and a **label**, and
the page the link opens decides what the person may see.

The label is what the note shows. When a link is added from an object,
the WUI fills it from the object's title (topic subject, issue title,
entry title, doc title, channel name, the first 80 characters of a
message); the person may edit it. Default D4 (section 3): when the person
no longer belongs to the link's workspace, the hub returns that link
without its label and the WUI shows "Link to a workspace you left"; the
stored label is erased by the next write to that note (2.4).

Three ways to add a link:

1. **"Add to note"** on the object: an item in the message menu (Shift+N),
   the issue menus and actions, a channel or topic row's menu, the
   calendar entry dialog and the doc page. It opens a small picker: the
   person's notes, most recently changed first, a filter box, and "New
   note" on top. One click adds the link and shows a toast "Added to
   <title>" with Open. Default D3.
2. **Paste into a note's link box**: a typed ref (`msg:<uuid>`,
   `topic:<uuid>`, rule 11), an issue key of the current workspace
   (`SPL-12`), or a Spool address on a workspace host the WUI knows
   (`/t/<uuid>`, `/m/<id>`, `/issues?issue=<KEY>`,
   `/calendar?d=…&event=…`, `/docs/<path>`, `/channel/<name>`) becomes
   the typed link of the table, its workspace taken from the host. Any
   other `http(s)://` address is a `url` link. Anything else is refused
   with "Not a link". The parser is one pure function,
   `wui/utils/note-links.mjs` `parseNoteLink(text, ctx)`.
3. **The omnibox**: `/note <text>` (2.5).

### 2.4 The hub side

All routes are realm routes (1.2 rows 26-27): `realmCaller`, no
workspace header, the person from the session alone. An act-as clone, an
agent and a time-accountant-only seat are refused (403 `person_only`).

When the hub returns a link, it compares its `workspace_id` with the
person's seats (1.2 row 26, already loaded by `realmRefuses`). A link
into a workspace the person no longer belongs to comes back with
`label: ""` and `left: true`. A PATCH or link write on that note sets the
stored label of each such link to `''` in the same transaction. No
sweeper and no cross-person door: the realm's rule "no realm function may
also open a tenant scope" (`realmTenantCallers`, 1.2 row 25) stays true.

Limits, each a 400 with its code: title <= 200 characters, text <= 20 000,
<= 200 checklist lines of <= 500 characters, <= 100 links of label <= 200
and ref <= 2 048, <= 2 000 notes per person (`notes_full`).

### 2.5 Search, palette and omnibox

- **Inside Notes**: a filter box over the list, client-side over title,
  text, checklist lines and labels (the whole list is in the store; 2 000
  notes is the cap). Archived notes are searched only with the Archived
  filter on.
- **Command palette**: a `notes` group over the notes store (1.2 row 20);
  a hit opens the note.
- **Omnibox**: `/note <text>` creates a note whose title is `<text>` (the
  first 200 characters) and, when the page shows an object (an open topic,
  an open issue, a calendar entry), whose first link is that object. A
  toast "Note created" with Open follows. `omniboxMode` (1.2 row 19)
  returns `'note'` for `/note`, `/n` and `/note:`, each followed by a
  space, a colon or the end of the line.
- **Not in `/search`**: the hub search runs in a workspace scope and the
  notes in the person scope; joining them would need a realm function
  that also opens a workspace scope, which the realm forbids (1.2 row 25).

### 2.6 WUI

- **Rail**: a `notes` tab (a new icon `notes` in `wui/utils/uiIcons.ts`,
  key `sidebar.notes`), rail-only like Calendar (1.2 row 5). A stored rail
  order from before it draws it appended before Archive
  (`parseRailOrder`). Default D5: it goes after Calendar in the default
  order for new members.
- **The list** (`/notes`): "New note" on top, then the filter box, the
  Pinned group, then the rest. Each row: title (or the first line of the
  text when there is no title), up to two lines of text, `3/5` when it has
  checklist lines, a link count, the change date. Order: pinned first,
  each group by the person's own order (drag, or Alt+Up/Down for the
  keyboard); a new note goes on top. A filter "Archived" shows the
  archived ones.
- **Open**: a click (or Enter) opens the note above 820 px as a modal like
  an issue (1.2 row 6), on a phone as a level-3 full screen (1.2 row 7).
  `/notes?note=<id>` opens it directly, so the browser's back and a
  bookmark work. Inside: the title, the text (plain text with the same
  link rendering as a message), the checklist (tick, add, edit, delete,
  drag), the links (label, kind icon, the workspace's name when it is not
  the current one, a remove ×), and the actions Pin, Archive, Delete.
- **Save**: each field saves 800 ms after the last key, and on close; a
  failed save keeps the text and shows "Not saved, retry".
- **Delete**: default D2, delete at once with a 10 s Undo toast; the WUI
  sends the DELETE when the toast ends or the page closes.
- **Phone**: the list is the page; "Add to note" opens the picker as a
  bottom sheet.

### 2.7 i18n

Every new text is a key in `csi-spl-wui/i18n/locales/en.json` and the
same key in every other locale file (developer guide 2.4;
`i18n-parity.test.mjs` refuses a missing key). Keys live under `notes.*`,
plus `sidebar.notes`, `feed.msg_menu.add_to_note` and
`issues_menu.add_to_note`. All of them land in B5, the later rows add
none. agy reviews the locale files as the last step before B5 ships
(language rule); with no agy seat the text waits for that review.

### 2.8 Privacy

- RLS: the three tables carry only `person_scope` (section 4); asOperator
  reads 0 rows.
- Export: `GET /v1/me/realm/notes/export` returns every note of the
  person, archived ones too, as one JSON file (`notes-<date>.json`).
- Erase: `DELETE /v1/me/realm/notes` deletes every note of the person,
  after a typed confirmation in Settings -> Notes.
- Account erase: the `humans` FK cascade (1.2 row 22).
- A link stores no content of the object beyond its label (2.3, D4).
- Logs: a route logs the person id, the note id and the outcome, never a
  title, text, label or URL.

## 3. Defaults (owner may change)

The owner asked to start building without a question round. Each default
below is the simplest sensible choice; changing one changes only the rows
named.

- **D1.** Default (owner may change): a note is personal to its writer,
  and one person has one list, shown in every workspace they belong to
  (the realm, 2.2). No sharing. Per-workspace or shared notes would
  change B2, B3 and B4.
- **D2.** Default (owner may change): Delete removes a note at once, with
  a 10 s Undo; there is no Trash. Archive is the way to keep a note out
  of sight. Changes B6 only.
- **D3.** Default (owner may change): "Add to note" opens a picker of the
  person's notes (latest first) with "New note" on top; it never adds
  silently to a fixed note. Changes B8 only.
- **D4.** Default (owner may change): after the person leaves a
  workspace, links into it stay in the note but lose their label (2.3,
  2.4). Changes B4 only.
- **D5.** Default (owner may change): the Notes tab sits after Calendar
  in the default rail order. Changes B5 only.
- **D6.** Default (owner may change): a note = title + text + optional
  checklist lines; the checklist is a list inside the note, not a note
  type of its own (owner: "a small task list/notepad"). Changes B2, B6.
- **D7.** Default (owner may change): a link is a typed ref per
  how-to-post rule 11, extended with the kinds `issue`, `event`, `doc`,
  `channel` and `url` (2.3). Rule 11 itself is not changed by this spec.
  Changes B2, B7.

## 4. Data

One migration (B2), number fixed at build time:

```sql
CREATE TABLE personal.notes (
    person_id   text        NOT NULL REFERENCES humans(human_id) ON DELETE CASCADE,
    note_id     uuid        NOT NULL DEFAULT gen_random_uuid(),
    title       text        NOT NULL DEFAULT '' CHECK (length(title) <= 200),
    body        text        NOT NULL DEFAULT '' CHECK (length(body) <= 20000),
    pinned      boolean     NOT NULL DEFAULT false,
    position    double precision NOT NULL,
    archived_at timestamptz NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, note_id)
);
CREATE TABLE personal.note_items (
    person_id text NOT NULL REFERENCES humans(human_id) ON DELETE CASCADE,
    note_id   uuid NOT NULL,
    item_id   uuid NOT NULL DEFAULT gen_random_uuid(),
    text      text NOT NULL CHECK (length(text) <= 500),
    done      boolean NOT NULL DEFAULT false,
    position  double precision NOT NULL,
    PRIMARY KEY (person_id, note_id, item_id),
    FOREIGN KEY (person_id, note_id) REFERENCES personal.notes ON DELETE CASCADE
);
CREATE TABLE personal.note_links (
    person_id    text NOT NULL REFERENCES humans(human_id) ON DELETE CASCADE,
    note_id      uuid NOT NULL,
    link_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    kind         text NOT NULL CHECK (kind IN ('msg','topic','issue','event','doc','channel','url')),
    workspace_id text NULL,
    ref          text NOT NULL CHECK (length(ref) BETWEEN 1 AND 2048),
    day          date NULL,
    label        text NOT NULL DEFAULT '' CHECK (length(label) <= 200),
    position     double precision NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, note_id, link_id),
    FOREIGN KEY (person_id, note_id) REFERENCES personal.notes ON DELETE CASCADE,
    CHECK ((kind = 'url') = (workspace_id IS NULL)),
    CHECK (kind <> 'url' OR ref ~ '^https?://'),
    CHECK ((kind = 'event') = (day IS NOT NULL))
);
```

`workspace_id` is plain text with no FK, like `personal.receipt_due`'s
(the realm rule, 1.2 row 22: no FK to a table that carries `tenant_id`).
Each table gets ENABLE + FORCE RLS and the one `person_scope` policy of
0168 (:138-149), and its grant by name in `roles/runtime-grants.sql`
(SELECT, INSERT, UPDATE, DELETE). The 2 000-note cap is checked by the
store in the insert's transaction, not by a trigger.

## 5. Routes

**Built** (B4, SPL-3636): every route below is in `hub/realm_notes.go`,
registered by `routeRealmNotes` from `routeMe` (`hub/channel_order.go`),
cases C10-C16 in `hub/realm_notes_test.go` (memory and Postgres). Wire
names: a list row is `id, title, snippet, pinned, position, archived,
archived_at, updated_at, items_done, items_total, link_count`; a link is
`id, kind, workspace_id, ref, day, label, left, position, created_at`. A
store refusal is 400 `bad_note` (a limit of 2.4), 400 `notes_full` at
2 000 notes; another person's note 404 `not_found`. The export is
`{exported_at, notes}`. Section 6's switch is on in the cnf; the hub's env
reaches Cloud Run through terraform step 030, so a hub served before 030
is applied with it still answers `notes_off` (the binary default is off).

| route | does | answer |
|---|---|---|
| `GET /v1/me/realm/notes` | the list: id, title, the first 200 characters of the body, pinned, position, archived, updated_at, item counts (done/total), link count | 200 |
| `POST /v1/me/realm/notes` | a new note; the body may hold title, body, items, links | 201, the note |
| `GET /v1/me/realm/notes/{id}` | one note with items and links (2.4 for labels) | 200, 404 |
| `PATCH /v1/me/realm/notes/{id}` | title, body, pinned, archived, position | 200, 404 |
| `DELETE /v1/me/realm/notes/{id}` | deletes it; items and links cascade | 204, 404 |
| `PUT /v1/me/realm/notes/{id}/items` | replaces the checklist | 200 |
| `POST /v1/me/realm/notes/{id}/links` | adds one link | 201 |
| `PATCH` / `DELETE /v1/me/realm/notes/{id}/links/{link_id}` | edits the label or position / removes it | 200 / 204 |
| `GET /v1/me/realm/notes/export` | every note as JSON, `Content-Disposition: attachment` | 200 |
| `DELETE /v1/me/realm/notes` | erases every note of the person | 204 |

Another person's note id answers 404, never 403, so a note's existence
is not revealed.

## 6. Kill switch

The hub env var `SPOOL_HUB_NOTES_ENABLED` (v1.1, W2), set in the hub's env
in `csi-spl-cnf/csi-spl/all.env.yaml` like `SPOOL_HUB_AUTH_NATIVE_ENABLED`
(1.2 row 31), `"true"` once B4 lands. It reaches the hub as one field in
`api/internal/config/config.go`, copied into `hub.Options` in
`api/cmd/spool/hub.go`. `false`: every notes route answers 404
`notes_off`. The WUI needs no session claim: when
`GET /v1/me/realm/notes` answers 404 `notes_off`, it hides the tab and the
"Add to note" items. The stored notes stay. Deferred, by name: B5 shows
"Notes are turned off" on `/notes` only; hiding the rail tab and the items
lands with B8, since it needs a notes read at boot that the first screen's
budget (`ci_initial_gzip_kb` 154.9 <= 155 at B5) has little room for.

## 7. Cases

Every case is **planned**. "Master today" is `2daeaf1fa`. Each red
control fails on master today and passes once its row lands; (C) marks a
control that must pass on both. P1 and P2 are two persons, W1 and W2 two
workspaces.

| # | row | case | master today | expected | red control |
|---|---|---|---|---|---|
| C1 | B1 | `auth.IsRailOrder` with `notes` in a 14-id order | refused | admitted | `rail_order_test.go`: the 14-id order fails on today's `RailTabs` |
| C2 | B1 | store a 14-id `rail_order` in Postgres | CHECK violation | stored | `humans_test.go` row; twin: a 15th unknown id still violates |
| C3 | B2 | the migration applies after the latest | tables absent | the three tables, RLS, grants | rdb test: `\d personal.notes` errors today |
| C4 | B2 | `TestRLSPersonalCatalogue` with the three tables | pass | pass (C) | the old table list fails on the new catalogue (`personal_catalogue_test.go:30-33`) |
| C5 | B2 | a note of P2 read under P1's `app.person_id`; under P2's with `app.tenant_id` set; under the operator scope | n/a | 0 rows each | Postgres test; twin: under P2's `app.person_id` alone it is read |
| C6 | B2 | a `url` link with `ref = 'javascript:x'`; a `msg` link with no workspace | n/a | CHECK violation each | Postgres test; twin: `https://example.com` inserts |
| C7 | B3 | store: P2 lists, reads, patches, deletes P1's note | n/a | not found, nothing changed | Go test, memory and Postgres; twin: P1 does each |
| C8 | B3 | the 2 001st note of P1 | n/a | `notes_full` | Go test; twin: the 2 000th inserts |
| C9 | B3 | `TestPersonScopeCallers` with the notes methods | pass | pass (C); `realmTenantCallers` stays empty | without the `personCallers` lines it fails ("inPerson callers: new [...]") |
| C10 | B4 | `GET /v1/me/realm/notes/{P1's id}` as P2, and as an admin of P1's workspace | 404 (no route) | 404 | Go test; twin: P1 gets 200 |
| C11 | B4 | a notes route with the workspace header; from an act-as clone; from an agent | 404 (no route) | 400 `tenant_named`; 403 `person_only` twice | Go test; twin: P1's own session gets 200 |
| C12 | B4 | P1 left W2; a note holds a `topic` link into W2 labelled "Plan" | n/a | GET returns `label: ""`, `left: true`; a PATCH erases the stored label | Go test, memory and Postgres; twin: the link into W1 keeps "Plan" |
| C13 | B4 | a 201-character title; the 101st link | n/a | 400 each | Go test; twin: 200 characters and the 100th link pass |
| C14 | B4 | export, then erase | n/a | the export holds every note incl. archived; erase leaves 0 | Go test |
| C15 | B4 | `SPOOL_HUB_NOTES_ENABLED=false` | n/a | 404 `notes_off` on every notes route; the WUI store reads it as "off" | Go test; twin: true answers 200 |
| C16 | B4 | a route's log line on create | n/a | holds the person and note id, never the title | Go test greps the captured log for the title |
| C17 | B5 | a new member's rail | no Notes tab | `notes` after `calendar` | `rail-order.test.mjs`: today's default order has no `notes` |
| C18 | B5 | an order saved before B5, read back | 10 tabs | `notes` drawn before Archive (no `RAIL_HUB_PENDING`: B1 was live first) | unit test on `parseRailOrder` / `wireRailOrder` |
| C19 | B5 | the i18n parity and raw-text gates | pass | pass (C) | a `notes.*` key missing in one locale fails `i18n-parity.test.mjs` |
| C20 | B6 | click a row; reload `/notes?note=<id>`; Back | n/a | the note opens; reopens; closes | e2e on the mock bundle; twin: an unknown id shows "Note not found" |
| C21 | B6 | delete, then Undo within 10 s | n/a | no DELETE sent, the note stays | e2e counts DELETE requests: 0; twin: no Undo -> 1 |
| C22 | B6 | pin a note | n/a | it moves to the Pinned group | e2e on the mock bundle |
| C23 | B7 | `parseNoteLink` on `topic:<uuid>`, `SPL-12`, `https://<ws host>/t/<uuid>`, `https://example.com/a`, `javascript:alert(1)`, `hello` | n/a | topic, issue, topic (workspace from the host), url, refused, refused | unit test, one row each |
| C24 | B7 | open a `topic` link into W2 from W1 | n/a | opens on W2's host (`tenantOrigin`) | unit test on the href builder; twin: a W1 link stays on this host |
| C25 | B7 | a `url` link's anchor | n/a | `target=_blank`, `rel="noopener noreferrer"` | unit test |
| C26 | B8 | message menu, Shift+N | no item, no key | "Add to note" item; Shift+N opens the picker | `msg-menu.test.mjs`; `msg-shortcuts.test.mjs`: `N` in `MSG_SHORTCUTS` |
| C27 | B8 | "Add to note" on a topic row, an issue, a calendar entry: pick a note | n/a | the note gains a link of that kind and workspace, label = the object's title | e2e on the mock bundle, one per object; twin: "New note" creates a note with that one link |
| C28 | B9 | `omniboxMode('/note buy milk')`, `('/n x')`, `('/notes')` | `'send'` each | `'note'`, `'note'`, `'send'` | `search.test.mjs` |
| C29 | B9 | `/note Plan` on an open issue | n/a | a note "Plan" with that issue as its link | e2e on the mock bundle |
| C30 | B9 | palette, type a note's title | no hit | a `notes` hit that opens it | `palette.test.mjs` |
| C31 | B10 | Settings -> Notes: Export, Erase with the typed confirmation | n/a | a `notes-<date>.json` download; the list empty after Erase | e2e on the mock bundle; twin: a wrong confirmation word erases nothing |

## 8. Build rows

Smallest first. Rows that may run side by side touch no common file; a
later row may edit a file an earlier row created (B7 mounts `NoteLinks` in
B6's `NoteDetail.vue`). B5 adds **every** text key of the feature (2.7),
so no later row touches a locale file and agy reviews the text once.
Each row runs the gate of the tree it touches (repo CLAUDE.md) and lands
its docs or a `Docs: none (<why>)` line.

| row | does | files | cases | after |
|---|---|---|---|---|
| B1 | the hub admits `notes` in the rail order | `api/internal/auth/handler.go` (`RailTabs`), `api/internal/auth/rail_order_test.go`, `api/internal/auth/preferences_test.go`, `store/humans_test.go`, `store/hours_rls_test.go`, `rdb/<next>_human_rail_order_notes.sql` (the `2835ff381` precedent) | C1, C2 | - |
| B2 | the three realm tables | `rdb/<next>_personal_notes.sql`, `roles/runtime-grants.sql`, `store/personal_catalogue_test.go` (the lists and `seedRealm`), `store/personal_rls_test.go` (`realmSeedPG`, v1.1 W1) | C3-C6 | B1 (migration order) |
| B3 | the notes store, memory and Postgres | `store/personal_notes.go`, `store/personal_notes_memory.go`, `store/personal_notes_test.go`, `store/personal_scope_test.go` (`personCallers`) | C7-C9 | B2 |
| B4 | the realm routes, the kill switch, labels after a leave | `hub/realm_notes.go`, `hub/realm_notes_test.go`, `hub/channel_order.go` (one line in `routeMe`), `hub/server.go` (`Options`), `api/internal/config/config.go`, `api/cmd/spool/hub.go` (v1.1 W2), `csi-spl-cnf/csi-spl/all.env.yaml` (+ its tpl-gen output); docs: section 5 of this spec marked built | C10-C16 | B3 |
| B5 | WUI section shell: rail entry, `/notes` list page, notes store, i18n keys, help page | `wui/utils/rail-order.ts` (no `RAIL_HUB_PENDING`: B1 was live first; `rail-order.mjs` is gone, the `.ts` is the one file), `wui/utils/sidebar-tabs.mjs`, `wui/types/mjs-shims.d.ts` (`NOTES_TAB`, the `tabForPath` / `routeForTab` types), `wui/composables/useSidebarRailNav.ts` (the rail click opens `/notes`; the navigation moved there from `ChannelSidebar.vue` in r19-01), `wui/utils/uiIcons.ts`, `wui/composables/useSidebarRailOnly.ts`, `wui/components/ChannelSidebar.vue`, `wui/pages/notes.vue`, `wui/stores/notes.ts`, `csi-spl-wui/i18n/locales/*.json`, `csi-spl-doc/doc/help/notes.md` + its synced copy `wui/public/help-md/notes.md` and `wui/public/help-md/pages.json` (`node src/node/help/sync-help.mjs`), `wui-tests/unit/help-settings-coverage.test.mjs` (`RAIL_HELP`, v1.1 W3), `wui-tests/unit/rail-order.test.mjs`, `wui-tests/e2e/rail-order-default.test.mjs` | C17-C19 | B4 for live data (the mock serves before) |
| B6 | the open note: editor, checklist, pin, archive, delete + Undo, order | `wui/components/NoteDetail.vue`, `wui/components/NoteChecklist.vue`, `wui/utils/note-order.mjs`, their tests | C20-C22 | B5 |
| B7 | links: parse, render, open. **Implemented** (SPL-4330, landed sha: [5039f423b](https://github.com/csitea/csi-spl/commit/5039f423bba40ae2bb427a70b3ecb59e659cc1af)): also the store's `addLink` / `removeLink` (`wui/stores/notes.ts`), `NoteLinks` mounted in `NoteDetail.vue`, the issue prefix read shared from `wui/utils/issue-links-install.ts`, the types in `wui/types/note-links.d.ts`, the e2e in `wui-tests/e2e/notes-open.test.mjs` (1440 and 390 px), help `notes.md`; no new text key. Not built in B7 (dispatch c-002, msg 40cd06a0): editing a link's label (2.3 "the person may edit it"); the hub's `PATCH .../links/{link_id}` exists, the WUI has no control for it | `wui/utils/note-links.mjs` (`parseNoteLink`, the href builder), `wui/components/NoteLinks.vue`, `wui-tests/unit/note-links.test.mjs` | C23-C25 | B6 |
| B8 | "Add to note" everywhere + the picker; on `notes_off` the rail tab and the items hide (section 6) | `wui/utils/msg-menu.mjs`, `wui/components/MessageMenu.vue`, `wui/utils/msg-shortcuts.mjs`, `wui/components/IssueRowMenu.vue`, `wui/components/IssueDetailActions.vue`, `wui/components/SidebarRowMenu.vue`, `wui/components/CalendarEventDialog.vue`, `wui/components/AddToNotePicker.vue`, `wui-tests/unit/msg-menu.test.mjs`, `wui-tests/unit/msg-shortcuts.test.mjs`, a new e2e | C26, C27 | B7 |
| B9 | `/note` in the omnibox, the palette's `notes` group | `wui/utils/search.mjs` (`omniboxMode`), `wui/components/TopBar.vue`, `wui/composables/usePaletteItems.ts`, `wui-tests/unit/search.test.mjs`, `wui-tests/unit/palette.test.mjs` | C28-C30 | B7 |
| B10 | Settings -> Notes: export and erase | `wui/utils/settings-nav.mjs`, `wui/pages/settings/[[section]].vue`, `wui/components/SettingsNotes.vue`, `csi-spl-doc/doc/help/user-settings.md` + its synced copy `wui/public/help-md/user-settings.md` (names `/settings/notes`, v1.1 W4), a new e2e | C31 | B5 |

**B10 Implemented** (SPL-4331, the `feat(wui, SPL-4331)` commit): the files moved with the code. A section is `wui/components/settings/<id>.vue` behind one lazy import in `wui/components/SettingsDialog.vue` (the B8 precedent of spec 149), so `SettingsNotes.vue` is `wui/components/settings/notes.vue`; `pages/settings/[[section]].vue` only keeps the old route and is unchanged. The calls are `wui/utils/notes-data.mjs` (on the mock bundle they go through the notes store's own load / get / remove, so `stores/notes.ts` is untouched). Two new keys, `notes.settings.export_failed` and `notes.settings.erase_failed`, in all 19 locales (drafts for the language review). Tests: `wui-tests/unit/settings-notes.test.mjs`, `wui-tests/e2e/settings-notes.test.mjs` (C31 with its wrong-word twin, 1440 and 390 px).

Only B5 changes locale files: agy reviews them last (2.7). B5 to B10 are
WUI rows: never placed on mistral (developer guide 4.1). B8 and B9 both
come after B7 and touch no common file, so they may run side by side.

The rail entry is off until the CRUD rows are live (owner HUM-10, 2026-10-29,
t1 `cb9d7bdc`, msg `cdf216a0`: "hide the notes section in the UI until the
CRUD has been completed"; SPL-4219). One line turns it back on:
`export const NOTES_RAIL_ON: boolean = false` in
`csi-spl-wui/src/utils/rail-order.ts`, set to `true`. While it is off no
person's rail draws Notes, a stored order that lists it is drawn without it,
a saved order still carries `notes` for the hub (`RAIL_SWITCHED_OFF`,
`wireRailOrder`), and `/notes` stays reachable by URL. `rail-order.test.mjs`
runs the Notes cases with the switch on and the shipped module with it off;
`rail-order-default.test.mjs` follows the shipped value.
The same switch keeps the Notes page out of the Help list
(`helpPageListed` in `rail-order.ts`, used by `pages/help/[[page]].vue`), so
Help does not send people to a tab that is not drawn; `/help/notes` still
opens by URL and its text is unchanged for the day the tab comes back.
It also keeps the Notes section out of the Settings list and the command
palette (`settingsSectionListed` in `rail-order.ts`, used by
`SettingsDialog.vue` and `usePaletteItems.ts`; SPL-4331, B10);
`?settings=notes` and `/settings/notes` still open it by URL.

## 9. Review record

- v1.0 `471c55f24`: agy seat a-089, NOT SIGNED at `fafbb86d0`
  (`seat-agy.md`, msg `1b611787`). It confirmed the 29 code facts, the
  privacy design and C1-C31, and found four missing files:
  - W1: B2 lacked the seed rows in `store/personal_rls_test.go`
    (`realmSeedPG`) and `seedRealm`. Folded: B2's files, 1.2 row 30.
  - W2: B4 lacked the flag's plumbing. Folded: section 6 is now one hub
    env var through `config.go`, `cmd/spool/hub.go` and `hub.Options`; the
    WUI reads the 404 instead of a session claim, so no auth file is
    touched. B4's files, 1.2 row 31, C15.
  - W3: B5 lacked `RAIL_HELP` in `help-settings-coverage.test.mjs` and the
    synced help copy. Folded: B5's files, 1.2 row 32.
  - W4: B10 lacked `/settings/notes` in `user-settings.md`. Folded: B10's
    files, 1.2 row 32.
- v1.1: waits for the same seat's re-check.
