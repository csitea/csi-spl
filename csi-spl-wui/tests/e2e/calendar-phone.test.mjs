// spec 089 T009 (AC-08) tested the Calendar's first phone layout here: the
// year strip as a sheet behind a header button, the main view's Day view
// and its Week list. spec 106 T011 retired that layout; a phone (<= 820 px)
// now gets CalendarPhone for everyone, tested by:
//   calendar-phone-shell.test.mjs  the shell, H1..H8, FR-011 (1440 unchanged),
//                                  and a fresh browser at 390 gets it (T011)
//   calendar-phone-month.test.mjs  Month (T005)
//   calendar-phone-week.test.mjs   Week (T006)
//   calendar-phone-day.test.mjs    Day, hold-drag (T007)
//   calendar-phone-sheet.test.mjs  the add / edit sheet (T008)
//   calendar-phone-peek.test.mjs   peek, delete, Undo (T009)
//   calendar-phone-jump.test.mjs   month picker, search (T010)
//
// This file now holds spec 107 v1.2 T011 on a phone (owner R8..R11, t1
// a28dc5c9): at 360x780 and 390x844, dark and light, font levels 1, 3, 5:
//   line    Day on this week's Monday shows one Working hours line with the
//           mock's GET /v1/me/hours total (3:05); a weekend day without
//           hours shows none
//   sheet   a tap opens the phone's entry sheet of type Working hours: the
//           day's discussion first as a link to its topic, the meeting and
//           "other", the total, no event Save
//   panel   the header menu's Hours opens the hours tabs as a sheet, Monday
//           listed with its total
//   phone   nothing scrolls sideways; the line, the menu item and the panel's
//           days are >= 44 px tall
// Control: before T011 there is no [data-test=calendar-hours-line] and the
// menu holds nothing, so every check FAILs.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay, calWeekStart } from '../../src/utils/calendar-year.mjs'
import { HOURS_BIZ_OWNER, HOURS_MEMBER, driveHoursTeam, hoursFrozenDay } from './lib/hours-team.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-hours-${name}.png`) })
}

const ROOT = '[data-test=calendar-phone]'
const PAGE = `${ROOT} [data-test=calphone-page][data-dir="0"]`
const today = calIsoDay(Date.now())
const mon = calWeekStart(today)
const sat = calAddDays(mon, 5)

async function open(browser, vp, { theme, level, day, me }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
      localStorage.setItem('spool-calendar-phone-view', 'day')
      if (s.me) localStorage.setItem('spool.mock.me', JSON.stringify(s.me))
    } catch { /* about:blank */ }
  }, { theme, level, me: me || null })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar?d=' + day, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForSelector(`${PAGE} [data-test=calphone-day][data-day="${day}"]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await sleep(300)
  return { p, ctx }
}

const lineOf = (p, day) => p.$eval(`${PAGE} [data-test=calendar-hours-line][data-day="${day}"]`, (el) => {
  const b = el.getBoundingClientRect()
  return { total: el.getAttribute('data-total'), text: el.textContent.replace(/\s+/g, ' ').trim(), h: Math.round(b.height) }
}).catch(() => null)
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1 && document.scrollingElement.scrollLeft === 0)

const server = await startServer()
const browser = await launch()
const RUNS = [
  { vp: { width: 390, height: 844 }, theme: 'dark', level: 3 },
  { vp: { width: 390, height: 844 }, theme: 'light', level: 5 },
  { vp: { width: 360, height: 780 }, theme: 'dark', level: 1 },
  { vp: { width: 360, height: 780 }, theme: 'light', level: 5 },
]

