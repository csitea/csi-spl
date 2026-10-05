// 081 T006 (FR-006, FR-007, FR-009): the F6 cycle, the skip link and the
// focus after a route change. The pure half is utils/pane-focus.mjs; the
// wiring is read from useGlobalKeys.ts and layouts/default.vue.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { F6_ORDER, LEFT, MIDDLE, OMNIBOX, RIGHT, nextPane, paneAt, paneKey, paneOfTarget, paneTarget, routeTakesFocus } from '../../src/utils/pane-focus.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (rel) => readFileSync(join(SRC, rel), 'utf8')

/** an element inside the given roots (selectors) */
const inside = (...roots) => ({ closest: (sel) => (roots.some((r) => sel.split(', ').includes(r)) ? {} : null) })

/** a root whose querySelectorAll answers from a table of selector -> elements */
const rootOf = (table) => ({ querySelectorAll: (sel) => table[sel] || [] })

describe('081 T006: F6 panes', () => {
  it('the cycle is left, middle, right, Omnibox', () => {
    assert.deepEqual([...F6_ORDER], [LEFT, MIDDLE, RIGHT, OMNIBOX])
    assert.deepEqual([LEFT, MIDDLE, RIGHT, OMNIBOX], ['left', 'middle', 'right', 'omnibox'])
  })

  it('paneAt names every stop; the docked Omnibox inside .spool-main is the Omnibox', () => {
    assert.equal(paneAt(inside('nav.sidebar')), LEFT)
    assert.equal(paneAt(inside('.spool-main')), MIDDLE)
    assert.equal(paneAt(inside('aside.live-pane', '.spool-main')), RIGHT)
    assert.equal(paneAt(inside('aside.operator-pane')), RIGHT)
    assert.equal(paneAt(inside('.top-bar__omnibox', '.spool-main')), OMNIBOX)
    assert.equal(paneAt(inside('.top-bar')), '')
    assert.equal(paneAt(null), '')
  })

  it('paneOfTarget is unchanged: the sidebar still chooses no level (SPL-996)', () => {
    assert.equal(paneOfTarget(inside('nav.sidebar')), '')
    assert.equal(paneOfTarget({ closest: (s) => (s === '.sidebar' ? {} : null) }), '')
  })

  it('F6 is next, Shift + F6 is prev, a modifier makes it the browser\'s', () => {
    assert.equal(paneKey({ key: 'F6' }), 'next')
    assert.equal(paneKey({ key: 'F6', shiftKey: true }), 'prev')
    for (const m of ['ctrlKey', 'altKey', 'metaKey']) assert.equal(paneKey({ key: 'F6', [m]: true }), '')
    assert.equal(paneKey({ key: 'F5' }), '')
    assert.equal(paneKey(null), '')
  })

  it('AC6: with a topic open F6 walks left, middle, right, Omnibox and wraps; Shift + F6 walks back', () => {
    let at = LEFT
    const seen = []
    for (let i = 0; i < 4; i++) { at = nextPane(at); seen.push(at) }
    assert.deepEqual(seen, [MIDDLE, RIGHT, OMNIBOX, LEFT])
    assert.equal(nextPane(OMNIBOX, { back: true }), RIGHT)
    assert.equal(nextPane(LEFT, { back: true }), OMNIBOX)
  })

  it('without a topic the right pane is skipped both ways', () => {
    const has = (p) => p !== RIGHT
    assert.equal(nextPane(MIDDLE, { has }), OMNIBOX)
    assert.equal(nextPane(OMNIBOX, { back: true, has }), MIDDLE)
  })

  it('from nowhere F6 starts at the left, Shift + F6 at the Omnibox; nothing there is no move', () => {
    assert.equal(nextPane(''), LEFT)
    assert.equal(nextPane('', { back: true }), OMNIBOX)
    assert.equal(nextPane('', { has: () => false }), '')
    assert.equal(nextPane(MIDDLE, { has: (p) => p === MIDDLE }), '')
  })
})

