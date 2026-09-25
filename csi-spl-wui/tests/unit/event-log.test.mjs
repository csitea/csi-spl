// The personal event log's client + shipper (005 FR-WUI-EVLOG,
// contracts/events-v1.md, CLE-34990), executed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  EVENT_BATCH_MAX,
  EVENT_RETRY_MAX,
  bindShipperToJournal,
  createEventShipper,
  createEventsClient,
  eventsErrorKey,
  toEventPayload,
} from '../../src/utils/event-log.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

const rec = (over = {}) => ({
  seq: 1, ref: 'E1-abcd', errorId: 'ERR-CLIENT-20260925-190000-ABCD', at: '2026-09-25T19:00:00.000Z',
  source: 'api', method: 'GET', origin: 'https://api.example.test', path: '/v1/view/roster',
  status: 502, code: '', message: 'Bad gateway', name: 'FetchError', route: '/lobby',
  ...over,
})

function fakeFetch(answers) {
  const calls = []
  const fn = async (url, init) => {
    calls.push({ url, init, body: init && init.body ? JSON.parse(init.body) : null })
    const a = answers.length > 1 ? answers.shift() : answers[0]
    if (a === 'throw') throw new TypeError('Failed to fetch')
    return {
      ok: a.status >= 200 && a.status < 300,
      status: a.status,
      headers: { get: (h) => (h.toLowerCase() === 'retry-after' ? a.retryAfter || null : null) },
      json: async () => a.body || {},
    }
  }
  return { fn, calls }
}

function manualTimers() {
  const pending = []
  return {
    setTimer: (fn, ms) => { const h = { fn, ms }; pending.push(h); return h },
    clearTimer: (h) => { const i = pending.indexOf(h); if (i >= 0) pending.splice(i, 1) },
    pending,
    async runAll() {
      while (pending.length) { const h = pending.shift(); h.fn(); await new Promise((r) => setTimeout(r, 0)) }
    },
  }
}

describe('toEventPayload', () => {
  it('sends only the redacted journal fields, in wire names', () => {
    const p = toEventPayload({ ...rec(), body: 'secret', headers: { a: 1 }, query: 'token=x', stack: 'at …', ref: 'E1' })
    assert.deepEqual(Object.keys(p).sort(), ['at', 'code', 'error_id', 'message', 'method', 'name', 'origin', 'path', 'route', 'source', 'status'])
    assert.equal(p.error_id, 'ERR-CLIENT-20260925-190000-ABCD')
    assert.equal(p.status, 502)
  })
  it('caps fields and sanitises status', () => {
    const p = toEventPayload(rec({ message: 'x'.repeat(5000), status: 'nope' }))
    assert.ok(p.message.length <= 800)
    assert.equal(p.status, 0)
    assert.equal(toEventPayload(null), null)
  })
})

describe('createEventsClient', () => {
  it('lists with limit/before, adds a batch, clears — all credentialed on the auth prefix', async () => {
    const f = fakeFetch([{ status: 200, body: { events: [] } }])
    const c = createEventsClient({ fetchFn: f.fn, base: 'https://api.example.test' })
    await c.list({ limit: 25, before: 40 })
    await c.add([toEventPayload(rec())])
    await c.clear()
    assert.equal(f.calls[0].url, 'https://api.example.test/api/v1/auth/events?limit=25&before=40')
    assert.equal(f.calls[1].url, 'https://api.example.test/api/v1/auth/events')
    assert.equal(f.calls[1].init.method, 'POST')
    assert.equal(f.calls[1].body.events.length, 1)
    assert.equal(f.calls[2].url, 'https://api.example.test/api/v1/auth/events/clear')
    for (const call of f.calls) assert.equal(call.init.credentials, 'include')
  })
  it('never throws: a transport failure resolves to error network', async () => {
    const c = createEventsClient({ fetchFn: fakeFetch(['throw']).fn })
    const r = await c.list()
    assert.equal(r.ok, false)
    assert.equal(r.error, 'network')
  })
  it('maps errors to i18n keys', () => {
    assert.equal(eventsErrorKey('unauthenticated'), 'events.signed_out')
    assert.equal(eventsErrorKey('network'), 'events.load_failed')
  })
})

