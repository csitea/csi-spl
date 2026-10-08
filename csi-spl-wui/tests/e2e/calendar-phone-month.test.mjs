// spec 106 T005: the phone calendar's Month view (CalendarPhoneMonth.vue).
//
// At 360x780, 390x844 and 820x1180, dark and light, font levels 1, 3 and 5:
//   FR-003 the 6x7 grid (role=grid, 6 week rows + the weekday row, 42
//          cells), 16 px side gutters and no gap between cells
//   H3  no sideways scroll, scrollLeft == 0 (with a 200-character
//       unbroken title in the agenda)
//   H7  every cell, agenda card and the empty state's Add >= 44x44
//   H8  the view >= 82 % of the page the app gives the calendar (level 3)
//   S4-8 each dot draws var(--cal-dot-ring): an edge on light, none on dark
//   dim (level 3) a day of the previous / next month reads >= 3.3x fainter
//       (WCAG contrast on its background) than a day of this month, yet
//       >= 3:1, its dots dimmed too
// Once per width (level 3, dark):
//   FR-003 up to 3 dots then +n; today raised, outlined in the accent, bold,
//       aria-current=date; the selected day's agenda under the grid
//   S2-3 an agenda card opens its peek in 1 tap; an empty day shows
//       "No events planned" and + Add event opens the add sheet on that
//       day (2 taps); a second tap on the selected day opens Day
//   S4-2 cells are named "<weekday> <day>, <n> event(s)", one selected;
//       arrows move the selection and the focus, Enter opens Day
//   H2  a swipe left / right turns one month
// S4-3, under America/New_York and Asia/Tokyo: an all-day event sits on its
// UTC date, a 3-day all-day event has a dot on each of its 3 days.
// Controls: a planted 2000 px scroller trips H3, a planted 30 px cell H7,
// the dot-ring probe reads 'none' on a dot with box-shadow removed, and the
// pre-fix look (opacity 1 on the other months' days) trips the dim check.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-month
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay } from '../../src/utils/calendar-year.mjs'
import { calPhoneMonthGrid, calPhoneRange, calPhoneStep } from '../../src/utils/calendar-phone-nav.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-month-${name}.png`) })
}

/* ---- the fixture: days of today's month grid that nothing else touches ---- */
const today = calIsoDay(Date.now())
const GRID = calPhoneMonthGrid(today).map((c) => c.iso)
/* the mock's own items (calendar-mock.mjs) and a day of slack for the zones */
const year = today.slice(0, 4)
const busy = new Set()
for (const d of [today, calAddDays(today, 2), calAddDays(today, 30), `${year}-12-25`]) {
  for (let k = -2; k <= 2; k++) busy.add(calAddDays(d, k))
}
const free = GRID.filter((d) => !busy.has(d))
/** the first run of `n` free days in the grid with a free day either side */
function freeRun(n, taken) {
  for (let i = 1; i + n < GRID.length; i++) {
    const days = GRID.slice(i - 1, i + n + 1)
    if (days.every((d) => free.includes(d) && !taken.has(d))) return GRID.slice(i, i + n)
  }
  return []
}
const taken = new Set()
const ALLDAY = freeRun(1, taken)[0]
for (const k of [-1, 0, 1]) taken.add(calAddDays(ALLDAY, k))
const SPAN = freeRun(3, taken)
for (const d of SPAN) for (const k of [-1, 0, 1]) taken.add(calAddDays(d, k))
const EMPTY = freeRun(1, taken)[0]
const LONG = 'x'.repeat(200)
const at = (day, hhmm) => `${day}T${hhmm}:00Z`
const FIXTURE = [
  { id: 'c535-0000-4000-8000-000000000001', title: 'Standup', starts_at: at(today, '11:00'), ends_at: at(today, '11:15'), color: 'banana' },
  { id: 'c535-0000-4000-8000-000000000002', title: 'Review', starts_at: at(today, '12:00'), ends_at: at(today, '13:00'), color: 'sage' },
  { id: 'c535-0000-4000-8000-000000000003', title: 'Lunch', starts_at: at(today, '13:00'), ends_at: at(today, '13:30'), color: 'flamingo' },
  { id: 'c535-0000-4000-8000-000000000004', title: 'Retro', starts_at: at(today, '14:00'), ends_at: at(today, '14:45'), color: 'peacock' },
  { id: 'c535-0000-4000-8000-000000000005', title: LONG, starts_at: at(ALLDAY, '00:00'), ends_at: at(calAddDays(ALLDAY, 1), '00:00'), all_day: true, color: 'banana' },
  { id: 'c535-0000-4000-8000-000000000006', title: 'Offsite', starts_at: at(SPAN[0], '00:00'), ends_at: at(calAddDays(SPAN[2], 1), '00:00'), all_day: true, color: 'grape' },
]
/* today: the mock's 09:00Z release plus the four above */
const TODAY_COUNT = 5

