// csi-spl-wui/src/utils/reporting-releases.ts
//
// The Releases tab of the Reporting section (spec 143 2.2, T022-T024) as the
// WUI reads it:
//
//   GET /v1/reporting/releases/projects
//       -> { configured, default, projects: [{ slug, name, is_default, repos: [{ slug, web_url, ... }] }] }
//   GET /v1/reporting/releases/daily?project&repo&from&to&kind&area
//       -> { configured, project, repos, days: [{ date, commits_count, kinds, areas, repos, deploys }],
//            total_commits, total_versions, unreleased_commits }
//   GET /v1/reporting/releases/commits?project&repo&from&to&kind&area&search&limit&offset
//       -> { total, limit, offset, notes }
//
// Spec 143 releases-projects.md section 7 (B-7, SPL-5853): the project and
// repo picks live in the URL (?project=<slug>&repo=<org/name>); no param is
// the workspace's default project, a stale one falls back to it.
//
// The deploys come from estate_deploys, empty until spec 143 row 4 records
// them: a day without one shows "not recorded", never an error.
// The mock tenant answers from a generated estate: two commits an hour, a
// dev + prd deploy on every other day. Loaded with the Releases page only.

import { HUB_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { isoSeconds } from '~/utils/iso-seconds.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

export type ReleaseDeploy = { env: string, component: string, version: string, commit_sha?: string, deployed_at: string, status: string, source?: string, repo_slug?: string }
export type ReleaseDay = { date: string, commits_count: number, kinds: Record<string, number>, areas: Record<string, number>, repos?: Record<string, number>, deploys: ReleaseDeploy[] }
export type ReleaseDaily = { days: ReleaseDay[], total_commits: number, total_versions: number, unreleased_commits?: number, configured?: boolean }
export type ReleaseProjectRepo = { slug: string, web_url?: string, commit_path?: string, trunk_branch?: string, sync_status?: string, last_synced_at?: string | null }
export type ReleaseProject = { slug: string, name: string, is_default: boolean, repos: ReleaseProjectRepo[] }
export type ReleaseProjects = { configured: boolean, default: string, projects: ReleaseProject[] }
/** The project and repo a report reads: '' is the default project / every repo. */
export type ReleasePick = { project: string, repo: string }
export type ReleaseCommit = {
  sha: string, version?: string, committed_at: string, kind: string, area: string, subject: string,
  lay_what: string, lay_how: string, lay_why: string, tech_what: string, tech_how: string, tech_why: string,
  state: string, link?: string,
  /* B-5: the repo the commit is in (org/name) */
  repo_slug?: string,
  /* SPL-4789: the issues the message cites, in the workspace that owns them (release-issue-links.mjs) */
  issues?: ReleaseCommitIssue[],
}
export type ReleaseCommitIssue = {
  key: string, tenant: string, found: boolean, member?: boolean,
  discussions: { task_id?: string, title?: string, state?: string, can_open: boolean }[],
}
export type ReleaseCommits = { total: number, limit: number, offset: number, notes: ReleaseCommit[] }
export type ReleaseSummary = { releases: number | null, commits: number | null, perDay: number | null, dev: number | null, prd: number | null, unreleased: number | null }
export type ReleaseQuery = {
  from: string, to: string, kinds?: readonly string[], areas?: readonly string[], search?: string, limit?: number, offset?: number,
  project?: string, repo?: string,
}
export type DeployChip = { env: string, component: string, version: string, time: string, failed: boolean, repo: string }
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
  const p = new URLSearchParams()
  if (q.project) p.set('project', q.project)
  if (q.repo) p.set('repo', q.repo)
  p.set('from', q.from)
  p.set('to', q.to)
  if (q.kinds?.length) p.set('kind', q.kinds.join(','))
  if (q.areas?.length) p.set('area', q.areas.join(','))
  if (q.search?.trim()) p.set('search', q.search.trim())
  if (q.limit) p.set('limit', String(q.limit))
  if (q.offset) p.set('offset', String(q.offset))
  return '?' + p.toString()
}

