# 089: the Calendar section (time coordination between people and agents)

**Feature ID**: `089-calendar-section` · **Milestone**: M3 · **Status**: Planned (v0.5.0, owner decisions folded in, wire format pinned)
**Created**: 2026-10-05 · **Lane**: a-270 · **Topic**: `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3` (spec, closed) · implementation `819d8610-4fc9-442a-9916-ef2fd691da5f`
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is built. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, task lifecycle)
- [005 WUI](../005-spool-wui/spec.md) (Slack-like interface, layout, theming)
- [023 user settings & rail order](../023-spool-user-settings-keys/spec.md) (left rail tabs, reordering)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles and permissions)
- [027 spool performance](../027-spool-performance/spec.md) (155 KB initial gzip budget)
- [043 mobile WUI](../043-spool-wui-mobile/spec.md) (mobile viewports and navigation stack)
- [047 issues](../039-spool-issues/spec.md) (`issues.deadline` integration)
- [065 release notes table](../065-release-notes-table/spec.md) (release version tags `v<X.Y.Z>`)

`<BASE_DOMAIN>`, `<workspace_id>`, `<human_id>`, `<agent_id>`, and `<env>` are placeholders. No estate value appears as a literal to copy.
Per the owner's rule, this specification uses the term **workspace** throughout; the term **tenant** appears strictly when citing database columns, code identifiers, or API headers.

---

## 1. Why and The Owner's Ask

The spool web application coordinates human engineers and autonomous agents through channels, topics, and direct messages. To coordinate activities in time, members and agents need a straightforward calendar to view, schedule, and track timed events.

The owner defined the feature in topic `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3`, verbatim:

1. Owner HUM-10, msg `f4d3ad2f`:
   > "We need to create a new section which will be called Calendar, and it will have an open-source control for the calendar in view. It should be able to present, of course, the official calendar, but it should have daily, monthly, and weekly views as well. It should have only one panel, not three panels. - On the leftmost panel, it should have the small monthly calendars of the current year, just scrollable back and forth (3 years) and loadable from the database. - The middle-sized panel should have the weekly view. Let's spec it. I'm not sure how it should work."

2. Owner HUM-10, msg `aaccdf38`:
   > "But the idea will be to have coordinated and scheduled releases to track everything, all of the events which have been scheduled for a time."

3. Owner HUM-10, msg `c346a4b9`:
   > "Include also a Grok agent. I would like to see his opinion as well, and you both should reach a consensus."

4. Owner HUM-10, msg `e3d63084`:
   > "The calendar should be for coordinating any events which are to be coordinated between people and agents, even for people themselves to set up their own alerts or things which are related to time. Anything related to time. It doesn't have to replicate the complex functionalities of Google Calendar, but it should have the most basic things for one to be able to track events and things happening in time."

5. Owner HUM-10, msg `2a9ce886`:
   > "Iterate according to this description and present me with simple specs."

### 1.1 Owner decisions 2026-10-05

Owner HUM-10 on the implementation topic `819d8610-4fc9-442a-9916-ef2fd691da5f`, verbatim. These override anything else in this file, the consensus in section 10 included.

| # | msg | Owner text | What it decides |
|---|---|---|---|
| D1 | `1a99ca3a` | "Z so the specs are ready. If that is the case, close the discussion and create a new one on the actual implementation, and start the implementation in it as well." | The spec topic is closed; the build runs on `819d8610` from `tasks.md`. |
| D2 | `a692786d` | "Each event is public by default and has to be set to be private explicitly by the event owner." | `audience` defaults to `public`. Only the event's owner sets `private`, and only as an explicit action (section 4.2). |
| D3 | `d77d5f53` | "Yes, reminders should be received as messages from agents as of now, for a beginning." | **Replaced by D4.** Kept here only as the record. |
| D4 | `a83949ed` | "Actually, no, reminders should be just the technical pop-ups, Google Calendar style, which do not require any artificial intelligence." | A reminder is a plain in-app pop-up (section 4.3). |
| D4 | `9850818d` | "Because they are purely technical" | No agent, no AI and no spool message in the reminder path. |

Defaults posted on the same topic by the implementation lane, which stand until the owner overrides them:

