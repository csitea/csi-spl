// The personal event log's client + shipper (005 FR-WUI-EVLOG,
// contracts/events-v1.md), executed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  EVENT_BATCH_MAX,
  EVENT_QUEUE_MAX,
  EVENT_QUEUE_STORE_KEY,
  EVENT_RETRY_MAX,
  bindShipperToJournal,
  createEventShipper,
  createQueueStore,
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

// SPL-7 (owner topic 4335f075): an error the shipper could not send yet must
// survive a page reload and ship on the next load.
function fakeStorage(init = {}) {
  const m = new Map(Object.entries(init))
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)) },
    removeItem: (k) => { m.delete(k) },
    map: m,
  }
}

describe('unsent queue survives a reload (SPL-7)', () => {
  it('a 5xx leaves the event in storage; the next page load ships it', async () => {
    const storage = fakeStorage()
    const f1 = fakeFetch([{ status: 503 }])
    const t1 = manualTimers()
    const s1 = createEventShipper({ client: createEventsClient({ fetchFn: f1.fn }), session: () => 'in', store: createQueueStore(storage), ...t1 })
    s1.note(rec())
    t1.pending.shift().fn()
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(f1.calls.length, 1)
    const kept = JSON.parse(storage.getItem(EVENT_QUEUE_STORE_KEY))
    assert.equal(kept.length, 1)
    assert.equal(kept[0].error_id, 'ERR-CLIENT-20260925-190000-ABCD')
    // reload: the old page and its timers are gone, a new shipper boots signed in
    const f2 = fakeFetch([{ status: 200 }])
    const t2 = manualTimers()
    const s2 = createEventShipper({ client: createEventsClient({ fetchFn: f2.fn }), session: () => 'in', store: createQueueStore(storage), ...t2 })
    assert.equal(s2.size(), 1)
    await t2.runAll()
    assert.equal(f2.calls.length, 1)
    assert.deepEqual(f2.calls[0].body.events, kept)
    assert.equal(storage.getItem(EVENT_QUEUE_STORE_KEY), null)
  })

  it('a session still loading at boot waits, then ships the stored queue', async () => {
    const storage = fakeStorage({ [EVENT_QUEUE_STORE_KEY]: JSON.stringify([toEventPayload(rec())]) })
    let st = 'loading'
    const f = fakeFetch([{ status: 200 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => st, store: createQueueStore(storage), ...t })
    assert.equal(t.pending.length, 0)
    st = 'in'
    s.sessionChanged()
    await t.runAll()
    assert.equal(f.calls.length, 1)
    assert.equal(s.size(), 0)
  })

  it('signed out at boot or later: the stored queue is dropped, never sent', async () => {
    const storage = fakeStorage({ [EVENT_QUEUE_STORE_KEY]: JSON.stringify([toEventPayload(rec())]) })
    const f = fakeFetch([{ status: 200 }])
    const t = manualTimers()
    createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'out', store: createQueueStore(storage), ...t })
    await t.runAll()
    assert.equal(f.calls.length, 0)
    assert.equal(storage.getItem(EVENT_QUEUE_STORE_KEY), null)
  })

  it('a 401 clears the store too', async () => {
    const storage = fakeStorage()
    const f = fakeFetch([{ status: 401 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', store: createQueueStore(storage), ...t })
    s.note(rec())
    assert.notEqual(storage.getItem(EVENT_QUEUE_STORE_KEY), null)
    await t.runAll()
    assert.equal(storage.getItem(EVENT_QUEUE_STORE_KEY), null)
  })

  it('reads back only capped wire fields, at most EVENT_QUEUE_MAX; junk reads as empty', () => {
    const big = { ...toEventPayload(rec()), message: 'x'.repeat(5000), body: 'secret', status: 'nope' }
    const many = Array.from({ length: EVENT_QUEUE_MAX + 7 }, () => big)
    const got = createQueueStore(fakeStorage({ [EVENT_QUEUE_STORE_KEY]: JSON.stringify([...many, 'junk', null, [1]]) })).load()
    assert.equal(got.length, EVENT_QUEUE_MAX)
    assert.equal(got[0].message.length, 800)
    assert.equal(got[0].status, 0)
    assert.equal('body' in got[0], false)
    for (const raw of ['{not json', '{"a":1}', '"x"']) {
      assert.deepEqual(createQueueStore(fakeStorage({ [EVENT_QUEUE_STORE_KEY]: raw })).load(), [])
    }
    assert.deepEqual(createQueueStore(null).load(), [])
  })

  it('a throwing storage (quota, blocked) never breaks the shipper', async () => {
    const bad = { getItem: () => { throw new Error('SecurityError') }, setItem: () => { throw new Error('QuotaExceeded') }, removeItem: () => { throw new Error('x') } }
    const f = fakeFetch([{ status: 200 }])
    const t = manualTimers()
    const s = createEventShipper({ client: createEventsClient({ fetchFn: f.fn }), session: () => 'in', store: createQueueStore(bad), ...t })
    s.note(rec())
    await t.runAll()
    assert.equal(f.calls.length, 1)
    assert.equal(s.size(), 0)
  })

  it('by default the browser tab sessionStorage holds the queue; null = memory only', () => {
    const storage = fakeStorage()
    globalThis.window = { sessionStorage: storage }
    try {
      const t = manualTimers()
      const s = createEventShipper({ client: createEventsClient({ fetchFn: fakeFetch([{ status: 200 }]).fn }), session: () => 'loading', ...t })
      s.note(rec())
      assert.equal(JSON.parse(storage.getItem(EVENT_QUEUE_STORE_KEY)).length, 1)
      storage.removeItem(EVENT_QUEUE_STORE_KEY)
      const m = createEventShipper({ client: createEventsClient({ fetchFn: fakeFetch([{ status: 200 }]).fn }), session: () => 'loading', store: null, ...t })
      m.note(rec())
      assert.equal(storage.getItem(EVENT_QUEUE_STORE_KEY), null)
    } finally {
      delete globalThis.window
    }
  })
})
