// Spec 107 v1.2 T013 + T014 (owner R9, R10; spec 4.1, 5.2, 5.3): what the
// member's controls in the Working hours dialog and the panel's Mine tab
// write (PUT /v1/me/hours bodies), and the mock hub that keeps those writes.
// - Approve week / Approve N days approve CLOSED days only: approving on
//   Friday morning leaves Friday open; today has Approve so far.
// - A delta is one tap; reject counts 0 and Undo puts the row back.
// - Every write keeps the row's note; a note is <= 500 characters.
// - The mock refuses 1440+ approved minutes a day (400 day_cap) and a frozen
//   period (409), and Resubmit moves a returned period to frozen.
// Control: before T013 / T014 src/utils/hours-mine.mjs does not exist and
// the mock has no PUT, so this file fails at import.
// Run: node tests/unit/hours-mine.test.mjs
import {
  HOURS_NOTE_MAX, hoursAddEntry, hoursApproveEntries, hoursApproveRow, hoursDayEditable, hoursEditEntry, hoursNote,
  hoursOpenCount, hoursParseMinutes, hoursRefusalKey, hoursRejectEntry, hoursRowOpen, hoursStep, hoursUndoBody,
} from '../../src/utils/hours-mine.mjs'
import { hoursIndex } from '../../src/utils/hours-calendar.mjs'
import { putMyHours } from '../../src/utils/hours-calendar-api.mjs'
import { HOURS_MOCK_TOPIC, mockHoursReset, mockHoursSetPeriod, mockMyHours, mockPutMyHours } from '../../src/utils/hours-calendar-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const j = (v) => JSON.stringify(v)

// a week, Monday 2026-10-05 .. Sunday 2026-10-11, the member's today Friday 10-09
const week = {
  today: '2026-10-09',
  period: { start: '2026-10-05', end: '2026-10-11', state: 'open' },
  days: [
    { date: '2026-10-05', closed: true, rows: [
      { target: 't:a', state: 'suggested', minutes: 110 },
      { target: 'cal:m', state: 'approved', minutes: 60 },
      { target: 'ws', state: 'rejected', minutes: 15 },
    ] },
    { date: '2026-10-06', closed: true, rows: [{ target: 't:a', state: 'approved', minutes: 50, delta: 20, note: 'review' }] },
    { date: '2026-10-07', closed: true, rows: [{ target: 'ch:x', state: 'approved', minutes: 30 }] },
    { date: '2026-10-08', closed: true, frozen: true, rows: [{ target: 't:b', state: 'suggested', minutes: 40 }] },
    { date: '2026-10-09', today: true, rows: [{ target: 't:b', state: 'suggested', minutes: 25 }] },
    { date: '2026-10-10', rows: [] },
    { date: '2026-10-11', rows: [] },
  ],
}

// T013: which rows wait for the member
ok('a suggestion is open', hoursRowOpen({ state: 'suggested' }))
ok('a delta is open', hoursRowOpen({ state: 'approved', delta: 20 }))
ok('an approved row without delta and a rejected row are not', !hoursRowOpen({ state: 'approved' }) && !hoursRowOpen({ state: 'rejected', delta: 5 }))
ok('approving a delta adds it, keeping the note', j(hoursApproveRow('2026-10-06', week.days[1].rows[0])) === j({ day: '2026-10-06', target: 't:a', minutes: 70, state: 'approved', note: 'review' }))

