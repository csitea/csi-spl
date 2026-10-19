/**
 * Spec 140 section 4 (SPL-2322, owner HUM-10, t1 e8ae0aad): Monitoring ->
 * Tokens over GET /v1/operator/fleet-tokens (hub internal/hub/fleet_tokens.go,
 * wire.FleetTokenSummaryResponse). The body as a view, the compact numbers,
 * the burn thresholds (4.4.1), the stale marker (4.3), the agent table's sort
 * and filter, and the mock answer.
 *
 * Honest figures: a null count or cost (agy, never metered) stays null and
 * shows as a dash beside "Not metered", never a 0; a metered lane the hub
 * holds no price for is "not priced", never a 0 cost.
 *
 * Only the Tokens page, its components and the lazy spool client import this
 * file, so none of it rides the initial JS (ci_initial_gzip_kb). Node tests
 * import it.
 */

import { isoSeconds } from './iso-seconds.mjs'

/** The windows the page offers; the hub's default is 1h. */
export const TOKENS_WINDOWS = Object.freeze(['1h', 'today', '24h'])
export const TOKENS_DEFAULT_WINDOW = '1h'
/** Polling while the tab is open and the browser tab visible (4.3 D6). */
export const TOKENS_POLL_MS = 30000
/** Lag after which the data is amber (1.5x the timer) and red (3x). */
export const TOKENS_STALE_AMBER_S = 45
export const TOKENS_STALE_RED_S = 90
/** Fresh tokens per minute (in + out + cache write) for the burn badges (4.4.1). */
export const TOKENS_ELEVATED_PER_MIN = 30000
export const TOKENS_SURGE_PER_MIN = 60000
/** A lane is Active when its newest minute is this close to the answer's as_of (the hub's burn window). */
export const TOKENS_ACTIVE_S = 5 * 60
/** The agent kind that reports no tokens (wire.FleetBurnVendorUnmetered). */
export const TOKENS_UNMETERED_VENDOR = 'qwen'
/** The kinds in the hub's order (wire.FleetTokenVendors). */
export const TOKENS_VENDORS = Object.freeze(['claude', 'mistral', 'grok', 'agy', 'qwen'])
/** e2e opt-in (mock only): the operator admin, operator-console.mjs OPERATOR_MOCK_KEY (the same key shows the tab). */
export const TOKENS_MOCK_OPERATOR_KEY = 'spool.mock.operator_admin'
/** e2e opt-in (mock only): '' = a busy fleet, 'empty' = no lane seen yet. */
export const TOKENS_MOCK_KEY = 'spool.mock.fleet_tokens'

const CUR_RE = /^[A-Z]{3}$/
const str = (v) => (typeof v === 'string' ? v : '')
/** A count: a finite number >= 0, else null (a missing or negative count is never shown as one). */
const count = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) || Number(v) < 0 ? null : Number(v))
const int = (v) => (Number.isFinite(Number(v)) && Number(v) >= 0 ? Math.trunc(Number(v)) : 0)

/** The query string for a window ('' for an unknown one: the hub's default 1h). */
export function tokensQuery(window) {
  return TOKENS_WINDOWS.includes(window) ? '?window=' + window : ''
}

/**
 * The hub's answer as the page's view. Unknown or junk fields are dropped;
 * a null rate, total or cost stays null.
 * @param {unknown} body
 */
