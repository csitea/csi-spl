// csi-spl-wui/src/utils/reporting-releases.ts
//
// The Releases tab of the Reporting section (spec 143 2.2, T022-T024) as the
// WUI reads it:
//
//   GET /v1/reporting/releases/daily?from&to&kind&area
//       -> { days: [{ date, commits_count, kinds, areas, deploys }], total_commits, total_versions }
//   GET /v1/reporting/releases/commits?from&to&kind&area&search&limit&offset
//       -> { total, limit, offset, notes }
//
// The deploys come from estate_deploys, empty until spec 143 row 4 records
// them: a day without one shows "not recorded", never an error.
// The mock tenant answers from a generated estate: two commits an hour, a
// dev + prd deploy on every other day. Loaded with the Releases page only.

import { HUB_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { isoSeconds } from '~/utils/iso-seconds.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

export type ReleaseDeploy = { env: string, component: string, version: string, commit_sha?: string, deployed_at: string, status: string, source?: string }
export type ReleaseDay = { date: string, commits_count: number, kinds: Record<string, number>, areas: Record<string, number>, deploys: ReleaseDeploy[] }
export type ReleaseDaily = { days: ReleaseDay[], total_commits: number, total_versions: number }
export type ReleaseCommit = {
  sha: string, version?: string, committed_at: string, kind: string, area: string, subject: string,
  lay_what: string, lay_how: string, lay_why: string, tech_what: string, tech_how: string, tech_why: string,
  state: string, link?: string,
}
export type ReleaseCommits = { total: number, limit: number, offset: number, notes: ReleaseCommit[] }
export type ReleaseSummary = { releases: number | null, commits: number | null, perDay: number | null, dev: number | null, prd: number | null }
export type ReleaseQuery = { from: string, to: string, kinds?: readonly string[], areas?: readonly string[], search?: string, limit?: number, offset?: number }
export type DeployChip = { env: string, component: string, version: string, time: string, failed: boolean }
type ReportApi = Parameters<typeof withSessionRetry>[0] & { mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }

/** The range pills in display order, and the default. */
export const RELEASE_RANGES = Object.freeze(['today', '7d', '30d', '90d'] as const)
export type ReleaseRange = typeof RELEASE_RANGES[number]
export const RELEASE_RANGE_DEFAULT: ReleaseRange = '7d'
const RANGE_DAYS: Record<ReleaseRange, number> = { today: 1, '7d': 7, '30d': 30, '90d': 90 }

/** The kind and area pills (spec 143 2.2). */
export const RELEASE_KINDS = Object.freeze(['feat', 'fix', 'docs', 'chore', 'perf', 'refactor', 'ci', 'test'])
export const RELEASE_AREAS = Object.freeze(['orc', 'api', 'wui', 'iac', 'cnf', 'doc', 'rdb'])

/** Commits one page asks for (the hub's max is 200). */
export const RELEASE_PAGE = 100
/** How long the search box waits after the last key before it filters. */
export const RELEASE_SEARCH_DEBOUNCE_MS = 300

const DAY_MS = 86400000
const isoS = (ms: number): string => isoSeconds(new Date(ms))

/**
 * The window of a range pill: from the UTC midnight that starts its first
 * day to now (a second past, so a commit of this second is in). Today is one
 * day; 7d is today and the six days before it.
 */
export function releaseWindow(range: string, now: number): { from: string, to: string, days: number } {
  const days = RANGE_DAYS[range as ReleaseRange] || RANGE_DAYS[RELEASE_RANGE_DEFAULT]
  const start = Math.floor(now / DAY_MS) * DAY_MS - (days - 1) * DAY_MS
  return { from: isoS(start), to: isoS(now + 1000), days }
}

/** The query string of one report read. */
export function releaseQuery(q: ReleaseQuery): string {
  const p = new URLSearchParams({ from: q.from, to: q.to })
  if (q.kinds?.length) p.set('kind', q.kinds.join(','))
  if (q.areas?.length) p.set('area', q.areas.join(','))
  if (q.search?.trim()) p.set('search', q.search.trim())
  if (q.limit) p.set('limit', String(q.limit))
  if (q.offset) p.set('offset', String(q.offset))
  return '?' + p.toString()
}

/** One pill toggled in or out of a selection, in the pills' order. */
export function togglePill(all: readonly string[], picked: readonly string[], id: string): string[] {
  const on = new Set(picked)
  if (on.has(id)) on.delete(id)
  else on.add(id)
  return all.filter((x) => on.has(x))
}

/** The size steps of the label cloud: 0 is a label no commit carries, 5 the most used. */
export const LABEL_CLOUD_STEPS = 5

/** How many commits of the daily answer carry each kind or area label. */
export function labelCounts(days: readonly ReleaseDay[] | undefined, field: 'kinds' | 'areas'): Record<string, number> {
  const out: Record<string, number> = {}
  for (const d of days || []) {
    for (const [k, n] of Object.entries(d?.[field] || {})) {
      if (typeof n === 'number' && n > 0) out[k] = (out[k] || 0) + n
    }
  }
  return out
}

/**
 * The label cloud of one pill row (owner, t1 58c4aa4b): each label sized by
 * how many commits carry it, the most used in the centre and the next ones
 * placed right, left, right ... of it. A step grows with the square root of
 * the label's share of the top one, so a rare label stays readable; ties
 * keep the pills' order.
 */
export function labelCloud(all: readonly string[], counts: Record<string, number> | undefined): { id: string, n: number, step: number }[] {
  const max = Math.max(0, ...all.map((id) => counts?.[id] || 0))
  const ranked = all
    .map((id, i) => {
      const n = counts?.[id] || 0
      return { id, n, i, step: n > 0 ? Math.max(1, Math.ceil(LABEL_CLOUD_STEPS * Math.sqrt(n / max))) : 0 }
    })
    .sort((a, b) => b.n - a.n || a.i - b.i)
  const out: { id: string, n: number, step: number }[] = []
  ranked.forEach(({ id, n, step }, r) => {
    if (r % 2) out.push({ id, n, step })
    else out.unshift({ id, n, step })
  })
  return out
}

/** A release key as a reader sees it: v1.0.1-c2 -> v1.0.1. */
export function displayVersion(v: unknown): string {
  return String(v || '').replace(/-c[0-9]+$/, '')
}

const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null)

