// Spec 107 E3, T083: the one-tap week strip on the phone calendar, in a REAL
// browser at 412x915 against the mock bundle (hours-calendar-mock.mjs keeps
// every PUT /v1/me/hours entry in spool.mock.hours-entries, keyed day|target).
//
// The clock starts on a Thursday (2026-10-15), so the open week holds three
// closed working days, Monday..Wednesday, each with open rows.
//
//   1  the strip on top of the calendar (first in the page's scroll, so it
//      covers nothing) reads 3 ("3 days to approve"), its Approve is
//      >= 44 px tall, nothing scrolls sideways
//   2  one tap on Approve sends what the banner's Approve N days sends: the
//      PUT body's entries, read back from the mock, are exactly
//      hoursApproveEntries(period, 'closed') (day, target, minutes, state,
//      note), five rows on the three days; then the strip goes
//   3  CONTROL: no open day (Monday..Wednesday empty, allocation 0, so no
//      prefill either): the period is read and there is no strip
//   4  CONTROL: the week frozen: no strip
//
// Red on a tree without T083: step 1 and 2 fail (no strip).
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e hours-week-strip
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

/* a Thursday, before clock.mjs reads it: three closed days in the open week */
process.env.CAL_E2E_NOW = '2026-10-15T10:00:00Z'
const { E2E_TODAY, pinClock } = await import('./lib/clock.mjs')
const { startServer } = await import('./lib/server.mjs')
const { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } = await import('./lib/viewport.mjs')
const { calAddDays, calWeekStart } = await import('../../src/utils/calendar-year.mjs')
const { mockHoursReset, mockMyHours } = await import('../../src/utils/hours-calendar-mock.mjs')
const { hoursApproveEntries } = await import('../../src/utils/hours-mine.mjs')

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PHONE = { width: 412, height: 915, isMobile: true, hasTouch: true }
const STRIP = '[data-test=hours-week-approve]'

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
const mon = calWeekStart(E2E_TODAY)
const closed = [mon, calAddDays(mon, 1), calAddDays(mon, 2)]

/** a fresh signed-in phone page on the calendar; `seed`: allocation, empty days, the week's state */
async function open(browser, seed = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      if (!sessionStorage.getItem('strip-seeded')) {
        if (s.norm !== undefined) localStorage.setItem('spool.mock.hours-norm', String(s.norm))
        if (s.state) localStorage.setItem('spool.mock.hours-periods', JSON.stringify({ [s.mon]: { state: s.state, note: '' } }))
        if (s.empty) localStorage.setItem('spool.mock.hours-empty', JSON.stringify(Object.fromEntries(s.empty.map((d) => [d, true]))))
        sessionStorage.setItem('strip-seeded', '1')
      }
    } catch { /* about:blank */ }
  }, { ...seed, mon })
  await pinClock(p)
  await setPageViewport(p, PHONE)
  await p.goto(`${server.base}/calendar`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, PHONE)
  await p.waitForSelector('[data-test=calendar-phone]', { timeout: 15000 }).catch(() => null)
  return { p, ctx, errors }
}

/** the strip once its read settled: null when the tree has no strip at all */
async function strip(p) {
  await until(p, (s) => ['ready', 'failed'].includes(document.querySelector(s)?.getAttribute('data-state') || ''), STRIP, 15000)
  return p.$eval(STRIP, (e) => {
    const b = e.querySelector('[data-test=hours-week-approve-btn]')
    return {
      open: Number(e.getAttribute('data-open')),
      state: e.getAttribute('data-state'),
      shown: !e.hidden && e.getBoundingClientRect().height > 0,
      /* on top of the calendar: first in the current page's scroll, over nothing */
      top: e.parentElement?.classList.contains('calphone__scroll') && e.parentElement.firstElementChild === e,
      text: e.querySelector('[data-test=hours-week-approve-text]')?.textContent?.trim() || '',
      btn: b ? { text: b.textContent.trim(), h: Math.round(b.getBoundingClientRect().height), label: b.getAttribute('aria-label') } : null,
    }
  }).catch(() => null)
}

/* what the banner's Approve N days would PUT for this week (T013), from the same mock */
mockHoursReset()
const want = hoursApproveEntries(mockMyHours(E2E_TODAY, E2E_TODAY), 'closed')

const server = await startServer()
const browser = await launch()
try {
  /* ---- 1..2 three open closed days ---- */
  const g = await open(browser)
  const s1 = await strip(g.p)
  const wide = await g.p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('1 412x915: the strip reads 3 days to approve, Approve >= 44 px, no sideways scroll',
    s1?.shown && s1.open === 3 && s1.text === '3 days to approve' && s1.btn?.text === 'Approve' && s1.btn.label === 'Approve 3 days' && s1.btn.h >= 44 && s1.top && wide <= 1,
    { s1, wide })

  await g.p.click(`${STRIP} [data-test=hours-week-approve-btn]`).catch(() => {})
  await until(g.p, (s) => document.querySelector(s)?.getAttribute('data-open') === '0', STRIP, 10000)
  const stored = await g.p.evaluate(() => JSON.parse(localStorage.getItem('spool.mock.hours-entries') || '{}'))
  const got = Object.entries(stored).map(([k, v]) => ({ day: k.slice(0, 10), target: k.slice(11), minutes: v.minutes, state: v.state, note: v.note }))
  const same = want.length === got.length && want.every((e) => {
    const v = stored[`${e.day}|${e.target}`]
    return v && v.minutes === e.minutes && v.state === e.state && v.note === e.note
  })
  const days = [...new Set(want.map((e) => e.day))].sort()
  const after = await strip(g.p)
  ok('2 one tap PUTs the closed days\' open rows (5 rows, Mon..Wed, approved), then the strip goes',
    same && want.length === 5 && JSON.stringify(days) === JSON.stringify(closed) && after?.open === 0 && !after.shown,
    { want, got, after })
  ok('1..2: no unexpected page errors', g.errors.length === 0, g.errors)
  await g.ctx.close()

  /* ---- 3 CONTROL: no open day ---- */
  const z = await open(browser, { norm: 0, empty: closed })
  const s3 = await strip(z.p)
  ok('3 CONTROL: no open day: the period is read and there is no strip', s3?.state === 'ready' && s3.open === 0 && !s3.shown, s3)
  await z.ctx.close()

  /* ---- 4 CONTROL: the week frozen ---- */
  const f = await open(browser, { state: 'frozen' })
  const s4 = await strip(f.p)
  ok('4 CONTROL: a frozen week: no strip', s4?.state === 'ready' && s4.open === 0 && !s4.shown, s4)
  await f.ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nhours-week-strip: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