const ROOT = '[data-test=calendar-phone]'
const MONTH = `${ROOT} [data-test=calphone-page][data-dir="0"] [data-test=calphone-month]`
const cell = (iso) => `${MONTH} [data-test=calphone-month-cell][data-iso="${iso}"]`
const periodOf = (day) => calPhoneRange('month', day)?.from || ''
/* the dim check's pair: a day of the next / previous month and one of this
   month, neither today (the selected day on open) */
const OUT_DAY = calPhoneMonthGrid(today).find((c) => !c.inMonth && c.iso !== today)?.iso
const IN_DAY = calPhoneMonthGrid(today).find((c) => c.inMonth && c.iso !== today)?.iso

/** a fresh page on Month: the fixture, theme and level first */
async function open(browser, vp, { theme = 'dark', level = 3, zone = '' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  if (zone) await p.emulateTimezone(zone)
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calmonth-seeded')) return
      sessionStorage.setItem('calmonth-seeded', '1')
      localStorage.setItem('spool-calendar-phone-view', 'month')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(s.fixture))
    } catch { /* about:blank */ }
  }, { theme, level, fixture: FIXTURE })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForSelector(MONTH, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 10000 }, ROOT).catch(() => {})
  await p.waitForSelector(`${MONTH} [data-test=calphone-month-agenda]`, { timeout: 5000 }).catch(() => null)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const rootAttr = (p, n) => p.$eval(ROOT, (el, a) => el.getAttribute(a), n).catch(() => '')
const waitRoot = (p, n, want) => p.waitForFunction((r, a, w) => document.querySelector(r)?.getAttribute(a) === w, { timeout: 5000 }, ROOT, n, want).then(() => true, () => false)
const panel = (p) => p.evaluate((r) => {
  const el = document.querySelector(`${r} [data-test=calphone-panel]`)
  return el ? { kind: el.getAttribute('data-panel'), day: el.getAttribute('data-at-day') || '' } : null
}, ROOT)
const cellInfo = (p, iso) => p.$eval(cell(iso), (el) => ({
  count: Number(el.getAttribute('data-count')),
  dots: el.querySelectorAll('[data-test=calphone-month-dot]').length,
  more: el.querySelector('[data-test=calphone-month-more]')?.textContent?.trim() || '',
  label: el.getAttribute('aria-label') || '',
})).catch(() => null)
const agendaIds = (p) => p.$$eval(`${MONTH} [data-test=calphone-month-event]`, (els) => els.map((el) => el.getAttribute('data-id')))

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