// Approve week on Friday morning: Monday and Tuesday's open rows, never today
const wk = hoursApproveEntries(week, 'closed')
ok('Approve week approves the closed days\' open rows', j(wk.map((e) => `${e.day} ${e.target} ${e.minutes}`)) === j(['2026-10-05 t:a 110', '2026-10-06 t:a 70']), j(wk))
ok('Friday-morning Approve week leaves today open', !wk.some((e) => e.day === '2026-10-09'))
ok('a frozen closed day is left alone', !wk.some((e) => e.day === '2026-10-08'))
ok('the open count is 2 ("Approve week · 2 open")', hoursOpenCount(week) === 2)
ok('Approve so far: today only', j(hoursApproveEntries(week, 'today')) === j([{ day: '2026-10-09', target: 't:b', minutes: 25, state: 'approved', note: '' }]))
ok('Approve day: that closed day only', j(hoursApproveEntries(week, '2026-10-05').map((e) => e.target)) === j(['t:a']))
ok('Approve day is never today', hoursApproveEntries(week, '2026-10-09').length === 0)
ok('a frozen or Final period approves nothing', hoursApproveEntries({ ...week, period: { state: 'frozen' } }, 'closed').length === 0 && hoursApproveEntries({ ...week, period: { state: 'approved' } }, 'today').length === 0)
ok('a returned period is editable', hoursApproveEntries({ ...week, period: { state: 'returned' } }, 'closed').length === 2)
ok('editable: not frozen, not after today, period open or returned',
  hoursDayEditable({ date: '2026-10-09' }, { state: 'open' }, '2026-10-09') && !hoursDayEditable({ date: '2026-10-10' }, { state: 'open' }, '2026-10-09')
  && !hoursDayEditable({ date: '2026-10-08', frozen: true }, { state: 'open' }, '2026-10-09') && !hoursDayEditable({ date: '2026-10-07' }, { state: 'approved' }, '2026-10-09'))

// reject + Undo
const sug = week.days[0].rows[0]
ok('reject writes the row rejected', j(hoursRejectEntry('2026-10-05', sug)) === j({ day: '2026-10-05', target: 't:a', minutes: 110, state: 'rejected', note: '' }))
ok('Undo of a rejected suggestion removes the entry (the suggestion comes back)', j(hoursUndoBody('2026-10-05', sug)) === j({ remove: [{ day: '2026-10-05', target: 't:a' }] }))
ok('Undo of a rejected entry puts its minutes and note back', j(hoursUndoBody('2026-10-06', { target: 't:a', state: 'approved', minutes: 50, note: 'review' })) === j({ entries: [{ day: '2026-10-06', target: 't:a', minutes: 50, state: 'approved', note: 'review' }] }))

// T014: stepper, +15, typed minutes, notes, add
ok('±15 stays within 0..1440', hoursStep(10, -15) === 0 && hoursStep(1430, 15) === 1440 && hoursStep(30, 15) === 45)
ok('typed time: 1:30 and 90 are 90; junk is -1', hoursParseMinutes('1:30') === 90 && hoursParseMinutes(' 90 ') === 90 && hoursParseMinutes('1:75') === -1 && hoursParseMinutes('abc') === -1)
ok('+15 on a suggestion approves it with 15 more', j(hoursEditEntry('2026-10-05', sug, { minutes: hoursStep(sug.minutes, 15) })) === j({ day: '2026-10-05', target: 't:a', minutes: 125, state: 'approved', note: '' }))
ok('R10: a note on an open suggestion approves it with its suggested minutes', j(hoursEditEntry('2026-10-05', sug, { note: '  spec review ' })) === j({ day: '2026-10-05', target: 't:a', minutes: 110, state: 'approved', note: 'spec review' }))
ok('a note on a rejected row keeps it rejected', hoursEditEntry('2026-10-05', week.days[0].rows[2], { note: 'x' }).state === 'rejected')
ok('an edit keeps the row\'s note', hoursEditEntry('2026-10-06', week.days[1].rows[0], { minutes: 45 }).note === 'review')
ok(`a note is at most ${HOURS_NOTE_MAX} characters`, [...hoursNote('ä'.repeat(600))].length === 500)
ok('+ Add books the target approved', j(hoursAddEntry('2026-10-09', 'ch:x', 30)) === j({ day: '2026-10-09', target: 'ch:x', minutes: 30, state: 'approved', note: '' }))
ok('refusals in words', hoursRefusalKey({ status: 409, error: 'period_frozen' }) === 'hours_cal.err_frozen' && hoursRefusalKey({ status: 400, error: 'day_cap' }) === 'hours_cal.err_day_cap'
  && hoursRefusalKey({ status: 401 }) === 'hours_cal.err_session' && hoursRefusalKey({ status: 0 }) === 'hours_cal.err_network')

