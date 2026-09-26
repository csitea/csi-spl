// SPL-982 (owner, prd t1 topic 8296eeec): "the is_parent=1 msgs in the
// channels - remove the <<n>> replies, replace it with <<n>> and the '>>' as
// link"; precision: exactly "3 >>", the literal ">>", no word "replies";
// addition: "the emoji ... some 5px after the time".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
const at = vue.indexOf('data-test="topic-replies"')
const btn = vue.slice(vue.lastIndexOf('<button', at), vue.indexOf('</button>', at))

describe('SPL-982 the replies link reads "n >>"', () => {
  it('shows the count and a literal >>, not the word', () => {
    assert.match(btn, /\{\{ count \}\} &gt;&gt;/)
    assert.doesNotMatch(btn, /feed\.replies'/)
    assert.doesNotMatch(btn, /»/)
  })
  it('keeps the accessible name "n replies - Open topic" on aria-label and title', () => {
    assert.match(btn, /:aria-label="repliesName"/)
    assert.match(btn, /:title="repliesName"/)
    assert.match(vue, /const repliesName = computed\(\(\) => `\$\{t\('feed\.replies', \{ n: props\.count \?\? 0 \}, props\.count \?\? 0\)\} - \$\{t\('feed\.open_topic'\)\}`\)/)
  })
  it('the whole control (number and >>) opens the thread', () => {
    assert.match(btn, /@click\.stop="openReplies"/)
  })
})

describe('SPL-982 the emoji stays 5px after the time on an edited card', () => {
  it('the (edited) marker paints after the emoji and takes the push to the right', () => {
    assert.match(vue, /\.msg-meta > \.msg-edited \{ order: 2; margin-inline-end: auto; \}/)
    assert.match(vue, /\.msg-edited ~ \.msg-actions \.icon-btn\[data-testid="msg-emoji-btn"\] \{ margin-inline-end: 0; \}/)
    // order 2: after the emoji (1); before Open topic (also 2) because the marker is earlier in the DOM
  })
})
