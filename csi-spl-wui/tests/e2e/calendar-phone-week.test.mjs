// spec 106 T006: the phone calendar's Week (CalendarPhoneWeek.vue) on a phone.
//
// At 360x780 and 390x844 (dark, font level 3), under the viewer zones
// America/New_York and Asia/Tokyo:
//   FR-004  Week opens first, a strip of seven chips Monday first (each
//           >= 44x44, today marked aria-current=date) over the agenda; the
//           list opens at today (today's row under the strip, on screen)
//   next    "see next week" in 1 tap (>) and in 1 swipe (on the strip)
//   fold    next week, seeded with a 3-day all-day event Mon-Wed and a timed
//           event Fri: Mon, Tue, Wed and Fri are day rows, Thu folds alone,
//           Sat-Sun fold into one row "Sat-Sun: nothing planned"
//   S4-3    the all-day event lists under Mon, Tue and Wed by its UTC date in
//           both zones, as "Day 1 of 3" .. "Day 3 of 3"
//   S2-7    a tap on the Sat-Sun fold unfolds Sat and Sun in place, each with
//           a + (>= 44x44); a tap on Thu's chip unfolds Thu and scrolls the
//           list to it; a + opens the add panel
//   H7      every agenda row and chip >= 44 px tall
//   H3      nothing scrolls sideways, also at font level 5 with a
//           200-character unbroken title
//   dots    every event dot draws box-shadow: var(--cal-dot-ring)
//
// Control: before T006 the Week slot is a placeholder and there is no
// [data-test=calphone-week], so every check FAILs.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-week
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay, calWeekStart } from '../../src/utils/calendar-year.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-week-${name}.png`) })
}

const ROOT = '[data-test=calendar-phone]'
const PAGE = `${ROOT} [data-test=calphone-page][data-dir="0"]`
const WEEK = `${PAGE} [data-test=calphone-week]`
const today = calIsoDay(Date.now())
const thisMon = calWeekStart(today)
const nextMon = calAddDays(thisMon, 7)
const nd = (i) => calAddDays(nextMon, i)

/* next week's fixture: an all-day Mon-Wed (UTC dates) and Fri 10:00-11:00 */
const SEED = [
  { id: '00000000-0000-4000-8000-000000000601', title: 'Offsite', starts_at: `${nd(0)}T00:00:00Z`, ends_at: `${nd(3)}T00:00:00Z`, all_day: true, color: 'banana' },
  { id: '00000000-0000-4000-8000-000000000602', title: 'Review', starts_at: `${nd(4)}T10:00:00Z`, ends_at: `${nd(4)}T11:00:00Z`, all_day: false, color: 'peacock' },
]

