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
import { HOURS_BIZ_OWNER, HOURS_MEMBER, driveHoursTeam, hoursFrozenDay } from './lib/hours-team.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* ci_initial_gzip_kb (027 perf-budgets.json, owner 2026-10-02) */
const INITIAL_KB = 155
/* ci_home_gzip_kb (027 perf-budgets.json, spec 109 T002; T003 lowers it) */
const HOME_KB = 352.1
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
    if (/calendar-year-strip|calendar-main|\/v1\/calendar\/|calendar-hours-line|hours-panel/.test(body.toString('utf8'))) withCalendar.push(src)
  }
  return { count: srcs.length, kb: Number((gz / 1024).toFixed(1)), withCalendar }
}

/* spec 107 v1.2 T013 + T014 at 1440 px (owner R9, R10; spec 4.1, 5.2, 5.3):
   inside the Working hours dialog and the panel's Mine tab, on last week
   (every day closed) of the mock, which keeps the writes in localStorage.
   Its own browser context, so the T011 checks above read the fixture.
   CONTROL: before T013 / T014 the dialog is read only - no
   [data-test=hours-approve-open], no stepper, no + Add - so these FAIL. */
const DLG = '[data-test=calendar-event-form][data-mode=hours]'
const rowOf = (p, target) => p.$eval(`${DLG} [data-test=hours-day-row][data-target="${target}"]`, (el) => ({
  state: el.getAttribute('data-row-state'),
  minutes: Number(el.getAttribute('data-minutes')),
  delta: Number(el.getAttribute('data-delta')),
  note: el.querySelector('[data-test=hours-day-note]')?.textContent?.trim() || '',
})).catch(() => null)
const rowAttr = (p, target, attr, want) => p.waitForFunction((s, tg, a, v) => document.querySelector(`${s} [data-test=hours-day-row][data-target="${tg}"]`)?.getAttribute(a) === v, { timeout: 8000 }, DLG, target, attr, want).then(() => true, () => false)
const TOPIC = 't:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'

async function openDay(p, day) {
  await p.waitForFunction((d) => document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)?.getAttribute('data-total') !== '0', { timeout: 10000 }, day).catch(() => {})
  await p.click(`[data-test=calendar-hours-line][data-day="${day}"]`)
  return Boolean(await p.waitForSelector(`${DLG}[data-day="${day}"] [data-test=hours-day-row]`, { visible: true, timeout: 10000 }).catch(() => null))
}
async function closeDay(p) {
  await p.click('[data-test=calendar-hours-close]')
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, DLG).catch(() => {})
}

