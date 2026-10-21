// The left strip's list tabs, top to bottom: direct messages, channels,
// flow. The Topics tab is gone (owner HUM-10, t1 e4bfddb1, msg a78e06c8).
// The strip is at most 5% of the viewport.
//
// Run: node tests/unit/sidebar-tabs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { SIDE_TABS, routeForTab, switchPaneOf, tabForPath } from '../../src/utils/sidebar-tabs.mjs'
const { RAIL_IDS } = await importTs('src/utils/rail-order.ts')
import { isMobileFrontDoor } from '../../src/utils/mobile-stack.mjs'
import { importTs } from './lib/load-ts.mjs'

const { lobbyHomeTarget, noteLoadedUrl, takeLoadedQuery } = await importTs('src/utils/home-target.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('tabForPath', () => {
  it('the strip order is direct messages, channels, flow: no Topics tab', () => {
    assert.deepEqual([...SIDE_TABS], ['dm', 'channels', 'flow'])
    assert.equal(SIDE_TABS.includes('topics'), false)
  })

  it('a route opens its own tab', () => {
    assert.equal(tabForPath('/dm/HUM-1@box-wui'), 'dm')
    assert.equal(tabForPath('/fi/dm/CLE-07@box-a'), 'dm')
    assert.equal(tabForPath('/channel/tasks'), 'channels')
    assert.equal(tabForPath('/en/channel/lobby'), 'channels')
    /* t1 e4bfddb1: the front door and a topic's own page sit under Channels */
    assert.equal(tabForPath('/'), 'channels')
    assert.equal(tabForPath('/fi'), 'channels')
    assert.equal(tabForPath('/t/abc'), 'channels')
    assert.equal(tabForPath('/fi/t/abc'), 'channels')
    /* CONTROL: no path answers the gone tab */
    for (const p of ['/', '/t', '/t/abc', '/fi', '/topics']) assert.notEqual(tabForPath(p), 'topics', p)
    /* SPL-2075: Boxes and Agents are Monitoring tabs; an old link is Monitoring's */
    for (const p of ['/boxes', '/boxes/box-a', '/fi/boxes/box-wui', '/agents', '/agents/c-001@box-a']) assert.equal(tabForPath(p), 'monitoring', p)
  })

  it('lobby, search and settings keep the reader\'s current tab', () => {
    for (const path of ['/lobby', '/fi/lobby', '/search', '/settings', '/fi/search']) {
      assert.equal(tabForPath(path), null, path)
    }
  })

  it('does not treat a lookalike path as a tab', () => {
    assert.equal(tabForPath('/dmail'), null)
    assert.equal(tabForPath('/channels'), null)
  })
})

describe('routeForTab (081 T003)', () => {
  const LISTS = ['dm', 'channels', 'flow']

  it('forward then back: every page tab opens a path that names it again', () => {
    for (const id of [...RAIL_IDS, 'users']) {
      const to = routeForTab(id)
      if (LISTS.includes(id)) continue
      assert.equal(typeof to, 'string', id)
      assert.equal(tabForPath(to), id, id)
      /* the caller adds the locale; the tab survives it */
      assert.equal(tabForPath('/fi' + (to === '/' ? '' : to)), id, id)
    }
  })

  it('back then forward: the tab of a page routes to a path of the same tab', () => {
    for (const path of ['/issues', '/users', '/events', '/archive', '/people', '/people/HUM-1', '/agents/c-001@box-a', '/boxes/box-a', '/fi/boxes']) {
      const tab = tabForPath(path)
      assert.ok(tab, path)
      assert.equal(tabForPath(routeForTab(tab)), tab, path)
    }
  })

  it('the sidebar lists have no page: null, the caller shows the list', () => {
    for (const id of LISTS) assert.equal(routeForTab(id), null, id)
    /* the Topics tab's page (`/`) is no tab's route any more */
    assert.equal(routeForTab('topics'), null)
    assert.equal(routeForTab(tabForPath('/')), null)
    assert.equal(routeForTab(tabForPath('/t/abc')), null)
    assert.equal(routeForTab(tabForPath('/dm/HUM-1@box-wui')), null)
    assert.equal(routeForTab(tabForPath('/channel/feedback')), null)
  })

  it('an unknown id has no route', () => {
    for (const id of ['', 'nope', 'settings', 'toString', '__proto__']) assert.equal(routeForTab(id), null, id)
  })

  it('every rail tab is either a page or a list', () => {
    for (const id of RAIL_IDS) assert.ok(routeForTab(id) !== null || LISTS.includes(id), id)
  })
})

