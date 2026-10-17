import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { unreadLandingId } from '../../src/utils/unread-landing.mjs'
import { topicBoundary } from '../../src/utils/read-cursor.mjs'
import { displayOrder } from '../../src/utils/view-prefs.mjs'

/* SPL-2430 (owner, t1 89010926): a feed opens where its unseen messages start, per message order. */
const boundary = { ts: '2026-09-18T10:00:00.000Z', id: '' }
const row = (id, ts, from = 'GRK-03') => ({ msg_id: id, ts, received_at: ts, from })
const seen1 = row('s1', '2026-09-18T08:00:00.000Z')
const seen2 = row('s2', '2026-09-18T09:00:00.000Z')
const new1 = row('n1', '2026-09-18T11:00:00.000Z')
const new2 = row('n2', '2026-09-18T12:00:00.000Z')
const own = row('own', '2026-09-18T13:00:00.000Z', 'HUM-2')
/* newest first, as the stores hold them (displayOrder flips them for newest-last) */
const rows = [own, new2, new1, seen2, seen1]
const shown = (order) => displayOrder(rows, order)

describe('unreadLandingId', () => {
  it('newest-last: the first unseen, where the divider goes', () => {
    assert.equal(unreadLandingId(shown('newest-last'), boundary, 'HUM-2', true), 'n1')
  })
  it('newest-first: the top of the unseen block, the newest unseen', () => {
    assert.equal(unreadLandingId(shown('newest-first'), boundary, 'HUM-2', false), 'n2')
  })
  it('the reader\'s own rows are never where it opens', () => {
    assert.equal(unreadLandingId(shown('newest-first'), boundary, 'HUM-2', false), 'n2')
    assert.equal(unreadLandingId([own], boundary, 'HUM-2', false), '')
    assert.equal(unreadLandingId([own], boundary, 'HUM-2', true), '')
  })
  it('nothing unseen, or a feed never read: no landing', () => {
    assert.equal(unreadLandingId([seen1, seen2], boundary, '', true), '')
    assert.equal(unreadLandingId([seen2, seen1], boundary, '', false), '')
    assert.equal(unreadLandingId(rows, null, '', true), '')
    assert.equal(unreadLandingId(rows, { ts: '' }, '', false), '')
  })
})

describe('topicBoundary', () => {
  it('is the topic mark\'s time, frozen before the open stamps it', () => {
    const cursors = { 't:T1': { ts: '2026-09-18T10:00:00.000Z', id: '', count: 3 }, 'ch:alerts': { ts: '2026-09-18T09:00:00.000Z', id: 'x' } }
    assert.deepEqual(topicBoundary(cursors, 'T1'), { ts: '2026-09-18T10:00:00.000Z', id: '' })
  })
  it('a topic never read has none (no divider)', () => {
    assert.equal(topicBoundary({ 'ch:alerts': { ts: '2026-09-18T09:00:00.000Z' } }, 'T1'), null)
    assert.equal(topicBoundary({}, ''), null)
    assert.equal(topicBoundary(null, 'T1'), null)
  })
})
