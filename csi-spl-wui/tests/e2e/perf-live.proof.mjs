// CLE-34984 live performance proof of the WUI client against a deployed host:
// native sign-in through the WUI form, then, in one real Chrome,
//
//   cold    /lobby with the HTTP cache cleared: navigation timing, FCP, LCP,
//           time to the first rendered message, bytes and request count by
//           kind (script / css / api / ws / other).
//   warm    the same URL reloaded with the cache kept: what the browser still
//           downloads (a correct immutable /_nuxt/** header makes JS ~0).
//   routes  client-side route changes by clicking sidebar channel links:
//           click -> first message rendered, and the API reads each one fires.
//   feed    DOM size of the page and Chrome's own task/script/layout
//           durations (Performance.getMetrics) across the whole run.
//   dupes   the same METHOD+URL requested more than once inside one phase -
//           the network-waterfall defect this proof exists to catch.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [ROUTES=3] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/perf-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Numbers go to stdout
// and OUT/perf.json; the exit code is 0 unless sign-in or a page load fails
// (a measurement, not a gate).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const ROUTES = Number(process.env.ROUTES || 3)
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const res = { base: BASE, at: new Date().toISOString(), phases: {} }
let failed = false

/** Every request of the page, by CDP id, with its final size and cache source. */
function recorder(cdp) {
  let reqs = new Map()
  let base = 0
  cdp.on('Network.requestWillBeSent', (e) => {
    if (e.request.url.startsWith('data:')) return
    if (!base) base = e.timestamp
    reqs.set(e.requestId, { url: e.request.url, method: e.request.method, type: e.type, bytes: 0, cached: false, status: 0, at: Math.round((e.timestamp - base) * 1000) })
  })
  cdp.on('Network.webSocketCreated', (e) => reqs.set(e.requestId, { url: e.url, method: 'WS', type: 'WebSocket', bytes: 0, cached: false, status: 101 }))
  cdp.on('Network.responseReceived', (e) => {
    const r = reqs.get(e.requestId); if (!r) return
    r.status = e.response.status
    r.cached = !!(e.response.fromDiskCache || e.response.fromMemoryCache || e.response.fromServiceWorker || e.response.fromPrefetchCache)
  })
  cdp.on('Network.requestServedFromCache', (e) => { const r = reqs.get(e.requestId); if (r) r.cached = true })
  cdp.on('Network.loadingFinished', (e) => {
    const r = reqs.get(e.requestId); if (!r) return
    r.bytes = e.encodedDataLength
    if (base) r.end = Math.round((e.timestamp - base) * 1000)
  })
  return { take() { const out = [...reqs.values()]; reqs = new Map(); base = 0; return out } }
}

