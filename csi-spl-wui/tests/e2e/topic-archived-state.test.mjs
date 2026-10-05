// t1 64ce816a (owner, HUM-10: "a topic accessed from the topics section /
// view, it is not clear whether is active or archived"). Real browser, mock
// tenant, 1440 and 390, light and dark:
//
//   archived  open an archived topic from Topics (home ?topic= and /t/:id):
//             the topic header's Archived badge is in view and its visible
//             text carries the word and the archive day (YYYY-MM-DD). The
//             hover title is not enough: a phone has no hover.
//   control   the same header on a live topic has no Archived badge
//
// A full page load resets the mock, so the archive and the reopen stay on
// one document (client navigation).
//
//   BASE_URL=<generated bundle> node tests/e2e/topic-archived-state.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const ARCH = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const LIVE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const DATE = /\d{4}-\d{2}-\d{2}/

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

async function until(p, fn, ms = 8000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn)) return true
    await sleep(150)
  }
  return false
}

/* The open topic's own header, not a list row. */
const snap = () => {
  const inView = (el) => {
    if (!el) return false
    const r = el.getBoundingClientRect()
    const s = getComputedStyle(el)
    return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0
      && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth
  }
  const header = document.querySelector('[data-test=topic-section] header')
  const badge = header && header.querySelector('[data-test=archived-badge]')
  const when = badge && badge.querySelector('.archived-badge__when')
  const clip = header && header.querySelector('[data-testid=card-clip-control]')
  const text = badge ? badge.textContent.replace(/\s+/g, ' ').trim() : ''
  return {
    text,
    title: badge ? badge.getAttribute('title') || '' : '',
    whenText: when ? when.textContent.trim() : '',
    badgeInView: Boolean(badge && inView(badge)),
    whenInView: Boolean(when && inView(when)),
    clipInView: Boolean(clip && inView(clip)),
    xScroll: document.documentElement.scrollWidth > innerWidth + 1,
    color: badge ? getComputedStyle(badge).color : '',
    bg: header ? getComputedStyle(header).backgroundColor : '',
  }
}


/* Open the Topics row menu and choose Archive. True once that row has left
   the list, which is what the app does after a successful archive. */
/* Phone level 1 does not mount the home list. The topics rail is the
   list on screen; its row menu id is th:<id>, and the row leaves after
   Archive the same way the home row does. */
async function archiveFromRail(p, taskId) {
  const btn = `[data-menu-id="th:${taskId}"]`
  await p.waitForSelector(btn, { timeout: 15000 })
  let opened = false
  for (let i = 0; i < 4 && !opened; i++) {
    await p.evaluate((sel) => document.querySelector(sel)?.click(), btn)
    opened = await until(p, () => Boolean(document.querySelector('[data-testid=sidebar-row-menu-archive]')), 4000)
  }
  if (!opened) return false
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-row-menu-archive]')?.click())
  const t0 = Date.now()
  while (Date.now() - t0 < 8000) {
    const gone = await p.evaluate((id) => !document.querySelector(`#sidebar-panel-topics [data-key="${id}"]`), taskId)
    if (gone) return true
    await sleep(150)
  }
  return false
}

async function archiveFromList(p, taskId) {
  const btn = `[data-menu-id="home:${taskId}"]`
  await p.waitForSelector(btn, { timeout: 15000 })
  let opened = false
  for (let i = 0; i < 4 && !opened; i++) {
    await p.evaluate((sel) => document.querySelector(sel)?.click(), btn)
    opened = await until(p, () => Boolean(document.querySelector('[data-testid=sidebar-row-menu-archive]')), 4000)
  }
  if (!opened) return false
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-row-menu-archive]')?.click())
  const t0 = Date.now()
  while (Date.now() - t0 < 8000) {
    const gone = await p.evaluate((id) => !document.querySelector(`a.topic-row[data-key="${id}"]`), taskId)
    if (gone) return true
    await sleep(150)
  }
  return false
}

