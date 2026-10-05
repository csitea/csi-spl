# 089: the Calendar section (release coordination, scheduled events, multi-view calendar)

**Feature ID**: `089-calendar-section` · **Milestone**: M3 · **Status**: Draft (v0.1.0)
**Created**: 2026-10-05 · **Lane**: a-270 · **Topic**: `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3`
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, task lifecycle)
- [005 WUI](../005-spool-wui/spec.md) (Slack-like interface, layout, theming, CSS variables)
- [013 chat reverse](../013-spool-chat-reverse/spec.md) (feed layout, 3-panel work area structure)
- [023 user settings & rail order](../023-spool-user-settings-keys/spec.md) (left rail tabs, reordering, custom claims)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles, permissions, and entry gates)
- [043 mobile WUI](../043-spool-wui-mobile/spec.md) (mobile viewports, phone navigation stack)
- [050 panel collapse](../050-spool-panel-collapse/spec.md) (sidebar and topic drawer mechanics)
- [065 release notes table](../065-release-notes-table/spec.md) (release version tags `v<X.Y.Z>`, release metadata, cycles)
- [074 operator workspace](../074-operator-workspace/spec.md) (multi-workspace management, operator scope)
- [075 docs section](../075-docs-section/spec.md) (single-panel full-viewport rail pattern, themed rendering)

`<BASE_DOMAIN>`, `<workspace_id>`, `<human_id>`, `<agent_id>`, `<org>`, `<app>`, and `<env>` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, terraform resources, or API headers.

---

## 1. Why and The Owner's Ask

The spool web application provides real-time communication channels, topics, direct messages, settings, issues, events, and documentation. However, coordinated software delivery across human engineers and autonomous agents requires a unified, time-based operational view. Upcoming software releases, deployment windows, freeze periods, scheduled maintenance, and task deadlines are currently dispersed across chat topics, git tags, and external CI/CD dashboards.

The owner established the architectural requirements in prd workspace `t1`, topic `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3`, verbatim:

1. Owner HUM-10, msg `f4d3ad2f`:
   > "We need to create a new section which will be called Calendar, and it will have an open-source control for the calendar in view. It should be able to present, of course, the official calendar, but it should have daily, monthly, and weekly views as well. It should have only one panel, not three panels. - On the leftmost panel, it should have the small monthly calendars of the current year, just scrollable back and forth (3 years) and loadable from the database. - The middle-sized panel should have the weekly view. Let's spec it. I'm not sure how it should work."

2. Owner HUM-10, msg `aaccdf38`:
   > "But the idea will be to have coordinated and scheduled releases to track everything, all of the events which have been scheduled for a time."

3. Owner HUM-10, msg `c346a4b9`:
   > "Include also a Grok agent. I would like to see his opinion as well, and you both should reach a consensus."

### 1.1 Dispatcher c-002's Reading (Confirmed and Refined)
- **Rail Section & Layout**: Calendar is a top-level rail section (`/calendar`). "One panel, not three panels" means it replaces the three chat panes (channel list, topic list, and message thread) with a dedicated workspace view, maintaining only the persistent left navigation rail (matching the pattern established by `/docs` in spec 075).
- **Two Internal Columns**:
  1. *Leftmost column (sub-panel)*: Narrow column displaying small monthly mini-calendars for a continuous 3-year window (e.g., previous year, current year, next year: 36 months total), scrollable back and forth, displaying event density indicators loaded from the database.
  2. *Main middle viewport*: Broad primary calendar surface defaulting to the **Week view** (per owner mandate), switchable to Day and Month views.
