// Spec 155 2.6 (SPL-6153): entering Notes puts the keyboard focus on the +
// (New note, data-test=notes-new), so Enter makes a note at once.
//
// Owner HUM-10 (t1 1f25c14e, msg 17b9aebc): "the notes , whenever one clicks
// on the notes the first selected element should be the plus button so that
// one quickly could create a new note".
//
// Cases, on the mock bundle at 1440 px and at a 390 px phone:
//   a click / tap on the rail's Notes tab lands on /notes with the focus on
//   the +; at 1440 px Enter on it makes a note and opens it;
//   the route /notes, pushed from another page: the focus is on the +;
//   SPL-6063 kept (1440 px): Esc out of a note opened from its row leaves
//   the focus on that row, not on the +.
// CONTROL: with the fix out (pages/notes.vue: no focusNew on mount) the "+"
// checks FAIL on origin/master.
//
// Run:
//   node tests/e2e/notes-open-focus-new.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-open-focus-new.test.mjs
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
const order = (p) => p.$$eval('[data-test=notes-row]', (els) => els.map((e) => e.getAttribute('data-note-id')))
const waitDetail = (p, id) => p.waitForSelector(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
const waitGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).then(() => true, () => false)
/* where the focus is: a note row's id, else the element's tag / test id */
const focusAt = (p) => p.evaluate(() => {
  const a = document.activeElement
  const row = a?.closest?.('[data-test=notes-row]')
  if (row && a.matches('[data-test=notes-open]')) return row.getAttribute('data-note-id')
  const id = a?.getAttribute?.('data-test') || a?.getAttribute?.('data-testid') || ''
  return `${a?.tagName || 'none'}${id ? '[' + id + ']' : ''}`
})
const focusOnNew = (p) => p.waitForFunction(() => document.activeElement?.matches?.('[data-test=notes-new]'), { timeout: 5000 }).then(() => true, () => false)
const focusOnRow = (p, want) => p.waitForFunction((want) => {
  const a = document.activeElement
  return a?.matches?.('[data-test=notes-open]') && a.closest('[data-test=notes-row]')?.getAttribute('data-note-id') === want
}, { timeout: 3000 }, want).then(() => true, () => false)

async function openPage(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  return p
}

/* the rail's Notes tab, clicked or tapped */
async function fromRail(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/channel/general')
  await p.waitForSelector('[data-testid=sidebar-tab-notes]', { timeout: NAV }).catch(() => null)
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-notes]')?.scrollIntoView({ inline: 'center', block: 'center' }))
  const tab = await p.waitForSelector('[data-testid=sidebar-tab-notes]', { visible: true, timeout: 15000 }).catch(() => null)
  check(`${tag}: the rail draws the Notes tab`, Boolean(tab))
  if (!tab) return p.close()
  if (touch) await tab.tap()
  else await tab.click()
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  check(`${tag}: the rail's Notes: the focus is on the +`, await focusOnNew(p), await focusAt(p))
  if (!touch) {
    const before = await order(p)
    await p.keyboard.press('Enter')
    const made = await p.waitForFunction((before) => {
      const ids = [...document.querySelectorAll('[data-test=notes-row]')].map((e) => e.getAttribute('data-note-id'))
      return ids.find((id) => !before.includes(id)) || false
    }, { timeout: 15000 }, before).then((h) => h.jsonValue(), () => '')
    check(`${tag}: Enter on the + makes a note and opens it`, Boolean(made) && await waitDetail(p, made), made)
  }
  await p.close()
}

/* the route /notes, pushed from another page */
async function fromRoute(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await openPage(browser, base, width, touch)
  await go(p, '/channel/general')
  await p.waitForSelector('[data-testid=sidebar-rail]', { timeout: NAV }).catch(() => null)
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  check(`${tag}: /notes: the focus is on the +`, await focusOnNew(p), await focusAt(p))
  await p.close()
}

/* SPL-6063 kept: Esc out of a note goes back to its row, not to the + */
async function escKeepsRow(browser, base) {
  const p = await openPage(browser, base, 1440, false)
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  const [, second] = await order(p)
  await p.click(`[data-note-id="${second}"] [data-test=notes-open]`)
  check('1440px: a click on a row opens its note', await waitDetail(p, second))
  await p.click('[data-test=note-title]')
  await p.keyboard.press('Escape')
  check('1440px: Esc closes the note', await waitGone(p))
  check('1440px: Esc: the focus is on the closed note\'s row, not on the +', await focusOnRow(p, second), await focusAt(p))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await fromRail(browser, server.base, 1440, false)
  await fromRail(browser, server.base, 390, true)
  await fromRoute(browser, server.base, 1440, false)
  await fromRoute(browser, server.base, 390, true)
  await escKeepsRow(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-open-focus-new: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