/**
 * The KPI strip of a daily answer. A figure the answer lacks is null, so the
 * card shows a dash, never NaN or a false 0.
 */
export function releaseSummary(daily: unknown, days: number): ReleaseSummary {
  const d = daily as Partial<ReleaseDaily> | null | undefined
  if (!d || typeof d !== 'object' || !Array.isArray(d.days)) return { releases: null, commits: null, perDay: null, dev: null, prd: null }
  const commits = num(d.total_commits)
  const deploys = d.days.flatMap((x) => (Array.isArray(x?.deploys) ? x.deploys : []))
  return {
    releases: num(d.total_versions),
    commits,
    perDay: commits === null || !(days > 0) ? null : Math.round((commits / days) * 10) / 10,
    dev: deploys.filter((x) => x?.env === 'dev').length,
    prd: deploys.filter((x) => x?.env === 'prd').length,
  }
}

/** A number for a KPI card in the locale's digits; a dash for null. */
export function fmtCount(n: number | null | undefined, locale: string): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  try {
    return new Intl.NumberFormat(locale || 'en', { maximumFractionDigits: 1 }).format(n)
  } catch {
    return String(n)
  }
}

/** The UTC day of an RFC3339 time, YYYY-MM-DD ('' when it is none). */
export function utcDay(iso: unknown): string {
  const ms = Date.parse(String(iso || ''))
  return Number.isFinite(ms) ? new Date(ms).toISOString().slice(0, 10) : ''
}

/**
 * HH:MM of an RFC3339 time in UTC ('' when it is none). A commit row shows
 * its committed_at with it: the git committer time, the closest time the hub
 * stores to the push (the lanes rebase right before they push); no push time
 * is recorded.
 */
export function utcTime(iso: unknown): string {
  const ms = Date.parse(String(iso || ''))
  return Number.isFinite(ms) ? new Date(ms).toISOString().slice(11, 16) : ''
}

const byTimeDesc = (a: ReleaseCommit, b: ReleaseCommit) =>
  Date.parse(b.committed_at) - Date.parse(a.committed_at) || a.sha.localeCompare(b.sha)

/**
 * The page's day groups: every day of the daily answer, newest first, each
 * with its loaded commits, newest first. A loaded commit whose day the daily
 * answer lacks still gets its day.
 */
