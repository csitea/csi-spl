// Owner HUM-10 (t1 41881574, e3ce4c34): the docs a signed-out visitor reads,
// those marked `public: true`. Apart from docs.mjs, which the home bundle
// carries (the palette): only the docs page and the build-time copy
// (src/node/docs/sync-public-docs.mjs) need these.
import { validDocsPath } from './docs.mjs'

/**
 * The public marker, the doc's last line (owner HUM-10, t1 41881574,
 * ef9bb80c: "not at the beginning of the doc, but at the end"): an HTML
 * comment, so GitHub renders nothing for it.
 */
export const PUBLIC_END_MARKER = /(?:^|\r?\n)[ \t]*<!--[ \t]*public:[ \t]*true[ \t]*-->\s*$/

/**
 * The doc without its leading `---` frontmatter and without its end marker
 * `<!-- public: true -->` (both mark a doc a signed-out visitor reads, owner
 * HUM-10 e3ce4c34 / ef9bb80c); the text as it is when there is neither.
 */
export function docsBody(md) {
  const s = String(md).replace(/^---\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/, '')
  const m = PUBLIC_END_MARKER.exec(s)
  return m ? s.slice(0, m.index).replace(/\s*$/, '') + (m.index > 0 ? '\n' : '') : s
}

/** Where the build-time copy of the public docs is served (sync-public-docs.mjs). */
export const PUBLIC_DOCS_DIR = '/docs-public/'

/**
 * The public docs out of the copy's index.json: [{ path, title }], each a
 * valid docs path. Anything else (no copy: the SPA fallback's HTML) is [].
 */
export function publicDocsList(body) {
  const files = body && typeof body === 'object' && Array.isArray(body.files) ? body.files : []
  return files.filter((f) => f && validDocsPath(f.path))
    .map((f) => ({ path: f.path, title: typeof f.title === 'string' ? f.title : '' }))
}
