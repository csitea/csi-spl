// CLE-35062 perf baseline of the WUI against a deployed host, the probe the
// before/after of every perf fix is measured with. ONE native sign-in (the
// hub allows 10 per email per 15 min), then per PROFILE, N rounds of:
//
//   cold     /lobby with the HTTP cache cleared: TTFB, FCP, LCP, first message,
//            TTI (last long task end, or first message if later), TBT, JS/CSS
//            bytes on the wire, request count, websocket connect time.
//   warm     the same URL reloaded with the cache kept.
//   home     / with the HTTP cache cleared: FCP and the first topic row.
//   list     client-side route to / until the first topic row shows.
//   open     click the first topic row until the topic pane shows a message.
//   send     Ctrl+Enter in /lobby until the row shows (optimistic) and until it
//            is confirmed by the hub (no data-pending).
//   search   client-side route to /search?q=<Q> until results or "no results".
//
// Profiles: d1440 = 1440x900 on the box link; d1440-4g = the same on slow 4G;
// m390-4g = 390x844 phone (touch) on slow 4G with the CPU 4x slower. Slow 4G is
// Lighthouse's mobile profile: 150 ms RTT, 1.6 Mbps down, 750 kbps up.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [N=5] [PROFILES=d1440,d1440-4g,m390-4g] [Q=perf] [SEND=1] [WATERFALL=0] \
//     [LOCAL_MAP=127.0.0.1:8443] [USER_DATA_DIR=<dir>] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/perf-baseline-live.proof.mjs
//
// LOCAL_MAP A/Bs an undeployed bundle: Chrome resolves the BASE host to that
// address, where tests/e2e/lib/serve-hosting-h2.mjs serves the bundle. The page
// keeps its real origin (hub CORS, session cookie), only the static files differ.
//
// SEND=1 writes one message per round, so it refuses unless the page host AND
// the session claim are both TENANT (a proof on a tenant host writes into the
// host's tenant, not the claim's). The password is read from PW_FILE and never
// printed. Output: OUT/baseline.json (every sample) and a p50/p95 table on
// stdout. Exit 0 unless sign-in fails (a measurement, not a gate).
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const N = Number(process.env.N || 5)
const Q = process.env.Q || 'perf'
const SEND = process.env.SEND !== '0'
const WATERFALL = process.env.WATERFALL === '1'
const PROFILES = (process.env.PROFILES || 'd1440,d1440-4g,m390-4g').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const SLOW_4G = { offline: false, latency: 150, downloadThroughput: (1.6 * 1024 * 1024) / 8, uploadThroughput: (750 * 1024) / 8 }
const PROFILE = {
  d1440: { vp: { width: 1440, height: 900 }, net: null, cpu: 1 },
  'd1440-4g': { vp: { width: 1440, height: 900 }, net: SLOW_4G, cpu: 1 },
  'm390-4g': { vp: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 3 }, net: SLOW_4G, cpu: 4 },
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)
const res = { base: BASE, tenant: TENANT, n: N, at: new Date().toISOString(), profiles: {} }

