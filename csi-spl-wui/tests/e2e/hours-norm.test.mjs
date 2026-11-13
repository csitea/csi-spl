// Spec 107 FR-41 (SPL-5440, section 22.2): the workspace's average hours per
// day in a REAL browser, against the mock bundle (hours-norm.mjs keeps the
// mock's value in localStorage spool.mock.hours-norm).
//
//   1  an admin: Tenant settings -> Hours shows "Average hours per day"
//      empty (no norm) above the four hours controls
//   2  type 7:30, save, leave the page and come back: 7:30
//   3  CONTROL: 25 is refused (error line, Save disabled), nothing saved
//   4  a product owner (hours.norm, no tenant.settings): the Hours entry
//      shows, with the average field and without the four controls
//   5  the calendar, last week, norm 0:15: a day with minutes carries the
//      warning mark on its line; its dialog shows "of 0:15 average per day"
//      and the warning line; the entry is still there (nothing refused)
//   6  CONTROL: norm 0 (none): no line has the mark, the dialog has neither
//   7  390x844 phone: the field and Save are 44..48 px, no sideways scroll
//
// Plant the defect and watch step 2 go red (the save is never clicked):
//   PROVE_RED=no-save node tests/e2e/hours-norm.test.mjs
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e hours-norm
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

const NORM = '[data-test=tenant-hours-norm]'
const INPUT = '[data-test=tenant-hours-norm-input]'
const SAVE = '[data-test=tenant-hours-norm-save]'
const DLG = '[data-test=calendar-event-form][data-mode=hours]'
const value = (p, sel) => p.$eval(sel, (e) => e.value).catch(() => null)
const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)

/** a fresh signed-in page; `me` plays a role (spool.mock.me), `norm` seeds the mock's value */
async function open(browser, vp, path, { me = null, norm = null } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      if (s.me) localStorage.setItem('spool.mock.me', JSON.stringify(s.me))
      if (s.norm !== null && !sessionStorage.getItem('norm-seeded')) {
        localStorage.setItem('spool.mock.hours-norm', String(s.norm))
        sessionStorage.setItem('norm-seeded', '1')
      }
    } catch { /* about:blank */ }
  }, { me, norm })
  await pinClock(p)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return { p, ctx, errors }
}

async function typeNorm(p, text) {
  await p.$eval(INPUT, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(INPUT, text)
}

async function reopenHours(p) {
  await p.click('[data-test=tenant-settings-nav-performance]')
  await until(p, () => location.pathname.endsWith('/tenant-settings/performance'), null, 10000)
  await p.click('[data-test=tenant-settings-nav-hours]')
  await p.waitForSelector(INPUT, { visible: true, timeout: 10000 }).catch(() => null)
  await sleep(300)
}

/* the calendar's last week (every day closed, the mock has minutes on weekdays) */
async function lastWeek(browser, norm) {
  const lastMon = calAddDays(calWeekStart(E2E_TODAY), -7)
  const g = await open(browser, { width: 1440, height: 900 }, `/calendar?d=${lastMon}`, { norm })
  const p = g.p
  await until(p, (d) => {
    const l = document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)
    return l && l.getAttribute('data-total') !== '0'
  }, lastMon, 15000)
  const marked = await p.$$eval('[data-test=calendar-hours-line]', (els) => els.filter((e) => e.hasAttribute('data-over')).map((e) => e.getAttribute('data-day')))
  const label = await p.$eval(`[data-test=calendar-hours-line][data-day="${lastMon}"]`, (e) => e.getAttribute('aria-label')).catch(() => '')
  await p.click(`[data-test=calendar-hours-line][data-day="${lastMon}"]`)
  await p.waitForSelector(`${DLG} [data-test=hours-day-row]`, { visible: true, timeout: 10000 }).catch(() => null)
  const dialog = await p.evaluate((s) => ({
    norm: document.querySelector(`${s} [data-test=hours-day-norm]`)?.textContent?.trim() || '',
    over: document.querySelector(`${s} [data-test=hours-day-over]`)?.textContent?.trim() || '',
    rows: document.querySelectorAll(`${s} [data-test=hours-day-row]`).length,
  }), DLG)
  return { g, lastMon, marked, label, dialog }
}

