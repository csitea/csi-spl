// t1 8fb802cd (owner: "in the actual topics section it's not clear whether or
// not a topic is archived. If a topic is archived it should be clearly marked
// as archived"). Every list leaves an archived topic out (specs/041); where
// one still renders - a topic opened by its id, a row - it carries the
// ArchivedBadge (archive glyph + the word) and a muted style. A live topic
// renders neither: that is the control.
//
// The row and header templates are cut from the SHIPPED components and
// rendered with Vue's own compiler + server renderer, so a template that
// drops the badge fails here, not in a screenshot.
//
// Run: node tests/unit/archived-mark.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import { compile } from '@vue/compiler-dom'
import { renderToString } from 'vue/server-renderer'
import { archiveStamp } from '../../src/utils/topic-archive.mjs'
import { mergeTopicPage } from '../../src/utils/topic-list.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const STAMP = '2026-10-02T12:00:00Z'

/** The <template> of an SFC. */
function templateOf(file) {
  const s = read(file)
  return s.slice(s.indexOf('<template>') + 10, s.lastIndexOf('</template>'))
}

/** The first element in `src` opening with `open`, through its matching close tag. */
function cut(src, open) {
  const at = src.indexOf(open)
  assert.ok(at >= 0, `template has ${open}`)
  const tag = open.match(/^<([\w-]+)/)[1]
  const re = new RegExp(`<${tag}\\b|</${tag}>`, 'g')
  re.lastIndex = at
  let depth = 0
  for (let m = re.exec(src); m; m = re.exec(src)) {
    depth += m[0].startsWith('</') ? -1 : 1
    if (depth === 0) return src.slice(at, m.index + m[0].length)
  }
  throw new Error(`unclosed ${open}`)
}

/* The badge itself, rendered from ArchivedBadge.vue's template with the
   catalogue's own words (en): the glyph + "Archived", the date as the title. */
const en = JSON.parse(read('i18n/locales/en.json'))
const t = (key, params = {}) => key.split('.').reduce((o, k) => o?.[k], en).replace(/\{(\w+)\}/g, (_, k) => params[k])
const UiIcon = { props: ['name'], render() { return Vue.h('svg', { 'data-icon': this.name }) } }
function component(template, ctx) {
  /* the SFCs are lang="ts": a non-null assertion is the one TS form these templates use */
  const code = compile(template.replace(/\)!\./g, ').'), { mode: 'function', prefixIdentifiers: false }).code
  const render = new Function('Vue', code)(Vue)
  const scope = new Proxy({}, {
    /* the compiler's own helpers (_Vue, _toDisplayString ...) and globals stay outside the scope */
    has: (_, k) => typeof k === 'string' && !k.startsWith('_') && !(k in globalThis),
    get: (_, k) => (k in ctx ? ctx[k] : () => ''),
  })
  return { render: (_c, cache) => render(scope, cache || []) }
}
const ArchivedBadge = {
  props: ['at', 'showWhen'],
  setup(props) {
    const tpl = component(templateOf('src/components/ArchivedBadge.vue'), {
      t,
      get when() { return props.at ? `when:${props.at}` : '' },
      get date() { return props.at ? String(props.at).slice(0, 10) : '' },
      get showWhen() { return Boolean(props.showWhen) },
    })
    return () => tpl.render(null, [])
  },
}

async function html(template, ctx) {
  const app = Vue.createSSRApp(component(template, ctx))
  app.component('ArchivedBadge', ArchivedBadge)
  app.component('UiIcon', UiIcon)
  for (const stub of ['SpoolAvatar', 'KindBadge', 'MobileBack', 'UiCloseButton', 'LazyCardClipControl']) app.component(stub, { render: () => null })
  app.config.warnHandler = () => {}
  return renderToString(app)
}

const live = { task_id: 'live-1', subject: 'live topic', kinds: {}, participants: ['HUM-2@box-wui'], count: 2, last_ts: STAMP }
const archived = { ...live, task_id: 'arch-1', subject: 'archived topic', archived_at: STAMP }

