// spec 106 T007: the phone calendar's Day view (CalendarPhoneDay.vue) in the
// T004 shell, on a phone.
//
// At 360x780, 390x844 and 820x1180, dark and light, font levels 1, 3 and 5:
//   FR-005  Day renders with no week strip; one 48 px row per hour (24 on
//           an ordinary day); the now line on today, scrolled into view
//   H3      no sideways scroll (scrollWidth, overflow-x scrollers, scrollLeft)
//   H7      header and bar controls >= 44x44 (<= 48 px tall at level 3);
//           hour rows and all-day chips >= 44 tall; event blocks >= 44 wide
//   H8      the view >= 82 % of the page (level 3); the visible Day grid
//           >= 520 px (>= 10.5 hours) at 390x844 and 820x1180
// Once per width (level 3, dark, zone UTC):
//   AC-04   a tap on empty 14:00 opens T008's add sheet on that hour
//           (data-at = 14:00 of that day, chips 14:00 - 15:00); Save
//           stores 14:00-15:00 and the grid shows it
//   S2-2    a diagonal drag (30 px x, 80 px y) adds nothing and turns no
//           page; a still finger held 500 ms on empty time adds nothing
//   097     a finger held on an event lifts it; dragged 2 hours down it is
//           stored 2 hours later, same day, and the period stays; one
//           tap on it opens T009's peek
//   S4-4    a fixture day: 5 events overlap at 14:00 -> at most 3 columns,
//           a +3 chip whose list holds the rest; every event reachable; a
//           15-minute event is >= 26 px and < 44 px tall, >= 44 px wide
//   S4-3    3 all-day events: two lines (1 chip + "+2"), +2 expands to 3;
//           an all-day event keeps its UTC date in America/New_York and
//           Asia/Tokyo; a 22:00-02:00 event is marked as continuing
// S4-6: in Europe/Helsinki 2026-10-25 has 25 rows, 03:00 twice; a tap on
// the second 03:00 opens the add sheet at 2026-10-25T01:00:00Z.
//
// Controls: before T007 there is no [data-test=calphone-day], so every check
// FAILs; in-run, a planted 30 px wide event trips the H7 width check.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-day
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay } from '../../src/utils/calendar-year.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-day-${name}.png`) })
}

const today = calIsoDay(Date.now())
const ROOT = '[data-test=calendar-phone]'
const DAY = `${ROOT} [data-test=calphone-page][data-dir="0"] [data-test=calphone-day]`
const ADDED_KEY = 'spool.mock.calendar-added'
const SHEET_TITLE = '[data-test=calphone-sheet] [data-test=calphone-sheet-title]'

/** a fresh page on Day: the opt-in, theme, level, zone and fixture events first */
async function open(browser, vp, { theme = 'dark', level = 3, zone = 'UTC', day = '', added = [] } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.emulateTimezone(zone)
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calday-seeded')) return
      sessionStorage.setItem('calday-seeded', '1')
      localStorage.setItem('spool-calendar-phone', '1')
      localStorage.setItem('spool-calendar-phone-view', 'day')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
      if (s.added.length) localStorage.setItem(s.key, JSON.stringify(s.added))
    } catch { /* about:blank */ }
  }, { theme, level, added, key: ADDED_KEY })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar' + (day ? `?d=${day}` : ''), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForSelector(DAY, { visible: true, timeout: 15000 }).catch(() => null)
  await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 10000 }, ROOT).catch(() => {})
  await sleep(300)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const rootAttr = (p, n) => p.$eval(ROOT, (el, a) => el.getAttribute(a), n).catch(() => '')
const panelAt = (p) => p.$eval(`${ROOT} [data-test=calphone-panel]`, (el) => ({ panel: el.getAttribute('data-panel'), at: el.getAttribute('data-at') })).catch(() => ({ panel: '', at: '' }))
/* the panel is T008..T010's to close; until they land a reload resets it (localStorage stays) */
async function closePanel(p) {
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(DAY, { visible: true, timeout: 15000 }).catch(() => null)
  await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 10000 }, ROOT).catch(() => {})
  await sleep(300)
}

