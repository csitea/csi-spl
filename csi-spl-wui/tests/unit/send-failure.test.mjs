// CLE-3433 — the owner wrote a message in a DM on 2026-09-21 and it vanished.
// CLE-3434 read the dev hub's own `messages` table: nothing from HUM-9 after
// 12:39:03Z. The row was never written, and the WUI said nothing. Three
// things had to line up, and all three did:
//
//   1. MessageComposer cleared `text` on the same tick it emitted `send`;
//   2. channel.sendLive rolled its optimistic row back on failure;
//   3. nothing awaited the emit's listener, so the rejection was an unhandled
//      promise rejection and was swallowed.
//
// So the human lost their text, saw no row, and saw no error. This pins the
// repair: keep the text, say what happened, offer a retry — and retry once
// automatically ONLY where a retry cannot double-post.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { failureToken, sendFailureKey, shouldAutoResend } from '../../src/utils/send-failure.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const closed = Object.assign(new Error('socket closed'), { token: 'closed' })
const timeout = Object.assign(new Error('send timed out'), { token: 'timeout' })

describe('classifying a failed send (CLE-3433)', () => {
  it('reads the token live-ws sets, and nothing else', () => {
    assert.equal(failureToken(closed), 'closed')
    assert.equal(failureToken(timeout), 'timeout')
    assert.equal(failureToken(new Error('plain')), '')
    assert.equal(failureToken({ token: 7 }), '')
    assert.equal(failureToken(null), '')
    assert.equal(failureToken('closed'), '')
  })

  it("auto-resends ONLY 'closed' — the case that provably did not land", () => {
    assert.equal(shouldAutoResend(closed), true)
    /* a timeout may still be being written hub-side; a second write against a
       hub that is already not answering in 10s is reported, not attempted */
    assert.equal(shouldAutoResend(timeout), false)
    assert.equal(shouldAutoResend(new Error('anything else')), false)
    assert.equal(shouldAutoResend(null), false)
  })

  it('every failure has a sentence, including the ones we did not name', () => {
    assert.equal(sendFailureKey(closed), 'composer.send_failed_closed')
    assert.equal(sendFailureKey(timeout), 'composer.send_failed_timeout')
    assert.equal(sendFailureKey(new Error('who knows')), 'composer.send_failed')
    assert.equal(sendFailureKey(undefined), 'composer.send_failed')
  })
})

describe('the send path cannot lose text silently any more (CLE-3433)', () => {
  it('TopBar catches the rejection instead of leaving it unhandled', () => {
    const s = src('src/components/TopBar.vue')
    assert.match(s, /await target\.send\(text, sent\)/)
    assert.match(s, /catch \(err\)/)
    assert.match(s, /sendFailureKey\(err\)/)
    /* the text goes back in the box - the human never has to retype it */
    assert.match(s, /composer\.value\?\.restore\(text, sent\)/)
    assert.match(s, /test-id="omnibox-send-error"/)
    assert.match(s, /data-test="omnibox-send-retry"/)
  })

  it('the composer can be handed its text back', () => {
    const s = src('src/components/MessageComposer.vue')
    assert.match(s, /function restore\(body: string, files\?: File\[\]\)/)
    assert.match(s, /defineExpose\(\{ setText, focus: focusInput, restore \}\)/)
  })

  it('sendLive retries once on a dropped socket, keeping the optimistic row', () => {
    const s = src('src/stores/channel.ts')
    assert.match(s, /import \{ shouldAutoResend \} from '~\/utils\/send-failure\.mjs'/)
    assert.match(s, /if \(!shouldAutoResend\(first\)\) \{/)
    /* the retry reuses the SAME frame, so the hub de-dupes on our msg_id */
    const body = s.slice(s.indexOf('catch (first)'), s.indexOf('const row = rowFromAck'))
    assert.match(body, /ack = await client\.send\(frame\)/)
    assert.doesNotMatch(body, /newId\(/)
  })

  it('all 19 locales carry the three failure lines and the retry label', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    assert.equal(files.length, 19)
    for (const code of files) {
      const c = JSON.parse(readFileSync(join(dir, `${code}.json`), 'utf8')).composer
      for (const k of ['send_failed', 'send_failed_closed', 'send_failed_timeout', 'send_retry']) {
        assert.equal(typeof c[k], 'string', `${code}: composer.${k} missing`)
        assert.ok(c[k].trim().length > 0, `${code}: composer.${k} empty`)
      }
    }
  })
})
