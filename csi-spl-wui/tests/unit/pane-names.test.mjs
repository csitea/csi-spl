// The middle column that lists messages is the msgs page. The right column
// is the topic pane, named by the open topic.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('pane names', () => {
  for (const rel of ['src/pages/lobby.vue', 'src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue']) {
    it(`${rel} is the msgs page`, () => {
      const src = read(rel)
      assert.match(src, /data-pane="msgs"/)
      assert.match(src, /<FeedHeader\b/)
    })
  }

  /* SPL-941: the header's title is the channel / peer; "Msgs" names the pane
     for screen readers */
  it('FeedHeader carries the msgs pane name as its aria-label', () => {
    assert.match(read('src/components/FeedHeader.vue'), /:aria-label="t\('pane\.msgs'\)"/)
  })

  for (const rel of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
    it(`${rel} is the topic pane`, () => {
      const src = read(rel)
      assert.match(src, /data-pane="topic"/)
      assert.match(src, /:aria-label="heading"/)
    })
  }
})
