// SPL-1833 (owner HUM-10, t1 659e3927, msgs 090f687d, 9f8f842e, 4de3b04e):
// a search that times out or fails shows ONE plain sentence (what happened +
// what to do) and a Try again button in the results area - no red error box,
// no red top snackbar, no status code, id or timing. Those technical details
// show only with the existing Debug pane setting on (the diagnostics_enabled
// session claim). Replaces the t1 6d5bd334 budget-notice checks.
//
// The mock search is made slow and failing with the mock-only hook
// localStorage `spool.mock.search-fault` (utils/search-results.mjs), so the
// real store and page path run. Real browser, mock tenant, 1440 and 390.
//
// Run:
//   node tests/e2e/search-budget-message.test.mjs
//   BASE_URL=<generated bundle> SHOT_DIR=<dir> node tests/e2e/search-budget-message.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const QUERY = 'archive'
const SLOW = 'The search took too long. Try fewer or more specific words, then try again.'
const FAILED = 'Search is not working right now. Try again in a moment.'

const CASES = [
  { name: 'timeout', sentence: SLOW, fault: { status: 504, token: '', detail: 'upstream request timeout', delayMs: 1500 },
    tech: ['HTTP 504', 'upstream request timeout', ' ms', 'budget 7 s', 'ERR-'] },
  { name: 'failure', sentence: FAILED, fault: { status: 500, token: 'internal', detail: 'search query failed', delayMs: 0 },
    tech: ['HTTP 500', 'internal', 'search query failed', ' ms', 'ERR-'] },
]
/* what a reader without the Debug pane must never see */
const TECH_WORDS = /\b(504|500|HTTP|ERR-|upstream|internal|ms)\b|search query failed/

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

/** The Debug pane on, as the hub's session claim would say it. */
const debugOn = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.claims = { ...(s.claims || {}), hum: 'HUM-1', diagnostics_enabled: true }
  s.state = 'in'
  return true
})

const notice = (p) => p.evaluate(() => {
  const box = document.querySelector('[data-test=search-error]')
  const text = (sel) => (document.querySelector(sel)?.textContent || '').trim()
  return {
    msg: text('[data-test=search-error-message]'),
    all: (box?.textContent || '').trim(),
    tech: text('[data-test=search-error-tech]'),
    retry: Boolean(document.querySelector('[data-test=search-error-retry]')),
    side: text('[data-test=side-search-error-message]'),
    redBox: Boolean(document.querySelector('.error-notice')),
    snack: document.querySelectorAll('[data-test=error-snackbar-item]').length,
  }
})

const srv = await startServer()
const browser = await launch()
try {
  for (const [width, height, mobile] of [[1440, 900, false], [390, 800, true]]) {
    for (const c of CASES) {
      const tag = `${width} ${c.name}`
      const page = await browser.newPage()
      page.setDefaultNavigationTimeout(NAV_TIMEOUT)
      await page.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
      await page.evaluateOnNewDocument((f) => {
        try { localStorage.setItem('spool.mock.search-fault', f) } catch { /* the check below fails */ }
      }, JSON.stringify(c.fault))
      await page.goto(`${srv.base}/search?q=${encodeURIComponent(QUERY)}`, { waitUntil: 'domcontentloaded' })
      await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
      if (c.fault.delayMs) {
        const waiting = Boolean(await page.waitForSelector('[data-test=search-loading]', { timeout: 10000 }).catch(() => null))
        ok(`${tag}: the slow search says it is searching first`, waiting)
      }
      const shown = Boolean(await page.waitForSelector('[data-test=search-error-message]', { timeout: 15000 }).catch(() => null))
      ok(`${tag}: the notice is shown`, shown)
      await page.waitForFunction((s) => document.querySelector('[data-test=search-error-message]')?.textContent?.includes(s),
        { timeout: 10000 }, c.sentence).catch(() => null)
      await sleep(400)
      let n = await notice(page)
      ok(`${tag}: one plain sentence`, n.msg === c.sentence, n.msg)
      ok(`${tag}: no status, id or timing without the Debug pane`, !TECH_WORDS.test(n.all) && !n.tech, n.all)
      ok(`${tag}: no red error box, no red snackbar`, !n.redBox && n.snack === 0, { redBox: n.redBox, snack: n.snack })
      ok(`${tag}: a Try again button`, n.retry)
      if (!mobile) ok(`${tag}: the left panel says the same sentence`, n.side === c.sentence, n.side)
      if (SHOT_DIR && shown) await page.screenshot({ path: `${SHOT_DIR}/search-${c.name}-${width}-after.png` })

      const on = await debugOn(page)
      const techShown = on && Boolean(await page.waitForSelector('[data-test=search-error-tech]', { timeout: 10000 }).catch(() => null))
      n = await notice(page)
      ok(`${tag}: the Debug pane shows the technical details`, techShown && c.tech.every((w) => n.tech.includes(w)), n.tech)
      ok(`${tag}: the sentence stays the same with the Debug pane on`, n.msg === c.sentence, n.msg)
      if (SHOT_DIR && techShown) await page.screenshot({ path: `${SHOT_DIR}/search-${c.name}-${width}-after-debug.png` })

      await page.evaluate(() => localStorage.removeItem('spool.mock.search-fault'))
      await page.click('[data-test=search-error-retry]').catch(() => null)
      const cleared = await page.waitForFunction(() => !document.querySelector('[data-test=search-error]')
        && document.querySelector('[data-test=search-left-hint],[data-test=search-empty],[data-test=search-results]'),
      { timeout: 15000 }).then(() => true).catch(() => false)
      ok(`${tag}: Try again runs the search again and the app answers`, cleared)
      await page.close()
    }
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsearch-budget-message: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
