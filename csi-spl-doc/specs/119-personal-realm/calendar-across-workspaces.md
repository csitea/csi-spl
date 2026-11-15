# 119 addition: my calendar across workspaces

**Status**: v0.5, 2026-11-15, c-203 (SPL-5599, epic SPL-2396). Docs
only: builds nothing. All five owner answers folded (HUM-10): Q1 `1a`,
Q2 `2a`, Q3 `3c`, Q5 `5a` (poll `75b0d544`, msg `76f7af1c`, 16:20:00Z) and
Q4 `4b` (poll `555f92f9`, msg `f94ea39e`): pop-ups from every workspace,
with a mute switch per workspace (section 4.1). v0.4 folds the agy spec
review of v0.3 (a-277, FAIL W1..W6, N1..N5), v0.5 the delta review of v0.4
(a-293, FAIL W1..W7, N1..N3); section 12. Build rows:
[tasks.md](tasks.md), section "Calendar across workspaces".
Topic: t1 #spool-hub-ui `26b46de6-28b4-4bdf-93f2-c85346f2a13d`.

Part of [119 personal realm](spec.md) (section 15 links here). Builds on,
and does not repeat: [089 calendar](../089-calendar-section/spec.md) (event
object, audience, reminders), [097 full editing](../097-calendar-full-editing/spec.md)
(guests, recurrence, colour, trash), [149 Google Calendar connect](../149-google-calendar-connect/spec.md),
[118 multi-workspace hours](../118-multi-workspace-hours/spec.md) sections
5.2 and 7 (the read and the write across workspaces this copies).

Phone layout: [106 calendar phone rewrite](../106-calendar-phone-rewrite/spec.md)
(<= 820 px, `CalendarPhone.vue`), which replaced 089's and 097's phone parts.

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

## 1. Facts from the code (origin/master `a6dd716b3`; v0.4 rows rechecked on `5d0525c7d`, v0.5 rows on `1a96997ba`; read, not run)

