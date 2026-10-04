// SPL-964 — a reply sent from the Topics page was lost.
//
// Owner 2026-09-26: "when being in the topics and a thread msg from the topic
// has been selected last, it does not result in adding a new msg when one
// clicks after that to the omnibox, types the msg and clicks on the send".
//
// Measured on dev (build 8212214, tests/e2e/select-reply-send-live.proof.mjs
// DROP=1, n=1 per surface): with the socket closing while the reply's frame
// was pending, the Topics page (`/`) stored NOTHING and emptied the Omnibox;
// the only trace was a notice inside the right pane. /channel/lobby, same
// drop, stored the reply. The two pages send through different stores:
// channel.sendLive resends once on 'closed' and rethrows, while
// stores/live.ts send() - used by `/`, `/t/<id>` and #lobby - did neither.
// It caught every failure, so TopBar never learned the send had failed and
// never put the text back.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sendWithResend } from '../../src/utils/send-failure.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const closed = () => Object.assign(new Error('socket closed'), { token: 'closed' })
const timeout = () => Object.assign(new Error('send timed out'), { token: 'timeout' })

/** A client.send stand-in: fails with each error in turn, then acks. */
function flaky(...errors) {
  const calls = []
  const send = async (frame) => {
    calls.push(frame)
    const e = errors.shift()
    if (e) throw e
    return { cursor: 'c1' }
  }
  return { send, calls }
}

describe('sendWithResend: one resend, only where it cannot double-post', () => {
  it("a frame lost to a closed socket is sent again, the SAME frame", async () => {
    const c = flaky(closed())
    const frame = { msg_id: 'm1', body: 'hi' }
    const ack = await sendWithResend(() => c.send(frame))
    assert.deepEqual(ack, { cursor: 'c1' })
    assert.equal(c.calls.length, 2)
    assert.equal(c.calls[0], c.calls[1])
  })

  it('a second close is reported, not retried forever', async () => {
    const c = flaky(closed(), closed())
    await assert.rejects(sendWithResend(() => c.send({})), (e) => e.token === 'closed')
    assert.equal(c.calls.length, 2)
  })

  it('a timeout or any other failure is reported at once', async () => {
    for (const e of [timeout(), new Error('403 tenant_mismatch')]) {
      const c = flaky(e)
      await assert.rejects(sendWithResend(() => c.send({})), (x) => x === e)
      assert.equal(c.calls.length, 1)
    }
  })
})

describe('stores/live.ts send() never loses a line silently (SPL-964)', () => {
  const s = src('src/stores/live.ts')
  const send = s.slice(s.indexOf('async function send('), s.indexOf('\n  return {', s.indexOf('async function send(')))

  it('resends once on a closed socket, like channel.sendLive', () => {
    assert.match(send, /sendWithResend\(\s*\(\)\s*=>\s*client\.send\(/)
  })

  it('a failure reaches the Omnibox: the catch rethrows', () => {
    const c = send.slice(send.indexOf('} catch (e) {'))
    assert.ok(c.length > 0, 'send() has a catch')
    assert.match(c.slice(0, c.indexOf('} finally')), /\bthrow e\b/)
  })

  it('no open task is an error, not a quiet return', () => {
    assert.doesNotMatch(send, /if \(!taskId\.value\) return\b/)
    assert.match(send, /if \(!taskId\.value\) throw /)
  })

  it('refuses an empty line after the mention is parsed, before the frame goes out', () => {
    const guard = send.indexOf('isEmptySend(text, refs)')
    assert.ok(guard > 0, 'send() checks isEmptySend(text, refs)')
    assert.ok(guard > send.indexOf('parseMention(body)'))
    assert.ok(guard < send.indexOf('pendingRow('))
  })

  it('channel.sendLive shares the same resend rule', () => {
    const c = src('src/stores/channel.ts')
    const live = c.slice(c.indexOf('async function sendLive'))
    assert.match(live.slice(0, live.indexOf('\n  }\n')), /sendWithResend\(\s*\(\)\s*=>\s*client\.send\(frame\)\s*\)/)
  })
})

describe('every page that sends through the live store lets a failure reach TopBar', () => {
  it('TopBar restores the text and names the failure when target.send rejects', () => {
    const t = src('src/components/TopBar.vue')
    const on = t.slice(t.indexOf('async function onSend'))
    assert.match(on, /await target\.send\(/)
    assert.match(on, /composer\.value\?\.restore\(text, sent\)/)
    assert.match(on, /sendError\.value = \{ key: sendFailureKey\(err\)/)
  })

  for (const page of ['src/pages/index.vue', 'src/pages/lobby.vue']) {
    it(`${page} awaits the store send and does not catch it`, () => {
      const p = src(page)
      assert.match(p, /await (pane|store)\.send\(/)
      assert.doesNotMatch(p, /(pane|store)\.send\([^)]*\)\s*\.catch\(/)
    })
  }

  it('src/pages/t/[task_id].vue awaits channel.send and does not catch it', () => {
    const p = src('src/pages/t/[task_id].vue')
    assert.match(p, /await channel\.send\(/)
    assert.doesNotMatch(p, /\.catch\(/)
  })
})
