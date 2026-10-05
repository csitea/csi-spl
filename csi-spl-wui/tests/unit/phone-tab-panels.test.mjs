// E08 (perf 20261004): a phone keeps a visited rail panel in the document
// and hides it. That panel is mounted only while it is the open tab.
// Desktop still keeps it (tabsBuilt) so a switch back does not rebuild it.
//
// Run: node tests/unit/phone-tab-panels.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = readFileSync(join(WUI, 'src/components/ChannelSidebar.vue'), 'utf8')
const IDS = ['dm', 'channels', 'topics', 'flow', 'issues', 'events', 'people', 'agents', 'boxes']

describe('a phone frees a rail panel it has left', () => {
  it('each panel stays mounted after a visit only on desktop', () => {
    for (const id of IDS) {
      assert.match(src, new RegExp(`v-if="tab === '${id}' \\|\\| \\(tabsBuilt\\.${id} && !phone\\)"`))
    }
    assert.doesNotMatch(src, /v-if="tab === '[a-z]+' \|\| tabsBuilt\.[a-z]+"/)
  })

  it('desktop still records the first open and does not build every tab on idle', () => {
    assert.match(src, /const tabsBuilt = reactive/)
    assert.match(src, /watch\(tab, \(open\) => \{ tabsBuilt\[open\] = true \}\)/)
    assert.doesNotMatch(src, /requestIdleCallback/)
  })
})
