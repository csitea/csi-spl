// SPL-1559 (owner HUM-10, t1 7edebc75 msg 7d76ce22): "A new issue should be
// marked as a new issue, which has not been opened yet". In a REAL browser,
// against the mock bundle: the mock tenant starts with two issues a teammate
// assigned to me (localStorage spool.mock.issues-new = 2: SPL-2, SPL-3).
//
// Desktop:
//   1  both rows carry the mark (data-unopened, the dot) and nothing else does
//   2  the dot is the unread row's dot: the shared .unread-dot, 8 px, the
//      Flow list's accent colour, and the title is bold
//   3  opening SPL-2 clears its mark at once; SPL-3 keeps its
//   4  the Issues tab counts exactly the marked rows (1)
// Phone, 390x844:
//   5  the card carries the same dot and loses it on open
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e issues-unopened
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

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

/** the keys of the marked rows (table rows or phone cards) */
const marked = (p, sel) => p.$$eval(`${sel}[data-unopened="true"]`, (els) => els.map((e) => e.getAttribute('data-key')).sort())

const server = await startServer()
const browser = await launch()
try {
  /* ---- desktop ---- */
  const d = await open(browser, { width: 1280, height: 800 }, '/issues')
  const p = d.p
  const ROW = '[data-test=issues-row]'
  const listed = await p.waitForSelector(`${ROW}[data-key="SPL-3"]`, { visible: true, timeout: NAV_TIMEOUT }).then(() => true, () => false)
  const first = await marked(p, ROW)
  const dots = await p.$$eval('[data-test=issues-row-unopened]', (els) => els.length)
  ok('1 the two issues a teammate assigned to me are marked, nothing else', listed && first.join() === 'SPL-2,SPL-3' && dots === 2, { first, dots })

  const look = await p.$eval(`${ROW}[data-key="SPL-2"]`, (row) => {
    const dot = row.querySelector('.unread-dot')
    const title = row.querySelector('.issues-title')
    const probe = document.createElement('span')
    probe.style.color = 'var(--color-accent)'
    document.body.appendChild(probe)
    const accent = getComputedStyle(probe).color
    probe.remove()
    const cs = dot ? getComputedStyle(dot) : null
    return { w: cs?.width, h: cs?.height, bg: cs?.backgroundColor, accent, weight: title ? getComputedStyle(title).fontWeight : '' }
  })
  ok('2 the mark is the unread row\'s: 8 px accent dot, bold title', look.w === '8px' && look.h === '8px' && look.bg === look.accent && Number(look.weight) >= 700, look)

  await p.click(`${ROW}[data-key="SPL-2"] .issues-title`)
  const cleared = await until(p, (s) => !document.querySelector(s), `${ROW}[data-key="SPL-2"][data-unopened="true"]`, 5000)
  const after = await marked(p, ROW)
  ok('3 opening SPL-2 clears its mark, SPL-3 keeps its', cleared && after.join() === 'SPL-3', { cleared, after })

  const counted = await until(p, () => document.querySelector('[data-testid=sidebar-tab-issues-count]')?.textContent?.trim() === '1', null, 8000)
  const count = await p.$eval('[data-testid=sidebar-tab-issues-count]', (e) => e.textContent.trim()).catch(() => '')
  ok('4 the Issues tab counts exactly the marked rows', counted && count === String(after.length), { count, marked: after.length })
  ok('desktop: no unexpected page errors', d.errors.length === 0, d.errors)
  await d.ctx.close()

  /* ---- phone ---- */
  const g = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '/issues')
  const CARD = '[data-test=issues-card]'
  await g.p.waitForSelector(`${CARD}[data-key="SPL-3"]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const cards = await marked(g.p, CARD)
  const cardDots = await g.p.$$eval('[data-test=issues-card-unopened]', (els) => els.length)
  await g.p.click(`${CARD}[data-key="SPL-3"]`)
  const cardCleared = await until(g.p, (s) => !document.querySelector(s), `${CARD}[data-key="SPL-3"][data-unopened="true"]`, 5000)
  ok('5 phone: the card carries the dot and loses it on open', cards.join() === 'SPL-2,SPL-3' && cardDots === 2 && cardCleared, { cards, cardDots, cardCleared })
  ok('phone: no unexpected page errors', g.errors.length === 0, g.errors)
  await g.ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-unopened: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
