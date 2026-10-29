/**
 * The personal event log's rows (pages/monitoring/events/index.vue), read
 * from the body of GET /api/v1/auth/events. Pure, so the unit suite can test
 * it. Spec 162 B1 (E1): the request (method, origin, path) and the code and
 * name the hub answers are kept, not dropped.
 */

/**
 * @typedef {{
 *   id: number,
 *   error_id: string,
 *   at: string | null,
 *   received_at: string,
 *   source: string,
 *   method: string,
 *   origin: string,
 *   path: string,
 *   status: number,
 *   code: string,
 *   name: string,
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
      method: String(o.method || ''),
      origin: String(o.origin || ''),
      path: String(o.path || ''),
      status: Number(o.status) || 0,
      code: String(o.code || ''),
      name: String(o.name || ''),
      message: String(o.message || ''),
      route: String(o.route || ''),
    })
  }
  return out
}
