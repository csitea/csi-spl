// useCardTouchLift's rules, run for real (r54-08): the only tests naming the
// composable read its source, so nothing held when a card lifts, what a lift
// stops, or what a hold released in place opens. createHandleDrag is stubbed
// to capture its options; each pin calls those callbacks as a finger would.
//
// Run: node --test tests/unit/card-touch-lift.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const SLOP_PX = 10

let drag
let mod
let realDocument
let realWarn

before(async () => {
  realDocument = globalThis.document
  realWarn = console.warn
  /* the composable runs outside a component, so vue warns about its unmount hook */
  console.warn = (...args) => { if (!String(args[0]).includes('onBeforeUnmount')) realWarn(...args) }
  globalThis.document = { scrollingElement: null }
  mod = await importTsStubbed('src/composables/useCardTouchLift.ts', {
    '~/utils/touch-ui': { LONG_PRESS_MS: 500, LONG_PRESS_SLOP_PX: SLOP_PX },
    '~/utils/move-drag': {
      createEdgeScroll: () => ({ at: () => {}, stop: () => {} }),
      createHandleDrag: (options) => {
        drag = options
        return { state: 'idle', cancel: () => {}, takeClick: () => false }
      },
    },
    '~/composables/useMobileStack': {
      useMobileStack: () => ({ isMobile: ref(true), swipe: { claim: () => {} } }),
    },
    '~/composables/useCardSwipe': { buzz: () => {} },
  })
})

after(() => {
  globalThis.document = realDocument
  console.warn = realWarn
})

/** A phone card the viewer may move, wired as MessageCard wires it. */
function card() {
  const seen = { stops: 0, menuAt: [] }
  const editing = ref(false)
  const rowEl = ref({ parentElement: null, focus: () => {}, addEventListener: () => {}, removeEventListener: () => {} })
  const mv = {
    flags: { move: { track: () => {}, land: () => {} }, canMoveTopic: ref(true) },
    endDrag: () => {},
    liftCard: () => {},
  }
  const menu = { close: () => {}, openAt: (x, y) => seen.menuAt.push([x, y]) }
  const stopOthers = () => { seen.stops += 1 }
  const { touchLift } = mod.useCardTouchLift({ rowEl, editing, pickerOpen: ref(true) }, mv, stopOthers, menu)
  return { seen, editing, touchLift }
}

describe('useCardTouchLift', () => {
  it('(E) a card being edited does not lift', () => {
    const { editing, touchLift } = card()
    assert.equal(touchLift.value, true)
    editing.value = true
    assert.equal(touchLift.value, false)
  })

  it('(S) a lift stops the card\'s other gestures', () => {
    const { seen } = card()
    drag.onStart(30, 40)
    assert.equal(seen.stops, 1)
  })

  it('(D) a drop with no travel opens the menu at the lift point, a dragged one does not', () => {
    const { seen } = card()
    drag.onStart(30, 40)
    drag.onDrop(30, 40)
    assert.deepEqual(seen.menuAt, [[30, 40]])

    drag.onStart(30, 40)
    drag.onMove(30, 40 + SLOP_PX + 1)
    drag.onDrop(30, 40 + SLOP_PX + 1)
    assert.deepEqual(seen.menuAt, [[30, 40]])
  })
})
