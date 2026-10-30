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
  monitoringStaff,
} from '../../src/utils/monitoring-tabs.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'
import { importTs } from './lib/load-ts.mjs'
const { RAIL_TABS, RAIL_RETIRED, DEFAULT_RAIL_ORDER } = await importTs('src/utils/rail-order.ts')
import { MONITORING_TAB, routeForTab, tabForPath } from '../../src/utils/sidebar-tabs.mjs'
import { isSectionPage } from '../../src/utils/section-strip.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('monitoring tabs', () => {
  it('Agents first (the landing tab, Q1 A), then Boxes, Events (SPL-3250), Tokens (spec 140), Lanes (spec 153 C15), Topics (spec 153 3.10, SPL-4421); no Costs (SPL-3986)', () => {
    assert.deepEqual(MONITORING_TABS.map((t) => t.id), ['agents', 'boxes', 'events', 'tokens', 'lanes', 'topics', 'file-streams'])
    assert.deepEqual(MONITORING_TABS.map((t) => t.path), ['/monitoring/agents', '/monitoring/boxes', '/monitoring/events', '/monitoring/tokens', '/monitoring/lanes', '/monitoring/topics', '/monitoring/file-streams'])
    assert.equal(MONITORING_DEFAULT_PATH, '/monitoring/agents')
    for (const t of MONITORING_TABS) {
      assert.equal(t.path, '/monitoring/' + t.id, 'a tab is its own path (D4)')
      assert.equal(t.labelKey, 'monitoring.tab.' + t.id.replace(/-/g, '_'), 'a key has no hyphen: file-streams -> file_streams')
      assert.equal(typeof t.operatorsOnly, 'boolean')
    }
  })
  it('Tokens (spec 140 4.1, SPL-2322) shows beside Agents and Boxes for an operator admin, never for anyone else', () => {
    assert.deepEqual(visibleMonitoringTabs({ operator: true }).map((t) => t.id), ['agents', 'boxes', 'events', 'tokens', 'lanes', 'topics'])
    /* CONTROL: a member who is not an operator admin, or not known yet, never sees it */
    assert.deepEqual(visibleMonitoringTabs().map((t) => t.id), ['agents', 'boxes', 'events'])
    assert.deepEqual(visibleMonitoringTabs({ operator: false }).map((t) => t.id), ['agents', 'boxes', 'events'])
  })
  it('no Costs tab (SPL-3986, owner HUM-10, t1 e0fec998, msg ed506f41): Costs lives in Reporting alone', () => {
    /* "The cost tab should be removed from the monitoring section, as it does exist already in the reporting section." */
    assert.ok(!visibleMonitoringTabs({ can: () => true, operator: true, staff: true }).some((t) => t.id === 'costs'), 'the bar never draws it')
    assert.ok(!MONITORING_TABS.some((t) => t.id === 'costs' || t.path === '/monitoring/costs'), 'not even a hidden row')
    const holds = (perms) => (p) => perms.includes(p)
    assert.deepEqual(visibleMonitoringTabs({ can: holds(['costs.read']) }).map((t) => t.id), ['agents', 'boxes', 'events'])
    assert.deepEqual(visibleMonitoringTabs({ operator: true, can: holds(['costs.read']) }).map((t) => t.id), ['agents', 'boxes', 'events', 'tokens', 'lanes', 'topics'])
    /* the old link still lands on Reporting -> Costs: the page is the redirect, off the bar */
    assert.match(read('src/pages/monitoring/costs/index.vue'), /<LegacyMonitoringRedirect \/>/)
    assert.equal(monitoringTabFor('/monitoring/costs'), null)
  })
  it('case 2: Events (SPL-3250) shows to everyone who saw the Event log rail section: every reader, operator or not, any permission', () => {
    const events = MONITORING_TABS.find((t) => t.id === 'events')
    assert.deepEqual({ ...events }, { id: 'events', path: '/monitoring/events', labelKey: 'monitoring.tab.events', operatorsOnly: false, ready: true })
    /* the rail tab it replaces had no gate (RAIL_TABS draws every tab to everyone), so neither has this one */
    for (const who of [undefined, {}, { operator: false }, { operator: true }, { can: () => false }, { operator: true, can: () => true }]) {
      assert.ok(visibleMonitoringTabs(who).some((t) => t.id === 'events'), JSON.stringify(who))
    }
    assert.equal(monitoringTabFor('/monitoring/events'), 'events')
    assert.equal(monitoringTabFor('/fi/monitoring/events'), 'events')
    assert.equal(isSectionPage('/monitoring/events'), true, 'a phone shows the section strip above it')
    /* case 3: the tab is the event log page itself, rows and Clear log, its own chunk */
    const page = read('src/pages/monitoring/events/index.vue')
    for (const tid of ['events-page', 'events-table', 'events-row', 'events-clear', 'events-load-more']) assert.match(page, new RegExp(`data-test="${tid}"`), tid)
    assert.match(page, /client\.clear\(\)/)
    assert.doesNotMatch(page, /<MobileBack|<SectionClose|feed-header/, 'the Monitoring page holds the header and the tab bar')
  })
  it('File streams (spec 160 3.5, SPL-3888, C18): staff only, never an operator who is neither owner nor admin', () => {
    const fs = MONITORING_TABS.find((t) => t.id === 'file-streams')
    assert.deepEqual({ ...fs }, { id: 'file-streams', path: '/monitoring/file-streams', labelKey: 'monitoring.tab.file_streams',
      operatorsOnly: false, staff: true, staffOnly: true, ready: true })
    const ids = (who) => visibleMonitoringTabs(who).map((t) => t.id)
    assert.ok(ids({ staff: true }).includes('file-streams'), 'owner or admin')
    assert.ok(ids({ operator: true, staff: true }).includes('file-streams'), 'an operator who is also staff')
    /* C18 CONTROL: an operator who is not staff sees Lanes (its operator rule) but not File streams */
    assert.ok(ids({ operator: true, staff: false }).includes('lanes'))
    for (const who of [undefined, { operator: true }, { operator: true, staff: false }, { staff: false }, { operator: false, can: () => true }]) {
      assert.equal(ids(who).includes('file-streams'), false, JSON.stringify(who))
    }
    assert.equal(monitoringTabFor('/monitoring/file-streams'), 'file-streams')
    assert.equal(monitoringTabFor('/fi/monitoring/file-streams'), 'file-streams')
  })
  it('Lanes (spec 153 3.2, SPL-3215, C15-C16) is ready; operator admins and, since row B6, a workspace\'s staff', () => {
    const lanes = MONITORING_TABS.find((t) => t.id === 'lanes')
    assert.deepEqual({ ...lanes }, { id: 'lanes', path: '/monitoring/lanes', labelKey: 'monitoring.tab.lanes', operatorsOnly: false, staff: true, ready: true })
    /* C16 CONTROL: not an operator admin nor staff, or not known yet, never sees it, costs.read or not */
    for (const who of [undefined, { operator: false }, { operator: false, can: () => true }, { operator: false, staff: false }]) {
      assert.ok(!visibleMonitoringTabs(who).some((t) => t.id === 'lanes'), JSON.stringify(who))
    }
    assert.equal(monitoringTabFor('/monitoring/lanes'), 'lanes')
    assert.equal(monitoringTabFor('/fi/monitoring/lanes'), 'lanes')
    /* Reporting keeps its own history tab (2.4): a different path and label key */
    assert.notEqual(lanes.labelKey, 'reporting.tab.lanes')
  })
  it('Topics (spec 153 3.10, SPL-4421, C45) is ready, after Lanes, for the same readers as Lanes', () => {
    const topics = MONITORING_TABS.find((t) => t.id === 'topics')
    assert.deepEqual({ ...topics }, { id: 'topics', path: '/monitoring/topics', labelKey: 'monitoring.tab.topics', operatorsOnly: false, staff: true, ready: true })
    const ids = MONITORING_TABS.map((t) => t.id)
    assert.equal(ids.indexOf('topics'), ids.indexOf('lanes') + 1, 'right after Lanes')
    /* C45 CONTROL: whoever sees Lanes sees Topics, and nobody else */
    for (const who of [undefined, {}, { operator: false }, { operator: true }, { staff: true }, { staff: false }, { operator: true, staff: false }, { operator: false, can: () => true }]) {
      const v = visibleMonitoringTabs(who).map((t) => t.id)
      assert.equal(v.includes('topics'), v.includes('lanes'), JSON.stringify(who))
    }
    assert.equal(monitoringTabFor('/monitoring/topics'), 'topics')
    assert.equal(monitoringTabFor('/fi/monitoring/topics'), 'topics')
  })
  it('Lanes (spec 153 3.6, row B6, SPL-3229, C26): a workspace owner or admin sees the tab, a plain member does not', () => {
    /* C26: staff false has no lanes; twin: staff true has it, and Tokens stays the operator's */
    assert.deepEqual(visibleMonitoringTabs({ staff: false }).map((t) => t.id), ['agents', 'boxes', 'events'])
    assert.deepEqual(visibleMonitoringTabs({ staff: true }).map((t) => t.id), ['agents', 'boxes', 'events', 'lanes', 'topics', 'file-streams'])
    assert.deepEqual(visibleMonitoringTabs({ operator: true, staff: false }).map((t) => t.id), ['agents', 'boxes', 'events', 'tokens', 'lanes', 'topics'])
    /* who is staff: the hub's pair, TenantOwner || Has(admin) anywhere in the role set (C25b, C26b) */
    const me = (body) => normalizeMe(body)
    assert.equal(monitoringStaff(me({ role: 'biz_owner', roles: ['biz_owner'], tenant_owner: true })), true, 'the owner')
    assert.equal(monitoringStaff(me({ role: 'admin', roles: ['admin'] })), true, 'an admin')
    assert.equal(monitoringStaff(me({ role: 'developer', roles: ['developer', 'admin'] })), true, 'C26b: admin as a second role')
    assert.equal(monitoringStaff(me({ role: 'developer', roles: ['developer'] })), false, 'C26: a plain developer')
    assert.equal(monitoringStaff(me({ role: 'developer' })), false, 'an old hub with no roles: the primary only')
    assert.equal(monitoringStaff(null), false, 'not known yet')
    /* the bar passes the rule (monitoring.vue) */
    assert.match(read('src/pages/monitoring.vue'), /staff: monitoringStaff\(access\.me\)/)
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
    /* case 4 (SPL-3250): the Event log's deep link, its #<id> the caller's (LegacyMonitoringRedirect keeps route.hash) */
    assert.equal(legacyMonitoringPath('/events'), '/monitoring/events')
    assert.equal(legacyMonitoringPath('/sv/events/'), '/monitoring/events')
    assert.equal(legacyMonitoringPath('/events#42'), '/monitoring/events')
  })
  it('anything else is not an old link', () => {
    for (const p of ['/', '/monitoring/boxes', '/monitoring/events', '/people/HUM-1', '/boxes/a/b', '/agentsx', '/t/boxes', '/events/1', '/eventsx']) assert.equal(legacyMonitoringPath(p), null, p)
  })
  it('the four old pages are the redirect, and the cards live under Monitoring', () => {
    for (const f of ['agents/index', 'agents/[id]', 'boxes/index', 'boxes/[id]', 'events']) {
      assert.match(read(`src/pages/${f}.vue`), /<LegacyMonitoringRedirect \/>/, f)
    }
    const redirect = read('src/components/LegacyMonitoringRedirect.vue')
    assert.match(redirect, /onMounted\(/, 'client side: nuxt generate on static hosting runs no server redirect')
    assert.match(redirect, /query: route\.query, hash: route\.hash/, '?r= and the seat hash are kept')
    assert.match(read('src/pages/monitoring/agents/[id].vue'), /data-test="agent-message"/)
    assert.match(read('src/pages/monitoring/boxes/[id].vue'), /<BoxLoadBand v-if="!box\.browser"/)
  })
})