describe('/switch-pane:', () => {
  it('messages and channels open those panes; topics (also topic) still parses and opens Channels', () => {
    assert.equal(switchPaneOf('/switch-pane: messages'), 'dm')
    assert.equal(switchPaneOf('/switch-pane: channels'), 'channels')
    assert.equal(switchPaneOf('/switch-pane: topics'), 'channels')
    assert.equal(switchPaneOf('/switch-pane: topic'), 'channels')
    assert.equal(switchPaneOf('/Switch-Pane: Topics'), 'channels')
    assert.equal(switchPaneOf('/switch-pane: flow'), 'flow')
    assert.equal(switchPaneOf('  /Switch-Pane: Messages  '), 'dm')
    assert.equal(switchPaneOf('/switch-pane:channels'), 'channels')
  })

  it('an unknown name is the command but not a pane, and other lines are messages', () => {
    assert.equal(switchPaneOf('/switch-pane:'), '')
    assert.equal(switchPaneOf('/switch-pane: nope'), '')
    assert.equal(switchPaneOf('/switch-pane: messages please'), '')
    assert.equal(switchPaneOf('hello'), null)
    assert.equal(switchPaneOf('/search messages'), null)
  })

  it('the omnibox runs the command before it can send the line', () => {
    const composer = src('src/components/MessageComposer.vue')
    const send = composer.indexOf("emit('send'")
    const cmd = composer.indexOf('switchPaneOf(text.value)')
    assert.ok(cmd > 0 && send > cmd)
    assert.match(composer, /useSidePane\(\)\.request\(pane\)/)
    assert.match(src('src/components/ChannelSidebar.vue'), /sidePane\.requested/)
  })
})