/** a fresh page: the opt-in, the theme, the font level and the fixture in localStorage first */
async function open(browser, vp, { theme = 'dark', level = 3, zone = '' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  if (zone) await p.emulateTimezone(zone)
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calweek-seeded')) return
      sessionStorage.setItem('calweek-seeded', '1')
      localStorage.setItem('spool-calendar-phone', '1')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(s.seed))
    } catch { /* about:blank */ }
  }, { theme, level, seed: SEED })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForSelector(`${WEEK} [data-test=calweek-list]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await sleep(300)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const rootAttr = (p, n) => p.$eval(ROOT, (el, a) => el.getAttribute(a), n).catch(() => '')
const waitWeek = (p, mon) => p.waitForFunction((s, m) => document.querySelector(`${s} [data-test=calweek-list]`) && document.querySelector(s)?.getAttribute('data-period') === m, { timeout: 8000 }, WEEK, mon).then(() => true, () => false)

/* the list as rows: kind, day, to, text, height, and the spans under a day */
const readRows = (p) => p.$$eval(`${WEEK} [data-test=calweek-list] > li`, (els) => els.map((el) => ({
  kind: (el.getAttribute('data-test') || '').replace('calweek-', ''),
  day: el.getAttribute('data-day'),
  to: el.getAttribute('data-to') || '',
  text: el.textContent.replace(/\s+/g, ' ').trim(),
  spans: [...el.querySelectorAll('[data-test=calweek-span]')].map((s) => s.textContent.trim()),
  titles: [...el.querySelectorAll('[data-test=calweek-event]')].map((b) => b.textContent.replace(/\s+/g, ' ').trim()),
}))).catch(() => [])

/* every tap target in the week: chips, folds, events, + */
const targets = (p) => p.$$eval(`${WEEK} button`, (els) => els.filter((el) => el.offsetParent !== null).map((el) => {
  const b = el.getBoundingClientRect()
  return { id: el.getAttribute('data-test') || el.className, w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }
})).catch(() => [])
const small = (list) => list.filter((b) => b.w < 44 || b.h < 44)

async function sideways(p) {
  return p.evaluate((r) => {
    const root = document.querySelector(r)
    const wide = []
    for (const el of root ? root.querySelectorAll('*') : []) {
      const ox = getComputedStyle(el).overflowX
      if ((ox === 'auto' || ox === 'scroll') && el.scrollWidth > el.clientWidth + 1) wide.push(el.className || el.tagName)
      if (el.scrollLeft !== 0) wide.push(`scrollLeft ${el.className || el.tagName}`)
    }
    return { doc: document.documentElement.scrollWidth - document.documentElement.clientWidth, wide }
  }, ROOT)
}
const flatOk = (s) => s.doc <= 1 && s.wide.length === 0

/* where a row sits: under the sticky strip and inside the scroller */
const placeOf = (p, day) => p.evaluate((s, d) => {
  const row = document.querySelector(`${s} [data-test=calweek-list] > [data-day="${d}"]`)
  const strip = document.querySelector(`${s} [data-test=calweek-strip]`)
  const sc = row?.closest('.calphone__scroll')
  if (!row || !strip || !sc) return null
  const r = row.getBoundingClientRect()
  return { top: Math.round(r.top), stripBottom: Math.round(strip.getBoundingClientRect().bottom), scBottom: Math.round(sc.getBoundingClientRect().bottom), scrollTop: sc.scrollTop, max: sc.scrollHeight - sc.clientHeight }
}, WEEK, day)
const onScreen = (pl) => Boolean(pl) && pl.top >= pl.stripBottom - 2 && pl.top < pl.scBottom - 20

async function swipe(p, from, to, steps = 10) {
  const cdp = await p.createCDPSession()
  const pt = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(from.x, from.y) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(400)
}

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }]
const ZONES = ['America/New_York', 'Asia/Tokyo']

try {
  for (const vp of PHONES) {
    for (const zone of ZONES) {
      const w = `${vp.width} ${zone}`
      const { p, ctx } = await open(browser, vp, { zone })

      /* FR-004: Week first, the strip, opened at today */
      const chips = await p.$$eval(`${WEEK} [data-test=calweek-chip]`, (els) => els.map((el) => ({ day: el.getAttribute('data-day'), cur: el.getAttribute('aria-current') || '', label: el.getAttribute('aria-label') || '' }))).catch(() => [])
      const want = Array.from({ length: 7 }, (_, i) => calAddDays(thisMon, i))
      ok(`FR-004 ${w}: Week opens first`, (await rootAttr(p, 'data-view')) === 'week', await rootAttr(p, 'data-view'))
      ok(`FR-004 ${w}: seven chips, Monday first, today aria-current=date`, chips.map((c) => c.day).join() === want.join() && chips.filter((c) => c.cur === 'date').map((c) => c.day).join() === today, chips)
      const todayAt = await placeOf(p, today)
      ok(`FR-004 ${w}: the list opens at today (its row under the strip, on screen)`, onScreen(todayAt) || (todayAt?.scrollTop === todayAt?.max && todayAt?.top < todayAt?.scBottom), todayAt)
      const dots = await p.$$eval(`${WEEK} .calweek__dot, ${WEEK} .calweek__chip--busy .calweek__chip-mark`, (els) => els.map((el) => getComputedStyle(el).boxShadow))
      const ring = await p.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--cal-dot-ring').trim())
      ok(`dots ${w}: every event dot carries --cal-dot-ring`, dots.length > 0 && dots.every((s) => (ring === '' || ring === 'none' ? s === 'none' : s !== 'none')), { n: dots.length, ring })
      if (zone === ZONES[0]) await shot(p, `${vp.width}-today`)

      /* next week in 1 tap */
      await p.click(`${ROOT} [data-test=calphone-next]`)
      ok(`next ${w}: > shows next week in 1 tap`, await waitWeek(p, nextMon), await rootAttr(p, 'data-period'))
      await sleep(200)

      /* the folds and S4-3 */
      const rows = await readRows(p)
      const shape = rows.map((r) => (r.kind === 'fold' ? `fold:${r.day}..${r.to}` : `${r.kind}:${r.day}`))
      const wantShape = [`day:${nd(0)}`, `day:${nd(1)}`, `day:${nd(2)}`, `fold:${nd(3)}..${nd(3)}`, `day:${nd(4)}`, `fold:${nd(5)}..${nd(6)}`]
      ok(`fold ${w}: Mon-Wed and Fri are days, Thu folds alone, Sat-Sun fold together`, shape.join() === wantShape.join(), shape)
      const satSun = rows.find((r) => r.kind === 'fold' && r.day === nd(5))
      ok(`fold ${w}: the folded row reads "Sat-Sun: nothing planned"`, satSun?.text === 'Sat-Sun: nothing planned', satSun?.text)
      const offsite = [0, 1, 2].map((i) => rows.find((r) => r.day === nd(i))?.spans.join('|'))
      ok(`S4-3 ${w}: the all-day Mon-Wed lists under each day as Day 1..3 of 3`, offsite.join() === 'Day 1 of 3,Day 2 of 3,Day 3 of 3', offsite)
      const fri = rows.find((r) => r.day === nd(4))?.titles || []
      ok(`S4-3 ${w}: the timed Fri event shows its wall time in the viewer's zone`, fri.length === 1 && /Review/.test(fri[0]) && /\d\d:\d\d-\d\d:\d\d/.test(fri[0]), fri)
      ok(`H7 ${w}: every chip, row and button in Week >= 44x44`, small(await targets(p)).length === 0, small(await targets(p)))

      /* S2-7: a folded day's chip unfolds and scrolls to it */
      await p.click(`${WEEK} [data-test=calweek-chip][data-day="${nd(3)}"]`)
      await sleep(250)
      const thu = (await readRows(p)).find((r) => r.day === nd(3))
      const thuAt = await placeOf(p, nd(3))
      ok(`S2-7 ${w}: Thu's chip unfolds Thu into an empty row with a +`, thu?.kind === 'empty' && Boolean(await p.$(`${WEEK} [data-test=calweek-add][data-day="${nd(3)}"]`)), thu)
      ok(`S2-7 ${w}: and scrolls the list to it`, onScreen(thuAt), thuAt)

      /* S2-7: a tap on the fold unfolds it in place */
      await p.click(`${WEEK} [data-test=calweek-fold][data-day="${nd(5)}"] button`)
      await sleep(200)
      const after = (await readRows(p)).map((r) => `${r.kind}:${r.day}`)
      ok(`S2-7 ${w}: the Sat-Sun fold unfolds into two empty rows`, after.slice(-2).join() === `empty:${nd(5)},empty:${nd(6)}` && !after.some((r) => r.startsWith('fold')), after)
      const plus = small(await targets(p))
      ok(`H7 ${w}: the unfolded + buttons are >= 44x44`, plus.length === 0, plus)
      await shot(p, `${vp.width}-${zone.split('/')[1]}-unfolded`)
      await p.click(`${WEEK} [data-test=calweek-add][data-day="${nd(6)}"]`)
      const panel = await p.waitForSelector(`${ROOT} [data-test=calphone-panel][data-panel=add]`, { timeout: 3000 }).then(() => true, () => false)
      ok(`S2-7 ${w}: a + on an empty day opens the add panel`, panel)

      /* next week in 1 swipe, on the strip */
      await p.click(`${ROOT} [data-test=calphone-today]`)
      await waitWeek(p, thisMon)
      const strip = await p.$eval(`${WEEK} [data-test=calweek-strip]`, (el) => { const b = el.getBoundingClientRect(); return { x: b.left, w: b.width, y: b.top + b.height / 2 } })
      await swipe(p, { x: strip.x + strip.w * 0.8, y: strip.y }, { x: strip.x + strip.w * 0.2, y: strip.y + 4 })
      ok(`next ${w}: one swipe on the strip shows next week`, await waitWeek(p, nextMon), await rootAttr(p, 'data-period'))
      ok(`H3 ${w}: nothing scrolls sideways`, flatOk(await sideways(p)), await sideways(p))
      await ctx.close()
    }

    /* H3 at font level 5 with a 200-character unbroken title */
    {
      const { p, ctx } = await open(browser, vp, { level: 5 })
      await p.click(`${ROOT} [data-test=calphone-next]`)
      await waitWeek(p, nextMon)
      await p.evaluate((s, t) => { const el = document.querySelector(`${s} .calweek__title`); if (el) el.textContent = t }, WEEK, 'x'.repeat(200))
      ok(`H3 ${vp.width} level 5: a 200-character title widens nothing`, flatOk(await sideways(p)), await sideways(p))
      ok(`H7 ${vp.width} level 5: chips and rows stay >= 44x44`, small(await targets(p)).length === 0, small(await targets(p)))
      await shot(p, `${vp.width}-level5`)
      await ctx.close()
    }

    /* light theme: the same Week, for the eye */
    {
      const { p, ctx } = await open(browser, vp, { theme: 'light' })
      await p.click(`${ROOT} [data-test=calphone-next]`)
      await waitWeek(p, nextMon)
      ok(`light ${vp.width}: Week renders`, (await readRows(p)).length > 0)
      await shot(p, `${vp.width}-light`)
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-week: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
