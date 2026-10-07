/**
 * The mock tenant's Docs (NUXT_PUBLIC_USE_MOCK): a few repo-shaped docs, so
 * the section and its e2e run without a hub. Loaded lazily by the docs page.
 * Repo-edit (spec 075 T11): tree.json flags each doc editable, as the hub
 * does with editing on (how-to-post sits under the csi-spl-doc/doc/help/**
 * deny glob, so it is not), and mockRepoSave / mockAuthorNotice answer the
 * PUT and the consent the way the hub does: 428 until the member consents,
 * then the overlay serves the saved text.
 * T12: mockRepoEdits / mockRepoRetry / mockRepoConflict answer the edits
 * routes; each edits read is one worker tick (queued -> pushing -> pushed,
 * or conflict / failed for a text carrying MOCK_CONFLICT / MOCK_FAIL), and
 * one agent edit for the mock member starts failed, for My edits' retry.
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

/** A save carrying this marker meets a real line conflict on master (T12). */
export const MOCK_CONFLICT = 'MOCK-CONFLICT'

/** A save carrying this marker fails its first push (T12). */
export const MOCK_FAIL = 'MOCK-FAIL'

/** The mock viewer (spool-client's mock me). */
const ME = 'HUM-1'

/** The agent edit My edits starts with: failed, retried on demand. */
export const MOCK_AGENT_EDIT = 'mock-edit-agent-1'
const AGENT_PATH = 'csi-spl-doc/specs/072-rapid-deployability/spec.md'

const overlays = new Map()
let consented = false
let seq = 0
/** The queue, newest first: the hub's repo_doc_edits for this workspace. */
let edits = []

function seedEdits() {
  edits = [{ edit_id: MOCK_AGENT_EDIT, path: AGENT_PATH, status: 'failed', human_id: ME, actor_kind: 'agent', agent_id: 'c-101', text: '', failed: true, commit_sha: '', last_error: 'github: 503 service unavailable', created_at: '2026-10-07T08:00:00Z' }]
}
seedEdits()

/** The master blob a conflict is resolved against. */
const headBlob = (path) => fakeBlob(path + '@head')

/** One step of the mock worker on every edit it still owes a push. */
function tick() {
  for (const e of edits) {
    if (e.status === 'queued') e.status = 'pushing'
    else if (e.status === 'pushing') {
      if (e.text.includes(MOCK_CONFLICT)) {
        e.status = 'conflict'
        e.last_error = 'master changed the same lines'
      } else if (e.text.includes(MOCK_FAIL) && !e.failed) {
        e.status = 'failed'
        e.failed = true
        e.last_error = 'github: 503 service unavailable'
      } else {
        e.status = 'pushed'
        e.commit_sha = fakeBlob(e.edit_id)
        e.last_error = ''
      }
    }
  }
}

const view = (e) => ({ edit_id: e.edit_id, path: e.path, status: e.status, human_id: e.human_id, actor_kind: e.actor_kind, ...(e.agent_id ? { agent_id: e.agent_id } : {}), base: fakeBlob(e.path), git_name: MOCK_AUTHOR.git_name, git_email: MOCK_AUTHOR.git_email, author_source: MOCK_AUTHOR.author_source, tries: 0, ...(e.last_error ? { last_error: e.last_error } : {}), ...(e.commit_sha ? { commit_sha: e.commit_sha } : {}), created_at: e.created_at, updated_at: e.created_at })

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
  const im = String(ifMatch ?? '').replace(/"/g, '')
  const resolving = edits.some((e) => e.path === path && e.status === 'conflict') && im === headBlob(path)
  if (im !== fakeBlob(path) && !resolving) return { status: 409, body: { error: 'base_unknown', detail: 'base' } }
  const at = String(text).split('\n').findIndex((l) => l.includes(MOCK_REJECT))
  if (at >= 0) return { status: 422, body: { error: 'rejected_text', detail: 'secret', hits: [{ kind: 'secret', rule: 'private key', line: at + 1 }] } }
  if (!consented) return { status: 428, body: { error: 'author_notice_required', detail: 'consent', ...MOCK_AUTHOR } }
  overlays.set(path, String(text))
  const id = 'mock-edit-' + (++seq)
  /* the author's queued rows fold into this save; their conflict rows are resolved by it */
  const superseded = []
  for (const e of edits) {
    if (e.path === path && e.human_id === ME && e.actor_kind === 'member' && (e.status === 'queued' || e.status === 'conflict')) {
      e.status = 'superseded'
      superseded.push(e.edit_id)
    }
  }
  edits.unshift({ edit_id: id, path, status: 'queued', human_id: ME, actor_kind: 'member', agent_id: '', text: String(text), failed: false, commit_sha: '', last_error: '', created_at: new Date(Date.UTC(2026, 9, 7, 9, 0, seq)).toISOString() })
  return { status: 200, body: { edit_id: id, status: 'queued', path, base: resolving ? headBlob(path) : fakeBlob(path), superseded, author: MOCK_AUTHOR } }
}

/** POST /v1/docs/author-notice: 204, or 409 author_changed for another identity. */
export function mockAuthorNotice(body) {
  if (!body || body.git_name !== MOCK_AUTHOR.git_name || body.git_email !== MOCK_AUTHOR.git_email) return { status: 409, body: { error: 'author_changed', ...MOCK_AUTHOR } }
  consented = true
  return { status: 204, body: null }
}

/** GET /v1/docs/edits?mine=1|path=: one worker tick, then the rows newest first. */
export function mockRepoEdits(q) {
  if (!q || (!q.mine && !q.path)) return { status: 400, body: { error: 'bad_request', detail: 'name mine=1 or path=<doc>' } }
  tick()
  const rows = edits.filter((e) => (q.path ? e.path === q.path : true) && (q.mine ? e.human_id === ME : true))
  return { status: 200, body: { edits: rows.map(view) } }
}

/** POST /v1/docs/edits/{id}/retry: a failed edit back to the queue (202). */
export function mockRepoRetry(id) {
  const e = edits.find((x) => x.edit_id === id)
  if (!e) return { status: 404, body: { error: 'not_found', detail: 'no such edit' } }
  if (e.status !== 'failed') return { status: 409, body: { error: 'not_failed', detail: 'this one is ' + e.status } }
  e.status = 'queued'
  e.last_error = ''
  return { status: 202, body: view(e) }
}

/** GET /v1/docs/edits/{id}/conflict: {base, theirs, mine} of a conflict. */
export function mockRepoConflict(id) {
  const e = edits.find((x) => x.edit_id === id)
  if (!e) return { status: 404, body: { error: 'not_found', detail: 'no such edit' } }
  if (e.status !== 'conflict') return { status: 409, body: { error: 'not_conflict', detail: 'this edit is ' + e.status } }
  const base = DOCS[e.path] ?? ''
  return { status: 200, body: { edit_id: e.edit_id, path: e.path, base, theirs: base + '\nChanged on master meanwhile.\n', mine: e.text, base_blob: fakeBlob(e.path), head_blob: headBlob(e.path), head_commit: fakeBlob('head:' + e.path), reason: e.last_error } }
}

/** Tests: back to no overlay, no consent and the seeded queue. */
export function mockRepoReset() {
  overlays.clear()
  consented = false
  seq = 0
  seedEdits()
}
