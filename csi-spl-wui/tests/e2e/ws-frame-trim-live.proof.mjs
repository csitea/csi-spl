// R2-3 live proof (db payload audit round 2): the trimmed WUI `message` frame.
// One signed-in session, two pages: desktop (1400 px) and phone (390 px), both
// open on one topic of CHANNEL. The desktop page's live socket posts a root
// and RUNS replies; each reply must show in BOTH pages with no reload. Every
// `message` frame both pages receive (CDP webSocketFrameReceived, payload as
// the page reads it, after inflate) is normalised with this tree's
// messageFromFrame and must carry the ack's cursor, the topic's task_id,
// files [] and box-wui ends - the same object the full frame gave. The
// payloads go to OUT/frames.jsonl for the byte count (raw and deflated).
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=live-proof] [RUNS=5] \
//     node tests/e2e/ws-frame-trim-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { randomUUID } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'
import { messageFromFrame } from '../../src/utils/live-ws.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'live-proof'
const RUNS = Number(process.env.RUNS || 5)
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, channel: CHANNEL, runs: RUNS, steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ headless: true, executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', args: ['--no-sandbox'] })
const frames = []
async function openPage(label, viewport) {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument(() => {
    const W = window.WebSocket
    window.__sockets = []
    window.WebSocket = function (...args) { const ws = new W(...args); window.__sockets.push(ws); return ws }
    window.WebSocket.prototype = W.prototype
    Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 })
  })
  await p.setViewport(viewport)
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  cdp.on('Network.webSocketFrameReceived', (e) => {
    const data = e.response && e.response.payloadData
    if (typeof data !== 'string' || !data.includes('"type":"message"')) return
    try { const f = JSON.parse(data); if (f.type === 'message') frames.push({ page: label, bytes: Buffer.byteLength(data), payload: data, frame: f }) } catch { /* not JSON */ }
  })
  return p
}
const shown = (p, text) => p.waitForFunction((t) => document.body && document.body.innerText.includes(t), { timeout: 20000 }, text).then(() => true, () => false)

try {
  const d = await openPage('desktop', { width: 1400, height: 900 })
  await d.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await d.waitForSelector('[data-test=native-auth-email]')
  await d.type('[data-test=native-auth-email]', email)
  await d.type('[data-test=native-auth-password]', pw)
  await d.click('[data-test=native-auth-submit]')
  const signed = await d.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signed)
  if (!signed) throw new Error('not signed in')

  // send over the desktop page's own live socket; resolves the ack / error frame
  const send = (frame) => d.evaluate((fr) => new Promise((resolve) => {
    const ws = window.__sockets.filter((s) => s.readyState === 1).pop()
    if (!ws) return resolve({ type: 'error', error: 'no open socket' })
    const on = (ev) => { try { const f = JSON.parse(ev.data); if ((f.type === 'ack' || f.type === 'error') && f.msg_id === fr.msg_id) { ws.removeEventListener('message', on); resolve(f) } } catch { /* ignore */ } }
    ws.addEventListener('message', on)
    ws.send(JSON.stringify(fr))
    setTimeout(() => resolve({ type: 'error', error: 'ack timeout' }), 15000)
  }), frame)

  const task = randomUUID()
  /* a plain tag, not a date: the WUI re-renders ISO times in a body as local ones */
  const stamp = randomUUID().slice(0, 8)
  const root = await send({ type: 'send', msg_id: randomUUID(), task_id: task, channel: CHANNEL, body: `R2-3 frame-trim proof ${stamp}` })
  step('root posted', root.type === 'ack', { task_id: task, ack: root.type, error: root.error })
  if (root.type !== 'ack') throw new Error('root refused')

  const ph = await openPage('phone', { width: 390, height: 844 })
  await d.goto(BASE + '/t/' + task, { waitUntil: 'networkidle2' })
  await ph.goto(BASE + '/t/' + task, { waitUntil: 'networkidle2' })
  await sleep(1500)
  const acks = new Map()
  for (let i = 1; i <= RUNS; i++) {
    const body = `R2-3 reply ${i} of ${RUNS} ${stamp}`
    const msgId = randomUUID()
    const ack = await send({ type: 'send', msg_id: msgId, task_id: task, channel: CHANNEL, body })
    acks.set(msgId, ack)
    const [inD, inP] = await Promise.all([shown(d, body), shown(ph, body)])
    step(`reply ${i} shows in the open topic, desktop + phone`, ack.type === 'ack' && inD && inP, { ack: ack.type, desktop: inD, phone: inP })
  }
  await sleep(1000)
  await d.screenshot({ path: OUT + '/desktop.png' })
  await ph.screenshot({ path: OUT + '/phone.png' })

  // every reply frame normalises to the full message object
  const mine = frames.filter((x) => acks.has(((x.frame.env || {}).msg || {}).msg_id))
  let bad = 0
  for (const x of mine) {
    const m = messageFromFrame(x.frame)
    const ack = acks.get(m.msg_id)
    const ok = m.cursor === ack.cursor && m.task_id === task && Array.isArray(m.files) && m.from_box === 'box-wui' && m.to_box === 'box-wui' && m.channel === CHANNEL
    if (!ok) { bad++; console.log('mismatch', JSON.stringify({ page: x.page, cursor: m.cursor, ack: ack.cursor, task_id: m.task_id, files: m.files, from_box: m.from_box, to_box: m.to_box, channel: m.channel })) }
  }
  step('reply frames normalise to the full message (cursor = ack cursor, task_id, files, boxes, channel)', mine.length === 2 * RUNS && bad === 0, { frames: mine.length, want: 2 * RUNS, bad })
  const trimmed = mine.filter((x) => x.frame.cursor === undefined).length
  const sizes = mine.map((x) => x.bytes).sort((a, b) => a - b)
  res.frames = { n: mine.length, trimmed, raw_bytes: sizes, raw_median: sizes[Math.floor(sizes.length / 2)] }
  console.log('frames', JSON.stringify(res.frames))
  writeFileSync(OUT + '/frames.jsonl', mine.map((x) => JSON.stringify({ page: x.page, bytes: x.bytes, payload: x.payload })).join('\n') + '\n')
} catch (e) {
  step('run', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  writeFileSync(OUT + '/result.json', JSON.stringify(res, null, 2))
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
