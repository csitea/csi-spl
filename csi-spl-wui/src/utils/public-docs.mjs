// Owner HUM-10 (t1 41881574, e3ce4c34): the docs a signed-out visitor reads,
// those marked `public: true`. Apart from docs.mjs, which the home bundle
// carries (the palette): only the docs page and the build-time copy
// (src/node/docs/sync-public-docs.mjs) need these.
import { validDocsPath } from './docs.mjs'

/**
 * The doc without its leading `---` frontmatter (`public: true` marks a doc
 * a signed-out visitor reads, owner HUM-10 e3ce4c34); the text as it is
 * when there is none.
 */
export function docsBody(md) {
  return String(md).replace(/^---\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/, '')
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
