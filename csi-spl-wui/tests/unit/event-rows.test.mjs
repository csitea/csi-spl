// pages/events.vue reads GET /api/v1/auth/events through eventRowsOf.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { eventRowsOf } from '../../src/utils/event-rows.mjs'

describe('eventRowsOf', () => {
  it('a body that is not an object, or has no events list, is no rows', () => {
    for (const d of [undefined, null, 0, 'x', true, {}, { events: null }, { events: {} }, { events: 'x' }]) {
      assert.deepEqual(eventRowsOf(d), [], JSON.stringify(d))
    }
  })

  it('skips non-object entries and a missing, bad or non-positive id', () => {
    const rows = eventRowsOf({ events: [null, 3, 'x', {}, { id: 'abc' }, { id: 0 }, { id: -4 }, { id: Infinity }, { id: 7 }] })
    assert.deepEqual(rows.map((r) => r.id), [7])
  })

  it('keeps at: null (and undefined) as null, received_at falls back to ""', () => {
    const [a, b] = eventRowsOf({ events: [{ id: 1, at: null }, { id: 2 }] })
    assert.equal(a.at, null)
    assert.equal(b.at, null)
    assert.equal(a.received_at, '')
  })

  it('coerces every field', () => {
    const [r] = eventRowsOf({ events: [{
      id: '12', error_id: 99, at: 1700000000, received_at: '2026-10-01T00:00:00Z',
      source: 'wui', status: '502', message: 0, route: undefined,
    }] })
    assert.deepEqual(r, {
      id: 12, error_id: '99', at: '1700000000', received_at: '2026-10-01T00:00:00Z',
      source: 'wui', status: 502, message: '', route: '',
    })
    assert.equal(eventRowsOf({ events: [{ id: 1, status: 'nope' }] })[0].status, 0)
  })

  it('keeps the list order', () => {
    assert.deepEqual(eventRowsOf({ events: [{ id: 3 }, { id: 1 }, { id: 2 }] }).map((r) => r.id), [3, 1, 2])
  })
})
