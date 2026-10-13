// SPL-1595 (owner HUM-10, t1 27b3ab77 msg 3aee57ba: "There is still no way for
// me to find out what these three issues are that have not been opened";
// msg de869df4: "I should have an option in the filter to filter by unread
// issues"). In a REAL browser, against the mock bundle: the mock tenant starts
// with two issues a teammate assigned to me (localStorage
// spool.mock.issues-new = 2: SPL-2, SPL-3), so the Issues tab badge reads 2.
//
// Desktop:
//   1  a click on the Issues badge opens /issues?unread=1, the Unread filter on
//   2  the list holds exactly the rows the badge counts (SPL-2, SPL-3)
//   3  open SPL-2, close it: it leaves the list and the badge drops to 1
//   4  CONTROL: Unread off lists the opened SPL-2 again, and the URL drops it
// Phone, 390x844:
//   5  the filter sheet carries Unread; on, the cards are the badge's rows
//   6  Back to the sections, a tap on the badge opens the filtered list
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e issues-unread-filter
// SHOT_DIR=<dir> also saves the phone screenshots (sheet, filtered list).
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)

async function open(browser, vp, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      localStorage.setItem('spool.mock.issues-new', '2')
    } catch { /* about:blank */ }
  })
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx, errors }
}

const BADGE = '[data-testid=sidebar-tab-issues-count]'
const keys = (p, sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-key')).sort())
const badge = (p) => p.$eval(BADGE, (e) => e.textContent.trim()).catch(() => '')
const unreadInUrl = (p) => p.evaluate(() => new URL(window.location.href).searchParams.get('unread') || '')

const server = await startServer()
const browser = await launch()
try {
  /* ---- desktop ---- */
  const d = await open(browser, { width: 1280, height: 800 }, '/issues')
  const p = d.p
  const ROW = '[data-test=issues-row]'
  await p.waitForSelector(`${ROW}[data-key="SPL-3"]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const all = (await keys(p, ROW)).length
  await until(p, (s) => document.querySelector(s)?.textContent?.trim() === '2', BADGE, 8000)
  await p.click(BADGE)
  const on = await until(p, () => document.querySelector('[data-test=issues-filter-unread]')?.getAttribute('aria-pressed') === 'true'
    && new URL(window.location.href).searchParams.get('unread') === '1', null, 8000)
  ok('1 the Issues badge opens the list with Unread on (?unread=1)', on, { url: await unreadInUrl(p) })

  await until(p, (s) => document.querySelectorAll(s).length === 2, ROW, 8000)
  const shown = await keys(p, ROW)
  const count = await badge(p)
  ok('2 the list is exactly the rows the badge counts', shown.join() === 'SPL-2,SPL-3' && count === String(shown.length), { shown, count, all })

  await p.click(`${ROW}[data-key="SPL-2"] .issues-title`)
  const opened = await until(p, () => Boolean(document.querySelector('[data-test=issues-detail]')), null, 8000)
  await p.keyboard.press('Escape')
  const closed = await until(p, () => !document.querySelector('[data-test=issues-detail]'), null, 8000)
  const left = await until(p, (s) => !document.querySelector(`${s}[data-key="SPL-2"]`) && Boolean(document.querySelector(`${s}[data-key="SPL-3"]`)), ROW, 8000)
  const dropped = await until(p, (s) => document.querySelector(s)?.textContent?.trim() === '1', BADGE, 8000)
  ok('3 open SPL-2, back: it leaves the list and the badge drops by one', opened && closed && left && dropped, { opened, closed, left, rows: await keys(p, ROW), badge: await badge(p) })

  await p.click('[data-test=issues-filter-unread]')
  /* the list reloads and router.replace drops ?unread: wait for both, the
     replace can land after the rows on a slow runner */
  const off = await until(p, (s) => Boolean(document.querySelector(`${s}[data-key="SPL-2"]`))
    && !new URL(window.location.href).searchParams.has('unread'), ROW, 8000)
  const back = await keys(p, ROW)
  const url = await unreadInUrl(p)
  const search = await p.evaluate(() => window.location.search)
  ok('4 CONTROL: Unread off lists the opened SPL-2 again and leaves the URL', off && back.length === all && url === '', { off, back, all, url, search })
  ok('desktop: no unexpected page errors', d.errors.length === 0, d.errors)
  await d.ctx.close()

  /* ---- phone ---- */
  const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
  const g = await open(browser, PHONE, '/issues')
  const CARD = '[data-test=issues-card]'
  await g.p.waitForSelector(`${CARD}[data-key="SPL-3"]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await g.p.click('[data-test=issues-filters-open]')
  const chip = await g.p.waitForSelector('[data-test=issues-filter-unread-m]', { visible: true, timeout: 8000 }).then(() => true, () => false)
  if (chip) await g.p.click('[data-test=issues-filter-unread-m]')
  const pressed = await until(g.p, () => document.querySelector('[data-test=issues-filter-unread-m]')?.getAttribute('aria-pressed') === 'true', null, 5000)
  if (SHOT_DIR) await g.p.screenshot({ path: `${SHOT_DIR}/issues-unread-sheet.png` })
  await g.p.click('[data-test=issues-filter-sheet-done]')
  await until(g.p, (s) => document.querySelectorAll(s).length === 2, CARD, 8000)
  const cards = await keys(g.p, CARD)
  if (SHOT_DIR) await g.p.screenshot({ path: `${SHOT_DIR}/issues-unread-list.png` })
  ok('5 phone: the filter sheet has Unread; on, the cards are the badge\'s rows', chip && pressed && cards.join() === 'SPL-2,SPL-3', { chip, pressed, cards })
  ok('phone: no unexpected page errors', g.errors.length === 0, g.errors)
  await g.ctx.close()

  /* the mock tenant's issues live with the Issues page: open it, Back to the
     sections, then the badge */
  const h = await open(browser, PHONE, '/issues')
  await h.p.waitForSelector(`${CARD}[data-key="SPL-3"]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await h.p.click('[data-test=issues-back]').catch(() => {})
  const seen = await until(h.p, (s) => { const r = document.querySelector(s)?.getBoundingClientRect(); return Boolean(r && r.width && r.right <= window.innerWidth) }, BADGE, 10000)
  if (seen) await h.p.tap(BADGE)
  const listed = await until(h.p, (s) => new URL(window.location.href).searchParams.get('unread') === '1' && document.querySelectorAll(s).length === 2, CARD, 10000)
  ok('6 phone: a tap on the badge opens the filtered list', seen && listed, { seen, cards: await keys(h.p, CARD), url: await unreadInUrl(h.p) })
  ok('phone (badge): no unexpected page errors', h.errors.length === 0, h.errors)
  await h.ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-unread-filter: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
