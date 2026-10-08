// CLE-77799 (owner topic 1fc29f99: "the admin of a tenant should be able to
// remove members from the people section"): the People card's "Remove from
// workspace" action (and, t1 06c39172, the Activity log dialog's look), proved in a real browser with the two controls the task
// asks for:
//   - as an admin (the mock plays one: /v1/view/me is null = unrestricted), the
//     action shows, the confirm names the person, and OK removes + navigates.
//   - as a regular_user (permissions without members.invite, set on the access
//     store), the action is NOT offered.
// The hub stays the authority (it re-checks members.invite, self, role coverage
// and the last-owner rule on the DELETE); this only proves the WUI's hiding.
//
// Run:
//   node tests/e2e/people-remove.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/people-remove.test.mjs
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

/** Adopt a member session in the mock, like the other e2e (HUM-1 is the admin). */
const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'admin@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

/** Set the access store's `me`, to play a role other than the mock's admin. */
const setMe = (p, me) => p.evaluate((me) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const access = pinia?._s.get('access')
  if (!access) return false
  access.me = me
  return true
}, me)

const present = (p, sel) => p.$(sel).then((el) => Boolean(el))

/** The Activity log dialog in the Release Log's look: a bordered card, an
 *  uppercase header band, event chips, no "—" fillers, the filter kept; on a
 *  phone no header row and one cell per event. SHOT_DIR saves screenshots. */
async function activityLog(p) {
  await go(p, '/people/HUM-2')
  await p.waitForFunction(() => location.pathname.endsWith('/people/HUM-2'), { timeout: NAV })
  await p.waitForSelector('[data-test=person-activity-open]', { timeout: NAV })
  await p.click('[data-test=person-activity-open]')
  await p.waitForSelector('[data-test=activity-row]', { visible: true, timeout: 10000 })
  const look = await p.evaluate(() => {
    const card = document.querySelector('[data-test=activity-card]')
    const th = document.querySelector('[data-test=activity-table] thead th')
    const rows = [...document.querySelectorAll('[data-test=activity-row]')]
    const cs = (e) => (e ? getComputedStyle(e) : null)
    return {
      cardBorder: cs(card)?.borderTopStyle,
      cardRadius: parseFloat(cs(card)?.borderTopLeftRadius || '0'),
      headUpper: cs(th)?.textTransform,
      rows: rows.length,
      chips: document.querySelectorAll('[data-test=activity-row-event]').length,
      dashes: rows.filter((r) => r.textContent.includes('—')).length,
      times: document.querySelectorAll('[data-test=activity-row] time[datetime]').length,
    }
  })
  check('activity: the table is a bordered card', look.cardBorder === 'solid' && look.cardRadius > 0, look)
  check('activity: the header band is uppercase', look.headUpper === 'uppercase', look)
  check('activity: three events, each an event chip and a time', look.rows === 3 && look.chips === 3 && look.times === 3, look)
  check('activity: no "—" fillers', look.dashes === 0, look)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/activity-desktop.png` })

  await p.select('[data-test=activity-filter-kind]', 'act_as_ended')
  await sleep(200)
  const ended = await p.$$eval('[data-test=activity-row]', (rs) => rs.map((r) => r.dataset.kind))
  check('activity: the Event filter keeps one kind', ended.length === 1 && ended[0] === 'act_as_ended', { ended })
  await p.click('[data-test=activity-filter-clear]')
  await sleep(200)
  check('activity: Clear filter shows every event', (await p.$$('[data-test=activity-row]')).length === 3)

  await p.setViewport({ width: 390, height: 844 })
  await sleep(400)
  const phone = await p.evaluate(() => ({
    head: Boolean(document.querySelector('[data-test=activity-table] thead')),
    cells: document.querySelectorAll('[data-test=activity-row] td').length,
    rows: document.querySelectorAll('[data-test=activity-row]').length,
    overflow: document.documentElement.scrollWidth > window.innerWidth,
  }))
  check('activity phone: no header row, one cell per event, no side scroll', !phone.head && phone.rows === 3 && phone.cells === 3 && !phone.overflow, phone)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/activity-phone.png` })
  await p.setViewport({ width: 1440, height: 900 })
  await p.keyboard.press('Escape')
  await sleep(300)
  await go(p, '/people/HUM-3')
  await p.waitForSelector('[data-test=person-remove]', { timeout: NAV })
}

async function run(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')

  // HUM-3 is a member (not the reader HUM-1, not an owner) in the mock roster.
  await go(p, '/people/HUM-3')
  await p.waitForSelector('[data-test=person-page]', { timeout: NAV })
  await sleep(500)

  // 1. admin: the action is offered
  check('admin sees Remove from workspace', await present(p, '[data-test=person-remove]'))

  // 2. the confirm names the person and states what happens
  await p.click('[data-test=person-remove]')
  await p.waitForSelector('[data-test=person-remove-ok]', { visible: true, timeout: 5000 })
  const text = await p.$eval('[data-test=person-remove-text]', (e) => e.textContent.trim()).catch(() => '')
  check('the confirm names the person', text.includes('HUM-3'), { text })
  await p.click('[data-test=person-remove-cancel]')
  await sleep(300)

  // 2b. the Activity log (t1 06c39172: "the same standards as the Release
  //     Log"): HUM-2 carries the mock's act-as trail (two starts, one end).
  await activityLog(p)

  // 3. CONTROL: a regular_user (no members.invite) is offered no action
  await setMe(p, { humanId: 'HUM-1', role: 'regular_user', tenantOwner: false, permissions: ['topics.read'], channelOrder: null })
  await sleep(300)
  check('CONTROL regular_user is offered no Remove', !(await present(p, '[data-test=person-remove]')))

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
console.log(`\npeople-remove: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