// the mock hub keeps the writes (lde and e2e read them back)
mockHoursReset()
const TODAY = '2026-10-09'
const mon = '2026-10-05'
const before = hoursIndex([mockMyHours(mon, TODAY)])
ok('mock: Tuesday\'s topic carries a 0:20 delta', before.get('2026-10-06').rows.find((r) => r.target === `t:${HOURS_MOCK_TOPIC}`)?.delta === 20)
const after1 = await putMyHours({ mock: true, base: '' }, { entries: hoursApproveEntries(mockMyHours(mon, TODAY), 'closed') }, TODAY)
const idx = hoursIndex([after1])
ok('mock: Approve week leaves no open row on a closed day', [...idx.values()].filter((d) => d.closed).every((d) => d.open === 0), j([...idx.values()].map((d) => [d.date, d.open])))
ok('mock: today stays open after Approve week', idx.get(TODAY).open === 1)
ok('mock: the accepted delta reads 1:10, no delta', (() => { const r = idx.get('2026-10-06').rows.find((x) => x.target === `t:${HOURS_MOCK_TOPIC}`); return r.minutes === 70 && !r.delta })())
const rej = mockPutMyHours({ entries: [hoursRejectEntry(TODAY, idx.get(TODAY).rows[0])] }, TODAY)
ok('mock: a rejected row counts 0', hoursIndex([rej]).get(TODAY).total === 0)
const undone = mockPutMyHours(hoursUndoBody(TODAY, { ...idx.get(TODAY).rows[0] }), TODAY)
ok('mock: Undo gives the suggestion back', hoursIndex([undone]).get(TODAY).rows[0].state === 'suggested')
const noted = mockPutMyHours({ entries: [hoursEditEntry(mon, { target: `t:${HOURS_MOCK_TOPIC}`, state: 'approved', minutes: 110 }, { note: 'spec review' })] }, TODAY)
ok('R10: mock: the note reads back on its line', hoursIndex([noted]).get(mon).rows.find((r) => r.target === `t:${HOURS_MOCK_TOPIC}`)?.note === 'spec review')
const added = mockPutMyHours({ entries: [hoursAddEntry(TODAY, 'ch:general', 30)] }, TODAY)
ok('mock: + Add shows the new row', hoursIndex([added]).get(TODAY).rows.some((r) => r.target === 'ch:general' && r.minutes === 30 && r.state === 'approved'))
let capErr = null
try { mockPutMyHours({ entries: [hoursAddEntry(mon, 'ch:general', 1440)] }, TODAY) } catch (e) { capErr = e }
ok('mock: 1440+ approved minutes a day is 400 day_cap', capErr?.status === 400 && capErr?.error === 'day_cap', j(capErr))
let futErr = null
try { mockPutMyHours({ entries: [hoursAddEntry('2026-10-10', 'ch:general', 10)] }, TODAY) } catch (e) { futErr = e }
ok('mock: a day after today is refused', futErr?.status === 400)
mockHoursSetPeriod(mon, 'returned', 'Tuesday is short')
const ret = mockMyHours(mon, TODAY)
ok('mock: a returned period shows its note and no suggestions', ret.period.state === 'returned' && ret.period.note === 'Tuesday is short' && ret.days.every((d) => d.rows.every((r) => r.state !== 'suggested')))
const resub = mockPutMyHours({ resubmit: mon }, TODAY)
ok('mock: Resubmit moves the period to frozen, its days locked', resub.period.state === 'frozen' && resub.days.every((d) => d.frozen))
let frozenErr = null
try { mockPutMyHours({ entries: [hoursAddEntry(mon, 'ws', 15)] }, TODAY) } catch (e) { frozenErr = e }
ok('mock: a frozen period is 409 period_frozen', frozenErr?.status === 409 && frozenErr?.error === 'period_frozen')
mockHoursReset()

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-mine checks passed.')
