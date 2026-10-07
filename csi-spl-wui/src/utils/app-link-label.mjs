/**
 * Short label for a URL of this app (owner, t1 b698941b).
 *
 * A bare address of a known route renders as `topic: 41261a3f`,
 * `channel: spool-hub`, `message: ab12cd34`, and the same for the other
 * object routes. A different workspace of this env is a segment in front:
 * `workspace: csitea · topic: 41261a3f`. The anchor keeps the full URL as
 * its href and its title. An external URL, and an app URL whose path is
 * not one of those routes, stays as written (this function returns null).
 *
 * The label is a list of segments, in order: instance, workspace, type.
 * `instance` is reserved for a future cloud prefix and is never produced.
 * formatAppLinkSegments skips it, so a later producer can prepend one
 * without a second renderer.
 *
 * Pure. The page, the apex (siteUrl) and the apex tenant are arguments.
 * No domain literal: the caller passes the runtime site.
 */
import { classifyHref } from './link-target.mjs'
import { isTenantHostOf, pageTenant } from './tenant-host-core.mjs'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
/* a locale prefix only when the next segment is a real route, so /m/<id> stays a message */
const TOP = new Set(['channel', 'dm', 't', 'm', 'agents', 'boxes', 'people', 'releases', 'help', 'docs', 'issues'])
const ONE = {
  agents: 'agent',
  boxes: 'box',
  people: 'person',
  releases: 'release',
  help: 'help',
}

/**
 * @typedef {'instance' | 'workspace' | 'type'} AppLinkSegmentKind
 * @typedef {{ kind: AppLinkSegmentKind, value: string, id?: string }} AppLinkSegment
 * @typedef {{ segments: AppLinkSegment[], text: string, title: string }} AppLinkLabel
 */

/** The visible text is the address itself, not an author-written label. */
export function linkTextIsAddress(text) {
  return /^(?:https?:\/\/|www\.)\S+$/i.test(String(text ?? '').trim())
}

/**
 * Render segments. An `instance` segment is kept in the list for later and
 * is not written. Anything else unknown is skipped the same way.
 * @param {AppLinkSegment[]} segments
 */
export function formatAppLinkSegments(segments) {
  const parts = []
  for (const s of segments || []) {
    if (!s || s.kind === 'instance') continue
    if (s.kind === 'workspace' && s.value) parts.push('workspace: ' + s.value)
    else if (s.kind === 'type' && s.value && s.id) parts.push(s.value + ': ' + s.id)
  }
  return parts.join(' \u00b7 ')
}

/**
 * The runtime public config, as the label sees it. Tenant hosts off means
 * no other workspace: only this page's own origin is this app.
 * @param {string} pageHref
 * @param {{ tenantHosts?: unknown, siteUrl?: unknown, tenant?: unknown }} [pub]
 */
export function appLinkLabelContext(pageHref, pub) {
  const p = pub && typeof pub === 'object' ? pub : {}
  const hostsOn = String(p.tenantHosts || '0') === '1'
  return {
    pageHref: String(pageHref || ''),
    siteUrl: hostsOn ? String(p.siteUrl || '') : '',
    apexTenant: String(p.tenant || ''),
  }
}

function dec(raw) {
  try {
    return decodeURIComponent(String(raw || ''))
  } catch {
    return ''
  }
}

function cleanId(raw, slash) {
  const s = dec(raw).trim()
  if (!s || s.length > 120 || s.includes('..')) return ''
  if (/[\u0000-\u001f\u007f]/.test(s)) return ''
  if (slash ? /\s/.test(s) : /[\s/]/.test(s)) return ''
  return s
}

function shortUuid(uuid) {
  return String(uuid).slice(0, 8).toLowerCase()
}

/** Drop a locale prefix (/fi/channel/x -> /channel/x). */
function routePath(pathname) {
  const parts = String(pathname || '').split('/').filter(Boolean)
  if (parts.length >= 2 && /^[a-z]{2}(?:-[a-z]{2})?$/i.test(parts[0]) && TOP.has(parts[1].toLowerCase())) {
    parts.shift()
  }
  return '/' + parts.join('/')
}