describe('ArchivedBadge', () => {
  it('is the archive glyph and the word, the date on hover', async () => {
    const out = await html('<ArchivedBadge :at="at" />', { at: STAMP })
    assert.match(out, /data-test="archived-badge"/)
    assert.match(out, /data-icon="archive"/)
    assert.match(out, />Archived</)
    assert.match(out, new RegExp(`title="Archived when:${STAMP}"`))
    assert.doesNotMatch(out, /archived-badge__when/, 'a row badge keeps the day on the title')
  })
  it('show-when prints the day; the full stamp stays the title', async () => {
    const out = await html('<ArchivedBadge :at="at" :show-when="true" />', { at: STAMP })
    assert.match(out, /archived-badge__when[^>]*>2026-10-02</)
    assert.match(out, />Archived</)
    assert.match(out, new RegExp(`title="Archived when:${STAMP}"`))
  })
  it('every locale names it (archive.badge)', () => {
    const dir = join(WUI, 'i18n/locales')
    for (const f of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const cat = JSON.parse(readFileSync(join(dir, f + '.json'), 'utf8'))
      assert.ok(cat.archive?.badge && cat.archive.badge === cat.archive.undo.done, `${f}: archive.badge`)
    }
  })
})

describe('the Topics rows mark an archived topic, never a live one', () => {
  const sidebarRow = cut(templateOf('src/components/ChannelSidebar.vue').slice(templateOf('src/components/ChannelSidebar.vue').indexOf('id="sidebar-panel-topics"')), '<a\n          class="nav-item"')
  const homeRow = cut(templateOf('src/pages/index.vue'), '<a\n        class="topic-row"')
  const helpers = { localePath: (p) => p, tr: (k) => k, t: (k) => k, namedLine: () => ({}), people: { names: { value: {} } },
    topicRowTitle: (s) => s, peopleLabels: () => '', topicPeople: () => ({ text: 'people' }), topicStarter: () => null, rowTime: () => '', pane: {} }

  for (const [name, row, key] of [['sidebar', sidebarRow, 'row'], ['home list', homeRow, 't']]) {
    it(`${name}: archived -> badge + muted; live -> neither (control)`, async () => {
      const a = await html(row, { ...helpers, [key]: archived })
      assert.match(a, /data-test="archived-badge"/, `${name} archived row has the badge`)
      assert.match(a, /class="[^"]*\bis-archived\b/, `${name} archived row is muted`)
      const l = await html(row, { ...helpers, [key]: live })
      assert.doesNotMatch(l, /archived-badge/, `${name} live row has no badge`)
      assert.doesNotMatch(l, /is-archived/, `${name} live row is not muted`)
    })
  }
})

describe('the open topic header marks an archived topic', () => {
  const panes = [
    ['TopicPane', cut(templateOf('src/components/TopicPane.vue'), '<header>'), (at) => ({ archivedAt: at, heading: 'h', topic: {} })],
    ['LiveTopicPane', cut(templateOf('src/components/LiveTopicPane.vue'), '<header>'), (at) => ({ pane: { archivedAt: at }, heading: 'h', topic: {} })],
    ['/t/<id>', cut(templateOf('src/pages/t/[task_id].vue'), '<a\n          class="topic-row"'), (at) => ({ row: at ? { ...archived, archived_at: at } : live, taskId: 'other', t: (k) => k, localePath: (p) => p, rowTitle: (s) => s })],
  ]
  for (const [name, tpl, ctx] of panes) {
    it(`${name}: archived -> badge; live -> none (control)`, async () => {
      const a = await html(tpl, ctx(STAMP))
      assert.match(a, /data-test="archived-badge"/)
      if (name === 'TopicPane' || name === 'LiveTopicPane') {
        assert.match(a, /archived-badge__when[^>]*>2026-10-02</, `${name} header prints the day`)
      } else {
        assert.doesNotMatch(a, /archived-badge__when/, `${name} keeps the day on the title`)
      }
      assert.doesNotMatch(await html(tpl, ctx('')), /archived-badge/)
    })
  }
})

