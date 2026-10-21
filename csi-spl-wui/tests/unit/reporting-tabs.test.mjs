// spec 143 1 (SPL-2324, SPL-2351), tasks T010-T013: the Reporting section's
// rail entry, its tab list, the section page and its strings.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  REPORTING_TABS,
  REPORTING_DEFAULT_PATH,
  visibleReportingTabs,
  reportingTabShows,
  reportingTabFor,
} from '../../src/utils/reporting-tabs.mjs'
import { importTs } from './lib/load-ts.mjs'
import { channelSidebarSrc } from './lib/channel-sidebar-src.mjs'
const { RAIL_TABS, RAIL_IDS, RAIL_HUB_PENDING, DEFAULT_RAIL_ORDER, wireRailOrder } = await importTs('src/utils/rail-order.ts')
import { REPORTING_TAB, routeForTab, tabForPath } from '../../src/utils/sidebar-tabs.mjs'
import { isSectionPage } from '../../src/utils/section-strip.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const ids = (tabs) => tabs.map((t) => t.id)
/* the rule on a list of tabs */
const shown = (who, tabs) => tabs.filter((t) => reportingTabShows(t, who))
/* every reserved tab drawn as if its page existed: the visibility rules alone */
const ALL_READY = REPORTING_TABS.map((t) => ({ ...t, ready: true }))

describe('T010 the Reporting rail entry', () => {
  it('one rail tab with its own icon and label, right after Monitoring, before Archive', () => {
    const tab = RAIL_TABS.find((t) => t.id === 'reporting')
    assert.deepEqual({ ...tab }, { id: 'reporting', icon: 'chart-column', labelKey: 'sidebar.reporting' })
    /* CONTROL: without the entry neither holds */
    assert.equal(RAIL_IDS.indexOf('reporting'), RAIL_IDS.indexOf('monitoring') + 1)
    assert.deepEqual(DEFAULT_RAIL_ORDER.slice(-3), ['monitoring', 'reporting', 'archive'])
    assert.match(read('src/utils/uiIcons.ts'), /\n {2}"chart-column": \[/)
  })
  it('opens /reporting and selects itself on every Reporting path', () => {
    assert.equal(REPORTING_TAB, 'reporting')
    assert.equal(routeForTab('reporting'), '/reporting')
    for (const p of ['/reporting', '/reporting/releases', '/fi/reporting/releases', '/reporting/sql']) assert.equal(tabForPath(p), 'reporting', p)
    assert.equal(tabForPath('/reportingx'), null)
    for (const p of ['/reporting', '/reporting/releases']) assert.equal(isSectionPage(p), true, p)
  })
  it('the hub does not admit it yet: a saved order leaves it out, so the hub keeps admitting the order', () => {
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    const hub = JSON.parse('[' + /\bRailTabs = \[\]string\{([^}]*)\}/.exec(go)[1] + ']')
    if (!hub.includes('reporting')) assert.ok(RAIL_HUB_PENDING.includes('reporting'), 'pending while the hub lacks it')
    assert.equal(wireRailOrder([...DEFAULT_RAIL_ORDER]).every((id) => !RAIL_HUB_PENDING.includes(id)), true)
  })
  it('the sidebar keeps the icon rail only on Reporting, and the rail tab navigates there', () => {
    const side = channelSidebarSrc()
    assert.match(side, /const reportingRailOnly = computed\(\(\) => tab\.value === REPORTING_TAB\)/)
    assert.match(side, /'sidebar--rail': [^}]*reportingRailOnly/)
    assert.match(side, /next === REPORTING_TAB && [^\n]*navigateTo\(localePath\('\/reporting'\)\)/)
  })
})

