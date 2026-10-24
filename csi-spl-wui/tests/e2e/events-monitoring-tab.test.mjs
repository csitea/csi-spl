// SPL-3250 (owner HUM-10, t1 463d7692, msgs 24316f72 + ac1c95f9): "the event
// log section should be come just one tab of the monitoring section", "on
// both mobile and the desktop". It replaces SPL-3212's events-tab-auto test,
// whose Events rail tab is gone.
//
// The mock bundle, signed in with 12 events, phone 360x800 (touch) and
// desktop 1440x900, each:
//   1 the rail has no Events entry (and still has Monitoring)
//   2 Monitoring shows an Events tab; it opens /monitoring/events
//   3 the tab shows the event log (its first row, no link) and Clear log
//     POSTs /clear and empties it
//   4 the deep link /events lands on /monitoring/events, and /events#<id>
//     keeps the hash: that row is the focused one
//   5 no sideways scroll; the Monitoring tabs and Clear log are >= 44 px tall
//     on the phone
// Control: the bundle of origin/master a1d2ced73 fails 1, 2, 3 and 4 on both
// viewports (an Events rail tab, no Events tab in Monitoring, /events stays).
//
// Run:
//   node tests/e2e/events-monitoring-tab.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/events-monitoring-tab.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// The signed-in mock owner (specs/054) and 12 events, as events-clear-log-mobile.
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
const EVENTS = Array.from({ length: 12 }, (_, i) => ({
  id: 12 - i, error_id: `e-${12 - i}`, at: '2026-10-24T08:00:00Z', received_at: '2026-10-24T08:00:01Z',
  source: 'wui', status: 500, message: `event ${12 - i}`, route: '/events',
}))
function answer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && req.method() === 'GET') {
    return json(200, {
      v: 1, p: 'password', sub: 'person@example.com', email: 'person@example.com', name: 'FirstName LastName',
      hum: 'HUM-4', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  if (path === 'events') return json(200, { events: EVENTS, next_before: 0 })
  return json(404, { error: 'not_found' })
}

let clears = 0
async function open(browser, base, vp, path) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((session) => {
    try { localStorage.setItem('spool.mock.session', session) } catch { /* first document */ }
  }, MOCK_SESSION)
  await p.setViewport({ width: vp.w, height: vp.h, isMobile: vp.mobile, hasTouch: vp.mobile, deviceScaleFactor: 1 })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (req.method() === 'POST' && new URL(req.url()).pathname === '/api/v1/auth/events/clear') {
      clears++
      req.respond(json(200, { ok: true })).catch(() => {})
      return
    }
    const a = answer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  await p.goto(base + path, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true, timeout: 15000 })
  await sleep(1200)
  return p
}

/* what the reader sees */
const seen = (p) => p.evaluate(() => {
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0 && r.top < innerHeight && r.bottom > 0
  }
  const h = (sel) => [...document.querySelectorAll(sel)].filter(vis).map((e) => Math.round(e.getBoundingClientRect().height))
  const row = document.querySelector('[data-test=events-row]')
  const se = document.scrollingElement || document.documentElement
  return {
    path: location.pathname,
    hash: location.hash,
    railEvents: Boolean(document.querySelector('[data-testid=sidebar-tab-events]')),
    railMonitoring: vis(document.querySelector('[data-testid=sidebar-tab-monitoring]')),
    tab: vis(document.querySelector('[data-test=monitoring-tab-events]')),
    tabActive: document.querySelector('[data-test=monitoring-tab-events]')?.getAttribute('aria-current') === 'page',
    row: vis(row),
    rows: document.querySelectorAll('[data-test=events-row]').length,
    focus: document.querySelector('.events-row--focus')?.id || '',
    empty: vis(document.querySelector('[data-test=events-empty]')),
    clear: vis(document.querySelector('[data-test=events-clear]')),
    logs: document.querySelectorAll('[data-test=events-page]').length,
    sideways: se.scrollWidth - innerWidth,
    tabH: h('.monitoring-tab'),
    clearH: h('[data-test=events-clear]'),
  }
})

async function settle(p, sel = '[data-test=events-row]') {
  await p.waitForSelector(sel, { visible: true, timeout: 10000 }).catch(() => {})
  await sleep(400)
  return seen(p)
}
const click = (p, sel) => p.$eval(sel, (e) => e.click())
const shot = async (p, name) => { if (OUT) await p.screenshot({ path: join(OUT, `${name}.png`) }) }

async function check(browser, base, vp, name) {
  const phone = vp.mobile
  let p = await open(browser, base, vp, '/')
  try {
    const s0 = await seen(p)
    ok(`${name}: 1 the rail has no Events entry, Monitoring is there`, !s0.railEvents && s0.railMonitoring, s0)
    await click(p, '[data-testid=sidebar-tab-monitoring]')
    const s1 = await settle(p, '[data-test=monitoring-tab-events]')
    ok(`${name}: 2 Monitoring shows an Events tab`, s1.tab && s1.path.startsWith('/monitoring'), s1)
    await click(p, '[data-test=monitoring-tab-events]')
    const s2 = await settle(p)
    await shot(p, `${name}-tab`)
    ok(`${name}: 2 the Events tab opens /monitoring/events, selected`, s2.path.endsWith('/monitoring/events') && s2.tabActive, s2)
    ok(`${name}: 3 the tab shows the event log and Clear log, one log`, s2.row && s2.rows === 12 && s2.clear && s2.logs === 1, s2)
    ok(`${name}: 5 no sideways scroll`, s2.sideways <= 0, s2)
    if (phone) ok(`${name}: 5 tap targets: Monitoring tabs and Clear log >= 44 px`, s2.tabH.length > 0 && s2.tabH.every((x) => x >= 44) && s2.clearH.every((x) => x >= 44), { tabH: s2.tabH, clearH: s2.clearH })
    const before = clears
    await click(p, '[data-test=events-clear]')
    const s3 = await settle(p, '[data-test=events-empty]')
    ok(`${name}: 3 Clear log POSTs /clear and empties the log`, clears === before + 1 && s3.rows === 0 && s3.empty, { clears: clears - before, s3 })
  } catch (e) {
    ok(`${name}: tab ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events')
  try {
    const s = await settle(p)
    await shot(p, `${name}-deep-link`)
    ok(`${name}: 4 /events lands on Monitoring -> Events with the log`, s.path.endsWith('/monitoring/events') && s.tabActive && s.row, s)
    ok(`${name}: 5 no sideways scroll on the deep link`, s.sideways <= 0, s)
  } catch (e) {
    ok(`${name}: deep link ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events#5')
  try {
    const s = await settle(p, '.events-row--focus')
    ok(`${name}: 4 /events#5 keeps the hash, row 5 focused`, s.path.endsWith('/monitoring/events') && s.hash === '#5' && s.focus === '5', s)
  } catch (e) {
    ok(`${name}: hash link ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  await check(browser, server.base, { w: 360, h: 800, mobile: true }, 'phone-360')
  await check(browser, server.base, { w: 1440, h: 900, mobile: false }, 'desktop-1440')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
