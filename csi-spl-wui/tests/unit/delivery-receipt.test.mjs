// The delivery receipt (CLE-3435).
//
// The hub already decides what happened to a message and says so on the ack:
// `sent` means it handed the message to the recipient's box, `queued` that the
// box is offline and it is being held. The client dropped both on the floor,
// which is why a human had no evidence their message had ARRIVED until a reply
// came back - and a reply contains a model turn, ~14 s. Arrival itself is known
// in ~83 ms, measured on the live dev path.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { rowFromAck } from '../../src/utils/channel-feed.mjs'

const frame = { task_id: 't1', body: 'hello', to: 'CLE-00' }

describe('rowFromAck carries the hub delivery receipt', () => {
  it('keeps delivery and to_box when the hub reports them', () => {
    const row = rowFromAck(
      { msg_id: 'm1', task_id: 't1', received_at: '2026-09-21T13:00:00Z', delivery: 'sent', to_box: 'box-desk' },
      frame,
      { from: 'HUM-1' },
    )
    assert.equal(row.delivery, 'sent')
    assert.equal(row.to_box, 'box-desk')
    // …and it did not disturb the card it already built
    assert.equal(row.msg_id, 'm1')
    assert.equal(row.body, 'hello')
    assert.equal(row.task_id, 't1')
    assert.equal(row.from, 'HUM-1')
  })

  it('distinguishes queued from sent - they mean different things to a reader', () => {
    const row = rowFromAck({ msg_id: 'm2', task_id: 't1', delivery: 'queued', to_box: 'box-desk' }, frame)
    assert.equal(row.delivery, 'queued')
  })

  it('leaves the field ABSENT when the hub said nothing, rather than inventing one', () => {
    // A default here would be a lie: the card would claim a receipt the hub
    // never gave, which is worse than showing no receipt at all.
    const row = rowFromAck({ msg_id: 'm3', task_id: 't1' }, frame)
    assert.equal('delivery' in row, false)
    assert.equal('to_box' in row, false)
  })

  it('survives a null ack without throwing', () => {
    const row = rowFromAck(null, frame, { from: 'HUM-1' })
    assert.equal('delivery' in row, false)
    assert.equal(row.body, 'hello')
  })
})
