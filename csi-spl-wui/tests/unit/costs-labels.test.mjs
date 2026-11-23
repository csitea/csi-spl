// SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806,
// 2026-11-11): Reporting -> Costs is four labels, Total, Persons, Cloud and
// Tokens; each a pie (value and share) and a table per month of the period,
// sortable by any column. utils/costs-labels.mjs makes the rows from the
// hub's month answers, the one function a workspace's numbers go through.
//
// Run: node --test tests/unit/costs-labels.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  COSTS_LABEL_IDS, costLabelOf, costsLabelRows, costsColumnTotals, costsLabelSlices, costsSortRows, costsNextSort, costsDayRows, costsWorkspaceBurn, costsCellSum,
} from '../../src/utils/costs-labels.mjs'
import { costMonthOf, mockTenantCostsBody } from '../../src/utils/tenant-costs.mjs'
import { cloudDaysOf, mockCloudDays } from '../../src/utils/costs-sections.mjs'

const NOW = new Date(Date.UTC(2026, 10, 11, 10))
const month = (m, scenario = 'entries', cur = 'EUR') => costMonthOf(mockTenantCostsBody(m, scenario, NOW, cur))
const SEP = month('2026-09')
const OCT = month('2026-10')
const keys = (rows) => rows.map((r) => r.key)

describe('which label a cost counts under', () => {
  it('hr entries are Persons; GCP and cloud entries Cloud; token burn, paid AI items and a share Tokens; the rest other', () => {
    assert.deepEqual(COSTS_LABEL_IDS, ['total', 'persons', 'cloud', 'tokens'])
    const of = (source, kind) => costLabelOf({ source, kind })
    assert.equal(of('cost_entry', 'hr'), 'persons')
    assert.equal(of('cost_entry', 'cloud'), 'cloud')
    assert.equal(of('gcp', 'cloud_run'), 'cloud')
    for (const s of ['fleet_tokens', 'fleet_tokens.box-a', 'ai_paid', 'ai_share']) assert.equal(of(s, 'x'), 'tokens', s)
    assert.equal(of('hand', 'subscription'), 'tokens', 'a paid AI invoice')
    assert.equal(of('agent_hours', 'agent_seconds'), 'other')
    /* the hand allocation (spec 143 costs-allocation.md) names its item's own source */
    assert.equal(costLabelOf({ source: 'allocated', allocatedSource: 'gcp', kind: 'compute' }), 'cloud')
  })
})

