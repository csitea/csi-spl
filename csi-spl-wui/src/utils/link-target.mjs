/**
 * Where a link in a message or a description opens (SPL-951).
 *
 * Internal: a relative URL, or an absolute http(s) URL whose origin is the
 * page origin exactly. Same tab, no target. followSameTabLink cancels the
 * browser navigation and hands the path to the router, so the SPA does not
 * reload. A query-only href ("?topic=") resolves against the current page.
 * Also internal (SPL-959): a tenant host of THIS env, https://<tenant>.<fqdn>
 * or the apex https://<fqdn> (setLinkSite, tenant-host-core.mjs isTenantHostOf).
 * Same tab; another host is a full page load, the browser's own navigation.
 * A product host reached the wrong way is normalised before the rule decides
 * (SPL-951 regression, CLE-001 topic e802196b): a leading "www." label is
 * dropped ("www" is a reserved tenant label, and www has no DNS yet) and an
 * http link is forced to https, so www.<fqdn>, www.<tenant>.<fqdn> and an
 * http link to a product host are internal AND their href is REWRITTEN to the
 * canonical https apex/tenant origin, so they load even before any www record.
 * External: every other http(s) URL, and mailto. A new tab, with
 * rel="noopener noreferrer nofollow". The other env is external: the dev
 * origin viewed from production differs, and the reverse, and "dev" is no
 * tenant label.
 *
 * Not a link: javascript:, data:, vbscript:, file:, any other scheme,
 * protocol-relative (//host), a backslash (the parser can turn "/\\evil"
 * into another host), a control character, or a relative URL that resolves
 * off the base origin.
 *
 * classifyHref, linkOpen, sameTabPath and followSameTabLink are pure.
 * pageOrigin is window.location.origin at render time. Omit it and every
 * absolute URL is external: a renderer that does not know the page must not
 * call a foreign host internal. A relative URL stays internal.
 *
 * A phone tap on a link inside a card often produces no click. The card is
 * user-select:none (the body opts back into text) and the anchor is
 * draggable, so the browser keeps pointerup and drops the click. Desktop
 * clicks still go through followSameTabLink. messageLinkPointerUp opens the
 * link from that pointerup. The navigation re-renders the anchor before the
 * click, so messageLinkClick matches that open by href and swallows the
 * click. One tap navigates once. A mouse click is unchanged. The href is
 * what matters: a link to an archived topic opens the same way.
 */

import { isTenantHostOf } from './tenant-host-core.mjs'

export const NEW_TAB_REL = 'noopener noreferrer nofollow'

/* SPL-959: the env's apex (NUXT_PUBLIC_SITE_URL) once tenant hosts are on;
   set once at start by plugins/tenant-host.client.ts. '' = off. */
let linkSite = ''
export function setLinkSite(siteUrl) {
  linkSite = String(siteUrl || '')
}

/* A base with a path, so "?topic=" and "#id" stay relative and a backslash
   that escapes the host fails the origin check. Not a real site. */
const DUMMY_PAGE = 'https://link-target.invalid/page'
const SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:/

/* A relative href is a path, a query or a hash — not a scheme hiding behind
   percent-encoding ("%6Aavascript:" decodes to "javascript:"). A colon in the
   first path segment is a scheme. Decoding is repeated so "%256A" is caught. */