const server = await startServer()
const browser = await launch()
try {
  /* ---- 1..3 an admin ---- */
  const a = await open(browser, { width: 1280, height: 800 }, '/tenant-settings/hours')
  const p = a.p
  const shown = await p.waitForSelector(INPUT, { visible: true, timeout: NAV_TIMEOUT }).then(() => true, () => false)
  await sleep(300)
  const label = await p.$eval(`${NORM} label > span`, (e) => e.textContent.trim()).catch(() => '')
  const four = await p.$$eval('[data-test=tenant-hours-period]', (els) => els.length)
  ok('1 an admin sees "Average hours per day", empty, above the four hours controls', shown && label === 'Average hours per day' && (await value(p, INPUT)) === '' && four === 1, { shown, label, four })

  await typeNorm(p, '7:30')
  if (RED !== 'no-save') await p.click(SAVE)
  const notice = await until(p, (s) => Boolean(document.querySelector(s)), '[data-test=tenant-hours-norm-notice]', 5000)
  await reopenHours(p)
  const back = await value(p, INPUT)
  ok('2 7:30 is saved and reads back as 7:30', notice && back === '7:30', { notice, back })

  await typeNorm(p, '25')
  await sleep(200)
  const refused = await p.evaluate((s) => ({ err: document.querySelector('[data-test=tenant-hours-norm-error]')?.textContent?.trim() || '', disabled: document.querySelector(s)?.disabled === true }), SAVE)
  await reopenHours(p)
  ok('3 CONTROL: 25 is refused (error line, Save disabled) and 7:30 stays', refused.err !== '' && refused.disabled && (await value(p, INPUT)) === '7:30', refused)
  ok('admin: no unexpected page errors', a.errors.length === 0, a.errors)
  await a.ctx.close()

  /* ---- 4 a product owner ---- */
  const po = await open(browser, { width: 1280, height: 800 }, '/tenant-settings/hours', { me: { role: 'product_owner', permissions: ['topics.read', 'audit.read', 'hours.norm'] } })
  const poField = await po.p.waitForSelector(INPUT, { visible: true, timeout: NAV_TIMEOUT }).then(() => true, () => false)
  await sleep(300)
  const poState = await po.p.evaluate(() => ({
    nav: [...document.querySelectorAll('[data-test^=tenant-settings-nav-]')].map((e) => e.getAttribute('data-test').replace('tenant-settings-nav-', '')),
    four: document.querySelectorAll('[data-test=tenant-hours-period]').length,
    forbidden: Boolean(document.querySelector('[data-test=tenant-section-forbidden]')),
  }))
  ok('4 a product owner sees the Hours entry with the average field alone', poField && poState.nav.includes('hours') && poState.four === 0 && !poState.forbidden, poState)
  await po.ctx.close()

  /* ---- 5 and 6 the calendar ---- */
  const on = await lastWeek(browser, 15)
  ok('5a with a 0:15 norm the last week\'s lines carry the warning mark', on.marked.includes(on.lastMon) && /0:15/.test(on.label), { marked: on.marked, label: on.label })
  ok('5b the dialog shows "of 0:15 average per day" and the warning line; the rows stay', on.dialog.norm === 'of 0:15 average per day' && /above the workspace average of 0:15 per day/.test(on.dialog.over) && on.dialog.rows > 0, on.dialog)
  ok('5: no unexpected page errors', on.g.errors.length === 0, on.g.errors)
  await on.g.ctx.close()
  const off = await lastWeek(browser, 0)
  ok('6 CONTROL: no norm, no mark and neither dialog line', off.marked.length === 0 && off.dialog.norm === '' && off.dialog.over === '' && off.dialog.rows > 0, { marked: off.marked, ...off.dialog })
  await off.g.ctx.close()

  /* ---- 7 phone ---- */
  const ph = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '/tenant-settings/hours')
  await ph.p.waitForSelector(INPUT, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await ph.p.$eval(NORM, (e) => e.scrollIntoView({ block: 'start' })).catch(() => {})
  await sleep(200)
  const hs = await ph.p.$$eval(`${INPUT}, ${SAVE}`, (els) => els.map((e) => Math.round(e.getBoundingClientRect().height * 10) / 10))
  const wide = await ph.p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('7 390x844: the field and Save are 44..48 px, no sideways scroll', hs.length === 2 && hs.every((h) => h >= 44 && h <= 48) && wide <= 1, { hs, wide })
  await ph.ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nhours-norm: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
