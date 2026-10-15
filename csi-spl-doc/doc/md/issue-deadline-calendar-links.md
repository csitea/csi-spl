# Issue deadline <-> calendar links (SPL-2034)

Owner HUM-10, t1 `edc177bc`: "any issue which has a set time deadline should
have a linkage to open the same in the calendar view ... it should work both
ways". Design B, chosen 3 of 3 by the panel; built as SPL-2034. The calendar's
contract is [spec 089](../../specs/089-calendar-section/spec.md) (section 6.1.1
lists the deadline item's `status` and `assignee`).

## 1. The two links

| from | link | builder |
|---|---|---|
| an issue with a deadline | `/calendar?d=<viewer day>&issue=<KEY>` | `issueCalendarHref` in `csi-spl-wui/src/utils/issue-calendar-link.mjs` |
| a deadline on the calendar | `/issues?issue=<KEY>` | `issuePageHref`, same file |

The key resolves; `d=` is a hint that may go stale. No other parameter.

## 2. Issue -> calendar

- The issue detail has "Show in calendar" beside its Deadline picker, only
  while a deadline is set: a real link (a new tab works), 48 px, red once the
  deadline has passed. It is labelled rather than a second bare calendar icon
  next to the picker's own, and wraps under the picker in a narrow panel.
- No entry in the issue row or card menu (option C, later if asked).
- The link opens the week (desktop) or Day (phone, the stored view untouched)
  with the deadline scrolled into view and its pop-over open.

## 3. Calendar -> issue

- A deadline is clickable, never dragged or edited. Its read-only pop-over
  (desktop) or peek (phone) shows the key, title, due time in the viewer's
  zone, status and assignee, painted from the hub's item: no issue read.
- "Open issue" navigates to the issue (no side panel). "Copy link" copies
  the calendar link of section 1.
- Opening or closing the pop-over replaces `issue=` in the URL and adds no
  history entry. "Open issue" first drops `issue=`, then pushes the issue, so
  Back returns to the week with the pop-over closed. On a phone, Back closes
  an open peek before it leaves the calendar.

## 4. A link the shown range lacks

The calendar reads the issue once (`deadlineLinkMiss`,
`csi-spl-wui/src/utils/issue-calendar-miss.mjs`):

| the issue | the calendar shows |
|---|---|
| unreadable (no access, unknown key) | `calendar_event.not_available`, "Open issue" disabled with a tooltip |
| closed (done, diss; off the calendar, SPL-37) | `calendar_event.issue_closed` + "Open issue" |
| no deadline | `calendar_event.issue_no_deadline` + "Open issue" |
| an open deadline outside the range | turns to the deadline's day |

## 5. Refresh

- A deadline save on Issues fires `CALENDAR_CHANGED_EVENT`: a calendar in the
  same tab re-reads.
- On window focus the desktop week re-reads its deadlines only; a stored
  event keeps the copy the view read, so a stale drag still meets
  `edit_conflict` (If-Match). The phone re-reads its range.

## 6. Text

Six keys under `calendar_event` (`show_in_calendar`,
`show_in_calendar_overdue`, `open_issue`, `open_issue_denied`,
`issue_closed`, `issue_no_deadline`), English in every locale until agy's
review (the language rule). Status and assignee reuse `issues.field_status`
and `issues.field_assignee`.

## 7. Tests

- Hub: `TestCalendarDeadlineCarriesStatusAndAssignee`
  (`csi-spl-api/.../internal/hub/calendar_deadline_fields_test.go`).
- WUI unit: `tests/unit/issue-calendar-link.test.mjs`.
- WUI e2e: `tests/e2e/calendar-events.test.mjs`, the `SPL-2034` checks.
