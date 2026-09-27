// SPL-1000 (owner, 2026-09-27, topic e0b12a2c, "on mobile only"): a phone's
// card header drops the year of this year; another year keeps it; desktop
// prints the whole value.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatMsgListTs, phoneCardTime } from '../../src/utils/channel-feed.mjs'

// SPL-1007 (owner, 2026-09-27, topic 70c82b54): a message from today shows only its time.
// CLE-35065 (owner, prd t1 topic 95adf832): "today" is the viewer's LOCAL day on every phone surface.
describe('phoneCardTime', () => {
  /* the viewer's zone: Node re-reads process.env.TZ on assignment */
  const tz0 = process.env.TZ
  const inZone = (zone, fn) => () => { process.env.TZ = zone; try { fn() } finally { if (tz0 === undefined) delete process.env.TZ; else process.env.TZ = tz0 } }
  const HEL = 'Europe/Helsinki' /* UTC+3 in summer */
  const BOG = 'America/Bogota' /* UTC-5, no DST */
  const at = (iso) => Date.parse(iso)
  it('a list line from today (the reader\'s local clock): HH:MM only', () => {
    const now = at('2026-09-27T12:00:00Z')
    const ts = new Date(now - 60 * 60 * 1000).toISOString()
    assert.match(phoneCardTime(formatMsgListTs(ts), ts, now), /^\d{2}:\d{2}$/)
  })
  it('UTC+3 after local midnight: 00:10 today is HH:MM although UTC still reads yesterday', inZone(HEL, () => {
    const now = at('2026-09-27T21:35:00Z') /* 00:35 on 09-28 in Helsinki */
    assert.equal(phoneCardTime('2026-09-28 00:10', '2026-09-27T21:10:00Z', now), '00:10')
    /* the topic pane prints UTC: the phone still shows the reader's own clock, only the hours */
    assert.equal(phoneCardTime('2026-09-27 21:10:00 sent 25m', '2026-09-27T21:10:00Z', now), '00:10')
  }))
  it('UTC+3 midnight: 23:59 yesterday keeps its date, 00:00 today does not', inZone(HEL, () => {
    const now = at('2026-09-27T21:01:00Z') /* 00:01 local */
    assert.equal(phoneCardTime('2026-09-27 23:59', '2026-09-27T20:59:00Z', now), '09-27 23:59')
    assert.equal(phoneCardTime('2026-09-28 00:00', '2026-09-27T21:00:00Z', now), '00:00')
  }))
  it('UTC-5 before local midnight: 23:30 today is HH:MM although UTC already reads tomorrow', inZone(BOG, () => {
    const now = at('2026-09-28T04:45:00Z') /* 23:45 on 09-27 in Bogota */
    assert.equal(phoneCardTime('2026-09-28 04:30:00 sent 15m', '2026-09-28T04:30:00Z', now), '23:30')
    assert.equal(phoneCardTime('2026-09-26 23:59', '2026-09-27T04:59:00Z', now), '09-26 23:59')
    assert.equal(phoneCardTime('2026-09-27 00:00', '2026-09-27T05:00:00Z', now), '00:00')
  }))
  it('a DST change day (Helsinki 2026-10-25, 04:00 -> 03:00): both 03:30s are today, the night before is not', inZone(HEL, () => {
    const now = at('2026-10-25T10:00:00Z') /* 12:00 local, UTC+2 */
    assert.equal(phoneCardTime('2026-10-25 03:30', '2026-10-25T00:30:00Z', now), '03:30') /* EEST */
    assert.equal(phoneCardTime('2026-10-25 03:30', '2026-10-25T01:30:00Z', now), '03:30') /* EET */
    assert.equal(phoneCardTime('2026-10-24 23:59', '2026-10-24T20:59:00Z', now), '10-24 23:59')
    assert.equal(phoneCardTime('2026-10-25 00:00', '2026-10-24T21:00:00Z', now), '00:00')
  }))
  it('another day this year: MM-DD HH:MM; another year keeps the year (local clock)', inZone(HEL, () => {
    const now = at('2026-09-27T12:00:00Z')
    assert.equal(phoneCardTime('2026-03-01 12:43', '2026-03-01T10:43:00Z', now), '03-01 12:43')
    assert.equal(phoneCardTime('2025-12-31 23:59', '2025-12-31T21:59:00Z', now), '2025-12-31 23:59')
    /* 2026-01-01 00:30 in Helsinki is 2025 in UTC: the year is the reader's */
    assert.equal(phoneCardTime('2025-12-31 22:30:00 sent 1m', '2025-12-31T22:30:00Z', now), '01-01 00:30')
  }))
  it('a value that is not a time passes through', () => {
    const now = at('2026-09-27T12:00:00Z')
    assert.equal(phoneCardTime('now', 'not-a-date', now), 'now')
    assert.equal(phoneCardTime('', null, now), '')
    assert.equal(phoneCardTime('now', '2026-09-27T10:00:00Z', now), 'now')
  })
})

describe('MessageCard wires it on phones only', () => {
  const card = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
  it('the time is shortened only while useMobileStack().isMobile, and the hover keeps the whole value', () => {
    assert.match(card, /const mobile = useMobileStack\(\)\.isMobile/)
    assert.match(card, /mobile\.value \? phoneCardTime\(fullTime\.value, at\.value\) : fullTime\.value/)
    assert.match(card, /:title="timeTitle"/)
  })
  it('the home topic rows use it on phones too (CLE-35065); desktop keeps formatTs', () => {
    const home = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/pages/index.vue'), 'utf8')
    assert.match(home, /<span class="msg-time">\{\{ rowTime\(t\.last_ts\) \}\}<\/span>/)
    assert.match(home, /mobile\.value \? phoneCardTime\(formatMsgListTs\(ts\), ts\) : formatTs\(ts, locale\.value\)/)
  })
  it('phones: card text <= 6 px from either edge, under the avatar too (CLE-35065)', () => {
    const css = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/assets/css/main.css'), 'utf8')
    const phoneCss = css.slice(css.indexOf('@media (max-width: 820px) {'))
    assert.match(phoneCss, /\n  \.feed-body, \.feed-body\.pinned-root \{ padding-inline: 2px; \}/)
    assert.match(css, /\.feed-body \{[^}]*padding: 16px 20px 8px;/, 'desktop keeps its inset')
    const phone = card.slice(card.indexOf('@media (max-width: 820px)'))
    assert.match(phone, /\n  \.msg \{[^}]*padding: 8px 4px;/)
    assert.match(phone, /\.msg-main \{ display: contents; \}/)
    assert.match(phone, /\.msg-main > \* \{ grid-column: 1 \/ -1; min-width: 0; \}/)
    assert.match(phone, /\.msg-main > \.msg-meta \{ grid-column: 2; \}/)
    assert.match(card, /<div class="msg-main">/)
  })
  it('the phone block no longer hides Add emoji', () => {
    const phone = card.slice(card.indexOf('@media (max-width: 820px)'))
    assert.doesNotMatch(phone, /msg-emoji-btn"\],\s*\n\s*\.msg-actions \[data-test="open-topic"\] \{ display: none; \}/)
    assert.match(phone, /\.msg-actions \.icon-btn\[data-testid="msg-emoji-btn"\] \{[^}]*width: var\(--tap\)/)
  })
})
