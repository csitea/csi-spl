// spec 089 T007: the Calendar section shell and its year strip.
//
// AC-01: the rail's Calendar tab opens /calendar as one sheet - the left rail
//        stays (the sidebar is the icon rail only), no topic pane - and the
//        main view shows the current week.
// AC-04: a click on a day in the 36 mini-months moves the main view to that
//        day's week (and the URL keeps it: ?d=YYYY-MM-DD).
// AC-02: the calendar code is its own chunk: nothing of it is in the initial
//        download of 200.html, which stays at or under 155 KB gzip, nor in
//        that of the prerendered `/` (index.html, ci_home_gzip_kb, spec 109
//        T002).
// The mock workspace answers GET /v1/calendar/marks and /events in the wire
// format of spec 6.1 (src/utils/calendar-mock.mjs): a release today, an
// issue deadline and a maintenance window two days on, an event 30 days on,
// and the official day of 25 December.
//
// Control: before T007 there is no [data-testid=sidebar-tab-calendar] and
// /calendar is the 404 page, so every check below FAILS.
//
// Run:
//   pnpm run test:e2e calendar
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { gzipSync } from 'node:zlib'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { calAddDays, calIsoDay, calWeekStart } from '../../src/utils/calendar-year.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* ci_initial_gzip_kb (027 perf-budgets.json, owner 2026-10-02) */
const INITIAL_KB = 155
/* ci_home_gzip_kb (027 perf-budgets.json, spec 109 T002; T003 lowers it) */
const HOME_KB = 351.9
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

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-${name}.png`) })
}

const today = calIsoDay(Date.now())
const week = (p) => p.$eval('[data-test=calendar-main]', (el) => el.getAttribute('data-week')).catch(() => '')
const waitWeek = (p, want) => p.waitForFunction((w) => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-week') === w, { timeout: 10000 }, want).then(() => true, () => false)
const items = (p) => p.$$eval('[data-test=calendar-item]', (els) => els.map((e) => e.getAttribute('data-kind')))

/* AC-02: the chunks a prerendered document asks for (script src +
   modulepreload), as src/node/test/bundle-size.mjs counts them; none may
   carry calendar code */
async function initialChunks(base, doc = '200.html') {
  const html = await (await fetch(base + '/' + doc)).text()
  const scriptSrc = [...html.matchAll(/<script\b[^>]*\bsrc="(\/_nuxt\/[A-Za-z0-9._-]+\.js)"/g)].map((m) => m[1])
  const preload = [...html.matchAll(/<link\b[^>]*>/g)].map((m) => m[0])
    .filter((tag) => /\brel="modulepreload"/.test(tag))
    .map((tag) => (tag.match(/\bhref="(\/_nuxt\/[A-Za-z0-9._-]+\.js)"/) || [])[1])
    .filter(Boolean)
  const srcs = [...new Set([...scriptSrc, ...preload])]
  let gz = 0
  const withCalendar = []
  for (const src of srcs) {
    const body = Buffer.from(await (await fetch(new URL(src, base + '/'))).arrayBuffer())
    gz += gzipSync(body).length
    if (/calendar-year-strip|calendar-main|\/v1\/calendar\//.test(body.toString('utf8'))) withCalendar.push(src)
  }
  return { count: srcs.length, kb: Number((gz / 1024).toFixed(1)), withCalendar }
}

const server = await startServer()
const browser = await launch()
try {
  const init = await initialChunks(server.base).catch((e) => ({ error: String(e) }))
  ok('AC-02: 200.html names its initial chunks', init.count > 0, init)
  ok('AC-02: no calendar code in the initial download', Array.isArray(init.withCalendar) && init.withCalendar.length === 0, init.withCalendar)
  ok(`AC-02: the initial download is <= ${INITIAL_KB} KB gzip`, init.kb > 0 && init.kb <= INITIAL_KB, init.kb)
  const home = await initialChunks(server.base, 'index.html').catch((e) => ({ error: String(e) }))
  ok('AC-02: index.html names its initial chunks', home.count > 0, { count: home.count, kb: home.kb, error: home.error })
  ok('AC-02: no calendar code in the home download', Array.isArray(home.withCalendar) && home.withCalendar.length === 0, home.withCalendar)
  ok(`AC-02: the home download is <= ${HOME_KB} KB gzip`, home.kb > 0 && home.kb <= HOME_KB, home.kb)

  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const tab = await p.waitForSelector('[data-testid=sidebar-tab-calendar]', { visible: true, timeout: 15000 }).catch(() => null)
    ok('AC-01: the rail carries a Calendar tab', Boolean(tab))
    if (!tab) { await p.close(); continue }
    ok('it is named for assistive tech', (await tab.evaluate((el) => el.getAttribute('aria-label'))) === 'Calendar')
    await tab.click()
    await p.waitForFunction(() => location.pathname === '/calendar', { timeout: 10000 }).catch(() => {})
    ok('AC-01: one click lands on /calendar', new URL(p.url()).pathname === '/calendar', p.url())
    ok('the page renders', Boolean(await p.waitForSelector('[data-test=calendar-page]', { timeout: 15000 }).catch(() => null)))
    ok('AC-01: the main view (its own chunk) renders the current week', await waitWeek(p, calWeekStart(today)), await week(p))
    ok('AC-01: the tab reads as selected', (await tab.evaluate((el) => el.getAttribute('aria-selected'))) === 'true')
    const shell = await p.evaluate(() => {
      const shown = (sel) => {
        const el = document.querySelector(sel)
        if (!el) return false
        const r = el.getBoundingClientRect()
        return r.width > 40 && r.height > 40 && getComputedStyle(el).display !== 'none'
      }
      return {
        railOnly: document.querySelector('nav.sidebar')?.classList.contains('sidebar--rail') || false,
        list: shown('.sidebar-body'),
        topic: shown('[data-test=topic-section]'),
      }
    })
    ok('AC-01: one sheet - the sidebar is the icon rail only, no topic pane', shell.railOnly && !shell.list && !shell.topic, shell)

    const months = await p.$$eval('[data-test=calendar-month]', (els) => els.map((e) => e.getAttribute('data-month')))
    const y = Number(today.slice(0, 4))
    ok('the strip holds 36 mini-months, previous to next year', months.length === 36 && months[0] === `${y - 1}-01` && months[35] === `${y + 1}-12`, { n: months.length, first: months[0], last: months.at(-1) })
    await p.waitForSelector('[data-test=calendar-year-strip][data-state=ready]', { timeout: 10000 }).catch(() => null)
    const marks = await p.evaluate((d) => ({
      today: document.querySelector(`[data-test=calendar-day][data-day="${d}"]`)?.getAttribute('data-count') || '',
      dot: Boolean(document.querySelector(`[data-test=calendar-day][data-day="${d}"] [data-test=calendar-dot]`)),
      tint: document.querySelector(`[data-test=calendar-day][data-day="${d.slice(0, 4)}-12-25"]`)?.getAttribute('data-official') || '',
      none: document.querySelector(`[data-test=calendar-day][data-day="${d.slice(0, 4)}-01-15"]`)?.getAttribute('data-count') || '',
    }), today)
    ok('a day with events carries a dot (marks from the hub)', marks.today === '1' && marks.dot, marks)
    ok('an official day is tinted', marks.tint === '1', marks)
    ok('CONTROL a day with nothing has no mark', marks.none === '', marks)
    const scroller = await p.$eval('[data-test=calendar-year-strip] .cal-strip__scroll', (el) => {
      const cur = el.querySelector('[aria-current=date]')
      const a = el.getBoundingClientRect()
      const b = cur ? cur.getBoundingClientRect() : null
      return { scrolled: el.scrollTop > 0, inView: Boolean(b && b.top >= a.top - 1 && b.bottom <= a.bottom + 1) }
    })
    ok('the strip opens on this month', scroller.scrolled && scroller.inView, scroller)
    ok('this week is in the main view: today\'s release is shown', (await items(p)).includes('release'), await items(p))
    await shot(p, `desktop-${theme}`)

    /* AC-04: a click on a day 30 days on moves the main view to its week */
    const later = calAddDays(today, 30)
    await p.$eval(`[data-test=calendar-day][data-day="${later}"]`, (el) => el.scrollIntoView({ block: 'center' }))
    await p.click(`[data-test=calendar-day][data-day="${later}"]`)
    ok('AC-04: a click on a day moves the main view to that week', await waitWeek(p, calWeekStart(later)), await week(p))
    ok('AC-04: the URL keeps the day', new URL(p.url()).searchParams.get('d') === later, p.url())
    await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: 10000 }).catch(() => {})
    ok('AC-04: that week\'s event is shown', (await items(p)).includes('other'), await items(p))
    const highlighted = await p.$$eval('[data-test=calendar-day].cal-day--week', (els) => els.map((e) => e.getAttribute('data-day')))
    ok('the strip marks the shown week', highlighted.length === 7 && highlighted[0] === calWeekStart(later), highlighted)

    await p.click('[data-test=calendar-today]')
    ok('Today goes back to this week', await waitWeek(p, calWeekStart(today)), await week(p))
    await p.click('[data-test=calendar-next]')
    ok('next week', await waitWeek(p, calAddDays(calWeekStart(today), 7)), await week(p))
    await p.click('[data-test=calendar-prev]')
    await p.click('[data-test=calendar-prev]')
    ok('previous week (twice)', await waitWeek(p, calAddDays(calWeekStart(today), -7)), await week(p))

    /* the strip is one tab stop; the arrow keys walk the days, Enter picks */
    await p.focus(`[data-test=calendar-day][data-day="${today}"]`)
    await p.keyboard.press('ArrowDown')
    const focused = await p.evaluate(() => document.activeElement?.getAttribute('data-day') || '')
    ok('ArrowDown moves the focus one week on', focused === calAddDays(today, 7), focused)
    await p.keyboard.press('Enter')
    ok('Enter picks the focused day', await waitWeek(p, calWeekStart(calAddDays(today, 7))), await week(p))
    const stops = await p.$$eval('[data-test=calendar-day]', (els) => els.filter((e) => e.tabIndex === 0).length)
    ok('one tab stop in the 36 months', stops === 1, stops)

    /* a reload or a link opens the same week */
    await p.goto(server.base + '/calendar?d=' + later, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok('a deep link opens that week', await waitWeek(p, calWeekStart(later)), await week(p))
    ok('no sideways scroll', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar: ${failed} FAILED` : `calendar: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
