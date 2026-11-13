// SPL-5431 (spec 154 section 12; owner t1 30f935b4 msg 4329fec1: "at least
// their email and their names should be visible to all of the other people
// in the workspace"): the person card shows the member's address as a
// mailto: link, read from the member card route (the mock answers a HUM-<n>
// with an example.com address). CONTROL: under act-as the card does not read
// it and shows no Email row (the hub refuses it with 403 person_only).
// The hub's gates (same workspace only, person only) are hub tests:
// hub/member_card_test.go. SHOT_DIR saves the screenshot.
//
// Run:
//   node tests/e2e/people-email.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/people-email.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'admin@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

/* Waits for the page life's one access load first, so its answer cannot
   overwrite the planted `me` afterwards. */
const setMe = (p, me) => p.evaluate(async (me) => {
  const access = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('access')
  if (!access) return false
  await access.load()
  access.me = me
  return true
}, me)

const emailRow = (p) => p.$eval('[data-test=person-email] a', (a) => ({ text: a.textContent.trim(), href: a.getAttribute('href') })).catch(() => null)

async function run(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')

  await go(p, '/people/HUM-2')
  await p.waitForSelector('[data-test=person-email]', { timeout: NAV }).catch(() => null)
  const row = await emailRow(p)
  check('the card shows the member\'s email as a mailto: link', row?.text === 'hum-2@example.com' && row?.href === 'mailto:hum-2@example.com', row)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/people-card-email.png` })

  await p.setViewport({ width: 390, height: 844 })
  await sleep(400)
  const phone = await p.evaluate(() => ({ overflow: document.documentElement.scrollWidth > window.innerWidth, row: Boolean(document.querySelector('[data-test=person-email]')) }))
  check('phone: the row shows, no side scroll', phone.row && !phone.overflow, phone)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/people-card-email-phone.png` })
  await p.setViewport({ width: 1440, height: 900 })

  // CONTROL: the session turns act-as on this card: the address goes, since
  // the card never reads it under act-as (the hub refuses it, 403 person_only)
  await go(p, '/people/HUM-3')
  await p.waitForSelector('[data-test=person-email]', { timeout: NAV }).catch(() => null)
  check('twin: HUM-3\'s card shows its address before act-as', (await emailRow(p))?.text === 'hum-3@example.com')
  await setMe(p, { humanId: 'HUM-1', role: 'regular_user', tenantOwner: false, permissions: ['topics.read'], channelOrder: null, actAs: { targetHum: 'HUM-1', targetName: 'HUM-1', expiresAt: '' } })
  await sleep(800)
  check('CONTROL act-as: no Email row', !(await p.$('[data-test=person-email]')))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\npeople-email: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
