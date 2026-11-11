// SPL-5268 (owner HUM-10, t1 90194aeb, poll 157965f2 answer A): on a phone
// the top chevron shows at the top level of Discussions too (the channel
// list, level 1), and a tap there does what the browser's Back does. It is
// the same useMobileStack().pop() as the dock's Back: at level 1 it is
// history.back() while the tab has an app entry before this one
// (mobileHasPrev), so the SPL-5232 land guard applies unchanged. With no such
// entry there is nowhere to go back to: the chevron is not drawn (no dead
// tap), as the dock's Back is disabled.
//
// Cases, at 360 and 390 px:
//   1. /notes, then #alerts by a route push, then the dock's Back to the
//      channel list: the chevron is drawn in the list's head
//   2. a tap on it lands where browser Back lands from the same state (a
//      twin context presses browser Back), and that is not the list
//   3. a fresh tab on the list (no app entry before): no chevron, the dock's
//      Back disabled
//   4. levels 2 and 3 keep their one chevron (the list's is not drawn under
//      them, so `[data-testid=mobile-back]` stays one element)
//   5. 1440 px: no chevron in the sidebar (desktop unchanged)
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/phone-top-chevron.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
// SHOTS_DIR=<dir> also writes top-chevron-<width>.png of the list.
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS_DIR = process.env.SHOTS_DIR || ''
const WIDTHS = [360, 390]

const results = []
function ok(name, pass, ev) {
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

/* where we are, and the chevrons drawn: in the list's head, and anywhere */
const where = (p) => p.evaluate(() => {
  const seen = (e) => e.getBoundingClientRect().width > 0
  const backs = [...document.querySelectorAll('[data-testid=mobile-back]')]
  const dock = [...document.querySelectorAll('[data-testid=dock-back]')].find(seen)
  return {
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
    path: location.pathname,
    top: backs.filter((e) => e.closest('[data-testid=sidebar-panel-channels], [data-testid=sidebar-panel-dm]') && seen(e)).length,
    all: backs.length,
    dock: dock ? (dock.disabled ? 'disabled' : 'enabled') : 'none',
  }
})

async function waitFor(p, want, max = 8000) {
  const end = Date.now() + max
  let s = await where(p)
  while (Date.now() < end && !want(s)) { await sleep(100); s = await where(p) }
  return s
}

const vue = (p, fn, arg) => p.evaluate(fn, arg)

const signIn = (p) => vue(p, () => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  pinia?._s.get('session')?.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
})

const go = (p, path) => vue(p, (to) => {
  void document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$router?.push(to)
}, path)

const tap = (p, sel) => vue(p, (s) => {
  const e = [...document.querySelectorAll(s)].find((x) => x.getBoundingClientRect().width > 0 && !x.disabled)
  e?.click()
  return Boolean(e)
}, sel)

async function phone(browser, base, width, path = '/') {
  const ctx = await browser.createBrowserContext()
  const page = await ctx.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell')
  await sleep(800)
  await signIn(page)
  await sleep(400)
  return { ctx, page }
}

/* /notes, then #alerts (level 2), then the dock's Back to the channel list */
async function toList(page, w) {
  await go(page, '/notes')
  await waitFor(page, (s) => s.path === '/notes')
  await sleep(600)
  await go(page, '/channel/alerts')
  const s2 = await waitFor(page, (s) => s.path === '/channel/alerts' && s.level === '2')
  ok(`${w}: setup, #alerts on level 2 after /notes`, s2.level === '2', s2)
  ok(`${w}: level 2 draws one chevron, the pane's (the list's is not drawn under it)`, s2.all === 1 && s2.top === 0, s2)
  await sleep(600)
  await tap(page, '[data-testid=dock-back]')
  return waitFor(page, (s) => s.level === '1')
}

async function withHistory(browser, base, w) {
  const a = await phone(browser, base, w)
  const b = await phone(browser, base, w)
  try {
    const l1 = await toList(a.page, w)
    ok(`${w}: the dock's Back from #alerts goes to the channel list`, l1.level === '1', l1)
    ok(`${w}: at the top level of Discussions the top chevron is drawn`, l1.top === 1 && l1.all === 1, l1)
    if (SHOTS_DIR) { await sleep(900); await a.page.screenshot({ path: join(SHOTS_DIR, `top-chevron-${w}.png`) }) }
    const from = l1.path
    await toList(b.page, w)
    await sleep(400)
    await vue(b.page, () => { history.back() })
    const browserBack = await waitFor(b.page, (s) => s.path !== from || s.level !== '1')
    await sleep(800)
    const twin = await where(b.page)
    const tapped = await tap(a.page, '[data-testid=sidebar-panel-channels] [data-testid=mobile-back]')
    await waitFor(a.page, (s) => s.path !== from || s.level !== '1')
    await sleep(800)
    const after = await where(a.page)
    ok(`${w}: a tap on it leaves the list (${from} -> ${after.path})`, tapped && after.path !== from, after)
    ok(`${w}: it lands where browser Back lands (${twin.path}, level ${twin.level})`, after.path === twin.path && after.level === twin.level, { chevron: after, browserBack: twin, first: browserBack })
  } finally {
    await a.ctx.close().catch(() => {})
    await b.ctx.close().catch(() => {})
  }
}

async function noHistory(browser, base, w) {
  const { ctx, page } = await phone(browser, base, w)
  try {
    const s = await waitFor(page, (x) => x.level === '1')
    ok(`${w}: a fresh tab opens on the list (level 1)`, s.level === '1', s)
    await sleep(600)
    const s1 = await where(page)
    ok(`${w}: no app entry before it: no top chevron (no dead tap)`, s1.top === 0 && s1.all === 0, s1)
    ok(`${w}: and the dock's Back is disabled there too`, s1.dock !== 'enabled', s1)
  } finally {
    await ctx.close().catch(() => {})
  }
}

async function desktop(browser, base) {
  const ctx = await browser.createBrowserContext()
  try {
    const page = await ctx.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    await page.goto(`${base}/notes`, { waitUntil: 'networkidle2' })
    await sleep(800)
    await signIn(page)
    await go(page, '/channel/alerts')
    await sleep(1500)
    const n = await page.evaluate(() => document.querySelectorAll('[data-testid=mobile-back]').length)
    ok('1440px: no chevron at all (desktop unchanged)', n === 0, n)
  } finally {
    await ctx.close().catch(() => {})
  }
}

const server = await startServer()
const browser = await launch()
try {
  console.log(`phone-top-chevron on ${server.base}`)
  for (const w of WIDTHS) {
    await withHistory(browser, server.base, w)
    await noHistory(browser, server.base, w)
  }
  await desktop(browser, server.base)
} finally {
  await browser.close().catch(() => {})
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`phone-top-chevron: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
