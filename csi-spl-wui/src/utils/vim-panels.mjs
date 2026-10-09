/**
 * 103 T003: the four vim panels (spec 103 §2, §4.1, §4.2, §6.3) - which DOM
 * root holds each panel in every view, which panel an element sits in, where
 * h / l / Esc lands, and the rows j / k / g g / G walk.
 *
 * Owner numbering (HUM-10, t1 7d9e1681): 0 = the icon rail, 1 = the left
 * list, 2 = the middle list / main, 3 = the topic or detail pane on the right.
 *
 * Pure: the DOM is duck-typed (closest / matches / querySelectorAll /
 * getClientRects / setAttribute), so the unit test drives it with plain
 * objects. Nothing here is mounted; the key layer (T005) and the view
 * adapters (T006+) call it.
 */

/** The panels, left to right. */
export const VIM_PANELS = Object.freeze([0, 1, 2, 3])

/** Not a panel even though it sits inside one: the Omnibox (docked inside .spool-main, or the top bar). */
export const VIM_NOT_A_PANEL = '.omnibox-dock, .top-bar__omnibox'

/**
 * 050: a collapsed panel is a strip whose children are display: none, but the
 * strip itself still has a box. Anything inside one counts as hidden.
 */
export const VIM_COLLAPSED = [
  '.spool-shell[data-collapse-channels="1"] > .sidebar',
  '.spool-shell[data-collapse-topic="1"] > .spool-main',
  '.spool-shell[data-collapse-threads="1"] > .topic',
].join(', ')

/** A panel's selected row (spec 4.1 step 2). aria-selected="false" rows do not match. */
export const VIM_ACTIVE_ITEM = '[aria-current="true"], [aria-current="page"], [aria-selected="true"], [data-selected="true"]'

/**
 * Each panel's roots across the views, the most specific first: a view that
 * renders its own left list inside the page (docs tree, help nav, settings
 * nav, calendar year strip, issues epic chips) takes Panel 1 from the
 * sidebar body, and its reader takes Panel 2 from .spool-main. `items` is
 * what j / k walk; `[data-vim-item]` lets a view adapter (T006+) opt a row in.
 */
export const PANE_SELECTORS = Object.freeze({
  0: Object.freeze({
    roots: Object.freeze(['.sidebar-rail']),
    items: '.sidebar-tab, .sidebar-rail__help, .sidebar-rail__docs, .sidebar-rail__qto, .sidebar-rail__settings, [data-vim-item]',
  }),
  1: Object.freeze({
    roots: Object.freeze(['.docs-tree', '.help-nav', '.settings-nav', '.calendar-body__strip', '.issues-chips', '.sidebar-body']),
    items: '.nav-item, .settings-nav__link, .docs-tree__item, .side-hit, .issues-chip, [role="treeitem"], [data-vim-item]',
  }),
  2: Object.freeze({
    roots: Object.freeze(['.docs-content', '.help-content', '.settings-content', '.calendar-body__main', '.spool-main']),
    items: 'article.msg, a.topic-row, tr.issues-row, tr[data-test="events-row"], .archive-row, [data-vim-item]',
  }),
  3: Object.freeze({
    roots: Object.freeze(['aside.live-pane', 'aside.operator-pane', '.issues-detail-side']),
    items: 'article.msg, [data-vim-item]',
  }),
})

/*
 * The order activePanelOf tests the roots in: the right pane, then the
 * in-page lists and readers (they sit inside .spool-main), then the shell.
 */
const ROOT_ORDER = Object.freeze([
  ...PANE_SELECTORS[3].roots.map((s) => [s, 3]),
  ...PANE_SELECTORS[1].roots.filter((s) => s !== '.sidebar-body').map((s) => [s, 1]),
  ...PANE_SELECTORS[2].roots.map((s) => [s, 2]),
  ['.sidebar-rail', 0],
  ['.sidebar-body', 1],
])

