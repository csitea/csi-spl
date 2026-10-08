// spec 106 T010: the phone calendar's month picker (CalendarPhoneYear.vue)
// and search (CalendarPhoneSearch.vue), spec 4.6, FR-009, FR-010.
//
// At 360x780, 390x844 and 820x1180, dark and light, font levels 1, 3 and 5,
// on the picker and on the search with results:
//   H3  no sideways scroll: documentElement scrollWidth - clientWidth <= 1,
//       no scroller under the calendar wider than its box, scrollLeft == 0
//   H7  controls (the picker's and the search's header) >= 44x44, <= 48 px
//       tall at level 3; content (month buttons, result rows) >= 44x44
//   H8  the picker / the search covers >= 82 % of the page the app gives
//       the calendar (level 3)
//   S4-2 e  each is role=dialog aria-modal=true
// Once per width (level 3, dark):
//   AC-03  title, month: Month on the first of the month 3 ahead; a year
//          crossing costs the one < / > tap (the day is T005's third tap)
//   FR-009 the year stays inside 089's 3 years (< / > disabled at the
//          ends); a sideways swipe turns the year; Escape closes and focus
//          returns to the title
//   FR-010 search opens in 1 tap with the field focused; typing lists the
//          mock "Planning" under its day; a tap opens Day on that day
//          with the event's peek (T009);
//          nothing matching shows the empty note
//
// Controls: before T010 the title opens no [data-test=calphone-picker], so
// every check FAILs; in-run, a planted 30 px button must trip the H7
// detector, a planted 2000 px scroller the H3 one.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-jump
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay } from '../../src/utils/calendar-year.mjs'
import { calPhoneRange } from '../../src/utils/calendar-phone-nav.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-jump-${name}.png`) })
}

const today = calIsoDay(Date.now())
const ROOT = '[data-test=calendar-phone]'
const PICKER = '[data-test=calphone-picker]'
const SEARCH = '[data-test=calphone-searchbox]'

/** a fresh page: the theme and the font level in localStorage first */
async function open(browser, vp, { theme = 'dark', level = 3 } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calphone-seeded')) return
      sessionStorage.setItem('calphone-seeded', '1')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
      localStorage.setItem('spool-calendar-phone-view', 'week')
    } catch { /* about:blank */ }
  }, { theme, level })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForSelector(ROOT, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 10000 }, ROOT).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const rootAttr = (p, n) => p.$eval(ROOT, (el, a) => el.getAttribute(a), n).catch(() => '')
const waitRoot = (p, n, want) => p.waitForFunction((r, a, w) => document.querySelector(r)?.getAttribute(a) === w, { timeout: 5000 }, ROOT, n, want).then(() => true, () => false)
const shown = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 8000 }).then(() => true, () => false)
const gone = (p, sel) => p.waitForSelector(sel, { hidden: true, timeout: 5000 }).then(() => true, () => false)

