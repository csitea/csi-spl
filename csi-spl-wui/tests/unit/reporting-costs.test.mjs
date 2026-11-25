// Spec 143 costs-redesign.md 3.2 and 5, slice S1 (SPL-3798, owner HUM-10,
// t1 1be0e370, msg 3f1c7128, answers 2 A and 6 A): Reporting -> Costs, its
// pages (six since SPL-4187: Cloud, AI tokens and Human, each a section of
// its own), the header's month and currency, and the redirect table.
// SPL-5312 (owner HUM-10, t1 41a74806): the four labels Total, Persons,
// Cloud and Tokens for every costs reader; the period is one of the last 12
// months or the year to date; Spend, Human and Price redirect to their label.
//
// Run: node --test tests/unit/reporting-costs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  COSTS_PAGES, COSTS_DEFAULT_PATH, COSTS_REDIRECTS, COSTS_YTD, COSTS_L12M, visibleCostsPages, costsPageFor, legacyCostsPath,
  costsMonth, costsMonthOptions, costsPeriod, costsPeriodMonths, costsCurrencyOptions, costsCurrency, costsQueryWith,
  COSTS_RANGE_MAX, costsMonthsBetween, costsRange, costsPeriodOf, costsRangeOf, costsRangeEnds,
} from '../../src/utils/reporting-costs.mjs'
import { reportingTabFor } from '../../src/utils/reporting-tabs.mjs'
import { costProjectOf, costProjectQuery, mockCostProject } from '../../src/utils/cost-project.mjs'
import { legacyMonitoringPath, monitoringTabFor } from '../../src/utils/monitoring-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const ids = (pages) => pages.map((p) => p.id)

