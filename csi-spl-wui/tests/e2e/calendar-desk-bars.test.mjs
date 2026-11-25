// SPL-6491 (member HUM-5, topic 4f4748dd): a TIMED event over several days
// was drawn nowhere in the desktop Week. Now it is one bar in the all-day
// strip across every shown day it covers, as Google draws it, at 1440x900,
// light and dark, viewer zone Europe/Amsterdam:
//
// (a) a 17-day timed event that began two weeks before is ONE bar from the
//     Monday column to the Thursday one, marked as going on before (no
//     rounded start), its title whole, its colour band kept (a-567 W2);
// (b) a 2.3-day timed event from Friday 23:00 is ONE bar over Friday ..
//     Sunday, marked as going on after, its start time and its whole title
//     (a-567 W1: a bar cut per column showed "23:00 W...");
// (c) neither is a block on the hour grid; a 1-hour event still is;
// (d) a bar's click opens its pop-over; its hover carries its start and end;
// (e) 3 days and Day cut the bar at their range; Month lists the 17-day
//     event on each of its days.
//
// Control: on the tree before SPL-6491 there is no calendar-bar, the 17-day
// event is on no shown day and the 2.3-day one is a 1-hour block at 23:00,
// so (a), (b), (c), (d) and (e) FAIL.
//
// Run: BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-desk-bars
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { calAddDays, calWeekStart } from '../../src/utils/calendar-year.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const ZONE = 'Europe/Amsterdam'
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-desk-bars-${name}.png`) })
}

/* the shown week (Monday mon) and the member's two shapes around it */
const mon = calWeekStart(E2E_TODAY)
const day = (n) => calAddDays(mon, n)
const LONG = '00000000-0000-4000-8000-000000649101'
const TRIP = '00000000-0000-4000-8000-000000649102'
const HOUR = '00000000-0000-4000-8000-000000649103'
/* the pinned e2e week is in October: Amsterdam is UTC+2 (CEST), so local
   00:00 is 22:00Z the day before */
const SEED = [
  /* 17 days: from Monday 00:00 Amsterdam two weeks before, to Friday 00:00 */
  { id: LONG, title: 'Long timed trip', starts_at: `${day(-14)}T22:00:00Z`, ends_at: `${day(3)}T22:00:00Z`, color: 'grape' },
  /* 2.3 days: Friday 23:00 Amsterdam to Monday 05:40 next week */
  { id: TRIP, title: 'Weekend away', starts_at: `${day(4)}T21:00:00Z`, ends_at: `${day(7)}T03:40:00Z`, color: 'sage' },
  { id: HOUR, title: 'One hour', starts_at: `${day(2)}T10:00:00Z`, ends_at: `${day(2)}T11:00:00Z` },
]

/* the bar of event id: one element per bar (a-567 W1), with its shown
   first / last day, its box against those days' columns, whether its title
   is whole (not cut with an ellipsis) and its colour band (W2) */
const barOf = (p, id) => p.$$eval(`[data-test=calendar-bar][data-id="${id}"]`, (els) => els.map((e) => {
  const r = e.getBoundingClientRect()
  const t = e.querySelector('.cal-week__title')
  const col = (d) => document.querySelector(`[data-test=calendar-week-day][data-day="${d}"]`)?.getBoundingClientRect()
  const from = e.getAttribute('data-day'), to = e.getAttribute('data-to')
  const cs = getComputedStyle(e)
  return {
    from, to, before: e.getAttribute('data-before') === 'true', after: e.getAttribute('data-after') === 'true',
    left: Math.round(r.left), right: Math.round(r.right), top: Math.round(r.top), h: Math.round(r.height),
    colL: Math.round(col(from)?.left ?? -1), colR: Math.round(col(to)?.right ?? -1),
    title: t ? t.textContent.trim() : '', titleW: t ? Math.round(t.getBoundingClientRect().width) : 0,
    whole: t ? t.scrollWidth <= t.clientWidth + 1 : false,
    band: cs.borderInlineStartWidth, bandColor: cs.borderInlineStartColor, bg: cs.backgroundColor,
    time: e.querySelector('.cal-week__time')?.textContent.trim() || '', hover: e.getAttribute('title') || '',
  }
})).catch(() => [])
/* the bar runs from its first shown column to its last (within the insets) */
const spansCols = (b) => Boolean(b) && b.left >= b.colL - 1 && b.left <= b.colL + 8 && b.right <= b.colR + 1 && b.right >= b.colR - 8
const inGrid = (p, id) => p.$$eval(`.cal-grid [data-test=calendar-item][data-id="${id}"]`, (els) => els.length).catch(() => -1)
const ready = (p) => p.waitForSelector('[data-test=calendar-main][data-state=ready]', { timeout: 15000 }).then(() => true, () => false)

async function open(p, base, query) {
  await p.goto(`${base}/calendar${query}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await ready(p)
  await new Promise((r) => setTimeout(r, 300))
}

