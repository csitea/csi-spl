// The left strip is four icon tabs, top to bottom: direct messages,
// channels, topics, flow. The strip is at most 5% of the viewport.
//
// Run: node tests/unit/sidebar-tabs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { SIDE_TABS, switchPaneOf, tabForPath } from '../../src/utils/sidebar-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('tabForPath', () => {
  it('the strip order is direct messages, channels, topics, flow', () => {
    assert.deepEqual([...SIDE_TABS], ['dm', 'channels', 'topics', 'flow'])
  })

  it('a route opens its own tab', () => {
    assert.equal(tabForPath('/dm/HUM-1@box-wui'), 'dm')
    assert.equal(tabForPath('/fi/dm/CLE-07@box-a'), 'dm')
    assert.equal(tabForPath('/channel/tasks'), 'channels')
    assert.equal(tabForPath('/en/channel/lobby'), 'channels')
    assert.equal(tabForPath('/'), 'topics')
    assert.equal(tabForPath('/fi'), 'topics')
    assert.equal(tabForPath('/t/abc'), 'topics')
    assert.equal(tabForPath('/fi/t/abc'), 'topics')
    /* CLE-77799: Boxes is a list-then-card tab like People / Agents */
    assert.equal(tabForPath('/boxes'), 'boxes')
    assert.equal(tabForPath('/boxes/box-a'), 'boxes')
    assert.equal(tabForPath('/fi/boxes/box-wui'), 'boxes')
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

describe('/switch-pane:', () => {
  it('messages, channels and topics open those panes', () => {
    assert.equal(switchPaneOf('/switch-pane: messages'), 'dm')
    assert.equal(switchPaneOf('/switch-pane: channels'), 'channels')
    assert.equal(switchPaneOf('/switch-pane: topics'), 'topics')
    assert.equal(switchPaneOf('/switch-pane: topic'), 'topics')
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

  it('the rail lists the four tabs in order, icons only', () => {
    /* SPL-979: the default order and icons live in utils/rail-order.mjs */
    const tabs = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/utils/rail-order.mjs'), 'utf8')
    const ids = ["'channels'", "'dm'", "'topics'", "'flow'"]
    let at = 0
    for (const id of ids) {
      const i = tabs.indexOf(`id: ${id}`, at)
      assert.ok(i > at, id)
      at = i
    }
    assert.match(tabs, /icon: 'messages'/)
    assert.match(tabs, /icon: 'hash'/)
    assert.match(tabs, /icon: 'list'/)
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

  it('topics and flow are their own panels; topics is not a row inside channels', () => {
    const ch = vue.indexOf('data-testid="sidebar-panel-channels"')
    const topics = vue.indexOf('data-testid="sidebar-panel-topics"')
    const flow = vue.indexOf('data-testid="sidebar-panel-flow"')
    assert.ok(ch > 0 && topics > ch && flow > topics)
    assert.match(vue, /v-for="\(row, topicIndex\) in topicRows"/)
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
    assert.match(vue, /topicOpening\(subject\)/)
    assert.match(vue, /t\('topic\.list_title'/)
    assert.equal(en.search.group.topics, 'Topics')
  })
})
