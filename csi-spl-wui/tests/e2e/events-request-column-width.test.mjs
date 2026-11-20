// SPL-6065 (owner HUM-10, t1 6faa2976, msg 9865c91f): "the events request
// column should be a twice as wide to utlize better the space in the table so
// that all of the rows in the table hsould be about the same size".
//
// The mock bundle, signed in with 8 events whose requests are as long as the
// owner's screenshot (a Vue component path that wrapped to 9 lines, a POST
// path, blanks):
//   desktop 1440x900 and 1920x1080, each:
//   1 the Request column is at least 1.9x the mean of the other 7 data
//      columns (origin/master: 1.0x, all eight columns the same width)
//   2 the row heights vary less than in the equal-width layout: the same page
//      with every column set back to auto width (what origin/master renders)
//      has a larger tallest/shortest row ratio
//   phone 360x800:
//   3 the card rows are unchanged: each cell a block, the Request cell as
//      wide as the Message cell
// Control: the bundle of origin/master 4c4e97f75 fails 1 and 2 on both
// desktop viewports (ratio 1.0, the override changes nothing).
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/events-request-column-width.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
const VUE_PATH = 'NuxtLayoutProvider/LayoutLoader/AsyncComponentWrapper/default/ClientOnly/NuxtPage/RouterView/RouteProvider/name/MessageFeed/LiveFeed/TransitionGroup'
const NULL_READ = "Cannot read properties of null (reading 'emitsOptions')"
const REQUESTS = [
  { method: 'POST', path: '/v1/issues/ABC-123/archive', source: 'api', code: 'net.unreachable', name: 'TypeError', message: 'Failed to fetch', route: '/issues' },
  { source: 'topic', name: 'TypeError', message: 'topic load failed', route: '/channel/general' },
  { source: 'channel', name: 'TypeError', message: 'Failed to fetch', route: '/channel/spool-hub-bugs' },
  { path: VUE_PATH, source: 'vue', code: 'vue:runtime-15', name: 'TypeError', message: NULL_READ, route: '/channel/general' },
  { path: VUE_PATH, source: 'vue', code: 'vue:runtime-15', name: 'TypeError', message: NULL_READ, route: '/channel/general' },
  { method: 'GET', path: '/v1/view/topics/6faa2976-51ad-423d-95d2-1571482a4ca9', source: 'api', code: 'not_found', message: 'topic not found', route: '/t/6faa2976' },
  { method: 'GET', path: '/v1/issues?limit=50', source: 'api', code: 'bad_request', name: 'Error', message: 'bad request', route: '/issues' },
  { source: 'wui', message: 'event', route: '/monitoring/events' },
]
const EVENTS = REQUESTS.map((r, i) => ({
  id: 8 - i, error_id: `ERR-CLIENT-20261120-10353${i}-18A${i}`, at: '2026-11-20T10:35:33Z', received_at: '2026-11-20T10:35:34Z',
  status: 0, origin: 'https://example.com', ...r,
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
  await p.goto(base + '/monitoring/events', { waitUntil: 'networkidle2' })
  await p.waitForFunction((n) => document.querySelectorAll('[data-test=events-row]').length === n, { timeout: 15000 }, EVENTS.length)
  return p
}

/* the widths of the first row's data cells and every row's height */
const measure = (p) => p.evaluate(() => {
  const rows = [...document.querySelectorAll('[data-test=events-row]')]
  const req = rows[0].querySelector('[data-test=events-request]')
  const msg = rows[0].querySelector('[data-test=events-message]')
  const w = (e) => e.getBoundingClientRect().width
  const others = [...rows[0].querySelectorAll('td:not(.events-check)')].filter((c) => c !== req).map(w)
  const heights = rows.map((r) => Math.round(r.getBoundingClientRect().height))
  return {
    req: Math.round(w(req)),
    otherMean: Math.round(others.reduce((a, b) => a + b, 0) / others.length),
    msg: Math.round(w(msg)),
    display: getComputedStyle(req).display,
    heights,
    spread: Math.max(...heights) / Math.min(...heights),
  }
})

/* the origin/master layout on the same page: every data column auto width */
const EQUAL = '.events-table th:not(.events-check-h) { width: auto !important; }'

async function desktop(browser, base, vp, name) {
  const p = await open(browser, base, vp)
  try {
    const now = await measure(p)
    const ratio = now.req / now.otherMean
    ok(`${name}: Request is >= 1.9x the other columns`, ratio >= 1.9, { ratio: Number(ratio.toFixed(2)), ...now })
    await p.addStyleTag({ content: EQUAL })
    const equal = await measure(p)
    ok(`${name}: rows vary less than the equal-width layout`, now.spread < equal.spread,
      { now: Number(now.spread.toFixed(2)), equal: Number(equal.spread.toFixed(2)), nowH: now.heights, equalH: equal.heights })
  } finally {
    await p.close()
  }
}

async function phone(browser, base) {
  const p = await open(browser, base, { w: 360, h: 800, mobile: true })
  try {
    const m = await measure(p)
    ok('phone-360: card cells are blocks, Request as wide as Message', m.display !== 'table-cell' && m.req === m.msg, m)
  } finally {
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  await desktop(browser, server.base, { w: 1440, h: 900, mobile: false }, 'desktop-1440')
  await desktop(browser, server.base, { w: 1920, h: 1080, mobile: false }, 'desktop-1920')
  await phone(browser, server.base)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
