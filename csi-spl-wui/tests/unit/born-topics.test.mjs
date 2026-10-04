// While the right pane is open, an Omnibox line that starts a new message
// is another topic at the top of that pane. An `in:` reply is not, and a
// closed pane does not collect one.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dismissBornTopic, noteBornTopic } from '../../src/utils/born-topics.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('a new topic pops up at the top of the open right pane', () => {
  it('prepends, newest first, and replaces a repeat of the same message', () => {
    let rows = noteBornTopic([], true, '', { msg_id: 'a', body: 'first' })
    rows = noteBornTopic(rows, true, undefined, { msg_id: 'b', body: 'second' })
    assert.deepEqual(rows.map((m) => m.msg_id), ['b', 'a'])
    rows = noteBornTopic(rows, true, '', { msg_id: 'a', body: 'first again' })
    assert.deepEqual(rows.map((m) => m.msg_id), ['a', 'b'])
    assert.equal(rows[0].body, 'first again')
  })

  it('a closed pane and an in: reply leave the list alone', () => {
    const rows = [{ msg_id: 'a', body: 'first' }]
    assert.equal(noteBornTopic(rows, false, '', { msg_id: 'b' }), rows)
    assert.equal(noteBornTopic(rows, true, 'T-9', { msg_id: 'b' }), rows)
    assert.deepEqual(noteBornTopic(rows, true, '', { body: 'no id' }), rows)
    assert.deepEqual(noteBornTopic(null, true, '', null), [])
  })

  it('opening one removes only that card', () => {
    const rows = [{ msg_id: 'b' }, { msg_id: 'a' }]
    assert.deepEqual(dismissBornTopic(rows, 'b').map((m) => m.msg_id), ['a'])
    assert.deepEqual(dismissBornTopic(rows, ''), rows)
  })

  it('both right panes render the stack above the open topic', () => {
    for (const rel of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
      const s = src(rel)
      const born = s.indexOf('<BornTopics')
      const root = s.indexOf('pinned-root')
      assert.ok(born > 0 && born < root, rel)
      assert.match(s, /data-test="topic-heading"/)
      assert.match(s, /t\('topic\.list_title'/)
    }
  })

  /* SPL-996: a page whose list already shows the new topic must not also
     draw a born card in the thread. /t/<id> now has that list, so it bumps
     the row and does not call noteBorn. */
  it('channel, DM, the Topics list and the topic page draw a new topic once', () => {
    for (const rel of ['src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue', 'src/pages/index.vue', 'src/pages/t/[task_id].vue']) {
      assert.doesNotMatch(src(rel), /noteBorn\(/, rel)
    }
    assert.match(src('src/pages/t/[task_id].vue'), /bumpTopic\(/)
  })
})
