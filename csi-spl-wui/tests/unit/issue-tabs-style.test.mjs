// SPL-2655 (owner t1 67d850ce: "They should have some kind of 3D, but this
// current bracket does not work, and it's also on the wrong side"): the
// Discussion | History tabs of an issue are 3D folder tabs, plan
// csi-spl-doc/doc/md/issue-tabs-panel-plan.md Option 1, targets T1-T6. This
// reads the rules in issues.vue's <style>; the browser half (computed styles,
// boxes, desktop and phone) is in tests/e2e/issues-crud-modal.test.mjs.
// Run: cd csi-spl-wui && pnpm test:unit issue-tabs-style
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const vue = read('src/pages/issues.vue')
const css = vue.slice(vue.indexOf('<style'), vue.lastIndexOf('</style>'))
const vars = read('src/assets/css/variables.css')
const main = read('src/assets/css/main.css')

/** the declarations of the one top-level rule whose selector is exactly sel */
function rule(sel) {
  const at = css.indexOf(`\n${sel} {`)
  assert.notEqual(at, -1, `no rule "${sel}" in issues.vue`)
  assert.equal(css.indexOf(`\n${sel} {`, at + 1), -1, `"${sel}" is declared twice`)
  const body = css.slice(css.indexOf('{', at) + 1, css.indexOf('}', at))
  return Object.fromEntries(body.split(';').map((d) => d.trim()).filter(Boolean).map((d) => {
    const i = d.indexOf(':')
    return [d.slice(0, i).trim(), d.slice(i + 1).trim()]
  }))
}
/** a token's value in the dark (:root) and light ([data-theme="light"]) blocks */
function token(name) {
  const block = (head) => vars.slice(vars.indexOf(head), vars.indexOf('}', vars.indexOf(head)))
  const pick = (b) => b.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1].trim()
  return { dark: pick(block(':root {')), light: pick(block(':root[data-theme="light"] {')) }
}

const list = rule('.issues-talk__h')
const tab = rule('.issues-talk__tab')
const sel = rule(".issues-talk__tab[aria-selected='true']")
const MARKER = /^inset 0 var\(--select-bar-w\) 0 var\(--focus-ring\)/

describe('issue tabs: 3D folder tabs (plan Option 1)', () => {
  it('T1: the selected tab marks its TOP edge, --focus-ring at --select-bar-w; no visible bottom marker', () => {
    assert.match(sel['box-shadow'] || '', MARKER)
    assert.match(sel['box-shadow'], /var\(--bevel-shine\)/)
    // N2: the bottom border is the tab's own fill, so it reads as no border
    assert.equal(sel['border-bottom-color'], sel.background)
    assert.ok(!Object.keys(tab).concat(Object.keys(sel)).some((k) => /^border-bottom(-width)?$/.test(k) && /[2-9]px/.test(tab[k] || sel[k])), 'no 2 px+ bottom border')
    assert.doesNotMatch(css, /issues-talk__tab[^{]*\{[^}]*--accent/, 'the old --accent underline is gone')
    assert.equal(token('--select-bar-w').dark, '3px')
  })

  it('T2: selected and focused show one colour: the marker is the focus outline colour', () => {
    assert.match(main, /:focus-visible \{\s*outline: var\(--focus-ring-w\) solid var\(--focus-ring\) !important;/)
    assert.match(sel['box-shadow'], /var\(--focus-ring\)/)
    assert.doesNotMatch(sel['box-shadow'], /--color-accent/)
  })

  it('T3 + T4: equal boxes sitting on the tablist baseline, joined to the panel', () => {
    assert.equal(list['align-items'], 'flex-end')
    assert.equal(list['border-bottom'], '1px solid var(--color-border)')
    // both tabs: one margin, one border width, bottom corners square; the selected tab only recolours
    assert.match(tab.margin, /^\S+ 0 -1px$/)
    assert.equal(tab.border, '1px solid transparent')
    assert.equal(tab['border-radius'], 'var(--radius-sm) var(--radius-sm) 0 0')
    for (const k of ['margin', 'border', 'border-width', 'padding', 'min-block-size', 'border-radius']) assert.equal(sel[k], undefined, `the selected tab keeps the shared ${k}`)
  })

  it('T5: the inactive tab is recessed (--color-bg-2), the selected one takes the panel fill', () => {
    assert.equal(tab.background, 'var(--color-bg-2)')
    assert.equal(tab['box-shadow'], 'var(--bevel-shade)')
    assert.equal(tab.color, 'var(--color-muted)')
    assert.equal(sel.background, 'var(--issues-talk-panel)')
    // N3: the panel it joins is the dialog's surface on desktop, the page bg on a phone
    assert.equal(list['--issues-talk-panel'], 'var(--color-bg)')
    assert.equal(rule(".issues-detail-in[data-modal='true'] .issues-talk__h")['--issues-talk-panel'], 'var(--color-surface)')
    for (const t of ['--color-surface', '--color-bg']) {
      const a = token(t)
      const b = token('--color-bg-2')
      assert.notEqual(a.dark, b.dark, `${t} vs --color-bg-2 dark`)
      assert.notEqual(a.light, b.light, `${t} vs --color-bg-2 light`)
    }
  })

  it('T6: a 44 px touch target that scales with the font level', () => {
    assert.equal(tab['min-block-size'], '2.75rem')
  })

  it('tokens only: no colour literal in the tab rules', () => {
    for (const r of [list, tab, sel]) assert.doesNotMatch(Object.values(r).join(';'), /#[0-9a-f]{3,8}\b|rgba?\(/i)
    assert.equal(tab.opacity, undefined, 'no opacity dimming: the muted colour carries it')
  })
})
