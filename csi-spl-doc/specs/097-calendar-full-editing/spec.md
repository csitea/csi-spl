# 097 Calendar: full editing, Google Calendar style

Status: **v0.4, 2026-10-06: mobile-first specification added.** The owner approved
the v1 feature list (section 0.1, E1..E3) and answered Q1..Q9 "as proposed"
(section 10, msg `92b3e0d6`). Mobile-first section 5.1 defines phone layout,
touch interactions, and 360/390 px acceptance checks for all 10 features, with
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

An unknown key is `400 bad_event`. A key added later is one registry line and
a test, no DDL. The size check (16 KB) keeps a row small.

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
  event); a guest who may not edit can still answer (Q4).

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

### 5.1 Mobile first

Mobile first (owner HUM-10 msg `8d181e85`, t1 `70484be0`; mobile channel
`#spool-hub-mobile` `52aee116-fe6a-4776-bc5c-0076b40cbc56`, c-002 msg `5c1a9e2d`):
the screens and interactions are designed for the phone first (viewport <= 820 px,
mobile stack Level 2 per spec 089 section 2.2). **Where phone and desktop
conflict, the phone wins.**

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
  floats for 10 seconds. On a phone, it is anchored **directly above the calendar's
  bottom navigation bar and composer dock**:
  `bottom: calc(var(--cal-bottom-bar-h, 48px) + var(--composer-dock-h, 0px) + 8px)`,
  spanning the width with 8 px side margins. It leaves the Today/prev/next controls
  and the iOS home indicator fully visible and accessible. The "Undo" action button
  has a >= 44 px touch target.
- **How it differs from desktop:** Desktop toast floats at the bottom-left or
  center of the screen. On a phone, a bottom toast would collide with the sticky
  bottom toolbar or iOS home gesture zone; phone positions it safely above the
  bottom bar without obstructing date navigation.
- **Acceptance check (360 px and 390 px widths):**
  - **360 px:** Undo bar sits above bottom bar with >= 8 px separation; Today,
    prev, next buttons remain 100% visible and clickable while Undo bar is shown;
    Undo button has >= 44 px touch target; tapping Undo restores event within 10 s;
    bar auto-dismisses after 10 s; `xScroll <= 1 px`.
  - **390 px:** Tested at 390x844; toast width is 374 px (390 px minus margins);
    zero overlap with bottom navigation or system gesture areas.

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
| M4 | When an event is deleted, should the 10-second Undo toast float immediately above the Calendar bottom toolbar (Today/prev/next), or should it temporarily replace the bottom toolbar? | Float immediately above the bottom toolbar (`bottom: calc(var(--cal-bottom-bar-h) + var(--composer-dock-h) + 8px)`), so date navigation remains available while the Undo option is visible. |
| M5 | In the mobile Day view, should tapping an empty time slot directly create/open the event dialog pre-filled with that hour, or should event creation only be triggered by the bottom "+ New event" button? | Both: tapping an empty time slot opens the dialog pre-filled with that specific hour; tapping the bottom "+ New event" button defaults to the next full hour. |

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

## 11. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.4 | 2026-10-06 | a-424 | Mobile-first section 5.1 (phone layout, touch gestures, full-screen dialogs, thumb reach, 360/390 px acceptance checks for all 10 v1 features, owner questions M1..M5). |
| v0.3 | 2026-10-06 | c-363 | Owner answered Q1..Q9 "as proposed" (msg `92b3e0d6`): every row of section 10 DECIDED as proposed; with E1..E3 the spec is fully decided. |
| v0.2 | 2026-10-06 | c-397 | Owner decisions E1..E3 (section 0.1): v1 list approved; reminders are a typed whole number of minutes / hours / days (up to 5); video-call link and busy / free dropped. Q1..Q9 still open. |
| v0.1 | 2026-10-06 | c-397 | Gap analysis against Google Calendar (G1..G15); additive DDL (jsonb `props` under the 098 promotion rule, recurrence columns, soft delete, `calendar_guests`); the calls; the WUI surface; ranking and v1 line; Q1..Q9. |

<!-- version: 0.4 · updated: 2026-10-06 -->