describe('createEventShipper', () => {
  it('signed in: batches a burst into one POST after the delay', async () => {
    const f = fakeFetch([{ status: 200, body: { added: 3 } }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', ...t })
    s.note(rec({ seq: 1 })); s.note(rec({ seq: 2 })); s.note(rec({ seq: 3 }))
    assert.equal(t.pending.length, 1)
    await t.runAll()
    assert.equal(f.calls.length, 1)
    assert.equal(f.calls[0].body.events.length, 3)
    assert.equal(s.size(), 0)
  })

  it('splits more than EVENT_BATCH_MAX into several POSTs', async () => {
    const f = fakeFetch([{ status: 200 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', ...t })
    for (let i = 0; i < EVENT_BATCH_MAX + 5; i++) s.note(rec({ seq: i + 1 }))
    await t.runAll()
    assert.deepEqual(f.calls.map((c) => c.body.events.length), [EVENT_BATCH_MAX, 5])
  })

  it('signed out: nothing is queued and nothing is POSTed', async () => {
    const f = fakeFetch([{ status: 200 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'out', ...t })
    s.note(rec())
    await s.flush()
    await t.runAll()
    assert.equal(f.calls.length, 0)
    assert.equal(s.size(), 0)
  })

  it('session unknown at boot: records wait, then ship once signed in', async () => {
    let st = 'loading'
    const f = fakeFetch([{ status: 200 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => st, ...t })
    s.note(rec())
    assert.equal(t.pending.length, 0)
    assert.equal(s.size(), 1)
    st = 'in'
    s.sessionChanged()
    await t.runAll()
    assert.equal(f.calls.length, 1)
  })

  it('a 401 drops the queue; a 400 drops the batch; neither retries', async () => {
    for (const status of [401, 400]) {
      const f = fakeFetch([{ status }])
      const t = manualTimers()
      const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', ...t })
      s.note(rec())
      await t.runAll()
      assert.equal(f.calls.length, 1, `status ${status}`)
      assert.equal(s.size(), 0)
    }
  })

  it('transport failure / 5xx retries with backoff, then gives up — and never journals', async () => {
    const f = fakeFetch(['throw'])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', ...t })
    s.note(rec())
    await t.runAll()
    assert.equal(f.calls.length, EVENT_RETRY_MAX + 1)
    assert.equal(s.size(), 0)
    // The shipper must not import the journal: its own failure is never an event.
    const src = readFileSync(join(WUI, 'src/utils/event-log.mjs'), 'utf8')
    assert.equal(/errorJournal|noteError|spool-client/.test(src.replace(/^\s*\/\/.*$/gm, '')), false)
  })

  it('a 429 waits Retry-After seconds', async () => {
    const f = fakeFetch([{ status: 429, retryAfter: '7' }, { status: 200 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', ...t })
    s.note(rec())
    const first = t.pending.shift()
    first.fn()
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(t.pending[0].ms, 7000)
    await t.runAll()
    assert.equal(s.size(), 0)
  })
})

describe('bindShipperToJournal', () => {
  it('notes buffered and new records once each', () => {
    const seen = []
    let fire
    bindShipperToJournal({ note: (r) => seen.push(r.seq) }, {
      getErrors: () => [rec({ seq: 1 }), rec({ seq: 2 })],
      subscribeErrors: (fn) => { fire = fn; return () => {} },
    })
    fire([rec({ seq: 1 }), rec({ seq: 2 }), rec({ seq: 3 })])
    fire([rec({ seq: 1 }), rec({ seq: 2 }), rec({ seq: 3 })])
    assert.deepEqual(seen, [1, 2, 3])
  })
})
