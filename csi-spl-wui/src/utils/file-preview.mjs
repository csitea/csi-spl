// Which attachments get an inline picture, and which icon every other file
// gets (owner, 2026-09-25: "there should be a preview for pic files", "no
// preview for them, but icons for the type of the file"). A FileRef carries
// no MIME type, so the name decides. SVG never previews: it is a document
// that can carry script, and a picture preview must never be one.

export const PREVIEW_MAX_BYTES = 10 * 1024 * 1024

const IMAGE_EXT = /\.(png|jpe?g|gif|webp)$/i

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
