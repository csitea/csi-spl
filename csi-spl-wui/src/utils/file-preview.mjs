// Which attachments get an inline picture, and which icon every other file
// gets (owner, 2026-09-25: "there should be a preview for pic files", "no
// preview for them, but icons for the type of the file"). A FileRef carries
// no MIME type, so the name decides which files are fetched, and the bytes
// decide what is shown (previewImageMime).
//
// Owner, 2026-09-25: "basically all the images / pictures type of file types
// should" preview. Every type a browser can draw in <img> does: png, jpeg,
// gif, webp, avif, bmp, ico, and svg. An svg shown by <img> runs no script.
// tiff and heic keep their icon: Chrome cannot draw them.

export const PREVIEW_MAX_BYTES = 10 * 1024 * 1024

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|avif|bmp|ico|svg)$/i

/** true when `name` looks like a raster picture and is small enough to show inline */
export function isPreviewableImage(name, bytes) {
  if (!IMAGE_EXT.test(String(name || ''))) return false
  const n = Number(bytes)
  return !(Number.isFinite(n) && n > PREVIEW_MAX_BYTES)
}

/* extension -> kind. The kind names the icon (UiIcon file-*) and the colour
   of the card's icon; anything unknown is a plain "other". */
const KINDS = {
  pdf: ['pdf'],
  doc: ['doc', 'docx', 'odt', 'rtf', 'txt', 'md', 'pages'],
  sheet: ['xls', 'xlsx', 'xlsm', 'ods', 'csv', 'tsv', 'numbers'],
  slides: ['ppt', 'pptx', 'odp', 'key'],
  image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'svg', 'heic', 'tif', 'tiff', 'ico'],
  archive: ['zip', 'gz', 'tgz', 'tar', '7z', 'rar', 'bz2', 'xz', 'zst'],
  code: ['js', 'mjs', 'ts', 'py', 'go', 'sh', 'json', 'yaml', 'yml', 'xml', 'html', 'css', 'sql', 'rs', 'java', 'c', 'h', 'cpp', 'tf', 'toml', 'log'],
  media: ['mp3', 'wav', 'ogg', 'flac', 'm4a', 'mp4', 'mov', 'webm', 'mkv', 'avi'],
}
const ICON = {
  pdf: 'file-text',
  doc: 'file-text',
  sheet: 'file-spreadsheet',
  slides: 'file-slides',
  image: 'file-image',
  archive: 'file-archive',
  code: 'file-code',
  media: 'file-media',
  other: 'file',
}
const BY_EXT = new Map(Object.entries(KINDS).flatMap(([k, exts]) => exts.map((e) => [e, k])))

/** the lower-case extension of `name` without the dot, or '' */
export function fileExt(name) {
  const m = /\.([A-Za-z0-9]{1,8})$/.exec(String(name || ''))
  return m ? m[1].toLowerCase() : ''
}

/** { kind, icon, ext } for a file name: what the card and the composer chip draw */
export function fileKind(name) {
  const ext = fileExt(name)
  const kind = BY_EXT.get(ext) || 'other'
  return { kind, icon: ICON[kind], ext }
}

/** a picked File as a data: URL (every deployed CSP is img-src 'self' data:, never blob:) */
export function readDataUrl(file) {
  return new Promise((resolve) => {
    const r = new FileReader()
    r.onload = () => resolve(typeof r.result === 'string' ? r.result : '')
    r.onerror = () => resolve('')
    r.readAsDataURL(file)
  })
}

/**
 * The picture type the bytes are, or '' when they are not one a browser
 * draws. The name only chose to fetch the file; a file NAMED .png that is not
 * a picture shows its icon instead.
 * @param {ArrayBuffer | Uint8Array | null | undefined} bytes
 * @returns {string}
 */
export function previewImageMime(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || [])
  const at = (i, ...xs) => xs.every((x, k) => b[i + k] === x)
  const ascii = (i, s) => at(i, ...[...s].map((c) => c.charCodeAt(0)))
  if (at(0, 0x89, 0x50, 0x4e, 0x47)) return 'image/png'
  if (at(0, 0xff, 0xd8, 0xff)) return 'image/jpeg'
  if (ascii(0, 'GIF8')) return 'image/gif'
  if (ascii(0, 'RIFF') && ascii(8, 'WEBP')) return 'image/webp'
  if (ascii(4, 'ftypavif') || ascii(4, 'ftypavis')) return 'image/avif'
  if (ascii(0, 'BM') && b.length > 14) return 'image/bmp'
  if (at(0, 0x00, 0x00, 0x01, 0x00)) return 'image/x-icon'
  const head = new TextDecoder('utf-8', { fatal: false }).decode(b.subarray(0, 1024)).replace(/^\uFEFF/, '').trimStart()
  if ((head.startsWith('<svg') || head.startsWith('<?xml') || head.startsWith('<!--')) && /<svg[\s>]/.test(head)) return 'image/svg+xml'
  return ''
}
