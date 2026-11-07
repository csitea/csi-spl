/**
 * When the hub last returned data, for the top-bar clock: the formats, and the
 * rest from last-data-core.mjs.
 *
 * SPL-2144: it prints in the viewer's zone (Settings -> Appearance, else the
 * browser's) through date-iso.mjs, like every other clock of the WUI.
 */

import { isoDateTimeSec } from './date-iso.mjs'

export { lastDataAt, noteLastData, onLastData, resetLastData } from './last-data-core.mjs'

const PLACEHOLDER = '--:--:--'

/** HH:mm:ss in the viewer's zone, zero-padded, 24-hour. No instant yet: `--:--:--`. */
export function formatLastDataClock(ms) {
  return formatLastDataDate(ms).slice(11) || PLACEHOLDER
}

/** `yyyy-mm-dd HH:mm:ss` in the viewer's zone, for the tooltip. '' when there is no instant. */
export function formatLastDataDate(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms <= 0) return ''
  return isoDateTimeSec(ms)
}