- **Official-days region**: empty by default. A workspace with no region shows no holiday tints.
- **Version tags**: a `v<X.Y.Z>` tag shows as a badge on a scheduled release event. It never creates a calendar row.
- **Audience**: `public`, `internal` or `private`, plus `@mentions`. No RSVP.

---

## 2. Layout: "One Panel, Not Three"

```
+----+-----------------------+------------------------------------------------------------------------+
|    |  36 MINI-MONTHS (VUE) |                     MAIN CALENDAR VIEW (WEEK DEFAULT)                  |
|    |  (Prev, Curr, Next)   |  [Today] [<] [>]  Oct 05 - Oct 11, 2026   [ Day | Week | Month ]   [+]  |
| R  +-----------------------+------------------------------------------------------------------------+
| A  | < 2026 >              | Mon 05      Tue 06      Wed 07      Thu 08      Fri 09      Sat 10      |
| I  |  OCTOBER 2026         +------------------------------------------------------------------------+
| L  |  Mo Tu We Th Fr Sa Su | [All Day]   Official Holiday: Public Observance                        |
|    |         1  2  3  4    +------------------------------------------------------------------------+
|    |   5  6  7  8  9 10 11 | 09:00       │           │           │ [Rel v1.4.0]│           │        |
|    |  12 13 14 15 16 17 18 |             │           │           │ Deploy prd  │           │        |
|    |  19 20 21 22 23 24 25 | 10:00       │ [Agent Run]           │             │           │        |
|    |  26 27 28 29 30 31    |             │ DB Vacuum │           │             │           │        |
|    +-----------------------+ 11:00       │           │           │             │           │        |
|    |  Dots = events        | ...         │           │           │             │           │        |
|    |  Tint = official day  | Now line ──────────────────────────────────────────────────────────    |
+----+-----------------------+------------------------------------------------------------------------+
```

### 2.1 Desktop Layout (> 820 px)
- **Single Work Sheet**: Route `/calendar`, rail tab `calendar`. The left icon rail stays. The channel list, topic list, and thread pane are closed, matching the single-sheet layout of Issues (`csi-spl-wui/src/pages/issues.vue`).
- **Left Column (~240 px)**: 36 small monthly calendars representing 3 consecutive years (previous year, current year, next year). Scrolling stops at the 3-year boundaries.
  - Days with events show a dot indicator; official holidays show a background tint. Both are loaded from the database.
  - Clicking any day moves the main view to that week.
  - Built as our own custom Vue component without third-party library overhead.
- **Right Main View**:
  - Opens on the **Week view** by default.
  - Header segmented control switches between **Day**, **Week**, and **Month**.
  - Week view renders a time grid with an all-day header row, business hours highlighted, and a horizontal marker for the current time ("now line").
  - Dragging moves an event's scheduled time.
  - The calendar library's own toolbar is hidden in favor of standard WUI controls.
- **Event Interaction**: Clicking an event opens a modal dialog (identical to an opened issue card). There is no third pane.

### 2.2 Phone Layout (<= 820 px)
- Rendered as Level 2 with the mobile section strip (`useMobileStack.ts`).
- Opens on the **Day view** by default. Week view displays a compact list grouped by day.
- The 3-year mini-calendar strip sits behind a header button (`📅`).

---

## 3. The Calendar Control & Performance Budget

- **Budget**: The WUI first-paint ceiling `ci_initial_gzip_kb` is **155 KB** (`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`).
- **Dynamic Lazy Loading**: Calendar components and third-party libraries are loaded dynamically on route entry (`defineAsyncComponent`), keeping 0 bytes in the initial chunk.
- **Component Selection**:
  - **Schedule-X** (`@schedule-x/calendar`, `@schedule-x/vue`): Primary choice for the main grid when pnpm installs a clean MIT set. Lightweight, modern, accessible, dark/light theme support matching CSS variables.
  - **Fallback**: `@fullcalendar/vue3` standard views (MIT), lazy-loaded, if peer dependency issues occur with Schedule-X Vue wrappers.
  - **Year Strip**: Pure custom Vue component using standard date calculations, avoiding external dependencies.

---

## 4. Timed Events Model

Per owner guidance (`e3d63084`), the calendar coordinates any time-related event between people and agents. It focuses on basic capabilities: create, edit, drag-to-move, and delete. Complex enterprise features (invitations, RSVP loops, complex recurrence rules) are explicitly excluded.