/** Every request of the page by CDP id; the websocket's handshake time; the document's start. */
function recorder(cdp) {
  let reqs = new Map()
  let navAt = 0
  cdp.on('Network.requestWillBeSent', (e) => {
    if (e.request.url.startsWith('data:')) return
    if (e.type === 'Document' && !navAt) navAt = e.timestamp
    reqs.set(e.requestId, { url: e.request.url, method: e.request.method, type: e.type, bytes: 0, cached: false, status: 0, t0: e.timestamp })
  })
  cdp.on('Network.webSocketCreated', (e) => reqs.set(e.requestId, { url: e.url, method: 'WS', type: 'WebSocket', bytes: 0, cached: false, status: 0, t0: 0 }))
  cdp.on('Network.webSocketWillSendHandshakeRequest', (e) => { const r = reqs.get(e.requestId); if (r) r.t0 = e.timestamp })
  cdp.on('Network.webSocketHandshakeResponseReceived', (e) => { const r = reqs.get(e.requestId); if (r) { r.status = e.response.status; r.t1 = e.timestamp } })
  cdp.on('Network.responseReceived', (e) => {
    const r = reqs.get(e.requestId); if (!r) return
    r.status = e.response.status
    r.cached = !!(e.response.fromDiskCache || e.response.fromMemoryCache || e.response.fromServiceWorker || e.response.fromPrefetchCache)
  })
  cdp.on('Network.requestServedFromCache', (e) => { const r = reqs.get(e.requestId); if (r) r.cached = true })
  cdp.on('Network.loadingFinished', (e) => { const r = reqs.get(e.requestId); if (r) { r.bytes = e.encodedDataLength; r.t1 = e.timestamp } })
  return {
    take() { const out = { list: [...reqs.values()], navAt }; reqs = new Map(); navAt = 0; return out },
  }
}
const kindOf = (r) => {
  const u = new URL(r.url, BASE)
  if (r.type === 'WebSocket') return 'ws'
  if (u.pathname.endsWith('.js')) return 'js'
  if (u.pathname.endsWith('.css')) return 'css'
  if (/^\/(v1|api)\//.test(u.pathname) || u.host !== new URL(BASE).host) return 'api'
  return 'other'
}
/** /api/v1/tasks/7653a44f-... -> /api/v1/tasks/:id, so samples of one route group together. */
const routeOf = (r) => r.method + ' ' + new URL(r.url, BASE).pathname
  .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, ':id')
  .replace(/\/(HUM|BOX|CLE|GRK|AGY)-[0-9]+/g, '/:actor')
function netSummary({ list, navAt }) {
  const by = {}
  for (const r of list) {
    const k = kindOf(r)
    by[k] ??= { n: 0, kb: 0 }
    by[k].n++; by[k].kb += r.bytes / 1024
  }
  for (const k of Object.keys(by)) by[k].kb = Math.round(by[k].kb * 10) / 10
  const ws = list.find((r) => r.type === 'WebSocket' && r.t1)
  const api = list.filter((r) => kindOf(r) === 'api' && r.method !== 'OPTIONS' && r.t1).map((r) => ({ route: routeOf(r), ms: Math.round((r.t1 - r.t0) * 1000), status: r.status }))
  return {
    requests: list.length,
    kb: Math.round(list.reduce((a, r) => a + r.bytes, 0) / 102.4) / 10,
    by,
    preflights: list.filter((r) => r.method === 'OPTIONS').length,
    wsConnectMs: ws ? Math.round((ws.t1 - ws.t0) * 1000) : -1,
    wsOpenAtMs: ws && navAt ? Math.round((ws.t1 - navAt) * 1000) : -1,
    api,
    ...(WATERFALL ? { waterfall: list.map((r) => `${navAt || r.t0 ? Math.round((r.t0 - (navAt || list[0].t0)) * 1000) : '?'}..${r.t1 ? Math.round((r.t1 - (navAt || list[0].t0)) * 1000) : '?'}ms ${kindOf(r)}${r.cached ? '(cache)' : ''} ${r.status} ${Math.round(r.bytes / 102.4) / 10}KB ${r.method} ${r.url.replace(/^https?:\/\/[^/]+/, '')}`) } : {}),
  }
}
/** Page-side timings; long tasks come from the observer installed at document start. */
const vitals = (p) => p.evaluate(() => new Promise((resolve) => {
  const nav = performance.getEntriesByType('navigation')[0] || {}
  const fcp = performance.getEntriesByName('first-contentful-paint')[0]
  let lcp = 0
  try {
    new PerformanceObserver((l) => { for (const e of l.getEntries()) lcp = e.startTime }).observe({ type: 'largest-contentful-paint', buffered: true })
  } catch { /* unsupported */ }
  setTimeout(() => {
    const lt = window.__perfLong || []
    resolve({
      ttfb: Math.round(nav.responseStart || 0),
      dcl: Math.round(nav.domContentLoadedEventEnd || 0),
      load: Math.round(nav.loadEventEnd || 0),
      fcp: Math.round(fcp?.startTime || 0),
      lcp: Math.round(lcp),
      lastLongTaskEnd: Math.round(lt.reduce((a, e) => Math.max(a, e.end), 0)),
      tbt: Math.round(lt.reduce((a, e) => a + Math.max(0, e.dur - 50), 0)),
      longTasks: lt.length,
      domNodes: document.getElementsByTagName('*').length,
    })
  }, 300)
}))
const whenSel = (p, sel, timeout = 30000) => p.waitForFunction((s) => document.querySelector(s) ? performance.now() : 0, { timeout, polling: 'raf' }, sel)
  .then((h) => h.jsonValue()).catch(() => -1)
