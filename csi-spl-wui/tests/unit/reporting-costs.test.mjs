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
} from '../../src/utils/reporting-costs.mjs'
import { reportingTabFor } from '../../src/utils/reporting-tabs.mjs'
import { legacyMonitoringPath, monitoringTabFor } from '../../src/utils/monitoring-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const ids = (pages) => pages.map((p) => p.id)

describe('the pages (section 3.2; SPL-5312 the four labels)', () => {
  it('Total (default), Persons, Cloud, Tokens, each its own path and page file (its own chunk)', () => {
    assert.deepEqual(COSTS_PAGES.map((p) => [p.id, p.path]), [
      ['total', '/reporting/costs/total'], ['persons', '/reporting/costs/persons'], ['cloud', '/reporting/costs/cloud'], ['tokens', '/reporting/costs/tokens'],
    ])
    assert.equal(COSTS_DEFAULT_PATH, '/reporting/costs/total')
    for (const p of COSTS_PAGES) {
      assert.ok(existsSync(join(WUI, 'src/pages' + p.path + '.vue')), p.path)
      assert.equal(p.labelKey, 'reporting.costs.label.' + p.id)
    }
    /* no page is imported by hand: Nuxt makes each route its own chunk */
    for (const f of walk('src')) assert.doesNotMatch(read(f), /import [^\n]*pages\/reporting\/costs\//, f)
  })
  it('every costs reader sees the four labels (the hub scopes the money to the workspace)', () => {
    for (const who of [undefined, {}, { operator: false }, { operator: true }]) assert.deepEqual(ids(visibleCostsPages(who)), ['total', 'persons', 'cloud', 'tokens'], JSON.stringify(who))
    /* CONTROL: before SPL-5312 Cloud and Price were the operator admin's only */
    assert.equal(COSTS_PAGES.some((p) => p.operatorsOnly), false)
  })
  it('costsPageFor: the page a route is on, locale prefix or not; the Reporting tab is Costs', () => {
    assert.equal(costsPageFor('/reporting/costs/total'), 'total')
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
      '/reporting/costs': '/reporting/costs/total',
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
    assert.match(c2, /costsPeriod\(route\.query\.month, new Date\(\)\)/)
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

function walk(rel) {
  const out = []
  for (const e of readdirSync(join(WUI, rel), { withFileTypes: true })) {
    const p = rel + '/' + e.name
    if (e.isDirectory()) out.push(...walk(p))
    else if (/\.(vue|ts|mjs|js)$/.test(e.name)) out.push(p)
  }
  return out
}
