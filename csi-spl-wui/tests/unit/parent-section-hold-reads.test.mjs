// p20-03 (perf round 20 row 03): the topic-open hold (holdCard) reads the
// card's place only when something can have moved it, not every frame.
// Run: node tests/unit/parent-section-hold-reads.test.mjs
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import * as parentSection from '../../src/utils/parent-section.mjs'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const { landCard } = await importTsStubbed('src/utils/parent-section-open.mjs', {
  '~/stores/topic': { useTopicStore: () => ({}) },
  '~/composables/useSidePane': { useSidePane: () => ({}) },
  './live-follow.mjs': { withSessionRetry: () => {} },
  './pane-scroll.mjs': { scrollRowToTop: () => {} },
  './parent-section.mjs': { ...parentSection },
})

/* A fake page: frames run by hand, a ResizeObserver whose callbacks the test
   delivers, and boxes whose rect reads count. */
let frames
let observers
const saved = {}

function nextFrame() {
  const run = frames
  frames = []
  for (const f of run) f()
}

function box({ top = 0, height = 100, children = [] } = {}) {
  const el = {
    top,
    height,
    reads: 0,
    scrollTop: 0,
    isConnected: true,
    parentElement: null,
    children,
    listeners: {},
    pending: false,
    getBoundingClientRect() {
      el.reads++
      const t = el.top - (el.scrolls ? el.scrolls.scrollTop : 0)
      return { top: t, bottom: t + el.height }
    },
    addEventListener(t, f) { (el.listeners[t] ??= new Set()).add(f) },
    removeEventListener(t, f) { el.listeners[t]?.delete(f) },
    fire(t) { for (const f of [...(el.listeners[t] || [])]) f() },
    querySelector() { return el.pending ? {} : null },
  }
  for (const c of children) c.parentElement = el
  return el
}

/* scroller (top 0, 600 high) > list > card at 1000; the card lands at the top */
function page({ cardTop = 1000 } = {}) {
  const card = box({ top: cardTop, height: 80 })
  const list = box({ height: 2000, children: [card] })
  const scroller = box({ top: 0, height: 600, children: [list] })
  card.scrolls = scroller
  scroller.paddingBottom = '0px'
  return { card, list, scroller }
}

beforeEach(() => {
  frames = []
  observers = []
  for (const k of ['requestAnimationFrame', 'ResizeObserver', 'getComputedStyle']) saved[k] = globalThis[k]
  globalThis.requestAnimationFrame = (f) => frames.push(f)
  globalThis.getComputedStyle = (el) => ({ paddingBottom: el.paddingBottom || '0px' })
  globalThis.ResizeObserver = class {
    constructor(cb) { this.cb = cb; this.targets = new Set(); observers.push(this) }
    observe(el) { this.targets.add(el) }
    disconnect() { this.targets.clear() }
  }
})

afterEach(() => {
  for (const [k, v] of Object.entries(saved)) globalThis[k] = v
})

/* the observer's delivery after a frame's layout (the first one is the initial size) */
function layout() {
  for (const o of observers) if (o.targets.size) o.cb([...o.targets].map((target) => ({ target })))
}

describe('holdCard: a still card is read at most twice', () => {
  it('lands, then reads once after the first layout, then counts frames without a read', () => {
    const { card, scroller } = page()
    landCard(card, scroller, false)
    assert.equal(scroller.scrollTop, 1000, 'landed at the top')
    const landing = card.reads
    for (let i = 0; i < 30; i++) {
      nextFrame()
      if (i === 0) layout()
    }
    assert.ok(card.reads - landing <= 2, `the hold read the card ${card.reads - landing} times`)
    assert.equal(frames.length, 0, 'the hold let go once the card kept its place')
    assert.equal(observers[0].targets.size, 0, 'the observer is disconnected')
  })

  it('observes the scroller, its list and the card', () => {
    const { card, list, scroller } = page()
    landCard(card, scroller, false)
    assert.deepEqual([...observers[0].targets].sort((a, b) => a.height - b.height), [card, scroller, list])
  })
})

describe('holdCard: the same end condition and cap', () => {
  it('a size change above the card re-lands it in the observer callback, before the paint', () => {
    const { card, scroller } = page()
    landCard(card, scroller, false)
    nextFrame()
    layout()
    for (let i = 0; i < 5; i++) nextFrame()
    card.top += 300
    layout()
    assert.equal(scroller.scrollTop, 1300, 'the card is back at the top')
    nextFrame()
    assert.ok(frames.length, 'still holding')
  })

  it('reads every frame while a cause the observer cannot see is pending', () => {
    const { card, scroller } = page()
    landCard(card, scroller, false)
    scroller.pending = true
    const before = card.reads
    for (let i = 0; i < 5; i++) nextFrame()
    assert.equal(card.reads - before, 10, 'apply + place, each frame')
    scroller.pending = false
    const quiet = card.reads
    for (let i = 0; i < 5; i++) nextFrame()
    assert.equal(card.reads, quiet, 'no read once nothing is pending')
  })

  it('a script scroll is read the frame after', () => {
    const { card, scroller } = page()
    landCard(card, scroller, false)
    nextFrame()
    scroller.scrollTop = 900
    scroller.fire('scroll')
    nextFrame()
    assert.equal(scroller.scrollTop, 1000, 'put back')
  })

  it('a card that never keeps its place is let go at the cap', () => {
    const { card, scroller } = page()
    landCard(card, scroller, false)
    scroller.pending = true
    /* each read finds it a pixel further than the read before did: never still */
    const read = card.getBoundingClientRect
    let n = 0
    card.getBoundingClientRect = () => { card.top += ++n; return read() }
    const now = Date.now
    const t0 = now()
    let t = t0
    Date.now = () => t
    try {
      while (frames.length && t - t0 < 5000) {
        t += 16
        nextFrame()
      }
    } finally {
      Date.now = now
    }
    assert.equal(frames.length, 0, 'let go')
    assert.ok(t - t0 > 2000 && t - t0 <= 2032, `held ${t - t0} ms, the cap is 2000`)
  })

  it('the reader\'s own input lets go at once', () => {
    const { card, scroller } = page()
    landCard(card, scroller, false)
    scroller.fire('wheel')
    nextFrame()
    assert.equal(frames.length, 0)
    assert.equal(observers[0].targets.size, 0)
  })

  it('no ResizeObserver: reads every frame, as before', () => {
    globalThis.ResizeObserver = undefined
    const { card, scroller } = page()
    landCard(card, scroller, false)
    const before = card.reads
    for (let i = 0; i < 5; i++) nextFrame()
    assert.equal(card.reads - before, 10)
  })
})
