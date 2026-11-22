# 097 Calendar: full editing, Google Calendar style

Status: **v1.0, 2026-11-19: section 11 (event tags, SPL-5883) is a draft for review.** Before it, **v0.4, 2026-10-06: mobile-first specification added and approved.** The owner
approved the v1 feature list (section 0.1, E1..E3), answered Q1..Q9 "as proposed"
(section 10, msg `92b3e0d6`), and approved the mobile-first feature list and rule in
t1 52aee116 (HUM-10 msg `adf16567`, "look good . go"). Mobile-first section 5.1 defines
phone layout, touch interactions, and 360/390 px acceptance checks for all 10 features, with
open owner questions M1..M5. Building may start (tasks.md).
Topic: t1 `70484be0-ed1d-4fc0-bebb-44874cc2661e` (owner HUM-10, msg
`88405d88`). Author: c-397.
Builds on, and does not repeat: [089 the Calendar section](../089-calendar-section/spec.md)
(the section, the event object of 6.1, audience, pop-up reminders);
spec 098 workspace settings jsonb (t1 `29b19f85`, in progress: the
jsonb-plus-promotion rule this spec reuses for event properties);
[095 Web Push](../095-web-push/spec.md) (a later reminder channel);
[062 per-user Flow](../062-flow-per-user-counts/spec.md) (where an invitation
lands for a human).

`<BASE_DOMAIN>`, `<workspace_id>`, `<human_id>`, `<agent_id>` are
placeholders. Prose says **workspace**; **tenant** appears only in column,
code and header names.

## 0. Why

The owner, verbatim (HUM-10, t1 `70484be0`, msg `88405d88`):

> "improve the possible set of calls to the calendar api to enable full gmail
> like style of editing of calendar entries ..."

089 shipped a deliberately small event model: one event, one time range, one
reminder time, `@mentions` without answers, hard delete. 089 section 11 put
recurrence, invitations and RSVP out of scope; this owner order brings them
in. This spec lists what Google Calendar's editor lets a person do, what the
spool calendar can do today, and the calls, columns and screens that close
the gap, each as one small build task (`tasks.md`).

### 0.1 Owner decisions on the v1 list (2026-10-06)

Owner HUM-10 on t1 `70484be0`, verbatim. These override anything else in
this file.

| # | msg | Owner text | What it decides |
|---|---|---|---|
| E1 | `74b55a55` | "1 Drag to move and resize ... yes. [...] 3 Repeating events ... yes 4 Undo delete ... yes 5 Guests who answer ... yes [...] 7 Search ... yes 8 Quick add ... yes 9 Duplicate ... yes 10 Export ... yes" | Items 1, 3, 4, 5, 7, 8, 9 and 10 of section 6 are in v1 as written. |
| E2 | `74b55a55` | "2 Several reminders [...] should be able to type how many an dwhat - minutes , hours, days" | A reminder is a typed number and a unit, minutes, hours or days before the event; the person adds as many as they want, up to 5 (section 4.3). |
| E2 | `68ac36bd` | "yes only whole number accepted" | The number is a whole number, 1 or more; `1.5` or `0` is refused. |
| E3 | `74b55a55` | "6 Event details Location, video-call link with a Join button( not needed) , colour, time zone per event, now need to change the status based on busy or free." | Location, colour and time zone per event stay in v1. |
| E3 | `68ac36bd` | "on 6 - yes no need [...] no need for video call link - too much glutter" | **Dropped:** the video-call link and its Join button, and busy / free. |

## 1. Measured before (tree `bb135572d`)

| fact | check |
|---|---|
| six calendar routes, three reads and three writes | `grep -c 'mux.HandleFunc("[A-Z]* /v1/calendar' csi-spl-api/src/go/spool-hub-api/internal/hub/calendar.go` -> 10, of which 4 are `OPTIONS` |
| the create / PATCH body is eleven fields, unknown fields refused | `calendarRequest` in `internal/hub/calendar.go`; `dec.DisallowUnknownFields()` |
| one reminder per event, a time, no lead or channel | `calendar_events.remind_at timestamptz NULL` in `rdb/0125_calendar.sql` |
| `@mentions` widen a private event's readers, no answer is stored | `mentions text[]`, GIN index `calendar_events_mentions` |
| delete is a hard `DELETE` | `DeleteCalendarEvent` in `internal/store/calendar_postgres.go` |
| no recurrence, location, colour, time zone | none of them in `rdb/0125_calendar.sql` |
| the WUI main view is still 089 T007's placeholder week | `wc -l csi-spl-wui/src/components/CalendarMainView.vue` -> 145; 089 `tasks.md` T008 (dialog, drag, Day/Week/Month) is open |
| a human already stores a display time zone | `time_zone` in the preferences of `internal/auth/handler.go` |
| next free migration number | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -1` -> `0134_fleet_load_box_bands.sql`; 098 takes the next one, so this spec says `rdb/NNNN` and the build lane takes the next free number |

**Backward compatibility is a rule of this spec, not a wish.** c-394 is
adding an "Add to calendar" message action that calls today's
`POST /v1/calendar/events` with today's body. Every change below is additive:
the eleven 089 fields keep their meaning, an old body still answers `201`
with an event object that is a superset of 089 6.1.1, and `remind_at` keeps
working (section 4.3).

## 2. Gap analysis against Google Calendar

| # | Google Calendar can | spool today | v1 of this spec | later |
|---|---|---|---|---|
| G1 | move and resize by drag | `PATCH` with `starts_at`/`ends_at` works; no drag UI (089 T008 open) | drag + resize in the WUI, conflict-safe `If-Match` | |
| G2 | repeat: daily, weekly on days, monthly, yearly, custom, until / count | none | RRULE subset, expanded by the hub | full RFC 5545 RRULE, RDATE |
| G3 | edit or delete "this / this and following / all" | none | `scope=this\|following\|all` on PATCH and DELETE | |
| G4 | guests (people) with Yes / No / Maybe | `@mentions`, no answer | `guests` with RSVP, members **and** agents | optional guests |
| G5 | invitation and update notices to guests | nothing is sent (089 D4) | an in-app notice per invite, change, cancel, with "notify guests?" | e-mail notice |
| G6 | several reminders, "10 min before", pop-up or e-mail | one `remind_at` time, pop-up only | up to 5 reminders, a whole number of minutes, hours or days before (E2), `popup` | `push` (095), `email` |
| G7 | location, video-call link | none | `location`; no video link (E3) | |
| G8 | colour per event | colour from `kind` | `color` from a fixed palette | |
| G9 | time zone per event | UTC only | `time_zone` per event (IANA) | separate start and end zones |
| G10 | visibility and busy / free | `audience` public / internal / private | `audience` kept; no busy / free (E3) | |
| G11 | duplicate | none | WUI "Duplicate" fills the create dialog; no new call | |
| G12 | quick add from text | none | `POST /v1/calendar/events/quick`, a fixed grammar, no AI | more phrasings, more languages |
| G13 | undo delete, trash | hard delete | soft delete, Undo toast, restore, 30-day trash | |
| G14 | search by text, guest, date | none | `GET /v1/calendar/search` | |
| G15 | import / export `.ics` | none | export `.ics` | import `.ics`; a private subscribe link |

## 3. Data: what is a column, what is jsonb

The rule is 098's (owner, t1 `29b19f85`, msgs `eefc2b3a`, `1ec24f32`): a
value that varies goes into a jsonb object, its keys, types and defaults in a
hub registry, every write validated; a key that becomes heavily used
(filtered, indexed, or on a hot query) is **promoted** to a real column by an
ordinary DDL change. Applied to the calendar:

| value | where | why |
|---|---|---|
| `location`, `color`, `reminders` | `props` jsonb | read with the row, never filtered in SQL. A new presentational setting needs no DDL. |
| `rrule`, `recur_until` | columns | the range read filters on `recur_until` for every recurring event |
| `recurring_event_id`, `original_start`, `status` | columns | an exception row is found by `(recurring_event_id, original_start)` on every expansion |
| `time_zone` | column | the expansion of every recurring event needs it; a check refuses junk |
| `deleted_at`, `deleted_by` | columns | every read filters `deleted_at IS NULL` |
| guests and answers | a table, `calendar_guests` | one row per guest, written by that guest, queried by guest (search, "my invitations") |

### 3.1 DDL (`rdb/NNNN_calendar_full_edit.sql`, additive, forward-only)

```sql
ALTER TABLE calendar_events
    ADD COLUMN props              jsonb       NOT NULL DEFAULT '{}'
        CHECK (jsonb_typeof(props) = 'object' AND octet_length(props::text) <= 16384),
    ADD COLUMN time_zone          text        NOT NULL DEFAULT 'UTC'
        CHECK (length(time_zone) BETWEEN 1 AND 64),
    ADD COLUMN rrule              text        NULL CHECK (rrule IS NULL OR length(rrule) <= 500),
    ADD COLUMN recur_until        timestamptz NULL,      -- hub-computed end of the series; NULL = no end
    ADD COLUMN recurring_event_id uuid        NULL REFERENCES calendar_events (event_id) ON DELETE CASCADE,
    ADD COLUMN original_start     timestamptz NULL,      -- the occurrence an exception replaces
    ADD COLUMN status             text        NOT NULL DEFAULT 'confirmed'
        CHECK (status IN ('confirmed', 'cancelled')),   -- cancelled = one deleted occurrence
    ADD COLUMN deleted_at         timestamptz NULL,
    ADD COLUMN deleted_by         text        NULL CHECK (deleted_by IS NULL OR length(deleted_by) <= 64),
    ADD CONSTRAINT calendar_events_exception_shape
        CHECK ((recurring_event_id IS NULL) = (original_start IS NULL)),
    ADD CONSTRAINT calendar_events_master_or_exception
        CHECK (rrule IS NULL OR recurring_event_id IS NULL),
    ADD CONSTRAINT calendar_events_tenant_event UNIQUE (tenant_id, event_id);

CREATE UNIQUE INDEX calendar_events_exception_once
    ON calendar_events (recurring_event_id, original_start) WHERE recurring_event_id IS NOT NULL;
CREATE INDEX calendar_events_series
    ON calendar_events (tenant_id, recur_until) WHERE rrule IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX calendar_events_trash
    ON calendar_events (tenant_id, deleted_at) WHERE deleted_at IS NOT NULL;

CREATE TABLE calendar_guests (
    tenant_id     text        NOT NULL,
    event_id      uuid        NOT NULL,
    guest_type    text        NOT NULL CHECK (guest_type IN ('human', 'agent')),
    guest_id      text        NOT NULL CHECK (length(guest_id) BETWEEN 1 AND 64),
    response      text        NOT NULL DEFAULT 'needs_action'
        CHECK (response IN ('needs_action', 'yes', 'no', 'maybe')),
    comment       text        NOT NULL DEFAULT '' CHECK (length(comment) <= 500),
    responded_at  timestamptz NULL,
    invited_by    text        NOT NULL CHECK (length(invited_by) BETWEEN 1 AND 64),
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, guest_type, guest_id),
    -- a guest row can only point at an event of its own workspace
    FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE
);
CREATE INDEX calendar_guests_guest ON calendar_guests (tenant_id, guest_id);

ALTER TABLE calendar_guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_guests FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON calendar_guests
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON calendar_guests
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

Every added column is nullable or has a constant default, so the column adds
are catalogue-only (PostgreSQL 11+); the checks and the
`UNIQUE (tenant_id, event_id)` scan a small table once. The deploy order is
089's: the migration lands on dev and prd **before** the hub that reads it,
and the store keeps a missing-column probe so a hub that rolls early answers
089's shape, never a 500.

### 3.2 Workspace isolation

- `calendar_guests` carries `tenant_id` with RLS in the `NULLIF` form, and the
  composite foreign key `(tenant_id, event_id)` makes a guest row of
  workspace A pointing at an event of workspace B impossible, not only
  unreadable. The same commit seeds it in `seedTenantAll`
  (`internal/store/crosstenant_test.go`), or `TestCrossTenantEveryTable`
  turns trunk red.
