/**
 * Tenant settings -> Performance (spec 066 section 6 (b), L7): the reader of
 * GET /v1/admin/perf/summary?days=&build=&build_b= (hub perf_summary.go) and
 * the mock build's canned summary. Pure, no Vue: the page and the node test
 * import it; the client's lazy chunk loads it only in a mock build.
 *
 * A row is one (metric, device, view) group: n, p50, p75, p95 in ms, ranked
 * by p75 descending (the hub's order is kept). p95 is null under n = 50 (the
 * hub omits it, section 8). No id, no text: the summary carries none.
 */

export const PERF_DAYS_OPTIONS = [7, 30]
export const PERF_P95_MIN_N = 50
export const PERF_METRICS = ['load_rail', 'load_messages', 'send_ack', 'deliver_visible', 'switch_view', 'type_next_paint', 'inp', 'scroll_jank', 'reconnect_live']
export const PERF_VIEWS = ['topic', 'channel', 'dm', 'flow', 'search']

/* the hub's build token (perf_summary.go perfSummaryBuildRe) */
const BUILD_RE = /^[0-9A-Za-z.+-]{0,40}$/

/** A build token as typed: trimmed, '' when it is not one the hub accepts. */
export function perfBuildOf(v) {
  const s = String(v ?? '').trim()
  return BUILD_RE.test(s) ? s : ''
}

const daysOf = (v) => (PERF_DAYS_OPTIONS.includes(Number(v)) ? Number(v) : 7)

/** The query string of a summary call (empty builds left out). */
export function perfSummaryQuery({ days = 7, build = '', buildB = '' } = {}) {
  const q = new URLSearchParams()
  q.set('days', String(daysOf(days)))
  const a = perfBuildOf(build)
  const b = perfBuildOf(buildB)
  if (a) q.set('build', a)
  if (b) q.set('build_b', b)
  return q.toString()
}

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const count = (v) => (Number.isInteger(v) && v >= 0 ? v : 0)

function normalizeRow(r) {
  if (!r || typeof r !== 'object' || !PERF_METRICS.includes(r.metric)) return null
  const n = count(r.n)
  return {
    metric: r.metric,
    device: r.device === 'phone' ? 'phone' : 'desktop',
    view: PERF_VIEWS.includes(r.view) ? r.view : '',
    n,
    p50: num(r.p50),
    p75: num(r.p75),
    p95: n >= PERF_P95_MIN_N ? num(r.p95) : null,
    failed: count(r.failed),
  }
}

const rowsOf = (v) => (Array.isArray(v) ? v.map(normalizeRow).filter(Boolean) : [])

/** The summary body with safe types; junk reads as an empty summary. */
export function normalizePerfSummary(body) {
  const b = body && typeof body === 'object' ? body : {}
  return {
    off: b.off === true,
    days: daysOf(b.days),
    build: typeof b.build === 'string' ? b.build : '',
    buildB: typeof b.build_b === 'string' ? b.build_b : '',
    rows: rowsOf(b.rows),
    rowsB: rowsOf(b.rows_b),
  }
}

/** The group key of a row. */
export const perfRowKey = (r) => `${r.metric}|${r.device}|${r.view}`

/**
 * Build A / B side by side: every A row in A's order, then the groups only B
 * has. `b` is the B row of the same group or null; `delta` is B's p75 minus
 * A's (ms), null when either is missing.
 */
export function perfCompareRows(rows, rowsB) {
  const byKey = new Map(rowsB.map((r) => [perfRowKey(r), r]))
  const out = rows.map((a) => {
    const key = perfRowKey(a)
    const b = byKey.get(key) || null
    byKey.delete(key)
    return { key, a, b, delta: a.p75 !== null && b && b.p75 !== null ? Math.round(b.p75 - a.p75) : null }
  })
  for (const b of byKey.values()) out.push({ key: perfRowKey(b), a: null, b, delta: null })
  return out
}

/** A percentile as whole ms ('' when absent). */
export const perfMs = (v) => (v === null || v === undefined ? '' : String(Math.round(v)))

/* the mock build's canned summary: a few groups, one under n = 50 (no p95) */
const MOCK_ROWS = [
  { metric: 'load_messages', device: 'phone', view: 'channel', n: 212, p50: 1180, p75: 1640, p95: 2950, failed: 0 },
  { metric: 'load_rail', device: 'phone', view: '', n: 240, p50: 860, p75: 1210, p95: 2100, failed: 0 },
  { metric: 'reconnect_live', device: 'phone', view: '', n: 31, p50: 640, p75: 980, failed: 0 },
  { metric: 'switch_view', device: 'desktop', view: 'topic', n: 530, p50: 140, p75: 260, p95: 610, failed: 0 },
  { metric: 'send_ack', device: 'desktop', view: 'channel', n: 318, p50: 120, p75: 190, p95: 420, failed: 3 },
  { metric: 'type_next_paint', device: 'desktop', view: 'topic', n: 1204, p50: 18, p75: 26, p95: 48, failed: 0 },
]

/** GET /v1/admin/perf/summary in the mock build: the canned rows; build B is 10 % faster. */
export function mockPerfSummary({ days = 7, build = '', buildB = '' } = {}) {
  const d = daysOf(days)
  const f = d === 30 ? 4 : 1
  const rows = MOCK_ROWS.map((r) => ({ ...r, n: r.n * f }))
  const body = { days: d, rows }
  const a = perfBuildOf(build)
  const b = perfBuildOf(buildB)
  if (a) body.build = a
  if (b) {
    const faster = (v) => (v === undefined ? undefined : Math.round(v * 0.9))
    body.build_b = b
    body.rows_b = rows.map((r) => ({ ...r, p50: faster(r.p50), p75: faster(r.p75), p95: faster(r.p95) }))
  }
  return body
}