/* the boxes FR-003 / H7 / H8 read */
async function boxes(p) {
  return p.evaluate((m, r) => {
    const box = (el) => {
      const b = el.getBoundingClientRect()
      return { x: Math.round(b.left * 10) / 10, y: Math.round(b.top * 10) / 10, w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }
    }
    const month = document.querySelector(m)
    const scroll = month?.closest('.calphone__scroll')
    const cells = [...(month?.querySelectorAll('[data-test=calphone-month-cell]') || [])].map((el) => ({ iso: el.getAttribute('data-iso'), ...box(el) }))
    const targets = [...(month?.querySelectorAll('[data-test=calphone-month-event], [data-test=calphone-month-add]') || [])].map((el) => ({ id: el.getAttribute('data-test'), ...box(el) }))
    const grid = month?.querySelector('[role=grid]')
    const dock = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h')) || 0
    const page = document.querySelector('[data-test=calendar-page]')
    const pg = page ? box(page) : null
    if (pg) pg.h = Math.min(pg.y + pg.h, window.innerHeight - dock) - pg.y
    const view = document.querySelector(`${r} [data-test=calphone-view]`)
    return {
      cells,
      targets,
      rows: grid ? grid.querySelectorAll('[role=row]').length : 0,
      gridcells: grid ? grid.querySelectorAll('[role=gridcell]').length : 0,
      scroll: scroll ? { ...box(scroll), inner: scroll.clientWidth, padL: parseFloat(getComputedStyle(scroll).paddingLeft), padR: parseFloat(getComputedStyle(scroll).paddingRight) } : null,
      page: pg,
      view: view ? box(view) : null,
    }
  }, MONTH, ROOT)
}
const tapSize = (c) => c.w >= 43.5 && c.h >= 43.5

/** FR-003 grid geometry, H3, H7, H8 on the screen as it is */
async function layoutChecks(p, tag, lvl) {
  const b = await boxes(p)
  ok(`FR-003 ${tag}: a grid of 6 week rows + the weekday row, 42 cells`, b.rows === 7 && b.gridcells === 42 && b.cells.length === 42, { rows: b.rows, cells: b.gridcells })
  if (b.cells.length === 42 && b.scroll) {
    const left = b.cells[0].x - b.scroll.x
    const rightEdge = b.cells[6].x + b.cells[6].w
    const contentRight = b.scroll.x + b.scroll.padL + (b.scroll.inner - b.scroll.padL - b.scroll.padR)
    ok(`FR-003 ${tag}: 16 px side gutters`, Math.abs(left - 16) <= 1 && Math.abs(b.scroll.padR - 16) <= 0.5 && Math.abs(rightEdge - contentRight) <= 1, { left, padR: b.scroll.padR, rightEdge, contentRight })
    const gaps = []
    for (let i = 0; i < 42; i++) {
      if (i % 7 !== 6) gaps.push(Math.abs(b.cells[i + 1].x - (b.cells[i].x + b.cells[i].w)))
      if (i < 35) gaps.push(Math.abs(b.cells[i + 7].y - (b.cells[i].y + b.cells[i].h)))
    }
    ok(`FR-003 ${tag}: no gap between cells`, Math.max(...gaps) <= 0.6, Math.max(...gaps))
  }
  const small = [...b.cells, ...b.targets].filter((c) => !tapSize(c))
  ok(`H7 ${tag}: every cell and agenda target >= 44x44`, small.length === 0 && b.targets.length > 0, small.slice(0, 3))
  const s = await sideways(p)
  ok(`H3 ${tag}: no sideways scroll`, flatOk(s), s)
  if (lvl === 3) {
    const share = b.page && b.view ? b.view.h / b.page.h : 0
    ok(`H8 ${tag}: the view is >= 82 % of the page`, share >= 0.82, { share: Math.round(share * 1000) / 10 })
  }
  return b
}

/* S4-8: the dot's computed ring */
const dotRings = (p) => p.$$eval(`${MONTH} [data-test=calphone-month-dot]`, (els) => els.slice(0, 4).map((el) => getComputedStyle(el).boxShadow))
const ringDraws = (s) => Boolean(s) && s !== 'none' && !/rgba\(0, 0, 0, 0\)|transparent/.test(s) && !/\b0px 0px 0px 0px\b/.test(s)

/* dim: a day number's effective colour (its alpha times every opacity up to
   the cell, over the first painted background above it) and its WCAG
   contrast on that background; the dots' opacity */