const routerPush = (p, path) => p.evaluate((to) => {
  const t = performance.now()
  document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to)
  return t
}, path)

const pct = (xs, q) => {
  const v = xs.filter((x) => typeof x === 'number' && x >= 0).sort((a, b) => a - b)
  if (!v.length) return null
  return v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)]
}

async function round(p, cdp, rec, prof, i, out) {
  const s = {}
  // cold
  await cdp.send('Network.clearBrowserCache')
  rec.take()
  await p.goto(BASE + '/lobby', { waitUntil: 'domcontentloaded', timeout: 90000 })
  const firstMsg = await whenSel(p, 'article.msg')
  await sleep(prof.net ? 5000 : 3000)
  const cv = await vitals(p)
  s.cold = { firstMsg: Math.round(firstMsg), tti: Math.max(Math.round(firstMsg), cv.lastLongTaskEnd), ...cv, ...netSummary(rec.take()) }
  // warm
  await p.goto(BASE + '/lobby', { waitUntil: 'domcontentloaded', timeout: 90000 })
  const firstMsgW = await whenSel(p, 'article.msg')
  await sleep(prof.net ? 4000 : 2500)
  const wv = await vitals(p)
  s.warm = { firstMsg: Math.round(firstMsgW), tti: Math.max(Math.round(firstMsgW), wv.lastLongTaskEnd), ...wv, ...netSummary(rec.take()) }
  // topic list
  let t0 = await routerPush(p, '/')
  let t1 = await whenSel(p, 'a.topic-row')
  s.list = { ms: t1 < 0 ? -1 : Math.round(t1 - t0), ...netSummary(rec.take()) }
  await sleep(1000)
  // open the first topic
  t0 = await p.evaluate(() => {
    document.querySelectorAll('[data-test=topic-section] article.msg').forEach((a) => a.setAttribute('data-perf-old', '1'))
    const a = document.querySelector('a.topic-row')
    if (!a) return -1
    const t = performance.now(); a.click(); return t
  })
  t1 = t0 < 0 ? -1 : await whenSel(p, '[data-test=topic-section] article.msg:not([data-perf-old])')
  s.open = { ms: t1 < 0 ? -1 : Math.round(t1 - t0), ...netSummary(rec.take()) }
  await sleep(1000)
  // send in the lobby
  if (SEND) {
    await routerPush(p, '/lobby')
    await whenSel(p, 'article.msg')
    const ta = await p.waitForSelector('form.composer textarea', { timeout: 15000 }).catch(() => null)
    if (ta) {
      await sleep(1500)
      const nonce = `perf probe ${out} r${i} ${run}`
      await ta.focus()
      await p.keyboard.type(nonce)
      rec.take()
      const shown = p.waitForFunction((t) => [...document.querySelectorAll('article.msg')].some((a) => a.textContent.includes(t)) ? Date.now() : 0,
        { polling: 'mutation', timeout: 20000 }, nonce).then((h) => h.jsonValue(), () => -1)
      const confirmed = p.waitForFunction((t) => [...document.querySelectorAll('article.msg:not([data-pending])')].some((a) => a.textContent.includes(t)) ? Date.now() : 0,
        { polling: 'mutation', timeout: 20000 }, nonce).then((h) => h.jsonValue(), () => -1)
      const ts = Date.now()
      await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
      const [a, b] = await Promise.all([shown, confirmed])
      await sleep(800)
      s.send = { shownMs: a < 0 ? -1 : a - ts, confirmedMs: b < 0 ? -1 : b - ts, ...netSummary(rec.take()) }
    } else s.send = { shownMs: -1, confirmedMs: -1, note: 'no composer' }
  }
  // search
  t0 = await routerPush(p, '/search?q=' + encodeURIComponent(Q))
  t1 = await whenSel(p, '[data-test=search-results], [data-test=search-empty], [data-test=search-bad-query]')
  s.search = { ms: t1 < 0 ? -1 : Math.round(t1 - t0), ...netSummary(rec.take()) }
  // cold / (the topic list is where a signed-in visit lands)
  await cdp.send('Network.clearBrowserCache')
  rec.take()
  await p.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 90000 })
  const firstRow = await whenSel(p, 'a.topic-row')
  await sleep(prof.net ? 4000 : 2500)
  const hv = await vitals(p)
  s.home = { firstRow: Math.round(firstRow), ...hv, ...netSummary(rec.take()) }
  return s
}

