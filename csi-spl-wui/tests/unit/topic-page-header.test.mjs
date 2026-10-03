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
})