async function mineDesktop(browser, base) {
  console.log('-- 1440x900 T013 + T014 (Mine)')
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const lastMon = calAddDays(calWeekStart(today), -7)
  const lastTue = calAddDays(lastMon, 1)
  await p.goto(`${base}/calendar?d=${lastMon}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await waitWeek(p, lastMon)

  /* T013: one tap accepts a delta (Tuesday's topic: approved 0:50, now 1:10) */
  ok('T013: a day opens its Working hours dialog', await openDay(p, lastTue))
  const before = await rowOf(p, TOPIC)
  ok('T013: Tuesday\'s discussion carries a +0:20 delta', before?.delta === 20, before)
  await p.click(`${DLG} [data-test=hours-day-row][data-target="${TOPIC}"] [data-test=hours-row-delta]`).catch(() => {})
  ok('T013: ✓ +0:20 accepts it in one tap (1:10, no delta)', await rowAttr(p, TOPIC, 'data-minutes', '70') && await rowAttr(p, TOPIC, 'data-delta', '0'), await rowOf(p, TOPIC))
  await closeDay(p)

  /* T013 common case: the day's line -> [Approve N days] in the banner = 2 clicks */
  await openDay(p, lastMon)
  const n = await p.$eval(`${DLG} [data-test=hours-day-banner]`, (el) => Number(el.getAttribute('data-open'))).catch(() => -1)
  const week = await p.$eval(`${DLG} [data-test=hours-approve-week]`, (el) => ({ open: Number(el.getAttribute('data-open')), text: el.textContent.trim(), disabled: el.disabled })).catch(() => null)
  ok('T013: the banner counts 5 open days, Approve week shows its open count', n === 5 && week?.open >= 5 && week.text.includes(`${week.open} open`) && !week.disabled, { n, week })
  await p.click(`${DLG} [data-test=hours-approve-open]`)
  await p.waitForFunction((s) => document.querySelector(`${s} [data-test=hours-day-banner]`)?.getAttribute('data-open') === '0', { timeout: 8000 }, DLG).catch(() => {})
  const states = await p.$$eval(`${DLG} [data-test=hours-day-row]`, (els) => els.map((e) => e.getAttribute('data-row-state')))
  ok('T013: 2 clicks from the calendar approve every closed day', states.length === 3 && states.every((s) => s === 'approved'), states)
  await p.waitForFunction((d) => [...document.querySelectorAll('[data-test=calendar-hours-line]')].filter((l) => l.getAttribute('data-day') >= d).every((l) => l.getAttribute('data-state') === ''), { timeout: 8000 }, lastMon).catch(() => {})
  const marks = await p.$$eval('[data-test=calendar-hours-line]', (els) => els.map((e) => e.getAttribute('data-state')))
  ok('T013: the lines lose their open mark (the calendar re-read)', marks.length === 5 && marks.every((s) => s === ''), marks)

  /* ✕ reject, the day's total drops, Undo puts it back */
  const total0 = await p.$eval(`${DLG} [data-test=hours-day-total] strong`, (el) => el.textContent.trim())
  await p.click(`${DLG} [data-test=hours-day-row][data-target="${TOPIC}"] [data-test=hours-row-reject]`)
  ok('T013: ✕ rejects the row (counts 0)', await rowAttr(p, TOPIC, 'data-row-state', 'rejected'))
  const total1 = await p.$eval(`${DLG} [data-test=hours-day-total] strong`, (el) => el.textContent.trim())
  ok('T013: the total drops by the row', total0 === '3:05' && total1 === '1:15', { total0, total1 })
  ok('T013: Undo is offered', Boolean(await p.$(`${DLG} [data-test=hours-undo]`)))
  await p.click(`${DLG} [data-test=hours-undo-btn]`)
  ok('T013: Undo brings the row back', await rowAttr(p, TOPIC, 'data-row-state', 'approved'))

  /* T014: the stepper in place, +15, typed minutes, the 1440 refusal */
  await p.click(`${DLG} [data-test=hours-day-row][data-target="${TOPIC}"] [data-test=hours-row-min]`)
  await p.click(`${DLG} [data-test=hours-stepper-plus]`)
  ok('T014: the stepper steps by 15', (await p.$eval(`${DLG} [data-test=hours-stepper-input]`, (el) => el.value)) === '2:05')
  await p.click(`${DLG} [data-test=hours-stepper-save]`)
  ok('T014: Save writes 2:05', await rowAttr(p, TOPIC, 'data-minutes', '125'))
  await p.click(`${DLG} [data-test=hours-day-row][data-target="cal:mock-weekly-sync"] [data-test=hours-row-plus]`)
  ok('T014: +15 extends a row', await rowAttr(p, 'cal:mock-weekly-sync', 'data-minutes', '75'))
  await p.click(`${DLG} [data-test=hours-day-row][data-target="${TOPIC}"] [data-test=hours-row-min]`)
  await p.$eval(`${DLG} [data-test=hours-stepper-input]`, (el) => { el.value = '' })
  await p.type(`${DLG} [data-test=hours-stepper-input]`, '24:00')
  await p.click(`${DLG} [data-test=hours-stepper-save]`)
  const capErr = await p.waitForSelector(`${DLG} [data-test=hours-day-error]`, { visible: true, timeout: 8000 }).then((el) => el.evaluate((e) => e.textContent.trim())).catch(() => '')
  ok('T014: the 1440-minute refusal is shown in words', capErr.includes('1440'), capErr)
  ok('T014: nothing changed', (await rowOf(p, TOPIC))?.minutes === 125)

  /* T014 (R10): a note per discussion line, kept */
  await p.click(`${DLG} [data-test=hours-day-row][data-target="${TOPIC}"] [data-test=hours-row-note-edit]`).catch(() => {})
  await p.type(`${DLG} [data-test=hours-note-input]`, 'spec review with the owner')
  await p.click(`${DLG} [data-test=hours-note-save]`)
  await p.waitForFunction((s, tg) => document.querySelector(`${s} [data-test=hours-day-row][data-target="${tg}"] [data-test=hours-day-note]`), { timeout: 8000 }, DLG, TOPIC).catch(() => {})
  ok('T014 (R10): the note shows on its discussion line', (await rowOf(p, TOPIC))?.note === 'spec review with the owner', await rowOf(p, TOPIC))

  /* T014: why = the row's blocks */
  await p.click(`${DLG} [data-test=hours-day-row][data-target="${TOPIC}"] [data-test=hours-row-why]`)
  const why = await p.$eval(`${DLG} [data-test=hours-row-why-sheet]`, (el) => el.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
  ok('T014: Why shows the blocks the time was counted from', why.includes('09:00-10:50'), why)

  /* T014: + Add, a target from the picker, 0:30 + 15 */
  await p.click(`${DLG} [data-test=hours-add]`)
  const pick = await p.waitForSelector(`${DLG} [data-test=hours-picker-row]`, { visible: true, timeout: 10000 }).catch(() => null)
  ok('T014: + Add opens the target picker', Boolean(pick))
  let target = ''
  if (pick) {
    /* the list re-renders once topics and issues load: click by selector */
    await new Promise((r) => setTimeout(r, 600))
    /* centred: at the scroller's bottom edge the sticky Approve week covers it */
    target = await p.$eval(`${DLG} [data-test=hours-picker-row]`, (el) => { el.scrollIntoView({ block: 'center' }); return el.getAttribute('data-target') })
    await p.click(`${DLG} [data-test=hours-picker-row][data-target="${target}"]`)
    await p.waitForSelector(`${DLG} [data-test=hours-add-plus]`, { visible: true, timeout: 5000 }).catch(() => null)
    await p.click(`${DLG} [data-test=hours-add-plus]`)
    ok('T014: the new row starts at 0:30, +15 = 0:45', (await p.$eval(`${DLG} [data-test=hours-add-minutes]`, (el) => el.textContent.trim()).catch(() => '')) === '0:45')
    const had = (await rowOf(p, target))?.minutes || 0
    await p.click(`${DLG} [data-test=hours-add-save]`)
    ok('T014: + Add books it on the day', await rowAttr(p, target, 'data-minutes', String(had + 45)), { target, had, now: await rowOf(p, target) })
  }
  ok('T014: no sideways scroll in the dialog', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  await shot(p, 'hours-mine-dialog')
  await closeDay(p)

  /* the writes are kept: a reload reads the note back */
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await openDay(p, lastMon)
  ok('T014: after a reload the note and minutes read back', (await rowOf(p, TOPIC))?.note === 'spec review with the owner' && (await rowOf(p, TOPIC))?.minutes === 125)
  await closeDay(p)

  /* T013: a returned period's note and Resubmit in the panel; then frozen, locked */
  await p.evaluate((d) => localStorage.setItem('spool.mock.hours-periods', JSON.stringify({ [d]: { state: 'returned', note: 'Tuesday looks short' } })), lastMon)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const ret = await p.waitForSelector('[data-test=hours-panel] [data-test=hours-panel-returned]', { visible: true, timeout: 10000 }).then((el) => el.evaluate((e) => e.textContent.trim())).catch(() => '')
  ok('T013: the panel shows the returned note with Resubmit', ret.includes('Tuesday looks short') && Boolean(await p.$('[data-test=hours-panel-resubmit]')), ret)
  await p.click('[data-test=hours-panel-resubmit]').catch(() => {})
  await p.waitForFunction((d) => document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)?.getAttribute('data-state') === 'frozen', { timeout: 8000 }, lastMon).catch(() => {})
  ok('T013: Resubmit freezes the period (a lock on the line)', (await p.$eval(`[data-test=calendar-hours-line][data-day="${lastMon}"]`, (el) => el.getAttribute('data-state')).catch(() => '')) === 'frozen')
  await openDay(p, lastMon)
  const locked = await p.evaluate((s) => ({
    lock: Boolean(document.querySelector(`${s} [data-test=hours-day-frozen]`)),
    buttons: document.querySelectorAll(`${s} [data-test=hours-row-min], ${s} [data-test=hours-row-reject], ${s} [data-test=hours-add], ${s} [data-test=hours-approve-week]`).length,
  }), DLG)
  ok('T013: a frozen day carries a lock and no buttons', locked.lock && locked.buttons === 0, locked)
  await closeDay(p)

  /* T013: this week's Approve week (panel) approves the closed days and leaves today open */
  await p.goto(`${base}/calendar?d=${today}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const pw = await p.waitForSelector('[data-test=hours-panel] [data-test=hours-panel-approve-week]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('T013: the panel carries Approve week', Boolean(pw))
  const wd = new Date(`${today}T00:00:00Z`).getUTCDay()
  if (pw && wd >= 2 && wd <= 5) {
    await pw.click()
    await p.waitForFunction(() => document.querySelector('[data-test=hours-panel-approve-week]')?.getAttribute('data-open') === '0', { timeout: 8000 }).catch(() => {})
    const todayLine = await p.$eval(`[data-test=calendar-hours-line][data-day="${today}"]`, (el) => el.getAttribute('data-state')).catch(() => '')
    ok('T013: Approve week leaves today open (Approve so far is its own tap)', todayLine === 'open', todayLine)
  } else if (pw) {
    ok('T013: on a Monday or a weekend Approve week has no closed day to approve', await pw.evaluate((el) => el.disabled || el.getAttribute('data-open') !== '0'))
  }
  await ctx.close()
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

    /* spec 107 v1.2 T011 (owner R8..R11): a Working hours line on every
       working day of the week, Monday's total from the mock's
       GET /v1/me/hours (3:05), a click opens the event dialog of type
       Working hours with the day's discussions as links, and the right
       side's hours panel lists the period. CONTROL: before T011 there is
       no [data-test=calendar-hours-line] and no hours panel. */
    const mon = calWeekStart(today)
    await p.waitForFunction((d) => document.querySelector(`[data-test=calendar-hours-line][data-day="${d}"]`)?.getAttribute('data-total') === '185', { timeout: 10000 }, mon).catch(() => {})
    const lines = await p.$$eval('[data-test=calendar-hours-line]', (els) => els.map((e) => ({ day: e.getAttribute('data-day'), total: e.getAttribute('data-total'), text: e.textContent.replace(/\s+/g, ' ').trim() })))
    ok('T011: a Working hours line on Monday..Friday, none on the empty weekend', lines.length === 5 && lines.every((l) => [1, 2, 3, 4, 5].includes(new Date(l.day + 'T00:00:00Z').getUTCDay())), lines.map((l) => l.day))
    const monLine = lines.find((l) => l.day === mon)
    ok('T011: Monday\'s line carries the day\'s total 3:05', Boolean(monLine && monLine.total === '185' && monLine.text.includes('Working hours') && monLine.text.includes('3:05')), monLine)
    await p.click(`[data-test=calendar-hours-line][data-day="${mon}"]`)
    const dlg = await p.waitForSelector('[data-test=calendar-event-form][data-mode=hours] [data-test=hours-day-row]', { visible: true, timeout: 10000 }).catch(() => null)
    ok('T011: a click opens the event dialog of type Working hours', Boolean(dlg))
    const day = await p.evaluate(() => {
      const f = document.querySelector('[data-test=calendar-event-form][data-mode=hours]')
      return {
        type: f?.getAttribute('data-type') || '',
        day: f?.getAttribute('data-day') || '',
        label: f?.querySelector('[data-test=calendar-event-type]')?.textContent?.trim() || '',
        rows: [...(f?.querySelectorAll('[data-test=hours-day-row]') || [])].map((r) => r.getAttribute('data-kind')),
        link: f?.querySelector('[data-test=hours-day-link]')?.getAttribute('href') || '',
        total: f?.querySelector('[data-test=hours-day-total] strong')?.textContent?.trim() || '',
        save: Boolean(document.querySelector('[data-test=calendar-event-save]')),
      }
    })
    ok('T011: the dialog is the Working hours entry of that day', day.type === 'working_hours' && day.day === mon && day.label === 'Working hours', day)
    ok('T011 (R10): the day\'s discussion first, as a link to its topic', day.rows[0] === 'topic' && day.link.endsWith('/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'), day)
    ok('T011: the day\'s rows and total (meeting, other), no event Save', day.rows.length === 3 && day.rows.includes('meeting') && day.total === '3:05' && !day.save, day)
    await shot(p, `hours-dialog-${theme}`)
    await p.click('[data-test=calendar-hours-close]')
    await p.waitForFunction(() => !document.querySelector('[data-test=calendar-event-form][data-mode=hours]'), { timeout: 5000 }).catch(() => {})
    const panel = await p.waitForSelector('[data-test=hours-panel] [data-test=hours-panel-day]', { visible: true, timeout: 10000 }).catch(() => null)
    ok('T011 (R11): the right side carries the hours panel with the period\'s days', Boolean(panel))
    const pdays = await p.$$eval('[data-test=hours-panel-day]', (els) => els.map((e) => ({ day: e.getAttribute('data-day'), total: e.getAttribute('data-total') })))
    ok('T011: the panel lists Monday with its total, newest first', pdays.some((d) => d.day === mon && d.total === '185') && pdays.every((d, i) => i === 0 || d.day < pdays[i - 1].day), pdays)
    ok('T011: Mine only for a member without hours.read', !(await p.$('[data-test=hours-panel-tab-team]')))
    await p.click(`[data-test=hours-panel-day][data-day="${mon}"]`)
    ok('T011: a day in the panel opens its Working hours dialog', Boolean(await p.waitForSelector(`[data-test=calendar-event-form][data-mode=hours][data-day="${mon}"]`, { visible: true, timeout: 10000 }).catch(() => null)))
    await p.click('[data-test=calendar-hours-close]')
    ok('T011: no sideways scroll with the panel open', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))

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

  /* spec 107 v1.2 T015 (owner R11): the hours panel's Team and Download
     tabs at 1440. A member without hours.read sees Mine only; a biz owner
     (hours.read + hours.approve) gets the grid of a frozen period, approves
     one member, returns one with a note, Approve all, and downloads CSV and
     XLSX. CONTROL: before T015 the Team tab is a placeholder, so every T015
     check FAILs. */
  for (const [who, me] of [['member', HOURS_MEMBER], ['biz owner', HOURS_BIZ_OWNER]]) {
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.evaluateOnNewDocument((m) => { try { localStorage.setItem('spool.mock.me', JSON.stringify(m)) } catch { /* private mode */ } }, me)
    await p.goto(server.base + '/calendar?d=' + hoursFrozenDay(calWeekStart(today), calAddDays), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=hours-panel] [data-test=hours-panel-mine]', { visible: true, timeout: 15000 }).catch(() => null)
    if (me === HOURS_MEMBER) {
      await new Promise((r) => setTimeout(r, 800))
      ok('T015: a member without hours.read sees no Team tab', !(await p.$('[data-test=hours-panel-tab-team]')) && !(await p.$('[data-test=hours-panel-tab-download]')))
    } else {
      await p.waitForSelector('[data-test=hours-panel-tab-team]', { visible: true, timeout: 10000 }).catch(() => null)
      await driveHoursTeam(p, '[data-test=hours-panel]', '1440', ok, { layout: 'grid', shot: (n) => shot(p, `hours-${n}`) })
      ok('T015 1440: no sideways scroll with the Team tab', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    }
    await p.close()
  }

  await mineDesktop(browser, server.base)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar: ${failed} FAILED` : `calendar: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
