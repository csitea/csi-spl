// useCardGrip's rules, run for real (r53-03): the only tests naming
// useCardHeight read its source, so nothing held which keys step the grip,
// that the click ending a drag is swallowed, or how far a pointer moves
// before it drags. The vue and card-clip code is real; the link previews and
// the viewport listener are stubbed, and the card's box is a plain object.
//
// Run: node --test tests/unit/card-grip.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { CARD_GRIP_STEP_ROWS } from '../../src/utils/card-clip.mjs'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const LINE_PX = 20
const CONTENT_PX = 400
const BOX_PX = 100

let mod
let saved

before(async () => {
  saved = { window: globalThis.window, HTMLElement: globalThis.HTMLElement, getComputedStyle: globalThis.getComputedStyle, warn: console.warn }
  /* the composable runs outside a component, so vue warns about its lifecycle hooks */
  console.warn = (...args) => { if (!/onMounted|onBeforeUnmount/.test(String(args[0]))) saved.warn(...args) }
  globalThis.window = {}
  globalThis.HTMLElement = class {}
  globalThis.getComputedStyle = () => ({ lineHeight: `${LINE_PX}px`, fontSize: '14px' })
  mod = await importTsStubbed('src/composables/useCardHeight.ts', {
    '~/composables/useLinkPreviewRefs': { useLinkPreviewRefs: () => ref([]) },
    '~/utils/viewport-resize': { onViewportResize: () => () => {} },
  })
})

after(() => {
  globalThis.window = saved.window
  globalThis.HTMLElement = saved.HTMLElement
  globalThis.getComputedStyle = saved.getComputedStyle
  console.warn = saved.warn
})

/** A 5-row card of CONTENT_PX content in a BOX_PX box, and its grip handle. */
function card() {
  const box = { getBoundingClientRect: () => ({ height: BOX_PX, top: 0 }) }
  const inner = { querySelector: () => null, scrollHeight: CONTENT_PX, parentElement: null }
  const grip = mod.useCardHeight({ msg: { msg_id: 'm1', body: 'a long card' }, clipMode: 'rows' }, ref(false), ref(box), ref(inner))
  const handle = new globalThis.HTMLElement()
  handle.on = {}
  handle.setPointerCapture = () => {}
  handle.addEventListener = (type, fn) => { handle.on[type] = fn }
  handle.removeEventListener = (type) => { delete handle.on[type] }
  return { grip, handle }
}

const pointer = (over) => ({ pointerId: 1, clientY: 0, preventDefault: () => {}, ...over })

/** A press on the handle at y 0, then a move to `dy`, then the release. */
function drag({ grip, handle }, dy) {
  grip.startGrip(pointer({ currentTarget: handle }))
  handle.on.pointermove(pointer({ clientY: dy }))
  handle.on.pointerup(pointer({ clientY: dy }))
}

function key(grip, name) {
  const ev = { key: name, prevented: 0, stopped: 0, preventDefault() { this.prevented += 1 }, stopPropagation() { this.stopped += 1 } }
  grip.onGripKey(ev)
  return ev
}

describe('useCardGrip: what the grip does', () => {
  it('(K) only the arrows act: Down and Up step two rows, another key does nothing', () => {
    const { grip } = card()
    const other = key(grip, 'a')
    assert.equal(other.prevented, 0)
    assert.equal(other.stopped, 0)
    assert.equal(grip.userPx.value, null)

    const down = key(grip, 'ArrowDown')
    assert.equal(down.prevented, 1)
    assert.equal(down.stopped, 1)
    assert.equal(grip.userPx.value, BOX_PX + LINE_PX * CARD_GRIP_STEP_ROWS)

    const up = key(grip, 'ArrowUp')
    assert.equal(up.prevented, 1)
    assert.equal(grip.userPx.value, BOX_PX - LINE_PX * CARD_GRIP_STEP_ROWS)
  })

  it('(C) the click right after a drag does nothing; the next click acts', () => {
    const c = card()
    drag(c, 30)
    const dragged = c.grip.userPx.value
    c.grip.onGripClick()
    assert.equal(c.grip.userPx.value, dragged)

    assert.equal(c.grip.clipped.value, true)
    c.grip.onGripClick()
    assert.equal(c.grip.userPx.value, CONTENT_PX)
  })

  it('(D) a pointer move under 3 px is no drag; 3 px is', () => {
    const c = card()
    drag(c, 2)
    assert.equal(c.grip.userPx.value, null)

    drag(c, 3)
    assert.equal(c.grip.userPx.value, BOX_PX + 3)
  })
})
