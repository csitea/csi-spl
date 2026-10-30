# 170 Day's tasks: a To-do view in the Calendar, and a signal for what is due today

Version: v1.1 (2026-10-30). Status: **WHAT v1.0 and HOW v1.0, each signed by all four seats**
(plan only; nothing below is built). Issue SPL-4396 · Epic SPL-2396 · Class
feature · Kind specs_and_docs · Task `dispatch-dfe850d9` · Placement slug
`c001-dfe850d9-panel-editor` · Editor c-864.

Number: 169 is `169-channel-workspace-move` on origin/master `568035cf1`
(`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`), and
`git ls-remote --heads origin | grep -E '170|day-task'` shows no branch
holding 170, so this is 170.

Phase 1 is WHAT (this version): the problem, who it is for, what they see and
when, what is out of scope, and the owner's open questions. Phase 2, HOW,
starts only after WHAT v1.0 is signed by every seat (section 9).

Paths used below: `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`,
`wui/` = `csi-spl-wui/src/`. Every claim about the code was read on
origin/master `568035cf1` and carries its command.

Neighbours, not the same:

- [089 Calendar section](../089-calendar-section/spec.md), [097 full
  editing](../097-calendar-full-editing/spec.md), [106 phone
  rewrite](../106-calendar-phone-rewrite/spec.md): the Calendar this view
  lives in, and its Day / 3 days / Week / Month ranges.
- [039 issues](../039-spool-issues/spec.md): the tasks themselves
  (`issues.deadline`).
- [155 Notes section](../155-notes-section/spec.md): notes stay there and are
  NOT part of this view (owner decision, section 1.2).

## 1. The owner's words

Source: prd csitea topic `dfe850d9-e283-4460-a0ed-223b71d657fa`.

### 1.1 The ask

- HUM-24, msg `1715819f`: a morning notification listing the day's tasks
  that expire that day, as a short list.
- HUM-10, msg `61878905`: maybe a calendar section for the day's tasks; the
  reminder is only a link to it.
- HUM-10, msg `9e158831` (Bulgarian, poll chat): he does not know exactly
  HOW; first a discussion to agree WHAT, then HOW. Relayed from the terminal
  (c-002, `1b939c7d`): he wants a panel of experts.
- HUM-10, msg `a57354ec-f225-4b69-a2a2-bdea08394d05`, verbatim: "todo list in
  the calendar as separate view , on daily , 3day , weeekly , monthly basis
  ?!". This is the leading direction for WHAT.
- HUM-24, msg `e0fb60bb-8b9c-4049-9fe8-ab154240d116` (Bulgarian, to HUM-10):
  today the tasks icon shows a red circle with the unread count; could tasks
  due today be signalled the same way? Posted 2026-10-30 15:00:52Z; it is
  Q1 option B. The dispatch holder c-003 answered it pointing to Q1 (msg
  `221bb299-a0cc-4398-8c88-89b977d0d48f`).

### 1.2 Decided

- HUM-10, msg `24864613-1751-4956-bacd-a15a5eb117c1`: this overlaps a little
  with Notes (spec 155), so WHAT must say how they relate.
- Poll `30b44091`, answer **B** (HUM-10, msg
  `5046197f-c140-47cf-819b-a173e753606b`): ONLY tasks (issues by deadline) are
  in the Calendar To-do view; notes stay where they are and are not in it.
  Closed: this spec only names 155 as a neighbour.

### 1.3 Panel defaults

Not from an owner message; the panel's reading, kept unless the owner
overrules: a task excludes epics and features (2, 4.1); the row fields and
empty days (4.3); read-only (4.6); at most 3 titles in the reminder, once
per person per day, none on an empty day (5.1); the per-person off switch,
no snooze (5.4); the signal counts what the Day range shows (5); section 7
except its first line. Each spot is tagged "(panel default, 1.3)".

## 2. Words

- **Task**: an issue (spec 039) that is open, is not an epic or a feature
  (panel default, 1.3), and has a deadline. Open = status `eval`, `todo`, `wip`, `blocked`,
  `onhold` or `qas`, the set the Issues rail count already uses
  (`git grep -n "OPEN_ISSUE_STATUSES = " origin/master -- csi-spl-wui/src/utils/my-issues-count.mjs`
  -> `['eval', 'todo', 'wip', 'blocked', 'onhold', 'qas']`).