async function run(browser, base, theme) {
  console.log(`-- 1440x900 ${theme} ${ZONE}`)
  const p = await browser.newPage()
  await pinClock(p, ZONE)
  await p.setViewport({ width: 1440, height: 900 })
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
  await p.evaluateOnNewDocument((t, seed) => {
    try {
      localStorage.setItem('spool-theme', t)
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(seed))
    } catch { /* private mode */ }
  }, theme, SEED)
  await open(p, base, '')
  await shot(p, `week-${theme}`)

  /* (a) */
  const long = await barOf(p, LONG)
  const L = long[0]
  ok(`(a) ${theme}: the 17-day event is ONE bar over Monday .. Thursday`, long.length === 1 && L.from === day(0) && L.to === day(3) && spansCols(L), L)
  ok(`(a) ${theme}: it goes on before the week, its title whole`, L?.before === true && !L?.after && L?.title === 'Long timed trip' && L?.whole && L?.titleW > 60, L)
  ok(`(a) ${theme}: a bar going on from before keeps its colour band (W2)`, L?.band === '4px' && L?.bandColor !== L?.bg, { band: L?.band, color: L?.bandColor })

  /* (b) */
  const trip = await barOf(p, TRIP)
  const T = trip[0]
  ok(`(b) ${theme}: the 2.3-day event is ONE bar over Friday .. Sunday, going on after`, trip.length === 1 && T.from === day(4) && T.to === day(6) && T.after && !T.before && spansCols(T), T)
  ok(`(b) ${theme}: it shows its start time and its whole title (W1)`, T?.time === '23:00' && T?.title === 'Weekend away' && T?.whole && T?.titleW > 60, T)
  ok(`(a,b) ${theme}: the two bars share a lane (they do not overlap)`, Boolean(L && T && Math.abs(L.top - T.top) <= 1), { long: L?.top, trip: T?.top })

  /* (c) */
  const grid = { long: await inGrid(p, LONG), trip: await inGrid(p, TRIP), hour: await inGrid(p, HOUR) }
  ok(`(c) ${theme}: neither is a block on the hour grid; a 1-hour event still is`, grid.long === 0 && grid.trip === 0 && grid.hour === 1, grid)

  /* (d) */
  ok(`(d) ${theme}: the hover carries the start and the end`, /\d{4}-\d{2}-\d{2} 23:00 – \d{4}-\d{2}-\d{2} 05:40/.test(T?.hover || ''), T?.hover)
  const mid = await p.$eval(`[data-test=calendar-week-day][data-day="${day(2)}"]`, (e) => { const r = e.getBoundingClientRect(); return r.left + r.width / 2 }).catch(() => 0)
  if (L) await p.mouse.click(mid, L.top + L.h / 2).catch(() => {})
  const pop = await p.waitForSelector(`[data-test=calendar-event-popover][data-id="${LONG}"]`, { timeout: 5000 }).then(() => true, () => false)
  ok(`(d) ${theme}: a click on the bar over Wednesday opens its pop-over`, pop)
  await p.keyboard.press('Escape').catch(() => {})

  /* (e) */
  await open(p, base, `?v=3day&d=${day(2)}`)
  const three = await barOf(p, LONG)
  ok(`(e) ${theme}: 3 days cuts the bar at its range`, three.length === 1 && three[0].from === day(1) && three[0].to === day(3) && three[0].before && spansCols(three[0]), three)
  await open(p, base, `?v=day&d=${day(5)}`)
  const one = await barOf(p, TRIP)
  ok(`(e) ${theme}: Day shows the bar on a middle day, going on both ways`, one.length === 1 && one[0].before && one[0].after && one[0].title === 'Weekend away', one)
  await open(p, base, `?v=month&d=${day(2)}`)
  const cells = await p.$$eval(`[data-test=calendar-month-cell]`, (els, id) => els.filter((c) => c.querySelector(`[data-id="${id}"]`)).map((c) => c.getAttribute('data-day')), LONG).catch(() => [])
  ok(`(e) ${theme}: Month lists the 17-day event on each of its shown days`, cells.includes(day(0)) && cells.includes(day(3)) && !cells.includes(day(4)) && cells.length >= 4, cells)
  ok(`${theme}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) await run(browser, server.base, theme)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-desk-bars: ${failed} FAILED` : `calendar-desk-bars: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