export function fleetTokensOf(body) {
  const b = body && typeof body === 'object' ? /** @type {Record<string, any>} */ (body) : {}
  const s = b.summary && typeof b.summary === 'object' ? b.summary : {}
  const currency = CUR_RE.test(str(s.currency)) ? s.currency : 'USD'
  const agents = (Array.isArray(b.by_agent) ? b.by_agent : []).filter((a) => a && typeof a === 'object' && str(a.agent_id)).map((a) => ({
    agentId: str(a.agent_id),
    vendor: str(a.vendor),
    model: str(a.model),
    box: str(a.box),
    rate1m: count(a.burn_rate_1m_tokens_per_min),
    rate: count(a.burn_rate_tokens_per_min),
    fresh: count(a.fresh_tokens_per_min),
    todayTokens: count(a.today_total_tokens),
    todayCost: count(a.today_cost),
    metered: a.is_metered !== false && str(a.vendor) !== TOKENS_UNMETERED_VENDOR,
    priced: a.priced === true,
    lastActive: str(a.last_active),
  }))
  const vendors = (Array.isArray(b.by_vendor) ? b.by_vendor : []).filter((v) => v && typeof v === 'object' && str(v.vendor)).map((v) => {
    const vendor = str(v.vendor)
    const metered = vendor !== TOKENS_UNMETERED_VENDOR && v.status !== 'unmetered'
    return {
      vendor,
      active: int(v.active_agents),
      rate: metered ? count(v.burn_rate_tokens_per_min) : null,
      fresh: metered ? count(v.fresh_tokens_per_min) : null,
      todayTokens: metered ? count(v.today_total_tokens) : null,
      todayCost: metered ? count(v.today_cost) : null,
      metered,
      status: metered ? (v.status === 'metered' ? 'metered' : 'idle') : 'unmetered',
      /* the hub sends no price flag per kind: a kind is unpriced when one of its lanes is */
      priced: !agents.some((a) => a.vendor === vendor && a.metered && !a.priced && (a.todayTokens || 0) > 0),
    }
  })
  return {
    asOf: str(b.as_of),
    window: str(b.window),
    currency,
    summary: {
      rate: count(s.burn_rate_tokens_per_min),
      fresh: count(s.fresh_tokens_per_min),
      costPerHour: count(s.burn_rate_cost_per_hour),
      todayTokens: count(s.today_total_tokens),
      todayCacheRead: count(s.today_cache_read),
      todayCost: count(s.today_total_cost),
      active: int(s.active_agents),
      unmetered: int(s.unmetered_agents),
      unpriced: int(s.unpriced_agents),
    },
    vendors,
    agents,
  }
}

/**
 * The Costs card's line per kind (SPL-2461): every metered kind that used
 * tokens today, its tokens and its cost, or priced false when one of its
 * lanes has no price (the card says "not priced", never a cost of 0).
 * @param {ReturnType<typeof fleetTokensOf>} view
 */
export function tokensCardVendors(view) {
  return (view?.vendors || []).filter((v) => v.metered && (v.todayTokens || 0) > 0)
    .map((v) => ({ vendor: v.vendor, tokens: v.todayTokens, cost: v.todayCost, priced: v.priced }))
}

/** A compact token count ("45.2K", "18.45M"); '—' for none (never NaN, never a false 0). */
export function fmtTokens(n, locale = 'en') {
  if (n === null || n === undefined || !Number.isFinite(Number(n)) || Number(n) < 0) return '—'
  const v = Number(n)
  try {
    if (v < 1000) return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(v)
    return new Intl.NumberFormat(locale, { notation: 'compact', maximumFractionDigits: v < 1e6 ? 1 : 2 }).format(v)
  } catch {
    return String(Math.round(v))
  }
}