- **Due on a day**: the task's deadline falls inside that calendar day in the
  viewer's time zone: the zone picked in Settings, Time zone, else the
  browser's, the zone every date in the app is printed in
  (`git grep -n "export function viewerTimeZone" origin/master -- csi-spl-wui/src/utils/date-iso.mjs`
  -> line 77). The deadline is a point in time, not a date
  (`git grep -n "deadline " origin/master -- csi-spl-rdb/src/sql/postgres/spool-hub/0047_issues.sql`
  -> `deadline timestamptz NULL`). The reminder, the badge and the view all
  use this one zone, so the phone and the desktop agree on what "today" is.
- **Overdue**: an open task whose deadline is before the start of today. A
  task due today at 09:00 is still "due today" at 10:00, listed under today
  with its time shown, never "overdue". Issues already has a different
  meaning under the same word (neighbour, not this spec's):
  `git grep -n "export function isOverdue" origin/master -- csi-spl-wui/src/utils/issues-view.mjs`
  -> line 292, `d < now`, so it turns overdue the minute the time passes.
- **My tasks**: tasks assigned to the viewer. Whether the view shows only
  mine or the whole workspace's is owner question Q2.
- **To-do view**: the new Calendar view of section 4.
- **Day signal**: what tells a person, without opening anything, that tasks
  are due today (section 5; which one is Q1).
- **Known edge, not fixed here**: the deadline input converts with the
  browser's offset, not the picked zone (`localInputToDeadline(local)` with
  no offset, `git grep -n "localInputToDeadline(local)" origin/master -- csi-spl-wui/src/composables/`
  -> `useIssueDetailForm.ts` line 150, `useIssueCells.ts` line 106). For a
  person whose picked zone differs from the browser's, a deadline set near
  midnight can land on the neighbouring day in the To-do view. HOW names it;
  the fix is its own issue.
- **Known edge, not fixed here**: that `isOverdue` (line 292) treats
  only `done` and `canceled` as closed
  (`git show origin/master:csi-spl-wui/src/utils/issues-view.mjs | sed -n 292,295p`):
  `canceled` is a status the store no longer has, and `diss` (closed in the
  store) reads as open, so a dismissed issue with a past deadline counts as
  overdue there (store closed =
  `done || diss`,
  `git grep -n "func IssueClosed" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/store/issues.go`
  -> line 191), and has no caller outside its file
  (`git grep -n "isOverdue" origin/master -- csi-spl-wui/src | grep -v issues-view.mjs | grep -v mjs-shims.d.ts`
  -> no output; without the last filter it prints only the type declaration,
  `types/mjs-shims.d.ts` line 1838). HOW does not reuse it as it is.

## 3. The problem, and who has it

A person with tasks that expire today has no place that answers "what must I
finish today?" in one look:

- The Calendar already draws open issue deadlines, but only as read-only
  items mixed into the event grid, for the whole workspace, with no list of
  them (`git grep -n "calendarSourceIssue  = " origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/calendar.go`
  -> `"issue"`; `deadlinesIn` drops closed issues and those with no deadline,
  `git grep -n "func (s \*Server) deadlinesIn" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/calendar.go`
  -> line 617; tests `TestCalendarMergesIssueDeadlines`,
  `TestCalendarHidesClosedDeadlines` in `api/hub/calendar_test.go`).
- The Issues page can filter "due on or before a day"
  (`git grep -n "one day: issues due on or before" origin/master -- csi-spl-wui/src/composables/useIssueFilters.ts`
  -> line 256), but that is a filter the person must set each time, and it
  mixes in overdue and other days.
- The Issues rail badge counts the viewer's open issues not yet opened
  (`newIssueCount`, `wui/utils/my-issues-count.mjs`, SPL-1559), not what is
  due.
- Nothing tells the person in the morning. The calendar's reminders are
  in-app pop-ups driven by the open tab's own timer
  (`git grep -n "plain in-app pop-ups" origin/master -- csi-spl-wui/src/plugins/calendar-reminders.client.ts`
  -> line 1), and they are set per event, not per issue.

Users: every human member of a workspace who is assigned tasks with
deadlines (HUM-24 asked first; HUM-10 owns the direction). Agents are out of
scope as readers (section 7): they read issues through the spool and CLI.

## 4. What the person sees: the To-do view in the Calendar

4.1 **A separate view.** The Calendar gets a To-do view next to its event
views. It shows tasks only, never events, official days or notes (owner
decision 1.2). The event views keep drawing deadlines as they do today; the
To-do view does not change them. The two differ on purpose: the event views
draw every open issue deadline, epics and features included (`deadlinesIn`
filters only closed, no deadline and the range,
`git show origin/master:csi-spl-api/src/go/spool-hub-api/internal/hub/calendar.go | sed -n 625,628p`;
`git grep -n "IssueKindEpic" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/calendar.go`
-> no output), while the To-do view lists tasks only (section 2): an epic due
today shows in the Week grid but not in the To-do list, because an epic is
not finished by hand (panel default, 1.3).

