import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mergeMarks, pendingMarks, wireMark, laterThan, createReadSync } from '../../src/utils/read-sync.mjs'
import { loadCursors, saveCursors } from '../../src/utils/read-cursor.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

// CLE-77930 (owner, t1 bf737f3f): unread is "for me and me only ... not the
// new messages which I have seen" - a read on one device is a read on all.
describe('CLE-77930: hub read marks follow the member across devices', () => {
  const T0 = '2026-10-02T02:00:00Z'
  const T1 = '2026-10-02T02:10:00.5Z'

  it('orders marks by time then msg id, parsing timestamps (not comparing strings)', () => {
    assert.equal(laterThan({ ts: '2026-10-02T02:00:00.1234Z' }, { ts: '2026-10-02T02:00:00.123Z' }), false) // same ms
    assert.equal(laterThan({ ts: T1 }, { ts: T0 }), true)
    assert.equal(laterThan({ ts: T0, id: 'b' }, { ts: T0, id: 'a' }), true)
    assert.equal(laterThan({ ts: T0 }, null), true)
  })

  it('moves a local cursor forward to a later hub mark, keeps a later local one, raises a thread count', () => {
    const local = {
      'ch:devel': { ts: T0, id: 'a' },
      'ch:ops': { ts: T1, id: 'z', hub: 'H' },
      't:T1': { ts: T1, id: '', count: 3, own: ['m9'] },
    }
    const { cursors, moved } = mergeMarks(local, {
      'ch:devel': { ts: T1, id: 'b', cursor: 'C' },
      'ch:ops': { ts: T0, id: 'y' },
      't:T1': { ts: T0, count: 5 },
      'dm:CLE-07@box-a': { ts: T0, id: 'd' },
      'bad key': { ts: T1 },
    })
    assert.deepEqual(moved.sort(), ['ch:devel', 'dm:CLE-07@box-a', 't:T1'])
    assert.deepEqual(cursors['ch:devel'], { ts: T1, id: 'b', hub: 'C' })
    assert.equal(cursors['ch:ops'], local['ch:ops'])
    assert.deepEqual(cursors['t:T1'], { ts: T1, id: '', count: 5, own: ['m9'] })
    assert.equal(mergeMarks(local, {}).cursors, local)
  })

  it('sends only what moved since the last exchange, as the hub wire mark', () => {
    const cs = { 'ch:devel': { ts: T1, id: 'b', hub: 'C' }, 't:T1': { ts: T0, id: '', count: 2 }, 'x:other': { ts: T0 } }
    const sent = { 'ch:devel': JSON.stringify(wireMark(cs['ch:devel'])) }
    assert.deepEqual(pendingMarks(cs, sent), { 't:T1': { ts: T0, count: 2 } })
    assert.deepEqual(wireMark(cs['ch:devel']), { ts: T1, id: 'b', cursor: 'C' })
  })

  it('pulls on start, pushes a moved cursor, and does not push it again', async () => {
    const store = memoryStore()
    saveCursors({ 'ch:devel': { ts: T0, id: 'a' } }, store)
    const hub = { 'ch:devel': { ts: T1, id: 'b', cursor: 'C' } }
    const puts = []
    const fetchFn = async (url, opts) => {
      assert.match(url, /\/v1\/me\/reads$/)
      if (opts.method === 'PUT') {
        const { marks } = JSON.parse(opts.body)
        puts.push(marks)
        for (const [k, m] of Object.entries(marks)) if (!hub[k] || laterThan(m, hub[k]) || (m.count || 0) > (hub[k].count || 0)) hub[k] = { ...hub[k], ...m }
      }
      return { ok: true, json: async () => ({ marks: hub }) }
    }
    const moves = []
    const sync = createReadSync({ base: 'https://api.example.com', token: '', credentials: 'include' }, { fetchFn, store, onMoved: (m) => moves.push(...m) })
    try {
      await sync.ready
      assert.deepEqual(loadCursors(store)['ch:devel'], { ts: T1, id: 'b', hub: 'C' }, 'the pull moved the stale device forward')
      assert.deepEqual(moves, ['ch:devel'])
      await sync.push()
      assert.equal(puts.length, 0, 'nothing moved locally: nothing to push')
      saveCursors({ ...loadCursors(store), 't:T9': { ts: T1, id: '', count: 4 } }, store)
      await sync.push()
      await sync.push()
      assert.deepEqual(puts, [{ 't:T9': { ts: T1, count: 4 } }])
    } finally {
      sync.stop()
    }
  })

  it('a failing hub leaves the local cursors alone and retries later', async () => {
    const store = memoryStore()
    saveCursors({ 'ch:devel': { ts: T0, id: 'a' } }, store)
    let calls = 0
    const sync = createReadSync({ base: '', token: 't', credentials: 'omit' }, { store, fetchFn: async () => { calls++; throw new Error('offline') } })
    try {
      assert.deepEqual(await sync.ready, [])
      await sync.push()
      await sync.push()
      assert.equal(calls, 3)
      assert.deepEqual(loadCursors(store), { 'ch:devel': { ts: T0, id: 'a' } })
    } finally {
      sync.stop()
    }
  })
})
