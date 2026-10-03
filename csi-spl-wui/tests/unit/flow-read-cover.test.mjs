// Owner, t1 56b8cc17 (HUM-10): a topic read on the phone left the unread
// numbers where they were. The mock Flow now drops a line once a read
// cursor of its topic (t:), channel (ch:) or DM peer (dm:) is at or past it,
// as the hub's read marks do (contract flow-v1 section 3).
//
// Run: node tests/unit/flow-read-cover.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mockCovered, mockFlowCounts, mockFlowKeys } from '../../src/utils/flow-badge.mjs'

const line = { msg_id: 'm1', task_id: 'T', channel: 'alerts', from: 'GRK-03', kind: 'mention', at: '2026-09-18T11:00:00Z' }
const dm = { msg_id: 'm2', task_id: 'D', channel: null, from: 'GRK-03', from_box: 'box-a', kind: 'dm', at: '2026-09-18T11:00:00Z' }

describe('mockCovered', () => {
  it('a t:, ch: or dm: cursor at or past the line covers it', () => {
    assert.equal(mockCovered(line, { 't:T': { ts: '2026-09-18T11:00:00Z' } }), true)
    assert.equal(mockCovered(line, { 'ch:alerts': { ts: '2026-09-18T12:00:00.000Z' } }), true)
    assert.equal(mockCovered(dm, { 'dm:GRK-03@box-a': { ts: '2026-09-18T12:00:00Z' } }), true)
    assert.equal(mockCovered(dm, { 'dm:GRK-03': { ts: '2026-09-18T12:00:00Z' } }), true)
  })
  it('an older cursor, another place, or none leaves it unread', () => {
    assert.equal(mockCovered(line, { 't:T': { ts: '2026-09-18T10:59:59Z' } }), false)
    assert.equal(mockCovered(line, { 'ch:lobby': { ts: '2026-09-18T12:00:00Z' } }), false)
    assert.equal(mockCovered(line, null), false)
  })
})

describe('the mock counts and keys honour the cursors', () => {
  it('a read topic leaves its row and the totals together', () => {
    const cursors = { 't:T': { ts: '2026-09-18T12:00:00Z' } }
    assert.deepEqual(mockFlowKeys([line, dm], new Set(), cursors), { 'dm:GRK-03@box-a': 1, 't:D': 1 })
    const c = mockFlowCounts([line, dm], '', new Set(), cursors)
    assert.equal(c.total, 1)
    assert.equal(c.channels, 0)
    assert.equal(c.dms, 1)
  })
  it('without cursors nothing changes', () => {
    assert.deepEqual(mockFlowKeys([line], new Set()), { 'ch:alerts': 1, 't:T': 1 })
  })
})
