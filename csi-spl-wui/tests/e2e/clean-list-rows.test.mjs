// Clean list rows (spec 082 T003: AC2, AC3), proved in a real browser.
//
// At 1440 px against the mock:
//   AC5  (T004) a Flow entry whose body has `**#lobby**` shows `#lobby`,
//        and no Flow entry text carries `**` (FR-005).
// AC2 / AC3 read the Topics rows (sidebar and the `/` middle list); owner
// HUM-10 (t1 e4bfddb1, msg a78e06c8) removed that view, so `/` must paint no
// topic row at all (checked here) and the two checks went with it.
//
// CONTROL - plant the defect and watch it go red:
//   PROVE_RED=flow   pnpm run test:e2e clean-list-rows   (Flow texts get "**x**")
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
const FLOW_TEXT = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow] [data-testid=left-entry] .side-hit__text'

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

/** Open `/` with the Flow sidebar tab shown, then read its entry texts. */
async function flowTexts(browser, server) {
  const page = watchPage(await browser.newPage(), '1440 flow')
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  /* every message, not only the viewer's (flow-left's setup): the lobby welcome is an entry */
  await page.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.flow-scope', 'all'); localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await page.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: NAV_TIMEOUT })
  await page.click('[data-testid=sidebar-tab-flow]')
  await page.waitForFunction((sel) => [...document.querySelectorAll(sel)].some((el) => (el.textContent || '').includes('Welcome to')), { timeout: NAV_TIMEOUT }, FLOW_TEXT).catch(() => {})
  await sleep(500)
  if (RED === 'flow') {
    await page.evaluate((sel) => {
      for (const el of document.querySelectorAll(sel)) el.textContent = '**' + el.textContent + '**'
    }, FLOW_TEXT)
  }
  const texts = await page.evaluate((sel) => [...document.querySelectorAll(sel)].map((el) => (el.textContent || '').trim()), FLOW_TEXT)
  /* t1 e4bfddb1: no Topics view - `/` paints no topic row, no Topics panel */
  const topicRows = await page.evaluate(() => document.querySelectorAll('a.topic-row, #sidebar-panel-topics').length)
  await page.close()
  return { texts, errors, topicRows }
}

const server = await startServer()
const browser = await launch()
try {
  const flow = await flowTexts(browser, server)
  const lobby = flow.texts.filter((s) => s.includes('Welcome to'))
  ok('AC5 1440: the Flow entry for "Welcome to **#lobby**." shows "Welcome to #lobby."',
    lobby.length > 0 && lobby.every((s) => s.startsWith('Welcome to #lobby.')), { lobby })
  const marked = flow.texts.filter((s) => s.includes('**'))
  ok('AC5 1440: no Flow entry text carries "**"', flow.texts.length > 0 && marked.length === 0,
    { entries: flow.texts.length, marked: marked.slice(0, 3) })
  ok('1440: `/` paints no topic row and no Topics panel (the view is gone)', flow.topicRows === 0, { topicRows: flow.topicRows })
  ok('no page error', flow.errors.length === 0, flow.errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
