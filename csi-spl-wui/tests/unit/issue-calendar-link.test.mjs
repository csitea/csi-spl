// SPL-2034 (design B, t1 edc177bc): the links between an issue deadline and
// the calendar - /calendar?d=<viewer day>&issue=<KEY> and /issues?issue=<KEY> -
// and a deadline's Copy link on the calendar.
import { afterEach, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
import { deadlineOverdue, issueCalendarHref, issuePageHref } from '../../src/utils/issue-calendar-link.mjs'
import { calEventLink } from '../../src/utils/calendar-event-link.mjs'

afterEach(() => setTimeZoneSource(() => ''))

describe('issueCalendarHref', () => {
  beforeEach(() => setTimeZoneSource(() => 'UTC'))

  it('is the calendar on the deadline day with the issue key', () => {
    assert.equal(issueCalendarHref('SPL-12', '2026-10-07T17:00:00Z'), '/calendar?d=2026-10-07&issue=SPL-12')
  })

  it('the day is the viewer wall day', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    assert.equal(issueCalendarHref('SPL-12', '2026-10-07T22:30:00Z'), '/calendar?d=2026-10-08&issue=SPL-12')
    setTimeZoneSource(() => 'America/Los_Angeles')
    assert.equal(issueCalendarHref('SPL-12', '2026-10-07T03:00:00Z'), '/calendar?d=2026-10-06&issue=SPL-12')
  })

  it('encodes the key and trims it', () => {
    assert.equal(issueCalendarHref(' A B&C ', '2026-10-07T17:00:00Z'), '/calendar?d=2026-10-07&issue=A%20B%26C')
  })

  it('no key or no readable deadline is no link', () => {
    assert.equal(issueCalendarHref('', '2026-10-07T17:00:00Z'), '')
    assert.equal(issueCalendarHref('SPL-12', ''), '')
    assert.equal(issueCalendarHref('SPL-12', 'soon'), '')
    assert.equal(issueCalendarHref(null, null), '')
  })
})

describe('issuePageHref', () => {
  it('is the issues page with the issue open', () => {
    assert.equal(issuePageHref('SPL-12'), '/issues?issue=SPL-12')
    assert.equal(issuePageHref('a&b'), '/issues?issue=a%26b')
  })

  it('no key is no link', () => {
    assert.equal(issuePageHref(''), '')
    assert.equal(issuePageHref(undefined), '')
  })
})

describe('deadlineOverdue', () => {
  const now = Date.parse('2026-10-15T12:00:00Z')
  it('a past deadline is overdue, a coming one is not', () => {
    assert.equal(deadlineOverdue('2026-10-15T11:59:00Z', now), true)
    assert.equal(deadlineOverdue('2026-10-15T12:01:00Z', now), false)
  })
  it('no deadline is never overdue', () => {
    assert.equal(deadlineOverdue('', now), false)
    assert.equal(deadlineOverdue('nope', now), false)
  })
})

describe('calEventLink on an issue deadline', () => {
  beforeEach(() => setTimeZoneSource(() => 'UTC'))

  it('copies the issue link, not event=', () => {
    const ev = { id: 'SPL-12', source: 'issue', all_day: false, starts_at: '2026-10-07T17:00:00Z' }
    assert.equal(calEventLink(ev, 'https://t1.example.com'), 'https://t1.example.com/calendar?d=2026-10-07&issue=SPL-12')
  })

  it('CONTROL a stored event keeps event=', () => {
    const ev = { id: 'ev-1', source: 'event', all_day: false, starts_at: '2026-10-07T17:00:00Z' }
    assert.equal(calEventLink(ev, 'https://t1.example.com'), 'https://t1.example.com/calendar?d=2026-10-07&event=ev-1')
  })
})

describe('deadlineLinkMiss (a link the shown range lacks)', async () => {
  const { deadlineLinkMiss } = await import('../../src/utils/issue-calendar-miss.mjs')
  const api = (issue) => ({ getIssue: async () => { if (!issue) throw Object.assign(new Error('nf'), { status: 404 }); return { issue } } })
  beforeEach(() => setTimeZoneSource(() => 'UTC'))

  it('an unreadable issue is not available, Open issue disabled', async () => {
    assert.deepEqual(await deadlineLinkMiss(api(null), 'SPL-9', '2026-10-05', '2026-10-12'),
      { notice: 'calendar_event.not_available', denied: true, moveTo: '' })
  })
  it('a closed issue says so (SPL-37 keeps it off the calendar)', async () => {
    for (const status of ['done', 'diss']) {
      assert.deepEqual(await deadlineLinkMiss(api({ status, deadline: '2026-10-07T17:00:00Z' }), 'SPL-9', '2026-10-05', '2026-10-12'),
        { notice: 'calendar_event.issue_closed', denied: false, moveTo: '' })
    }
  })
  it('an issue with no deadline says so', async () => {
    assert.deepEqual(await deadlineLinkMiss(api({ status: 'wip', deadline: '' }), 'SPL-9', '2026-10-05', '2026-10-12'),
      { notice: 'calendar_event.issue_no_deadline', denied: false, moveTo: '' })
  })
  it('a stale d= turns to the deadline day', async () => {
    assert.deepEqual(await deadlineLinkMiss(api({ status: 'wip', deadline: '2026-11-20T17:00:00Z' }), 'SPL-9', '2026-10-05', '2026-10-12'),
      { notice: '', denied: false, moveTo: '2026-11-20' })
  })
})

describe('mockWithIssueDeadlines (the mock hub)', async () => {
  const { mockCalendarEvents, mockWithIssueDeadlines } = await import('../../src/utils/calendar-mock.mjs')
  const start = '2026-10-05T00:00:00Z'
  const end = '2026-10-12T00:00:00Z'
  it('an open issue with a deadline in range is a deadline item with status and assignee', () => {
    const body = mockWithIssueDeadlines(mockCalendarEvents(start, end, '2026-10-05'), [
      { key: 'SPL-1', title: 'Due', status: 'wip', assignee: 'HUM-2', deadline: '2026-10-06T12:00:00Z' },
      { key: 'SPL-2', title: 'Done', status: 'done', deadline: '2026-10-06T12:00:00Z' },
      { key: 'SPL-3', title: 'Later', status: 'todo', deadline: '2026-11-06T12:00:00Z' },
      { key: 'SPL-4', title: 'None', status: 'todo', deadline: '' },
    ])
    const due = body.events.filter((x) => x.source === 'issue').map((x) => `${x.id}:${x.status}:${x.assignee}`)
    assert.deepEqual(due, ['SPL-1:wip:HUM-2', 'SPL-12:todo:HUM-1'])
    const sorted = [...body.events].sort((a, b) => a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id))
    assert.deepEqual(body.events, sorted)
  })
  it('a mock issue replaces the seeded item of its key', () => {
    const body = mockWithIssueDeadlines(mockCalendarEvents(start, end, '2026-10-05'), [
      { key: 'SPL-12', title: 'Real', status: 'wip', deadline: '2026-10-08T09:00:00Z' }])
    assert.deepEqual(body.events.filter((x) => x.id === 'SPL-12').map((x) => x.title), ['Real'])
  })
})
