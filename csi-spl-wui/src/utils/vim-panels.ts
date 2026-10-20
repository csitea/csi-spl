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

export type VimPanel = 0 | 1 | 2 | 3
export type PanelQuery = { querySelectorAll?: (s: string) => ArrayLike<unknown> } | null
type VisibleOpt = { visible?: (el: unknown) => boolean }

/** The panels, left to right. */
export const VIM_PANELS: readonly VimPanel[] = Object.freeze([0, 1, 2, 3] as const)

/** Not a panel even though it sits inside one: the Omnibox (docked inside .spool-main, or the top bar). */
const VIM_NOT_A_PANEL = '.omnibox-dock, .top-bar__omnibox'

/**
 * 050: a collapsed panel is a strip whose children are display: none, but the
 * strip itself still has a box. Anything inside one counts as hidden.
 */
export const VIM_COLLAPSED: string = [
  '.spool-shell[data-collapse-channels="1"] > .sidebar',
  '.spool-shell[data-collapse-topic="1"] > .spool-main',
  '.spool-shell[data-collapse-threads="1"] > .topic',
].join(', ')

/** A panel's selected row (spec 4.1 step 2). aria-selected="false" rows do not match. */
export const VIM_ACTIVE_ITEM: string = '[aria-current="true"], [aria-current="page"], [aria-selected="true"], [data-selected="true"]'

/**
 * Each panel's roots across the views, the most specific first: a view that
 * renders its own left list inside the page (docs tree, help nav, settings
 * nav, calendar year strip, issues epic chips) takes Panel 1 from the
 * sidebar body, and its reader takes Panel 2 from .spool-main. `items` is
 * what j / k walk; `[data-vim-item]` lets a view adapter (T006+) opt a row in.
 */