export function releaseDayGroups(days: readonly ReleaseDay[] | undefined, notes: readonly ReleaseCommit[] | undefined): { day: ReleaseDay, notes: ReleaseCommit[] }[] {
  const by = new Map<string, { day: ReleaseDay, notes: ReleaseCommit[] }>()
  for (const d of days || []) by.set(d.date, { day: d, notes: [] })
  for (const n of notes || []) {
    const date = utcDay(n?.committed_at)
    if (!date) continue
    let g = by.get(date)
    if (!g) {
      g = { day: { date, commits_count: 0, kinds: {}, areas: {}, deploys: [] }, notes: [] }
      by.set(date, g)
    }
    g.notes.push(n)
  }
  const out = [...by.values()].sort((a, b) => (a.day.date < b.day.date ? 1 : a.day.date > b.day.date ? -1 : 0))
  for (const g of out) g.notes.sort(byTimeDesc)
  return out
}

/** One page of commits added to the ones loaded, a sha never twice. */
export function mergeCommitPages(have: readonly ReleaseCommit[], page: readonly ReleaseCommit[] | undefined): ReleaseCommit[] {
  const seen = new Set(have.map((n) => n.sha))
  return [...have, ...(page || []).filter((n) => n && n.sha && !seen.has(n.sha))]
}

/** The kind pills of a day header: most first, then by name. */
export function kindBreakdown(kinds: Record<string, number> | undefined): { kind: string, n: number }[] {
  return Object.entries(kinds || {})
    .filter(([, n]) => typeof n === 'number' && n > 0)
    .map(([kind, n]) => ({ kind, n }))
    .sort((a, b) => b.n - a.n || a.kind.localeCompare(b.kind))
}

/**
 * The deploy chips of a day: per env and component the newest deploy, prd
 * before dev, each as env, component, plain version and its UTC time.
 */
export function deployChips(deploys: readonly ReleaseDeploy[] | undefined): DeployChip[] {
  const newest = new Map<string, ReleaseDeploy>()
  for (const d of deploys || []) {
    if (!d || !d.env || !d.version) continue
    const key = `${d.env}/${d.component || ''}`
    const have = newest.get(key)
    if (!have || Date.parse(d.deployed_at) > Date.parse(have.deployed_at)) newest.set(key, d)
  }
  const envRank = (e: string) => (e === 'prd' ? 0 : e === 'dev' ? 1 : 2)
  return [...newest.values()]
    .sort((a, b) => envRank(a.env) - envRank(b.env) || String(a.component).localeCompare(String(b.component)))
    .map((d) => ({ env: d.env, component: d.component || '', version: displayVersion(d.version), time: utcTime(d.deployed_at), failed: d.status === 'failed' }))
}

/** Whether a commit carries any Lay-* / Tech-* text to expand. */
export function hasTrailers(n: Partial<ReleaseCommit> | null | undefined): boolean {
  return (['lay_what', 'lay_how', 'lay_why', 'tech_what', 'tech_how', 'tech_why'] as const).some((k) => String(n?.[k] || '').trim() !== '')
}

/**
 * One GET of the report as the reader, behind the view door like the release
 * notes dialog. Throws { status } on a non-2xx answer.
 */