/** A repo's short name, the part after its org: csitea/csi-spl -> csi-spl. */
export function repoShort(slug: unknown): string {
  const s = String(slug || '')
  return s.slice(s.lastIndexOf('/') + 1)
}

/** A project of the list by slug; '' is the workspace's default. */
export function releaseProjectOf(list: ReleaseProjects | null | undefined, slug: string): ReleaseProject | null {
  const all = list?.projects || []
  const want = slug || list?.default || ''
  return all.find((p) => p.slug === want) || (slug ? null : all[0] || null)
}

const queryValue = (v: unknown): string => (typeof v === 'string' ? v.trim() : '')

/**
 * The pick a URL asks for (?project=&repo=, spec 143 releases-projects 7.2),
 * checked against the projects list: a project the list lacks, or a repo
 * that is not the project's, is stale and falls back to the default. Without
 * a list (its read failed) the URL is taken as it is and the hub's 404 tells.
 * The default project is '' in a pick, so its URL stays clean.
 */
export function releasePickOf(query: Record<string, unknown>, list: ReleaseProjects | null): { pick: ReleasePick, stale: boolean } {
  const project = queryValue(query.project)
  const repo = queryValue(query.repo)
  if (!list) return { pick: { project, repo }, stale: false }
  const p = releaseProjectOf(list, project)
  if (!p) return { pick: { project: '', repo: '' }, stale: true }
  const slug = p.slug === list.default ? '' : p.slug
  if (repo && !p.repos.some((r) => r.slug === repo)) return { pick: { project: slug, repo: '' }, stale: true }
  return { pick: { project: slug, repo }, stale: false }
}