/* H3: the document and every scroller under the calendar */
async function sideways(p) {
  return p.evaluate((r) => {
    const root = document.querySelector(r)
    const wide = []
    for (const el of root ? root.querySelectorAll('*') : []) {
      const ox = getComputedStyle(el).overflowX
      if ((ox === 'auto' || ox === 'scroll') && el.scrollWidth > el.clientWidth + 1) wide.push(el.className || el.tagName)
      if (el.scrollLeft !== 0) wide.push(`scrollLeft ${el.className || el.tagName}`)
    }
    return { doc: document.documentElement.scrollWidth - document.documentElement.clientWidth, docLeft: document.scrollingElement?.scrollLeft || 0, wide }
  }, ROOT)
}
const flatOk = (s) => s.doc <= 1 && s.docLeft === 0 && s.wide.length === 0

/* what H7 / H8 and FR-005 read off the Day */
async function dayBoxes(p) {
  return p.evaluate((r, d) => {
    const box = (el) => {
      const b = el.getBoundingClientRect()
      return { x: Math.round(b.left), y: Math.round(b.top), w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }
    }
    const q = (s) => document.querySelector(s)
    const day = q(d)
    const controls = [...document.querySelectorAll(`${r} [data-test=calphone-head] button, ${r} [data-test=calphone-bar] button`)]
      .filter((el) => el.offsetParent !== null)
      .map((el) => ({ id: el.getAttribute('data-test') || el.className, ...box(el) }))
    const dock = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h')) || 0
    const pgEl = q('[data-test=calendar-page]')
    const pg = pgEl ? box(pgEl) : null
    if (pg) pg.h = Math.min(pg.y + pg.h, window.innerHeight - dock) - pg.y
    const view = q(`${r} [data-test=calphone-view]`)
    const grid = day?.querySelector('[data-test=calday-grid]')
    /* the visible grid: the part of it inside its scroller, scrolled to the grid's top */
    let visible = 0
    const sc = grid?.closest('.calphone__scroll')
    if (grid && sc) {
      const keep = sc.scrollTop
      sc.scrollTop = grid.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop
      const g = grid.getBoundingClientRect()
      const s = sc.getBoundingClientRect()
      /* the scroller's 72 px bottom padding sits after the grid's last row, not over it */
      visible = Math.min(g.bottom, s.bottom) - Math.max(g.top, s.top)
      sc.scrollTop = keep
    }
    const view0 = view ? view.querySelector('[data-test=calphone-page][data-dir="0"]') : null
    return {
      present: Boolean(day),
      hours: Number(day?.getAttribute('data-hours') || 0),
      rows: [...(day?.querySelectorAll('[data-test=calday-hour]') || [])].map((el) => box(el).h),
      strip: view0 ? view0.querySelectorAll('[data-test*=strip], [data-test*=chip-day], .calphone-week-strip').length : -1,
      events: [...(day?.querySelectorAll('[data-test=calday-event]') || [])].map((el) => ({ id: el.getAttribute('data-id'), cols: Number(el.getAttribute('data-cols')), cont: el.classList.contains('calday__ev--cont'), ...box(el) })),
      chips: [...(day?.querySelectorAll('[data-test=calday-allday-item], [data-test=calday-allday-more], [data-test=calday-more]') || [])].map((el) => ({ id: el.getAttribute('data-test'), ...box(el) })),
      controls,
      dock,
      page: pg,
      view: view ? box(view) : null,
      head: q(`${r} [data-test=calphone-head]`) ? box(q(`${r} [data-test=calphone-head]`)) : null,
      bar: q(`${r} [data-test=calphone-bar]`) ? box(q(`${r} [data-test=calphone-bar]`)) : null,
      visible: Math.round(visible),
    }
  }, ROOT, DAY)
}
const tapSize = (c) => c.w >= 43.5 && c.h >= 43.5

