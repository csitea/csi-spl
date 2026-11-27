// SPL-6675 (HUM-5, topic ea3ea4a3; HUM-10, t1 bcfd15e1; spec 197 v1.2): a
// type:calendar search lists only real entries, nearest upcoming first, read
// over every page of the hub's calendars section; the search panel's width.
// CONTROL: a real entry that only starts like a marker stays, and an answer
// with no calendars section comes back unchanged.
//
// Run: node tests/unit/search-calendar.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { importTs } from './lib/load-ts.mjs'

const { isWeekMarker, orderCalendarRows, completeCalendarSection, CALENDAR_MAX_PAGES } = await importTs('src/utils/search-calendar.ts')
const { searchPanelBounds, searchPanelDefault, clampSearchPanel, SEARCH_W_KEY } = await importTs('src/utils/search-panel.ts')

const NOW = Date.parse('2026-11-27T12:00:00Z')
const row = (key, title, starts, ends = starts) => ({ key, type: 'calendars', title: { text: title, highlights: [] }, starts_at: starts, ends_at: ends })

describe('week-number markers', () => {
  it('a title that is only the week is a marker', () => {
    for (const t of ['Week 48', 'week 7', 'Week 48 of 2026', 'W48', 'Wk 48', 'KW 48', 'Viikko 48', 'Vecka 3', ' Week 1 ']) assert.equal(isWeekMarker({ title: { text: t } }), true, t)
  })
  it('CONTROL: a real entry that starts so, or names a week, stays', () => {
    for (const t of ['Week 48 sprint planning', 'Weekly sync', 'Review of week 48', 'Week', '48', 'Wedding 12']) assert.equal(isWeekMarker({ title: { text: t } }), false, t)
  })
})

describe('nearest upcoming first', () => {
  it('upcoming by start, a running one with them, then the past latest first; markers out', () => {
    const rows = [
      row('old', 'Last year', '2025-12-01T10:00:00Z'),
      row('w', 'Week 48', '2026-11-23T00:00:00Z', '2026-11-30T00:00:00Z'),
      row('far', 'Next month', '2026-12-27T09:00:00Z'),
      row('soon', 'Tomorrow', '2026-11-28T09:00:00Z'),
      row('now', 'Running', '2026-11-27T11:00:00Z', '2026-11-27T13:00:00Z'),
      row('ago', 'Yesterday', '2026-11-26T09:00:00Z'),
    ]
    assert.deepEqual(orderCalendarRows(rows, NOW).map((r) => r.key), ['now', 'soon', 'far', 'ago', 'old'])
  })
})

describe('the section read whole', () => {
  it('follows the cursor to the end, keeps each entry once, clears next', async () => {
    const first = { query: 'type:cal', groups: [{ type: 'messages', items: [{ key: 'm1' }], next: 'mc' }, { type: 'calendars', items: [row('a', 'Old', '2025-12-01T10:00:00Z')], next: 'c1' }] }
    const pages = {
      c1: { groups: [{ type: 'calendars', items: [row('a', 'Old', '2025-12-01T10:00:00Z'), row('b', 'Week 49', '2026-11-30T00:00:00Z')], next: 'c2' }] },
      c2: { groups: [{ type: 'calendars', items: [row('c', 'Soon', '2026-11-28T09:00:00Z')], next: null }] },
    }
    const asked = []
    const out = await completeCalendarSection(first, async (c) => { asked.push(c); return pages[c] }, NOW)
    assert.deepEqual(asked, ['c1', 'c2'])
    const cal = out.groups.find((g) => g.type === 'calendars')
    assert.deepEqual(cal.items.map((r) => r.key), ['c', 'a'])
    assert.equal(cal.next, null)
    assert.equal(out.groups[0].next, 'mc', 'another section keeps its own cursor')
  })
  it('stops after CALENDAR_MAX_PAGES pages', async () => {
    let n = 0
    const first = { groups: [{ type: 'calendars', items: [], next: 'c' }] }
    await completeCalendarSection(first, async () => { n++; return { groups: [{ type: 'calendars', items: [row('x' + n, 'E', '2026-12-01T00:00:00Z')], next: 'c' }] } }, NOW)
    assert.equal(n, CALENDAR_MAX_PAGES)
  })
  it('a section of markers only is dropped', async () => {
    const out = await completeCalendarSection({ groups: [{ type: 'calendars', items: [row('w', 'Week 48', '2026-11-23T00:00:00Z')], next: null }] }, async () => null, NOW)
    assert.deepEqual(out.groups, [])
  })
  it('CONTROL: no calendars section, the same answer back, no page read', async () => {
    const r = { groups: [{ type: 'messages', items: [], next: 'x' }] }
    assert.equal(await completeCalendarSection(r, async () => { throw new Error('read') }, NOW), r)
  })
})

describe('search panel width (spec 197 v1.2: 48 %, 380 px..65 %)', () => {
  it('opens at 48 % of the window, wider than the 260 px sidebar', () => {
    assert.equal(searchPanelDefault(1440), 691)
    assert.ok(searchPanelDefault(1024) > 260)
  })
  it('a drag stays between 380 px and 65 %', () => {
    assert.deepEqual(searchPanelBounds(1440), { min: 380, max: 936 })
    assert.equal(clampSearchPanel(100, 1440), 380)
    assert.equal(clampSearchPanel(5000, 1440), 936)
    assert.equal(clampSearchPanel(500, 1440), 500)
  })
  it('its width has its own key, not the sidebar\'s', () => {
    assert.equal(SEARCH_W_KEY, 'spool.us-pane-w')
  })
})
