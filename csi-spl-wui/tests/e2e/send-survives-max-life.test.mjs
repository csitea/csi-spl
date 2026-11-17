// SPL-5749 / SPL-5755 (spec 162 F7): a send survives the hub closing its
// socket at max life. The hub closes every socket after WSMaxLife with 1012
// max_life (ws_maxlife.go); a socket on its way out answers nothing more, and
// its close can reach the tab after the 10 s ack timer. Before the fix that
// timer was final: the reader saw "not sent" (event omnibox-send timeout)
// even when the hub had stored the row.
//
//   mock hub (in process, no browser): the WUI's own live-ws client and
//   sendWithResend, the hub's msg_id de-dupe (wui.go wuiAck acks a duplicate
//   with the stored row), a socket that goes quiet and then closes 1012:
//     A the hub stored the frame, then the socket went quiet and closed
//       1012 -> the send resolves, ONE row
//     B the frame died with the quiet socket -> the send resolves, ONE row
//     C the socket closes 1012 at once, the frame pending -> ONE row
//     D an upload whose POST gets hub_down while the socket redials is sent
//       again after the redial -> one file
//   CONTROL: before the fix A and B reject 'timeout' (the reader's "not sent")
//   and D rejects 'hub_down'.
//
// Run:
//   pnpm run test:e2e send-survives-max-life
import { createLiveClient } from '../../src/utils/live-ws.mjs'
import { sendWithResend } from '../../src/utils/send-failure.mjs'
import { hubDownError } from '../../src/utils/upload-fail.mjs'
import { uploadWithFreshToken } from '../../src/utils/upload-retry.mjs'

const ACK_MS = 300
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** The hub's side: the rows it stored (by msg_id) and its sockets. */
function mockHub() {
  const rows = new Map()
  const sockets = []
  class MockSocket {
    constructor(url) {
      this.url = url
      this.quiet = false
      this.closed = false
      sockets.push(this)
      /* a closed socket never opens, as in a browser */
      setTimeout(() => !this.closed && this.onopen && this.onopen(), 5)
    }
    send(s) {
      if (this.closed) return
      const f = JSON.parse(s)
      if (f.type === 'hello') return this.push({ type: 'welcome', as: 'HUM-1', upload_token: `t${sockets.length}` })
      if (f.type !== 'send') return
      if (this.quiet === 'lost') return
      const dup = rows.has(f.msg_id)
      if (!dup) rows.set(f.msg_id, f)
      if (this.quiet) return
      this.push({ type: 'ack', msg_id: f.msg_id, duplicate: dup })
    }
    push(obj) {
      setTimeout(() => !this.closed && this.onmessage && this.onmessage({ data: JSON.stringify(obj) }), 1)
    }
    /** The browser's close() and the hub's 1012 both end here. */
    close(code = 1000, reason = '') {
      if (this.closed) return
      this.closed = true
      setTimeout(() => this.onclose && this.onclose({ code, reason }), 1)
    }
  }
  return { rows, sockets, MockSocket }
}

async function openClient(hub) {
  const c = createLiveClient({ url: 'ws://mock/v1/wui/ws', WebSocketImpl: hub.MockSocket, ackTimeoutMs: ACK_MS, random: () => 0 })
  c.connect()
  for (let i = 0; i < 100 && c.state !== 'open'; i++) await sleep(10)
  return c
}

/** Send with the stores' one resend; the socket turns `quiet` and closes 1012 after `closeAfterMs`. */
async function scenario(quiet, closeAfterMs) {
  const hub = mockHub()
  const c = await openClient(hub)
  const first = hub.sockets[0]
  first.quiet = quiet
  const frame = { task_id: 'L', body: 'hi', msg_id: `m-${quiet}-${closeAfterMs}` }
  const sent = sendWithResend(() => c.send(frame)).then((ack) => ({ ack }), (err) => ({ err: err.token || String(err) }))
  setTimeout(() => first.close(1012, 'max_life'), closeAfterMs)
  const out = await sent
  await sleep(ACK_MS + 100)
  c.close()
  return { ...out, rows: [...hub.rows.keys()].filter((k) => k === frame.msg_id).length, dials: hub.sockets.length }
}

const a = await scenario(true, ACK_MS + 150)
ok('A stored, then quiet, then 1012 max_life after the ack timer: the send lands, exactly one row', Boolean(a.ack) && a.rows === 1, a)
const b = await scenario('lost', ACK_MS + 150)
ok('B lost on the quiet socket, then 1012 max_life: the send lands, exactly one row', Boolean(b.ack) && b.rows === 1, b)
const cc = await scenario('lost', 50)
ok('C 1012 max_life while the frame is pending: the send lands, exactly one row', Boolean(cc.ack) && cc.rows === 1, cc)

/* D: the POST meets the 1012 close; the socket is redialling when hub_down comes back */
{
  const hub = mockHub()
  const c = await openClient(hub)
  const files = []
  const api = {
    async uploadFile(file, token) {
      if (!files.length && !hub.sockets[0].closed) {
        hub.sockets[0].close(1012, 'max_life')
        await sleep(20)
        throw hubDownError(new TypeError('Failed to fetch'))
      }
      files.push({ file, token })
      return { file_id: 'f1', sha256: 'f1', bytes: 1 }
    },
  }
  const live = {
    state: { get value() { return c.state } },
    ensure() {},
    async freshUploadToken() { return c.welcome ? c.welcome.upload_token : '' },
  }
  const d = await uploadWithFreshToken(api, live, 'bytes').then((r) => ({ r }), (e) => ({ err: e.token || String(e) }))
  c.close()
  ok('D an upload that gets hub_down while the socket redials is sent once more and lands once', Boolean(d.r) && files.length === 1, { ...d, files: files.length })
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
