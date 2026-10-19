// Spec 140 4 (SPL-2322): Monitoring -> Tokens, the util under the page
// (src/utils/monitoring-tokens.mjs): the hub body as a view, honest figures
// (agy's nulls stay nulls, never a 0), the compact formats, the burn and
// stale thresholds, the numeric sort and the kind filter, the mock's 403.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  TOKENS_POLL_MS,
  TOKENS_STALE_AMBER_S,
  TOKENS_STALE_RED_S,
  agentStatus,
  burnLevel,
  cacheHitPct,
  fleetTokensOf,
  fmtMoney,
  fmtTokens,
  lagSeconds,
  mockFleetTokens,
  sortAgents,
  staleLevel,
  tokensQuery,
  tokensCardVendors,
  tokensShouldPoll,
  tokenVelocity,
} from '../../src/utils/monitoring-tokens.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const store = (items) => ({ getItem: (k) => (k in items ? items[k] : null) })
const NOW = new Date('2026-10-17T10:00:30Z')
const mock = (items = { 'spool.mock.operator_admin': '1' }) => fleetTokensOf(mockFleetTokens('1h', store(items), NOW))

describe('monitoring tokens: the hub body as a view', () => {
  it('reads the summary, the kinds in the hub order and the lanes', () => {
    const v = mock()
    assert.equal(v.currency, 'USD')
    assert.equal(v.summary.todayTokens, 19350000)
    assert.equal(v.summary.unmetered, 1)
    assert.deepEqual(v.vendors.map((x) => x.vendor), ['claude', 'mistral', 'grok', 'agy', 'qwen'])
    assert.equal(v.agents.length, 7)
  })
  it('unmetered vendors (qwen or agy with no counts) stay null and unmetered, while metered agy reads its figures (T032 red control)', () => {
    const v = mock()
    const agy = v.vendors.find((x) => x.vendor === 'agy')
    assert.equal(agy.metered, false)
    assert.equal(agy.status, 'unmetered')
    for (const k of ['rate', 'fresh', 'todayTokens', 'todayCost']) assert.equal(agy[k], null, k)
    const lane = v.agents.find((a) => a.vendor === 'agy')
    assert.equal(lane.metered, false)
    assert.equal(agentStatus(lane, v.asOf), 'not_metered')
    /* CONTROL: even a hub that wrongly sent 0 for an unmetered vendor reads as null, never "0 tokens" */
    const wrong = fleetTokensOf({ by_vendor: [{ vendor: 'qwen', active_agents: 1, burn_rate_tokens_per_min: 0, today_total_tokens: 0, today_cost: 0, status: 'metered' }] })
    assert.equal(wrong.vendors[0].metered, false)
    assert.equal(wrong.vendors[0].todayTokens, null)
    assert.equal(wrong.vendors[0].todayCost, null)
    /* agy when metered reads real counts (SPL-2598) */
    const met = fleetTokensOf({ by_vendor: [{ vendor: 'agy', active_agents: 1, burn_rate_tokens_per_min: 500, today_total_tokens: 12000, today_cost: 0, status: 'metered' }] })
    assert.equal(met.vendors[0].metered, true)
    assert.equal(met.vendors[0].todayTokens, 12000)
    assert.equal(met.vendors[0].status, 'metered')
  })
  it('a kind with a metered lane the hub holds no price for is unpriced, a priced kind is not', () => {
    const v = mock()
    assert.equal(v.vendors.find((x) => x.vendor === 'mistral').priced, false)
    assert.equal(v.vendors.find((x) => x.vendor === 'claude').priced, true)
    assert.equal(v.agents.find((a) => a.agentId === 'm-201').priced, false)
  })
  it('grok is a metered kind with its lane; no xai price: "not priced", never a cost of 0 (SPL-2461)', () => {
    const v = mock()
    const grok = v.vendors.find((x) => x.vendor === 'grok')
    assert.equal(grok.metered, true)
    assert.equal(grok.todayTokens, 900000)
    assert.equal(grok.priced, false)
    const lane = v.agents.find((a) => a.agentId === 'g-401')
    assert.equal(lane.vendor, 'grok')
    assert.equal(lane.priced, false)
  })
  it('the Costs card has one line per kind that used tokens today, agy and idle kinds none (SPL-2461)', () => {
    const lines = tokensCardVendors(mock())
    assert.deepEqual(lines.map((l) => [l.vendor, l.tokens, l.priced]), [['claude', 15800000, true], ['mistral', 2650000, false], ['grok', 900000, false]])
    /* CONTROL: an empty fleet draws no line */
    assert.deepEqual(tokensCardVendors(mock({ 'spool.mock.operator_admin': '1', 'spool.mock.fleet_tokens': 'empty' })), [])
    assert.deepEqual(tokensCardVendors(null), [])
  })
  it('a missing, negative or junk figure is null, never NaN (T031 red control)', () => {
    const v = fleetTokensOf({ summary: { burn_rate_tokens_per_min: -5, today_total_tokens: 'x', today_total_cost: null, currency: 'eur' } })
    assert.equal(v.summary.rate, null)
    assert.equal(v.summary.todayTokens, null)
    assert.equal(v.summary.todayCost, null)
    assert.equal(v.currency, 'USD', 'a currency that is not an ISO code falls back')
    assert.deepEqual(fleetTokensOf(null).agents, [])
  })
})

