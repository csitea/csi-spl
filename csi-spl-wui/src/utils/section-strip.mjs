// CLE-77886 (owner, t1 topic ac0fa400): on a phone every section keeps the
// ONE section strip (the rail's row of Channels, DMs, Issues, ...) on top,
// the section shown as the selected control and no title text. A section
// whose content is a page (Issues, Event log, People, Boxes, Agents, Help,
// Workspace settings, ...) is level 2, so the layout shows the strip above
// that page; a drill-down (a channel, a person's card, a settings section)
// keeps its own header and Back.
import { productPath } from './signed-out-redirect.mjs'

const SECTION_PAGES = new Set([
  '/',
  '/issues',
  '/events',
  '/archive',
  '/users',
  '/people',
  '/agents',
  '/boxes',
  '/help',
  '/tenant-settings',
])

/** true when the route is a section's own page (not a drill-down inside it) */
export function isSectionPage(path) {
  return SECTION_PAGES.has(productPath(path))
}

/** the rail links (not tabs) a section page may be: Help, Workspace settings */
export function railLinkSection(path) {
  const p = productPath(path)
  if (p === '/help' || p.startsWith('/help/')) return 'help'
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
  if (pos < set * 0.5) return pos + set
  if (pos > set * 1.5) return pos - set
  return pos
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
