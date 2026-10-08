// Spec 107 Q7 = B (T019): the header timer, WUI side - the per-member row in
// localStorage (survives a reload, one row per workspace + member), the
// clocks, the refusal words, the mock hub (one piece per local day, the
// freeze switch), and the header loading none of it at first paint.
// Run: node tests/unit/hours-timer.test.mjs
import { readFileSync } from 'node:fs'
import { HOURS_TIMER_KEY, HOURS_TIMER_MOCK_FROZEN, HOURS_TIMER_MOCK_LOG, hoursTimerClock, hoursTimerMinutes, hoursTimerOwner, hoursTimerRead, hoursTimerRefusalKey, hoursTimerWrite, postHoursTimer } from '../../src/utils/hours-timer.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

function memStorage() {
  const m = new Map()
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)) },
    removeItem: (k) => { m.delete(k) },
    get size() { return m.size },
  }
}

console.log('hours-timer')
const s = memStorage()
const a = hoursTimerOwner('t1', 'HUM-1')
const b = hoursTimerOwner('t1', 'HUM-2')
ok('no row = no timer', hoursTimerRead(s, a) === null)
hoursTimerWrite(s, a, { target: 't:x', label: 'X', start: '2026-10-07T09:00:00.000Z', stopped: '' })
ok('a written row reads back (a reload)', hoursTimerRead(s, a)?.target === 't:x' && hoursTimerRead(s, a)?.start === '2026-10-07T09:00:00.000Z')
ok('another member of the workspace sees none', hoursTimerRead(s, b) === null)
ok('another workspace sees none', hoursTimerRead(s, hoursTimerOwner('t2', 'HUM-1')) === null)
ok('the header key holds it', s.getItem(HOURS_TIMER_KEY)?.includes('t:x'))
hoursTimerWrite(s, a, null)
ok('dropping the last row removes the key (the header loads nothing)', s.getItem(HOURS_TIMER_KEY) === null)
s.setItem(HOURS_TIMER_KEY, '{not json')
ok('a broken key reads as none', hoursTimerRead(s, a) === null)
s.setItem(HOURS_TIMER_KEY, JSON.stringify({ [a]: { target: 't:x', start: 'later' } }))
ok('a row without a real start is none', hoursTimerRead(s, a) === null)

ok('clock h:mm:ss', hoursTimerClock(((1 * 60 + 2) * 60 + 3) * 1000) === '1:02:03')
ok('clock never negative', hoursTimerClock(-5000) === '0:00:00')
ok('minutes h:mm', hoursTimerMinutes(90) === '1:30' && hoursTimerMinutes(5) === '0:05')

ok('409 period_frozen in words', hoursTimerRefusalKey({ status: 409, error: 'period_frozen' }) === 'hours_timer.err_frozen')
ok('400 day_cap in words', hoursTimerRefusalKey({ status: 400, error: 'day_cap' }) === 'hours_timer.err_day_cap')
ok('400 bad_timer in words', hoursTimerRefusalKey({ status: 400, error: 'bad_timer' }) === 'hours_timer.err_bad')
ok('401 = the session', hoursTimerRefusalKey({ status: 401, error: 'unauthorized' }) === 'hours_timer.err_session')
ok('off the network', hoursTimerRefusalKey({ status: 0 }) === 'hours_timer.err_network')

const en = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8'))
for (const k of ['err_frozen', 'err_day_cap', 'err_bad', 'err_session', 'err_network']) {
  ok(`en has hours_timer.${k}`, typeof en.hours_timer?.[k] === 'string' && en.hours_timer[k].length > 10)
}

/* the mock hub, as the e2e drives it */
globalThis.localStorage = memStorage()
const api = { mock: true, base: '', token: '', credentials: 'omit' }
const local = (d, h, m) => new Date(d[0], d[1] - 1, d[2], h, m)
const out = await postHoursTimer(api, { target: 't:x', start: local([2026, 10, 5], 23, 30).toISOString(), end: local([2026, 10, 6], 0, 45).toISOString() })
ok('the mock splits at local midnight', JSON.stringify(out.written) === JSON.stringify([{ day: '2026-10-05', minutes: 30 }, { day: '2026-10-06', minutes: 45 }]), JSON.stringify(out))
ok('the mock logs the interval', JSON.parse(localStorage.getItem(HOURS_TIMER_MOCK_LOG)).length === 1)
localStorage.setItem(HOURS_TIMER_MOCK_FROZEN, '1')
let refused = null
try { await postHoursTimer(api, { target: 't:x', start: local([2026, 10, 6], 9, 0).toISOString(), end: local([2026, 10, 6], 10, 0).toISOString() }) } catch (e) { refused = e }
ok('the mock freeze answers 409 period_frozen', refused?.status === 409 && refused?.error === 'period_frozen')
ok('a refused interval is not logged', JSON.parse(localStorage.getItem(HOURS_TIMER_MOCK_LOG)).length === 1)

/* 027: the header draws a plain button and loads the timer chunk lazily */
const bar = readFileSync(new URL('../../src/components/TopBar.vue', import.meta.url), 'utf8')
ok('TopBar mounts the timer as LazyHoursTimer', /<LazyHoursTimer\b/.test(bar))
ok('TopBar never imports the timer or its util', !/import[^\n]*(HoursTimer|hours-timer)/.test(bar))
ok("TopBar's inline key is the util's", bar.includes(`'${HOURS_TIMER_KEY}'`))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-timer checks passed.')