### 4.1 Event Attributes
- **Title**: Short description (1..200 characters).
- **Time Range**: Start time and end time (with all-day flag).
- **Kind**: Category label (`release`, `deploy`, `maintenance`, `freeze`, `agent_task`, `reminder`, `other`).
- **Owner**: The person or agent who created the event (`creator_type`, `creator_id`). Ownership does not move.
- **Audience**: One of `public` (the default), `internal` or `private`. Section 4.2 has the rules.
- **Mentions**: Zero or more people or agents named with `@` (`mentions`). A mention adds a viewer to a private event and makes the event show on that person's or agent's own list. It is not an invitation and has no RSVP.
- **Reminder**: Optional alert time (`remind_at`). When it comes, a plain pop-up shows in the app. Section 4.3 has the rules.
- **Issue Deadlines**: `issues.deadline` values (`0047_issues.sql`) appear directly on the calendar grid. Editing the deadline block updates the underlying issue.
- **Release Version Tags**: A release milestone scheduled in the calendar displays its associated `v<X.Y.Z>` tag as a badge once deployed. (No automatic row creation per git tag).
- **Official Days**: Official public holidays and statutory non-working days are displayed from a shared reference table based on the workspace's configured region. The region is empty by default, so a new workspace shows no tints.

### 4.2 Audience: public by default, private only by the owner (D2)

| Audience | Who sees the event |
|---|---|
| `public` (default) | Everyone who can open the workspace, a guest or demo viewer included. |
| `internal` | Signed-in members and agents of the workspace. Not a guest or demo viewer. |
| `private` | The event's owner and the people and agents in `mentions`. Nobody else. |

- A create request without `audience` stores `public`. The database default is `public` as well, so no path makes an event private by accident.
- **Only the owner may set `private`, and only explicitly.** The hub refuses, with `403`, any create or update that sets `audience = 'private'` when the caller is not the event's owner (for a create, the caller is the owner). An admin role does not change this. Moving an event out of `private` is the owner's action too.
- Anyone who may edit the event may move it between `public` and `internal`.
- The WUI shows the audience control to everyone who can edit, and shows the `private` choice only to the owner. The hub check is the rule; the hidden choice is only convenience.

### 4.3 Reminders: a technical pop-up, Google Calendar style (D4)

- At `remind_at` the app shows a small pop-up with the event's **title and time**, and two buttons: open the event, and dismiss.
- The pop-up shows to the event's owner and to the people in `mentions`, in each of their open WUI tabs. It does not show to the rest of the audience of a public or internal event.
- **The timer is the app's own.** The WUI asks the hub for the viewer's reminders in the next 24 hours (`GET /v1/calendar/reminders`), sets a browser timer for each, and asks again on page focus, on an event change, and once an hour. The hub serves the list and holds no reminder state of its own.
- **No agent, no AI, no spool message** is in the path. Nothing is posted to a channel, a topic or an inbox, and no pane is rung. An agent can read its events through the API but receives no reminder.
- Dismissing a pop-up is remembered in the browser for that event and reminder time. A missed reminder (the app was closed) shows once when the app next opens, if the event has not yet ended.

---

## 5. PostgreSQL Schema & Workspace Isolation

Stored in `csi-spl-rdb` with strict PostgreSQL `FORCE ROW LEVEL SECURITY`.

