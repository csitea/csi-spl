// useCardSwipe's rules, run for real (r54-10): the only test naming the
// composable beyond the source readers stubs its buzz, so nothing held what a
// swipe lock stops, what a menu commit closes, or who owns a right swipe from
// the shell's Back zone. createSwipe is stubbed to capture the options the
// composable hands it; each pin calls the one option a real gesture would.
//
// Run: node --test tests/unit/card-swipe-commit.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

let mod
let realWarn
let options
let inBackZone = false

before(async () => {
  realWarn = console.warn
  /* the composable runs outside a component, so vue warns about its unmount hook */
  console.warn = (...args) => { if (!String(args[0]).includes('onBeforeUnmount')) realWarn(...args) }
  mod = await importTsStubbed('src/composables/useCardSwipe.ts', {
    '~/utils/touch-ui': { createLongPress: () => ({ cancel: () => {} }) },
    '~/utils/swipe-archive.mjs': {
      SWIPE_SETTLE_MS: 200,
      createSwipe: (opts) => { options = opts; return { down: () => {}, cancel: () => {} } },
      swipeInBackZone: () => inBackZone,
      swipeLeftAction: () => null,
    },
    '~/utils/reselect-row.mjs': { paneOfRow: () => 'topic' },
    '~/utils/undo-timer': { isTouchUi: () => true },
    '~/composables/useHiddenCards': { useHiddenCards: () => ({ hide: () => {} }) },
    '~/composables/useMobileStack': {
      useMobileStack: () => ({ isMobile: ref(true), level: ref(2), swipe: { claim: () => {} } }),
    },
    '~/stores/live': { useLiveFeed: () => ({}) },
    '~/stores/topic': { useTopicStore: () => ({}) },
  })
})

after(() => {
  console.warn = realWarn
})

/** A phone card one level deep, wired as MessageCard wires it. */
function card() {
  const pickerOpen = ref(true)
  const opened = []
  let stops = 0
  const menu = { openAt: (x, y) => { opened.push([x, y]) }, close: () => {} }
  const peer = { stop: () => { stops += 1 }, archive: async () => true }
  const swipe = mod.useCardSwipe({ props: { msg: { msg_id: 'm-1' } }, rowEl: ref(null), swipeLeft: ref('archive'), pickerOpen }, menu, peer)
  return { swipe, pickerOpen, opened, stops: () => stops }
}

describe('useCardSwipe', () => {
  it('(L) a swipe lock stops the card\'s other gestures', () => {
    const { swipe, stops } = card()
    assert.equal(stops(), 0)
    options.onLock('menu')
    assert.equal(stops(), 1)
    assert.equal(swipe.swipeDir.value, 'menu')
  })

  it('(M) a menu commit closes the picker and opens the menu at the finger', () => {
    const { pickerOpen, opened } = card()
    options.onCommit('menu', 10, 20)
    assert.equal(pickerOpen.value, false)
    assert.deepEqual(opened, [[10, 20]])
  })

  it('(B) the shell\'s Back zone refuses a right swipe', () => {
    card()
    inBackZone = true
    assert.equal(options.canRight(5), false)
    inBackZone = false
    assert.equal(options.canRight(5), true)
  })
})