async function run(browser, base, width, theme) {
  const p = await browser.newPage()
  const phone = width < 600
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument((claims, themeName) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* */ }
    try { localStorage.setItem('spool-theme', themeName) } catch { /* */ }
  }, CLAIMS, theme)
  const tag = `${width} ${theme}`

  /* A cold dev compile can miss the first paint. One retry, then the
     visible text, so a red log says what was on screen. */
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  await p.evaluate((name) => { document.documentElement.setAttribute('data-theme', name) }, theme)
  let archived = false
  if (phone) {
    await p.waitForSelector('[data-testid=sidebar-tab-topics]', { timeout: 15000 })
    await p.click('[data-testid=sidebar-tab-topics]')
    archived = await archiveFromRail(p, ARCH)
  } else {
    let listed = false
    let listedText = ''
    for (let i = 0; i < 2 && !listed; i++) {
      if (i) await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
      listed = await until(p, () => Boolean(document.querySelector('a.topic-row')), 20000)
      if (!listed) listedText = await p.evaluate(() => (document.body && document.body.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 180)).catch(() => '')
    }
    if (!listed) throw new Error('topics list never appeared: ' + listedText)
    /* Archive from the row menu. The generated bundle does not put the page
       instance on the DOM, so a dev-only __vueParentComponent walk cannot
       reach the mock. The menu is the same control a person uses. */
    archived = await archiveFromList(p, ARCH)
  }
  check(`${tag}: archived the fixture topic`, archived)

  const open = (path) => p.evaluate(async (to) => {
    const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
    await r.push(to)
  }, path)

  await open(`/?topic=${ARCH}`)
  await until(p, () => Boolean(document.querySelector('[data-test=topic-section] header [data-test=archived-badge]')))
  await sleep(300)
  const home = await p.evaluate(snap)
  check(`${tag}: topics home, archived topic header shows Archived and the day, in view`,
    /archived/i.test(home.text) && DATE.test(home.text) && DATE.test(home.whenText) && home.badgeInView && home.whenInView && home.clipInView && !home.xScroll && home.color && home.color !== home.bg,
    home)

  await open(`/?topic=${LIVE}`)
  await until(p, () => Boolean(document.querySelector('[data-test=topic-section] [data-test=topic-heading]')))
  await sleep(400)
  const homeLive = await p.evaluate(snap)
  check(`${tag}: topics home, live topic header has no Archived badge`,
    !homeLive.text && !homeLive.badgeInView, homeLive)

  await open(`/t/${ARCH}`)
  await until(p, () => Boolean(document.querySelector('[data-test=topic-browse-thread] [data-test=archived-badge]')))
  await sleep(300)
  const view = await p.evaluate(snap)
  check(`${tag}: topics view, archived topic header shows Archived and the day, in view`,
    /archived/i.test(view.text) && DATE.test(view.text) && DATE.test(view.whenText) && view.badgeInView && view.whenInView && view.clipInView && !view.xScroll,
    view)

  await open(`/t/${LIVE}`)
  await until(p, () => {
    const el = document.querySelector('[data-test=topic-browse-thread] [data-test=topic-heading]')
    return Boolean(el && el.textContent && el.textContent.includes('Welcome'))
  })
  await sleep(400)
  const viewLive = await p.evaluate(snap)
  check(`${tag}: topics view, live topic header has no Archived badge`,
    !viewLive.text && !viewLive.badgeInView, viewLive)

  const errs = (await p.evaluate(() => window.__errs || [])).filter((e) => !/dynamically imported module/.test(e))
  check(`${tag}: no window error`, errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [1440, 390]) {
    for (const theme of ['light', 'dark']) await run(browser, server.base, w, theme)
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-archived-state: ${results.length - failed.length}/${results.length} passed`)
if (failed.length || code) process.exit(1)
