// CLE-77933 (owner topic 87eaa57b: "investigate whether or not something else
// could be decreased as well"). The repeatable NETWORK map of the first load
// on a DEPLOYED host: every request a fresh page makes from navigation start
// until the left rail shows (the Flow rail tab visible), and what it keeps
// fetching in the SETTLE ms after. Read-only: it loads and reads, never posts.
//
// ONE native sign-in (USER_DATA_DIR keeps the session between runs), then per
// PROFILE x CACHE, N rounds of a fresh page on /. Per round:
//
//   rail       ms from navigation start to the rail tab visible
//   before     requests started before the rail showed: count, KB on the wire
//              (encodedDataLength, so a cache hit reads ~0), per kind
//   after      the same for the SETTLE window after the rail
//   prefetch   requests made for a <link rel=prefetch> (Lowest priority, type Other)
//
// kinds: doc, js, css, font, img, i18n (locale JSON), api (hub), ws, other.
// CACHES: cold = HTTP cache cleared before every round; warm = kept.
// Profiles: d1440 = 1440x900 desktop; m390 = 390x844 phone (touch, CPU 4x).
// NET=fast4g emulates a 4G link (150 ms RTT, 9 Mbit/s down) for both.
//
//   BASE=https://<tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [N=10] [PROFILES=d1440,m390] [CACHES=cold,warm] [NET=none] \
//     [SETTLE=4000] [USER_DATA_DIR=<dir>] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/perf-first-load-net.timing.mjs
//
// The action csi-spl-orc `do_spl_wui_perf_first_load_net` runs it per env. Output:
// OUT/first-load-net.json (every request of every round), a median / p90 markdown
// table on stdout. Exit 0 unless the sign-in fails (a measurement, not a gate).
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
const N = Number(process.env.N || 10)
const SETTLE = Number(process.env.SETTLE || 4000)
const NET = process.env.NET || 'none'
const list = (k, d) => (process.env[k] || d).split(',').map((s) => s.trim()).filter(Boolean)
const PROFILES = list('PROFILES', 'd1440,m390')
const CACHES = list('CACHES', 'cold,warm')
mkdirSync(OUT, { recursive: true })

const PROFILE = {
  d1440: { vp: { width: 1440, height: 900 }, cpu: 1 },
  m390: { vp: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 3 }, cpu: 4 },
}
const NETS = {
  none: null,
  fast4g: { offline: false, latency: 150, downloadThroughput: 9e6 / 8, uploadThroughput: 1.5e6 / 8 },
}
const KINDS = ['doc', 'js', 'css', 'font', 'img', 'i18n', 'api', 'ws', 'other']
const RAIL = '[data-testid=sidebar-tab-flow]'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const host = new URL(BASE).host

