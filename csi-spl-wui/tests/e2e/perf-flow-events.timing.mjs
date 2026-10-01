// CLE-77914 (owner topic 73c9704c: "the clicking on the flow and the loading
// of the events is really slow"; "some kind of optimization e2e must be
// performed with empiric evidence for the performed changes"). The repeatable
// timing e2e every Flow / Event log perf change is measured with, against a
// DEPLOYED host. Read-only: it clicks and reads, it never posts.
//
// ONE native sign-in (the hub allows 10 per email per 15 min; USER_DATA_DIR
// keeps the session between runs), then per PROFILE, N rounds of:
//
//   flow-cold    a fresh page (/, HTTP cache kept): click the Flow rail tab
//                until the first Flow entry is painted - the store's first read.
//   flow-open    click the Nth Flow entry until the opened message is shown
//                and marked in its original place (open-focus class);
//                flow-open-shown = until it is first on screen, unmarked.
//   flow-warm    Back, another rail tab, then Flow again: until the entries show.
//   events-tab   click the Event log rail tab until its "Event log" link shows.
//   events-paint click that link until the /events page shell is painted (a
//                phone's rail tab opens /events itself: timed from the tab).
//   events-full  ... until its table, empty line or error is painted.
//   events-warm  Back, then click the link again: until full.
//
// Each step also records the API reads it fired (route, client ms, KB) and
// its resource timeline relative to the click (start..end ms).
// Profiles: d1440 = 1440x900 desktop; m390 = 390x844 phone (touch, CPU 4x).
// COLD_CACHE=1 clears the HTTP cache before each round's fresh page.
//
//   BASE=https://<tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [N=10] [PROFILES=d1440,m390] [COLD_CACHE=0] [USER_DATA_DIR=<dir>] \
//     [LOCAL_MAP=127.0.0.1:8443] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/perf-flow-events.timing.mjs
//
// The action csi-spl-orc `do_spl_wui_perf_flow_events` runs it per env. The
// password is read from PW_FILE and never printed. Output: OUT/timing.json
// (every sample), a median / p90 markdown table on stdout. Exit 0 unless the
// sign-in fails (a measurement, not a gate).
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
const COLD_CACHE = process.env.COLD_CACHE === '1'
const PROFILES = (process.env.PROFILES || 'd1440,m390').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const PROFILE = {
  d1440: { vp: { width: 1440, height: 900 }, cpu: 1 },
  m390: { vp: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 3 }, cpu: 4 },
}
const STEPS = ['flow-cold', 'flow-open-shown', 'flow-open', 'flow-warm', 'events-tab', 'events-paint', 'events-full', 'events-warm']

/** a step's ms; flow-open-shown is the flow-open sample's first-on-screen time */
const msOf = (s, k) => (k === 'flow-open-shown' ? s['flow-open']?.shownMs : s[k]?.ms)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, tenant: TENANT, n: N, coldCache: COLD_CACHE, at: new Date().toISOString(), profiles: {} }

/** API reads by CDP id: route, client-observed ms, encoded KB. */
function recorder(cdp) {
  let reqs = new Map()
  cdp.on('Network.requestWillBeSent', (e) => {
    if (e.request.url.startsWith('data:')) return
    reqs.set(e.requestId, { url: e.request.url, method: e.request.method, type: e.type, bytes: 0, status: 0, t0: e.timestamp })
  })
  cdp.on('Network.responseReceived', (e) => { const r = reqs.get(e.requestId); if (r) r.status = e.response.status })
  cdp.on('Network.loadingFinished', (e) => { const r = reqs.get(e.requestId); if (r) { r.bytes = e.encodedDataLength; r.t1 = e.timestamp } })
  return { take() { const out = [...reqs.values()]; reqs = new Map(); return out } }
}
const isApi = (r) => { const u = new URL(r.url, BASE); return /^\/(v1|api)\//.test(u.pathname) || u.host !== new URL(BASE).host }
const routeOf = (r) => r.method + ' ' + new URL(r.url, BASE).pathname
  .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, ':id')
  .replace(/\/(HUM|BOX|CLE|GRK|AGY|QWN)-[0-9]+/g, '/:actor')
function net(list) {
  const api = list.filter((r) => isApi(r) && r.type !== 'WebSocket' && r.method !== 'OPTIONS')
  const js = list.filter((r) => new URL(r.url, BASE).pathname.endsWith('.js'))
  return {
    api: api.map((r) => ({ route: routeOf(r), ms: r.t1 ? Math.round((r.t1 - r.t0) * 1000) : -1, kb: Math.round(r.bytes / 102.4) / 10, status: r.status })),
    jsN: js.length,
    jsKB: Math.round(js.reduce((a, r) => a + r.bytes, 0) / 102.4) / 10,
  }
}