| fact | check | so |
|---|---|---|
| An event belongs to one workspace: `calendar_events.tenant_id NOT NULL`, FORCE RLS `tenant_scope` on `app.tenant_id` | `csi-spl-rdb/src/sql/postgres/spool-hub/0125_calendar.sql` lines 21, 49..51 | the view reads each workspace in its own scope; no row moves |
| Every calendar read runs in one workspace scope | `store/calendar_postgres.go` `calendarQuery` -> `queryTenant` | one read per workspace, as 118 5.2 |
| The private filter is one expression in the store | `calendar_postgres.go:35` `calendarPrivateSQL`: `audience <> 'private' OR creator_id = viewer OR viewer = ANY (mentions)` | "mine" narrows it, never widens it (section 3) |
| Audiences today: `public` (signed-out visitors), `workspace` (default), `internal`, `private` | rdb `0161_calendar_web_to_public.sql` (the 0159 rename) | a `demo_user` seat in a workspace still gets no `internal` item there |
| Every browser door into a workspace, the calendar routes included, needs `topics.read` in that workspace | `hub/view.go` `viewDoor` -> `s.permit(..., rbac.TopicsRead)`; `hub/resolve.go`; calendar routes are `viewHandler` (`hub/calendar.go` `routeCalendar`) | the realm read skips a workspace where P lacks it (section 4) |
| Seats without `topics.read`: `channel_guest` (no permission at all), `time_accountant`, `external_accountant`; `demo_user` has it and only it enters calendar routes with `internal` stripped | `rbac/rbac.go` lines 136..160; `hub/calendar.go` `isDemoVisitor` | the per-workspace gate is `topics.read`, the strip is `demo_user` (section 4) |
| `Memberships` leaves out a `channel_guest` seat but returns `time_accountant` and `external_accountant` seats | `store/memberships.go` `membershipsSQL` (`m.role <> 'channel_guest'`) | those two reach the realm routes and are stopped by the `topics.read` gate, reads and writes alike (sections 4, 4.1, 5) |
| The 119 realm gate is `realmCaller`: 400 `tenant_named` / `member_named`, 403 `person_only` for a bearer token, an act-as session, a non-`HUM-*` id, a live act-as clone in the session's workspace, or seats that are all `pure_agent` / `time_accountant`; 401 `door`; `no-store` | `hub/realm.go` lines 62..124 (`realmCaller`, `realmRefuses`, `realmSeatsNotPerson`, `realmPersonRe`) | the calendar routes use it, plus 118's `realmClone` over every seat (4.2) |
| `realmPreflight` allows `Authorization, Content-Type, X-Locale` only; the workspace calendar's `calendarPreflight` adds `If-Match` | `hub/realm.go` line 422; `hub/calendar.go` lines 1230..1238 | the realm calendar routes need their own preflight with `If-Match` (4.2) |
| Issue deadlines are read in the **hub**, not the calendar store: `s.deadlinesIn(ctx, tenant, range)` over `s.o.Issues.ListIssues` | `hub/calendar.go` lines 648..661, 740, 831; `store/calendar*.go` never reads `issues` | the "assigned to me" filter is a hub step (3.1, T013) |
| No people-search route exists for the calendar; the guest check reads `ListMembers` and `Roster` of the workspace | `hub/calendar.go` `routeCalendar` (lines 1241..1259), `checkGuestsInWorkspace` (line 464) | the realm `people` route is new and its contract is in section 5 |
| Guests are a subset of `mentions` | 097 section 3.2 | `viewer = ANY (mentions)` covers guests; GIN index `calendar_events_mentions` (0125 line 42) |
| An event has a responsible `owner_id` beside `creator_id` | rdb `0247_calendar_event_links.sql` | "mine" can include "I own it" |
| A person is one `HUM-*` id in every workspace | 118 5.1; `store/rls.go` `personIDRe` | no id mapping |
| The person's workspaces: `Memberships(ctx, human)`, the one allow-listed operator read; it already drops a disabled membership, a disabled human and a membership past `access_until` | `store/memberships.go` line 150 (`h.disabled_at IS NULL AND m.disabled_at IS NULL`), rdb 0113 | no new operator read; leavers fall out by themselves (section 7) |
| Each `Membership` row carries its role set and its raw `tenant_memberships.settings` jsonb | `store/memberships.go` `Membership.Roles`, `Membership.Settings` (line 146 selects `m.settings`) | the mute is read from the list already fetched, no extra transaction (4.1) |
| Realm routes register in their own file's `routeRealm*(mux)`, each called from one line of `hub/channel_order.go`, with an `OPTIONS` preflight per path | `hub/realm.go` `routeRealm`, `hub/channel_order.go` lines 119..122; SPL-5589 (a route without its preflight failed in the browser) | the build rows name that line, not `server.go` (tasks.md) |
| The person scope is built: `inPerson`, `pgScopePerson`, rdb 0168 | `store/rls.go` lines 56..75; 119 tasks T001..T004 `[x]` | the realm is not touched by this view: under Q3 `3c` no realm table is added (section 3.3) |
| 118's cross-workspace read is built: at most 20 workspaces (400 `too_many_workspaces`), a failed one `unavailable`, 403 `person_only` under act-as | `hub/realm_hours_read.go` lines 23..50, 178..193 | the calendar read reuses the same shape and limits |
| Calendar routes read the session's **active** workspace; `X-Spool-Tenant` is for boxes | 089 6.1; 118 5.1 (`hub/resolve.go`) | the existing routes cannot reach a second workspace: the view needs realm routes that name the workspace per call (sections 4, 5) |
| Google Calendar imports are per member **per workspace** connection, stored as that member's `private` events in that workspace | 149 sections 2.1, 2.10 B (`source_key gcal:<connection>:src.<hash>.<google id>`) | a person connected in two workspaces holds the same Google event twice (section 6, Q5) |
| Every event with a `source_key` is read only in Spool: `PATCH` and `DELETE` answer 409 `synced_read_only`; Google imports are never written back | `hub/calendar.go` lines 1064, 1164 (`cur.SourceKey != ""`); 149 sections 2.5, 2.10 B | a folded Google import is shown, never edited (section 6) |
| Google imports carry no reminder | `hub/gcal_sync_in.go`: `grep -ci remind` -> 0 | a Google import never pops (4.1) |
| An issue deadline on the calendar is read only and never draggable; it opens the issue | SPL-2034: `CalendarMainView.vue` lines 22..28, `CalendarEventPopover.vue` line 79; 089 6.1.2 (deadlines change only through `PATCH /v1/issues/{ref}`, active workspace) | the same in the personal view (3.1, 5) |
| Reminder pop-ups read the active workspace only | 089 4.3, `GET /v1/calendar/reminders`; `csi-spl-wui/src/utils/calendar-reminders.mjs` | the realm reminders read of 4.1 (Q4 `4b`) |
| The workspace reminders route builds its list with `s.reminderEvents` (097 `props.reminders` through `ListCalendarEvents`, plus 089 `remind_at` through `store.CalendarReminders`) and fires with `reminderFires` | `hub/calendar.go` lines 857, 889, 895 | the realm read reuses those two, never `store.CalendarReminders` alone (that drops 097 reminders) (4.1) |
| A person's per-workspace setting is one key of `tenant_memberships.settings` jsonb, written by `PUT /api/v1/auth/preferences` for the active workspace; the hub admits only known keys and `null` removes a key (`hours_reading`: "true, false or null") | rdb `0078_membership_settings.sql`; `auth/handler.go` `preferencesReq`, `parseHoursReading` | the per-workspace mute is one new key, no DDL (4.1) |
| The settings jsonb decodes into `auth.MembershipSettings`; `HumanSettings.Overlay` lays it over the person's globals for `GET /api/v1/auth/session`, which the settings dialog reads | `auth/settings.go` lines 67..104, `store/membership_settings.go` | the mute key is a field there too, or the decode drops it (4.1, T016) |
| The workspace year strip allows 5 calendar years (`to - from < 5`) | `hub/calendar.go` line 57 `calendarMaxYears = 5`, line 611 | the realm marks route takes the same bound (section 4) |
| One list read returns at most 2000 events | `store/calendar.go:278` `calendarMaxEvents` | per-workspace cap in the view (section 9) |
| No workspace colour exists | `grep -rln "workspace_color\|workspaceColor\|tenantColor" csi-spl-wui/src csi-spl-api/src/go/spool-hub-api/internal` -> none | the source marker is new (section 3.3) |
| A workspace setting that is not a column is one key of `tenants.settings` jsonb; the hub registers its kind, default and check; an absent key reads as the default | rdb `0136_tenant_settings_jsonb.sql`; `store/tenant_kv.go` `RegisterTenantSetting`; spec 098 sections 3, 10 | the workspace colour is a new key, no DDL (section 3.3) |
| `PATCH /v1/tenant/settings {settings: {key: value \| null}}` checks `tenant.settings`, held by default by `biz_owner` and `admin` | `hub/tenant_settings.go` `handlePatchTenantSettings`; `rbac/rbac.go` `Defaults` | who may set the colour, no new route or permission |
| The event colour is one of 11 palette names, each a theme variable in light and dark | 097 section 6 (`color`: `tomato` .. `graphite`) | the workspace colour takes the same palette |
| An issue deadline is `issues.deadline` of an issue whose `assignee` is a `HUM-*` id | rdb `0047_issues.sql` lines 57, 61; 089 6.1.1 (`source = issue`) | "assigned to me" is `assignee = P` |
| Initial JS: ceiling 155 KB gzip, last metric 153.4 KB | `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json` `ci_initial_gzip_kb` | the page adds 0 bytes to first paint (section 9) |