/** An amount of money in its currency ("$42.15"); '—' for none. */
export function fmtMoney(amount, currency = 'USD', locale = 'en') {
  if (amount === null || amount === undefined || !Number.isFinite(Number(amount)) || Number(amount) < 0) return '—'
  try {
    return new Intl.NumberFormat(locale, { style: 'currency', currency, minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(amount))
  } catch {
    return Number(amount).toFixed(2) + ' ' + currency
  }
}

/** Today's cache reads as a whole % of today's tokens; null when there is nothing to divide. */
export function cacheHitPct(cacheRead, total) {
  if (cacheRead === null || total === null || !(Number(total) > 0)) return null
  return Math.round((Number(cacheRead) / Number(total)) * 100)
}

/** The burn badge for a fresh tokens/min (4.4.1): 'normal', 'elevated' (>= 30k) or 'surge' (> 60k); '' for none. */
export function burnLevel(fresh) {
  if (fresh === null || fresh === undefined || !Number.isFinite(Number(fresh))) return ''
  const v = Number(fresh)
  if (v > TOKENS_SURGE_PER_MIN) return 'surge'
  if (v >= TOKENS_ELEVATED_PER_MIN) return 'elevated'
  return 'normal'
}

/** A change of the 1m rate against the 5m rate of at least this share is a trend (plan 5.3). */
export const TOKENS_TREND_SHARE = 0.15
/** The 5m rate the share is taken of is never below this, so a near-idle lane shows no trend on a few tokens. */
export const TOKENS_TREND_FLOOR_PER_MIN = 1000

/**
 * A lane's burn velocity (SPL-2483, plan 5.3): 'rising' or 'falling' when the
 * 1m rate is at least 15% of max(5m rate, 1000) above or below the 5m rate,
 * else 'steady'; null when either rate is missing (agy, an unmetered lane).
 */
export function tokenVelocity(rate1m, rate5m) {
  const r1 = count(rate1m)
  const r5 = count(rate5m)
  if (r1 === null || r5 === null) return null
  if (Math.abs(r1 - r5) / Math.max(r5, TOKENS_TREND_FLOOR_PER_MIN) < TOKENS_TREND_SHARE) return 'steady'
  return r1 > r5 ? 'rising' : 'falling'
}

/** The stale marker for a lag in seconds (4.3): 'ok' up to 45 s, 'amber' up to 90 s, then 'red'. */
export function staleLevel(lagS) {
  if (!Number.isFinite(Number(lagS))) return 'red'
  const v = Number(lagS)
  if (v > TOKENS_STALE_RED_S) return 'red'
  if (v > TOKENS_STALE_AMBER_S) return 'amber'
  return 'ok'
}

/** Whole seconds from an ISO time (or ms) to now; Infinity when there is none. */
export function lagSeconds(at, now = Date.now()) {
  const t = typeof at === 'number' ? at : Date.parse(str(at))
  if (!Number.isFinite(t)) return Infinity
  return Math.max(0, Math.floor((now - t) / 1000))
}

/** True when a tick of the poll may fetch: the tab is open and the browser tab visible. */
export function tokensShouldPoll(visibilityState, open = true) {
  return open === true && visibilityState === 'visible'
}

/** A lane's status: 'not_metered' (agy), 'active' (a minute in the burn window) or 'idle'. */
export function agentStatus(a, asOf) {
  if (!a.metered) return 'not_metered'
  const ref = Date.parse(str(asOf))
  const last = Date.parse(str(a.lastActive))
  if (!Number.isFinite(ref) || !Number.isFinite(last)) return 'idle'
  return ref - last <= TOKENS_ACTIVE_S * 1000 ? 'active' : 'idle'
}

/** The agent table's sortable columns: numeric ones sort as numbers, a null always last. */
export const TOKENS_SORT_KEYS = Object.freeze(['agentId', 'rate1m', 'rate', 'todayTokens', 'todayCost', 'lastActive'])
const NUMERIC = new Set(['rate1m', 'rate', 'todayTokens', 'todayCost'])

/**
 * The lanes of one kind ('' = all), sorted by a column. Numbers compare as
 * numbers (100 after 9, never as text); a null (unmetered) sorts last either
 * way; ties keep the agent id order.
 * @param {ReturnType<typeof fleetTokensOf>['agents']} rows
 * @param {{ vendor?: string, key?: string, dir?: 'asc' | 'desc' }} [opts]
 */
export function sortAgents(rows, opts = {}) {
  const key = TOKENS_SORT_KEYS.includes(opts.key || '') ? /** @type {string} */ (opts.key) : 'rate'
  const sign = opts.dir === 'asc' ? 1 : -1
  const vendor = str(opts.vendor)
  const list = (Array.isArray(rows) ? rows : []).filter((a) => !vendor || a.vendor === vendor)
  return list.slice().sort((a, b) => {
    const x = /** @type {any} */ (a)[key]
    const y = /** @type {any} */ (b)[key]
    const xn = x === null || x === undefined || x === ''
    const yn = y === null || y === undefined || y === ''
    if (xn !== yn) return xn ? 1 : -1
    if (!xn && x !== y) {
      if (NUMERIC.has(key)) return (Number(x) - Number(y)) * sign
      return (String(x) < String(y) ? -1 : 1) * sign
    }
    return a.agentId < b.agentId ? -1 : a.agentId > b.agentId ? 1 : a.box < b.box ? -1 : a.box > b.box ? 1 : 0
  })
}

function mockForbidden() {
  const e = /** @type {Error & { status?: number, token?: string, permission?: string }} */ (new Error('only an admin of the operator workspace reads the fleet'))
  e.status = 403
  e.token = 'forbidden'
  e.permission = 'operator.workspaces'
  return e
}

function mockStore() {
  try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
}

/**
 * The mock's GET: 403 operator.workspaces unless the e2e opted into the
 * operator admin (the operator console's key, which shows the tab), else a fleet
 * shaped as the hub answers it: claude and mistral lanes (one surging, one
 * unpriced), an agy lane (nulls) and two idle kinds.
 */
export function mockFleetTokens(window = TOKENS_DEFAULT_WINDOW, store = mockStore(), now = new Date()) {
  const get = (k) => { try { return store ? store.getItem(k) : null } catch { return null } }
  if (get(TOKENS_MOCK_OPERATOR_KEY) !== '1') throw mockForbidden()
  const asOf = new Date(Math.floor(now.getTime() / 60000) * 60000)
  const ago = (min) => isoSeconds(new Date(asOf.getTime() - min * 60000))
  const w = TOKENS_WINDOWS.includes(window) ? window : TOKENS_DEFAULT_WINDOW
  const NULLS = { burn_rate_tokens_per_min: null, fresh_tokens_per_min: null, today_tokens_in: null, today_tokens_out: null,
    today_cache_read: null, today_cache_write: null, today_total_tokens: null, today_cost: null }
  /* [vendor, active, rate, fresh, today, cost, status] */
  const vendorRow = ([vendor, active, rate, fresh, total, cost, status]) => (vendor === TOKENS_UNMETERED_VENDOR || status === 'unmetered' || !status
    ? { vendor, active_agents: active, ...NULLS, status: 'unmetered' }
    : { vendor, active_agents: active, burn_rate_tokens_per_min: rate, fresh_tokens_per_min: fresh, today_tokens_in: total,
        today_tokens_out: 0, today_cache_read: 0, today_cache_write: 0, today_total_tokens: total, today_cost: cost, status })
  /* [agent_id, vendor, box, model, rate 1m, rate 5m, fresh, today, cost, priced, minutes ago] */
  const agentRow = ([agent_id, vendor, box, model, r1, rate, fresh, total, cost, priced, last]) => (vendor === TOKENS_UNMETERED_VENDOR || rate === null
    ? { agent_id, vendor, model: null, box, burn_rate_1m_tokens_per_min: null, burn_rate_tokens_per_min: null, fresh_tokens_per_min: null,
        today_total_tokens: null, today_cost: null, is_metered: false, priced: false, last_active: ago(last) }
    : { agent_id, vendor, model, box, burn_rate_1m_tokens_per_min: r1, burn_rate_tokens_per_min: rate, fresh_tokens_per_min: fresh,
        today_total_tokens: total, today_cost: cost, is_metered: true, priced, last_active: ago(last) })
  if (get(TOKENS_MOCK_KEY) === 'empty') {
    return { as_of: asOf.toISOString(), window: w, history: [],
      summary: { burn_rate_tokens_per_min: 0, fresh_tokens_per_min: 0, burn_rate_cost_per_hour: 0, today_total_tokens: 0, today_cache_read: 0,
        today_total_cost: 0, currency: 'USD', active_agents: 0, unmetered_agents: 0, unpriced_agents: 0 },
      by_vendor: TOKENS_VENDORS.map((v) => vendorRow([v, 0, 0, 0, 0, 0, 'idle'])),
      by_agent: [] }
  }
  return {
    as_of: asOf.toISOString(),
    window: w,
    summary: { burn_rate_tokens_per_min: 113300, fresh_tokens_per_min: 81500, burn_rate_cost_per_hour: 6.12, today_total_tokens: 19350000,
      today_cache_read: 8856000, today_total_cost: 42.15, currency: 'USD', active_agents: 6, unmetered_agents: 1, unpriced_agents: 2 },
    by_vendor: [
      ['claude', 3, 104200, 74600, 15800000, 39.4, 'metered'],
      ['mistral', 1, 9100, 6900, 2650000, 2.75, 'metered'],
      ['grok', 1, 2800, 1200, 900000, 0, 'metered'],
      ['agy', 1],
      ['qwen', 0, 0, 0, 0, 0, 'idle'],
    ].map(vendorRow),
    by_agent: [
      ['c-101', 'claude', 'box-a', 'claude-opus-5-5', 88000, 81200, 64300, 9200000, 24.1, true, 1],
      ['c-102', 'claude', 'box-a', 'claude-sonnet-5-5', 15000, 14800, 8100, 4100000, 11.2, true, 1],
      ['m-201', 'mistral', 'box-b', 'devstral-2', 9500, 9100, 6900, 2650000, 0, false, 2],
      ['c-103', 'claude', 'box-b', 'claude-haiku-4-5', 0, 8200, 2200, 2500000, 4.1, true, 4],
      /* grok (SPL-2461): metered, no xai price row: "not priced", never $0.00 */
      ['g-401', 'grok', 'box-b', 'grok-4.7-build', 3000, 2800, 1200, 900000, 0, false, 3],
      ['a-301', 'agy', 'box-b', null, null, null, null, null, null, false, 1],
      ['c-104', 'claude', 'box-a', 'claude-sonnet-5-5', 0, 0, 0, 0, 0, true, 40],
    ].map(agentRow),
    history: [],
  }
}
