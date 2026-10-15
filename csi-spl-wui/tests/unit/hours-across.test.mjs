// Spec 118 T005, T-OV-JS (the JS half): src/utils/hours-across.mjs gives the
// answer the hub's hours.Across gives, case by case, on the one shared
// fixture csi-spl-api/.../internal/hours/testdata/overlap_fixture.json (the Go
// half is TestAcrossFixture in across_test.go). Then what the fixture does
// not pin: a person's midnight in a non-UTC zone, a rejected entry, the
// placement cut, a data error, an unavailable workspace, the window sum; and
// the composable's pure parts: the timer redraw and the D3 limit warning.
// Run: node tests/unit/hours-across.test.mjs
import { readFileSync } from 'node:fs'
import { hoursAcross, hoursDayIn, hoursLimitInEffect, hoursLimitLevel, hoursSum, hoursWithTimers } from '../../src/utils/hours-across.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

// JSON with sorted keys: Go's map order and ours need not agree
const canon = (v) => JSON.stringify(v, (_, x) => (x && typeof x === 'object' && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]]))
  : x))

const fixtureUrl = new URL('../../../csi-spl-api/src/go/spool-hub-api/internal/hours/testdata/overlap_fixture.json', import.meta.url)
const fixture = JSON.parse(readFileSync(fixtureUrl, 'utf8'))
ok('the shared fixture has cases', Array.isArray(fixture.cases) && fixture.cases.length >= 4, String(fixture.cases?.length))
for (const c of fixture.cases) {
  let got
  try { got = hoursAcross(c.days, c.zone, c.now) } catch (e) { got = String(e) }
  ok(`fixture: ${c.name}`, canon(got) === canon(c.want), `\n    got  ${canon(got)}\n    want ${canon(c.want)}`)
}

const ws = (workspace, day, entries, extra = {}) => ({ workspace, day, entries, ...extra })
const entry = (minutes, state, ...spans) => ({ target: 't:1', minutes, state, spans: spans.map(([start, end]) => ({ start, end })) })

ok('empty input: no days', hoursAcross([], 'UTC', new Date()).length === 0)
ok('an unknown zone is refused, as Go\'s LoadLocation refuses it', (() => { try { hoursAcross([], 'Mars/Olympus', new Date()); return false } catch { return true } })())
ok('a zone is required', (() => { try { hoursAcross([], '', new Date()); return false } catch { return true } })())

// Europe/Helsinki is UTC+3 on 2026-10-13: the person's midnight is 21:00Z
{
  const days = hoursAcross([ws('A', '2026-10-13', [entry(120, 'approved', ['2026-10-13T20:00:00Z', '2026-10-13T22:00:00Z'])])], 'Europe/Helsinki', '2026-10-14T06:00:00Z')
  ok('a span is split at the person\'s midnight (Helsinki 21:00Z)', days.map((d) => `${d.day}:${d.reported}`).join() === '2026-10-13:60,2026-10-14:60', canon(days))
  ok('the second part starts at that midnight', days[1]?.workspaces.A.spans[0].start === '2026-10-13T21:00:00Z', canon(days[1]))
}
{
  // 2026-10-25: Helsinki leaves summer time, the day is 25 hours long
  const days = hoursAcross([ws('A', '2026-10-25', [entry(1500, 'approved', ['2026-10-24T21:00:00Z', '2026-10-25T22:00:00Z'])])], 'Europe/Helsinki', '2026-10-26T06:00:00Z')
  ok('a DST day is 25 hours between two midnights', days.length === 1 && days[0].day === '2026-10-25' && days[0].actual === 1500, canon(days))
}
ok('hoursDayIn reads the zone', hoursDayIn(Date.parse('2026-10-13T21:30:00Z'), 'Europe/Helsinki') === '2026-10-14' && hoursDayIn(Date.parse('2026-10-13T21:30:00Z'), 'UTC') === '2026-10-13')
{
  const [d] = hoursAcross([ws('A', '2026-10-13', [entry(60, 'rejected', ['2026-10-13T09:00:00Z', '2026-10-13T10:00:00Z']), entry(30, 'approved', ['2026-10-13T11:00:00Z', '2026-10-13T12:00:00Z'])])], 'UTC', '2026-10-13T18:00:00Z')
  ok('a rejected entry counts 0', d.reported === 30 && d.workspaces.A.spans.length === 1, canon(d))
  ok('placement cuts the span to the entry\'s minutes', d.workspaces.A.spans[0].end === '2026-10-13T11:30:00Z' && d.actual === 30, canon(d))
}
{
  const [d] = hoursAcross([ws('A', '2026-10-13', [entry(60, 'approved', ['2026-10-13T09:00:00Z', '2026-10-13T10:00:00Z']), entry(60, 'approved', ['2026-10-13T09:30:00Z', '2026-10-13T10:30:00Z'])])], 'UTC', '2026-10-13T18:00:00Z')
  ok('one workspace overlapping itself is a data error, counted once', d.data_error_minutes === 30 && d.actual === 90 && d.overlap === 30 && d.overlap_intervals.length === 0, canon(d))
}
{
  const [d] = hoursAcross([ws('A', '2026-10-13', [entry(60, 'approved', ['2026-10-13T09:00:00Z', '2026-10-13T10:00:00Z'])]), ws('B', '2026-10-13', [], { unavailable: true })], 'UTC', '2026-10-13T18:00:00Z')
  ok('an unavailable workspace marks the day incomplete and is named', d.incomplete && d.unavailable.join() === 'B' && d.reported === 60, canon(d))
}
{
  const [d] = hoursAcross([ws('A', '2026-10-13', [entry(240, 'approved', ['2026-10-13T09:00:00Z', '2026-10-13T13:00:00Z'])]), ws('B', '2026-10-13', [entry(60, 'approved', ['2026-10-13T10:00:00Z', '2026-10-13T11:00:00Z'])]), ws('C', '2026-10-13', [entry(60, 'approved', ['2026-10-13T10:30:00Z', '2026-10-13T11:30:00Z'])])], 'UTC', '2026-10-13T18:00:00Z')
  ok('three workspaces: one interval per open set', d.overlap_intervals.map((i) => `${i.start.slice(11, 16)}-${i.end.slice(11, 16)}:${i.workspaces.join('')}`).join() === '10:00-10:30:AB,10:30-11:00:ABC,11:00-11:30:AC', canon(d.overlap_intervals))
}
ok('a timer not yet started adds nothing', hoursAcross([ws('A', '2026-10-13', [], { timer: '2026-10-13T12:00:00Z' })], 'UTC', '2026-10-13T11:00:00Z')[0].actual === 0)
ok('a bad entry state is refused', (() => { try { hoursAcross([ws('A', '2026-10-13', [entry(1, 'maybe')])], 'UTC', 0); return false } catch { return true } })())
ok('the window sum adds the days', canon(hoursSum([{ reported: 1, open: 0, actual: 2, overlap: 0, unplaced: 1, data_error_minutes: 0 }, { reported: 3, open: 1, actual: 1, overlap: 2, unplaced: 0, data_error_minutes: 4 }])) === canon({ reported: 4, open: 1, actual: 3, overlap: 2, unplaced: 1, data_error_minutes: 4 }))

