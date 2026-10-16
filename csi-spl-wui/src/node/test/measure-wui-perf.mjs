#!/usr/bin/env node
// measure-wui-perf.mjs — page metrics of a generated WUI bundle, desktop and
// mobile, n samples per route, median shown (perf round 6 row 12, SPL-2051).
//
// WHY: round 6's baseline came from a session-scratch script no other seat
// could run (`git ls-files | grep -c measure-wui-perf` -> 0), and the mock
// tenant is too small to show rows 06, 08, 09 and 10 at all. This runner is
// the committed harness: it serves the bundle on a free port, seeds the large
// tenant of perf-fixture.mjs, drives headless Chrome over CDP and prints one
// table a later row can rerun on its own sha and diff.
//
// Per route x profile x sample: a fresh browser context; CDP
// Performance.enable and Emulation.setCPUThrottlingRate; observers for
// largest-contentful-paint and longtask; goto networkidle0, then +500 ms; then
//   FP, FCP   paint entries
//   LCP       the last largest-contentful-paint entry
//   TTI       end of the last long task, or FCP when there is none (a lab
//             proxy: the page is quiet from there to the read)
//   TBT       sum of max(0, duration - 50) over every long task
//   DOM       document.getElementsByTagName('*').length
//   Layout, Script   Performance.getMetrics LayoutDuration / ScriptDuration
// Profiles: desktop = 1440x900, no throttle; mobile = 390x844, touch,
// 4x CPU, iPhone UA. Absolute ms follow box load (the header prints it):
// compare two shas on the same box in the same hour, never against a table
// taken elsewhere.
//
// Build the mock bundle first (the fixture extends the mock tenant):
//   NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate
// Usage (from the repo root or csi-spl-wui):
//   node csi-spl-wui/src/node/test/measure-wui-perf.mjs
//     [--root <bundle dir>]     default csi-spl-wui/.output/public
//     [--n 3] [--routes /,/issues] [--profiles desktop,mobile]
//     [--no-fixture]            measure the plain mock tenant
//     [--json <file>]           also write every sample as JSON
// Exit: 0 table printed; 1 a sample or the fixture check failed; 2 usage /
// no bundle. CHROME_PATH (default /usr/bin/google-chrome), PUPPETEER_CORE.
import { spawn, execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { loadavg } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { PERF_FIXTURE, perfStorage, isMockChannelsChunk, patchMockChannels } from './perf-fixture.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SETTLE_MS = 500

export const ROUTES = ['/', '/login', '/channel/alerts', '/issues', '/workspace/docs']
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
export const PROFILES = {
  desktop: { viewport: { width: 1440, height: 900, deviceScaleFactor: 1 }, cpu: 1, ua: '' },
  mobile: { viewport: { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true }, cpu: 4, ua: IPHONE_UA },
}
export const METRICS = ['fp', 'fcp', 'lcp', 'tti', 'tbt', 'dom', 'layout', 'script']

/** argv -> options; throws on a bad flag or value. */
export function parseArgs(argv) {
  const opt = { root: join(WUI, '.output/public'), n: 3, routes: ROUTES, profiles: Object.keys(PROFILES), fixture: true, json: '' }
  const list = (v) => String(v || '').split(',').map((s) => s.trim()).filter(Boolean)
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i] }
    if (a === '--root') opt.root = resolve(val())
    else if (a === '--n') opt.n = Number(val())
    else if (a === '--routes') opt.routes = list(val())
    else if (a === '--profiles') opt.profiles = list(val())
    else if (a === '--json') opt.json = resolve(val())
    else if (a === '--no-fixture') opt.fixture = false
    else throw new Error(`unknown flag ${a}`)
  }
  if (!Number.isInteger(opt.n) || opt.n < 1) throw new Error('--n must be a whole number >= 1')
  for (const p of opt.profiles) if (!PROFILES[p]) throw new Error(`unknown profile ${p} (${Object.keys(PROFILES).join(', ')})`)
  for (const r of opt.routes) if (!r.startsWith('/')) throw new Error(`route ${r} must start with /`)
  if (!opt.routes.length || !opt.profiles.length) throw new Error('no route or no profile to measure')
  return opt
}