- An exception row has its series' `tenant_id`; the store copies it, and a
  store test proves a cross-workspace `recurring_event_id` is refused.
- **The private filter stays one expression.** The hub keeps every guest id in
  `mentions` too (guests are a subset of `mentions`), so 089's filter
  `audience <> 'private' OR creator_id = viewer OR viewer = ANY (mentions)`
  and its GIN index serve guests unchanged. Removing a guest removes it from
  both.
- Every read adds `deleted_at IS NULL`, except the trash read, which shows the
  caller's own deletions only (section 4.8).

### 3.3 The `props` registry (hub)

| key | type | default | rule |
|---|---|---|---|
| `location` | string | `""` | at most 300 characters |
| `color` | string | `""` (= the `kind`'s colour) | one of 11 palette names (`tomato`, `flamingo`, `tangerine`, `banana`, `sage`, `basil`, `peacock`, `blueberry`, `lavender`, `grape`, `graphite`); the WUI maps each to a theme variable, light and dark |
| `reminders` | array | `[]` | at most 5 of `{"amount": <whole number>, "unit": "minutes\|hours\|days", "method": "popup"}`, at most 4 weeks before (section 4.3); `method` widens later |
| `pinned` | bool | `false` (dropped) | the event leads its day in every view (section 3.3.1); on the wire as `pinned`, omitted when false (SPL-5453) |

An unknown key is `400 bad_event`. A key added later is one registry line and
a test, no DDL. The size check (16 KB) keeps a row small.

#### 3.3.1 The order of a day's events (SPL-5453)

Owner HUM-10 (csitea `218fa45d`, 2026-11-13): "mark the calendar entries to be
the first events for the days". The hub lists a range `ORDER BY starts_at,
event_id`; every whole-day event starts at 00:00Z, so among them the order was
the random uuid (measured on the csitea calendar: on 17 of 28 days the
owner's Finland / Netherlands entry was not first). Every view now orders one
day's events by one rule, `calDayCompare` in
`csi-spl-wui/src/utils/calendar-phone-nav.mjs`:

1. whole-day events before timed ones (phone Week also counts a carried-over
   day of a multi-day event as whole-day);
2. then `pinned` before not pinned;
3. then by start, then by id.

The views: desktop Day, 3 days and Week (the all-day row), desktop Month (a
day cell), phone Month (the agenda and the dots), phone Week and phone Day
(the all-day row). Before, phone Month and Week already put whole-day first;
the desktop views and phone Day showed the hub's order. Nothing else changes
for an event that is not pinned. `pinned` is set by an operator
(`do_spl_calendar_event_pin`, section 4.10) or by any `props` write; the WUI
has no control for it yet.

## 4. The calls

All routes keep 089 6.1: JSON, RFC 3339 UTC times, `""` for unset, arrays
never `null`, the usual `{"error", "detail"}` refusal. Reads need
`topics.read`, writes `notes.send`; a demo visitor still writes nothing
(`403 demo_read_only`). Agents call the same routes; 089 T005 (CLI + MCP)
grows one flag or tool per call as each task lands.

### 4.1 The event object grows (no field changes meaning)

089 6.1.1 plus:

| field | type | meaning |
|---|---|---|
| `time_zone` | string | IANA zone the event was made in (`Europe/Helsinki`); `UTC` for every 089 event |
| `rrule` | string | the repeat rule (section 4.4) on each occurrence of a series, `""` otherwise |
| `recurring_event_id` | string | the series an occurrence belongs to, `""` otherwise |
| `original_start` | string | the occurrence's unchanged start, `""` otherwise |
| `location`, `color` | string | from `props`, `""` = unset |
| `reminders` | array | `[{"amount": 10, "unit": "minutes", "method": "popup"}]`, as the person typed them |
| `guests` | array | `[{"type": "human", "id": "<human_id>", "response": "yes", "comment": ""}]`; the owner is not listed |
| `my_response` | string | the viewer's own answer when they are a guest, `""` otherwise |
| `deleted_at` | string | `""` except in the trash read |

An occurrence of a series has `id` = `<event_id>_<YYYYMMDDTHHMMSSZ>` (its
`original_start`), Google's form. The series row itself is never on the grid,
only its occurrences.

### 4.2 Create and PATCH: the body grows

The 089 body fields stay; these are added, all optional:
`time_zone`, `rrule`, `location`, `color`, `reminders`,
`guests` (a list of `{"type", "id"}`; on PATCH the full new list),
`notify_guests` (section 4.5).

- **c-394's call keeps working**: a body of 089 fields only stores
  `time_zone = UTC`, no `rrule`, `props = {}`, no guests, exactly as today.
- A guest is put in `mentions` by the hub (section 3.2). A mention is not
  made a guest.
- **Move and resize (G1)** need no new call: drag and resize send `PATCH`
  with `starts_at` / `ends_at`. New: `PATCH` and `DELETE` accept
  `If-Match: "<updated_at>"`; a stale value is `409 edit_conflict` with the
  current event in the body, so two people dragging the same event never
  silently overwrite each other. Without the header the call behaves as today.
- **Duplicate (G11)** needs no new call: the WUI opens the create dialog with
  the event's fields filled in and guests' answers reset, and `POST`s it.

### 4.3 Several reminders (G6, owner E2)

- `reminders` is a list of up to 5 `{"amount", "unit", "method"}`, kept as
  the person typed them, so "1 day before" reads back as 1 day, not 1440
  minutes:
  - `amount` is a **whole number**, 1 or more (E2). A fraction (`1.5`), `0`,
    a negative number or a string is `400 bad_event`.
  - `unit` is `minutes`, `hours` or `days`. The reminder is at most 4 weeks
    before the event: `amount` at most 40320 minutes, 672 hours or 28 days.
  - Two equal reminders are stored once.
  - `method` is `popup` in v1: 089's in-app pop-up, still the WUI's own timer,
    still no agent, no AI and no spool message (089 D4 stands).
- `remind_at` stays on the wire for c-394 and old clients. **Written**, it
  becomes one reminder of the whole minutes between it and `starts_at`
  (`{"amount": 15, "unit": "minutes"}`), seconds dropped; a `remind_at` after
  the start is refused. **Read**, it is the earliest coming reminder time of
  the event (of its next occurrence for a series), `""` when none.
- `GET /v1/calendar/reminders?from=&to=` keeps its shape and answers one item
  per reminder that fires in the window, with the item's `remind_at` set to
  that fire time, so the shipped pop-up code (089 T006) works unchanged. The
  store reads events starting in `[from, to + 28 days)` (the 4-week cap) and
  computes fire times in Go.
- Later: `push` (web push, after 095 ships) and `email` (the existing mail
  relay, `internal/mail`). Both are technical deliveries, not agents.

### 4.4 Recurrence (G2) and edit scopes (G3)

**The rule.** `rrule` is an RFC 5545 `RRULE` value without the `RRULE:`
prefix. v1 accepts this subset, anything else is `400 bad_event`:
`FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `BYDAY` (weekly: `MO,WE`;
monthly: `2TU`, `-1FR`), `BYMONTHDAY`, `BYMONTH` (yearly), and at most one of
`COUNT` / `UNTIL`. That covers every choice in Google's "Custom" repeat
dialog. The hub expands it in the event's `time_zone`, so a 09:00 Helsinki
meeting stays 09:00 across a daylight-saving change.

**Storage, Google's model.** One series row (`rrule` set). An occurrence that
was changed is an exception row (`recurring_event_id`, `original_start`, its
own fields). A deleted occurrence is an exception row with
`status = 'cancelled'`. The hub sets `recur_until` from `UNTIL` / `COUNT` on
every write, so the range read skips ended series.

**The range read** (`GET /v1/calendar/events`, unchanged parameters): single
events overlapping the range, plus each series with
`starts_at < end AND (recur_until IS NULL OR recur_until >= start)`, expanded
in Go, exceptions applied, cancelled occurrences dropped. The marks read
(`/marks`) counts occurrences the same way. A response holds at most 2000
occurrences; past that it is `400 bad_range` ("narrow the range"), never a
silent cut.

**Edit and delete scope.** `PATCH` and `DELETE` on
`/v1/calendar/events/{id}?scope=this|following|all`, where `{id}` is a series
id or an occurrence id:

| scope | PATCH does | DELETE does |
|---|---|---|
| `this` (default for an occurrence id) | writes or updates the exception row for that occurrence | writes a `cancelled` exception row |
| `following` | ends the old series with `UNTIL` just before this occurrence and creates a new series from it with the changed fields; later exceptions move to the new series | ends the old series with `UNTIL` just before this occurrence |
| `all` (default for a series id) | updates the series; a time shift moves every exception's `original_start` by the same amount; a changed field applies to the exceptions that did not change that field themselves | soft-deletes the series and its exceptions (section 4.8) |

`scope` on a single event is ignored. Answers stay `200 {"event": ...}`, the
event as changed (for `following`, the first occurrence of the new series).

### 4.5 Guests and RSVP (G4, G5)

- `guests` on create and PATCH: humans by `<human_id>`, agents by
  `<agent_id>`, both of this workspace (else `400 bad_event`), at most 50, the
  same cap as `mentions`.
- `POST /v1/calendar/events/{id}/rsvp`
  `{"response": "yes|no|maybe", "comment": "", "scope": "this|all"}`: the
  caller answers for themselves only; a caller who is not a guest is
  `403 not_a_guest`. On an occurrence id, `this` stores the answer on that
  occurrence's exception row, `all` on the series. Answer:
  `200 {"event": ...}`.
- Agents answer with `spool calendar rsvp <id> yes` and the MCP tool
  `calendar_rsvp` (added to 089 T005's surface).
- **Notices.** A create with guests, a change of time or place, and a cancel
  each notify every guest once, unless the call carries
  `"notify_guests": false` (Google's "Send / Don't send" prompt). A human gets
  an item in their Flow (062) with Yes / Maybe / No buttons that call the
  rsvp route; an agent gets a spool `note` from `system` with the event and
  the `spool calendar rsvp` line (Q3). Reminders stay outside this path:
  `TestCalendarSendsNothing` is narrowed to the reminder code, and a new test
  proves an invite sends exactly one notice per guest.
- Who may edit: unchanged from 089 (anyone with `notes.send` who can read the
  event); a guest who may not edit can still answer (Q4). Amended by spec 149
  section 13.6 (plan, SPL-6255): an event whose `edit_level` is `owner`
  ("workspace can read") is edited and deleted only by its creator and the
  workspace's `biz_owner` / `admin` holders; `everyone`, every existing
  event's value, keeps this rule.

### 4.6 Quick add (G12)

`POST /v1/calendar/events/quick`
`{"text": "Deploy prd tomorrow 15:00-16:00 @<agent_id> #deploy", "time_zone": "Europe/Helsinki", "dry_run": false}`

A fixed, documented grammar, **no AI** (the owner's line for reminders, 089
D4, applied here too): dates (`today`, `tomorrow`, a weekday name,
`YYYY-MM-DD`, `Oct 12`), times (`15:00`, `3pm`, `15:00-16:00`), durations
(`for 30m`, `for 2h`), repeats (`every day`, `every weekday`, `every Monday`,
`every month`), `@id` as a guest, `#kind` as the kind; the rest is the title.
English only in v1. `dry_run: true` answers `200 {"event": ...}` without
storing, so the WUI shows what will be created as the person types; otherwise
`201`. Text it cannot read is `400 bad_quick_add` naming the part it did not
understand.

### 4.7 Search (G14)

`GET /v1/calendar/search?q=&kind=&guest=&from=&to=&audience=&limit=&cursor=`

- `q` matches title, description and location (case-insensitive substring);
  `guest` is a human or agent id (guest, mention or owner); `kind` and
  `audience` may repeat; `from` / `to` default to one year back and one year
  ahead, at most 5 years apart; `limit` 1..100, default 50; `cursor` comes
  from the last answer.
- Answer: `{"events": [event...], "next_cursor": ""}`, by `starts_at`; a
  series matches once, as its next occurrence after `from`.
- The private filter, the demo filter and `deleted_at IS NULL` apply as on
  every read. No new index in v1 (a workspace holds thousands of events, not
  millions); a trigram index comes only if `do_spl_db_health` shows the query
  slow (the 098 promotion rule).

### 4.8 Soft delete, Undo and trash (G13)

- `DELETE` sets `deleted_at` / `deleted_by` instead of removing the row; its
  answer is 089's, `200 {"event": ...}`, so old callers see no change.
- `POST /v1/calendar/events/{id}/restore` clears them: `200 {"event": ...}`.
  The WUI shows "Event deleted · Undo" for 10 seconds after a delete.
- `GET /v1/calendar/trash` lists the events the caller deleted in the last 30
  days, newest first.
- A named action, `./run -a do_spl_calendar_purge_trash`, removes rows
  deleted more than 30 days ago, run daily from a cron entry (nothing ad hoc).
  The 30 days are a workspace setting in 098's registry (Q6).

### 4.9 Export, and later import (G15)

- `GET /v1/calendar/export.ics?start=&end=` (v1): a `text/calendar` file of
  the events the caller can read in the range (at most 400 days), series as
  `RRULE` with their exceptions as `RECURRENCE-ID` items, guests as `ATTENDEE`
  with `PARTSTAT`. Read only, the same filters as the range read.
- Later: `POST /v1/calendar/import` (`text/calendar`, at most 1 MB, a
  `dry_run` preview, the rrule subset of 4.4; an item it cannot read is
  reported, not guessed) and a private "subscribe" link with its own
  revocable token (Q7).

### 4.10 Operator writes on an existing event (SPL-5453)

An agent creates an event with `POST /v1/operator/calendar/events`
(`do_spl_calendar_event_add`). Two more operator routes change one
(`csi-spl-api/src/go/spool-hub-api/internal/hub/calendar_operator_write.go`),
with the create's auth (the env service account on the operator allow-list),
its workspace scope (a host of another workspace is `403 tenant_mismatch`)
and its log fields (`tenant`, `agent_id`, `ordered_by`, the operator):

- `PATCH /v1/operator/calendar/events/{id}`, body `{tenant, agent_id,
  ordered_by?, props: {"pinned": true|false}}`: sets `props.pinned`; another
  `props` key is `400 bad_event`. Since SPL-5720 the body may also carry
  `title`, `description`, `starts_at`, `ends_at`, `all_day` and `reminders`
  (the member PATCH's checks); any other field (audience, mentions, guests,
  owner, links, kind, rrule) is `400 bad_json`, an empty change `400
  bad_event`. Action: `cd csi-spl-orc && ENV=<env> TENANT_ID=<ws>
  EVENT_IDS=<id,...> AGENT_ID=<id> ORDERED_BY=<HUM-n> ./run -a
  do_spl_calendar_event_pin` (`PINNED=0` unpins).
- `DELETE /v1/operator/calendar/events/{id}?tenant=&agent_id=&ordered_by=`:
  the member delete of section 4.8. The event goes to the trash of
  `ordered_by` when that human is a member of the workspace, so they see it
  in their trash and can Undo it in the WUI; otherwise to the agent's.
  Action: `do_spl_calendar_event_delete`, the same variables.
- Both touch only a single event the operator reaches (the private rule
  below): a synced one is `409 synced_read_only`, a repeating one `400
  bad_event`. Both actions are a dry run unless `DRY_RUN=0`, take 1..200 ids
  and read each one back (`GET`: pinned as asked; `404` once trashed).

A private event from an agent (SPL-5498). The create takes the member
create's `audience` and `mentions`. With no `audience` (SPL-5963, owner
HUM-10, msg eac307d4: "An entry an agent writes for one person is private to
that person by default"), an entry whose owner is a member (`owner_id`, else
`ordered_by`) is `private` with the owner added to `mentions`
(`operatorPersonalDefault`); with no person it is `workspace`; an explicit
`audience` is kept (spec 089 section 4.2). Then three
operator checks, each a `400 bad_event`: every mention is a `HUM-n` member of
the workspace; a `private` event names at least one; and `ordered_by` is set
and is one of them, so the human who ordered it can read it. The creator stays
the agent. The read-back `GET /v1/operator/calendar/events/{id}?tenant=&as=<agent id>`
reads a private event only when `as` is its creator and that creator is an
agent: an agent reads back what it wrote. Any other `as` (another agent, a
human, a mention included) and no `as` is `404` on a private event, so the
operator never reads a human's private event. Workspace and internal events
read as before. The pin and delete routes reach a private event only under
the rule below. Who sees a private event in the WUI is
unchanged (the creator and the mentions). Because the creator is the agent,
FR-010 (only the creator sets or clears private) means the mentioned humans
cannot move such an event out of private in the WUI. Action:
`do_spl_calendar_event_add` with `AUDIENCE=workspace|internal|private` and
`MENTIONS=HUM-n,...`; `AUDIENCE=private` needs `ORDERED_BY` among `MENTIONS`
(checked before any call), and its read-back passes `as=$AGENT_ID` for
every event, since a create with no `AUDIENCE` may now be private.

An agent replaces a private entry an agent made for a person (SPL-5720,
owner HUM-10, topic b610f795, msg 18ee3ef7: "Fix it first so an agent can
replace a private entry made for me"). **The rule (owner may change):** an
operator call reaches a private event only when all three hold:

1. its `creator_type` is `agent` (any agent, not only the caller);
2. the call names `ordered_by`, and that human is a member of the workspace;
3. `ordered_by` is in the event's `mentions` (the operator create always
   puts it there).

The store's private filter (spec 089 section 5: `creator_id = <viewer> OR
<viewer> = ANY (mentions)`) is not changed; the operator reads and writes as
the viewer `ordered_by`, and the hub adds 1 (`operatorReachesPrivate`,
`calendar_operator_write.go`). So the operator never reaches a private event
the person made themselves (creator human), one another person made that
names them, or an agent's private event for another person: each is `404`
on `PATCH`, `DELETE` and `GET ...?ordered_by=`. An event whose owner is the
person but who is not in its mentions is not reached either: the person
cannot read it in the WUI. Under the rule:

- `PATCH` changes the fields above; audience and mentions stay, so it stays
  private to the same people.
- `PATCH {audience: "private"}` (SPL-5963, owner msg eac307d4) is the one
  audience change an operator makes: on an agent's entry whose owner is
  `ordered_by` (a member), it becomes `private`; a shared entry's `mentions`
  become `{ordered_by}`, an entry already private keeps its mentions. Any
  other value, no `ordered_by`, another owner or a human's entry is `400
  bad_event`; `mentions` stays refused (`400 bad_json`). Nothing widens an
  audience. Action: `do_spl_calendar_event_update` with `AUDIENCE=private`
  and `ORDERED_BY` (else it fails before any call); the read-back must hold
  `audience: private`. Tests: `calendar_personal_test.go` (memory and
  Postgres), `spl-calendar-event-update.tst.sh` case 6.
- `DELETE` moves it to the person's trash, where they can Undo it.
- `GET /v1/operator/calendar/events/{id}?tenant=&ordered_by=<HUM-n>` reads it
  back (with `as=` it is `400`).
- Google Calendar follows the hub row with no second path: the sync's out
  half sends every live event the member reads, patches it when its sync hash
  changes and deletes it at Google once trashed (`gcal_sync.go`; test
  `gcal_sync_agent_private_test.go`).

Action: `cd csi-spl-orc && ENV=<env> TENANT_ID=<ws> EVENT_ID=<id>
AGENT_ID=<id> ORDERED_BY=<HUM-n> REMINDERS=15m ./run -a
do_spl_calendar_event_update` (also `TITLE`, `DESCRIPTION`, `DAY` or
`STARTS_AT` + `ENDS_AT`; a dry run unless `DRY_RUN=0`; the read-back must
hold every field sent). `do_spl_calendar_event_delete` and `_pin` take the
same `ORDERED_BY`, and their read-back names it. Tests:
`calendar_operator_private_write_test.go` (memory and Postgres),
`spl-calendar-event-update.tst.sh`.

Reminders from an agent (SPL-5718). `do_spl_calendar_event_add` takes
`REMINDERS=15m,1h,1d`: each an amount and `m`, `h` or `d`, sent as the
create's `reminders` (`{amount, unit: minutes|hours|days, method: popup}`,
section 4.3's rules: 1 or more, at most 4 weeks, at most 5, equal ones once),
refused before any call when bad; unset or empty sends none. The read-back
line prints them.

## 5. The WUI editing surface

All of it is calendar code, loaded on route entry, outside the 155 KB
initial chunk (089 section 3). It lands on top of 089 T008 (the main view
and the event dialog), not instead of it.

| surface | what the person does |
|---|---|
| main view | drag an event to move it, drag its bottom edge to resize, drag on empty time to create; an `edit_conflict` reloads the event and says who changed it |
| event pop-over (click) | title, time, location, guests with their answers, Edit / Delete / Duplicate, and for a guest Yes / Maybe / No |
| event dialog (Edit) | Google's full editor: title; date, time, all-day, time zone; "Does not repeat / Daily / Weekly on <day> / Monthly on the <n>th <day> / Annually / Every weekday / Custom..."; location; guests picker (members and agents) with "notify guests"; reminders list ("+ Add reminder", up to 5, each a whole-number field and a minutes / hours / days choice, E2); colour swatches; audience (`private` only for the owner, 089 4.2); description |
| scope prompt | on save or delete of a repeating event: "This event / This and following events / All events" |
| quick add | the `+` box accepts a sentence and shows the `dry_run` preview before saving |
| search | a search field over the main view; results as a list, a click jumps to that day |
| Undo | the toast after a delete; the trash list in the calendar menu |
| export | "Export .ics" in the calendar menu |

### Discussion, issues and the owner (SPL-4043)

Every calendar entry shows a discussion link, one or more issue links, and one owner. The discussion is `calendar_events.topic_id` (rdb 0125): the dialog takes a full topic id, its 8-hex short id, or a `/t/<id>` link. The hub stores the full id. A short id must match exactly one topic of the workspace; none, or more than one, is refused. This holds for a member's create and edit too: a `topic_id` that is not a topic of the workspace is a 400 `bad_event`, never stored. The popover and the phone peek link to `/t/<id>`. Issues are `issue_keys text[]` (rdb 0247), at most 20 keys of this workspace, shown as chips; each chip links to `/issues?issue=<key>`. The owner is `owner_id` (rdb 0247), one workspace member (`HUM-n`) or one agent id, distinct from `creator_id` and from guests. A new event defaults to its creator. Empty fields stay as placeholders. The operator action `do_spl_calendar_event_add` takes optional `ISSUE_KEYS` (comma separated) and `EVENT_OWNER` (`HUM-n` or an agent id). An empty `EVENT_OWNER` leaves the hub default: `ORDERED_BY` when that human is a member of the workspace, otherwise the agent. The catalogue strings are in all 19 locales. Outside English they are drafts; an agy review has the last word on the wording.

### 5.1 Mobile first

Mobile first (owner HUM-10 msg `8d181e85`, t1 `70484be0`; mobile channel
`#spool-hub-mobile` `52aee116-fe6a-4776-bc5c-0076b40cbc56`, c-002 msg `5c1a9e2d`;
approved by owner HUM-10 in t1 `52aee116`, msg `adf16567-43e0-4ce1-aa55-5b4fa91e0da4`,
verbatim: "look good . go"): the screens and interactions are designed for the
phone first (viewport <= 820 px, mobile stack Level 2 per spec 089 section 2.2).
**Where phone and desktop conflict, the phone wins.**

Every v1 editing feature (section 6) adapts to a small touchscreen:
- **Baseline viewports:** tested and verified at 360 px width (compact phone,
  e.g. 360x780 / 360x740) and 390 px width (standard phone, 390x844).
- **Thumb zone:** primary actions (navigation, "+ New event", view switcher,
  dialog Save/Cancel/Delete, RSVP buttons) sit in the lower half of the
  screen (`y >= ih / 2`), reachable with one thumb.
- **Touch targets:** interactive controls meet the 44 px target standard
  (`min-height: var(--tap); min-width: var(--tap)`).
- **No sideways scroll:** `scrollWidth <= clientWidth` (`xScroll <= 1 px`) across
  all views, sheets, and dialogs.
- **Safe-area insets:** insets respect `env(safe-area-inset-bottom)` and the
  composer dock height (`var(--composer-dock-h, 0px)`).

#### 1. Drag to move and resize (G1)
- **What the phone does:**
  - **Move:** Tapping an event opens its pop-over/sheet. A **touch-and-hold**
    (long press >= 250 ms, accompanied by visual card elevation and border tint)
    enters drag-move mode; dragging vertically moves the event across time slots
    or across days in the Week list. Releasing drops the event and issues `PATCH`
    with `If-Match`. Swiping without holding scrolls the day/week list smoothly
    without initiating a drag.
  - **Resize:** When an event is selected in Day view, an explicit bottom
    **resize handle** (a grab bar/pill) appears with a dedicated >= 44x44 px touch
    hit area. Dragging the handle up or down adjusts the event's duration in
    15-minute increments; releasing submits `PATCH` with the new `ends_at` and
    `If-Match`.
- **How it differs from desktop:** Desktop relies on immediate mouse click-drag
  and 3 px edge hover cursors (`ns-resize`). On a phone touch screen, immediate
  drag would intercept scrolling; touch hold-to-drag disambiguates scrolling from
  repositioning, and touch resizing requires a visible >= 44 px hit handle instead
  of hover.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Hold >= 250 ms initiates event drag without scrolling; vertical
    drag adjusts time slot; tap without hold opens event; swipe without hold
    scrolls schedule; bottom resize handle has >= 44x44 px touch area; drag
    updates duration; `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; hold-to-drag moves event across day/hour
    boundaries; bottom resize handle cleanly resizes; `edit_conflict` shows
    in-view toast without horizontal clipping.

#### 2. Several reminders (G6, owner E2)
- **What the phone does:** The dialog provides "+ Add reminder" (up to 5). Each
  reminder is an inline row with:
  - Amount input configured with `inputmode="numeric"` and `pattern="[0-9]*"`,
    which opens the compact numeric keypad on iOS and Android rather than the full
    alphanumeric keyboard.
  - Unit dropdown (`minutes`, `hours`, `days`) sized at >= 44 px tap height.
  - Delete icon button with >= 44x44 px touch target.
  - Up to 5 reminder rows stack cleanly inside the scrollable dialog. Non-whole
    numbers or values > 4 weeks show immediate inline validation.
- **How it differs from desktop:** Desktop uses compact horizontal stepper inputs.
  Phone uses `inputmode="numeric"` to preserve vertical viewport space, full-width
  stacked rows, and >= 44 px touch targets for unit pickers and deletion buttons.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Each reminder row (amount input, unit select, remove button) fits
    in 360 px width without line wrapping; amount input summons numeric keyboard;
    unit select and delete button have >= 44 px touch targets; non-whole numbers
    rejected; up to 5 reminders scroll cleanly.
  - **390 px:** Tested at 390x844; numeric keypad does not conceal active input or
    dialog controls; 5 stacked reminders persist and reload as typed `{amount, unit}`.

#### 3. Repeating events (G2, G3)
- **What the phone does:**
  - Repeat options ("Does not repeat", "Daily", "Weekly...", "Every weekday",
    "Custom...") render via a full-width mobile picker or bottom sheet.
  - "Custom..." repeat editor stacks vertically: interval stepper, weekday chips
    (`M`, `T`, `W`, `T`, `F`, `S`, `S` as touchable circles >= 40 px each), and
    until/count choices.
  - On saving or deleting an occurrence, the scope prompt ("This event",
    "This and following events", "All events") displays as a **bottom action sheet**
    with large, vertically stacked buttons (>= 44 px height each) directly in the
    lower thumb zone.
- **How it differs from desktop:** Desktop displays small radio/dropdown menus
  and floating modal prompts. Phone uses touch-friendly chip rows, full-width
  pickers, and a bottom action sheet for thumb-reachable scope selection.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Repeat select fits within 360 px; Custom repeat weekday chips fit
    in a single 7-chip row or wrap cleanly; scope prompt renders 3 stacked buttons
    with >= 44 px height in the bottom thumb zone; `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; tapping scope prompt applies selected scope
    to `PATCH`/`DELETE` and dismisses sheet; bottom safe area padding respected.

#### 4. Undo delete (G13)
- **What the phone does:** When an event is deleted, the Undo bar ("Event deleted · Undo")
  floats for 10 seconds. On a phone it sits **at the top**, at the same place and
  with the same look as the app's other phone undo bars (Archived · Undo,
  Deleted · Undo: the shared UndoSnackbar, `top: calc(0.5rem +
  env(safe-area-inset-top))`, centred). Owner, msg b6f816c2: the earlier place,
  8 px above the calendar's bottom bar, is replaced. It leaves the Today/prev/next
  controls and the iOS home indicator fully visible and accessible. The "Undo"
  action button has a >= 44 px touch target.
