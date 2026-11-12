// SPL-5380 (owner HUM-10, t1 56f50ebb msgs 859f9742, 6b4f264b: "The preo and
// card sizing control should also be hidden while scrolling." - "Exactly
// during the time when all the other controls are hiding"): the header's
// second row (SPL-5349: the topic's 1..5 priority bar, the topic list's
// filter and sort, the card-size control) goes and comes with the section
// strip and the logo bar, on their one state (layouts/default stripAway,
// data-mobile-strip-hidden), never a scroll listener of its own.
//
// Phone, 390 px: on the channel page (feed header row 2) and on an open topic
// (topic head row 2) a wheel down hides the strip AND the row (not painted);
// a wheel up paints both again, the row at the same y. A row with keyboard
// focus inside stays painted while the strip is away. Desktop, 1280 px:
// nothing hides on a scroll there, so the row stays painted too.
// Red control: without the main.css rule the row stays painted while the
// strip is away.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/prio-cardsize-scroll-hide.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const TOPIC = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
/* the header row 2 of each pane: feed header (channel page), topic head (an open topic) */
const ROUTES = [['/channel/lobby', 'feed-header-row2'], [`/channel/lobby?topic=${TOPIC}`, 'topic-head-row2']]

/* the shell's flag, the row (painted, its y, focus inside) and the pane's message list */
const read = (p, row) => p.evaluate((row) => {
  const paints = (el) => {
    if (!el) return false
    const r = el.getBoundingClientRect()
    const cs = getComputedStyle(el)
    if (cs.display === 'none' || cs.visibility === 'hidden' || !(r.width > 0 && r.height > 0) || r.bottom <= 0) return false
    const hit = document.elementFromPoint(Math.min(r.left + r.width / 2, innerWidth - 1), r.top + r.height / 2)
    return Boolean(hit) && (el.contains(hit) || hit.contains(el))
  }
  const shell = document.querySelector('.spool-shell')
  const el = [...document.querySelectorAll(`[data-test=${row}]`)].find((e) => e.getClientRects().length) ?? document.querySelector(`[data-test=${row}]`)
  /* the pane's message list: the one .feed-body on screen (channel feed or topic) */
  const pane = [...document.querySelectorAll('.spool-shell .feed-body')].find((e) => e.getClientRects().length && e.clientHeight >= 150)
  pane?.setAttribute('data-e2e-scroller', '1')
  const pr = pane?.getBoundingClientRect()
  return {
    hidden: shell?.getAttribute('data-mobile-strip-hidden') ?? null,
    row: paints(el),
    rowTop: el && el.getClientRects().length ? Math.round(el.getBoundingClientRect().top) : null,
    focusIn: Boolean(el?.contains(document.activeElement)),
    controls: el ? el.querySelectorAll('button, input').length : 0,
    pane: pane ? { x: Math.round(pr.left + pr.width / 2), y: Math.round(pr.top + pr.height / 2) } : null,
  }
}, row)

async function settle(p, row, max = 8000) {
  const end = Date.now() + max
  let prev = ''
  while (Date.now() < end) {
    const s = await read(p, row)
    const key = JSON.stringify(s)
    if (s.row && s.controls > 0 && s.pane && key === prev) return s
    prev = key
    await sleep(200)
  }
  return read(p, row)
}

/* the mock tenant's lists hardly scroll (49 px, 0): pad the list under its
   rows so a real wheel has room to scroll it down */
const pad = (p) => p.evaluate(() => {
  const list = document.querySelector('[data-e2e-scroller]')
  if (list && !list.querySelector('[data-e2e-pad]')) list.insertAdjacentHTML('beforeend', '<div data-e2e-pad style="height:2000px"></div>')
})

const wheel = async (p, at, dy) => {
  await p.mouse.move(at.x, at.y)
  for (let i = 0; i < 3; i++) { await p.mouse.wheel({ deltaY: dy / 3 }); await sleep(60) }
  await sleep(500)
}

async function page(browser, width, height, mobile) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })))
  await p.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
  return p
}

/* phone: the row goes and comes with the strip; a focused row stays */
async function phone(browser) {
  const p = await page(browser, 390, 844, true)
  for (const [route, row] of ROUTES) {
    await p.goto(`${srv.base}${route}`, { waitUntil: 'networkidle2' }).catch(() => null)
    const s0 = await settle(p, row)
    await pad(p)
    if (s0.pane) await wheel(p, s0.pane, 600)
    const down = await read(p, row)
    if (s0.pane) await wheel(p, s0.pane, -200)
    const up = await read(p, row)
    ok(`390px ${route}: before the scroll the row (${row}, ${s0.controls} controls) is painted`, s0.row && s0.controls > 0 && Boolean(s0.pane), s0)
    ok(`390px ${route}: wheel down: the strip is away and the row with it (not painted)`, down.hidden === '1' && !down.row, down)
    ok(`390px ${route}: wheel up: the strip is back and the row painted again at the same y`, up.hidden === null && up.row && up.rowTop === s0.rowTop, { before: s0.rowTop, ...up })
  }
  /* a control with the keyboard focus never vanishes under the reader */
  const [route, row] = ROUTES[1]
  await p.goto(`${srv.base}${route}`, { waitUntil: 'networkidle2' }).catch(() => null)
  const f0 = await settle(p, row)
  await pad(p)
  await p.evaluate((row) => document.querySelector(`[data-test=${row}] input, [data-test=${row}] button`)?.focus(), row)
  if (f0.pane) await wheel(p, f0.pane, 600)
  const f1 = await read(p, row)
  ok(`390px ${route}: a row with the keyboard focus inside stays painted while the strip is away`, f1.hidden === '1' && f1.focusIn && f1.row, f1)
  await p.close()
}

/* desktop: nothing hides on a scroll, the row neither */
async function desktop(browser) {
  const p = await page(browser, 1280, 900, false)
  for (const [route, row] of ROUTES) {
    await p.goto(`${srv.base}${route}`, { waitUntil: 'networkidle2' }).catch(() => null)
    const s0 = await settle(p, row)
    await pad(p)
    if (s0.pane) await wheel(p, s0.pane, 600)
    const down = await read(p, row)
    ok(`1280px ${route}: a wheel down hides nothing on a desktop, the row (${row}) stays painted`, s0.row && Boolean(s0.pane) && down.hidden === null && down.row, { before: s0, ...down })
  }
  await p.close()
}

const srv = await startServer()
const browsers = []
try {
  /* one browser per viewport: the wheel is real input, a background tab never gets it */
  await Promise.all([phone, desktop].map(async (run) => {
    const browser = await launch()
    browsers.push(browser)
    await run(browser)
  }))
} finally {
  await Promise.all(browsers.map((b) => b.close()))
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nprio-cardsize-scroll-hide: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length || !results.length ? 1 : 0)