export function releaseReportRead<T>(api: ReportApi, path: string, now = Date.now()): Promise<T> {
  if (api.mock) return Promise.resolve(mockReleaseReport(path, now) as T)
  return withSessionRetry(api, async () => {
    const headers: Record<string, string> = { accept: 'application/json' }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const r = await fetch(`${api.base}${path}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
    if (!r.ok) throw Object.assign(new Error(`releases report ${r.status}`), { status: r.status })
    return r.json() as Promise<T>
  })
}

const MOCK_KINDS = ['feat', 'fix', 'docs', 'refactor', 'fix', 'chore', 'test', 'perf']
const MOCK_AREAS = ['wui', 'api', 'orc', 'doc', 'iac', 'rdb', 'cnf']
const HOUR_MS = 3600000
const MOCK_DAYS = 100

/** The mock estate: a commit every half hour back from the hour, 100 days of them. */
function mockCommits(now: number): ReleaseCommit[] {
  const top = Math.floor(now / HOUR_MS) * HOUR_MS
  const out: ReleaseCommit[] = []
  for (let j = 0; j < MOCK_DAYS * 48; j++) {
    const kind = MOCK_KINDS[j % MOCK_KINDS.length]
    const area = MOCK_AREAS[j % MOCK_AREAS.length]
    const v = 900 - Math.floor(j / 6)
    const bare = j % 5 === 0
    const scope = `${area}, SPL-${2000 + (j % 700)}`
    out.push({
      sha: (j + 1).toString(16).padStart(8, '0').repeat(5),
      version: `v3.${Math.floor(v / 10)}.${v % 10}`,
      committed_at: isoS(top - j * 30 * 60000),
      kind,
      area: scope,
      subject: `${kind}(${scope}): mock change ${j + 1}`,
      lay_what: bare ? '' : `Change number ${j + 1} makes something easier to use.`,
      lay_how: bare ? '' : 'The app now does the step for you.',
      lay_why: bare ? '' : 'You had to do it by hand before.',
      tech_what: bare ? '' : `Mock module ${j + 1} handles the case.`,
      tech_how: bare ? '' : 'One function call replaces three.',
      tech_why: bare ? '' : 'The old path skipped the check.',
      state: bare ? 'missing' : 'ok',
      link: '',
    })
  }
  return out
}

/** A dev deploy, then prd 13 minutes later, at 14:00 UTC of every even day. */
function mockDeploys(from: number, to: number): ReleaseDeploy[] {
  const out: ReleaseDeploy[] = []
  for (let day = Math.floor(from / DAY_MS) * DAY_MS; day < to; day += DAY_MS) {
    if ((day / DAY_MS) % 2) continue
    const version = `v3.${(day / DAY_MS) % 90}.0`
    for (const [env, min] of [['dev', 0], ['prd', 13]] as const) {
      const at = day + 14 * HOUR_MS + min * 60000
      if (at >= from && at < to) out.push({ env, component: 'wui', version, commit_sha: 'f'.repeat(40), deployed_at: isoS(at), status: 'success', source: 'ci' })
    }
  }
  return out.reverse()
}

/** The mock tenant's answer to one report GET, filtered as the hub filters. */
export function mockReleaseReport(path: string, now: number): ReleaseDaily | ReleaseCommits {
  const u = new URL(path, 'http://mock.invalid')
  const q = u.searchParams
  const from = Date.parse(q.get('from') || '') || now - 30 * DAY_MS
  const to = Date.parse(q.get('to') || '') || now
  const kinds = (q.get('kind') || '').split(',').filter(Boolean)
  const areas = (q.get('area') || '').split(',').filter(Boolean)
  const search = (q.get('search') || '').toLowerCase()
  const hit = mockCommits(now).filter((n) => {
    const at = Date.parse(n.committed_at)
    if (at < from || at >= to) return false
    if (kinds.length && !kinds.includes(n.kind)) return false
    if (areas.length && !areas.includes(n.area.split(',')[0])) return false
    if (!search || n.sha.startsWith(search)) return true
    return [n.subject, n.version, n.lay_what, n.lay_how, n.lay_why, n.tech_what, n.tech_how, n.tech_why].join('\n').toLowerCase().includes(search)
  })
  if (u.pathname.endsWith('/commits')) {
    const limit = Number(q.get('limit')) || 50
    const offset = Number(q.get('offset')) || 0
    return { total: hit.length, limit, offset, notes: hit.slice(offset, offset + limit) }
  }
  const by = new Map<string, ReleaseDay>()
  const day = (date: string) => {
    let d = by.get(date)
    if (!d) {
      d = { date, commits_count: 0, kinds: {}, areas: {}, deploys: [] }
      by.set(date, d)
    }
    return d
  }
  for (const n of hit) {
    const d = day(utcDay(n.committed_at))
    const area = n.area.split(',')[0]
    d.commits_count++
    d.kinds[n.kind] = (d.kinds[n.kind] || 0) + 1
    d.areas[area] = (d.areas[area] || 0) + 1
  }
  for (const dp of mockDeploys(from, to)) day(utcDay(dp.deployed_at)).deploys.push(dp)
  return {
    days: [...by.values()].sort((a, b) => (a.date < b.date ? 1 : -1)),
    total_commits: hit.length,
    total_versions: new Set(hit.map((n) => n.version)).size,
  }
}