describe('the rows of each label, one month', () => {
  it('Total: Persons, Cloud, Tokens in that order, then other; shares of the positive totals', () => {
    const rows = costsLabelRows('total', [SEP])
    assert.deepEqual(keys(rows), ['persons', 'cloud', 'tokens', 'other'])
    const usd = Object.fromEntries(rows.map((r) => [r.key, r.total.v]))
    /* Persons = the priced hr entry (EUR 1200 / 0.92), the CHF one has no rate and is left out, said by `left` */
    assert.equal(usd.persons, 1_304_347_826)
    assert.equal(rows[0].total.left, 1)
    /* Cloud = the six GCP parts + the priced cloud entry; Tokens = the paid invoice ($200), the burn is $0 */
    assert.equal(usd.cloud, 168_400_000 + 70_434_783)
    assert.equal(usd.tokens, 200_000_000)
    assert.equal(usd.other, 0)
    const pct = rows.reduce((s, r) => s + (r.pct || 0), 0)
    assert.ok(Math.abs(pct - 100) <= 0.2, pct)
  })
  it('Total: a month with no person cost still lists Persons, at 0', () => {
    const rows = costsLabelRows('total', [month('2026-09', '')])
    assert.deepEqual(keys(rows), ['persons', 'cloud', 'tokens', 'other'])
    assert.equal(rows[0].total.v, 0)
  })
  it('Persons: one row per hr entry; the unpriced one a dash (null), never $0', () => {
    const rows = costsLabelRows('persons', [SEP])
    assert.deepEqual(keys(rows), ['hr:Design contract', 'hr:Support contract'])
    assert.equal(rows[1].total.v, null)
    assert.equal(rows[1].pct, null)
    assert.equal(rows[0].entryCurrency, 'EUR')
  })
  it('SPL-5546: a hand-entered row reads in the interface language, its key the master text; no label = the master text', () => {
    const bg = costMonthOf(mockTenantCostsBody('2026-09', 'entries', NOW, 'EUR', 'bg'))
    const rows = costsLabelRows('persons', [bg])
    assert.deepEqual(keys(rows), ['hr:Design contract', 'hr:Support contract'])
    assert.deepEqual(rows.map((r) => r.name), ['Договор за дизайн', 'Support contract'])
    assert.deepEqual(costsLabelRows('persons', [SEP]).map((r) => r.name), ['Design contract', 'Support contract'])
  })
  it('SPL-5433 step b: Persons is a row per hr group, its components summed, never a person', () => {
    const hr = (component, group, amount) => ({ estate: true, source: 'cost_entry', project_or_vendor: component + ' label', kind: 'hr', origin: 'hand',
      usd_micros: amount, eur_micros: amount, entry_micros: amount, entry_currency: 'EUR', component, group })
    const m = costMonthOf({ month: '2026-10', scope: 'estate', parts: [], human: [
      hr('monthly_salary', 'salaries_wages', 3_000_000), hr('hourly_pay', 'salaries_wages', 1_000_000),
      hr('tyel', 'employer_contributions', 500_000), { ...hr('', '', 200_000), project_or_vendor: 'Old free line' }] })
    const rows = costsLabelRows('persons', [m])
    assert.deepEqual(keys(rows), ['hr-group:salaries_wages', 'hr-group:employer_contributions', 'hr:Old free line'])
    assert.equal(rows[0].total.v, 4_000_000, 'the two salaries_wages components are one row')
    assert.equal(rows[0].group, 'salaries_wages')
    assert.equal(rows[2].group, undefined, 'a line without a component keeps its own label')
  })
  it('Cloud: one row per GCP project (its box apart) and per entry; a project drills to its services', () => {
    const rows = costsLabelRows('cloud', [SEP])
    assert.deepEqual(keys(rows), ['project-prd', 'entry:Workspace suite', 'project-all', 'project-dev', 'entry:Domain suite'])
    assert.equal(rows[0].drill, 'project')
    assert.equal(rows[1].drill, undefined)
    const svc = costsLabelRows('cloud', [SEP], { project: 'project-prd' })
    assert.deepEqual(keys(svc), ['cloud_sql', 'cloud_run', 'network'])
    assert.equal(svc.reduce((s, r) => s + r.total.v, 0), rows[0].total.v, 'the services sum to the project row')
  })
  it('Tokens: the token parts and the paid AI invoice, units and list price summed', () => {
    const rows = costsLabelRows('tokens', [SEP])
    assert.deepEqual(keys(rows), ['hand|llm-vendor|subscription', 'fleet_tokens|llm-vendor|tokens'])
    assert.equal(rows[1].units, 2.6e9)
    assert.equal(rows[1].listMicros, 1_200_000_000)
  })
  it('a customer workspace (scope workspace): Persons and Cloud have no rows; Tokens has its share', () => {
    const ws = costMonthOf(mockTenantCostsBody('2026-09', 'share', NOW, 'EUR'))
    assert.equal(ws.scope, 'workspace')
    assert.deepEqual(costsLabelRows('persons', [ws]), [])
    assert.deepEqual(costsLabelRows('cloud', [ws]), [])
    assert.deepEqual(keys(costsLabelRows('tokens', [ws])), ['ai_share|agy|share', 'ai_share|claude|share', 'fleet_tokens|claude|tokens'])
  })
})

