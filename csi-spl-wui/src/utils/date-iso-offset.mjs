/**
 * Spec 162 E7: YYYY-MM-DD HH:MM:SS±HH:MM in the viewer's zone, for the event
 * log's When cell. ISO 8601 with seconds and the zone's offset at that
 * instant, so one viewer's cells sort as text and none is ambiguous.
 * date-iso.mjs sits in the first-screen chunk; this file is imported by the
 * Events page alone, so it stays in that page's lazy chunk (ci_initial_gzip_kb).
 */
import { isoDateTimeSec } from "./date-iso.mjs"

const pad = (n) => String(n).padStart(2, "0")

/**
 * @param {unknown} value
 * @returns {string}
 */
export function isoDateTimeOffset(value) {
  const wall = isoDateTimeSec(value)
  if (!wall) return ""
  const ms = (value instanceof Date ? value : new Date(/** @type {string} */ (value))).getTime()
  const [y, mo, da, h, mi, s] = wall.split(/[- :]/).map(Number)
  const mins = Math.round((Date.UTC(y, mo - 1, da, h, mi, s) - Math.floor(ms / 1000) * 1000) / 60000)
  const abs = Math.abs(mins)
  return `${wall}${mins < 0 ? "-" : "+"}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
}