```sql
CREATE TABLE calendar_events (
    event_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text        NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    title           text        NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description     text        NOT NULL DEFAULT '' CHECK (length(description) <= 4000),
    kind            text        NOT NULL CHECK (kind IN ('release', 'deploy', 'maintenance', 'freeze', 'agent_task', 'reminder', 'other')),
    starts_at       timestamptz NOT NULL,
    ends_at         timestamptz NOT NULL,
    all_day         boolean     NOT NULL DEFAULT false,
    audience        text        NOT NULL DEFAULT 'public' CHECK (audience IN ('public', 'internal', 'private')),
    mentions        text[]      NOT NULL DEFAULT '{}', -- human UUIDs and agent ids named with @
    creator_type    text        NOT NULL CHECK (creator_type IN ('human', 'agent', 'system')),
    creator_id      text        NOT NULL CHECK (length(creator_id) BETWEEN 1 AND 64),
    remind_at       timestamptz NULL, -- pop-up time; no delivery state is stored (section 4.3)
    topic_id        text        NULL, -- Optional linkage to discussion topic (spec 003)
    release_version text        NULL CHECK (release_version IS NULL OR release_version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$'),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT calendar_events_valid_range CHECK (ends_at >= starts_at)
);

CREATE TABLE official_days (
    region          text        NOT NULL CHECK (length(region) BETWEEN 2 AND 16),
    day             date        NOT NULL,
    title           text        NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    PRIMARY KEY (region, day)
);

-- Indexes for range queries and marks
CREATE INDEX calendar_events_tenant_range ON calendar_events (tenant_id, starts_at, ends_at);
CREATE INDEX calendar_events_mentions ON calendar_events USING gin (mentions);
CREATE INDEX calendar_events_remind ON calendar_events (tenant_id, remind_at) WHERE remind_at IS NOT NULL;

-- Strict Row Level Security
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_events FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON calendar_events
    USING (
        tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
    )
    WITH CHECK (
        tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
    );

CREATE POLICY operator_scope ON calendar_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

RLS enforces the workspace only, in the same `NULLIF` form as every other workspace table. The hub sets no per-viewer setting today (`grep -rhoE "app\.[a-z_]+" csi-spl-api/src/go/spool-hub-api/internal/store/rls.go csi-spl-rdb/src/sql/postgres/spool-hub/*.sql` -> only `app.tenant_id`, `app.rls_scope`, `app.change_stamped` on 31c04371c), so the audience rules live in the store and the hub:

- `private`: every store read filters `audience <> 'private' OR creator_id = <viewer> OR <viewer> = ANY (mentions)`, proven by a store test on Postgres.
- `internal`: the hub drops `internal` events for a guest or demo session, which it knows from the session's role.
- Owner-only `private` (section 4.2): a hub check, proven by an API test, because RLS cannot see which column a write changes.

---

## 6. Hub API Serving Routes

- `GET /v1/calendar/events?start=<ISO>&end=<ISO>`: Returns calendar events, issue deadlines, and official days overlapping the range.
- `GET /v1/calendar/marks?start_year=<YYYY>&end_year=<YYYY>`: Returns days that have events (for dots) and official holidays (for tints) across the 3-year strip.
- `POST /v1/calendar/events`: Creates an event; `audience` defaults to `public`. Agents and members use the same endpoint (also exposed via CLI and `spool mcp`).
- `PATCH /v1/calendar/events/{id}`: Updates or reschedules an event. Setting `audience` to or from `private` by anyone but the owner returns `403`.
- `GET /v1/calendar/reminders?from=<ISO>&to=<ISO>`: The viewer's reminders in the window (events they own or are mentioned on), for the WUI's pop-up timer. Read only.
- `DELETE /v1/calendar/events/{id}`: Removes an event.

### 6.1 Wire format

Every route answers JSON. Times are RFC 3339 in UTC (`2026-10-05T09:00:00Z`); a request may send any zone, and the hub stores and answers UTC. A time that is not set reads as `""`, never `null`. Every list is an array, never `null`. Routes read the session's workspace, as every `/v1/view/*` route does.

#### 6.1.1 The event object

One shape for every item on the grid, whatever its `source`:

| field | type | meaning |
|---|---|---|
| `id` | string | the event's UUID; the issue key (`SPL-12`) for an issue deadline; `official:<region>:<YYYY-MM-DD>` for an official day |
| `source` | string | `event` (a `calendar_events` row), `issue` (an `issues.deadline`, read only here), `official_day` (read only) |
| `title` | string | 1..200 characters |
| `description` | string | 0..4000 characters; `""` for an official day |
| `kind` | string | `release`, `deploy`, `maintenance`, `freeze`, `agent_task`, `reminder` or `other` for an `event`; `deadline` for an `issue`; `official_day` for an `official_day` |
| `starts_at` | string | start; an issue deadline starts and ends at its deadline |
| `ends_at` | string | end, never before `starts_at` |
| `all_day` | boolean | an official day is `true`, from midnight UTC to the next midnight |
| `audience` | string | `public`, `internal` or `private`; `issue` and `official_day` items are `public` |
| `mentions` | string[] | human ids and agent ids named with `@` |
| `creator_type` | string | `human`, `agent` or `system` (`system` for an `official_day`) |
| `creator_id` | string | the event's owner: the human id or agent id that created it; the issue's creator for an `issue` |
| `remind_at` | string | the pop-up time, `""` = no reminder |
| `topic_id` | string | the linked topic, `""` = none |
| `release_version` | string | the `v<X.Y.Z>` badge of a release event, `""` = none; no event is made per git tag |
| `issue_key` | string | the issue for an `issue` item (equal to `id`), `""` otherwise |
| `created_at` | string | `""` for an `official_day` |
| `updated_at` | string | `""` for an `official_day` |

A guest or demo session never receives an `internal` item; nobody receives a `private` item they neither own nor are mentioned on.

#### 6.1.2 Routes

| route | request | `200` / `201` answer |
|---|---|---|
| `GET /v1/calendar/events?start=&end=` | both required, `start < end`, at most 400 days | `{"start": "...", "end": "...", "events": [event...]}`: the `event`, `issue` and `official_day` items overlapping `[start, end)`, by `starts_at` then `id` |
| `GET /v1/calendar/marks?start_year=&end_year=` | 4-digit years, `start_year <= end_year`, at most 5 years | `{"start_year": 2025, "end_year": 2027, "days": [{"day": "2026-10-05", "count": 2, "kinds": ["deadline", "release"]}], "official_days": [{"day": "2026-12-25", "title": "..."}]}`: `days` counts the `event` and `issue` items the viewer can read, per UTC day, oldest first, `kinds` sorted; `official_days` are the tints |
| `GET /v1/calendar/reminders?from=&to=` | both required, `from < to`, at most 31 days | `{"from": "...", "to": "...", "reminders": [event...]}`: `event` items the viewer created or is mentioned on whose `remind_at` is in `[from, to)`, by `remind_at` |
| `POST /v1/calendar/events` | the event body below; `title`, `starts_at`, `ends_at` required | `201 {"event": event}` |
| `PATCH /v1/calendar/events/{id}` | the event body below; an absent field is left as it is | `200 {"event": event}` |
| `DELETE /v1/calendar/events/{id}` | none | `200 {"event": event}`, the event as it was |

The event body (create and `PATCH`) holds only these fields; any other field is `400 bad_json`:
`title`, `description`, `kind` (default `other`), `starts_at`, `ends_at`, `all_day`, `audience` (default `public`), `mentions`, `remind_at` (`""` clears), `topic_id` (`""` clears), `release_version` (`""` clears). `source`, `creator_*`, `issue_key` and the stamps are the hub's. An issue deadline is edited through the issue's own `PATCH /v1/issues/{ref}`, never here.

#### 6.1.3 Errors

Every refusal is the hub's usual body `{"error": "<token>", "detail": "<plain English>"}`:

| status | `error` | when |
|---|---|---|
| `400` | `bad_json` | the body is not an event body |
| `400` | `bad_range` | a range parameter is missing, unparsable, reversed or too long |
| `400` | `bad_event` | a field breaks a rule of section 5 (title length, kind, audience, times, `release_version`, a mention longer than 64 characters or more than 50 mentions) |
| `403` | `private_owner_only` | a `PATCH` sets `audience` to or from `private` and the caller is not the event's owner (`creator_id`); an admin or the workspace owner gets this too (FR-010). A create is always by the event's owner, so a create may set `private` |
| `403` | `demo_read_only` | a guest or demo session calls `POST`, `PATCH` or `DELETE` (they read public events only) |
| `403` | `forbidden` | the role lacks a permission; this body also carries `"permission": "<perm>"` (spec 025): reads need `topics.read`, writes `notes.send` |
| `404` | `not_found` | no such event, or a `private` event the caller may not read |
| `503` | `calendar_unavailable` | this environment's database has no `calendar_events` yet (rdb 0125); reads then answer empty lists, never this |

---

## 7. User Stories

| ID | Role | Story | Benefit |
|---|---|---|---|
| **US1** | Member | Open `/calendar` from the rail and see the current week's schedule | Immediate overview of scheduled work and deadlines |
| **US2** | Member | Switch between Day, Week, and Month views via header control | Zoom from hourly schedule to monthly perspective |
| **US3** | Member | Scroll 3 years of mini-months on the left and click any date | Rapid date jumping across past and future years |
| **US4** | Agent / Member | Schedule a maintenance or deployment window via API or dialog | Prevents conflicting tasks across the team |
| **US5** | Member | Set a reminder on an event and see a pop-up with its title and time when it comes | Timely alerts directly in the application, without an agent |
| **US6** | Mobile Member | View upcoming schedule on a smartphone in Day view | Clean, readable time tracking on small screens |
| **US7** | Event owner | Keep an event public by default and make it private with one explicit action | Nothing is hidden by accident, and only the owner can hide it |

---

## 8. Functional Requirements & Acceptance Matrix

### 8.1 Functional Requirements
- **FR-001**: Rail icon `calendar` navigates to `/calendar`, closing channel and topic panes.
- **FR-002**: Left column renders 36 mini-months (3 years) with event dots and holiday tints from DB.
- **FR-003**: Main view defaults to Week view with Day and Month switches.
- **FR-004**: Calendar code is dynamically imported, keeping initial gzip bundle at or under 155 KB.
- **FR-005**: Events support title, start, end, category, audience (`public` default, `internal`, `private`), `@mentions`, and an optional reminder time.
- **FR-006**: A due reminder shows a plain in-app pop-up (title and time) to the owner and the mentioned people, driven by the WUI timer. No agent, AI or spool message is involved.
- **FR-007**: `issues.deadline` values appear on the calendar; editing updates the issue.
- **FR-008**: Data stored in `calendar_events` with PostgreSQL `FORCE ROW LEVEL SECURITY`.
- **FR-009**: On viewports <= 820px, layout opens on Day view with year strip behind a button.
- **FR-010**: Only the event's owner can set or clear `private`, by an explicit action; the hub refuses anyone else with `403`.

### 8.2 Acceptance Scenarios
- **AC-01 (Rail Navigation)**: Click Calendar icon -> `/calendar` opens as single sheet with left rail; Week view renders.
- **AC-02 (Bundle Budget)**: `pnpm build` output verifies `ci_initial_gzip_kb` <= 155.0 KB; calendar is a separate chunk.
- **AC-03 (View Switching)**: Switch Day/Week/Month -> calendar updates instantly without layout jitter.
- **AC-04 (Mini-Month Navigation)**: Click date in mini-month -> main view smoothly shifts to that date's week.
- **AC-05 (Event Creation & Dialog)**: Click "+", enter title and time -> event appears; click event opens modal dialog.
- **AC-06 (Reminder Pop-up)**: Set a reminder time -> when reached, a pop-up with the event title and time shows in the owner's open tab; no spool message is written and no pane is rung.
- **AC-07 (Tenant Isolation)**: Workspace `t1` member cannot access or view workspace `t2` calendar events.
- **AC-08 (Phone Responsiveness)**: At 390x844 viewport, opens on Day view; Week displays as grouped list.
- **AC-09 (Public by Default)**: Create an event without an audience -> it is `public`. A non-owner who sets `private` gets `403`; the owner who sets it explicitly succeeds, and a member who is not mentioned then cannot read the event.

---

## 9. Questions for the Owner (answered)

1. **Official Days Region**: empty by default (default posted on `819d8610`, section 1.1).
2. **Version Tag Display**: a badge on a scheduled release, never an automatic row (default, section 1.1).
3. **Reminders**: answered by D4: a technical pop-up, not a spool message.
4. **Audience Model**: answered by D2 and the default: `public` (default) / `internal` / `private` plus `@mentions`, no RSVP. This replaces the single-target model.

---

## 10. Consensus Section (agy author `a-270` & grok peer `g-288`)

Per owner msg `c346a4b9`: *"Include also a Grok agent. I would like to see his opinion as well, and you both should reach a consensus."*

### 10.1 Consensus Statement: Complete Agreement Reached
Following independent drafting and structured peer review on task `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3`, author **a-270** (Antigravity) and peer **g-288** (Grok) reached **full architectural consensus**:

1. **Layout ("One panel, not three")**:
   - Agreed: `/calendar` is a single work sheet with the persistent icon rail, closing the channel, topic, and thread panes (matching the `issues.vue` single-sheet pattern).
   - Agreed: Desktop layout consists of two columns: 36 small months on the left (custom Vue) and main schedule view on the right (Week by default, Day/Month switch).
   - Agreed: Event details open in a modal dialog; there is no third column.
   - Agreed: Phone layout opens on Day view, with Week as a grouped list and year strip behind a button.
2. **Control & Performance**:
   - Agreed: The first-paint ceiling `ci_initial_gzip_kb` is strictly **155 KB** (`perf-budgets.json`). Calendar is lazy-loaded on route entry.
   - Agreed: Schedule-X (`@schedule-x/calendar`, `@schedule-x/vue`) is the primary MIT candidate; `@fullcalendar/vue3` standard views serves as lazy-loaded fallback if peer package issues arise.
   - Agreed: 36-month year strip is built as a lightweight custom Vue component (zero third-party dependencies).
3. **Event & Reminder Model**:
   - Agreed: Simple, pragmatic event model (title, start, end, category, single audience). **The single audience is superseded by D2 and the default in section 1.1.** Complex features (RSVP, meeting invitations, recurring rule engines) are out of scope.
   - Agreed: Event reminders are delivered as native Spool messages via `internal/notify` to recipient panes. **Superseded by owner decision D4 (section 1.1): reminders are in-app pop-ups.**
   - Agreed: Issue deadlines (`issues.deadline`) are reflected on the grid directly.
   - Agreed: Git version tags `v<X.Y.Z>` are labels on scheduled releases, not automatic database rows per commit.
4. **Data Isolation**:
   - Agreed: `calendar_events` table carries `tenant_id REFERENCES tenants(tenant_id)` with `FORCE ROW LEVEL SECURITY`, using `tenant_scope` and `operator_scope`.
   - Agreed: Official holidays reside in a shared `official_days` table; workspace setting names the region (starting empty).

### 10.2 Disputed Points
- **None**. All items resolved and aligned between `a-270` and `g-288`.

---

## 11. Not in Scope

- Two-way CalDAV / Google Calendar / Outlook synchronization.
- Meeting room bookings and resource management.
- Multi-attendee invitations and RSVP tracking.
- Complex recurrence rule editors (RRULE).

### 11.1 Future: scheduled deploys shown on the calendar (owner, not in the first tasks)

Owner HUM-10 on topic `819d8610`, msgs `f23094d6` and `69fc0cbc`, verbatim:

> "We could later on also implement the feature that reminds people that there is a schedule update on the system and makes those schedule updates. Let's put it twice a day, or, the more technical the system is, even once an hour, and schedule the updates to be performed once an hour, not like now, straight away from the master."

> "But for now, in this instance, everything should be deployed as soon as it gets to the master."

- **Later**: deploys run on a schedule (once an hour, or twice a day) instead of on every push. Each scheduled update gets a calendar event and the usual pop-up reminder (section 4.3), so people see it coming.
- **Now**: nothing changes. Every push to master still deploys at once. `tasks.md` has no task for this item; it needs its own spec when the owner starts it.

---

## 12. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-05 | a-270 | Initial comprehensive draft specification for the Calendar section. |
| v0.2.0 | 2026-10-05 | a-270 | Folded owner scope correction (msg `e3d63084`) for general time coordination and personal reminders. |
| v0.3.0 | 2026-10-05 | a-270 | Full consensus specification harmonized with grok peer `g-288` (opinion `63300b4cd`): simplified structure per owner msg `2a9ce886`, updated 155 KB budget ceiling, `tenants(tenant_id)` foreign key, custom Vue 36-month strip, Schedule-X / FullCalendar fallback, spool message reminders, single audience model, dialog event modal, and formal Consensus section. |
| v0.4.0 | 2026-10-05 | c-275 | Owner decisions 2026-10-05 (section 1.1): audience `public` by default, `private` only by the owner explicitly (4.2); reminders are app-timer pop-ups with no agent, AI or spool message (4.3); schema `audience` + `mentions` replace `for_type`/`for_id`, `reminded` dropped, RLS policy back to the workspace-only form (no `app.human_id`/`app.agent_id` setting exists; the private filter moves to the store); questions answered; future scheduled-deploy item (11.1, msgs `f23094d6`, `69fc0cbc`); `tasks.md` added. |
| v0.5.0 | 2026-10-05 | c-326 | Section 6.1 wire format: the one event object (`source` event / issue / official_day), the marks and reminders answers, the request body, and the refusal tokens (`private_owner_only`, `demo_read_only`). |

<!-- version: 0.5.0 · updated: 2026-10-05 · last-edit: 2026-10-05T19:58:00Z -->
