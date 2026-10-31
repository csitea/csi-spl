// Spec 143 costs-redesign.md 3.8 (SPL-4382; owner HUM-10, t1 4f48f878, msgs
// 4cea9710, b0ccc0aa, 50d84663; name poll 9fbea87a A): the Expenses section,
// a level-0 rail entry where costs are entered, one tab per cost type. Its
// rail entry, its tab list, the section page as each reader sees it, the old
// Paid items link and its strings.
//
// The page's template is the SHIPPED one, rendered with Vue's own compiler +
// server renderer for each role, so a page that drops the gate fails here.
//
// Run: node tests/unit/expenses-tabs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import { compile } from '@vue/compiler-dom'
import { renderToString } from 'vue/server-renderer'
import { EXPENSES_TABS, EXPENSES_DEFAULT_PATH, expensesTabFor, visibleExpensesTabs } from '../../src/utils/expenses-tabs.mjs'
import { EXPENSES_TAB, routeForTab, tabForPath } from '../../src/utils/sidebar-tabs.mjs'
import { isSectionPage } from '../../src/utils/section-strip.mjs'
import { COSTS_PAGES, legacyCostsPath } from '../../src/utils/reporting-costs.mjs'
import { importTs } from './lib/load-ts.mjs'

const { RAIL_TABS, RAIL_IDS, DEFAULT_RAIL_ORDER, railLabelKey } = await importTs('src/utils/rail-order.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const ids = (tabs) => tabs.map((x) => x.id)
const en = JSON.parse(read('i18n/locales/en.json'))
const t = (key) => key.split('.').reduce((o, k) => o?.[k], en)

/** Server-render the shipped pages/expenses.vue template; `operator` is the operator pane's probe. */
async function renderPage(operator) {
  const s = read('src/pages/expenses.vue')
  const template = s.slice(s.indexOf('<template>') + 10, s.lastIndexOf('</template>'))
  const code = compile(template, { mode: 'function', prefixIdentifiers: false }).code
  const fn = new Function('Vue', code)(Vue)
  const ctx = { t, localePath: (p) => p, operator: { visible: operator }, tabs: visibleExpensesTabs({ operator }), active: 'ai' }
  const scope = new Proxy({}, {
    has: (_, k) => typeof k === 'string' && !k.startsWith('_') && !(k in globalThis),
    get: (_, k) => (k in ctx ? ctx[k] : undefined),
  })
  const app = Vue.createSSRApp({ render: (_c, cache) => fn(scope, cache || []) })
  app.component('NuxtLink', { props: ['to'], setup: (p, { slots }) => () => Vue.h('a', { href: p.to }, slots.default?.()) })
  app.component('NuxtPage', { setup: () => () => Vue.h('div', { 'data-test': 'nuxt-page' }) })
  for (const c of ['MobileBack', 'SectionClose']) app.component(c, { setup: () => () => null })
  return renderToString(app)
}

describe('the Expenses rail entry', () => {
  it('one rail tab with its own icon and label, after Reporting, before Archive by default', () => {
    const tab = RAIL_TABS.find((x) => x.id === 'expenses')
    assert.deepEqual({ ...tab }, { id: 'expenses', icon: 'receipt', labelKey: 'sidebar.expenses' })
    for (const phone of [false, true]) assert.equal(railLabelKey(tab, phone), 'sidebar.expenses', 'phone ' + phone)
    assert.equal(RAIL_IDS.at(-1), 'expenses', 'last in RAIL_TABS, so an older stored order gets it appended')
    assert.deepEqual(DEFAULT_RAIL_ORDER.slice(-3), ['reporting', 'expenses', 'archive'])
    assert.match(read('src/utils/uiIcons.ts'), /\n {2}receipt: \[/)
  })
  it('opens /expenses and selects itself on every Expenses path, locale prefix or not', () => {
    assert.equal(EXPENSES_TAB, 'expenses')
    assert.equal(routeForTab('expenses'), '/expenses')
    for (const p of ['/expenses', '/expenses/ai', '/fi/expenses/cloud', '/expenses/hr']) assert.equal(tabForPath(p), 'expenses', p)
    /* CONTROL: a near miss is not Expenses */
    for (const p of ['/expensesx', '/reporting/costs/spend']) assert.notEqual(tabForPath(p), 'expenses', p)
  })
  it('the rail click and the rail-only sidebar are wired', () => {
    assert.match(read('src/composables/useSidebarRailNav.ts'), /next === EXPENSES_TAB && tabForPath\(route\.path\) !== EXPENSES_TAB\) await navigateTo\(localePath\('\/expenses'\)\)/)
    assert.match(read('src/composables/useSidebarRailOnly.ts'), /const expensesRailOnly = computed\(\(\) => tab\.value === EXPENSES_TAB\)/)
  })
})

describe('the tabs: one per cost type (owner msg 50d84663: "at least 3 different tabs")', () => {
  it('AI costs (default), Cloud infra costs, HR costs, each its own path and page file (its own chunk)', () => {
    assert.deepEqual(EXPENSES_TABS.map((x) => [x.id, x.path, x.labelKey]), [
      ['ai', '/expenses/ai', 'expenses.tab.ai'],
      ['cloud', '/expenses/cloud', 'expenses.tab.cloud'],
      ['hr', '/expenses/hr', 'expenses.tab.hr'],
    ])
    assert.equal(EXPENSES_DEFAULT_PATH, '/expenses/ai')
    for (const x of EXPENSES_TABS) assert.ok(existsSync(join(WUI, 'src/pages' + x.path + '.vue')), x.path)
  })
  it('AI costs holds the paid subscriptions and top-ups (the Paid card); Cloud and HR wait for their forms', () => {
    assert.match(read('src/pages/expenses/ai.vue'), /<div class="tk-lazy"><PaidItemsCard \/><\/div>/)
    assert.deepEqual(EXPENSES_TABS.map((x) => x.entry), [true, false, false])
    for (const id of ['cloud', 'hr']) assert.match(read(`src/pages/expenses/${id}.vue`), /t\('expenses\.coming'\)/, id)
  })
  it('operator admins only, as the Paid card was; anyone else sees no tab', () => {
    assert.deepEqual(ids(visibleExpensesTabs({ operator: true })), ['ai', 'cloud', 'hr'])
    /* CONTROL: anyone else, or not known yet */
    for (const who of [undefined, {}, { operator: false }]) assert.deepEqual(ids(visibleExpensesTabs(who)), [], JSON.stringify(who))
  })
  it('expensesTabFor: the tab a route is on; /expenses itself and other sections are none', () => {
    assert.equal(expensesTabFor('/expenses/ai'), 'ai')
    assert.equal(expensesTabFor('/sv/expenses/hr'), 'hr')
    assert.equal(expensesTabFor('/expenses/cloud/x'), 'cloud')
    for (const p of ['/expenses', '/expenses/aix', '/reporting/costs/paid']) assert.equal(expensesTabFor(p), null, p)
  })
  it('every Expenses path is a section page', () => {
    for (const p of ['/expenses', ...EXPENSES_TABS.map((x) => x.path), '/fi/expenses/ai']) assert.equal(isSectionPage(p), true, p)
  })
})

describe('the page as each reader sees it', () => {
  it('an operator admin: the heading, three tabs, the open tab', async () => {
    const html = await renderPage(true)
    assert.ok(html.includes(t('sidebar.expenses')))
    for (const x of EXPENSES_TABS) assert.match(html, new RegExp(`data-test="expenses-tab-${x.id}"[^>]*>${t(x.labelKey)}<`), x.id)
    assert.match(html, /data-test="nuxt-page"/)
    assert.doesNotMatch(html, /data-test="expenses-operators-only"/)
  })
  it('CONTROL anyone else: the operators-only line, no tab, no page', async () => {
    const html = await renderPage(false)
    assert.match(html, /data-test="expenses-operators-only"/)
    assert.ok(html.includes(t('expenses.operators_only')))
    assert.doesNotMatch(html, /data-test="expenses-tab-|data-test="nuxt-page"/)
  })
})

describe('Reporting -> Costs only reports (owner msg baa43948)', () => {
  it('no Costs page enters costs: no Paid items page, its old path leads to Expenses -> AI costs', () => {
    assert.equal(COSTS_PAGES.some((p) => p.id === 'paid'), false)
    assert.equal(legacyCostsPath('/reporting/costs/paid'), '/expenses/ai')
    assert.equal(legacyCostsPath('/fi/reporting/costs/paid'), '/expenses/ai')
    assert.match(read('src/pages/reporting/costs/paid.vue'), /<LegacyMonitoringRedirect \/>/)
    for (const p of COSTS_PAGES) assert.doesNotMatch(read('src/pages' + p.path + '.vue'), /PaidItemsCard|PaidItemForm/, p.path)
  })
  it('Monitoring -> Tokens no longer mounts the Paid card; it links to AI costs', () => {
    const page = read('src/pages/monitoring/tokens/index.vue')
    assert.doesNotMatch(page, /PaidItemsCard/)
    assert.match(page, /data-test="tokens-paid-link"/)
  })
})

describe('the strings', () => {
  it('the section name is ONE key, sidebar.expenses, for the rail and the heading', () => {
    assert.match(read('src/pages/expenses.vue'), /\{\{ t\('sidebar\.expenses'\) \}\}/)
    assert.equal(t('sidebar.expenses'), 'Expenses')
  })
  it('every Expenses string is in every locale', () => {
    const keys = ['sidebar.expenses', 'expenses.tabs_label', 'expenses.coming', 'expenses.operators_only', 'expenses.tokens_link', ...EXPENSES_TABS.map((x) => x.labelKey)]
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const cat = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const key of keys) assert.equal(typeof key.split('.').reduce((o, k) => o?.[k], cat), 'string', f + ': ' + key)
    }
  })
})
