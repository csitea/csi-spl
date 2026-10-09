// Spec 107 v1.2 T011 (owner R8..R11): the member's hours inside the calendar -
// which days show the Working hours line, the day's total from the
// GET /v1/me/hours answers, the periods a shown range needs, the rows as
// links (the day's discussions, R10), the banner, and the mock's answer.
// Run: node tests/unit/hours-calendar.test.mjs
import {
  HOURS_RANGE_MAX_PERIODS, hoursAddDays, hoursBanner, hoursBlocksText, hoursCollectPeriods, hoursHhmm, hoursIndex,
  hoursIsWorkday, hoursLineState, hoursNextPeriodDay, hoursShowsLine, hoursSortRows, hoursTarget,
} from '../../src/utils/hours-calendar.mjs'
import { loadHoursRange } from '../../src/utils/hours-calendar-api.mjs'
import { HOURS_MOCK_TOPIC, mockMyHours } from '../../src/utils/hours-calendar-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

// working days: Monday..Friday of the civil date (2026-10-05 is a Monday)
ok('Monday..Friday are working days', ['2026-10-05', '2026-10-06', '2026-10-07', '2026-10-08', '2026-10-09'].every(hoursIsWorkday))
ok('Saturday and Sunday are not', !hoursIsWorkday('2026-10-10') && !hoursIsWorkday('2026-10-11'))
ok('a bad date is not', !hoursIsWorkday('2026-13-40x') && !hoursIsWorkday(''))
ok('add days crosses a month', hoursAddDays('2026-10-31', 1) === '2026-11-01' && hoursAddDays('2026-10-01', -1) === '2026-09-30')

ok('h:mm', hoursHhmm(0) === '0:00' && hoursHhmm(65) === '1:05' && hoursHhmm(600) === '10:00' && hoursHhmm(-3) === '0:00')

// one answer per period the range touches
const week = (start) => ({ period: { start, end: hoursAddDays(start, 6) }, days: [] })
{
  const asked = []
  const got = await hoursCollectPeriods('2026-10-05', '2026-11-08', async (d) => { asked.push(d); return week(d) })
  ok('a month of weekly periods: one ask per week', asked.join() === '2026-10-05,2026-10-12,2026-10-19,2026-10-26,2026-11-02' && got.length === 5, asked.join())
}
{
  const asked = []
  await hoursCollectPeriods('2026-10-05', '2026-10-11', async (d) => { asked.push(d); return week('2026-10-01') })
  ok('a period ending inside the range asks for the next one', asked.join() === '2026-10-05,2026-10-08', asked.join())
}
{
  let n = 0
  await hoursCollectPeriods('2026-10-05', '2027-10-05', async () => { n++; return { period: { end: '2026-10-04' } } })
  ok('a period that does not move forward stops the walk', n === 1, String(n))
  n = 0
  await hoursCollectPeriods('2026-01-01', '2027-12-31', async (d) => { n++; return week(d) })
  ok('at most HOURS_RANGE_MAX_PERIODS asks', n === HOURS_RANGE_MAX_PERIODS, String(n))
}
ok('next period day', hoursNextPeriodDay({ period: { end: '2026-10-11' } }) === '2026-10-12' && hoursNextPeriodDay({}) === '')

// the day's total: approved entries + open suggestions, a rejected row counts 0
const body = {
  tz: 'UTC',
  period: { start: '2026-10-05', end: '2026-10-11', state: 'open', freezes_at: '2026-10-14T00:00:00Z' },
  days: [
    { date: '2026-10-05', closed: true, open: 2, approved_minutes: 60, rows: [
      { target: 'ws', state: 'suggested', minutes: 15 },
      { target: 'cal:e1', state: 'approved', minutes: 60 },
      { target: `t:${HOURS_MOCK_TOPIC}`, state: 'suggested', minutes: 110 },
      { target: 'ch:lobby', state: 'rejected', minutes: 30 },
    ] },
    { date: '2026-10-06', closed: true, frozen: true, open: 1, rows: [{ target: 'ch:lobby', state: 'approved', minutes: 20 }] },
    { date: '2026-10-09', today: true, open: 0, rows: [] },
    { date: '2026-10-10', open: 0, rows: [] },
    { date: '2026-10-11', open: 0, rows: [{ target: 'ws', state: 'approved', minutes: 30 }] },
  ],
}
const idx = hoursIndex([body])
ok('total = approved + suggested, rejected counts 0', idx.get('2026-10-05').total === 185, String(idx.get('2026-10-05')?.total))
ok('the day keeps its period', idx.get('2026-10-05').period.end === '2026-10-11')
ok('an empty or broken answer indexes nothing', hoursIndex([null, {}, { days: [{ date: 'x' }] }]).size === 0 && hoursIndex(undefined).size === 0)

