// SPL-5719 (spec 149 section 2.7): a broken Google Calendar connection shows
// on the Calendar page, with a one-click Reconnect, in a real browser, mock
// tenant signed in. The mock keeps the connection in localStorage
// spool.mock.gcal (utils/gcal-client.mjs): absent = not connected, 'off' = a
// workspace outside gcal.workspaces (the hub's 404), else the hub's JSON.
//   B1 1440 revoked: the banner shows the status and the hub's reason
//   B2 1440 Reconnect (the mock's Google is instant) clears the banner
//   B3 CONTROL: connected, not connected, error and 'off' - only error shows it
//   B4 390 revoked: the phone calendar shows it, no sideways scroll, the
//       button >= 44 px tall
// Red control: on origin/master before SPL-5719 the Calendar page has no
// [data-test=calendar-gcal-banner]: B1, B2's precondition, B3 error and B4 fail.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/calendar-gcal-banner.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const DESKTOP = { name: '1440', width: 1440, height: 900 }
const PHONE = { name: '390', width: 390, height: 844 }
const BANNER = '[data-test=calendar-gcal-banner]'
const row = (status, detail = '') => JSON.stringify({ connected: true, google_email: 'member@example.com',
  calendar_title: 'Spool Hub (Mock)', status, status_detail: detail, last_synced_at: '2026-10-24T08:00:00Z' })
const REASON = 'google refused the refresh token (invalid_grant): reconnect'

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* opaque origin on the very first document */ }
  })

  const load = async (vp) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=calendar-page]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  }
  const setMock = (v) => p.evaluate((val) => {
    if (val === null) localStorage.removeItem('spool.mock.gcal'); else localStorage.setItem('spool.mock.gcal', val)
  }, v)
  /* the event that settles a negative: the calendar's own chunk has drawn,
     so the page's lazy banner had its turn too (it mounts first) */
  const settled = () => p.waitForSelector('[data-test=calendar-page] [data-test]:not([data-test=calendar-gcal-banner])', { timeout: NAV_TIMEOUT })
    .then(() => p.waitForNetworkIdle({ idleTime: 300, timeout: 10000 })).catch(() => null)
  const shown = () => p.waitForSelector(BANNER, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const absent = async () => { await settled(); return !(await p.$(BANNER)) }
  const text = () => p.$eval(BANNER, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/calendar-gcal-banner-${name}.png` }) }

  /* the origin, then the mock row */
  await load(DESKTOP)

  /* B1: revoked */
  await setMock(row('revoked', REASON))
  await load(DESKTOP)
  ok('B1-1 1440 revoked: the banner shows', await shown())
  const said = await text()
  ok('B1-2 it names Google Calendar, the status and the reason', said.startsWith('Google Calendar: Access revoked') && said.includes(REASON), { said })
  ok('B1-3 its Reconnect button', Boolean(await p.$(`${BANNER} [data-test=calendar-gcal-reconnect]`)))
  await shot('1440-revoked')

  /* B2: Reconnect */
  const clicked = await p.click(`${BANNER} [data-test=calendar-gcal-reconnect]`).then(() => true).catch(() => false)
  const gone = clicked && await p.waitForSelector(BANNER, { hidden: true, timeout: 10000 }).then(() => true).catch(() => false)
  const stored = await p.evaluate(() => JSON.parse(localStorage.getItem('spool.mock.gcal') || '{}').status)
  ok('B2 Reconnect connects and the banner goes', clicked && gone && stored === 'connected', { clicked, gone, stored })

  /* B3: controls */
  await setMock(row('connected'))
  await load(DESKTOP)
  ok('B3-1 CONTROL connected: no banner', await absent())
  await setMock(null)
  await load(DESKTOP)
  ok('B3-2 CONTROL not connected: no banner', await absent())
  await setMock('off')
  await load(DESKTOP)
  ok('B3-3 CONTROL off (404): no banner', await absent())
  await setMock(row('error', 'calendar list 500'))
  await load(DESKTOP)
  ok('B3-4 error: the banner shows Sync error', await shown() && (await text()).startsWith('Google Calendar: Sync error'), { said: await text() })

  /* B4: phone */
  await setMock(row('revoked', REASON))
  await load(PHONE)
  ok('B4-1 390 revoked: the banner shows on the phone calendar', await shown() && Boolean(await p.$('[data-test=calendar-phone]')))
  const phone = await p.evaluate((sel) => ({
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    btn: Math.round(document.querySelector(`${sel} button`)?.getBoundingClientRect().height || 0),
  }), BANNER)
  ok('B4-2 390: no sideways scroll, Reconnect >= 44 px tall', phone.over <= 0 && phone.btn >= 44, phone)
  await shot('390-revoked')

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
