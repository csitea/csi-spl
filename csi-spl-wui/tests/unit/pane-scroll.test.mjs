// A click moves a row to the top of its own list. The document does not scroll.
// Run: node --test tests/unit/pane-scroll.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openThreadRow, scrollRowToTop } from '../../src/utils/pane-scroll.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

/**
 * Viewport geometry: scrolling the list moves the row, scrolling the document
 * moves both. The scroller's own top stays put (it is the pane, not the page).
 */
function scene({ scrollerTop, rowTop, scrollTop, docScroll }) {
  const doc = { scrollingElement: { scrollTop: docScroll } }
  const origin = { scrollTop, docScroll }
  const scroller = {
    _top: scrollTop,
    get scrollTop() { return this._top },
    set scrollTop(v) { this._top = v },
    getBoundingClientRect() { return { top: scrollerTop } },
  }
  const row = {
    getBoundingClientRect() {
      const moved = (scroller.scrollTop - origin.scrollTop) + (doc.scrollingElement.scrollTop - origin.docScroll)
      return { top: rowTop - moved }
    },
  }
  return { doc, scroller, row }
}

describe('scrollRowToTop', () => {
  it('the row top meets the scroller top, and the document scrollTop does not change', () => {
    const { doc, scroller, row } = scene({ scrollerTop: 200, rowTop: 640, scrollTop: 80, docScroll: 36 })
    scrollRowToTop(scroller, row)
    assert.equal(row.getBoundingClientRect().top, scroller.getBoundingClientRect().top)
    assert.equal(scroller.scrollTop, 80 + (640 - 200))
    assert.equal(doc.scrollingElement.scrollTop, 36)
  })

  it('a row already at the top does not move the list or the document', () => {
    const { doc, scroller, row } = scene({ scrollerTop: 148, rowTop: 148, scrollTop: 20, docScroll: 0 })
    scrollRowToTop(scroller, row)
    assert.equal(row.getBoundingClientRect().top, 148)
    assert.equal(scroller.scrollTop, 20)
    assert.equal(doc.scrollingElement.scrollTop, 0)
  })

  it('a row above the list top scrolls the list up, still not the document', () => {
    const { doc, scroller, row } = scene({ scrollerTop: 220, rowTop: 90, scrollTop: 400, docScroll: 12 })
    scrollRowToTop(scroller, row)
    assert.equal(row.getBoundingClientRect().top, scroller.getBoundingClientRect().top)
    assert.equal(scroller.scrollTop, 400 + (90 - 220))
    assert.equal(doc.scrollingElement.scrollTop, 12)
  })
})

describe('the four views do not call scrollIntoView', () => {
  it('ChannelSidebar, index, and search scroll the pane; MessageCard focus does not scroll', () => {
    for (const rel of [
      'src/components/ChannelSidebar.vue',
      'src/pages/index.vue',
      'src/pages/search.vue',
    ]) {
      const src = read(rel)
      assert.doesNotMatch(src, /scrollIntoView\s*\(/, rel)
      assert.match(src, /scrollRowToTop\(/, rel)
    }
    const card = read('src/components/MessageCard.vue')
    assert.doesNotMatch(card, /scrollIntoView\s*\(/)
    assert.match(card, /rowEl\.value\?\.focus\(\{\s*preventScroll:\s*true\s*\}\)/)
  })

  it('the feed list is the scroller and the shell under the bar does not scroll the document', () => {
    const css = read('src/assets/css/main.css')
    const layout = read('src/layouts/default.vue')
    const feed = css.slice(css.indexOf('.feed-body {'), css.indexOf('.feed-body {') + 500)
    assert.match(feed, /overflow-y:\s*auto/)
    assert.doesNotMatch(feed, /overflow-y:\s*visible/)
    assert.match(css, /\.new-pill-wrap\s*\{[^}]*top:\s*8px/)
    assert.match(layout, /overflow:\s*hidden/)
    assert.match(css, /\.spool-shell\s*\{[^}]*overflow:\s*clip/)
    assert.match(css, /\.sidebar-scroll\s*\{[^}]*overflow-y:\s*auto/)
    assert.match(feed, /overflow-anchor:\s*none/)
  })
})

describe('a thread is not scrolled', () => {
  it("a thread scroller's scrollTop is unchanged when a row in it is opened", () => {
    const scroller = { scrollTop: 240 }
    const row = { focus(opts) { this.opts = opts } }
    openThreadRow(row)
    assert.equal(scroller.scrollTop, 240)
    assert.deepEqual(row.opts, { preventScroll: true })
  })

  it('the thread panes do not assign scrollTop, and a replies click does not select Topics', () => {
    for (const rel of [
      'src/components/LiveTopicPane.vue',
      'src/components/TopicPane.vue',
      'src/pages/t/[task_id].vue',
    ]) {
      const src = read(rel)
      assert.match(src, /hold-scroll/, rel)
      assert.doesNotMatch(src, /scrollTop\s*=/, rel)
      assert.doesNotMatch(src, /scrollIntoView\s*\(/, rel)
      assert.doesNotMatch(src, /scrollRowToTop\s*\(/, rel)
    }
    const search = read('src/pages/search.vue')
    const focus = search.slice(search.indexOf('function focusMessage'), search.indexOf('useHead'))
    assert.match(focus, /openThreadRow\(/)
    assert.doesNotMatch(focus, /scrollTop/)
    const card = read('src/components/MessageCard.vue')
    assert.doesNotMatch(card, /reveal\('topics'\)/)
    assert.doesNotMatch(card, /useSidePane/)
    const anchor = read('src/composables/useScrollAnchor.ts')
    assert.match(anchor, /if \(!enabled\(\)\) return null/)
  })
})
