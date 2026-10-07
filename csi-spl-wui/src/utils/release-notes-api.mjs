/**
 * The release notes API (spec 065 7.2) as the WUI reads it: the version
 * card's dialog (ReleaseNotesDialog.vue) and the small card under a message
 * that links a release note (LinkPreviews.vue, owner t1 a1bce52e).
 *
 * GET /v1/release-notes?limit=N[&before=<version>] -> { versions, next_before }
 * GET /v1/release-notes/<sha|vX.Y.Z>   -> { note } or one version
 *
 * The mock tenant answers from a generated list: 70 versions, two commits
 * each, every state; the running version is the newest.
 *
 * Loaded lazily with either component, never on the first paint.
 */

import { isoSeconds } from './iso-seconds.mjs'

export const RELEASE_NOTES_LATEST = 30
const VERSION_RE = /^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$/

/**
 * One GET as the reader. Throws { status } on a non-2xx answer.
 * @param {{ mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }} api useSpoolApi()
 * @param {string} path
 * @param {string} running the running build's version (the mock's newest)
 */
export async function releaseNotesGet(api, path, running) {
  if (api.mock) return mockReleaseNotes(path, running)
  /** @type {Record<string, string>} */
  const headers = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const r = await fetch(`${api.base}${path}`, { credentials: api.credentials, headers })
  if (!r.ok) throw Object.assign(new Error(`release notes ${r.status}`), { status: r.status })
  return r.json()
}

/**
 * The preview card of each release ref (`release:<ref>` ids), in the shape
 * of POST /v1/view/previews: { previews: [{ id, kind, title, excerpt, ts, meta }] }.
 * A ref with no note (unknown, a version, an error) has no card.
 * @param {string[]} ids `release:<sha>` ids
 * @param {(path: string) => Promise<unknown>} get releaseNotesGet bound to the api
 */
export async function releasePreviews(ids, get) {
  const out = await Promise.all((ids || []).map(async (id) => {
    const ref = String(id || '').replace(/^release:/, '')
    if (!ref) return null
    try {
      const body = /** @type {{ note?: Record<string, unknown> }} */ (await get(`/v1/release-notes/${encodeURIComponent(ref)}`))
      const n = body && body.note
      if (!n || typeof n !== 'object') return null
      const title = String(n.subject || n.sha || ref).slice(0, 100)
      return {
        id,
        kind: 'release',
        title,
        excerpt: String(n.lay_what || n.tech_what || ''),
        ts: String(n.committed_at || ''),
        meta: [String(n.version || '').replace(/-c[0-9]+$/, ''), String(n.sha || ref).slice(0, 8)].filter(Boolean).join(' · '),
      }
    } catch {
      return null
    }
  }))
  return { previews: out.filter(Boolean) }
}

/**
 * One more page appended to the versions already loaded (owner, t1 ee8cd6f2:
 * "loading of older version up till the first entry"). A note seen before
 * is never shown twice; a version split across two pages is one group.
 * @param {{ version: string, notes?: { sha: string }[] }[]} have newest first
 * @param {{ version: string, notes?: { sha: string }[] }[]} page the next, older page
 */
export function mergeReleasePages(have, page) {
  const out = (have || []).map((v) => ({ ...v, notes: [...(v.notes || [])] }))
  const seen = new Set(out.flatMap((v) => v.notes.map((n) => n.sha)))
  for (const v of page || []) {
    const notes = (v.notes || []).filter((n) => n && n.sha && !seen.has(n.sha))
    notes.forEach((n) => seen.add(n.sha))
    const last = out[out.length - 1]
    if (last && last.version === v.version) last.notes.push(...notes)
    else if (notes.length) out.push({ ...v, notes })
  }
  return out
}

/**
 * The cursor after a page: the hub's next_before, '' at the end - an empty
 * page, no cursor, or the same cursor again (never ask for one page twice).
 * @param {{ versions?: unknown[], next_before?: string } | null | undefined} body
 * @param {string} prev the cursor this page was asked with
 */
export function nextReleaseCursor(body, prev) {
  const next = String(body?.next_before || '')
  if (!body?.versions?.length || !next || next === prev) return ''
  return next
}

/** How many changes the versions carry. */
export function releaseNoteCount(versions) {
  return (versions || []).reduce((n, v) => n + (v.notes?.length || 0), 0)
}

const KEY_TYPING = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="combobox"]'

