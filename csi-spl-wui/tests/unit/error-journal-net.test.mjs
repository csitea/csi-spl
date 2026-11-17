// SPL-5745 (spec 162 F5): a transport drop says why. prd human_events
// (SPL-5733) held `GET /v1/view/channels` n=13, `/topics` n=12,
// `/topics/<id>` n=6 and `/flow` n=3 as `TypeError Failed to fetch` with no
// code, so a phone that was offline or a tab the browser had just woken read
// as a broken screen. The record now carries navigator.onLine,
// document.visibilityState, the ms since the last wake / online, and a code.
//
// Namespace import on purpose: on the old module the names are missing and
// these tests FAIL on their assertions instead of the file failing to load.
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import * as EJ from '../../src/composables/errorJournal.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const CLIENT = { isClient: true }
const T0 = Date.parse('2026-11-15T17:15:34Z')
const drop = () => new TypeError('Failed to fetch')
const view = (url, now) => EJ.noteError({ source: 'api', method: 'GET', url, error: drop() }, { ...CLIENT, now })

const saved = {}
function browser({ onLine = true, visibility = 'visible' } = {}) {
  for (const k of ['navigator', 'document']) {
    saved[k] = Object.getOwnPropertyDescriptor(globalThis, k)
  }
  Object.defineProperty(globalThis, 'navigator', { value: { onLine }, configurable: true, writable: true })
  Object.defineProperty(globalThis, 'document', { value: { visibilityState: visibility }, configurable: true, writable: true })
}
function restore() {
  for (const k of ['navigator', 'document']) {
    if (saved[k]) Object.defineProperty(globalThis, k, saved[k])
    else delete globalThis[k]
    delete saved[k]
  }
}

describe('errorJournal: a transport drop is classified (SPL-5745)', () => {
  beforeEach(() => EJ.resetErrorJournal())
  afterEach(() => restore())

  it('offline: code net.offline, the record carries online=false and the visibility', () => {
    browser({ onLine: false })
    const r = view('/v1/view/channels', T0)
    assert.equal(r.code, 'net.offline')
    assert.equal(r.online, false)
    assert.equal(r.visibility, 'visible')
    assert.ok('sinceWakeMs' in r)
  })

  it('a hidden tab: code net.resumed', () => {
    browser({ visibility: 'hidden' })
    const r = view('/v1/view/topics', T0)
    assert.equal(r.code, 'net.resumed')
    assert.equal(r.visibility, 'hidden')
    assert.equal(r.online, true)
  })

  it('woke 3 s ago: code net.resumed, sinceWakeMs 3000', () => {
    browser()
    EJ.noteWake(T0 - 3_000)
    const r = view('/v1/view/flow', T0)
    assert.equal(r.code, 'net.resumed')
    assert.equal(r.sinceWakeMs, 3_000)
  })

  it('online, visible, woke long ago: net.unreachable, still an error', () => {
    browser()
    EJ.noteWake(T0 - EJ.NET_RESUME_MS - 1)
    const r = view('/v1/view/topics/x', T0)
    assert.equal(r.code, 'net.unreachable')
    assert.equal(r.sinceWakeMs, EJ.NET_RESUME_MS + 1)
    assert.equal(EJ.isNetworkEventCode(r.code), false)
  })

  it('offline then unreachable inside the coalesce window: two records, not one', () => {
    browser({ onLine: false })
    view('/v1/view/channels', T0)
    view('/v1/view/topics', T0 + 100)
    restore()
    browser()
    EJ.noteWake(T0 - 60_000)
    view('/v1/view/channels', T0 + 200)
    assert.deepEqual(EJ.getErrors().map((r) => [r.code, r.count]), [['net.offline', 2], ['net.unreachable', 1]])
  })

  it('a non-transport error gets no net fields and keeps its own code', () => {
    browser({ onLine: false })
    const r = EJ.noteError({ source: 'api', method: 'GET', url: '/v1/view/topics', status: 502 }, CLIENT)
    assert.equal(r.code, '')
    assert.equal('online' in r, false)
  })

  it('net.offline and net.resumed are network; net.unreachable and others are not', () => {
    assert.equal(EJ.isNetworkEventCode('net.offline'), true)
    assert.equal(EJ.isNetworkEventCode('net.resumed'), true)
    assert.equal(EJ.isNetworkEventCode('net.unreachable'), false)
    assert.equal(EJ.isNetworkEventCode(''), false)
    assert.equal(EJ.isNetworkEventCode('upload_failed'), false)
  })

  it('the Events page marks a network row as network, from the shared predicate', () => {
    const page = read('src/pages/monitoring/events/index.vue')
    assert.match(page, /isNetworkEventCode\(r\.code\)/)
    assert.match(page, /data-test="events-network"/)
    assert.match(page, /t\('events\.network'\)/)
  })
})
