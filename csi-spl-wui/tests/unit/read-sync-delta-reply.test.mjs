import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { laterThan, createReadSync } from '../../src/utils/read-sync.mjs'
import { loadCursors, saveCursors } from '../../src/utils/read-cursor.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

// Perf edition 20261004 E11: PUT /v1/me/reads answers only the marks it wrote,
// as stored (a later mark from another device wins); GET still answers all.
// read-sync needs no change for that reply: what it sent is recorded once, a
// stored later mark still moves the cursor, and the rest arrives on a pull.
describe('E11: read-sync on a PUT reply that carries only the written marks', () => {
  const T0 = '2026-10-04T02:00:00Z'
  const T1 = '2026-10-04T02:10:00Z'
  const T2 = '2026-10-04T02:20:00Z'

  function deltaHub(hub) {
    const puts = []
    const replies = []
    const fetchFn = async (_url, opts) => {
      let reply = hub
      if (opts.method === 'PUT') {
        const { marks } = JSON.parse(opts.body)
        puts.push(marks)
        reply = {}
        for (const [k, m] of Object.entries(marks)) {
          if (!hub[k] || laterThan(m, hub[k])) hub[k] = { ...hub[k], ...m }
          reply[k] = hub[k]
        }
      }
      replies.push(reply)
      return { ok: true, json: async () => ({ marks: reply }) }
    }
    return { fetchFn, puts, replies }
  }

  it('records a pushed cursor once, takes a stored later mark, and gets the rest on pull', async () => {
    const store = memoryStore()
    saveCursors({}, store)
    const hub = { 'ch:ops': { ts: T2, id: 'phone' }, 'dm:HUM-9': { ts: T1, id: 'other-device' } }
    const { fetchFn, puts, replies } = deltaHub(hub)
    const sync = createReadSync({ base: '', token: '', credentials: 'omit' }, { fetchFn, store })
    await sync.ready
    sync.stop()
    hub['t:T1'] = { ts: T2, id: 'later', count: 4 }
    saveCursors({ ...loadCursors(store), 'ch:devel': { ts: T1, id: 'a' }, 'ch:ops': { ts: T0, id: 'stale' } }, store)
    await sync.push()
    assert.deepEqual(Object.keys(puts[0]).sort(), ['ch:devel', 'ch:ops'])
    assert.deepEqual(Object.keys(replies[1]).sort(), ['ch:devel', 'ch:ops'])
    assert.equal(loadCursors(store)['ch:ops'].id, 'phone', 'the stored later mark in the reply wins')
    await sync.push()
    assert.equal(puts.length, 1, 'nothing moved: no second PUT')
    assert.equal(loadCursors(store)['t:T1'], undefined, 'a PUT reply no longer carries other keys')
    await sync.pull()
    assert.equal(loadCursors(store)['t:T1'].count, 4, 'a pull still brings the whole map')
  })
})
