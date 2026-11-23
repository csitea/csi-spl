// SPL-6316 (spec 154; owner, t1 b400601b msgs cabc83c5 + 7d3d4464: "the
// google contacs sync is in 2 places" ... "leave it only under the Google
// sync"): the Google Contacts switch has one place, Settings -> Google Sync.
// SPL-6284 put it in the Settings list as its own Contacts row too; that row
// is gone, and Google Sync keeps what SPL-6284 fixed for phones: its
// contacts part shows in every Google state. Mock tenant signed in;
// localStorage spool.mock.gcal is the calendar connection, spool.mock.me
// plays GET /v1/view/me (its contacts kill switch, 2.9),
// spool.mock.contacts_sync the GET /v1/me/contacts/sync state.
//   M1 390, contacts on: the Settings list has no Contacts row, and a Google
//      Sync row >= 44 px
//   M2 CONTROL 390, contacts off: no Contacts row either, Google Sync listed
//   M3 390, Google not connected: Google Sync shows Connect and the contacts
//      part that says how to start (Give access to Google Contacts)
//   M4 its button connects Google (the mock grants calendar and contacts):
//      the switch shows, off, next to the calendar facts
//   M5 390, connected: Google Sync shows the calendar facts, the switch and
//      Disconnect; turning the switch on starts the first import
//   M6 the old address ?settings=contacts lands on Google Sync (its section
//      and calendar facts), not a Contacts-only section
//   M7 contacts off in the workspace, connected: no contacts part
//   P  no sideways scroll, every button >= 44 px; no page errors
// Red control: on the master bundle before SPL-6316 (c0fe7647a) M1 fails:
// "FAIL M1 390, contacts on: no Contacts row, Google Sync listed >= 44 px",
// the list still draws the Contacts row; M6 fails too (the old address opens
// the Contacts-only section).
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
const OLD_PAGE = '/channel/general?settings=contacts'
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
  const row = (id) => p.$eval(`${D} [data-test=settings-nav-${id}]`, (a) => {
    const r = a.getBoundingClientRect()
    return { text: a.textContent.trim(), h: Math.round(r.height), w: Math.round(r.width) }
  }).catch(() => null)
  const sectionOpen = (test) => visible(`${D} [data-test=${test}]`)
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-contacts-mobile-${name}.png` }) }

  await load('/channel/general')

  /* M1 */
  await seed(null, ME_ON, null)
  await load(LIST)
  await visible(`${D} [data-test=settings-nav-calendar-google]`)
  const g1 = await row('calendar-google')
  ok('M1 390, contacts on: no Contacts row, Google Sync listed >= 44 px', (await row('contacts')) === null && Boolean(g1) && g1.text === 'Google Sync' && g1.h >= 44, g1)
  await shot('list')

  /* M2 */
  await seed(null, ME_OFF, null)
  await load(LIST)
  await visible(`${D} [data-test=settings-nav-calendar-google]`)
  ok('M2 CONTROL 390, contacts off: no Contacts row, Google Sync listed', (await row('contacts')) === null && Boolean(await row('calendar-google')))

  /* M3 */
  await seed(null, ME_ON, null)
  await load(LIST)
  await visible(`${D} [data-test=settings-nav-calendar-google]`)
  await p.tap(`${D} [data-test=settings-nav-calendar-google]`)
  ok('M3-1 not connected: Google Sync shows Connect and the contacts part, saying how to start', await cview('connect') && await has('gcal-connect')
    && (await text('gcal-contacts-connect')) === 'Give access to Google Contacts', { said: await text('gcal-contacts-connect') })
  ok('M3-2 the address is ?settings=calendar-google', new URL(p.url()).searchParams.get('settings') === 'calendar-google')
  await shot('connect')

  /* M4 */
  await p.tap(`${D} [data-test=gcal-contacts-connect]`)
  ok('M4 its button connects Google with the contacts grant: the switch shows, off, with the calendar facts', await cview('off') && await has('gcal-contacts-switch') && await has('gcal-connected'))

  /* M5 */
  await seed(CONNECTED, ME_ON, null)
  await load(GCAL_PAGE)
  ok('M5-1 connected: the calendar facts, the switch and Disconnect', await cview('off') && await has('gcal-connected') && await has('gcal-disconnect'))
  await p.tap(`${D} [data-test=gcal-contacts-switch]`)
  await visible(`${D} [data-test=gcal-contacts-result]`, 5000)
  ok('M5-2 on: the first import started', await cview('on') && (await text('gcal-contacts-result')) === 'Contacts sync is on. The first import has started.', { said: await text('gcal-contacts-result') })
  await shot('on')

  /* M6 */
  await seed(CONNECTED, ME_ON, null)
  await load(OLD_PAGE)
  const m6 = await sectionOpen('settings-calendar-google') && await cview('off')
  ok('M6 ?settings=contacts lands on Google Sync: its section, calendar facts and the switch, no Contacts-only section', m6 && await has('gcal-connected')
    && !(await has('settings-contacts')))
  await shot('old-link')

  /* M7 */
  await seed(CONNECTED, ME_OFF, null)
  await load(GCAL_PAGE)
  await visible(`${D} [data-test=gcal-connected]`)
  ok('M7 contacts off, connected: no contacts part', !(await has('gcal-contacts')) && await has('gcal-connected'))

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