`store/` and `hub/` are under `csi-spl-api/src/go/spool-hub-api/internal/`.

## 2. The view

A realm page, **My calendar** (`/me/calendar`), one lazy chunk. It shows the
signed-in person's own entries (section 3) from every workspace in
`Memberships(caller)`, merged on one grid, each marked with its workspace
(section 3.2). The views the workspace calendar ships, with the same ids:
`day`, `3day`, `week`, `month` on desktop (`CalendarViewTabs.vue`), and
`month`, `week`, `day` on the phone (106, `CalendarPhone.vue`). Entry points: the realm's
navigation (119 T009); an "All my workspaces" link for a person with 2+
workspaces, on desktop in the workspace calendar's vertical tab group
(`CalendarViewTabs.vue`; there is no header bar on desktop, SPL-4060). The
link carries nothing from the other workspaces into the workspace page.

With one workspace the page shows that workspace's own entries. With none it
says where entries come from.

## 3. Which entries count as "mine"

### 3.1 The rule (owner: Q1 `1a`)

An event E of workspace W is **mine** for person P when, inside W's scope:

- P made it (`creator_id = P`), or
- P is its responsible owner (`owner_id = P`, rdb 0247), or
- P is a guest or `@`-mentioned on it (`P = ANY (mentions)`; guests are a
  subset, 097 3.2), or
- it is an issue deadline (089 4.1, `source = issue`) of an issue in W
  whose `assignee = P` and whose `deadline` falls in the window. It is read
  only and never draggable, as on the workspace grid (SPL-2034): it opens
  that issue in W, where its deadline is changed (section 5).

A declined RSVP keeps the event mine: 097 4.5 keeps a declined guest in
`event_guests` and `mentions`, so P still sees it (marked declined) and can
change the answer back.

Not mine: a `workspace`, `internal` or `public` event P can merely read.
Official days are not shown (they are a workspace's region tint, 089 4.1,
and two regions would clash). A Google import (149) is P's own private event
in W, so it counts.

The store gets one predicate, added with AND after the private filter:
`(creator_id = $2 OR owner_id = $2 OR $2 = ANY (mentions))`. Issue
deadlines are not a store read (section 1): the realm read calls the hub's
existing `s.deadlinesIn(ctx, W, range)` in W and keeps only the issues
whose `Assignee == P`. Every event the store
returns already passes `calendarPrivateSQL` for the same viewer, so the view
can never show an event the workspace calendar would hide from P.

### 3.2 Each entry keeps its workspace

- **Saved in its own workspace.** Nothing is copied into the realm: no
  `personal.*` table holds an event, a title or a time. The view is a live
  read (section 4); reload it and it reflects each workspace's current rows.
- **Marked with its workspace.** Every chip carries its workspace's colour
  bar (section 3.3) and the pop-over names the workspace. The event's own colour (097
  3.3 `props.color`) stays the chip fill, so both read at once.
- **Identity** is the pair `(workspace_id, event_id)`, never `event_id`
  alone, on the wire and in the WUI store.
- **Edit opens that workspace's rules** (section 5): who may edit (089 4.2,
  097 4.5 `notes.send`), owner-only `private`, guests from that workspace
  only, its trash and undo. A rule a workspace has is never relaxed, and a
  workspace never learns that the change came from the personal view.

### 3.3 The workspace colour (owner: Q3 `3c`)

The owner chose `3c`, not the recommended `3a`: the colour is a **workspace
setting** an admin sets, the same for every member. It is not the personal
realm's per-person colour, and no person can change it for themselves.

- **Where it is stored**: one key of the workspace's generic settings,
  `tenants.settings -> 'calendar.color'` (rdb 0136, spec 098), registered in
  the hub as `RegisterTenantSetting({Key: "calendar.color", Kind:
  SettingString, Default: "", OneOf: ["", <the 11 palette names of 097
  section 6>]})`. No DDL, no realm table, no new column; a 098 section 10
  row. It rides the cached tenant row, so the read in section 4 costs no
  extra query.
