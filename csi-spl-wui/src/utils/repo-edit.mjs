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

/* ---- T12: the status chip, "My edits", the conflict view (spec §3, §8) ---- */

/** The statuses of a queued edit (spec §10 repo_doc_edits.status). */
export const EDIT_STATUSES = ['queued', 'pushing', 'pushed', 'published', 'conflict', 'failed', 'superseded']

/** A commit sha as the hub reports it. */
const SHA_RE = /^[0-9a-f]{7,40}$/

/** An edit as GET /v1/docs/edits answers it, read leniently; null when it is not one. */
export function editOf(v) {
  if (!v || typeof v !== 'object') return null
  const s = (k) => (typeof v[k] === 'string' ? v[k] : '')
  if (!s('edit_id') || !validDocsPath(s('path')) || !EDIT_STATUSES.includes(s('status'))) return null
  const sha = s('commit_sha').toLowerCase()
  const merged = s('merged_with').toLowerCase()
  return {
    edit_id: s('edit_id'),
    path: s('path'),
    status: s('status'),
    human_id: s('human_id'),
    actor_kind: s('actor_kind') === 'agent' ? 'agent' : 'member',
    agent_id: s('agent_id'),
    commit_sha: SHA_RE.test(sha) ? sha : '',
    merged_with: SHA_RE.test(merged) ? merged : '',
    last_error: s('last_error'),
    created_at: s('created_at'),
  }
}

/** The edits of a GET /v1/docs/edits body, newest first as the hub sends them. */
export function editsOf(body) {
  const rows = body && Array.isArray(body.edits) ? body.edits : []
  return rows.map(editOf).filter(Boolean)
}

/**
 * The chip of spec §3 for one edit: { status, key, sha7, merged7, action },
 * or null for none (published, superseded, no edit). queued and pushing
 * read the same ("Saved · pushing"); action is what the chip offers.
 */
export function chipOf(edit) {
  if (!edit || typeof edit !== 'object') return null
  const sha7 = typeof edit.commit_sha === 'string' ? edit.commit_sha.slice(0, 7) : ''
  const merged7 = typeof edit.merged_with === 'string' ? edit.merged_with.slice(0, 7) : ''
  switch (edit.status) {
    case 'queued':
    case 'pushing': return { status: edit.status, key: 'docs.repoEdit.chip.pushing', sha7: '', merged7: '', action: '' }
    case 'pushed': return { status: 'pushed', key: 'docs.repoEdit.chip.pushed', sha7, merged7, action: '' }
    case 'conflict': return { status: 'conflict', key: 'docs.repoEdit.chip.conflict', sha7: '', merged7: '', action: 'resolve' }
    case 'failed': return { status: 'failed', key: 'docs.repoEdit.chip.failed', sha7: '', merged7: '', action: 'retry' }
    default: return null
  }
}

/** The worker still owes this edit a push: the chip keeps polling. */
export const isPending = (edit) => Boolean(edit) && (edit.status === 'queued' || edit.status === 'pushing')

/**
 * The edit the doc header shows for `path`: the newest of the path's rows
 * (and `last`, the save this page just made, when the rows do not have it
 * yet), skipping superseded rows and another member's conflict (the hub
 * serves a conflict's text only to its editor). me '' = the viewer is
 * unknown: every row counts as theirs.
 */
export function headerEdit(rows, path, me, last) {
  const list = (Array.isArray(rows) ? rows : []).filter((e) => e && e.path === path)
  if (last && last.path === path && last.edit_id && !list.some((e) => e.edit_id === last.edit_id)) list.unshift(last)
  return list.find((e) => e.status !== 'superseded' && !(e.status === 'conflict' && me && e.human_id && e.human_id !== me)) ?? null
}

/**
 * GET /v1/docs/edits/{id}/conflict: { edit_id, path, base, theirs, mine,
 * head_blob, head_commit, reason }, or null. The resolution saves again
 * with If-Match = head_blob ('' when master no longer has the file).
 */
export function conflictOf(body) {
  if (!body || typeof body !== 'object') return null
  const s = (k) => (typeof body[k] === 'string' ? body[k] : '')
  if (!s('edit_id') || !validDocsPath(s('path'))) return null
  const head = s('head_blob').toLowerCase()
  return {
    edit_id: s('edit_id'),
    path: s('path'),
    base: s('base'),
    theirs: s('theirs'),
    mine: s('mine'),
    head_blob: BLOB_RE.test(head) ? head : '',
    head_commit: s('head_commit').toLowerCase(),
    reason: s('reason'),
  }
}

/** The message a refused retry or conflict read shows (docs.repoEdit.err.*). */
export function editActionErrorOf(status, body) {
  const reason = body && typeof body.error === 'string' ? body.error : ''
  if (status === 409 && reason === 'not_failed') return { key: 'docs.repoEdit.err.not_failed', params: {} }
  if (status === 409 && reason === 'not_conflict') return { key: 'docs.repoEdit.err.not_conflict', params: {} }
  if (status === 403) return { key: 'docs.repoEdit.err.not_yours', params: {} }
  if (status === 404) return { key: 'docs.repoEdit.err.no_edit', params: {} }
  return { key: 'docs.repoEdit.err.failed', params: {} }
}