/** The middle value (odd n) or the rounded mean of the two middle values. */
export function median(values) {
  const s = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b)
  if (!s.length) return NaN
  const mid = Math.floor(s.length / 2)
  return s.length % 2 ? s[mid] : Math.round((s[mid - 1] + s[mid]) / 2)
}

/** Lab metrics from one page read: paint + LCP entries, long tasks, CDP durations (s). */
export function metricsOf(read, cdp) {
  const tasks = read.longtasks || []
  const fcp = Math.round(read.fcp)
  const lastEnd = tasks.reduce((m, t) => Math.max(m, t.start + t.duration), 0)
  return {
    fp: Math.round(read.fp),
    fcp,
    lcp: Math.round(read.lcp || read.fcp),
    tti: Math.round(Math.max(fcp, lastEnd)),
    tbt: Math.round(tasks.reduce((s, t) => s + Math.max(0, t.duration - 50), 0)),
    dom: read.dom,
    layout: Math.round((cdp.LayoutDuration || 0) * 1000),
    script: Math.round((cdp.ScriptDuration || 0) * 1000),
  }
}

/** One markdown table: a row per profile x route, medians, then each sample's FCP/LCP/TBT/DOM. */
export function renderTable(samples) {
  const head = ['profile', 'route (landed)', 'FP', 'FCP', 'LCP', 'TTI', 'TBT', 'DOM', 'Layout ms', 'Script ms', 'raw FCP/LCP/TBT/DOM']
  const lines = [`| ${head.join(' | ')} |`, `|${head.map(() => '---').join('|')}|`]
  const groups = new Map()
  for (const s of samples) {
    const k = `${s.profile} ${s.route}`
    if (!groups.has(k)) groups.set(k, [])
    groups.get(k).push(s)
  }
  for (const rows of groups.values()) {
    const { profile, route, landed } = rows[0]
    const med = METRICS.map((m) => median(rows.map((r) => r.m[m])))
    const raw = rows.map((r) => `${r.m.fcp}/${r.m.lcp}/${r.m.tbt}/${r.m.dom}`).join(' ')
    const where = landed && landed !== route ? `\`${route}\` (\`${landed}\`)` : `\`${route}\``
    lines.push(`| ${profile} | ${where} | ${med.join(' | ')} | ${raw} |`)
  }
  return lines.join('\n')
}

/** The one mock-data chunk under <root>/_nuxt the fixture patches: { name, body }. */
export function findMockChunk(root) {
  const dir = join(root, '_nuxt')
  const hits = readdirSync(dir).filter((f) => f.endsWith('.js') && isMockChannelsChunk(readFileSync(join(dir, f), 'utf8')))
  if (hits.length !== 1) throw new Error(`perf fixture: ${hits.length} mock-data chunk(s) under ${dir}; build with NUXT_PUBLIC_USE_MOCK=1`)
  return { name: hits[0], body: patchMockChannels(readFileSync(join(dir, hits[0]), 'utf8')) }
}

function freePort() {
  return new Promise((ok, fail) => {
    const s = createServer()
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => ok(port)) })
    s.on('error', fail)
  })
}

/* the signed-out auth stub wui-e2e-mock-api.py gives the e2e bundle, so
   /api/** answers JSON instead of the SPA fallback's HTML */
function startStubApi(port) {
  const srv = createServer((req, res) => {
    const p = String(req.url || '').split('?')[0]
    const send = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(body) }
    if (p === '/api/v1/auth/session') return send(401, '{"error":"unauthenticated"}')
    if (p === '/api/v1/auth/providers') return send(200, '{"native":false,"providers":[]}')
    return send(404, '{"error":"not_found"}')
  })
  return new Promise((ok) => srv.listen(port, '127.0.0.1', () => ok(srv)))
}

async function waitHttp(url, ms) {
  for (const t0 = Date.now(); Date.now() - t0 < ms;) {
    try { if ((await fetch(url, { redirect: 'manual' })).status < 500) return } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 250))
  }
  throw new Error(`bundle not serving at ${url}`)
}