- **Who may set it**: whoever holds `tenant.settings` in that workspace
  (by default `biz_owner` and `admin`, `rbac.Defaults`), through the
  existing `PATCH /v1/tenant/settings {"settings": {"calendar.color":
  "peacock"}}`; `null` resets it to the default. One row on the workspace
  settings page (palette swatches, >= 44 px). No new route or permission.
- **The default** when no admin has set one (`""`): the hub picks a palette
  name from the workspace id (the first 4 bytes of `sha256(workspace_id)`
  modulo 11), so it is stable and the same for every member and device
  without a write. Two workspaces may get the same default colour; the name
  in the chip row and the pop-over still tells them apart, and an admin can
  pick another.
- **On the wire**: each `workspaces[]` entry of section 4 carries `color`,
  the effective palette name (set or default), never `""`.
- **Hiding a workspace** in the view (the chip toggle, section 9) is a
  per-browser convenience in `localStorage`, not a stored preference: under
  `3c` nothing per person is written to the hub.
- The event's own colour (097 `props.color`) stays the chip fill and the
  workspace colour is the bar, so the two do not compete.

## 4. The read path, RLS unchanged

`GET /v1/me/realm/calendar/events?start=<ISO>&end=<ISO>`

- **Who**: the gate of 4.2 (`realmCaller`, then `realmClone`). The person is the session's human, never a request
  field (119 7.2).
- **Window**: `start < end`, at most 62 days (a month grid with its spill
  is 42), the 118 5.2 bound.
- **Which workspaces**: `Memberships(caller)` that pass the per-workspace
  gate below; at most 20, a 21st is 400
  `too_many_workspaces`, never dropped. No new operator-scoped read
  (`TestOperatorScopeCallers` gains nothing).
- **How**: for each workspace W, the existing `ListCalendarEvents(ctx, W,
  caller, range)` in W's own workspace scope with the "mine" predicate on
  (3.1), recurrence expanded as today (`calendarWithSeries`), plus the
  deadlines of W's issues assigned to P (`s.deadlinesIn`, filtered in the
  hub, 3.1). For a seat whose
  primary role in W is `demo_user`, the hub drops `internal` items as the
  workspace route does (`isDemoVisitor`).
- **Per-workspace gate**: a workspace W where P lacks `topics.read`
  (`s.allowed(ctx, P, W, rbac.TopicsRead)`, the check of every browser door,
  section 1) is skipped before any read: a `time_accountant` or
  `external_accountant` seat cannot read W's calendar through the realm
  route either (`Memberships` never returns a `channel_guest` seat). It is left out of `workspaces[]`
  altogether, read nothing, and does not count toward the 20.
- **Concurrency**: at most **2 workspaces in flight** (the 118 bound,
  pool 8). Never `asOperator`, never `app.rls_scope = operator`.
- `app.person_id` is never set in a calendar transaction: the read touches no
  realm table (under Q3 `3c` there is none to read).
- **A failed workspace** (store error, timeout, membership removed
  mid-request) comes back as `{"workspace_id": W, "state": "unavailable"}`,
  never a silent empty list and never retried under a broader scope.
- **Answer**: `{"start","end","workspaces":[{"workspace_id","name","color","state"}],
  "events":[event + "workspace_id" + "workspace_ids"]}`, events by
  `starts_at`, then `workspace_id`, then `id`. `state` is `ok`,
  `unavailable` or `truncated`. The event object is 089 6.1.1 plus
  `workspace_id` (the workspace whose row this is) and `workspace_ids`
  (every workspace P sees this event through: one entry, or more for a
  folded Google import, section 6; `workspace_id` is always its first).
  Mention and guest names are resolved inside W's read only.
- **Year strip**: `GET /v1/me/realm/calendar/marks?start_year=&end_year=`,
  the same bound as 089's strip (`end_year - start_year < 5`,
  `calendarMaxYears`), the same gate and fan-out over `CalendarMarks`.
  Answer: `{"start_year","end_year","workspaces":[...as above],
  "days":[{"day","count","kinds","workspace_ids"}]}`: 089's day item plus
  `workspace_ids`, the workspaces with an entry of P's that day; `count`
  is the sum over them.
- Nothing is written by a read; no log line carries a title or a description
  (workspace id, counts and timings only).

### 4.1 Reminder pop-ups across workspaces (owner: Q4 `4b`)

The owner chose `4b`: P gets the pop-ups of the entries of every workspace
P belongs to, whichever workspace is open, and can mute any one workspace.

- **Read**: `GET /v1/me/realm/calendar/reminders?from=&to=` (RFC 3339).
  The gate of 4.2. Each workspace W of `Memberships(caller)` that passes
  the section 4 `topics.read` gate and is not muted is read in its own
  workspace-scoped transaction with the hub's existing `s.reminderEvents`
  (097 `props.reminders` and 089 `remind_at` together) and
  `reminderFires`, exactly as `GET /v1/calendar/reminders` does for the
  active workspace; never `store.CalendarReminders` alone, which drops every
  097 reminder. At most 20 workspaces, 2 in flight, `unavailable` per failed
  workspace. "Mine" (3.1) is not applied: a reminder is sent today to
  whoever the workspace route sends it to, and that set is kept per
  workspace; the read only stops being limited to the open one.