const kindOf = (r) => {
  const u = new URL(r.url, BASE)
  if (r.type === 'WebSocket') return 'ws'
  if (u.pathname.startsWith('/_nuxt/') && u.pathname.endsWith('.js')) return 'script'
  if (u.pathname.endsWith('.css')) return 'css'
  if (/^\/(v1|api)\//.test(u.pathname) || u.host !== new URL(BASE).host) return 'api'
  return 'other'
}
function summarise(list) {
  const by = {}
  for (const r of list) {
    const k = kindOf(r)
    by[k] ??= { n: 0, bytes: 0, cached: 0 }
    by[k].n++; by[k].bytes += r.bytes; if (r.cached) by[k].cached++
  }
  const seen = new Map()
  for (const r of list) {
    // a memory-cache hit (modulepreload then import) costs no network
    if (r.method === 'OPTIONS' || r.cached) continue
    const key = r.method + ' ' + r.url
    seen.set(key, (seen.get(key) || 0) + 1)
  }
  const strip = (u) => u.replace(/^https?:\/\/[^/]+/, '')
  const dupes = [...seen].filter(([, n]) => n > 1).map(([k, n]) => ({ req: k.replace(/^(\w+ )https?:\/\/[^/]+/, '$1'), n }))
  const api = list.filter((r) => kindOf(r) === 'api' && r.method !== 'OPTIONS').map((r) => `${r.at}..${r.end ?? '?'}ms ${r.method} ${strip(r.url)} ${r.status}`)
  const preflights = list.filter((r) => r.method === 'OPTIONS').length
  const waterfall = list.map((r) => `${r.at}..${r.end ?? '?'}ms ${kindOf(r)}${r.cached ? '(cache)' : ''} ${r.method} ${strip(r.url)} ${r.status}`)
  return { requests: list.length, totalKB: Math.round(list.reduce((a, r) => a + r.bytes, 0) / 102.4) / 10, by, preflights, dupes, api, waterfall }
}
const vitals = (p) => p.evaluate(() => new Promise((resolve) => {
  const nav = performance.getEntriesByType('navigation')[0] || {}
  const fcp = performance.getEntriesByName('first-contentful-paint')[0]
  let lcp = 0
  try {
    new PerformanceObserver((l) => { for (const e of l.getEntries()) lcp = e.startTime }).observe({ type: 'largest-contentful-paint', buffered: true })
  } catch { /* unsupported */ }
  setTimeout(() => resolve({
    ttfb: Math.round(nav.responseStart || 0),
    domContentLoaded: Math.round(nav.domContentLoadedEventEnd || 0),
    load: Math.round(nav.loadEventEnd || 0),
    fcp: Math.round(fcp?.startTime || 0),
    lcp: Math.round(lcp),
    domNodes: document.getElementsByTagName('*').length,
    msgs: document.querySelectorAll('article.msg').length,
  }), 300)
}))
/** performance.now() in the page when the first article.msg exists (-1 = never). */
const firstMsgAt = (p, timeout = 20000) => p.waitForFunction(() => document.querySelector('article.msg') ? performance.now() : 0, { timeout, polling: 'raf' })
  .then((h) => h.jsonValue()).catch(() => -1)

try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  await cdp.send('Performance.enable')
  const rec = recorder(cdp)

  // sign in (not measured)
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'domcontentloaded', timeout: 60000 })
  const form = await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 }).catch(() => null)
  if (!form) {
    await p.screenshot({ path: `${OUT}/login-missing.png` }).catch(() => {})
    throw new Error('no sign-in form at ' + p.url())
  }
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  if (!signed) throw new Error('sign-in failed at ' + p.url())
  await sleep(1500)
  rec.take()

  // cold
  await cdp.send('Network.clearBrowserCache')
  await p.goto(BASE + '/lobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  const firstMsg = await firstMsgAt(p)
  await sleep(3000)
  res.phases.cold = { firstMsgMs: Math.round(firstMsg), ...(await vitals(p)), ...summarise(rec.take()) }

  // warm
  await p.goto(BASE + '/lobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  const firstMsgWarm = await firstMsgAt(p)
  await sleep(3000)
  res.phases.warm = { firstMsgMs: Math.round(firstMsgWarm), ...(await vitals(p)), ...summarise(rec.take()) }

  // routes: click sidebar channel links, client-side
  const hrefs = await p.$$eval('a.nav-item[href*="/channel/"]', (as) => as.map((a) => a.getAttribute('href')))
  res.phases.routes = []
  for (const href of hrefs.slice(0, ROUTES)) {
    const el = await p.$(`a.nav-item[href="${href}"]`)
    if (!el) continue
    const clickAt = await p.evaluate(() => {
      document.querySelectorAll('article.msg').forEach((a) => a.setAttribute('data-perf-old', '1'))
      return performance.now()
    })
    await el.evaluate((a) => a.click())
    const shown = await p.waitForFunction(() => document.querySelector('article.msg:not([data-perf-old])') ? performance.now() : 0,
      { timeout: 15000, polling: 'raf' }).then((h) => h.jsonValue()).catch(() => -1)
    await sleep(2500)
    const s = summarise(rec.take())
    res.phases.routes.push({ href, clickToMsgMs: shown < 0 ? -1 : Math.round(shown - clickAt), msgs: await p.$$eval('article.msg', (a) => a.length), ...s })
  }
  const m = Object.fromEntries((await cdp.send('Performance.getMetrics')).metrics.map((x) => [x.name, x.value]))
  res.phases.metrics = {
    TaskDurationS: +m.TaskDuration.toFixed(2), ScriptDurationS: +m.ScriptDuration.toFixed(2),
    LayoutDurationS: +m.LayoutDuration.toFixed(2), RecalcStyleDurationS: +m.RecalcStyleDuration.toFixed(2),
    JSHeapUsedMB: +(m.JSHeapUsedSize / 1048576).toFixed(1), Nodes: m.Nodes,
  }
} catch (e) {
  failed = true
  res.error = String((e && e.message) || e)
  console.log('FAIL', res.error)
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/perf.json`, JSON.stringify(res, null, 1))
const c = res.phases.cold, w = res.phases.warm
if (c) console.log(`cold  ttfb=${c.ttfb} fcp=${c.fcp} lcp=${c.lcp} dcl=${c.domContentLoaded} firstMsg=${c.firstMsgMs} msgs=${c.msgs} nodes=${c.domNodes} req=${c.requests} ${c.totalKB}KB by=${JSON.stringify(c.by)} preflights=${c.preflights} dupes=${JSON.stringify(c.dupes)}`)
if (w) console.log(`warm  fcp=${w.fcp} firstMsg=${w.firstMsgMs} req=${w.requests} ${w.totalKB}KB by=${JSON.stringify(w.by)} dupes=${JSON.stringify(w.dupes)}`)
for (const r of res.phases.routes || []) console.log(`route ${r.href} click->msg=${r.clickToMsgMs} msgs=${r.msgs} req=${r.requests} api=${r.api.length} preflights=${r.preflights} dupes=${JSON.stringify(r.dupes)}`)
if (res.phases.metrics) console.log('metrics', JSON.stringify(res.phases.metrics))
console.log('build', JSON.stringify(res.build || {}))
process.exit(failed ? 1 : 0)
