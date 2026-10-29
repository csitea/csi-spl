// Spec 163 G5, build row B1 (SPL-4250): the Reporting Marketing tab. Owner
// HUM-10 (csitea topic b13f7763, poll 337fb605, msg 449350b3): Q7 last
// touch over 28 days, Q8 workspace admins and the owner only. The tab rule
// (reporting-tabs.mjs `staff`), the read and its mock (reporting-marketing.mjs),
// the page and its strings in every locale.
//
// Run: node tests/unit/reporting-marketing.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { REPORTING_TABS, reportingTabShows, visibleReportingTabs } from '../../src/utils/reporting-tabs.mjs'
import { monitoringStaff } from '../../src/utils/monitoring-tabs.mjs'
import {
  MARKETING_STAGE_IDS,
  marketingAttribution,
  marketingReportRead,
  marketingStageCards,
  mockMarketingReport,
} from '../../src/utils/reporting-marketing.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const ids = (tabs) => tabs.map((t) => t.id)
const tab = REPORTING_TABS.find((t) => t.id === 'marketing')

/** A Storage stand-in holding the opt-in mock me ({ role, permissions }). */
const storeAs = (role) => {
  const m = new Map(role ? [['spool.mock.me', JSON.stringify({ role, permissions: [] })]] : [])
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

describe('the tab: workspace owner and admins only (Q8)', () => {
  it('a ready tab at /reporting/marketing, after Costs, marked staff', () => {
    assert.deepEqual({ ...tab }, { id: 'marketing', path: '/reporting/marketing', labelKey: 'reporting.tab.marketing',
      adminOnly: false, operatorsOnly: false, staff: true, ready: true })
    assert.equal(ids(REPORTING_TABS).indexOf('marketing'), ids(REPORTING_TABS).indexOf('costs') + 1)
  })
  it('shown to the owner and to an admin, never to a member or before me answered', () => {
    const who = (me) => ({ staff: monitoringStaff(me) })
    const ROLE = {
      'biz_owner (tenant_owner)': [{ tenantOwner: true, role: 'biz_owner', roles: ['biz_owner'] }, true],
      'workspace admin': [{ tenantOwner: false, role: 'admin', roles: ['admin'] }, true],
      'admin as a second role': [{ tenantOwner: false, role: 'developer', roles: ['developer', 'admin'] }, true],
      developer: [{ tenantOwner: false, role: 'developer', roles: ['developer'] }, false],
      tester: [{ tenantOwner: false, role: 'tester', roles: ['tester'] }, false],
      'me not answered (null)': [null, false],
    }
    for (const [role, [me, want]] of Object.entries(ROLE)) {
      assert.equal(visibleReportingTabs(who(me)).some((t) => t.id === 'marketing'), want, role)
    }
    /* an operator admin of another workspace is no staff of this one */
    assert.equal(reportingTabShows(tab, { operator: true, admin: false }), false)
  })
  it('RED control: the staff mark is what hides it (dropped, a member would see the tab)', () => {
    const member = { staff: false }
    assert.equal(reportingTabShows(tab, member), false)
    const { staff: _drop, ...noStaff } = tab
    assert.equal(reportingTabShows(noStaff, member), true)
  })
})

describe('utils/reporting-marketing.mjs', () => {
  it('the seven stages in the overview order (spec 163 section 2.1..2.7)', () => {
    assert.deepEqual([...MARKETING_STAGE_IDS], ['reach', 'engagement', 'acquisition', 'conversion', 'revenue', 'retention', 'content_seo'])
  })
  it('the mock answers the empty report to the owner and an admin, 403 to anyone else (the hub\'s rule)', () => {
    const now = Date.UTC(2026, 9, 29, 12, 0, 0)
    for (const role of [null, 'biz_owner', 'admin']) {
      const r = mockMarketingReport(now, storeAs(role))
      assert.deepEqual(r, { as_of: '2026-10-29T12:00:00Z', attribution: { rule: 'last_touch', window_days: 28 },
        stages: [...MARKETING_STAGE_IDS], samples: [], definitions: [] }, String(role))
    }
    for (const role of ['developer', 'member', 'tester']) {
      assert.throws(() => mockMarketingReport(now, storeAs(role)), (e) => e.status === 403, role)
    }
  })
  it('the read goes to GET /v1/reporting/marketing and passes a 403 on as { status }', async () => {
    const calls = []
    const real = globalThis.fetch
    globalThis.fetch = async (url, init) => {
      calls.push({ url, init })
      return { ok: false, status: 403, json: async () => ({}) }
    }
    try {
      await assert.rejects(marketingReportRead({ base: 'https://hub.example.com', token: 'tok', credentials: 'include' }), (e) => e.status === 403)
    } finally {
      globalThis.fetch = real
    }
    assert.equal(calls[0].url, 'https://hub.example.com/v1/reporting/marketing')
    assert.equal(calls[0].init.headers.authorization, 'Bearer tok')
  })
  it('one empty card per stage the hub names, in its order; an unknown stage id is not drawn', () => {
    const cards = marketingStageCards({ stages: ['reach', 'nope', 'revenue'] })
    assert.deepEqual(cards, [
      { id: 'reach', labelKey: 'reporting.marketing.stage.reach', samples: [] },
      { id: 'revenue', labelKey: 'reporting.marketing.stage.revenue', samples: [] },
    ])
    assert.deepEqual(ids(marketingStageCards(undefined)), [...MARKETING_STAGE_IDS])
  })
  it('the attribution line is Q7\'s: last touch, the hub\'s window or 28 days; an unknown rule draws no line', () => {
    assert.deepEqual(marketingAttribution({ attribution: { rule: 'last_touch', window_days: 28 } }), { ruleKey: 'reporting.marketing.rule_last_touch', days: 28 })
    assert.deepEqual(marketingAttribution({ attribution: { rule: 'last_touch', window_days: 7 } }), { ruleKey: 'reporting.marketing.rule_last_touch', days: 7 })
    assert.deepEqual(marketingAttribution(undefined), { ruleKey: 'reporting.marketing.rule_last_touch', days: 28 })
    assert.equal(marketingAttribution({ attribution: { rule: 'first_touch', window_days: 28 } }), null)
  })
})

describe('pages/reporting/marketing.vue and its strings', () => {
  const page = read('src/pages/reporting/marketing.vue')
  it('reads the hub once in the browser, shows the 403 line and no card to a non-staff reader', () => {
    assert.match(page, /onMounted\(async \(\) => \{[\s\S]*marketingReportRead\(api\)/)
    assert.match(page, /status === 403 \? 'forbidden' : 'error'/)
    assert.match(page, /v-else-if="state === 'forbidden'"[^>]*data-test="reporting-marketing-forbidden"/)
    assert.match(page, /v-for="card in cards"[^>]*:data-test="'reporting-marketing-card-' \+ card\.id"/)
  })
  it('every key the tab uses is in every locale', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    const keys = ['reporting.tab.marketing', ...['loading', 'forbidden', 'error', 'intro', 'attribution', 'rule_last_touch', 'cards_label', 'empty']
      .map((k) => 'reporting.marketing.' + k), ...MARKETING_STAGE_IDS.map((s) => 'reporting.marketing.stage.' + s)]
    for (const [, key] of page.matchAll(/t\('(reporting\.marketing\.[a-z_.]+)'/g)) assert.ok(keys.includes(key), key)
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const cat = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const get = (key) => key.split('.').reduce((o, k) => (o == null ? o : o[k]), cat)
      for (const key of keys) assert.equal(typeof get(key), 'string', f + ': ' + key)
      assert.match(get('reporting.marketing.attribution'), /\{rule\}/, f)
      assert.match(get('reporting.marketing.attribution'), /\{days\}/, f)
    }
    assert.equal(en.reporting.marketing.attribution, 'Attribution: {rule}, {days} days')
  })
})