- **400s**: `bad_range` on a missing or unparseable `from` or `to`, on
  `from >= to` and on `to - from > 31 days` (the workspace route's own
  parse, `calendarRange(r, "from", "to", calendarMaxReminderDays)`); `too_many_workspaces` on a
  21st gated workspace; the 4.2 refusals.
- **Answer**: `{"from","to","workspaces":[{"workspace_id","name","color","state"}],
  "reminders":[<the workspace route's reminder item> + "workspace_id"]}`,
  `state` one of `ok`, `muted`, `unavailable`; reminders by fire time, then
  `workspace_id`, then event id.
- **Each pop-up names its workspace** (name and the 3.3 colour) and opens
  the entry in the personal view's sheet (section 5's rules). The WUI's
  dismissed-reminder key includes the workspace
  (`<workspace_id>/<event id>@<remind_at>`), so the same event id in two
  workspaces never hides the other's pop-up.
- **Google imports do not pop**: an import carries no reminder (section 1),
  so Q5's fold needs no rule here. If a later 149 change imports reminders,
  that change says how a folded import pops (once, from the first unmuted
  workspace in `workspace_ids`); this spec adds nothing for it now.
- **The mute switch**: one boolean key `calendar_reminders_muted` in P's
  `tenant_memberships.settings` of W (rdb 0078, the per-workspace override
  that already holds `time_zone` and `hours_reading`; no DDL). It is a field
  of `auth.MembershipSettings` (`*bool`, `omitempty`) and of
  `HumanSettings` through `Overlay`, and it is answered both by
  `GET /api/v1/auth/session` (`auth/handler.go`) and by the native login
  answer (`auth/native.go` `loginResp`, which mirrors every session
  preference, `hours_reading` at line 444, because the WUI adopts it
  without a second `/session` read). So the settings dialog shows its state
  right after sign-in.
  Absent = not muted, so nothing changes for anyone until they mute.
- **Read without a transaction**: the fan-out decodes the key from
  `Membership.Settings`, already in the `Memberships(caller)` list. A muted
  W opens no transaction and comes back `{"workspace_id": W, "state":
  "muted"}`. The section 9 count for this route is 1 + the number of
  gated, unmuted workspaces.
- **What mute means**: no pop-up from W at all, including while W is open.
  Muting changes pop-ups only: W's entries still show in the personal view
  and in W's calendar, and nothing in W changes for any other member.
- **Where it is set**: a bell toggle on W's chip in the personal view
  (section 9) and one row in P's notification settings while W is open.
  - The chip writes `PUT /v1/me/realm/calendar/{workspace_id}/reminders`
    with body `{"muted": true}` or `{"muted": false}`. The gate of 4.2;
    then W in `Memberships(caller)` (else 403 `not_a_member`, nothing
    written); then `topics.read` in W (else 403 `forbidden`, as for every
    realm calendar route that names W, so an accountant seat cannot mute a
    calendar it cannot see); 400 `bad_request` on a missing or non-boolean
    `muted` and on
    any other key. `true` stores `true`; `false` removes the key (one
    "not muted" state, never a stored `false`). It writes in W's scope the
    same way `PUT /api/v1/auth/preferences` does. 200
    `{"workspace_id": W, "muted": true|false}`.
  - The settings row writes `PUT /api/v1/auth/preferences
    {"calendar_reminders_muted": true | false | null}` for the active
    workspace. Its parser departs from `parseHoursReading` on purpose:
    that one stores `false` (`auth/hours_reading.go` line 30); this one
    turns both `false` and `null` into "remove the key", so a stored
    `false` never exists and the session answers `null` when not muted.
  - A member of W sets only their own key; no admin sets it for another
    member.
- **Act-as, agents, boxes**: the realm routes are 403 for them (4.2), so
  the WUI's timer keeps reading today's `GET /v1/calendar/reminders` of the
  open workspace under act-as; that route is unchanged and ignores the
  mute.
- **Nothing flows down** (section 8): the reminders read of W1 never reads
  W2's rows; W1 never learns whether P muted W2.

### 4.2 The gate every realm calendar route shares

Every route under `/v1/me/realm/calendar/` (sections 4, 4.1, 5) starts
with the same check before anything is read or written:

