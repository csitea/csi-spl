// SPL-5313 (spec 087, epic SPL-2402): on a phone, a sheet whose page writes
// its query through the router while the sheet is open (router.replace on the
// overlay's history entry) must close with the router's route EQUAL to the
// address bar. Found on Monitoring -> Lanes (c-561, msg fb5c5f44): the shell
// put ?sort= back into the address bar with replaceState, but vue-router had
// already read the entry under the sheet and navigated to the URL without it.
// Here the same trace runs on /issues (the filter sheet writes ?status=),
// closed both ways: browser Back, and the sheet's own X (history.go(-1)).
//
// It also logs the order the window's popstate listeners run in (capture
// flag, add order), the measurement the fix rests on.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/mobile-overlay-route.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const VIEWPORTS = [{ width: 320, height: 844 }, { width: 412, height: 915 }]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

/* before any app code: every window popstate listener logs its add order and
   capture flag into window.__popOrder when it runs */
const TRACE_POPSTATE = () => {
  const add = window.addEventListener
  let n = 0
  window.__popOrder = []
  window.addEventListener = function (type, fn, opts) {
    if (type !== 'popstate' || typeof fn !== 'function') return add.call(this, type, fn, opts)
    const tag = `#${++n}${(opts === true || opts?.capture) ? ' capture' : ''}`
    return add.call(this, type, function (e) { window.__popOrder.push(tag); return fn.call(this, e) }, opts)
  }
}

/** the address bar, the router's route, the sheet, the level */
const state = (p) => p.evaluate(() => {
  const app = document.querySelector('#__nuxt')?.__vue_app__
  const sheet = document.querySelector('[data-test=issues-filter-sheet]')
  return {
    bar: location.pathname + location.search,
    route: app?.config?.globalProperties?.$router?.currentRoute?.value?.fullPath ?? null,
    sheet: !!sheet && sheet.getBoundingClientRect().width > 0,
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
  }
})
async function until(p, want, max = 8000) {
  const end = Date.now() + max
  let prev = ''
  let s = await state(p)
  while (Date.now() < end) {
    const key = want(s) ? JSON.stringify(s) : ''
    if (key && key === prev) return s
    prev = key
    await sleep(150)
    s = await state(p)
  }
  return s
}
const click = (p, sel) => p.evaluate((s) => {
  const e = [...document.querySelectorAll(s)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)

/** open the filter sheet, pick a status (router.replace ?status=), close it with `close` */
async function trace(page, at, how, close) {
  await page.goto('about:blank')
  await page.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('[data-test=issues-filters-open]', { timeout: 15000 })
  await sleep(800)
  const s0 = await state(page)
  await click(page, '[data-test=issues-filters-open]')
  let s = await until(page, (s) => s.sheet)
  ok(`${at} ${how}: the filter sheet opens`, s.sheet, s)
  const picked = await click(page, '[data-test=issues-filter-status-m-opt][data-value=done]')
  const s1 = await until(page, (s) => s.bar !== s0.bar && s.route === s.bar, 3000)
  ok(`${at} ${how}: a status picked in the open sheet writes ?status= through the router`, picked && s1.sheet && /[?&]status=done/.test(s1.route ?? ''), s1)
  await page.evaluate(() => { window.__popOrder = [] })
  await close()
  s = await until(page, (s) => !s.sheet)
  const order = await page.evaluate(() => window.__popOrder)
  console.log(`  ${at} ${how}: popstate listeners ran in order ${JSON.stringify(order)}`)
  ok(`${at} ${how}: the sheet closes, the level stays`, !s.sheet && s.level === s0.level, { s0, s })
  ok(`${at} ${how}: the address bar keeps the status picked in the sheet`, s.bar === s1.bar, { s1, s })
  ok(`${at} ${how}: the router's route equals the address bar`, s.route === s.bar, s)
}

const srv = await startServer()
const browser = await launch()
try {
  for (const vp of VIEWPORTS) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ ...vp, isMobile: true, hasTouch: true })
    await page.evaluateOnNewDocument(TRACE_POPSTATE)
    const at = `${vp.width}x${vp.height}`
    await trace(page, at, 'Back', () => page.goBack().catch(() => {}))
    await trace(page, at, 'its X', () => click(page, '[data-test=issues-filter-sheet-close]'))
    await page.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmobile-overlay-route: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