async function layoutChecks(p, tag, vp, lvl) {
  const s = await sideways(p)
  ok(`H3 ${tag}: no sideways scroll`, flatOk(s), s)
  const b = await dayBoxes(p)
  ok(`FR-005 ${tag}: Day renders, no week strip`, b.present && b.strip === 0, { present: b.present, strip: b.strip })
  ok(`FR-005 ${tag}: one 48 px row per hour`, b.hours >= 23 && b.rows.length === b.hours && b.rows.every((h) => Math.abs(h - 48) < 0.6), { hours: b.hours, rows: [...new Set(b.rows)] })
  const small = b.controls.filter((c) => !tapSize(c))
  ok(`H7 ${tag}: every control >= 44x44`, small.length === 0 && b.controls.length >= 8, small.length ? small : b.controls.length)
  const thin = b.events.filter((e) => e.w < 43.5)
  ok(`H7 ${tag}: every event block >= 44 px wide`, thin.length === 0, thin)
  const smallChips = b.chips.filter((c) => !tapSize(c))
  ok(`H7 ${tag}: all-day chips and +n >= 44x44`, smallChips.length === 0, smallChips)
  if (lvl === 3) {
    const tall = b.controls.filter((c) => c.h > 48.5)
    ok(`H7 ${tag}: controls <= 48 px tall at level 3`, tall.length === 0, tall)
    const share = b.page && b.view ? b.view.h / b.page.h : 0
    ok(`H8 ${tag}: the view is >= 82 % of the page`, share >= 0.82, { share: Math.round(share * 1000) / 10, view: b.view?.h, page: b.page?.h })
    if (vp.width >= 390) ok(`H8 ${tag}: the visible Day grid >= 520 px (>= 10.5 hours)`, b.visible >= 520, b.visible)
    else console.log(`  info ${tag}: visible Day grid ${b.visible} px`)
  }
  return b
}

/* a finger: down at `from`, `steps` moves to `to` (after `wait` ms still), then up */
async function touch(p, from, to, { wait = 0, steps = 8, gap = 16 } = {}) {
  const cdp = await p.createCDPSession()
  const pt = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(from.x, from.y) })
  if (wait) await sleep(wait)
  for (let i = 1; i <= steps && (to.x !== from.x || to.y !== from.y); i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps) })
    await sleep(gap)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
  await sleep(300)
}

/** the hour row labelled `label` (the `nth` one on a fall-back day), centred in its scroller; its free spot on screen */
async function hourSpot(p, label, nth = 0) {
  return p.evaluate((d, l, n) => {
    const row = [...document.querySelectorAll(`${d} [data-test=calday-hour]`)].filter((el) => el.getAttribute('data-label') === l)[n]
    if (!row) return null
    row.scrollIntoView({ block: 'center' })
    const b = row.getBoundingClientRect()
    /* the right end of the row: past the gutter, clear of events in the early columns */
    return { x: b.right - 12, y: b.top + b.height / 2, at: row.getAttribute('data-at') }
  }, DAY, label, nth)
}

