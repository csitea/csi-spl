// spec 066 L5: the real-user timing collector is fire-and-forget (section 4.0).
import { describe, it, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  PERF_BATCH_MAX, PERF_BUFFER_MAX, PERF_FAIL_STOP, PERF_FLUSH_MS, PERF_HOUR_CAP, PERF_SEND_TIMEOUT_MS,
  createPerfCollector, perfMark, perfRumReset, perfSample, startPerfRum,
} from '../../src/utils/perf-rum.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const SID = '0f1e2d3c-4b5a-4987-8765-43210fedcba9'
const WIRE = new Set(['session_id', 'metric', 'value_ms', 'ratio', 'device', 'view', 'cache', 'outcome', 'build', 'net', 'clock_err_ms', 'hidden_s'])

/* a manual clock: timers fire only when the test advances it */
function clock() {
  let t = 0
  let seq = 0
  const timers = new Map()
  return {
    now: () => t,
    setTimer: (fn, ms) => { const id = ++seq; timers.set(id, { at: t + ms, fn }); return id },
    clearTimer: (id) => { timers.delete(id) },
    advance(ms) {
      t += ms
      for (const [id, x] of [...timers].sort((a, b) => a[1].at - b[1].at)) {
        if (x.at <= t && timers.has(id)) { timers.delete(id); x.fn() }
      }
    },
    pending: () => timers.size,
  }
}

function collector(send, extra = {}) {
  const c = clock()
  const sent = []
  const col = createPerfCollector({
    send: (body, signal) => { sent.push(JSON.parse(body)); return send(body, signal) },
    sessionId: SID, device: () => 'desktop', net: () => '', build: 'v1.3.7',
    now: c.now, wallNow: c.now, setTimer: c.setTimer, clearTimer: c.clearTimer, idle: () => {},
    ...extra,
  })
  return { col, c, sent }
}
const ok = () => Promise.resolve({ ok: true, status: 204 })
const fill = (col, n) => { for (let i = 0; i < n; i++) col.mark('switch_view', 100 + (i % 1000), { view: 'topic' }) }
/* n samples valued 0..n-1, rolling the hour so the 300 / hour cap does not bite */
const many = (col, c, n) => { for (let i = 0; i < n; i++) { if (i && i % PERF_HOUR_CAP === 0) c.advance(3_600_000); col.mark('send_ack', i) } }

afterEach(() => perfRumReset())

describe('perfMark: never throws, returns synchronously', () => {
  it('RUM off (no collector): false, at once', () => {
    assert.equal(perfMark('send_ack', 120), false)
  })
  it('a broken collector, a bad metric or junk arguments never throw', () => {
    const { col } = collector(ok, { device: () => { throw new Error('boom') } })
    assert.doesNotThrow(() => col.mark('send_ack', 1))
    for (const args of [[], [null], ['nope', 5], ['send_ack', NaN], ['send_ack', -1], ['send_ack', 1, 'x'], [{}, {}, {}]]) {
      assert.doesNotThrow(() => perfMark(...args))
      assert.equal(typeof perfMark(...args), 'boolean')
    }
  })
  it('the return is a boolean, never a promise', () => {
    const { col } = collector(() => new Promise(() => {}))
    const r = col.mark('send_ack', 80)
    assert.equal(r, true)
    assert.equal(typeof r, 'boolean')
  })
})

describe('sender failures drop the batch, no retry', () => {
  for (const [name, send] of [
    ['rejecting', () => Promise.reject(new Error('net'))],
    ['500', () => Promise.resolve({ ok: false, status: 500 })],
    ['throwing synchronously', () => { throw new Error('sync') }],
  ]) {
    it(`a ${name} sender: batch dropped, counted, never resent`, async () => {
      const { col, sent } = collector(send)
      fill(col, 3)
      assert.equal(await col.flush(), false)
      assert.equal(col.state().buffered, 0)
      assert.equal(col.state().dropped, 3)
      assert.equal(await col.flush(), false) // only the drop count goes out: no samples resent
      assert.equal(sent.length, 2)
      assert.equal(sent[1].samples.length, 0)
      assert.equal(sent[1].dropped, 3)
    })
  }
  it('a hanging sender is aborted after 5 s and its batch dropped', async () => {
    let signal = null
    const { col, c } = collector((_b, s) => { signal = s; return new Promise(() => {}) })
    fill(col, 2)
    const p = col.flush()
    c.advance(PERF_SEND_TIMEOUT_MS - 1)
    assert.equal(signal.aborted, false)
    c.advance(1)
    assert.equal(await p, false)
    assert.equal(signal.aborted, true)
    assert.equal(col.state().dropped, 2)
  })
  it('one send at a time: a flush while one is in flight sends nothing', async () => {
    let release
    const { col, sent } = collector(() => new Promise((r) => { release = r }))
    fill(col, 2)
    const p = col.flush()
    fill(col, 2)
    assert.equal(await col.flush(), false)
    assert.equal(sent.length, 1)
    release({ ok: true, status: 204 })
    assert.equal(await p, true)
  })
  it(`${PERF_FAIL_STOP} failures in a row stop the tab`, async () => {
    const { col, c, sent } = collector(() => Promise.reject(new Error('down')))
    for (let i = 0; i < PERF_FAIL_STOP; i++) { fill(col, 1); await col.flush() }
    assert.equal(col.state().stopped, true)
    assert.equal(col.mark('send_ack', 10), false)
    assert.equal(await col.flush(), false)
    assert.equal(sent.length, PERF_FAIL_STOP)
    assert.equal(c.pending(), 0, 'no timer left running')
  })
  it('CONTROL: a success between failures resets the count', async () => {
    let n = 0
    const { col } = collector(() => (++n === 2 ? ok() : Promise.reject(new Error('x'))))
    for (let i = 0; i < 4; i++) { fill(col, 1); await col.flush() }
    assert.equal(col.state().stopped, false)
  })
})

