// Spec 107 T012: the active-tab minute recorder with a fake clock, window and
// document: no input -> no minute, hidden or unfocused -> no minute, one row
// per minute with the target of the address, the flush moments (5 min,
// hidden, pagehide with keepalive), the off switch drops the buffer, a
// network failure keeps the minutes, a refusal does not, batches of <= 60,
// and the recorder kept out of the initial chunk.
// Run: node tests/unit/hours-recorder.test.mjs
import { readFileSync } from 'node:fs'
import { BATCH_MAX, BUFFER_MAX, FLUSH_MS, HOURS_MINUTES_MOCK_LOG, MINUTE_MS, TICK_MS, createHoursRecorder, hoursTargetOf, mockSendHoursMinutes } from '../../src/utils/hours-recorder.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

function target() {
  const ls = new Map()
  const on = (m) => (ev, fn) => { if (!m.has(ev)) m.set(ev, new Set()); m.get(ev).add(fn) }
  const off = (m) => (ev, fn) => { m.get(ev)?.delete(fn) }
  return { ls, addEventListener: on(ls), removeEventListener: off(ls), fire: (ev) => { for (const fn of [...(ls.get(ev) || [])]) fn() } }
}

/** a recorder on a fake clock; `sent` keeps every batch with its keepalive */
function rig({ fail, tz = () => 'Europe/Helsinki', clearTimer = () => {} } = {}) {
  const T0 = Date.UTC(2026, 9, 12, 9, 0, 5)
  const s = { t: T0, visible: true, focus: true, on: true, path: '/channel/general', search: '', sent: [], timers: [] }
  const win = target()
  const doc = Object.defineProperties(target(), {
    visibilityState: { get: () => (s.visible ? 'visible' : 'hidden') },
    hasFocus: { value: () => s.focus },
  })
  const rec = createHoursRecorder({
    win, doc,
    now: () => s.t,
    target: () => hoursTargetOf(s.path, s.search),
    enabled: () => s.on,
    tz,
    send: async (body, opts) => {
      if (fail) throw fail
      s.sent.push({ ...body, keepalive: opts.keepalive })
    },
    setTimer: (fn, ms) => { s.timers.push({ fn, ms }); return s.timers.length },
    clearTimer,
  })
  const input = (ev = 'keydown') => win.fire(ev)
  const advance = (ms) => {
    for (let left = ms; left > 0; left -= TICK_MS) {
      s.t += Math.min(TICK_MS, left)
      for (const x of s.timers) x.fn()
    }
  }
  const settle = () => new Promise((r) => setTimeout(r, 0))
  const rows = () => s.sent.flatMap((b) => b.minutes)
  return { s, rec, win, doc, input, advance, settle, rows }
}

console.log('hours-recorder: the target from the address')
ok('a channel', hoursTargetOf('/channel/general') === 'ch:general')
ok('a channel behind a locale prefix', hoursTargetOf('/de/channel/ops') === 'ch:ops')
ok('the lobby', hoursTargetOf('/lobby') === 'ch:lobby')
ok('an open topic (?topic=) wins over the channel', hoursTargetOf('/channel/general', '?topic=task-a') === 't:task-a')
ok('a topic page', hoursTargetOf('/t/task-b') === 't:task-b')
ok('a DM, decoded', hoursTargetOf('/dm/HUM%2D7') === 'dm:HUM-7')
ok('anything else is the workspace', hoursTargetOf('/calendar') === 'ws' && hoursTargetOf('') === 'ws')

console.log('hours-recorder: what counts')
{
  const r = rig()
  r.advance(5 * MINUTE_MS)
  ok('no input: no minute', r.rec.pending().length === 0, JSON.stringify(r.rec.pending()))
}
{
  const r = rig()
  r.s.visible = false
  r.input()
  r.advance(MINUTE_MS)
  ok('hidden: no minute', r.rec.pending().length === 0)
}
{
  const r = rig()
  r.s.focus = false
  r.input('pointerdown')
  r.advance(MINUTE_MS)
  ok('visible but unfocused (a second monitor): no minute', r.rec.pending().length === 0)
}
{
  const r = rig()
  r.input()
  ok('input in a visible focused tab counts this minute', r.rec.pending().length === 1 && r.rec.pending()[0].target === 'ch:general', JSON.stringify(r.rec.pending()))
  r.input('wheel')
  r.input('scroll')
  ok('more input in the same minute is still one minute', r.rec.pending().length === 1)
  r.advance(60_000)
  ok('reading up to 60 s after the input counts the next minute too', r.rec.pending().length === 2)
  r.advance(2 * MINUTE_MS)
  ok('no input for over 60 s: counting stops', r.rec.pending().length === 2, JSON.stringify(r.rec.pending()))
  r.s.path = '/dm/HUM-7'
  r.input('touchstart')
  const p = r.rec.pending()
  ok('a minute takes the target open at that minute', p.length === 3 && p[2].target === 'dm:HUM-7' && p[0].target === 'ch:general', JSON.stringify(p))
  ok('rows are whole UTC minutes', p.every((m) => /T\d\d:\d\d:00\.000Z$/.test(m.at)))
}