async function openPicker(p) {
  await p.click(`${ROOT} [data-test=calphone-title]`)
  return shown(p, `${PICKER} [data-test=calphone-picker-grid]`)
}
async function openSearch(p, text) {
  await p.click(`${ROOT} [data-test=calphone-search]`)
  if (!(await shown(p, `${SEARCH} [data-test=calphone-search-input]`))) return false
  if (text) {
    await p.type(`${SEARCH} [data-test=calphone-search-input]`, text)
    await p.waitForFunction((s) => ['ready', 'failed'].includes(document.querySelector(s)?.getAttribute('data-state') || ''), { timeout: 8000 }, SEARCH).catch(() => {})
  }
  return true
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

/* the boxes H7 / H8 read on a dialog: its header controls and its content targets */
async function boxes(p, sel, head, content) {
  return p.evaluate((s, h, c) => {
    const box = (el) => {
      if (!el) return null
      const b = el.getBoundingClientRect()
      return { x: Math.round(b.left), y: Math.round(b.top), w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }
    }
    const root = document.querySelector(s)
    const list = (q) => [...(root ? root.querySelectorAll(q) : [])].filter((el) => el.offsetParent !== null).map((el) => ({ id: el.getAttribute('data-test') || el.className, ...box(el) }))
    const dock = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h')) || 0
    const pg = box(document.querySelector('[data-test=calendar-page]'))
    if (pg) pg.h = Math.min(pg.y + pg.h, window.innerHeight - dock) - pg.y
    return {
      page: pg,
      dialog: box(root),
      role: root ? `${root.getAttribute('role')}/${root.getAttribute('aria-modal')}` : '',
      controls: list(h),
      content: list(c),
    }
  }, sel, head, content)
}
const tapSize = (c) => c.w >= 43.5 && c.h >= 43.5

/** H3 / H7 / H8 on an open dialog */
async function dialogChecks(p, tag, sel, head, content, lvl) {
  const s = await sideways(p)
  ok(`H3 ${tag}: no sideways scroll`, flatOk(s), s)
  const b = await boxes(p, sel, head, content)
  ok(`S4-2 ${tag}: role=dialog aria-modal=true`, b.role === 'dialog/true', b.role)
  const small = b.controls.filter((c) => !tapSize(c))
  ok(`H7 ${tag}: every control >= 44x44`, small.length === 0 && b.controls.length >= 1, small.length ? small : b.controls.length)
  const tiny = b.content.filter((c) => !tapSize(c))
  ok(`H7 ${tag}: every content target >= 44x44`, tiny.length === 0 && b.content.length >= 1, tiny.length ? tiny : b.content.length)
  if (lvl === 3) {
    const tall = b.controls.filter((c) => c.h > 48.5)
    ok(`H7 ${tag}: controls <= 48 px tall at level 3`, tall.length === 0, tall)
    const share = b.page && b.dialog ? Math.min(b.dialog.h, b.page.h) / b.page.h : 0
    ok(`H8 ${tag}: covers >= 82 % of the page`, share >= 0.82, { share: Math.round(share * 1000) / 10, dialog: b.dialog?.h, page: b.page?.h })
  }
  return b
}
const PICK_HEAD = '.calyear__head button'
const PICK_CONTENT = '.calyear__month'
const SEARCH_HEAD = '.calsearch__head button, .calsearch__head input'
const SEARCH_CONTENT = '[data-test=calphone-search-row]'

/* a finger on the picker: down at `from`, 10 moves to `to`, then up */
async function swipe(p, from, to) {
  const cdp = await p.createCDPSession()
  const pt = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(from.x, from.y) })
  for (let i = 1; i <= 10; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(from.x + ((to.x - from.x) * i) / 10, from.y + ((to.y - from.y) * i) / 10) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(300)
}

/** the first of the month `n` months after `iso` */
function monthAhead(iso, n) {
  const y = Number(iso.slice(0, 4))
  const m = Number(iso.slice(5, 7)) - 1 + n
  return `${y + Math.floor(m / 12)}-${String((m % 12) + 1).padStart(2, '0')}-01`
}

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }, { width: 820, height: 1180 }]

