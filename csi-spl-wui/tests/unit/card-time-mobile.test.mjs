// SPL-1000 (owner, 2026-09-27, topic e0b12a2c, "on mobile only"): a phone's
// card header drops the year of this year; another year keeps it; desktop
// prints the whole value.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dropThisYear } from '../../src/utils/channel-feed.mjs'

const NOW = Date.parse('2026-09-27T10:00:00Z')

describe('dropThisYear', () => {
  it('this year: MM-DD HH:MM', () => {
    assert.equal(dropThisYear('2026-09-27 13:43', '2026-09-27T10:43:00Z', NOW), '09-27 13:43')
  })
  it('the topic pane clock keeps its tail', () => {
    assert.equal(dropThisYear('2026-09-27 10:43:00 sent 7s', '2026-09-27T10:43:00Z', NOW), '09-27 10:43:00 sent 7s')
  })
  it('another year keeps the year', () => {
    assert.equal(dropThisYear('2025-12-31 23:59', '2025-12-31T21:59:00Z', NOW), '2025-12-31 23:59')
  })
  it('a value that is not a time passes through', () => {
    assert.equal(dropThisYear('now', 'not-a-date', NOW), 'now')
    assert.equal(dropThisYear('', null, NOW), '')
  })
})

describe('MessageCard wires it on phones only', () => {
  const card = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
  it('the time is shortened only while useMobileStack().isMobile, and the hover keeps the whole value', () => {
    assert.match(card, /const mobile = useMobileStack\(\)\.isMobile/)
    assert.match(card, /mobile\.value \? dropThisYear\(fullTime\.value, at\.value\) : fullTime\.value/)
    assert.match(card, /:title="timeTitle"/)
  })
  it('the phone block no longer hides Add emoji', () => {
    const phone = card.slice(card.indexOf('@media (max-width: 820px)'))
    assert.doesNotMatch(phone, /msg-emoji-btn"\],\s*\n\s*\.msg-actions \[data-test="open-topic"\] \{ display: none; \}/)
    assert.match(phone, /\.msg-actions \.icon-btn\[data-testid="msg-emoji-btn"\] \{[^}]*width: var\(--tap\)/)
  })
})