const puppeteer = await loadPuppeteer()
const LOCAL_MAP = process.env.LOCAL_MAP || ''
const chromeArgs = ['--no-sandbox']
if (LOCAL_MAP) chromeArgs.push(`--host-resolver-rules=MAP ${new URL(BASE).hostname} ${LOCAL_MAP}`, '--ignore-certificate-errors')
// USER_DATA_DIR keeps the session between runs: the hub allows 10 native
// sign-ins per email per 15 min, and an A/B of two bundles is several runs.
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: chromeArgs, ...(process.env.USER_DATA_DIR ? { userDataDir: process.env.USER_DATA_DIR } : {}) })
let failed = false
try {
  res.build = LOCAL_MAP ? { local: LOCAL_MAP } : await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  const ctx = process.env.USER_DATA_DIR ? browser.defaultBrowserContext() : await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument(() => {
    window.__perfLong = []
    try {
      new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__perfLong.push({ end: e.startTime + e.duration, dur: e.duration }) })
        .observe({ type: 'longtask', buffered: true })
    } catch { /* unsupported */ }
  })
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/lobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  const already = await p.waitForSelector('[data-test=user-menu-trigger], [data-test=native-auth-email]', { timeout: 45000 })
    .then((h) => h.evaluate((e) => e.matches('[data-test=user-menu-trigger]'))).catch(() => false)
  res.signIn = already ? 'kept' : 'native'
  if (!already) {
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
    await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    if (!(await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null))) throw new Error('sign-in failed at ' + p.url())
  }
  await sleep(1500)
  const claimT = await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value.session?.claims?.t || '')
  const hostT = new URL(BASE).hostname.split('.')[0]
  res.guard = { claim: claimT, host: hostT }
  if (SEND && (claimT !== TENANT || hostT !== TENANT)) throw new Error(`refusing SEND: claim t=${claimT} host=${hostT} but TENANT=${TENANT}`)

  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  const rec = recorder(cdp)
  for (const name of PROFILES) {
    const prof = PROFILE[name]
    if (!prof) { console.error('unknown profile', name); continue }
    await p.setViewport(prof.vp)
    await cdp.send('Network.emulateNetworkConditions', prof.net || { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: prof.cpu })
    const samples = []
    for (let i = 0; i < N; i++) {
      try { samples.push(await round(p, cdp, rec, prof, i, name)) } catch (e) { samples.push({ error: String(e?.message || e) }); console.log('round error', name, i, e?.message) }
      console.log(name, 'round', i, JSON.stringify({ fcp: samples.at(-1).cold?.fcp, msg: samples.at(-1).cold?.firstMsg, send: samples.at(-1).send?.confirmedMs }))
    }
    res.profiles[name] = samples
  }
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 })
} catch (e) {
  failed = true
  res.error = String((e && e.message) || e)
  console.log('FAIL', res.error)
} finally {
  await browser.close()
}

