# 119 addition: my calendar across workspaces

**Status**: v0.1 draft, 2026-11-15, c-203 (SPL-5599, epic SPL-2396). Docs
only: builds nothing. Owner questions in section 11, unanswered. Draft build
rows: [tasks.md](tasks.md), section "Calendar across workspaces".
Topic: t1 #spool-hub-ui `26b46de6-28b4-4bdf-93f2-c85346f2a13d`.

Part of [119 personal realm](spec.md) (section 15 links here). Builds on,
and does not repeat: [089 calendar](../089-calendar-section/spec.md) (event
object, audience, reminders), [097 full editing](../097-calendar-full-editing/spec.md)
(guests, recurrence, colour, trash), [149 Google Calendar connect](../149-google-calendar-connect/spec.md),
[118 multi-workspace hours](../118-multi-workspace-hours/spec.md) sections
5.2 and 7 (the read and the write across workspaces this copies).

Prose says **workspace**; **tenant** appears only in column, code and header
names.

## 0. The owner's words

HUM-10, t1 #spool-hub-ui, 2026-11-15:

> "The calendar entries for each user should be global between all of the
> workspaces." (13:29:21Z)
>
> "That is, I should be able to see all of my calendar entries in one place
> regardless of how many workspaces I do have access to." (13:29:52Z)

Read as: one **personal view** of the person's own entries from every
workspace they belong to. Each entry stays in, and is governed by, its own
workspace. Nothing becomes a "global" row: a cross-workspace event table
would break the workspace isolation every calendar rule rests on (section 1).

## 1. Facts from the code (origin/master `a6dd716b3`, read, not run)

| fact | check | so |
|---|---|---|
| An event belongs to one workspace: `calendar_events.tenant_id NOT NULL`, FORCE RLS `tenant_scope` on `app.tenant_id` | `csi-spl-rdb/src/sql/postgres/spool-hub/0125_calendar.sql` lines 21, 49..51 | the view reads each workspace in its own scope; no row moves |
| Every calendar read runs in one workspace scope | `store/calendar_postgres.go` `calendarQuery` -> `queryTenant` | one read per workspace, as 118 5.2 |
| The private filter is one expression in the store | `calendar_postgres.go:35` `calendarPrivateSQL`: `audience <> 'private' OR creator_id = viewer OR viewer = ANY (mentions)` | "mine" narrows it, never widens it (section 3) |
| Audiences today: `public` (signed-out visitors), `workspace` (default), `internal`, `private` | rdb `0161_calendar_web_to_public.sql` (the 0159 rename) | a guest or demo seat in a workspace still gets no `internal` item there |
| Guests are a subset of `mentions` | 097 section 3.2 | `viewer = ANY (mentions)` covers guests; GIN index `calendar_events_mentions` (0125 line 42) |
| An event has a responsible `owner_id` beside `creator_id` | rdb `0247_calendar_event_links.sql` | "mine" can include "I own it" |
| A person is one `HUM-*` id in every workspace | 118 5.1; `store/rls.go` `personIDRe` | no id mapping |
| The person's workspaces: `Memberships(ctx, human)`, the one allow-listed operator read; it already drops a disabled membership, a disabled human and a membership past `access_until` | `store/memberships.go` line 51 (`h.disabled_at IS NULL AND m.disabled_at IS NULL`), rdb 0113 | no new operator read; leavers fall out by themselves (section 7) |
| The person scope is built: `inPerson`, `pgScopePerson`, rdb 0168 | `store/rls.go` lines 56..75; 119 tasks T001..T004 `[x]` | the realm pieces this needs (only under Q3 `3a`) sit on built ground |
| 118's cross-workspace read is built: at most 20 workspaces (400 `too_many_workspaces`), a failed one `unavailable`, 403 `person_only` under act-as | `hub/realm_hours_read.go` lines 23..50, 178..193 | the calendar read reuses the same shape and limits |
| Calendar routes read the session's **active** workspace; `X-Spool-Tenant` is for boxes | 089 6.1; 118 5.1 (`hub/resolve.go`) | the existing routes cannot reach a second workspace: the view needs realm routes that name the workspace per call (sections 4, 5) |
| Google Calendar imports are per member **per workspace** connection, stored as that member's `private` events in that workspace | 149 sections 2.1, 2.10 B (`source_key gcal:<connection>:src.<hash>.<google id>`) | a person connected in two workspaces holds the same Google event twice (section 6, Q5) |
| Reminder pop-ups read the active workspace only | 089 4.3, `GET /v1/calendar/reminders`; `csi-spl-wui/src/utils/calendar-reminders.mjs` | reminders across workspaces are a choice (Q4) |
| One list read returns at most 2000 events | `store/calendar.go:278` `calendarMaxEvents` | per-workspace cap in the view (section 9) |
| No workspace colour exists | `grep -rln "workspace_color\|workspaceColor\|tenantColor" csi-spl-wui/src csi-spl-api/src/go/spool-hub-api/internal` -> none | the source marker is new (Q3) |
| Initial JS: ceiling 155 KB gzip, last metric 153.4 KB | `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json` `ci_initial_gzip_kb` | the page adds 0 bytes to first paint (section 9) |