- **How it differs from desktop:** Desktop toast floats at the bottom-left or
  center of the screen. On a phone, a bottom toast would collide with the sticky
  bottom toolbar or iOS home gesture zone; the phone puts it at the top, where
  every other undo bar of the app sits, clear of date navigation.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Undo bar sits at the top, at the archive toast's top; Today,
    prev, next buttons remain 100% visible and clickable while Undo bar is shown;
    Undo button has >= 44 px touch target; tapping Undo restores event within 10 s;
    bar auto-dismisses after 10 s; `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; the toast is centred like the archive toast,
    at its top; zero overlap with bottom navigation or system gesture areas.

#### 5. Guests who answer (G4, G5)
- **What the phone does:**
  - **RSVP:** In the event pop-over / detail sheet, the viewer's RSVP choices
    ("Yes", "Maybe", "No") render as a segmented bar or prominent buttons in the
    bottom thumb zone (>= 44 px height each).
  - **Guest picker:** In the edit dialog, the guest search field expands a
    touch-friendly dropdown of workspace members and agents with avatars and badges
    (>= 44 px row height). Selected guests display as removable chips (>= 44 px
    tap target on remove). "Notify guests" toggle switch has >= 44 px tap target.
- **How it differs from desktop:** Desktop places RSVP inside compact popover
  headers. Phone places RSVP in the primary thumb zone at the bottom of the card;
  guest autocomplete supports touch scroll and large touch targets for quick selection.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Yes / Maybe / No buttons fit in a single 3-column row in thumb
    reach (each >= 44 px height); tapping records RSVP via `POST .../rsvp` with
    instant active state; guest autocomplete list and chips fit within 360 px;
    "Notify guests" switch is >= 44 px; `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; RSVP buttons positioned in lower third of screen;
    guest search results scroll smoothly on touch.

