// spec 066 12.4: the RUM collector starts after load and in an idle slot,
// never on the first load's critical path.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PERF_IDLE_FALLBACK_MS, PERF_IDLE_TIMEOUT_MS, perfWhenIdle } from '../../src/utils/perf-idle.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

/* a window whose load, idle and timer callbacks fire only when the test says */
function fakeWin({ ready = 'complete', ric = true } = {}) {
  const w = { idles: [], timers: [], loads: [] }
  w.document = { readyState: ready }
  w.addEventListener = (type, fn, opts) => { if (type === 'load') w.loads.push({ fn, opts }) }
  w.setTimeout = (fn, ms) => { w.timers.push({ fn, ms }); return w.timers.length }
  if (ric) w.requestIdleCallback = (fn, opts) => { w.idles.push({ fn, opts }); return w.idles.length }
  w.load = () => { w.document.readyState = 'complete'; for (const l of w.loads.splice(0)) l.fn() }
  return w
}

describe('perfWhenIdle', () => {
  it('waits for an idle slot, with a timeout, and runs fn once', () => {
    const win = fakeWin()
    let n = 0
    perfWhenIdle(() => { n++ }, { win })
    assert.equal(n, 0, 'nothing runs synchronously')
    assert.equal(win.idles.length, 1)
    assert.equal(win.idles[0].opts.timeout, PERF_IDLE_TIMEOUT_MS)
    win.idles[0].fn()
    win.idles[0].fn()
    assert.equal(n, 1)
  })

  it('waits for the load event before asking for an idle slot', () => {
    const win = fakeWin({ ready: 'interactive' })
    let n = 0
    perfWhenIdle(() => { n++ }, { win })
    assert.equal(win.idles.length, 0, 'no idle request before load')
    assert.equal(win.loads.length, 1)
    assert.equal(win.loads[0].opts.once, true)
    win.load()
    assert.equal(win.idles.length, 1)
    assert.equal(n, 0)
    win.idles[0].fn()
    assert.equal(n, 1)
  })

  it('falls back to setTimeout where requestIdleCallback is missing', () => {
    const win = fakeWin({ ric: false })
    let n = 0
    perfWhenIdle(() => { n++ }, { win })
    assert.equal(win.timers.length, 1)
    assert.equal(win.timers[0].ms, PERF_IDLE_FALLBACK_MS)
    assert.equal(n, 0)
    win.timers[0].fn()
    assert.equal(n, 1)
  })

  it('never throws: not from fn, not from a broken window', () => {
    const win = fakeWin()
    assert.doesNotThrow(() => perfWhenIdle(() => { throw new Error('boom') }, { win }))
    assert.doesNotThrow(() => win.idles[0].fn())
    const broken = { document: { readyState: 'complete' }, requestIdleCallback: () => { throw new Error('no') } }
    assert.doesNotThrow(() => perfWhenIdle(() => {}, { win: broken }))
  })
})

describe('perf-rum plugin defers the collector', () => {
  const src = read('src/plugins/perf-rum.client.ts')
  it('imports the collector only from inside perfWhenIdle', () => {
    const at = src.indexOf("import('~/utils/perf-rum.mjs')")
    assert.ok(at > 0)
    assert.ok(src.lastIndexOf('perfWhenIdle(', at) > src.indexOf('onNuxtReady('), 'import is inside a perfWhenIdle after onNuxtReady')
  })
  it('starts the collector from a second idle slot, after the chunk ran', () => {
    assert.match(src, /perfWhenIdle\(\(\) => startPerfRum\(/)
  })
  it('keeps the collector out of the initial chunk', () => {
    assert.doesNotMatch(src, /from '~\/utils\/perf-rum\.mjs'/)
  })
})
