// t1 6d5bd334 (owner: "a better error msg shown to the end user"): a search
// the hub stops at its time budget (503 search_budget) says so plainly, with
// the budget in seconds and what to try, and keeps the diagnostics reference
// on its own line under the sentence, not in it. The search store is put in
// that state in the page (the mock tenant never runs past a budget).
// Real browser, mock tenant, 1440 and 390.
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
const QUERY = 'Example refactoring prompt (round 4)'

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

/** The search store answers as the hub does past its budget. */
const budgetError = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('search')
  if (!s) return false
  s.loading = false
  s.result = null
  s.error = { status: 503, token: 'search_budget', detail: 'the search ran past its time budget; narrow the query',
    pos: -1, badToken: '', retryAfter: 0, raw: { status: 503 } }
  return true
})

const notice = (p) => p.evaluate(() => {
  const msg = document.querySelector('[data-test=search-error-message]')
  const ref = document.querySelector('[data-test=search-error-ref]')
  return { msg: (msg?.textContent || '').trim(), ref: (ref?.textContent || '').trim(), refInMsg: Boolean(msg && ref && msg.contains(ref)) }
})

const srv = await startServer()
const browser = await launch()
try {
  for (const [width, height, mobile] of [[1440, 900, false], [390, 800, true]]) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
    await page.goto(`${srv.base}/search?q=${encodeURIComponent(QUERY)}`, { waitUntil: 'networkidle2' })
    await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await sleep(800)
    const set = await budgetError(page)
    const shown = set ? Boolean(await page.waitForSelector('[data-test=search-error-message]', { timeout: 10000 }).catch(() => null)) : false
    const n = shown ? await notice(page) : { msg: '', ref: '', refInMsg: false }
    ok(`${width}: the budget notice is shown`, shown)
    ok(`${width}: it names the 5 second budget and what to try`,
      n.msg.includes('longer than 5 seconds') && n.msg.includes('fewer or more specific words'), n.msg)
    ok(`${width}: the old "Narrow the query." wording is gone`, !n.msg.includes('Narrow the query'), n.msg)
    ok(`${width}: a diagnostics reference sits under it, not in it`, /^ERR-/.test(n.ref) && !n.refInMsg && !n.msg.includes('ERR-'), n)
    if (SHOT_DIR && shown) await page.screenshot({ path: `${SHOT_DIR}/search-budget-${width}.png` })
    await page.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsearch-budget-message: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