`store/` and `hub/` are under `csi-spl-api/src/go/spool-hub-api/internal/`.

## 2. The view

A realm page, **My calendar** (`/me/calendar`), one lazy chunk. It shows the
signed-in person's own entries (section 3) from every workspace in
`Memberships(caller)`, merged on one grid, each marked with its workspace
(section 3.2). Week, month and agenda views as the workspace calendar has
(089 2, 097 5.1). Entry points: the person menu; an "All my workspaces" link
in each workspace's calendar header for a person with 2+ workspaces. The link
carries nothing from the other workspaces into the workspace page.

With one workspace the page shows that workspace's own entries. With none it
says where entries come from.

## 3. Which entries count as "mine"

### 3.1 The rule (recommended, Q1 `1a`)

An event E of workspace W is **mine** for person P when, inside W's scope:

- P made it (`creator_id = P`), or
- P is its responsible owner (`owner_id = P`, rdb 0247), or
- P is a guest or `@`-mentioned on it (`P = ANY (mentions)`; guests are a
  subset, 097 3.2), or
- (Q1 `1a` only) it is an issue deadline (089 4.1) of an issue in W assigned
  to P.

Not mine: a `workspace`, `internal` or `public` event P can merely read.
Official days are not shown (they are a workspace's region tint, 089 4.1,
and two regions would clash). A Google import (149) is P's own private event
in W, so it counts.

The store gets one predicate, added with AND after the private filter:
`(creator_id = $2 OR owner_id = $2 OR $2 = ANY (mentions))`. Every event it
returns already passes `calendarPrivateSQL` for the same viewer, so the view
can never show an event the workspace calendar would hide from P.

### 3.2 Each entry keeps its workspace

- **Saved in its own workspace.** Nothing is copied into the realm: no
  `personal.*` table holds an event, a title or a time. The view is a live
  read (section 4); reload it and it reflects each workspace's current rows.
- **Marked with its workspace.** Every chip carries its workspace's colour
  bar (Q3) and the pop-over names the workspace. The event's own colour (097
  3.3 `props.color`) stays the chip fill, so both read at once.
- **Identity** is the pair `(workspace_id, event_id)`, never `event_id`
  alone, on the wire and in the WUI store.
- **Edit opens that workspace's rules** (section 5): who may edit (089 4.2,
  097 4.5 `notes.send`), owner-only `private`, guests from that workspace
  only, its trash and undo. A rule a workspace has is never relaxed, and a
  workspace never learns that the change came from the personal view.

## 4. The read path, RLS unchanged

