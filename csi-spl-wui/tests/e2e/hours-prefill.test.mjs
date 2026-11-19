// Spec 107 E2, T082 (owner Q31 = A): an empty closed working day prefilled at
// the member's allocation, marked "No activity", in a REAL browser against the
// mock bundle (hours-calendar-mock.mjs: spool.mock.hours-empty empties the
// days, spool.mock.hours-norm is the allocation).
//
//   1  last week, allocation 8:00, Monday and Tuesday empty: their lines say
//      "No activity" (text and label); Wednesday, with activity, does not
//   2  Monday's dialog: one 8:00 row marked "No activity"; Why says it counts
//      only once approved
//   3  Approve day: the row is approved, its mark and the line's mark gone
//   4  CONTROL: allocation 0: the empty Monday has no row and no mark
//   5  412x915 phone: the compact line carries the mark as data-no-activity
//
// Plant the defect and watch steps 1..3 go red (the days keep their fixture):
//   PROVE_RED=no-empty node tests/e2e/hours-prefill.test.mjs
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e hours-prefill
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calWeekStart } from '../../src/utils/calendar-year.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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

const DLG = '[data-test=calendar-event-form][data-mode=hours]'
const LINE = (d) => `[data-test=calendar-hours-line][data-day="${d}"]`
const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)
const lastMon = calAddDays(calWeekStart(E2E_TODAY), -7)
const lastTue = calAddDays(lastMon, 1)
const lastWed = calAddDays(lastMon, 2)

/** a fresh signed-in page on last week, with `norm` minutes a day and Monday and Tuesday empty */
async function open(browser, vp, norm) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      if (!sessionStorage.getItem('prefill-seeded')) {
        localStorage.setItem('spool.mock.hours-norm', String(s.norm))
        if (s.empty.length) localStorage.setItem('spool.mock.hours-empty', JSON.stringify(Object.fromEntries(s.empty.map((d) => [d, true]))))
        sessionStorage.setItem('prefill-seeded', '1')
      }
    } catch { /* about:blank */ }
  }, { norm, empty: RED === 'no-empty' ? [] : [lastMon, lastTue] })
  await pinClock(p)
  await setPageViewport(p, vp)
  await p.goto(`${server.base}/calendar?d=${lastMon}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await until(p, (d) => {
    const l = document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)
    return l && l.getAttribute('data-total') !== '0'
  }, lastWed, 15000)
  return { p, ctx, errors }
}

const line = (p, d) => p.$eval(LINE(d), (e) => ({
  mark: e.getAttribute('data-no-activity') === 'true',
  text: e.querySelector('[data-test=calendar-hours-no-activity]')?.textContent?.trim() || '',
  label: e.getAttribute('aria-label') || '',
})).catch(() => null)

async function dialogOf(p, d) {
  await p.click(LINE(d))
  await p.waitForSelector(`${DLG} [data-test=hours-day-day], ${DLG} [data-test=hours-day]`, { visible: true, timeout: 10000 }).catch(() => null)
  await until(p, (s) => document.querySelectorAll(`${s} [data-test=hours-day-row]`).length > 0 || Boolean(document.querySelector(`${s} [data-test=hours-day-empty]`)), DLG, 10000)
  return p.evaluate((s) => [...document.querySelectorAll(`${s} [data-test=hours-day-row]`)].map((r) => ({
    state: r.getAttribute('data-row-state'),
    minutes: r.getAttribute('data-minutes'),
    mark: r.getAttribute('data-no-activity') === 'true',
    tag: r.querySelector('[data-test=hours-row-no-activity]')?.textContent?.trim() || '',
  })), DLG)
}

const server = await startServer()
const browser = await launch()
try {
  /* ---- 1..3 an allocation of 8:00 ---- */
  const g = await open(browser, { width: 1440, height: 900 }, 480)
  const p = g.p
  const mon = await line(p, lastMon)
  const tue = await line(p, lastTue)
  const wed = await line(p, lastWed)
  ok('1 the empty Monday and Tuesday say "No activity"; Wednesday does not',
    mon?.mark && mon.text === 'No activity' && /No activity/.test(mon.label) && tue?.mark && wed && !wed.mark && wed.text === '', { mon, tue, wed })

  const rows = await dialogOf(p, lastMon)
  await p.click(`${DLG} [data-test=hours-row-why]`).catch(() => {})
  const why = await p.$eval(`${DLG} [data-test=hours-row-why-sheet]`, (e) => e.textContent.trim()).catch(() => '')
  ok('2 Monday: one 8:00 suggested row marked "No activity"; Why says it counts once approved',
    rows.length === 1 && rows[0].state === 'suggested' && rows[0].minutes === '480' && rows[0].mark && rows[0].tag === 'No activity' && /only after you approve/.test(why), { rows, why })

  await p.click(`${DLG} [data-test=hours-approve-day]`).catch(() => {})
  await until(p, (s) => document.querySelector(`${s} [data-test=hours-day-row]`)?.getAttribute('data-row-state') === 'approved', DLG, 10000)
  const after = await p.evaluate((s) => [...document.querySelectorAll(`${s} [data-test=hours-day-row]`)].map((r) => ({
    state: r.getAttribute('data-row-state'), mark: r.hasAttribute('data-no-activity'), tag: Boolean(r.querySelector('[data-test=hours-row-no-activity]')),
  })), DLG)
  await p.keyboard.press('Escape')
  await until(p, (d) => !document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)?.hasAttribute('data-no-activity'), lastMon, 10000)
  const monAfter = await line(p, lastMon)
  ok('3 Approve day: the row is approved, the row and the line lose the mark',
    after.length === 1 && after[0].state === 'approved' && !after[0].mark && !after[0].tag && monAfter && !monAfter.mark, { after, monAfter })
  ok('1..3: no unexpected page errors', g.errors.length === 0, g.errors)
  await g.ctx.close()

  /* ---- 4 CONTROL: no allocation ---- */
  const z = await open(browser, { width: 1440, height: 900 }, 0)
  const zMon = await line(z.p, lastMon)
  const zRows = await dialogOf(z.p, lastMon)
  ok('4 CONTROL: allocation 0, the empty Monday has no row and no mark', zMon && !zMon.mark && zRows.length === 0, { zMon, zRows })
  await z.ctx.close()

  /* ---- 5 phone ---- */
  const ph = await open(browser, { width: 412, height: 915, isMobile: true, hasTouch: true }, 480)
  const phMarks = await ph.p.$$eval('[data-test=calendar-hours-line][data-no-activity=true]', (els) => els.map((e) => e.getAttribute('data-day')))
  const wide = await ph.p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('5 412x915: the marked lines are there, no sideways scroll', phMarks.includes(lastMon) && wide <= 1, { phMarks, wide })
  await ph.ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nhours-prefill: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