#### 6. Event details (G7..G9)
- **What the phone does:** Clicking "+ New event", an empty slot, or an event
  opens `CalendarEventDialog` as a **full-screen sheet/modal** (`width: 100vw;
  height: 100dvh; max-height: 100%`) rather than a centered popup.
  - Single-column vertical scroll holds all fields: title, date, start/end or
    all-day, time zone picker, repeat rule, location, guests, reminders, colour
    swatches, private switch, and description.
  - Colour picker wraps into a grid of touchable circles (>= 44x44 px).
  - Time zone picker is a full-width select with searchable modal list.
  - **Primary actions at the bottom:** Save, Cancel, and Delete are anchored in a
    sticky bottom action bar inside the thumb zone, with Save and Delete having
    >= 44 px height.
- **How it differs from desktop:** Desktop uses a floating modal dialog (`size="md"`)
  with a 4-column form grid. Phone uses a full-screen takeover with single-column
  scrolling and sticky thumb-zone actions at the bottom.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Dialog fills 100% width and height without horizontal scrolling;
    fields stack in 1 column; color swatches >= 44x44 px; sticky bottom bar holds
    Save and Cancel (>= 44 px height); scrolling reveals all fields smoothly.
  - **390 px:** Tested at 390x844; sticky bottom bar stays visible when keyboard is
    dismissed; active inputs scroll into view above virtual keyboard; header close
    button and bottom Save button work reliably.

#### 7. Search (G14)
- **What the phone does:** Tapping Search in the mobile calendar header opens a
  **full-screen search view**.
  - The search input auto-focuses with an instant "Clear" (X) button and a "Cancel"
    header button.
  - Below the input, filter chips (kind, guest, date range) scroll horizontally
    in a touch-friendly chip bar (`overflow-x: auto`).
  - Search results render as a full-width vertical list with date header, time,
    title, and location, with each result row having >= 48 px height.
  - Tapping a result jumps directly to that day in the Day view, opens the event,
    and closes the search view.
- **How it differs from desktop:** Desktop renders a drop-down results list below
  the header search bar. Phone uses a full-screen overlay to provide maximum
  readability and keyboard room.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Search opens full screen; search input, clear button, and cancel
    button fit 360 px width; filter chips scroll horizontally without expanding
    page width; result items have >= 44 px height; tapping result navigates to day;
    `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; live debounced queries query `GET /v1/calendar/search`;
    results list remains scrollable above virtual keyboard.

#### 8. Quick add (G12)
- **What the phone does:** Opening Quick add displays a compact input bar
  **docked directly above the virtual keyboard** (`interactive-widget=resizes-content`
  / `visualViewport`-safe).
  - A 1-line text input accepts the sentence ("Sync tomorrow 10am @bot #infra").
  - Immediately attached above the input, a compact live `dry_run` preview card
    displays the parsed title, time, date, and guests as chips.
  - The phone keyboard stays open continuously while typing and updating preview.
  - A Send/Create button (>= 44x44 px) commits the event via `POST /v1/calendar/events/quick`
    and dismisses the keyboard.
- **How it differs from desktop:** Desktop uses an expanding input box in the
  desktop header. Phone must keep the virtual keyboard open without hiding the input
  or the live preview, docking above the keyboard and fitting within the visible height budget.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Input bar and preview card fit within visible height above software
    keyboard (~350 px height budget); keyboard stays open during live `dry_run`;
    Send button is >= 44x44 px; submitting creates event and closes Quick add;
    `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; preview text and chips wrap without overflowing;
    unrecognized syntax displays inline validation message without jumping.

#### 9. Duplicate (G11)
- **What the phone does:** In the event pop-over or detail sheet, tapping "Duplicate"
  opens the full-screen event dialog populated with all fields copied from the
  selected event (title, duration, location, colour, reminders, time zone, description),
  with guest RSVP states reset and ready for creation. Primary Save button sits in the
  bottom thumb zone.
- **How it differs from desktop:** Desktop opens the desktop modal dialog. Phone
  opens the full-screen dialog with sticky thumb-zone actions at the bottom.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** "Duplicate" action in event sheet has >= 44 px tap height; opens
    full-screen dialog pre-filled; Save button is reachable by thumb at bottom;
    saving creates event and returns to calendar view.
  - **390 px:** Tested at 390x844; duplicate flow executes smoothly without
    horizontal scroll.