/** performance.now() once a VISIBLE element matches `sel`; -1 on timeout. */
const whenSel = (p, sel, timeout = 30000) => p.waitForFunction((s) => {
  for (const el of document.querySelectorAll(s)) {
    const r = el.getBoundingClientRect()
    if (r.width > 0 && r.height > 0) return performance.now()
  }
  return 0
}, { timeout, polling: 'raf' }, sel).then((h) => h.jsonValue()).catch(() => -1)
/** Click the first visible match of `sel`; performance.now() at the click, -1 if none. */
const clickAt = (p, sel) => p.evaluate((s) => {
  const el = [...document.querySelectorAll(s)].find((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 })
  if (!el) return -1
  const t = performance.now()
  el.click()
  return t
}, sel)

const FLOW_TAB = '[data-testid=sidebar-tab-flow]'
const FLOW_ENTRY = '[data-testid=sidebar-panel-flow] [data-testid=left-entry]'
const EVENTS_TAB = '[data-testid=sidebar-tab-events]'
const EVENTS_LINK = '[data-testid=sidebar-events-open]'
const EVENTS_PAGE = '[data-test=events-page]'
const EVENTS_DONE = '[data-test=events-table], [data-test=events-empty], [data-test=events-error], [data-test=events-signed-out]'
/** a rail tab that is not Flow / Event log, to leave Flow and come back */
const OTHER_TAB = '[data-testid=sidebar-tab-channels], [data-testid=sidebar-tab-topics], [data-testid=sidebar-tab-dm]'

/** The page's own resource timings since `t0` (performance.now() base): what ran when, relative to the click. */
const timeline = (p, t0) => p.evaluate((t0) => performance.getEntriesByType('resource')
  .filter((e) => e.startTime >= t0 && !e.name.startsWith('data:'))
  .map((e) => `${Math.round(e.startTime - t0)}..${Math.round(e.responseEnd - t0)} ${e.initiatorType} ${e.name.replace(/^https?:\/\/[^/]+/, '').slice(0, 90)}`), t0)

async function step(p, rec, s, name, clickSel, doneSel, midSel = '') {
  rec.take()
  const t0 = await clickAt(p, clickSel)
  const [t1, tm] = t0 < 0 ? [-1, -1] : await Promise.all([whenSel(p, doneSel), midSel ? whenSel(p, midSel) : -1])
  s[name] = {
    ms: t0 < 0 || t1 < 0 ? -1 : Math.round(t1 - t0),
    ...(midSel ? { shownMs: tm < 0 || t0 < 0 ? -1 : Math.round(tm - t0) } : {}),
    ...(t0 < 0 ? { note: 'no ' + clickSel } : { timeline: await timeline(p, t0) }),
    ...net(rec.take()),
  }
  if (t0 < 0 || t1 < 0) await p.screenshot({ path: `${OUT}/${s.tag}-${name}.png` }).catch(() => {})
}

async function round(p, cdp, rec, i, tag) {
  const s = { tag }
  if (COLD_CACHE) await cdp.send('Network.clearBrowserCache')
  await p.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 90000 })
  if ((await whenSel(p, FLOW_TAB, 45000)) < 0) throw new Error('no Flow rail tab at ' + p.url())
  await sleep(2500)
  // Flow, first open in this page
  await step(p, rec, s, 'flow-cold', FLOW_TAB, FLOW_ENTRY)
  await sleep(800)
  // open the i-th entry (rotating over the first 8, so one cached place does not stand for all)
  const pick = await p.evaluate((sel, i) => {
    const rows = [...document.querySelectorAll(sel)].filter((e) => e.getBoundingClientRect().height > 0)
    const el = rows[i % Math.max(1, Math.min(rows.length, 8))]
    return el ? el.getAttribute('data-msg-id') || '' : ''
  }, FLOW_ENTRY, i)
  if (pick) {
    await step(p, rec, s, 'flow-open', `${FLOW_ENTRY}[data-msg-id="${pick}"]`,
      `.msg[data-msg-id="${pick}"].open-focus, .msg[data-msg-id="${pick}"].search-focus`, `.msg[data-msg-id="${pick}"]`)
  } else s['flow-open'] = { ms: -1, note: 'no entry' }
  await sleep(800)
  // Flow again after another tab. Back (one history entry over the list, as
  // the reader would) returns a phone to the list level.
  await p.evaluate(() => history.back())
  await sleep(600)
  await clickAt(p, OTHER_TAB)
  await sleep(600)
  await step(p, rec, s, 'flow-warm', FLOW_TAB, FLOW_ENTRY)
  await sleep(600)
  // Event log: rail tab, then its link, then the page. On a phone the rail
  // tab opens /events itself (level 2): the page is timed from the tab click.
  rec.take()
  const tt = await clickAt(p, EVENTS_TAB)
  const tl = tt < 0 ? -1 : await whenSel(p, `${EVENTS_LINK}, ${EVENTS_PAGE}`)
  // the link paints first on a phone while the tab is already routing to
  // /events: give the route 1.5 s to show the page before clicking the link
  const direct = tl >= 0 && (await whenSel(p, EVENTS_PAGE, 1500)) >= 0
  s['events-tab'] = { ms: tt < 0 || tl < 0 ? -1 : Math.round(tl - tt), direct, ...(tt < 0 ? {} : { timeline: await timeline(p, tt) }) }
  const t0 = direct ? tt : await clickAt(p, EVENTS_LINK)
  const [tp, tf] = t0 < 0 ? [-1, -1] : await Promise.all([whenSel(p, EVENTS_PAGE), whenSel(p, EVENTS_DONE)])
  const n = net(rec.take())
  s['events-paint'] = { ms: tp < 0 || t0 < 0 ? -1 : Math.round(tp - t0), ...n }
  s['events-full'] = { ms: tf < 0 || t0 < 0 ? -1 : Math.round(tf - t0), rows: await p.evaluate(() => document.querySelectorAll('[data-test=events-row]').length), ...n }
  await sleep(600)
  await p.evaluate(() => history.back())
  await sleep(800)
  if ((await whenSel(p, EVENTS_LINK, 2000)) < 0) {
    // phone: back at level 1 the rail tab is the way in again
    await step(p, rec, s, 'events-warm', EVENTS_TAB, EVENTS_DONE)
  } else {
    await sleep(300)
    await step(p, rec, s, 'events-warm', EVENTS_LINK, EVENTS_DONE)
  }
  return s
}

