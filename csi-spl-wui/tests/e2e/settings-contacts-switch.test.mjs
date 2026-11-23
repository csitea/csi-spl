// Spec 154 B18 (SPL-6278): the Contacts switch in Settings -> Google Calendar,
// in a real browser, mock tenant signed in. localStorage spool.mock.gcal is the
// calendar connection, spool.mock.contacts_sync the GET /v1/me/contacts/sync
// state ('off' = the hub's 404), spool.mock.me plays GET /v1/view/me (its
// contacts kill switch, 2.9).
//   CS1 connected, contacts on here: the switch shows, off
//   CS2 CONTROL: the calendar section is connected but the kill switch is off
//       (contacts: false): no switch; not connected: no switch
//   CS3 on with no contacts scope: the mock's Google grants it, the switch is
//       on and says the first import started
//   CS4 a reload keeps it on (the GET), Sync now moves the last sync
//   CS5 off says so and stays off after a reload
//   CS6 the binding in another workspace: the line, the switch disabled
//   CS7 on with no grant read back: the "not given access" line and the button
//   CS8 'off' (the hub's 404): no switch
//   P   phone 390: no sideways scroll, every button >= 44 px
// Red control: on master before B18 there is no switch: CS1 fails.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/settings-contacts-switch.test.mjs
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
const GCAL = '[data-testid=ui-dialog] [data-test=gcal]'
const SWITCH = '[data-testid=ui-dialog] [data-test=gcal-contacts]'
const SETTINGS = '/channel/general?settings=calendar-google'
const CONNECTED = JSON.stringify({ connected: true, google_email: 'member@example.com', calendar_title: 'Spool Hub (Mock)', status: 'connected', status_detail: '', last_synced_at: '2026-10-24T08:00:00Z' })
const ME_ON = JSON.stringify({ role: 'admin', permissions: [], contacts: true })
const ME_OFF = JSON.stringify({ role: 'admin', permissions: [], contacts: false })

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

  const load = async (vp, path) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(400)
  }
  const seed = (gcal, me, cs) => p.evaluate((g, m, c) => {
    const put = (k, v) => { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v) }
    put('spool.mock.gcal', g)
    put('spool.mock.me', m)
    put('spool.mock.contacts_sync', c)
  }, gcal, me, cs)
  const gview = (want) => p.waitForSelector(`${GCAL}[data-view="${want}"]`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const cview = (want) => p.waitForSelector(`${SWITCH}[data-view="${want}"]`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const has = (test) => p.evaluate((t) => {
    const e = document.querySelector(`[data-testid=ui-dialog] [data-test="${t}"]`)
    return Boolean(e && e.getBoundingClientRect().width > 0)
  }, test)
  const text = (test) => p.$eval(`[data-testid=ui-dialog] [data-test="${test}"]`, (e) => e.textContent.trim()).catch(() => '')
  const checked = () => p.$eval('[data-testid=ui-dialog] [data-test=gcal-contacts-switch]', (e) => ({ on: e.checked, aria: e.getAttribute('aria-checked'), disabled: e.disabled })).catch(() => null)
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-contacts-switch-${name}.png` }) }

  await load(DESKTOP, '/channel/general')

  /* CS1 */
  await seed(CONNECTED, ME_ON, null)
  await load(DESKTOP, SETTINGS)
  ok('CS1-1 connected, contacts on here: the switch shows, off', await gview('connected') && await cview('off') && (await checked())?.on === false)
  ok('CS1-2 its label and line', (await p.$eval(SWITCH, (e) => e.textContent).catch(() => '')).includes('Sync Google Contacts'))
  await shot('1440-off')

  /* CS2 */
  await seed(CONNECTED, ME_OFF, null)
  await load(DESKTOP, SETTINGS)
  ok('CS2-1 CONTROL: the kill switch off: connected, no switch', await gview('connected') && !(await has('gcal-contacts')))
  await seed(null, ME_ON, null)
  await load(DESKTOP, SETTINGS)
  ok('CS2-2 not connected: no switch', await gview('disconnected') && !(await has('gcal-contacts')))

  /* CS3 */
  await seed(CONNECTED, ME_ON, null)
  await load(DESKTOP, SETTINGS)
  await cview('off')
  await p.click('[data-testid=ui-dialog] [data-test=gcal-contacts-switch]')
  ok('CS3-1 on: the grant is asked and read back, the switch is on', await cview('on') && (await checked())?.aria === 'true', await checked())
  await p.waitForSelector('[data-testid=ui-dialog] [data-test=gcal-contacts-result]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('CS3-2 it says the first import started', (await text('gcal-contacts-result')) === 'Contacts sync is on. The first import has started.', { said: await text('gcal-contacts-result') })
  ok('CS3-3 the calendar connection is kept', await gview('connected') && (await text('gcal-email')) === 'member@example.com')

  /* CS4 */
  await load(DESKTOP, SETTINGS)
  ok('CS4-1 a reload keeps it on, last sync not yet', await cview('on') && (await checked())?.on === true && (await text('gcal-contacts-last-sync')) === 'Not yet', { at: await text('gcal-contacts-last-sync') })
  await p.click('[data-testid=ui-dialog] [data-test=gcal-contacts-sync]')
  await p.waitForSelector('[data-testid=ui-dialog] [data-test=gcal-contacts-result]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('CS4-2 Sync now says it started, the last sync is an ISO time', (await text('gcal-contacts-result')) === 'Sync started.'
    && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(await text('gcal-contacts-last-sync')), { said: await text('gcal-contacts-result'), at: await text('gcal-contacts-last-sync') })
  await shot('1440-on')

  /* CS5 */
  await p.click('[data-testid=ui-dialog] [data-test=gcal-contacts-switch]')
  ok('CS5-1 off says so', await cview('off') && (await text('gcal-contacts-result')) === 'Contacts sync is off.', { said: await text('gcal-contacts-result') })
  await load(DESKTOP, SETTINGS)
  ok('CS5-2 off after a reload', await cview('off') && (await checked())?.on === false)

  /* CS6 */
  await seed(CONNECTED, ME_ON, JSON.stringify({ elsewhere: true }))
  await load(DESKTOP, SETTINGS)
  ok('CS6-1 elsewhere: the line, the switch off and disabled', await cview('elsewhere')
    && (await text('gcal-contacts-elsewhere')) === 'Contacts sync is on in another of your workspaces. Turn it off there first.'
    && (await checked())?.disabled === true && (await checked())?.on === false, await checked())
  await shot('1440-elsewhere')

  /* CS7 */
  await seed(CONNECTED, ME_ON, JSON.stringify({ enabled: true, scope_granted: false }))
  await load(DESKTOP, SETTINGS)
  ok('CS7-1 on with no grant: the line and Give access', await cview('grant') && await has('gcal-contacts-grant')
    && (await text('gcal-contacts-grant-needed')) === 'Google has not given access to your contacts yet.')
  await p.click('[data-testid=ui-dialog] [data-test=gcal-contacts-grant]')
  ok('CS7-2 Give access: the grant is read back, on', await cview('on'))

  /* CS8 */
  await seed(CONNECTED, ME_ON, 'off')
  await load(DESKTOP, SETTINGS)
  ok("CS8-1 'off' (404): connected, no switch", await gview('connected') && !(await has('gcal-contacts')))

  /* P */
  await seed(CONNECTED, ME_ON, JSON.stringify({ enabled: true, scope_granted: true, last_synced_at: '2026-11-22T08:00:00Z', status_detail: 'Google contacts sync: pictures: 2 contact(s) have no picture' }))
  await load(PHONE, SETTINGS)
  ok('P1 390: on, with its status line', await cview('on') && (await text('gcal-contacts-detail')).startsWith('Google contacts sync:'))
  const phone = await p.evaluate(() => ({
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    short: [...document.querySelectorAll('[data-testid=ui-dialog] [data-test=gcal] button, [data-testid=ui-dialog] .gcal__switch')]
      .filter((b) => b.getBoundingClientRect().width > 0 && b.getBoundingClientRect().height < 44).map((b) => b.dataset.test || b.className),
  }))
  ok('P2 390: no sideways scroll, every button and the switch row >= 44 px', phone.over <= 0 && phone.short.length === 0, phone)
  await shot('390-on')

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