#### 10. Export on a phone (G15)
- **What the phone does:** "Export .ics" in the calendar menu triggers
  `GET /v1/calendar/export.ics?start=...&end=...` with
  `Content-Disposition: attachment; filename="calendar.ics"` and
  `Content-Type: text/calendar; charset=utf-8`. On mobile Safari (iOS) and mobile
  Chrome/Firefox (Android), this automatically prompts the native OS modal ("Open
  in Calendar" / "Add to Calendar" / download prompt), allowing 1-tap import into
  the device's native calendar app.
- **How it differs from desktop:** Desktop silently saves the `.ics` file to the
  browser's Downloads directory. On mobile, browsers hand off `.ics` files directly
  to the device's native calendar application.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** "Export .ics" menu entry has >= 44 px tap height; tapping triggers
    download request; browser receives `200` with `text/calendar` and triggers OS
    calendar import/download prompt without page reload or layout corruption.
  - **390 px:** Tested at 390x844; date range parameters correctly passed; download
    completes cleanly.

#### Owner questions (Mx)

| # | Question | Proposal |
|---|---|---|
| M1 | On touch screens, should moving an event require a 250 ms long-press anywhere on the event card, or an explicit touch drag handle icon on the card? | 250 ms long-press anywhere on the card to lift and drag, with subtle haptic/visual elevation feedback. This avoids cluttering small event cards with extra icons while preventing scroll conflicts. |
| M2 | The event dialog is full-screen on phones (<= 600 px). On larger mobile screens (601–820 px, e.g. tablets or unfolded phones in landscape), should it remain full-screen or use the desktop centered modal (`size="md"`)? | Use full-screen for <= 600 px (phones); switch to centered modal for 601–820 px (tablets/landscape), keeping form fields from becoming excessively wide while maintaining touch-sized targets. |
| M3 | When Quick add is opened on mobile, should it dock directly above the software keyboard as a bottom bar, or open as a full-screen input view? | Dock directly above the software keyboard with the live dry-run preview card attached, keeping the calendar view visible behind it so the user can see their existing schedule while typing. |
| M4 | When an event is deleted, should the 10-second Undo toast float immediately above the Calendar bottom toolbar (Today/prev/next), or should it temporarily replace the bottom toolbar? | Float immediately above the bottom toolbar (`bottom: calc(var(--cal-bottom-bar-h) + var(--composer-dock-h) + 8px)`), so date navigation remains available while the Undo option is visible. **Superseded** (owner, msg b6f816c2): the phone Undo bar sits at the top, like the app's other undo bars. |
| M5 | In the mobile Day view, should tapping an empty time slot directly create/open the event dialog pre-filled with that hour, or should event creation only be triggered by the bottom "+ New event" button? | Both: tapping an empty time slot opens the dialog pre-filled with that specific hour; tapping the bottom "+ New event" button defaults to the next full hour. |

### 5.2 The week number is a label (SPL-6146)

Owner HUM-10, t1 74772974 (msg `3d289c5c`): the week number is written
`w-01`, `w-02` .. `w-53`, two digits, "in the front of the week on the
monthly view and on each day, after the day number in the calendar view and
not as a separate event".

- The number is the ISO-8601 week (Monday first, the week holding its
  Thursday names it): 2026-12-28 is `w-53`, 2027-01-04 is `w-01`. One helper
  draws it everywhere, `calWeekLabel` in `csi-spl-wui/src/utils/calendar-year.mjs`.
- Month (desktop and phone): `w-NN` in the first cell of each week row, in
  front of its day number.
- Day, 3 days and Week (desktop) and the phone Week: `w-NN` after the date in
  each day header. The phone Day: after the date in the header title, so the
  phone search's day group headings read the same (`Wed 2026-10-07 w-41`).
- It is drawn lower case as written: a day header that capitalizes its
  weekday leaves the label alone (`text-transform: none`). On the phone
  Month it has its own band at the top of the row, above the day number
  and inside the cell, never on top of the number (at 390 and 320 px).
- It is a label of the grid, never an event item. A "Week NN of YYYY" event
  a member sees comes from a calendar they imported or connected (the WUI
  makes none) and stays as that calendar sent it.
- Tests: `csi-spl-wui/tests/unit/calendar-week-label.test.mjs`,
  `csi-spl-wui/tests/e2e/calendar-week-label.test.mjs`.

## 6. Ranked value to the owner, and v1

| rank | item | v1 |
|---|---|---|
| 1 | drag move / resize + conflict-safe `If-Match` (G1) | yes |
| 2 | several reminders, a typed whole number of minutes, hours or days before (G6, E2) | yes |
| 3 | recurrence + this / following / all (G2, G3) | yes |
| 4 | soft delete + Undo + trash (G13) | yes |
| 5 | guests + RSVP + in-app notices (G4, G5) | yes |
| 6 | location, colour, time zone (G7..G9); the video link and busy / free are dropped (E3) | yes |
| 7 | search (G14) | yes |
| 8 | quick add (G12) | yes |
| 9 | duplicate (G11) | yes, WUI only |
| 10 | export `.ics` (G15) | yes |
| 11 | import `.ics`, subscribe link, push / e-mail reminders, e-mail invites | later |

## 7. Requirements

- **FR-001** Every 089 call keeps its body, answer and meaning; a body of 089
  fields only stores exactly what it stores today (c-394's "Add to calendar").
- **FR-002** `PATCH` / `DELETE` honour `If-Match: "<updated_at>"` with
  `409 edit_conflict`.
- **FR-003** An event holds up to 5 reminders (`amount` a whole number,
  `unit` minutes / hours / days, `method`);
  `remind_at` reads and writes as in 4.3; reminders stay pop-ups with no
  agent, AI or spool message.
- **FR-004** `rrule` (the 4.4 subset) repeats an event in its `time_zone`;
  range and marks reads expand series with exceptions and cancellations;
  `scope` on PATCH and DELETE does this / following / all.
- **FR-005** Guests (members and agents) answer yes / no / maybe through
  `/rsvp`, for themselves only; guests are kept in `mentions`.
- **FR-006** An invite, a change of time or place, and a cancel notify each
  guest once, unless `notify_guests: false`.
- **FR-007** `location`, `color`, `reminders` live in
  `props` behind a hub registry; an unknown key is `400`.
- **FR-008** Delete is soft; restore within 30 days; a named purge action.
- **FR-009** `GET /v1/calendar/search` filters by text, kind, guest, audience
  and date range, with the private and demo filters.
- **FR-010** Quick add parses the documented grammar, no AI, with `dry_run`.
- **FR-011** `GET /v1/calendar/export.ics` exports what the caller can read.
- **FR-012** `calendar_guests` is workspace-isolated by RLS and by its
  composite foreign key; `TestCrossTenantEveryTable` covers it.
- **FR-013** All of it stays out of the initial chunk (155 KB).

## 8. Acceptance

- **AC-01** c-394's body against the new hub: `201`, the event equals 089's
  shape plus the new fields at their defaults.
- **AC-02** Two `PATCH`es with the same `If-Match`: the second is `409` with
  the first one's result.
- **AC-03** An event with reminders 10 minutes and 1 day: `/reminders` answers
  two items and the event reads back `1 days`, not `1440 minutes`;
  `{"amount": 1.5, "unit": "hours"}` and `{"amount": 0, ...}` are `400`; an
  old body with `remind_at` 15 minutes before the start reads back
  `reminders = [{"amount": 15, "unit": "minutes", "method": "popup"}]`.
- **AC-04** `FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6` in `Europe/Helsinki` across the
  October daylight-saving change: six occurrences, all at 09:00 local; edit
  "this" moves one; delete "following" from the 4th leaves three; edit "all"
  moves the rest and keeps the moved one moved.
- **AC-05** A guest answers `maybe`; the owner sees it; a non-guest's rsvp is
  `403`; a private event is readable by its guests and nobody else.
- **AC-06** An invite with two guests (one human, one agent) makes one Flow
  item and one spool note; with `notify_guests: false` it makes none; a
  reminder still makes none.
- **AC-07** Delete, then Undo: the event is back with the same id; 30 days
  after a delete the purge action removes it.
- **AC-08** Workspace A cannot read, list guests of, search, restore or export
  workspace B's events (Postgres store test).
- **AC-09** Quick add "Standup every weekday 09:30 for 15m @<agent_id>"
  previews a weekday series with one agent guest.

## 9. Not in scope

Two-way sync with Google / Outlook / CalDAV, room and resource booking,
working-hours and out-of-office events, appointment schedules, tasks inside
the calendar, several calendars per person (the workspace has one calendar;
`kind` and `color` group events). Each can get its own spec if the owner asks.

## 10. Questions for the owner: all decided

Owner HUM-10 on t1 `70484be0`, msg `92b3e0d6`, 2026-10-06, verbatim: "as
proposed". Every row below is **DECIDED (as proposed).** With E1..E3
(section 0.1) the spec has no open question left.

| # | Question | Proposal | Decision |
|---|---|---|---|
| Q1 | Recurrence: our own small expander, or the MIT library `rrule-go`? | `rrule-go` (MIT, mature, handles daylight saving), wrapped so only the 4.4 subset gets in; one dependency, checked by the licence and vulnerability gates. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q2 | Can agents be guests and answer, like members? | Yes: agents are guests and answer through the CLI / MCP (`spool calendar rsvp`). | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q3 | 089 D4 says nothing is sent for reminders. May an **invitation** send a notice: a Flow item for a human, a spool note for an agent? | Yes, for invitations, changes and cancels only; reminders stay pop-ups with nothing sent. E-mail invites come later, opt-in per workspace. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q4 | Who may edit an event: anyone in the workspace (today), or only its owner and its guests? | Keep today's rule for `public` / `internal`; a per-event "guests can modify" switch later if wanted. A `private` event is already owner-and-guests only. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q5 | Should others see your `private` event as an anonymous "Busy" block, as Google shows it? | No: private stays invisible (089 4.2), and E3 drops busy / free altogether. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q6 | Trash: keep deleted events 30 days, then remove them for good? | Yes, 30 days, a workspace setting. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q7 | An `.ics` subscribe link (for a phone calendar app) needs a per-person secret in the URL. Wanted? | Later, not v1: a download in v1; the link only with a revocable token when asked for. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q8 | Quick add: a fixed English grammar, no AI? | Yes, fixed grammar, English first; other languages when the WUI locale needs them. | **DECIDED (as proposed).** msg `92b3e0d6` |
| Q9 | Event colours: Google's 11 named colours, or free colour codes? | The 11 named colours, mapped to theme variables, so dark mode stays readable. | **DECIDED (as proposed).** msg `92b3e0d6` |

## 11. Event tags with colours (SPL-5883)

Status: **decided, for the spec review**, v1.2, 2026-11-19: the owner
answered O1, O2, O3, O5 and O6 (msg `cde26d3f`, poll `c15f11e0`; 11.12).
Issue SPL-5883, epic SPL-2403. Discussion: t1 `f5778b9f` (#spool-hub-ui).

### 11.0 The owner's ask and the agreed scope

Owner HUM-10, t1 `f5778b9f`, 2026-11-18:

- msg `3ada46ca`: "basically one should be able to define different tags for
  the different type of events and each tag should be possible to have
  besireds the default color theme stripe color ..." (the full post is in
  the topic).
- msg `9884e085` (poll `f99b4cb2`): "No there should be a way to define the
  labels / tags for the ..." (full text in the topic).
- msg `62e387eb` (poll `2d3164e8`): "B — Several tags: all chips shown, the
  stripe takes the first tag's colour".
- msg `7f371baa`: "there should be also a way in each view to show only the
  events with specific labels or tags".

The agreed scope (dispatcher post `5a9f7682`), which this section builds:

1. each workspace defines its own event tags, each with a colour;
2. an event carries several tags, all chips shown; the left stripe takes the
   **first** tag's colour; an untagged event keeps the theme default;
3. every calendar view (Day, 3 days, Week, Month, To-do) gets a tag filter.

### 11.1 Measured before (tree `386b38058`)

| fact | where |
|---|---|
| an event has one fixed `kind`, seven values, widened to nine; no tag or label | `csi-spl-rdb/src/sql/postgres/spool-hub/0125_calendar.sql:24`, `0156_calendar_source_key.sql:31` |
| an event's own colour is `props.color`, one of 11 palette names | `internal/hub/calendar_props.go:45-53`; WUI `src/utils/calendar-event-form.mjs:49` (`CAL_COLORS`) |
| each palette name is a theme variable, dark family and light family | `csi-spl-wui/src/assets/css/variables.css:421` (dark, the default) and `:434` (light) |
| the stripe today is 4 px on a desktop timed block, 3 px on a Month item and on an all-day item, a dot on phone Day, Week and Month | `src/components/CalendarMainView.vue:715`, `:623`; `CalendarDeskMonth.vue:132`; `CalendarPhoneDay.vue:528-535`; `CalendarPhoneWeek.vue:121`; `CalendarPhoneMonth.vue:154` |
| the stripe colour is `--cal-ev-color` (the event's `color`), else `--color-accent` | `CalendarMainView.vue:529`, `:715` |
| issue labels: per workspace, `label_id` = slug of the name, free hex colour, create only (no rename, no delete), written by `notes.send` + `topics.manage` | `0047_issues.sql:33-41`; `internal/hub/issues.go:863` (`POST /v1/issue-labels`), `:928-933` (`issueWriter`), `:1188` |
| issue labels hold a system label, `epic`, with meaning in the hub | `0049_issue_epics.sql:20` |
| an event with a `source_key` (roadmap sync, Outlook import, Google import) is read-only to a member PATCH and DELETE | `internal/hub/calendar.go:1064`, `:1164` (`synced_read_only`) |
| the sync upsert rewrites a fixed column list | `internal/store/calendar_sync.go:208-212` |
| the To-do view lists **issues** (open tasks with a deadline), never events | `src/components/CalendarTodoView.vue:1-13`, `:91` (`listIssues`) |
| the view state is in the URL: `v` (view), `d` (day), `k=todo`, `event` | `src/pages/calendar.vue:80-116` |
| the range read also returns issue deadlines (`source: issue`) and official days | `src/types/calendar-shims.d.ts:21-22` |
| a channel move copies its calendar events; the issue label catalogue is re-created by name in the target | `internal/channelmove/catalogue.go:95`, `:183` |
| migration head | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -1` -> `0295_hours_prices_commit_ledger.sql` |
| locales | `ls csi-spl-wui/i18n/locales \| wc -l` -> 19 |

### 11.2 Decision: event tags are their own table, not issue labels

Event tags get their own catalogue, `calendar_tags`. Issue labels are not
reused. Why:

1. **Colour.** Issue labels take any hex colour (`0047:38`). A calendar
   colour must read in both themes, which is why Q9 chose the 11 named
   colours, each a light and a dark variable (`variables.css:421`, `:434`).
   A tag takes the same 11 names, so the stripe and the chips follow the
   theme with no new colour code.
2. **Rename and delete.** An issue label's id is the slug of its name and
   there is no edit or delete route. The owner asks to *define* tags
   (msg `9884e085`), which means rename, recolour and delete. Adding those
   to issue labels would change every issue that carries one.
3. **Meaning.** `epic` is a system label with hub behaviour (`0049:20`). An
   event tagged `epic`, or an Issues label picker full of `standup` and
   `travel`, mixes two catalogues the owner keeps apart ("tags for the
   different type of events").
4. **Isolation and who may write.** A separate table gets its own RLS and
   its own permission line (11.5). Issue labels need `topics.manage`, which
   many calendar writers do not hold.

Cost of the choice: the To-do view lists issues, which carry issue labels,
not event tags. Its filter therefore filters by **issue labels** (11.8.3);
the owner confirmed it (O3 = A, msg `cde26d3f`).

### 11.3 Data model

Migration `rdb/NNNN_calendar_tags.sql`, forward-only and additive. It is not
written by this spec: the build lane takes the number with
`cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (head on
`386b38058`: 0295).

```sql
CREATE TABLE calendar_tags (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    tag_id     text        NOT NULL CHECK (tag_id ~ '^[0-9a-f]{8}$'),   -- minted by the hub
    name       text        NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
    color      text        NOT NULL CHECK (color IN ('tomato', 'flamingo', 'tangerine', 'banana', 'sage',
                               'basil', 'peacock', 'blueberry', 'lavender', 'grape', 'graphite')),
    position   integer     NOT NULL DEFAULT 0 CHECK (position >= 0),     -- order in the catalogue
    created_by text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, tag_id)
);
CREATE UNIQUE INDEX calendar_tags_name ON calendar_tags (tenant_id, lower(name));

ALTER TABLE calendar_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_tags FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON calendar_tags
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON calendar_tags
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- the event's tags, IN ORDER: tag_ids[1] is the first tag, the one the stripe shows
ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS tag_ids text[] NOT NULL DEFAULT '{}'
    CHECK (cardinality(tag_ids) <= 10);
```

- **The order is the array's order.** `tag_ids[1]` is the first tag. The
  hub stores the list as the writer sent it, duplicates removed (first one
  kept). A join table would need a position column and an aggregate on the
  range read (up to 2000 occurrences, 4.4); an ordered `text[]` is the form
  `mentions` (0125) and `issue_keys` (0247) already use.
- **A column, not `props`.** Tags are filtered in SQL (11.8), so by 3's rule
  (098's promotion rule) they are a column, not a `props` key.
- **No `tag_ids` index in T1** (v1.2, R7 finding W1 of c-318, decision (a)
  of c-001 msg `7f1d9e7b`). A GIN on `tag_ids` cannot serve `tag_ids @> $1`:
  `calendar_events` forces RLS and `arraycontains` is not LEAKPROOF, so the
  planner keeps `@>` in the heap Filter, never in the Index Cond (the rdb
  0081 lesson). Row T6 adds any index together with the access path that can
  use it (e.g. a SECURITY DEFINER door, as 0143), in its own migration, with
  an EXPLAIN under FORCE RLS as its proof.
- **Integrity.** An array has no foreign key. The hub checks on every write
  that each id is a tag of the event's workspace (else `400 unknown_tag`),
  as it does for issue labels (`0047:59`). A tag delete strips the id from
  every event of the workspace, trashed rows included, in the same
  transaction (11.5).
- **Recurrence.** `tag_ids` is a column of the series row; an exception row
  (4.4) gets the series' list when it is created. A PATCH with
  `scope=all` changes the exceptions that did not change their own tags,
  the 4.4 rule for every field.
- **Limits.** At most 10 tags per event, at most 100 tags per workspace
  (hub check, `400 too_many_tags`), names unique per workspace ignoring
  case (`409 tag_exists`).
- **Workspace isolation.** The same commit seeds `calendar_tags` in
  `seedTenantAll` (`internal/store/crosstenant_test.go`), or
  `TestCrossTenantEveryTable` turns trunk red; `TestRLSCoversEveryTenantTable`
  sees the new policy.
- Deploy order as 3.1: the migration before the hub that reads it. The
  column has a constant default, so the add is catalogue-only.

### 11.4 API

All routes keep 4's conventions (JSON, `""` for unset, arrays never `null`,
the `{"error", "detail"}` refusal, `403 demo_read_only` for a demo visitor).

#### 11.4.1 The tag catalogue

| route | who | body / answer |
|---|---|---|
| `GET /v1/calendar/tags` | `topics.read` | `200 {"tags": [{"id", "name", "color", "position", "events"}]}` in `position`, then name order; `events` is how many live events carry it |
| `POST /v1/calendar/tags` | 11.5 | `{"name", "color"}` -> `201 {"tag": ...}`; the hub mints `id` (8 hex, retried on a clash) and puts it last |
| `PATCH /v1/calendar/tags/{id}` | 11.5 | any of `{"name", "color", "position"}` -> `200 {"tag": ...}`; moving one renumbers the others |
| `DELETE /v1/calendar/tags/{id}` | 11.5 | `200 {"tag": ..., "events": <n stripped>}`; strips the id from every event of the workspace |

Refusals: a name of 0 or more than 40 characters, or a colour that is not
one of the 11 names, is `400 bad_tag`; a second tag with the same name
(case ignored) is `409 tag_exists`; the 101st tag is `400 too_many_tags`;
an id of another workspace is `404`. Unknown body fields are refused
(`DisallowUnknownFields`, as the event body, `calendar.go:555-560`).

#### 11.4.2 Tags on an event

- **Read.** The event object (4.1) gains
  `tags: [{"id", "name", "color"}]`, in the event's order, `[]` when none.
  The hub reads the workspace's catalogue once per request (at most 100
  rows) and fills the objects in Go, so a client needs no second call and
  an event of another workspace shown in My calendar (spec 119) carries its
  own workspace's names and colours.
- **Write on create and PATCH.** `calendarRequest` gains
  `tags *[]string` (ids). Nil on PATCH keeps the stored list; `[]` clears
  it. The order sent is the order kept.
- **Write on a synced event.** `PUT /v1/calendar/events/{id}/tags`
  `{"tags": ["<id>", ...]}` -> `200 {"event": ...}`. It is the one write a
  member may make on an event with a `source_key` (Outlook import, Google
  import, roadmap sync; today all `409 synced_read_only`, `calendar.go:1064`):
  tags are this workspace's own data and no sync writes them. It honours
  `If-Match` and `?scope=` as 4.2 and 4.4. On an event without a
  `source_key` it does the same as a PATCH with only `tags`.
- **Every sync keeps the tags.** `tag_ids` is never in the upsert's
  `UPDATE SET` (`calendar_sync.go:208`), in the Outlook import
  (`store/calendar_import.go`) or in the Google in-half
  (`hub/gcal_sync_in.go`, `hub/gcal_sync_sources.go`). A soft-delete by a
  sync and a restore by the same key keep them too.
- **The private filter is unchanged.** A tag says nothing about who reads
  the event.

#### 11.4.3 The filter on the reads

`GET /v1/calendar/events`, `GET /v1/calendar/marks` and
`GET /v1/calendar/search` take `tags=<id>,<id>,...` (at most 20 ids) and
the pseudo id `none`:

- **all, not any** (O2 = B, owner msg `cde26d3f`): an event matches when it
  carries **every** chosen id, `tag_ids @> $1` (array contains; T1 has
  no index for it, and T6 brings one only with an access path that uses it,
  11.3). Two tags chosen narrow the
  calendar, they never widen it;
- `none` matches an event with no tag (`cardinality(tag_ids) = 0`) and is
  **only valid alone**: `tags=none,<id>` is `400 bad_tags_filter`. Why: under
  "all", "no tag and tag X" can match nothing, so allowing it would only ever
  show an empty calendar. The WUI never sends it: "No tag" and the tags are
  exclusive in the control (11.8.1);
- an unknown id is ignored (a link that names a deleted tag still opens). It
  is dropped from `$1` before the query, so it does not empty the answer; a
  list of unknown ids only is no filter, and the read answers as without
  `tags`;
- with `tags` set, the range read returns no issue deadlines
  (`source: issue`): an issue carries issue labels, not event tags. Official
  days stay: they are the day's background, not events;
- without `tags`, every read answers exactly as today.

#### 11.4.4 Agents

- `spool calendar tags` (list) and `--tags <id|name>,...` on the CLI's
  create and edit; the MCP tools `calendar_tags_list` and a `tags` argument
  on the create and update tools (089 T005's surface).
- The operator routes (4.10) take `tags` as **names**, resolved in the
  workspace; an unknown name is `400 unknown_tag`, never created by an agent.
  Actions: `do_spl_calendar_event_add` and `do_spl_calendar_event_update`
  take `TAGS=<name>,<name>` (order kept); the read-back line prints them.
- An agent does not create, rename or delete tags (11.5).

### 11.5 The tag manager: who may do what

| act | needs | why |
|---|---|---|
| see the catalogue, filter by tag | `topics.read` | as every calendar read |
| put tags on an event, reorder them | the right to edit that event (section 10, Q4) | a tag is a field of the event |
| tag a synced event (11.4.2) | `notes.send` and read access to the event | the event is otherwise read-only |
| create a tag | `notes.send` | as issue labels today: whoever writes events may make the tag they need |
| rename, recolour, reorder a tag | `notes.send` | the change is visible and harmless; nothing is lost |
| delete a tag | `channels.manage` | it strips the tag from every event of the workspace, which nobody can undo |

Agents: none of the catalogue writes. The catalogue routes are member
routes, resolved with `humanTenant` as `issueWriter` does
(`issues.go:922-924`), so an agent token is refused.

**Decided** (O1 = A, owner msg `cde26d3f`): any member who writes events
(`notes.send`) creates, renames, recolours and reorders a tag; deleting a
tag stays admin-only (`channels.manage`). The table above is the rule.

**The manager in the WUI.** A "Tags" item in the calendar's ... menu
(`MENU_ITEMS`, beside Trash and Export) opens `CalendarTags.vue` (lazy
chunk): one row per tag with a colour swatch, the name (edit in place), the
count of events, drag handle (desktop) or up / down buttons (phone) for the
order, and Delete. Delete asks first, naming the count ("Remove the tag
*Travel* from 12 events?"). A member without `channels.manage` does not see
Delete. "+ New tag" adds a row with the next unused colour. On a phone it is
a full-screen sheet (the rule of 5.1, item 6, Event details), rows and buttons at least 44 px.

### 11.6 The event editor's tag picker

In `CalendarEventDialog.vue`, a "Tags" field below the colour swatches:

- the chosen tags as chips in their order, each with its colour, its name
  and a remove button (44 px tap target on a phone);
- "+ Add tag" opens a search list of the catalogue (type to filter, Enter
  picks); the list ends with "Create tag "<typed text>"" for a member who may
  create (11.5), which creates it with the next unused colour and adds it;
- **order**: a picked tag goes last. On desktop the chips reorder by drag;
  on every screen each chip that is not first has a "Make first" action in
  its menu, because the first tag sets the stripe. A hint under the field
  says so: "The first tag colours the event";
- Duplicate (G11) copies the tags in their order; quick add (4.6) is
  unchanged in v1 (`#word` stays the kind).

For a synced event the dialog is read-only today; it keeps that and shows
the Tags field as the one editable field, saved with `PUT .../tags`.

### 11.7 The stripe and the chips in every view

**One stripe rule.** A new token `--cal-stripe-w: 5px` (variables.css)
replaces the three widths of 11.1, and a new variable `--cal-stripe-color`
is set per event:

1. the first tag's colour, `var(--cal-color-<tags[0].color>)`;
2. else the event's own `color` (`--cal-ev-color`);
3. else the theme default, `--color-accent`.

The block's tint (`color-mix(... 20%, var(--color-bg))`,
`CalendarMainView.vue:716`) keeps using the event's own colour, else the
accent, so the text contrast tests of SPL-4060 stay valid. That the first
tag beats the event's own colour for the stripe is **DECIDED** by the
owner (msg `62e387eb`: "the stripe takes the first tag's colour"); it is
not asked again (it was O4, dropped from 11.12).

**The chips.** A chip is the tag name on
`color-mix(in srgb, var(--cal-color-<c>) 20%, var(--color-bg))` with a
6 px dot of the full colour, text `--color-fg`; the same mix the blocks
already pass at 4.5:1 in both themes. Light and dark come from the palette
variables, no per-theme code.

| view | stripe | chips |
|---|---|---|
| desktop Day, 3 days, Week: timed block | 5 px, first tag | under the title when the block is three lines tall or more; as many as fit, then `+n` |
| desktop Day, 3 days, Week: all-day row | 5 px inset (was 3 px, `:623`) | as many as fit after the title, then `+n` |
| desktop Month: day cell item | 5 px (was 3 px, `CalendarDeskMonth.vue:132`) | none (one line per event); the pop-over shows all |
| event pop-over (desktop), peek and sheet (phone) | 5 px on the header | **all** chips, wrapped |
| phone Day | the event's dot takes the first tag's colour; the block gets the 5 px stripe | as many as fit on the second line, then `+n` |
| phone Week and Month (dots and agenda) | dots take the first tag's colour | agenda rows: as many as fit, then `+n` |
| phone Year | unchanged (day marks only) | none |
| search results (desktop and phone) | 5 px | all, wrapped |
| To-do (issues) | unchanged | the issue's labels, as the Issues view shows them |

"All chips shown" (owner `62e387eb`) holds wherever the event is opened;
on a grid block the space is a few pixels, so `+n` stands for the rest and
its title lists them. An untagged event looks as today, but with the
5 px stripe.

### 11.8 The filter in every view

#### 11.8.1 The control

A "Tags" filter button in the calendar header (`CalendarViewTabs.vue`,
desktop; the phone header, spec 106), so every view of the tab has it and
switching view keeps it. It opens a list of the catalogue with a check per
tag, plus "No tag" (untagged events) and "Clear". "No tag" is exclusive:
ticking it unticks every tag, and ticking a tag unticks "No tag" (11.4.3,
`none` only alone). The list's header says the rule: "Events with all the
chosen tags". With a filter on, the
button shows the count (`Tags · 2`) and a strip of the chosen chips sits
under the header, each with a remove x, so the filter is never invisible.
On a phone the list is a bottom sheet with 44 px rows.

#### 11.8.2 Where it lives: the URL, and remembered for you

**The URL.** The filter is the query parameter `tags`, beside `v`, `d` and
`k` (`pages/calendar.vue:89-100`): `?v=month&tags=1a2b3c4d,5e6f7a8b`, and
`tags=none` for untagged. A reload, Back and a shared link keep it. The WUI
passes it to the range read, the marks read and search (11.4.3), so the
year strip and the phone Month dots count only the matching events.

**Remembered across visits** (O5 = B, owner msg `cde26d3f`). The last filter
a member chose is kept for that member and applied when they open Calendar
again, on any device.

Measured first, tree `86572482f`: what already keeps a member's view choices.

| command | printed | reading |
|---|---|---|
| `grep -n 'preferences"' csi-spl-api/.../internal/auth/handler.go` | `:294 mux.HandleFunc("PUT "+RoutePrefix+"preferences", h.putPreferences)` | one write route for every member preference (`RoutePrefix` = `/api/v1/auth/`, `handler.go:26`) |
| `sed -n 1112,1138p auth/handler.go` | `preferencesReq`: 25 keys, `issues_sort`, `pane_sizes`, `time_zone`, `await_anims`, ... | the body grows by one key per preference |
| `sed -n 1431p auth/handler.go` | "issues_sort, pane_sizes, time_zone, keyboard_shortcuts, hours_reading, await_anims and second_currency have no humans column: they live ONLY here" | a per-workspace-only key needs no new column |
| `sed -n 16,31p csi-spl-rdb/.../0078_membership_settings.sql` | `tenant_memberships.settings jsonb`, "a channel id ... only means something inside its tenant" | the per-workspace store, one JSON object per member and workspace |
| `grep -n 'type MembershipSettings' auth/settings.go` | `:67` | the decoded keys; `store/membership_settings.go:85` (Postgres) and `:125` (memory) write a patch |
| `grep -n 'function mirror' csi-spl-wui/src/stores/session.ts` | `:141` | the WUI reads the keys as session claims and mirrors a save (`setIssuesSort`, `:186`) |
| `sed -n 9,13p csi-spl-wui/src/composables/useIssueListUrl.ts` | "A URL with `view=` is a complete link ... the reader's stored choices do not apply. A URL without it ... takes the stored choices, and the address is then completed with them." | the precedent for link versus remembered |
| `grep -rn localStorage csi-spl-wui/src --include=*.vue --include=*.ts --include=*.mjs \| wc -l` | `184` | browser storage is used for per-browser conveniences: the calendar's hours panel (`pages/calendar.vue:124`), the phone view (`CalendarPhone.vue:285`), the Issues folds (`useIssueFilters.ts:142`, "a per-browser convenience (localStorage), not a hub setting") |
| `grep -n 'calendar' auth/settings.go` | nothing | no calendar preference is kept today |

The decision, from that measurement:

- **Where.** A new key `calendar_filter` in the member's per-workspace
  settings (`tenant_memberships.settings`, rdb 0078), written by the
  existing `PUT /api/v1/auth/preferences` and read back as the session
  claim `calendar_filter`. **No new table and no migration**: the column
  admits any known key (0078's CHECK only pins a JSON object), and the hub
  admits a new key by its parse (row T16). Not `localStorage`: the owner's
  "remembered for you across visits" means the member, not the browser,
  and a phone and a desktop must agree.
- **Per workspace, not global.** A tag id only means something inside its
  workspace (11.3), as a channel id does (0078's own reason). Like
  `time_zone`, the key has no humans-row global; outside a workspace it is
  not stored (`handler.go:1448-1454`).
- **Shape.** `{"tags": ["<id>", ...] | ["none"], "labels": ["<label_id>", ...]}`,
  at most 20 of each, ids as 11.4.3 and the issue labels' `label_id`;
  `null` forgets it. A malformed value is `400 unsupported_calendar_filter`.
  `labels` is the To-do filter (11.8.3), remembered by the same rule, so one
  meaning holds for the whole Calendar tab.
- **When it is saved.** Only a change made with the control (tick, untick,
  the strip's x, Clear) saves it, debounced to one PUT per second. Opening
  a link never saves: a shared link does not overwrite the reader's own
  filter.
- **The link wins.** A URL that carries `tags` (or `labels` in To-do)
  applies exactly that and ignores the remembered filter, so a shared link
  shows the reader what the sender saw. A URL without it takes the
  remembered filter, and the address is completed with it
  (`router.replace`), the Issues list's rule (`useIssueListUrl.ts:9-13`).
  The chip strip (11.8.1) shows it, so a remembered filter is never
  invisible.
- **Clear** empties the filter, removes `tags` / `labels` from the URL and
  saves `calendar_filter: null`: the next visit shows everything.
- **A deleted tag.** The tag delete (11.4.1) does not touch any member's
  settings (it would write every member's row). Instead the read ignores an
  unknown id (11.4.3), and the WUI drops ids that are not in the catalogue
  when it applies the remembered filter, then saves the pruned list once.
  When nothing is left, the filter is off, never an empty calendar.

#### 11.8.3 Per view

| view | what the filter does |
|---|---|
| Day, 3 days, Week, Month (desktop and phone), phone Year marks, search | shows only events carrying **every** chosen tag (or no tag, for "No tag", alone); issue deadlines are hidden while a filter is on; official days stay |
| To-do (`?k=todo`) | **decided** (O3 = A, owner msg `cde26d3f`): its rows are issues, so the same button lists the workspace's **issue labels** instead, parameter `labels=<label_id>,...`; a task shows when it carries **every** chosen label, the same "all" rule as the tags (O2), so the filter has one meaning in every view. The hub's issue list matches `label=a,b` as **any** today (`hub/issues.go:605`, `:681` `allowsAny`), so To-do asks with `label_match=all` (row T17); the Issues view keeps "any". `tags` is kept in the URL but not applied to To-do; switching back to an event view applies it again |

An empty result says so ("No events with these tags in this range") with a
Clear button.

### 11.9 Imports and syncs (spec 180, spec 149)

- **v1: no tags come in.** The Outlook export has no category field
  (spec 180 FR-1) and the Google in-half reads no `colorId`. An imported
  event arrives untagged.
- **A member may tag an imported event** with `PUT .../tags` (11.4.2), and
  every later import, sync, soft-delete and restore keeps those tags
  (11.4.2, "Every sync keeps the tags"). This is what makes tags useful on
  the owner's imported Outlook meetings.
- **Out to Google**: tags are not sent in v1. **Later** (O6 = A, owner msg
  `cde26d3f`, row T15 after T11): the out half sets the Google event's
  `colorId` from the first tag's colour. Google has the same 11 colour
  names, so it is a fixed name -> id map. Today no colour goes out:
  `grep -rn colorId csi-spl-api/src/go/spool-hub-api/internal` -> nothing.
- **Later, on the owner's ask**: an Outlook category -> a tag of the same
  name (created when missing), which needs the export to add `categories`
  (spec 180 FR-1 is "no body, no attendees" only, so it is allowed).
- **Channel move** (`channelmove/catalogue.go`): a moved event's tags are
  re-created by name in the target workspace's catalogue and the ids
  rewritten, as T5b does for issue labels (`catalogue.go:183`).

### 11.10 UI text

New keys under `calendar_tags.*` (manager, picker, filter, empty and error
texts, the delete question with its count), in `en.json` and in each of the
other 18 locales in the same commit (`i18n-parity.test.mjs`). Outside
English they are drafts; **an agy review is the last step before any of
them ships** (the language rule). The tag *names* are the workspace's own
data and are never translated.

### 11.11 Build rows

Smallest and most depended-on first. Each row lands with its test and a red
control (seen red on the planted defect, then green, both in the commit
body), its docs, and cites SPL-5883.

| # | row | depends | test | red control |
|---|---|---|---|---|
| T1 | migration `NNNN_calendar_tags.sql` (11.3); seed `calendar_tags` in `seedTenantAll` | - | `lint-migration`; `TestCrossTenantEveryTable`, `TestRLSCoversEveryTenantTable` on Postgres (`PRE_PUSH_TIER=full`) | leave the seed out: `TestCrossTenantEveryTable` red |
| T2 | store: tag catalogue CRUD, `tag_ids` read and write, delete strips every event, both stores | T1 | `store/calendar_tags_test.go` (memory and Postgres): order kept, duplicate dropped, delete strips trashed rows too | delete without the strip: the stripped-count test red |
| T3 | store: syncs keep tags (`calendar_sync.go`, `calendar_import.go`, `gcal_import.go`) | T2 | a tagged synced row re-synced with a changed title keeps its `tag_ids` | add `tag_ids = EXCLUDED.tag_ids` to the upsert: red |
| T4 | hub: `/v1/calendar/tags` routes and the 11.5 permissions | T2 | `hub/calendar_tags_test.go`: 201 / 409 / 400 / 404, delete needs `channels.manage`, an agent token refused | drop the `channels.manage` check: the 403 case red |
| T5 | hub: `tags` on the event (read objects, create, PATCH), `PUT .../tags` on a synced event, `unknown_tag` | T3, T4 | create with two tags reads back in order; a synced event takes `PUT .../tags` but still refuses PATCH | allow PATCH on a synced event: the 409 case red |
| T6 | hub: `tags=` and `none` on events, marks, search (11.4.3): **all** (`tag_ids @> $1`), `none` alone, unknown ids dropped | T5 | filter of two tags returns only events carrying both (an event with one of them is left out); `none` alone; `none,<id>` -> `400 bad_tags_filter`; unknown ids only = the unfiltered answer; issue deadlines left out; no `tags` = byte-identical answer to before | turn `@>` into `&&`: the "all" case (event with one of two tags left out) red |
| T7 | operator, CLI and MCP: `TAGS=` on `do_spl_calendar_event_add` / `_update`, `spool calendar tags` | T5 | `spl-calendar-event-add.tst.sh`, `spl-calendar-event-update.tst.sh` (names resolved, order kept, unknown name refused before any write) | resolve names without the workspace scope: the cross-workspace case red |
| T8 | channel move maps tags by name (11.9) | T2 | `channelmove` test: a moved tagged event keeps its tag names in the target | skip the mapping: red |
| T9 | WUI: tags API client and mock, `CalendarTags.vue` manager (11.5) | T4 | unit `calendar-tags.test.mjs`; e2e create, rename, reorder, delete at 1440, 360, 390 px | show Delete to a member without `channels.manage`: e2e red |
| T10 | WUI: the editor's tag picker, order, Make first, create from the picker, synced-event save (11.6) | T5, T9 | unit for the order logic; e2e pick two, make the second first, save, reopen | append instead of moving to first: red |
| T11 | WUI: `--cal-stripe-w` 5 px, `--cal-stripe-color` (11.7 rule), chips in every view of 11.7's table | T10 | e2e in every view, both themes, 1440 / 360 / 390 px: stripe 5 px of the first tag, chips or `+n`, `xScroll <= 1 px`; contrast unit test of each chip mix | set the stripe from the last tag: red |
| T12 | WUI: the filter button ("No tag" exclusive), chip strip, `tags` and `labels` URL params, every view (11.8); the remembered filter (11.8.2): applied when the URL has none, the link wins, saved only on a control change, Clear forgets, unknown ids pruned; To-do asks `label_match=all` | T6, T11, T16, T17 | unit for the URL round trip and the precedence (link > remembered > none); e2e per view: filter, reload keeps it, a fresh visit without `tags` gets the remembered filter, a link with `tags` shows the link's, Clear then a fresh visit shows everything, To-do filters by every chosen issue label | drop `tags` from `router.replace`: the reload case red; apply the remembered filter over a link's `tags`: the link case red |
| T13 | i18n: `calendar_tags.*` in 19 locales; **agy review** of the 18 drafts | T9..T12 | `i18n-parity`, `i18n-untranslated`, `i18n-no-raw-text` | a key missing in one locale: parity red |
| T14 | help: `csi-spl-doc/doc/help/calendar.md` gains Tags (manage, pick, filter, "all chosen tags", remembered for you, the link wins), then the help sync (`csi-spl-wui/src/node/help/sync-help.mjs`) | T12 | new unit `csi-spl-wui/tests/unit/help-calendar-tags.test.mjs`: the synced help page has a Tags heading naming the manager, the picker, the filter and the `tags=` link | delete the Tags heading from `calendar.md`: the test red |
| T15 | **later** (O6): Google out sync sets `colorId` from the first tag's colour (spec 149 2.5, `hub/gcal_map.go:49` `GcalEventOf`); the colour joins the sync hash (`gcal_map.go:27`) only when set, so an untagged event hashes as before and no event is rewritten for nothing; an untagged event sends no `colorId`; spec 180's Outlook path is unchanged | T11 | `hub/gcal_map_test.go`: each of the 11 names maps to its Google id (the map pinned in the test, checked once against Google's `colors.get` by the builder); a tagged event carries the first tag's id; retagging changes the hash; an untagged event's hash equals the pre-T15 value | take the last tag instead of the first: red; leave the colour out of the hash: the retag case red |
| T16 | hub: the `calendar_filter` preference (11.8.2): `preferencesReq` key, parse (shape, at most 20 + 20, `none` alone), stored only in `tenant_memberships.settings` (no humans column, as `time_zone`), `null` forgets, the session claim; WUI session store `setCalendarFilter` mirror | - | `auth/preferences_test.go`: PUT then GET `/session` returns it in that workspace and not in another; `null` clears; a bad shape is `400 unsupported_calendar_filter`; no active workspace = not stored | write it to the humans row instead of the membership: the other-workspace case red |
| T17 | hub: `label_match=all` on `GET /v1/view/issues` (default `any`, today's answer unchanged; `issues.go:681`) | - | `hub/issues_*_test.go`: `label=a,b&label_match=all` returns only issues with both; without it, issues with either (unchanged) | use `allowsAny` for `all`: red |

### 11.12 Owner answers: all decided

Owner HUM-10, t1 `f5778b9f`, msg `cde26d3f-0bce-427d-8241-62553e073d83`
(poll `c15f11e0`), 2026-11-19: "Answer 1: A ... Answer 2: B ... Answer 3:
A ... Answer 4: B ... Answer 5: A". The poll's five questions are this
table's rows in order.

| # | question | A | B | proposal | decision | where |
|---|---|---|---|---|---|---|
| O1 | Who may create a tag? | any member who writes events | admins only (`channels.manage`) | A (delete stays admin-only) | **A, as proposed**: any member who writes events; delete stays admin-only | 11.5 |
| O2 | Two tags chosen in the filter show events with... | any of them | all of them | A | **B, all of them** (not the proposal): `tag_ids @> $1`; `none` only alone | 11.4.3, 11.8.1, 11.8.3, T6 |
| O3 | The To-do view lists issues. Its filter uses... | the issue labels | no filter in To-do | A | **A, as proposed**: the issue labels, also "all" (`label_match=all`) | 11.2, 11.8.3, T12, T17 |
| O5 | The chosen filter is kept... | in the link only (reload, Back, a shared link) | also remembered for you across visits | A | **B, also remembered** (not the proposal): per member and workspace in `tenant_memberships.settings`; the link wins | 11.8.2, T12, T16 |
| O6 | Send the first tag's colour to Google Calendar with the event? | yes | no | A, as a later row after T11 | **A, as proposed**: later, row T15 | 11.9, T15 |


## 12. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v1.4 | 2026-11-21 | c-610 | Section 5.2: the label is drawn lower case in capitalized day headers and has its own band on the phone Month, never over the day number (R7 c-709 W1, W2); the phone search headings carry it too. SPL-6146. |
| v1.3 | 2026-11-21 | c-610 | Section 5.2: the ISO week as a `w-NN` label beside the day number in every view (owner msg `3d289c5c`), never an event. SPL-6146. |
| v1.2 | 2026-11-19 | c-852 | Section 11.3: no `tag_ids` index in T1 (R7 finding W1 of c-318 on T1: under FORCE RLS a non-LEAKPROOF `@>` never reaches a GIN's Index Cond; decision (a) of c-001, msg `7f1d9e7b`); T6 adds any index with the access path that can use it, in its own migration, proved by an EXPLAIN under FORCE RLS. 11.4.3 points to it. SPL-5945. |
| v1.1 | 2026-11-19 | c-836 | Section 11: the owner's answers (msg `cde26d3f`, poll `c15f11e0`) written in. O1 A: any member who writes events creates tags, delete stays admin-only (11.5). O2 B: the filter matches events with ALL chosen tags (`@>`), `none` only alone, unknown ids dropped (11.4.3, 11.8); T6's test and red control flipped. O3 A: To-do filters by issue labels, also "all" (`label_match=all`, new T17). O5 B: the filter is also remembered per member and workspace in `tenant_memberships.settings` (rdb 0078, no new table), the link wins, Clear forgets, deleted tags pruned (11.8.2, measured on `86572482f`; new T16, T12 grows). O6 A: later row T15, the first tag's colour as Google `colorId`. 11.12 is now "Owner answers". SPL-5883. |
| v1.0 | 2026-11-19 | c-702 | Section 11: event tags with colours per workspace (own `calendar_tags` table, not issue labels, and why), ordered `tag_ids` on the event (the first tag sets the 5 px stripe), the tags API and the one write allowed on a synced event, the tag manager and its permissions, the editor's picker, chips in every view, the filter in every view (`tags` in the URL; To-do filters by issue labels), imports keep tags, build rows T1..T14, owner questions O1, O2, O3, O5, O6 (O4 dropped: DECIDED by the owner, msg `62e387eb`, 11.7). Review fixes W1..W5 of m-707. SPL-5883. |
| v0.9 | 2026-11-16 | c-647 | An agent changes or deletes a private entry an agent made for a member (`ordered_by` in its mentions), never a person's own or another person's (4.10, rule marked owner may change); operator PATCH takes title, description, times and reminders; `do_spl_calendar_event_update`. SPL-5720. |
| v0.8 | 2026-11-16 | c-628 | `REMINDERS` on `do_spl_calendar_event_add`: an agent's event carries pop-up reminders (4.10). SPL-5718. |
| v0.7 | 2026-11-14 | c-437 | A private event from an agent through the operator routes: mention checks, the creator-only `?as=` read-back, `AUDIENCE` / `MENTIONS` on `do_spl_calendar_event_add` (4.10). SPL-5498. |
| v0.6 | 2026-11-13 | c-687 | The order of a day's events in every view, whole-day then `pinned` first (3.3.1); the `pinned` props key; the operator pin and delete routes and actions (4.10). SPL-5453. |
| v0.5 | 2026-10-28 | g-523 | Discussion link, issue keys and one owner on every calendar entry (SPL-4043). Catalogue strings in all 19 locales; outside English they are drafts, and an agy review has the last word on the wording. |
| v0.4 | 2026-10-06 | a-424 | Mobile-first section 5.1 (phone layout, touch gestures, full-screen dialogs, thumb reach, 360/390 px acceptance checks for all 10 v1 features, owner questions M1..M5); owner HUM-10 approved feature list and mobile-first rule (msg `adf16567`). |
| v0.3 | 2026-10-06 | c-363 | Owner answered Q1..Q9 "as proposed" (msg `92b3e0d6`): every row of section 10 DECIDED as proposed; with E1..E3 the spec is fully decided. |
| v0.2 | 2026-10-06 | c-397 | Owner decisions E1..E3 (section 0.1): v1 list approved; reminders are a typed whole number of minutes / hours / days (up to 5); video-call link and busy / free dropped. Q1..Q9 still open. |
| v0.1 | 2026-10-06 | c-397 | Gap analysis against Google Calendar (G1..G15); additive DDL (jsonb `props` under the 098 promotion rule, recurrence columns, soft delete, `calendar_guests`); the calls; the WUI surface; ranking and v1 line; Q1..Q9. |

<!-- version: 1.3 · updated: 2026-11-21 -->