4.2 **The same four ranges.** The To-do view has the ranges the Calendar
already has: Day, 3 days, Week, Month
(`git grep -n "'3day': 'calendar.view_3day'" origin/master -- csi-spl-wui/src/components/CalendarViewTabs.vue`
-> line 74, beside `day`, `week`, `month`), with the same Today, previous and
next steps and the same period title.

4.3 **A list, grouped by day.** Each range shows its days in order; under
each day, the tasks due that day as a short list. Each row shows at least:
the issue key, the title, the status, the priority and the deadline's time.
An empty day says so in one line (Day range) or is left out (longer ranges)
(panel default, 1.3).

4.4 **Overdue on top of today.** When the range holds today, overdue tasks
are listed above today's, marked overdue, until they are closed or moved
(default; Q3).

4.5 **A row opens the issue.** Clicking or tapping a row opens that issue in
Issues, the way the deadline pop-over's "Open issue" already does
(`git grep -n "calendar-popover-open-issue" origin/master -- csi-spl-wui/src/components/CalendarEventPopover.vue`
-> line 41). Closing or re-dating the issue there updates the view when the
person comes back. Back returns to the To-do view on the same range and day.

4.6 **Read-only here** (panel default, 1.3). The To-do view does not edit tasks; status, deadline
and assignee are changed in Issues. (A tick-to-close in the view is a
possible later step, not in v1; see section 7.)

4.7 **Phone and desktop.** The view works in the desktop Calendar and in the
phone Calendar of spec 106, with the same ranges.

4.8 **A link to it.** The Day range of the To-do view, on today, has its own
address, so a reminder or another page can link straight to it (HUM-10
`61878905`: the reminder is only a link). The Calendar already keeps its view
and day in the address (`?v=` and `?d=`,
`git grep -nE "route.query.(v|d)" origin/master -- csi-spl-wui/src/pages/calendar.vue`
-> lines 64 and 73); the To-do view follows that shape, so it can be
bookmarked. The link names the To-do view and its range. A link the app does
not understand opens the Calendar's default view, never an error. The
reminder's link carries no fixed day: an old reminder or a bookmark opens
today's list. (For HOW: an unknown `?v=` opens Week today,
`git grep -n "CAL_DESK_VIEWS.includes(s) ? s : 'week'" origin/master -- csi-spl-wui/src/utils/calendar-desktop-view.mjs`
-> line 29, so the To-do view must not be a fifth `?v=` value.)

## 5. The day signal: what tells the person, and when

Two candidates are on the table; the owner chooses (Q1):

5.1 **Morning reminder with a link** (HUM-24 `1715819f`, HUM-10
`61878905`). Once a day, in the morning, the person is told how many tasks
are due today, with a link to the To-do view's Day range (4.8). The reminder
reads like "3 due today · 1 overdue" and shows at most 3 titles, then
"+N more"; the list itself lives in the view. It comes once per person per
day, not once per tab or device: seen on the phone, it does not appear again
on the desktop that day, and it does not appear after the person has already
opened the To-do view that day. No reminder on a day with nothing due. (The
3 titles, once per day and none on an empty day: panel default, 1.3; Q4
covers the time and the channel.)

5.2 **A red badge on the Issues icon** (HUM-24 `e0fb60bb`). The Issues rail
icon, which today shows a red count of new issues (section 3), also signals
the tasks due today. The open choice inside this candidate: a second,
separate mark for "due today", or the due-today count replacing the current
count. Two different red numbers on one icon would be read wrong, so WHAT
asks the owner (Q1b). The current count is itself an owner fix: it counted
every open issue until HUM-10 said "I cannot distinguish which issues are the
new ones" (SPL-1559,
`git grep -n "I cannot distinguish" origin/master -- csi-spl-wui/src/utils/my-issues-count.mjs`
-> line 22). Replacing it with a due-today count would undo that fix, so a
separate mark must look different from the red unread count (not a second
red number).

5.3 **Both**: the badge is always there; the morning reminder links to the
view.

