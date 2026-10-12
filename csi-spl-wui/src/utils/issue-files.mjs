/**
 * Files in an issue's comments and description (owner HUM-10, t1 43ebdf0b:
 * Ctrl + V files in the issue descriptions and the comments, and an attach
 * button there too).
 *
 * A comment is a message row, so it carries its files like any message. A
 * description is a plain text field, and the hub serves a file only to a
 * reader of a message that carries it (store/file_door.go): an upload that no
 * message carries is refused after the upload grace. So a description's file
 * rides on a note in the issue's discussion, and the description names it
 * with a markdown link to /v1/files/<sha256>. That link is the reference; the
 * description view reads it back as a file card (descFileRefs).
 */

/**
 * Upload each picked File and return the wire refs (the channel store's
 * toFileRefs shape). `upload` is uploadWithFreshToken bound to the client.
 * @param {File[]} files
 * @param {(f: File) => Promise<{ file_id: string, sha256: string, bytes: number }>} upload
 * @returns {Promise<Array<{ mode: 'blob', kind: 'file', file_id: string, sha256: string, bytes: number, name: string }>>}
 */
export async function uploadRefs(files, upload) {
  const refs = []
  for (const f of files || []) {
    const up = await upload(f)
    refs.push({ mode: 'blob', kind: 'file', file_id: up.file_id, sha256: up.sha256, bytes: up.bytes, name: f.name })
  }
  return refs
}

/** brackets and line breaks would end the link text early */
const cleanName = (name) => String(name || 'file').replace(/[[\]\r\n]+/g, ' ').trim() || 'file'

/**
 * The markdown that names one stored file in a description:
 * `[name](<url>#bytes=<n>)`. The fragment never reaches the hub; it keeps the
 * size for the card.
 * @param {{ name?: string, file_id?: string, sha256?: string, bytes?: number }} ref
 * @param {string} url the client's fileUrl(file_id)
 * @returns {string}
 */
export function descFileLink(ref, url) {
  const n = Number(ref && ref.bytes)
  const frag = Number.isFinite(n) && n >= 0 ? `#bytes=${Math.floor(n)}` : ''
  return `[${cleanName(ref && ref.name)}](${url}${frag})`
}

const LINK = /\[([^\]\n]*)\]\(([^()\s]*\/v1\/files\/([0-9a-f]{64}))(?:#bytes=(\d+))?\)/g

/**
 * The stored files a description names (descFileLink), once each, in order.
 * @param {string} text
 * @returns {Array<{ mode: 'blob', kind: 'file', file_id: string, sha256: string, bytes: number, name: string }>}
 */
export function descFileRefs(text) {
  const out = []
  const seen = new Set()
  for (const m of String(text || '').matchAll(LINK)) {
    const id = m[3]
    if (seen.has(id)) continue
    seen.add(id)
    out.push({ mode: 'blob', kind: 'file', file_id: id, sha256: id, bytes: m[4] ? Number(m[4]) : 0, name: m[1] || id.slice(0, 12) })
  }
  return out
}
