// CLE-35075: the live and channel stores hold their rows in a shallowRef.
// That is only correct while nothing mutates the array or a row in place -
// a shallowRef does not see an in-place change, so the screen would keep the
// old row. Two pins: every helper the stores feed `messages.value` to leaves
// its (deep-frozen) input alone, and the stores only ever assign the array.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { mergeById, withoutMsg, newestFirst, matchesSearch, rootAndReplies, windowed } from '../../src/utils/feed.mjs'
import { mergeLive, mergePage, channelView, topLevel, rootsByTask, topicReplyIndex } from '../../src/utils/channel-feed.mjs'
import { applyEdit } from '../../src/utils/msg-edit.mjs'
import { applyReactions } from '../../src/utils/emoji.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

function deepFreeze(x) {
  if (x && typeof x === 'object' && !Object.isFrozen(x)) {
    Object.freeze(x)
    for (const v of Object.values(x)) deepFreeze(v)
  }
  return x
}

function held() {
  return deepFreeze([
    { msg_id: 'a', task_id: 't', ts: '2026-09-28T10:00:01Z', body: 'one', reactions: [{ emoji: '👍', count: 1 }] },
    { msg_id: 'b', task_id: 't', ts: '2026-09-28T10:00:02Z', body: 'two', pending: true },
    { msg_id: 'c', task_id: 'u', ts: '2026-09-28T10:00:03Z', body: 'three', topic_row: true, count: 2 },
  ])
}

describe('store helpers never mutate the held rows', () => {
  it('each one returns without touching a deep-frozen input', () => {
    const rows = held()
    const before = JSON.stringify(rows)
    mergeById(rows, [{ msg_id: 'b', task_id: 't', ts: '2026-09-28T10:00:02Z' }, { msg_id: 'd', task_id: 't' }, { msg_id: 'a', reactions: [] }])
    withoutMsg(rows, 'a')
    newestFirst(rows)
    rootAndReplies(rows.filter((m) => matchesSearch(m, 'o')))
    windowed(rows, 1)
    mergeLive(rows, { msg_id: 'b', task_id: 't' })
    mergeLive(rows, { msg_id: 'e', task_id: 'u', ts: '2026-09-28T10:00:09Z' })
    mergeLive(rows, { msg_id: 'f', task_id: 'z' })
    mergePage(rows, [{ msg_id: 'c', task_id: 'u' }, { msg_id: 'g', task_id: 'u' }])
    channelView(rows, { search: '', visible: 30 })
    rootsByTask(topLevel(rows))
    topicReplyIndex(rows)
    applyEdit(rows, { msg_id: 'a', body: 'edited' })
    applyReactions(rows, { msg_id: 'a', reactions: [] })
    assert.equal(JSON.stringify(rows), before)
  })

  it('a change comes back as a NEW array (so a shallowRef assignment triggers)', () => {
    const rows = held()
    assert.notEqual(mergeById(rows, [{ msg_id: 'd' }]).rows, rows)
    assert.notEqual(mergeLive(rows, { msg_id: 'd', task_id: 'x' }), rows)
    assert.notEqual(mergePage(rows, [{ msg_id: 'd' }]), rows)
    assert.notEqual(applyEdit(rows, { msg_id: 'a', body: 'x' }), rows)
    assert.notEqual(applyReactions(rows, { msg_id: 'a', reactions: [] }), rows)
    assert.notEqual(withoutMsg(rows, 'a'), rows)
  })
})

describe('the stores only assign messages whole', () => {
  for (const f of ['stores/live.ts', 'stores/channel.ts']) {
    it(f, () => {
      const src = readFileSync(join(SRC, f), 'utf8')
      assert.match(src, /const messages = shallowRef</)
      assert.doesNotMatch(src, /messages\.value\.(push|splice|sort|reverse|unshift|pop|shift|fill)\(/)
      assert.doesNotMatch(src, /messages\.value\[[^\]]+\]\s*=[^=]/)
    })
  }
})