console.log('hours-recorder: the flush moments')
{
  const r = rig()
  r.input()
  r.advance(FLUSH_MS - TICK_MS)
  await r.settle()
  ok('nothing is sent before 5 min', r.s.sent.length === 0)
  r.input()
  r.advance(TICK_MS)
  await r.settle()
  ok('the 5-min flush sends the buffer, tz with it, not keepalive', r.s.sent.length === 1 && r.s.sent[0].tz === 'Europe/Helsinki' && r.s.sent[0].keepalive === false && r.rows().length >= 2, JSON.stringify(r.s.sent))
  ok('the buffer is empty after it', r.rec.pending().length === 0)
  r.input()
  ok('a minute already sent is never counted again', r.rec.pending().length === 0)
}
{
  const r = rig()
  r.input()
  r.s.visible = false
  r.doc.fire('visibilitychange')
  await r.settle()
  ok('hidden flushes at once, with keepalive', r.s.sent.length === 1 && r.s.sent[0].keepalive === true)
}
{
  const r = rig()
  r.input()
  r.win.fire('pagehide')
  await r.settle()
  ok('pagehide flushes with keepalive', r.s.sent.length === 1 && r.s.sent[0].keepalive === true && r.rows().length === 1)
}
{
  const r = rig()
  for (let i = 0; i < BATCH_MAX + 5; i++) { r.input(); r.s.t += MINUTE_MS }
  await r.rec.flush()
  ok('over 60 minutes go out as batches of <= 60', r.s.sent.length === 2 && r.s.sent[0].minutes.length === BATCH_MAX && r.rows().length === BATCH_MAX + 5, String(r.s.sent.map((b) => b.minutes.length)))
}

{
  const r = rig({ tz: () => '' })
  r.input()
  await r.rec.flush()
  ok('no time zone from the browser: the batch says UTC', r.s.sent.length === 1 && r.s.sent[0].tz === 'UTC', JSON.stringify(r.s.sent))
}
{
  const r = rig()
  const first = Math.floor(r.s.t / MINUTE_MS) * MINUTE_MS
  for (let i = 0; i < BUFFER_MAX + 3; i++) { r.input(); r.s.t += MINUTE_MS }
  const p = r.rec.pending()
  ok('a long run without a flush keeps at most BUFFER_MAX minutes, the oldest dropped first', r.s.sent.length === 0 && p.length === BUFFER_MAX && p[0].at === new Date(first + 3 * MINUTE_MS).toISOString(), `${p.length} ${p[0]?.at}`)
}

console.log('hours-recorder: the switch and failures')
{
  const r = rig()
  r.input()
  r.s.on = false
  r.win.fire('pagehide')
  await r.settle()
  ok('CONTROL: "Count my reading time" off drops the buffer, nothing is sent', r.s.sent.length === 0 && r.rec.pending().length === 0)
  r.s.t += MINUTE_MS
  r.input()
  ok('off: input counts nothing', r.rec.pending().length === 0)
  r.s.on = true
  r.input()
  ok('back on: the minute counts again', r.rec.pending().length === 1)
}
{
  const r = rig({ fail: Object.assign(new Error('network'), { status: 0 }) })
  r.input()
  await r.rec.flush()
  ok('off the network: the minutes stay for the next flush', r.rec.pending().length === 1)
}
{
  const r = rig({ fail: Object.assign(new Error('frozen'), { status: 409 }) })
  r.input()
  await r.rec.flush()
  ok('a refusal (409 period_frozen) drops them', r.rec.pending().length === 0)
}
{
  const r = rig()
  r.input()
  r.rec.stop()
  r.s.t += MINUTE_MS
  r.input()
  ok('stop: listeners gone, buffer empty', r.rec.pending().length === 0 && [...r.win.ls.values()].every((x) => x.size === 0))
}
{
  const cleared = []
  const r = rig({ clearTimer: (id) => cleared.push(id) })
  r.rec.stop()
  ok('stop: clears the timer setTimer gave it', r.s.timers.length === 1 && cleared.length === 1 && cleared[0] === 1, JSON.stringify(cleared))
}

console.log('hours-recorder: the mock hub')
{
  const m = new Map()
  const st = { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) }
  mockSendHoursMinutes(st, { tz: 'UTC', minutes: [{ at: '2026-10-12T09:00:00.000Z', target: 'ws' }] })
  mockSendHoursMinutes(st, { tz: 'UTC', minutes: [{ at: '2026-10-12T09:01:00.000Z', target: 'ws' }] })
  const log = JSON.parse(m.get(HOURS_MINUTES_MOCK_LOG))
  ok('the mock keeps every batch in localStorage', log.length === 2 && log[1].minutes[0].at.endsWith('09:01:00.000Z'))
}

console.log('hours-recorder: out of the initial chunk')
{
  const src = (p) => readFileSync(new URL(p, import.meta.url), 'utf8')
  const boot = src('../../src/utils/read-sync-boot.ts')
  ok('read-sync-boot pulls the recorder boot in with a dynamic import', /import\(\s*['"]~\/utils\/hours-recorder-boot['"]\s*\)/.test(boot))
  ok('no static import of the recorder in read-sync-boot', !/^import .*hours-recorder/m.test(boot))
  const suite = runsInUnitSuite(import.meta.url)
  ok('pnpm test runs this suite', suite.ok, suite.why)
}

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-recorder checks passed.')