`GET /v1/me/realm/calendar/events?start=<ISO>&end=<ISO>`

- **Who**: human session only. 403 `person_only` under act-as (spec 054), for
  an agent and for a box token; 400 on an `X-Spool-Tenant` header, a
  `member=` or a `workspace=` parameter. The person is the session's human,
  never a request field (119 7.2).
- **Window**: `start < end`, at most 62 days (a month grid with its spill
  is 42), the 118 5.2 bound.
- **Which workspaces**: `Memberships(caller)`; at most 20, a 21st is 400
  `too_many_workspaces`, never dropped. No new operator-scoped read
  (`TestOperatorScopeCallers` gains nothing).
- **How**: for each workspace W, the existing `ListCalendarEvents(ctx, W,
  caller, range)` in W's own workspace scope with the "mine" predicate on
  (3.1), recurrence expanded as today (`calendarWithSeries`). For a seat whose
  role in W is guest or demo, the hub drops `internal` items as the
  workspace route does. At most **2 workspaces in flight** (the 118 bound,
  pool 8). Never `asOperator`, never `app.rls_scope = operator`.
- `app.person_id` is never set in a calendar transaction: the read touches no
  realm table, except the Q3 `3a` preference row, read in its own `inPerson`
  transaction.
- **A failed workspace** (store error, timeout, membership removed
  mid-request) comes back as `{"workspace_id": W, "state": "unavailable"}`,
  never a silent empty list and never retried under a broader scope.
- **Answer**: `{"start","end","workspaces":[{"workspace_id","name","state"}],
  "events":[event + "workspace_id"]}`, events by `starts_at`, then
  `workspace_id`, then `id`. The event object is 089 6.1.1 plus
  `workspace_id`. Mention and guest names are resolved inside W's read only.
