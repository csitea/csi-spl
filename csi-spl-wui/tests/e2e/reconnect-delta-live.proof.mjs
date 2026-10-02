// R2-2 live proof (db payload audit round 2): reconnect catch-up as a delta.
// One signed-in session, two tabs of it. Tab A opens a channel; the proof
// cuts A's network (CDP offline) and closes its live socket RUNS times, then
// brings the network back so the socket redials. CDP offline alone does NOT
// drop an open WebSocket, so A's WebSocket is wrapped before the app loads. For each reconnect it counts the topic reads A makes and their bytes
// on the wire (CDP encodedDataLength). The old catch-up's read - one topics
// page (limit 20, per_topic 50) plus a limit=1 read per topic whose page did
// not hold its opener, exactly what listMessages({limit: 50}) sends - is
// replayed RUNS times in the same tab as the "before".
// In the first gap tab B (same session, still online) adds a reaction to A's
// newest row; after the reconnect A must show it with no reload.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=live-proof] [RUNS=3] [EMOJI=👀] \
//     node tests/e2e/reconnect-delta-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'live-proof'
const RUNS = Number(process.env.RUNS || 3)
const EMOJI = process.env.EMOJI || '👀'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, channel: CHANNEL, at: new Date().toISOString(), runs: RUNS, steps: [], before: [], after: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