export const PANE_SELECTORS: Readonly<Record<VimPanel, { readonly roots: readonly string[], items: string }>> = Object.freeze({
  0: Object.freeze({
    roots: Object.freeze(['.sidebar-rail']),
    items: '.sidebar-tab, .sidebar-rail__help, .sidebar-rail__qto, .sidebar-rail__settings, [data-vim-item]',
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
const ROOT_ORDER: readonly (readonly [string, VimPanel])[] = Object.freeze([
  ...PANE_SELECTORS[3].roots.map((s) => [s, 3] as const),
  ...PANE_SELECTORS[1].roots.filter((s) => s !== '.sidebar-body').map((s) => [s, 1] as const),
  ...PANE_SELECTORS[2].roots.map((s) => [s, 2] as const),
  ['.sidebar-rail', 0] as const,
  ['.sidebar-body', 1] as const,
])

function closestOf(el: unknown): ((s: string) => unknown) | null {
  const e = el as { closest?: (s: string) => unknown } | null
  return e && typeof e.closest === 'function' ? e.closest.bind(e) : null
}

/**
 * Laid out at all: a display: none element (or one inside it) has no client
 * rects. An object without getClientRects counts as shown.
 */
export function vimShown(el: unknown): boolean {
  const e = el as { getClientRects?: () => ArrayLike<unknown> } | null
  if (!e) return false
  if (typeof e.getClientRects !== 'function') return true
  return e.getClientRects().length > 0
}

/**
 * The panel an element sits in, or -1 for none (the Omnibox, a dialog, the
 * top bar, the body).
 */
export function activePanelOf(el: unknown): -1 | VimPanel {
  const closest = closestOf(el)
  if (!closest) return -1
  if (closest(VIM_NOT_A_PANEL)) return -1
  for (const [sel, panel] of ROOT_ORDER) {
    if (closest(sel)) return panel
  }
  return -1
}

/**
 * Does this panel root take keys? Shown, and not inside a collapsed strip.
 */
export function panelUsable(root: unknown, { visible = vimShown }: VisibleOpt = {}): boolean {
  if (!root || !visible(root)) return false
  const closest = closestOf(root)
  return !(closest && closest(VIM_COLLAPSED))
}

/**
 * A panel's root in the document: the first root selector, most specific
 * first, with a usable element. null when the view has no such panel or it
 * is hidden or collapsed (spec 6.3).
 */
export function panelRoot(doc: PanelQuery, panel: number, opts: VisibleOpt = {}): Element | null {
  const spec = (PANE_SELECTORS as Record<number, { roots: readonly string[] } | undefined>)[panel]
  if (!spec || !doc || typeof doc.querySelectorAll !== 'function') return null
  for (const sel of spec.roots) {
    const hit = Array.from(doc.querySelectorAll(sel)).find((el) => panelUsable(el, opts))
    if (hit) return hit as Element
  }
  return null
}

/**
 * The panels this view shows right now, left to right.
 */
export function visiblePanels(doc: PanelQuery, opts: VisibleOpt = {}): VimPanel[] {
  return VIM_PANELS.filter((p) => panelRoot(doc, p, opts) != null)
}

/**
 * Where h / Esc ('left', 'back') or l ('right') lands from `fromPanel`: the
 * nearest visible panel that way, skipping the hidden and collapsed ones
 * (FR-008). No wrap: with nothing that way it stays at `fromPanel`. From
 * nowhere (-1) 'right' starts at the leftmost visible panel.
 */
export function resolveNextPanel(fromPanel: number, dir: 'left' | 'right' | 'back', visiblePanelsNow: readonly number[]): number {
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
 */
export function vimItemKey(el: unknown): string {
  const e = el as { getAttribute?: (n: string) => string | null } | null
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
 */
export function vimRoveTabindex(items: readonly unknown[], current: unknown): void {
  if (!items.includes(current)) return
  for (const el of items) {
    const e = el as { setAttribute?: (n: string, v: string) => void } | null
    if (e && typeof e.setAttribute === 'function') e.setAttribute('tabindex', el === current ? '0' : '-1')
  }
}

/**
 * The rows j / k walk in a panel, in document order: its item selector,
 * minus rows of another panel nested in the root (the docs tree inside
 * .spool-main), the hidden loop copies of the rail (aria-hidden) and rows
 * not laid out. With `current`, the roving tabindex moves onto it.
 */
export function panelItems(panelRootEl: PanelQuery | Element, panelId: number, { visible = vimShown, current }: VisibleOpt & { current?: unknown } = {}): HTMLElement[] {
  const spec = (PANE_SELECTORS as Record<number, { items: string } | undefined>)[panelId]
  const root = panelRootEl as PanelQuery
  if (!spec || !root || typeof root.querySelectorAll !== 'function') return []
  const items = Array.from(root.querySelectorAll(spec.items)).filter((el) => {
    const closest = closestOf(el)
    if (closest && closest('[aria-hidden="true"]')) return false
    if (activePanelOf(el) !== panelId) return false
    return visible(el)
  })
  if (current !== undefined) vimRoveTabindex(items, current)
  return items as HTMLElement[]
}

/**
 * The row a panel's focus lands on when h / l / Esc enters it (spec 4.1):
 * the remembered row, else the selected one, else the first; null for an
 * empty panel (the caller focuses the root, tabindex -1).
 */
export function panelEntry(items: readonly unknown[], { remembered = '' }: { remembered?: string } = {}): HTMLElement | null {
  if (!items.length) return null
  if (remembered) {
    const kept = items.find((el) => vimItemKey(el) === remembered)
    if (kept) return kept as HTMLElement
  }
  const active = items.find((el) => {
    const e = el as { matches?: (s: string) => boolean } | null
    return Boolean(e && typeof e.matches === 'function' && e.matches(VIM_ACTIVE_ITEM))
  })
  return (active || items[0]) as HTMLElement
}

/**
 * j ('down'), k ('up'), g g ('first'), G ('last') from `current` (spec 4.2,
 * 4.3). No wrap: past either end it stays. From a row that is not in the
 * list every move starts at the first row. null for an empty panel.
 */
export function vimStepItem(items: readonly unknown[], current: unknown, action: 'down' | 'up' | 'first' | 'last'): HTMLElement | null {
  if (!items.length) return null
  const at = (i: number) => items[i] as HTMLElement
  if (action === 'first') return at(0)
  if (action === 'last') return at(items.length - 1)
  const i = items.indexOf(current)
  if (i < 0) return at(0)
  if (action === 'down') return at(Math.min(i + 1, items.length - 1))
  if (action === 'up') return at(Math.max(i - 1, 0))
  return current as HTMLElement
}
