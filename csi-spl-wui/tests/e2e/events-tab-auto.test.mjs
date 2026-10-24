// SPL-3212 (owner HUM-10, t1 986e0918 msg 6c89aba3, phone screenshot of the
// Events tab showing a heading and one link): "I should not have to click
// this link in order to get the event log. The event log should appear
// automatically."
//
// The mock bundle, signed in with 12 events (more than a phone screen). No
// click on anything but the Events rail tab (and the phone's Back):
//   phone 360x800 (touch):
//     1 the tab opens /events: its first row is on screen, no link
//     2 a second tap on the selected tab (level 1, CLE-77886) shows the log
//       there, not a link
//     3 a load of /events, then Back to level 1: the log is there again
//     4 one log at a time in the document (the panel and the page never both),
//       and the level-1 log scrolls to its last event
//   desktop 1440x900:
//     5 the tab opens /events: its first row is on screen, no link
//     6 the sidebar is the icon rail alone there (.sidebar--rail)
//     7 the deep link /events itself shows the first row
// Control: the source of origin/master b5c78e2e7 fails 7 of 10 checks, all
// of 2, 3, 5, 6 and 7: level 1 is the panel's heading and its "Event log"
// link (sidebar-events-open), which a desktop shows beside the page.
//
// Run:
//   node tests/e2e/events-tab-auto.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/events-tab-auto.test.mjs   # what CI does
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

async function open(browser, base, vp, path) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
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
  await p.goto(base + path, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true, timeout: 15000 })
  await sleep(1200)
  return p
}

/* what the reader sees: the first row, the old link, the level, how many logs */
const seen = (p) => p.evaluate(() => {
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0 && r.top < innerHeight && r.bottom > 0
  }
  const row = document.querySelector('[data-test=events-row]')
  return {
    path: location.pathname,
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
    row: vis(row),
    rowText: row ? row.textContent.replace(/\s+/g, ' ').trim().slice(0, 60) : '',
    link: vis(document.querySelector('[data-testid=sidebar-events-open]')),
    logs: document.querySelectorAll('[data-test=events-page]').length,
    rail: document.querySelector('nav.sidebar')?.classList.contains('sidebar--rail') || false,
  }
})

/* waits up to 10 s for the first row, then reads the screen */
async function settle(p) {
  await p.waitForSelector('[data-test=events-row]', { visible: true, timeout: 10000 }).catch(() => {})
  await sleep(300)
  return seen(p)
}
const tapTab = (p) => p.$eval('[data-testid=sidebar-tab-events]', (e) => e.click())
const shot = async (p, name) => { if (OUT) await p.screenshot({ path: join(OUT, `${name}.png`) }) }

async function checkPhone(browser, base) {
  const vp = { w: 360, h: 800, mobile: true }
  let p = await open(browser, base, vp, '/')
  try {
    await tapTab(p)
    const s1 = await settle(p)
    await shot(p, 'phone-360-tab')
    ok('phone: the Events tab shows the first event, no link', s1.row && !s1.link && s1.path.endsWith('/events'), s1)
    await tapTab(p)
    const s2 = await settle(p)
    await shot(p, 'phone-360-level1')
    ok('phone: a second tap (level 1) shows the log, not a link', s2.level === '1' && s2.row && !s2.link, s2)
    ok('phone: one log in the document', s2.logs === 1 && s1.logs === 1, { tab: s1.logs, level1: s2.logs })
    /* the panel's log scrolls: its last event reaches the screen */
    const end = await p.evaluate(async () => {
      const rows = document.querySelectorAll('#sidebar-panel-events [data-test=events-row]')
      const last = rows[rows.length - 1]
      for (let el = last?.parentElement; el; el = el.parentElement) {
        if (el.scrollHeight > el.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(el).overflowY)) { el.scrollTop = el.scrollHeight; break }
      }
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
      const r = last?.getBoundingClientRect()
      const clear = document.querySelector('[data-test=events-clear]')?.getBoundingClientRect()
      return { rows: rows.length, lastBottom: r ? Math.round(r.bottom) : -1, clearTop: clear ? Math.round(clear.top) : null, vh: innerHeight }
    })
    ok('phone: level 1 scrolls to the last event, clear of Clear log', end.rows === 12 && end.lastBottom > 0 && end.lastBottom <= (end.clearTop ?? end.vh), end)
  } catch (e) {
    ok('phone tab ran', false, String(e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events')
  try {
    const s0 = await settle(p)
    ok('phone: a load of /events shows the first event', s0.row && !s0.link, s0)
    await p.$eval('[data-testid=mobile-back]', (e) => e.click())
    await sleep(800)
    const s3 = await settle(p)
    await shot(p, 'phone-360-back')
    ok('phone: Back to level 1 shows the log, not a link', s3.level === '1' && s3.row && !s3.link && s3.logs === 1, s3)
  } catch (e) {
    ok('phone back ran', false, String(e.message || e))
  } finally {
    await p.close()
  }
}

async function checkDesktop(browser, base) {
  const vp = { w: 1440, h: 900, mobile: false }
  let p = await open(browser, base, vp, '/')
  try {
    await tapTab(p)
    const s = await settle(p)
    await shot(p, 'desktop-1440-tab')
    ok('desktop: the Events tab shows the first event, no link', s.row && !s.link && s.path.endsWith('/events'), s)
    ok('desktop: the sidebar is the icon rail alone on the Event log', s.rail, s)
    ok('desktop: one log in the document', s.logs === 1, s)
  } catch (e) {
    ok('desktop tab ran', false, String(e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events')
  try {
    const s = await settle(p)
    ok('desktop: the deep link /events shows the first event', s.row && !s.link, s)
  } catch (e) {
    ok('desktop deep link ran', false, String(e.message || e))
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
