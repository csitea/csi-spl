// Spec 071 7.4.1 + 7.8 "summary table" (SPL-6239 row T9): the row builder of
// the summary table at the top of Monitoring > Boxes. One row per box in the
// order given, every reading from the box's NEWEST sample (as the card below
// it), RAM used % and the fullest mount's df Use% rounded up; a box with no
// sample has no readings (the table says boxes.now_none), never 0.
//
// Run: node tests/unit/box-summary.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { memUsedPct } from '../../src/utils/box-resources.mjs'
import { boxSummaryRows, summarySampleOf } from '../../src/utils/box-summary.mjs'

const OLD = { box: 'box-a', at: '2026-11-22T09:00:00Z', load1: 0.5, cpus: 4, mem_total_kb: 1000, mem_avail_kb: 900, swap_used_kb: 0, agents_live: 1 }
const NEW = {
  box: 'box-a', at: '2026-11-22T09:05:00Z', load1: 2.25, cpus: 4, mem_total_kb: 1000, mem_avail_kb: 333, swap_used_kb: 0, agents_live: 3,
  disks: [{ mount: '/', total_kb: 1000, avail_kb: 600, used_kb: 300 }, { mount: '/var', total_kb: 1000, avail_kb: 50, used_kb: 900 }],
}

describe('memUsedPct', () => {
  it('used / (used + avail), rounded up; 0 with nothing reported', () => {
    assert.equal(memUsedPct({ memUsedKB: 667, memAvailKB: 333 }), 67)
    assert.equal(memUsedPct({ memUsedKB: 1, memAvailKB: 999 }), 1)
    assert.equal(memUsedPct({ memUsedKB: 0, memAvailKB: 0 }), 0)
    assert.equal(memUsedPct(null), 0)
  })
})

describe('boxSummaryRows', () => {
  const boxes = [
    { id: 'box-a', tag: 'a', online: true },
    { id: 'box-b', tag: 'b', online: false },
  ]
  /* the older sample first: the newest must win wherever it sits */
  const rows = boxSummaryRows(boxes, [OLD, NEW, { ...OLD, box: 'box-z' }])

  it('one row per box, in the order given', () => {
    assert.deepEqual(rows.map((r) => [r.id, r.tag, r.online]), [['box-a', 'a', true], ['box-b', 'b', false]])
  })
  it('the readings are the newest sample\'s', () => {
    assert.deepEqual(rows[0].sample, {
      at: '2026-11-22T09:05:00Z', ramPct: 67, ramFreeKB: 333, disk: { mount: '/var', pct: 95 }, load1: 2.25, cpus: 4, agentsLive: 3,
    })
  })
  it('a box with no sample has none, never zeros', () => {
    assert.equal(rows[1].sample, null)
  })
  it('a sample without disks has no fullest disk', () => {
    assert.equal(summarySampleOf(OLD).disk, null)
    assert.equal(summarySampleOf(OLD).ramPct, 10)
  })
  it('no boxes, no rows', () => {
    assert.deepEqual(boxSummaryRows(null, [NEW]), [])
  })
})
