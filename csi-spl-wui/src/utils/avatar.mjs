/**
 * Deterministic default avatars (SPEC-spool-avatars.md §2, 013 US4).
 * Agents (CLE-*, GRK-*, AGY-*, any non-HUM agent id) → a wild, funny robot;
 * humans (HUM-*) → a symmetric identicon. Same id(@box) → same picture.
 * Generated inline SVG: no image files in the tree, no third-party CDN, and no
 * user text inside the SVG (only numbers and colours), so nothing to escape.
 */

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

const PREFIX_HUE = { CLE: 175, GRK: 28, AGY: 275 }

export function isHuman(id) {
  return /^HUM-/.test(String(id || ''))
}

export function prefixOf(id) {
  const m = String(id || '').match(/^([A-Z]{2,4})-/)
  return m ? m[1] : ''
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

export function avatarDataUri(id, box) {
  return `data:image/svg+xml;utf8,${encodeURIComponent(avatarSvg(id, box))}`
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
    if (isHuman(id) && FILE_ID_RE.test(fid)) out[id] = fid
  }
  return out
}

/**
 * The picture URL for id@box, or '' (draw the default). Humans only, and only
 * as themselves: a HUM-* on the browser box (or no box), never an agent id.
 */
export function avatarImageUrl(base, id, box, files) {
  if (!isHuman(id) || (box && box !== 'box-wui')) return ''
  const fid = files && Object.prototype.hasOwnProperty.call(files, id) ? String(files[id]) : ''
  if (!FILE_ID_RE.test(fid)) return ''
  return `${String(base || '').replace(/\/+$/, '')}/v1/files/${fid}`
}

/** Alt text: the id the card already names, so a screen reader hears who it is. */
export function avatarAlt(id, box) {
  const who = String(id || '') + (box && box !== 'box-wui' ? `@${box}` : '')
  return who ? `avatar of ${who}` : 'avatar'
}

export const AVATAR_FILES_TTL_MS = 60_000
const avatarLoads = new Map()

/**
 * One roster read per (base, token) per TTL, shared by every avatar on the
 * page. Resolves {} on any failure (the default is drawn), never rejects.
 */
export function loadAvatarFiles({ base = '', token = '', credentials = 'omit', fetchFn = globalThis.fetch, now = Date.now, ttlMs = AVATAR_FILES_TTL_MS } = {}) {
  const root = String(base || '').replace(/\/+$/, '')
  const key = `${root}\n${token}`
  const hit = avatarLoads.get(key)
  if (hit && now() - hit.at < ttlMs) return hit.promise
  const headers = { accept: 'application/json' }
  if (token) headers.authorization = `Bearer ${token}`
  const promise = (async () => {
    try {
      if (typeof fetchFn !== 'function') return {}
      const res = await fetchFn(`${root}/v1/view/roster`, { credentials, headers })
      return res && res.ok ? avatarFilesFromView(await res.json()) : {}
    } catch {
      return {}
    }
  })()
  avatarLoads.set(key, { at: now(), promise })
  return promise
}

/** Test seam: forget every cached roster read. */
export function resetAvatarFiles() {
  avatarLoads.clear()
}
