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
const IDS = ['dm', 'channels', 'flow', 'issues', 'people']

describe('a phone frees a rail panel it has left', () => {
  it('each panel stays mounted after a visit only on desktop', () => {
    for (const id of IDS) {
      assert.match(src, new RegExp(`v-if="(?:tab|panelTab) === '${id}' \\|\\| \\(tabsBuilt\\.${id} && !phone\\)"`))
    }
    /* SPL-3212: the Events panel is a phone's level 1 only (the log itself);
       a desktop never builds or keeps it, /events is the view there */
    assert.match(src, /v-if="tab === 'events' && phone && mobileStack\.level\.value === 1"/)
    assert.doesNotMatch(src, /tabsBuilt\.events/)
    /* no Topics panel any more (t1 e4bfddb1) */
    assert.doesNotMatch(src, /sidebar-panel-topics/)
    /* no Agents and no Boxes panel: both are Monitoring tabs (SPL-2075) */
    assert.doesNotMatch(src, /sidebar-panel-(agents|boxes)/)
    assert.doesNotMatch(src, /v-if="(?:tab|panelTab) === '[a-z]+' \|\| tabsBuilt\.[a-z]+"/)
  })

  it('desktop still records the first open and does not build every tab on idle', () => {
    assert.match(src, /const tabsBuilt = reactive/)
    assert.match(src, /watch\(panelTab, \(open\) => \{ tabsBuilt\[open\] = true \}\)/)
    assert.doesNotMatch(src, /requestIdleCallback/)
  })
})
