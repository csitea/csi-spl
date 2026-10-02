/**
 * The personal event log's rows (pages/events.vue), read from the body of
 * GET /api/v1/auth/events. Pure, so the unit suite can test it.
 */

/**
 * @typedef {{
 *   id: number,
 *   error_id: string,
 *   at: string | null,
 *   received_at: string,
 *   source: string,
 *   status: number,
 *   message: string,
 *   route: string,
 * }} EventRow
 */

/**
 * The `events` list of a response body as rows. Anything that is not an
 * object, or has no positive finite id, is skipped; every field is coerced.
 * @param {unknown} data
 * @returns {EventRow[]}
 */
export function eventRowsOf(data) {
  const list = data && typeof data === 'object' ? /** @type {{ events?: unknown }} */ (data).events : null
  if (!Array.isArray(list)) return []
  /** @type {EventRow[]} */
  const out = []
  for (const x of list) {
    if (!x || typeof x !== 'object') continue
    const o = /** @type {Record<string, unknown>} */ (x)
    const id = Number(o.id)
    if (!Number.isFinite(id) || id <= 0) continue
    out.push({
      id,
      error_id: String(o.error_id || ''),
      at: o.at == null ? null : String(o.at),
      received_at: String(o.received_at || ''),
      source: String(o.source || ''),
      status: Number(o.status) || 0,
      message: String(o.message || ''),
      route: String(o.route || ''),
    })
  }
  return out
}
