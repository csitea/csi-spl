// Spec 170 row B1: the task rules of the To-do view and the morning card
// (src/utils/day-tasks.mjs). Owner Q3 = A (msg 446d58a3): overdue shows above
// today's and counts in the signal; a task due today at 09:00 is still due
// today at 10:00.
//
// Run: node --test tests/unit/day-tasks.test.mjs
import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dayBounds, dueTodayCounts, groupByDay, isTask, overdue } from '../../src/utils/day-tasks.mjs'
import { calDeskRange } from '../../src/utils/calendar-desktop-view.mjs'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REAL_TZ = process.env.TZ

/** The picked zone (Settings) and the browser's; "" picks nothing. */
function viewer(picked, browser, fn) {
  process.env.TZ = browser
  setTimeZoneSource(() => picked)
  try { return fn() } finally { setTimeZoneSource(() => '') }
}

after(() => {
  if (REAL_TZ === undefined) delete process.env.TZ
  else process.env.TZ = REAL_TZ
})

const task = (deadline, extra = {}) => ({ key: `SPL-${deadline}`, status: 'todo', kind: 'issue', deadline, ...extra })

describe('isTask: open, not an epic or a feature, with a deadline', () => {
  const when = '2026-11-02T09:00:00Z'
  it('every open status is a task', () => {
    for (const status of ['eval', 'todo', 'wip', 'blocked', 'onhold', 'qas']) {
      assert.equal(isTask(task(when, { status })), true, status)
    }
    assert.equal(isTask(task(when, { kind: 'subtask' })), true)
  })
  it('an epic and a feature are out', () => {
    assert.equal(isTask(task(when, { kind: 'epic' })), false)
    assert.equal(isTask(task(when, { kind: 'feature' })), false)
  })
  it('done and diss are closed', () => {
    assert.equal(isTask(task(when, { status: 'done' })), false)
    assert.equal(isTask(task(when, { status: 'diss' })), false)
  })
  it('no deadline, or not a time, is not a task', () => {
    assert.equal(isTask(task('')), false)
    assert.equal(isTask(task(null)), false)
    assert.equal(isTask(task('nope')), false)
    assert.equal(isTask({ status: 'todo', kind: 'issue' }), false)
    assert.equal(isTask(null), false)
  })
})

describe('dayBounds: the picked zone, else the browser\'s', () => {
  it('an explicit zone wins over both', () => {
    assert.deepEqual(viewer('Asia/Tokyo', 'America/New_York', () => dayBounds('2026-11-03', 'Europe/Helsinki')),
      { start: '2026-11-02T22:00:00.000Z', end: '2026-11-03T22:00:00.000Z' })
  })
  it('the picked zone decides, not the browser\'s', () => {
    assert.deepEqual(viewer('Europe/Helsinki', 'America/New_York', () => dayBounds('2026-11-03')),
      { start: '2026-11-02T22:00:00.000Z', end: '2026-11-03T22:00:00.000Z' })
  })
  it('nothing picked: the browser\'s', () => {
    assert.deepEqual(viewer('', 'America/New_York', () => dayBounds('2026-11-03')),
      { start: '2026-11-03T05:00:00.000Z', end: '2026-11-04T05:00:00.000Z' })
  })
  it('an unknown picked zone falls back to the browser\'s', () => {
    assert.deepEqual(viewer('Nope/Nowhere', 'Asia/Tokyo', () => dayBounds('2026-11-03')),
      { start: '2026-11-02T15:00:00.000Z', end: '2026-11-03T15:00:00.000Z' })
  })
  it('the far offsets stay inside the search', () => {
    assert.equal(dayBounds('2026-11-03', 'Pacific/Kiritimati').start, '2026-11-02T10:00:00.000Z')
    assert.equal(dayBounds('2026-11-03', 'Etc/GMT+12').start, '2026-11-03T12:00:00.000Z')
    assert.equal(dayBounds('2026-11-03', 'Asia/Kolkata').start, '2026-11-02T18:30:00.000Z')
  })
  it('a daylight day is 23 or 25 hours', () => {
    const hours = (b) => (Date.parse(b.end) - Date.parse(b.start)) / 3600000
    assert.equal(hours(dayBounds('2026-03-29', 'Europe/Helsinki')), 23)
    assert.equal(hours(dayBounds('2026-10-25', 'Europe/Helsinki')), 25)
  })
  it('a day whose midnight does not exist starts at 01:00', () => {
    /* Havana springs from 00:00 to 01:00 on 2026-03-08 (UTC-5 before). */
    assert.equal(dayBounds('2026-03-08', 'America/Havana').start, '2026-03-08T05:00:00.000Z')
  })
  it('neighbouring days share their edge', () => {
    assert.equal(dayBounds('2026-11-02', 'Europe/Helsinki').end, dayBounds('2026-11-03', 'Europe/Helsinki').start)
  })
  it('not a day is null', () => {
    assert.equal(dayBounds('nope'), null)
    assert.equal(dayBounds('2026-02-30'), null)
    assert.equal(dayBounds(''), null)
  })
})

