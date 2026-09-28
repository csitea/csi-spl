// CLE-35075: the snackbar clock (tickWhileShown) runs only while a row is on
// screen, and rows still expire after SNACKBAR_TTL_MS exactly as with the old
// always-on interval.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { SNACKBAR_TICK_MS, SNACKBAR_TTL_MS, createSnackbarQueue, tickWhileShown } from '../../src/utils/error-snackbar.mjs'

function rig() {
  let t = 0
  const timers = new Map()
  let next = 1
  const queue = createSnackbarQueue({ now: () => t })
  const stop = tickWhileShown(queue, {
    every: (fn, ms) => { assert.equal(ms, SNACKBAR_TICK_MS); const id = next++; timers.set(id, fn); return id },
    cancel: (id) => { timers.delete(id) },
  })
  return {
    queue, timers, stop,
    advance(ms) { for (let s = 0; s < ms; s += SNACKBAR_TICK_MS) { t += SNACKBAR_TICK_MS; for (const fn of [...timers.values()]) fn() } },
  }
}

describe('tickWhileShown', () => {
  it('an empty snackbar runs no timer', () => {
    const r = rig()
    assert.equal(r.timers.size, 0)
    r.advance(60000)
    assert.equal(r.timers.size, 0)
  })

  it('a row starts one timer; its expiry stops it', () => {
    const r = rig()
    r.queue.push({ message: 'boom', source: 'fetch' })
    r.queue.push({ message: 'other', source: 'fetch' })
    assert.equal(r.timers.size, 1)
    r.advance(SNACKBAR_TTL_MS - SNACKBAR_TICK_MS)
    assert.equal(r.queue.items().length, 2, 'still up just before the TTL')
    r.advance(SNACKBAR_TICK_MS)
    assert.equal(r.queue.items().length, 0, 'gone at the TTL')
    assert.equal(r.timers.size, 0)
  })

  it('a held row keeps the clock; dismiss stops it', () => {
    const r = rig()
    const id = r.queue.push({ message: 'boom' })
    r.queue.hold(id, true)
    r.advance(SNACKBAR_TTL_MS * 3)
    assert.equal(r.queue.items().length, 1)
    assert.equal(r.timers.size, 1)
    r.queue.dismiss(id)
    assert.equal(r.timers.size, 0)
  })

  it('stop() cancels a running timer', () => {
    const r = rig()
    r.queue.push({ message: 'boom' })
    r.stop()
    assert.equal(r.timers.size, 0)
  })
})