/** serve-generated.mjs on a free port with the stub API beside it: { base, stop }. */
async function serveBundle(root) {
  const [webPort, apiPort] = [await freePort(), await freePort()]
  const api = await startStubApi(apiPort)
  const child = spawn(process.execPath, [join(__dirname, 'serve-generated.mjs'), '--root', root, '--port', String(webPort), '--api', `http://127.0.0.1:${apiPort}`], { stdio: 'ignore' })
  const stop = () => { child.kill(); api.close() }
  try {
    await waitHttp(`http://127.0.0.1:${webPort}/login`, 30000)
  } catch (e) { stop(); throw e }
  return { base: `http://127.0.0.1:${webPort}`, stop }
}

async function launch() {
  const require = createRequire(import.meta.url)
  const spec = process.env.PUPPETEER_CORE || 'puppeteer-core'
  const mod = await import(spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href)
  return (mod.default ?? mod).launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--force-device-scale-factor=1'],
  })
}

/* runs in the page before its own scripts: the fixture's storage and the observers */
function pageInit(storage) {
  try { for (const [k, v] of Object.entries(storage || {})) localStorage.setItem(k, v) } catch { /* opaque origin */ }
  const perf = (window.__perf = { lcp: 0, longtasks: [] })
  new PerformanceObserver((l) => { for (const e of l.getEntries()) perf.lcp = e.startTime }).observe({ type: 'largest-contentful-paint', buffered: true })
  new PerformanceObserver((l) => { for (const e of l.getEntries()) perf.longtasks.push({ start: e.startTime, duration: e.duration }) }).observe({ type: 'longtask', buffered: true })
}

function pageRead() {
  const paint = (n) => performance.getEntriesByName(n)[0]?.startTime || 0
  return { fp: paint('first-paint'), fcp: paint('first-contentful-paint'), lcp: window.__perf.lcp, longtasks: window.__perf.longtasks,
    dom: document.getElementsByTagName('*').length, landed: location.pathname, width: innerWidth }
}

/* CDP Fetch serves the patched mock-data chunk; every other request goes straight through */
async function servePatchedChunk(cdp, chunk) {
  await cdp.send('Fetch.enable', { patterns: [{ urlPattern: `*/_nuxt/${chunk.name}*` }] })
  const body = Buffer.from(chunk.body).toString('base64')
  cdp.on('Fetch.requestPaused', (ev) => {
    cdp.send('Fetch.fulfillRequest', { requestId: ev.requestId, responseCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'text/javascript; charset=utf-8' }], body })
      .catch(() => { /* the context closed mid-request; that sample's own read fails instead */ })
  })
}

/** One cold load of `route` under `profile` in a fresh context: { landed, m }. */
async function sample(browser, base, route, profile, fx) {
  const ctx = await browser.createBrowserContext()
  try {
    const page = await ctx.newPage()
    const prof = PROFILES[profile]
    await page.setViewport(prof.viewport)
    if (prof.ua) await page.setUserAgent(prof.ua)
    const cdp = await page.createCDPSession()
    await cdp.send('Performance.enable')
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: prof.cpu })
    if (fx) await servePatchedChunk(cdp, fx.chunk)
    await page.evaluateOnNewDocument(pageInit, fx ? fx.storage : {})
    await page.goto(base + route, { waitUntil: 'networkidle0', timeout: NAV_TIMEOUT })
    await new Promise((r) => setTimeout(r, SETTLE_MS))
    const read = await page.evaluate(pageRead)
    if (read.width !== prof.viewport.width) throw new Error(`viewport not applied: innerWidth ${read.width}, wanted ${prof.viewport.width}`)
    const cdpm = Object.fromEntries((await cdp.send('Performance.getMetrics')).metrics.map((x) => [x.name, x.value]))
    return { landed: read.landed, m: metricsOf(read, cdpm) }
  } finally {
    await ctx.close()
  }
}

/* the rows /issues lists once every Load more (ISSUE_PAGE each) is taken */
async function loadAllIssues(page) {
  const rows = () => page.$$eval('[data-test=issues-row]', (els) => els.length)
  for (let i = 0; i < 50; i++) {
    const before = await rows()
    const more = await page.$('[data-test=issues-load-more]:not([disabled])')
    if (!more) return before
    await more.click()
    await page.waitForFunction((n) => document.querySelectorAll('[data-test=issues-row]').length > n, { timeout: 10000 }, before)
  }
  return rows()
}

