import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  loadCursors,
  saveCursors,
  isUnread,
  advanceCursor,
  markReadAt,
  CURSOR_KEY,
} from '../../src/utils/read-cursor.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

describe('local read cursors', () => {
  it('round-trips JSON through storage try/catch', () => {
    const store = memoryStore()
    assert.deepEqual(loadCursors(store), {})
    const cursors = { 'ch:alerts': { ts: '2026-09-19T05:00:00Z', id: 'm1' } }
    saveCursors(cursors, store)
    assert.equal(Boolean(store.getItem(CURSOR_KEY)), true)
    assert.deepEqual(loadCursors(store), cursors)
    const boom = { getItem() { throw new Error('x') }, setItem() { throw new Error('x') } }
    assert.deepEqual(loadCursors(boom), {})
    assert.equal(saveCursors(cursors, boom), false)
  })

  it('treats missing cursor as unread and equal ts+id as read', () => {
    const m = { ts: '2026-09-19T05:00:00Z', msg_id: 'a' }
    assert.equal(isUnread(m, null), true)
    assert.equal(isUnread(m, { ts: '2026-09-19T04:00:00Z', id: 'z' }), true)
    assert.equal(isUnread(m, { ts: '2026-09-19T05:00:00Z', id: 'a' }), false)
    assert.equal(isUnread({ ts: '2026-09-19T05:00:00Z', msg_id: 'b' }, { ts: '2026-09-19T05:00:00Z', id: 'a' }), true)
  })

  it('advances to the newer ts and markReadAt writes the key', () => {
    const older = { ts: '2026-09-19T05:00:00Z', id: 'a' }
    const newer = advanceCursor(older, { ts: '2026-09-19T06:00:00Z', msg_id: 'b' })
    assert.deepEqual(newer, { ts: '2026-09-19T06:00:00Z', id: 'b' })
    const same = advanceCursor(newer, { ts: '2026-09-19T05:00:00Z', msg_id: 'a' })
    assert.deepEqual(same, newer)
    const next = markReadAt({}, 'ch:lobby', { ts: '2026-09-19T06:00:00Z', msg_id: 'b' })
    assert.equal(next['ch:lobby'].id, 'b')
  })
})
