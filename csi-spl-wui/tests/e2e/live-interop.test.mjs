// Live-chat interop against a REAL hub (003 wui-live-ws.md): two WUI sockets,
// a live lobby exchange, persistence via view-v1, and a file round trip.
// Uses the same client the pages use (utils/live-ws.mjs).
//
// Run (lde hub with the door off):
//   HUB_URL=http://t1.localhost:58080 node --experimental-websocket tests/e2e/live-interop.test.mjs
// Optional: BOX_POST_BODY=<text> — also wait for a box-agent lobby post with that body
// (send it with: spool send --to ALL-0 --to-box box-wui --task-id <lobby> --kind note --body <text>).
// Without HUB_URL the test is skipped (exit 0) locally. When CI is set,
// an unset HUB_URL is exit 1 so a skip cannot pass the gate (016 T006).

import { createLiveClient, wsUrl } from '../../src/utils/live-ws.mjs'
import { createSpoolClient, sha256Hex } from '../../src/utils/spool-client.mjs'

const HUB = (process.env.HUB_URL || '').replace(/\/+$/, '')
if (!HUB) {
  if (process.env.CI) {
    console.error('FAIL live-interop: HUB_URL is unset in CI (016 T006). Set HUB_URL or do not wire test:live into CI.')
    process.exit(1)
  }
  console.log('SKIP live-interop: HUB_URL unset')
  process.exit(0)
}
if (typeof WebSocket !== 'function') {
  console.error('FAIL: no WebSocket global — run with node --experimental-websocket (Node 20) or Node >= 22')
  process.exit(1)
}

const results = []
const ok = (n) => { results.push(true); console.log(`  OK   ${n}`) }
const bad = (n, d) => { results.push(false); console.log(`  FAIL ${n}${d ? ` — ${d}` : ''}`) }

function session(as) {
  const got = []
  const waiters = []
  let welcome = null
  const c = createLiveClient({
    url: wsUrl(HUB),
    as,
    onWelcome: (w) => { welcome = w },
    onMessage: (m) => {
      got.push(m)
      for (const w of waiters.slice()) if (w.pred(m)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(m) }
    },
  })
  return {
    c,
    got,
    get welcome() { return welcome },
    waitFor(pred, ms = 10000) {
      const hit = got.find(pred)
      if (hit) return Promise.resolve(hit)
      return new Promise((resolve, reject) => {
        const w = { pred, resolve }
        waiters.push(w)
        setTimeout(() => { const i = waiters.indexOf(w); if (i >= 0) { waiters.splice(i, 1); reject(new Error('timeout')) } }, ms)
      })
    },
  }
}

async function until(fn, ms = 10000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) { if (fn()) return true; await new Promise((r) => setTimeout(r, 50)) }
  return false
}

const A = session('HUM-801')
const B = session('HUM-802')
A.c.connect()
B.c.connect()
try {
  if (await until(() => A.c.state === 'open' && B.c.state === 'open')) ok('both sockets welcomed')
  else throw new Error(`sockets not open: A=${A.c.state} B=${B.c.state}`)
  const lobby = A.welcome.lobby_task_id
  lobby ? ok(`welcome carries lobby_task_id ${lobby}`) : bad('welcome carries lobby_task_id')
  A.welcome.as === 'HUM-801' ? ok('welcome.as honours hello.as') : bad('welcome.as', A.welcome.as)
  A.c.subscribe(lobby)
  B.c.subscribe(lobby)
  await new Promise((r) => setTimeout(r, 300))

  // A -> B live
  const bodyA = `interop A->B ${Date.now()}`
  await A.c.send({ task_id: lobby, body: bodyA })
  const seenB = await B.waitFor((m) => m.body === bodyA).catch(() => null)
  seenB ? ok('B receives A live') : bad('B receives A live')
  seenB && seenB.from === 'HUM-801' ? ok('from = HUM-801') : bad('from', seenB && seenB.from)
  seenB && seenB.from_box === 'box-wui' ? ok('from_box = box-wui') : bad('from_box', seenB && seenB.from_box)

  // B -> A live
  const bodyB = `interop B->A ${Date.now()}`
  await B.c.send({ task_id: lobby, body: bodyB })
  ;(await A.waitFor((m) => m.body === bodyB).catch(() => null)) ? ok('A receives B live') : bad('A receives B live')

  // persistence
  const api = createSpoolClient({ base: HUB, mock: false })
  const hist = await api.getTopic(lobby)
  const bodies = hist.messages.map((m) => m.body)
  bodies.includes(bodyA) && bodies.includes(bodyB) ? ok('both persist (view-v1 re-fetch)') : bad('persist', `${bodies.length} stored`)

  // file round trip: A uploads + sends, B downloads identical bytes
  const bytes = new TextEncoder().encode(`spool interop file ${Date.now()}\n`)
  const up = await api.uploadFile(new Blob([bytes]), A.welcome.upload_token)
  const want = await sha256Hex(bytes.buffer)
  up.file_id === want ? ok('upload is content-addressed') : bad('upload file_id', up.file_id)
  const bodyF = `file ${Date.now()}`
  await A.c.send({ task_id: lobby, body: bodyF, files: [{ mode: 'blob', kind: 'file', file_id: up.file_id, sha256: up.sha256, bytes: up.bytes, name: 'interop.txt' }] })
  const fm = await B.waitFor((m) => m.body === bodyF).catch(() => null)
  const ref = fm && Array.isArray(fm.files) ? fm.files[0] : null
  if (!ref) bad('B receives the file ref')
  else {
    ok('B receives the file ref')
    const got = await createSpoolClient({ base: HUB, mock: false }).downloadFile(ref.file_id)
    ;(await sha256Hex(got)) === want ? ok('B downloads identical bytes (sha256)') : bad('download sha256')
  }

  // optional: box agent post
  if (process.env.BOX_POST_BODY) {
    const bp = await A.waitFor((m) => m.body === process.env.BOX_POST_BODY, 60000).catch(() => null)
    bp ? ok(`box agent post live (${bp.from}@${bp.from_box})`) : bad('box agent post live (60 s)')
  }
} catch (e) {
  bad('interop', e.message)
} finally {
  A.c.close()
  B.c.close()
}
const failed = results.filter((x) => !x).length
console.log(`\n${results.length - failed}/${results.length} checks passed (${failed} failed)`)
process.exit(failed ? 1 : 0)
