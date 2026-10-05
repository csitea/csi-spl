// E08 (perf 20261004): at phone level 1 the middle pane is CSS-hidden.
// Mounting it built about 120 nodes the reader never sees. The layout
// unmounts it there, and holds the front door's topic follow while it is
// gone. Above 820 px, and at phone levels 2 and 3, the pane stays mounted.
//
// Run: node tests/unit/phone-main-mount.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const layout = readFileSync(join(WUI, 'src/layouts/default.vue'), 'utf8')

describe('phone level 1 does not mount the middle pane', () => {
  it('main is mounted only while mountMain is true', () => {
    /* <template v-if> adds no node, so .spool-shell > .spool-main and the
       dock's "<main class=\"spool-main\">" slice both stay true. */
    assert.match(layout, /<template v-if="mountMain">\s*<main class="spool-main">/)
    assert.match(layout, /<\/main>\s*<\/template>/)
  })

  it('mountMain is false only at phone level 1', () => {
    assert.match(layout, /const mountMain = computed\(\(\) => !\(stack\.isMobile\.value && stack\.level\.value === 1\)\)/)
  })

  it('the front door follow moves here while the page is unmounted', () => {
    assert.match(layout, /if \(mounted \|\| !ready \|\| !import\.meta\.client \|\| frontStarted\) return/)
    assert.match(layout, /frontViewer\.loadTopics\(\)/)
    assert.match(layout, /frontViewer\.follow\(\)/)
    assert.match(layout, /flush: 'post'/)
  })

  it('a phone front door with a topic query opens the pane while the page is unmounted', () => {
    assert.match(layout, /useSettledQuery\('topic'\)/)
    assert.match(layout, /isMobileFrontDoor\(route\.path\)/)
    assert.match(layout, /livePane\.open\(id\)/)
  })
})
