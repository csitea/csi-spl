// t1 1d8e647d: on a phone the topic page header showed the topic id
// broken over two lines ("6e61f b91") and "Topics /", the id and the
// status stacked into a tall column. The header shows the topic title
// (ellipsis, one line, full text on hover) and never the raw id. The
// breadcrumb stays one row at 360-430 px.
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
const header = template.slice(template.indexOf('<header'), template.indexOf('</header>') + '</header>'.length)
const css = read('src/assets/css/main.css')

describe('the topic page header shows the title on one row', () => {
  it('the breadcrumb is Topics / the title, never the raw id', () => {
    assert.match(header, /class="topic-page-heading"/)
    assert.match(header, /class="topic-page-title"[^>]*:title="heading"/)
    assert.match(header, /\{\{ heading \}\}/)
    assert.doesNotMatch(header, /shortId/)
    assert.doesNotMatch(header, /<code/)
    assert.match(page, /topicTitleFromRows\(store\.messages/)
  })

  it('the title ellipsizes and the row does not wrap (360-430 px included)', () => {
    assert.match(css, /\.feed-header h2\.topic-page-heading \{[^}]*white-space: nowrap;[^}]*overflow-wrap: normal;/)
    assert.match(css, /\.topic-page-title \{[^}]*text-overflow: ellipsis;[^}]*white-space: nowrap;/)
    assert.match(css, /\.feed-header:has\(\.topic-page-heading\) \{[^}]*flex-wrap: nowrap;/)
    assert.match(css, /\.topic-page-status \{[^}]*white-space: nowrap;[^}]*text-overflow: ellipsis;/)
    assert.doesNotMatch(css, /\.feed-header h2\.topic-page-heading \{[^}]*overflow-wrap: anywhere/)
  })

  it('on a phone the title keeps the row and the card height moves into the overflow', () => {
    assert.match(header, /data-test="topic-page-more"/)
    assert.match(header, /t\('mobile\.more'\)/)
    assert.match(header, /data-test="topic-page-tools"/)
    assert.match(header, /<LazyCardClipControl pane="thread" \/>/)
    assert.match(header, /@pointerdown="titlePress\.down"/)
    assert.match(page, /createLongPress/)
    assert.match(css, /\.topic-page-tools \{ display: contents; \}/)
    assert.match(css, /\.topic-page-more \{ display: none; \}/)
    const phone = css.slice(css.indexOf('@media (max-width: 820px)'))
    assert.match(phone, /\.topic-page-crumb,[\s\S]*display: none;/)
    assert.match(phone, /> \.topic-page-status \{ display: none; \}/)
    assert.match(phone, /\.topic-page-title \{[\s\S]*flex: 1 1 auto;/)
    assert.match(phone, /\.topic-page-more \{[\s\S]*width: var\(--tap\);/)
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
