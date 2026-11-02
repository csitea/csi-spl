// Spec 150 row B8, case C312 (SPL-4583; panel D11: "a list sorted by priority
// with no visible value cannot be read"). Real browser, mock tenant, phone 390
// then desktop 1440, the #lobby fixture topic open in the topic pane, its
// opening card in the list:
//
//   C312  card badge   nobody set it: no badge on the card (the default 3);
//                      set 2: the card shows `P2`; set 5: `P5`; set 3: the
//                      badge is gone again. In the tab that set it and, from
//                      the live frame alone, in a second tab.
//
// The value is set with B7's chooser (TopicPriorityChooser); the mock hub's
// fanout is a BroadcastChannel (spool-client-mock.mjs), so the two tabs are
// two pages of one browser context.
//
//   BASE_URL=<generated bundle> node tests/e2e/topic-priority-badge.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const LIVE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const PANE = '[data-test=topic-section]'
const CHOOSER = `${PANE} [data-testid=topic-priority]`
/* the topic's card in the list (pane 2), not the root card of the open pane */
const CARD = `.feed-body article.msg[data-task-id="${LIVE}"][data-opener=true]`

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

async function until(p, fn, ms = 8000, arg) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(150)
  }
  return false
}

/* The card's badge as the reader sees it: '' when there is none, null without the card. */
const badge = (sel) => {
  const card = document.querySelector(sel)
  if (!card) return null
  const b = card.querySelector('[data-testid=topic-priority-badge]')
  return b ? { text: b.textContent.trim(), data: b.getAttribute('data-priority') || '' } : ''
}

/* wait until the card's badge reads `want` ('' = none) in tab p */
const shows = (p, want) => until(p, ([sel, w]) => {
  const card = document.querySelector(sel)
  if (!card) return false
  const b = card.querySelector('[data-testid=topic-priority-badge]')
  return w === '' ? !b : Boolean(b) && b.textContent.trim() === w
}, 8000, [CARD, want])

/* A tab signed in to the mock, with the fixture topic open in the topic pane. */
async function openTab(browser, base, width) {
  const p = await browser.newPage()
  const phone = width < 600
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* about:blank */ }
  }, CLAIMS)
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-testid=sidebar-rail]', { timeout: NAV })
  await p.evaluate(async (to) => {
    await document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to)
  }, `/lobby?topic=${LIVE}`)
  await p.waitForSelector(`${CHOOSER} input[type=radio]`, { timeout: 15000 })
  await p.waitForSelector(CARD, { timeout: 15000 })
  return p
}

/* the acting tab in front (a hidden headless page does not paint), then a
   click on the radio itself, as a pointer on its label gives */
async function clickValue(p, n) {
  await p.bringToFront()
  await p.evaluate((sel) => document.querySelector(sel)?.click(), `${CHOOSER} [data-testid=topic-priority-${n}]`)
}

async function run(browser, base, width) {
  const tag = width < 600 ? `phone ${width}` : `desktop ${width}`
  const a = await openTab(browser, base, width)
  const b = await openTab(browser, base, width)
  check(`${tag}: C312 a topic nobody set (3): no badge on its card in either tab`,
    (await a.evaluate(badge, CARD)) === '' && (await b.evaluate(badge, CARD)) === '',
    { a: await a.evaluate(badge, CARD), b: await b.evaluate(badge, CARD) })

  for (const n of [2, 5]) {
    await clickValue(a, n)
    const inA = await shows(a, `P${n}`)
    check(`${tag}: C312 set ${n}: the card shows P${n} in the tab that set it`,
      inA && (await a.evaluate(badge, CARD))?.data === String(n), await a.evaluate(badge, CARD))
    const inB = await shows(b, `P${n}`)
    check(`${tag}: C312 set ${n}: the other tab's card shows P${n} from the live frame`, inB, await b.evaluate(badge, CARD))
  }

  await clickValue(a, 3)
  const goneA = await shows(a, '')
  const goneB = await shows(b, '')
  check(`${tag}: C312 set back to 3: no badge in either tab`, goneA && goneB,
    { a: await a.evaluate(badge, CARD), b: await b.evaluate(badge, CARD) })

  const errs = [...await a.evaluate(() => window.__errs || []), ...await b.evaluate(() => window.__errs || [])]
    .filter((e) => !/dynamically imported module/.test(e))
  check(`${tag}: no window error`, errs.length === 0, { errs })
  await a.close()
  await b.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [390, 1440]) await run(browser, server.base, w)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-priority-badge: ${results.length - failed.length}/${results.length} passed`)
if (failed.length || code) process.exit(1)
