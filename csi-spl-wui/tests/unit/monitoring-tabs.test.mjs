// SPL-1991 (owner HUM-10, t1 dbf2f39b, A on Q1-Q4): the Monitoring section's
// tabs - one list for the tab bar and these tests; each tab its own path.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MONITORING_TABS,
  MONITORING_DEFAULT_PATH,
  visibleMonitoringTabs,
  monitoringTabFor,
  legacyMonitoringPath,
} from '../../src/utils/monitoring-tabs.mjs'
import { importTs } from './lib/load-ts.mjs'
const { RAIL_TABS, RAIL_RETIRED, DEFAULT_RAIL_ORDER } = await importTs('src/utils/rail-order.ts')
import { MONITORING_TAB, routeForTab, tabForPath } from '../../src/utils/sidebar-tabs.mjs'
import { isSectionPage } from '../../src/utils/section-strip.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('monitoring tabs', () => {
  it('Agents first (the landing tab, Q1 A), then Boxes, Costs (spec 123), then Tokens (spec 140)', () => {
    assert.deepEqual(MONITORING_TABS.map((t) => t.id), ['agents', 'boxes', 'costs', 'tokens'])
    assert.deepEqual(MONITORING_TABS.map((t) => t.path), ['/monitoring/agents', '/monitoring/boxes', '/monitoring/costs', '/monitoring/tokens'])
    assert.equal(MONITORING_DEFAULT_PATH, '/monitoring/agents')
    for (const t of MONITORING_TABS) {
      assert.equal(t.path, '/monitoring/' + t.id, 'a tab is its own path (D4)')
      assert.equal(t.labelKey, 'monitoring.tab.' + t.id)
      assert.equal(typeof t.operatorsOnly, 'boolean')
    }
  })
  it('Tokens (spec 140 4.1, SPL-2322) shows beside Agents and Boxes for an operator admin, never for anyone else', () => {
    assert.deepEqual(visibleMonitoringTabs({ operator: true }).map((t) => t.id), ['agents', 'boxes', 'tokens'])
    /* CONTROL: a member who is not an operator admin, or not known yet, never sees it */
    assert.deepEqual(visibleMonitoringTabs().map((t) => t.id), ['agents', 'boxes'])
    assert.deepEqual(visibleMonitoringTabs({ operator: false }).map((t) => t.id), ['agents', 'boxes'])
  })
  it('Costs (spec 123 5, SPL-2056) shows to a member holding costs.read only, operator or not', () => {
    const costs = MONITORING_TABS.find((t) => t.id === 'costs')
    assert.equal(costs.perm, 'costs.read')
    assert.equal(costs.operatorsOnly, false, 'any workspace: biz_owner and admin read their own rows')
    const holds = (perms) => (p) => perms.includes(p)
    assert.deepEqual(visibleMonitoringTabs({ can: holds(['costs.read']) }).map((t) => t.id), ['agents', 'boxes', 'costs'])
    assert.deepEqual(visibleMonitoringTabs({ operator: true, can: holds(['costs.read']) }).map((t) => t.id), ['agents', 'boxes', 'costs', 'tokens'])
    /* CONTROL: without the permission (or before /v1/view/me answered) it is hidden */
    assert.deepEqual(visibleMonitoringTabs({ can: holds(['members.invite']) }).map((t) => t.id), ['agents', 'boxes'])
    assert.deepEqual(visibleMonitoringTabs({ operator: true }).map((t) => t.id), ['agents', 'boxes', 'tokens'])
  })
  it('an operator-only ready tab shows to operators only (Q3 A)', () => {
    const tokens = MONITORING_TABS.find((t) => t.id === 'tokens')
    assert.equal(tokens.operatorsOnly, true)
    assert.equal(tokens.ready, true)
    /* the filter rule itself: CONTROL that operator gates, and that ready gates */
    const rule = (tab, who) => tab.ready && (!tab.operatorsOnly || who.operator === true)
    assert.equal(rule(tokens, { operator: true }), true)
    assert.equal(rule(tokens, { operator: false }), false)
    assert.equal(rule({ ...tokens, ready: false }, { operator: true }), false)
  })
  it('monitoringTabFor: the tab a route is on, locale prefix or not; a detail page keeps its tab', () => {
    assert.equal(monitoringTabFor('/monitoring/agents'), 'agents')
    assert.equal(monitoringTabFor('/fi/monitoring/boxes'), 'boxes')
    assert.equal(monitoringTabFor('/monitoring/boxes/box-desk'), 'boxes')
    assert.equal(monitoringTabFor('/monitoring/agents/c-1%40tnk?x=1'), 'agents')
    assert.equal(monitoringTabFor('/monitoring'), null)
    assert.equal(monitoringTabFor('/monitoring/agentsx'), null)
    assert.equal(monitoringTabFor('/agents'), null)
  })
  it('each ready tab has its own page (its own chunk), and the parent holds a NuxtPage', () => {
    for (const t of visibleMonitoringTabs({ can: () => true })) assert.ok(existsSync(join(WUI, 'src/pages' + t.path + '/index.vue')), t.path)
    const parent = read('src/pages/monitoring.vue')
    assert.match(parent, /<NuxtPage \/>/)
    assert.match(parent, /data-test="monitoring-summary"/, 'the summary strip slot')
    assert.match(parent, /visibleMonitoringTabs\(/, 'the bar reads the one list')
  })
  it('every tab label, the title and the rail name are in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const locales = ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    for (const loc of locales) {
      const cat = JSON.parse(readFileSync(join(dir, loc + '.json'), 'utf8'))
      const get = (key) => key.split('.').reduce((o, k) => (o == null ? o : o[k]), cat)
      for (const key of [...MONITORING_TABS.map((t) => t.labelKey), 'monitoring.title', 'monitoring.tabs_label', 'sidebar.monitoring']) {
        assert.equal(typeof get(key), 'string', loc + ': ' + key)
      }
    }
  })
})

