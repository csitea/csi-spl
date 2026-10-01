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
  it('keeps the accessible name "n replies - Open topic" on aria-label and title, and announces unread', () => {
    assert.match(btn, /:aria-label="repliesName"/)
    assert.match(btn, /:title="repliesName"/)
    assert.match(vue, /t\('feed\.replies', \{ n: props\.count \?\? 0 \}, props\.count \?\? 0\)/)
    assert.match(vue, /t\('feed\.open_topic'\)/)
    /* CLE-77804: the unread part is announced when present */
    assert.match(vue, /unreadCount\.value > 0 \? `\$\{t\('feed\.replies_unread', \{ n: unreadCount\.value \}\)\}/)
  })
  it('the whole control (number and >>) opens the thread', () => {
    assert.match(btn, /@click\.stop="openReplies"/)
  })
})

describe('CLE-77804 (topic 35053f95) the counter shows "<unread>/<total> >>", unread bold', () => {
  it('renders a bold unread count before the total, only when there is unread', () => {
    /* "2/7 >>": the unread number is a <strong>, then a slash only when > 0, then the total */
    assert.match(btn, /<strong v-if="unreadCount > 0" class="replies__new" data-test="topic-unread">\{\{ unreadCount \}\}<\/strong>/)
    assert.match(btn, /\{\{ unreadCount > 0 \? '\/' : '' \}\}\{\{ count \}\} &gt;&gt;/)
  })
  it('never shows "0/…": the unread part is capped at the total and hidden at 0', () => {
    assert.match(vue, /const unreadCount = computed\(\(\) => Math\.max\(0, Math\.min\(count\.value, Number\(props\.unread\) \|\| 0\)\)\)/)
  })
})

describe('SPL-982 the reactions sit in the header, 3px after the Add-emoji icon', () => {
  it('the chips are inside .msg-meta, after the actions, and no longer below the body', () => {
    const meta = vue.slice(vue.indexOf('<div class="msg-meta">'), vue.indexOf('<span class="msg-meta-spacer"'))
    assert.match(meta, /class="msg-reactions" data-testid="msg-reactions"/)
    assert.ok(meta.indexOf('data-testid="msg-reactions"') > meta.indexOf('data-testid="msg-emoji-btn"'))
    /* one strip per card: the desktop strip, or (SPL-1007) the phone one inside Add emoji */
    assert.equal(vue.split('data-testid="msg-reactions"').length - 1, 2)
    assert.match(vue, /v-if="chips\.length && !mobile" class="msg-reactions" data-testid="msg-reactions"/)
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
  it('a chip shows its count from 2 people on, and its tooltip names the emoji then who reacted', () => {
    assert.match(vue, /<span v-if="chip\.showCount" class="msg-reaction__n">\{\{ chip\.count \}\}<\/span>/)
    /* da0c0e98: the title now leads with what the emoji represents ("Fire · Ann") */
    assert.match(vue, /:title="chipTitle\(chip\)"/)
    assert.match(vue, /function chipTitle/)
    assert.match(vue, /const name = emojiLabel\(chip\.emoji\)/)
  })
})
