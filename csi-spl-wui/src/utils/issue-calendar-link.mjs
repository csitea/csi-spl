/**
 * SPL-2034 (design B, t1 edc177bc): the two links between an issue with a
 * deadline and the calendar. `/calendar?d=<day>&issue=<KEY>` opens the week
 * (desktop) or day (phone) holding the deadline with its pop-over open;
 * `/issues?issue=<KEY>` opens the issue. The key resolves; `d=` is a hint
 * that may go stale (spec 138). The day is the grid's: the viewer's wall day.
 */
import { isoDate } from './date-iso.mjs'

const key = (k) => String(k || '').trim()

/**
 * The calendar path that opens `issueKey`'s deadline; '' without a key or a
 * readable deadline.
 * @param {string} issueKey
 * @param {string} deadline RFC 3339
 * @returns {string}
 */
export function issueCalendarHref(issueKey, deadline) {
  const k = key(issueKey)
  if (!k || !deadline || Number.isNaN(Date.parse(deadline))) return ''
  return `/calendar?d=${isoDate(deadline)}&issue=${encodeURIComponent(k)}`
}

/**
 * The issues page with `issueKey` open; '' without a key.
 * @param {string} issueKey
 * @returns {string}
 */
export function issuePageHref(issueKey) {
  const k = key(issueKey)
  return k ? `/issues?issue=${encodeURIComponent(k)}` : ''
}

/**
 * A deadline already past at `nowMs` (the red tint on Show in calendar).
 * @param {string} deadline RFC 3339
 * @param {number} [nowMs]
 * @returns {boolean}
 */
export function deadlineOverdue(deadline, nowMs = Date.now()) {
  const at = Date.parse(deadline || '')
  return !Number.isNaN(at) && at < nowMs
}
