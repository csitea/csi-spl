/**
 * Internal link previews (owner, prd t1 topic e1f8f797): "each internal link
 * to an object ... topic, msg etc. if the user has a setting for it - it
 * should present as small slack like 3 lines excerpt of what it was all
 * about .. the first 100 chars of the title". And: "the users should be able
 * to turn this off, from their individual settings".
 *
 * This module is what a message body needs on the first paint: which links
 * of the body name a topic or a message of THIS workspace, and whether the
 * reader's own `link_previews` setting is on. The cards, the hub call and
 * its cache load with the lazy LinkPreviews.vue (link-preview-lookup.mjs).
 *
 * A link names an object when it is internal (link-target.mjs classifyHref)
 * AND resolves to the page's own origin exactly: another tenant host is
 * another workspace, never previewed. Its address is one of
 *   /t/<task>              a topic         /t/<task>#<msg>   that message
 *   /m/<msg>               a message       <any>?topic=<task>[#<msg>]
 * with or without a locale prefix (/fi/t/<task>). Links inside code are not
 * links; an id quoted as text (id-links.mjs) is not a link either.
 *
 * The hub answers only what the reader may read (POST /v1/view/previews);
 * anything else stays a plain link.
 */
import { classifyHref } from './link-target.mjs'

/** The most cards one message shows. */
export const PREVIEWS_PER_BODY = 3

/** Settings -> Behaviour "Link previews" (rdb 0120): on first = the default. */
export const LINK_PREVIEWS = /** @type {const} */ (['on', 'off'])

/**
 * The `link_previews` session claim as one of LINK_PREVIEWS: null, unknown
 * or never picked is 'on'.
 * @param {unknown} raw
 * @returns {'on' | 'off'}
 */
export function parseLinkPreviews(raw) {
  return raw === 'off' ? 'off' : 'on'
}

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
const UUID_RE = new RegExp(`^${UUID}$`)
const PATH_RE = new RegExp(`^(?:/[a-z]{2}(?:-[a-z]{2})?)?/(t|m)/(${UUID})/?$`, 'i')
/* code first, so a link inside it is skipped; then markdown links and bare urls */
const SCAN_RE = /```[\s\S]*?(?:```|$)|`[^`\n]+`|\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"\n]*")?\s*\)|(https?:\/\/[^\s<>()[\]]+)/gi
const TRAIL_RE = /[.,;:!?'"*_]+$/

/**
 * The object one href names, or null.
 * @param {string} href
 * @param {string} pageOrigin window.location.origin
 * @returns {string | null} the topic or message uuid, lower case
 */
export function previewTarget(href, pageOrigin) {
  const origin = String(pageOrigin || '')
  if (!origin) return null
  const c = classifyHref(href, origin)
  if (!c || !c.internal) return null
  let u
  try {
    u = new URL(c.href, origin + '/')
  } catch {
    return null
  }
  if (u.origin !== origin) return null
  const hash = decodeURIComponent(u.hash.slice(1))
  const msg = UUID_RE.test(hash) ? hash : ''
  const m = PATH_RE.exec(u.pathname)
  if (m) return (m[1].toLowerCase() === 't' && msg ? msg : m[2]).toLowerCase()
  const topic = u.searchParams.get('topic') || ''
  if (UUID_RE.test(topic)) return (msg || topic).toLowerCase()
  return null
}

/**
 * The links of a body that name an object, each once, in body order, at
 * most `max`.
 * @param {unknown} body
 * @param {string} pageOrigin
 * @param {number} [max]
 * @returns {{ id: string, href: string }[]}
 */
export function previewRefs(body, pageOrigin, max = PREVIEWS_PER_BODY) {
  const s = String(body ?? '')
  if (!s.includes('/') || !pageOrigin) return []
  const out = []
  const seen = new Set()
  SCAN_RE.lastIndex = 0
  for (const m of s.matchAll(SCAN_RE)) {
    const raw = m[1] || (m[2] ? m[2].replace(TRAIL_RE, '') : '')
    if (!raw) continue
    const id = previewTarget(raw, pageOrigin)
    if (!id || seen.has(id)) continue
    seen.add(id)
    out.push({ id, href: raw })
    if (out.length >= max) break
  }
  return out
}