5.4 **Turning it off** (panel default, 1.3). Each person can switch the morning reminder off, and
the due-today badge mark if chosen, in Settings, Notifications, where the
bell switch and the muted channels already live
(`git grep -n "settings-notifications" origin/master -- csi-spl-wui/src/components/settings/notifications.vue`
-> line 13). The switch belongs to the person, not the device: turned off on
the phone, it is off on the desktop too. No snooze in v1. (For HOW: today's
muted channels are per device,
`git grep -n "MUTED_CHANNELS_KEY = " origin/master -- csi-spl-wui/src/utils/notify.mjs`
-> line 73, browser storage; the time zone is per person, `setTimeZone`,
`csi-spl-wui/src/stores/session.ts` line 196.)

Whatever is chosen, the signal counts exactly what the To-do view's Day range
on today shows (same task set, same "mine or all" rule, overdue included or
not by the same Q3 answer), so the number and the list never disagree
(panel default, 1.3).

## 6. How it relates to Notes (spec 155)

Notes are not tasks and do not appear in the To-do view or in the day signal
(owner poll `30b44091`, answer B). A note with a date stays a note in the
Notes section. This spec edits no file of the Notes lanes; HOW names any
shared component before it touches one.

## 7. Out of scope for v1

All but the first line are panel defaults (1.3).

- Notes in the view (decided, 1.2).
- Calendar events in the To-do view (they have their own views).
- Editing tasks from the view (4.6): no status change, re-date or reassign.
- Tasks with no deadline: they belong to Issues, not to a day.
- Agents as readers of the view or the signal.
- An email reminder on by default (Q4 option c is opt-in).
- A reminder sent as a chat message.
- Tasks due today in a connected Google calendar: the sync (spec 149)
  carries events only
  (`git grep -ciE "deadline|issue" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_sync.go`
  -> no output).
- A new task store: tasks are issues; nothing new is created to hold them.

## 8. Owner questions

Each goes to the dispatch lease holder as one poll form on task
`dispatch-dfe850d9`; the panel never asks the owner directly. The default is
what WHAT assumes until the owner answers.

Posted by c-003 in dfe850d9 at 15:26Z: Q1 msg `9958a8b7`, Q2 msg
`14caab4c`, Q3 msg `e3b1370c`. Q1b and Q4 follow the Q1 answer.

- **Q1 the day signal.** Morning reminder with a link (5.1), red badge on
  the Issues icon (5.2), or both (5.3)? Default: both.
- **Q1b the badge, if chosen.** A separate "due today" mark beside the
  current new-issues count, or the due-today count in place of it? Default:
  a separate mark.
- **Q2 whose tasks.** Only tasks assigned to me, or every task of the
  workspace? The Calendar's event views show the whole workspace's deadlines
  today; the Issues count counts mine. Default: mine, with a switch to the
  whole workspace.
- **Q3 overdue.** Show overdue tasks above today's (and count them in the
  signal), or only tasks due today? Default: list overdue tasks above
  today's in the view, marked overdue; the signal names them apart ("2 due
  today · 5 overdue"), so an old overdue pile never hides what is due today.
