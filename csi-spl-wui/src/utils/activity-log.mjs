// CLE-77799 (owner topic 1fc29f99: "the admin should be able to see ... the
// main event log activities for this person, when he has logged in, and logged
// out etc."): the admin-only per-person Activity log on the People card.
//
// One row shape serves every source, newest-first by default, so the table
// (zebra, Issues-table style, sortable header, per-column filter) does not care
// where a row came from:
//   at     RFC3339 time of the event
//   kind   a stable key (act_as_started, act_as_ended, invited, role_changed,
//          removed, sign_in, sign_out, session_expiry, …); label is
//          activity.kinds.<kind>
//   detail free text already safe to show (a role, an end reason, a sign-in
//          method, an outcome) — never a token, password or third-party email
//   actor  the HUM-* who caused it (the admin for act-as / membership), '' when
//          it is the person's own action (a sign-in)
//   ip     the /24-masked client IP for auth events, '' otherwise
//
// Slice 1 fills it from the act-as trail (GET /v1/audit/clones). Slices 2 and 3
// add membership and auth events into the same shape.

/**
 * @typedef {{ at: string, kind: string, detail: string, actor: string, ip: string }} ActivityRow
 */

/** The kinds a filter dropdown offers, in a stable order (label: activity.kinds.<k>). */
export const ACTIVITY_KINDS = Object.freeze([
  'act_as_started', 'act_as_ended',
  'invited', 'invite_accepted', 'role_changed', 'removed',
  'sign_in', 'sign_out', 'session_expiry',
])

/**
 * The act-as clone trail for one person, as activity rows. Each clone is a
 * "started" event and, when it has ended, a "stopped" event. Rows not for this
 * person (target_hum) are dropped.
 * @param {Array<{ target_hum?: string, created_by?: string, role?: string,
 *   created_at?: string, ended_at?: string | null, end_reason?: string }>} clones
 * @param {string} targetHum
 * @returns {ActivityRow[]} newest-first
 */
export function cloneActivityRows(clones, targetHum) {
  const target = String(targetHum || '')
  /** @type {ActivityRow[]} */
  const rows = []
  for (const c of Array.isArray(clones) ? clones : []) {
    if (!c || String(c.target_hum || '') !== target) continue
    const actor = String(c.created_by || '')
    if (c.created_at) rows.push({ at: String(c.created_at), kind: 'act_as_started', detail: String(c.role || ''), actor, ip: '' })
    if (c.ended_at) rows.push({ at: String(c.ended_at), kind: 'act_as_ended', detail: String(c.end_reason || ''), actor, ip: '' })
  }
  return sortActivity(rows, 'at', 'desc')
}

/**
 * The hub's per-member audit rows (GET /v1/members/{id}/activity) as activity
 * rows: membership events (role change, removal) and auth events (sign-in with
 * method, sign-out, session expiry). The hub already shaped them; this just
 * renames `by` -> actor and drops anything without a time.
 * @param {Array<{ at?: string, kind?: string, detail?: string, by?: string, ip?: string }>} events
 * @returns {ActivityRow[]}
 */
export function memberActivityRows(events) {
  /** @type {ActivityRow[]} */
  const out = []
  for (const e of Array.isArray(events) ? events : []) {
    if (!e || !e.at || !e.kind) continue
    out.push({ at: String(e.at), kind: String(e.kind), detail: String(e.detail || ''), actor: String(e.by || ''), ip: String(e.ip || '') })
  }
  return out
}

/**
 * A copy sorted by a column ('at' or 'kind'), ascending or descending. String
 * compare (RFC3339 sorts correctly as text); ties keep input order (stable).
 * @param {ActivityRow[]} rows
 * @param {'at' | 'kind' | 'actor' | 'detail'} col
 * @param {'asc' | 'desc'} dir
 * @returns {ActivityRow[]}
 */
export function sortActivity(rows, col, dir) {
  const list = Array.isArray(rows) ? rows.map((r, i) => [r, i]) : []
  const m = dir === 'asc' ? 1 : -1
  list.sort((a, b) => {
    const av = String(a[0][col] ?? '')
    const bv = String(b[0][col] ?? '')
    if (av < bv) return -m
    if (av > bv) return m
    return a[1] - b[1]
  })
  return list.map((x) => x[0])
}

/**
 * Rows whose kind matches (empty keeps all) — the per-column "Event" filter.
 * @param {ActivityRow[]} rows
 * @param {string} kind
 * @returns {ActivityRow[]}
 */
export function filterActivity(rows, kind) {
  const k = String(kind || '')
  const list = Array.isArray(rows) ? rows : []
  return k ? list.filter((r) => r && r.kind === k) : list
}
