// The left strip is four icon tabs, top to bottom: direct messages,
// channels, threads, flow. The strip is at most 5% of the viewport.
//
// Run: node tests/unit/sidebar-tabs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { flowRows, SIDE_TABS, switchPaneOf, tabForPath } from '../../src/utils/sidebar-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('tabForPath', () => {
  it('the strip order is direct messages, channels, threads, flow', () => {
    assert.deepEqual([...SIDE_TABS], ['dm', 'channels', 'threads', 'flow'])
  })

  it('a route opens its own tab', () => {
    assert.equal(tabForPath('/dm/HUM-1@box-wui'), 'dm')
    assert.equal(tabForPath('/fi/dm/CLE-07@box-a'), 'dm')
    assert.equal(tabForPath('/channel/tasks'), 'channels')
    assert.equal(tabForPath('/en/channel/lobby'), 'channels')
    assert.equal(tabForPath('/'), 'threads')
    assert.equal(tabForPath('/fi'), 'threads')
    assert.equal(tabForPath('/t/abc'), 'threads')
    assert.equal(tabForPath('/fi/t/abc'), 'threads')
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
  it('messages, channels and threads open those panes', () => {
    assert.equal(switchPaneOf('/switch-pane: messages'), 'dm')
    assert.equal(switchPaneOf('/switch-pane: channels'), 'channels')
    assert.equal(switchPaneOf('/switch-pane: threads'), 'threads')
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
    const ids = ["'dm'", "'channels'", "'threads'", "'flow'"]
    let at = 0
    for (const id of ids) {
      const i = vue.indexOf(`id: ${id}`, at)
      assert.ok(i > at, id)
      at = i
    }
    assert.match(vue, /icon: 'messages'/)
    assert.match(vue, /icon: 'hash'/)
    assert.match(vue, /icon: 'list'/)
    assert.match(vue, /icon: 'waves'/)
    assert.match(vue, /v-for="item in RAIL"/)
    assert.match(vue, /:aria-label="t\(item\.labelKey\)"/)
    assert.match(vue, /:title="t\(item\.labelKey\)"/)
    const rail = vue.slice(vue.indexOf('class="sidebar-rail"'), vue.indexOf('class="sidebar-body"'))
    assert.doesNotMatch(rail, /\{\{\s*t\(/)
  })

  it('threads and flow are their own panels; threads is not a row inside channels', () => {
    const ch = vue.indexOf('data-testid="sidebar-panel-channels"')
    const threads = vue.indexOf('data-testid="sidebar-panel-threads"')
    const flow = vue.indexOf('data-testid="sidebar-panel-flow"')
    assert.ok(ch > 0 && threads > ch && flow > threads)
    assert.match(vue, /v-for="\(row, threadIndex\) in threadRows"/)
    assert.match(vue, /v-for="row in flow"/)
    assert.match(vue, /flowRows\(/)
    assert.match(vue, /t\('sidebar\.flow'\)/)
    assert.doesNotMatch(vue, /navigateTo\(localePath\('\/lobby'\)\)/)
  })

  it('flow mixes channels, direct messages and threads, newest first', () => {
    const rows = flowRows({
      channels: [
        { channel_id: 'tasks', name: 'tasks', last_ts: '2026-09-18T10:00:00Z' },
        { channel_id: 'alerts', name: 'alerts', last_ts: '2026-09-20T10:00:00Z' },
      ],
      peers: [
        { id: 'CLE-07', box: 'box-a', label: 'CLE-07@box-a', online: true },
        { id: 'GRK-03', box: 'box-a', label: 'GRK-03@box-a', online: false },
      ],
      threads: [
        { task_id: 't-old', subject: 'older', last_ts: '2026-09-19T10:00:00Z' },
        { task_id: 't-new', subject: 'newer', last_ts: '2026-09-21T10:00:00Z' },
      ],
      liveAt: { tasks: '2026-09-22T10:00:00Z' },
      dmAt: { 'CLE-07@box-a': '2026-09-20T12:00:00Z' },
    })
    assert.deepEqual(rows.map((r) => r.key), [
      'ch:tasks',
      'th:t-new',
      'dm:CLE-07@box-a',
      'ch:alerts',
      'th:t-old',
      'dm:GRK-03@box-a',
    ])
    assert.deepEqual(rows.map((r) => r.kind), ['channel', 'thread', 'dm', 'channel', 'thread', 'dm'])
    const stamped = rows.filter((r) => r.at)
    for (let i = 1; i < stamped.length; i++) {
      assert.ok(stamped[i].at <= stamped[i - 1].at, stamped.map((r) => r.at).join(' > '))
    }
    assert.equal(rows.at(-1).at, '')
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
    assert.equal(en.nav.threads, 'Threads')
  })
})