// summary: p50 / p95 per metric per profile, and per API route over every phase
const METRICS = [
  ['cold TTFB', (s) => s.cold?.ttfb], ['cold FCP', (s) => s.cold?.fcp], ['cold LCP', (s) => s.cold?.lcp],
  ['cold first msg', (s) => s.cold?.firstMsg], ['cold TTI', (s) => s.cold?.tti], ['cold TBT', (s) => s.cold?.tbt],
  ['cold JS KB', (s) => s.cold?.by?.js?.kb], ['cold CSS KB', (s) => s.cold?.by?.css?.kb], ['cold total KB', (s) => s.cold?.kb],
  ['cold API KB', (s) => s.cold?.by?.api?.kb], ['list API KB', (s) => s.list?.by?.api?.kb], ['open API KB', (s) => s.open?.by?.api?.kb],
  ['cold requests', (s) => s.cold?.requests], ['cold api requests', (s) => s.cold?.by?.api?.n], ['cold preflights', (s) => s.cold?.preflights],
  ['ws connect', (s) => s.cold?.wsConnectMs], ['ws open after nav', (s) => s.cold?.wsOpenAtMs],
  ['warm FCP', (s) => s.warm?.fcp], ['warm first msg', (s) => s.warm?.firstMsg], ['warm KB', (s) => s.warm?.kb], ['warm requests', (s) => s.warm?.requests],
  ['cold / FCP', (s) => s.home?.fcp], ['cold / first topic row', (s) => s.home?.firstRow], ['cold / TBT', (s) => s.home?.tbt],
  ['topic list', (s) => s.list?.ms], ['open topic', (s) => s.open?.ms],
  ['send shown', (s) => s.send?.shownMs], ['send confirmed', (s) => s.send?.confirmedMs], ['search', (s) => s.search?.ms],
]
const summary = {}
for (const [name, samples] of Object.entries(res.profiles)) {
  summary[name] = {}
  for (const [label, f] of METRICS) {
    const xs = samples.map(f)
    summary[name][label] = { p50: pct(xs, 0.5), p95: pct(xs, 0.95), n: xs.filter((x) => typeof x === 'number' && x >= 0).length }
  }
  const routes = {}
  for (const s of samples) for (const ph of ['cold', 'warm', 'home', 'list', 'open', 'send', 'search']) for (const a of s[ph]?.api || []) (routes[a.route] ??= []).push(a.ms)
  summary[name].api = Object.fromEntries(Object.entries(routes).sort().map(([r, xs]) => [r, { p50: pct(xs, 0.5), p95: pct(xs, 0.95), n: xs.length }]))
}
res.summary = summary
writeFileSync(`${OUT}/baseline.json`, JSON.stringify(res, null, 1))
console.log('build', JSON.stringify(res.build || {}))
const names = Object.keys(summary)
console.log(`| metric | ${names.map((n) => `${n} p50 / p95`).join(' | ')} |`)
console.log(`|---|${names.map(() => '---|').join('')}`)
for (const [label] of METRICS) console.log(`| ${label} | ${names.map((n) => { const m = summary[n][label]; return m.p50 === null ? '-' : `${m.p50} / ${m.p95} (n=${m.n})` }).join(' | ')} |`)
for (const n of names) {
  console.log(`\n${n} API (client-observed ms, all phases)`)
  for (const [r, m] of Object.entries(summary[n].api)) console.log(`  ${r}  p50=${m.p50} p95=${m.p95} n=${m.n}`)
}
process.exit(failed ? 1 : 0)
