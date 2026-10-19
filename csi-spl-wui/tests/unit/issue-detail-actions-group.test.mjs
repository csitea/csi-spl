// Issues multi-select panel plan v1.1, row 05 (issues-multiselect-panel-plan.md
// section 7.1): the open issue's Copy link / Archive / Delete are one action
// group - the same 32 px height each (44 px tap targets in the phone's top
// bar, plan 9.2), a 6 px gap between them, and the theme's one focus ring.
// Red control: on master the group's gap was 2 px (measured 2026-10-20 at
// 1280x800 and 412x915, dark and light, 4dbc49cad); this test failed there.
// The browser half: /var/spool-hub/dispatch/405e08ba/work/c-546-r05/measure-r05.mjs
// Run: node tests/unit/issue-detail-actions-group.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const comp = readFileSync(join(WUI, 'src/components/IssueDetailActions.vue'), 'utf8')
const main = readFileSync(join(WUI, 'src/assets/css/main.css'), 'utf8')
const css = comp.slice(comp.indexOf('<style'))
const tmpl = comp.slice(0, comp.indexOf('<script'))
/* the declarations of the rule whose selector list is exactly sel */
function rule(src, sel) {
  const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const m = src.match(new RegExp(`(?:^|\\n)${esc}\\s*\\{([^}]*)\\}`))
  assert.ok(m, `no rule ${sel}`)
  return m[1]
}

describe('IssueDetailActions: one consistent action group (plan row 05)', () => {
  it('the group spaces its three buttons 6px apart', () => {
    assert.match(rule(css, '.issue-actions'), /\bgap:\s*6px\s*;/)
  })
  it('every button is 32px high and wide, one rule for all three', () => {
    const b = rule(css, '.issue-actions__btn')
    assert.match(b, /min-width:\s*32px/)
    assert.match(b, /min-height:\s*32px/)
    assert.doesNotMatch(css, /\.issue-actions__btn--danger\s*\{[^}]*(?:height|width|padding|margin)/)
  })
  it('the phone top bar keeps 44px tap targets', () => {
    const t = rule(css, '.issue-actions__btn--tap')
    assert.match(t, /min-width:\s*var\(--tap,\s*44px\)/)
    assert.match(t, /min-height:\s*var\(--tap,\s*44px\)/)
  })
  it('the focus ring is the theme ring: the global :focus-visible rule', () => {
    const f = rule(main, ':focus-visible')
    assert.match(f, /outline:\s*var\(--focus-ring-w\)\s+solid\s+var\(--focus-ring\)\s*!important/)
    assert.match(f, /outline-offset:\s*var\(--focus-offset\)\s*!important/)
  })
  it('theme tokens only: no raw colour, no inline style, no v-html', () => {
    assert.doesNotMatch(css, /#[0-9a-f]{3,8}\b|rgba?\(/i)
    assert.doesNotMatch(tmpl, /\sstyle=|:style=|v-html/)
  })
})
