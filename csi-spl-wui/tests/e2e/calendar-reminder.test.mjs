// Spec 089 T006, AC-06 (owner D4): a calendar reminder is a plain in-app
// pop-up, Google Calendar style. In the mock tenant (src/utils/calendar-reminders-mock.mjs,
// seeded through localStorage) the tab's own timer shows the pop-up with the
// event's title and time when its reminder comes; a missed reminder shows on
// open while its event runs, an ended one never; Dismiss is remembered across
// a reload; Open goes to /calendar?event=<id>; no spool message and no notification request is made on the way.
// Light and dark at desktop width, and a phone.
//
// Control: before T006 there is no [data-test=calendar-reminder]; every
// "shows" check fails.
//
// Run:
//   pnpm run test:e2e calendar-reminder
//   BASE_URL=<generated bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-reminder
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-reminder-${name}.png`) })
}

/* the reminder path must never write a message or ring a notification */
const FORBIDDEN = /\/v1\/(messages|notes|notify|notifications|push)\b|\/v1\/topics\/[^/]+\/messages/

/** The seed: one reminder due 25 s after load, one missed while its
 *  event still runs, one missed whose event is over. Times from the browser's clock. */
function seed(dueInMs) {
  /* when each card first showed, by the page's clock, against its reminder time */
  window.__shown = {}
  const iv = setInterval(() => {
    for (const el of document.querySelectorAll('[data-test=calendar-reminder]')) {
      const id = el.getAttribute('data-event-id')
      if (!(id in window.__shown)) window.__shown[id] = Date.now()
    }
  }, 50)
  window.addEventListener('pagehide', () => clearInterval(iv))
  /* once per tab: a reload keeps the store's times and the dismissed map */
  if (sessionStorage.getItem('calendar-seeded')) return
  sessionStorage.setItem('calendar-seeded', '1')
  const now = Date.now()
  const at = (ms) => new Date(now + ms).toISOString()
  const MIN = 60000
  sessionStorage.setItem('calendar-soon-at', String(now + dueInMs))
  localStorage.setItem('spool.mock.calendar-reminders', JSON.stringify([
    { id: 'rem-soon', title: 'Release review', starts_at: at(15 * MIN), ends_at: at(45 * MIN), remind_at: at(dueInMs) },
    { id: 'rem-missed', title: 'Freeze window', starts_at: at(-20 * MIN), ends_at: at(40 * MIN), remind_at: at(-30 * MIN) },
    { id: 'rem-over', title: 'Old standup', starts_at: at(-120 * MIN), ends_at: at(-60 * MIN), remind_at: at(-130 * MIN) },
  ]))
}

/* each page in its own context: localStorage (seed, dismissed map) never leaks between them */
async function newPage(browser) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.done = () => ctx.close()
  return p
}

const titles = (p) => p.$$eval('[data-test=calendar-reminder]', (els) => els.map((e) => e.querySelector('[data-test=calendar-reminder-title]')?.textContent?.trim() || ''))
const waitTitles = (p, want, timeout = 15000) => p.waitForFunction((want) => {
  const got = [...document.querySelectorAll('[data-test=calendar-reminder-title]')].map((e) => e.textContent.trim())
  return got.length === want.length && want.every((w) => got.includes(w))
}, { timeout }, want).then(() => true, () => false)

const browser = await launch()
const server = await startServer()
try {
  for (const theme of ['dark', 'light']) {
    const p = await newPage(browser)
    await p.setViewport({ width: 1280, height: 800 })
    const bad = []
    p.on('request', (r) => { if (FORBIDDEN.test(r.url())) bad.push(r.method() + ' ' + r.url()) })
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.evaluateOnNewDocument(seed, 25000)
    await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

    ok(`${theme}: the due reminder shows`, await waitTitles(p, ['Freeze window', 'Release review'], 40000), await titles(p))
    /* the page's 50 ms poll records a card's first show a beat after it renders */
    await p.waitForFunction(() => window.__shown && 'rem-soon' in window.__shown && 'rem-missed' in window.__shown, { timeout: 5000 }).catch(() => {})
    const when = await p.evaluate(() => ({ ...window.__shown, soonAt: Number(sessionStorage.getItem('calendar-soon-at')) }))
    ok(`${theme}: a missed reminder shows on open, before the due one comes`, when['rem-missed'] > 0 && when['rem-missed'] < when.soonAt, when)
    ok(`${theme}: the due reminder shows when its time comes, not before`, when['rem-soon'] >= when.soonAt && when['rem-soon'] - when.soonAt < 3000, when)
    ok(`${theme}: an ended event's reminder never shows`, !(await titles(p)).includes('Old standup') && !('rem-over' in when))
    const card = await p.$eval('[data-test=calendar-reminder][data-event-id=rem-soon]', (el) => ({
      time: el.querySelector('[data-test=calendar-reminder-time]')?.textContent?.trim() || '',
      open: Boolean(el.querySelector('[data-test=calendar-reminder-dismiss]')),
      role: el.getAttribute('role'),
      inView: (() => { const r = el.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth && r.bottom <= innerHeight && r.width > 0 })(),
    })).catch(() => null)
    ok(`${theme}: the pop-up gives the event's time`, Boolean(card && /^\d{4}-\d\d-\d\d \d\d:\d\d - (\d{4}-\d\d-\d\d )?\d\d:\d\d$/.test(card.time)), card)
    ok(`${theme}: it has a Dismiss button, is announced and sits in view`, Boolean(card && card.open && card.role === 'alert' && card.inView), card)
    await shot(p, `${theme}-shown`)

    await p.click('[data-test=calendar-reminder][data-event-id=rem-soon] [data-test=calendar-reminder-dismiss]')
    ok(`${theme}: Dismiss closes that reminder only`, await waitTitles(p, ['Freeze window'], 5000), await titles(p))
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await new Promise((r) => setTimeout(r, 2500))
    ok(`${theme}: a dismissed reminder stays dismissed after a reload`, (await titles(p)).join() === 'Freeze window', await titles(p))
    await p.click('[data-test=calendar-reminder][data-event-id=rem-missed] [data-test=calendar-reminder-open]')
    ok(`${theme}: Open goes to the event in the Calendar section`, await p.waitForFunction(() => /\/calendar$/.test(location.pathname) && new URLSearchParams(location.search).get('event') === 'rem-missed', { timeout: 10000 }).then(() => true, () => false), await p.evaluate(() => location.pathname + location.search))
    ok(`${theme}: Open closes the last reminder and the pop-up`, await p.waitForFunction(() => !document.querySelector('[data-test=calendar-reminders]'), { timeout: 5000 }).then(() => true, () => false))
    ok(`${theme}: no spool message or notification request was made`, bad.length === 0, bad)
    await p.done()
  }

  const m = await newPage(browser)
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.evaluateOnNewDocument(seed, 1000)
  await m.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('phone: both live reminders show', await waitTitles(m, ['Freeze window', 'Release review'], 15000), await titles(m))
  const fit = await m.$eval('[data-test=calendar-reminders]', (el) => {
    const r = el.getBoundingClientRect()
    const b = el.querySelector('[data-test=calendar-reminder-dismiss]').getBoundingClientRect()
    return { left: Math.round(r.left), right: Math.round(r.right), w: innerWidth, btn: Math.round(b.height) }
  }).catch(() => null)
  ok('phone: the pop-up fits the screen with 44 px buttons', Boolean(fit && fit.left >= 0 && fit.right <= fit.w && fit.btn >= 44), fit)
  ok('phone: no sideways scroll', await m.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  await shot(m, 'phone')
  await m.done()

  const q = await newPage(browser)
  await q.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await new Promise((r) => setTimeout(r, 1500))
  ok('no reminders: no pop-up', !(await q.$('[data-test=calendar-reminders]')))
  await q.done()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-reminder: ${failed} FAILED` : `calendar-reminder: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
