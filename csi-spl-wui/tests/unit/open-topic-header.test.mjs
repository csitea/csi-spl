// SPL-948 — the Open button sits in the card header, painted immediately
// left of the replies link. It stays out of the titles card (the same gate
// as before). Tab order is unchanged: the replies link is still the first
// stop, because the Open button comes after the emoji in the DOM and only
// paints first (the same CSS-order trick the emoji button already uses).
//
// Run: node tests/unit/open-topic-header.test.mjs
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

describe('open topic is left of replies (SPL-948)', () => {
  const tpl = templateOf(vue)
  const actionsAt = tpl.indexOf('class="msg-actions"')
  const actions = tpl.slice(actionsAt, tpl.indexOf('</span>', actionsAt))
  const outside = tpl.slice(0, actionsAt) + tpl.slice(tpl.indexOf('</span>', actionsAt))

  it('header paint order is open-topic, then topic-replies', () => {
    const open = actions.indexOf('data-test="open-topic"')
    const replies = actions.indexOf('data-test="topic-replies"')
    assert.ok(open > 0 && replies > 0, 'both controls live in the header actions')
    // SPL-982: order is now across the whole meta row (actions are display: contents)
    assert.match(vue, /\.msg-actions \[data-test="open-topic"\] \{ order: 3; \}/)
    assert.match(vue, /\.msg-actions \.replies \{ order: 4;/)
  })

  it('has no open-topic outside the header', () => {
    assert.equal(outside.includes('data-test="open-topic"'), false)
    assert.equal(tpl.split('data-test="open-topic"').length - 1, 1)
  })

  it('keeps the gate, the open-topic emit, and the existing name', () => {
    assert.match(actions, /v-if="topicLink && !titleOnly"/)
    assert.match(actions, /@click="\$emit\('open-topic', msg\)"/)
    assert.match(actions, /:aria-label="t\('feed\.open_topic'\)"/)
    assert.match(actions, /:title="t\('feed\.open_topic'\)"/)
    assert.match(actions, /class="icon-btn icon-btn--accent"/)
  })

  it('stays after the menu in the DOM, so the replies link is still the first stop', () => {
    const replies = actions.indexOf('data-test="topic-replies"')
    const menu = actions.indexOf('data-testid="msg-menu-btn"')
    const open = actions.indexOf('data-test="open-topic"')
    assert.ok(replies > 0 && replies < menu && menu < open)
  })
})
