// W4 (perf round 4, round-3 P3-07): measureControlText measures with one
// canvas measureText in the control's computed font - no probe span in the
// DOM, so no forced layout - and the drop box measures nothing while it is
// hidden (<= 820 px, TopBarTenant is the phone's switcher). The canvas-vs-
// probe width parity runs in Chrome: tests/e2e/tenant-text-measure.test.mjs.
//
// Run: node tests/unit/tenant-text-measure.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { measureControlText, measureControlTextProbe } from '../../src/utils/tenant-switcher.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

/* A fake document: a 2D context whose glyphs are 10px wide, a body that
   counts appends, and a probe whose rect is 7px per character. */
function fakeDoc(style = {}, { canvas = true } = {}) {
  const calls = { canvas: 0, measure: [], appended: 0, styleReads: 0 }
  const ctx = { font: '', measureText(s) { calls.measure.push({ s, font: this.font }); return { width: 10 * [...s].length } } }
  const doc = {
    body: { appendChild() { calls.appended++ } },
    createElement(tag) {
      if (tag === 'canvas') { calls.canvas++; return { getContext: () => (canvas ? ctx : null) } }
      let text = ''
      return {
        style: {},
        setAttribute() {},
        set textContent(v) { text = v },
        getBoundingClientRect: () => ({ width: 7 * text.length }),
        remove() {},
      }
    },
  }
  const cs = {
    font: '400 14px / 20px Inter, sans-serif', fontStyle: 'normal', fontVariantCaps: 'normal', fontWeight: '400',
    fontSize: '14px', fontFamily: 'Inter, sans-serif', letterSpacing: 'normal', wordSpacing: '0px',
    textTransform: 'none', fontKerning: 'auto', fontFeatureSettings: 'normal', fontVariant: 'normal', ...style,
  }
  doc.defaultView = { getComputedStyle: () => { calls.styleReads++; return cs } }
  return { el: { ownerDocument: doc }, calls }
}

describe('W4 measureControlText: one canvas measureText, no DOM probe', () => {
  it('measures in the computed font without touching the DOM', () => {
    const { el, calls } = fakeDoc()
    assert.equal(measureControlText(el, 'csitea'), 60)
    assert.equal(calls.appended, 0)
    assert.equal(calls.measure[0].font, '400 14px Inter, sans-serif')
  })
  it('reuses one canvas context per document', () => {
    const { el, calls } = fakeDoc()
    for (const label of ['a', 'bb', 'ccc']) measureControlText(el, label)
    assert.equal(calls.canvas, 1)
    assert.equal(calls.measure.length, 3)
  })
  it('collapses and trims spaces the way the probe (white-space: nowrap) drew them', () => {
    const { el } = fakeDoc()
    assert.equal(measureControlText(el, '  a   b  '), 30)
  })
  it('adds letter- and word-spacing and applies text-transform', () => {
    assert.equal(measureControlText(fakeDoc({ letterSpacing: '0.5px' }).el, 'abcd'), 42)
    assert.equal(measureControlText(fakeDoc({ wordSpacing: '3px' }).el, 'a b c'), 56)
    const up = fakeDoc({ textTransform: 'uppercase' })
    measureControlText(up.el, 'ab')
    assert.equal(up.calls.measure[0].s, 'AB')
  })
  it('keeps italic, bold and small-caps in the canvas font', () => {
    const f = fakeDoc({ fontStyle: 'italic', fontWeight: '700', fontVariantCaps: 'small-caps' })
    measureControlText(f.el, 'x')
    assert.equal(f.calls.measure[0].font, 'italic small-caps 700 14px Inter, sans-serif')
  })
  it('falls back to the probe span when there is no canvas or a feature setting a canvas cannot draw', () => {
    const none = fakeDoc({}, { canvas: false })
    assert.equal(measureControlText(none.el, 'abc'), 21)
    assert.equal(none.calls.appended, 1)
    const feat = fakeDoc({ fontFeatureSettings: '"tnum" 1' })
    assert.equal(measureControlText(feat.el, 'abc'), 21)
    assert.equal(feat.calls.appended, 1)
    assert.equal(measureControlTextProbe(fakeDoc().el, 'abcd'), 28)
  })
  it('is NaN with no document to measure in', () => {
    assert.equal(Number.isNaN(measureControlText(null, 'Aa')), true)
    assert.equal(Number.isNaN(measureControlTextProbe({}, 'Aa')), true)
  })
})

describe('W4 TenantDropBox: nothing is measured while the box is hidden', () => {
  it('returns before measuring at <= 820 px and re-measures on the viewport change', () => {
    const vue = readFileSync(join(WUI, 'src/components/TenantDropBox.vue'), 'utf8')
    const fn = vue.slice(vue.indexOf('function applyTenantSelectWidth()'), vue.indexOf('function tenantBoxHidden('))
    assert.ok(fn.indexOf('if (tenantBoxHidden(sel)) return') > 0)
    assert.ok(fn.indexOf('if (tenantBoxHidden(sel)) return') < fn.indexOf('measureControlText('))
    assert.match(vue, /view\.matchMedia\(MOBILE_STACK_QUERY\)\.matches/)
    assert.match(vue, /tenantWidthMq\.addEventListener\('change', onTenantWidthViewport\)/)
    assert.match(vue, /@media \(max-width: 820px\) \{\s*\.tenant-drop \{ display: none; \}/)
  })
})