describe('monitoring tokens: formats', () => {
  it('compact tokens and money (T031 gate)', () => {
    assert.equal(fmtTokens(45200, 'en'), '45.2K')
    assert.equal(fmtTokens(18450000, 'en'), '18.45M')
    assert.equal(fmtTokens(950, 'en'), '950')
    assert.equal(fmtTokens(0, 'en'), '0')
    assert.equal(fmtMoney(42.15, 'EUR', 'en'), '€42.15')
    assert.equal(fmtMoney(42.15, 'USD', 'en'), '$42.15')
  })
  it('none is a dash, never NaN or a false 0 (T031 red control)', () => {
    for (const bad of [null, undefined, -1, NaN, 'x']) {
      assert.equal(fmtTokens(bad), '—', String(bad))
      assert.equal(fmtMoney(bad), '—', String(bad))
    }
    assert.equal(cacheHitPct(4800, 10000), 48)
    assert.equal(cacheHitPct(null, 10000), null)
    assert.equal(cacheHitPct(0, 0), null)
  })
})

describe('monitoring tokens: thresholds', () => {
  it('burn badge on fresh tokens/min: elevated from 30k, surge above 60k (4.4.1)', () => {
    assert.equal(burnLevel(29999), 'normal')
    assert.equal(burnLevel(30000), 'elevated')
    assert.equal(burnLevel(60000), 'elevated')
    assert.equal(burnLevel(60001), 'surge')
    assert.equal(burnLevel(null), '')
  })
  it('stale: ok to 45 s, amber to 90 s, red beyond (T034 gate + red control)', () => {
    assert.equal(TOKENS_POLL_MS, 30000)
    assert.equal(TOKENS_STALE_AMBER_S, 45)
    assert.equal(TOKENS_STALE_RED_S, 90)
    assert.equal(staleLevel(0), 'ok')
    assert.equal(staleLevel(45), 'ok')
    assert.equal(staleLevel(46), 'amber')
    assert.equal(staleLevel(90), 'amber')
    assert.equal(staleLevel(91), 'red')
    assert.equal(staleLevel(Infinity), 'red', 'no answer at all is stale')
    assert.equal(lagSeconds(Date.parse('2026-10-17T10:00:00Z'), Date.parse('2026-10-17T10:00:48Z')), 48)
    assert.equal(lagSeconds(''), Infinity)
  })
  it('polls only while open and visible (T034: a backgrounded tab makes no call)', () => {
    assert.equal(tokensShouldPoll('visible'), true)
    assert.equal(tokensShouldPoll('hidden'), false)
    assert.equal(tokensShouldPoll('visible', false), false)
  })
  it('a lane is Active with a minute in the last 5, else Idle', () => {
    const v = mock()
    assert.equal(agentStatus(v.agents.find((a) => a.agentId === 'c-101'), v.asOf), 'active')
    assert.equal(agentStatus(v.agents.find((a) => a.agentId === 'c-104'), v.asOf), 'idle')
  })
})

describe('monitoring tokens: the agent table', () => {
  const rows = [
    { agentId: 'c-1', vendor: 'claude', box: 'a', rate: 9, rate1m: 0, todayTokens: 5, todayCost: 1, lastActive: '' },
    { agentId: 'c-2', vendor: 'claude', box: 'a', rate: 100, rate1m: 0, todayTokens: 50, todayCost: 2, lastActive: '' },
    { agentId: 'a-3', vendor: 'agy', box: 'b', rate: null, rate1m: null, todayTokens: null, todayCost: null, lastActive: '' },
    { agentId: 'm-4', vendor: 'mistral', box: 'b', rate: 20, rate1m: 0, todayTokens: 500, todayCost: 3, lastActive: '' },
  ]
  it('sorts by burn rate, highest first, by default (T033 gate)', () => {
    assert.deepEqual(sortAgents(rows).map((a) => a.agentId), ['c-2', 'm-4', 'c-1', 'a-3'])
  })
  it('sorts numbers as numbers, ascending too, a null always last (T033 red control: 100 after 9, not before)', () => {
    assert.deepEqual(sortAgents(rows, { key: 'rate', dir: 'asc' }).map((a) => a.agentId), ['c-1', 'm-4', 'c-2', 'a-3'])
    const asText = rows.slice().sort((a, b) => String(a.rate) < String(b.rate) ? -1 : 1).map((a) => a.agentId)
    assert.notDeepEqual(sortAgents(rows, { key: 'rate', dir: 'asc' }).map((a) => a.agentId), asText)
  })
  it('filters by kind', () => {
    assert.deepEqual(sortAgents(rows, { vendor: 'claude' }).map((a) => a.agentId), ['c-2', 'c-1'])
    assert.deepEqual(sortAgents(rows, { vendor: 'agy' }).map((a) => a.agentId), ['a-3'])
  })
})

