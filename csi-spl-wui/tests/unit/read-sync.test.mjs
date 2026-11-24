import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mergeMarks, pendingMarks, wireMark, laterThan, createReadSync, channelMoves } from '../../src/utils/read-sync.mjs'
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

  it('ap-05: the echo of its own channel read (same time, id filled in) moves nothing and is not pushed again; a later mark still moves', async () => {
    const store = memoryStore()
    saveCursors({ 'ch:lobby': { ts: T0, id: '', hub: 'H0' } }, store)
    const hub = {}
    const puts = []
    const fetchFn = async (_url, opts) => {
      if (opts.method === 'PUT') {
        const { marks } = JSON.parse(opts.body)
        puts.push(marks)
        for (const [k, m] of Object.entries(marks)) hub[k] = { ts: m.ts, id: 'm-at-t0', cursor: m.cursor }
      }
      return { ok: true, json: async () => ({ marks: hub }) }
    }
    const moves = []
    const sync = createReadSync({ base: '', token: '', credentials: 'include' }, { fetchFn, store, onMoved: (m) => moves.push(...m) })
    try {
      await sync.ready
      await sync.push()
      await sync.push()
      assert.equal(puts.length, 1, 'one PUT, then nothing pending')
      assert.deepEqual(moves, [], 'the echo is not a new mark: no channel reload')
      assert.deepEqual(loadCursors(store)['ch:lobby'], { ts: T0, id: '', hub: 'H0' })
      hub['ch:lobby'] = { ts: T1, id: 'm-other-device', cursor: 'H1' }
      await sync.pull()
      assert.deepEqual(moves, ['ch:lobby'], 'a read on another device still merges and reloads')
      assert.deepEqual(loadCursors(store)['ch:lobby'], { ts: T1, id: 'm-other-device', hub: 'H1' })
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

// p20-06 (SPL-6428), prd n=1 session: a channel page re-sent its row cursor
// (the channel's newest message) every 5 s; each PUT's answer carried a later
// wall-clock mark with no id, the key moved, and each move reloaded the list.
describe('p20-06: a ch: move that leaves nothing unread does not reload the channel list', () => {
  const ROW_TS = '2026-10-14T09:53:52.845251Z'
  const WALL = '2026-11-24T20:41:12.085Z'
  const cur = (ts, id) => Buffer.from(`${ts}|${id}`).toString('base64url')
  const row = { channel_id: 'lobby', last_ts: ROW_TS, last_cursor: cur(ROW_TS, 'm-last'), unread: 0 }

  /** the read-sync-boot onMoved rule: count the list reloads a PUT's answer causes */
  async function reloadsAfterPut(answer, rows, counts = {}) {
    const store = memoryStore()
    saveCursors({ 'ch:lobby': { ts: ROW_TS, id: '', hub: row.last_cursor } }, store)
    const fetchFn = async (_url, opts) => ({ ok: true, json: async () => ({ marks: opts.method === 'PUT' ? { 'ch:lobby': answer } : {} }) })
    let reloads = 0
    const onMoved = (moved) => {
      if (channelMoves(moved, loadCursors(store), rows, counts).reload) reloads++
    }
    const sync = createReadSync({ base: '', token: '', credentials: 'include' }, { fetchFn, store, onMoved })
    try {
      await sync.ready
      await sync.push()
    } finally {
      sync.stop()
    }
    return { reloads, cursor: loadCursors(store)['ch:lobby'] }
  }

  it('the observed answer (sent: the row cursor; answer: a later wall-clock mark, id "") moves the key and reloads 0 times', async () => {
    const { reloads, cursor } = await reloadsAfterPut({ ts: WALL }, [row])
    assert.equal(cursor.ts, WALL, 'the later mark still moves the local cursor')
    assert.equal(reloads, 0, 'nothing is unread in #lobby: no GET /v1/view/channels')
  })

  it('CONTROL: a mark from elsewhere before the row newest message (read partway) still reloads', async () => {
    const { reloads, cursor } = await reloadsAfterPut({ ts: '2026-10-14T09:53:52.9Z', id: 'm-mid', cursor: cur('2026-10-14T09:53:52.9Z', 'm-mid') },
      [{ ...row, last_ts: '2026-10-15T00:00:00Z', last_cursor: cur('2026-10-15T00:00:00Z', 'm-new') }])
    assert.equal(cursor.id, 'm-mid')
    assert.equal(reloads, 1)
  })

  it('CONTROL: a local badge above 0 (a live message may be newer than the row) still reloads', async () => {
    assert.equal((await reloadsAfterPut({ ts: WALL }, [row], { 'ch:lobby': 1 })).reloads, 1)
  })

  it('CONTROL: a moved key with no row still reloads', async () => {
    assert.equal((await reloadsAfterPut({ ts: WALL }, [])).reloads, 1)
  })

  it('channelMoves: at or past the newest message is in place; a same-ms tie needs the same msg id', () => {
    const tie = { ts: '2026-10-14T09:53:52.845Z' }
    assert.deepEqual(channelMoves(['ch:lobby', 't:x'], { 'ch:lobby': { ts: WALL, id: '' } }, [row]), { inPlace: ['ch:lobby'], reload: false })
    assert.deepEqual(channelMoves(['ch:lobby'], { 'ch:lobby': { ...tie, id: 'm-last' } }, [row]), { inPlace: ['ch:lobby'], reload: false })
    assert.deepEqual(channelMoves(['ch:lobby'], { 'ch:lobby': { ...tie, id: '' } }, [row]), { inPlace: [], reload: true })
    assert.deepEqual(channelMoves(['ch:lobby'], { 'ch:lobby': { ts: WALL } }, [{ channel_id: 'lobby' }]), { inPlace: [], reload: true })
    assert.deepEqual(channelMoves(['dm:HUM-1'], {}, []), { inPlace: [], reload: false })
  })
})