try {
  for (const run of RUNS) {
    const w = `${run.vp.width} ${run.theme} L${run.level}`
    const { p, ctx } = await open(browser, run.vp, { ...run, day: mon })

    /* line: Monday's Working hours line with the day's total */
    await p.waitForFunction((s, d) => document.querySelector(`${s} [data-test=calendar-hours-line][data-day="${d}"]`)?.getAttribute('data-total') === '185', { timeout: 10000 }, PAGE, mon).catch(() => {})
    const line = await lineOf(p, mon)
    ok(`line ${w}: Monday shows Working hours 3:05`, Boolean(line && line.total === '185' && line.text.includes('Working hours') && line.text.includes('3:05')), line)
    ok(`phone ${w}: the line is >= 44 px tall`, Boolean(line && line.h >= 44), line?.h)
    ok(`phone ${w}: no sideways scroll`, await sideways(p))
    await shot(p, `${run.vp.width}-${run.theme}-L${run.level}-day`)

    /* sheet: the entry of type Working hours */
    await p.tap(`${PAGE} [data-test=calendar-hours-line][data-day="${mon}"]`).catch(() => p.click(`${PAGE} [data-test=calendar-hours-line][data-day="${mon}"]`))
    const body = await p.waitForSelector('[data-test=calphone-sheet][data-mode=hours] [data-test=hours-day-row]', { visible: true, timeout: 10000 }).catch(() => null)
    ok(`sheet ${w}: a tap opens the entry sheet of type Working hours`, Boolean(body))
    const sheet = await p.evaluate(() => {
      const s = document.querySelector('[data-test=calphone-sheet][data-mode=hours]')
      return {
        type: s?.querySelector('[data-test=calphone-sheet-body]')?.getAttribute('data-type') || '',
        rows: [...(s?.querySelectorAll('[data-test=hours-day-row]') || [])].map((r) => r.getAttribute('data-kind')),
        link: s?.querySelector('[data-test=hours-day-link]')?.getAttribute('href') || '',
        total: s?.querySelector('[data-test=hours-day-total] strong')?.textContent?.trim() || '',
        save: Boolean(s?.querySelector('[data-test=calphone-sheet-save]')),
        short: [...(s?.querySelectorAll('[data-test=hours-day-row]') || [])].filter((r) => r.getBoundingClientRect().height < 44).length,
      }
    })
    ok(`sheet ${w}: the discussion first as a link, then meeting and other; total 3:05; no Save`, sheet.type === 'working_hours' && sheet.rows.join() === 'topic,meeting,other' && sheet.link.endsWith('/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') && sheet.total === '3:05' && !sheet.save, sheet)
    ok(`phone ${w}: every row in the sheet is >= 44 px tall`, sheet.short === 0, sheet.short)
    ok(`phone ${w}: no sideways scroll with the sheet open`, await sideways(p))
    await shot(p, `${run.vp.width}-${run.theme}-L${run.level}-sheet`)
    await p.click('[data-test=calphone-sheet-cancel]')
    await p.waitForFunction(() => !document.querySelector('[data-test=calphone-sheet]'), { timeout: 5000 }).catch(() => {})

    /* panel: the menu's Hours, the hours tabs as a sheet */
    await p.click(`${ROOT} [data-test=calphone-menu]`)
    const item = await p.waitForSelector('[data-test=calphone-menu-hours]', { visible: true, timeout: 5000 }).catch(() => null)
    const itemH = item ? await item.evaluate((el) => Math.round(el.getBoundingClientRect().height)) : 0
    ok(`panel ${w}: the calendar menu offers Hours (>= 44 px)`, Boolean(item) && itemH >= 44, itemH)
    if (item) await item.click()
    await p.waitForSelector('[data-test=calphone-hours-sheet] [data-test=hours-panel-day]', { visible: true, timeout: 10000 }).catch(() => null)
    const pdays = await p.$$eval('[data-test=calphone-hours-sheet] [data-test=hours-panel-day]', (els) => els.map((e) => ({ day: e.getAttribute('data-day'), total: e.getAttribute('data-total'), h: Math.round(e.getBoundingClientRect().height) })))
    ok(`panel ${w}: the hours sheet lists Monday with its total`, pdays.some((d) => d.day === mon && d.total === '185'), pdays)
    ok(`phone ${w}: the panel's days are >= 44 px tall`, pdays.length > 0 && pdays.every((d) => d.h >= 44), pdays.map((d) => d.h))
    ok(`phone ${w}: no sideways scroll with the hours sheet`, await sideways(p))
    await shot(p, `${run.vp.width}-${run.theme}-L${run.level}-panel`)
    await ctx.close()
  }

  /* a weekend day without hours shows no line (CONTROL for "every working day") */
  const { p, ctx } = await open(browser, RUNS[0].vp, { ...RUNS[0], day: sat })
  await sleep(800)
  ok('line: a weekend day without hours shows no Working hours line', (await lineOf(p, sat)) === null && Boolean(await p.$(`${PAGE} [data-test=calphone-day][data-day="${sat}"]`)))
  await ctx.close()

  /* spec 107 v1.2 T015 (owner R11) at 390: the hours sheet's Team and
     Download tabs. A member without hours.read sees Mine only; a biz owner
     gets one card per member of a frozen period, approves, returns with a
     note, Approve all, downloads CSV and XLSX; nothing scrolls sideways.
     CONTROL: before T015 the Team tab is a placeholder, so every T015 check FAILs. */
  const frozen = hoursFrozenDay(mon, calAddDays)
  for (const [who, me] of [['member', HOURS_MEMBER], ['biz owner', HOURS_BIZ_OWNER]]) {
    const run = RUNS[1]
    const o = await open(browser, run.vp, { ...run, day: frozen, me })
    await o.p.click(`${ROOT} [data-test=calphone-menu]`)
    const item = await o.p.waitForSelector('[data-test=calphone-menu-hours]', { visible: true, timeout: 5000 }).catch(() => null)
    if (item) await item.click()
    await o.p.waitForSelector('[data-test=calphone-hours-sheet] [data-test=hours-panel-mine]', { visible: true, timeout: 10000 }).catch(() => null)
    if (who === 'member') {
      await sleep(800)
      ok('T015 390: a member without hours.read sees no Team tab', !(await o.p.$('[data-test=calphone-hours-sheet] [data-test=hours-panel-tab-team]')))
    } else {
      await o.p.waitForSelector('[data-test=calphone-hours-sheet] [data-test=hours-panel-tab-team]', { visible: true, timeout: 10000 }).catch(() => null)
      await driveHoursTeam(o.p, '[data-test=calphone-hours-sheet]', '390', ok, { layout: 'cards', shot: (n) => shot(o.p, `390-team-${n}`) })
      ok('T015 390: no sideways scroll with the Team and Download tabs', await sideways(o.p))
    }
    await o.ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-phone: ${failed} FAILED` : `calendar-phone: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