/** @param {unknown} el */
function closestOf(el) {
  const e = /** @type {{ closest?: (s: string) => unknown } | null} */ (el)
  return e && typeof e.closest === 'function' ? /** @type {(s: string) => unknown} */ (e.closest.bind(e)) : null
}

/**
 * Laid out at all: a display: none element (or one inside it) has no client
 * rects. An object without getClientRects counts as shown.
 * @param {unknown} el
 */
export function vimShown(el) {
  const e = /** @type {{ getClientRects?: () => ArrayLike<unknown> } | null} */ (el)
  if (!e) return false
  if (typeof e.getClientRects !== 'function') return true
  return e.getClientRects().length > 0
}

/**
 * The panel an element sits in, or -1 for none (the Omnibox, a dialog, the
 * top bar, the body).
 * @param {unknown} el
 * @returns {-1 | 0 | 1 | 2 | 3}
 */
export function activePanelOf(el) {
  const closest = closestOf(el)
  if (!closest) return -1
  if (closest(VIM_NOT_A_PANEL)) return -1
  for (const [sel, panel] of ROOT_ORDER) {
    if (closest(/** @type {string} */ (sel))) return /** @type {0 | 1 | 2 | 3} */ (panel)
  }
  return -1
}

/**
 * Does this panel root take keys? Shown, and not inside a collapsed strip.
 * @param {unknown} root
 * @param {{ visible?: (el: unknown) => boolean }} [opts]
 */
export function panelUsable(root, { visible = vimShown } = {}) {
  if (!root || !visible(root)) return false
  const closest = closestOf(root)
  return !(closest && closest(VIM_COLLAPSED))
}

/**
 * A panel's root in the document: the first root selector, most specific
 * first, with a usable element. null when the view has no such panel or it
 * is hidden or collapsed (spec 6.3).
 * @param {{ querySelectorAll?: (s: string) => ArrayLike<unknown> } | null} doc
 * @param {number} panel
 * @param {{ visible?: (el: unknown) => boolean }} [opts]
 * @returns {unknown}
 */
export function panelRoot(doc, panel, opts = {}) {
  const spec = /** @type {Record<number, { roots: readonly string[] }>} */ (PANE_SELECTORS)[panel]
  if (!spec || !doc || typeof doc.querySelectorAll !== 'function') return null
  for (const sel of spec.roots) {
    const hit = Array.from(doc.querySelectorAll(sel)).find((el) => panelUsable(el, opts))
    if (hit) return hit
  }
  return null
}

/**
 * The panels this view shows right now, left to right.
 * @param {{ querySelectorAll?: (s: string) => ArrayLike<unknown> } | null} doc
 * @param {{ visible?: (el: unknown) => boolean }} [opts]
 * @returns {number[]}
 */
export function visiblePanels(doc, opts = {}) {
  return VIM_PANELS.filter((p) => panelRoot(doc, p, opts) != null)
}

/**
 * Where h / Esc ('left', 'back') or l ('right') lands from `fromPanel`: the
 * nearest visible panel that way, skipping the hidden and collapsed ones
 * (FR-008). No wrap: with nothing that way it stays at `fromPanel`. From
 * nowhere (-1) 'right' starts at the leftmost visible panel.
 * @param {number} fromPanel
 * @param {'left' | 'right' | 'back'} dir
 * @param {readonly number[]} visiblePanelsNow
 * @returns {number}
 */
export function resolveNextPanel(fromPanel, dir, visiblePanelsNow) {
  const there = VIM_PANELS.filter((p) => (visiblePanelsNow || []).includes(p))
  if (dir === 'right') {
    const next = there.find((p) => p > fromPanel)
    return next === undefined ? fromPanel : next
  }
  if (dir === 'left' || dir === 'back') {
    const prev = there.filter((p) => p < fromPanel).pop()
    return prev === undefined ? fromPanel : prev
  }
  return fromPanel
}

