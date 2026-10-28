// Spec 143 costs-redesign.md 3.2 and 5, slice S1 (SPL-3798, owner HUM-10,
// t1 1be0e370, msg 3f1c7128, answers 2 A and 6 A): Reporting -> Costs, its
// four pages, the header's month and currency, and the redirect table.
//
// Run: node --test tests/unit/reporting-costs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  COSTS_PAGES, COSTS_DEFAULT_PATH, COSTS_REDIRECTS, COSTS_FIRST_MONTH, visibleCostsPages, costsPageFor, legacyCostsPath,
  costsMonth, costsMonthOptions, costsCurrencyOptions, costsCurrency, costsQueryWith,
} from '../../src/utils/reporting-costs.mjs'
import { reportingTabFor } from '../../src/utils/reporting-tabs.mjs'
import { legacyMonitoringPath, monitoringTabFor } from '../../src/utils/monitoring-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const ids = (pages) => pages.map((p) => p.id)

describe('the four pages (section 3.2)', () => {
  it('Spend (default), Tokens, Price per token, Paid items, each its own path and page file (its own chunk)', () => {
    assert.deepEqual(COSTS_PAGES.map((p) => [p.id, p.path]), [
      ['spend', '/reporting/costs/spend'], ['tokens', '/reporting/costs/tokens'],
      ['price', '/reporting/costs/price'], ['paid', '/reporting/costs/paid'],
    ])
    assert.equal(COSTS_DEFAULT_PATH, '/reporting/costs/spend')
    for (const p of COSTS_PAGES) {
      assert.ok(existsSync(join(WUI, 'src/pages' + p.path + '.vue')), p.path)
      assert.equal(p.labelKey, 'reporting.costs.page.' + p.id)
    }
    /* no page is imported by hand: Nuxt makes each route its own chunk */
    for (const f of walk('src')) assert.doesNotMatch(read(f), /import [^\n]*pages\/reporting\/costs\//, f)
  })
  it('Price per token and Paid items for an operator admin only; Spend and Tokens for every costs reader', () => {
    assert.deepEqual(ids(visibleCostsPages({ operator: true })), ['spend', 'tokens', 'price', 'paid'])
    /* CONTROL: anyone else, or not known yet */
    for (const who of [undefined, {}, { operator: false }]) assert.deepEqual(ids(visibleCostsPages(who)), ['spend', 'tokens'], JSON.stringify(who))
  })
  it('costsPageFor: the page a route is on, locale prefix or not; the Reporting tab is Costs', () => {
    assert.equal(costsPageFor('/reporting/costs/spend'), 'spend')
    assert.equal(costsPageFor('/fi/reporting/costs/paid'), 'paid')
    assert.equal(costsPageFor('/reporting/costs'), null)
    assert.equal(costsPageFor('/reporting/costs/spendx'), null)
    for (const p of ['/reporting/costs', '/reporting/costs/price', '/sv/reporting/costs/tokens']) assert.equal(reportingTabFor(p), 'costs', p)
  })
})

describe('the redirect table (section 5 "Links")', () => {
  it('three old paths, each to its Costs page', () => {
    assert.deepEqual({ ...COSTS_REDIRECTS }, {
      '/monitoring/costs': '/reporting/costs/spend',
      '/reporting/tokens': '/reporting/costs/tokens',
      '/reporting/costs': '/reporting/costs/spend',
    })
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
    /* /reporting/costs lands on Spend from its own page, query kept, a Costs page itself never redirected */
    const c = read('src/pages/reporting/costs.vue')
    assert.match(c, /const to = costsPageFor\(p\) \? null : legacyCostsPath\(p\)/)
    assert.match(c, /navigateTo\(\{ path: localePath\(to\), query: route\.query, hash: route\.hash \}, \{ replace: true \}\)/)
    /* SPL-3986: the Monitoring Costs tab is gone; its path is only the redirect */
    assert.equal(monitoringTabFor('/monitoring/costs'), null)
  })
})

describe('the header: one month, one currency, in the query', () => {
  const NOW = new Date(Date.UTC(2026, 9, 27, 10))
  it('months from the current one back to the first month holding a cost line', () => {
    assert.equal(COSTS_FIRST_MONTH, '2026-10')
    assert.deepEqual(costsMonthOptions(NOW), ['2026-10'])
    assert.deepEqual(costsMonthOptions(new Date(Date.UTC(2027, 0, 3))), ['2027-01', '2026-12', '2026-11', '2026-10'])
    const far = costsMonthOptions(new Date(Date.UTC(2028, 5, 1)))
    assert.equal(far.length, 12, 'at most 12')
    assert.equal(far[0], '2028-06')
    /* CONTROL: the old picker's 12 months back would offer 2025-11 today */
    assert.equal(costsMonthOptions(NOW).includes('2025-11'), false)
  })
  it('a URL month before the first line is kept (an old link never rewritten); a future or bad one is not', () => {
    assert.deepEqual(costsMonthOptions(NOW, undefined, '2026-09'), ['2026-10', '2026-09'])
    assert.deepEqual(costsMonthOptions(NOW, undefined, '2026-11'), ['2026-10'])
    assert.deepEqual(costsMonthOptions(NOW, undefined, '2026-13'), ['2026-10'])
    assert.equal(costsMonth(['2026-09', 'x']), '2026-09')
    assert.equal(costsMonth('26-09'), '')
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
    /* the Spend page reads the header's month, it has no picker of its own */
    const s = read('src/pages/reporting/costs/spend.vue')
    assert.doesNotMatch(s, /data-test="costs-month"/)
    assert.match(s, /costsMonth\(route\.query\.month\)/)
  })
  it('every new string is in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const keys = ['reporting.tab.costs', 'reporting.costs.pages_label', 'reporting.costs.currency', 'reporting.costs.coming', ...COSTS_PAGES.map((p) => p.labelKey)]
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
