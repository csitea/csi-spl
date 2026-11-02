// Spec 155 (SPL-4615; owner HUM-10, t1 cb9d7bdc, msg b75fb3d3): the Notes rail
// tab is on. On the mock bundle at 1440 px and at a 390 px phone:
//   the rail draws Notes right after Calendar (D5), Archive last; the tab is
//     visible and a real click or tap lands on /notes
//   section 6: the hub's 404 notes_off (read by the store as `off`) hides the
//     tab. CONTROL (the twin): a failed read (`failed`) keeps the tab; a list
//     that comes back (`ready`) brings it back
//
// Red control: with NOTES_RAIL_ON false every "the rail" check FAILs; with the
// notes_off filter out of useRailOrder the "hides" checks FAIL (the output is
// in the commit body).
//
// Run:
//   BASE_URL=http://127.0.0.1:3000 SHOT_DIR=<dir> node tests/e2e/notes-rail-on.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  return p
}

const railOf = (p) => p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
const railHas = (p, want) => p.waitForFunction((want) => Boolean(document.querySelector('[data-testid=sidebar-tab-notes]')) === want, { timeout: 5000 }, want).then(() => true, () => false)
/* the rail's boot read (useRailOrder -> useAddToNote.probe) made the store */
const storeUp = (p) => p.waitForFunction(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')?.state === 'ready', { timeout: 15000 }).then(() => true, () => false)
const setState = (p, state) => p.evaluate((state) => { document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').state = state }, state)

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/channel/general')
  await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
  check(`${tag}: signed in on a channel page, the rail read the notes once (idle, no notes page open)`, await storeUp(p))
  const rail = await railOf(p)
  check(`${tag}: the rail has Notes right after Calendar`, rail.includes('notes') && rail.indexOf('notes') === rail.indexOf('calendar') + 1, rail)
  check(`${tag}: the rail keeps Archive last`, rail.at(-1) === 'archive', rail)
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-notes]')?.scrollIntoView({ inline: 'center', block: 'center' }))
  const tab = await p.waitForSelector('[data-testid=sidebar-tab-notes]', { visible: true, timeout: 5000 }).catch(() => null)
  check(`${tag}: the rail draws the Notes tab visible`, Boolean(tab))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/rail-notes-${width}.png` })
  if (tab) {
    if (touch) await tab.tap()
    else await tab.click()
    check(`${tag}: the tab lands on /notes`, await p.waitForFunction(() => location.pathname === '/notes', { timeout: 15000 }).then(() => true, () => false), await p.evaluate(() => location.pathname))
  }
  await setState(p, 'failed')
  check(`${tag} CONTROL: a failed read keeps the tab`, await railHas(p, true) && !(await p.waitForFunction(() => !document.querySelector('[data-testid=sidebar-tab-notes]'), { timeout: 1000 }).then(() => true, () => false)))
  await setState(p, 'off')
  check(`${tag}: notes_off hides the tab`, await railHas(p, false), await railOf(p))
  const off = await railOf(p)
  check(`${tag}: notes_off leaves the other tabs, Archive last`, off.length === rail.length - 1 && off.at(-1) === 'archive', off)
  await setState(p, 'ready')
  check(`${tag} CONTROL: a list that comes back brings the tab back`, await railHas(p, true))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base, 1440, false)
  await run(browser, server.base, 390, true)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-rail-on: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
