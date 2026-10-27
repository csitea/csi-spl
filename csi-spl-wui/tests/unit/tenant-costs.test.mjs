// Spec 123 5 + 8 (SPL-2056): the Monitoring -> Costs tab's pure parts - the
// money from micros, the pie's slices, the coverage and the honest empties,
// the month picker, the mock's refusals - and the chunk rule: the pie and
// this module stay out of the shell (ci_initial_gzip_kb).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  COSTS_READ,
  costAIShareNote,
  COST_PIE_COLORS,
  COST_PIE_OTHER_COLOR,
  costCoverageRows,
  costEmptySources,
  costListTotal,
  costMoney,
  costMonthOf,
  costMonthOptions,
  costPieArc,
  costPieSlices,
  costSliceColor,
  costUnits,
  costsQuery,
  COST_SECOND_DEFAULT,
  MOCK_FX_RATES,
  costCurrency,
  costCurrencyOptions,
  costFxRate,
  costSecondCell,
  mockFxCurrencies,
  mockTenantCosts,
  mockTenantCostsBody,
} from '../../src/utils/tenant-costs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const NOW = new Date('2026-10-16T09:00:00Z')
const part = (source, usd, extra = {}) => ({ source, usd_micros: usd * 1e6, eur_micros: usd * 0.9e6, project_or_vendor: extra.pov || 'p', kind: extra.kind || 'k', origin: extra.origin || 'transcript', ...extra })

describe('costMoney: USD and EUR from micros', () => {
  it('two decimals, the currency sign, the reader locale', () => {
    assert.equal(costMoney(1_234_560_000, 'USD', 'en'), '$1,234.56')
    assert.equal(costMoney(900_000, 'EUR', 'en'), '€0.90')
    assert.equal(costMoney(0, 'USD', 'en'), '$0.00')
    assert.equal(costMoney(5_000, 'USD', 'en'), '$0.01', 'half a cent rounds up, never drops')
    assert.match(costMoney(1_234_560_000, 'EUR', 'fi'), /^1\s234,56\s€$/)
  })
  it('a missing amount is blank, never a 0', () => {
    assert.equal(costMoney(null), '')
    assert.equal(costMoney(undefined), '')
    assert.equal(costMoney('x'), '')
  })
  it('units are compact, none blank', () => {
    assert.equal(costUnits(2.6e9, 'en'), '2.6B')
    assert.equal(costUnits(0), '')
  })
})

describe('costMonthOf: the hub body, defensively', () => {
  it('reads every field; list price only when > 0', () => {
    const m = costMonthOf(mockTenantCostsBody('2026-09', '', NOW))
    assert.equal(m.month, '2026-09')
    assert.equal(m.status, 'ended')
    assert.equal(m.scope, 'estate')
    assert.equal(m.days, 30)
    assert.equal(m.daysEnded, 30)
    const sub = m.parts.find((p) => p.kind === 'subscription')
    assert.equal(sub.hand, true)
    assert.equal(sub.listValueMicros, 1450e6)
    assert.equal(m.parts.find((p) => p.kind === 'cloud_sql').listValueMicros, null)
    assert.equal(m.total.usdMicros, m.parts.reduce((s, p) => s + p.usdMicros, 0))
  })
  it('garbage in, an empty month out', () => {
    const m = costMonthOf(null)
    assert.deepEqual(m.parts, [])
    assert.equal(m.total.usdMicros, 0)
    assert.equal(m.scope, 'workspace')
  })
})

