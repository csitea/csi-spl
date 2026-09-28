// SPL-941: the middle pane's header is one FeedHeader for the
// channel, DM and lobby pages. Owner, 2026-09-26: the title is what you are
// reading, "last 30 · tenant-scoped" is gone, the channel description is not
// shown (it lives in channel Properties), and the card height control is a
// compact icon control at the right edge with a tooltip per mode.
// Run: node --test tests/unit/feed-header.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const template = (p) => {
  const s = read(p)
  return s.slice(s.indexOf('<template>'), s.lastIndexOf('</template>'))
}
const PAGES = ['src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue', 'src/pages/lobby.vue']

describe('FeedHeader: one header for channel, DM and lobby', () => {
  for (const p of PAGES) {
    it(`${p} renders FeedHeader and no header of its own`, () => {
      const t = template(p)
      assert.match(t, /<FeedHeader\b/)
      assert.doesNotMatch(t, /<header class="feed-header"/)
      assert.doesNotMatch(t, /<CardClipControl/, 'the control comes with FeedHeader')
      assert.doesNotMatch(t, /t\('pane\.msgs'\)/, 'no visible "Msgs" label')
      assert.doesNotMatch(t, /channel-description|feed-header__about/, 'no channel description')
      assert.doesNotMatch(t, /subtitle/, 'no "last 30 · tenant-scoped" note')
    })
  }

  it('the channel title is #<name>, the lobby #lobby, the DM the peer (id@box on hover)', () => {
    assert.match(template(PAGES[0]), /<FeedHeader :title="'#' \+ titleName"/)
    assert.match(template(PAGES[1]), /:title="peerName"[\s\S]*?:title-tip="peer"/)
    assert.match(template(PAGES[2]), /title="#lobby"/)
  })

  it('DM and lobby keep their status as the dot plus its tooltip', () => {
    assert.match(template(PAGES[1]), /:status="online \? 'on' : 'off'"[\s\S]*?pages\.dm\.offline_queued/)
    assert.match(template(PAGES[2]), /:status="live\.state\.value === 'open' \? 'on' : 'off'"[\s\S]*?pages\.lobby\.status/)
  })

  it('the component: the pane label for screen readers, title, status text, the control', () => {
    const t = template('src/components/FeedHeader.vue')
    assert.match(t, /<header class="feed-header feed-header--pane" data-test="feed-header" :aria-label="t\('pane\.msgs'\)">/)
    assert.match(t, /<h2 class="feed-header__title" :title="titleTip \|\| title">\{\{ title \}\}<\/h2>/)
    assert.match(t, /v-if="status"[\s\S]*?class="dot"[\s\S]*?:title="statusText"/)
    assert.match(t, /<span v-if="statusText" class="sr-only">/)
    assert.match(t, /<CardClipControl \/>/)
    /* a boolean prop would read false when omitted and every channel would
       grow an "offline" dot */
    assert.match(read('src/components/FeedHeader.vue'), /status\?: 'on' \| 'off'/)
  })

  it('one row at every width: the title ellipses instead of wrapping the control', () => {
    const css = read('src/assets/css/main.css')
    assert.match(css, /\.feed-header--pane \.feed-header__title \{[^}]*text-overflow: ellipsis;[^}]*white-space: nowrap;/)
    assert.doesNotMatch(css, /\.feed-header:has\(\.card-clip-ctl\) \{ flex-wrap: wrap/)
    assert.doesNotMatch(css, /\.feed-header__about/)
  })
})

describe('CardClipControl: three icons with tooltips', () => {
  const src = read('src/components/CardClipControl.vue')

  it('each segment is an icon; its words are the tooltip and the accessible name', () => {
    assert.match(src, /:title="t\('feed\.clip\.mode\.' \+ m\)"/)
    assert.match(src, /<UiIcon :name="ICON\[m\]" size="1em" \/>/)
    assert.match(src, /\{ titles: 'clip-titles', rows: 'clip-rows', full: 'clip-full' \}/)
    assert.match(src, /<span class="sr-only">\{\{ t\('feed\.clip\.mode\.' \+ m\) \}\}<\/span>/)
  })

  it('keeps the radio group, testids and the mode the proofs and useCardClip read', () => {
    assert.match(src, /role="radiogroup"/)
    assert.match(src, /data-testid="card-clip-control"/)
    assert.match(src, /:data-mode="mode"/)
    assert.match(src, /:data-testid="`card-clip-\$\{m\}`"/)
    assert.match(src, /@change="setMode\(m\)"/)
  })

  it('the icons exist', () => {
    const icons = read('src/utils/uiIcons.ts')
    for (const m of ['titles', 'rows', 'full']) assert.match(icons, new RegExp(`"clip-${m}": \\[`))
  })
})

describe('i18n: the "last 30 · tenant-scoped" note is gone from every locale', () => {
  it('no pages.channel.subtitle / subtitle_retention', () => {
    const files = readdirSync(join(WUI, 'i18n/locales')).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const pages = JSON.parse(read(`i18n/locales/${f}`)).pages
      assert.equal(pages.channel, undefined, f)
    }
  })
})

/* Owner 2026-09-26 (prd topic b8cbfbe1): the thread pane's header is one row -
   the X first, then the title on one line with an ellipsis (full title on
   hover), then the replies' height control (SPL-945). */
describe('the thread pane header: X, then the title on one line, then the control', () => {
  for (const p of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
    it(p, () => {
      const t = template(p)
      const head = t.slice(t.indexOf('<header>'), t.indexOf('</header>'))
      const x = head.indexOf('<UiIcon name="x"')
      const title = head.indexOf('class="topic-heading__title"')
      const ctl = head.indexOf('<LazyCardClipControl pane="thread" />')
      assert.ok(x > 0 && title > x && ctl > title, `order X ${x} < title ${title} < control ${ctl}`)
      assert.match(head, /class="topic-heading__title"[^>]*:title="heading"/)
      assert.doesNotMatch(head, /flex-wrap:wrap/)
    })
  }

  it('the title never wraps: nowrap + ellipsis, and the header row does not wrap', () => {
    const css = read('src/assets/css/main.css')
    assert.match(css, /\.topic header \{[^}]*flex-wrap: nowrap;/)
    assert.match(css, /\.topic-heading__title \{[^}]*overflow: hidden;[^}]*text-overflow: ellipsis;[^}]*white-space: nowrap;/)
    assert.doesNotMatch(css, /\.topic-heading__title \{[^}]*overflow-wrap: anywhere/)
  })
})
