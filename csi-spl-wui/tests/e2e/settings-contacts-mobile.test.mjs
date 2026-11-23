// SPL-6284 (spec 154; owner, t1 b400601b msg e4a482d1: "Not visible in
// mobile"): on a phone the Google contacts import is findable from the
// Settings list, and its section shows in every Google state. Mock tenant
// signed in; localStorage spool.mock.gcal is the calendar connection,
// spool.mock.me plays GET /v1/view/me (its contacts kill switch, 2.9),
// spool.mock.contacts_sync the GET /v1/me/contacts/sync state.
//   M1 390, contacts on: the Settings list has a Contacts row, >= 44 px high
//   M2 CONTROL 390, contacts off in the workspace: no Contacts row
//   M3 390, Google not connected: Contacts opens a section that says how to
//      start (Give access to Google Contacts); no calendar facts
//   M4 its button connects Google (the mock grants calendar and contacts);
//      the switch shows, off, the contacts scope granted
//   M5 390, connected: Contacts shows the switch, not the calendar facts or
//      Disconnect; turning it on starts the first import
//   M6 390, Google Calendar not connected: the Contacts part is there too
//   P  no sideways scroll, every button >= 44 px; no page errors
// Red control: on origin/master bed9d989c (before SPL-6284) M1, M3, M4, M5
// and M6 fail: there is no Contacts row, and not connected shows no
// Contacts part at all.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/settings-contacts-mobile.test.mjs
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
const PHONE = { name: '390', width: 390, height: 844, mobile: true, touch: true }
const D = '[data-testid=ui-dialog]'
const CONTACTS = `${D} [data-test=gcal-contacts]`
const LIST = '/channel/general?settings='
const PAGE = '/channel/general?settings=contacts'
const GCAL_PAGE = '/channel/general?settings=calendar-google'
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

  const load = async (path) => {
    await setPageViewport(p, PHONE)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, PHONE)
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
  const visible = (sel, timeout = 10000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true).catch(() => false)
  const cview = (want) => visible(`${CONTACTS}[data-view="${want}"]`)
  const has = (test) => p.evaluate((t) => {
    const e = document.querySelector(`[data-testid=ui-dialog] [data-test="${t}"]`)
    return Boolean(e && e.getBoundingClientRect().width > 0)
  }, test)
  const text = (test) => p.$eval(`${D} [data-test="${test}"]`, (e) => e.textContent.trim()).catch(() => '')
  const row = () => p.$eval(`${D} [data-test=settings-nav-contacts]`, (a) => {
    const r = a.getBoundingClientRect()
    return { text: a.textContent.trim(), h: Math.round(r.height), w: Math.round(r.width) }
  }).catch(() => null)
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-contacts-mobile-${name}.png` }) }

  await load('/channel/general')

  /* M1 */
  await seed(null, ME_ON, null)
  await load(LIST)
  await visible(`${D} [data-test=settings-nav]`)
  await visible(`${D} [data-test=settings-nav-contacts]`, 5000)
  const r1 = await row()
  ok('M1 390, contacts on: the Settings list has a Contacts row >= 44 px', Boolean(r1) && r1.text === 'Contacts' && r1.h >= 44, r1)
  await shot('list')

  /* M2 */
  await seed(null, ME_OFF, null)
  await load(LIST)
  await visible(`${D} [data-test=settings-nav-profile]`)
  ok('M2 CONTROL 390, contacts off: no Contacts row', (await row()) === null && await has('settings-nav-profile'))

  /* M3 */
  await seed(null, ME_ON, null)
  await load(LIST)
  await visible(`${D} [data-test=settings-nav-contacts]`)
  await p.tap(`${D} [data-test=settings-nav-contacts]`)
  ok('M3-1 not connected: Contacts opens on its section, saying how to start', await cview('connect') && await has('gcal-contacts-connect')
    && (await text('gcal-contacts-connect')) === 'Give access to Google Contacts', { said: await text('gcal-contacts-connect') })
  ok('M3-2 the address is ?settings=contacts, the calendar Connect and facts are not there',
    new URL(p.url()).searchParams.get('settings') === 'contacts' && !(await has('gcal-connect')) && !(await has('gcal-connected')))
  await shot('connect')

  /* M4 */
  await p.tap(`${D} [data-test=gcal-contacts-connect]`)
  ok('M4 its button connects Google with the contacts grant: the switch shows, off', await cview('off') && await has('gcal-contacts-switch'))

  /* M5 */
  await seed(CONNECTED, ME_ON, null)
  await load(PAGE)
  ok('M5-1 connected: the switch, no calendar facts, no Disconnect', await cview('off') && !(await has('gcal-connected')) && !(await has('gcal-disconnect')))
  await p.tap(`${D} [data-test=gcal-contacts-switch]`)
  await visible(`${D} [data-test=gcal-contacts-result]`, 5000)
  ok('M5-2 on: the first import started', await cview('on') && (await text('gcal-contacts-result')) === 'Contacts sync is on. The first import has started.', { said: await text('gcal-contacts-result') })
  await shot('on')

  /* M6 */
  await seed(null, ME_ON, null)
  await load(GCAL_PAGE)
  ok('M6 Google Calendar not connected: Connect and the Contacts part are both there', await cview('connect') && await has('gcal-connect'))

  /* P */
  const phone = await p.evaluate(() => ({
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    short: [...document.querySelectorAll('[data-testid=ui-dialog] [data-test=gcal] button')]
      .filter((b) => b.getBoundingClientRect().width > 0 && b.getBoundingClientRect().height < 44).map((b) => b.dataset.test || b.className),
  }))
  ok('P1 390: no sideways scroll, every button >= 44 px', phone.over <= 0 && phone.short.length === 0, phone)
  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('P2 no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