/* proves the large tenant is the one measured: channels in the sidebar, cards in #alerts, issues listed */
async function fixtureCheck(browser, base, fx) {
  const ctx = await browser.createBrowserContext()
  try {
    const page = await ctx.newPage()
    await page.setViewport(PROFILES.desktop.viewport)
    if (fx) await servePatchedChunk(await page.createCDPSession(), fx.chunk)
    await page.evaluateOnNewDocument(pageInit, fx ? fx.storage : {})
    const count = async (route, sel) => {
      await page.goto(base + route, { waitUntil: 'networkidle0', timeout: NAV_TIMEOUT })
      return page.$$eval(sel, (els) => els.length)
    }
    const alerts = await count('/channel/alerts', 'article.msg')
    const channels = await page.$$eval('a[href^="/channel/perf-"]', (els) => new Set(els.map((e) => e.getAttribute('href'))).size)
    const rows = await count('/issues', '[data-test=issues-row]')
    return { channels, alerts, rows, issues: await loadAllIssues(page) }
  } finally {
    await ctx.close()
  }
}

function header(opt, fx) {
  let sha = 'unknown'
  try { sha = execFileSync('git', ['-C', WUI, 'rev-parse', '--short=9', 'HEAD'], { encoding: 'utf8' }).trim() } catch { /* not a checkout */ }
  const tenant = fx ? `fixture ${PERF_FIXTURE.issues} issues, ${PERF_FIXTURE.messages} feed messages, +${PERF_FIXTURE.channels} channels` : 'plain mock tenant'
  return `measure-wui-perf: sha ${sha}, n=${opt.n} per route, median; ${tenant}; load ${loadavg().map((l) => l.toFixed(2)).join(' ')}`
}

/* the fixture check, then every profile x route x sample; returns the failure count */
async function measureAll(browser, base, opt, fx, samples) {
  let failed = 0
  const seen = await fixtureCheck(browser, base, fx)
  console.log(`tenant seen: ${seen.channels} perf channel(s) in the sidebar, ${seen.alerts} card(s) in #alerts, ${seen.issues} issue row(s) on /issues after every Load more (${seen.rows} painted first)`)
  const want = fx ? { channels: PERF_FIXTURE.channels, issues: PERF_FIXTURE.issues } : {}
  for (const [k, v] of Object.entries(want)) if (seen[k] !== v) { console.error(`FAIL fixture: ${seen[k]} ${k} seen, wanted ${v}`); failed++ }
  const runs = opt.profiles.flatMap((profile) => opt.routes.flatMap((route) => Array.from({ length: opt.n }, (_, i) => ({ profile, route, i }))))
  for (const { profile, route, i } of runs) {
    try { samples.push({ profile, route, ...(await sample(browser, base, route, profile, fx)) }) } catch (e) { console.error(`FAIL ${profile} ${route} #${i + 1}: ${e.message}`); failed++ }
  }
  return failed
}

async function main() {
  let opt
  try { opt = parseArgs(process.argv.slice(2)) } catch (e) { console.error(`measure-wui-perf: ${e.message}`); return 2 }
  if (!existsSync(join(opt.root, '200.html'))) {
    console.error(`measure-wui-perf: no generated bundle at ${opt.root}; run NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate`)
    return 2
  }
  const fx = opt.fixture ? { chunk: findMockChunk(opt.root), storage: perfStorage() } : null
  const server = await serveBundle(opt.root)
  const browser = await launch()
  const samples = []
  let failed = 0
  try {
    console.log(header(opt, fx))
    failed = await measureAll(browser, server.base, opt, fx, samples)
  } finally {
    await browser.close()
    server.stop()
  }
  console.log(renderTable(samples))
  if (opt.json) writeFileSync(opt.json, JSON.stringify({ header: header(opt, fx), samples }, null, 2))
  return failed ? 1 : 0
}

if (import.meta.url === pathToFileURL(resolve(process.argv[1] || '')).href) {
  main().then((code) => process.exit(code), (e) => { console.error(`measure-wui-perf: ${e.stack || e}`); process.exit(1) })
}