describe('overdue and due today', () => {
  /* 10:00 on 2026-11-02 at Helsinki (+02) */
  const TEN = Date.UTC(2026, 10, 2, 8, 0)
  const NINE_TODAY = task('2026-11-02T07:00:00Z')
  const YESTERDAY = task('2026-11-01T21:59:00Z')
  const LAST_WEEK = task('2026-10-26T09:00:00Z')
  const TOMORROW = task('2026-11-02T22:00:00Z')

  it('09:00 today is still due today at 10:00, never overdue', () => {
    assert.deepEqual(overdue([NINE_TODAY], TEN, 'Europe/Helsinki'), [])
    assert.deepEqual(dueTodayCounts([NINE_TODAY], TEN, 'Europe/Helsinki'), { today: 1, overdue: 0 })
  })
  it('23:59 yesterday is overdue, 00:00 tomorrow is neither', () => {
    assert.deepEqual(overdue([YESTERDAY, TOMORROW], TEN, 'Europe/Helsinki'), [YESTERDAY])
    assert.deepEqual(dueTodayCounts([YESTERDAY, TOMORROW], TEN, 'Europe/Helsinki'), { today: 0, overdue: 1 })
  })
  it('the same deadline is overdue or today by the zone', () => {
    /* 2026-11-01 23:30Z: 01:30 on the 2nd at Helsinki, 18:30 on the 1st in New York */
    const d = task('2026-11-01T23:30:00Z')
    const now = Date.UTC(2026, 10, 2, 12, 0)
    assert.deepEqual(dueTodayCounts([d], now, 'Europe/Helsinki'), { today: 1, overdue: 0 })
    assert.deepEqual(dueTodayCounts([d], now, 'America/New_York'), { today: 0, overdue: 1 })
  })
  it('oldest first, and a Date is a clock too', () => {
    assert.deepEqual(overdue([YESTERDAY, LAST_WEEK], new Date(TEN), 'Europe/Helsinki'), [LAST_WEEK, YESTERDAY])
  })
  it('a closed task, an epic and a feature count in neither', () => {
    const out = [
      task('2026-11-02T07:00:00Z', { status: 'done' }), task('2026-11-02T07:00:00Z', { status: 'diss' }),
      task('2026-10-26T09:00:00Z', { status: 'done' }), task('2026-10-26T09:00:00Z', { status: 'diss' }),
      task('2026-11-02T07:00:00Z', { kind: 'epic' }), task('2026-10-26T09:00:00Z', { kind: 'feature' }),
    ]
    assert.deepEqual(overdue(out, TEN, 'Europe/Helsinki'), [])
    assert.deepEqual(dueTodayCounts(out, TEN, 'Europe/Helsinki'), { today: 0, overdue: 0 })
  })
  it('not a list or not a clock counts nothing', () => {
    assert.deepEqual(overdue(null, TEN), [])
    assert.deepEqual(overdue([LAST_WEEK], NaN), [])
    assert.deepEqual(dueTodayCounts(null, TEN), { today: 0, overdue: 0 })
    assert.deepEqual(dueTodayCounts([LAST_WEEK], NaN), { today: 0, overdue: 0 })
  })
})

