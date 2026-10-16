// SPL-2093 (owner HUM-10, t1 04d9c246 msgs 72470279 + 55d8a23c + b04d12fb):
// "The button to clear the log should be on the bottom center on mobile" /
// "And not on the top right" / "Also, on mobile, the bottom could be a little
// bit smaller." - and t1 ec6ca844 (msg 1b0bcba8): "the distance between the
// connected dot and the bell icon on the bottom bar should be 2 mm smaller.
// The same for the note icon: it should go some 3 mm on the left. The version
// should stay where it is, and then the clock should go 2 mm on the left."
//
//   phone (412x915, isMobile + hasTouch), /events signed in with 14 events:
//     1 Clear log is centred (|centre - viewport centre| <= 4 px), in the
//       bottom 25 % of the viewport, just above the dock; none in the header
//     2 scrolled to the end, the last event card ends above Clear log
//     3 the bottom bar (dock + status strip) is lower than before
//       (BEFORE, measured on origin/master 97a636405), every dock control
//       still >= 40 px tall
//     4 the status line, against BEFORE (1 mm = 3.78 px, within 1 px):
//       bell 8 px nearer the dot, note 11 px left, version unmoved, clock
//       8 px left
//   desktop (1280x800):
//     5 Clear log stays in the header, top right
//
// Run:
//   node tests/e2e/events-clear-log-mobile.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/events-clear-log-mobile.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per viewport
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const PHONE = { w: 412, h: 915, mobile: true }
const DESKTOP = { w: 1280, h: 800, mobile: false }
// origin/master 97a636405 at 412x915 (the mock bundle, this harness): the
// dock + strip height, and each status-line item's x (glyph left edges, the
// version text's start, the clock's end)
const BEFORE = { bar: 81, bell: 70, note: 118, version: 146, clockEnd: 412 }
const MOVE = { bell: -8, note: -11, version: 0, clockEnd: -8 }
const MIN_TAP = 40

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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// The signed-in mock owner (specs/054: localStorage in the mock bundle, the
// session stub against a real BASE_URL) and 14 events, enough to scroll.
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
const EVENTS = Array.from({ length: 14 }, (_, i) => ({
  id: 14 - i, error_id: `e-${14 - i}`, at: '2026-10-15T08:00:00Z', received_at: '2026-10-15T08:00:01Z',
  source: i % 2 ? 'hub' : 'wui', status: i % 2 ? 404 : 500, message: `event ${14 - i}`, route: '/events',
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

async function open(browser, base, vp) {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument((session) => {
    try { localStorage.setItem('spool.mock.session', session) } catch { /* first document */ }
  }, MOCK_SESSION)
  await p.setViewport({ width: vp.w, height: vp.h, isMobile: vp.mobile, hasTouch: vp.mobile, deviceScaleFactor: 1 })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const a = answer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  await p.goto(base + '/events', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=events-table]', { visible: true, timeout: 15000 })
  await p.waitForSelector('[data-test=events-clear]', { visible: true, timeout: 15000 })
  if (vp.mobile) await p.waitForSelector('[data-test=status-strip]', { visible: true, timeout: 15000 })
  await sleep(600)
  return p
}

const measure = (p) => p.evaluate(() => {
  const rect = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { x: r.left, y: r.top, w: r.width, h: r.height, r: r.right, b: r.bottom }
  }
  const q = (s) => document.querySelector(s)
  const clear = q('[data-test=events-clear]')
  const dock = q('.composer--dock')
  const strip = q('[data-test=status-strip]')
  const dockCtl = dock ? [...dock.querySelectorAll('.composer-row button, .composer-row .composer-go, .search-syntax-btn, .omnibox-field')]
    .filter((e) => e.getBoundingClientRect().width > 0)
    .map((e) => Math.round(e.getBoundingClientRect().height)) : []
  return {
    vw: window.innerWidth,
    vh: window.innerHeight,
    clear: rect(clear),
    clearInHeader: Boolean(clear?.closest('.feed-header')),
    dock: rect(dock),
    strip: rect(strip),
    dockCtl,
    dot: rect(q('.status-strip__dot')),
    bell: rect(q('[data-test=status-strip] [data-testid=notify-alerts] svg')),
    note: rect(q('[data-test=status-strip] [data-testid=notify-chime] svg')),
    version: rect(q('.status-strip__ver')),
    clock: rect(q('.status-strip__clock')),
  }
})

async function checkPhone(browser, base) {
  const p = await open(browser, base, PHONE)
  try {
    const m = await measure(p)
    const now = {
      bar: Math.round(m.vh - m.dock.y),
      bell: Math.round(m.bell.x),
      note: Math.round(m.note.x),
      version: Math.round(m.version.x),
      clockEnd: Math.round(m.clock.r),
    }
    console.log('  measured', JSON.stringify({ before: BEFORE, now, dock: Math.round(m.dock.h), strip: Math.round(m.strip.h) }))
    const c = m.clear
    const centre = c.x + c.w / 2
    ok('phone: Clear log is centred horizontally', Math.abs(centre - m.vw / 2) <= 4, { centre, vw: m.vw })
    ok('phone: Clear log sits in the bottom 25 % of the viewport', c.y >= m.vh * 0.75 && c.b <= m.vh, { top: c.y, bottom: c.b, vh: m.vh })
    ok('phone: Clear log is above the dock, not under it', c.b <= m.dock.y, { clearBottom: c.b, dockTop: m.dock.y })
    ok('phone: Clear log is not in the header row', !m.clearInHeader)
    ok(`phone: Clear log is a >= ${MIN_TAP} px target`, c.h >= MIN_TAP, { h: c.h })

    const last = await p.evaluate(() => {
      const body = document.querySelector('.feed-body')
      body.scrollTop = body.scrollHeight
      return new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => {
        const rows = document.querySelectorAll('[data-test=events-row]')
        r(rows[rows.length - 1].getBoundingClientRect().bottom)
      })))
    })
    ok('phone: scrolled to the end, the last event card ends above Clear log', last <= c.y, { lastBottom: last, clearTop: c.y })

    ok('phone: the bottom bar (dock + strip) is lower than before', now.bar < BEFORE.bar, { before: BEFORE.bar, now: now.bar })
    ok(`phone: every dock control is still >= ${MIN_TAP} px tall`, m.dockCtl.length >= 4 && m.dockCtl.every((h) => h >= MIN_TAP), m.dockCtl)
    for (const k of Object.keys(MOVE)) {
      const d = now[k] - BEFORE[k]
      ok(`phone: status line ${k} moved ${MOVE[k]} px (1 px slack)`, Math.abs(d - MOVE[k]) <= 1, { before: BEFORE[k], now: now[k], moved: d })
    }
    ok('phone: the dot did not move', Math.round(m.dot.x) === 26, { dot: m.dot.x })
    if (OUT) await p.screenshot({ path: join(OUT, 'events-phone-412x915.png') })
  } catch (e) {
    ok('phone ran', false, String(e.message || e))
  } finally {
    await p.close()
  }
}

async function checkDesktop(browser, base) {
  const p = await open(browser, base, DESKTOP)
  try {
    const m = await measure(p)
    const c = m.clear
    ok('desktop: Clear log stays in the header row', m.clearInHeader)
    ok('desktop: Clear log stays top right', c.r >= m.vw * 0.75 && c.y <= 120, { right: c.r, top: c.y, vw: m.vw })
    ok('desktop: no phone dock or strip', !m.dock?.h && !m.strip, { dock: m.dock, strip: m.strip })
    if (OUT) await p.screenshot({ path: join(OUT, 'events-desktop-1280x800.png') })
  } catch (e) {
    ok('desktop ran', false, String(e.message || e))
  } finally {
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  await checkPhone(browser, server.base)
  await checkDesktop(browser, server.base)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
