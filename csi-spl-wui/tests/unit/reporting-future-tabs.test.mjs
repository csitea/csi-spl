// spec 143 5 (SPL-2791), tasks T051-T053: the reserved tabs Issues, Posts
// and Lanes. Each has its own page (its own chunk), stays ready: false so the
// bar never draws it, and Lanes renders for an operator admin only.
// costs-redesign.md slice S1 (SPL-3798): the reserved Tokens tab (T050)
// became Reporting -> Costs; /reporting/tokens redirects to its Tokens page,
// and its Tokens, Price per token and Paid items pages are shells: Price and
// Paid render for an operator admin only, Tokens for every member (owner
// HUM-10, t1 1be0e370, msg 3f1c7128, answer 1 A). SPL-4382: Paid items left
// Costs for Expenses -> AI costs; /reporting/costs/paid only redirects.
// SPL-5312: Costs is the four labels Total, Persons, Cloud, Tokens, one
// component each; Spend, Human and Price per token redirect to their label.
//
// The pages' templates are the SHIPPED ones, rendered with Vue's own
// compiler + server renderer for each role, so a page that drops the gate
// fails here.
//
// Run: node tests/unit/reporting-future-tabs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import { compile } from '@vue/compiler-dom'
import { renderToString } from 'vue/server-renderer'
import { REPORTING_TABS, visibleReportingTabs, reportingTabShows } from '../../src/utils/reporting-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const FUTURE = ['issues', 'posts', 'lanes']
/* SPL-5312: Price per token became a redirect to Tokens; no Costs page is operators-only now */
const OPERATOR_ONLY = ['lanes']
const tab = (id) => REPORTING_TABS.find((x) => x.id === id)
const page = (id) => 'src/pages/reporting/' + id + '.vue'

const en = JSON.parse(read('i18n/locales/en.json'))
const t = (key) => key.split('.').reduce((o, k) => o?.[k], en)

/* the readers: a member, a workspace admin, an operator admin; `operator` is
   what pages/reporting.vue passes (the operator pane's probe) */
const ROLES = {
  member: { who: {}, operator: false },
  'workspace admin': { who: { admin: true }, operator: false },
  'operator admin': { who: { admin: true, operator: true }, operator: true },
}

/** Server-render the shipped page's template as `role`; `extra` adds to its scope. */
async function render(id, role, extra = {}) {
  const s = read(page(id))
  const template = s.slice(s.indexOf('<template>') + 10, s.lastIndexOf('</template>'))
  const code = compile(template, { mode: 'function', prefixIdentifiers: false }).code
  const fn = new Function('Vue', code)(Vue)
  const ctx = { t, localePath: (p) => p, operator: { visible: ROLES[role].operator }, reader: ROLES[role].operator, ...extra }
  const scope = new Proxy({}, {
    has: (_, k) => typeof k === 'string' && !k.startsWith('_') && !(k in globalThis),
    get: (_, k) => (k in ctx ? ctx[k] : undefined),
  })
  const app = Vue.createSSRApp({ render: (_c, cache) => fn(scope, cache || []) })
  app.component('NuxtLink', { props: ['to'], setup: (p, { slots }) => () => Vue.h('a', { href: p.to }, slots.default?.()) })
  return renderToString(app)
}

describe('T051-T053 each reserved tab has its page and stays hidden', () => {
  it('a page per tab, its own chunk under /reporting/<id>', () => {
    for (const id of FUTURE) assert.ok(existsSync(join(WUI, page(id))), page(id))
  })
  it('ready: false: no reader sees Issues, Posts or Lanes in the bar', () => {
    for (const id of FUTURE) assert.equal(tab(id).ready, false, id)
    for (const { who } of Object.values(ROLES)) {
      /* CONTROL: a flipped ready shows the tab to some reader */
      for (const id of FUTURE) assert.equal(visibleReportingTabs(who).some((x) => x.id === id), false, id + ' ' + JSON.stringify(who))
    }
  })
})

describe('S1 Costs pages (SPL-3798; SPL-4187; SPL-5312 the four labels): Total, Persons, Cloud and Tokens for every costs reader; the pages before them and Paid items (SPL-4382) redirect', () => {
  it('/reporting/tokens is a redirect now, no page of its own', () => {
    const src = read(page('tokens'))
    assert.match(src, /<LegacyMonitoringRedirect \/>/)
    assert.doesNotMatch(src, /reporting\.future\.tokens/)
  })
  it('SPL-5312: each label page is the one CostsLabel component with its section, no gate of its own (the hub scopes the money)', () => {
    for (const id of ['total', 'persons', 'cloud', 'tokens']) {
      const src = read(page('costs/' + id))
      assert.match(src, new RegExp(`<CostsLabel section="${id}" />`), id)
      /* CONTROL: before SPL-5312 Cloud drew the operators-only line for anyone else */
      assert.doesNotMatch(src, /operators_only|useOperatorReader/, id)
    }
  })
  it('SPL-5312: Spend, Human and Price per token are redirects to their label now; SPL-4382: Paid items to Expenses', () => {
    for (const id of ['spend', 'human', 'price', 'paid']) {
      const src = read(page('costs/' + id))
      assert.match(src, /<LegacyMonitoringRedirect \/>/, id)
      assert.doesNotMatch(src, /costs-shell|reporting\.costs\.coming|data-test="costs-table"/, id)
    }
  })
})

describe('T053 Lanes: operator admins only (spec 143 6.1)', () => {
  it('the tab rule and the page agree', async () => {
    const ready = { ...tab('lanes'), ready: true }
    assert.equal(reportingTabShows(ready, ROLES['operator admin'].who), true)
    assert.equal(reportingTabShows(ready, ROLES['workspace admin'].who), false)
    assert.match(await render('lanes', 'operator admin'), /data-test="reporting-lanes"/)
    assert.doesNotMatch(await render('lanes', 'workspace admin'), /data-test="reporting-lanes"/)
  })
})

describe('T051 Issues, T052 Posts: every signed-in member', () => {
  it('the placeholder for every role', async () => {
    for (const id of ['issues', 'posts']) {
      for (const role of Object.keys(ROLES)) {
        const html = await render(id, role)
        assert.match(html, new RegExp('data-test="reporting-' + id + '"'), id + ' ' + role)
        assert.ok(html.includes(t('reporting.future.' + id)), id + ' ' + role)
      }
    }
  })
})

describe('the strings', () => {
  it('every reserved tab string is in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const keys = [...FUTURE, 'operators_only'].map((k) => 'reporting.future.' + k)
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const cat = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const key of keys) assert.equal(typeof key.split('.').reduce((o, k) => o?.[k], cat), 'string', f + ': ' + key)
    }
  })
  it('the operator-only pages say so in the catalogue words, no literal text', () => {
    for (const id of OPERATOR_ONLY) assert.match(read(page(id)), /t\('reporting\.future\.operators_only'\)/)
  })
})