describe('caps', () => {
  it(`the buffer keeps ${PERF_BUFFER_MAX}: the oldest go and are counted in the next batch`, async () => {
    const { col, c, sent } = collector(ok, { ready: () => false })
    many(col, c, PERF_BUFFER_MAX + 7)
    assert.equal(col.state().buffered, PERF_BUFFER_MAX)
    assert.equal(col.state().dropped, 7)
    col.final() // not ready: nothing leaves
    assert.equal(sent.length, 0)
  })
  it('the oldest is what goes', async () => {
    let up = false
    const { col, c, sent } = collector(ok, { ready: () => up })
    many(col, c, PERF_BUFFER_MAX + 1)
    up = true
    await col.flush()
    assert.equal(sent[0].samples[0].value_ms, 1)
    assert.equal(sent[0].dropped, 1)
    assert.equal(col.state().dropped, 0)
  })
  it(`${PERF_HOUR_CAP} samples per tab per hour, then a new hour`, () => {
    const { col, c } = collector(ok)
    let kept = 0
    for (let i = 0; i < PERF_HOUR_CAP + 20; i++) if (col.mark('send_ack', 5)) kept++
    assert.equal(kept, PERF_HOUR_CAP)
    assert.equal(col.state().capped, 20)
    c.advance(3_600_000)
    assert.equal(col.mark('send_ack', 5), true)
  })
  it(`a batch carries at most ${PERF_BATCH_MAX}; ${PERF_BATCH_MAX} buffered asks for an idle flush`, async () => {
    let idled = 0
    const { col, sent } = collector(ok, { idle: () => { idled++ } })
    fill(col, PERF_BATCH_MAX - 1)
    assert.equal(idled, 0)
    fill(col, 1)
    assert.equal(idled, 1)
    fill(col, 10)
    assert.equal(idled, 1, 'one idle flush queued, not one per mark')
    await col.flush()
    assert.equal(sent[0].samples.length, PERF_BATCH_MAX)
  })
  it(`flushes every ${PERF_FLUSH_MS / 1000} s`, async () => {
    const { col, c, sent } = collector(ok)
    fill(col, 1)
    c.advance(PERF_FLUSH_MS)
    await Promise.resolve()
    assert.equal(sent.length, 1)
  })
})

describe('pagehide beacon', () => {
  it('the rest goes in beacons of at most one batch each', () => {
    const beacons = []
    const { col } = collector(ok, { beacon: (b) => { beacons.push(JSON.parse(b)); return true } })
    fill(col, PERF_BATCH_MAX + 3)
    col.final()
    assert.deepEqual(beacons.map((b) => b.samples.length), [PERF_BATCH_MAX, 3])
    assert.equal(col.state().buffered, 0)
  })
  it('startPerfRum wires pagehide and hidden to the beacon', () => {
    const on = {}
    const beacons = []
    const doc = { visibilityState: 'visible', addEventListener: (ev, fn) => { on[`doc:${ev}`] = fn } }
    const win = {
      document: doc,
      navigator: { sendBeacon: (url, body) => { beacons.push({ url, body: JSON.parse(body) }); return true } },
      addEventListener: (ev, fn) => { on[ev] = fn },
    }
    const c = startPerfRum({ url: 'https://api.example.com/v1/perf/samples', build: 'v1.3.7', win })
    assert.ok(c)
    assert.equal(perfMark('load_rail', 900, { cache: 'cold' }), true)
    on.pagehide()
    assert.equal(beacons.length, 1)
    assert.equal(beacons[0].url, 'https://api.example.com/v1/perf/samples')
    assert.equal(beacons[0].body.samples[0].metric, 'load_rail')
    perfMark('send_ack', 40)
    doc.visibilityState = 'hidden'
    on['doc:visibilitychange']()
    assert.equal(beacons.length, 2)
  })
  it('a throwing sendBeacon is swallowed', () => {
    const win = { navigator: { sendBeacon: () => { throw new Error('quota') } }, addEventListener: (_e, fn) => { win.hide = fn } }
    startPerfRum({ url: 'https://api.example.com/v1/perf/samples', win })
    perfMark('send_ack', 1)
    assert.doesNotThrow(() => win.hide())
  })
  it('sampleRate 0 or a non-http url: no collector', () => {
    const win = { addEventListener: () => {} }
    assert.equal(startPerfRum({ url: 'https://h/v1/perf/samples', sampleRate: '0', win }), null)
    assert.equal(startPerfRum({ url: '/v1/perf/samples', win }), null)
    assert.equal(startPerfRum({ url: 'https://h/v1/perf/samples', sampleRate: 0.5, random: () => 0.7, win }), null)
  })
})

