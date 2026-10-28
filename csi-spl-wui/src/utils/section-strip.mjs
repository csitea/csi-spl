// CLE-77886 (owner, t1 topic ac0fa400): on a phone every section keeps the
// ONE section strip (the rail's row of Channels, DMs, Issues, ...) on top,
// the section shown as the selected control and no title text. A section's
// own page (Issues, People, Monitoring and each of its tabs, Help, Workspace
// settings, ...) shows the strip with no header of its own; a drill-down (a
// channel, a person's card, a settings section) keeps its own header and Back.
import { productPath } from './signed-out-redirect.mjs'
import { TAB_ROUTE_PATHS } from './sidebar-tabs.mjs'
import { COSTS_PAGES } from './reporting-costs.mjs'

/* SPL-3785 (owner HUM-10, t1 c3e53990: the strip must not "jump on and off
   based on the tab"): a section's own page is read off the route, never a
   hand-kept list - the list missed 8 Monitoring and Reporting tabs added
   after it. A tab is one segment under its section (/monitoring/costs), a
   drill-down two (/monitoring/agents/<id>). A tab with a page bar of its own
   (Reporting -> Costs, SPL-3798) has its pages read off that bar's list. */
const TAB_SECTION_PAGE = /^\/(monitoring|reporting)(\/[^/]+)?$/
/* the rail links' own pages; their deeper paths are documents and sections */
const RAIL_LINK_ROOTS = new Set(['/help', '/docs', '/tenant-settings'])

/** true when the route is a section's own page (not a drill-down inside it) */
export function isSectionPage(path) {
  const p = productPath(path)
  return p === '/' || RAIL_LINK_ROOTS.has(p) || TAB_SECTION_PAGE.test(p) || TAB_ROUTE_PATHS.includes(p) ||
    COSTS_PAGES.some((c) => c.path === p)
}

/** the rail links (not tabs) a section page may be: Help, Docs, Workspace settings */
export function railLinkSection(path) {
  const p = productPath(path)
  if (p === '/help' || p.startsWith('/help/')) return 'help'
  /* t1 efde25bb: Docs (Qto) is a docs section too: its left panel is its file tree */
  if (p === '/docs' || p.startsWith('/docs/') || p === '/workspace/docs') return 'docs'
  if (p === '/tenant-settings' || p.startsWith('/tenant-settings/')) return 'settings'
  return ''
}

/**
 * The endless strip (owner, msg 8ebbce0e: "it will roll constantly ... like
 * a continuous strip"): the row is three copies [clone][real][clone], each
 * `set` px wide. `pos` is the distance from the row's physical left edge.
 * Kept inside the middle half of the row, a swipe never reaches an end: past
 * the last control the first comes in again. Returns the position to jump to
 * (the same picture, one copy over), or `pos` when it is already inside.
 * @param {number} pos
 * @param {number} set
 */
export function loopPosition(pos, set) {
  if (!(set > 0)) return pos
  /* SPL-2062: 1 px of slack. The snapping strip rests on control edges, and
     with an even number of controls set / 2 is one of them: a sub-pixel
     scroll there (a press, a drag) must not jump the row a copy over. */
  if (pos < set * 0.5 - 1) return pos + set
  if (pos > set * 1.5 + 1) return pos - set
  return pos
}

/** SPL-2062: the narrowest a phone strip control may be (a 44 px target plus room for its name) */
export const STRIP_ITEM_MIN = 64

/**
 * SPL-2062 (owner HUM-10, t1 508e17a0 msg ae4f7ceb: "there will never be a
 * half or non-whole icon on the top bar"): how many controls share the
 * strip's width. Each control is view / fit wide, so the strip always shows
 * exactly `fit` whole ones, and its scroll snaps one control at a time. As
 * many as fit at STRIP_ITEM_MIN, never more than there are, at least one.
 * @param {number} view the strip's inner width, px
 * @param {number} count the controls in the strip
 * @param {number} [min]
 */
export function stripFit(view, count, min = STRIP_ITEM_MIN) {
  if (!(view > 0) || !(count > 0)) return 1
  return Math.max(1, Math.min(count, Math.floor(view / min)))
}

/**
 * SPL-2062: a scrollLeft on the strip's control grid (a multiple of one
 * control's width), so a centring write lands where a snap would, and the
 * browser does not move the row again a moment later.
 * @param {number} pos
 * @param {number} step one control's width, px (0: leave pos as it is)
 */
export function onStripGrid(pos, step) {
  if (!(step > 0)) return pos
  return Math.round(pos / step) * step
}

/**
 * CLE-77886 (HUM-24, csitea 7930dfbf: "there is no exit from the Issues
 * window"): the conversation a reader left for a section page. 'channel'
 * for a channel or the lobby, 'dm' for a direct message, '' for the rest.
 * @param {string} path
 */
export function chatKind(path) {
  const p = productPath(path)
  if (p === '/lobby' || p.startsWith('/channel/')) return 'channel'
  if (p.startsWith('/dm/')) return 'dm'
  return ''
}

/**
 * Where a way out of a section page leads: the rail's Channels to the last
 * channel, Direct messages to the last DM, Flow and the close X to the last
 * conversation of either kind; the lobby when there was none ('' for a DM:
 * no DM to go back to, the list on the left is the way on).
 * @param {{ channel?: string, dm?: string, chat?: string }} last
 * @param {string} [tab]
 */
export function sectionExitPath(last, tab = '') {
  const l = last || {}
  if (tab === 'dm') return l.dm || ''
  if (tab === 'channels') return l.channel || '/lobby'
  return l.chat || '/lobby'
}

/* SPL-3785 slice 6 (owner pick B, t1 c3e53990 poll 12414c26): on a phone the
   strip slides away while a reader scrolls down and comes back on a scroll
   up or at the top. A move under STRIP_SCROLL_STEP px from where the last
   decision was made changes nothing, so a jitter does not flicker it. */
export const STRIP_SCROLL_STEP = 8

/**
 * One scroll of a pane: whether the strip is hidden now, and the scrollTop
 * the next move is measured from.
 * @param {number} anchor the scrollTop of the last decision
 * @param {number} y the pane's scrollTop now
 * @param {boolean} hidden
 * @param {number} [step]
 * @returns {{ anchor: number, hidden: boolean }}
 */
export function stripScroll(anchor, y, hidden, step = STRIP_SCROLL_STEP) {
  if (y <= 0) return { anchor: 0, hidden: false }
  const d = y - anchor
  if (d >= step) return { anchor: y, hidden: true }
  if (d <= -step) return { anchor: y, hidden: false }
  return { anchor, hidden }
}
