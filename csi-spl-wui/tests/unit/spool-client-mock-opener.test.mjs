// SPL-6205: the mock's channel read keeps a long topic's opening line, as the
// live listMessages does, so the channel keeps that topic's card when the
// topic holds more lines than the read's cap. Synthetic rows only.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mockListMessages } from '../../src/utils/spool-client-mock.mjs'

const row = (i, task, extra = {}) => ({ msg_id: `m-${task}-${i}`, task_id: task, channel: 'c1', ts: `2026-01-01T00:${String(i).padStart(2, '0')}:00Z`, body: `line ${i}`, ...extra })

describe('mockListMessages cap', () => {
  it('keeps the opener of a topic longer than the cap, plus the newest lines', () => {
    const rows = [row(0, 't1', { is_parent: 1 }), ...Array.from({ length: 40 }, (_, k) => row(k + 1, 't1', { is_parent: 0 }))]
    const { messages } = mockListMessages({ messages: rows }, { channel: 'c1', limit: 30 })
    assert.equal(messages.length, 31, 'the opener and the newest 30')
    assert.equal(messages[0].msg_id, 'm-t1-0', 'the opening line is kept')
    assert.deepEqual(messages.slice(1).map((m) => m.msg_id), rows.slice(-30).map((m) => m.msg_id))
  })

  it('a feed within the cap is returned whole, in order', () => {
    const rows = [row(0, 'a'), row(1, 'b'), row(2, 'a')]
    const { messages } = mockListMessages({ messages: rows }, { channel: 'c1', limit: 30 })
    assert.deepEqual(messages.map((m) => m.msg_id), rows.map((m) => m.msg_id))
  })
})
