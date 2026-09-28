// CLE-35075: the topic pane's 1 Hz clock (utils/now-tick.mjs) keeps the
// old contract - an immediate reading on enable, one reading per second while
// open, stopped on close - and adds one rule: no ticks while the tab is
// hidden, and a fresh reading the moment it is visible again.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { createNowTick } from '../../src/utils/now-tick.mjs'

function rig(visibility = 'visible') {
  let t = 1000
  const timers = new Map()
  let nextId = 1
  const listeners = new Set()
  const doc = {
    visibilityState: visibility,
    addEventListener: (type, fn) => { if (type === 'visibilitychange') listeners.add(fn) },
    removeEventListener: (type, fn) => { if (type === 'visibilitychange') listeners.delete(fn) },
  }
  const seen = []
  const clock = createNowTick({
    set: (ms) => seen.push(ms),
    now: () => t,
    doc,
    every: (fn) => { const id = nextId++; timers.set(id, fn); return id },
    cancel: (id) => { timers.delete(id) },
  })
  return {
    clock,
    seen,
    timers,
    listeners,
    /** advance one second: every live interval fires once */
    second() { t += 1000; for (const fn of [...timers.values()]) fn() },
    show(state) { doc.visibilityState = state; for (const fn of [...listeners]) fn() },
  }
}

describe('now-tick', () => {
  it('reads now at once on enable, then once per second, and stops on disable', () => {
    const r = rig()
    r.clock.enable(true)
    assert.deepEqual(r.seen, [1000])
    r.second(); r.second()
    assert.deepEqual(r.seen, [1000, 2000, 3000])
    r.clock.enable(false)
    r.second()
    assert.deepEqual(r.seen, [1000, 2000, 3000])
    assert.equal(r.timers.size, 0)
  })

  it('never runs two intervals for one clock', () => {
    const r = rig()
    r.clock.enable(true)
    r.clock.enable(true)
    assert.equal(r.timers.size, 1)
  })

  it('a hidden tab ticks zero times; visible again reads now at once', () => {
    const r = rig()
    r.clock.enable(true)
    r.show('hidden')
    for (let i = 0; i < 60; i++) r.second()
    assert.deepEqual(r.seen, [1000], '60 hidden seconds, no reading')
    assert.equal(r.clock.running(), false)
    r.show('visible')
    assert.deepEqual(r.seen, [1000, 61000])
    r.second()
    assert.deepEqual(r.seen, [1000, 61000, 62000])
  })

  it('enabled while hidden: starts when the tab shows', () => {
    const r = rig('hidden')
    r.clock.enable(true)
    assert.deepEqual(r.seen, [])
    r.show('visible')
    assert.deepEqual(r.seen, [1000])
    assert.equal(r.clock.running(), true)
  })

  it('a closed pane stays stopped when the tab shows', () => {
    const r = rig()
    r.show('visible')
    assert.deepEqual(r.seen, [])
    assert.equal(r.clock.running(), false)
  })

  it('dispose stops it and removes the listener', () => {
    const r = rig()
    r.clock.enable(true)
    r.clock.dispose()
    assert.equal(r.timers.size, 0)
    assert.equal(r.listeners.size, 0)
  })
})