// hoursWithTimers: the hub's answer has no timer (it never sees one); redrawn on
// the device it must give what Across gives with the timer in its input
{
  const c = fixture.cases.find((x) => x.days.some((d) => d.timer))
  ok('the fixture has a timer case', !!c)
  if (c) {
    const timers = Object.fromEntries(c.days.filter((d) => d.timer).map((d) => [d.workspace, d.timer]))
    const [hub] = hoursAcross(c.days.map(({ timer, ...d }) => d), c.zone, c.now)
    const got = hoursWithTimers(hub, timers, c.zone, c.now)
    ok('hoursWithTimers on the hub answer = the fixture\'s timer case', canon(got) === canon(c.want[0]), `\n    got  ${canon(got)}\n    want ${canon(c.want[0])}`)
    const later = hoursWithTimers(hub, timers, c.zone, Date.parse(c.now) + 30 * 60000)
    ok('a minute tick moves actual, never reported', later.actual === got.actual + 30 && later.reported === got.reported, canon(later))
  }
  const [plain] = hoursAcross(fixture.cases[0].days, 'UTC', fixture.cases[0].now)
  ok('no timer: the day is returned as is', hoursWithTimers(plain, {}, 'UTC', 0) === plain)
  const [mixed] = hoursAcross([ws('A', '2026-10-13', [entry(60, 'open', ['2026-10-13T09:00:00Z', '2026-10-13T10:00:00Z']), entry(30, 'approved'), entry(60, 'approved', ['2026-10-13T09:30:00Z', '2026-10-13T10:30:00Z'])])], 'UTC', '2026-10-13T18:00:00Z')
  const redrawn = hoursWithTimers(mixed, { B: '2026-10-13T17:00:00Z' }, 'UTC', '2026-10-13T18:00:00Z')
  ok('the redraw keeps open, unplaced and the data error', redrawn.open === 60 && redrawn.workspaces.A.open === 60 && redrawn.unplaced === 30 && redrawn.data_error_minutes === 30 && redrawn.actual === mixed.actual + 60, canon(redrawn))
}

// D3 limit warning (8.1): amber at 90 %, red past 100 %
ok('no limit: no warning', hoursLimitLevel(500, null) === 'none' && hoursLimitLevel(500, 0) === 'none')
ok('below 90 %: none', hoursLimitLevel(2429, 2700) === 'none')
ok('at 90 %: amber', hoursLimitLevel(2430, 2700) === 'amber')
ok('at 100 %: still amber', hoursLimitLevel(2700, 2700) === 'amber')
ok('past 100 %: red', hoursLimitLevel(2701, 2700) === 'red')
{
  const limits = [{ valid_from: '2026-09-01', week_minutes: 2400 }, { valid_from: '2026-10-10', week_minutes: 2700 }, { valid_from: '2026-11-01', week_minutes: 1 }]
  ok('the limit in effect is the latest not after the day', hoursLimitInEffect(limits, '2026-10-13')?.week_minutes === 2700 && hoursLimitInEffect(limits, '2026-10-09')?.week_minutes === 2400)
  ok('no limit before the first', hoursLimitInEffect(limits, '2026-08-01') === null)
}

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-across checks passed.')