describe('T011 utils/reporting-tabs.mjs', () => {
  it('the tabs in their order, each its own path; Releases is where /reporting lands', () => {
    assert.deepEqual(ids(REPORTING_TABS), ['releases', 'sql', 'tokens', 'issues', 'posts', 'lanes'])
    assert.equal(REPORTING_DEFAULT_PATH, '/reporting/releases')
    for (const t of REPORTING_TABS) {
      assert.equal(t.path, '/reporting/' + t.id)
      assert.equal(t.labelKey, 'reporting.tab.' + t.id)
      assert.equal(typeof t.adminOnly, 'boolean')
      assert.equal(typeof t.operatorsOnly, 'boolean')
      assert.equal(typeof t.ready, 'boolean')
    }
  })
  it('Releases and SQL are ready today (SQL since T033, SPL-2789): a member sees Releases, an admin both', () => {
    assert.deepEqual(REPORTING_TABS.filter((t) => t.ready).map((t) => t.id), ['releases', 'sql'])
    for (const who of [undefined, {}, { admin: false }]) {
      assert.deepEqual(ids(visibleReportingTabs(who)), ['releases'], JSON.stringify(who))
    }
    for (const who of [{ admin: true }, { operator: true }, { admin: true, operator: true, can: () => true }]) {
      assert.deepEqual(ids(visibleReportingTabs(who)), ['releases', 'sql'], JSON.stringify(who))
    }
  })
  it('a member sees no admin tab; a workspace admin sees SQL', () => {
    assert.deepEqual(ids(shown({}, ALL_READY)), ['releases', 'issues', 'posts'])
    assert.deepEqual(ids(shown({ admin: false }, ALL_READY)), ['releases', 'issues', 'posts'])
    assert.deepEqual(ids(shown({ admin: true }, ALL_READY)), ['releases', 'sql', 'issues', 'posts'])
  })
  it('owner t1 af25a1f3 (msg a8bfcdd0): Tokens is for operator admins only, never a workspace admin', () => {
    const tokens = REPORTING_TABS.find((t) => t.id === 'tokens')
    assert.equal(tokens.operatorsOnly, true)
    assert.equal(tokens.ready, false)
    /* CONTROL: a workspace admin, a member, or a reader not known yet never sees it */
    for (const who of [{ admin: true }, {}, { operator: false, admin: true }]) {
      assert.equal(ids(shown(who, ALL_READY)).includes('tokens'), false, JSON.stringify(who))
    }
    assert.deepEqual(ids(shown({ operator: true }, ALL_READY)), ['releases', 'sql', 'tokens', 'issues', 'posts', 'lanes'])
    assert.deepEqual(ids(shown({ operator: true, admin: true }, ALL_READY)), ['releases', 'sql', 'tokens', 'issues', 'posts', 'lanes'])
  })
  it('a tab naming a perm shows only when who.can grants it', () => {
    const tabs = [{ id: 'x', ready: true, perm: 'p.read' }]
    assert.deepEqual(ids(shown({ can: (p) => p === 'p.read' }, tabs)), ['x'])
    assert.deepEqual(ids(shown({ can: () => false }, tabs)), [])
    assert.deepEqual(ids(shown({}, tabs)), [])
  })
  it('reportingTabFor: the tab a route is on, locale prefix or not; null on /reporting itself', () => {
    assert.equal(reportingTabFor('/reporting/releases'), 'releases')
    assert.equal(reportingTabFor('/sv/reporting/sql'), 'sql')
    assert.equal(reportingTabFor('/reporting/releases/2026-10-17'), 'releases')
    assert.equal(reportingTabFor('/reporting'), null)
    assert.equal(reportingTabFor('/reporting/releasesx'), null)
    assert.equal(reportingTabFor('/monitoring/tokens'), null)
  })
})

describe('T012 pages/reporting.vue', () => {
  const page = read('src/pages/reporting.vue')
  it('the header, the tab bar from the one list, and the child route', () => {
    assert.match(page, /<MobileBack \/>/)
    assert.match(page, /<SectionClose side="start" \/>/)
    assert.match(page, /data-test="reporting-heading">\{\{ t\('reporting\.title'\) \}\}/)
    assert.match(page, /:aria-label="t\('reporting\.tabs_label'\)"/)
    assert.match(page, /visibleReportingTabs\(\{/)
    assert.match(page, /'reporting-tab--active': active === tab\.id/)
    assert.match(page, /:aria-current="active === tab\.id \? 'page' : undefined"/)
    assert.match(page, /<NuxtPage \/>/)
  })
  it('/reporting replaces itself with the default tab, in the browser only', () => {
    assert.match(page, /onMounted\(\(\) => \{[\s\S]*productPath\(p\) === '\/reporting'\) void navigateTo\(localePath\(REPORTING_DEFAULT_PATH\), \{ replace: true \}\)/)
  })
  it('Tokens follows the operator pane, not the workspace role', () => {
    assert.match(page, /operator: operator\.visible/)
    assert.match(page, /admin: meRead\.value && access\.me\?\.role === 'admin'/)
  })
  it('each ready tab has its own page (its own chunk)', () => {
    for (const t of visibleReportingTabs({ operator: true })) assert.ok(existsSync(join(WUI, 'src/pages' + t.path + '.vue')), t.path)
  })
})

describe('T013 the strings', () => {
  it('every tab label, the title, the tab bar label, the rail name and the placeholder are in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const locales = readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5))
    assert.equal(locales.length, 19)
    const keys = [...REPORTING_TABS.map((t) => t.labelKey), 'reporting.title', 'reporting.tabs_label', 'sidebar.reporting', 'reporting.releases.soon']
    for (const loc of locales) {
      const cat = JSON.parse(readFileSync(join(dir, loc + '.json'), 'utf8'))
      const get = (key) => key.split('.').reduce((o, k) => (o == null ? o : o[k]), cat)
      for (const key of keys) assert.equal(typeof get(key), 'string', loc + ': ' + key)
    }
  })
})
