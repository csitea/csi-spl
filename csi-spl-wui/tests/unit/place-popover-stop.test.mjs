// Refactor round 3, row 24: observePopover's stop function removes the
// observer and the click / focusin / keydown listeners in one go (one
// AbortController for the group). A fake host (an EventTarget) and a stub
// MutationObserver. Every re-place looks the panel up once with
// host.querySelector, so those lookups count how often the listeners ran.
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { observePopover } from '../../src/utils/place-popover.mjs'

const EVENTS = ['click', 'focusin', 'keydown']

let observers = []
let saved
beforeEach(() => {
  observers = []
  saved = globalThis.MutationObserver
  globalThis.MutationObserver = class {
    constructor(cb) { this.cb = cb; this.disconnected = 0; observers.push(this) }
    observe() {}
    disconnect() { this.disconnected++ }
  }
})
afterEach(() => { globalThis.MutationObserver = saved })

/** an EventTarget host with no panel, so a re-place only counts itself */
function fakeHost() {
  const host = new EventTarget()
  host.reads = 0
  host.querySelector = (sel) => { if (sel === '.p') host.reads++; return null }
  return host
}

describe('observePopover stop', () => {
  it('listens to click, focusin and keydown while observing', () => {
    const host = fakeHost()
    observePopover(host, { panel: '.p', anchor: '.a' })
    for (const type of EVENTS) host.dispatchEvent(new Event(type))
    assert.equal(host.reads, EVENTS.length)
  })

  it('after stop, click / focusin / keydown call nothing and the observer is gone', () => {
    const host = fakeHost()
    const stop = observePopover(host, { panel: '.p', anchor: '.a' })
    stop()
    for (const type of EVENTS) host.dispatchEvent(new Event(type))
    assert.equal(host.reads, 0)
    assert.equal(observers.length, 1)
    assert.equal(observers[0].disconnected, 1)
  })

  it('is safe to call twice', () => {
    const host = fakeHost()
    const stop = observePopover(host, { panel: '.p', anchor: '.a' })
    stop()
    assert.doesNotThrow(() => stop())
    host.dispatchEvent(new Event('click'))
    assert.equal(host.reads, 0)
  })
})
