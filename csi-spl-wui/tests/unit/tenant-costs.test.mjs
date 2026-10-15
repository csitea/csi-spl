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
  COST_PIE_COLORS,
  COST_PIE_OTHER_COLOR,
  costCoverageRows,
  costEmptySources,
  costMoney,
  costMonthOf,
  costMonthOptions,
  costPieArc,
  costPieSlices,
  costSliceColor,
  costUnits,
  costsQuery,
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

describe('the chunk rule (spec 123 8: ci_initial_gzip_kb stays <= 155)', () => {
  const files = walk(join(WUI, 'src')).map((p) => relative(WUI, p))
  it('the pie is imported by the costs page only, and lazily', () => {
    const users = files.filter((f) => /MonitoringCostsPie/.test(read(f)) && !f.endsWith('MonitoringCostsPie.vue'))
    assert.deepEqual(users, ['src/pages/monitoring/costs/index.vue'])
    const page = read('src/pages/monitoring/costs/index.vue')
    assert.match(page, /defineAsyncComponent\(\(\) => import\('@\/components\/MonitoringCostsPie\.vue'\)\)/)
    assert.doesNotMatch(page, /^import .*MonitoringCostsPie/m)
  })
  it('tenant-costs.mjs is statically imported by the costs page only; the client loads it on call', () => {
    const statics = files.filter((f) => /^import [^\n]*from '[^']*tenant-costs\.mjs'/m.test(read(f)))
    assert.deepEqual(statics, ['src/pages/monitoring/costs/index.vue'])
    assert.match(read('src/utils/spool-client-lazy.mjs'), /await import\('\.\/tenant-costs\.mjs'\)/)
    assert.doesNotMatch(read('src/utils/spool-client.mjs'), /tenant-costs/)
  })
  it('no chart library (spec 123 5)', () => {
    assert.equal((read('package.json').match(/chart|echarts|d3/gi) || []).length, 0)
  })
})
