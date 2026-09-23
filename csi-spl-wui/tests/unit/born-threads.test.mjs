// While the right pane is open, an Omnibox line that starts a new message
// is another thread at the top of that pane. An `in:` reply is not, and a
// closed pane does not collect one.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dismissBornThread, noteBornThread } from '../../src/utils/born-threads.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('a new thread pops up at the top of the open right pane', () => {
  it('prepends, newest first, and replaces a repeat of the same message', () => {
    let rows = noteBornThread([], true, '', { msg_id: 'a', body: 'first' })
    rows = noteBornThread(rows, true, undefined, { msg_id: 'b', body: 'second' })
    assert.deepEqual(rows.map((m) => m.msg_id), ['b', 'a'])
    rows = noteBornThread(rows, true, '', { msg_id: 'a', body: 'first again' })
    assert.deepEqual(rows.map((m) => m.msg_id), ['a', 'b'])
    assert.equal(rows[0].body, 'first again')
  })

  it('a closed pane and an in: reply leave the list alone', () => {
    const rows = [{ msg_id: 'a', body: 'first' }]
    assert.equal(noteBornThread(rows, false, '', { msg_id: 'b' }), rows)
    assert.equal(noteBornThread(rows, true, 'T-9', { msg_id: 'b' }), rows)
    assert.deepEqual(noteBornThread(rows, true, '', { body: 'no id' }), rows)
    assert.deepEqual(noteBornThread(null, true, '', null), [])
  })

  it('opening one removes only that card', () => {
    const rows = [{ msg_id: 'b' }, { msg_id: 'a' }]
    assert.deepEqual(dismissBornThread(rows, 'b').map((m) => m.msg_id), ['a'])
    assert.deepEqual(dismissBornThread(rows, ''), rows)
  })

  it('both right panes render the stack above the open thread', () => {
    for (const rel of ['src/components/ThreadPane.vue', 'src/components/LiveThreadPane.vue']) {
      const s = src(rel)
      const born = s.indexOf('<BornThreads')
      const root = s.indexOf('pinned-root')
      assert.ok(born > 0 && born < root, rel)
    }
  })

  it('channel and DM note a born thread only from the Omnibox send', () => {
    for (const rel of ['src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue']) {
      const s = src(rel)
      assert.match(s, /thread\.noteBorn\(thread\.open \|\| Boolean\(livePane\.taskId\), threadId, sent/)
    }
  })
})
