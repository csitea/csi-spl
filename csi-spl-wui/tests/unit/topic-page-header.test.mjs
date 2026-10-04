// The topic view (/t/:id) is two panels: the list of topics and the
// thread (TopicPane) filling the rest of the width. The title is the
// topic text, never the raw id. A phone shows one panel at a time.
// Run: node --test tests/unit/topic-page-header.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const page = read('src/pages/t/[task_id].vue')
const template = page.slice(page.indexOf('<template>'), page.lastIndexOf('</template>'))
const css = read('src/assets/css/main.css')

describe('the topic view is two panels', () => {
  it('the list names topics and the thread is TopicPane, never the raw id', () => {
    assert.match(template, /data-test="topic-browse"/)
    assert.match(template, /data-test="topic-browse-list"/)
    assert.match(template, /data-test="topic-browse-thread"/)
    assert.match(template, /<TopicPane\s*\/>/)
    assert.match(template, /\{\{ t\('nav\.topics'\) \}\}/)
    assert.doesNotMatch(template, /shortId/)
    assert.doesNotMatch(template, /<code/)
    assert.doesNotMatch(template, /<LiveFeed/)
    assert.match(page, /topicOpening\(subject\)/)
    assert.doesNotMatch(page, /topic\.list_title/)
  })

  it('desktop is the list plus a thread, and the sidebar is not a column', () => {
    assert.match(css, /\.topic-browse \{[^}]*display: flex;/)
    assert.match(css, /\.topic-browse__list \{[^}]*flex: 0 0 340px;/)
    assert.match(css, /\.topic-browse__thread > \.topic \{[^}]*width: auto;/)
    assert.match(css, /\.topic-browse__thread > \.topic \{[^}]*position: relative;/)
    assert.match(css, /\.topic-browse__thread > \.topic \{[^}]*top: auto;/)
    const start = css.indexOf('/* /t/:id is two panels:')
    const block = css.slice(start, css.indexOf('.topic-browse {', start))
    const side = block.match(/\.spool-shell\[data-topic-browse="1"\] > \.sidebar \{[^}]*\}/)
    assert.ok(side, 'desktop topic-browse sidebar rule')
    assert.match(side[0], /visibility: hidden;/)
    assert.match(side[0], /width: var\(--sidebar-w\);/)
    assert.doesNotMatch(side[0], /display:\s*none/)
  })

  it('a phone shows the thread or the list, one at a time', () => {
    assert.match(page, /phoneThread/)
    assert.match(template, /data-phone/)
    assert.match(css, /\.topic-browse:not\(\[data-phone="list"\]\) > \.topic-browse__list \{ display: none; \}/)
    assert.match(css, /\.topic-browse\[data-phone="list"\] > \.topic-browse__thread \{ display: none; \}/)
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
})