describe('costPieSlices', () => {
  it('slices sum to one whole turn (100 %), largest first, the last closes at 1', () => {
    const parts = costMonthOf({ parts: [part('gcp', 30), part('gcp', 50, { pov: 'b' }), part('hand', 20, { pov: 'c' })] }).parts
    const s = costPieSlices(parts)
    assert.deepEqual(s.map((x) => x.usdMicros / 1e6), [50, 30, 20])
    assert.equal(s[0].from, 0)
    assert.equal(s.at(-1).to, 1)
    for (let i = 1; i < s.length; i++) assert.equal(s[i].from, s[i - 1].to)
    assert.ok(Math.abs(s.reduce((a, x) => a + x.frac, 0) - 1) < 1e-9)
    assert.equal(s.reduce((a, x) => a + x.pct, 0), 100)
  })
  it('a part at or under 1 % folds into one "other" slice, last; zero-money parts draw nothing', () => {
    const parts = costMonthOf({ parts: [part('gcp', 990), part('gcp', 5, { pov: 'x' }), part('gcp', 4, { pov: 'y' }), part('fleet_tokens', 0)] }).parts
    const s = costPieSlices(parts)
    assert.equal(s.length, 2)
    assert.equal(s[1].other, true)
    assert.equal(s[1].n, 2)
    assert.equal(s[1].usdMicros, 9e6)
    /* CONTROL: with no threshold each part is its own slice */
    assert.equal(costPieSlices(parts, -1).length, 3)
  })
  it('no money at all -> no slices (no pie, never a 0 pie)', () => {
    assert.deepEqual(costPieSlices(costMonthOf(mockTenantCostsBody('2026-09', 'empty', NOW)).parts), [])
    assert.deepEqual(costPieSlices([]), [])
  })
  it('one slice is a full circle; arcs start at 12 o\'clock', () => {
    const s = costPieSlices(costMonthOf({ parts: [part('gcp', 3)] }).parts)
    assert.equal(s.length, 1)
    assert.match(s[0].d, /^M 50 0 A 50 50 0 1 1 50 100 A/)
    assert.equal(costPieArc(0, 0.25), 'M 50 50 L 50 0 A 50 50 0 0 1 100 50 Z')
    assert.match(costPieArc(0, 0.75), / 0 1 1 /, 'a slice over half a turn takes the large arc')
  })
  it('colours: the palette in order, "other" grey', () => {
    assert.equal(costSliceColor({ other: false }, 0), COST_PIE_COLORS[0])
    assert.equal(costSliceColor({ other: true }, 0), COST_PIE_OTHER_COLOR)
  })
})

describe('coverage and the honest empties', () => {
  it('n of N per source, complete only when every ended day is ok', () => {
    const rows = costCoverageRows(costMonthOf(mockTenantCostsBody('2026-10', '', NOW)))
    const by = Object.fromEntries(rows.map((r) => [r.source, r]))
    assert.equal(by.fleet_tokens.days, 15)
    assert.equal(by.fleet_tokens.complete, true)
    assert.equal(by.gcp.ok, 14)
    assert.equal(by.gcp.partial, 1)
    assert.equal(by.gcp.complete, false)
    assert.equal(by.agent_hours.missing, 1)
    assert.equal(by.agent_hours.unrecorded, 1)
  })
  it('today\'s prd: tokens and agent hours carry counts only, GCP has no rows -> all three named', () => {
    assert.deepEqual(costEmptySources(costMonthOf(mockTenantCostsBody('2026-10', 'empty', NOW))), ['gcp', 'fleet_tokens', 'agent_hours'])
  })
  it('a full month names only the money-less sources; a workspace scope never asks for GCP', () => {
    assert.deepEqual(costEmptySources(costMonthOf(mockTenantCostsBody('2026-10', '', NOW))), ['fleet_tokens', 'agent_hours'])
    assert.deepEqual(costEmptySources(costMonthOf({ scope: 'workspace', parts: [part('hand', 5)] })), [])
  })
})

describe('a workspace\'s token costs (spec 140 3.10, SPL-3565)', () => {
  it('the estate lists every workspace\'s burn; a workspace answer never does, even if the body carries it', () => {
    const ws = [{ workspace: 'ws-a', vendor: 'claude', tokens: 1100, list_value_micros: 4500, days: 1 }]
    assert.deepEqual(costMonthOf({ scope: 'estate', workspaces: ws }).workspaces, [{ workspace: 'ws-a', vendor: 'claude', tokens: 1100, listValueMicros: 4500, days: 1 }])
    assert.deepEqual(costMonthOf({ scope: 'workspace', workspaces: ws }).workspaces, [])
    assert.deepEqual(costMonthOf({}).workspaces, [])
  })
  it('the list-price total sums every part\'s list value; a paid-0 token part still counts', () => {
    const m = costMonthOf({ scope: 'workspace', parts: [part('fleet_tokens', 0, { list_value_micros: 13_890_000 }), part('hand', 5, { list_value_micros: 1_000_000 }), part('gcp', 2)] })
    assert.equal(costListTotal(m.parts), 14_890_000)
    assert.equal(costListTotal([]), 0)
    assert.equal(costListTotal(undefined), 0)
  })
})