try {
  /* ---- the matrix: H3 / H7 / H8 on the picker and the search ---- */
  for (const vp of PHONES) {
    for (const theme of ['dark', 'light']) {
      for (const lvl of [1, 3, 5]) {
        const tag = `${vp.width} ${theme} L${lvl}`
        const { p, ctx } = await open(browser, vp, { theme, level: lvl })
        if (!(await openPicker(p))) {
          ok(`FR-009 ${tag}: the title opens the month picker`, false)
          await ctx.close()
          continue
        }
        await dialogChecks(p, `${tag} picker`, PICKER, PICK_HEAD, PICK_CONTENT, lvl)
        if (lvl === 3) await shot(p, `${vp.width}-${theme}-picker`)
        await p.keyboard.press('Escape')
        await gone(p, PICKER)
        if (!(await openSearch(p, 'a'))) {
          ok(`FR-010 ${tag}: the search button opens the field`, false)
          await ctx.close()
          continue
        }
        await dialogChecks(p, `${tag} search`, SEARCH, SEARCH_HEAD, SEARCH_CONTENT, lvl)
        if (lvl === 3) await shot(p, `${vp.width}-${theme}-search`)
        await ctx.close()
      }
    }
  }

  /* ---- controls: the detectors must trip ---- */
  {
    const { p, ctx } = await open(browser, PHONES[0])
    await openPicker(p)
    await p.evaluate((s) => {
      const b = document.createElement('button')
      b.className = 'planted'
      b.style.cssText = 'width:30px;height:30px'
      document.querySelector(`${s} .calyear__head`)?.append(b)
      const w = document.createElement('div')
      w.style.cssText = 'overflow-x:auto;width:100px'
      w.innerHTML = '<div style="width:2000px;height:1px"></div>'
      document.querySelector(`${s} .calyear__grid`)?.append(w)
    }, PICKER)
    const b = await boxes(p, PICKER, PICK_HEAD, PICK_CONTENT)
    ok('control: a planted 30 px button trips H7', b.controls.some((c) => !tapSize(c)))
    ok('control: a planted 2000 px scroller trips H3', !flatOk(await sideways(p)))
    await ctx.close()
  }

  /* ---- the flows, once per width (level 3, dark) ---- */
  for (const vp of PHONES) {
    const w = vp.width
    let { p, ctx } = await open(browser, vp)

    /* AC-03: title, month (and < / > when the target is next year) */
    {
      const target = monthAhead(today, 3)
      let taps = 0
      taps += 1
      const opened = await openPicker(p)
      ok(`FR-009 ${w}: one tap on the title opens the picker`, opened)
      const year = Number(await p.$eval(PICKER, (el) => el.getAttribute('data-year')).catch(() => '0'))
      ok(`FR-009 ${w}: the picker opens on the shown year`, year === Number(today.slice(0, 4)), year)
      if (Number(target.slice(0, 4)) > year) {
        await p.click(`${PICKER} [data-test=calphone-picker-next]`)
        taps += 1
      }
      const sel = `${PICKER} [data-test=calphone-picker-month-${target.slice(0, 7)}]`
      await p.waitForSelector(sel, { visible: true, timeout: 3000 }).catch(() => null)
      await p.click(sel).catch(() => {})
      taps += 1
      const month = await waitRoot(p, 'data-view', 'month')
      const period = await waitRoot(p, 'data-period', calPhoneRange('month', target)?.from || '')
      ok(`AC-03 ${w}: Month on ${target.slice(0, 7)} after ${taps} taps (title, ${taps === 3 ? 'next year, ' : ''}month)`, month && period && taps <= 3, { view: await rootAttr(p, 'data-view'), period: await rootAttr(p, 'data-period'), taps })
      ok(`AC-03 ${w}: the picker closes on the pick`, await gone(p, PICKER))
    }

    /* FR-009: the 3-year range, swipe, Escape, focus back to the title */
    {
      await openPicker(p)
      const thisYear = Number(today.slice(0, 4))
      const yearOf = () => p.$eval(PICKER, (el) => Number(el.getAttribute('data-year'))).catch(() => 0)
      for (let i = 0; i < 4; i++) await p.click(`${PICKER} [data-test=calphone-picker-prev]`).catch(() => {})
      const low = await yearOf()
      const prevOff = await p.$eval(`${PICKER} [data-test=calphone-picker-prev]`, (el) => el.disabled)
      for (let i = 0; i < 4; i++) await p.click(`${PICKER} [data-test=calphone-picker-next]`).catch(() => {})
      const high = await yearOf()
      const nextOff = await p.$eval(`${PICKER} [data-test=calphone-picker-next]`, (el) => el.disabled)
      ok(`FR-009 ${w}: the years run ${thisYear - 1}..${thisYear + 1}, the ends disabled`, low === thisYear - 1 && high === thisYear + 1 && prevOff && nextOff, { low, high, prevOff, nextOff })
      const g = await p.$eval(`${PICKER} [data-test=calphone-picker-grid]`, (el) => {
        const r = el.getBoundingClientRect()
        return { x: r.left, w: r.width, y: r.top + r.height / 2 }
      })
      await swipe(p, { x: g.x + g.w * 0.8, y: g.y }, { x: g.x + g.w * 0.2, y: g.y })
      ok(`FR-009 ${w}: a swipe left past the last year stays on it`, (await yearOf()) === thisYear + 1, await yearOf())
      await swipe(p, { x: g.x + g.w * 0.3, y: g.y }, { x: g.x + g.w * 0.85, y: g.y })
      ok(`FR-009 ${w}: a swipe right turns back a year`, (await yearOf()) === thisYear, await yearOf())
      await p.keyboard.press('Escape')
      const closed = await gone(p, PICKER)
      const focus = await p.evaluate(() => document.activeElement?.getAttribute('data-test') || '')
      ok(`S4-2 ${w}: Escape closes the picker, focus back on the title`, closed && focus === 'calphone-title', { closed, focus })
    }
    await ctx.close()

    /* FR-010: search in 1 tap, a result opens Day on its day */
    ;({ p, ctx } = await open(browser, vp));
    {
      await p.click(`${ROOT} [data-test=calphone-search]`)
      const opened = await shown(p, `${SEARCH} [data-test=calphone-search-input]`)
      const focused = await p.evaluate(() => document.activeElement?.getAttribute('data-test') || '')
      ok(`FR-010 ${w}: search opens in 1 tap, the field focused`, opened && focused === 'calphone-search-input', { opened, focused })
      await p.type(`${SEARCH} [data-test=calphone-search-input]`, 'planning')
      const want = calAddDays(today, 30)
      const row = `${SEARCH} [data-test=calphone-search-row][data-id="00000000-0000-4000-8000-000000000103"]`
      const found = await shown(p, row)
      const day = await p.$eval(row, (el) => el.getAttribute('data-day')).catch(() => '')
      const head = await p.$eval(`${SEARCH} [data-test=calphone-search-day][data-day="${day}"] h3`, (el) => el.textContent.trim()).catch(() => '')
      ok(`FR-010 ${w}: "planning" lists the event under its day`, found && day === want && head.includes(want), { found, day, want, head })
      await p.click(row).catch(() => {})
      const dayView = await waitRoot(p, 'data-view', 'day')
      const onDay = await waitRoot(p, 'data-day', want)
      ok(`FR-010 ${w}: a tap opens Day on ${want}, the search closed`, dayView && onDay && (await gone(p, SEARCH)), { view: await rootAttr(p, 'data-view'), day: await rootAttr(p, 'data-day') })
      const peek = '[data-test=calpeek][data-id="00000000-0000-4000-8000-000000000103"]'
      ok(`FR-010 ${w}: the tap opens that event's peek (T009)`, await shown(p, peek))
      await p.click('[data-test=calpeek-close]').catch(() => {})
      await gone(p, '[data-test=calpeek]')
      await openSearch(p, 'zzzz-no-such-event')
      ok(`FR-010 ${w}: nothing matching shows the empty note`, await shown(p, `${SEARCH} [data-test=calphone-search-empty]`))
      await p.keyboard.press('Escape')
      const closed = await gone(p, SEARCH)
      const focus = await p.evaluate(() => document.activeElement?.getAttribute('data-test') || '')
      ok(`S4-2 ${w}: Escape closes the search, focus back on its button`, closed && focus === 'calphone-search', { closed, focus })
    }
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-jump: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