const browser = await puppeteer.launch({ headless: true, executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', args: ['--no-sandbox'] })
try {
  const a = await browser.newPage()
  await a.evaluateOnNewDocument(() => {
    const W = window.WebSocket
    window.__sockets = []
    window.WebSocket = function (...args) { const ws = new W(...args); window.__sockets.push(ws); return ws }
    window.WebSocket.prototype = W.prototype
    Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 })
  })
  await a.setViewport({ width: 1400, height: 900 })
  await a.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await a.waitForSelector('[data-test=native-auth-email]')
  await a.type('[data-test=native-auth-email]', email)
  await a.type('[data-test=native-auth-password]', pw)
  await a.click('[data-test=native-auth-submit]')
  const signed = await a.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signed)
  if (!signed) throw new Error('not signed in')

  // The wire log of tab A: topic reads with their encoded (gzip) size.
  const cdp = await a.createCDPSession()
  await cdp.send('Network.enable')
  const reqs = new Map()
  let sockets = 0
  cdp.on('Network.webSocketCreated', () => { sockets++ })
  cdp.on('Network.requestWillBeSent', (e) => { if (/\/v1\/view\/topics/.test(e.request.url) && e.request.method === 'GET') reqs.set(e.requestId, { url: e.request.url, t: Date.now(), bytes: 0, body: 0, status: 0, done: false }) })
  cdp.on('Network.responseReceived', (e) => { const r = reqs.get(e.requestId); if (r) r.status = e.response.status })
  cdp.on('Network.dataReceived', (e) => { const r = reqs.get(e.requestId); if (r) r.body += e.dataLength })
  cdp.on('Network.loadingFinished', (e) => { const r = reqs.get(e.requestId); if (r) { r.bytes = e.encodedDataLength; r.done = true } })
  cdp.on('Network.loadingFailed', (e) => { const r = reqs.get(e.requestId); if (r) r.done = true })
  // The channel catch-up's reads: its topics page and per-topic reads. Other
  // reads on a reconnect (the DM seed, boot) are listed apart, not counted.
  const mine = (r) => r.url.includes('channel=' + encodeURIComponent(CHANNEL)) || /\/v1\/view\/topics\/[0-9a-f-]{36}/.test(r.url)
  const window = (from) => [...reqs.values()].filter((r) => r.t >= from && mine(r))
  const others = (from) => [...reqs.values()].filter((r) => r.t >= from && !mine(r)).map((r) => r.url.replace(/^https?:\/\/[^/]+/, '').slice(0, 80))
  const sum = (rs) => ({ reads: rs.length, bytes: rs.reduce((n, r) => n + r.bytes, 0), body: rs.reduce((n, r) => n + r.body, 0),
    status: rs.map((r) => r.status), urls: rs.map((r) => r.url.replace(/^https?:\/\/[^/]+/, '')) })

  await a.goto(BASE + '/channel/' + encodeURIComponent(CHANNEL), { waitUntil: 'networkidle2' })
  await a.waitForSelector('form.composer textarea', { timeout: 20000 }).catch(() => {})
  await sleep(2500)
  const api = [...reqs.values()][0].url.split('/v1/view/')[0]
  res.api_root = api.replace(/^https?:\/\/[^/]+/, '<host>')
  const held = () => a.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    return (pinia.state.value.channel.messages || []).map((m) => ({ msg_id: m.msg_id, task_id: m.task_id, received_at: m.received_at, reactions: m.reactions || [] }))
  })
  const rows = await held()
  step('channel feed loaded', rows.length > 0, { rows: rows.length, api_host_seen: !!api })

  // BEFORE: the old catch-up's reads, replayed in tab A - as the app sends
  // them (the browser cache may revalidate to a 304: the hub still reads the
  // whole page to hash it), and with no-store (the page the hub builds).
  res.before_nostore = []
  for (let i = 0; i < 2 * RUNS; i++) {
    const cache = i < RUNS ? 'default' : 'no-store'
    const t0 = Date.now()
    const err = await a.evaluate(async (root, ch, cache) => {
     try {
      const r = await fetch(`${root}/v1/view/topics?limit=20&channel=${encodeURIComponent(ch)}&per_topic=50`, { cache, credentials: 'include', headers: { accept: 'application/json' } })
      const body = await r.json()
      for (const t of body.topics || []) {
        if (Number(t.count) > (t.messages || []).length) {
          await fetch(`${root}/v1/view/topics/${t.task_id}?limit=1`, { cache, credentials: 'include', headers: { accept: 'application/json' } })
        }
      }
      return ''
     } catch (e) { return String(e) }
    }, api, CHANNEL, cache)
    if (err) step('before: replay the old catch-up reads', false, { error: err, root: res.api_root })
    await sleep(800)
    ;(cache === 'default' ? res.before : res.before_nostore).push(sum(window(t0)))
  }

  // AFTER: real reconnects. The first gap carries a reaction from tab B.
  const target = rows.slice().sort((x, y) => Date.parse(y.received_at || 0) - Date.parse(x.received_at || 0))[0]
  const b = await browser.newPage()
  await b.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  const had = (target.reactions || []).some((r) => r.emoji === EMOJI)
  for (let i = 0; i < RUNS; i++) {
    const s0 = sockets
    await cdp.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
    await a.evaluate(() => { for (const ws of window.__sockets) if (ws.readyState <= 1) ws.close(4000, 'proof gap') })
    await sleep(3000)
    if (i === 0) {
      const code = await b.evaluate(async (root, id, emoji, op) => {
        const r = await fetch(`${root}/v1/messages/${id}/reactions`, { method: op, credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ emoji }) })
        return r.status
      }, api, target.msg_id, EMOJI, had ? 'DELETE' : 'PUT')
      step(`gap: tab B ${had ? 'removed' : 'added'} ${EMOJI} on the newest row`, code >= 200 && code < 300, { status: code, msg_id: target.msg_id })
    }
    const t0 = Date.now()
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
    const deadline = Date.now() + 20000
    while (sockets === s0 && Date.now() < deadline) await sleep(200)
    await sleep(4000)
    const w = sum(window(t0))
    res.after.push({ ...w, others: others(t0), redialled: sockets > s0, delta: w.urls.some((u) => u.includes('since=')) })
    if (i === 0) {
      const now = (await held()).find((m) => m.msg_id === target.msg_id)
      const has = !!now && (now.reactions || []).some((r) => r.emoji === EMOJI)
      step(`after reconnect: the gap's reaction shows on the row (no reload)`, has === !had, { has_emoji: has, reactions: now && now.reactions })
      await a.screenshot({ path: `${OUT}/after-reconnect.png` }).catch(() => {})
      // put it back as it was
      await b.evaluate(async (root, id, emoji, op) => {
        await fetch(`${root}/v1/messages/${id}/reactions`, { method: op, credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ emoji }) })
      }, api, target.msg_id, EMOJI, had ? 'PUT' : 'DELETE')
    }
  }
  const med = (xs) => xs.slice().sort((p, q) => p - q)[Math.floor(xs.length / 2)]
  res.summary = {
    before: { reads_median: med(res.before.map((r) => r.reads)), bytes_median: med(res.before.map((r) => r.bytes)) },
    after: { reads_median: med(res.after.map((r) => r.reads)), bytes_median: med(res.after.map((r) => r.bytes)) },
    before_nostore: { reads_median: med(res.before_nostore.map((r) => r.reads)), bytes_median: med(res.before_nostore.map((r) => r.bytes)), body_median: med(res.before_nostore.map((r) => r.body)) },
    before_body_median: med(res.before.map((r) => r.body)), after_body_median: med(res.after.map((r) => r.body)),
  }
  step('every reconnect redialled the socket', res.after.every((r) => r.redialled))
  step('every reconnect read a delta (since=)', res.after.every((r) => r.delta), { after: res.after.map((r) => ({ reads: r.reads, bytes: r.bytes, body: r.body, status: r.status })) })
  console.log('SUMMARY', JSON.stringify(res.summary))
} catch (e) {
  step('run', false, { error: String(e && e.message || e) })
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