describe('the pages (section 3.2; SPL-5312 the four labels; spec 123 P05 the project\'s cost first)', () => {
  it('The project\'s cost (default, SPL-6117 Q-9 A), Total, Persons, Cloud, Tokens, each its own path and page file (its own chunk)', () => {
    assert.deepEqual(COSTS_PAGES.map((p) => [p.id, p.path]), [
      ['project', '/reporting/costs/project'], ['total', '/reporting/costs/total'], ['persons', '/reporting/costs/persons'], ['cloud', '/reporting/costs/cloud'], ['tokens', '/reporting/costs/tokens'],
      ['taxes', '/reporting/costs/taxes'],
    ])
    assert.equal(COSTS_DEFAULT_PATH, '/reporting/costs/project')
    for (const p of COSTS_PAGES) {
      assert.ok(existsSync(join(WUI, 'src/pages' + p.path + '.vue')), p.path)
      assert.equal(p.labelKey, 'reporting.costs.label.' + p.id)
    }
    /* no page is imported by hand: Nuxt makes each route its own chunk */
    for (const f of walk('src')) assert.doesNotMatch(read(f), /import [^\n]*pages\/reporting\/costs\//, f)
  })
  it('every costs reader sees the five labels (the hub scopes the money to the workspace)', () => {
    for (const who of [undefined, {}, { operator: false }, { operator: true }, { taxReader: false }]) assert.deepEqual(ids(visibleCostsPages(who)), ['project', 'total', 'persons', 'cloud', 'tokens'], JSON.stringify(who))
    /* SPL-6438: Taxes, last, only for a reader of the tax workspace (the probe's 2xx) */
    assert.deepEqual(ids(visibleCostsPages({ taxReader: true })), ['project', 'total', 'persons', 'cloud', 'tokens', 'taxes'])
    assert.equal(costsPageFor('/fi/reporting/costs/taxes'), 'taxes')
    /* CONTROL: before SPL-5312 Cloud and Price were the operator admin's only */
    assert.equal(COSTS_PAGES.some((p) => p.operatorsOnly), false)
  })
  it('costsPageFor: the page a route is on, locale prefix or not; the Reporting tab is Costs', () => {
    assert.equal(costsPageFor('/reporting/costs/total'), 'total')
    assert.equal(costsPageFor('/et/reporting/costs/project'), 'project')
    assert.equal(costsPageFor('/fi/reporting/costs/persons'), 'persons')
    /* the pages before the labels and Paid items are no Costs page: they redirect */
    for (const p of ['/reporting/costs/spend', '/reporting/costs/human', '/reporting/costs/price', '/reporting/costs/paid', '/reporting/costs', '/reporting/costs/totalx']) assert.equal(costsPageFor(p), null, p)
    for (const p of ['/reporting/costs', '/reporting/costs/cloud', '/sv/reporting/costs/tokens']) assert.equal(reportingTabFor(p), 'costs', p)
  })
})

describe('the redirect table (section 5 "Links")', () => {
  it('the old paths, each to its label or (SPL-4382) Paid items to Expenses -> AI costs, never a 404', () => {
    assert.deepEqual({ ...COSTS_REDIRECTS }, {
      '/monitoring/costs': '/reporting/costs/total',
      '/reporting/tokens': '/reporting/costs/tokens',
      '/reporting/costs': '/reporting/costs/project',
      '/reporting/costs/spend': '/reporting/costs/total',
      '/reporting/costs/human': '/reporting/costs/persons',
      '/reporting/costs/price': '/reporting/costs/tokens',
      '/reporting/costs/paid': '/expenses/ai',
    })
    /* every old Costs path keeps a page file (the route matches, then redirects) */
    for (const from of Object.keys(COSTS_REDIRECTS).filter((f) => f.startsWith('/reporting/costs/'))) {
      assert.match(read('src/pages' + from + '.vue'), /<LegacyMonitoringRedirect \/>/, from)
    }
    for (const [from, to] of Object.entries(COSTS_REDIRECTS)) {
      assert.equal(legacyCostsPath(from), to, from)
      assert.equal(legacyCostsPath('/nl' + from), to, 'locale ' + from)
      assert.equal(legacyCostsPath(from + '/'), to, 'slash ' + from)
    }
  })
  it('/monitoring/tokens stays (live burn), and no Costs page redirects (no loop)', () => {
    assert.equal(legacyCostsPath('/monitoring/tokens'), null)
    for (const p of COSTS_PAGES) assert.equal(legacyCostsPath(p.path), null, p.path)
    for (const p of ['/monitoring', '/reporting', '/monitoring/costsx', '/reporting/tokensx', '/monitoring/costs/x']) assert.equal(legacyCostsPath(p), null, p)
    /* the Monitoring table does not claim the Costs links, so the two never disagree */
    for (const from of Object.keys(COSTS_REDIRECTS)) assert.equal(legacyMonitoringPath(from), null, from)
  })
  it('the old pages redirect through LegacyMonitoringRedirect, which keeps the query (?month=) and asks the Costs table', () => {
    for (const f of ['src/pages/monitoring/costs/index.vue', 'src/pages/reporting/tokens.vue']) assert.match(read(f), /<LegacyMonitoringRedirect \/>/, f)
    const r = read('src/components/LegacyMonitoringRedirect.vue')
    assert.match(r, /legacyMonitoringPath\(route\.path\) \|\| legacyCostsPath\(route\.path\)/)
    assert.match(r, /navigateTo\(\{ path: localePath\(to\), query: route\.query, hash: route\.hash \}, \{ replace: true \}\)/)
    /* /reporting/costs lands on Total from its own page, query kept, a Costs page itself never redirected */
    const c = read('src/pages/reporting/costs.vue')
    assert.match(c, /const to = costsPageFor\(p\) \? null : legacyCostsPath\(p\)/)
    assert.match(c, /navigateTo\(\{ path: localePath\(to\), query: route\.query, hash: route\.hash \}, \{ replace: true \}\)/)
    /* SPL-3986: the Monitoring Costs tab is gone; its path is only the redirect */
    assert.equal(monitoringTabFor('/monitoring/costs'), null)
  })
})

describe('the header: one period, one currency, in the query', () => {
  const NOW = new Date(Date.UTC(2026, 10, 11, 10))
  it('SPL-5312: the months are the current one and the 11 before it', () => {
    const m = costsMonthOptions(NOW)
    assert.equal(m.length, 12)
    assert.deepEqual([m[0], m[11]], ['2026-11', '2025-12'])
    /* CONTROL: the floor of October 2026 is gone, the owner asked for the last 12 months */
    assert.ok(m.includes('2026-09') && m.includes('2026-01'))
  })
  it('a URL month older than 12 is kept (an old link never rewritten); a future or bad one is not', () => {
    assert.deepEqual(costsMonthOptions(NOW, '2025-03').slice(-1), ['2025-03'])
    assert.equal(costsMonthOptions(NOW, '2026-12').length, 12)
    assert.equal(costsMonthOptions(NOW, '2026-13').length, 12)
    assert.equal(costsMonth(['2026-09', 'x']), '2026-09')
    assert.equal(costsMonth('26-09'), '')
  })
  it('SPL-5312: the period is a month or the year to date; the year to date reads January to now', () => {
    assert.equal(costsPeriod(COSTS_YTD, NOW), 'ytd')
    assert.equal(costsPeriod('2026-09', NOW), '2026-09')
    assert.equal(costsPeriod('2026-12', NOW), '', 'a future month is no period')
    assert.equal(costsPeriod(undefined, NOW), '')
    assert.deepEqual(costsPeriodMonths('ytd', NOW), ['2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11'])
    assert.deepEqual(costsPeriodMonths('ytd', new Date(Date.UTC(2027, 0, 2))), ['2027-01'])
    assert.deepEqual(costsPeriodMonths('2026-09', NOW), ['2026-09'])
    assert.deepEqual(costsPeriodMonths('', NOW), ['2026-11'])
  })
  it('SPL-5433 step b: the last 12 months is the picker\'s 12, oldest first', () => {
    assert.equal(costsPeriod(COSTS_L12M, NOW), 'l12m')
    assert.equal(costsPeriod(['l12m'], NOW), 'l12m')
    assert.deepEqual(costsPeriodMonths('l12m', NOW), ['2025-12', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11'])
    assert.deepEqual(costsPeriodMonths('l12m', new Date(Date.UTC(2027, 0, 2))).slice(0, 2), ['2026-02', '2026-03'])
    assert.deepEqual(costsQueryWith({}, { month: 'l12m', current: '2026-11' }), { month: 'l12m' })
  })
  it('currency: USD (default) or the reader\'s second currency, EUR unless picked', () => {
    assert.deepEqual(costsCurrencyOptions(''), ['USD', 'EUR'])
    assert.deepEqual(costsCurrencyOptions('SEK'), ['USD', 'SEK'])
    assert.deepEqual(costsCurrencyOptions('USD'), ['USD'])
    assert.equal(costsCurrency(undefined, ['USD', 'SEK']), 'USD')
    assert.equal(costsCurrency('SEK', ['USD', 'SEK']), 'SEK')
    assert.equal(costsCurrency('GBP', ['USD', 'SEK']), 'USD', 'a currency no longer offered falls back to USD')
  })
  it('a pick writes the query; the defaults leave it; other keys stay', () => {
    assert.deepEqual(costsQueryWith({ x: '1' }, { month: '2026-09', current: '2026-10' }), { x: '1', month: '2026-09' })
    assert.deepEqual(costsQueryWith({ month: '2026-09' }, { month: '2026-10', current: '2026-10' }), {})
    assert.deepEqual(costsQueryWith({ month: '2026-09' }, { currency: 'EUR' }), { month: '2026-09', currency: 'EUR' })
    assert.deepEqual(costsQueryWith({ currency: 'EUR' }, { currency: 'USD' }), {})
    assert.deepEqual(costsQueryWith({ month: '2026-09' }, { month: 'ytd', current: '2026-11' }), { month: 'ytd' })
  })
  it('the header and the page bar: the query carried, no :style (CSP), the strings from the catalogue', () => {
    const h = read('src/components/reporting/costs/CostsHeader.vue')
    assert.match(h, /data-test="costs-header-month"/)
    assert.match(h, /role="radiogroup"/)
    const c = read('src/pages/reporting/costs.vue')
    assert.match(c, /:to="\{ path: localePath\(page\.path\), query: carried \}"/)
    for (const f of ['src/components/reporting/costs/CostsHeader.vue', 'src/pages/reporting/costs.vue', ...COSTS_PAGES.map((p) => 'src/pages' + p.path + '.vue')]) {
      assert.doesNotMatch(read(f), /:style=|v-bind:style/, f)
    }
    /* the labels read the header's period, they have no picker of their own */
    const c2 = read('src/composables/useCostsPeriod.ts')
    assert.match(c2, /costsPeriodOf\(route\.query, new Date\(\)\)/)
    assert.doesNotMatch(read('src/components/reporting/costs/CostsLabel.vue'), /<select/)
    assert.match(h, /:value="COSTS_YTD"/)
    assert.match(h, /:value="COSTS_L12M"/)
  })
  it('every new string is in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const keys = ['reporting.tab.costs', 'reporting.costs.pages_label', 'reporting.costs.currency', ...COSTS_PAGES.map((p) => p.labelKey),
      ...['label.other', 'period', 'period_ytd', 'period_l12m', 'col_item', 'col_share', 'pie_label', 'table_label', 'no_pie', 'empty', 'no_split', 'tokens_sub', 'price_link'].map((k) => 'reporting.costs.' + k)]
    const files = readdirSync(dir).filter((x) => x.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const cat = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const key of keys) assert.equal(typeof key.split('.').reduce((o, k) => o?.[k], cat), 'string', f + ': ' + key)
    }
  })
})