describe('the currency and the period', () => {
  it('the second currency: each cell in it; a part with no rate blanks the cell (null), never a guess', () => {
    const eur = costsLabelRows('cloud', [SEP], { currency: 'EUR' })
    assert.equal(eur.find((r) => r.key === 'entry:Workspace suite').total.v, 64_800_000, 'an EUR entry is its own amount')
    const nr = costsLabelRows('tokens', [month('2026-09', 'norate')], { currency: 'EUR' })
    assert.equal(nr.find((r) => r.key.startsWith('hand|')).total.v, null)
  })
  it('several months: one cell per month, the row total their sum; an item missing in a month is an empty cell', () => {
    const one = { ...OCT, parts: OCT.parts.filter((p) => p.projectOrVendor !== 'project-dev') }
    const rows = costsLabelRows('cloud', [SEP, one])
    const dev = rows.find((r) => r.key === 'project-dev')
    assert.equal(dev.cells.length, 2)
    assert.equal(dev.cells[1].empty, true)
    assert.equal(dev.total.v, dev.cells[0].v)
    const prd = rows.find((r) => r.key === 'project-prd')
    assert.equal(prd.total.v, prd.cells[0].v + prd.cells[1].v)
    const foot = costsColumnTotals(rows, ['2026-09', '2026-10'])
    assert.equal(foot.cells.length, 2)
    assert.equal(foot.total.v, rows.reduce((s, r) => s + (r.total.v || 0), 0))
    assert.equal(foot.total.left, 2, 'the unpriced CHF entry, once per month')
  })
  it('a sum of cells: dashes only -> a dash; empty only -> empty', () => {
    assert.equal(costsCellSum([{ v: null, left: 1, empty: false }]).v, null)
    assert.equal(costsCellSum([{ v: 0, left: 0, empty: true }]).empty, true)
  })
  it('a sum that leaves out a cell with no amount counts it in none, through a nested sum (N1)', () => {
    const row = costsCellSum([{ v: 5, left: 0, empty: false }, { v: null, left: 0, empty: false }, { v: 0, left: 0, empty: true }])
    assert.equal(row.v, 5)
    assert.equal(row.none, 1)
    const allNone = costsCellSum([{ v: null, left: 0, empty: false }, { v: null, left: 0, empty: false }])
    assert.equal(allNone.v, null)
    assert.equal(allNone.none, 2)
    const foot = costsCellSum([row, allNone, { v: 3, left: 0, empty: false, none: 0 }])
    assert.equal(foot.v, 8)
    assert.equal(foot.none, 3)
    assert.equal(costsCellSum([{ v: 1, left: 0, empty: false }]).none, 0)
  })
})

describe('the pie', () => {
  it('one slice per item with money, its value and share; the slices close the turn', () => {
    const slices = costsLabelSlices(costsLabelRows('cloud', [SEP]))
    assert.deepEqual(slices.map((s) => s.key), ['project-prd', 'entry:Workspace suite', 'project-all', 'project-dev'])
    assert.ok(slices.every((s) => s.v > 0 && /^M /.test(s.d) && s.color))
    assert.ok(Math.abs(slices.reduce((s, x) => s + x.pct, 0) - 100) <= 0.2)
    /* CONTROL: no money, no pie */
    assert.deepEqual(costsLabelSlices(costsLabelRows('cloud', [month('2026-09', 'empty')])), [])
  })
})

describe('the sort', () => {
  const rows = costsLabelRows('cloud', [SEP])
  it('a money column: highest first on the first click, a dash last both ways', () => {
    const s = costsNextSort(null, 'total')
    assert.deepEqual(s, { col: 'total', dir: 'descending' })
    const down = keys(costsSortRows(rows, s.col, s.dir))
    assert.deepEqual(down, ['project-prd', 'entry:Workspace suite', 'project-all', 'project-dev', 'entry:Domain suite'])
    const up = keys(costsSortRows(rows, 'total', costsNextSort(s, 'total').dir))
    assert.deepEqual(up, ['project-dev', 'project-all', 'entry:Workspace suite', 'project-prd', 'entry:Domain suite'])
  })
  it('the name column: A-Z first, any case, numbers as numbers; a month column by its index', () => {
    assert.deepEqual(costsNextSort({ col: 'total', dir: 'descending' }, 'name'), { col: 'name', dir: 'ascending' })
    assert.deepEqual(keys(costsSortRows(rows, 'name', 'ascending')), ['entry:Domain suite', 'project-all', 'project-dev', 'project-prd', 'entry:Workspace suite'])
    assert.deepEqual(keys(costsSortRows(rows, 0, 'ascending')).at(-1), 'entry:Domain suite')
  })
})

