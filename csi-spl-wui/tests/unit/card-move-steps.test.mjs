// useCardMove's drag rules, run for real (r52-01): the only tests naming the
// composable read its source, so nothing held what a lift carries, which key
// cancels it, or what a phone's hold does. The vue and move-drag code is real;
// the composables that reach a router or a store are stubbed.
//
// Run: node --test tests/unit/card-move-steps.test.mjs
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ref } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const VIEWER = 'human-1'
const ACCESS = { me: { id: VIEWER, role: 'member' } }
const TOPIC_CARD = { msg_id: 'card-1', task_id: 'task-1', channel: 'ops', is_parent: 1, from: VIEWER, body: 'the topic' }
const THREAD_ROW = { msg_id: 'row-1', task_id: 'task-1', channel: 'ops', is_parent: 0, from: VIEWER, body: 'a reply' }
const MOVE_CTX = { channel: 'ops', opener: 'card-1', topic: 'task-of-pane' }

let mobile
let lifts
let buzzes
let keydown
let mod
let realWindow
let realWarn

before(async () => {
  realWindow = globalThis.window
  realWarn = console.warn
  /* the composable runs outside a component, so vue warns about its unmount hook */
  console.warn = (...args) => { if (!String(args[0]).includes('onBeforeUnmount')) realWarn(...args) }
  globalThis.window = {
    addEventListener: (type, fn) => { if (type === 'keydown') keydown = fn },
    removeEventListener: (type, fn) => { if (type === 'keydown' && keydown === fn) keydown = null },
  }
  mod = await importTsStubbed('src/composables/useCardMove.ts', {
    '~/composables/useMove': {
      useMove: () => ({
        drag: ref(null),
        over: ref(null),
        lift: (drag) => lifts.push(drag),
        track: () => {},
        land: () => {},
        run: async () => {},
      }),
    },
    '~/composables/useLive': { useLive: () => ({ lobbyTaskId: ref('') }) },
    '~/composables/useMobileStack': { useMobileStack: () => ({ isMobile: mobile }) },
    '~/composables/useCardSwipe': { buzz: () => { buzzes += 1 } },
  })
})

after(() => {
  globalThis.window = realWindow
  console.warn = realWarn
})

/** A card of `props` as MessageCard wires it, on a viewport `phone` or not. */
function card(props, phone = false) {
  mobile = ref(phone)
  lifts = []
  buzzes = 0
  keydown = null
  const rowCancels = { count: 0 }
  const flags = mod.useCardMoveFlags(props, ref(false), ref(false), ref(VIEWER), ACCESS)
  const peer = { swipeDown: () => {}, cancelRowDrag: () => { rowCancels.count += 1 } }
  const menu = { close: () => {} }
  return { mv: mod.useCardMove(props, flags, ref('the title'), ref(false), menu, peer), rowCancels }
}

const pointer = (over) => ({ pointerId: 1, pointerType: 'mouse', button: 0, clientX: 0, clientY: 0, preventDefault: () => {}, currentTarget: null, ...over })

/** A mouse press on the handle, then far enough to lift the card. */
function dragWithMouse(mv) {
  mv.onHandleDown(pointer())
  mv.handle.move(pointer({ clientX: 20 }))
}

function press(key) {
  const ev = { key, prevented: 0, preventDefault() { this.prevented += 1 } }
  keydown(ev)
  return ev
}

describe('useCardMove: what a drag does', () => {
  it('(A) a topic card lifts kind topic, a thread row kind message with the topic of moveCtx', () => {
    const topic = card({ msg: TOPIC_CARD, topicMenu: true })
    dragWithMouse(topic.mv)
    assert.equal(lifts.length, 1)
    assert.equal(lifts[0].kind, 'topic')
    assert.equal(lifts[0].topicTask, 'task-1')

    const row = card({ msg: THREAD_ROW, moveCtx: MOVE_CTX })
    dragWithMouse(row.mv)
    assert.equal(lifts.length, 1)
    assert.equal(lifts[0].kind, 'message')
    assert.equal(lifts[0].topicTask, 'task-of-pane')
  })

  it('(B) only Escape cancels a lifted card', () => {
    const { mv, rowCancels } = card({ msg: TOPIC_CARD, topicMenu: true })
    dragWithMouse(mv)
    const other = press('a')
    assert.equal(rowCancels.count, 0)
    assert.equal(other.prevented, 0)
    assert.equal(mv.dragging.value, true)

    const esc = press('Escape')
    assert.equal(rowCancels.count, 1)
    assert.equal(esc.prevented, 1)
    assert.equal(mv.dragging.value, false)
  })

  it("(C) a phone's touch hold opens Move to channel and lifts nothing", (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] })
    const { mv } = card({ msg: TOPIC_CARD, topicMenu: true }, true)
    mv.onHandleDown(pointer({ pointerType: 'touch' }))
    assert.equal(mv.movePicker.value, '')
    t.mock.timers.tick(350)
    assert.equal(mv.movePicker.value, 'channel')
    assert.equal(buzzes, 1)
    assert.equal(lifts.length, 0)
    assert.equal(mv.dragging.value, false)
  })
})
