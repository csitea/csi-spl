/**
 * SPL-4901 (owner HUM-10, t1 7da30ebd msg 5af63dee): the search button opens
 * on the entities of the section the reader is in. The one map from a
 * section to its search:
 *
 * - `doc`: the Qto documents (`/docs`, `/workspace/docs`): the hub search,
 *   the Omnibox line prefilled `/search type:doc ` (the token is visible;
 *   deleting it widens the search).
 * - `calendar`: calendar entries (`/calendar`): the calendar's own search
 *   (`GET /v1/calendar/search`, CalendarPhoneSearch); the hub search has no
 *   calendar type (`type:event` is the event log).
 * - `notes`: notes (`/notes`): the Notes page's own filter; notes are not in
 *   the hub search on purpose (spec 155 section 2.5).
 * - '': every other section keeps the plain `/search `.
 *
 * Paths in any shipped locale (`/fi/notes`), as productPath reads them.
 */
import { productPath } from './signed-out-redirect.mjs'

const DOCS_RE = /^\/(?:workspace\/)?docs(?:\/|$)/
const CALENDAR_RE = /^\/calendar(?:\/|$)/
const NOTES_RE = /^\/notes(?:\/|$)/

/** The plain search line the Omnibox opens with. */
export const SEARCH_LINE = '/search '

/** The Notes page's filter, focused by the search button on /notes. */
export const NOTES_FILTER_SELECTOR = '[data-test="notes-filter"]'

/**
 * The section's search type for a route path.
 * @param {string} path
 * @returns {'doc' | 'calendar' | 'notes' | ''}
 */
export function sectionSearchType(path) {
  const p = productPath(path)
  if (DOCS_RE.test(p)) return 'doc'
  if (CALENDAR_RE.test(p)) return 'calendar'
  if (NOTES_RE.test(p)) return 'notes'
  return ''
}

/**
 * The Omnibox line a search opens with: the hub type token for a section
 * the hub search covers, else the plain line.
 * @param {string} type
 */
export function sectionSearchLine(type) {
  return type === 'doc' ? `${SEARCH_LINE}type:doc ` : SEARCH_LINE
}

/**
 * SPL-2516 + SPL-4901 (msg 1497d676): the phone routes whose dock and status
 * strip collapse until the search button is tapped: the Qto reading routes
 * and Notes.
 * @param {string} path
 */
export function isDockCollapsedPath(path) {
  const type = sectionSearchType(path)
  return type === 'doc' || type === 'notes'
}

/**
 * SPL-4901 (msg acf9d324): leaving a section puts the Omnibox back to
 * normal. A line that is still only the left section's prefill (nothing
 * typed after the token) is emptied; any other line is kept as typed.
 * @param {string} text the Omnibox line
 * @param {string} type the left section's type
 * @returns {string}
 */
export function lineLeavingSection(text, type) {
  const line = sectionSearchLine(type)
  if (line === SEARCH_LINE) return text
  return String(text || '').trim() === line.trim() ? '' : text
}
