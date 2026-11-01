// Spec 150 row B7 (SPL-4568; owner HUM-10, t1 0344254d msg f5ed1396: "some
// kind of small row of 1..5 radio buttons whith default 3 and one would have
// to click on 1 to make the prio 1"). Real browser, mock tenant, phone 390
// then desktop 1440, the #lobby fixture topic open in the topic pane:
//
//   C309  live frame   two tabs on the same topic; tab A clicks 1, tab B
//                      shows 1 without a reload or a re-read of the pane
//                      (its topic-root node is the same element)
//   C311  failed save  the mock refuses (403 not_allowed): the old value is
//                      checked again and the error line names the token
//   C310  top / bottom the chooser sits above the topic root when Message
//                      order is newest first, below the last reply when it
//                      is newest last
//
// The mock hub's fanout is a BroadcastChannel (spool-client-mock.mjs), so the
// two tabs are two pages of one browser context.
//
//   BASE_URL=<generated bundle> node tests/e2e/topic-priority.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const LIVE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const PANE = '[data-test=topic-section]'
const CHOOSER = `${PANE} [data-testid=topic-priority]`

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

/* The chooser as the reader sees it: the checked radio, the data value, the note line. */
const read = (sel) => {
  const el = document.querySelector(sel)
  if (!el) return null
  const on = el.querySelector('input[type=radio]:checked')
  const note = el.querySelector('[data-testid=topic-priority-note]')
  return { checked: on ? on.value : '', data: el.getAttribute('data-priority') || '', note: note ? note.textContent.trim() : '' }
}

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
  return p
}

const setOrder = (p, order) => p.evaluate((order) => {
  document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').setViewPref('message_order', order)
}, order)

/* The chooser's box against the topic root's (the root card and its replies). */
const place = (pane) => {
  const c = document.querySelector(`${pane} [data-testid=topic-priority]`)
  const r = document.querySelector(`${pane} [data-test=topic-root]`)
  if (!c || !r) return null
  const cb = c.getBoundingClientRect()
  const rb = r.getBoundingClientRect()
  return { chooserTop: Math.round(cb.top), chooserBottom: Math.round(cb.bottom), rootTop: Math.round(rb.top), rootBottom: Math.round(rb.bottom) }
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
  check(`${tag}: a topic nobody set shows 3 checked in both tabs`,
    (await a.evaluate(read, CHOOSER))?.checked === '3' && (await b.evaluate(read, CHOOSER))?.checked === '3',
    { a: await a.evaluate(read, CHOOSER), b: await b.evaluate(read, CHOOSER) })

  /* C309: tab A sets 1; tab B follows from the frame alone */
  await b.evaluate((sel) => { window.__root = document.querySelector(sel) }, `${PANE} [data-test=topic-root]`)
  await clickValue(a, 1)
  const savedA = await until(a, (sel) => {
    const el = document.querySelector(sel)
    return el && el.querySelector('input[type=radio]:checked')?.value === '1' && /Priority set to 1/.test(el.textContent || '')
  }, 8000, CHOOSER)
  check(`${tag}: C309 tab A: 1 checked and "Priority set to 1."`, savedA, await a.evaluate(read, CHOOSER))
  const seenB = await until(b, (sel) => document.querySelector(sel)?.querySelector('input[type=radio]:checked')?.value === '1', 8000, CHOOSER)
  const sameRoot = await b.evaluate((sel) => window.__root === document.querySelector(sel), `${PANE} [data-test=topic-root]`)
  check(`${tag}: C309 tab B shows 1 from the live frame, no reload (same topic-root node)`, seenB && sameRoot, { b: await b.evaluate(read, CHOOSER), sameRoot })

  /* C311: a refused save puts 1 back and names the token */
  await a.evaluate(() => localStorage.setItem('spool.mock.priority-fault', JSON.stringify('not_allowed')))
  await clickValue(a, 5)
  const rolledBack = await until(a, (sel) => {
    const el = document.querySelector(sel)
    return el && /Could not save the priority \(not_allowed\)/.test(el.textContent || '')
  }, 8000, CHOOSER)
  await sleep(200)
  const after = await a.evaluate(read, CHOOSER)
  check(`${tag}: C311 a refused save: 1 is checked again and the error line shows`,
    rolledBack && after?.checked === '1' && after?.data === '1', after)
  await a.evaluate(() => localStorage.removeItem('spool.mock.priority-fault'))

  /* C310: the pane's newest end */
  await a.bringToFront()
  await setOrder(a, 'newest-first')
  await until(a, (sel) => Boolean(document.querySelector(sel)), 8000, CHOOSER)
  await sleep(300)
  const first = await a.evaluate(place, PANE)
  check(`${tag}: C310 newest first: the chooser is above the topic root`, Boolean(first) && first.chooserBottom <= first.rootTop, first)
  await setOrder(a, 'newest-last')
  await until(a, (pane) => {
    const c = document.querySelector(`${pane} [data-testid=topic-priority]`)
    const r = document.querySelector(`${pane} [data-test=topic-root]`)
    return Boolean(c && r && (r.compareDocumentPosition(c) & Node.DOCUMENT_POSITION_FOLLOWING))
  }, 8000, PANE)
  await sleep(300)
  const last = await a.evaluate(place, PANE)
  check(`${tag}: C310 newest last: the chooser is below the last reply`, Boolean(last) && last.chooserTop >= last.rootBottom, last)
  check(`${tag}: C310 the value survives the move (1 still checked)`, (await a.evaluate(read, CHOOSER))?.checked === '1', await a.evaluate(read, CHOOSER))
  await setOrder(a, 'newest-first')

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
console.log(`\ntopic-priority: ${results.length - failed.length}/${results.length} passed`)
if (failed.length || code) process.exit(1)
