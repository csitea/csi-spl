/**
 * Spec 107 v1.2 T013 + T014 (owner R9, R10; spec 4.1, 5.2, 5.3): what the
 * member's own controls in the Working hours dialog and the panel's Mine tab
 * write, as PUT /v1/me/hours bodies (T006). Pure: no fetch, no DOM; loaded
 * only by the calendar's lazy hours chunks (027).
 *
 * - Approve day / Approve week / Approve N days approve CLOSED days only
 *   (before the member's today); today has its own Approve so far (4.1).
 * - A delta (2.3) is accepted with one tap: the entry grows by it.
 * - Reject writes the row `rejected` (counts 0); Undo puts back what it was:
 *   an open suggestion comes back by removing the entry.
 * - Every write carries the row's note: PUT replaces it, and R10's note per
 *   discussion line (<= 500 characters) is the entry's `note`.
 */

export const HOURS_STEP = 15
export const HOURS_DAY_CAP = 1440
export const HOURS_NOTE_MAX = 500
export const HOURS_ADD_DEFAULT = 30
export const HOURS_UNDO_MS = 10000

/** minutes kept within 0..1440 */
export function hoursClamp(min) {
  return Math.min(HOURS_DAY_CAP, Math.max(0, Math.round(Number(min) || 0)))
}

/** minutes stepped by `by` (±15), within 0..1440 */
export function hoursStep(min, by) {
  return hoursClamp((Number(min) || 0) + by)
}

/**
 * Typed minutes: "1:30" or "90" -> 90; -1 when it is not a time.
 * @param {string} text
 */
export function hoursParseMinutes(text) {
  const s = String(text ?? '').trim()
  let m = s.match(/^(\d{1,2}):([0-5]\d)$/)
  if (m) return Number(m[1]) * 60 + Number(m[2])
  m = s.match(/^\d{1,4}$/)
  return m ? Number(s) : -1
}

/** a note as the hub keeps it: trimmed, at most 500 characters */
export function hoursNote(text) {
  return [...String(text ?? '').trim()].slice(0, HOURS_NOTE_MAX).join('')
}

/** a row still waiting for the member: an open suggestion or a delta */
export function hoursRowOpen(r) {
  return Boolean(r) && (r.state === 'suggested' || (r.state === 'approved' && Number(r.delta) > 0))
}

/**
 * Can the member write `day` of this period? Not frozen, not after today,
 * and the period open or returned (frozen and approved = Final are locked).
 * @param {{ date: string, frozen?: boolean }} d a day of a GET /v1/me/hours answer
 * @param {{ state?: string } | null | undefined} period
 * @param {string} today YYYY-MM-DD
 */
export function hoursDayEditable(d, period, today) {
  const ps = String(period?.state || 'open')
  return Boolean(d) && !d.frozen && (ps === 'open' || ps === 'returned') && (!today || String(d.date) <= today)
}

/** the entry approving a row as it stands: a suggestion its minutes, a delta added */
export function hoursApproveRow(day, r) {
  const grow = r.state === 'approved' ? Math.max(0, Number(r.delta) || 0) : 0
  return { day, target: r.target, minutes: hoursClamp((Number(r.minutes) || 0) + grow), state: 'approved', note: String(r.note || '') }
}

/** the days of an answer, with today / closed computed when the answer lacks them */
function daysOf(body) {
  const today = String(body?.today || '')
  return (Array.isArray(body?.days) ? body.days : []).filter(Boolean).map((d) => ({
    ...d,
    today: d.today ?? d.date === today,
    closed: d.closed ?? (today ? d.date < today : false),
  }))
}

/**
 * The PUT entries approving the open rows of some days of one answer.
 * `which`: 'closed' (Approve week / Approve N days: every closed day),
 * 'today' (Approve so far), or a YYYY-MM-DD (Approve day: that day, closed).
 * @param {any} body a GET /v1/me/hours answer
 * @param {string} which
 */
export function hoursApproveEntries(body, which) {
  const today = String(body?.today || '')
  const out = []
  for (const d of daysOf(body)) {
    const pick = which === 'closed' ? d.closed && !d.today
      : which === 'today' ? d.today
        : d.date === which && d.closed && !d.today
    if (!pick || !hoursDayEditable(d, body?.period, today)) continue
    for (const r of Array.isArray(d.rows) ? d.rows : []) {
      if (hoursRowOpen(r)) out.push(hoursApproveRow(d.date, r))
    }
  }
  return out
}

/** open rows on the closed, writable days: the "Approve week · N open" count */
export function hoursOpenCount(body) {
  return hoursApproveEntries(body, 'closed').length
}

/** reject: the row counts 0 */
export function hoursRejectEntry(day, r) {
  return { day, target: r.target, minutes: hoursClamp(r.minutes), state: 'rejected', note: String(r.note || '') }
}

/**
 * The PUT body that undoes a reject: an open suggestion comes back when the
 * entry is removed; an entry gets its old minutes, state and note.
 * @param {string} day
 * @param {{ target: string, state: string, minutes: number, note?: string }} prev the row before
 */
export function hoursUndoBody(day, prev) {
  if (prev.state === 'suggested') return { remove: [{ day, target: prev.target }] }
  return { entries: [{ day, target: prev.target, minutes: hoursClamp(prev.minutes), state: prev.state === 'rejected' ? 'rejected' : 'approved', note: String(prev.note || '') }] }
}

/**
 * Edit (stepper, +15, typed minutes) and note: the row approved with the new
 * minutes and note. A note on an open suggestion approves it with its
 * suggested minutes (spec 5.2); a rejected row keeps its state.
 * @param {string} day
 * @param {{ target: string, state: string, minutes: number, note?: string }} r
 * @param {{ minutes?: number, note?: string }} change
 */
export function hoursEditEntry(day, r, change) {
  const minutes = change.minutes === undefined ? r.minutes : change.minutes
  const note = change.note === undefined ? String(r.note || '') : hoursNote(change.note)
  const state = r.state === 'rejected' && change.minutes === undefined ? 'rejected' : 'approved'
  return { day, target: r.target, minutes: hoursClamp(minutes), state, note }
}

/** + Add: a new row on `day` for `target`, approved */
export function hoursAddEntry(day, target, minutes, note = '') {
  return { day, target, minutes: hoursClamp(minutes), state: 'approved', note: hoursNote(note) }
}

/** The i18n key of a refused write: { status, error } as putMyHours throws it. */
export function hoursRefusalKey(err) {
  const code = err && typeof err === 'object' ? String(err.error || '') : ''
  if (code === 'period_frozen') return 'hours_cal.err_frozen'
  if (code === 'day_cap') return 'hours_cal.err_day_cap'
  if (code === 'period_state') return 'hours_cal.err_state'
  if (code === 'bad_day' || code === 'bad_hours' || code === 'bad_json') return 'hours_cal.err_bad'
  if (err && typeof err === 'object' && (err.status === 401 || err.status === 403)) return 'hours_cal.err_session'
  return 'hours_cal.err_network'
}
