// SPL-4060 (owner HUM-10, t1 080e1f77, poll 7c472af4): the desktop
// calendar's views (src/utils/calendar-desktop-view.mjs) and the grid that
// shows 8 hours from 09:00. Control: before SPL-4060 the module does not
// exist and the main view pins --cal-hour to 48 px, so this file FAILS.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  CAL_DESK_MIN_HOUR_PX, CAL_DESK_OPEN_MIN, CAL_DESK_VIEWS, CAL_DESK_WINDOW_H,
  calDeskDays, calDeskHourPx, calDeskRange, calDeskStep, calDeskTitle, calDeskView,
} from '../../src/utils/calendar-desktop-view.mjs'

const main = readFileSync(new URL('../../src/components/CalendarMainView.vue', import.meta.url), 'utf8')
const page = readFileSync(new URL('../../src/pages/calendar.vue', import.meta.url), 'utf8')

describe('calendar desktop views (SPL-4060)', () => {
  it('has Day, 3 days, Week, Month; anything else is Week', () => {
    assert.deepEqual(CAL_DESK_VIEWS, ['day', '3day', 'week', 'month'])
    assert.equal(calDeskView('3day'), '3day')
    assert.equal(calDeskView(undefined), 'week')
    assert.equal(calDeskView('year'), 'week')
  })
  it('3 days is the day before, the day and the day after (msg 37951fb6)', () => {
    assert.deepEqual(calDeskDays('3day', '2026-10-28'), ['2026-10-27', '2026-10-28', '2026-10-29'])
    assert.deepEqual(calDeskDays('3day', '2026-03-01'), ['2026-02-28', '2026-03-01', '2026-03-02'])
  })
  it('Day is the day, Week Monday..Sunday, Month its 42 cells', () => {
    assert.deepEqual(calDeskDays('day', '2026-10-28'), ['2026-10-28'])
    const w = calDeskDays('week', '2026-10-28')
    assert.equal(w.length, 7)
    assert.equal(w[0], '2026-10-26')
    const m = calDeskDays('month', '2026-10-28')
    assert.equal(m.length, 42)
    assert.equal(m[0], '2026-09-28')
    assert.deepEqual(calDeskDays('week', 'nope'), [])
  })
  it('reads [first, last + 1) of what it shows', () => {
    assert.deepEqual(calDeskRange('3day', '2026-10-28'), { from: '2026-10-27', to: '2026-10-30' })
    assert.deepEqual(calDeskRange('month', '2026-10-28'), { from: '2026-09-28', to: '2026-11-09' })
    assert.equal(calDeskRange('day', ''), null)
  })
  it('steps a day, 3 days, a week or a month', () => {
    assert.equal(calDeskStep('day', '2026-10-28', 1), '2026-10-29')
    assert.equal(calDeskStep('3day', '2026-10-28', -1), '2026-10-25')
    assert.equal(calDeskStep('week', '2026-10-28', 1), '2026-11-04')
    assert.equal(calDeskStep('month', '2026-01-31', 1), '2026-02-28')
  })
  it('titles a day, a span and a month', () => {
    assert.deepEqual(calDeskTitle('day', '2026-10-28'), ['2026-10-28'])
    assert.deepEqual(calDeskTitle('week', '2026-10-28'), ['2026-10-26', '2026-11-01'])
    assert.deepEqual(calDeskTitle('month', '2026-10-28'), ['2026-10'])
  })
  it('an hour row is 1/8 of the visible grid, never under the floor', () => {
    assert.equal(CAL_DESK_WINDOW_H, 8)
    assert.equal(CAL_DESK_OPEN_MIN, 540)
    assert.equal(calDeskHourPx(800), 100)
    assert.equal(calDeskHourPx(100), CAL_DESK_MIN_HOUR_PX)
    assert.equal(calDeskHourPx(NaN), CAL_DESK_MIN_HOUR_PX)
  })
  it('the main view sizes its hours from the window, not a fixed 48 px', () => {
    assert.doesNotMatch(main, /--cal-hour:\s*48px/)
    assert.match(main, /'--cal-hour': `\$\{hourPx\}px`/)
    assert.match(main, /CAL_DESK_OPEN_MIN \/ CAL_DAY_MIN/)
  })
  it('the desktop page has no header bar; the tab group holds its controls', () => {
    assert.doesNotMatch(page, /class="feed-header"/)
    const tabs = readFileSync(new URL('../../src/components/CalendarViewTabs.vue', import.meta.url), 'utf8')
    for (const t of ['calendar-hours-toggle', 'calendar-today', 'calendar-prev', 'calendar-next', 'calendar-range', 'calendar-menu', 'aria-orientation="vertical"', '<SectionClose side="start" />']) {
      assert.ok(tabs.includes(t), `CalendarViewTabs lacks ${t}`)
    }
  })
})