- **Year strip**: `GET /v1/me/realm/calendar/marks?start_year=&end_year=`,
  at most 3 years (089's strip), the same fan-out over `CalendarMarks`; dots
  per day with the workspaces that have one.
- Nothing is written by a read; no log line carries a title or a description
  (workspace id, counts and timings only).

## 5. Writing from the view (Q2)

Under Q2 `2a` (recommended):

- **Edit, move, resize, delete, restore, RSVP**:
  `PATCH|DELETE /v1/me/realm/calendar/{workspace_id}/events/{id}`,
  `POST .../{id}/restore`, `POST .../{id}/rsvp`. The hub checks
  `workspace_id` is in `Memberships(caller)` (else 403 `not_a_member`, nothing
  read or written), then runs the **same** store call and the same checks as
  the workspace route, in W's own workspace scope: `If-Match` (097),
  owner-only `private` (089 4.2), the edit permission, edit scopes of a
  series (097 4.4), guest notices (097 4.5). One handler body serves both
  routes, taking the workspace as an argument, so the rules cannot drift.
- **Create**: `POST /v1/me/realm/calendar/{workspace_id}/events`. The
  dialog asks for the **workspace first** (chips of the person's workspaces;
  preselected: the last one used, else the one the person came from).
  Guests, mentions, topic and issue links are offered from that workspace
  only (`GET /v1/me/realm/calendar/{workspace_id}/people?q=` in W's scope);
  changing the workspace clears them.
- **No move between workspaces.** An event's workspace cannot change: moving
  it is a delete in A and a create in B, two visible writes (118 7.4).
- Drag across days in the merged grid writes only to that event's workspace.

Under `2b` the view is read-only plus RSVP and every edit opens the event in
its workspace's calendar (switching the active workspace); under `2c` it is
read-only.

## 6. Google Calendar imports (149)

- 149's connections stay per member per workspace; this spec changes no
  sync. The out half ("Spool Hub" calendar) keeps sending each workspace's
  events from that workspace's connection.
- A Google event P imports through connections in A and B is two private
  rows (one per workspace) with the same calendar hash and Google id at the
  end of `source_key`. Under Q5 `5a` (recommended) the view shows it
  **once**, marked "Google", listing the workspaces it came through; an edit
  goes to the copy of the first listed workspace and the next sync carries
  the change through Google to the other. Under `5b` each copy shows with its
  workspace.
- Match key: `src.<12 hex>.<google id>` (the part after
  `gcal:<connection>:`), compared only among P's own rows. No new column.

## 7. Leavers and lost access (119 D4)

A calendar entry is workspace **content** (title, description, people), so
119 REQ-4/5 and 118 D4 apply: a leaver keeps hours receipts, never content.

| change | the view |
|---|---|
| removed or banned | W's entries are gone on the next read (`Memberships` drops W); no copy, no realm row |
| `access_until` passes | gone at that instant (rdb 0113, `Memberships`) |
| membership disabled (rdb 0074) | gone while disabled, back when enabled; nothing copied either way |
| workspace deleted | gone (the 0125 cascade) |
| rejoin | back, as live rows |

An event P made in W stays in W after P leaves, under W's rules (089: the
owner does not move). A person who wants their own copy exports before
leaving (097 4.9); the view builds no export of its own.

## 8. Privacy

- The view is P's only: no route reads another person's view; a foreman, an
  admin or the owner of a shared workspace has none (119 9 C2, T-N8 shape).
- **A private entry never leaks**: each workspace's read keeps
  `calendarPrivateSQL` (section 1), and "mine" only narrows it (3.1). A
  private event of W1 reaches P only, and only because P made, owns or is
  named on it.
- **Nothing flows down** (119 REQ-6, 9 C7): no workspace route, Flow item,
  reminder, export, free/busy or log line of W1 carries anything of W2. In
  particular W1's calendar never shows P as "busy" because of a W2 event.
- **The WUI keeps the two apart**: the personal view has its own store keyed
  by person, cleared on sign-out; the workspace calendar store never receives
  a personal-view item, so a workspace page cannot render another
  workspace's event.
- Names: a person or agent named on a W1 event is resolved in W1's read; the
  view never shows a W1 member's name for a W2 event.

## 9. Phone, desktop, performance

**Desktop (> 820 px)**: the merged grid; a row of workspace chips above it
(colour, name, a count for the window) that toggles a workspace on or off in
the view (remembered per person, Q3); an unavailable workspace is a grey chip
"could not be read, retry". The pop-over shows the workspace first, then the
089 / 097 details.

**Phone (<= 820 px, 360 and 390 px)**: agenda by day by default (the 097 5.1
list), each row with the workspace colour bar and name; the workspace chips
wrap, never scroll sideways; the event opens the 097 sheet; controls 44..48
px; swipe for the previous or next week.

**Budgets**

- Initial JS: **+0 KB**. The page and its store are a lazy route chunk; the
  grid comes from the calendar chunk the workspace page already loads (089 3,
  `defineAsyncComponent`). Gate: `perf-budget.py` (155 KB ceiling, metric
  153.4 KB: there is no room).
- Hub: 1 `Memberships` read + 1 workspace-scoped read per workspace (at most
  20), 2 in flight, each the existing indexed range read
  (`calendar_events_tenant_range`, `calendar_events_mentions`). A counting
  test pins the transaction count (1 + N) and that no transaction sets both
  `app.tenant_id` and `app.person_id`.
- Answer size: at most 2000 events per workspace (`calendarMaxEvents`); a
  workspace that hits it is marked `truncated` in its `workspaces[]` entry,
  never silently cut.
- Latency: measured first (`csi-spl-doc/doc/md/lesson-speed-up-measure-first.md`).
  The build lane records the p95 of `GET /v1/calendar/events` for one
  workspace and of the new route for 1, 5 and 20 workspaces (n >= 12 each),
  and sets the ceiling from that measurement. Target before measuring:
  5 workspaces within 3x the single-workspace p95 (2 in flight).

## 10. Tests (for the build rows; Postgres, runtime role)

- **T-CAL1** "mine": in W, P sees events P made, owns, is a guest of and is
  mentioned on; P does not see a `workspace` event of Q's. Red control: drop
  the predicate, P's list grows.
- **T-CAL2** private never leaks: Q's private event in W (P neither owner nor
  named) is in no answer of P's. Red control: drop `calendarPrivateSQL` from
  the per-workspace read.
