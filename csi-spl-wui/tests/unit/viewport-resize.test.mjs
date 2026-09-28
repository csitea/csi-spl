// CLE-35075: MessageCard's clip measure runs from ONE shared window resize
// listener, once per animation frame, instead of one listener per card.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { createViewportResize } from '../../src/utils/viewport-resize.mjs'

function rig() {
  const listeners = new Set()
  const frames = []
  const win = {
    addEventListener: (t, fn) => { assert.equal(t, 'resize'); listeners.add(fn) },
    removeEventListener: (t, fn) => { listeners.delete(fn) },
  }
  const vr = createViewportResize({ win, frame: (fn) => frames.push(fn) })
  return {
    vr, listeners, frames,
    resize(times = 1) { for (let i = 0; i < times; i++) for (const fn of [...listeners]) fn() },
    paint() { const f = frames.splice(0); for (const fn of f) fn() },
  }
}

describe('viewport-resize', () => {
  it('N cards share one window listener', () => {
    const r = rig()
    const offs = Array.from({ length: 300 }, () => r.vr.subscribe(() => {}))
    assert.equal(r.listeners.size, 1)
    offs.forEach((off) => off())
    assert.equal(r.listeners.size, 0, 'the last one out removes it')
  })

  it('a burst of resize events in one frame measures each card once, before paint', () => {
    const r = rig()
    let a = 0
    let b = 0
    r.vr.subscribe(() => a++)
    r.vr.subscribe(() => b++)
    r.resize(12)
    assert.equal(a, 0, 'nothing before the frame')
    assert.equal(r.frames.length, 1, 'one frame queued for the burst')
    r.paint()
    assert.deepEqual([a, b], [1, 1])
    r.resize(1)
    r.paint()
    assert.deepEqual([a, b], [2, 2])
  })

  it('an unsubscribed card is not measured; a throwing one does not stop the rest', () => {
    const r = rig()
    let n = 0
    const off = r.vr.subscribe(() => n++)
    r.vr.subscribe(() => { throw new Error('gone') })
    let after = 0
    r.vr.subscribe(() => after++)
    off()
    r.resize()
    r.paint()
    assert.equal(n, 0)
    assert.equal(after, 1)
    off()
    assert.equal(r.vr.size(), 2, 'a second off() is a no-op')
  })

  it('MessageCard subscribes measure instead of adding its own listener', () => {
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
    assert.match(vue, /offResize = onViewportResize\(measure\)/)
    assert.doesNotMatch(vue, /addEventListener\('resize'/)
  })
})
