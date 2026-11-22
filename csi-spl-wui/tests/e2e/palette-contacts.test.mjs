// Spec 154 B10 (C26): the reader's contacts in the command palette's `people`
// group, in a real browser, mock tenant signed in. localStorage spool.mock.me
// plays GET /v1/view/me (its contacts switch); spool.mock.contacts holds the
// list and globalThis.SPOOL_MOCK_CONTACTS_READS counts its reads
// (utils/contacts-client.mjs).
//   C26-1  the first open reads the list once; a second open reads nothing
//   C26-2  a contact's name lists it in the people group; Enter opens its card
//   C26-3  its email finds it too
//   C26-4  a contact matched to a member (HUM-2) shows once, as that member
//   C26-5  contacts: false = no contact row and no read
// CONTROL: C26-4 first asserts the member's own row is listed, so "no contact
// row" cannot pass on an empty list. Red control: on master before B10
// C26-2 fails, the palette has no contact row.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/palette-contacts.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const PALETTE = '[data-testid=command-palette]'
const INPUT = '[data-testid=command-palette-input]'
const shown = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))
const gone = (sel) => !document.querySelector(sel)
const rowIds = () => [...document.querySelectorAll('[data-testid=command-palette-row]')].map((r) => r.getAttribute('data-item'))
const reads = () => globalThis.SPOOL_MOCK_CONTACTS_READS || 0

const ON = { role: 'regular_user', permissions: [], contacts: true }
const OFF = { role: 'regular_user', permissions: [], contacts: false }
const olive = { contact_id: 'k-out', first_name: 'Olive', last_name: 'Outer', email: 'olive.outer@example.com', phone: null, google: false, member_id: null }
const twin = { contact_id: 'k-in', first_name: 'Inner', last_name: 'Person', email: 'inner@example.com', phone: null, google: false, member_id: 'HUM-2' }

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.removeItem('spool.palette-recent')
    } catch { /* opaque origin on the very first document */ }
  })
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })

  const load = async (me, list) => {
    await p.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
    await p.evaluate((m, l) => {
      localStorage.setItem('spool.mock.me', JSON.stringify(m))
      localStorage.setItem('spool.mock.contacts', JSON.stringify(l))
    }, me, list)
    await p.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await sleep(600)
  }
  const open = async (text) => {
    await p.keyboard.down('Control')
    await p.keyboard.press('k')
    await p.keyboard.up('Control')
    const up = await until(p, shown, PALETTE, 6000)
    if (up && text) await p.type(INPUT, text)
    return up
  }
  const close = async () => {
    await p.keyboard.press('Escape')
    return until(p, gone, PALETTE, 4000)
  }

  await load(ON, [olive, twin])
  const before = await p.evaluate(reads)
  ok('C26-1 the palette opens', await open('olive'))
  ok('C26-2 "olive" lists the contact row first', await until(p, () => document.querySelector('[data-testid=command-palette-row]')?.getAttribute('data-item') === 'contact:k-out', null, 6000), await p.evaluate(rowIds))
  ok('C26-1 the first open read the list once', (await p.evaluate(reads)) - before === 1, { before, after: await p.evaluate(reads) })
  await p.keyboard.press('Enter')
  ok('C26-2 Enter opens the contact card', await until(p, () => /\/people\/contact\/k-out$/.test(location.pathname), null, 8000), await p.evaluate(() => location.pathname))
  ok('... and closes the palette', await until(p, gone, PALETTE, 4000))

  const held = await p.evaluate(reads)
  ok('C26-3 a second open finds the contact by email', (await open('olive.outer@')) && await until(p, () => document.querySelector('[data-testid=command-palette-row]')?.getAttribute('data-item') === 'contact:k-out', null, 6000), await p.evaluate(rowIds))
  ok('C26-1 ... and reads the list no more', (await p.evaluate(reads)) === held, { held, now: await p.evaluate(reads) })
  await close()

  ok('C26-4 the palette opens on "HUM-2"', await open('HUM-2'))
  const memberRow = await until(p, () => [...document.querySelectorAll('[data-testid=command-palette-row]')].some((r) => (r.getAttribute('data-item') || '').startsWith('dm:HUM-2')), null, 6000)
  ok('C26-4 control: the member HUM-2 is listed', memberRow, await p.evaluate(rowIds))
  await close()
  await open('inner')
  await sleep(400)
  ok('C26-4 the matched contact has no row of its own', !(await p.evaluate(rowIds)).includes('contact:k-in'), await p.evaluate(rowIds))
  await close()

  await load(OFF, [olive])
  const offBefore = await p.evaluate(reads)
  await open('olive')
  await sleep(800)
  ok('C26-5 contacts off: no contact row', !(await p.evaluate(rowIds)).includes('contact:k-out'), await p.evaluate(rowIds))
  ok('C26-5 ... and no read', (await p.evaluate(reads)) === offBefore, { offBefore, now: await p.evaluate(reads) })
  await close()

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
