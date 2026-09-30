import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  loadCursors,
  saveCursors,
  isUnread,
  advanceCursor,
  markReadAt,
  CURSOR_KEY,
  cursorFromChannel,
  unreadFromCursors,
  readParams,
  unreadFromChannels,
  readMap,
  firstUnreadId,
  countUnread,
  markTopicReadAt,
  topicUnread,
  topicKey,
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

describe('unread from stored cursors (gap A2, channels-v1 §5.2)', () => {
  const key = (m) => (m.channel ? `ch:${m.channel}` : `dm:${m.from}`)
  const msgs = [
    { msg_id: 'a', ts: '2026-09-19T05:00:00Z', channel: 'lobby' },
    { msg_id: 'b', ts: '2026-09-19T06:00:00Z', channel: 'lobby' },
    { msg_id: 'c', ts: '2026-09-19T07:00:00Z', channel: 'alerts' },
    { msg_id: 'd', ts: '2026-09-19T07:30:00Z', channel: null, from: 'CLE-2' },
  ]

  it('counts only messages newer than each key cursor, after a reload', () => {
    const store = memoryStore()
    saveCursors({ 'ch:lobby': { ts: '2026-09-19T05:00:00Z', id: 'a' } }, store)
    const reloaded = loadCursors(store)
    assert.deepEqual(unreadFromCursors(msgs, reloaded, key), { 'ch:lobby': 1, 'ch:alerts': 1, 'dm:CLE-2': 1 })
    assert.deepEqual(unreadFromCursors(msgs, { ...reloaded, 'ch:alerts': { ts: '2026-09-19T07:00:00Z', id: 'c' } }, key),
      { 'ch:lobby': 1, 'dm:CLE-2': 1 })
  })

  it('keeps the hub cursor and sends it back as read=<channel>~<cursor>', () => {
    const c = advanceCursor(null, { ts: '2026-09-19T05:00:00Z', msg_id: 'a', cursor: 'CUR1' })
    assert.deepEqual(c, { ts: '2026-09-19T05:00:00Z', id: 'a', hub: 'CUR1' })
    const row = cursorFromChannel({ channel: 'alerts', last_ts: '2026-09-19T07:00:00Z', last_cursor: 'CUR2' })
    assert.deepEqual(row, { ts: '2026-09-19T07:00:00Z', id: '', hub: 'CUR2' })
    assert.equal(cursorFromChannel({ channel: 'empty', last_ts: null }), null)
    assert.deepEqual(readParams({ 'ch:lobby': c, 'ch:alerts': row, 'dm:CLE-2': { ts: 'x', id: '', hub: 'NO' }, 'ch:tasks': { ts: 'y', id: '' } }),
      ['lobby~CUR1', 'alerts~CUR2'])
  })

  it('maps hub unread onto ch: keys', () => {
    assert.deepEqual(unreadFromChannels([
      { channel: 'lobby', unread: 2 }, { channel_id: 'alerts', unread: 0 }, { channel: 'tasks' },
    ]), { 'ch:lobby': 2, 'ch:alerts': 0 })
  })
})

describe('New-messages divider boundary (CLE-77804)', () => {
  const msgs = [
    { msg_id: 'a', ts: '2026-09-19T05:00:00Z' },
    { msg_id: 'b', ts: '2026-09-19T06:00:00Z' },
    { msg_id: 'c', ts: '2026-09-19T07:00:00Z' },
  ]
  it('first unread is the earliest message after the frozen boundary', () => {
    const cur = { ts: '2026-09-19T05:00:00Z', id: 'a' }
    assert.equal(firstUnreadId(msgs, cur), 'b')
    assert.equal(countUnread(msgs, cur), 2)
  })
  it('order of the array does not matter — it picks by timestamp', () => {
    const cur = { ts: '2026-09-19T06:00:00Z', id: 'b' }
    assert.equal(firstUnreadId([...msgs].reverse(), cur), 'c')
    assert.equal(countUnread([...msgs].reverse(), cur), 1)
  })
  it('nothing new once the boundary is at the newest', () => {
    const cur = { ts: '2026-09-19T07:00:00Z', id: 'c' }
    assert.equal(firstUnreadId(msgs, cur), '')
    assert.equal(countUnread(msgs, cur), 0)
  })
  it('a never-read feed (no boundary) draws no divider', () => {
    assert.equal(firstUnreadId(msgs, null), '')
    assert.equal(firstUnreadId(msgs, { ts: '', id: '' }), '')
    assert.equal(countUnread(msgs, null), 0)
  })
  it("the reader's own messages are never new (HUM-24, topic 311427c6)", () => {
    const cur = { ts: '2026-09-19T05:00:00Z', id: 'a' }
    const mixed = [
      { msg_id: 'b', ts: '2026-09-19T06:00:00Z', from: 'HUM-1@box-wui' }, // own
      { msg_id: 'c', ts: '2026-09-19T07:00:00Z', from: 'HUM-2' },         // someone else
    ]
    assert.equal(countUnread(mixed, cur, 'HUM-1'), 1)          // only c
    assert.equal(firstUnreadId(mixed, cur, 'HUM-1'), 'c')      // the divider skips own b
    assert.equal(countUnread(mixed, cur, 'HUM-1@box-wui'), 1)  // box-qualified self matches
    assert.equal(countUnread(mixed, cur, ''), 2)               // no self given: both count
  })
})

describe('per-topic unread ("2/7 >>", CLE-77804 topic 35053f95)', () => {
  it('unread = current total minus the total seen at last open', () => {
    const cur = markTopicReadAt({}, 'task-1', 5)[topicKey('task-1')]
    assert.equal(cur.count, 5)
    assert.equal(topicUnread(7, cur), 2)   // 2 new -> "2/7"
    assert.equal(topicUnread(5, cur), 0)   // just opened -> plain "5"
  })
  it('a never-opened topic (no cursor) is 0, so the card shows a plain total', () => {
    assert.equal(topicUnread(7, undefined), 0)
    assert.equal(topicUnread(7, { ts: 'x', id: '' }), 0) // a cursor with no count snapshot
  })
  it('never negative when the total dropped below the snapshot (a delete)', () => {
    const cur = markTopicReadAt({}, 'task-1', 7)[topicKey('task-1')]
    assert.equal(topicUnread(6, cur), 0)
  })
})

describe('read map for spool-client listChannels({ read })', () => {
  it('keeps only channel keys with a hub cursor', () => {
    assert.deepEqual(readMap({
      'ch:lobby': { ts: 'a', id: '', hub: 'C1' }, 'ch:tasks': { ts: 'b', id: '' }, 'dm:X': { ts: 'c', id: '', hub: 'C2' },
    }), { lobby: 'C1' })
  })
})

describe('read cursor from a live frame (H4)', () => {
  it('a live frame cursor on the open channel becomes the next read= param', () => {
    const frame = { msg_id: 'm1', channel: 'lobby', received_at: '2026-09-19T09:00:00.123456Z', cursor: 'cur-R' }
    const cursors = markReadAt({ 'ch:lobby': { ts: '2026-09-19T08:00:00Z', id: 'old', hub: 'cur-old' } }, 'ch:lobby', frame)
    assert.deepEqual(cursors['ch:lobby'], { ts: frame.received_at, id: 'm1', hub: 'cur-R' })
    assert.deepEqual(readParams(cursors), ['lobby~cur-R'])
  })
})
