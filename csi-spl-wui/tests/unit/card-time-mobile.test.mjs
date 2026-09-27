// SPL-1000 (owner, 2026-09-27, topic e0b12a2c, "on mobile only"): a phone's
// card header drops the year of this year; another year keeps it; desktop
// prints the whole value.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dropThisYear, formatMsgListTs, formatTopicTs, phoneCardTime } from '../../src/utils/channel-feed.mjs'

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

// SPL-1007 (owner, 2026-09-27, topic 70c82b54): a message from today shows only its time
describe('phoneCardTime', () => {
  const now = Date.parse('2026-09-27T12:00:00Z')
  it('today (the list prints local time): HH:MM only', () => {
    const ts = new Date(now - 60 * 60 * 1000).toISOString()
    const text = formatMsgListTs(ts)
    assert.equal(phoneCardTime(text, ts, now), text.slice(11))
    assert.match(phoneCardTime(text, ts, now), /^\d{2}:\d{2}$/)
  })
  it('midnight: 23:59 yesterday keeps its date, 00:01 today does not', () => {
    const today = new Date(now)
    const y = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1, 23, 59)
    const t = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 0, 1)
    assert.match(phoneCardTime(formatMsgListTs(y.toISOString()), y.toISOString(), t.getTime() + 60000), /^\d{2}-\d{2} 23:59$/)
    assert.equal(phoneCardTime(formatMsgListTs(t.toISOString()), t.toISOString(), t.getTime() + 60000), '00:01')
  })
  it('another day this year: MM-DD HH:MM; another year keeps the year', () => {
    assert.equal(phoneCardTime('2026-03-01 13:43', '2026-03-01T10:43:00Z', now), '03-01 13:43')
    assert.equal(phoneCardTime('2025-12-31 23:59', '2025-12-31T21:59:00Z', now), '2025-12-31 23:59')
  })
  it('the topic pane clock (UTC) keeps its tail', () => {
    const ts = '2026-09-27T10:43:00Z'
    assert.equal(phoneCardTime(formatTopicTs(ts, Date.parse(ts) + 7000), ts, now), '10:43:00 sent 7s')
  })
  it('a value that is not a time passes through', () => {
    assert.equal(phoneCardTime('now', 'not-a-date', now), 'now')
    assert.equal(phoneCardTime('', null, now), '')
  })
})

describe('MessageCard wires it on phones only', () => {
  const card = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
  it('the time is shortened only while useMobileStack().isMobile, and the hover keeps the whole value', () => {
    assert.match(card, /const mobile = useMobileStack\(\)\.isMobile/)
    assert.match(card, /mobile\.value \? phoneCardTime\(fullTime\.value, at\.value\) : fullTime\.value/)
    assert.match(card, /:title="timeTitle"/)
  })
  it('the phone block no longer hides Add emoji', () => {
    const phone = card.slice(card.indexOf('@media (max-width: 820px)'))
    assert.doesNotMatch(phone, /msg-emoji-btn"\],\s*\n\s*\.msg-actions \[data-test="open-topic"\] \{ display: none; \}/)
    assert.match(phone, /\.msg-actions \.icon-btn\[data-testid="msg-emoji-btn"\] \{[^}]*width: var\(--tap\)/)
  })
})
