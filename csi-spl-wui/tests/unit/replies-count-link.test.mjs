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

describe('SPL-982 the reactions sit in the header, 3px after the Add-emoji icon', () => {
  it('the chips are inside .msg-meta, after the actions, and no longer below the body', () => {
    const meta = vue.slice(vue.indexOf('<div class="msg-meta">'), vue.indexOf('<span class="msg-meta-spacer"'))
    assert.match(meta, /class="msg-reactions" data-testid="msg-reactions"/)
    assert.ok(meta.indexOf('data-testid="msg-reactions"') > meta.indexOf('data-testid="msg-emoji-btn"'))
    /* one strip per card: the desktop strip, or (SPL-1007) the phone one inside Add emoji */
    assert.equal(vue.split('data-testid="msg-reactions"').length - 1, 2)
    assert.match(vue, /v-if="chips\.length && !titleOnly && !mobile" class="msg-reactions" data-testid="msg-reactions"/)
    assert.match(vue, /v-if="phoneChips" class="msg-reactions msg-reactions--phone" data-testid="msg-reactions"/)
  })
  it('paints emoji, chips, (edited), spacer, then the right-hand controls', () => {
    assert.match(vue, /\.msg-meta > \.msg-reactions \{ order: 1; margin-inline-start: -13px; flex: 0 1 auto; align-self: center; \}/)
    // one header line (a narrow pane keeps the chips beside the emoji); SPL-991: on a
    // phone the names ellipsize and only the chips take their own wrapping row
    assert.match(vue, /\.msg-meta \{ align-items: center; flex-wrap: nowrap; \}/)
    assert.match(vue, /@media \(max-width: 820px\) \{[\s\S]*?\.msg-meta \{ flex-wrap: wrap;/)
    assert.match(vue, /\.msg-meta > \.msg-reactions \{ order: 10; flex: 1 0 100%; margin-inline-start: 0; \}/)
    assert.match(vue, /\.msg-meta > \.msg-edited \{ order: 2; \}/)
    assert.match(vue, /\.msg-reactions \{\s*display: inline-flex;\s*flex-wrap: wrap;/)
  })
  it('a chip shows its count from 2 people on, and its tooltip names who reacted', () => {
    assert.match(vue, /<span v-if="chip\.showCount" class="msg-reaction__n">\{\{ chip\.count \}\}<\/span>/)
    assert.match(vue, /:title="chipWho\(chip\.actors\)"/)
  })
})
