// spec 143 5 (SPL-2791), tasks T050-T053: the reserved tabs Tokens, Issues,
// Posts and Lanes. Each has its own page (its own chunk), stays ready: false
// so the bar never draws it, and Tokens and Lanes render for an operator
// admin only: owner HUM-10 (t1 af25a1f3, msg a8bfcdd0, answer 4 = A), Tokens
// is never a workspace admin's.
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
const FUTURE = ['tokens', 'issues', 'posts', 'lanes']
const OPERATOR_ONLY = ['tokens', 'lanes']
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

/** Server-render the shipped page's template as `role`. */
async function render(id, role) {
  const s = read(page(id))
  const template = s.slice(s.indexOf('<template>') + 10, s.lastIndexOf('</template>'))
  const code = compile(template, { mode: 'function', prefixIdentifiers: false }).code
  const fn = new Function('Vue', code)(Vue)
  const ctx = { t, localePath: (p) => p, operator: { visible: ROLES[role].operator } }
  const scope = new Proxy({}, {
    has: (_, k) => typeof k === 'string' && !k.startsWith('_') && !(k in globalThis),
    get: (_, k) => (k in ctx ? ctx[k] : undefined),
  })
  const app = Vue.createSSRApp({ render: (_c, cache) => fn(scope, cache || []) })
  app.component('NuxtLink', { props: ['to'], setup: (p, { slots }) => () => Vue.h('a', { href: p.to }, slots.default?.()) })
  return renderToString(app)
}

describe('T050-T053 each reserved tab has its page and stays hidden', () => {
  it('a page per tab, its own chunk under /reporting/<id>', () => {
    for (const id of FUTURE) assert.ok(existsSync(join(WUI, page(id))), page(id))
  })
  it('ready: false: no reader sees Tokens, Issues, Posts or Lanes in the bar', () => {
    for (const id of FUTURE) assert.equal(tab(id).ready, false, id)
    for (const { who } of Object.values(ROLES)) {
      /* CONTROL: a flipped ready shows the tab to some reader */
      for (const id of FUTURE) assert.equal(visibleReportingTabs(who).some((x) => x.id === id), false, id + ' ' + JSON.stringify(who))
    }
  })
})

describe('T050 Tokens: operator admins only (owner answer 4 = A)', () => {
  it('the tab rule: an operator admin only, never a workspace admin or a member', () => {
    const ready = { ...tab('tokens'), ready: true }
    assert.equal(reportingTabShows(ready, ROLES['operator admin'].who), true)
    /* CONTROL: the two roles that must never see it */
    assert.equal(reportingTabShows(ready, ROLES['workspace admin'].who), false)
    assert.equal(reportingTabShows(ready, ROLES.member.who), false)
  })
  it('the page: an operator admin gets the placeholder and Monitoring > Tokens; a workspace admin and a member get neither', async () => {
    const op = await render('tokens', 'operator admin')
    assert.match(op, /data-test="reporting-tokens"/)
    assert.ok(op.includes(t('reporting.future.tokens')))
    assert.match(op, /href="\/monitoring\/tokens"/)
    for (const role of ['workspace admin', 'member']) {
      const html = await render('tokens', role)
      /* CONTROL: the page's gate, not the bar, keeps a direct visit out */
      assert.doesNotMatch(html, /data-test="reporting-tokens"/, role)
      assert.doesNotMatch(html, /monitoring\/tokens/, role)
      assert.ok(html.includes(t('reporting.future.operators_only')), role)
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
    const keys = [...FUTURE, 'operators_only', 'tokens_link'].map((k) => 'reporting.future.' + k)
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const cat = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      for (const key of keys) assert.equal(typeof key.split('.').reduce((o, k) => o?.[k], cat), 'string', f + ': ' + key)
    }
  })
  it('the operator-only pages say so in the catalogue words, no literal text', () => {
    for (const id of OPERATOR_ONLY) assert.match(read(page(id)), /t\('reporting\.future\.operators_only'\)/)
  })
})
