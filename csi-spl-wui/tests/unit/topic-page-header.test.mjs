// The topic page (/t/:id) is the thread alone (TopicPane), beside the
// shell's left panel: its Topics list went with the Topics view (owner
// HUM-10, t1 e4bfddb1, msg a78e06c8). The title is the topic text, never the
// raw id.
// Run: node --test tests/unit/topic-page-header.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { rowTitle } from '../../src/utils/view-api.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const page = read('src/pages/t/[task_id].vue')
const template = page.slice(page.indexOf('<template>'), page.lastIndexOf('</template>'))
const css = read('src/assets/css/main.css')

describe('the topic page is the thread alone', () => {
  it('no Topics list of its own: no rows, no list heading', () => {
    assert.doesNotMatch(template, /data-test="topic-browse-list"/)
    assert.doesNotMatch(template, /v-for=/)
    assert.doesNotMatch(template, /nav\.topics|pages\.index/)
    assert.doesNotMatch(page, /viewer\.topics|loadTopics/)
    /* the shared row title helper still strips markdown for every other list */
    assert.equal(rowTitle('Welcome to **#lobby**.'), 'Welcome to #lobby.')
    assert.equal(rowTitle('**ROTATION FAILED**'), 'ROTATION FAILED')
    assert.equal(rowTitle('**bold**'), 'bold')
  })

  it('the thread is TopicPane, never the raw id', () => {
    assert.match(template, /data-test="topic-browse"/)
    assert.match(template, /data-test="topic-browse-thread"/)
    assert.match(template, /<TopicPane\s*\/>/)
    assert.doesNotMatch(template, /shortId/)
    assert.doesNotMatch(template, /<code/)
    assert.doesNotMatch(template, /<LiveFeed/)
    assert.doesNotMatch(page, /topic\.list_title/)
  })

  it('the thread fills the page and stays in its column', () => {
    assert.match(css, /\.topic-browse \{[^}]*display: flex;/)
    assert.doesNotMatch(css, /\.topic-browse__list/)
    assert.match(css, /\.topic-browse__thread > \.topic \{[^}]*width: auto;/)
    assert.match(css, /\.topic-browse__thread > \.topic \{[^}]*position: relative;/)
    assert.match(css, /\.topic-browse__thread > \.topic \{[^}]*top: auto;/)
  })

  it('a phone shows the thread; its X leaves for the front door', () => {
    assert.doesNotMatch(page, /phoneThread/)
    assert.match(template, /:data-phone="stack\.isMobile\.value \? 'thread' : undefined"/)
    assert.doesNotMatch(css, /data-phone="list"/)
    assert.match(page, /stack\.rightPanel\(/)
    assert.match(page, /if \(was && !open && taskId\.value\) void navigateTo\(localePath\('\/'\), \{ replace: true \}\)/)
  })

  it('a thread title has no Topic: prefix and a four-side border at every width', () => {
    assert.doesNotMatch(page, /topic\.list_title/)
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(en.topic.list_title, 'Topic: {text}')
    for (const rel of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
      const s = read(rel)
      assert.match(s, /class="topic-heading__label"/)
      assert.match(s, /t\('topic\.list_title', \{ text: '' \}\)/)
      assert.match(s, /class="topic-heading__text"/)
      assert.match(s, /t\('topic\.list_title', \{ text: titleText\.value \}\)/)
    }
    assert.match(css, /^\.topic-heading__label \{ display: none; \}\n\.topic-heading__title \{\n  background: transparent;\n  box-shadow: none;\n  border: 1px solid var\(--color-border\);\n\}/m)
    assert.doesNotMatch(css, /@media \(max-width: 820px\) \{\n  \.topic-heading__label/)
    assert.doesNotMatch(css, /\.topic-heading__title,\n\.search-row\.active/)
    assert.match(css, /\.topic\.selected,\n\.search-row\.active \{\n  background: var\(--color-selected\);\n  box-shadow: inset var\(--select-bar-w\) 0 0 var\(--focus-ring\);\n\}/)
  })

  it('every topic header strips markdown from the title through rowTitle (SPL-1683)', () => {
    const topicPane = read('src/components/TopicPane.vue')
    assert.match(topicPane, /rowTitle\(subject, ''\)/)
    const livePane = read('src/components/LiveTopicPane.vue')
    assert.match(livePane, /rowTitle\(topicTitleFromRows\(pane\.messages, /)
    const dmPage = read('src/pages/dm/[peer].vue')
    assert.match(dmPage, /rowTitle\(topicTitleFromRows\(data\.messages \|\| \[\], topic\.rootMsg\), ''\)/)
  })

  it('rowTitle with no gist strips each inline mark (e.g., **bold** -> bold)', () => {
    assert.equal(rowTitle('**bold**', ''), 'bold')
    assert.equal(rowTitle('__bold__', ''), 'bold')
    assert.equal(rowTitle('*italic*', ''), 'italic')
    assert.equal(rowTitle('~~strike~~', ''), 'strike')
    assert.equal(rowTitle('`code`', ''), 'code')
    assert.equal(rowTitle('[link](url)', ''), 'link')
    assert.equal(rowTitle('**ROTATION FAILED**', ''), 'ROTATION FAILED')
  })
})