describe('the day level and the burn per workspace', () => {
  it('Cloud day level: a service per day, one cell, oldest first', () => {
    const body = mockTenantCostsBody('2026-09', '', NOW, 'EUR')
    const days = cloudDaysOf(mockCloudDays(body, 'project-prd', { operator: true }))
    const rows = costsDayRows(days, 'cloud_sql', 'USD')
    assert.equal(rows.length, 30)
    assert.equal(rows[0].key, '2026-09-01')
    assert.equal(rows.reduce((s, r) => s + r.total.v, 0), 63_500_000)
  })
  it('the estate\'s token burn per workspace, summed over the months', () => {
    const burn = costsWorkspaceBurn([SEP, OCT])
    assert.equal(burn.length, 3)
    assert.equal(burn.find((w) => w.key === 'ws-alpha|claude').listValueMicros, 2 * 13_890_000)
  })
})

/*
 * SPL-6330: a workspace whose only cloud items come by a 10000 bp hand
 * allocation of estate GCP lines (spec 143 costs-allocation.md). The hub
 * answers each as source "allocated" with the item's own source in
 * allocated_source; the month parse must keep it, or the part counts as
 * "other" and Cloud shows nothing. RED CONTROL: costPartOf without
 * allocatedSource -> Cloud has no rows and Total's cloud is empty.
 */
describe('a workspace whose cloud comes only by an allocation (SPL-6330)', () => {
  const part = (pov, kind, usd) => ({
    estate: false, source: 'allocated', allocated_source: 'gcp', share_bp: 10000,
    project_or_vendor: pov, kind, origin: 'billing_export', units: 1, usd_micros: usd, eur_micros: usd, days: 30,
  })
  const body = (m, parts) => ({
    month: m, status: 'ended', scope: 'workspace', second_currency: 'EUR', days: 30, days_ended: 30,
    total: { usd_micros: parts.reduce((s, p) => s + p.usd_micros, 0), eur_micros: 0, second_micros: null }, parts, coverage: [],
  })
  const months = [
    costMonthOf(body('2026-07', [])),
    costMonthOf(body('2026-08', [part('proj-a', 'cloud_run', 2_000_000), part('proj-b', 'storage', 1_000_000)])),
    costMonthOf(body('2026-09', [part('proj-a', 'cloud_run', 3_000_000)])),
  ]
  it('the month parse keeps the allocated part\'s own source and share', () => {
    const p = months[1].parts[0]
    assert.equal(p.source, 'allocated')
    assert.equal(p.allocatedSource, 'gcp')
    assert.equal(p.shareBP, 10000)
  })
  it('Cloud lists each allocated project with its amounts; Total counts them as cloud', () => {
    const rows = costsLabelRows('cloud', months)
    assert.deepEqual(keys(rows), ['proj-a', 'proj-b'])
    assert.deepEqual(rows[0].cells.map((c) => c.v), [0, 2_000_000, 3_000_000])
    assert.equal(rows[0].total.v, 5_000_000)
    assert.equal(rows[1].total.v, 1_000_000)
    assert.equal(rows[0].drill, 'project')
    const total = costsLabelRows('total', months)
    assert.equal(total.find((r) => r.key === 'cloud').total.v, 6_000_000)
    assert.equal(total.find((r) => r.key === 'other'), undefined)
  })
  it('a project drills to its allocated services', () => {
    const rows = costsLabelRows('cloud', months, { project: 'proj-a' })
    assert.deepEqual(keys(rows), ['cloud_run'])
    assert.equal(rows[0].total.v, 5_000_000)
  })
  it('an allocated hand-entered cloud cost stays an entry row, never a GCP project', () => {
    const e = costMonthOf(body('2026-09', [{ ...part('shared bill', 'cloud', 4_000_000), allocated_source: 'cost_entry' }]))
    const rows = costsLabelRows('cloud', [e])
    assert.deepEqual(keys(rows), ['entry:shared bill'])
    assert.equal(rows[0].drill, undefined)
  })
})