function kindOf(r) {
  const u = new URL(r.url)
  if (r.type === 'WebSocket') return 'ws'
  if (r.type === 'Document') return 'doc'
  if (u.host !== host || /^\/api\//.test(u.pathname)) return 'api'
  const p = u.pathname
  if (/\/_i18n\/|\/locales?\//.test(p)) return 'i18n'
  if (p.endsWith('.js') || r.type === 'Script') return 'js'
  if (p.endsWith('.css') || r.type === 'Stylesheet') return 'css'
  if (/\.(woff2?|ttf|otf)$/.test(p) || r.type === 'Font') return 'font'
  if (/\.(png|jpe?g|gif|svg|ico|webp|avif)$/.test(p) || r.type === 'Image') return 'img'
  return 'other'
}

/** every request by CDP id: url, type, prefetch?, wire bytes, cache, start (wall s). */
function recorder(cdp) {
  let reqs = new Map()
  cdp.on('Network.requestWillBeSent', (e) => {
    if (e.request.url.startsWith('data:') || reqs.has(e.requestId)) return
    const h = Object.fromEntries(Object.entries(e.request.headers || {}).map(([k, v]) => [k.toLowerCase(), v]))
    reqs.set(e.requestId, {
      url: e.request.url, method: e.request.method, type: e.type || '', t0: e.wallTime ?? 0,
      prefetch: /prefetch/i.test(h['sec-purpose'] || h.purpose || '') || (e.request.initialPriority === 'Lowest' && e.type === 'Other'),
      priority: e.request.initialPriority, bytes: 0, status: 0, cache: '', encoding: '',
    })
  })
  cdp.on('Network.requestServedFromCache', (e) => { const r = reqs.get(e.requestId); if (r) r.cache = 'memory' })
  cdp.on('Network.responseReceived', (e) => {
    const r = reqs.get(e.requestId); if (!r) return
    r.status = e.response.status
    if (e.type) r.type = e.type
    if (e.response.fromDiskCache) r.cache = 'disk'
    if (e.response.fromPrefetchCache) r.cache = 'prefetch'
    if (e.response.fromServiceWorker) r.cache = 'sw'
    const hs = Object.fromEntries(Object.entries(e.response.headers || {}).map(([k, v]) => [k.toLowerCase(), v]))
    r.encoding = hs['content-encoding'] || ''
    r.cacheControl = hs['cache-control'] || ''
  })
  cdp.on('Network.loadingFinished', (e) => { const r = reqs.get(e.requestId); if (r) r.bytes = e.encodedDataLength })
  cdp.on('Network.webSocketCreated', (e) => reqs.set(e.requestId, { url: e.url, method: 'GET', type: 'WebSocket', t0: 0, bytes: 0, status: 101, cache: '', prefetch: false }))
  return { take() { const out = [...reqs.values()]; reqs = new Map(); return out } }
}

function tally(rs) {
  const by = Object.fromEntries(KINDS.map((k) => [k, { n: 0, kb: 0 }]))
  for (const r of rs) { const b = by[r.kind]; b.n++; b.kb += r.bytes / 1024 }
  for (const b of Object.values(by)) b.kb = Math.round(b.kb * 10) / 10
  return { n: rs.length, kb: Math.round(rs.reduce((a, r) => a + r.bytes, 0) / 102.4) / 10, by }
}

async function round(p, cdp, rec, cache) {
  if (cache === 'cold') await cdp.send('Network.clearBrowserCache')
  rec.take()
  await p.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 90000 })
  const rail = await p.waitForFunction((s) => {
    for (const el of document.querySelectorAll(s)) { const r = el.getBoundingClientRect(); if (r.width > 0 && r.height > 0) return performance.now() }
    return 0
  }, { timeout: 45000, polling: 'raf' }, RAIL).then((h) => h.jsonValue()).catch(() => -1)
  if (rail < 0) throw new Error('no rail at ' + p.url())
  const railWall = Date.now() / 1000
  await sleep(SETTLE)
  const all = rec.take().map((r) => {
    const u = new URL(r.url)
    return { ...r, kind: kindOf(r), path: u.host === host ? u.pathname : `${u.protocol}//${u.host}${u.pathname}` }
  })
  // a request whose start was seen before the rail is "before"; a WebSocket has no wallTime: before
  const isBefore = (r) => !r.t0 || r.t0 <= railWall
  const before = all.filter(isBefore)
  const after = all.filter((r) => !isBefore(r))
  return {
    rail: Math.round(rail),
    before: tally(before), after: tally(after),
    prefetch: tally(all.filter((r) => r.prefetch)),
    prefetchBefore: tally(before.filter((r) => r.prefetch)),
    requests: all.map((r) => ({
      path: r.path, kind: r.kind, type: r.type, kb: Math.round(r.bytes / 102.4) / 10, status: r.status, cache: r.cache,
      prefetch: r.prefetch, priority: r.priority, encoding: r.encoding, cacheControl: r.cacheControl, phase: isBefore(r) ? 'before' : 'after',
    })),
  }
}