// which days show the line (spec 5.1: every working day by default)
ok('a weekday shows the line with no hours', hoursShowsLine('2026-10-08', idx) && hoursShowsLine('2026-10-07', new Map()))
ok('a weekend day without hours shows none', !hoursShowsLine('2026-10-10', idx))
ok('a weekend day with hours shows it', hoursShowsLine('2026-10-11', idx))

ok('state: open suggestions', hoursLineState(idx.get('2026-10-05')) === 'open')
ok('state: frozen day', hoursLineState(idx.get('2026-10-06')) === 'frozen')
ok('state: nothing to do', hoursLineState(idx.get('2026-10-09')) === '' && hoursLineState(undefined) === '')
ok('state: final and returned come from the period', hoursLineState({ open: 3, period: { state: 'approved' } }) === 'final' && hoursLineState({ open: 0, period: { state: 'returned' } }) === 'returned')

// rows: the day's discussions as links (R10), the rest plain
const tp = hoursTarget(`t:${HOURS_MOCK_TOPIC}`, { [`t:${HOURS_MOCK_TOPIC}`]: 'Review the scaffold' })
ok('a topic is a link to the topic', tp.kind === 'topic' && tp.href === `/t/${HOURS_MOCK_TOPIC}` && tp.label === 'Review the scaffold', JSON.stringify(tp))
ok('an unknown topic shows its short id', hoursTarget('t:abcdef0123').label === 'abcdef01')
ok('a channel is #name, no link', hoursTarget('ch:lobby').label === '#lobby' && hoursTarget('ch:lobby').href === '')
ok('a meeting and "other"', hoursTarget('cal:e1').kind === 'meeting' && hoursTarget('ws').kind === 'other' && hoursTarget('').kind === 'other')
const sorted = hoursSortRows(body.days[0].rows).map((r) => r.target)
ok('discussions first, then meeting, channel, other; rejected last', sorted.join() === `t:${HOURS_MOCK_TOPIC},cal:e1,ws,ch:lobby`, sorted.join())
ok('blocks print in the answer zone', hoursBlocksText([{ start: '2026-10-05T09:12:00Z', end: '2026-10-05T10:40:00Z' }], 'UTC') === '09:12-10:40'
  && hoursBlocksText([{ start: '2026-10-05T09:12:00Z', end: '2026-10-05T10:40:00Z' }], 'Europe/Helsinki') === '12:12-13:40')

// banner: closed, unfrozen days with open work
const ban = hoursBanner(body)
ok('banner counts closed unfrozen open days', ban.openDays.join() === '2026-10-05', ban.openDays.join())
ok('banner carries the freeze and state', ban.freezesAt === '2026-10-14T00:00:00Z' && ban.state === 'open')

// the mock workspace: weekdays up to today hold rows, weekends none
const m = mockMyHours('2026-10-07', '2026-10-08')
ok('mock: a weekly period, Monday first', m.period.start === '2026-10-05' && m.period.end === '2026-10-11' && m.days.length === 7)
const mi = hoursIndex([m])
ok('mock: Monday total 3:05', hoursHhmm(mi.get('2026-10-05').total) === '3:05', hoursHhmm(mi.get('2026-10-05')?.total))
ok('mock: days after today and weekends are empty', mi.get('2026-10-09').total === 0 && mi.get('2026-10-10').rows.length === 0)
const range = await loadHoursRange({ mock: true, base: '' }, '2026-10-05', '2026-10-18', '2026-10-08')
ok('mock range: two weeks = two answers', range.length === 2 && range[1].period.start === '2026-10-12')

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-calendar checks passed.')
