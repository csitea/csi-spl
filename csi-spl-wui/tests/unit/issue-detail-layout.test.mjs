// issues-06 (SPL-3072, plan issues-multiselect-panel-plan.md row 06): the open
// issue's title, description and property panel read as one hierarchy. The
// panel is a grid: one label column width for every row (--issues-meta-k),
// 12 px between rows, the values on one edge; the created / updated lines sit
// under it on that value edge. The title is the pane's heading. The browser
// half (one label edge, no value overflow at 412x915 and 1280x800) is
// tests/e2e/issue-detail-layout.test.mjs.
// Run: node tests/unit/issue-detail-layout.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const page = readFileSync(join(WUI, 'src/pages/issues.vue'), 'utf8')
const tmpl = page.slice(0, page.indexOf('<script'))
const css = page.slice(page.indexOf('<style'))
/* the declarations of the one top-level rule whose selector is exactly `sel` */
function rule(sel) {
  const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const all = [...css.matchAll(new RegExp(`^${esc} \\{([^}]*)\\}`, 'gm'))]
  assert.equal(all.length, 1, `one top-level rule for ${sel}, found ${all.length}`)
  return all[0][1]
}
const decl = (body, prop) => (body.match(new RegExp(`(?:^|[;\\s])${prop}:\\s*([^;]+);`)) || [])[1]?.trim()

describe('issues.vue detail pane: the property panel is an aligned grid', () => {
  it('one label column width, declared once, used by every property row', () => {
    const side = rule('.issues-detail-side')
    assert.equal(decl(side, '--issues-meta-k'), '5.5rem')
    assert.equal(decl(rule('.issues-prow'), 'grid-template-columns'), 'var(--issues-meta-k) minmax(0, 1fr)')
    assert.equal((css.match(/--issues-meta-k:/g) || []).length, 1, 'the width has one home')
    assert.doesNotMatch(css, /grid-template-columns: [0-9.]+rem minmax/, 'no row keeps its own label width')
  })
  it('12 px between the property rows', () => {
    const panel = rule('.issues-panel')
    assert.equal(decl(panel, 'display'), 'grid')
    assert.equal(decl(panel, 'row-gap'), '12px')
    assert.equal(decl(rule('.issues-detail-side'), '--issues-meta-gap'), '10px')
    assert.equal(decl(rule('.issues-prow'), 'column-gap'), 'var(--issues-meta-gap)')
  })
  it('created / updated by start on the value column\'s edge, not a 2 px flex stack', () => {
    const meta = rule('.issues-detail-meta')
    assert.equal(decl(meta, 'display'), 'grid')
    assert.equal(decl(meta, 'padding-inline-start'), 'calc(var(--issues-meta-k) + var(--issues-meta-gap))')
    assert.doesNotMatch(meta, /gap: 2px/)
  })
})

describe('issues.vue detail pane: title, description, metadata in that order', () => {
  it('the template puts the title first, then the description, then the panel and its created/updated lines', () => {
    const at = (s) => { const i = tmpl.indexOf(s); assert.ok(i > 0, `${s} is in the template`); return i }
    const order = ['data-test="issues-detail-title"', 'class="issues-detail-desc"', 'data-test="issues-props"', 'class="issues-detail-meta"'].map(at)
    assert.deepEqual([...order].sort((a, b) => a - b), order)
  })
  it('the title is the heading: larger than the 0.75rem labels, bold, no box until hovered or focused', () => {
    const title = rule('.issues-detail__title')
    assert.equal(decl(title, 'font-size'), '1.25rem')
    assert.equal(decl(title, 'font-weight'), '600')
    assert.equal(decl(title, 'border-color'), 'transparent')
    assert.match(css, /^\.issues-detail__title:focus \{[^}]*border-color: var\(--color-accent\)/m)
    assert.equal(decl(rule('.issues-prow__k'), 'font-size'), '0.75rem')
  })
  it('a phone keeps 44 px touch targets on the title and the property controls', () => {
    assert.match(css, /\.issues-detail__title \{ min-height: var\(--tap, 44px\); \}/)
    assert.match(css, /\.issues-pctl, \.issues-pval[^{]*\{ min-height: var\(--tap, 44px\); \}/)
  })
})