describe('a workspace\'s share of the AI subscriptions (spec 143 3.3.1, SPL-3891)', () => {
  const cov = [{ source: 'fleet_tokens', ok: 26, days: 26 }, { source: 'ai_share', ok: 26, days: 26 }]
  it('the hub\'s ai_share_from is read for a workspace, never for the estate', () => {
    assert.equal(costMonthOf({ scope: 'workspace', ai_share_from: '2026-10-27' }).aiShareFrom, '2026-10-27')
    assert.equal(costMonthOf({ scope: 'estate', ai_share_from: '2026-10-27' }).aiShareFrom, '')
    assert.equal(costMonthOf({}).aiShareFrom, '')
  })
  it('a workspace with a share: the line names its first day', () => {
    const m = costMonthOf({ scope: 'workspace', coverage: cov, ai_share_from: '2026-10-03', parts: [part('ai_share', 4, { pov: 'claude', kind: 'share' })] })
    assert.deepEqual(costAIShareNote(m), { key: 'ai_share_from', params: { day: '2026-10-03' } })
  })
  it('today\'s tokens only (a customer workspace on 2026-10-27): the line says no share yet, never silence', () => {
    assert.deepEqual(costAIShareNote(costMonthOf({ scope: 'workspace', coverage: cov })), { key: 'ai_share_none', params: {} })
  })
  it('no line for the estate, nor when the hub read no share (the operator\'s own members)', () => {
    assert.equal(costAIShareNote(costMonthOf({ scope: 'estate', coverage: cov })), null)
    assert.equal(costAIShareNote(costMonthOf({ scope: 'workspace', coverage: cov.slice(0, 1) })), null)
    assert.equal(costAIShareNote(null), null)
  })
  it('the mock: \'share\' carries ai_share parts and the first day, \'share_none\' neither', () => {
    const now = new Date('2026-10-27T21:00:00Z')
    const sh = costMonthOf(mockTenantCostsBody('', 'share', now))
    assert.equal(sh.scope, 'workspace')
    assert.deepEqual(sh.parts.filter((p) => p.source === 'ai_share').map((p) => p.projectOrVendor), ['agy', 'claude'])
    assert.equal(sh.parts.some((p) => p.source === 'ai_paid'), false, 'a customer never sees the estate\'s ai_paid')
    assert.equal(costAIShareNote(sh).key, 'ai_share_from')
    const none = costMonthOf(mockTenantCostsBody('', 'share_none', now))
    assert.equal(none.parts.some((p) => p.source === 'ai_share'), false)
    assert.equal(costAIShareNote(none).key, 'ai_share_none')
  })
})

describe('the month picker and the query', () => {
  it('now\'s UTC month first, then earlier ones, across the year; no future month', () => {
    const m = costMonthOptions(new Date('2026-02-01T00:30:00Z'), 4)
    assert.deepEqual(m, ['2026-02', '2026-01', '2025-12', '2025-11'])
    assert.equal(costMonthOptions(NOW).length, 12)
  })
  it('the query carries a valid month only', () => {
    assert.equal(costsQuery('2026-09'), '?month=2026-09')
    assert.equal(costsQuery(''), '')
    assert.equal(costsQuery('2026-13'), '')
  })
  it('the current month is "so far", an earlier one ended', () => {
    assert.equal(mockTenantCostsBody('2026-10', '', NOW).status, 'so_far')
    assert.equal(mockTenantCostsBody('2026-10', '', NOW).days_ended, 15)
    assert.equal(mockTenantCostsBody('2026-09', '', NOW).status, 'ended')
  })
})

describe('the mock GET refuses like the hub', () => {
  it('a member without costs.read gets the 403 naming it; with it, the month', () => {
    assert.throws(() => mockTenantCosts('', { me: { permissions: ['members.invite'] }, now: NOW, scenario: '' }),
      (e) => e.status === 403 && e.permission === COSTS_READ)
    assert.equal(mockTenantCosts('', { me: { permissions: [COSTS_READ] }, now: NOW, scenario: '' }).month, '2026-10')
    assert.equal(mockTenantCosts('', { me: null, now: NOW, scenario: '' }).month, '2026-10', 'no mock me = unrestricted')
  })
  it('a future month is 400', () => {
    assert.throws(() => mockTenantCosts('2026-11', { now: NOW, scenario: '' }), (e) => e.status === 400)
  })
})

