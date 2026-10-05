# Calendar section — opinion

**Feature**: `089-calendar-section` · **Date**: 2026-10-05

The owner asked for a Calendar section: an open-source control, the official calendar, and day, week and month views, as one work area. A later message (`e3d63084`) widens it: any timed thing people and agents coordinate, including a person's own alerts. A release is one kind of event. Keep it basic.

Written from the code on `origin/master`, then shortened for that message. Library versions are from the public npm registry on 2026-10-05. Those packages were not installed here.

The product word is workspace. The column that isolates one is `tenant_id`.

## Layout

A new rail id, `calendar`, route `/calendar`. The icon rail stays. The channel, topic and thread panes do not. This matches a section page such as Issues (`csi-spl-wui/src/pages/issues.vue`): the rail and one sheet. The existing `events` rail is a personal log (`csi-spl-wui/src/pages/events.vue`) and stays as it is.

Desktop, wider than 820 px: two columns in that sheet.

- Left: the small months of last year, this year and next year (36), scrolling and then stopping. A dot is a day with an event. A tint is an official day. Both come from the database. Click a day and the main view moves to that week.
- Right: the main view, opening on the week. A switch in the same header selects Day, Week or Month. The week is a time grid with an all-day band and hours, opened on the working day, and a line for now. Drag moves an event. The control's own toolbar stays hidden.
- Opening an event is a dialog, as an opened issue is. There is no third column.

Phone, at 820 px and under, already shows one panel (`useMobileStack.ts`). `/calendar` is level 2 with the section strip. It opens on the day. Week is a list grouped by day. The year strip sits behind a button.

## The control

The first-paint ceiling `ci_initial_gzip_kb` is **155** (`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`; it was 160 until 2026-10-02). The calendar route is a dynamic import, the way other heavy sections stay out of the initial chunk. The implementing change re-measures that gzip and keeps it at or under 155.

The grid (overlap, drag, day, week, month) is an MIT control. The year strip is our Vue. It draws our marks. It does not need a second package.

Registry the same day:

| package | version | licence | note |
|---|---|---|---|
| `@schedule-x/calendar` | 4.9.1 | MIT | peers Preact and `temporal-polyfill` pinned to 0.3.2 |
| `@schedule-x/vue` | 4.1.0 | MIT | lags that core; peers `@schedule-x/date-picker` at exactly 4.2.0 |
| `@fullcalendar/vue3` | 7.1.0 | MIT | same version as its core; depends on Preact; peer `temporal-polyfill` `^1.0.1` |

Use Schedule-X for the grid when pnpm installs one coherent MIT set. If that Vue package still requires the date-picker, use `@fullcalendar/vue3` standard views, still lazy. Leave any non-MIT add-on out. A published gzip for an older build is not the gate.

## Events

An event has a title, a start, an end, and who it is for: one person, one agent, or the whole workspace. Kind is a label (release, deploy, maintenance, reminder, other). Create, edit and delete are the actions. Invitations, RSVP and a recurrence editor stay out.

A reminder is an optional time on the event. When it is due, the hub sends a spool message to the people and agents it names. Delivery already notifies the pane (`csi-spl-api/src/go/spool-hub-api/internal/notify`). The WUI shows that message as it shows any other.

An agent uses the same hub route as the page. The existing CLI and `spool mcp` (`internal/mcp`) each grow one call that hits that route. One table.

An issue deadline is already a time (`issues.deadline` in `0047_issues.sql`). The grid reads it. Editing that block writes the issue.

A `v<X.Y.Z>` tag is a label on a release someone scheduled, once a deploy lands in its window. Spec 065 measured on the order of a hundred such tags a day. The grid shows the scheduled release.

Official days live in one shared table, keyed by region and date. A workspace setting names its region and starts empty. Holidays are rows in that table.

## Store

`calendar_events` carries `tenant_id` referencing `tenants(tenant_id)`, with `ENABLE` and `FORCE ROW LEVEL SECURITY` and the two policies from `0104_flow_events.sql` (`app.tenant_id`, and `app.rls_scope` for an operator). A range read returns workspace events that overlap, issue deadlines in the range, and official days in the range. The year strip asks only which days have a mark.

## Open

1. Which region, if any, the workspace uses for official days.
2. A version tag stays a label on a scheduled release. Confirm.
3. A reminder as a spool message. Confirm.
4. One audience per event (a person, an agent, or the workspace). Several names would be the next step, not this one.

Consensus reached with a-270 in spec.md de98a421 (v0.3.0), section 10. No point left open.
