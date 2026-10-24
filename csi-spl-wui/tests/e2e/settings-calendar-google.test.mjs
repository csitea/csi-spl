// Spec 149 B8 (SPL-3227): Settings -> Google Calendar in a real browser, mock
// tenant signed in. The mock keeps the connection in localStorage
// spool.mock.gcal (utils/gcal-client.mjs): absent = not connected, 'off' = a
// workspace outside gcal.workspaces (the hub's 404).
//   C26 1440: the nav lists Google Calendar; not connected shows Connect and
//       no Disconnect; Connect (the mock's Google is instant) shows the Google
//       email, the synced calendar and Disconnect; Sync now says it started;
//       Disconnect with "remove imported events" goes back to Connect
//   N   the callback's way back (?gcal=connected) shows the connected notice
//   C25b spool.mock.gcal = 'off': "not available here", no Connect button
//   P   phone 390: no sideways scroll, every button >= 44 px tall
// CONTROL: each state is asserted by its data-view AND its own element, so a
// section that never loads cannot pass a "no Connect button" check.
// Red control: on origin/master before B8 there is no such section: C26-1 fails.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/settings-calendar-google.test.mjs
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const PHONE = { name: '390', width: 390, height: 844 }
const SECTION = '[data-testid=ui-dialog] [data-test=gcal]'

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      const theme = localStorage.getItem('spool.test.theme')
      if (theme) localStorage.setItem('spool-theme', theme)
    } catch { /* opaque origin on the very first document */ }
  })

  const load = async (vp, path) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(400)
  }
  const setMock = (v) => p.evaluate((val) => {
    if (val === null) localStorage.removeItem('spool.mock.gcal'); else localStorage.setItem('spool.mock.gcal', val)
  }, v)
  const view = (want) => p.waitForSelector(`${SECTION}[data-view="${want}"]`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const has = (test) => p.evaluate((t) => {
    const e = document.querySelector(`[data-testid=ui-dialog] [data-test="${t}"]`)
    return Boolean(e && e.getBoundingClientRect().width > 0)
  }, test)
  const text = (test) => p.$eval(`[data-testid=ui-dialog] [data-test="${test}"]`, (e) => e.textContent.trim()).catch(() => '')
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-calendar-google-${name}.png` }) }
  const setTheme = (theme) => p.evaluate((t) => localStorage.setItem('spool.test.theme', t), theme)
  const SETTINGS = '/channel/general?settings=calendar-google'

  /* C26: not connected */
  await load(DESKTOP, '/channel/general')
  await setMock(null)
  await load(DESKTOP, SETTINGS)
  ok('C26-1 the section opens on ?settings=calendar-google, not connected', await view('disconnected') && await has('gcal-connect'))
  ok('C26-2 the nav lists it, active', await p.$eval('[data-test=settings-nav-calendar-google]', (a) => a.getAttribute('aria-current') === 'page' && a.textContent.trim() === 'Google Calendar').catch(() => false))
  ok('C26-3 CONTROL: not connected has no Disconnect', !(await has('gcal-disconnect')))
  await shot('1440-disconnected')

  /* C26: connect, sync, disconnect */
  await p.click('[data-testid=ui-dialog] [data-test=gcal-connect]')
  ok('C26-4 Connect shows the connection', await view('connected'))
  ok('C26-5 the Google email, the calendar and Disconnect show', (await text('gcal-email')) === 'member@example.com'
    && (await text('gcal-calendar')) === 'Spool Hub (Mock)' && await has('gcal-disconnect'), { email: await text('gcal-email'), cal: await text('gcal-calendar') })
  ok('C26-6 the last sync is an ISO time', /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(await text('gcal-last-sync')), { at: await text('gcal-last-sync') })
  await shot('1440-connected')
  await p.click('[data-testid=ui-dialog] [data-test=gcal-sync]')
  await p.waitForSelector('[data-testid=ui-dialog] [data-test=gcal-result]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('C26-7 Sync now says it started', (await text('gcal-result')) === 'Sync started.', { said: await text('gcal-result') })
  await p.click('[data-testid=ui-dialog] [data-test=gcal-remove-imported]')
  await p.click('[data-testid=ui-dialog] [data-test=gcal-disconnect]')
  ok('C26-8 Disconnect goes back to Connect', await view('disconnected') && await has('gcal-connect'))
  ok('C26-9 the mock row is gone', (await p.evaluate(() => localStorage.getItem('spool.mock.gcal'))) === null)

  /* N: the callback's way back */
  await load(DESKTOP, SETTINGS + '&gcal=connected')
  ok('N1 ?gcal=connected shows the connected notice', await view('disconnected') && (await text('gcal-notice')) === 'Google Calendar is connected.', { notice: await text('gcal-notice') })

  /* C25b: a workspace outside gcal.workspaces */
  await setMock('off')
  await load(DESKTOP, SETTINGS)
  ok('C25b-1 off: the section says it is not available here', await view('off') && (await text('gcal-off')) === 'Google Calendar is not available in this workspace.', { off: await text('gcal-off') })
  ok('C25b-2 off: no Connect button', !(await has('gcal-connect')))
  await shot('1440-off')

  /* P: phone */
  await setMock(JSON.stringify({ connected: true, google_email: 'member@example.com', calendar_title: 'Spool Hub (Mock)', status: 'revoked', status_detail: 'Google refused the refresh token.', last_synced_at: '2026-10-24T08:00:00Z' }))
  await load(PHONE, SETTINGS)
  ok('P1 390: a revoked connection shows its reason and Reconnect', await view('broken') && await has('gcal-reconnect') && (await text('gcal-broken')) === 'Google refused the refresh token.' && (await text('gcal-status')) === 'Access revoked')
  const phone = await p.evaluate(() => ({
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    short: [...document.querySelectorAll('[data-testid=ui-dialog] [data-test=gcal] button')]
      .filter((b) => b.getBoundingClientRect().width > 0 && b.getBoundingClientRect().height < 44).map((b) => b.dataset.test),
  }))
  ok('P2 390: no sideways scroll, every button >= 44 px', phone.over <= 0 && phone.short.length === 0, phone)
  await shot('390-revoked')

  if (OUT) {
    await setTheme('light')
    await setMock(JSON.stringify({ connected: true, google_email: 'member@example.com', calendar_title: 'Spool Hub (Mock)', status: 'connected', status_detail: '', last_synced_at: '2026-10-24T08:00:00Z' }))
    await load(DESKTOP, SETTINGS)
    await view('connected')
    await shot('1440-connected-light')
    await setMock(null)
    await load(PHONE, SETTINGS)
    await view('disconnected')
    await shot('390-disconnected-light')
    await setTheme('dark')
  }

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