describe('no personal data (spec 4.2)', () => {
  const ctx = { sessionId: SID, device: 'phone', net: '4g', build: 'v1.3.7' }
  it('only the wire fields leave the page, whatever the caller passes', () => {
    const s = perfSample('switch_view', 210.6, {
      view: 'channel', user_id: 'HUM-1', email: 'a@example.com', url: 'https://x/t/1', msg_id: 'm1', text: 'hi', tenant_id: 't1', at: 'now', topic: 'T',
    }, ctx)
    assert.deepEqual(Object.keys(s).filter((k) => !WIRE.has(k)), [])
    assert.deepEqual(s, { session_id: SID, metric: 'switch_view', value_ms: 211, device: 'phone', outcome: 'ok', build: 'v1.3.7', view: 'channel', net: '4g' })
  })
  it('an id or text in an enum slot drops the sample', () => {
    assert.equal(perfSample('switch_view', 1, { view: 'topic:3ac11098' }, ctx), null)
    assert.equal(perfSample('send_ack', 1, { outcome: 'hello there' }, ctx), null)
    assert.equal(perfSample('reconnect_live', 1, { hiddenS: 'a@b' }, ctx), null)
    assert.equal(perfSample('load_rail', 1, { cache: 'HUM-1' }, ctx), null)
    assert.equal(perfSample('scroll_jank', 1, { ratio: 2 }, ctx), null)
    assert.equal(perfSample('send_ack', 600_001, {}, ctx), null)
  })
  it('a build that is not a version token is sent empty; the session id is a uuid', async () => {
    const { col, sent } = collector(ok, { build: 'HUM-1 <a@b>', sessionId: 'not-a-uuid' })
    col.mark('send_ack', 3)
    await col.flush()
    assert.equal(sent[0].samples[0].build, '')
    assert.match(sent[0].samples[0].session_id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    assert.notEqual(sent[0].samples[0].session_id, 'not-a-uuid')
    assert.deepEqual(Object.keys(sent[0]).sort(), ['dropped', 'samples'])
  })
})

describe('hub clock (M4)', () => {
  it('a 202 hub_ms gives the offset; the lowest round trip wins', async () => {
    let t = 1000
    const resp = (hub) => ({ ok: true, status: 202, json: () => Promise.resolve({ hub_ms: hub }) })
    const sends = [() => { t += 100; return resp(5000) }, () => { t += 20; return resp(6000) }, () => { t += 300; return resp(1) }]
    const col = createPerfCollector({ send: () => Promise.resolve(sends.shift()()), sessionId: SID, now: () => t, wallNow: () => t, setTimer: () => 0, clearTimer: () => {}, idle: () => {} })
    for (let i = 0; i < 3; i++) { col.mark('send_ack', 1); await col.flush(); await new Promise((r) => setImmediate(r)) }
    assert.deepEqual(col.clock(), { offsetMs: 6000 - 1110, errMs: 10 })
  })
})

describe('wiring', () => {
  const src = read('src/utils/perf-rum.mjs')
  const plugin = read('src/plugins/perf-rum.client.ts')
  it('perf-rum.mjs imports no Vue or Nuxt', () => {
    assert.doesNotMatch(src, /from ['"](vue|#app|#imports|nuxt|pinia)/)
  })
  it('the plugin loads the collector lazily after onNuxtReady, only with perfRum on', () => {
    assert.doesNotMatch(plugin, /^import .*perf-rum\.mjs/m, 'no static import: it would land in the initial chunk')
    assert.match(plugin, /onNuxtReady\(/)
    assert.match(plugin, /import\('~\/utils\/perf-rum\.mjs'\)/)
    assert.match(plugin, /pub\.perfRum\) !== '1'\) return/)
    assert.match(plugin, /\.catch\(/)
    assert.ok(plugin.indexOf('onNuxtReady(') < plugin.indexOf("import('~/utils/perf-rum.mjs')"))
  })
})
