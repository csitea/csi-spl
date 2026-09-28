// CLE-35075: LiveFeed reads merge neighbors from ONE threadNeighbors() index
// per `rows` instead of sorting the thread for every card. This pins the
// index to the per-row answer it replaced, on generated feeds with the awkward
// shapes: mixed threads, equal timestamps, repeated msg_ids, rows without a
// task or an id, received_at vs ts.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { mergeableSource, mergeableSourceIn, neighborIn, threadNeighbor, threadNeighbors } from '../../src/utils/msg-menu.mjs'

/* the per-row implementation before CLE-35075, verbatim */
function at(m) { return String((m && (m.received_at || m.ts)) || '') }
function threadKey(m) { return String((m && m.task_id) || '') }
function oldNeighbor(rows, msg, which) {
  const id = String((msg && msg.msg_id) || '')
  const key = threadKey(msg)
  if (!id || !key || (which !== 'previous' && which !== 'next')) return null
  const peers = (Array.isArray(rows) ? rows : []).filter((m) => m && threadKey(m) === key && String(m.msg_id || ''))
  peers.sort((a, b) => {
    const c = at(a).localeCompare(at(b))
    return c !== 0 ? c : String(a.msg_id || '').localeCompare(String(b.msg_id || ''))
  })
  const i = peers.findIndex((m) => String(m.msg_id) === id)
  if (i < 0) return null
  if (which === 'previous') return i > 0 ? peers[i - 1] : null
  return i < peers.length - 1 ? peers[i + 1] : null
}
function oldMergeable(rows, m, lobby = '') {
  if (!m) return false
  const task = threadKey(m)
  if (m.is_parent === 0 || (task && task === String(lobby || ''))) return true
  return oldNeighbor(rows, m, 'previous') !== null
}

/* deterministic generator: a feed with collisions on purpose */
function feed(seed, n) {
  let s = seed
  const rnd = (k) => { s = (s * 1103515245 + 12345) % 2147483648; return s % k }
  const rows = []
  for (let i = 0; i < n; i++) {
    const r = {
      msg_id: rnd(10) === 0 ? '' : 'm' + rnd(n),
      task_id: rnd(12) === 0 ? '' : 't' + rnd(3),
      is_parent: rnd(4) === 0 ? 0 : 1,
    }
    const t = '2026-09-28T10:00:' + String(rnd(20)).padStart(2, '0') + 'Z'
    if (rnd(2)) r.received_at = t
    else r.ts = t
    rows.push(r)
  }
  return rows
}

describe('threadNeighbors index == per-row threadNeighbor', () => {
  for (const seed of [1, 7, 42, 99, 1234]) {
    it(`seed ${seed}: every row, both directions, and mergeable`, () => {
      const rows = feed(seed, 60)
      const index = threadNeighbors(rows)
      const probes = [...rows, { msg_id: 'm1', task_id: 'zz' }, null, {}]
      for (const m of probes) {
        for (const which of ['previous', 'next']) {
          assert.equal(neighborIn(index, m, which), oldNeighbor(rows, m, which))
          assert.equal(threadNeighbor(rows, m, which), oldNeighbor(rows, m, which))
        }
        for (const lobby of ['', 't1']) {
          assert.equal(mergeableSourceIn(index, m, lobby), oldMergeable(rows, m, lobby))
          assert.equal(mergeableSource(rows, m, lobby), oldMergeable(rows, m, lobby))
        }
      }
      assert.equal(neighborIn(index, rows[0], 'sideways'), null)
    })
  }

  it('LiveFeed builds the index once per rows, not per card', () => {
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/LiveFeed.vue'), 'utf8')
    assert.match(vue, /computed\(\(\) => threadNeighbors\(props\.rows\)\)/)
    assert.doesNotMatch(vue, /threadNeighbor\(props\.rows/)
  })
})