describe('groupByDay', () => {
  const RANGE = { from: '2026-11-01', to: '2026-11-04' }
  it('every day in order, tasks earliest first, empty days kept', () => {
    const late = task('2026-11-02T15:00:00Z')
    const early = task('2026-11-02T07:00:00Z')
    const got = groupByDay([late, early], RANGE, 'Europe/Helsinki')
    assert.deepEqual(got, [
      { day: '2026-11-01', tasks: [] },
      { day: '2026-11-02', tasks: [early, late] },
      { day: '2026-11-03', tasks: [] },
    ])
  })
  it('a deadline lands on the viewer\'s day, not the UTC one', () => {
    const d = task('2026-11-01T22:30:00Z')
    assert.deepEqual(groupByDay([d], RANGE, 'Europe/Helsinki')[1].tasks, [d])
    assert.deepEqual(groupByDay([d], RANGE, 'UTC')[0].tasks, [d])
    assert.deepEqual(viewer('Europe/Helsinki', 'UTC', () => groupByDay([d], RANGE))[1].tasks, [d])
    assert.deepEqual(viewer('', 'Europe/Helsinki', () => groupByDay([d], RANGE))[1].tasks, [d])
  })
  it('the range\'s end is out, as is what is before it', () => {
    const got = groupByDay([task('2026-11-04T12:00:00Z'), task('2026-10-31T12:00:00Z')], RANGE, 'UTC')
    assert.deepEqual(got.flatMap((g) => g.tasks), [])
  })
  it('only tasks: epic, feature, diss and no deadline are out', () => {
    const when = '2026-11-02T12:00:00Z'
    const got = groupByDay([task(when, { kind: 'epic' }), task(when, { kind: 'feature' }), task(when, { status: 'diss' }), task('')], RANGE, 'UTC')
    assert.deepEqual(got.flatMap((g) => g.tasks), [])
  })
  it('takes what calDeskRange answers: a Week is seven days', () => {
    const got = groupByDay([], calDeskRange('week', '2026-11-02'), 'UTC')
    assert.deepEqual(got.map((g) => g.day), ['2026-11-02', '2026-11-03', '2026-11-04', '2026-11-05', '2026-11-06', '2026-11-07', '2026-11-08'])
  })
  it('a list that is not a list is empty days; a bad range is no days', () => {
    assert.deepEqual(groupByDay(null, { from: '2026-11-01', to: '2026-11-02' }, 'UTC'), [{ day: '2026-11-01', tasks: [] }])
    assert.deepEqual(groupByDay([], null), [])
    assert.deepEqual(groupByDay([], { from: 'x', to: 'y' }), [])
    assert.deepEqual(groupByDay([], { from: '2026-11-02', to: '2026-11-02' }), [])
  })
})

describe('the list and the number agree (spec 170 section 5)', () => {
  it('the Day range on today lists what dueTodayCounts counts', () => {
    const now = Date.UTC(2026, 10, 2, 8, 0)
    const rows = [
      task('2026-11-02T07:00:00Z'), task('2026-11-02T21:00:00Z'), task('2026-11-01T21:00:00Z'),
      task('2026-11-02T22:30:00Z'), task('2026-11-02T07:00:00Z', { status: 'diss' }), task('2026-11-02T07:00:00Z', { kind: 'epic' }),
    ]
    const zone = 'Europe/Helsinki'
    const [day] = groupByDay(rows, calDeskRange('day', '2026-11-02'), zone)
    const counts = dueTodayCounts(rows, now, zone)
    assert.equal(counts.today, day.tasks.length)
    assert.equal(counts.overdue, overdue(rows, now, zone).length)
    assert.deepEqual(counts, { today: 2, overdue: 1 })
  })
})

describe('lazy: not in the initial JS yet (row B1)', () => {
  it('no source imports the module', () => {
    const importers = []
    const walk = (dir) => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name)
        if (e.isDirectory()) walk(p)
        else if (/\.(vue|ts|mjs)$/.test(e.name) && !p.endsWith('day-tasks.mjs') && !p.endsWith('day-tasks.d.ts')
          && /day-tasks\.mjs/.test(readFileSync(p, 'utf8'))) importers.push(p)
      }
    }
    walk(join(WUI, 'src'))
    assert.deepEqual(importers, [])
  })
})
