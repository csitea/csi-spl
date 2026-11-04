// The customer's draft hand-over (spec 090 T036, SPL-4804; spec.md
// section 17), the plain helpers of MarketingDraftHandover.vue: which
// photos go into the download pack, the caption with its hashtags, and the
// pack itself as a ZIP (stored, no compression: the photos are already
// compressed). No library: a store-only ZIP is a few headers and a CRC-32.

/** The photo selector's limit (spec.md section 17.2: 1 to 10 photos). */
export const HANDOVER_MAX_PHOTOS = 10

/** Instagram's limit on hashtags in one caption (spec.md section 21.1). */
export const HANDOVER_MAX_HASHTAGS = 30

/**
 * The photos of the download pack: the checked ones, in gallery order, at
 * most HANDOVER_MAX_PHOTOS. An unchecked photo never enters it.
 * @param {string[]} images
 * @param {Record<string, boolean>} checked
 * @returns {string[]}
 */
export function handoverPicked(images, checked) {
  return (images || []).filter((u) => checked && checked[u] === true).slice(0, HANDOVER_MAX_PHOTOS)
}

/**
 * The hashtags typed by the author, each once, '#'-prefixed, at most
 * HANDOVER_MAX_HASHTAGS. Separators: spaces, commas, new lines.
 * @param {string} text
 * @returns {string[]}
 */
export function handoverHashtags(text) {
  const out = []
  for (const raw of String(text || '').split(/[\s,]+/)) {
    const word = raw.replace(/^#+/, '').replace(/[^\p{L}\p{N}_]/gu, '')
    const tag = word ? `#${word}` : ''
    if (tag && !out.some((x) => x.toLowerCase() === tag.toLowerCase())) out.push(tag)
  }
  return out.slice(0, HANDOVER_MAX_HASHTAGS)
}

/**
 * The text "Copy caption & hashtags" puts on the clipboard: the caption,
 * then a blank line and the hashtags on one line when there are any.
 * @param {string} caption
 * @param {string} hashtags
 * @returns {string}
 */
export function handoverCopyText(caption, hashtags) {
  const tags = handoverHashtags(hashtags)
  const body = String(caption || '').trim()
  return tags.length ? `${body}\n\n${tags.join(' ')}` : body
}

/**
 * The file name of a photo in the pack: its last path segment, made unique.
 * @param {string} url
 * @param {number} i
 * @param {Set<string>} used
 * @returns {string}
 */
export function handoverFileName(url, i, used) {
  let base = ''
  try { base = decodeURIComponent(new URL(url, 'https://x.invalid/').pathname.split('/').pop() || '') } catch { base = '' }
  base = base.replace(/[^\w.-]/g, '_') || `photo-${i + 1}.jpg`
  let name = base
  for (let n = 2; used.has(name); n++) name = base.replace(/(\.[^.]*)?$/, (ext) => `-${n}${ext || ''}`)
  used.add(name)
  return name
}

let crcTable = null
/**
 * CRC-32 (IEEE 802.3), as ZIP needs it.
 * @param {Uint8Array} bytes
 * @returns {number}
 */
export function crc32(bytes) {
  if (!crcTable) {
    crcTable = new Uint32Array(256)
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
      crcTable[n] = c >>> 0
    }
  }
  let c = 0xffffffff
  for (let i = 0; i < bytes.length; i++) c = crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function zipHeader(sig, fields) {
  const size = 4 + fields.reduce((n, [w]) => n + w, 0)
  const v = new DataView(new ArrayBuffer(size))
  v.setUint32(0, sig, true)
  let o = 4
  for (const [w, x] of fields) {
    if (w === 2) v.setUint16(o, x, true)
    else v.setUint32(o, x, true)
    o += w
  }
  return new Uint8Array(v.buffer)
}

/**
 * A store-only ZIP of files [{ name, bytes }] (names ASCII, as
 * handoverFileName makes them), as one Uint8Array.
 * @param {{ name: string, bytes: Uint8Array }[]} files
 * @returns {Uint8Array}
 */
export function handoverZip(files) {
  const enc = new TextEncoder()
  const parts = []
  const central = []
  let offset = 0
  for (const f of files) {
    const name = enc.encode(f.name)
    const crc = crc32(f.bytes)
    const len = f.bytes.length
    // version 20, no flags, stored, time/date 0, crc, sizes, name length, extra 0
    const local = zipHeader(0x04034b50, [[2, 20], [2, 0], [2, 0], [2, 0], [2, 0x21], [4, crc], [4, len], [4, len], [2, name.length], [2, 0]])
    parts.push(local, name, f.bytes)
    central.push(zipHeader(0x02014b50, [[2, 20], [2, 20], [2, 0], [2, 0], [2, 0], [2, 0x21], [4, crc], [4, len], [4, len],
      [2, name.length], [2, 0], [2, 0], [2, 0], [2, 0], [4, 0], [4, offset]]), name)
    offset += local.length + name.length + len
  }
  const cdSize = central.reduce((n, p) => n + p.length, 0)
  const end = zipHeader(0x06054b50, [[2, 0], [2, 0], [2, files.length], [2, files.length], [4, cdSize], [4, offset], [2, 0]])
  const all = [...parts, ...central, end]
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of all) {
    out.set(p, o)
    o += p.length
  }
  return out
}

/**
 * How the selected photos are downloaded: one photo is a direct download,
 * more are one ZIP. Returns { kind: 'none' | 'single' | 'zip', urls }.
 * @param {string[]} picked
 */
export function handoverDownloadPlan(picked) {
  const urls = (picked || []).slice(0, HANDOVER_MAX_PHOTOS)
  if (!urls.length) return { kind: 'none', urls }
  return { kind: urls.length === 1 ? 'single' : 'zip', urls }
}
