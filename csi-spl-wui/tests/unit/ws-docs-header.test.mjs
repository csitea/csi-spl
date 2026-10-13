// The workspace documents header (SPL-1697): no visible Documents heading,
// and on a desktop the doc/grid views and both + buttons share one row.
//
// Run: node tests/unit/ws-docs-header.test.mjs
import { readFileSync } from 'node:fs'
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

const page = readFileSync(new URL('../../src/components/workspace-docs/WorkspaceDocsPage.vue', import.meta.url), 'utf8')
const tree = readFileSync(new URL('../../src/components/workspace-docs/QtoFileTree.vue', import.meta.url), 'utf8')

function between(text, start, end) {
  const a = text.indexOf(start)
  const b = text.indexOf(end, a + start.length)
  assert.ok(a >= 0 && b > a, `${start} .. ${end}`)
  return text.slice(a, b)
}

describe('workspace documents header', () => {
  it('the heading does not show the word Documents', () => {
    const h2 = page.match(/<h2[^>]*data-test="ws-docs-heading"[^>]*>[\s\S]*?<\/h2>/)
    assert.ok(h2, 'the drill heading stays')
    assert.match(h2[0], /v-if="phoneList && drillTitle"/)
    assert.match(h2[0], /\{\{ drillTitle \}\}/)
    assert.doesNotMatch(h2[0], /ws_doctree\.title/)
    assert.doesNotMatch(h2[0], />\s*Documents\s*</)
  })

  it('the tree keeps Documents as its aria-label', () => {
    assert.match(tree, /data-test="qto-file-tree"[^>]*:aria-label="t\('ws_doctree\.title'\)"/)
  })

  it('on a desktop the two view buttons and the two plus buttons share the header row', () => {
    const actions = between(page, 'class="wsdocs-head__actions"', '</header>')
    const folder = actions.indexOf('id="wsdocs-folder-slot"')
    const doc = actions.indexOf('data-test="ws-docs-new"')
    const views = actions.indexOf('class="wsdocs-views"')
    assert.ok(folder >= 0 && doc > folder && views > doc, 'folder slot, then new document, then the views at the end of the row')
    assert.match(page, /\.wsdocs-head__actions\s*\{[^}]*margin-inline-start:\s*auto/)
    assert.match(page, /\.wsdocs-head__actions\s*\{[^}]*display:\s*inline-flex/)
    assert.match(page, /\.wsdocs-head__actions\s*\{[^}]*flex:\s*0 0 auto/)
    assert.match(tree, /<Teleport to="#wsdocs-folder-slot" :disabled="!folderInHeader">/)
    assert.match(tree, /data-test="qto-new-folder"/)
    assert.match(tree, /const folderInHeader = computed\(\(\) => import\.meta\.client && !stack\.isMobile\.value\)/)
  })
})