const lum = ([r, g, b]) => {
  const ch = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }
  return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
}
const contrast = (a, b) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05)
async function numLook(p, iso) {
  const l = await p.$eval(cell(iso), (c) => {
    const rgba = (s) => { const m = (s.match(/[\d.]+/g) || []).map(Number); return [m[0] || 0, m[1] || 0, m[2] || 0, m[3] ?? 1] }
    const num = c.querySelector('.calmonth__num')
    let a = rgba(getComputedStyle(num).color)[3]
    for (let el = num; el; el = el === c ? null : el.parentElement) a *= Number(getComputedStyle(el).opacity)
    let bg = [255, 255, 255, 1]
    for (let el = c; el; el = el.parentElement) {
      const b = rgba(getComputedStyle(el).backgroundColor)
      if (b[3] > 0) { bg = b; break }
    }
    const fg = rgba(getComputedStyle(num).color)
    return { fg: [0, 1, 2].map((i) => fg[i] * a + bg[i] * (1 - a)), bg: bg.slice(0, 3), dots: Number(getComputedStyle(c.querySelector('.calmonth__dots')).opacity) }
  }).catch(() => null)
  return l && { ...l, ratio: Math.round(contrast(l.fg, l.bg) * 100) / 100 }
}
/* in / out >= 3.3 (the pre-fix look measured 2.2 dark, 2.57 light) */
const DIM_FACTOR = 3.3
async function dimLook(p) {
  const out = await numLook(p, OUT_DAY)
  const inn = await numLook(p, IN_DAY)
  const factor = out && inn ? Math.round((inn.ratio / out.ratio) * 100) / 100 : 0
  return { in: inn?.ratio, out: out?.ratio, factor, dotsOut: out?.dots, dotsIn: inn?.dots, ok: factor >= DIM_FACTOR && out.ratio >= 3 }
}

/* a finger on the view: down at `from`, moves to `to`, then up */
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
async function viewMid(p) {
  return p.$eval(`${ROOT} [data-test=calphone-view]`, (el) => {
    const r = el.getBoundingClientRect()
    return { x: r.left, w: r.width, y: r.top + r.height / 3 }
  })
}

/** a closed sheet or peek: the selected cell takes a tap again (what is under its centre) */
async function settled(p) {
  const t0 = Date.now()
  const free = await p.waitForFunction((m, d) => {
    const c = document.querySelector(`${m} [data-test=calphone-month-cell][data-iso="${d}"]`)
    if (!c) return false
    const r = c.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    return Boolean(hit && c.contains(hit))
  }, { timeout: 5000 }, MONTH, await rootAttr(p, 'data-day')).then(() => true, () => false)
  ok('a closed sheet leaves the grid tappable', free, { ms: Date.now() - t0 })
}

