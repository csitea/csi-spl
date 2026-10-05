// the owner wrote a message in a DM on 2026-09-21 and it vanished.
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
import { parseMention } from '../../src/utils/channel-feed.mjs'
import { fileURLToPath } from 'node:url'
import { emptySendError, failureToken, isEmptySend, sendFailureKey, shouldAutoResend } from '../../src/utils/send-failure.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const closed = Object.assign(new Error('socket closed'), { token: 'closed' })
const timeout = Object.assign(new Error('send timed out'), { token: 'timeout' })

describe('classifying a failed send', () => {
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
    assert.equal(sendFailureKey(emptySendError()), 'composer.send_failed_empty')
    /* CLE-77795: an upload that could not get a token even after a redial */
    assert.equal(sendFailureKey({ token: 'session_expired' }), 'composer.send_failed_session_expired')
    /* dc6d5e3f: a tag of an agent that is no longer active, refused by the hub */
    assert.equal(sendFailureKey({ token: 'retired_id' }), 'composer.send_failed_agent_inactive')
    /* a recycled id (c-NNN closed): no box announces it, the hub says unknown_agent */
    assert.equal(sendFailureKey({ token: 'unknown_agent' }), 'composer.send_failed_agent_inactive')
  })
})

/* CLE-3434 found this in the dev hub's own store: a row at 12:45:42Z with
   body = "". The composer refuses an empty BOX, but the live path then runs
   parseMention() over the text. A truly empty box still cannot send; a bare
   `@CLE-00` (e09a72f7) is no longer stripped to nothing - it keeps the mention
   as its body and sends. The guard only ever refuses a row with no text AND no
   files, which to the next reader is indistinguishable from a lost message. */
describe('an empty send never reaches the hub', () => {
  it('text-only, files-only and both are all real messages', () => {
    assert.equal(isEmptySend('hello'), false)
    assert.equal(isEmptySend('', [{ name: 'a.pdf' }]), false)
    assert.equal(isEmptySend('hello', [{ name: 'a.pdf' }]), false)
  })

  it('nothing and whitespace are empty; a bare mention is a real message', () => {
    assert.equal(isEmptySend('', []), true)
    assert.equal(isEmptySend('   \n\t ', []), true)
    assert.equal(isEmptySend(null, undefined), true)
    assert.equal(isEmptySend(undefined, null), true)
    /* e09a72f7: a bare `@CLE-00` used to strip to '' and be refused - it now
       keeps the mention as its body and sends (a message that mentions someone) */
    assert.equal(isEmptySend(parseMention('@CLE-00').body, []), false)
    assert.equal(parseMention('@CLE-00').body, '@CLE-00')
    assert.equal(isEmptySend(parseMention('@CLE-00 hi').body, []), false)
  })

  it('sendLive refuses it AFTER the mention is parsed, before the frame goes out', () => {
    const s = src('src/stores/channel.ts')
    const live = s.slice(s.indexOf('async function sendLive'))
    const guard = live.indexOf('isEmptySend(frame.body, frame.files)')
    assert.ok(guard > 0, 'no empty-send guard in sendLive')
    /* before the optimistic row and before the send, or it is not a guard */
    assert.ok(guard < live.indexOf('pendingRow('), 'guard runs after the optimistic row')
    assert.ok(guard < live.indexOf('client.send(frame)'), 'guard runs after the send')
    assert.match(live.slice(guard - 80, guard + 80), /throw emptySendError\(\)/)
  })
})

describe('the send path cannot lose text silently any more', () => {
  it('TopBar catches the rejection instead of leaving it unhandled', () => {
    const s = src('src/components/TopBar.vue')
    assert.match(s, /await target\.send\(text, sent, parent, channelId\)/)
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
    assert.match(s, /defineExpose\(\{ setText, focus: focusInput, restore[,} ]/)
  })

  it('sendLive retries once on a dropped socket, keeping the optimistic row', () => {
    const s = src('src/stores/channel.ts')
    /* SPL-964: the one-resend rule lives in send-failure.mjs sendWithResend,
       shared with stores/live.ts; its behaviour is pinned in pane-send-lost.test.mjs */
    assert.match(s, /import \{[^}]*sendWithResend[^}]*\} from '~\/utils\/send-failure\.mjs'/)
    /* the retry reuses the SAME frame, so the hub de-dupes on our msg_id */
    const body = s.slice(s.indexOf('async function sendLive'), s.indexOf('const row = rowFromAck'))
    assert.match(body, /ack = await sendWithResend\(\(\) => client\.send\(frame\)\)/)
    const tail = body.slice(body.indexOf('sendWithResend('))
    assert.doesNotMatch(tail, /newId\(/)
  })

  it('all 19 locales carry the failure lines and the retry label', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    assert.equal(files.length, 19)
    for (const code of files) {
      const c = JSON.parse(readFileSync(join(dir, `${code}.json`), 'utf8')).composer
      for (const k of ['send_failed', 'send_failed_closed', 'send_failed_timeout', 'send_failed_empty', 'send_failed_session_expired', 'send_failed_agent_inactive', 'send_retry']) {
        assert.equal(typeof c[k], 'string', `${code}: composer.${k} missing`)
        assert.ok(c[k].trim().length > 0, `${code}: composer.${k} empty`)
      }
    }
  })
})
