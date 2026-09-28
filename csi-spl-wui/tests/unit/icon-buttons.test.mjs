// Close / Open controls are icon buttons (UiIcon x / open), with the
// catalogue label on aria-label + title. No new i18n keys.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('icon buttons (Close = x, Open = square-arrow-out-up-right)', () => {
  it('uiIcons.ts has the x and open glyphs as path-only lucide strokes', () => {
    const src = read('src/utils/uiIcons.ts')
    assert.match(src, /\bx:\s*\[/)
    assert.match(src, /\bopen:\s*\[/)
    assert.match(src, /M21 3 3 21/)
    assert.match(src, /M15 3h6v6/)
    assert.match(src, /M21 13v6a2 2 0 0 1-2 2H5/)
  })

  it('icon-btn is compact >= 32x32 with hover and focus-visible', () => {
    const css = read('src/assets/css/main.css')
    assert.match(css, /\.icon-btn\s*\{/)
    assert.match(css, /min-width:\s*32px/)
    assert.match(css, /min-height:\s*32px/)
    assert.match(css, /\.icon-btn:hover\s*\{/)
    assert.match(css, /\.icon-btn:focus-visible\s*\{/)
    assert.match(css, /outline:\s*2px solid var\(--color-accent\)/)
  })

  it('topic panes and message cards keep i18n names on aria-label + title, not as visible text', () => {
    const live = read('src/components/LiveTopicPane.vue')
    const topic = read('src/components/TopicPane.vue')
    const card = read('src/components/MessageCard.vue')
    const composer = read('src/components/MessageComposer.vue')
    /* SPL-1133: the panes' X is the shared UiCloseButton (Mac / Windows corner) */
    const close = read('src/components/UiCloseButton.vue')
    for (const [name, src] of [['LiveTopicPane', live], ['TopicPane', topic]]) {
      assert.match(src, /<UiCloseButton side="start" class="icon-btn topic-close"/, name)
      assert.match(src, /<UiCloseButton side="end" class="icon-btn topic-close"/, name)
    }

    for (const [name, src] of [
      ['UiCloseButton', close],
    ]) {
      assert.match(src, /:aria-label="label \|\| t\('common\.close'\)"/, name)
      assert.match(src, /:title="label \|\| t\('common\.close'\)"/, name)
      assert.match(src, /name="x"/, name)
      assert.equal(/\>\{\{\s*t\('common\.close'\)\s*\}\}</.test(src), false, name + ' visible Close')
    }

    /* Owner, 2026-09-25: the pane's Open button (to /t/<task_id>) "is obsolet
       ... remove the whole button". The pane is the topic; nothing opens it again. */
    assert.equal(live.includes('data-test="live-topic-open"'), false, 'the pane Open button is gone')
    assert.equal(/name="open"/.test(live), false, 'no open icon in the pane header')

    assert.match(card, /name="open"/)
    assert.match(card, /:aria-label="t\('feed\.open_topic'\)"/)
    assert.match(card, /:title="t\('feed\.open_topic'\)"/)
    assert.equal(/\>\{\{\s*t\('feed\.open_topic'\)\s*\}\}</.test(card), false, 'visible Open topic')

    assert.match(composer, /name="x"/)
    assert.match(composer, /composer\.remove_file/)
    assert.equal(composer.includes('>×</button>'), false, 'raw x on file chip')
  })

  it('reuses existing en catalogue keys (no new Close/Open strings)', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(en.common.close, 'Close')
    assert.equal(en.topic.open, 'Open')
    assert.equal(en.feed.open_topic, 'Open topic')
    assert.equal(typeof en.composer.remove_file, 'string')
  })
})

/* Owner, 2026-09-25: "the button should be displayed only on the middle pane
   and it should work so that it will open the topic ( aka the threads in the
   right most pane". */
describe('the Open button lives on middle-pane cards only', () => {
  it('LiveFeed shows it on every card when the host asks for it', () => {
    const feed = read('src/components/LiveFeed.vue')
    assert.match(feed, /openButton\?: boolean/)
    assert.match(feed, /function openable\(m: SpoolMessage\) \{\s*if \(props\.openButton\) return Boolean\(m\.task_id\)/)
  })
  it('the channel / DM feed and the lobby ask for it', () => {
    assert.match(read('src/components/MessageFeed.vue'), /<LiveFeed[\s\S]*?\bopen-button\b/)
    assert.match(read('src/pages/lobby.vue'), /<LiveFeed[\s\S]*?\bopen-button\b/)
  })
  it('no thread pane asks for it, and the pane header has none', () => {
    for (const rel of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue', 'src/pages/t/[task_id].vue']) {
      assert.equal(/\bopen-button\b/.test(read(rel)), false, rel)
    }
  })
  it('its click is the same open-topic the row and replies use', () => {
    assert.match(read('src/components/MessageCard.vue'), /data-test="open-topic"[\s\S]*?@click="\$emit\('open-topic', msg\)"/)
  })
})

