/**
 * Spec 155 2.3 (B7, SPL-4330): a note's links. A link is a typed ref, never a
 * stored page address: { kind, workspace_id, ref, day, label }.
 *
 *   msg / topic   uuid           <origin>/m/<id>, <origin>/t/<id>
 *   issue         key, SPL-12    <origin>/issues?issue=<KEY>
 *   event         id + day       <origin>/calendar?d=<day>&event=<id>
 *   doc           path           <origin>/docs/<path>
 *   channel       name           <origin>/channel/<name>
 *   url           http(s) addr   that address, new tab, rel="noopener noreferrer"
 *
 * <origin> is tenantOrigin(workspace) (tenant-host.mjs): a link into another
 * of the person's workspaces opens on that workspace's host, where that
 * page's own access check applies. With tenant hosts off there is one host:
 * a link of this workspace opens here, one of another stays text.
 *
 * Pure: the page's workspace, the env's apex (siteUrl, '' when tenant hosts
 * are off) and the apex tenant are arguments. No domain literal.
 */
import { isTenantHostOf, pageTenant } from './tenant-host-core.mjs'
import { tenantOrigin } from './tenant-host.mjs'
import { isIssueKey } from './issue-key-links.mjs'
import { validDocsPath } from './docs.mjs'

/* spec 155 2.4 / section 4: ref <= 2 048 characters */
export const NOTE_LINK_REF_MAX = 2048
export const NOTE_LINK_KINDS = Object.freeze(['msg', 'topic', 'issue', 'event', 'doc', 'channel', 'url'])

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
const TYPED_RE = new RegExp(`^(msg|topic):(${UUID})$`, 'i')
const UUID_RE = new RegExp(`^${UUID}$`, 'i')
const KEY_RE = /^[A-Z][A-Z0-9]{0,9}-[1-9][0-9]{0,8}$/
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/
const CHANNEL_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/
const EVENT_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/
/* a locale prefix only when the next segment is one of the object routes */
const LOCALE_RE = /^[a-z]{2}(?:-[a-z]{2,4})?$/i
const ROUTES = new Set(['t', 'm', 'issues', 'calendar', 'docs', 'channel'])

/**
 * @typedef {{ tenant?: string, siteUrl?: string, apexTenant?: string, pageOrigin?: string, issuePrefix?: string }} NoteLinkCtx
 * @typedef {{ kind: string, workspace_id?: string, ref: string, day?: string, label?: string, left?: boolean }} NoteLinkRef
 */

function dec(raw) {
  try {
    return decodeURIComponent(String(raw || ''))
  } catch {
    return ''
  }
}

/** The workspace an http(s) URL of this app belongs to, '' when it is not one. */
function urlWorkspace(u, ctx) {
  const site = String(ctx.siteUrl || '')
  if (site) return isTenantHostOf(u.href, site) ? pageTenant(u.hostname, site, String(ctx.apexTenant || '')) : ''
  /* tenant hosts off: only this page's own origin is this app */
  return ctx.pageOrigin && u.origin === ctx.pageOrigin ? String(ctx.tenant || '') : ''
}

/** /fi/t/x -> ['t', 'x']: the path's segments without a locale prefix. */
function segmentsOf(pathname) {
  const segs = String(pathname || '').split('/').filter(Boolean)
  if (segs.length >= 2 && LOCALE_RE.test(segs[0]) && ROUTES.has(segs[1].toLowerCase())) segs.shift()
  return segs
}

/** The typed ref of /issues?issue= and /calendar?d=&event=, or null. */
function queryRef(head, u) {
  if (head === 'issues') {
    const key = (u.searchParams.get('issue') || '').trim()
    return KEY_RE.test(key) ? { kind: 'issue', ref: key } : null
  }
  const ev = (u.searchParams.get('event') || '').trim()
  const day = (u.searchParams.get('d') || '').trim()
  return EVENT_RE.test(ev) && DAY_RE.test(day) ? { kind: 'event', ref: ev, day } : null
}

/** The typed ref one Spool address names, or null (it then stays a url link). */
function appRef(u) {
  const segs = segmentsOf(u.pathname)
  const head = (segs[0] || '').toLowerCase()
  const one = segs.length === 2 ? dec(segs[1]) : ''
  if ((head === 't' || head === 'm') && UUID_RE.test(one)) return { kind: head === 't' ? 'topic' : 'msg', ref: one.toLowerCase() }
  if (head === 'channel' && CHANNEL_RE.test(one)) return { kind: 'channel', ref: one }
  if ((head === 'issues' || head === 'calendar') && segs.length === 1) return queryRef(head, u)
  if (head === 'docs' && segs.length >= 2) {
    const path = segs.slice(1).map(dec).join('/')
    return validDocsPath(path) ? { kind: 'doc', ref: path } : null
  }
  return null
}

