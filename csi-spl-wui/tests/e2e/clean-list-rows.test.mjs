// Clean list rows (spec 082 T003: AC2, AC3), proved in a real browser.
//
// At 1440 px against the mock, on `/`:
//   AC2  no Topics row, sidebar or middle list, starts with `Topic:` or
//        carries `**` (FR-002, FR-006: what is read is what is heard);
//   AC3  a desktop row time follows the list-time rule (FR-003): the
//        mock's 2026-09-18 rows show `09-18 HH:MM` (the full date in
//        another year); with the browser clock on that day the same rows
//        show only `HH:MM`.
// The browser runs in UTC so "today" is one calendar day for the check.
// T004 adds AC5 (Flow rows) here.
//
// CONTROLS - plant the defect and watch it go red:
//   PROVE_RED=prefix pnpm run test:e2e clean-list-rows   (rows get "Topic: **x**")
//   PROVE_RED=clock  pnpm run test:e2e clean-list-rows   (row times lose the date)
//
// Run:
//   pnpm run test:e2e clean-list-rows
//   BASE_URL=<generated bundle> pnpm run test:e2e clean-list-rows     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { printPageLog, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const MOCK_DAY = '2026-09-18'
const ON_MOCK_DAY = Date.parse(`${MOCK_DAY}T15:00:00Z`)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The planted defects, applied after the page has rendered. */
async function plant(page) {
  if (RED === 'prefix') {
    await page.evaluate(() => {
      for (const el of document.querySelectorAll('.topic-row .topic-subject, #sidebar-panel-topics .nav-item .label')) el.textContent = 'Topic: **' + el.textContent + '**'
    })
  }
  if (RED === 'clock') {
    await page.evaluate(() => {
      for (const el of document.querySelectorAll('.topic-row .msg-time')) el.textContent = el.textContent.slice(-5)
    })
  }
}

/* A shifted clock from the first script on: `new Date()` and `Date.now()`
   read `fakeNow` plus the time since load; a dated `new Date(x)` is untouched. */
function shiftClock(fakeNow) {
  const Real = Date
  const shift = fakeNow - Real.now()
  class Shifted extends Real {
    constructor(...a) { super(...(a.length ? a : [Real.now() + shift])) }
    static now() { return Real.now() + shift }
  }
  window.Date = Shifted
}

/** Open `/` with the Topics sidebar tab shown, then read both lists. */
async function rowsAt(browser, server, fakeNow) {
  const page = watchPage(await browser.newPage(), `1440 clock=${fakeNow ? 'mock-day' : 'real'}`)
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await page.setViewport({ width: 1440, height: 900 })
  await page.emulateTimezone('UTC')
  if (fakeNow) await page.evaluateOnNewDocument(shiftClock, fakeNow)
  for (let i = 0; ; i++) {
    try {
      await page.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await page.waitForSelector('a.topic-row', { visible: true, timeout: NAV_TIMEOUT })
      break
    } catch (e) {
      if (i >= 2 || !/context was destroyed|detached|navigation|Timeout/i.test(String(e))) throw e
    }
  }
  const shown = await page.evaluate(() => {
    const panel = document.querySelector('#sidebar-panel-topics')
    return Boolean(panel && panel.offsetParent)
  })
  if (!shown) await page.click('#sidebar-tab-topics')
  await page.waitForSelector('#sidebar-panel-topics .nav-item .label', { visible: true, timeout: NAV_TIMEOUT })
  await sleep(500)
  await plant(page)
  const rows = await page.evaluate(() => ({
    middle: [...document.querySelectorAll('a.topic-row')].map((a) => ({
      ts: a.getAttribute('data-ts') || '',
      title: (a.querySelector('.topic-subject')?.textContent || '').trim(),
      time: (a.querySelector('.msg-time')?.textContent || '').trim(),
    })),
    sidebar: [...document.querySelectorAll('#sidebar-panel-topics .nav-item .label')].map((el) => (el.textContent || '').trim()),
  }))
  await page.close()
  return { ...rows, errors }
}

const server = await startServer()
const browser = await launch()
try {
  const real = await rowsAt(browser, server, 0)
  const titles = [...real.middle.map((r) => r.title), ...real.sidebar]
  const dirty = titles.filter((s) => s.startsWith('Topic:') || s.includes('**'))
  ok('AC2 1440: middle and sidebar Topics rows are listed', real.middle.length > 0 && real.sidebar.length > 0,
    { middle: real.middle.length, sidebar: real.sidebar.length })
  ok('AC2 1440: no Topics row starts with "Topic:" or carries "**"', titles.length > 0 && dirty.length === 0, { dirty: dirty.slice(0, 3) })

  const thisYear = String(new Date().getUTCFullYear())
  const dated = MOCK_DAY.slice(0, 4) === thisYear ? MOCK_DAY.slice(5) : MOCK_DAY
  const old = real.middle.filter((r) => r.ts.startsWith(MOCK_DAY))
  ok(`AC3 1440: a ${MOCK_DAY} row shows "${dated} HH:MM", not a bare clock`,
    old.length > 0 && old.every((r) => new RegExp(`^${dated} \\d{2}:\\d{2}$`).test(r.time)), { rows: old.slice(0, 3) })

  const today = await rowsAt(browser, server, ON_MOCK_DAY)
  const now = today.middle.filter((r) => r.ts.startsWith(MOCK_DAY))
  ok(`AC3 1440: with the clock on ${MOCK_DAY}, its rows show only HH:MM`,
    now.length > 0 && now.every((r) => /^\d{2}:\d{2}$/.test(r.time)), { rows: now.slice(0, 3) })
  ok('no page error', real.errors.length === 0 && today.errors.length === 0, [...real.errors, ...today.errors])
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
