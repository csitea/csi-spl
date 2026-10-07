/**
 * The release notes API (spec 065 7.2) as the WUI reads it: the version
 * card's dialog (ReleaseNotesDialog.vue) and the small card under a message
 * that links a release note (LinkPreviews.vue, owner t1 a1bce52e).
 *
 * GET /v1/release-notes?limit=N        -> { versions, next_before }
 * GET /v1/release-notes/<sha|vX.Y.Z>   -> { note } or one version
 *
 * The mock tenant answers from a generated list: 70 versions, two commits
 * each, every state; the running version is the newest.
 *
 * Loaded lazily with either component, never on the first paint.
 */

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

const MOCK_VERSIONS = 70
const MOCK_STATES = ['ok', 'backfill', 'missing', 'ok', 'skip', 'revert']
const MOCK_KINDS = ['feat', 'fix', 'perf', 'docs']
const MOCK_AREAS = ['wui', 'hub', 'orc', 'iac']

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