function safeRelative(s) {
  if (!/^(?:\/(?!\/)|\?|#|\.\/|\.\.\/|[A-Za-z0-9._~-])/.test(s)) return false
  const head = s.split(/[/?#]/, 1)[0]
  if (head.includes(':')) return false
  let cur = s
  for (let i = 0; i < 3; i++) {
    let next
    try { next = decodeURIComponent(cur) } catch { return false }
    if (/[\u0000-\u001F\u007F]/.test(next)) return false
    const t = next.trim()
    if (SCHEME_RE.test(t) && !/^https?:\/\//i.test(t)) return false
    if (next === cur) return true
    cur = next
  }
  return true
}

function originOf(pageOrigin) {
  const s = String(pageOrigin ?? '').trim()
  if (!s) return ''
  try {
    return new URL(s).origin
  } catch {
    return ''
  }
}

/**
 * The canonical https product URL a link points at, or null when the link is
 * not one of THIS env's hosts (SPL-951 regression, CLE-001 topic e802196b).
 * A leading "www." label is dropped and the scheme is forced to https, then
 * isTenantHostOf decides: www.<fqdn>, www.<tenant>.<fqdn>, http://<fqdn> and
 * http://<tenant>.<fqdn> all resolve to the canonical https apex/tenant URL.
 * A port is left in place, so isTenantHostOf rejects it (a different port is a
 * different service, not the site). A non-product host returns null and the
 * caller keeps the URL exactly as written.
 */
function productHttpsUrl(u, site) {
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null
  let canon
  try {
    canon = new URL(u.href)
  } catch {
    return null
  }
  canon.protocol = 'https:'
  canon.hostname = u.hostname.toLowerCase().replace(/^www\./, '')
  return isTenantHostOf(canon.href, site) ? canon : null
}

/**
 * null when href must not be an anchor. Otherwise the canonical href
 * (absolute http(s)/mailto as URL.href, relative as the author wrote it)
 * and whether a plain click stays on this page.
 */
export function classifyHref(raw, pageOrigin, site = linkSite) {
  const s = String(raw ?? '').trim()
  if (!s) return null
  if (/[\u0000-\u001F\u007F]/.test(s) || s.includes('\\') || s.startsWith('//')) return null

  const scheme = SCHEME_RE.exec(s)
  if (scheme) {
    const proto = scheme[0].toLowerCase()
    if (proto !== 'http:' && proto !== 'https:' && proto !== 'mailto:') return null
    /* "https:example.com" is not an absolute URL; the parser would treat it
       as a path. Only http:// and https:// are absolute. */
    if (proto !== 'mailto:' && !/^https?:\/\//i.test(s)) return null
    let u
    try {
      u = new URL(s)
    } catch {
      return null
    }
    if (u.protocol === 'mailto:') return { href: u.href, internal: false }
    if ((u.protocol !== 'http:' && u.protocol !== 'https:') || !u.hostname) return null
    const origin = originOf(pageOrigin)
    if (origin !== '' && u.origin === origin) return { href: u.href, internal: true }
    if (origin !== '' && isTenantHostOf(origin, site)) {
      const canon = productHttpsUrl(u, site)
      if (canon) return { href: canon.href, internal: true }
    }
    return { href: u.href, internal: false }
  }

  if (!safeRelative(s)) return null
  let u
  try {
    u = new URL(s, DUMMY_PAGE)
  } catch {
    return null
  }
  if (u.origin !== new URL(DUMMY_PAGE).origin || u.protocol !== 'https:') return null
  return { href: s, internal: true }
}

/** Target and rel for an anchor, or null when the href is not a link. */
export function linkOpen(href, pageOrigin, site = linkSite) {
  const c = classifyHref(href, pageOrigin, site)
  if (!c) return null
  if (c.internal) return { href: c.href, internal: true }
  return { href: c.href, internal: false, target: '_blank', rel: NEW_TAB_REL }
}

/**
 * Router path for an internal link, resolved against the current page URL
 * so "?topic=" stays on this path. Null for an external link, a rejected
 * href, or a resolution that leaves the page origin.
 */
export function sameTabPath(href, pageHref) {
  let page
  try {
    page = new URL(pageHref)
  } catch {
    return null
  }
  const c = classifyHref(href, page.origin)
  if (!c || !c.internal) return null
  let u
  try {
    u = new URL(c.href, pageHref)
  } catch {
    return null
  }
  if (u.origin !== page.origin || (u.protocol !== 'http:' && u.protocol !== 'https:')) return null
  return u.pathname + u.search + u.hash
}

/**
 * Plain left click on an internal link: cancel the browser navigation and
 * call navigate(path). A modified click (ctrl, cmd, shift, alt, or a
 * non-primary button) stays with the browser, which opens another tab.
 * Returns whether this call navigated.
 */
export function followSameTabLink(event, href, pageHref, navigate) {
  if (!event || event.defaultPrevented) return false
  if (event.button != null && event.button !== 0) return false
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false
  const path = sameTabPath(href, pageHref)
  if (path == null) return false
  if (typeof event.preventDefault === 'function') event.preventDefault()
  navigate(path)
  return true
}

/** A finger held longer than this is a long press, not a tap. */
export const MESSAGE_LINK_TAP_MAX_MS = 450
/** A click this soon after pointerup already opened the link is the ghost. */
const GHOST_CLICK_MS = 1000
const TAP_SLOP_PX = 10

/** @type {WeakMap<object, { x: number, y: number, id: number, t: number }>} */
const tapDown = new WeakMap()
/* href -> when pointerup opened it. Keyed by href, not the node: the route
   re-renders the anchor before the click, and a new node would miss. */
/** @type {Map<string, number>} */
const tapOpenedAt = new Map()

/* The wall clock (ms) the tap and ghost-click windows read. A module-level
   seam rather than a param: messageLinkPointerUp already takes five. */
let clock = () => Date.now()

/**
 * Test seam: pin the clock the tap windows read (MESSAGE_LINK_TAP_MAX_MS,
 * GHOST_CLICK_MS). Pass nothing to restore the real one.
 * @param {(() => number) | null} [fn]
 */
export function setLinkTapClock(fn) {
  clock = typeof fn === 'function' ? fn : () => Date.now()
}

function touchLike(event) {
  const t = event && event.pointerType
  return t === 'touch' || t === 'pen'
}

/**
 * Open an internal link through navigate, or hand an external http(s)/mailto
 * URL to openExternal. Anything classifyHref rejects opens nothing.
 * openExternal returning false means the browser blocked it: the click that
 * follows is then left to the anchor.
 *
 * @param {string} href
 * @param {string} pageHref
 * @param {(path: string) => unknown} navigate
 * @param {(url: string) => unknown} [openExternal]
 */
export function openMessageLink(href, pageHref, navigate, openExternal) {
  const path = sameTabPath(href, pageHref)
  if (path != null) {
    navigate(path)
    return true
  }
  if (typeof openExternal !== 'function') return false
  let page
  try { page = new URL(pageHref) } catch { return false }
  const c = classifyHref(href, page.origin)
  if (!c || c.internal) return false
  if (!/^https?:/i.test(c.href) && !c.href.startsWith('mailto:')) return false
  return openExternal(c.href) !== false
}

/** Remember a finger down on the anchor. A mouse down is not a tap. */
export function messageLinkPointerDown(event) {
  if (!touchLike(event) || (event && event.isPrimary === false)) return
  const el = event.currentTarget
  if (!el) return
  tapDown.set(el, { x: event.clientX, y: event.clientY, id: event.pointerId, t: clock() })
}

/** A cancelled finger (scroll, drag) is not a tap. */
export function messageLinkPointerCancel(event) {
  const el = event && event.currentTarget
  if (el) tapDown.delete(el)
}

/**
 * A stationary short touch opens the link now, while the gesture is still a
 * user activation (an external link's new tab is blocked from a later timer).
 * Returns whether it opened. A mouse pointerup does nothing.
 */
export function messageLinkPointerUp(event, href, pageHref, navigate, openExternal) {
  const el = event && event.currentTarget
  const start = el && tapDown.get(el)
  if (el) tapDown.delete(el)
  if (!el || !start || !touchLike(event)) return false
  if (start.id !== event.pointerId) return false
  if (event.button != null && event.button !== 0) return false
  if (clock() - start.t > MESSAGE_LINK_TAP_MAX_MS) return false
  if (Math.hypot(event.clientX - start.x, event.clientY - start.y) > TAP_SLOP_PX) return false
  const opened = openMessageLink(href, pageHref, navigate, openExternal)
  if (opened) tapOpenedAt.set(String(href), clock())
  return opened
}

/**
 * The click path. The click that follows a touch open is swallowed, so it
 * does not push a second history entry or open a second tab. Any other click
 * is followSameTabLink. The click never bubbles to the card.
 */
export function messageLinkClick(event, href, pageHref, navigate) {
  if (!event) return false
  if (typeof event.stopPropagation === 'function') event.stopPropagation()
  const key = String(href)
  const opened = tapOpenedAt.get(key)
  if (typeof opened === 'number' && clock() - opened < GHOST_CLICK_MS) {
    tapOpenedAt.delete(key)
    if (typeof event.preventDefault === 'function') event.preventDefault()
    return false
  }
  tapOpenedAt.delete(key)
  return followSameTabLink(event, href, pageHref, navigate)
}
