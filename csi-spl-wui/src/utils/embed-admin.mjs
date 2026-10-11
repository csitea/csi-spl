/**
 * The embed admin page (spec 121 T204), the WUI side of the hub's
 * /v1/tenant/embeds (T203): the rows, the origins textarea both ways, the
 * embed id check and the error -> i18n key map. The workspace owner only;
 * 404 while cnf env.hub.embed.enabled is off. Rides only with the lazy
 * /embed page, never the initial chunk. Node tests import this file.
 */

/** rdb 0169's embed_id check, the same as the hub's embedIDPattern. */
export const EMBED_ID_RE = /^[a-z0-9][a-z0-9-]{2,63}$/

/** rdb 0169's cardinality check of allowed_origins. */
export const EMBED_MAX_ORIGINS = 32

/** A GET /v1/tenant/embeds body -> rows with safe types, by embed id. */
export function embedRows(body) {
  const list = Array.isArray(body && body.embeds) ? body.embeds : []
  return list.map(embedRow).filter((r) => r.embedId).sort((a, b) => a.embedId.localeCompare(b.embedId))
}

/** One embed as the admin API shows it: never a private key. */
export function embedRow(e) {
  const o = e && typeof e === 'object' ? e : {}
  return {
    embedId: String(o.embed_id || ''),
    origins: Array.isArray(o.allowed_origins) ? o.allowed_origins.map(String) : [],
    enabled: o.enabled === true,
    keyId: String(o.key_id || ''),
    keyAlg: String(o.key_alg || ''),
  }
}

/** The textarea's text -> the allowed_origins list: one per line, trimmed, blanks and repeats dropped. */
export function originsFromText(text) {
  const out = []
  for (const line of String(text || '').split(/\r?\n/)) {
    const o = line.trim()
    if (o && !out.includes(o)) out.push(o)
  }
  return out
}

/** The allowed_origins list -> the textarea's text. */
export function originsText(origins) {
  return Array.isArray(origins) ? origins.join('\n') : ''
}

/** True when `id` passes the hub's embed id check. */
export function embedIdValid(id) {
  return EMBED_ID_RE.test(String(id || ''))
}

/**
 * A refused call -> the i18n key the page shows (the hub's detail is shown
 * beside a bad origin). 403 = not the workspace owner, 404 on the list =
 * the embed is off on this hub.
 */
export function embedErrorKey(err, { listing = false } = {}) {
  const e = err && typeof err === 'object' ? err : {}
  if (e.status === 403) return 'embed.not_owner'
  if (e.status === 404 && listing) return 'embed.disabled'
  if (e.token === 'embed_exists') return 'embed.exists'
  if (e.token === 'bad_origin') return 'embed.bad_origin'
  if (e.token === 'bad_embed') return 'embed.bad_id'
  return listing ? 'embed.fetch_failed' : 'embed.save_failed'
}