describe('the Monitoring rail entry', () => {
  it('one rail tab, its own icon, opening /monitoring; Agents and Boxes went into it (SPL-2075)', () => {
    const tab = RAIL_TABS.find((t) => t.id === 'monitoring')
    assert.deepEqual({ ...tab }, { id: 'monitoring', icon: 'activity', labelKey: 'sidebar.monitoring' })
    /* owner fd5a2bf4: no Agents and no Boxes icon; the hub keeps both ids */
    assert.ok(!RAIL_TABS.some((t) => t.id === 'agents'))
    assert.ok(!RAIL_TABS.some((t) => t.id === 'boxes'))
    assert.ok(RAIL_RETIRED.includes('agents') && RAIL_RETIRED.includes('boxes'))
    assert.match(read('src/utils/uiIcons.ts'), /\n {2}activity: \[/)
    assert.equal(MONITORING_TAB, 'monitoring')
    assert.equal(routeForTab('monitoring'), '/monitoring')
    assert.equal(DEFAULT_RAIL_ORDER.at(-3), 'monitoring', 'before Reporting (spec 143 1.1) and Archive')
  })
  it('every Monitoring path selects the Monitoring rail tab and is a section page', () => {
    for (const p of ['/monitoring', '/monitoring/agents', '/monitoring/boxes', '/monitoring/costs', '/sv/monitoring/boxes', '/monitoring/boxes/box-desk', '/monitoring/agents/c-001%40box-a']) {
      assert.equal(tabForPath(p), 'monitoring', p)
    }
    for (const p of ['/monitoring', '/monitoring/agents', '/monitoring/boxes']) assert.equal(isSectionPage(p), true, p)
    /* SPL-2075: the old sections' paths are Monitoring's (they redirect) */
    for (const p of ['/agents', '/agents/c-001%40box-a', '/boxes', '/boxes/box-desk', '/fi/boxes']) assert.equal(tabForPath(p), 'monitoring', p)
    assert.equal(routeForTab('agents'), null)
    assert.equal(routeForTab('boxes'), null)
    /* a card is a drill-down: it keeps the Monitoring header and its Back */
    assert.equal(isSectionPage('/monitoring/boxes/box-desk'), false)
  })
})

describe('old Agents / Boxes links (SPL-2075)', () => {
  it('each lands on the matching Monitoring route, with or without a locale', () => {
    assert.equal(legacyMonitoringPath('/agents'), '/monitoring/agents')
    assert.equal(legacyMonitoringPath('/agents/'), '/monitoring/agents')
    assert.equal(legacyMonitoringPath('/agents/c-001%40box-a'), '/monitoring/agents/c-001%40box-a')
    assert.equal(legacyMonitoringPath('/boxes'), '/monitoring/boxes')
    assert.equal(legacyMonitoringPath('/fi/boxes/box-desk'), '/monitoring/boxes/box-desk')
    assert.equal(legacyMonitoringPath('/boxes/box-desk?r=hardware#box-people'), '/monitoring/boxes/box-desk')
  })
  it('anything else is not an old link', () => {
    for (const p of ['/', '/monitoring/boxes', '/people/HUM-1', '/boxes/a/b', '/agentsx', '/t/boxes']) assert.equal(legacyMonitoringPath(p), null, p)
  })
  it('the four old pages are the redirect, and the cards live under Monitoring', () => {
    for (const f of ['agents/index', 'agents/[id]', 'boxes/index', 'boxes/[id]']) {
      assert.match(read(`src/pages/${f}.vue`), /<LegacyMonitoringRedirect \/>/, f)
    }
    const redirect = read('src/components/LegacyMonitoringRedirect.vue')
    assert.match(redirect, /onMounted\(/, 'client side: nuxt generate on static hosting runs no server redirect')
    assert.match(redirect, /query: route\.query, hash: route\.hash/, '?r= and the seat hash are kept')
    assert.match(read('src/pages/monitoring/agents/[id].vue'), /data-test="agent-message"/)
    assert.match(read('src/pages/monitoring/boxes/[id].vue'), /<BoxLoadBand v-if="!box\.browser"/)
  })
})