/* t1 404cd808 (owner: "it must be a clear indication in this view if
   somethign is archived"): the DM page opened on an archived topic (?topic=)
   marks it in its own header - the SHIPPED DM page's <FeedHeader> rendered
   with the SHIPPED FeedHeader.vue template. A live topic: no mark (control). */
describe('the DM view header marks an archived open topic', () => {
  const headerTpl = templateOf('src/components/FeedHeader.vue')
  const dmPage = templateOf('src/pages/dm/[peer].vue')
  const dmTpl = dmPage.slice(dmPage.indexOf('<FeedHeader'), dmPage.indexOf('/>', dmPage.indexOf('<FeedHeader')) + 2) /* self-closing */
  const FeedHeader = {
    props: ['title', 'titleTip', 'status', 'statusText', 'statusShown', 'archivedAt', 'topicTitle'],
    setup(props) {
      const tpl = component(headerTpl, new Proxy({ t: (k) => k }, { get: (o, k) => (k in o ? o[k] : props[k]), has: () => true }))
      return () => tpl.render(null, [])
    },
  }
  async function dm(at, title) {
    const app = Vue.createSSRApp(component(dmTpl, {
      peerName: 'RSP-01', peer: 'RSP-01@box-rsp', presence: { status: 'off', key: 'k', params: {} }, t: (k) => k,
      openArchive: { at, title },
    }))
    app.component('FeedHeader', FeedHeader)
    app.component('ArchivedBadge', ArchivedBadge)
    app.component('UiIcon', UiIcon)
    for (const stub of ['MobileBack', 'CardClipControl']) app.component(stub, { render: () => null })
    app.config.warnHandler = () => {}
    return renderToString(app)
  }
  it('archived -> the badge beside the muted topic title', async () => {
    const out = await dm(STAMP, 'deploy the relay')
    assert.match(out, /data-test="archived-badge"/)
    assert.match(out, /class="feed-header__topic is-archived"/)
    assert.match(out, /class="feed-header__topic-title">deploy the relay</)
    assert.match(out, />RSP-01</, 'the peer name stays the title')
  })
  it('live topic (or none open) -> no badge, nothing muted (control)', async () => {
    const out = await dm('', '')
    assert.doesNotMatch(out, /archived-badge/)
    assert.doesNotMatch(out, /is-archived/)
    assert.match(out, />RSP-01</)
  })
})

describe('archiveStamp (the getTopic answer)', () => {
  it('is the hub stamp, or empty for a live topic or junk', () => {
    assert.equal(archiveStamp({ task_id: 'x', messages: [], archived_at: STAMP }), STAMP)
    for (const v of [{ task_id: 'x', messages: [] }, null, undefined, 'x', { archived_at: 7 }]) assert.equal(archiveStamp(v), '')
  })
})

describe('reconnect catch-up drops a row the hub no longer lists (the stale-row leak)', () => {
  const row = (id, ts) => ({ task_id: id, last_ts: ts, count: 1, kinds: {}, participants: [], subject: id })
  it('a held row inside the fresh page span that the page lacks was archived away: it goes', () => {
    const held = [row('a', '2026-10-02T10:05:00Z'), row('gone', '2026-10-02T10:03:00Z'), row('old', '2026-09-01T10:00:00Z')]
    const page = [row('a', '2026-10-02T10:05:00Z'), row('b', '2026-10-02T10:01:00Z')]
    assert.deepEqual(mergeTopicPage(held, page).map((r) => r.task_id), ['a', 'b', 'old'])
  })
  it('a row newer than the page (a live bump racing the read) stays; an empty page drops nothing', () => {
    const held = [row('new', '2026-10-02T11:00:00Z'), row('a', '2026-10-02T10:05:00Z')]
    assert.deepEqual(mergeTopicPage(held, [row('a', '2026-10-02T10:05:00Z')]).map((r) => r.task_id), ['new', 'a'])
    assert.deepEqual(mergeTopicPage(held, []).map((r) => r.task_id), ['new', 'a'])
  })
})