1. **`realmCaller`** (`hub/realm.go`, 119's realm gate), as is: 400
   `tenant_named` on an `X-Spool-Tenant` header, 400 `member_named` on a
   `member=` parameter; 403 `person_only` for a bearer (box or agent)
   token, an act-as session, an id that is not `HUM-*` (`realmPersonRe`),
   a live act-as clone in the session's workspace, and a person whose
   seats are all `pure_agent` or `time_accountant` (`realmSeatsNotPerson`);
   401 `door` with no session; `Cache-Control: no-store`. (118's
   `realmPerson` is not used: it checks none of the last three.)
2. **`realmClone` over every seat**: after `Memberships(caller)`, a live
   act-as clone in any of P's workspaces is 403 `person_only`, as 118's
   hours read does (`hub/realm_hours_read.go` line 183).
3. **No workspace parameter**: 400 `workspace_named` on a `workspace=`
   parameter (new code, the same shape as `member_named`); a route that
   acts on one workspace names it in the path, never in the query.
4. **Its own preflight**: `realmCalendarPreflight(methods)`, which is
   `realmPreflight` plus `If-Match` in `Access-Control-Allow-Headers` (as
   `calendarPreflight` has), registered as `OPTIONS` on every path. Without
   `If-Match` the browser's `PATCH` and `DELETE` of section 5 fail their
   preflight (SPL-5589 was the same class of fault).

Each route that names a workspace W then checks W is in
`Memberships(caller)` (403 `not_a_member`) and that P holds `topics.read`
in W (403 `forbidden`).

## 5. Writing from the view (owner: Q2 `2a`)

The owner chose `2a`: yes, under that workspace's own rules; a new entry asks
for the workspace first.

- **Edit, move, resize, delete, restore, RSVP**:
  `PATCH|DELETE /v1/me/realm/calendar/{workspace_id}/events/{id}`,
  `POST .../{id}/restore`, `POST .../{id}/rsvp`. The hub runs the 4.2
  gate with its membership (403 `not_a_member`, nothing read or written)
  and `topics.read` (403 `forbidden`) checks on W, then runs the **same** store call and the same checks as
  the workspace route, in W's own workspace scope: `If-Match` (097),
  owner-only `private` (089 4.2), the edit permission, edit scopes of a
  series (097 4.4), guest notices (097 4.5), 409 `synced_read_only` on an
  event with a `source_key` (a Google import, section 6). One handler body
  serves both routes, taking the workspace as an argument, so the rules
  cannot drift.
- **Create**: `POST /v1/me/realm/calendar/{workspace_id}/events`. The
  dialog asks for the **workspace first** (chips of the person's workspaces;
  preselected: the last one used, else the one the person came from).
  Every picker reads that workspace only, and changing the workspace
  clears what was picked:
  - guests and mentions: `GET /v1/me/realm/calendar/{workspace_id}/people?q=`,
    a **new** route (no workspace people search exists to reuse, section
    1). The 4.2 gate with its checks on W. It reads W's active human
    members (`ListMembers`) and roster agents (`Roster`), the same two
    lists `checkGuestsInWorkspace` checks a guest against, so whoever it
    offers the write accepts. `q`: 1..64 characters after trimming (400
    `bad_query` otherwise), matched case-insensitively as a substring of
    the display name or the id. Answer: `{"workspace_id": W, "people":
    [{"id", "type", "display_name"}]}`, `type` `human` or `agent`, at
    most 20, by display name then id; never an email or another field of
    the member row;
  - topic links: the topic entries of 118's existing
    `GET /v1/me/realm/targets?workspace=<W>&q=` (membership-checked, read
    under `inTenant(W)`). Known and accepted: that route refuses W for any
    seat that holds `time_accountant`, even beside a member role
    (`seatAccountant`, `hub/realm_hours_write.go`), so such a person types
    the topic ref instead, resolved in W on save as issue refs are;
  - issue links: no cross-workspace issue search in this version. P types
    the issue ref; the write resolves it in W under the workspace route's
    own link check, so an unknown ref is refused exactly as there.
- **No move between workspaces.** An event's workspace cannot change: moving
  it is a delete in A and a create in B, two visible writes (118 7.4).
- Drag across days in the merged grid writes only to that event's workspace.
- An issue deadline (3.1) is read only in the view and cannot be dragged,
  as on the workspace grid (SPL-2034, 089 6.1.2). Its sheet opens the issue
  in W; the deadline is changed there.

## 6. Google Calendar imports (149)

- 149's connections stay per member per workspace; this spec changes no
  sync. The out half ("Spool Hub" calendar) keeps sending each workspace's
  events from that workspace's connection.
- A Google event P imports through connections in A and B is two private
  rows (one per workspace) with the same calendar hash and Google id at the
  end of `source_key`. The owner chose Q5 `5a`: the view shows it **once**,
  marked "Google", with both (all) the workspaces it came through, each with
  its colour (3.3). On the wire it is one event: `workspace_id` is the first
  workspace in `Memberships` order, `workspace_ids` lists all of them
  (section 4).
- **Read only, as in 149**: a Google import is never edited, moved or
  deleted in Spool (409 `synced_read_only` on the realm routes as on the
  workspace routes; 149 sections 2.5, 2.10 B). The sheet says to change it
  in Google; the next sync brings the change into each workspace. (Today's
  popover line for a synced event reads "change it in the repo", written
  for 112's repo sync; the realm sheet says Google for a `gcal:` key.)
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
(colour, name, a count for the window, a bell for the 4.1 mute) that toggles a workspace on or off in
the view (remembered per browser, 3.3); an unavailable workspace is a grey chip
"could not be read, retry". The pop-over shows the workspace first, then the
089 / 097 details.

**Phone (<= 820 px, 360 and 390 px)**: laid out as the 106 phone
calendar (its `month` / `week` / `day` views, `day` first, and its sheet), each row
with the workspace colour bar and name; the workspace chips wrap, never
scroll sideways; the event opens the 106 sheet; controls 44..48 px; swipe
for the previous or next week.

**Budgets**

- Initial JS: **+0 KB**. The page and its store are a lazy route chunk; the
  grid comes from the calendar chunk the workspace page already loads (089 3,
  `defineAsyncComponent`). Gate: `perf-budget.py` (155 KB ceiling, metric
  153.4 KB: there is no room).
- Hub: 1 `Memberships` read + 1 workspace-scoped read per workspace (at most
  20), 2 in flight, each the existing indexed range read
  (`calendar_events_tenant_range`, `calendar_events_mentions`). A counting
  test pins the transaction count (1 + N, N the workspaces that pass the
  `topics.read` gate; for reminders, those also not muted, 4.1) and that no
  transaction sets both `app.tenant_id` and `app.person_id`.
- Answer size: at most 2000 events per workspace (`calendarMaxEvents`); a
  workspace that hits it is marked `truncated` in its `workspaces[]` entry,
  never silently cut.
- Latency: measured first (`csi-spl-doc/doc/md/lesson-speed-up-measure-first.md`).
  The build lane records the p95 of `GET /v1/calendar/events` for one
  workspace and of the new route for 1, 5 and 20 workspaces (n >= 12 each),
  and sets the ceiling from that measurement. Target before measuring:
  5 workspaces within 3x the single-workspace p95 (2 in flight).

## 10. Tests (for the build rows; Postgres, runtime role)

- **T-CAL1** "mine" (store, T012): in W, P sees events P made, owns, is
  a guest of (declined included) and is mentioned on; P does not see a
  `workspace` event of Q's. Red control: drop the predicate, P's list
  grows.
- **T-CAL1b** deadlines (hub, T013): the realm read returns the deadline
  of an issue in W assigned to P and not that of an issue assigned to Q.
  Red control: drop the `Assignee == P` filter, Q's deadline appears.
- **T-CAL2** private never leaks: Q's private event in W (P neither owner nor
  named) is in no answer of P's. Red control: drop `calendarPrivateSQL` from
  the per-workspace read.
- **T-CAL3** scopes: a store spy shows one transaction per workspace with one
  `app.tenant_id` each, none with `app.person_id` alongside, none operator.
- **T-CAL4** routes: on every realm calendar route (events, marks,
  reminders, the mute `PUT`, each write, `people`): 403 `person_only` under
  act-as (session provider and a store clone row in a second workspace),
  for a box token, for a non-`HUM-*` id and for a person whose seats are
  all `pure_agent`; 400 `tenant_named`, `member_named`, `workspace_named`;
  the `OPTIONS` preflight answers 204 and its `Access-Control-Allow-Headers`
  contains `If-Match`. 400 on a 63-day events window, a 5-year marks range,
  a 21st workspace and a 65-character `q`. Red control: register the
  event paths with `realmPreflight`, the `If-Match` assertion fails.
- **T-CAL5** leavers: after removal, after `access_until`, while disabled,
  W's events are absent; after re-enable they return.
- **T-CAL6** unavailable: a stubbed failure in W returns W `unavailable` and
  the others' events.
- **T-CAL7** writes: a write to a W not in `Memberships` is 403
  `not_a_member` and writes nothing; a non-owner setting `private` through the
  realm route is 403 as on the workspace route (one handler, both routes);
  act-as and an agent get 403 `person_only` on each write; `people?q=` in
  W returns W's members and agents only, never one of W2. Red control:
  skip the membership check, the write to the foreign W lands.
- **T-CAL8** seats: a `demo_user` seat in W gets no `internal` item of W;
  a `time_accountant` or `external_accountant` seat in W (beside a member
  seat in W2) gets nothing of W from events, marks or reminders (W absent
  from `workspaces[]`) and 403 `forbidden` on every route naming W: each
  write, `people`, and the mute `PUT`. Red control: drop the
  `topics.read` gate, the accountant seat reads W's `workspace` events.
- **T-CAL9** Google: one Google event imported in A and B shows once, with
  `workspace_ids` = [A, B]; `PATCH` and `DELETE` of it through the realm
  route are 409 `synced_read_only`. Red control: skip the `source_key`
  guard in the shared handler body, the `PATCH` returns 200.
- **T-CAL10** nothing flows down: W1's workspace calendar, reminders and
  marks for P are byte-identical with and without P's W2 events.
- **T-CAL11** workspace colour: an unset `calendar.color` reads the same
  default for two members and twice in a row; a member without
  `tenant.settings` gets 403 on setting it; a name outside the palette is 400
  `bad_setting`; `null` returns it to the default. Red control: drop the key's
  `OneOf`, the bad name is stored.
- **T-CAL12** reminders and mute (Q4 `4b`): P in W1 and W2 with W1 open
  gets W2's reminder from the realm route, the pop-up naming W2; after P
  mutes W2, W2 is `muted` and none of its reminders comes back, while W1's
  still do; Q in W2 still gets W2's reminders; unmute returns them and
  removes the key. A W2 event with two 097 `props.reminders` fires both.
  A muted W2 opens no transaction (store spy). A missing, non-boolean or
  extra key in the body is 400; a W not in `Memberships` is 403
  `not_a_member` and writes nothing; `GET /api/v1/auth/session` with W2
  active shows `calendar_reminders_muted: true`; `PUT
  /api/v1/auth/preferences` with `false` or with `null` removes it (the
  stored settings hold no `calendar_reminders_muted` key); the native
  login answer carries it as the session does. 400 `bad_range` on a
  32-day window and on `from >= to`. Red controls: drop the mute check from
  the fan-out, W2's reminders return while muted; read with
  `store.CalendarReminders` alone, the `props.reminders` fire is missing.
- **e2e** at 390 px and desktop (T017): the merged view, the chips, the
  sheet; two workspaces holding an event with the same id show both,
  each with its own workspace bar; an issue deadline does not drag. Red
  control: key the store by event id alone, one of the two events is
  lost. The reminder e2e is T018's.

## 11. Questions for the owner

All five answered by HUM-10 on 2026-11-15 in t1 `26b46de6`. Q1, Q2, Q3,
Q5 at 16:20:00Z (poll `75b0d544`, msg `76f7af1c`), verbatim:

> Answer 1: 1A — Events I made, own, am a guest of or am @mentioned on, plus
> deadlines of issues assigned to me
> Answer 2: 2A — Yes, under that workspace's own rules; a new entry asks for
> the workspace first
> Answer 3: 3C — A colour per workspace set by its admin, the same for
> everyone
> Answer 5: 5A — Shown once, marked with both workspaces

Q4 (blocker poll `555f92f9`, re-asked by the dispatcher at 18:31Z with
options A every workspace, B A + mute per workspace, C as today; msg
`f94ea39e`), verbatim:

> Poll: 555f92f9-d8d9-4724-938b-c488715b428c Answer: B — The same as A,
> plus a mute switch per workspace

| question | answer | folded into |
|---|---|---|
| Q1 what counts as "my" entry | `1a` (recommended) | 3.1, T-CAL1, T012 |
| Q2 create and edit from the view | `2a` (recommended) | 5, T-CAL7, T014 |
| Q3 how each entry's workspace is shown | `3c` (not the recommended `3a`) | 3.3, T-CAL11, T015 |
| Q4 reminder pop-ups across workspaces | `4b` (poll option B) | 4.1, T-CAL12, T016, T018 |
| Q5 a Google event through two workspaces | `5a` (recommended) | 6, T-CAL9, T013 |

**Q4. Reminder pop-ups across workspaces?** The poll's three options, kept
here with this file's keys: `4a` the pop-ups of all my workspaces'
entries, whichever workspace is open; `4b` (chosen) `4a` plus a mute switch
per workspace; `4c` as today, only the open workspace's. Folded as section
4.1. One reading is this file's, not the owner's words: a muted workspace
gives no pop-up even while it is the open one. The v0.3 spec review (a-277)
confirmed it as the natural reading of the poll's option B, and the
dispatcher (c-002) adopted it in the post to the owner.

## 12. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-11-15 | c-203 | draft: view, "mine", workspace kept, read and write paths, Google duplicates, leavers, privacy, phone and desktop, budgets, tests, Q1..Q5 |
| 0.2 | 2026-11-15 | c-203 | owner answers folded: Q1 `1a` (issue deadlines by `assignee`), Q2 `2a`, Q3 `3c` (new 3.3: `tenants.settings` key `calendar.color`, set with `tenant.settings`, default from the workspace id; no realm table), Q5 `5a`; Q4 open, owner discussing; T-CAL11 |
| 0.3 | 2026-11-15 | c-203 | Q4 folded: `4b` (poll `555f92f9`, msg `f94ea39e`), pop-ups from every workspace plus a mute per workspace; new 4.1 (realm reminders read, `calendar_reminders_muted` key in `tenant_memberships.settings`, chip bell, `muted` state); fact row for rdb 0078; T-CAL12; Q4 options renamed to the poll's three (`4a`..`4c`) |
| 0.4 | 2026-11-15 | c-203 | agy spec review of v0.3 folded (a-277, FAIL on `83fbfca9c`): W1 Google imports read only (409 `synced_read_only`, 149), no edit of a folded import; W2 issue deadlines read only and not draggable (SPL-2034); W3 new 4.2 gate on every realm calendar route (`person_only`, 400s, preflight) and the per-workspace `topics.read` gate; W4 mute key in `auth.MembershipSettings` / session overlay, read from `Membership.Settings`, full 400 / 200 contracts, `false` removes the key; W5 build rows (tasks.md); W6 `reminderEvents` + `reminderFires`, `workspace_ids`, `/marks` shape, pickers. N1 `demo_user`; N2 declined RSVP stays mine, 5-year strip, 106 for the phone; N3 line cite; N4 footers |
| 0.5 | 2026-11-15 | c-203 | agy delta review of v0.4 folded (a-293, FAIL on `ffccfc1cb`): W1 own preflight `realmCalendarPreflight` with `If-Match`; W2 4.2 is `realmCaller` (not `realmPerson`) plus `realmClone` over every seat, 400 `workspace_named`; W3 deadline filter in the hub over `s.deadlinesIn`, T-CAL1b; W4 WUI files and serial locale lanes (tasks.md); W5 red controls on T-CAL4, T-CAL7, T-CAL9 and the e2e, spec 098 row owned by T015; W6 native login answer, parser departs from `parseHoursReading`, `topics.read` on the mute `PUT`; W7 the `people` route is new and has its contract. N1 shipped view ids; N2 `targets` refuses an accountant add-on seat, accepted |

<!-- version: 0.5.0 · updated: 2026-11-15 -->
