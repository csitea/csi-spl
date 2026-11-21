// SPL-6146 (owner HUM-10, t1 74772974, msg 3d289c5c): "the week number of
// the calendar whould be written as w-01, w-02, w-03 ... w-n with 2 digits
// in the front of the week on the monthly view and on each day, after the
// day number in the calendar view and not as a separate event".
//
// Desktop 1440x900: Month shows w-NN in the first cell of each week row,
// in front of its day number; Day, 3 days and Week show it after the day
// number in each day header. Phone 390x844: Month the same in the first
// cell of each row, Week after each day's date, Day after the date in the
// header title. Every label is the ISO week of its day (calWeekLabel) and
// none is an event item.
//
// Control: on origin/master before SPL-6146 no view draws a w-NN label, so
// every check FAILS.
//
// Run: BASE_URL=<generated mock bundle> pnpm run test:e2e calendar-week-label
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calWeekLabel, calWeekStart } from '../../src/utils/calendar-year.mjs'
import { calPhoneMonthGrid } from '../../src/utils/calendar-phone-nav.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const LABEL_RX = /^w-\d{2}$/

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

/* the expected w-NN of the first day of each of the month's six rows */
const monthRows = () => {
  const g = calPhoneMonthGrid(E2E_TODAY)
  return Array.from({ length: 6 }, (_, i) => ({ iso: g[i * 7].iso, label: calWeekLabel(g[i * 7].iso) }))
}

async function desk(browser, base, v) {
  const p = await browser.newPage()
  await pinClock(p)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/calendar${v === 'week' ? '' : `?v=${v}`}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForFunction((v) => {
    const m = document.querySelector('[data-test=calendar-main]')
    return m?.getAttribute('data-view') === v && m?.getAttribute('data-state') === 'ready'
  }, { timeout: 15000 }, v).catch(() => null)
  return p
}

async function deskMonth(browser, base) {
  const p = await desk(browser, base, 'month')
  const got = await p.$$eval('[data-test=calendar-month-grid] [role=row]', (rows) => rows.slice(1).map((r) => {
    const cells = [...r.querySelectorAll('[data-test=calendar-month-cell]')]
    const first = cells[0]
    const wk = first?.querySelector('[data-test=calendar-month-week]')
    const num = first?.querySelector('[data-test=calendar-month-day]')
    return {
      iso: first?.getAttribute('data-day') || '',
      label: wk?.textContent?.trim() || '',
      before: Boolean(wk && num && (wk.compareDocumentPosition(num) & Node.DOCUMENT_POSITION_FOLLOWING)),
      others: cells.slice(1).filter((c) => c.querySelector('[data-test=calendar-month-week]')).length,
      inItem: Boolean(wk?.closest('[data-test=calendar-item]')),
    }
  })).catch(() => [])
  const want = monthRows()
  ok('desktop Month: six week rows', got.length === 6, got.length)
  ok('desktop Month: each row\'s first cell shows its ISO week as w-NN', want.every((w, i) => got[i]?.iso === w.iso && got[i]?.label === w.label && LABEL_RX.test(got[i].label)), { want, got })
  ok('desktop Month: the label sits in front of the day number', got.length === 6 && got.every((g) => g.before), got.map((g) => g.before))
  ok('desktop Month: only the first cell of a row has it, never an event item', got.length === 6 && got.every((g) => g.others === 0 && !g.inItem), got)
  await p.close()
}

async function deskDays(browser, base, v, days) {
  const p = await desk(browser, base, v)
  const got = await p.$$eval('[data-test=calendar-week-day]', (els) => els.map((el) => {
    const h = el.querySelector('.cal-week__head')
    const date = h?.querySelector('.cal-week__date')
    const wk = h?.querySelector('[data-test=calendar-week-label]')
    return {
      day: el.getAttribute('data-day'),
      label: wk?.textContent?.trim() || '',
      after: Boolean(wk && date && (date.compareDocumentPosition(wk) & Node.DOCUMENT_POSITION_FOLLOWING)),
      inItem: Boolean(wk?.closest('[data-test=calendar-item]')),
    }
  })).catch(() => [])
  const want = days.map((d) => ({ day: d, label: calWeekLabel(d) }))
  ok(`desktop ${v}: every day header shows its ISO week w-NN`, got.length === want.length && want.every((w, i) => got[i].day === w.day && got[i].label === w.label && LABEL_RX.test(got[i].label)), { want, got })
  ok(`desktop ${v}: after the day number, in the header, not an event`, got.length === want.length && got.every((g) => g.after && !g.inItem), got)
  await p.close()
}