const pct = (xs, q) => {
  const v = xs.filter((x) => typeof x === 'number' && x >= 0).sort((a, b) => a - b)
  if (!v.length) return null
  return v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)]
}
const mp = (xs) => [pct(xs, 0.5), pct(xs, 0.9)]

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'], ...(process.env.USER_DATA_DIR ? { userDataDir: process.env.USER_DATA_DIR } : {}) })
const res = { base: BASE, tenant: TENANT, n: N, net: NET, settleMs: SETTLE, at: new Date().toISOString(), runs: {} }
let failed = false
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  const ctx = process.env.USER_DATA_DIR ? browser.defaultBrowserContext() : await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 60000 })
  const already = await p.waitForSelector('[data-test=user-menu-trigger], [data-test=native-auth-email]', { timeout: 45000 })
    .then((h) => h.evaluate((e) => e.matches('[data-test=user-menu-trigger]'))).catch(() => false)
  res.signIn = already ? 'kept' : 'native'
  if (!already) {
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2F', { waitUntil: 'domcontentloaded', timeout: 60000 })
    await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    if (!(await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null))) throw new Error('sign-in failed at ' + p.url())
  }
  await sleep(1500)
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  if (NETS[NET]) await cdp.send('Network.emulateNetworkConditions', NETS[NET])
  const rec = recorder(cdp)
  for (const name of PROFILES) {
    const prof = PROFILE[name]
    if (!prof) { console.error('unknown profile', name); continue }
    await p.setViewport(prof.vp)
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: prof.cpu })
    for (const cache of CACHES) {
      const key = `${name}-${cache}`
      const samples = []
      for (let i = 0; i < N; i++) {
        try { samples.push(await round(p, cdp, rec, cache)) } catch (e) { samples.push({ error: String(e?.message || e) }) }
        const s = samples.at(-1)
        console.log(key, 'round', i, s.error ? 'ERROR ' + s.error
          : `rail=${s.rail}ms before=${s.before.n}req/${s.before.kb}KB after=${s.after.n}req/${s.after.kb}KB prefetch=${s.prefetch.n}`)
      }
      res.runs[key] = samples
    }
  }
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 })
} catch (e) {
  failed = true
  res.error = String((e && e.message) || e)
  console.log('FAIL', res.error)
} finally {
  await browser.close()
}

const summary = {}
for (const [key, samples] of Object.entries(res.runs)) {
  const ok = samples.filter((s) => !s.error)
  const col = (f) => mp(ok.map(f))
  summary[key] = {
    n: ok.length,
    rail: col((s) => s.rail),
    beforeN: col((s) => s.before.n), beforeKB: col((s) => s.before.kb),
    afterN: col((s) => s.after.n), afterKB: col((s) => s.after.kb),
    prefetchN: col((s) => s.prefetch.n), prefetchKB: col((s) => s.prefetch.kb), prefetchBeforeN: col((s) => s.prefetchBefore.n),
    kinds: Object.fromEntries(KINDS.map((k) => [k, { n: pct(ok.map((s) => s.before.by[k].n), 0.5), kb: pct(ok.map((s) => s.before.by[k].kb), 0.5) }])),
  }
}
res.summary = summary
writeFileSync(`${OUT}/first-load-net.json`, JSON.stringify(res, null, 1))
const b = res.build || {}
const keys = Object.keys(summary)
const fmt = (a) => (a[0] === null ? '-' : `${a[0]} / ${a[1]}`)
console.log(`build ${b.version || '?'} sha ${String(b.commit || b.sha || '?').slice(0, 8)} at ${BASE} net=${NET} settle=${SETTLE}ms`)
console.log(`| first load (median / p90) | ${keys.map((k) => `${k} (n=${summary[k].n})`).join(' | ')} |`)
console.log(`|---|${keys.map(() => '---|').join('')}`)
for (const [label, f] of [['rail visible ms', 'rail'], ['requests before rail', 'beforeN'], ['KB before rail (wire)', 'beforeKB'],
  [`requests in ${SETTLE} ms after`, 'afterN'], [`KB in ${SETTLE} ms after`, 'afterKB'],
  ['prefetch requests', 'prefetchN'], ['prefetch KB', 'prefetchKB'], ['prefetch before rail', 'prefetchBeforeN']]) {
  console.log(`| ${label} | ${keys.map((k) => fmt(summary[k][f])).join(' | ')} |`)
}
console.log('\nbefore the rail, per kind (median n / KB)')
console.log(`| kind | ${keys.join(' | ')} |`)
console.log(`|---|${keys.map(() => '---|').join('')}`)
for (const k of KINDS) console.log(`| ${k} | ${keys.map((x) => `${summary[x].kinds[k].n} / ${summary[x].kinds[k].kb}`).join(' | ')} |`)
process.exit(failed ? 1 : 0)
