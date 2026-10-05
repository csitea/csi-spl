/**
 * Deterministic default avatars (SPEC-spool-avatars.md §2, 013 US4).
 * Agents (CLE-*, GRK-*, AGY-*, any non-HUM agent id) → a wild, funny robot;
 * humans (HUM-*) → a symmetric identicon. Same id(@box) → same picture.
 * Generated inline SVG: no image files in the tree, no third-party CDN, and no
 * user text inside the SVG (only numbers and colours), so nothing to escape.
 */

import { idPrefix } from './agent-id.mjs'

/** FNV-1a 32-bit, then a small xorshift stream for independent picks. */
export function hashSeed(s) {
  let h = 0x811c9dc5
  for (const ch of String(s || '')) {
    h ^= ch.codePointAt(0)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h >>> 0
}

function stream(seed) {
  let x = seed || 0x9e3779b9
  return () => {
    x ^= x << 13; x >>>= 0
    x ^= x >>> 17
    x ^= x << 5; x >>>= 0
    return x
  }
}

/* one hue per kind: the spec 061 letter and its legacy prefix share it */
const PREFIX_HUE = { c: 175, CLE: 175, g: 28, GRK: 28, a: 275, AGY: 275 }

/** A human: a member HUM-* or a door-off guest GST-* (wui-live-ws 0.4.1 §3.1). */
export function isHuman(id) {
  return /^(HUM|GST)-/.test(String(id || ''))
}

/** A member (store) human, the only kind with a stored picture; never a guest. */
export function isMember(id) {
  return /^HUM-\d+$/.test(String(id || ''))
}

export function prefixOf(id) {
  return idPrefix(id)
}

function hsl(h, s, l) {
  return `hsl(${((h % 360) + 360) % 360} ${s}% ${l}%)`
}

/** Robot SVG string. key = id or id@box. */
export function robotSvg(key) {
  const id = String(key || '').split('@')[0]
  const next = stream(hashSeed(key))
  const pick = (n) => next() % n
  const base = PREFIX_HUE[prefixOf(id)] ?? (hashSeed(prefixOf(id)) % 360)
  const hue = base + (pick(41) - 20)
  const body = hsl(hue, 62, 58)
  const dark = hsl(hue, 45, 28)
  const glow = hsl(hue + 180, 90, 62)
  const bg = hsl(hue + 30, 40, 92)
  const r = [4, 10, 16][pick(3)]
  const w = 36 + pick(3) * 4
  const x = 32 - w / 2
  const parts = []
  parts.push(`<rect width="64" height="64" rx="14" fill="${bg}"/>`)
  // antenna
  const ant = pick(4)
  if (ant === 1) parts.push(`<line x1="32" y1="14" x2="32" y2="6" stroke="${dark}" stroke-width="2"/><circle cx="32" cy="5" r="3" fill="${glow}"/>`)
  if (ant === 2) parts.push(`<polyline points="32,14 28,10 34,8 30,3" fill="none" stroke="${dark}" stroke-width="2"/><circle cx="30" cy="3" r="2" fill="${glow}"/>`)
  if (ant === 3) parts.push(`<line x1="24" y1="15" x2="18" y2="6" stroke="${dark}" stroke-width="2"/><line x1="40" y1="15" x2="46" y2="6" stroke="${dark}" stroke-width="2"/><circle cx="18" cy="5" r="2.5" fill="${glow}"/><circle cx="46" cy="5" r="2.5" fill="${glow}"/>`)
  // ears / bolts
  if (pick(2)) parts.push(`<rect x="${x - 5}" y="28" width="5" height="10" rx="2" fill="${dark}"/><rect x="${x + w}" y="28" width="5" height="10" rx="2" fill="${dark}"/>`)
  // head
  parts.push(`<rect x="${x}" y="14" width="${w}" height="38" rx="${r}" fill="${body}" stroke="${dark}" stroke-width="2"/>`)
  // eyes
  const eyes = pick(5)
  const ey = 28 + pick(3)
  if (eyes === 0) parts.push(`<circle cx="24" cy="${ey}" r="5" fill="#fff"/><circle cx="40" cy="${ey}" r="5" fill="#fff"/><circle cx="${24 + pick(3) - 1}" cy="${ey}" r="2.4" fill="${dark}"/><circle cx="${40 + pick(3) - 1}" cy="${ey}" r="2.4" fill="${dark}"/>`)
  if (eyes === 1) parts.push(`<circle cx="32" cy="${ey}" r="8" fill="#fff" stroke="${dark}" stroke-width="2"/><circle cx="32" cy="${ey}" r="3.5" fill="${glow}"/>`)
  if (eyes === 2) parts.push(`<rect x="19" y="${ey - 4}" width="10" height="8" rx="2" fill="${glow}"/><rect x="35" y="${ey - 4}" width="10" height="8" rx="2" fill="${glow}"/>`)
  if (eyes === 3) parts.push(`<path d="M20 ${ey - 4} l8 8 M28 ${ey - 4} l-8 8 M36 ${ey - 4} l8 8 M44 ${ey - 4} l-8 8" stroke="${dark}" stroke-width="2.4" stroke-linecap="round"/>`)
  if (eyes === 4) parts.push(`<circle cx="23" cy="${ey}" r="3" fill="${dark}"/><circle cx="41" cy="${ey}" r="6.5" fill="#fff" stroke="${dark}" stroke-width="2"/><circle cx="42" cy="${ey + 1}" r="2.5" fill="${dark}"/>`)
  // mouth
  const my = 43
  const mouth = pick(4)
  if (mouth === 0) parts.push(`<rect x="22" y="${my - 3}" width="20" height="6" rx="2" fill="${dark}"/><path d="M26 ${my - 3} v6 M30 ${my - 3} v6 M34 ${my - 3} v6 M38 ${my - 3} v6" stroke="${body}" stroke-width="1.2"/>`)
  if (mouth === 1) parts.push(`<path d="M22 ${my - 3} q10 10 20 0" fill="none" stroke="${dark}" stroke-width="2.4" stroke-linecap="round"/>`)
  if (mouth === 2) parts.push(`<polyline points="21,${my} 25,${my - 3} 29,${my} 33,${my - 3} 37,${my} 41,${my - 3}" fill="none" stroke="${dark}" stroke-width="2"/>`)
  if (mouth === 3) parts.push(`<path d="M24 ${my - 3} h16 q0 8 -8 8 q-8 0 -8 -8z" fill="${dark}"/><path d="M29 ${my + 1} q3 4 6 0z" fill="#ff7a9a"/>`)
  // extras: blush / bolt / eyebrow
  const extra = pick(3)
  if (extra === 0) parts.push(`<circle cx="${x + 5}" cy="38" r="2.5" fill="#ff8fab" opacity=".7"/><circle cx="${x + w - 5}" cy="38" r="2.5" fill="#ff8fab" opacity=".7"/>`)
  if (extra === 1) parts.push(`<circle cx="${x + 4}" cy="18" r="1.6" fill="${dark}"/><circle cx="${x + w - 4}" cy="18" r="1.6" fill="${dark}"/>`)
  if (extra === 2) parts.push(`<path d="M18 ${ey - 9} l10 ${pick(2) ? 2 : -2} M36 ${ey - 9 + (pick(2) ? 2 : 0)} l10 -2" stroke="${dark}" stroke-width="2" stroke-linecap="round"/>`)
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">${parts.join('')}</svg>`
}

/** Human identicon: 5×5 mirrored grid, colour from the id. */
export function identiconSvg(key) {
  const next = stream(hashSeed(key))
  const hue = next() % 360
  const fg = hsl(hue, 55, 48)
  const bg = hsl(hue, 30, 93)
  const cells = []
  for (let row = 0; row < 5; row++) {
    for (let col = 0; col < 3; col++) {
      if (next() % 2) {
        cells.push([col, row])
        if (col < 2) cells.push([4 - col, row])
      }
    }
  }
  if (!cells.length) cells.push([2, 2])
  const rects = cells.map(([c, r]) => `<rect x="${7 + c * 10}" y="${7 + r * 10}" width="10" height="10" fill="${fg}"/>`).join('')
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="${bg}"/>${rects}</svg>`
}

export function avatarSvg(id, box) {
  const key = box ? `${id}@${box}` : String(id || '')
  return isHuman(id) ? identiconSvg(key) : robotSvg(key)
}

/* The generated picture is a pure function of id@box, and every card draws
   two: remember the few hundred a tab sees instead of rebuilding the SVG and
   URI-encoding it per mount (CLE-35075). Bounded: cleared when full. */
const avatarUris = new Map()
const AVATAR_URI_MAX = 1000

export function avatarDataUri(id, box) {
  const key = String(id || '') + '\n' + String(box || '')
  let uri = avatarUris.get(key)
  if (uri === undefined) {
    uri = `data:image/svg+xml;utf8,${encodeURIComponent(avatarSvg(id, box))}`
    if (avatarUris.size >= AVATAR_URI_MAX) avatarUris.clear()
    avatarUris.set(key, uri)
  }
  return uri
}

/*
 * Stored IdP pictures (gap A5; view-v1 §4.1 `humans`, 010 T044). The roster
 * carries each member HUM-*'s avatar_file_id; the picture is GET
 * /v1/files/{id} on the same tenant host. Anything missing or failing falls
 * back to the deterministic default above.
 */

const FILE_ID_RE = /^[0-9a-f]{64}$/

/** view-v1 §4.1 roster → { 'HUM-3': '<sha256 hex>' }; null / malformed ids are dropped. */
export function avatarFilesFromView(data) {
  const out = {}
  for (const h of (data && Array.isArray(data.humans) ? data.humans : [])) {
    const id = h && String(h.human_id || '')
    const fid = h && typeof h.avatar_file_id === 'string' ? h.avatar_file_id : ''
    if (isMember(id) && FILE_ID_RE.test(fid)) out[id] = fid
  }
  return out
}

/**
 * The picture URL for id@box, or '' (draw the default). Humans only, and only
 * as themselves: a HUM-* on the browser box (or no box), never an agent id.
 */
export function avatarImageUrl(base, id, box, files) {
  if (!isMember(id) || (box && box !== 'box-wui')) return ''
  const fid = files && Object.prototype.hasOwnProperty.call(files, id) ? String(files[id]) : ''
  if (!FILE_ID_RE.test(fid)) return ''
  return `${String(base || '').replace(/\/+$/, '')}/v1/files/${fid}`
}

/** Alt text: the id the card already names, so a screen reader hears who it is. */
export function avatarAlt(id, box) {
  const who = String(id || '') + (box && box !== 'box-wui' ? `@${box}` : '')
  return who ? `avatar of ${who}` : 'avatar'
}

/** i18n sibling of avatarAlt: `feed.avatar_of` {who} or `feed.avatar`. */
export function avatarAltKey(id, box) {
  const who = String(id || '') + (box && box !== 'box-wui' ? `@${box}` : '')
  return who ? { key: 'feed.avatar_of', params: { who } } : { key: 'feed.avatar', params: {} }
}

export const AVATAR_FILES_TTL_MS = 60_000
const avatarLoads = new Map()
/* The last roster read that ANSWERED, per (base, token). A later read that
   fails resolves this, not {}: every avatar re-reads the roster once the TTL
   is out, and an answer of {} replaced the page's whole picture and name map,
   so one transient 401 / 5xx / dropped request (a hub rollout) put every
   stored picture back to its identicon and every name back to its id until
   the next good read - "the avatars disappear from time to time" (owner,
   prd t1 432769d8 + 177db6cf, 2026-09-26). */
const rosterLastGood = new Map()

/**
 * One roster read per (base, token) per TTL, shared by every avatar on the
 * page. Never rejects: a failed read resolves the last read that answered
 * for this (base, token), or {} before any did (the default is drawn).
 * `read` (the spool client's rosterView) replaces the raw fetch: the read
 * then joins the roster store's identical one in flight instead of being a
 * second request.
 */
export function loadAvatarFiles({ base = '', token = '', credentials = 'omit', fetchFn = globalThis.fetch, read = null, now = Date.now, ttlMs = AVATAR_FILES_TTL_MS } = {}) {
  const root = String(base || '').replace(/\/+$/, '')
  const key = `${root}\n${token}`
  const hit = avatarLoads.get(key)
  if (hit && now() - hit.at < ttlMs) return hit.promise
  const headers = { accept: 'application/json' }
  if (token) headers.authorization = `Bearer ${token}`
  const json = (async () => {
    try {
      if (typeof read === 'function') return (await read()) || null
      if (typeof fetchFn !== 'function') return null
      const res = await fetchFn(`${root}/v1/view/roster`, { credentials, headers })
      return res && res.ok ? await res.json() : null
    } catch {
      return null
    }
  })()
  const read1 = json.then((data) => {
    if (data === null) return rosterLastGood.get(key) || { files: {}, names: {} }
    const got = { files: avatarFilesFromView(data), names: humanNamesFromView(data) }
    rosterLastGood.set(key, got)
    return got
  })
  const promise = read1.then((r) => r.files)
  const names = read1.then((r) => r.names)
  const entry = { at: now(), promise, names }
  avatarLoads.set(key, entry)
  /* A failed read is not kept: the first one runs on the login page, before
     the session exists, and its 401 would otherwise blank every name and
     picture for the whole TTL after sign-in. */
  json.then((data) => { if (data === null && avatarLoads.get(key) === entry) avatarLoads.delete(key) })
  return promise
}

/**
 * view-v1 §4.1 roster → { 'HUM-3': 'Alice Example' }: the name each member
 * chose in Settings > Profile. A member with none is left out (the WUI shows
 * the id).
 */
export function humanNamesFromView(data) {
  const out = {}
  for (const h of (data && Array.isArray(data.humans) ? data.humans : [])) {
    const id = h && String(h.human_id || '')
    const name = h && typeof h.display_name === 'string' ? h.display_name.trim() : ''
    if (isMember(id) && name) out[id] = name
  }
  return out
}

/** The display names from the same roster read as the pictures (one fetch, same cache). */
export function loadHumanNames(opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const root = String(o.base || '').replace(/\/+$/, '')
  loadAvatarFiles(o)
  const hit = avatarLoads.get(`${root}\n${o.token || ''}`)
  return hit && hit.names ? hit.names : Promise.resolve({})
}

/** png / jpeg / gif / webp from the magic bytes (the hub serves octet-stream), else ''. */
export function avatarImageMime(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || [])
  const at = (i, ...xs) => xs.every((x, k) => b[i + k] === x)
  if (at(0, 0x89, 0x50, 0x4e, 0x47)) return 'image/png'
  if (at(0, 0xff, 0xd8, 0xff)) return 'image/jpeg'
  if (at(0, 0x47, 0x49, 0x46, 0x38)) return 'image/gif'
  if (at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) return 'image/webp'
  return ''
}

const avatarImages = new Map()

/** bytes → data:<type>;base64,… (chunked, so a 256 KiB picture never overflows the call stack). */
export function bytesToDataUri(bytes, type) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || [])
  let bin = ''
  for (let i = 0; i < b.length; i += 0x8000) bin += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000))
  return `data:${type};base64,${btoa(bin)}`
}

/**
 * The picture as a data: URL, or '' (draw the default). Every deployed CSP
 * is img-src 'self' data: (render-wui-firebase-json.sh) — a blob: URL is
 * blocked there, which is why no stored picture ever showed —
 * and connect-src admits the hub, so the bytes are fetched with the caller's
 * credentials (017 FR-SEC-002: /v1/files needs the member session;
 * /api/v1/auth/avatar the session cookie) and only an image by its magic
 * bytes is shown. One fetch per URL for the page's lifetime, except after a
 * network error, a 5xx or a timeout (AVATAR_FETCH_TIMEOUT_MS), which the
 * next mount asks again.
 *
 * `missStore` (a Storage) also remembers a 404 across reloads, for ONE url:
 * the own-picture route answers 404 to a member with no stored picture on
 * every page load (124 times for one member in 6 h on prd). Its
 * URL carries the session's iat, so the next sign-in asks again. Only a 404
 * is remembered; a network error or a 5xx is asked again next time.
 */
export const AVATAR_MISS_KEY = 'spool.avatar.miss'
/** A picture fetch that has not answered by then is given up (and asked again on the next mount). */
export const AVATAR_FETCH_TIMEOUT_MS = 8000
export function loadAvatarImageUrl(url, { credentials = 'omit', fetchFn = globalThis.fetch, missStore = null, timeoutMs = AVATAR_FETCH_TIMEOUT_MS } = {}) {
  if (!url) return Promise.resolve('')
  if (avatarImages.has(url)) return avatarImages.get(url)
  const readMiss = () => { try { return missStore ? missStore.getItem(AVATAR_MISS_KEY) : null } catch { return null } }
  if (readMiss() === url) return Promise.resolve('')
  /* A 404 or a non-image answer is final for the page; a network error, a
     5xx or a timeout is not kept, so the next avatar that mounts asks again
     instead of showing the default until a reload. */
  let transient = false
  const promise = (async () => {
    const ctl = typeof AbortController === 'function' ? new AbortController() : null
    const timer = ctl ? setTimeout(() => ctl.abort(), timeoutMs) : null
    try {
      const res = await fetchFn(url, { credentials, signal: ctl?.signal })
      if (res && res.status === 404 && missStore) {
        try { missStore.setItem(AVATAR_MISS_KEY, url) } catch { /* storage full or blocked */ }
      }
      if (!res || !res.ok) {
        transient = !res || res.status !== 404
        return ''
      }
      const bytes = new Uint8Array(await res.arrayBuffer())
      const type = avatarImageMime(bytes)
      return type ? bytesToDataUri(bytes, type) : ''
    } catch {
      transient = true
      return ''
    } finally {
      if (timer) clearTimeout(timer)
    }
  })()
  avatarImages.set(url, promise)
  promise.then(() => { if (transient && avatarImages.get(url) === promise) avatarImages.delete(url) })
  return promise
}

/** Forget the cached roster read only (names and picture ids), not the pictures. */
export function forgetRosterRead() {
  avatarLoads.clear()
}

/** Test seam: forget every cached roster read and picture. */
export function resetAvatarFiles() {
  avatarLoads.clear()
  avatarImages.clear()
  rosterLastGood.clear()
}