/** The URL query of a pick: the other params kept, project and repo only when set. */
export function releasePickQuery(query: Record<string, unknown>, pick: ReleasePick): Record<string, unknown> {
  const out: Record<string, unknown> = { ...query }
  delete out.project
  delete out.repo
  if (pick.project) out.project = pick.project
  if (pick.repo) out.repo = pick.repo
  return out
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
export function labelCounts(days: readonly ReleaseDay[] | undefined, field: 'kinds' | 'areas' | 'repos'): Record<string, number> {
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
  if (!d || typeof d !== 'object' || !Array.isArray(d.days)) return { releases: null, commits: null, perDay: null, dev: null, prd: null, unreleased: null }
  const commits = num(d.total_commits)
  const deploys = d.days.flatMap((x) => (Array.isArray(x?.deploys) ? x.deploys : []))
  return {
    releases: num(d.total_versions),
    commits,
    perDay: commits === null || !(days > 0) ? null : Math.round((commits / days) * 10) / 10,
    dev: deploys.filter((x) => x?.env === 'dev').length,
    prd: deploys.filter((x) => x?.env === 'prd').length,
    unreleased: num(d.unreleased_commits),
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
    const key = `${d.repo_slug || ''}/${d.env}/${d.component || ''}`
    const have = newest.get(key)
    if (!have || Date.parse(d.deployed_at) > Date.parse(have.deployed_at)) newest.set(key, d)
  }
  const envRank = (e: string) => (e === 'prd' ? 0 : e === 'dev' ? 1 : 2)
  return [...newest.values()]
    .sort((a, b) => envRank(a.env) - envRank(b.env) || String(a.component).localeCompare(String(b.component)))
    .map((d) => ({ env: d.env, component: d.component || '', version: displayVersion(d.version), time: utcTime(d.deployed_at), failed: d.status === 'failed', repo: d.repo_slug || '' }))
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
  if (api.mock) {
    try {
      return Promise.resolve(mockReleaseReport(path, now) as T)
    } catch (e) {
      return Promise.reject(e)
    }
  }
  return withSessionRetry(api, async () => {
    const headers: Record<string, string> = { accept: 'application/json' }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const r = await fetch(`${api.base}${path}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
    if (!r.ok) throw Object.assign(new Error(`releases report ${r.status}`), { status: r.status })
    return r.json() as Promise<T>
  })
}

/** The projects of the workspace (B-5's route); the drop box is loaded from it once. */
export function releaseProjectsRead(api: ReportApi): Promise<ReleaseProjects> {
  return releaseReportRead<ReleaseProjects>(api, '/v1/reporting/releases/projects')
}

const MOCK_KINDS = ['feat', 'fix', 'docs', 'refactor', 'fix', 'chore', 'test', 'perf']
const MOCK_AREAS = ['wui', 'api', 'orc', 'doc', 'iac', 'rdb', 'cnf']
const HOUR_MS = 3600000
const MOCK_DAYS = 100
const MOCK_REPO = 'csitea/csi-spl'
const mockRepo = (slug: string, web: string): ReleaseProjectRepo =>
  ({ slug, web_url: web, commit_path: '/commit/', trunk_branch: 'main', sync_status: 'ok', last_synced_at: null })

/**
 * The mock workspace's projects (B-7: the offline e2e runs only on the mock):
 * the default one with this repo, as the page always showed, and a second
 * with two repos, so the drop box, the repo pills and a switch are testable.
 */
const MOCK_PROJECTS: ReleaseProjects = {
  configured: true,
  default: 'spool',
  projects: [
    { slug: 'spool', name: 'Spool', is_default: true, repos: [mockRepo(MOCK_REPO, 'https://github.com/' + MOCK_REPO)] },
    { slug: 'web-shop', name: 'Web shop', is_default: false, repos: [
      mockRepo('example/web-shop-api', 'https://example.com/example/web-shop-api'),
      mockRepo('example/web-shop-wui', 'https://example.com/example/web-shop-wui'),
    ] },
  ],
}

const SHOP_KINDS = ['fix', 'feat', 'fix', 'test', 'chore', 'fix']
const SHOP_UNRELEASED = 9

/**
 * The second project's commits: one every 90 minutes, a third of them in its
 * wui repo, the newest SHOP_UNRELEASED carrying no version yet. Their kinds
 * lean to fix, so a switch moves the label cloud's counts.
 */
function mockShopCommits(now: number): ReleaseCommit[] {
  const top = Math.floor(now / HOUR_MS) * HOUR_MS
  const out: ReleaseCommit[] = []
  for (let j = 0; j < MOCK_DAYS * 16; j++) {
    const kind = SHOP_KINDS[j % SHOP_KINDS.length]
    const area = MOCK_AREAS[(j * 3) % MOCK_AREAS.length]
    const repo = MOCK_PROJECTS.projects[1].repos[j % 3 === 0 ? 1 : 0].slug
    const v = 500 - Math.floor(j / 4)
    out.push({
      sha: (0x80000000 + j).toString(16).repeat(5),
      version: j < SHOP_UNRELEASED ? '' : `v1.${Math.floor(v / 10)}.${v % 10}`,
      committed_at: isoS(top - j * 90 * 60000),
      kind, area: `${area}, SHOP-${100 + (j % 300)}`,
      subject: `${kind}(${area}): shop change ${j + 1}`,
      lay_what: '', lay_how: '', lay_why: '', tech_what: '', tech_how: '', tech_why: '',
      state: 'skip', link: '', repo_slug: repo, issues: [],
    })
  }
  return out
}

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
      repo_slug: MOCK_REPO,
      issues: mockIssues(j, `SPL-${2000 + (j % 700)}`),
    })
  }
  return out
}

/**
 * The mock commit's issues (SPL-4789), tenant '' = this workspace: every
 * 7th commit is an older one with none ("unknown"), every 11th cites a key
 * with no issue beside its real one, the rest one issue and its discussion.
 */
function mockIssues(j: number, key: string): ReleaseCommitIssue[] {
  if (j % 7 === 3) return []
  const one: ReleaseCommitIssue = { key, tenant: '', found: true, member: true,
    discussions: [{ task_id: `0000${(j % 700).toString(16).padStart(4, '0')}-0000-4000-8000-000000000000`, title: `Mock discussion of ${key}`, state: 'live', can_open: true }] }
  return j % 11 === 5 ? [one, { key: 'SPL-99999', tenant: '', found: false, member: true, discussions: [] }] : [one]
}

/**
 * A dev deploy, then prd 13 minutes later, at 14:00 UTC of every even day,
 * per repo; this repo deploys as wui, another as the tail of its name.
 */
function mockDeploys(from: number, to: number, repos: readonly string[]): ReleaseDeploy[] {
  const out: ReleaseDeploy[] = []
  for (let day = Math.floor(from / DAY_MS) * DAY_MS; day < to; day += DAY_MS) {
    if ((day / DAY_MS) % 2) continue
    const version = `v3.${(day / DAY_MS) % 90}.0`
    for (const repo of repos) {
      const component = repo === MOCK_REPO ? 'wui' : repo.slice(repo.lastIndexOf('-') + 1)
      for (const [env, min] of [['dev', 0], ['prd', 13]] as const) {
        const at = day + 14 * HOUR_MS + min * 60000
        if (at >= from && at < to) out.push({ env, component, version, commit_sha: 'f'.repeat(40), deployed_at: isoS(at), status: 'success', source: 'ci', repo_slug: repo })
      }
    }
  }
  return out.reverse()
}

const notFound = (code: string) => Object.assign(new Error(`releases report 404 ${code}`), { status: 404, code })

/** The project and repos a mock read asks for, as the hub resolves them; 404 on a stale one. */
function mockScope(q: URLSearchParams): { project: ReleaseProject, repos: string[] } {
  const project = releaseProjectOf(MOCK_PROJECTS, q.get('project') || '')
  if (!project) throw notFound('unknown_project')
  const repo = q.get('repo') || ''
  if (repo && !project.repos.some((r) => r.slug === repo)) throw notFound('unknown_repo')
  return { project, repos: repo ? [repo] : project.repos.map((r) => r.slug) }
}

/** The daily answer of the mock's hit commits. */
function mockDaily(hit: readonly ReleaseCommit[], deploys: readonly ReleaseDeploy[]): ReleaseDaily {
  const by = new Map<string, ReleaseDay>()
  const day = (date: string) => {
    let d = by.get(date)
    if (!d) {
      d = { date, commits_count: 0, kinds: {}, areas: {}, repos: {}, deploys: [] }
      by.set(date, d)
    }
    return d
  }
  const bump = (m: Record<string, number>, k: string) => { m[k] = (m[k] || 0) + 1 }
  for (const n of hit) {
    const d = day(utcDay(n.committed_at))
    d.commits_count++
    bump(d.kinds, n.kind)
    bump(d.areas, n.area.split(',')[0])
    bump(d.repos!, n.repo_slug || '')
  }
  for (const dp of deploys) day(utcDay(dp.deployed_at)).deploys.push(dp)
  const versioned = hit.filter((n) => n.version)
  return {
    days: [...by.values()].sort((a, b) => (a.date < b.date ? 1 : -1)),
    total_commits: hit.length,
    total_versions: new Set(versioned.map((n) => `${n.repo_slug}@${n.version}`)).size,
    unreleased_commits: hit.length - versioned.length,
  }
}

/** The mock tenant's answer to one report GET, filtered as the hub filters. */
export function mockReleaseReport(path: string, now: number): ReleaseDaily | ReleaseCommits | ReleaseProjects {
  const u = new URL(path, 'http://mock.invalid')
  if (u.pathname.endsWith('/projects')) return MOCK_PROJECTS
  const q = u.searchParams
  const scope = mockScope(q)
  const from = Date.parse(q.get('from') || '') || now - 30 * DAY_MS
  const to = Date.parse(q.get('to') || '') || now
  const kinds = (q.get('kind') || '').split(',').filter(Boolean)
  const areas = (q.get('area') || '').split(',').filter(Boolean)
  const search = (q.get('search') || '').toLowerCase()
  const all = scope.project.slug === MOCK_PROJECTS.default ? mockCommits(now) : mockShopCommits(now)
  const hit = all.filter((n) => {
    const at = Date.parse(n.committed_at)
    if (at < from || at >= to) return false
    if (!scope.repos.includes(n.repo_slug || '')) return false
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
  return { configured: true, ...mockDaily(hit, mockDeploys(from, to, scope.repos)) }
}
