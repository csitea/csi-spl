/**
 * Spec 112 WUI-1 (5, 5.3 (b)): the spec rows of roadmap.json, as the roadmap
 * page shows them. Pure: the page hands in today and the day-of function
 * (date-iso isoDate, the viewer's zone, spec 089), so a test pins both.
 *
 * - `when` is the URL's ?when=: 'week' (the ISO week, Monday first) or
 *   'month' (the calendar month) holding today; anything else = every row.
 * - A row matches a window when its tasks.md last changed inside it (5.3 (b);
 *   the goal part, 5.3 (a), is WUI-3's). A row with no date (no tasks.md, or
 *   a shallow build) never matches a window.
 */
import { calWeekStart } from './calendar-year.mjs'

export const ROADMAP_WHEN = Object.freeze(['week', 'month'])

/** 'week' | 'month' | '' from a ?when= query value. */
export function roadmapWhen(value) {
  const v = String(Array.isArray(value) ? value[0] : value || '')
  return ROADMAP_WHEN.includes(v) ? v : ''
}

/** The spec rows of a fetched roadmap.json ([] for anything else). */
export function roadmapSpecs(doc) {
  const specs = doc && typeof doc === 'object' && Array.isArray(doc.specs) ? doc.specs : []
  return specs.filter((s) => s && typeof s.id === 'string' && /^\d{3}-/.test(s.id))
}

/** True when the day `day` (YYYY-MM-DD) is in the `when` window of `today`. */
export function inWindow(day, when, today) {
  if (!when) return true
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(day || ''))) return false
  if (when === 'month') return day.slice(0, 7) === String(today).slice(0, 7)
  const start = calWeekStart(today)
  return Boolean(start) && calWeekStart(day) === start
}

/**
 * The rows shown for `when`, in roadmap.json's order (by spec dir).
 * @template {{tasks_changed?: string}} T
 * @param {T[]} specs
 * @param {string} when 'week' | 'month' | ''
 * @param {string} today YYYY-MM-DD in the viewer's zone
 * @param {(iso: string) => string} dayOf an instant -> YYYY-MM-DD in that zone
 * @returns {T[]}
 */
export function roadmapRows(specs, when, today, dayOf) {
  if (!when) return specs.slice()
  return specs.filter((s) => s.tasks_changed && inWindow(dayOf(s.tasks_changed), when, today))
}

/** The anchor id of a row, so /roadmap#spec-089 opens on it (spec 4.4). */
export function roadmapAnchor(id) {
  return `spec-${String(id).slice(0, 3)}`
}
