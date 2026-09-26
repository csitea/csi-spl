// SPL-978 (owner, prd t1 topic d52f0763): "the new issue button in the issues
// should be just a button with + the google way". A round accent button with
// only the plus glyph in the header, the name on aria-label + title, and the
// C shortcut unchanged.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = readFileSync(join(WUI, 'src/pages/issues.vue'), 'utf8')

describe('SPL-978 the New issue button is a round +', () => {
  const btn = (/<button[^>]*data-test="issues-new"[^>]*>([\s\S]*?)<\/button>/.exec(src) || [])
  it('sits in the list header, beside the heading', () => {
    const head = /<header class="feed-header issues-head">([\s\S]*?)<\/header>/.exec(src)
    assert.ok(head && head[1].includes('data-test="issues-new"'))
  })
  it('shows only the plus icon, no visible text', () => {
    assert.ok(btn[0], 'button found')
    assert.match(btn[0], /class="issues-fab"/)
    assert.match(btn[1], /<UiIcon name="plus"/)
    assert.doesNotMatch(btn[1], /\{\{/)
  })
  it('the name is on aria-label and title, from the catalogue', () => {
    assert.match(btn[0], /:aria-label="t\('issues\.new'\)"/)
    assert.match(btn[0], /:title="t\('issues\.new'\)"/)
  })
  it('is a circle in the accent colour with an elevation shadow and hover / press states', () => {
    const css = /\.issues-fab \{([^}]*)\}/.exec(src)[1]
    assert.match(css, /border-radius:\s*50%/)
    assert.match(css, /background:\s*var\(--color-accent\)/)
    assert.match(css, /color:\s*var\(--color-on-accent\)/)
    assert.match(css, /box-shadow:/)
    assert.match(src, /\.issues-fab:hover \{/)
    assert.match(src, /\.issues-fab:active::after \{/)
  })
  it('the C shortcut still starts a new issue', () => {
    assert.match(src, /if \(k === 'c'\) \{ startCreate\(\)/)
  })
})
