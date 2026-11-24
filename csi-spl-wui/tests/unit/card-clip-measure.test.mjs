// A message card's clip measure, counted (perf round 20 row 05, p20-05).
//
// WHY: each card read getComputedStyle(.msg-body) for its line height and its
// scrollHeight in a sync measure() as it started observing, so a feed of N
// cards forced N style reads and N layouts in one go (editor 5: measureBox
// 113.5 ms self over 3 channel opens). The `.msg-body` line height is the same
// for every card of a feed, so it is read once per distinct `.msg-body` class
// and font-size level, and the content height is read in the ResizeObserver
// callback, after layout. The vue and card-clip code is real; the link
// previews and the viewport listener are stubbed, the DOM is plain objects.
//
// Run: node --test tests/unit/card-clip-measure.test.mjs
import { after, before, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { nextTick, reactive, ref, toRaw } from 'vue'
import { cardClipPx, cardClipStyle } from '../../src/utils/card-clip.mjs'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const CARDS = 20
const CONTENT_PX = 400
/* the .msg-body line height per font-size level (html data-font-size) */
const LINE_PX = { 3: 20, 4: 22 }

let saved
let reads
let level
let observers

before(() => {
  saved = { window: globalThis.window, document: globalThis.document, HTMLElement: globalThis.HTMLElement, getComputedStyle: globalThis.getComputedStyle, ResizeObserver: globalThis.ResizeObserver, warn: console.warn }
  /* the composable runs outside a component, so vue warns about its lifecycle hooks */
  console.warn = (...args) => { if (!/onMounted|onBeforeUnmount/.test(String(args[0]))) saved.warn(...args) }
  globalThis.window = {}
  globalThis.HTMLElement = class {}
  globalThis.document = { documentElement: { getAttribute: (name) => (name === 'data-font-size' ? String(level) : null) } }
  globalThis.getComputedStyle = (el) => {
    reads.style += 1
    return { lineHeight: `${el.linePx ?? LINE_PX[level]}px`, fontSize: '14px' }
  }
  /* a ResizeObserver whose deliveries the test makes */
  globalThis.ResizeObserver = class {
    constructor(cb) { this.cb = cb; this.targets = new Set(); observers.push(this) }
    observe(el) { this.targets.add(el) }
    unobserve(el) { this.targets.delete(el) }
    disconnect() { this.targets.clear() }
  }
})

after(() => {
  for (const k of ['window', 'document', 'HTMLElement', 'getComputedStyle', 'ResizeObserver']) globalThis[k] = saved[k]
  console.warn = saved.warn
})

beforeEach(() => {
  reads = { style: 0, scroll: 0 }
  level = 3
  observers = []
})

const load = () => importTsStubbed('src/composables/useCardHeight.ts', {
  '~/composables/useLinkPreviewRefs': { useLinkPreviewRefs: () => ref([]) },
  '~/utils/viewport-resize': { onViewportResize: () => () => {} },
})

/** One card's DOM: the clip box, its inner and the `.msg-body` in it. */
function cardDom(bodyClass = 'msg-body') {
  const body = { className: bodyClass }
  const inner = { querySelector: (sel) => (sel === '.msg-body' ? body : null), parentElement: null }
  Object.defineProperty(inner, 'scrollHeight', { get() { reads.scroll += 1; return CONTENT_PX } })
  return { box: { getBoundingClientRect: () => ({ height: 100, top: 0 }) }, inner, body }
}

/** N cards of one feed, mounted: the clip inner is set, so each starts observing. */
async function feed(mod, n, bodyClass) {
  const cards = Array.from({ length: n }, (_, i) => {
    const dom = cardDom(bodyClass)
    const props = reactive({ msg: { msg_id: `m${i}`, body: 'a long card' }, clipMode: 'rows' })
    const inner = ref(null)
    const card = mod.useCardHeight(props, ref(false), ref(dom.box), inner)
    return { dom, props, inner, card }
  })
  for (const c of cards) c.inner.value = c.dom.inner
  await settle()
  return cards
}

async function settle() {
  await nextTick()
  await nextTick()
}

/** The browser's delivery after layout: every observer, every observed target. */
async function deliver(only) {
  for (const ro of observers) {
    const entries = [...ro.targets].filter((t) => !only || only.includes(toRaw(t))).map((target) => ({ target }))
    if (entries.length) ro.cb(entries, ro)
  }
  await settle()
}

const styleFor = (linePx) => cardClipStyle(cardClipPx({ mode: 'rows', lineHeightPx: linePx, userPx: null, notesPx: 0 }))

describe('useCardHeight: the clip measure of a feed', () => {
  it(`(N) ${CARDS} cards of one feed read the .msg-body style once, not ${CARDS} times`, async () => {
    const cards = await feed(await load(), CARDS)
    await deliver()
    assert.equal(reads.style, 1, `getComputedStyle calls for ${CARDS} cards`)
    for (const { card } of cards) {
      assert.equal(card.clipped.value, true)
      assert.deepEqual(card.clipStyle.value, styleFor(LINE_PX[3]))
    }
  })

  it('(S) the content height is read in the ResizeObserver callback, after layout, not as a card starts', async () => {
    await feed(await load(), CARDS)
    assert.equal(reads.scroll, 0, 'scrollHeight reads before the observer delivered')
    assert.equal(reads.style, 0, 'getComputedStyle calls before the observer delivered')
    await deliver()
    assert.equal(reads.scroll, CARDS, 'one scrollHeight read per card, in the delivery')
  })

  it('(F) CONTROL: a card whose font changes is re-read: a new font-size level, a new .msg-body class', async () => {
    const mod = await load()
    const cards = await feed(mod, 2)
    await deliver()
    assert.deepEqual(cards[0].card.clipStyle.value, styleFor(LINE_PX[3]))

    level = 4
    let was = reads.style
    await deliver([cards[0].dom.inner])
    assert.ok(reads.style > was, 'a new font-size level reads the style again')
    assert.deepEqual(cards[0].card.clipStyle.value, styleFor(LINE_PX[4]))

    const [odd] = await feed(mod, 1, 'msg-body msg-body--odd')
    odd.dom.body.linePx = 30
    was = reads.style
    await deliver([odd.dom.inner])
    assert.ok(reads.style > was, 'another .msg-body class reads its own style')
    assert.deepEqual(odd.card.clipStyle.value, styleFor(30))
  })

  it('(E) the shared line height lives as long as the feed: once every card stops, the next feed reads again', async () => {
    const cards = await feed(await load(), 3)
    await deliver()
    for (const c of cards) c.props.clipMode = 'full'
    await settle()
    for (const c of cards) c.props.clipMode = 'rows'
    await settle()
    const was = reads.style
    await deliver()
    assert.ok(reads.style > was, 'a fresh feed reads the style again')
  })
})
