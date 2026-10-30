# 170 Day's tasks: a To-do view in the Calendar, and a signal for what is due today

Version: v0.2 (2026-10-30). Status: **WHAT v0.2 draft, under panel review**
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
  due today be signalled the same way?

### 1.2 Decided

- HUM-10, msg `24864613-1751-4956-bacd-a15a5eb117c1`: this overlaps a little
  with Notes (spec 155), so WHAT must say how they relate.
- Poll `30b44091`, answer **B** (HUM-10, msg
  `5046197f-c140-47cf-819b-a173e753606b`): ONLY tasks (issues by deadline) are
  in the Calendar To-do view; notes stay where they are and are not in it.
  Closed: this spec only names 155 as a neighbour.

## 2. Words

- **Task**: an issue (spec 039) that is open, is not an epic or a feature,
  and has a deadline. Open = status `eval`, `todo`, `wip`, `blocked`,
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
- **Overdue**: an open task whose deadline is before the start of today.
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
To-do view does not change them.

4.2 **The same four ranges.** The To-do view has the ranges the Calendar
already has: Day, 3 days, Week, Month
(`git grep -n "'3day': 'calendar.view_3day'" origin/master -- csi-spl-wui/src/components/CalendarViewTabs.vue`
-> line 74, beside `day`, `week`, `month`), with the same Today, previous and
next steps and the same period title.

4.3 **A list, grouped by day.** Each range shows its days in order; under
each day, the tasks due that day as a short list. Each row shows at least:
the issue key, the title, the status, the priority and the deadline's time.
An empty day says so in one line (Day range) or is left out (longer ranges).

4.4 **Overdue on top of today.** When the range holds today, overdue tasks
are listed above today's, marked overdue, until they are closed or moved
(default; Q3).

4.5 **A row opens the issue.** Clicking or tapping a row opens that issue in
Issues, the way the deadline pop-over's "Open issue" already does
(`git grep -n "calendar-popover-open-issue" origin/master -- csi-spl-wui/src/components/CalendarEventPopover.vue`
-> line 41). Closing or re-dating the issue there updates the view when the
person comes back. Back returns to the To-do view on the same range and day.

4.6 **Read-only here.** The To-do view does not edit tasks; status, deadline
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
bookmarked. The reminder's link carries no fixed day: an old reminder or a
bookmark opens today's list.

## 5. The day signal: what tells the person, and when

Two candidates are on the table; the owner chooses (Q1):

5.1 **Morning reminder with a link** (HUM-24 `1715819f`, HUM-10
`61878905`). Once a day, in the morning, the person is told how many tasks
are due today, with a link to the To-do view's Day range (4.8). The reminder
reads like "3 due today · 1 overdue" and shows at most 3 titles, then
"+N more"; the list itself lives in the view. It comes once per person per
day, not once per tab or device: seen on the phone, it does not appear again
on the desktop that day, and it does not appear after the person has already
opened the To-do view that day. No reminder on a day with nothing due (default; Q4 covers the time and
the channel).

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

5.4 **Turning it off.** Each person can switch the morning reminder off, and
the due-today badge mark if chosen, in Settings, Notifications, where the
bell switch and the muted channels already live
(`git grep -n "settings-notifications" origin/master -- csi-spl-wui/src/components/settings/notifications.vue`
-> line 13). The switch belongs to the person, not the device (stored with
their preferences like the time zone, `setTimeZone`,
`csi-spl-wui/src/stores/session.ts` line 196), so muting it on the phone
mutes it on the desktop. Today's muted channels are per device
(`git grep -n "MUTED_CHANNELS_KEY = " origin/master -- csi-spl-wui/src/utils/notify.mjs`
-> line 73, `'spool.muted-channels'`, browser storage); this switch must not
copy that. No snooze in v1.

Whatever is chosen, the signal counts exactly what the To-do view's Day range
on today shows (same task set, same "mine or all" rule, overdue included or
not by the same Q3 answer), so the number and the list never disagree.

## 6. How it relates to Notes (spec 155)

Notes are not tasks and do not appear in the To-do view or in the day signal
(owner poll `30b44091`, answer B). A note with a date stays a note in the
Notes section. This spec edits no file of the Notes lanes; HOW names any
shared component before it touches one.

## 7. Out of scope for v1

- Notes in the view (decided, 1.2).
- Calendar events in the To-do view (they have their own views).
- Editing tasks from the view (4.6): no status change, re-date or reassign.
- Tasks with no deadline: they belong to Issues, not to a day.
- Agents as readers of the view or the signal.
- An email reminder on by default (Q4 option c is opt-in).
- A reminder sent as a chat message.
- A new task store: tasks are issues; nothing new is created to hold them.

## 8. Owner questions

Each goes to the dispatch lease holder as one poll form on task
`dispatch-dfe850d9`; the panel never asks the owner directly. The default is
what WHAT assumes until the owner answers.

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
  (c) plus an email at that hour, opt-in per person. Default: (a) + (b), the
  hour 08:00 local; (c) off until the person turns it on.

## 9. Signatures

Each seat signs a version with its own commit on branch
`review/c001-spec-day-tasks`: one line, seat id, version, the sha it read.

| seat | id | version | sha read |
|---|---|---|---|
| editor | c-864 | WHAT v0.1 | (65e436eb1) |
| editor | c-864 | WHAT v0.2 | (this commit) |
| user view | c-866 | WHAT v0.2 | f71652e2c |

## 10. Changes

- v0.2: folded USER VIEW c-866 (msg 5fe949e9) F1-F8: the one time zone
  (F1), the deadline-input zone edge (F2), email as the closed-browser
  channel in Q4 (F3), the reminder's shape and once per person per day (F4),
  the per-person off switch, 5.4 (F5), why the badge mark is separate (F6),
  overdue named apart in the signal (F7), the address and Back (F8).
