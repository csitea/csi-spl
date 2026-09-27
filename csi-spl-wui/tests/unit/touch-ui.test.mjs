// SPL-991: the phone message area - breakpoint, keyboard inset, long-press.
// Run: node tests/unit/touch-ui.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  LONG_PRESS_MS,
  createLongPress,
  isTouchPointer,
  keyboardInset,
} from '../../src/utils/touch-ui.mjs'
import { MOBILE_STACK_QUERY } from '../../src/utils/mobile-stack.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

function fakeTimers() {
  const q = new Map()
  let n = 0
  return {
    setTimer: (fn, ms) => { q.set(++n, { fn, ms }); return n },
    clearTimer: (id) => { q.delete(id) },
    run() { for (const [id, t] of [...q]) { q.delete(id); t.fn() } },
    get size() { return q.size },
  }
}

describe('the phone line', () => {
  it('is SPL-989\'s one 820 px breakpoint, and the CSS says the same', () => {
    assert.equal(MOBILE_STACK_QUERY, '(max-width: 820px)')
    for (const f of ['MessageCard.vue']) {
      const src = readFileSync(join(WUI, 'src/components', f), 'utf8')
      assert.match(src, /@media \(max-width: 820px\)/, f)
    }
    assert.match(readFileSync(join(WUI, 'src/composables/useTouchUi.ts'), 'utf8'), /useMobileStack\(\)\.isMobile/)
  })
})

describe('keyboardInset', () => {
  it('is the part of the layout viewport under the keyboard', () => {
    assert.equal(keyboardInset(800, { height: 450, offsetTop: 0 }), 350)
  })
  it('subtracts the visual viewport scrolled down by iOS on focus', () => {
    assert.equal(keyboardInset(800, { height: 450, offsetTop: 100 }), 250)
  })
  it('reads a toolbar slide or a pinch as no keyboard', () => {
    assert.equal(keyboardInset(800, { height: 760, offsetTop: 0 }), 0)
    assert.equal(keyboardInset(800, { height: 900, offsetTop: 0 }), 0)
  })
  it('is 0 without the API or with nonsense', () => {
    assert.equal(keyboardInset(800, null), 0)
    assert.equal(keyboardInset(800, undefined), 0)
    assert.equal(keyboardInset(0, { height: 400 }), 0)
    assert.equal(keyboardInset(800, { height: Number.NaN }), 0)
  })
})

describe('isTouchPointer', () => {
  it('a finger and a pen long-press, a mouse has its right-click', () => {
    assert.equal(isTouchPointer('touch'), true)
    assert.equal(isTouchPointer('pen'), true)
    assert.equal(isTouchPointer('mouse'), false)
    assert.equal(isTouchPointer(undefined), false)
  })
})

describe('createLongPress', () => {
  const touch = (x = 10, y = 10) => ({ pointerType: 'touch', clientX: x, clientY: y, isPrimary: true })

  it('fires once after the delay at the press point, and swallows the next click once', () => {
    const t = fakeTimers()
    const hits = []
    const lp = createLongPress({ onPress: (x, y) => hits.push([x, y]), ...t })
    lp.down(touch(20, 30))
    assert.equal(lp.pending, true)
    t.run()
    assert.deepEqual(hits, [[20, 30]])
    assert.equal(lp.takeClick(), true)
    assert.equal(lp.takeClick(), false)
  })

  it('uses LONG_PRESS_MS by default', () => {
    const t = fakeTimers()
    let ms = 0
    const lp = createLongPress({ onPress: () => {}, setTimer: (fn, d) => { ms = d; return t.setTimer(fn, d) }, clearTimer: t.clearTimer })
    lp.down(touch())
    assert.equal(ms, LONG_PRESS_MS)
  })

  it('a finger that moves past the slop is scrolling: no press', () => {
    const t = fakeTimers()
    let hit = 0
    const lp = createLongPress({ onPress: () => { hit++ }, ...t })
    lp.down(touch(10, 10))
    lp.move({ clientX: 12, clientY: 14 })
    assert.equal(lp.pending, true)
    lp.move({ clientX: 10, clientY: 40 })
    assert.equal(lp.pending, false)
    t.run()
    assert.equal(hit, 0)
    assert.equal(lp.takeClick(), false)
  })

  it('lifting early is a tap, not a press', () => {
    const t = fakeTimers()
    let hit = 0
    const lp = createLongPress({ onPress: () => { hit++ }, ...t })
    lp.down(touch())
    lp.up()
    t.run()
    assert.equal(hit, 0)
    assert.equal(t.size, 0)
  })

  it('a mouse or a second finger never starts one', () => {
    const t = fakeTimers()
    const lp = createLongPress({ onPress: () => {}, ...t })
    lp.down({ pointerType: 'mouse', clientX: 0, clientY: 0 })
    assert.equal(lp.pending, false)
    lp.down({ pointerType: 'touch', clientX: 0, clientY: 0, isPrimary: false })
    assert.equal(lp.pending, false)
  })

  it('a new touch clears a stale fired flag', () => {
    const t = fakeTimers()
    const lp = createLongPress({ onPress: () => {}, ...t })
    lp.down(touch())
    t.run()
    lp.down(touch())
    lp.up()
    assert.equal(lp.takeClick(), false)
  })
})
