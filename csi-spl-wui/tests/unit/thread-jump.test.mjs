// Phone thread: a round arrow jumps to the newest end, and the reverse
// jumps to the oldest end once the reader is already there. "Bottom" is the
// newest end, so newest-last (append) and newest-first (prepend) point
// opposite ways. Desktop and a short thread show nothing.
// Run: node --test tests/unit/thread-jump.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { NEAR_BOTTOM_PX, NEAR_TOP_PX } from '../../src/utils/scroll-anchor.mjs'
import { threadJumpState } from '../../src/utils/thread-jump.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

const none = { show: '', dir: '', top: 0 }

describe('threadJumpState', () => {
  it('a thread that fits, or one not laid out yet, shows no arrow', () => {
    assert.deepEqual(threadJumpState({ scrollTop: 0, scrollHeight: 400, clientHeight: 400, newestLast: false }), none)
    assert.deepEqual(threadJumpState({ scrollTop: 0, scrollHeight: 580, clientHeight: 500, newestLast: true }), none)
    assert.deepEqual(threadJumpState({ scrollTop: 0, scrollHeight: 2000, clientHeight: 0, newestLast: false }), none)
  })

  it('newest first: at the newest end (the top) the arrow jumps to the oldest end', () => {
    assert.equal(NEAR_TOP_PX, 80)
    const at = threadJumpState({ scrollTop: 0, scrollHeight: 2000, clientHeight: 500, newestLast: false })
    assert.deepEqual(at, { show: 'oldest', dir: 'down', top: 2000 })
    const near = threadJumpState({ scrollTop: 80, scrollHeight: 2000, clientHeight: 500, newestLast: false })
    assert.deepEqual(near, { show: 'oldest', dir: 'down', top: 2000 })
  })

  it('newest first: scrolled away from the newest end, the arrow jumps back up to it', () => {
    const away = threadJumpState({ scrollTop: 81, scrollHeight: 2000, clientHeight: 500, newestLast: false })
    assert.deepEqual(away, { show: 'newest', dir: 'up', top: 0 })
    const mid = threadJumpState({ scrollTop: 900, scrollHeight: 2000, clientHeight: 500, newestLast: false })
    assert.deepEqual(mid, { show: 'newest', dir: 'up', top: 0 })
  })

  it('newest last: at the newest end (the bottom) the arrow jumps to the oldest end', () => {
    assert.equal(NEAR_BOTTOM_PX, 80)
    const at = threadJumpState({ scrollTop: 1500, scrollHeight: 2000, clientHeight: 500, newestLast: true })
    assert.deepEqual(at, { show: 'oldest', dir: 'up', top: 0 })
    const near = threadJumpState({ scrollTop: 1420, scrollHeight: 2000, clientHeight: 500, newestLast: true })
    assert.deepEqual(near, { show: 'oldest', dir: 'up', top: 0 })
  })

  it('newest last: scrolled up from the newest end, the arrow jumps down to it', () => {
    const away = threadJumpState({ scrollTop: 1419, scrollHeight: 2000, clientHeight: 500, newestLast: true })
    assert.deepEqual(away, { show: 'newest', dir: 'down', top: 2000 })
    const top = threadJumpState({ scrollTop: 0, scrollHeight: 2000, clientHeight: 500, newestLast: true })
    assert.deepEqual(top, { show: 'newest', dir: 'down', top: 2000 })
  })
})

describe('the phone thread paints the arrow and nothing else does', () => {
  const feed = read('src/components/LiveFeed.vue')

  it('the button is a phone thread only, and a tap scrolls that pane smoothly', () => {
    assert.match(feed, /v-if="phone && props\.holdScroll && jumpEnds\.show"/)
    assert.match(feed, /data-testid="thread-jump"/)
    assert.match(feed, /:data-end="jumpEnds\.show"/)
    assert.match(feed, /:data-dir="jumpEnds\.dir"/)
    assert.match(feed, /t\(jumpEnds\.show === 'newest' \? 'feed\.new_pill_label' : 'feed\.jump_oldest'\)/)
    assert.match(feed, /scrollTo\(\{ top: st\.top, behavior: reduce \? 'auto' : 'smooth' \}\)/)
    assert.match(feed, /prefers-reduced-motion: reduce/)
    assert.doesNotMatch(feed, /IntersectionObserver/)
  })

  it('the round button is drawn only at the phone width', () => {
    const style = feed.slice(feed.indexOf('<style'))
    const at = style.indexOf('@media (max-width: 820px)')
    assert.ok(at > 0)
    assert.doesNotMatch(style.slice(0, at), /\.thread-jump/)
    const media = style.slice(at)
    assert.match(media, /\.thread-jump \{[^}]*border-radius:\s*50%/)
    assert.match(media, /\.thread-jump \{[^}]*position:\s*fixed/)
  })

  it('the three thread panes still do not scroll themselves', () => {
    for (const rel of [
      'src/components/LiveTopicPane.vue',
      'src/components/TopicPane.vue',
      'src/pages/t/[task_id].vue',
    ]) {
      const src = read(rel)
      assert.match(src, /hold-scroll/, rel)
      assert.doesNotMatch(src, /thread-jump/, rel)
      assert.doesNotMatch(src, /scrollTop\s*=/, rel)
    }
  })

  it('the oldest-end label is in the catalogue', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(en.feed.jump_oldest, 'Jump to the oldest messages')
    assert.equal(en.feed.new_pill_label, 'Jump to the newest messages')
  })
})