async function phone(browser, base, view) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await pinClock(p, 'UTC')
  await p.evaluateOnNewDocument((v) => {
    try { localStorage.setItem('spool-calendar-phone-view', v) } catch { /* about:blank */ }
  }, view)
  const spec = { width: 390, height: 844, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(`${base}/calendar`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForFunction((v) => document.querySelector('[data-test=calendar-phone]')?.getAttribute('data-view') === v, { timeout: 15000 }, view).catch(() => null)
  return { p, ctx }
}

async function phoneMonth(browser, base) {
  const { p, ctx } = await phone(browser, base, 'month')
  const want = monthRows()
  await p.waitForSelector(`[data-test=calphone-month][data-period="${want[0].iso}"] [data-test=calphone-month-cell]`, { timeout: 15000 }).catch(() => null)
  const got = await p.$$eval(`[data-test=calphone-month][data-period="${want[0].iso}"] [data-test=calphone-month-grid] [role=row]`, (rows) => rows.slice(1).map((r) => {
    const cells = [...r.querySelectorAll('[data-test=calphone-month-cell]')]
    const wk = cells[0]?.querySelector('[data-test=calphone-month-week]')
    const num = cells[0]?.querySelector('.calmonth__num')
    return {
      iso: cells[0]?.getAttribute('data-iso') || '',
      label: wk?.textContent?.trim() || '',
      before: Boolean(wk && num && (wk.compareDocumentPosition(num) & Node.DOCUMENT_POSITION_FOLLOWING)),
      others: cells.slice(1).filter((c) => c.querySelector('[data-test=calphone-month-week]')).length,
    }
  })).catch(() => [])
  ok('phone Month: each row\'s first cell shows its ISO week w-NN, in front of the day number', got.length === 6 && want.every((w, i) => got[i].iso === w.iso && got[i].label === w.label && got[i].before && got[i].others === 0), { want, got })
  await ctx.close()
}

async function phoneWeek(browser, base) {
  const { p, ctx } = await phone(browser, base, 'week')
  const mon = calWeekStart(E2E_TODAY)
  const sel = `[data-test=calphone-week][data-period="${mon}"] [data-test=calweek-list]`
  await p.waitForSelector(sel, { timeout: 15000 }).catch(() => null)
  const got = await p.$$eval(`${sel} .calweek__day`, (hs) => hs.map((h) => {
    const iso = h.querySelector('.calweek__day-iso')
    const wk = h.querySelector('[data-test=calweek-day-week]')
    return {
      day: iso?.textContent?.trim() || '',
      label: wk?.textContent?.trim() || '',
      after: Boolean(wk && iso && (iso.compareDocumentPosition(wk) & Node.DOCUMENT_POSITION_FOLLOWING)),
    }
  })).catch(() => [])
  ok('phone Week: every day header shows its ISO week w-NN after the date', got.length > 0 && got.every((g) => g.label === calWeekLabel(g.day) && LABEL_RX.test(g.label) && g.after), got)
  await ctx.close()
}

async function phoneDay(browser, base) {
  const { p, ctx } = await phone(browser, base, 'day')
  const title = await p.waitForFunction((d) => {
    const s = document.querySelector('[data-test=calphone-title] .calphone__title-text')?.textContent?.trim() || ''
    return s.includes(d) ? s : false
  }, { timeout: 15000 }, E2E_TODAY).then((h) => h.jsonValue(), () => '')
  const want = calWeekLabel(E2E_TODAY)
  ok('phone Day: the header title writes w-NN after the date', typeof title === 'string' && title.endsWith(`${E2E_TODAY} ${want}`), { title, want })
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
try {
  await deskMonth(browser, server.base)
  await deskDays(browser, server.base, 'day', [E2E_TODAY])
  await deskDays(browser, server.base, '3day', [calAddDays(E2E_TODAY, -1), E2E_TODAY, calAddDays(E2E_TODAY, 1)])
  await deskDays(browser, server.base, 'week', Array.from({ length: 7 }, (_, i) => calAddDays(calWeekStart(E2E_TODAY), i)))
  await phoneMonth(browser, server.base)
  await phoneWeek(browser, server.base)
  await phoneDay(browser, server.base)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-week-label: ${failed} FAILED` : `calendar-week-label: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
