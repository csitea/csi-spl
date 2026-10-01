// SPL-963 (owner 2026-09-26): "clicking on the titles, 5 rows and full does
// not work for all of the listings - fix it". Every list that shows messages
// takes a pane's titles / 5 rows / full mode (utils/card-clip.mjs), and each
// has a control that sets it. One test per list.
//   middle pane (msgs):   lobby, channel, DM, search results
//   right pane (thread):  thread pane (root card too), /t page, BornTopics,
//                         issue discussion
// Run: node --test tests/unit/list-clip-modes.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CARD_CLIP_MODES, listClipClass } from '../../src/utils/card-clip.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const template = (p) => {
  const s = read(p)
  return s.slice(s.indexOf('<template>'), s.lastIndexOf('</template>'))
}
const script = (p) => {
  const s = read(p)
  return s.slice(s.indexOf('<script'), s.indexOf('</script>'))
}

describe('listClipClass: a non-card list line per mode', () => {
  it('one class per mode, an unknown mode is the 5 rows default', () => {
    assert.deepEqual(CARD_CLIP_MODES.map(listClipClass), ['list-clip--titles', 'list-clip--rows', 'list-clip--full'])
    assert.equal(listClipClass('bogus'), 'list-clip--rows')
    assert.equal(listClipClass(undefined), 'list-clip--rows')
  })
})

describe('middle pane lists (the msgs mode, FeedHeader control)', () => {
  it('the FeedHeader carries the middle pane control', () => {
    assert.match(template('src/components/FeedHeader.vue'), /<CardClipControl \/>/)
  })

  for (const [name, page] of [['lobby', 'src/pages/lobby.vue'], ['channel', 'src/pages/channel/[name].vue'], ['DM', 'src/pages/dm/[peer].vue']]) {
    it(`${name}: the header is FeedHeader and the feed clips with the middle mode`, () => {
      const t = template(page)
      assert.match(t, /<FeedHeader\b/)
      if (name === 'lobby') {
        assert.match(t, /<LiveFeed[\s\S]*?\n\s+clip\n[\s\S]*?\/>/)
        assert.doesNotMatch(t, /clip-pane/)
      } else {
        assert.match(t, /<MessageFeed\b/)
        const feed = template('src/components/MessageFeed.vue')
        assert.match(feed, /<LiveFeed[\s\S]*?\n\s+clip\n[\s\S]*?\/>/)
        assert.doesNotMatch(feed, /clip-pane/)
      }
    })
  }

  it('search results (CLE-77884): a compact left-panel list - a fixed two-line snippet, no clip control', () => {
    assert.doesNotMatch(template('src/pages/search.vue'), /CardClipControl/)
    const css = read('src/components/SideHitList.vue')
    assert.match(css, /\.side-hit__text \{[^}]*-webkit-line-clamp: 2;/)
  })
})

describe('right pane lists (the thread mode)', () => {
  for (const p of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
    it(`thread pane ${p}: the control, and the feed on the thread mode`, () => {
      const t = template(p)
      assert.match(t, /<LazyCardClipControl pane="thread" \/>/)
      assert.match(t, /<LiveFeed\s+clip\s+clip-pane="thread"/)
    })
  }

  it('thread root: LiveFeed gives every card the mode, the root card (is_parent 1) too', () => {
    const src = read('src/components/LiveFeed.vue')
    assert.match(src, /function clipModeFor\(\) \{\n\s+return props\.clip \? clipMode\.value : undefined\n\}/)
    assert.doesNotMatch(src, /is_parent|clipsInThread/)
  })

  it('/t page: its header has the thread control, its feed the thread mode', () => {
    const t = template('src/pages/t/[task_id].vue')
    assert.match(t, /<header class="feed-header">[\s\S]*?<LazyCardClipControl pane="thread" \/>[\s\S]*?<\/header>/)
    assert.match(t, /<LiveFeed\s+clip\s+clip-pane="thread"/)
  })

  it('BornTopics: the new-topic cards in the right pane take the thread mode', () => {
    assert.match(template('src/components/BornTopics.vue'), /<MessageCard[\s\S]*?:clip-mode="clipMode"[\s\S]*?\/>/)
    assert.match(script('src/components/BornTopics.vue'), /const \{ mode: clipMode \} = useCardClip\('thread'\)/)
  })

  it('issue discussion: the control by the heading; titles is one line, 5 rows is capped, full is whole', () => {
    const t = template('src/pages/issues.vue')
    assert.match(t, /<div class="issues-talk__h">\s*<h3>[\s\S]*?<LazyCardClipControl pane="thread" \/>\s*<\/div>/)
    // SPL-982: a comment is a MessageCard, which clips itself (titles / 5 rows / full)
    assert.match(t, /<MessageCard[\s\S]*?class="issues-comment"[\s\S]*?:clip-mode="clipMode"[\s\S]*?\/>/)
    assert.match(script('src/pages/issues.vue'), /const \{ mode: clipMode \} = useCardClip\('thread'\)/)
  })
})
