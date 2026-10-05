// spec 082 T003 AC4 (FR-004): both Topics lists name a row with the one
// builder, rowTitle (src/utils/view-api.mjs); no local topicRowTitle and no
// `Topic:` label (topic.list_title) left in either list.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('clean list rows: one row-title builder (AC4)', () => {
  for (const rel of ['src/pages/index.vue', 'src/components/ChannelSidebar.vue']) {
    it(`${rel}: rowTitle, no topicRowTitle, no topic.list_title`, () => {
      const s = src(rel)
      assert.equal((s.match(/topicRowTitle/g) || []).length, 0)
      assert.doesNotMatch(s, /topic\.list_title/)
      assert.match(s, /import \{ rowTitle \} from '~\/utils\/view-api\.mjs'/)
      assert.match(s, /rowTitle\((t|row)\.subject\)/)
    })
  }
})
