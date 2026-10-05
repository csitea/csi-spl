# 089: the Calendar section (time coordination between people and agents)

**Feature ID**: `089-calendar-section` · **Milestone**: M3 · **Status**: Consensus (v0.3.0)
**Created**: 2026-10-05 · **Lane**: a-270 · **Topic**: `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3`
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
- **Audience**: Exactly one target:
  - `workspace` (visible to all workspace members), or
  - A specific person (`human`), or
  - A specific agent (`agent`).
- **Reminder**: Optional alert time (`remind_at`). When due, the Hub sends a native Spool message to the recipient. Hub delivery notifies the pane (`internal/notify`) and displays in the WUI.
- **Issue Deadlines**: `issues.deadline` values (`0047_issues.sql`) appear directly on the calendar grid. Editing the deadline block updates the underlying issue.
- **Release Version Tags**: A release milestone scheduled in the calendar displays its associated `v<X.Y.Z>` tag once deployed. (No automatic row creation per git tag).
- **Official Days**: Official public holidays and statutory non-working days are displayed from a shared reference table based on the workspace's configured region.

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
    for_type        text        NOT NULL CHECK (for_type IN ('workspace', 'human', 'agent')),
    for_id          text        NULL, -- NULL for workspace, human UUID or agent ID otherwise
    creator_type    text        NOT NULL CHECK (creator_type IN ('human', 'agent', 'system')),
    creator_id      text        NOT NULL CHECK (length(creator_id) BETWEEN 1 AND 64),
    remind_at       timestamptz NULL,
    reminded        boolean     NOT NULL DEFAULT false,
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
CREATE INDEX calendar_events_target ON calendar_events (tenant_id, for_type, for_id, starts_at);
CREATE INDEX calendar_events_remind ON calendar_events (remind_at) WHERE remind_at IS NOT NULL AND reminded = false;

-- Strict Row Level Security
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_events FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON calendar_events
    USING (
        tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
        AND (for_type = 'workspace' OR for_id = NULLIF(current_setting('app.human_id', true), '') OR for_id = NULLIF(current_setting('app.agent_id', true), ''))
    )
    WITH CHECK (
        tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
    );

CREATE POLICY operator_scope ON calendar_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

---

## 6. Hub API Serving Routes

- `GET /v1/calendar/events?start=<ISO>&end=<ISO>`: Returns calendar events, issue deadlines, and official days overlapping the range.
- `GET /v1/calendar/marks?start_year=<YYYY>&end_year=<YYYY>`: Returns days that have events (for dots) and official holidays (for tints) across the 3-year strip.
- `POST /v1/calendar/events`: Creates an event. Agents and members use the same endpoint (also exposed via CLI and `spool mcp`).
- `PATCH /v1/calendar/events/{id}`: Updates or reschedules an event.
- `DELETE /v1/calendar/events/{id}`: Removes an event.

---

## 7. User Stories

| ID | Role | Story | Benefit |
|---|---|---|---|
| **US1** | Member | Open `/calendar` from the rail and see the current week's schedule | Immediate overview of scheduled work and deadlines |
| **US2** | Member | Switch between Day, Week, and Month views via header control | Zoom from hourly schedule to monthly perspective |
| **US3** | Member | Scroll 3 years of mini-months on the left and click any date | Rapid date jumping across past and future years |
| **US4** | Agent / Member | Schedule a maintenance or deployment window via API or dialog | Prevents conflicting tasks across the team |
| **US5** | Member | Set a reminder on an event and receive a spool notification | Timely alerts directly in the application |
| **US6** | Mobile Member | View upcoming schedule on a smartphone in Day view | Clean, readable time tracking on small screens |

---

## 8. Functional Requirements & Acceptance Matrix

### 8.1 Functional Requirements
- **FR-001**: Rail icon `calendar` navigates to `/calendar`, closing channel and topic panes.
- **FR-002**: Left column renders 36 mini-months (3 years) with event dots and holiday tints from DB.
- **FR-003**: Main view defaults to Week view with Day and Month switches.
- **FR-004**: Calendar code is dynamically imported, keeping initial gzip bundle at or under 155 KB.
- **FR-005**: Events support title, start, end, category, single audience, and optional reminder time.
- **FR-006**: Due reminders are dispatched as native spool messages notifying the recipient's pane.
- **FR-007**: `issues.deadline` values appear on the calendar; editing updates the issue.
- **FR-008**: Data stored in `calendar_events` with PostgreSQL `FORCE ROW LEVEL SECURITY`.
- **FR-009**: On viewports <= 820px, layout opens on Day view with year strip behind a button.

### 8.2 Acceptance Scenarios
- **AC-01 (Rail Navigation)**: Click Calendar icon -> `/calendar` opens as single sheet with left rail; Week view renders.
- **AC-02 (Bundle Budget)**: `pnpm build` output verifies `ci_initial_gzip_kb` <= 155.0 KB; calendar is a separate chunk.
- **AC-03 (View Switching)**: Switch Day/Week/Month -> calendar updates instantly without layout jitter.
- **AC-04 (Mini-Month Navigation)**: Click date in mini-month -> main view smoothly shifts to that date's week.
- **AC-05 (Event Creation & Dialog)**: Click "+", enter title and time -> event appears; click event opens modal dialog.
- **AC-06 (Reminder Spool Delivery)**: Set reminder time -> when reached, spool message arrives in recipient inbox and rings pane.
- **AC-07 (Tenant Isolation)**: Workspace `t1` member cannot access or view workspace `t2` calendar events.
- **AC-08 (Phone Responsiveness)**: At 390x844 viewport, opens on Day view; Week displays as grouped list.

---

## 9. Numbered Questions for the Owner

1. **Official Days Region**: Workspaces default with no region configured. Which region or country code (e.g. `BG`, `US`, `GB`) should the seed workspace start with?
2. **Version Tag Display**: Confirm that version tags `v<X.Y.Z>` appear strictly as labels on releases scheduled by people or agents, rather than generating automatic database rows for every git tag.
3. **Reminders as Spool Messages**: Confirm that event reminders are delivered as standard Spool messages through the existing notification pipeline.
4. **Single Audience Model**: Confirm that each event targets a single audience (one person, one agent, or the whole workspace), deferring multi-recipient lists to a future phase.

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
   - Agreed: Simple, pragmatic event model (title, start, end, category, single audience). Complex features (RSVP, meeting invitations, recurring rule engines) are out of scope.
   - Agreed: Event reminders are delivered as native Spool messages via `internal/notify` to recipient panes.
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

---

## 12. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-05 | a-270 | Initial comprehensive draft specification for the Calendar section. |
| v0.2.0 | 2026-10-05 | a-270 | Folded owner scope correction (msg `e3d63084`) for general time coordination and personal reminders. |
| v0.3.0 | 2026-10-05 | a-270 | Full consensus specification harmonized with grok peer `g-288` (opinion `63300b4cd`): simplified structure per owner msg `2a9ce886`, updated 155 KB budget ceiling, `tenants(tenant_id)` foreign key, custom Vue 36-month strip, Schedule-X / FullCalendar fallback, spool message reminders, single audience model, dialog event modal, and formal Consensus section. |

<!-- version: 0.3.0 · updated: 2026-10-05 · last-edit: 2026-10-05T03:55:00Z -->