- **Open-Source Component**: Must evaluate candidates against licence (strictly permissive MIT/Apache-2.0), bundle footprint (preserving the WUI's 160 KB initial-chunk budget via dynamic lazy loading), render speed, and Vue 3 / Nuxt 3 compatibility.
- **Official Calendar**: Provides official public holidays and statutory non-working days. The active country and regional calendar source is an open workspace-level configuration.
- **Core Purpose**: Release coordination and scheduled event tracking. Unified tracking for:
  - Software releases and deployment windows across environments (`dev`, `prd`).
  - Automated agent tasks and scheduled maintenance jobs.
  - Human operational milestones, code freezes, and deadlines.
  - Associated git release tags (`v<X.Y.Z>`) and deployment audit records.
- **Storage & Isolation**: Stored in PostgreSQL with strict Row Level Security (`FORCE ROW LEVEL SECURITY`), ensuring complete tenant/workspace isolation.

---

## 2. Architecture & Layout: "One Panel, Not Three"

```
+----+-----------------------+------------------------------------------------------------------------+
|    |  LEFT MINI-CALENDARS  |                     MAIN CALENDAR VIEW (WEEK DEFAULT)                  |
|    |  (3-Year Scrollable)  |  [Today] [<] [>]  Oct 05 - Oct 11, 2026   [ Day | Week | Month ]   [+]  |
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
|    |  NOVEMBER 2026        |             │           │           │             │           │        |
|    |  Mo Tu We Th Fr Sa Su | 12:00       │           │           │             │           │        |
|    |                  1    |             │           │           │             │           │        |
|    |   2  3  4  5  6  7  8 | 13:00       │           │           │             │           │        |
|    |  ... (36 months) ...  |             │           │           │             │           │        |
|    +-----------------------+             │           │           │             │           │        |
|    | Event Filters:        |             │           │           │             │           │        |
|    | [x] Releases          |             │           │           │             │           │        |
|    | [x] Deploys           |             │           │           │             │           │        |
|    | [x] Agent Tasks       |             │           │           │             │           │        |
|    | [x] Official Holidays |             │           │           │             │           │        |
+----+-----------------------+------------------------------------------------------------------------+
```

### 2.1 Viewport Transformation
- **Standard Chat Viewport (Three Panes)**: By default, the WUI presents three functional columns:
  1. Primary navigation rail + channel list sidebar.
  2. Topic / thread preview column.
  3. Active message conversation cards feed.
- **Calendar Section Viewport (One Work Panel)**:
  - When navigating to `/calendar`, the channel sidebar and topic column are unmounted from the main view (retaining only the collapsed 48px icon rail `ChannelSidebar calendarRailOnly`, identical to `docsRailOnly` in `csi-spl-wui/src/pages/docs.vue`).
  - The remaining 100% width of the application viewport is allocated to the Calendar interface.
  - The layout consists internally of two columns:
    1. **Mini-Calendar Rail (Left, ~260px)**: A continuous, virtual-scrolled column containing 36 mini-month calendars (representing 3 consecutive calendar years: `year - 1`, `year`, `year + 1`).
    2. **Main Scheduling Canvas (Middle/Right, flex-grow)**: An expansive grid supporting **Week** (default), **Day**, and **Month** views.

### 2.2 Left Mini-Calendar Sub-Panel (3-Year Scrollable Window)
- **Continuous 3-Year Scope**: Displays 12 months of the preceding year, 12 months of the current year, and 12 months of the following year (36 months total).
- **Virtual Scrolling**: To prevent rendering 36 heavy DOM nodes simultaneously, the list uses virtual scrolling (rendering ~3 visible months plus 2 buffer months above and below).
- **Database-Backed Event Density**:
  - Each day cell displays visual dot markers (density indicators) indicating scheduled items.
  - Dots are color-coded by event category:
    - 🟣 **Release** (`v<X.Y.Z>` tag, release notes).
    - 🔵 **Deploy** (scheduled CI/CD deployment window).
    - 🟠 **Maintenance / Agent Task** (maintenance window, automated agent sprint).
    - 🔴 **Freeze / Deadline** (code freeze, delivery deadline).
    - 🟢 **Official Holiday** (statutory / public holiday).
  - Fetched via lightweight aggregated API endpoint (`GET /v1/calendar/density?start_year=2025&end_year=2027`).
- **Interactive Synchronization**:
  - Clicking any date in a mini-month shifts the main calendar viewport to that specific date/week.
  - Double-clicking opens the quick-create event dialog for that date.
  - Today is visually highlighted with a distinctive accent circle.
  - Selected date range is highlighted with theme accent background.

### 2.3 Main Scheduling Viewport
- **Default View**: **Week View** with hourly time grid (00:00 - 23:59, defaulting scroll position to business hours 08:00 - 18:00).
- **View Switcher**: Segmented toggle in top header: `[ Day | Week | Month ]`.
- **Top Header Controls**:
  - `Today` button (instant jump to current date).
  - Navigation chevrons (`<` Previous, `>` Next period).
  - Current range title (e.g., `October 05 – 11, 2026`).
  - View switcher (`Day`, `Week`, `Month`).
  - Filter button (toggle category visibility).
  - `+ Schedule Event` primary action button.
- **All-Day Banner**: Pinned header row above the time grid displaying multi-day events, release milestones, and official holidays.
- **Event Cards**: Rendered with title, time, category badge, and optional link to associated topic or release tag. Clicking an event opens the Event Detail flyout or modal.

### 2.4 Mobile and Phone Adaptation (<= 820px)
- Aligns with the mobile conventions defined in [spec 043](../043-spool-wui-mobile/spec.md) and [spec 086](../086-phone-card-header/spec.md):
  - At viewports <= 820px, the 3-year left column folds away by default to maximize screen estate.
  - A header button `📅 Date Picker` opens the mini-calendar as an overlay drawer / bottom sheet.
  - On phones, the main view defaults to **Day View** or **Agenda View** (scrollable vertical feed of scheduled cards) rather than the multi-column Week grid, which is unreadable on narrow 360px–390px screens.
  - Swipe gestures (`swipe left`, `swipe right`) navigate between consecutive days.

---

## 3. Open-Source Component Evaluation & Chunk Budget

The spool WUI enforces a strict **160 KB initial-chunk budget** for fast first-paint performance on both desktop and mobile networks. Any calendar library bundled directly into the main entry chunk would violate this ceiling.

### 3.1 Evaluation of Open-Source Candidates

| Candidate | License | Bundle Size (Gzip) | Vue 3 / Nuxt 3 Support | Views Supported | Strengths & Trade-offs | Verdict |
|---|---|---|---|---|---|---|
| **Schedule-X** (`@schedule-x/vue`, `@schedule-x/calendar`) | MIT | **~28 KB** | Native Vue 3 wrapper, TS native | Day, Week, Month, Agenda | Modern, lightweight, modular plugins (drag & drop, resize, dark mode), matches CSS theme variables natively. | **Recommended for Main View** |
| **Qalendar** (`@mariomka/qalendar`) | MIT | **~35 KB** | Native Vue 3 component | Day, Week, Month | Built specifically for Vue 3, good drag & drop, localized. Slightly less flexible theming than Schedule-X. | Strong Alternative |
| **FullCalendar** (`@fullcalendar/vue3`) | MIT (core) / Commercial (timeline) | **~135 KB** | Vue 3 wrapper | Day, Week, Month | Industry standard and feature complete, but very heavy bundle, slow initial DOM render, commercial license required for advanced timeline views. | Rejected (Too heavy, licensing traps) |
| **V-Calendar** (`v-calendar`) | MIT | **~32 KB** | Native Vue 3 | Month, Multi-Month, Date Picker | Superb for mini-calendars and date pickers. Lacks a built-in hourly timegrid scheduler for week/day views. | **Recommended for Left Mini-Calendar** |
| **Toast UI Calendar** (`@toast-ui/calendar`) | MIT | **~115 KB** | Wrapper required | Day, Week, Month | Feature rich, but legacy codebase, large bundle, difficult to customize with modern CSS variables. | Rejected (Heavy, legacy architecture) |

### 3.2 Architectural Recommendation: Hybrid Composable Architecture
To achieve optimal performance and strict adherence to the 160 KB budget:
1. **Dynamic Lazy-Loading**:
   - The Calendar section code and external calendar libraries are loaded strictly on demand via Nuxt dynamic import:
     ```typescript
     const CalendarMain = defineAsyncComponent(() => import('~/components/calendar/CalendarMain.vue'))
     ```
   - Zero bytes of calendar code exist in the initial WUI landing bundle.
2. **Component Pairing**:
   - **Main Scheduling Canvas**: **Schedule-X** (`@schedule-x/vue`). Selected for its tiny footprint (<30 KB), clean modern design, TypeScript native API, accessible keyboard navigation, and seamless dark/light theme integration via CSS custom properties.
   - **Left Mini-Calendar Sub-Panel**: Lightweight custom virtualized mini-month component built using native `Intl.DateTimeFormat` or **V-Calendar**. A custom virtual mini-month grid requires <5 KB of code and avoids third-party overhead for the 3-year scroll.

---

## 4. Coordinated Release Scheduling & Event Model

Per owner msg `aaccdf38`: *"the idea will be to have coordinated and scheduled releases to track everything, all of the events which have been scheduled for a time."*

### 4.1 Event Categories (`kind`)
The calendar tracks six distinct categories of operational and workspace events:

| Kind | Badge Color | Description | Primary Sources |
|---|---|---|---|
| `release` | Purple | Scheduled software release milestone or tag cut (e.g., `v1.4.0`) | Humans, Release Managers, CI tags |
| `deploy` | Blue | Deployment execution window into `dev` or `prd` environments | CI/CD workflows, Ops agents |
| `maintenance` | Amber | Infrastructure maintenance, database migrations, backup windows | Ops agents, SRE humans |
| `freeze` | Red | Code freeze, feature freeze, or deployment block window | Release Leads, System Orchestrator |
| `agent_task` | Cyan | Long-running scheduled agent task (e.g., automated refactoring, regression suite) | Autonomous agents (`a-*`, `c-*`, `g-*`, `q-*`) |
| `official_holiday`| Green | Public holiday or official non-working day | Official Holiday calendar service / config |
| `custom` | Gray | General workspace event, meeting, or reminder | Workspace members |

### 4.2 Data Model & PostgreSQL Schema
The calendar store is managed in `csi-spl-rdb` with strict multi-workspace isolation via PostgreSQL Row Level Security.

```sql
CREATE TABLE calendar_events (
    event_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    title           text        NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description     text        NOT NULL DEFAULT '' CHECK (length(description) <= 4000),
    kind            text        NOT NULL CHECK (kind IN ('release', 'deploy', 'maintenance', 'freeze', 'agent_task', 'official_holiday', 'custom')),
    starts_at       timestamptz NOT NULL,
    ends_at         timestamptz NOT NULL,
    all_day         boolean     NOT NULL DEFAULT false,
    creator_type    text        NOT NULL CHECK (creator_type IN ('human', 'agent', 'system')),
    creator_id      text        NOT NULL CHECK (length(creator_id) BETWEEN 1 AND 64),
    topic_id        text        NULL, -- Optional linkage to discussion topic (spec 003)
    release_version text        NULL CHECK (release_version IS NULL OR release_version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$'),
    metadata        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT calendar_events_valid_range CHECK (ends_at >= starts_at)
);

-- Indexes for fast date range querying and density rollups
CREATE INDEX calendar_events_tenant_range ON calendar_events (tenant_id, starts_at, ends_at);
CREATE INDEX calendar_events_kind ON calendar_events (tenant_id, kind, starts_at);
CREATE INDEX calendar_events_version ON calendar_events (tenant_id, release_version) WHERE release_version IS NOT NULL;

-- Strict Row Level Security
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_events FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON calendar_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

CREATE POLICY operator_scope ON calendar_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

### 4.3 Automated Integration with Release Notes (Spec 065)
- When a new version tag `v<X.Y.Z>` is minted by `do_release_version` and ingested into `release_notes` (spec 065), a corresponding `release` event is automatically registered in the calendar with:
  - `title`: `Release v<X.Y.Z>`
  - `starts_at`: commit timestamp (`committed_at`)
  - `all_day`: `true`
  - `kind`: `'release'`
  - `release_version`: `v<X.Y.Z>`
  - `metadata`: `{ "sha": "<commit_sha>", "cycle": 1 }`
- Clicking a release event in the calendar displays the release notes summary directly in the event popover with a link to the full release modal or topic.

### 4.4 Agent Scheduling & Spool Integration
- Autonomous agents can schedule maintenance windows and task execution slots directly:
  1. **Via Hub API**: Agents authenticate with their agent session or join token (spec 073) and post to `POST /v1/calendar/events`.
  2. **Via Spool Message Bus**: Agents send a task notification with structured event payload.
- Enables autonomous agents to announce scheduled maintenance (e.g., database re-indexing, heavy test passes) and avoid overlapping disruptions.

---

## 5. Official Calendar (Public Holidays)

Per owner msg `f4d3ad2f`: *"It should be able to present, of course, the official calendar..."*

### 5.1 Concept & Requirements
- The "Official Calendar" represents statutory national and regional public holidays (e.g., New Year's Day, National Holidays, Christmas, Easter).
- Official calendar events appear as subtle, all-day background banners across the top of the day and week views, and inside the month grid cells.
- Serves to alert release coordinators and autonomous agents of non-working days when production deployments or high-risk maintenance should be avoided or subject to special authorization.

### 5.2 Country Configuration & Data Source
- Public holidays vary by country and jurisdiction.
- **Workspace Setting**: Each workspace defines its primary country code (`ISO 3166-1 alpha-2`, e.g., `BG`, `US`, `DE`, `GB`) in workspace settings (`workspace_settings.official_calendar_country`).
- **Data Ingestion Options**:
  1. *Embedded Offline Dataset*: Standard statutory holidays computed via lightweight calculation rules (e.g. Easter algorithms, fixed dates) for supported standard regions, requiring no external network requests.
  2. *Standard iCal / ICS Feed Sync*: Workspace administrators can configure an official ICS subscription URL for specialized national or corporate holiday schedules.

---

## 6. Hub API Serving Routes

The Hub API exposes authenticated REST endpoints under `/v1/calendar/`:

### 6.1 Endpoints
- `GET /v1/calendar/events`
  - Query parameters: `start` (ISO-8601), `end` (ISO-8601), `kinds` (comma-separated filter).
  - Returns array of event objects falling within the requested time window.
  - Requires authenticated workspace member session.
- `GET /v1/calendar/density`
  - Query parameters: `start_year` (e.g., 2025), `end_year` (e.g., 2027).
  - Returns a compact JSON object mapping dates to event counts and kind flags:
    ```json
    {
      "2026-10-08": { "count": 2, "kinds": ["release", "deploy"] },
      "2026-10-15": { "count": 1, "kinds": ["maintenance"] }
    }
    ```
  - Highly compressed for instant loading across the 3-year mini-calendar.
- `POST /v1/calendar/events`
  - Creates a new scheduled event.
  - Request body: `{ title, description, kind, starts_at, ends_at, all_day, topic_id, metadata }`.
  - Enforces workspace RBAC: requires `calendar.write` permission.
- `PATCH /v1/calendar/events/{event_id}`
  - Modifies or reschedules an existing event.
  - Requires creator identity or workspace admin role.
- `DELETE /v1/calendar/events/{event_id}`
  - Cancels / deletes a scheduled event.
- `GET /v1/calendar/official`
  - Returns official holidays for the workspace's configured country and requested year.

---

## 7. User Stories

| ID | Priority | Role | User Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Release Manager | Open the Calendar section from the rail and see the current week's scheduled releases and deploys in a single view | Quick operational overview without hunting across chat channels |
| **US2** | **P1** | Workspace Member | Switch between Day, Week, and Month views seamlessly with keyboard shortcuts or header toggle | Flexible temporal perspective from hourly schedule to monthly horizon |
| **US3** | **P1** | Engineer | Scroll smoothly through 3 years of mini-month calendars in the left column to locate past and future milestones | Long-range milestone navigation and date jumping |
| **US4** | **P2** | Autonomous Agent | Schedule an upcoming database maintenance window via the API and link it to an operational discussion topic | Prevents team collisions and gives visible notice in the calendar |
| **US5** | **P2** | Deployer | See official public holidays clearly highlighted before scheduling a critical production deployment | Avoids deploying risky updates on non-working days with minimal support staff |
| **US6** | **P2** | Mobile User | Open the calendar on a smartphone and review upcoming scheduled releases in a responsive agenda view | On-the-go visibility into release schedules |

---

## 8. Functional Requirements & Acceptance Matrix

### 8.1 Functional Requirements

| ID | Description | Phase | Status |
|---|---|---|---|
| **FR-001** | **Rail Section Navigation**: Add Calendar icon to the WUI left rail (`/calendar`) with active indicator and tooltip. | 1 | Planned |
| **FR-002** | **One-Panel Layout**: Navigating to `/calendar` collapses channel and topic panes, dedicating the workspace to the Calendar view with a minimal left rail. | 1 | Planned |
| **FR-003** | **Lazy-Loaded Calendar Bundle**: Calendar components are dynamically imported on route entry, maintaining 0 KB impact on initial WUI bundle. | 1 | Planned |
| **FR-004** | **Week View Default**: Main calendar viewport renders the Week view by default with hourly time slots and all-day header. | 1 | Planned |
| **FR-005** | **Day & Month View Modes**: Segmented toggle allows instantaneous switching between Day, Week, and Month views. | 1 | Planned |
| **FR-006** | **3-Year Mini-Calendar Rail**: Left column displays a virtual-scrolled 3-year continuous window (36 months: prior, current, next year). | 2 | Planned |
| **FR-007** | **Database-Backed Density Dots**: Mini-calendar displays event density indicators loaded via `GET /v1/calendar/density`. | 2 | Planned |
| **FR-008** | **PostgreSQL Event Store & RLS**: `calendar_events` table in `csi-spl-rdb` with `FORCE ROW LEVEL SECURITY` and strict tenant policies. | 2 | Planned |
| **FR-009** | **Hub Calendar API**: Hub serves `/v1/calendar/events` and `/v1/calendar/density` gated by authenticated member session. | 2 | Planned |
| **FR-010** | **Release Tag Integration**: Automatically display release milestones minted by `do_release_version` (`v<X.Y.Z>`). | 2 | Planned |
| **FR-011** | **Event Scheduling & Creation**: Human members and agents can create events with category, time range, description, and metadata. | 3 | Planned |
| **FR-012** | **Topic Linkage**: Calendar events can link bi-directionally to discussion topics (clicking event opens topic). | 3 | Planned |
| **FR-013** | **Official Calendar (Public Holidays)**: Display official public holidays as all-day event banners based on workspace country setting. | 4 | Planned |
| **FR-014** | **Mobile Adaptation**: On viewports <= 820px, left mini-calendar collapses to drawer and main view defaults to Day/Agenda. | 4 | Planned |

### 8.2 Acceptance Scenarios

| # | Scenario | Verification Method | Pass Criteria |
|---|---|---|---|
| **AC-01** | Open Calendar from Navigation Rail | Click Calendar rail icon | Route navigates to `/calendar`; channel/topic sidebars collapse; Week calendar renders. |
| **AC-02** | Bundle Size Budget Verification | Run `pnpm build` and inspect chunk manifest | Initial WUI entry bundle increases by 0 KB; calendar chunk is lazy-loaded asynchronously. |
| **AC-03** | Switch Calendar Views | Click "Day", "Week", "Month" in top switcher | Main calendar updates grid immediately without full page reload or layout shift. |
| **AC-04** | Scroll 3-Year Mini-Calendar | Scroll left column up/down | Mini-months scroll smoothly across past, current, and future years; date clicking jumps main view. |
| **AC-05** | Mini-Calendar Event Density | Inspect mini-month cells for days with events | Date cells show colored dots corresponding to event categories; density data matches database. |
| **AC-06** | Tenant Isolation Probe | Request events across workspace boundary | Hub API returns only events belonging to the caller's active workspace session (`tenant_id`). |
| **AC-07** | Release Milestone Display | View week containing a version release | Release card appears in all-day banner with version tag `v<X.Y.Z>` and release note link. |
| **AC-08** | Responsive Phone Viewport | Test viewport at 390x844 (phone) | 3-year rail collapses; main view renders Day/Agenda view; mini-calendar opens via overlay drawer. |

---

## 9. Numbered Questions for the Owner

The following questions highlight architectural decisions requiring the owner's confirmation:

### Q1. Default Country & Jurisdiction for "Official Calendar"
Owner requirement states: *"It should be able to present, of course, the official calendar..."*
Public holidays differ by country and region. How should the default official calendar be determined?
- **a) Workspace Country Setting with Bulgaria (BG) / EU Default (Recommended)**: The workspace settings specify a default country code (defaulting to BG / European Central bank calendar, configurable per workspace). Official holidays are loaded from a standard offline holiday catalogue.
- **b) Browser Locale Auto-Detection**: Dynamically detect the visitor's local browser country and render their local regional holidays.
- **c) Configurable External iCal / ICS Feed**: Workspace admins provide an external iCal/webcal subscription URL for official holidays.

*Recommended Answer*: **a**

---

### Q2. Automated Release Events: Explicit Scheduling vs Automatic Git Sync
Owner requirement states: *"coordinated and scheduled releases to track everything, all of the events which have been scheduled for a time."*
How should release events be populated in the calendar?
- **a) Hybrid Automatic Sync & Manual Scheduling (Recommended)**: Past releases and deployed git tags (`v<X.Y.Z>`) are automatically synced from `release_notes` (spec 065). Upcoming planned releases and deployment freeze windows are scheduled manually by release managers or autonomous agents via the WUI or API.
- **b) Strictly Manual Scheduling**: All release events must be explicitly scheduled by humans or agents; no automatic backfill from git tags.
- **c) Milestone-Driven**: Release dates are derived strictly from milestone target dates defined in GitHub or issue trackers.

*Recommended Answer*: **a**

---

### Q3. Autonomous Agent Scheduling Authority
Agents (`a-*`, `c-*`, `g-*`, `q-*`) can execute long-running tasks, migrations, and maintenance. Should autonomous agents be permitted to schedule calendar events directly?
- **a) Direct Agent Scheduling with Category Restrictions (Recommended)**: Autonomous agents holding valid credentials can schedule events within `agent_task`, `maintenance`, and `deploy` categories. Only human Workspace Admins can declare `freeze` windows or official holidays.
- **b) Human Approval Required**: Agent calendar requests are placed in a pending state until a human workspace member approves them.
- **c) Human Only**: Only authenticated human members may write to the calendar; agents are read-only.

*Recommended Answer*: **a**

---

### Q4. Component Selection for Main Calendar View
The open-source evaluation evaluated Schedule-X, Qalendar, and FullCalendar.
- **a) Schedule-X (Recommended)**: Modern, MIT license, <30 KB gzipped, TypeScript native, Vue 3 native, modular plugins, excellent dark mode / theme CSS compatibility, fits comfortably within WUI budgets.
- **b) Qalendar**: MIT license, ~35 KB gzipped, Vue 3 native, slightly less customizable styling.
- **c) Custom Handcrafted Scheduler**: Zero external dependencies, built entirely with native Vue 3 and CSS grid, but requires more upfront development effort.

*Recommended Answer*: **a**

---

## 10. Consensus Section (agy author `a-270` & grok peer `g-NNN`)

Per owner msg `c346a4b9`: *"Include also a Grok agent. I would like to see his opinion as well, and you both should reach a consensus."*

### 10.1 Consensus Framework & Mandate
- This specification represents the authoritative draft authored by **a-270** (Antigravity).
- Grok peer **g-NNN** provides an independent architectural opinion in `csi-spl-doc/specs/089-calendar-section/grok-opinion.md`.
- Following the publication of both documents, both agents engage in structured peer exchange on task `6d0afac7-2d13-4cc0-99a4-3f87f4ba21b3` (at most 3 rounds) to establish complete consensus or isolate concise differences for owner resolution.

### 10.2 Points of Baseline Agreement
*(To be reconciled with grok peer)*
1. **Layout ("One panel, not three")**: Replaces standard chat 3-panel layout with dedicated full-viewport workspace; retains minimal left rail; internal division into narrow 3-year mini-calendar column and wide main scheduling canvas.
2. **Default View**: Week view by default, switchable to Day and Month views.
3. **Chunk Budget & Lazy Loading**: Calendar components must be loaded dynamically on route entry to uphold the 160 KB initial-chunk budget.
4. **Data Isolation**: Database persistence in PostgreSQL (`calendar_events`) protected by `FORCE ROW LEVEL SECURITY` with per-workspace tenant scoping.
5. **Purpose**: Primary mission is coordinated release tracking and operational event scheduling (releases, deploys, maintenance, deadlines).

### 10.3 Peer Dialogue & Reconciliation Log
- **Round 1 (Initial Drafts & Opinion Exchange)**: *Pending grok peer initial opinion.*
- **Round 2 (Reconciliation & Cross-Review)**: *Pending exchange.*
- **Round 3 (Final Harmonization)**: *Pending final alignment.*

### 10.4 Disputed Points & Alternative Views
*(Any lingering divergence between a-270 and g-NNN following Round 3 will be listed here with one-line positions for owner decision).*
- *None currently recorded; pending grok peer opinion.*

---

## 11. Not in Scope

- Bi-directional CalDAV or Google Calendar / Microsoft Outlook two-way live synchronization in Phase 1 (iCal one-way read-only subscription evaluated for Phase 4).
- Booking / room reservation systems or personal meeting scheduling.
- Replacing the global Omnibox search with calendar-specific search (calendar search integrates via top-bar Omnisearch in Phase 3).
- Direct modification of Git repository tags from the Calendar UI (git tags remain driven by `do_release_version` and CI/CD pipelines).

---

## 12. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-05 | a-270 | Initial comprehensive draft specification for the Calendar section: captures verbatim owner requirements (topic `6d0afac7`), confirms "one panel, not three" layout architecture, details the 3-year scrollable mini-calendar and week-default scheduling canvas, evaluates open-source calendar components against the 160 KB budget (recommending Schedule-X + lazy loading), defines the PostgreSQL `calendar_events` schema with `FORCE ROW LEVEL SECURITY`, specifies automated release notes integration (spec 065), formulates user stories, functional requirements, acceptance criteria, owner questions Q1-Q4, and the consensus framework for the grok peer. |

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T03:45:00Z -->
