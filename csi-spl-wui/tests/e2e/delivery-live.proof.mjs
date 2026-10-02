// CLE-35076 live DELIVERY proof (perf lane P3): what the network costs a
// returning visitor, measured in one real Chrome against a deployed host.
//
//   anon    /login loaded once, then reloaded N times with the HTTP cache
//           kept: per reload the round trips that still reach the network
//           (a 304 revalidation is a full round trip for zero bytes), how
//           many were 304s, the bytes, and the load time.
//   member  (EMAIL + PW_FILE set) native sign-in, then /lobby reloaded N
//           times the same way, plus per reload the CORS preflights, the API
//           reads and their 304s, and the live socket's negotiated
//           extensions and received frames (count, payload bytes).
//
//   BASE=https://<host> OUT=<dir> [N=5] [EMAIL=<member> PW_FILE=<0600 file>]
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/delivery-live.proof.mjs
//
// A measurement, not a gate: exit 0 unless sign-in or a page load fails.
// The password is read from PW_FILE and never printed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const N = Number(process.env.N || 5)
const TENANT = process.env.TENANT || 't1'
const email = process.env.EMAIL || ''
const pw = email ? readFileSync(need('PW_FILE'), 'utf8').trim() : ''
mkdirSync(OUT, { recursive: true })

/** Every request of the page by CDP id: status, cache source, bytes; preflights and socket frames apart. */
function recorder(cdp) {
  let reqs = new Map(), ws = { ext: [], frames: 0, payloadBytes: 0 }
  cdp.on('Network.requestWillBeSent', (e) => {
    if (e.request.url.startsWith('data:')) return
    reqs.set(e.requestId, { ...reqs.get(e.requestId), url: e.request.url, method: e.request.method, type: e.type, bytes: 0, cached: false, status: 0 })
  })
  cdp.on('Network.responseReceived', (e) => {
    const r = reqs.get(e.requestId); if (!r) return
    r.status = e.response.status
    r.cached = !!(e.response.fromDiskCache || e.response.fromMemoryCache || e.response.fromServiceWorker || e.response.fromPrefetchCache)
  })
  // CDP reports a revalidated resource as the cached 200; the wire status
  // (304) only arrives in the extra-info event
  cdp.on('Network.responseReceivedExtraInfo', (e) => { const r = reqs.get(e.requestId); if (r && e.statusCode) r.wire = e.statusCode })
  cdp.on('Network.requestServedFromCache', (e) => { const r = reqs.get(e.requestId); if (r) r.cached = true })
  cdp.on('Network.loadingFinished', (e) => { const r = reqs.get(e.requestId); if (r) r.bytes = e.encodedDataLength })
  cdp.on('Network.webSocketHandshakeResponseReceived', (e) => {
    const h = e.response.headers || {}
    const v = h['Sec-WebSocket-Extensions'] ?? h['sec-websocket-extensions'] ?? ''
    ws.ext.push(v || '(none)')
  })
  cdp.on('Network.webSocketFrameReceived', (e) => { ws.frames++; ws.payloadBytes += (e.response.payloadData || '').length })
  return {
    take() {
      const out = { reqs: [...reqs.values()], ws }
      reqs = new Map(); ws = { ext: [], frames: 0, payloadBytes: 0 }
      return out
    },
  }
}

const isApi = (r) => { const u = new URL(r.url, BASE); return /^\/(v1|api)\//.test(u.pathname) || u.host !== new URL(BASE).host }
function summarise({ reqs, ws }) {
  for (const r of reqs) if (r.wire) r.status = r.wire
  // bytes 0 = never left the browser (a memory-cache or preload hit)
  const net = reqs.filter((r) => !r.cached && r.bytes > 0 && r.method !== 'OPTIONS' && r.type !== 'Preflight')
  const preflights = reqs.filter((r) => r.method === 'OPTIONS' || r.type === 'Preflight')
  const api = net.filter(isApi)
  return {
    roundTrips: net.length,
    revalidated304: net.filter((r) => r.status === 304).length,
    fromCache: reqs.filter((r) => r.cached).length,
    kb: Math.round(reqs.reduce((a, r) => a + r.bytes, 0) / 102.4) / 10,
    preflights: preflights.length,
    apiReads: api.length,
    api304: api.filter((r) => r.status === 304).length,
    apiKB: Math.round(api.reduce((a, r) => a + r.bytes, 0) / 102.4) / 10,
    wsExt: ws.ext, wsFrames: ws.frames, wsPayloadKB: Math.round(ws.payloadBytes / 102.4) / 10,
    net304: net.filter((r) => r.status === 304).map((r) => r.url.replace(/^https?:\/\/[^/]+/, '')),
    network: net.map((r) => `${r.method} ${r.url.replace(/^https?:\/\/[^/]+/, '')} ${r.status} ${r.bytes}B`),
  }
}
const loadMs = (p) => p.evaluate(() => Math.round((performance.getEntriesByType('navigation')[0] || {}).loadEventEnd || 0))
const pct = (xs, q) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)] : 0 }
function stats(runs) {
  const keys = ['roundTrips', 'revalidated304', 'kb', 'preflights', 'apiReads', 'api304', 'apiKB', 'wsFrames', 'loadMs']
  return Object.fromEntries(keys.map((k) => [k, { p50: pct(runs.map((r) => r[k]), 0.5), p95: pct(runs.map((r) => r[k]), 0.95) }]))
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const res = { base: BASE, at: new Date().toISOString(), n: N, phases: {} }
let failed = false
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  const rec = recorder(cdp)

  async function reloads(path, wait) {
    await p.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 60000 })
    await sleep(wait)
    rec.take()
    const runs = []
    for (let i = 0; i < N; i++) {
      await p.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 60000 })
      await sleep(wait)
      runs.push({ ...summarise(rec.take()), loadMs: await loadMs(p) })
    }
    return { runs, stats: stats(runs) }
  }

  res.phases.anon = await reloads('/login?tenant=' + encodeURIComponent(TENANT), 1000)

  if (email) {
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'domcontentloaded', timeout: 60000 })
    await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
    if (!signed) throw new Error('sign-in failed at ' + p.url())
    await sleep(1500)
    rec.take()
    res.phases.member = await reloads('/lobby', 3000)
  }
} catch (e) {
  failed = true
  res.error = String((e && e.message) || e)
  console.log('FAIL', res.error)
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/delivery.json`, JSON.stringify(res, null, 1))
for (const [name, ph] of Object.entries(res.phases)) {
  const s = ph.stats
  const line = Object.entries(s).map(([k, v]) => `${k}=${v.p50}/${v.p95}`).join(' ')
  console.log(`${name} n=${ph.runs.length} (p50/p95) ${line}`)
  const last = ph.runs[ph.runs.length - 1]
  console.log(`${name} last: wsExt=${JSON.stringify(last.wsExt)} 304s=${JSON.stringify(last.net304)}`)
}
console.log('build', JSON.stringify(res.build || {}))
process.exit(failed ? 1 : 0)
