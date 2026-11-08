// useCardSwipeFlags's rules, run for real (r54-09): the only test naming the
// composable is the clean-code gate, so nothing held when a card swipes, which
// reply a left swipe hides, or when the topic view's left swipe archives.
// The composable runs outside a component, so onMounted never fires; each pin
// sets the returned inTopicPane as that hook would.
//
// Run: node --test tests/unit/card-swipe-flags.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'
import { swipeLeftAction } from '../../src/utils/swipe-archive.mjs'

let mod
let realWarn

before(async () => {
  realWarn = console.warn
  /* the composable runs outside a component, so vue warns about its mount hook */
  console.warn = (...args) => { if (!String(args[0]).includes('onMounted')) realWarn(...args) }
  mod = await importTsStubbed('src/composables/useCardSwipe.ts', {
    '~/utils/touch-ui': { createLongPress: () => ({ cancel: () => {} }) },
    '~/utils/swipe-archive.mjs': {
      SWIPE_SETTLE_MS: 200,
      createSwipe: () => ({ down: () => {}, cancel: () => {} }),
      swipeInBackZone: () => false,
      swipeLeftAction,
    },
    '~/utils/reselect-row.mjs': { paneOfRow: () => 'topic' },
    '~/utils/undo-timer': { isTouchUi: () => true },
    '~/composables/useHiddenCards': { useHiddenCards: () => ({ hide: () => {} }) },
    '~/composables/useMobileStack': {
      useMobileStack: () => ({ isMobile: ref(true), swipe: { claim: () => {} } }),
    },
    '~/stores/live': { useLiveFeed: () => ({}) },
    '~/stores/topic': { useTopicStore: () => ({}) },
  })
})

after(() => {
  console.warn = realWarn
})

/** A phone card in the topic view, wired as MessageCard wires it. */
function card({ msg = {}, mayArchive = false } = {}) {
  const editing = ref(false)
  const props = { msg: { msg_id: 'm-1', is_parent: 0, ...msg } }
  const flags = mod.useCardSwipeFlags(props, { editing, rowEl: ref(null), inPane: ref(false), showTopicArchive: ref(false) }, () => mayArchive)
  flags.inTopicPane.value = true
  return { editing, flags }
}

describe('useCardSwipeFlags', () => {
  it('(E) a card being edited does not swipe', () => {
    const { editing, flags } = card()
    assert.equal(flags.swipeOn.value, true)
    editing.value = true
    assert.equal(flags.swipeOn.value, false)
  })

  it('(P) a sent reply swipes left to hide, a pending one does not', () => {
    assert.equal(card().flags.swipeLeft.value, 'hide')
    assert.equal(card({ msg: { pending: true } }).flags.swipeLeft.value, null)
  })

  it('(A) in the topic view a left swipe archives only where the viewer may archive', () => {
    assert.equal(card({ mayArchive: true }).flags.swipeArchive.value, true)
    assert.equal(card({ mayArchive: false }).flags.swipeArchive.value, false)
  })
})