function walk(dir, out = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (/\.(vue|ts|mjs|js)$/.test(n)) out.push(p)
  }
  return out
}

describe('the second currency (spec 123 5.4, SPL-2199)', () => {
  const hubPart = (extra = {}) => part('gcp', 10, { second_micros: 9_234_000, fx_rate: 0.9234, fx_rate_day: '2026-10-15', fx_rate_first_day: '2026-10-01', ...extra })
  it('costMonthOf reads the pick, the part amounts, the rate and its dates', () => {
    const m = costMonthOf({ second_currency: 'sek', total: { usd_micros: 10e6, eur_micros: 9e6, second_micros: 105e6 }, parts: [hubPart()] })
    assert.equal(m.secondCurrency, 'SEK')
    assert.equal(m.total.secondMicros, 105e6)
    const p = m.parts[0]
    assert.deepEqual([p.secondMicros, p.fxRate, p.fxRateDay, p.fxRateFirstDay], [9_234_000, 0.9234, '2026-10-15', '2026-10-01'])
  })
  it('no rate stays null, never a 0 (a hub before lane A answers no fields: EUR, null)', () => {
    const m = costMonthOf({ total: { usd_micros: 10e6, second_micros: null }, parts: [hubPart({ second_micros: null, fx_rate: null, fx_rate_day: null, fx_rate_first_day: null }), part('gcp', 1)] })
    assert.equal(m.secondCurrency, COST_SECOND_DEFAULT)
    assert.equal(m.total.secondMicros, null)
    for (const p of m.parts) assert.deepEqual([p.secondMicros, p.fxRate, p.fxRateDay], [null, null, ''])
  })
  it('an amount without its rate or date reads as no rate (never shown without a rate)', () => {
    assert.equal(costMonthOf({ parts: [hubPart({ fx_rate: null })] }).parts[0].secondMicros, null)
    assert.equal(costMonthOf({ parts: [hubPart({ fx_rate_day: 'soon' })] }).parts[0].secondMicros, null)
  })
  it('costSecondCell: the amount, its title the rate and the rate date', () => {
    const one = costSecondCell({ secondMicros: 9_234_000, fxRate: 0.9234, fxRateDay: '2026-10-15', fxRateFirstDay: '2026-10-15' }, 'EUR', 'en')
    assert.deepEqual(one, { text: '€9.23', none: false, key: 'rate', params: { currency: 'EUR', rate: '0.9234', day: '2026-10-15', first: '2026-10-15' } })
    const span = costSecondCell({ secondMicros: 105e6, fxRate: 10.5, fxRateDay: '2026-10-15', fxRateFirstDay: '2026-10-01' }, 'sek', 'en')
    assert.equal(span.key, 'rate_span')
    assert.equal(span.params.first, '2026-10-01')
    assert.equal(span.params.currency, 'SEK')
    assert.match(span.text, /^SEK\s?105\.00$/)
  })
  it('costSecondCell: no rate is an em dash with the "none" title, never a guess', () => {
    const none = costSecondCell({ secondMicros: null }, 'GBP', 'en')
    assert.deepEqual(none, { text: '\u2014', none: true, key: 'none', params: { currency: 'GBP' } })
    assert.equal(costSecondCell(null).text, '\u2014')
  })
  it('costSecondCell: the total row (no rate of its own) has an amount and no rate title', () => {
    assert.deepEqual(costSecondCell({ secondMicros: 338_928_000 }, 'EUR', 'en'), { text: '€338.93', none: false, key: '', params: {} })
  })
  it('costFxRate: up to 4 decimals in the reader locale; no rate is blank', () => {
    assert.equal(costFxRate(0.923456, 'en'), '0.9235')
    assert.equal(costFxRate(150, 'en'), '150')
    assert.equal(costFxRate(10.5, 'fi'), '10,5')
    assert.equal(costFxRate(null), '')
    assert.equal(costFxRate(0), '')
  })
  it('costCurrency: ISO 4217 codes only, upper-cased', () => {
    assert.equal(costCurrency(' sek '), 'SEK')
    assert.equal(costCurrency('EURO'), '')
    assert.equal(costCurrency(null), '')
  })
  it('costCurrencyOptions: sorted, the default and the current pick always in, junk out', () => {
    assert.deepEqual(costCurrencyOptions({ default: 'EUR', currencies: ['SEK', 'GBP', 'x1', 'EUR'] }), { default: 'EUR', currencies: ['EUR', 'GBP', 'SEK'] })
    assert.deepEqual(costCurrencyOptions(null, 'jpy'), { default: 'EUR', currencies: ['EUR', 'JPY'] })
  })
  it('the mock converts at its rate for the asked currency, and answers that currency', () => {
    const b = mockTenantCostsBody('2026-09', '', NOW, 'SEK')
    assert.equal(b.second_currency, 'SEK')
    for (const p of b.parts) assert.equal(p.second_micros, Math.round(p.usd_micros * MOCK_FX_RATES.SEK))
    assert.equal(b.total.second_micros, b.parts.reduce((s, p) => s + p.second_micros, 0))
    assert.equal(b.parts[0].fx_rate_day, '2026-09-30')
    assert.equal(b.parts[0].fx_rate_first_day, '2026-09-01')
    assert.equal(mockTenantCostsBody('2026-09', '', NOW).second_currency, 'EUR', 'EUR unless picked')
  })
  it("the mock's norate scenario: the invoice row and the total have no rate", () => {
    const m = costMonthOf(mockTenantCosts('2026-09', { now: NOW, scenario: 'norate', currency: 'EUR' }))
    const inv = m.parts.find((p) => p.origin === 'invoice')
    assert.equal(inv.secondMicros, null)
    assert.equal(m.total.secondMicros, null)
    assert.ok(m.parts.filter((p) => p.origin !== 'invoice').every((p) => p.secondMicros !== null))
  })
  it('the mock currency list', () => {
    assert.deepEqual(mockFxCurrencies(), { default: 'EUR', currencies: Object.keys(MOCK_FX_RATES).sort() })
  })
})

