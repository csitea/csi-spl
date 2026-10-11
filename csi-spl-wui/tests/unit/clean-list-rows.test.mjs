// spec 082 T003 AC4 (FR-004): both Topics lists named a row with the one
// builder, rowTitle (src/utils/view-api.mjs); no local topicRowTitle and no
// `Topic:` label (topic.list_title) in either list. Owner HUM-10 (t1
// e4bfddb1) removed both lists (the sidebar Topics panel and `/`): no topic
// row is left there, and no local title builder came back with the removal.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('clean list rows: one row-title builder (AC4)', () => {
  for (const rel of ['src/pages/index.vue', 'src/components/ChannelSidebar.vue']) {
    it(`${rel}: no topic list, no topicRowTitle, no topic.list_title`, () => {
      const s = src(rel)
      assert.equal((s.match(/topicRowTitle/g) || []).length, 0)
      assert.doesNotMatch(s, /topic\.list_title/)
      assert.doesNotMatch(s, /rowTitle\((t|row)\.subject\)/, 'the Topics list rows are gone')
      assert.doesNotMatch(s, /viewer\.topics/)
    })
  }
  it('rowTitle stays the one builder (control: it is still exported)', () => {
    assert.match(src('src/utils/view-api.mjs'), /export function rowTitle\(/)
  })
})
