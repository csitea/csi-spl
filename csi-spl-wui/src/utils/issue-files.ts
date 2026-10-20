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

/** One stored file as the wire carries it (the channel store's toFileRefs shape). */
export interface IssueFileRef { mode: 'blob', kind: 'file', file_id: string, sha256: string, bytes: number, name: string }

/**
 * Upload each picked File and return the wire refs. `upload` is
 * uploadWithFreshToken bound to the client.
 */
export async function uploadRefs(
  files: File[],
  upload: (f: File) => Promise<{ file_id: string, sha256: string, bytes: number }>,
): Promise<IssueFileRef[]> {
  const refs: IssueFileRef[] = []
  for (const f of files || []) {
    const up = await upload(f)
    refs.push({ mode: 'blob', kind: 'file', file_id: up.file_id, sha256: up.sha256, bytes: up.bytes, name: f.name })
  }
  return refs
}

/** brackets and line breaks would end the link text early */
const cleanName = (name: unknown): string => String(name || 'file').replace(/[[\]\r\n]+/g, ' ').trim() || 'file'

/**
 * The markdown that names one stored file in a description:
 * `[name](<url>#bytes=<n>)`. The fragment never reaches the hub; it keeps the
 * size for the card. `url` is the client's fileUrl(file_id).
 */
export function descFileLink(ref: { name?: string, file_id?: string, sha256?: string, bytes?: number }, url: string): string {
  const n = Number(ref && ref.bytes)
  const frag = Number.isFinite(n) && n >= 0 ? `#bytes=${Math.floor(n)}` : ''
  return `[${cleanName(ref && ref.name)}](${url}${frag})`
}

const LINK = /\[([^\]\n]*)\]\(([^()\s]*\/v1\/files\/([0-9a-f]{64}))(?:#bytes=(\d+))?\)/g

/** The stored files a description names (descFileLink), once each, in order. */
export function descFileRefs(text: string): IssueFileRef[] {
  const out: IssueFileRef[] = []
  const seen = new Set<string>()
  for (const m of String(text || '').matchAll(LINK)) {
    const id = m[3]!
    if (seen.has(id)) continue
    seen.add(id)
    out.push({ mode: 'blob', kind: 'file', file_id: id, sha256: id, bytes: m[4] ? Number(m[4]) : 0, name: m[1] || id.slice(0, 12) })
  }
  return out
}