describe('the strip is icons, in that order', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  const css = src('src/assets/css/main.css')

  it('the rail lists the list tabs in order, icons only', () => {
    /* SPL-979: the default order and icons live in utils/rail-order.ts */
    const tabs = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/utils/rail-order.ts'), 'utf8')
    const ids = ["'channels'", "'dm'", "'flow'"]
    let at = 0
    for (const id of ids) {
      const i = tabs.indexOf(`id: ${id}`, at)
      assert.ok(i > at, id)
      at = i
    }
    assert.match(tabs, /icon: 'messages'/)
    assert.match(tabs, /icon: 'hash'/)
    assert.doesNotMatch(tabs, /id: 'topics'/)
    assert.match(tabs, /icon: 'waves'/)
    // owner 2026-09-28 (topic bea3a4e6): the rendered rail is RAIL - no Users
    // icon (the users CRUD is Settings -> Members) - and the settings gear
    // sits at the foot of the strip, not on the footer row by the version.
    assert.match(vue, /v-for="item in rail"/)
    // rail is RAIL, minus the DM tab while acting as a member (specs/054)
    assert.match(vue, /const rail = computed\(\(\) => \(acting\.value \? RAIL\.value\.filter\(\(item\) => item\.id !== 'dm'\) : RAIL\.value\)\)/)
    assert.doesNotMatch(vue, /icon: 'users'/)
    assert.doesNotMatch(vue, /data-testid="sidebar-panel-users"/)
    const strip = vue.slice(vue.indexOf('class="sidebar-rail"'), vue.indexOf('class="sidebar-body"'))
    assert.match(strip, /class="sidebar-rail__settings"[\s\S]{0,120}data-testid="tenant-settings-open"/)
    assert.match(strip, /role="tablist"/)
    const foot = vue.slice(vue.indexOf('<div class="sidebar-foot">'), vue.indexOf('</nav>'))
    assert.doesNotMatch(foot, /tenant-settings-open/)
    assert.match(vue, /:aria-label="t\(item\.labelKey\)"/)
    assert.match(vue, /:title="t\(item\.labelKey\)"/)
    const rail = vue.slice(vue.indexOf('class="sidebar-rail"'), vue.indexOf('class="sidebar-body"'))
    /* SPL-989: the only words are the phone strip's label, hidden above 820 px
       (CLE-77886: also on the phone strip's endless-roll copies) */
    assert.doesNotMatch(rail.replace(/<span class="sidebar-tab__label"[^>]*>\{\{ t\(item\.labelKey\) \}\}<\/span>/g, ''), /\{\{\s*t\(/)
    const style = vue.slice(vue.indexOf('<style'))
    const outside = style.slice(0, style.indexOf('@media (max-width: 820px) {\n  .sidebar-main'))
    assert.match(outside, /\.sidebar-tab__label \{ display: none; \}/)
  })

  it('flow is its own panel; there is no Topics panel (t1 e4bfddb1)', () => {
    const ch = vue.indexOf('data-testid="sidebar-panel-channels"')
    const flow = vue.indexOf('data-testid="sidebar-panel-flow"')
    assert.ok(ch > 0 && flow > ch)
    assert.doesNotMatch(vue, /sidebar-panel-topics/)
    assert.doesNotMatch(vue, /topicRows|topicOrder/)
    assert.doesNotMatch(vue, /=== 'topics'/)
    assert.match(vue, /<LazyFlowList/)
    assert.match(vue, /t\('sidebar\.flow'\)/)
    assert.doesNotMatch(vue, /navigateTo\(localePath\('\/lobby'\)\)/)
  })

  it('starts on direct messages', () => {
    assert.match(vue, /ref<SideTab>\('dm'\)/)
  })

  it('the strip is at most 5% of the viewport and at most one icon wide', () => {
    assert.match(css, /\.sidebar-rail\s*\{[^}]*width:\s*min\(5vw,\s*48px\)/)
    assert.match(css, /\.sidebar-rail\s*\{[^}]*max-width:\s*min\(5vw,\s*48px\)/)
    assert.match(css, /\.sidebar-rail\s*\{[^}]*min-width:\s*0/)
    assert.equal(/\b100vw\b/.test(css), false)
  })

  it('the glyphs are path-only strokes', () => {
    const icons = src('src/utils/uiIcons.ts')
    assert.match(icons, /messages:\s*\[/)
    assert.match(icons, /hash:\s*\["M4 9h16", "M4 15h16", "M10 3 8 21", "M16 3 14 21"\]/)
    assert.match(icons, /list:\s*\["M3 6h18", "M3 12h18", "M3 18h18"\]/)
    assert.match(icons, /waves:\s*\[/)
  })

  it('every locale has a Flow name', () => {
    const en = JSON.parse(src('i18n/locales/en.json'))
    assert.equal(en.sidebar.flow, 'Flow')
    assert.equal(en.nav.topics, 'Topics')
    assert.equal(en.topic.title, 'Topic')
    assert.equal(en.topic.list_title, 'Topic: {text}')
    assert.doesNotMatch(vue, /topic\.list_title/)
    /* the Topics list's own keys went with it, from every locale */
    assert.equal(en.pages.index, undefined)
    assert.equal(en.feed.shortcuts.archive_topic_row, undefined)
    assert.equal(en.search.group.topics, 'Topics')
  })
})

/* t1 e4bfddb1: `/` was the Topics list; it now lands on Channels */
describe('lobbyHomeTarget: where `/` sends the reader', () => {
  it('a desktop opens #lobby, a topic deep link rides along', () => {
    assert.deepEqual(lobbyHomeTarget({ phone: false, query: {} }), { path: '/lobby', query: {} })
    assert.deepEqual(lobbyHomeTarget({ phone: false, query: { topic: 'abc' } }), { path: '/lobby', query: { topic: 'abc' } })
    assert.deepEqual(lobbyHomeTarget({ phone: false }), { path: '/lobby', query: {} })
  })
  it('a phone stays on `/` (its left panel, the Channels list) unless the link names a topic', () => {
    assert.equal(lobbyHomeTarget({ phone: true, query: {} }), null)
    assert.equal(lobbyHomeTarget({ phone: true }), null)
    assert.deepEqual(lobbyHomeTarget({ phone: true, query: { topic: 'abc' } }), { path: '/lobby', query: { topic: 'abc' } })
    assert.deepEqual(lobbyHomeTarget({ phone: true, query: { in: 'abc' } }), { path: '/lobby', query: { in: 'abc' } })
  })
  it('the query is a copy: the route\'s own object is never changed', () => {
    const q = { topic: 'abc' }
    lobbyHomeTarget({ phone: false, query: q }).query.x = 1
    assert.deepEqual(q, { topic: 'abc' })
  })
  it('pages/index.vue is the redirect, no topic list', () => {
    const page = src('src/pages/index.vue')
    assert.match(page, /lobbyHomeTarget\(/)
    assert.match(page, /replace: true/)
    assert.doesNotMatch(page, /viewer\.topics|topic-row|nav\.topics/)
  })
})

/* the hydration of a prerendered `/` drops the query from the address and
   restores it later, so `/` reads the address as loaded, once (t1 e4bfddb1) */
describe('takeLoadedQuery: the address `/` was loaded with', () => {
  it('gives a front-door load\'s query once, then null (a later visit reads the router)', () => {
    noteLoadedUrl('/fi', '?topic=abc&x=1')
    noteLoadedUrl('/lobby', '?topic=zzz')
    assert.deepEqual(takeLoadedQuery(isMobileFrontDoor), { topic: 'abc', x: '1' }, 'the first note wins')
    assert.equal(takeLoadedQuery(isMobileFrontDoor), null, 'taken once')
    noteLoadedUrl('/', '?topic=again')
    assert.equal(takeLoadedQuery(isMobileFrontDoor), null, 'one note per document')
    assert.equal(isMobileFrontDoor('/lobby'), false, 'CONTROL a load of another page is not the front door')
  })
  it('the plugin notes it before the page mounts', () => {
    const plugin = readFileSync(join(WUI, 'src/plugins/0.loaded-url.client.ts'), 'utf8')
    assert.match(plugin, /enforce: 'pre'/)
    assert.match(plugin, /noteLoadedUrl\(window\.location\.pathname, window\.location\.search\)/)
    assert.match(readFileSync(join(WUI, 'src/pages/index.vue'), 'utf8'), /takeLoadedQuery\(isMobileFrontDoor\)/)
  })
})