describe('SPL-6300: a start month and an end month, both included, in the URL', () => {
  const NOW = new Date(Date.UTC(2026, 10, 23, 10))
  it('?from=&to= is the range; its months oldest first, both ends included', () => {
    assert.deepEqual(costsRange({ from: '2026-09', to: '2026-11' }, NOW), { from: '2026-09', to: '2026-11' })
    assert.equal(costsPeriodOf({ from: '2026-09', to: '2026-11' }, NOW), '2026-09..2026-11')
    assert.deepEqual(costsPeriodMonths('2026-09..2026-11', NOW), ['2026-09', '2026-10', '2026-11'])
    assert.deepEqual(costsPeriodMonths(costsPeriodOf({ from: '2025-11', to: '2026-02' }, NOW), NOW), ['2025-11', '2025-12', '2026-01', '2026-02'])
    assert.deepEqual(costsRangeOf('2026-09..2026-11'), { from: '2026-09', to: '2026-11' })
    assert.equal(costsRangeOf('2026-09'), null)
    assert.equal(costsRangeOf('ytd'), null)
  })
  it('the owner\'s link (msg 8f58db07): cloud?from=2026-01&to=2026-06 reads those six months', () => {
    const q = Object.fromEntries(new URL('https://x.example.com/reporting/costs/cloud?from=2026-01&to=2026-06').searchParams)
    assert.deepEqual(costsPeriodMonths(costsPeriodOf(q, NOW), NOW), ['2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06'])
  })
  it('from = to is that one month; no range is ?month= as before (the current month by default)', () => {
    assert.equal(costsPeriodOf({ from: '2026-09', to: '2026-09' }, NOW), '2026-09')
    assert.equal(costsPeriodOf({ month: 'ytd' }, NOW), 'ytd')
    assert.equal(costsPeriodOf({ month: '2026-10' }, NOW), '2026-10')
    assert.equal(costsPeriodOf({}, NOW), '')
    assert.deepEqual(costsPeriodMonths(costsPeriodOf({}, NOW), NOW), ['2026-11'])
    /* the range wins over a stale month */
    assert.equal(costsPeriodOf({ month: '2026-01', from: '2026-09', to: '2026-10' }, NOW), '2026-09..2026-10')
  })
  it('a bad range is no range: from after to, a future end, a bad shape, one end, more than 24 months', () => {
    for (const q of [{ from: '2026-11', to: '2026-09' }, { from: '2026-11', to: '2026-12' }, { from: '2026-9', to: '2026-11' },
      { from: '2026-09' }, { to: '2026-09' }, { from: '2024-11', to: '2026-11' }]) {
      assert.equal(costsRange(q, NOW), null, JSON.stringify(q))
      assert.equal(costsRangeOf(costsPeriodOf(q, NOW)), null, JSON.stringify(q))
    }
    assert.equal(COSTS_RANGE_MAX, 24)
    assert.deepEqual(costsRange({ from: '2024-12', to: '2026-11' }, NOW), { from: '2024-12', to: '2026-11' })
    assert.equal(costsMonthsBetween('2024-12', '2026-11').length, 24)
  })
  it('a range pick writes from and to and drops month; the current month both ends leaves the URL; a month pick drops the range', () => {
    assert.deepEqual(costsQueryWith({ month: 'ytd', currency: 'EUR' }, { from: '2026-09', to: '2026-11', current: '2026-11' }),
      { currency: 'EUR', from: '2026-09', to: '2026-11' })
    assert.deepEqual(costsQueryWith({ from: '2026-09', to: '2026-11' }, { from: '2026-11', to: '2026-11', current: '2026-11' }), {})
    assert.deepEqual(costsQueryWith({ from: '2026-09', to: '2026-11', x: '1' }, { month: 'l12m', current: '2026-11' }), { x: '1', month: 'l12m' })
    /* CONTROL: the query a pick writes reads back as the same range */
    assert.equal(costsPeriodOf(costsQueryWith({}, { from: '2026-02', to: '2026-04', current: '2026-11' }), NOW), '2026-02..2026-04')
  })
  it('one end picked: the other follows when they would cross or span over 24 months', () => {
    assert.deepEqual(costsRangeEnds({ from: '2026-09', to: '2026-10' }, 'from', '2026-11'), { from: '2026-11', to: '2026-11' })
    assert.deepEqual(costsRangeEnds({ from: '2026-09', to: '2026-10' }, 'to', '2026-05'), { from: '2026-05', to: '2026-05' })
    assert.deepEqual(costsRangeEnds({ from: '2026-09', to: '2026-10' }, 'from', '2026-02'), { from: '2026-02', to: '2026-10' })
    assert.deepEqual(costsRangeEnds({ from: '2026-11', to: '2026-11' }, 'from', '2023-01'), { from: '2023-01', to: '2024-12' })
    assert.deepEqual(costsRangeEnds({ from: '2023-01', to: '2023-02' }, 'to', '2026-11'), { from: '2024-12', to: '2026-11' })
  })
  it('the project\'s cost asks the hub for the range in one read (period range)', () => {
    assert.equal(costProjectQuery({ from: '2026-09', to: '2026-11' }), '?from=2026-09&to=2026-11')
    assert.equal(costProjectQuery({ month: '2026-09' }), '?month=2026-09')
    assert.equal(costProjectQuery({ from: '2026-09' }), '', 'one end is no range')
    const r = costProjectOf(mockCostProject({ from: '2026-09', to: '2026-11' }, { now: NOW, scenario: '' }))
    assert.equal(r.period, 'range')
    assert.deepEqual([r.monthFrom, r.monthTo, r.from], ['2026-09', '2026-11', '2026-09-01'])
    /* CONTROL: one month stays the month answer */
    assert.equal(costProjectOf(mockCostProject({ month: '2026-09' }, { now: NOW, scenario: '' })).period, 'month')
  })
  it('the header draws both pickers from the catalogue; the shell and the project page carry from and to', () => {
    const h = read('src/components/reporting/costs/CostsHeader.vue')
    for (const s of ['data-test="costs-range-from"', 'data-test="costs-range-to"', "t('reporting.costs.range_from')", "t('reporting.costs.range_to')", "t('reporting.costs.range_label')"]) assert.ok(h.includes(s), s)
    for (const f of ['src/pages/reporting/costs.vue', 'src/pages/reporting/costs/project.vue']) assert.match(read(f), /\['month', 'from', 'to', 'currency'\]/, f)
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const c = JSON.parse(readFileSync(join(dir, f), 'utf8')).reporting.costs
      for (const k of ['range_label', 'range_from', 'range_to', 'range_name']) assert.equal(typeof c[k], 'string', f + ': ' + k)
      assert.match(c.range_name, /\{from\}.*\{to\}/, f)
    }
  })
})

function walk(rel) {
  const out = []
  for (const e of readdirSync(join(WUI, rel), { withFileTypes: true })) {
    const p = rel + '/' + e.name
    if (e.isDirectory()) out.push(...walk(p))
    else if (/\.(vue|ts|mjs|js)$/.test(e.name)) out.push(p)
  }
  return out
}