const pct = (xs, q) => {
  const v = xs.filter((x) => typeof x === 'number' && x >= 0).sort((a, b) => a - b)
  if (!v.length) return null
  return v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)]
}

const puppeteer = await loadPuppeteer()
const LOCAL_MAP = process.env.LOCAL_MAP || ''
const chromeArgs = ['--no-sandbox']
if (LOCAL_MAP) chromeArgs.push(`--host-resolver-rules=MAP ${new URL(BASE).hostname} ${LOCAL_MAP}`, '--ignore-certificate-errors')
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: chromeArgs, ...(process.env.USER_DATA_DIR ? { userDataDir: process.env.USER_DATA_DIR } : {}) })
let failed = false
try {
  res.build = LOCAL_MAP ? { local: LOCAL_MAP } : await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  const ctx = process.env.USER_DATA_DIR ? browser.defaultBrowserContext() : await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.evaluateOnNewDocument(() => { try { performance.setResourceTimingBufferSize(5000) } catch { /* old engine */ } })
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
  res.claimTenant = await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value.session?.claims?.t || '')

  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  const rec = recorder(cdp)
  for (const name of PROFILES) {
    const prof = PROFILE[name]
    if (!prof) { console.error('unknown profile', name); continue }
    await p.setViewport(prof.vp)
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: prof.cpu })
    const samples = []
    for (let i = 0; i < N; i++) {
      try { samples.push(await round(p, cdp, rec, i, `${name}-r${i}`)) } catch (e) { samples.push({ error: String(e?.message || e) }) }
      const s = samples.at(-1)
      console.log(name, 'round', i, s.error ? 'ERROR ' + s.error : STEPS.map((k) => `${k}=${msOf(s, k) ?? '?'}`).join(' '))
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

const summary = {}
for (const [name, samples] of Object.entries(res.profiles)) {
  summary[name] = {}
  for (const k of STEPS) {
    const xs = samples.map((s) => msOf(s, k))
    summary[name][k] = { median: pct(xs, 0.5), p90: pct(xs, 0.9), n: xs.filter((x) => typeof x === 'number' && x >= 0).length }
  }
  const routes = {}
  for (const s of samples) for (const k of STEPS) for (const a of s[k]?.api || []) (routes[`${k} ${a.route}`] ??= []).push(a)
  summary[name].api = Object.fromEntries(Object.entries(routes).sort().map(([r, xs]) => [r, {
    median: pct(xs.map((a) => a.ms), 0.5), p90: pct(xs.map((a) => a.ms), 0.9), kb: pct(xs.map((a) => a.kb), 0.5), n: xs.length,
  }]))
}
res.summary = summary
writeFileSync(`${OUT}/timing.json`, JSON.stringify(res, null, 1))
const b = res.build || {}
console.log(`build ${b.version || b.local || '?'} sha ${String(b.sha || b.commit || '?').slice(0, 8)} at ${BASE}`)
const names = Object.keys(summary)
console.log(`| step | ${names.map((n) => `${n} median / p90 ms (n)`).join(' | ')} |`)
console.log(`|---|${names.map(() => '---|').join('')}`)
for (const k of STEPS) console.log(`| ${k} | ${names.map((n) => { const m = summary[n][k]; return m.median === null ? '-' : `${m.median} / ${m.p90} (${m.n})` }).join(' | ')} |`)
for (const n of names) {
  console.log(`\n${n} API per step (client ms median / p90, KB median, n)`)
  for (const [r, m] of Object.entries(summary[n].api)) console.log(`  ${r}  ${m.median} / ${m.p90} ms  ${m.kb} KB  n=${m.n}`)
}
process.exit(failed ? 1 : 0)
