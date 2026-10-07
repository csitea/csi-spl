// 103 T003: panel selectors and resolver (spec 103 §2, §4.1, §4.2, §6.3).
// The module is pure: a tiny fake DOM below (tag, .class, #id, [attr],
// [attr="v"], comma lists and the `>` child combinator) drives it.
//
// Run: node tests/unit/vim-panels.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  VIM_ACTIVE_ITEM, VIM_COLLAPSED, VIM_PANELS, PANE_SELECTORS,
  activePanelOf, vimItemKey, panelEntry, panelItems, panelRoot, panelUsable,
  resolveNextPanel, vimRoveTabindex, vimShown, vimStepItem, visiblePanels,
} from '../../src/utils/vim-panels.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

/* ---------- fake DOM ---------- */

/** one compound selector ("tr.issues-row[data-test=\"x\"]") against a node */
function compound(node, sel) {
  const parts = sel.match(/^[a-z][a-z0-9]*|\.[\w-]+|#[\w-]+|\[[\w-]+(?:="[^"]*")?\]/g) || []
  if (parts.join('') !== sel) throw new Error(`fake DOM cannot parse: ${sel}`)
  return parts.every((p) => {
    if (p[0] === '.') return node.cls.has(p.slice(1))
    if (p[0] === '#') return node.attrs.id === p.slice(1)
    if (p[0] === '[') {
      const [, k, v] = p.match(/^\[([\w-]+)(?:="([^"]*)")?\]$/)
      return v === undefined ? k in node.attrs : node.attrs[k] === v
    }
    return node.tag === p
  })
}

/** a complex selector: compounds joined by ` > ` */
function complex(node, sel) {
  const chain = sel.split(/\s*>\s*/).reverse()
  let at = node
  for (let i = 0; i < chain.length; i++) {
    if (!at || !compound(at, chain[i])) return false
    at = at.parent
  }
  return true
}

/**
 * el('aside.topic.live-pane', { 'data-selected': 'true' }, [children])
 * `none: true` in attrs makes it display: none (not an attribute).
 */
function el(tagCls, attrs = {}, children = []) {
  const [tag, ...cls] = tagCls.split('.')
  const { none = false, ...rest } = attrs
  const node = {
    tag, cls: new Set(cls), attrs: { ...rest }, none, parent: null, children,
    matches(sel) { return sel.split(/\s*,\s*/).some((s) => complex(node, s)) },
    closest(sel) { for (let n = node; n; n = n.parent) if (n.matches(sel)) return n; return null },
    querySelectorAll(sel) {
      const out = []
      const walk = (n) => { for (const c of n.children) { if (c.matches(sel)) out.push(c); walk(c) } }
      walk(node)
      return out
    },
    getClientRects() { for (let n = node; n; n = n.parent) if (n.none) return []; return [{}] },
    getAttribute(k) { return k in node.attrs ? String(node.attrs[k]) : null },
    setAttribute(k, v) { node.attrs[k] = String(v) },
  }
  for (const c of children) c.parent = node
  return node
}

/** the shell of spec §3: rail, sidebar body, main, optional right pane */
function shell({ collapse = {}, railOnly = false, body = [], main = [], pane = null } = {}) {
  const rail = el('div.sidebar-rail', {}, [
    el('button.sidebar-tab', { 'data-key': 'channels', 'aria-selected': 'true' }),
    el('button.sidebar-tab', { 'data-key': 'dm', 'aria-selected': 'false' }),
    el('a.sidebar-rail__help', { href: '/help' }),
    el('div.sidebar-rail__loop', { 'aria-hidden': 'true' }, [el('button.sidebar-tab', { tabindex: '-1' })]),
  ])
  const sidebar = el(`nav.sidebar${railOnly ? '.sidebar--rail' : ''}`, {}, [
    rail,
    el('div.sidebar-body', railOnly ? { none: true } : {}, body),
  ])
  const kids = [sidebar, el('main.spool-main', {}, main)]
  if (pane) kids.push(pane)
  const attrs = {}
  for (const k of ['channels', 'topic', 'threads']) if (collapse[k]) attrs[`data-collapse-${k}`] = '1'
  const root = el('div.spool-shell', attrs, kids)
  return el('body', {}, [root])
}

const card = (id, extra = {}) => el('article.msg', { 'data-msg-id': id, ...extra })
const row = (key, extra = {}) => el('a.nav-item', { 'data-key': key, ...extra })
const livePane = (...cards) => el('aside.topic.live-pane', {}, cards)
const find = (doc, sel) => doc.querySelectorAll(sel)[0]

/* ---------- tests ---------- */

describe('103 T003: which panel an element sits in', () => {
  const doc = shell({
    body: [el('div#sidebar-panel-channels', {}, [row('general')])],
    main: [card('m1'), el('div.omnibox-dock', {}, [el('textarea')])],
    pane: livePane(card('r1')),
  })

  it('rail = 0, sidebar body = 1, middle = 2, right pane = 3', () => {
    assert.equal(activePanelOf(find(doc, '.sidebar-tab')), 0)
    assert.equal(activePanelOf(find(doc, 'a.nav-item')), 1)
    assert.equal(activePanelOf(find(doc, '[data-msg-id="m1"]')), 2)
    assert.equal(activePanelOf(find(doc, '[data-msg-id="r1"]')), 3)
  })

  it('the Omnibox docked inside .spool-main, the body and a non-element are no panel', () => {
    assert.equal(activePanelOf(find(doc, 'textarea')), -1)
    assert.equal(activePanelOf(doc), -1)
    assert.equal(activePanelOf(null), -1)
    assert.equal(activePanelOf({}), -1)
  })

  it('an in-page left list inside .spool-main is Panel 1, its reader Panel 2 (docs, help)', () => {
    const docs = shell({ railOnly: true, main: [
      el('nav.docs-tree', {}, [el('a.docs-tree__item', { 'data-key': 'a.md' })]),
      el('article.docs-content', {}, [el('h1')]),
    ] })
    assert.equal(activePanelOf(find(docs, '.docs-tree__item')), 1)
    assert.equal(activePanelOf(find(docs, 'h1')), 2)
    const help = shell({ railOnly: true, main: [el('nav.settings-nav.help-nav', {}, [el('a.settings-nav__link')]), el('article.settings-content.help-content')] })
    assert.equal(activePanelOf(find(help, '.settings-nav__link')), 1)
    assert.equal(activePanelOf(find(help, '.help-content')), 2)
  })

  it('the issues detail side is Panel 3 even inside .spool-main', () => {
    const issues = shell({ railOnly: true, main: [el('table', {}, [el('tr.issues-row')]), el('aside.issues-detail-side', {}, [el('button', { 'data-key': 'd' })])] })
    assert.equal(activePanelOf(find(issues, 'tr.issues-row')), 2)
    assert.equal(activePanelOf(find(issues, '[data-key="d"]')), 3)
  })
})

describe('103 T003: visible panels (FR-008, spec 6.3)', () => {
  it('channel view with a topic open shows 0..3; without one 0..2', () => {
    assert.deepEqual(visiblePanels(shell({ pane: livePane(card('r1')) })), [0, 1, 2, 3])
    assert.deepEqual(visiblePanels(shell()), [0, 1, 2])
  })

  it('a rail-only view hides the sidebar body; an in-page tree is Panel 1 instead', () => {
    assert.deepEqual(visiblePanels(shell({ railOnly: true })), [0, 2])
    const docs = shell({ railOnly: true, main: [el('nav.docs-tree'), el('article.docs-content')] })
    assert.deepEqual(visiblePanels(docs), [0, 1, 2])
    assert.ok(panelRoot(docs, 1).cls.has('docs-tree'))
    assert.ok(panelRoot(docs, 2).cls.has('docs-content'))
  })

  it('a collapsed strip is skipped although the strip itself is laid out (050)', () => {
    const strip = shell({ collapse: { threads: true }, pane: livePane(card('r1')) })
    assert.equal(vimShown(find(strip, 'aside')), true, 'the strip has a box')
    assert.deepEqual(visiblePanels(strip), [0, 1, 2])
    assert.deepEqual(visiblePanels(shell({ collapse: { topic: true }, pane: livePane() })), [0, 1, 3])
    assert.deepEqual(visiblePanels(shell({ collapse: { channels: true } })), [2])
    assert.equal(panelUsable(find(strip, 'aside')), false)
    assert.equal(panelUsable(find(strip, 'main')), true)
  })

  it('a hidden root falls through to the next candidate; none at all is null', () => {
    const doc = shell({ main: [el('nav.docs-tree', { none: true })] })
    assert.ok(panelRoot(doc, 1).cls.has('sidebar-body'))
    assert.equal(panelRoot(doc, 3), null)
    assert.equal(panelRoot(doc, 7), null)
    assert.equal(panelRoot(null, 1), null)
  })

  it('the caller may pass its own visibility test', () => {
    assert.deepEqual(visiblePanels(shell(), { visible: (n) => !n.cls.has('sidebar-rail') }), [1, 2])
  })
})

describe('103 T003: resolveNextPanel (h / l / Esc)', () => {
  const all = [0, 1, 2, 3]
  it('steps one panel each way', () => {
    assert.equal(resolveNextPanel(1, 'right', all), 2)
    assert.equal(resolveNextPanel(2, 'left', all), 1)
    assert.equal(resolveNextPanel(3, 'back', all), 2)
  })

  it('does not wrap: h at 0 and l at the rightmost visible panel stay', () => {
    assert.equal(resolveNextPanel(0, 'left', all), 0)
    assert.equal(resolveNextPanel(3, 'right', all), 3)
    assert.equal(resolveNextPanel(2, 'right', [0, 1, 2]), 2)
  })

  it('skips hidden panels both ways (rail-only views: 0 <-> 2)', () => {
    assert.equal(resolveNextPanel(0, 'right', [0, 2]), 2)
    assert.equal(resolveNextPanel(2, 'left', [0, 2]), 0)
    assert.equal(resolveNextPanel(1, 'right', [0, 1, 3]), 3)
  })

  it('from a panel that just closed, h lands on the nearest visible one to its left', () => {
    assert.equal(resolveNextPanel(3, 'left', [0, 1, 2]), 2)
  })

  it('from nowhere l starts at the leftmost visible panel; h stays nowhere', () => {
    assert.equal(resolveNextPanel(-1, 'right', [1, 2]), 1)
    assert.equal(resolveNextPanel(-1, 'left', all), -1)
  })

  it('an unknown direction or no visible list is no move; the input order does not matter', () => {
    assert.equal(resolveNextPanel(1, 'up', all), 1)
    assert.equal(resolveNextPanel(1, 'right', []), 1)
    assert.equal(resolveNextPanel(1, 'right', undefined), 1)
    assert.equal(resolveNextPanel(0, 'right', [3, 2]), 2)
  })

  it('every pair of panels: l then h returns when both are visible', () => {
    for (const a of VIM_PANELS) for (const b of VIM_PANELS) {
      if (b <= a) continue
      const vis = [a, b]
      assert.equal(resolveNextPanel(a, 'right', vis), b)
      assert.equal(resolveNextPanel(b, 'left', vis), a)
    }
  })
})

describe('103 T003: panel items and the roving tabindex', () => {
  it('rail items skip the aria-hidden loop copies', () => {
    const doc = shell()
    const items = panelItems(panelRoot(doc, 0), 0)
    assert.deepEqual(items.map(vimItemKey), ['channels', 'dm', '/help'])
  })

  it('a root holding another panel (the docs tree inside .spool-main) keeps only its own rows', () => {
    const doc = shell({ main: [el('nav.docs-tree', {}, [el('a.docs-tree__item', { 'data-key': 't' })]), card('m1'), card('m2')] })
    const main = find(doc, 'main')
    assert.deepEqual(panelItems(main, 2).map(vimItemKey), ['m1', 'm2'])
    assert.deepEqual(panelItems(main, 1).map(vimItemKey), ['t'])
  })

  it('hidden rows are left out; a missing root or panel gives none', () => {
    const doc = shell({ body: [row('a'), row('b', { none: true }), row('c')] })
    assert.deepEqual(panelItems(panelRoot(doc, 1), 1).map(vimItemKey), ['a', 'c'])
    assert.deepEqual(panelItems(null, 1), [])
    assert.deepEqual(panelItems(panelRoot(doc, 1), 9), [])
  })

  it('each view\'s rows: topic rows, issue rows, event rows, archive rows, data-vim-item', () => {
    const doc = shell({ main: [
      el('a.topic-row', { 'data-key': 't1' }), el('tr.issues-row', { 'data-key': 'i1' }),
      el('tr', { 'data-test': 'events-row', id: 'e1' }), el('li.archive-row', { 'data-msg-id': 'a1' }),
      el('div', { 'data-vim-item': '', 'data-key': 'v1' }), el('tr', { 'data-test': 'other' }),
    ] })
    assert.deepEqual(panelItems(find(doc, 'main'), 2).map(vimItemKey), ['t1', 'i1', 'e1', 'a1', 'v1'])
  })

  it('current gets tabindex 0, the rest -1; a current that is not a row changes nothing', () => {
    const doc = shell({ body: [row('a'), row('b'), row('c')] })
    const root = panelRoot(doc, 1)
    const [a, b, c] = panelItems(root, 1)
    panelItems(root, 1, { current: b })
    assert.deepEqual([a, b, c].map((n) => n.attrs.tabindex), ['-1', '0', '-1'])
    vimRoveTabindex([a, b, c], c)
    assert.deepEqual([a, b, c].map((n) => n.attrs.tabindex), ['-1', '-1', '0'])
    vimRoveTabindex([a, b, c], el('a.nav-item'))
    assert.deepEqual([a, b, c].map((n) => n.attrs.tabindex), ['-1', '-1', '0'])
  })
})

describe('103 T003: where focus lands on entering a panel (spec 4.1)', () => {
  const a = row('a')
  const b = row('b', { 'aria-current': 'true' })
  const c = row('c')
  el('div.sidebar-body', {}, [a, b, c])

  it('the remembered row first, then the selected one, then the first', () => {
    assert.equal(panelEntry([a, b, c], { remembered: 'c' }), c)
    assert.equal(panelEntry([a, b, c], { remembered: 'gone' }), b)
    assert.equal(panelEntry([a, b, c]), b)
    assert.equal(panelEntry([a, c]), a)
    assert.equal(panelEntry([]), null)
  })

  it('aria-selected="false" is not selected; aria-selected / data-selected "true" and aria-current="page" are', () => {
    const off = row('x', { 'aria-selected': 'false' })
    assert.equal(panelEntry([a, off]), a)
    for (const attrs of [{ 'aria-selected': 'true' }, { 'data-selected': 'true' }, { 'aria-current': 'page' }]) {
      const on = row('y', attrs)
      assert.equal(panelEntry([a, on]), on, JSON.stringify(attrs))
      assert.ok(on.matches(VIM_ACTIVE_ITEM))
    }
  })

  it('owner (t1 29c3b055): h from the topic pane lands in the middle list on the open topic\'s card', () => {
    const doc = shell({ main: [card('m1'), card('m2', { 'data-selected': 'true', 'aria-current': 'true' }), card('m3')], pane: livePane(card('r1')) })
    const to = resolveNextPanel(activePanelOf(find(doc, '[data-msg-id="r1"]')), 'left', visiblePanels(doc))
    assert.equal(to, 2)
    assert.equal(vimItemKey(panelEntry(panelItems(panelRoot(doc, to), to))), 'm2')
  })

  it('vimItemKey reads data-key, data-msg-id, id, href in that order', () => {
    assert.equal(vimItemKey(el('a', { href: '/h', id: 'i', 'data-msg-id': 'm', 'data-key': 'k' })), 'k')
    assert.equal(vimItemKey(el('a', { href: '/h', id: 'i', 'data-msg-id': 'm' })), 'm')
    assert.equal(vimItemKey(el('a', { href: '/h', id: 'i' })), 'i')
    assert.equal(vimItemKey(el('a', { href: '/h' })), '/h')
    assert.equal(vimItemKey(el('a')), '')
    assert.equal(vimItemKey(null), '')
  })
})

describe('103 T003: stepping rows (j / k / g g / G)', () => {
  const items = ['a', 'b', 'c']
  it('down and up move one row and stop at the ends', () => {
    assert.equal(vimStepItem(items, 'a', 'down'), 'b')
    assert.equal(vimStepItem(items, 'c', 'down'), 'c')
    assert.equal(vimStepItem(items, 'b', 'up'), 'a')
    assert.equal(vimStepItem(items, 'a', 'up'), 'a')
  })
  it('first and last jump to the ends', () => {
    assert.equal(vimStepItem(items, 'b', 'first'), 'a')
    assert.equal(vimStepItem(items, 'b', 'last'), 'c')
  })
  it('from no row every move starts at the first; an empty panel gives null', () => {
    assert.equal(vimStepItem(items, 'z', 'down'), 'a')
    assert.equal(vimStepItem(items, null, 'up'), 'a')
    assert.equal(vimStepItem([], 'a', 'down'), null)
    assert.equal(vimStepItem(items, 'b', 'sideways'), 'b')
  })
})

describe('103 T003: the selectors name classes the WUI really renders', () => {
  const vue = []
  const walk = (dir) => {
    for (const d of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, d.name)
      if (d.isDirectory()) walk(p)
      else if (d.name.endsWith('.vue')) vue.push(readFileSync(p, 'utf8'))
    }
  }
  walk(SRC)
  const all = vue.join('\n')

  it('every root and row class appears in a .vue file (a rename must update vim-panels.mjs)', () => {
    const sels = [...VIM_PANELS.flatMap((p) => [...PANE_SELECTORS[p].roots, ...PANE_SELECTORS[p].items.split(/\s*,\s*/)]), ...VIM_COLLAPSED.split(/\s*,\s*/)]
    const classes = new Set(sels.flatMap((s) => (s.match(/\.[\w-]+/g) || []).map((c) => c.slice(1))))
    assert.ok(classes.size > 20, `vacuous: only ${classes.size} classes`)
    const missing = [...classes].filter((c) => !all.includes(c))
    assert.deepEqual(missing, [])
  })

  it('control: a class nobody renders is reported missing', () => {
    assert.equal(all.includes('vim-panels-no-such-class'), false)
  })
})
