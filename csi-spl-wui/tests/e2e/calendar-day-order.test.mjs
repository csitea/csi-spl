// SPL-5453 (owner HUM-10, csitea 218fa45d; spec 097 section 3.3.1): a pinned
// whole-day entry leads its day in every calendar view.
//
// The fixture, on today: a pinned whole-day entry whose id sorts LAST, two
// unpinned whole-day entries and a timed one whose id sorts first. Every
// view lists the day: whole-day before timed, pinned first, then start,
// then id.
//   desktop 1440x900: Day, 3 days and Week (the all-day row), Month (the
//     day cell, first 3);
//   phone 390x844: Month (the day's agenda), Week (the day's row), Day (the
//     all-day row).
// Control: the same fixture with the entry NOT pinned puts it after the
// other whole-day entries (the id order), in the desktop Week and in the
// phone Month agenda, so a view that ignored `pinned` could not pass.
//
// Run: BASE_URL=<generated mock bundle> SHOT_DIR=<dir> pnpm run test:e2e calendar-day-order
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-day-order-${name}.png`) })
}

const today = E2E_TODAY
const next = new Date(Date.parse(`${today}T00:00:00Z`) + 86400000).toISOString().slice(0, 10)
const id = (n) => `00000000-0000-4000-8000-00000000540${n}`
const NL = id(9)
const WEEK = id(2)
const PAY = id(3)
const FLIGHT = id(1)
/** the fixture; pinned = whether the NL entry carries props.pinned */
const fixture = (pinned) => [
  { id: WEEK, title: 'Week 47 of 2026', starts_at: `${today}T00:00:00Z`, ends_at: `${next}T00:00:00Z`, all_day: true },
  { id: PAY, title: 'Check the payment', starts_at: `${today}T00:00:00Z`, ends_at: `${next}T00:00:00Z`, all_day: true, color: 'sage' },
  { id: NL, title: '🇳🇱 Холандия', starts_at: `${today}T00:00:00Z`, ends_at: `${next}T00:00:00Z`, all_day: true, color: 'tangerine', pinned },
  { id: FLIGHT, title: 'Flight', starts_at: `${today}T06:00:00Z`, ends_at: `${today}T07:00:00Z`, all_day: false, color: 'peacock' },
]
const OURS = new Set([NL, WEEK, PAY, FLIGHT])
/** the ids a view lists, ours only, in screen order */
const ids = (p, sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-id'))).then((l) => l.filter((x) => OURS.has(x))).catch(() => [])
/** the first id a view lists, anyone's (the mock's own items included) */
const first = (p, sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-id'))[0] || '').catch(() => '')

async function open(browser, vp, view, pinned) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await pinClock(p, 'UTC')
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('dayorder-seeded')) return
      sessionStorage.setItem('dayorder-seeded', '1')
      localStorage.setItem('spool-theme', 'light')
      if (s.view) localStorage.setItem('spool-calendar-phone-view', s.view)
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(s.seed))
    } catch { /* about:blank */ }
  }, { view, seed: fixture(pinned) })
  await setPageViewport(p, vp)
  await p.goto(`${server.base}/calendar`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector(`[data-id="${NL}"]`, { timeout: 15000 }).catch(() => null)
  await sleep(300)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const deskTab = (v) => `[data-test=calendar-view-tabs] [data-test=calendar-view-${v}]`
const waitDesk = (p, v) => p.waitForFunction((v) => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-view') === v && document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: 10000 }, v).then(() => true, () => false)
const deskRow = `[data-test=calendar-week-day][data-day="${today}"] .cal-week__list [data-test=calendar-item]`
const deskMonth = `[data-test=calendar-month-cell][data-day="${today}"] [data-test=calendar-item]`

async function desktop(browser) {
  console.log('-- desktop 1440x900')
  const { p, ctx } = await open(browser, { width: 1440, height: 900 }, '', true)
  for (const v of ['week', 'day', '3day']) {
    await p.click(deskTab(v)).catch(() => {})
    const ready = await waitDesk(p, v)
    await sleep(200)
    const got = await ids(p, deskRow)
    ok(`desktop ${v}: the all-day row lists the pinned entry first, then by id`, ready && got.join() === [NL, WEEK, PAY].join() && (await first(p, deskRow)) === NL, got)
    await shot(p, `desktop-${v}`)
  }
  await p.click(deskTab('month')).catch(() => {})
  const ready = await waitDesk(p, 'month')
  await sleep(200)
  const got = await ids(p, deskMonth)
  ok('desktop month: the day cell lists the pinned entry first', ready && got[0] === NL && (await first(p, deskMonth)) === NL && got.indexOf(FLIGHT) !== 1 && got.indexOf(FLIGHT) !== 2, got)
  await shot(p, 'desktop-month')
  ok('desktop: no sideways scroll', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  await ctx.close()

  /* control: not pinned, the entry is last of the whole-day ones (id order) */
  const c = await open(browser, { width: 1440, height: 900 }, '', false)
  await c.p.click(deskTab('week')).catch(() => {})
  await waitDesk(c.p, 'week')
  const ctl = await ids(c.p, deskRow)
  ok('control desktop week: unpinned, the entry follows the id order', ctl.join() === [WEEK, PAY, NL].join(), ctl)
  await c.ctx.close()
}

const PHONE = { width: 390, height: 844, hasTouch: true }
const PAGE = '[data-test=calendar-phone] [data-test=calphone-page][data-dir="0"]'
const phoneSel = {
  month: `${PAGE} [data-test=calphone-month] [data-test=calphone-month-agenda] [data-test=calphone-month-event]`,
  week: `${PAGE} [data-test=calphone-week] [data-test=calweek-list] > li[data-day="${today}"] [data-test=calweek-event]`,
  day: `${PAGE} [data-test=calphone-day] [data-test=calday-allday-item]`,
}

async function phone(browser) {
  console.log('-- phone 390x844')
  for (const v of ['month', 'week', 'day']) {
    const { p, ctx } = await open(browser, PHONE, v, true)
    await p.waitForSelector(phoneSel[v], { timeout: 10000 }).catch(() => null)
    const got = await ids(p, phoneSel[v])
    const want = v === 'day' ? [NL] : [NL, WEEK, PAY, FLIGHT]
    ok(`phone ${v}: the pinned entry leads the day, whole-day before timed`, got.slice(0, want.length).join() === want.join() && (await first(p, phoneSel[v])) === NL, got)
    await shot(p, `phone-${v}`)
    ok(`phone ${v}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    await ctx.close()
  }
  const c = await open(browser, PHONE, 'month', false)
  await c.p.waitForSelector(phoneSel.month, { timeout: 10000 }).catch(() => null)
  const ctl = await ids(c.p, phoneSel.month)
  ok('control phone month: unpinned, the entry follows the id order', ctl.join() === [WEEK, PAY, NL, FLIGHT].join(), ctl)
  await c.ctx.close()
}

const server = await startServer()
const browser = await launch()
try {
  await desktop(browser)
  await phone(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-day-order: ${failed} FAILED` : `calendar-day-order: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