/**
 * What one keydown means in the open release notes dialog (owner, t1
 * ee8cd6f2: "vim like hjkl ... between each of the version .. on the
 * Desktop"; "double esc is better"). j / k: next / previous version in the
 * list; Enter on a version: open it; h / l in an opened version: the older /
 * newer one; Escape in an opened version: back to the list (in the list it
 * stays the dialog's own: close). Desktop, the switch on, never while typing
 * or with a modifier.
 * @param {{ key?: string, ctrlKey?: boolean, metaKey?: boolean, altKey?: boolean, shiftKey?: boolean,
 *           isComposing?: boolean, defaultPrevented?: boolean, target?: unknown } | null | undefined} ev
 * @param {{ enabled?: boolean, view?: 'list' | 'version' | 'note', onVersion?: boolean }} [ctx]
 * @returns {{ type: 'step', step: 1 | -1 } | { type: 'open' } | { type: 'turn', step: 1 | -1 } | { type: 'back' } | null}
 */
export function releaseKeyFor(ev, { enabled = true, view = 'list', onVersion = false } = {}) {
  if (!ev || ev.isComposing || ev.defaultPrevented || !enabled) return null
  if (ev.key === 'Escape') return view === 'version' ? { type: 'back' } : null
  if (ev.ctrlKey || ev.metaKey || ev.altKey || ev.shiftKey || view === 'note') return null
  const t = /** @type {{ closest?: (s: string) => unknown, isContentEditable?: boolean } | null} */ (ev.target || null)
  if (t && (t.isContentEditable || (typeof t.closest === 'function' && t.closest(KEY_TYPING)))) return null
  const k = String(ev.key || '')
  if (k === 'j' || k === 'k') return { type: 'step', step: k === 'j' ? 1 : -1 }
  if (view === 'list' && k === 'Enter' && onVersion) return { type: 'open' }
  if (view === 'version' && (k === 'h' || k === 'l')) return { type: 'turn', step: k === 'h' ? 1 : -1 }
  return null
}

const MOCK_VERSIONS = 70
const MOCK_STATES = ['ok', 'backfill', 'missing', 'ok', 'skip', 'revert']
const MOCK_KINDS = ['feat', 'fix', 'perf', 'docs']
const MOCK_AREAS = ['wui', 'hub', 'orc', 'iac']
const MOCK_NEWEST_AT = Date.UTC(2026, 9, 3, 10, 14)

function mockNote(j, version) {
  const state = MOCK_STATES[j % MOCK_STATES.length]
  const area = MOCK_AREAS[j % MOCK_AREAS.length]
  const full = state === 'ok' || state === 'backfill'
  return {
    sha: (j + 1).toString(16).padStart(8, '0').repeat(5),
    version,
    kind: MOCK_KINDS[j % MOCK_KINDS.length],
    area,
    subject: `mock change ${j + 1}: the ${area} does a thing better`,
    lay_what: state === 'missing' ? '' : `Change number ${j + 1} makes something easier to use.`,
    lay_how: full ? 'The app now does the step for you.' : '',
    lay_why: state === 'missing' ? '' : 'You had to do it by hand before.',
    tech_what: full ? `Mock module ${j + 1} handles the case.` : '',
    tech_how: full ? 'One function call replaces three.' : '',
    tech_why: full ? 'The old path skipped the check.' : '',
    state,
    link: '',
    /* newest first, 47 min apart: a time to show in the list */
    committed_at: isoSeconds(new Date(MOCK_NEWEST_AT - j * 47 * 60000)),
    seq: MOCK_VERSIONS * 2 - j,
  }
}

function mockVersions(top) {
  const out = []
  for (let i = 0; i < MOCK_VERSIONS; i++) {
    const version = i === 0 && VERSION_RE.test(top) ? top : `v0.1.${MOCK_VERSIONS - i}`
    out.push({ version, notes: [mockNote(i * 2, version), mockNote(i * 2 + 1, version)] })
  }
  return out
}

/** The mock tenant's answer to one release notes GET. */
export function mockReleaseNotes(path, top) {
  const rows = mockVersions(top)
  const u = new URL(path, 'http://mock.invalid')
  const want = decodeURIComponent(u.pathname.replace(/^\/v1\/release-notes\/?/, ''))
  if (!want) {
    const before = u.searchParams.get('before') || ''
    const limit = Number(u.searchParams.get('limit')) || RELEASE_NOTES_LATEST
    const from = before ? rows.findIndex((v) => v.version === before) + 1 : 0
    const page = rows.slice(from, from + limit)
    return { versions: page, next_before: from + limit < rows.length ? page[page.length - 1]?.version || '' : '' }
  }
  if (VERSION_RE.test(want)) {
    const v = rows.find((x) => x.version === want)
    if (v) return v
  } else {
    const hits = rows.flatMap((v) => v.notes).filter((n) => n.sha.startsWith(want))
    if (hits.length === 1) return { note: hits[0] }
  }
  throw Object.assign(new Error('not found'), { status: 404 })
}