describe('the chunk rule (spec 123 8: ci_initial_gzip_kb stays <= 155)', () => {
  const files = walk(join(WUI, 'src')).map((p) => relative(WUI, p))
  it('the pie is imported by the costs page only, and lazily', () => {
    const users = files.filter((f) => /MonitoringCostsPie/.test(read(f)) && !f.endsWith('MonitoringCostsPie.vue'))
    assert.deepEqual(users, ['src/pages/reporting/costs/spend.vue'])
    const page = read('src/pages/reporting/costs/spend.vue')
    assert.match(page, /defineAsyncComponent\(\(\) => import\('@\/components\/MonitoringCostsPie\.vue'\)\)/)
    assert.doesNotMatch(page, /^import .*MonitoringCostsPie/m)
  })
  it('tenant-costs.mjs is statically imported by the costs page only; the client loads it on call', () => {
    const statics = files.filter((f) => /^import [^\n]*from '[^']*tenant-costs\.mjs'/m.test(read(f)))
    assert.deepEqual(statics, ['src/pages/reporting/costs/spend.vue'])
    assert.match(read('src/utils/spool-client-lazy.mjs'), /await import\('\.\/tenant-costs\.mjs'\)/)
    assert.doesNotMatch(read('src/utils/spool-client.mjs'), /tenant-costs/)
  })
  it('the second-currency setting loads tenant-costs.mjs on demand, inside the lazy Appearance section', () => {
    assert.match(read('src/components/SecondCurrencySetting.vue'), /await import\('~\/utils\/tenant-costs\.mjs'\)/)
    assert.match(read('src/components/SettingsDialog.vue'), /appearance: defineAsyncComponent\(\(\) => import\('~\/components\/settings\/appearance\.vue'\)\)/)
    const users = files.filter((f) => /SecondCurrencySetting/.test(read(f)) && !f.endsWith('SecondCurrencySetting.vue'))
    assert.deepEqual(users, ['src/components/settings/appearance.vue'])
  })
  it('no chart library (spec 123 5)', () => {
    assert.equal((read('package.json').match(/chart|echarts|d3/gi) || []).length, 0)
  })
})