- **T-CAL3** scopes: a store spy shows one transaction per workspace with one
  `app.tenant_id` each, none with `app.person_id` alongside, none operator.
- **T-CAL4** routes: 403 `person_only` under act-as, for an agent, a box
  token; 400 on `X-Spool-Tenant`, `member=`, `workspace=`; 400 on a 63-day
  window and on a 21st workspace.
- **T-CAL5** leavers: after removal, after `access_until`, while disabled,
  W's events are absent; after re-enable they return.
- **T-CAL6** unavailable: a stubbed failure in W returns W `unavailable` and
  the others' events.
- **T-CAL7** writes (Q2 `2a`): a write to a W not in `Memberships` is 403
  `not_a_member` and writes nothing; a non-owner setting `private` through the
  realm route is 403 as on the workspace route (one handler, both routes).
- **T-CAL8** guest seat: a guest or demo seat in W gets no `internal` item of
  W in the view.
- **T-CAL9** Google (Q5 `5a`): one Google event imported in A and B shows
  once with both workspaces.
- **T-CAL10** nothing flows down: W1's workspace calendar, reminders and
  marks for P are byte-identical with and without P's W2 events.
- **e2e** at 390 px and desktop: the merged agenda, the chips, the sheet.

## 11. Questions for the owner

Each with lettered options, the recommended one first. Keys at most 3
characters.

**Q1. What counts as "my" calendar entry?**
- `1a` (recommended): events I made, own, am a guest of or am @mentioned on,
  plus deadlines of issues assigned to me.
- `1b`: the same without issue deadlines.
- `1c`: only events I made or own.
- `1d`: everything I can read in each workspace (every workspace calendar
  merged).

**Q2. Can I create and edit entries from the personal view?**
- `2a` (recommended): yes, under that workspace's own rules; a new entry asks
  for the workspace first.
- `2b`: read and answer invitations only; editing opens the event in its
  workspace's calendar.
- `2c`: read only.

**Q3. How is each entry's workspace shown?**
- `3a` (recommended): each workspace gets a colour (picked automatically; I
  may change it and hide a workspace in my view; kept in my personal realm,
  the same on every device), plus the workspace name in the details.
- `3b`: the workspace name as a text label only, no colour.
- `3c`: a colour per workspace set by that workspace's admin, the same for
  everyone.

**Q4. Reminder pop-ups across workspaces?**
- `4a` (recommended): I get the pop-ups of all my workspaces' entries,
  whichever workspace is open.
- `4b`: as today, only the open workspace's.

**Q5. A Google Calendar event that comes in through two workspaces?**
- `5a` (recommended): shown once, marked with both workspaces.
- `5b`: shown twice, once per workspace.

Under `3a` the realm gains one table, `personal.calendar_prefs (person_id
PK, prefs jsonb <= 4 KB)` holding `{workspace_id: {color, hidden}}`, in the
rdb 0225 shape (FK to `humans`, no `tenant_id`, the 0168 `person_scope`
policy, named grants). Under `4a` the WUI's reminder timer reads
`GET /v1/me/realm/calendar/reminders?from=&to=` (at most 31 days, the same
fan-out over `CalendarReminders`) instead of the workspace route.

## 12. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-11-15 | c-203 | draft: view, "mine", workspace kept, read and write paths, Google duplicates, leavers, privacy, phone and desktop, budgets, tests, Q1..Q5 |

<!-- version: 0.1.0 · updated: 2026-11-15 -->
