// CLE-35075: channel.repliesFor reads one topicReplyIndex per `messages`
// instead of walking every held row for every card. This pins the index to
// the per-card topicReplies it replaced (verbatim copy below) on generated
// channels: topic rows, repeated topic rows, children, pending rows, hub
// totals with and without a usable last_ts.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { topicReplies, topicReplyIndex, topicRepliesIn, replyCount } from '../../src/utils/channel-feed.mjs'


function msgAt(m) { return Date.parse(String(m.received_at || m.ts || '')) }
function oldReplies(messages, taskId, total) {
  if (!taskId) return 0
  const list = messages || []
  const row = list.find((m) => m.topic_row && m.task_id === taskId)
  const children = replyCount(list, taskId)
  if (row) return children + (Number(row.count) || 0)
  const same = list.filter((m) => m.task_id === taskId && !m.topic_row)
  const held = Math.max(0, same.length - 1)
  const n = Number(total && total.count) || 0
  if (n <= 0) return children + held
  const at = Date.parse(String(total.last_ts || ''))
  const later = Number.isFinite(at) ? same.filter((m) => m.pending || msgAt(m) > at).length : 0
  return children + Math.max(held, n - 1 + later)
}

function channel(seed, n) {
  let s = seed
  const rnd = (k) => { s = (s * 1103515245 + 12345) % 2147483648; return s % k }
  return Array.from({ length: n }, (_, i) => {
    const r = { msg_id: 'm' + i, task_id: 't' + rnd(6), ts: '2026-09-28T10:00:' + String(rnd(50)).padStart(2, '0') + 'Z' }
    if (rnd(5) === 0) { r.topic_row = true; r.count = rnd(9) }
    if (rnd(4) === 0) r.parent_task_id = 't' + rnd(6)
    if (rnd(7) === 0) r.parent_task_id = null
    if (rnd(9) === 0) r.pending = true
    if (rnd(3) === 0) r.received_at = '2026-09-28T10:00:' + String(rnd(50)).padStart(2, '0') + 'Z'
    return r
  })
}

describe('topicReplyIndex == per-card topicReplies', () => {
  for (const seed of [2, 5, 77, 2026]) {
    it(`seed ${seed}`, () => {
      const rows = channel(seed, 90)
      const index = topicReplyIndex(rows)
      const totals = [undefined, null, { count: 0 }, { count: 4, last_ts: '2026-09-28T10:00:20Z' }, { count: 30, last_ts: 'garbage' }]
      for (const task of ['', 't0', 't1', 't2', 't3', 't4', 't5', 'tX']) {
        for (const total of totals) {
          assert.equal(topicRepliesIn(index, task, total), oldReplies(rows, task, total), `${task} ${JSON.stringify(total)}`)
          assert.equal(topicReplies(rows, task, total), oldReplies(rows, task, total))
        }
      }
    })
  }

  it('the channel store builds the index once per messages', () => {
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/stores/channel.ts'), 'utf8')
    assert.match(src, /computed\(\(\) => topicReplyIndex\(messages\.value\)\)/)
    assert.match(src, /topicRepliesIn\(replyIndex\.value, taskId/)
  })
})