/**
 * The object a resolved app URL names, or null when the route is not one.
 * A topic query beats the channel it is opened in. A message hash beats
 * that topic. /m/<uuid> is the message itself.
 * @param {URL} u
 */
function objectOf(u) {
  const rest = routePath(u.pathname).replace(/\/+$/, '') || '/'
  const hash = dec(u.hash.replace(/^#/, ''))
  const topic = u.searchParams.get('topic') || ''
  const issue = (u.searchParams.get('issue') || '').trim()
  const msgPath = new RegExp(`^/m/(${UUID_RE.source.slice(1, -1)})$`, 'i').exec(rest)
  const topicPath = new RegExp(`^/t/(${UUID_RE.source.slice(1, -1)})$`, 'i').exec(rest)
  const channel = /^\/channel\/([^/]+)$/i.exec(rest)
  const dm = /^\/dm\/([^/]+)$/i.exec(rest)
  const onThread = Boolean(msgPath || topicPath || channel || dm || UUID_RE.test(topic))

  if (msgPath) return { type: 'message', id: shortUuid(msgPath[1]) }
  if (onThread && UUID_RE.test(hash)) return { type: 'message', id: shortUuid(hash) }
  if (UUID_RE.test(topic)) return { type: 'topic', id: shortUuid(topic) }
  if (topicPath) return { type: 'topic', id: shortUuid(topicPath[1]) }
  if (channel) {
    const name = cleanId(channel[1], false).replace(/^#/, '')
    return name ? { type: 'channel', id: name } : null
  }
  if (dm) {
    const peer = cleanId(dm[1], false)
    return peer ? { type: 'dm', id: peer } : null
  }
  if (/^\/issues$/i.test(rest)) {
    const key = cleanId(issue, false)
    return key ? { type: 'issue', id: key } : null
  }
  const one = /^\/(agents|boxes|people|releases|help)\/([^/]+)$/i.exec(rest)
  if (one) {
    const id = cleanId(one[2], false)
    const type = ONE[one[1].toLowerCase()]
    /* a release sha reads as 8 hex, like a topic; v<X.Y.Z> stays whole */
    const shown = type === 'release' && /^[0-9a-f]{9,40}$/i.test(id) ? id.slice(0, 8).toLowerCase() : id
    return id && type ? { type, id: shown } : null
  }
  const docs = /^\/docs\/(.+)$/i.exec(rest)
  if (docs) {
    const id = cleanId(docs[1], true).replace(/\/+$/, '')
    return id ? { type: 'doc', id } : null
  }
  return null
}

function workspaceName(linkUrl, pageUrl, site, apex) {
  if (!site || linkUrl.origin === pageUrl.origin) return ''
  if (!isTenantHostOf(linkUrl.href, site) || !isTenantHostOf(pageUrl.href, site)) return ''
  const linkT = pageTenant(linkUrl.hostname, site, apex)
  const pageT = pageTenant(pageUrl.hostname, site, apex)
  if (!linkT || linkT === pageT) return ''
  return linkT
}

/**
 * The short label for an app URL, or null when the text should stay.
 * @param {string} href
 * @param {{ pageHref: string, siteUrl?: string, apexTenant?: string }} ctx
 * @returns {AppLinkLabel | null}
 */
export function appLinkLabel(href, ctx) {
  const pageHref = String(ctx && ctx.pageHref || '')
  let page
  try {
    page = new URL(pageHref)
  } catch {
    return null
  }
  const site = String(ctx && ctx.siteUrl || '')
  const apex = String(ctx && ctx.apexTenant || '')
  const c = classifyHref(href, page.origin, site)
  if (!c || !c.internal) return null
  let u
  try {
    u = new URL(c.href, pageHref)
  } catch {
    return null
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null
  if (u.origin !== page.origin && (!site || !isTenantHostOf(u.href, site))) return null
  const obj = objectOf(u)
  if (!obj) return null
  /** @type {AppLinkSegment[]} */
  const segments = []
  const ws = workspaceName(u, page, site, apex)
  if (ws) segments.push({ kind: 'workspace', value: ws })
  segments.push({ kind: 'type', value: obj.type, id: obj.id })
  const text = formatAppLinkSegments(segments)
  if (!text) return null
  return { segments, text, title: u.href }
}