/** An http(s) address: a typed link on a workspace host of this app, else a url link. */
function parseAddress(text, ctx) {
  let u
  try {
    u = new URL(text)
  } catch {
    return null
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null
  if (u.username || u.password) return null
  const ws = urlWorkspace(u, ctx)
  const ref = ws ? appRef(u) : null
  if (ref) return { ...ref, workspace_id: ws }
  return { kind: 'url', ref: u.href }
}

/**
 * What a pasted text is as a note link (spec 155 2.3, way 2), or why not:
 *   msg:<uuid> / topic:<uuid>            that object in this workspace
 *   <PREFIX>-<n>                         an issue of this workspace
 *   a Spool address on a workspace host  the typed link, its workspace from the host
 *   any other http(s):// address         a url link
 * Anything else is { error: 'not_a_link' }; a typed ref with no workspace to
 * put it in is { error: 'no_workspace' }.
 * @param {unknown} text
 * @param {NoteLinkCtx} [ctx]
 * @returns {{ link: NoteLinkRef } | { error: string }}
 */
export function parseNoteLink(text, ctx = {}) {
  const s = String(text ?? '').trim()
  if (!s || s.length > NOTE_LINK_REF_MAX || /\s/.test(s)) return { error: 'not_a_link' }
  const tenant = String(ctx.tenant || '')
  const typed = TYPED_RE.exec(s)
  const key = isIssueKey(ctx.issuePrefix, s.toUpperCase()) ? s.toUpperCase() : ''
  if (typed || key) {
    if (!tenant) return { error: 'no_workspace' }
    return { link: typed ? { kind: typed[1].toLowerCase(), workspace_id: tenant, ref: typed[2].toLowerCase() } : { kind: 'issue', workspace_id: tenant, ref: key } }
  }
  if (!/^https?:\/\//i.test(s)) return { error: 'not_a_link' }
  const link = parseAddress(s, ctx)
  if (!link || link.ref.length > NOTE_LINK_REF_MAX) return { error: 'not_a_link' }
  return { link }
}

/** The in-app path a typed link opens, '' for a url link or a bad ref. */
export function noteLinkPath(link) {
  const ref = String(link?.ref || '')
  const e = encodeURIComponent
  switch (link?.kind) {
    case 'msg': return UUID_RE.test(ref) ? `/m/${ref}` : ''
    case 'topic': return UUID_RE.test(ref) ? `/t/${ref}` : ''
    case 'issue': return ref ? `/issues?issue=${e(ref)}` : ''
    case 'event': return ref && DAY_RE.test(String(link.day || '')) ? `/calendar?d=${e(String(link.day))}&event=${e(ref)}` : ''
    case 'doc': return validDocsPath(ref) ? '/docs/' + ref.split('/').map(e).join('/') : ''
    case 'channel': return ref ? `/channel/${e(ref)}` : ''
    default: return ''
  }
}

/** The host a typed link opens on: its workspace's, '' when it cannot open. */
function originOf(ws, ctx) {
  const site = String(ctx.siteUrl || '')
  if (site) return tenantOrigin(ws, site, String(ctx.apexTenant || ''))
  /* tenant hosts off: one host, the page's own workspace only */
  return ws && ws === String(ctx.tenant || '') ? String(ctx.pageOrigin || '') : ''
}

/**
 * Where a link opens (spec 155 2.3): `href` ('' = shown as text), `external`
 * (a url link: new tab), `here` (it opens on this page's host, so the router
 * may take `path`). `typed(kind, ref)` is the WUI's own row lookup for msg
 * and topic (id-links.mjs resolveTyped), tried first; `pathFor` adds the
 * locale prefix.
 * @param {NoteLinkRef} link
 * @param {NoteLinkCtx & { pathFor?: (p: string) => string, typed?: (kind: string, ref: string) => { href: string } | null }} [ctx]
 * @returns {{ href: string, external: boolean, here: boolean, path: string }}
 */
export function noteLinkHref(link, ctx = {}) {
  const none = { href: '', external: false, here: false, path: '' }
  if (!link || typeof link !== 'object') return none
  if (link.kind === 'url') {
    const ref = String(link.ref || '')
    return /^https?:\/\//i.test(ref) ? { href: ref, external: true, here: false, path: '' } : none
  }
  const raw = noteLinkPath(link)
  const origin = raw ? originOf(String(link.workspace_id || ''), ctx) : ''
  if (!origin) return none
  const here = origin === String(ctx.pageOrigin || '')
  const hit = (link.kind === 'msg' || link.kind === 'topic') && typeof ctx.typed === 'function' ? ctx.typed(link.kind, String(link.ref)) : null
  if (hit && hit.href && hit.href.startsWith(origin + '/')) return { href: hit.href, external: false, here, path: hit.href.slice(origin.length) }
  const path = typeof ctx.pathFor === 'function' ? String(ctx.pathFor(raw) || raw) : raw
  return { href: origin + path, external: false, here, path }
}

/**
 * The anchor attributes of a link, null when it cannot open: a url link
 * opens in a new tab with rel="noopener noreferrer" (C25); an app link opens
 * in this tab.
 * @param {NoteLinkRef} link
 * @param {Parameters<typeof noteLinkHref>[1]} [ctx]
 */
export function noteLinkAnchor(link, ctx = {}) {
  const to = noteLinkHref(link, ctx)
  if (!to.href) return null
  return to.external ? { href: to.href, target: '_blank', rel: 'noopener noreferrer' } : { href: to.href }
}

/** What the note shows for a link: its label, else the ref in a short form. */
export function noteLinkText(link) {
  const label = String(link?.label || '').trim()
  if (label) return label
  const ref = String(link?.ref || '')
  if (link?.kind === 'msg' || link?.kind === 'topic') return ref.slice(0, 8)
  if (link?.kind === 'event') return String(link.day || '') || ref
  return ref
}
