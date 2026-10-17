// perf round 6 row 02 (SPL-2363): the shell loads both topic panes lazily.
//
// layouts/default.vue auto-imported LiveTopicPane and TopicPane, so their
// chunks sat in index.html's modulepreload set: every cold load fetched them,
// also for a reader who never opens a topic. Measured on the CI mock bundle
// (node 20.20.2, wf 10's generate env): ci_home_gzip_kb 352.0 -> 308.1 KB
// (-45,020 B), initial set +133 B (154.6 -> 154.8 KB, ceiling 155).
//
// CONTROL: drop either `const ... = defineAsyncComponent(...)` line from the
// layout and "loads <Pane> lazily" goes red. Keep the 1..1 chain test next to
// it: an async pane must still sit in the one v-if / v-else-if chain.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const layout = readFileSync(join(WUI, 'src/layouts/default.vue'), 'utf8')

describe('SPL-2363 — the topic panes load on first open, not on every cold load', () => {
  it('pnpm test runs this suite', () => {
    const s = runsInUnitSuite(import.meta.url)
    assert.ok(s.ok, s.why)
  })

  for (const pane of ['LiveTopicPane', 'TopicPane']) {
    it(`loads ${pane} lazily`, () => {
      const re = new RegExp(`const ${pane} = defineAsyncComponent\\(\\(\\) => import\\('@/components/${pane}\\.vue'\\)\\)`)
      assert.match(layout, re)
    })
  }

  it('keeps the one section chain: v-if LIVE, then v-else-if CHANNEL', () => {
    assert.match(layout, /<LiveTopicPane v-if="section === LIVE" \/>\s*<TopicPane v-else-if="section === CHANNEL" \/>/)
  })
})
