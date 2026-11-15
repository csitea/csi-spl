// Spec 107 FR-41 per member (SPL-5558; owner HUM-10 t1 59a7062f msg d26fd5e6:
// "settable per person via the persons section"): a member's own average hours
// per day on their People card, in a REAL browser against the mock bundle
// (hours-norm.mjs keeps the mock's values in localStorage:
// spool.mock.hours-norm, spool.mock.hours-norm.members).
//
//   1  an admin opens HUM-3's card, workspace average 7:30: the field shows,
//      empty, with 7:30 as its placeholder and in its hint
//   2  type 6:00, save, open the card again: 6:00
//   3  CONTROL: 25 is refused (error line, Save disabled), 6:00 stays
//   4  empty the field and save: open the card again, it is empty (the
//      workspace's average is back)
//   5  the calendar, last week, workspace average none, HUM-1's own 0:15:
//      a day with minutes carries the warning mark and the dialog says
//      "above your average of 0:15 per day"
//   6  CONTROL: the own average is HUM-3's, not the reader's: no mark
//   7  CONTROL: a developer (no hours.norm) sees no field on the card
//   8  390x844 phone: the field and Save are 44..48 px, no sideways scroll
//
// Plant the defect and watch step 2 go red (the save is never clicked):
//   PROVE_RED=no-save node tests/e2e/person-hours-norm.test.mjs
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e person-hours-norm
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

const FORM = '[data-test=person-hours-norm]'
const INPUT = '[data-test=person-hours-norm-input]'
const SAVE = '[data-test=person-hours-norm-save]'
const DLG = '[data-test=calendar-event-form][data-mode=hours]'
const CARD = '/people/HUM-3'
const value = (p, sel) => p.$eval(sel, (e) => e.value).catch(() => null)
const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)

/** a fresh signed-in page; `me` plays a role, `norm` / `members` seed the mock's values once */
async function open(browser, vp, path, { me = null, norm = null, members = null } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      if (s.me) localStorage.setItem('spool.mock.me', JSON.stringify(s.me))
      if (!sessionStorage.getItem('norm-seeded')) {
        if (s.norm !== null) localStorage.setItem('spool.mock.hours-norm', String(s.norm))
        if (s.members !== null) localStorage.setItem('spool.mock.hours-norm.members', JSON.stringify(s.members))
        sessionStorage.setItem('norm-seeded', '1')
      }
    } catch { /* about:blank */ }
  }, { me, norm, members })
  await pinClock(p)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return { p, ctx, errors }
}

async function typeNorm(p, text) {
  await p.$eval(INPUT, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  if (text) await p.type(INPUT, text)
}

/** open the card again (a full reload: the field reads the stored value) */
async function reopen(p) {
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(INPUT, { visible: true, timeout: 15000 }).catch(() => null)
  await until(p, (s) => !document.querySelector(s)?.disabled, INPUT, 10000)
  await sleep(300)
}

/* the calendar's last week (every day closed, the mock has minutes on weekdays) */
async function lastWeek(browser, members) {
  const lastMon = calAddDays(calWeekStart(E2E_TODAY), -7)
  const g = await open(browser, { width: 1440, height: 900 }, `/calendar?d=${lastMon}`, { norm: 0, members })
  const p = g.p
  await until(p, (d) => {
    const l = document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)
    return l && l.getAttribute('data-total') !== '0'
  }, lastMon, 15000)
  const marked = await p.$$eval('[data-test=calendar-hours-line]', (els) => els.filter((e) => e.hasAttribute('data-over')).map((e) => e.getAttribute('data-day')))
  await p.click(`[data-test=calendar-hours-line][data-day="${lastMon}"]`)
  await p.waitForSelector(`${DLG} [data-test=hours-day-row]`, { visible: true, timeout: 10000 }).catch(() => null)
  const over = await p.$eval(`${DLG} [data-test=hours-day-over]`, (e) => e.textContent.trim()).catch(() => '')
  return { g, lastMon, marked, over }
}

