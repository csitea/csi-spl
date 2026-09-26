// SPL-942 — Tab inside a message card.
//
// The card (tabindex 0) is first. The replies link is the next stop, then
// the row menu. The emoji button is painted between them and is reached
// after the menu. A card with no replies link does not insert a stop.
// No positive tabindex.
//
// Run: node tests/unit/replies-tab.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')

function templateOf(src) {
  const a = src.indexOf('<template>')
  const b = src.indexOf('<script')
  return src.slice(a, b)
}

describe('replies tab stop (SPL-942)', () => {
  const tpl = templateOf(vue)
  const actions = tpl.slice(tpl.indexOf('class="msg-actions"'), tpl.indexOf('</span>', tpl.indexOf('class="msg-actions"')))

  it('DOM order inside the actions is replies, then menu, then emoji', () => {
    const replies = actions.indexOf('data-test="topic-replies"')
    const menu = actions.indexOf('data-testid="msg-menu-btn"')
    const emoji = actions.indexOf('data-testid="msg-emoji-btn"')
    assert.ok(replies > 0 && menu > replies && emoji > menu)
  })

  it('SPL-982: paints the emoji just after the time, then open, replies and the menu on the right', () => {
    assert.match(vue, /\.msg-actions \{ display: contents; \}/)
    assert.match(vue, /\.msg-actions \.icon-btn\[data-testid="msg-emoji-btn"\] \{ order: 1; margin-inline-start: -11px; \}/)
    assert.match(vue, /\.msg-meta-spacer \{ order: 2; flex: 1 1 0; min-width: 0; \}/)
    assert.match(vue, /\.msg-actions \.replies \{ order: 4;/)
    assert.match(vue, /\.msg-actions \.msg-menu-btn \{ order: 5; \}/)
  })

  it('omits the link unless the card has replies or is always a topic, and uses no positive tabindex', () => {
    assert.match(actions, /v-if="count > 0 \|\| alwaysTopic"/)
    assert.match(vue, /tabindex="0"/)
    assert.doesNotMatch(vue, /tabindex="[1-9]/)
    assert.match(vue, /function onKey\(ev: KeyboardEvent\)/)
    assert.match(vue, /wantsEdit\(ev/)
  })
})