/**
 * A row's key, for the per-panel memory (spec 4.1 step 1): data-key, else
 * data-msg-id, else id, else href; '' when it has none.
 * @param {unknown} el
 */
export function vimItemKey(el) {
  const e = /** @type {{ getAttribute?: (n: string) => string | null } | null} */ (el)
  if (!e || typeof e.getAttribute !== 'function') return ''
  for (const attr of ['data-key', 'data-msg-id', 'id', 'href']) {
    const v = e.getAttribute(attr)
    if (v) return v
  }
  return ''
}

/**
 * Roving tabindex (spec 6.2): `current` gets 0, every other row -1. Rows
 * stay as they are when `current` is not one of them.
 * @param {readonly unknown[]} items
 * @param {unknown} current
 */
export function vimRoveTabindex(items, current) {
  if (!items.includes(current)) return
  for (const el of items) {
    const e = /** @type {{ setAttribute?: (n: string, v: string) => void } | null} */ (el)
    if (e && typeof e.setAttribute === 'function') e.setAttribute('tabindex', el === current ? '0' : '-1')
  }
}

/**
 * The rows j / k walk in a panel, in document order: its item selector,
 * minus rows of another panel nested in the root (the docs tree inside
 * .spool-main), the hidden loop copies of the rail (aria-hidden) and rows
 * not laid out. With `current`, the roving tabindex moves onto it.
 * @param {{ querySelectorAll?: (s: string) => ArrayLike<unknown> } | null} panelRootEl
 * @param {number} panelId
 * @param {{ visible?: (el: unknown) => boolean, current?: unknown }} [opts]
 * @returns {unknown[]}
 */
export function panelItems(panelRootEl, panelId, { visible = vimShown, current } = {}) {
  const spec = /** @type {Record<number, { items: string }>} */ (PANE_SELECTORS)[panelId]
  if (!spec || !panelRootEl || typeof panelRootEl.querySelectorAll !== 'function') return []
  const items = Array.from(panelRootEl.querySelectorAll(spec.items)).filter((el) => {
    const closest = closestOf(el)
    if (closest && closest('[aria-hidden="true"]')) return false
    if (activePanelOf(el) !== panelId) return false
    return visible(el)
  })
  if (current !== undefined) vimRoveTabindex(items, current)
  return items
}

/**
 * The row a panel's focus lands on when h / l / Esc enters it (spec 4.1):
 * the remembered row, else the selected one, else the first; null for an
 * empty panel (the caller focuses the root, tabindex -1).
 * @param {readonly unknown[]} items
 * @param {{ remembered?: string }} [opts]
 * @returns {unknown}
 */
export function panelEntry(items, { remembered = '' } = {}) {
  if (!items.length) return null
  if (remembered) {
    const kept = items.find((el) => vimItemKey(el) === remembered)
    if (kept) return kept
  }
  const active = items.find((el) => {
    const e = /** @type {{ matches?: (s: string) => boolean } | null} */ (el)
    return Boolean(e && typeof e.matches === 'function' && e.matches(VIM_ACTIVE_ITEM))
  })
  return active || items[0]
}

/**
 * j ('down'), k ('up'), g g ('first'), G ('last') from `current` (spec 4.2,
 * 4.3). No wrap: past either end it stays. From a row that is not in the
 * list every move starts at the first row. null for an empty panel.
 * @param {readonly unknown[]} items
 * @param {unknown} current
 * @param {'down' | 'up' | 'first' | 'last'} action
 * @returns {unknown}
 */
export function vimStepItem(items, current, action) {
  if (!items.length) return null
  if (action === 'first') return items[0]
  if (action === 'last') return items[items.length - 1]
  const i = items.indexOf(current)
  if (i < 0) return items[0]
  if (action === 'down') return items[Math.min(i + 1, items.length - 1)]
  if (action === 'up') return items[Math.max(i - 1, 0)]
  return current
}
