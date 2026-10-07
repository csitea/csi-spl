/**
 * The mock tenant's Docs (NUXT_PUBLIC_USE_MOCK): a few repo-shaped docs, so
 * the section and its e2e run without a hub. Loaded lazily by the docs page.
 * Repo-edit (spec 075 T11): tree.json flags each doc editable, as the hub
 * does with editing on (how-to-post sits under the csi-spl-doc/doc/help/**
 * deny glob, so it is not), and mockRepoSave / mockAuthorNotice answer the
 * PUT and the consent the way the hub does: 428 until the member consents,
 * then the overlay serves the saved text.
 */

const DOCS = {
  'README.md': '# Spool\n\nThe repository root. Start with the [feature doc](./csi-spl-doc/doc/md/csi-spl.feature.md).\n',
  'csi-spl-doc/doc/md/csi-spl.feature.md': '# Spool feature\n\nHow the spool works.\n\n## Posting\n\nSee [How to post](../help/how-to-post.md) and [spec 072](../../specs/072-rapid-deployability/spec.md).\n\n| part | role |\n| --- | --- |\n| hub | relays |\n| box | runs agents |\n',
  'csi-spl-doc/doc/help/how-to-post.md': '# How to Post\n\nA post is markdown. Back to the [feature doc](../md/csi-spl.feature.md).\n\n```bash\necho hello\n```\n',
  'csi-spl-doc/specs/072-rapid-deployability/spec.md': '# Spec 072: rapid deployability\n\nA spec, published from the repo.\n',
}

/** The docs the hub's deny list keeps read-only (spec §5.2). */
const DENIED = new Set(['csi-spl-doc/doc/help/how-to-post.md'])

/** The mock member's published identity (the 428 body). */
export const MOCK_AUTHOR = { git_name: 'FirstName LastName', git_email: 'member@example.com', author_source: 'signin' }

/** A save carrying this marker is refused as the hub's secret gate would (422). */
export const MOCK_REJECT = 'MOCK-SECRET'

const title = (md, path) => (/^#\s+(.+?)\s*$/m.exec(md) || [])[1] || path.split('/').pop()

/** A stable 40-hex fake blob sha per path. */
function fakeBlob(path) {
  let h = 2166136261
  for (const c of path) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0
  return h.toString(16).padStart(8, '0').repeat(5)
}

const overlays = new Map()
let consented = false
let seq = 0

/** The body the hub would answer for GET /v1/docs/<path>, null for a 404. */
export function mockDocs(path) {
  if (path === 'tree.json') {
    return JSON.stringify({ v: 1, files: Object.entries(DOCS).map(([p, md]) => ({ path: p, title: title(md, p), blob: fakeBlob(p), editable: !DENIED.has(p), ...(overlays.has(p) ? { overlay: true } : {}) })) })
  }
  if (overlays.has(path)) return overlays.get(path)
  return Object.prototype.hasOwnProperty.call(DOCS, path) ? DOCS[path] : null
}

/** The X-Spool-Doc-Base the hub sends with a doc. */
export function mockDocBase(path) {
  return Object.prototype.hasOwnProperty.call(DOCS, path) ? fakeBlob(path) : ''
}

/** PUT /v1/docs/<path> with If-Match: { status, body }. */
export function mockRepoSave(path, text, ifMatch) {
  if (!Object.prototype.hasOwnProperty.call(DOCS, path) || DENIED.has(path)) return { status: 403, body: { error: 'path_denied', detail: 'denied' } }
  if (String(ifMatch ?? '').replace(/"/g, '') !== fakeBlob(path)) return { status: 409, body: { error: 'base_unknown', detail: 'base' } }
  const at = String(text).split('\n').findIndex((l) => l.includes(MOCK_REJECT))
  if (at >= 0) return { status: 422, body: { error: 'rejected_text', detail: 'secret', hits: [{ kind: 'secret', rule: 'private key', line: at + 1 }] } }
  if (!consented) return { status: 428, body: { error: 'author_notice_required', detail: 'consent', ...MOCK_AUTHOR } }
  overlays.set(path, String(text))
  return { status: 200, body: { edit_id: 'mock-edit-' + (++seq), status: 'queued', path, base: fakeBlob(path), superseded: [], author: MOCK_AUTHOR } }
}

/** POST /v1/docs/author-notice: 204, or 409 author_changed for another identity. */
export function mockAuthorNotice(body) {
  if (!body || body.git_name !== MOCK_AUTHOR.git_name || body.git_email !== MOCK_AUTHOR.git_email) return { status: 409, body: { error: 'author_changed', ...MOCK_AUTHOR } }
  consented = true
  return { status: 204, body: null }
}

/** Tests: back to no overlay and no consent. */
export function mockRepoReset() {
  overlays.clear()
  consented = false
  seq = 0
}