const ev = (id, title, s, e, extra = {}) => ({ id, title, starts_at: s, ends_at: e, all_day: false, updated_at: '2026-01-01T00:00:00Z', ...extra })

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }, { width: 820, height: 1180 }]
const shots = process.env.SHOT_DIR
try {
  /* ---- the matrix ---- */
  for (const vp of PHONES) {
    for (const theme of ['dark', 'light']) {
      for (const lvl of [1, 3, 5]) {
        const tag = `${vp.width} ${theme} L${lvl}`
        console.log(`-- ${tag}`)
        const { p, ctx } = await open(browser, vp, { theme, level: lvl })
        ok(`${tag}: opens on Day`, (await rootAttr(p, 'data-view')) === 'day', await rootAttr(p, 'data-view'))
        await layoutChecks(p, tag, vp, lvl)
        if (lvl === 3) {
          const now = await p.evaluate((d) => {
            const line = document.querySelector(`${d} [data-test=calday-now]`)
            const sc = line?.closest('.calphone__scroll')
            if (!line || !sc) return null
            const a = line.getBoundingClientRect()
            const s = sc.getBoundingClientRect()
            return { inView: a.top >= s.top && a.top <= s.bottom }
          }, DAY)
          ok(`FR-005 ${tag}: today opens at the now line`, Boolean(now && now.inView), now)
        }
        if (vp.width === 390 && lvl === 3) await shot(p, `${vp.width}-${theme}`)
        await ctx.close()
      }
    }
  }

  /* ---- the interactions, once per width (level 3, dark) ---- */
  for (const vp of PHONES) {
    const w = vp.width
    console.log(`-- ${w}x${vp.height} interactions`)
    {
      const { p, ctx } = await open(browser, vp)
      const period = await rootAttr(p, 'data-period')

      /* AC-04: a tap on empty 14:00 */
      const spot = await hourSpot(p, '14:00')
      await touch(p, spot, spot)
      const pa = await panelAt(p)
      ok(`AC-04 ${w}: a tap on empty 14:00 opens the add sheet at 14:00`, pa.panel === 'add' && pa.at === `${today}T14:00:00Z` && spot.at === pa.at, { pa, spot })
      /* with T008's sheet: the chips read 14:00 - 15:00, Save stores it there */
      const sheetUp = await p.waitForSelector(SHEET_TITLE, { visible: true, timeout: 5000 }).then(() => true, () => false)
      const chips = await p.evaluate(() => ['date', 'start', 'end'].map((k) => document.querySelector(`[data-test=calphone-sheet] [data-test=calphone-sheet-${k}]`)?.textContent?.trim() || ''))
      ok(`AC-04 ${w}: the sheet opens on that day, 14:00 - 15:00`, sheetUp && chips.join() === `${today},14:00,15:00`, chips)
      if (sheetUp) {
        await p.type(SHEET_TITLE, `Day AC-04 ${w}`)
        await p.click('[data-test=calphone-sheet] [data-test=calphone-sheet-save]')
        await p.waitForFunction(() => !document.querySelector('[data-test=calphone-panel]'), { timeout: 5000 }).catch(() => {})
        const stored = await p.evaluate((k, t) => JSON.parse(localStorage.getItem(k) || '[]').find((x) => x.title === t) || null, ADDED_KEY, `Day AC-04 ${w}`)
        ok(`AC-04 ${w}: stored at 14:00-15:00 on that day`, Boolean(stored) && Date.parse(stored.starts_at) === Date.parse(`${today}T14:00:00Z`) && Date.parse(stored.ends_at) === Date.parse(`${today}T15:00:00Z`), stored && { s: stored.starts_at, e: stored.ends_at })
        const shown = await p.waitForFunction((d, t) => [...document.querySelectorAll(`${d} [data-test=calday-event]`)].some((el) => el.textContent.includes(t)), { timeout: 5000 }, DAY, `Day AC-04 ${w}`).then(() => true, () => false)
        ok(`AC-04 ${w}: the new event shows in the Day grid`, shown)
      }
      await closePanel(p)

      /* S2-2: a diagonal drag and a long still press add nothing */
      const s2 = await hourSpot(p, '16:00')
      await touch(p, s2, { x: s2.x - 30, y: s2.y - 80 })
      ok(`S2-2 ${w}: a diagonal drag adds nothing and turns no page`, (await panelAt(p)).panel === '' && (await rootAttr(p, 'data-period')) === period, { panel: await panelAt(p), period: await rootAttr(p, 'data-period') })
      const s3 = await hourSpot(p, '16:00')
      await touch(p, s3, s3, { wait: 500 })
      ok(`S2-2 ${w}: a finger held 500 ms on empty time adds nothing`, (await panelAt(p)).panel === '', await panelAt(p))

      /* 097: hold the 09:00 Release, drag it two hours down */
      const evBox = await p.evaluate((d) => {
        const el = document.querySelector(`${d} [data-test=calday-event][data-id="00000000-0000-4000-8000-000000000101"]`)
        if (!el) return null
        el.scrollIntoView({ block: 'start' })
        el.closest('.calphone__scroll').scrollTop -= 40
        const b = el.getBoundingClientRect()
        return { x: b.left + b.width / 2, y: b.top + 12, starts: el.getAttribute('data-starts') }
      }, DAY)
      if (evBox) {
        await touch(p, evBox, { x: evBox.x, y: evBox.y + 96 }, { wait: 550, steps: 12, gap: 20 })
        const moved = await p.waitForFunction((d) => document.querySelector(`${d} [data-test=calday-event][data-id="00000000-0000-4000-8000-000000000101"]`)?.getAttribute('data-starts')?.includes('T11:00'), { timeout: 5000 }, DAY).then(() => true, () => false)
        const stored = await p.evaluate((k) => (JSON.parse(localStorage.getItem(k) || '[]').find((x) => x.id === '00000000-0000-4000-8000-000000000101') || {}).starts_at || '', ADDED_KEY)
        ok(`097 ${w}: hold-drag moves the event two hours, same day`, moved && Date.parse(stored) === Date.parse(`${today}T11:00:00Z`), { stored, from: evBox.starts })
        ok(`097 ${w}: the drag turned no page`, (await rootAttr(p, 'data-period')) === period, await rootAttr(p, 'data-period'))
        ok(`097 ${w}: the drop opened no add sheet`, (await panelAt(p)).panel === '', await panelAt(p))
        /* with T009's peek: one tap on an event opens it */
        const tapAt = await p.evaluate((d) => {
          const el = document.querySelector(`${d} [data-test=calday-event][data-id="00000000-0000-4000-8000-000000000101"]`)
          if (!el) return null
          el.scrollIntoView({ block: 'center' })
          const b = el.getBoundingClientRect()
          return { x: b.left + b.width / 2, y: b.top + Math.min(12, b.height / 2) }
        }, DAY)
        if (tapAt) await touch(p, tapAt, tapAt)
        const peek = await p.waitForSelector('[data-test=calpeek]', { visible: true, timeout: 5000 }).then(() => true, () => false)
        ok(`${w}: one tap on an event opens its peek`, peek)
      } else {
        ok(`097 ${w}: the mock Release shows on today`, false)
      }

      /* control: a planted 30 px wide event trips the width check */
      if (w === 390) {
        await p.evaluate((d) => {
          const b = document.createElement('button')
          b.setAttribute('data-test', 'calday-event')
          b.style.cssText = 'position:absolute;top:0;left:60px;width:30px;height:30px;min-width:0'
          document.querySelector(`${d} [data-test=calday-grid]`).appendChild(b)
        }, DAY)
        const b = await dayBoxes(p)
        ok('control: a planted 30 px wide event trips the H7 width check', b.events.some((e) => e.w < 43.5))
      }
      await ctx.close()
    }

    /* S4-4 + S4-3: a full fixture day, three days ahead */
    {
      const d = calAddDays(today, 3)
      const at = (hhmm, off = 0) => `${calAddDays(d, off)}T${hhmm}:00Z`
      const added = [
        ev('f-o1', 'Overlap one', at('14:00'), at('15:00'), { color: 'banana' }),
        ev('f-o2', 'Overlap two', at('14:00'), at('15:30'), { color: 'sage' }),
        ev('f-o3', 'Overlap three', at('14:15'), at('15:00'), { color: 'flamingo' }),
        ev('f-o4', 'Overlap four', at('14:30'), at('15:15'), { color: 'peacock' }),
        ev('f-o5', 'Overlap five', at('14:45'), at('15:45')),
        ev('f-short', 'Quick call', at('10:00'), at('10:15')),
        ev('f-late', 'Late shift', at('22:00'), at('02:00', 1)),
        ev('f-a1', 'Holiday A', at('00:00'), at('00:00', 1), { all_day: true }),
        ev('f-a2', 'Holiday B', at('00:00'), at('00:00', 1), { all_day: true }),
        ev('f-a3', 'Trip', at('00:00', -1), at('00:00', 2), { all_day: true }),
      ]
      const { p, ctx } = await open(browser, vp, { day: d, added })
      const b = await dayBoxes(p)
      const ids = b.events.map((e) => e.id)
      const maxCols = Math.max(0, ...b.events.map((e) => e.cols))
      ok(`S4-4 ${w}: at most 3 overlap columns`, maxCols === 3, { maxCols, ids })
      const more = await p.$$eval(`${DAY} [data-test=calday-more]`, (els) => els.map((el) => el.textContent.trim()))
      ok(`S4-4 ${w}: the 4th and later overlap become one +3 chip`, more.length === 1 && more[0] === '+3', more)
      await p.click(`${DAY} [data-test=calday-more]`)
      const listed = await p.$$eval(`${DAY} [data-test=calday-list-item]`, (els) => els.map((el) => el.getAttribute('data-id')))
      const overlap = ['f-o1', 'f-o2', 'f-o3', 'f-o4', 'f-o5']
      ok(`S4-4 ${w}: every overlapping event is reachable (blocks + the chip's list)`, overlap.every((id) => ids.includes(id) || listed.includes(id)) && listed.length === 3, { ids, listed })
      const listRows = await p.$$eval(`${DAY} [data-test=calday-list-item]`, (els) => els.map((el) => Math.round(el.getBoundingClientRect().height)))
      ok(`H7 ${w}: the hour list's rows >= 44 px`, listRows.length > 0 && listRows.every((h) => h >= 44), listRows)
      const short = b.events.find((e) => e.id === 'f-short')
      ok(`S4-4 ${w}: a 15-minute event is >= 26 and < 44 px tall, >= 44 wide`, Boolean(short && short.h >= 25.5 && short.h < 44 && short.w >= 43.5), short)
      const late = b.events.find((e) => e.id === 'f-late')
      ok(`S4-3 ${w}: a 22:00-02:00 event is marked as continuing`, Boolean(late && late.cont), late)
      const allDay = await p.$$eval(`${DAY} [data-test=calday-allday-item]`, (els) => els.map((el) => el.getAttribute('data-id')))
      const plus = await p.$eval(`${DAY} [data-test=calday-allday-more]`, (el) => el.textContent.trim()).catch(() => '')
      ok(`S4-3 ${w}: three all-day events fill two lines: one chip and +2`, allDay.length === 1 && plus === '+2', { allDay, plus })
      await p.click(`${DAY} [data-test=calday-allday-more]`)
      const allDay2 = await p.$$eval(`${DAY} [data-test=calday-allday-item]`, (els) => els.map((el) => el.getAttribute('data-id')).sort())
      ok(`S4-3 ${w}: +2 expands the all-day row in place`, allDay2.join() === 'f-a1,f-a2,f-a3', allDay2)
      ok(`H3 ${w} fixture: no sideways scroll`, flatOk(await sideways(p)), await sideways(p))
      if (w === 390 && shots) await shot(p, '390-fixture')
      await ctx.close()
    }
  }

  /* ---- S4-3: an all-day event keeps its UTC date in any zone ---- */
  for (const zone of ['America/New_York', 'Asia/Tokyo']) {
    const d = calAddDays(today, 4)
    const added = [ev('z-a', 'Zone holiday', `${d}T00:00:00Z`, `${calAddDays(d, 1)}T00:00:00Z`, { all_day: true })]
    const { p, ctx } = await open(browser, { width: 390, height: 844 }, { zone, day: d, added })
    const on = await p.$$eval(`${DAY} [data-test=calday-allday-item]`, (els) => els.map((el) => el.getAttribute('data-id'))).catch(() => [])
    await p.click(`${ROOT} [data-test=calphone-prev]`)
    await sleep(500)
    const before = await p.$$eval(`${DAY} [data-test=calday-allday-item]`, (els) => els.map((el) => el.getAttribute('data-id'))).catch(() => [])
    ok(`S4-3 ${zone}: the all-day event sits on its UTC date, not the day before`, on.includes('z-a') && !before.includes('z-a'), { on, before })
    await ctx.close()
  }

  /* ---- S4-6: a fall-back day in Europe/Helsinki ---- */
  {
    const { p, ctx } = await open(browser, { width: 390, height: 844 }, { zone: 'Europe/Helsinki', day: '2026-10-25' })
    const rows = await p.$$eval(`${DAY} [data-test=calday-hour]`, (els) => els.map((el) => ({ l: el.getAttribute('data-label'), at: el.getAttribute('data-at') })))
    const threes = rows.filter((r) => r.l === '03:00')
    ok('S4-6 Helsinki 2026-10-25: 25 hour rows, 03:00 labelled twice', rows.length === 25 && threes.length === 2, { n: rows.length, threes })
    const spot = await hourSpot(p, '03:00', 1)
    if (spot) await touch(p, spot, spot)
    const pa = await panelAt(p)
    ok('S4-6 Helsinki: a tap on the second 03:00 opens the add sheet at 01:00Z', pa.panel === 'add' && pa.at === '2026-10-25T01:00:00Z', pa)
    await ctx.close()
  }
  {
    const { p, ctx } = await open(browser, { width: 390, height: 844 }, { zone: 'Europe/Helsinki', day: '2026-03-29' })
    const n = await p.$$eval(`${DAY} [data-test=calday-hour]`, (els) => els.length).catch(() => 0)
    ok('S4-6 Helsinki 2026-03-29 (spring forward): 23 hour rows', n === 23, n)
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-day: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
