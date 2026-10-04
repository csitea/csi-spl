/**
 * Workspace docs (spec 075 Phase 2, T010; owner, prd t1 9f0d751c): the
 * workspace's own markdown, kept in its docs bucket and read and written
 * through the hub, GET / PUT / DELETE /v1/workspace/docs/<path> and
 * GET /v1/workspace/docs/tree.json. A doc's page is /docs/ws/<path>; the repo
 * docs (Phase 1) stay read-only at /docs/<repo path>.
 * Save is last write wins: the hub keeps every overwritten version under
 * .history/, so there is no lock and no conflict dialog.
 * Node tests import this file.
 */

import { validDocsPath } from './docs.mjs'

/** The route prefix of a workspace doc under /docs. */
export const WS_PREFIX = 'ws/'

/** The permission that writes workspace docs (hub rbac, spec 075 §2). */
export const DOCS_WRITE = 'docs.write'

/** The in-app route of a workspace doc. */
export function wsDocsRoute(path) {
  return '/docs/' + WS_PREFIX + path
}

/** The workspace doc path of a /docs route path ('ws/a/b.md' -> 'a/b.md'), '' when it is a repo doc. */
export function wsPathOf(docsPath) {
  const s = String(docsPath || '')
  return s.startsWith(WS_PREFIX) ? s.slice(WS_PREFIX.length) : ''
}

/**
 * What a member types as the new doc's path, made a doc path: trimmed,
 * spaces to dashes, no leading slash, '.md' added. '' when it still is not
 * one the hub would take (validDocsPath).
 */
export function newDocPath(raw) {
  let s = String(raw ?? '').trim().replace(/\s+/g, '-').replace(/^\/+/, '')
  if (!s) return ''
  s = /\.md$/i.test(s) ? s.replace(/\.md$/i, '.md') : s + '.md'
  return validDocsPath(s) ? s : ''
}

/** The starter body of a new doc: a # heading named after the file. */
export function newDocBody(path) {
  const name = String(path || '').split('/').pop().replace(/\.md$/, '')
  return '# ' + (name || 'Untitled') + '\n\n'
}

/**
 * The files of a workspace tree.json body: { files: [{ path, title }] } as
 * the repo catalogue, or a bare array of those or of paths. Anything else is
 * an empty tree.
 */
export function wsTreeFiles(body) {
  const list = Array.isArray(body) ? body : body && typeof body === 'object' && Array.isArray(body.files) ? body.files : []
  const out = []
  for (const f of list) {
    const path = typeof f === 'string' ? f : f && typeof f.path === 'string' ? f.path : ''
    if (!validDocsPath(path)) continue
    out.push({ path, title: f && typeof f.title === 'string' && f.title ? f.title : path.split('/').pop() })
  }
  return out
}

/**
 * Whether the reader may edit workspace docs (spec 075 §2: signed-in members
 * and agents, not guests or demo users). The hub's docs.write check is the
 * control; this only hides Edit. No answer from /v1/view/me (old hub, the
 * mock) shows it, as accessAllows does; a guest (no human) or a permission
 * list without docs.write hides it.
 * @param {{ humanId?: string|null, permissions?: string[]|null } | null} me normalizeMe() output
 */
export function canWriteDocs(me) {
  if (!me) return true
  if (!me.humanId) return false
  if (!Array.isArray(me.permissions)) return true
  return me.permissions.includes(DOCS_WRITE)
}
