// Spec 079 (topic 3a74320e): one unread model, shown on the row. The rows,
// the section sums and the tab title come from one pure function, so they
// can never disagree (owner 92c4b3e8, da315c54).
//
// Run: node tests/unit/unread-model.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { unreadModel } from '../../src/utils/unread-model.mjs'

// AC1's fixed input: 2 unread in t:A, 1 in dm:B, 3 in muted ch:C.
const KEYS = { 't:A': 2, 'dm:B': 1, 'ch:C': 3 }
const LOCAL = {
  cursors: { 't:A': { ts: '2026-10-04T10:00:00Z', id: '', count: 3 } },
  channelUnread: { 'ch:C': 3 },
  dmUnread: { 'dm:B': 1 },
  topics: [{ task_id: 'A', total: 5 }],
}
const MUTED = ['C']

describe('unreadModel AC1: rows, sections, title', () => {
  const m = unreadModel({ keys: KEYS, muted: MUTED })

  it('each place carries its own number, muted included', () => {
    assert.equal(m.rows.get('t:A'), 2)
    assert.equal(m.rows.get('dm:B'), 1)
    assert.equal(m.rows.get('ch:C'), 3)
  })

  it('the title is the row sum without the muted channel', () => {
    assert.equal(m.title, 3)
  })

  it('section sums are the rows of that section, muted shown', () => {
    assert.deepEqual(m.sections, { channels: 3, dms: 1, topics: 2 })
  })

  it('unmuted, the title is every row', () => {
    assert.equal(unreadModel({ keys: KEYS }).title, 6)
  })
})

describe('unreadModel AC2: hub keys and local cursors agree', () => {
  it('the same state as keys and as local inputs yields the same map', () => {
    const hub = unreadModel({ keys: KEYS, muted: MUTED })
    const local = unreadModel({ ...LOCAL, muted: MUTED })
    assert.deepEqual([...local.rows].sort(), [...hub.rows].sort())
    assert.deepEqual(local.sections, hub.sections)
    assert.equal(local.title, hub.title)
  })

  it('topic messages counted against the cursor give the same t: value', () => {
    const cursors = { 't:A': { ts: '2026-10-04T10:00:00Z', id: '' } }
    const messages = [
      { msg_id: 'm1', ts: '2026-10-04T09:00:00Z', from: 'c-002' },
      { msg_id: 'm2', ts: '2026-10-04T11:00:00Z', from: 'c-002' },
      { msg_id: 'm3', ts: '2026-10-04T12:00:00Z', from: 'c-002' },
      { msg_id: 'm4', ts: '2026-10-04T12:30:00Z', from: 'HUM-10' },
    ]
    const m = unreadModel({ cursors, topics: [{ task_id: 'A', messages }], self: 'HUM-10' })
    assert.equal(m.rows.get('t:A'), 2)
  })
})

describe('unreadModel: hub keys win (spec Q3)', () => {
  it('a key the hub sent overrides the local count, a local-only place reads 0', () => {
    const m = unreadModel({ ...LOCAL, keys: { 't:A': 4 } })
    assert.equal(m.rows.get('t:A'), 4)
    assert.equal(m.rows.has('dm:B'), false)
    assert.equal(m.title, 4)
  })

  it('a topic never opened shows no unread (plain total)', () => {
    const m = unreadModel({ topics: [{ task_id: 'Z', total: 9 }] })
    assert.equal(m.rows.size, 0)
    assert.equal(m.title, 0)
  })
})

describe('unreadModel: defensive input', () => {
  it('no input -> empty model', () => {
    const m = unreadModel()
    assert.equal(m.rows.size, 0)
    assert.deepEqual(m.sections, { channels: 0, dms: 0, topics: 0 })
    assert.equal(m.title, 0)
  })

  it('zero, negative and junk counts are left out of rows', () => {
    const m = unreadModel({ keys: { 'ch:a': 0, 'ch:b': -2, 'dm:c': 'x', 't:d': 1.9 } })
    assert.deepEqual([...m.rows], [['t:d', 1]])
  })
})
