// dc6d5e3f (owner, prd t1): a channel line that tags an agent also shows in
// the person's DM view of that agent - as a pointer card of its own topic,
// never a copy and never a new topic.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { dmPointerRow, dmPointerRows, mockDmPointers } from '../../src/utils/dm-pointer.mjs'

const tag = { msg_id: 'm1', task_id: 't1', channel: 'lobby', from: 'HUM-1', to: 'CLE-07', to_box: 'box-wui', is_parent: 0, parent_task_id: null }
const back = { msg_id: 'm2', task_id: 't1', channel: 'lobby', from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', is_parent: 0 }
const dm = { msg_id: 'm3', task_id: 't2', channel: null, from: 'HUM-1', to: 'CLE-07' }
const other = { msg_id: 'm4', task_id: 't1', channel: 'lobby', from: 'HUM-2', to: 'CLE-07' }
const otherBox = { msg_id: 'm5', task_id: 't1', channel: 'lobby', from: 'CLE-07', from_box: 'box-b', to: 'HUM-1' }

describe('dm pointers', () => {
  it('a channel line becomes a middle card of its own topic, marked pointer', () => {
    assert.deepEqual(dmPointerRow(tag), { ...tag, is_parent: 1, parent_task_id: null, pointer: true })
    assert.equal(dmPointerRow(dm), null, 'a DM is no pointer')
    assert.equal(dmPointerRow({ channel: 'lobby' }), null)
    assert.deepEqual(dmPointerRows([tag, dm, null]).map((r) => r.msg_id), ['m1'])
    assert.deepEqual(dmPointerRows(undefined), [])
  })
  it('the mock hub keeps the lines between me and the peer only', () => {
    const all = [tag, back, dm, other, otherBox]
    assert.deepEqual(mockDmPointers(all, 'HUM-1', 'CLE-07').map((r) => r.msg_id), ['m1', 'm2', 'm5'])
    assert.deepEqual(mockDmPointers(all, 'HUM-1', 'CLE-07@box-a').map((r) => r.msg_id), ['m1', 'm2'])
    assert.deepEqual(mockDmPointers(all, 'HUM-1', 'CLE-08'), [])
    assert.deepEqual(mockDmPointers(all, '', 'CLE-07'), [])
  })
})