/* SPL-3397 (owner HUM-10, t1 1b4b6250, msg 97fd74b3): the tab bar reads as
   folder tabs with a 3D effect, the selected one raised above the others. */
describe('monitoring tab bar: 3D folder tabs', () => {
  const css = read('src/assets/css/main.css')
  /* the declarations of the top-level rule whose selector list is exactly `sel` */
  const rule = (sel) => {
    const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const m = css.match(new RegExp(`^${esc}\\s*\\{([^}]*)\\}`, 'm'))
    assert.ok(m, `rule ${sel} exists`)
    return m[1]
  }
  it('every tab is a bordered folder tab with rounded top corners, behind on a muted fill', () => {
    const tab = rule('.monitoring-tab')
    assert.match(tab, /border:\s*1px solid var\(--color-border[a-z-]*\)/, 'a border on every side')
    assert.match(tab, /border-radius:\s*var\(--radius-sm\) var\(--radius-sm\) 0 0/, 'rounded top corners only')
    assert.match(tab, /background:\s*var\(--color-bg-2\)/, 'unselected tabs sit behind, muted')
  })
  it('the selected tab joins the panel below and is raised in front', () => {
    const on = rule('.monitoring-tab--active')
    assert.match(on, /background:\s*var\(--color-bg\)/, "the panel's own background")
    assert.match(on, /border-bottom-color:\s*var\(--color-bg\)/, 'no bottom border: it joins the panel')
    assert.match(on, /box-shadow:\s*var\(--tab-lift\)/, 'a shadow upward: it reads as in front')
    const vars = read('src/assets/css/variables.css')
    const lifts = [...vars.matchAll(/--tab-lift:\s*([^;]+);/g)].map((x) => x[1])
    assert.equal(lifts.length, 2, 'one lift per theme family, dark and light')
    for (const l of lifts) assert.match(l, /^0 -\d+px \d+px rgba\([^)]*\)$/, `upward, blurred, no spread, no inset: ${l}`)
    assert.match(on, /z-index:\s*[1-9]/, 'drawn over its neighbours')
    /* the bar aligns its tabs at the bottom (flex-end): the selected one stands taller */
    const top = (body) => Number((body.match(/padding-top:\s*(\d+)px/) || body.match(/padding:\s*(\d+)px/))[1])
    assert.ok(top(on) > top(rule('.monitoring-tab')), 'taller than the others')
  })
  it('both themes: the tab rules use theme tokens only, never a literal colour', () => {
    for (const sel of ['.monitoring-tab', '.monitoring-tab--active']) assert.doesNotMatch(rule(sel), /#[0-9a-f]{3,8}\b|rgba?\(/i, sel)
  })
  it('the selected tab is marked for assistive tech, and no :style binding (CSP)', () => {
    const page = read('src/pages/monitoring.vue')
    assert.match(page, /'monitoring-tab--active': active === tab\.id/)
    assert.match(page, /:aria-current="active === tab\.id \? 'page' : undefined"/)
    assert.doesNotMatch(page, /:style=/)
  })
})
