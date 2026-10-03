// perf round 4 W5: useKeyboardInset subscribes to the tab's ONE viewport
// source (utils/viewport-resize.mjs) - passive window + visualViewport
// listeners, at most one run per frame - instead of adding three active
// listeners of its own and reading innerHeight during mount.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { createViewportResize } from '../../src/utils/viewport-resize.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

function target() {
  const listeners = new Map()
  return {
    listeners,
    addEventListener: (t, fn, opts) => {
      assert.equal(opts?.passive, true, `${t} listener is passive`)
      assert.ok(!listeners.has(t), `one ${t} listener`)
      listeners.set(t, fn)
    },
    removeEventListener: (t, fn) => { if (listeners.get(t) === fn) listeners.delete(t) },
    fire(t, times = 1) { for (let i = 0; i < times; i++) listeners.get(t)?.() },
  }
}

function rig() {
  const win = target()
  const vv = target()
  win.visualViewport = vv
  const frames = []
  const src = createViewportResize({ win, frame: (fn) => frames.push(fn) })
  return { win, vv, frames, src, paint() { for (const fn of frames.splice(0)) fn() } }
}

describe('viewport source (W5)', () => {
  it('a visual subscriber hears window resize + visualViewport resize/scroll, all passive', () => {
    const r = rig()
    const off = r.src.subscribe(() => {}, { visual: true })
    assert.deepEqual([...r.win.listeners.keys()], ['resize'])
    assert.deepEqual([...r.vv.listeners.keys()].sort(), ['resize', 'scroll'])
    off()
    assert.equal(r.win.listeners.size + r.vv.listeners.size, 0, 'the last one out removes all three')
  })

  it('a card-only source never touches visualViewport', () => {
    const r = rig()
    r.src.subscribe(() => {})
    assert.equal(r.vv.listeners.size, 0)
    assert.equal(r.win.listeners.size, 1)
  })

  it('a keyboard burst (vv resize + scroll + window resize) runs the inset once per frame', () => {
    const r = rig()
    let inset = 0
    let card = 0
    r.src.subscribe(() => inset++, { visual: true })
    r.src.subscribe(() => card++)
    r.vv.fire('resize', 8)
    r.vv.fire('scroll', 8)
    assert.equal(inset, 0, 'nothing synchronous in the event')
    assert.equal(r.frames.length, 1, 'one frame for the burst')
    r.paint()
    assert.deepEqual([inset, card], [1, 0], 'a visualViewport-only frame leaves the cards alone')
    r.vv.fire('resize')
    r.win.fire('resize')
    assert.equal(r.frames.length, 1)
    r.paint()
    assert.deepEqual([inset, card], [2, 1], 'a window resize runs everyone, still once')
  })

  it('initial runs the first apply in the next frame, not during mount', () => {
    const r = rig()
    let n = 0
    r.src.subscribe(() => n++, { visual: true, initial: true })
    assert.equal(n, 0)
    r.paint()
    assert.equal(n, 1)
  })

  it('no visualViewport: a visual subscriber still hears window resize', () => {
    const win = target()
    const frames = []
    const src = createViewportResize({ win, frame: (fn) => frames.push(fn) })
    let n = 0
    src.subscribe(() => n++, { visual: true })
    win.fire('resize')
    for (const fn of frames.splice(0)) fn()
    assert.equal(n, 1)
  })

  it('useKeyboardInset adds no listener of its own and subscribes apply', () => {
    const ts = readFileSync(join(WUI, 'src/composables/useTouchUi.ts'), 'utf8')
    assert.doesNotMatch(ts, /addEventListener/)
    assert.match(ts, /onViewportResize\(apply, \{ visual: true, initial: true \}\)/)
    assert.doesNotMatch(ts, /^\s*apply\(\)/m, 'no synchronous apply at mount')
  })
})