- **Q4 the morning reminder's time and channel** (only if 5.1 is chosen).
  When (a fixed hour, or the person's first visit of the day) and how (an
  in-app pop-up when the person opens the app, a browser alert while a tab is
  open, or a notice that reaches a closed browser)? No web push exists
  (`git grep -cE "vapid|PushSubscription" origin/master -- csi-spl-api csi-spl-wui/src`
  -> no output), and browser alerts come only from an open tab
  (`wui/utils/notify.mjs`, "Raise one browser alert"). The one channel that
  reaches a person whose browser is closed is email: the hub already sends
  transactional mail
  (`git grep -n "Package mail sends" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go`
  -> line 1, spec 015). Options: (a) an in-app notice on the first visit of
  the day, (b) plus a browser alert at a fixed local hour if a tab is open,
  (c) plus an email at that hour, opt-in per person; the email needs the
  person's time zone set in Settings, because the hub does not know the zone
  of a person who never picked one (it keeps only the picked override,
  `git grep -n "the hub never converts a time" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/auth/time_zone.go`
  -> line 15; HOW may record the browser's zone instead). Default: (a) + (b),
  the hour 08:00 local; (c) off until the person turns it on.

## 9. Signatures

Each seat signs a version with its own commit on branch
`review/c001-spec-day-tasks`: one line, seat id, version, the sha it read.

| seat | id | version | sha read |
|---|---|---|---|
| editor | c-864 | WHAT v0.1 | (65e436eb1) |
| editor | c-864 | WHAT v0.2 | f71652e2c |
| editor | c-864 | WHAT v0.3 | df5412503 |
| editor | c-864 | WHAT v0.4 | 9ae74d524 |
| editor | c-864 | WHAT v1.0 = v0.4 text, declared | 1c1008b30 |
| user view | c-866 | WHAT v0.2 | f71652e2c |
| user view | c-866 | WHAT v0.3 | ef9bebc03 |
| user view | c-866 | WHAT v0.4 | 9ae74d524 |
| calendar / issues expert | c-869 | WHAT v0.4 | 9ae74d524 |
| reviewer | c-880 | WHAT v0.4 | 9ae74d524 |
| editor | c-864 | HOW v0.1 | d9e8b1a1d |
| editor | c-864 | HOW v0.2 | ae6765d95 |
| editor | c-864 | HOW v0.3 | 262d3309a |
| editor | c-864 | HOW v1.0 = v0.3 text, declared | eea24076d |
| user view | c-866 | HOW v0.3 | 262d3309a |
| calendar / issues expert | c-869 | HOW v0.3 | 262d3309a |
| reviewer | c-880 | HOW v0.3 | 262d3309a |

## 10. Changes

- v1.1 = HOW v1.0: declared by the editor. Text = HOW v0.3 (`262d3309a`),
  signed by c-866 (`8be6a4e8e`), c-869 (`f93d980c9`) and reviewer c-880
  (`eea24076d`, its PASS on HOW). Owner questions Q1-Q3 still open; their
  answers, and Q1b / Q4, fold into a later version and may drop rows B4-B6.

- HOW v0.3: folded CALENDAR / ISSUES EXPERT c-869 (msg cef17ced) H1 = and
  REVIEWER c-880 (msg d5b9d892) H2 (the lazy import is in
  `useSidebarCounts.ts`, 11.1, 11.3), c-869 H2 (the pop-up has no kinds; B5
  adds one and keeps 089 T006 green, 11.4), the `[after, before)` window
  cite (11.2), and c-880 H1 (phone: four ranges for the To-do kind, `?k=todo&v=`
  sets the visit's range; WHAT 4.7 kept, not amended), H3 (`declare module`,
  B1), H4 (seen-today per human, the risk in 11.7), H5 (section 11 moved
  after section 10).
- HOW v0.2: folded USER VIEW c-866 (msg b91b89c8) U1 (day change and
  focus re-check, 11.4), U2 (the 08:00 alert respects the bell and
  permission, 11.4), U3 (one switch for card + alert, 11.4), U4 (the mark's
  accessible name, 11.3), U5 (assignee on rows under "all", 11.2).
- HOW v0.1: section 11 drafted from WHAT v1.0 and c-869's C1-C8 / D.

- v1.0: WHAT v1.0 declared by the editor. Text = v0.4 (`9ae74d524`), which
  all four seats signed (c-866 `0da4216ce`, c-869 `270f79f8a`, c-880
  `1c1008b30`); only this status line, the editor rows and this entry change.
  The owner questions Q1-Q3 are posted and open; their answers, and Q1b / Q4
  after Q1, fold into a v1.x. Next: HOW, phase 2.

- v0.4: folded REVIEWER c-880 (msg a50ab05b): R1 was already in df5412503
  (the `isOverdue` caller grep); R2 the edge is `done`/`canceled` only, so
  `diss` reads overdue there (section 2); R3 new 1.3 Panel defaults, each
  spot tagged; R4 the storage and `?v=` detail of 5.4 and 4.8 moved into
  "For HOW" notes; R5 the HUM-24 15:00Z post is `e0fb60bb` itself (one
  bullet, c-003's answer `221bb299`, per c-003 msg e910987e), the wrong id
  `e5e6fafc` (a spool note, not a post) removed.

- v0.3: folded CALENDAR / ISSUES EXPERT c-869 (msg bf9fb184) B1 (epics and
  features in the event grid, not in the To-do list, 4.1), B2 (one meaning of
  overdue, the Issues `isOverdue` as a neighbour and a known edge, section
  2), B3 (the link's second axis, 4.8), C4 (Q4 c needs the picked zone) and
  C7 (Google sync out of scope, section 7). C1-C3, C5, C6, C8 and D are
  input for HOW, kept in the seat's message. Then c-869 msg f0b72e4b: the
  `isOverdue` caller grep also drops the type declaration.

- v0.2: folded USER VIEW c-866 (msg 5fe949e9) F1-F8: the one time zone
  (F1), the deadline-input zone edge (F2), email as the closed-browser
  channel in Q4 (F3), the reminder's shape and once per person per day (F4),
  the per-person off switch, 5.4 (F5), why the badge mark is separate (F6),
  overdue named apart in the signal (F7), the address and Back (F8).

## 11. HOW (phase 2)

HOW v1.0 (2026-10-30; text = v0.3 `262d3309a`, signed by every seat). Built on WHAT v1.0 and its defaults; the rows that
depend on an open owner answer say so (Q1, Q1b, Q2, Q4). Every file named
was read on origin/master `568035cf1`. Input: the calendar expert's C1-C8
and D (c-869 msg bf9fb184), each re-checked below.

### 11.1 Principles

- **No new task store and no new endpoint for the list.** Tasks are issues;
  the view and the counts read `GET /v1/issues`, which already filters by
  `assignee=me`, `status` (comma list), `deadline_before` and
  `deadline_after` (RFC 3339)
  (`git grep -nE 'case "me":|deadline_before' origin/master -- csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go`
  -> lines 559, 582, 597).
- **"Today" is computed in the browser**, in `viewerTimeZone()` (WHAT 2):
  the client turns the day's local bounds into RFC 3339 instants and asks
  the hub for that window. The hub never converts a time with the zone
  (`auth/time_zone.go` line 15), so nothing changes there for the view.
- **One pure module holds the task rules**, so the view, the badge and the
  reminder cannot disagree (WHAT 5, last paragraph): new
  `csi-spl-wui/src/utils/day-tasks.mjs` (Node-testable like
  `my-issues-count.mjs`): `isTask(issue)` (open status from
  `OPEN_ISSUE_STATUSES`, not epic / feature, has a deadline),
  `dayBounds(date, zone)`, `groupByDay(issues, range, zone)`,
  `overdue(issues, now, zone)` and `dueTodayCounts(issues, now, zone)` ->
  `{ today, overdue }`. It does not reuse `isOverdue` of `issues-view.mjs`
  (WHAT 2, known edge).
- **Lazy, never in the initial JS**: the view and the reminder are their own
  chunks, like the calendar reminder timer
  (`plugins/calendar-reminders.client.ts`, dynamic import) and the rail count
  (`git grep -n "my-issues-count" origin/master -- csi-spl-wui/src/composables/useSidebarCounts.ts`
  -> line 38 imports `utils/my-issues-count.mjs` dynamically).

### 11.2 The To-do view (WHAT 4)

- **Address.** A new query key names the view kind, `?k=todo`, beside the
  existing `?v=` (range) and `?d=` (day) of `pages/calendar.vue` (lines 64,
  73). `?v=` keeps its four values (`CAL_DESK_VIEWS`,
  `utils/calendar-desktop-view.mjs` line 14); an unknown `k` is the event
  views (WHAT 4.8). The reminder links to `/calendar?k=todo&v=day` with no
  `d`, so it always opens today. A new `calTodoKind(query)` sits next to
  `calDeskView` in the same file, with its unit test.
- **Tabs.** `CalendarViewTabs.vue` gets a To-do switch above the four
  ranges; the ranges, Today, previous / next and the title stay as they are
  and drive both kinds.
- **Component.** New `components/CalendarTodoView.vue`, loaded with
  `defineAsyncComponent` the way `pages/calendar.vue` line 50 loads
  `CalendarMainView`. It reads, per range: the tasks in
  `[start of first day, end of last day)` and, when the range holds today,
  the overdue ones (`deadline_before=<start of today>`), both with
  `status=eval,todo,wip,blocked,onhold,qas` and the Q2 assignee rule, then
  `day-tasks.mjs` drops epics / features and groups. Month range: one read,
  no `limit` (the hub answers the whole set without one,
  `issues_page.go` line 16). The hub's window is exactly `[after, before)`
  (`git show origin/master:csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go | sed -n 647,651p`:
  `deadline_before` strict, `deadline_after` inclusive), so a day's
  `[start, next start)` never counts a task twice. Range moves keep other
  query keys (`{ ...route.query, v, d }`, `pages/calendar.vue` lines 78,
  84), so `?k=todo` survives Today / previous / next.
- **Rows.** Key, title, status, priority, the deadline's time; a row is a
  router link to the issue, built as `CalendarEventPopover.vue` builds
  `issueLink` (line 74), so Back returns to the same `k`, `v`, `d`. With
  the switch on "all" (Q2), each row also shows the assignee.
- **Live.** It re-reads on the issue frame and on reconnect, as
  `startMyIssuesCount` does (`live?.onIssue`, `my-issues-count.mjs` line 64).
- **Phone.** `CalendarPhone.vue` gets the same To-do switch and renders
  `CalendarTodoView.vue` in a phone layout (spec 106 shell); one data path
  for both (C8). The phone has three ranges today
  (`git grep -n "CAL_PHONE_VIEWS =" origin/master -- csi-spl-wui/src/utils/calendar-phone-nav.mjs`
  -> line 17, `['month', 'week', 'day']`) and keeps its range in browser
  storage, not in `?v=` (`CalendarPhone.vue` lines 255-264, `VIEW_KEY`,
  `storedView()`; only `?issue=` forces Day). So: the To-do kind on the
  phone offers all four ranges, Day, 3 days, Week, Month (3 days added for
  the To-do kind only; the event views keep their three), which keeps WHAT
  4.2 / 4.7 and the owner's "daily , 3day , weeekly , monthly" as written;
  and `?k=todo&v=<range>` sets the phone's range for that visit, the way
  `?issue=` forces Day, without overwriting the stored event-view range.
- **Q2 = "mine with a switch"** (default): the switch is a chip in the view
  header, per session, not a saved preference in v1.

### 11.3 The due-today mark on the Issues icon (WHAT 5.2; only if Q1 = B or C)

- `startMyIssuesCount` already reads the viewer's issues and re-reads them
  live (`my-issues-count.mjs` lines 51, 56, 64); its rows carry `deadline`.
  The mark is `dueTodayCounts(rows, now, zone)` over the same read: no extra
  request (C2). Q2 = all would need a second read; the mark stays "mine"
  whatever the view's switch shows, unless the owner says otherwise.
- The due-today count is started where the current count is,
  `composables/useSidebarCounts.ts` (line 38); `ChannelSidebar.vue` renders
  the mark beside the current count (lines 53 and 138); its shape follows Q1b (default: a separate mark that is not a
  second red number, e.g. an outlined count with a clock glyph). The current
  new-issues count is untouched (SPL-1559). The mark carries an accessible
  name and a tooltip from an i18n key, e.g. "2 due today", so a screen
  reader and a hover tell it apart from the new-issues count.
- A timer re-computes at local midnight, so the mark moves to the new day
  without a reload.

### 11.4 The morning reminder (WHAT 5.1; only if Q1 = A or C)

- **Delivery (Q4 a + b, the default).** A small client plugin, the same
  shape as `plugins/calendar-reminders.client.ts`: on app ready and signed
  in, it computes `dueTodayCounts`; if `today + overdue > 0`, the reminder is
  on, and it has not been seen today, it shows one card through the existing
  reminder pop-up (`CalendarReminderPopup.vue`, C5). That pop-up has no item
  kinds today: its item is an event
  (`git show origin/master:csi-spl-wui/src/components/CalendarReminderPopup.vue | sed -n '52p;65p;73,74p'`
  -> `type Reminder = { id, title, starts_at, ends_at, all_day, remind_at }`,
  `when()` formats start / end, `open()` pushes `?event=<id>`). B5 adds a
  `kind` field to that type and branches `when()` and `open()` (a
  `day-tasks` item opens `/calendar?k=todo&v=day`); the pop-up is shared
  with the spec 089 T006 event reminders, so B5 keeps their e2e green. The
  card has the "3 due today · 1 overdue" line, at most 3 titles,
  "+N more" and an Open link to `/calendar?k=todo&v=day`. The check also
  runs when the local day changes in an open tab and when the tab comes back
  to the front (focus / visibilitychange), the way the calendar reminder
  timer re-reads
  (`git show origin/master:csi-spl-wui/src/utils/calendar-reminder-timer.ts | grep -n visibilitychange`
  -> line 95), so a tab kept open overnight shows the card on the person's
  first look of the new day. (b) adds a timer for 08:00 local in an open
  tab, raising a browser alert through `showAlert`
  (`git grep -n "export async function showAlert" origin/master -- csi-spl-wui/src/utils/notify.mjs`
  -> line 252) only when this device's bell is on (`alertsEnabled`,
  `stores/notification.ts` line 518) and the browser granted permission;
  the alert is the same reminder, so it counts as seen-today and is gated
  by `day_tasks_reminder` too.
- **Seen today, per person, on the hub (D).** New humans column
  `day_tasks_seen_on date NULL`, the viewer's local date of the last time the
  card was shown or the To-do view's today was opened; written by a new
  `PUT /v1/me/day-tasks-seen {date}` (idempotent, rejects a date more than
  one day from the hub's UTC date). The client compares it with its own
  local date. Not browser storage: phone and desktop must agree (WHAT 5.1).
  Scope: per human, while the picked zone is per workspace membership
  (`git grep -n "PER TENANT" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/auth/time_zone.go`
  -> line 10). The date written is the local date in the zone of the
  workspace the card was shown in; a person in two workspaces with
  different zones may see the card once, not once per workspace, near
  midnight (accepted, 11.7).
- **The off switch (WHAT 5.4).** A new `auth.ViewPrefs` key
  `day_tasks_reminder` with values `{"on", "off"}` (default first, the shape
  of `PrefLinkPreviews`, `auth/handler.go` line 976), shown in
  `components/settings/notifications.vue`; and, if the badge is built,
  `day_tasks_badge` the same way. `day_tasks_reminder = off` stops the card
  and the 08:00 alert; the email has its own opt-in (`day_tasks_email`). Each ViewPrefs key is a humans column read
  in one SELECT (`store/human_settings.go` line 39), so the rdb file lands
  and is applied on dev and prd BEFORE the hub change (11.6, B0).
- **Email (Q4 c, only if the owner picks it).** A hub ticker like the gcal
  sync (`hub/gcal_sync.go` lines 20-26: claim by lease, so two instances do
  not both send), on a hub that keeps CPU and one instance
  (`04-cloud-run-service.tf` line 129, `cpu_idle = false`). Per opted-in
  member with a picked zone (C4), at 08:00 in that zone (`time.LoadLocation`,
  as `hours_me.go` line 129), it counts the tasks with the same rules
  (ported to Go with a shared fixture file both test suites read) and sends
  one mail through `internal/mail`. A new opt-in key, `day_tasks_email`
  `{"off", "on"}`. Its own build row (B6), not in the first cut.

### 11.5 Text and languages

Every new string is a key in `csi-spl-wui/i18n/locales/en.json` and every
other locale (`i18n-parity.test.mjs`); no literal in a template
(`i18n-no-raw-text.test.mjs`). The locale text gets the agy review as its
last step before it ships (fleet language rule).

### 11.6 Build rows

Each row is one lane with its own issue, its tests and its red control;
each lands through `do_spl_push_master` and is done when served on dev and
prd.

| row | what | depends on | tests |
|---|---|---|---|
| B0 | rdb: humans `day_tasks_seen_on date NULL`, `day_tasks_reminder`, `day_tasks_badge` text columns; applied on dev and prd with `do_spl_db_bootstrap` before B4 / B5 land | Q1 | migration lint; `do_spl_db_query` on information_schema, dev and prd |
| B1 | `utils/day-tasks.mjs` + `calTodoKind`, with its `declare module` in `csi-spl-wui/src/types/` (as `blocker-settings.d.ts` line 10 declares `my-issues-count.mjs`) | none | unit tests: zone bounds (picked zone vs browser), epic / feature out, `diss` closed, overdue vs due today at 09:00 / 10:00 |
| B2 | desktop To-do view: tab, `?k=todo`, `CalendarTodoView.vue`, rows, live re-read, i18n | B1 | extend `tests/e2e/calendar-desk-views.test.mjs` (no new e2e file); chunk budget |
| B3 | phone To-do view, four ranges for the To-do kind, `?k=todo&v=` sets the visit's range | B2 | extend an existing `calendar-phone-*` e2e file; the reminder link opens Day on a phone whose stored range is Week |
| B4 | due-today mark on the Issues icon + its off switch | B0, B1, Q1b | unit over `my-issues-count.mjs`; e2e on the rail |
| B5 | morning card (+ 08:00 alert), seen-today endpoint, off switch | B0, B1, B2, Q4 | hub test for the endpoint (Postgres tier); e2e: shown once, not after the view was opened |
| B6 | email at 08:00 local (only if Q4 c) | B5 | hub ticker test with a fake clock and two instances (one mail) |

Order: B1, then B2 and B0 in parallel, then B3, B4, B5; B6 last if chosen.
Out of these rows: the deadline-input zone edge (WHAT 2) and `isOverdue`
(WHAT 2) each get their own issue.

### 11.7 Risks

- **A settings column the hub reads before it exists** nulls every setting
  of `GET /session` (one SELECT over every ViewPrefs column): B0 first, then
  the hub. B4 / B5 check `information_schema` on both envs before they push.
- **Two clocks.** The client decides "today"; the hub only stores the date it
  is handed. A wrong browser clock shows the wrong day for that person only.
- **Two workspaces, two zones** (11.4): one seen-today date per human; near
  midnight the second workspace may skip that day's card. Accepted for v1.
- **Count drift.** The badge's read is "mine"; if Q2 = all for the view, the
  badge and the view's "all" list differ on purpose, and the view says which
  set it shows.