describe('monitoring tokens: the velocity trend (SPL-2483, plan 5.3)', () => {
  it('red control: the mock lanes read rising, steady, falling, and null for an unmetered lane', () => {
    assert.equal(tokenVelocity(100000, 80000), 'rising')
    assert.equal(tokenVelocity(88000, 81200), 'steady')
    assert.equal(tokenVelocity(0, 8200), 'falling')
    assert.equal(tokenVelocity(null, null), null)
  })
  it('the threshold is 15% of the 5m rate, never of less than 1000/min', () => {
    assert.equal(tokenVelocity(11500, 10000), 'rising')
    assert.equal(tokenVelocity(11499, 10000), 'steady')
    assert.equal(tokenVelocity(8500, 10000), 'falling')
    assert.equal(tokenVelocity(100, 0), 'steady', 'a few tokens on an idle lane are no surge')
    assert.equal(tokenVelocity(150, 0), 'rising')
    assert.equal(tokenVelocity(0, 0), 'steady')
  })
  it('a missing rate is null, never a trend', () => {
    assert.equal(tokenVelocity(5000, null), null)
    assert.equal(tokenVelocity(undefined, 5000), null)
    assert.equal(tokenVelocity('x', 5000), null)
  })
  it('the badge marks each trend with its translated aria-label and no :style or v-html', () => {
    const vue = read('src/components/monitoring/token-burn/TrendBadge.vue')
    for (const k of ['trend_rising', 'trend_falling', 'trend_steady']) assert.match(vue, new RegExp(`'monitoring\\.tokens\\.${k}'`), k)
    for (const m of ['▲', '▼', '—']) assert.ok(vue.includes(m), m)
    assert.doesNotMatch(vue, /:style=|v-bind:style|v-html/)
  })
})

describe('monitoring tokens: the mock and the wiring', () => {
  it('the mock answers 403 operator.workspaces unless the e2e opted into the operator admin', () => {
    assert.throws(() => mockFleetTokens('1h', store({}), NOW), (e) => e.status === 403 && e.permission === 'operator.workspaces')
    assert.equal(mock({ 'spool.mock.operator_admin': '1', 'spool.mock.fleet_tokens': 'empty' }).agents.length, 0)
  })
  it('the mock operator key is the operator console\'s (the key that shows the tab)', () => {
    assert.match(read('src/utils/operator-console.mjs'), /OPERATOR_MOCK_KEY = 'spool\.mock\.operator_admin'/)
  })
  it('the query names a known window only', () => {
    assert.equal(tokensQuery('today'), '?window=today')
    assert.equal(tokensQuery('7d'), '')
  })
  it('the page, its components and the costs card bind no :style (CSP) and stay lazy', () => {
    const files = ['src/pages/monitoring/tokens/index.vue', 'src/components/monitoring/token-burn/MonitoringTokensSummary.vue',
      'src/components/monitoring/token-burn/VendorBurnTable.vue', 'src/components/monitoring/token-burn/AgentBurnTable.vue',
      'src/components/monitoring/token-burn/BurnBadge.vue', 'src/components/monitoring/token-burn/TokensCostsCard.vue']
    for (const f of files) assert.doesNotMatch(read(f), /:style=|v-bind:style/, f)
    const page = read('src/pages/monitoring/tokens/index.vue')
    assert.match(page, /visibilityState|tokensShouldPoll/, 'the poll is visibility-guarded')
    assert.match(page, /TOKENS_POLL_MS/)
    const costs = read('src/pages/monitoring/costs/index.vue')
    assert.match(costs, /defineAsyncComponent\(\(\) => import\('@\/components\/monitoring\/token-burn\/TokensCostsCard\.vue'\)\)/, 'the costs card is its own chunk')
    assert.match(costs, /v-if="operator\.visible"/, 'the costs card is for operator admins only')
    assert.match(read('src/utils/spool-client-lazy.mjs'), /live\('\/v1\/operator\/fleet-tokens' \+ mt\.tokensQuery\(window\)\)/)
  })
})