describe('081 T006: where the focus lands in a pane', () => {
  const sel = { dataset: 'selected' }
  const first = { dataset: 'first' }
  const head = { dataset: 'heading' }
  const table = {
    '[data-selected="true"], [aria-current="true"]': [sel],
    '.msg[tabindex="0"], [role="row"], [role="option"]': [first],
    'h1, h2': [head],
  }

  it('the selected row first', () => {
    assert.equal(paneTarget(rootOf(table), MIDDLE), sel)
  })
  it('else the first row, else the heading, else the pane', () => {
    const noSel = { ...table, '[data-selected="true"], [aria-current="true"]': [] }
    assert.equal(paneTarget(rootOf(noSel), MIDDLE), first)
    const headOnly = { 'h1, h2': [head] }
    assert.equal(paneTarget(rootOf(headOnly), MIDDLE), head)
    const bare = rootOf({})
    assert.equal(paneTarget(bare, MIDDLE), bare)
  })
  it('after a route change the first row is skipped: selected row or heading (spec 3.3)', () => {
    const noSel = { ...table, '[data-selected="true"], [aria-current="true"]': [] }
    assert.equal(paneTarget(rootOf(noSel), MIDDLE, { firstRow: false }), head)
  })
  it('a hidden row is passed over', () => {
    assert.equal(paneTarget(rootOf(table), MIDDLE, { visible: (el) => el !== sel }), first)
  })
  it('no root, no target', () => {
    assert.equal(paneTarget(null, MIDDLE), null)
  })
})

describe('081 T006 (FR-009): which navigations move the focus', () => {
  const nav = { fromPath: '/lobby', toPath: '/people' }
  it('a click or a key to another page does', () => {
    assert.equal(routeTakesFocus(nav), true)
  })
  it('Back / Forward, the first load, a failure, a phone, a query-only change do not', () => {
    assert.equal(routeTakesFocus({ ...nav, popstate: true }), false)
    assert.equal(routeTakesFocus({ ...nav, initial: true }), false)
    assert.equal(routeTakesFocus({ ...nav, failed: true }), false)
    assert.equal(routeTakesFocus({ ...nav, mobile: true }), false)
    assert.equal(routeTakesFocus({ fromPath: '/lobby', toPath: '/lobby' }), false)
  })
  it('never out of a text field or a dialog', () => {
    assert.equal(routeTakesFocus({ ...nav, typing: true }), false)
    assert.equal(routeTakesFocus({ ...nav, dialog: true }), false)
  })
})

describe('081 T006: wiring', () => {
  it('useGlobalKeys handles F6 off a phone and outside an open dialog', () => {
    const src = read('composables/useGlobalKeys.ts')
    assert.match(src, /if \(ev\.key === 'F6'\) \{\s*if \(!phone\.value && !paletteOpen\.value && !document\.querySelector\(OVERLAY_OPEN\)\) onPaneKey\(ev\)/)
    assert.match(src, /export function focusPane\(/)
  })
  it('the skip link is the layout\'s first child and focuses the middle pane', () => {
    const tpl = read('layouts/default.vue')
    assert.match(tpl, /<div class="layout">\s*(<!--[\s\S]*?-->\s*)?<a class="skip-link"[^>]*@click\.prevent="skipToMsgs"/)
    assert.match(tpl, /function skipToMsgs\(\) \{\s*focusPane\(MIDDLE\)/)
  })
  it('the live region is polite and the route hook uses routeTakesFocus after 078\'s close rule', () => {
    const tpl = read('layouts/default.vue')
    assert.match(tpl, /role="status" aria-live="polite" data-testid="route-announce"/)
    const close = tpl.indexOf('if (routeLeavesTopic(nav))')
    const focus = tpl.indexOf('routeTakesFocus({ ...nav')
    assert.ok(close > 0 && focus > close, 'focus after the close rule')
  })
})