/** tap a cell and wait for the shell to follow */
async function tapCell(p, iso) {
  await p.click(cell(iso))
  return waitRoot(p, 'data-day', iso)
}

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }, { width: 820, height: 1180 }]
try {
  ok('fixture: free days for the all-day, the 3-day and the empty day', Boolean(ALLDAY && SPAN.length === 3 && EMPTY), { today, ALLDAY, SPAN, EMPTY })
  ok('fixture: a day of another month and one of this month for the dim check', Boolean(OUT_DAY && IN_DAY), { OUT_DAY, IN_DAY })

  /* ---- the matrix: FR-003 grid, H3 / H7 / H8, the dot ring ---- */
  for (const vp of PHONES) {
    for (const theme of ['dark', 'light']) {
      for (const lvl of [1, 3, 5]) {
        const tag = `${vp.width} ${theme} L${lvl}`
        console.log(`-- ${tag}`)
        const { p, ctx } = await open(browser, vp, { theme, level: lvl })
        ok(`${tag}: Month renders`, (await rootAttr(p, 'data-view')) === 'month' && Boolean(await p.$(MONTH)))
        await layoutChecks(p, `${tag} today`, lvl)
        if (lvl === 3) {
          const rings = await dotRings(p)
          ok(`S4-8 ${tag}: dots ${theme === 'light' ? 'draw' : 'need no'} the --cal-dot-ring edge`, rings.length > 0 && rings.every((s) => ringDraws(s) === (theme === 'light')), rings)
          if (vp.width === 390) await shot(p, `${vp.width}-${theme}`)
          const dim = await dimLook(p)
          ok(`dim ${tag}: ${OUT_DAY} reads >= ${DIM_FACTOR}x fainter than ${IN_DAY}, >= 3:1`, dim.ok, dim)
          ok(`dim ${tag}: the other months' dots dim too`, dim.dotsOut < 1 && dim.dotsIn === 1, dim)
          if (vp.width === 390) {
            /* control: the pre-fix look (no opacity) trips the check */
            await p.evaluate(() => {
              const st = document.createElement('style')
              st.id = 'calmonth-dim-control'
              st.textContent = '.calmonth__num, .calmonth__dots { opacity: 1 !important; }'
              document.head.appendChild(st)
            })
            const pre = await dimLook(p)
            ok(`control ${tag}: the pre-fix look fails the dim check`, !pre.ok, pre)
            await p.evaluate(() => document.getElementById('calmonth-dim-control')?.remove())
          }
        }
        /* the empty state and the 200-character title */
        await tapCell(p, EMPTY)
        await layoutChecks(p, `${tag} empty day`, lvl)
        await tapCell(p, ALLDAY)
        const longS = await sideways(p)
        ok(`H3 ${tag}: a 200-character title widens nothing`, flatOk(longS) && (await agendaIds(p)).includes(FIXTURE[4].id), longS)
        await ctx.close()
      }
    }
  }

  /* ---- the interactions, once per width (level 3, dark) ---- */
  for (const vp of PHONES) {
    const w = vp.width
    console.log(`-- ${w}x${vp.height} interactions`)
    const { p, ctx } = await open(browser, vp)
    ok(`${w}: Month opens on today, its month`, (await rootAttr(p, 'data-day')) === today && (await rootAttr(p, 'data-period')) === periodOf(today), { day: await rootAttr(p, 'data-day'), period: await rootAttr(p, 'data-period') })

    /* today: raised, accent outline, bold, aria-current */
    const t = await p.$eval(cell(today), (el) => {
      const cs = getComputedStyle(el)
      const num = el.querySelector('.calmonth__num')
      const probe = document.createElement('span')
      probe.style.color = 'var(--color-accent)'
      document.body.appendChild(probe)
      const accent = getComputedStyle(probe).color
      probe.remove()
      return { shadow: cs.boxShadow, outline: `${cs.outlineStyle} ${cs.outlineWidth}`, outlineColor: cs.outlineColor, accent, weight: Number(getComputedStyle(num).fontWeight), current: el.getAttribute('aria-current') }
    })
    ok(`FR-003 ${w}: today is raised, outlined in the accent, bold, aria-current=date`, t.shadow !== 'none' && t.outline.startsWith('solid') && t.outlineColor === t.accent && t.weight >= 700 && t.current === 'date', t)

    /* dots: 3, then +n; the cell says its count */
    const ti = await cellInfo(p, today)
    ok(`FR-003 ${w}: ${TODAY_COUNT} events today = 3 dots and +${TODAY_COUNT - 3}`, ti && ti.count === TODAY_COUNT && ti.dots === 3 && ti.more === `+${TODAY_COUNT - 3}`, ti)
    ok(`S4-2 ${w}: the cell is named with its day and count`, Boolean(ti && ti.label.includes(today) && ti.label.includes(String(TODAY_COUNT))), ti?.label)
    const aria = await p.evaluate((m) => {
      const g = document.querySelector(`${m} [role=grid]`)
      const on = [...(g?.querySelectorAll('[role=gridcell][aria-selected=true]') || [])]
      return { selected: on.map((el) => el.getAttribute('data-iso')), dotsHidden: [...(g?.querySelectorAll('.calmonth__dots') || [])].every((el) => el.getAttribute('aria-hidden') === 'true') }
    }, MONTH)
    ok(`S4-2 ${w}: one selected cell, dots aria-hidden`, aria.selected.length === 1 && aria.selected[0] === today && aria.dotsHidden, aria)

    /* the agenda under the grid; a card opens its peek in 1 tap */
    const ids = await agendaIds(p)
    ok(`FR-003 ${w}: today's agenda lists its ${TODAY_COUNT} events`, ids.length === TODAY_COUNT, ids)
    await p.click(`${MONTH} [data-test=calphone-month-event][data-id="${FIXTURE[1].id}"]`)
    const pk = await p.waitForSelector(`${ROOT} [data-test=calpeek-title]`, { visible: true, timeout: 5000 }).then((el) => el.evaluate((x) => x.textContent.trim()), () => '')
    ok(`S2-3 ${w}: an agenda card opens its peek (T009) in 1 tap`, pk === FIXTURE[1].title, pk)
    await p.click(`${ROOT} [data-test=calpeek-close]`)
    await settled(p)

    /* an empty day: "No events planned", + Add event on that day = 2 taps */
    await tapCell(p, EMPTY)
    const empty = await p.$eval(`${MONTH} [data-test=calphone-month-empty]`, (el) => el.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
    ok(`S2-3 ${w}: an empty day says No events planned`, /No events planned/.test(empty) && /Add event/.test(empty), empty)
    await p.click(`${MONTH} [data-test=calphone-month-add]`)
    const ad = await panel(p)
    ok(`S2-3 ${w}: + Add event opens the add sheet on that day (2 taps)`, ad?.kind === 'add' && ad.day === EMPTY, ad)
    /* T008's sheet (teleported to body) opens on that date; Cancel closes it */
    const sheet = await p.waitForSelector('[data-test=calphone-sheet-date]', { visible: true, timeout: 5000 }).then(() => p.$eval('[data-test=calphone-sheet-date]', (el) => el.getAttribute('data-value')), () => null)
    ok(`S2-3 ${w}: the add sheet is preset to that day`, sheet === EMPTY, sheet)
    if (sheet !== null) await p.click('[data-test=calphone-sheet-cancel]')
    await settled(p)

    /* the 3-day event: a dot on each day */
    const span = []
    for (const d of SPAN) span.push({ d, ...(await cellInfo(p, d)) })
    ok(`S4-3 ${w}: the 3-day event has a dot on each of its days`, span.every((c) => c.count === 1 && c.dots === 1), span)

    /* a selected / today day of another month keeps that look, not dimmed
       (a tap turns the page to its month, so the class is set by hand) */
    const keep = await p.$eval(cell(OUT_DAY), (el) => {
      const op = () => [el.querySelector('.calmonth__num'), el.querySelector('.calmonth__dots')].map((x) => Number(getComputedStyle(x).opacity))
      const got = {}
      for (const k of ['calmonth__cell--on', 'calmonth__cell--today']) {
        el.classList.add(k)
        got[k] = op()
        el.classList.remove(k)
      }
      got.plain = op()
      return got
    }).catch(() => null)
    ok(`dim ${w}: a selected or today day of another month is not dimmed`, Boolean(keep) && [...keep['calmonth__cell--on'], ...keep['calmonth__cell--today']].every((o) => o === 1) && keep.plain.every((o) => o < 1), keep)

    /* a second tap on the selected day opens Day */
    ok(`${w}: a tap selects a day of the previous / next month`, await tapCell(p, ALLDAY), await rootAttr(p, 'data-day'))
    await p.click(cell(ALLDAY))
    ok(`FR-003 ${w}: a second tap on the selected day opens Day`, (await waitRoot(p, 'data-view', 'day')) && (await rootAttr(p, 'data-day')) === ALLDAY, { view: await rootAttr(p, 'data-view'), day: await rootAttr(p, 'data-day') })
    await p.click(`${ROOT} [data-test=calphone-view-month]`)
    await waitRoot(p, 'data-view', 'month')
    await p.waitForSelector(MONTH, { visible: true, timeout: 5000 }).catch(() => null)

    /* S4-2 the keyboard: arrows move day and focus, Enter opens Day */
    await tapCell(p, today)
    await p.focus(cell(today))
    await p.keyboard.press('ArrowRight')
    const r1 = await waitRoot(p, 'data-day', calAddDays(today, 1))
    await p.keyboard.press('ArrowDown')
    const want = calAddDays(today, 8)
    const r2 = await waitRoot(p, 'data-day', want)
    await sleep(150)
    const focused = await p.evaluate(() => document.activeElement?.getAttribute('data-iso') || '')
    ok(`S4-2 ${w}: ArrowRight then ArrowDown move the selection 1 + 7 days, focus follows`, r1 && r2 && focused === want, { day: await rootAttr(p, 'data-day'), focused, want })
    await p.keyboard.press('Enter')
    ok(`S4-2 ${w}: Enter opens the selected day in Day`, (await waitRoot(p, 'data-view', 'day')) && (await rootAttr(p, 'data-day')) === want, await rootAttr(p, 'data-view'))
    await p.click(`${ROOT} [data-test=calphone-today]`)
    await p.click(`${ROOT} [data-test=calphone-view-month]`)
    await waitRoot(p, 'data-view', 'month')
    await waitRoot(p, 'data-day', today)

    /* H2: a swipe left / right turns one month */
    {
      const m = await viewMid(p)
      await swipe(p, { x: m.x + m.w * 0.8, y: m.y }, { x: m.x + m.w * 0.2, y: m.y + 4 })
      const next = periodOf(calPhoneStep('month', today, 1))
      const got = await rootAttr(p, 'data-period')
      const shown = await p.$eval(MONTH, (el) => el.getAttribute('data-period')).catch(() => '')
      ok(`H2 ${w}: swipe left = next month, its grid shown`, got === next && shown === next, { got, shown, next })
      await swipe(p, { x: m.x + m.w * 0.3, y: m.y }, { x: m.x + m.w * 0.85, y: m.y + 4 })
      ok(`H2 ${w}: swipe right = back to this month`, (await waitRoot(p, 'data-period', periodOf(today))), await rootAttr(p, 'data-period'))
    }

    /* controls: the detectors have teeth */
    if (w === 390) {
      await p.evaluate((m) => {
        const s = document.createElement('div')
        s.style.cssText = 'overflow-x:auto;width:100px'
        s.innerHTML = '<div style="width:2000px;height:4px"></div>'
        document.querySelector(`${m} [data-test=calphone-month-agenda]`).appendChild(s)
        const c = document.querySelector(`${m} [data-test=calphone-month-cell]`)
        c.style.cssText = 'min-width:0;min-height:0;width:30px;height:30px'
        const d = document.querySelector(`${m} [data-test=calphone-month-dot]`)
        if (d) d.style.boxShadow = 'none'
      }, MONTH)
      ok('control: a planted 2000 px scroller trips H3', !flatOk(await sideways(p)))
      ok('control: a planted 30 px cell trips H7', (await boxes(p)).cells.some((c) => !tapSize(c)))
      ok('control: a dot without its ring reads as no ring', !ringDraws((await dotRings(p))[0]))
    }
    await ctx.close()
  }

  /* ---- S4-3: all-day by its UTC date in zones either side of UTC ---- */
  for (const zone of ['America/New_York', 'Asia/Tokyo']) {
    const { p, ctx } = await open(browser, { width: 390, height: 844 }, { zone })
    const c = {}
    for (const d of [calAddDays(ALLDAY, -1), ALLDAY, calAddDays(ALLDAY, 1), calAddDays(SPAN[0], -1), ...SPAN, calAddDays(SPAN[2], 1)]) c[d] = (await cellInfo(p, d))?.count ?? -1
    const want = { [calAddDays(ALLDAY, -1)]: 0, [ALLDAY]: 1, [calAddDays(ALLDAY, 1)]: 0, [calAddDays(SPAN[0], -1)]: 0, [SPAN[0]]: 1, [SPAN[1]]: 1, [SPAN[2]]: 1, [calAddDays(SPAN[2], 1)]: 0 }
    ok(`S4-3 ${zone}: the all-day and the 3-day event sit on their UTC dates`, JSON.stringify(c) === JSON.stringify(want), { got: c, want })
    await tapCell(p, ALLDAY)
    ok(`S4-3 ${zone}: the all-day event is in that day's agenda`, (await agendaIds(p)).includes(FIXTURE[4].id))
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-month: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