const server = await startServer()
const browser = await launch()
try {
  /* ---- 1..4 an admin on HUM-3's card ---- */
  const a = await open(browser, { width: 1280, height: 800 }, CARD, { norm: 450, members: {} })
  const p = a.p
  const shown = await p.waitForSelector(INPUT, { visible: true, timeout: NAV_TIMEOUT }).then(() => true, () => false)
  await until(p, (s) => !document.querySelector(s)?.disabled, INPUT, 10000)
  await sleep(300)
  const first = await p.evaluate((s) => ({
    label: document.querySelector(`${s.f} label > span`)?.textContent?.trim() || '',
    placeholder: document.querySelector(s.i)?.getAttribute('placeholder') || '',
    hint: document.querySelector('[data-test=person-hours-norm-hint]')?.textContent?.trim() || '',
    value: document.querySelector(s.i)?.value,
  }), { f: FORM, i: INPUT })
  ok('1 an admin sees "Average hours per day" on the card, empty, the workspace\'s 7:30 as placeholder and in the hint',
    shown && first.label === 'Average hours per day' && first.value === '' && first.placeholder === '7:30' && first.hint.includes('(7:30)'), first)

  await typeNorm(p, '6:00')
  if (RED !== 'no-save') await p.click(SAVE)
  const notice = await until(p, (s) => Boolean(document.querySelector(s)), '[data-test=person-hours-norm-notice]', 5000)
  await reopen(p)
  const back = await value(p, INPUT)
  ok('2 6:00 is saved and reads back as 6:00', notice && back === '6:00', { notice, back })

  await typeNorm(p, '25')
  await sleep(200)
  const refused = await p.evaluate((s) => ({ err: document.querySelector('[data-test=person-hours-norm-error]')?.textContent?.trim() || '', disabled: document.querySelector(s)?.disabled === true }), SAVE)
  await reopen(p)
  ok('3 CONTROL: 25 is refused (error line, Save disabled) and 6:00 stays', refused.err !== '' && refused.disabled && (await value(p, INPUT)) === '6:00', refused)

  await typeNorm(p, '')
  await p.click(SAVE)
  const cleared = await until(p, (s) => Boolean(document.querySelector(s)), '[data-test=person-hours-norm-notice]', 5000)
  await reopen(p)
  ok('4 emptied and saved: the field is empty again (the workspace\'s average)', cleared && (await value(p, INPUT)) === '', { cleared })
  ok('admin: no unexpected page errors', a.errors.length === 0, a.errors)
  await a.ctx.close()

  /* ---- 5 and 6 the calendar reads the reader's own average ---- */
  const own = await lastWeek(browser, { 'HUM-1': 15 })
  ok('5 the reader\'s own 0:15: the last week is marked, "above your average of 0:15 per day"',
    own.marked.includes(own.lastMon) && /above your average of 0:15 per day/.test(own.over), { marked: own.marked, over: own.over })
  ok('5: no unexpected page errors', own.g.errors.length === 0, own.g.errors)
  await own.g.ctx.close()
  const other = await lastWeek(browser, { 'HUM-3': 15 })
  ok('6 CONTROL: HUM-3\'s own average does not mark the reader\'s calendar', other.marked.length === 0 && other.over === '', { marked: other.marked, over: other.over })
  await other.g.ctx.close()

  /* ---- 7 a developer ---- */
  const dev = await open(browser, { width: 1280, height: 800 }, CARD, { me: { role: 'developer', permissions: ['topics.read'] } })
  await dev.p.waitForSelector('[data-test=person-card]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  /* the reader's role is loaded (the access store's me), not merely the card drawn */
  const role = await until(dev.p, () => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('access')?.me?.role === 'developer', null, 15000)
  await sleep(500)
  ok('7 CONTROL: a developer, role loaded, sees no average field on the card', role && !(await dev.p.$(FORM)), { role })
  ok('7: no unexpected page errors (the card re-renders when the role lands)', dev.errors.length === 0, dev.errors)
  await dev.ctx.close()

  /* ---- 8 phone ---- */
  const ph = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, CARD, { norm: 450 })
  await ph.p.waitForSelector(INPUT, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await ph.p.$eval(FORM, (e) => e.scrollIntoView({ block: 'start' })).catch(() => {})
  await sleep(200)
  const hs = await ph.p.$$eval(`${INPUT}, ${SAVE}`, (els) => els.map((e) => Math.round(e.getBoundingClientRect().height * 10) / 10))
  const wide = await ph.p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('8 390x844: the field and Save are 44..48 px, no sideways scroll', hs.length === 2 && hs.every((h) => h >= 44 && h <= 48) && wide <= 1, { hs, wide })
  await ph.ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nperson-hours-norm: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
