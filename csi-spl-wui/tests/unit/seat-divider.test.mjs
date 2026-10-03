import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { seatDividerId, seatedAtFor } from '../../src/utils/seat-divider.mjs'

/* Spec 061 3.6, lane L10: a DM with a reused id shows "new holder since". */
const seat = '2026-10-03T09:00:00Z'
const old1 = { msg_id: 'o1', received_at: '2026-10-01T10:00:00Z' }
const old2 = { msg_id: 'o2', received_at: '2026-10-02T08:59:59.999Z' }
const new1 = { msg_id: 'n1', received_at: '2026-10-03T09:00:00.5Z' }
const new2 = { msg_id: 'n2', received_at: '2026-10-03T12:00:00Z' }

describe('seatDividerId', () => {
  it('marks the first message of the new holder, whatever the feed order', () => {
    assert.equal(seatDividerId([new2, old1, new1, old2], seat), 'n1')
    assert.equal(seatDividerId([old1, old2, new1, new2], seat), 'n1')
  })
  it('compares instants, not strings (fraction digits vs a whole second)', () => {
    const same = { msg_id: 's', received_at: '2026-10-03T09:00:00.000000001Z' }
    assert.equal(seatDividerId([old1, same], '2026-10-03T09:00:00Z'), 's')
    const before = { msg_id: 'b', received_at: '2026-10-03T08:59:59.9Z' }
    assert.equal(seatDividerId([before, new2], seat), 'n2')
  })
  it('falls back to ts when the hub received_at is missing', () => {
    assert.equal(seatDividerId([{ msg_id: 'x', ts: '2026-10-03T10:00:00Z' }, old1], seat), 'x')
  })
  it('draws nothing without a previous holder on screen', () => {
    assert.equal(seatDividerId([new1, new2], seat), '')
  })
  it('draws nothing when the current holder has not written yet', () => {
    assert.equal(seatDividerId([old1, old2], seat), '')
  })
  it('draws nothing without a seat time (an id seated before rdb 0107, a human)', () => {
    assert.equal(seatDividerId([old1, new1], ''), '')
    assert.equal(seatDividerId([old1, new1], undefined), '')
    assert.equal(seatDividerId([old1, new1], 'garbage'), '')
    assert.equal(seatDividerId(null, seat), '')
  })
})

describe('seatedAtFor', () => {
  const boxes = { 'box-a': { online: true, last_hello_at: '', seated_at: { 'c-004': seat } } }
  it('reads the agent seat on its own box', () => {
    assert.equal(seatedAtFor(boxes, 'c-004', 'box-a'), seat)
  })
  it('is empty for another box, another id, or no box', () => {
    assert.equal(seatedAtFor(boxes, 'c-004', 'box-b'), '')
    assert.equal(seatedAtFor(boxes, 'c-005', 'box-a'), '')
    assert.equal(seatedAtFor(boxes, 'c-004', ''), '')
    assert.equal(seatedAtFor({ 'box-a': { online: false, last_hello_at: '' } }, 'c-004', 'box-a'), '')
  })
})
