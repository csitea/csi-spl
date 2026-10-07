/**
 * Editable Repo Docs, the WUI side (spec 075 repo-edit §4.2, §10; task T11).
 * A repo doc the hub's tree.json marks `editable` shows Edit to a member who
 * holds docs.write. Save PUTs /v1/docs/<path> with If-Match: the blob the
 * editor opened (the GET's X-Spool-Doc-Base, else tree.json's blob). The
 * first save under a published identity answers 428 author_notice_required:
 * the WUI shows the notice, POSTs /v1/docs/author-notice and saves again.
 * Loaded only by the docs page, never by the first screen. Node tests
 * import this file.
 */

import { validDocsPath } from './docs.mjs'

/** A git blob sha, as the hub takes it in If-Match. */
const BLOB_RE = /^[0-9a-f]{40}$/

/**
 * path -> { editable, blob, overlay } out of tree.json's files. A file the
 * hub did not flag is not editable (editing off, an older hub).
 */
export function repoEditFiles(files) {
  const out = new Map()
  for (const f of Array.isArray(files) ? files : []) {
    if (!f || !validDocsPath(f.path)) continue
    out.set(f.path, {
      editable: f.editable === true,
      blob: typeof f.blob === 'string' && BLOB_RE.test(f.blob) ? f.blob : '',
      overlay: f.overlay === true,
    })
  }
  return out
}

/** The If-Match value of a save: the opened blob quoted, '' for a doc not published yet. */
export function ifMatchOf(base) {
  const b = String(base ?? '').trim().toLowerCase().replace(/^w\//, '').replace(/"/g, '')
  return BLOB_RE.test(b) ? `"${b}"` : ''
}

/**
 * The identity a 428 names, or null when the body is not one: the notice
 * shows exactly this and the consent sends it back unchanged.
 */
export function noticeIdentity(body) {
  if (!body || typeof body !== 'object') return null
  const name = typeof body.git_name === 'string' ? body.git_name : ''
  const email = typeof body.git_email === 'string' ? body.git_email : ''
  if (!name || !email) return null
  return { git_name: name, git_email: email, author_source: typeof body.author_source === 'string' ? body.author_source : '' }
}

/**
 * The message a refused save shows: { key, params } under docs.repoEdit.
 * 409 base unknown (the doc changed since it was opened), 413 too large,
 * 422 rejected text (the first hit's rule and line), 429 rate limited,
 * 403 by reason, 404 editing off; anything else a generic failure.
 */
export function saveErrorOf(status, body) {
  const reason = body && typeof body.error === 'string' ? body.error : ''
  switch (status) {
    case 409: return { key: 'docs.repoEdit.err.conflict', params: {} }
    case 413: return { key: 'docs.repoEdit.err.too_large', params: {} }
    case 422: {
      const hit = Array.isArray(body?.hits) ? body.hits[0] : null
      if (hit && typeof hit.rule === 'string' && Number(hit.line) > 0) {
        return { key: 'docs.repoEdit.err.rejected_line', params: { rule: hit.rule, line: Number(hit.line) } }
      }
      return { key: 'docs.repoEdit.err.rejected', params: {} }
    }
    case 429: return { key: 'docs.repoEdit.err.rate_limited', params: {} }
    case 403:
      if (reason === 'path_denied') return { key: 'docs.repoEdit.err.path_denied', params: {} }
      if (reason === 'email_unverified') return { key: 'docs.repoEdit.err.email_unverified', params: {} }
      if (reason === 'member_too_new') return { key: 'docs.repoEdit.err.member_too_new', params: {} }
      if (reason === 'workspace_blocked') return { key: 'docs.repoEdit.err.workspace_blocked', params: {} }
      return { key: 'docs.repoEdit.err.forbidden', params: {} }
    case 404: return { key: 'docs.repoEdit.err.off', params: {} }
    default: return { key: 'docs.repoEdit.err.failed', params: {} }
  }
}
