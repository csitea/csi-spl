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
 * links.
 *
 * An id quoted as text that id-links.mjs turned into a link (a bare uuid or
 * 8-hex start of a known topic / message, e.g. "topic 9f0d751c") IS an
 * internal link too, and the one the owner sees most (owner, e1f8f797
 * 3522fd83: "I have the setting, but I cannot see any previews" - agent
 * posts carry ids, not URLs). previewRefsOfBlocks reads those from the
 * rendered parts (code-blocks.mjs parseBody), whose hrefs are the same
 * ?topic=<task>[#<msg>] addresses.
 *
 * The hub answers only what the reader may read (POST /v1/view/previews);
 * anything else stays a plain link.
 *
 * A release note (/releases/<sha or vX.Y.Z>, of any env of this spool:
 * release-link.mjs) is an object too (owner, t1 a1bce52e: "it should have a
 * small preview if the data is fetched internally"). Its id is
 * `release:<ref>` (RELEASE_ID_PREFIX); the card comes from the release
 * notes API, not the previews batch (LinkPreviews.vue).
 */
import { classifyHref } from './link-target.mjs'
import { releaseRefOfPath } from './release-link.mjs'

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

/** The id prefix of a release-note ref: `release:<sha or vX.Y.Z>`. */
export const RELEASE_ID_PREFIX = 'release:'

/**
 * The object one href names, or null.
 * @param {string} href
 * @param {string} pageOrigin window.location.origin
 * @returns {string | null} the topic or message uuid, lower case, or
 *   `release:<ref>` for a release note
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
  const release = releaseRefOfPath(u.pathname)
  if (release) return RELEASE_ID_PREFIX + release
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

/**
 * The link parts of parsed body blocks (code-blocks.mjs parseBody: plain
 * links, wiki links and the id links of id-links.mjs) that name an object,
 * each once, in body order, at most `max`. A code block holds no parts.
 * @param {unknown} blocks
 * @param {string} pageOrigin
 * @param {number} [max]
 * @returns {{ id: string, href: string }[]}
 */
export function previewRefsOfBlocks(blocks, pageOrigin, max = PREVIEWS_PER_BODY) {
  const out = []
  if (!Array.isArray(blocks) || !pageOrigin) return out
  const seen = new Set()
  const take = (parts) => {
    for (const p of Array.isArray(parts) ? parts : []) {
      if (out.length >= max) return
      if (!p || p.type !== 'link' || !p.href) continue
      const id = previewTarget(String(p.href), pageOrigin)
      if (!id || seen.has(id)) continue
      seen.add(id)
      out.push({ id, href: String(p.href) })
    }
  }
  for (const b of blocks) {
    if (!b || typeof b !== 'object' || b.type === 'code') continue
    take(b.parts)
    for (const item of Array.isArray(b.items) ? b.items : []) take(item && item.parts)
    if (out.length >= max) break
  }
  return out
}

/**
 * The refs of a body: its rendered link parts first (id links included),
 * then any URL link the parts missed (a relative markdown link outside a
 * wiki region), each object once, none of `skip` (a card's own message and
 * topic), at most `max`.
 * @param {unknown} blocks parseBody(body)
 * @param {unknown} body
 * @param {string} pageOrigin
 * @param {{ skip?: Iterable<string>, max?: number }} [opts]
 */
export function bodyPreviewRefs(blocks, body, pageOrigin, opts = {}) {
  const max = Number(opts.max) > 0 ? Number(opts.max) : PREVIEWS_PER_BODY
  const skip = new Set([...(opts.skip || [])].map((s) => String(s || '').toLowerCase()).filter(Boolean))
  const out = []
  const seen = new Set()
  for (const r of [...previewRefsOfBlocks(blocks, pageOrigin, max + skip.size), ...previewRefs(body, pageOrigin, max + skip.size)]) {
    if (seen.has(r.id) || skip.has(r.id)) continue
    seen.add(r.id)
    out.push(r)
    if (out.length >= max) break
  }
  return out
}
