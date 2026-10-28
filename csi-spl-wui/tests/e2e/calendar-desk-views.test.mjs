// SPL-4060 (owner HUM-10, t1 080e1f77, poll 7c472af4): the desktop
// calendar at 1440x900, light and dark.
//
// (a) timed entries are readable: a 30-min event shows its title inside its
//     block, the title is >= 4.5:1 against the block, two overlapping
//     events sit side by side;
// (b) the time grid shows 8 hours at once and opens on 09:00 (Q2 W9);
// (c) no page header bar above the calendar: its controls (close, Hours)
//     moved into the vertical group;
// (d) a vertical tab group at the grid's LEFT edge (Q1) holds Day, 3 days,
//     Week, Month and Hours, then Today / previous / next and the period
//     title (Q3); each view opens on the period holding today; 3 days is
//     yesterday, today, tomorrow, and a day picked in the strip is the
//     middle one (msg 37951fb6); the + is round at the grid's bottom right
//     (Q4).
//
// Control: on the tree before SPL-4060 (48 px hours, a surface-coloured
// block, the feed-header bar, no tab group) every check below but the
// overlap one FAILS.
//
// Run: BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-desk-views
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { calAddDays, calWeekStart } from '../../src/utils/calendar-year.mjs'

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-desk-${name}.png`) })
}

const today = E2E_TODAY
const at = (day, hhmm) => `${day}T${hhmm}:00Z`
/* three short events today: a 30-min one alone, two 30-min ones overlapping */
const SEED = [
  { id: 'spl4060-short', title: 'Standup with the team', starts_at: at(today, '11:00'), ends_at: at(today, '11:30'), color: 'banana' },
  { id: 'spl4060-a', title: 'Review A', starts_at: at(today, '14:00'), ends_at: at(today, '14:30') },
  { id: 'spl4060-b', title: 'Review B', starts_at: at(today, '14:00'), ends_at: at(today, '14:30'), color: 'grape' },
]

/* the WCAG contrast of two CSS colours as Chrome computes them (a canvas
   turns any colour syntax, color-mix included, into sRGB bytes) */
function contrastIn(fg, bg, under) {
  const c = document.createElement('canvas')
  c.width = 1
  c.height = 1
  const g = c.getContext('2d', { willReadFrequently: true })
  const px = (col, base) => {
    g.clearRect(0, 0, 1, 1)
    g.fillStyle = base
    g.fillRect(0, 0, 1, 1)
    g.fillStyle = col
    g.fillRect(0, 0, 1, 1)
    return [...g.getImageData(0, 0, 1, 1).data].slice(0, 3)
  }
  const lum = ([r, gg, b]) => {
    const f = (v) => { const s = v / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4 }
    return 0.2126 * f(r) + 0.7152 * f(gg) + 0.0722 * f(b)
  }
  /* the block over the page, then the text over the block */
  const back = px(bg, under)
  const a = lum(back)
  const b = lum(px(fg, `rgb(${back.join(',')})`))
  return Math.round(((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)) * 100) / 100
}

async function measure(p, id) {
  return p.evaluate((id, src) => {
    const contrast = new Function(`return (${src})`)()
    const el = document.querySelector(`[data-test=calendar-item][data-id="${id}"]`)
    if (!el) return null
    const r = el.getBoundingClientRect()
    const title = el.querySelector('.cal-week__title')
    const tr = title?.getBoundingClientRect()
    const cs = getComputedStyle(el)
    const pageBg = getComputedStyle(document.body).backgroundColor
    return {
      h: Math.round(r.height), w: Math.round(r.width), left: Math.round(r.left), right: Math.round(r.right),
      titleIn: Boolean(tr && tr.width > 20 && tr.height > 0 && tr.top >= r.top - 1 && tr.bottom <= r.bottom + 1),
      contrast: title ? contrast(getComputedStyle(title).color, cs.backgroundColor, pageBg) : 0,
      bg: cs.backgroundColor,
    }
  }, id, contrastIn.toString())
}

/* how many hours the grid shows, and the clock at its top edge */
async function window8(p) {
  return p.evaluate(() => {
    const box = document.querySelector('[data-test=calendar-week]')
    const g = box?.querySelector('.cal-grid[data-grid-day]')
    if (!box || !g) return null
    const head = g.previousElementSibling?.getBoundingClientRect().height || 0
    const gr = g.getBoundingClientRect()
    const br = box.getBoundingClientRect()
    const hourPx = gr.height / 24
    const visible = box.clientHeight - head
    const topMin = ((br.top + head - gr.top) / hourPx) * 60
    return { hourPx: Math.round(hourPx), hours: Math.round((visible / hourPx) * 10) / 10, top: Math.round(topMin) }
  })
}

const view = (p) => p.$eval('[data-test=calendar-main]', (el) => el.getAttribute('data-view')).catch(() => '')
const cols = (p) => p.$$eval('[data-test=calendar-week-day]', (els) => els.map((e) => e.getAttribute('data-day')))
const waitView = (p, v) => p.waitForFunction((v) => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-view') === v && document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: 10000 }, v).then(() => true, () => false)
const tab = (v) => `[data-test=calendar-view-tabs] [data-test=calendar-view-${v}]`

async function run(browser, base, theme) {
  console.log(`-- 1440x900 ${theme}`)
  const p = await browser.newPage()
  await pinClock(p)
  await p.setViewport({ width: 1440, height: 900 })
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
  await p.evaluateOnNewDocument((t, seed) => {
    try {
      localStorage.setItem('spool-theme', t)
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(seed))
    } catch { /* private mode */ }
  }, theme, SEED)
  await p.goto(`${base}/calendar`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=calendar-main][data-state=ready]', { timeout: 15000 }).catch(() => null)
  await p.waitForSelector('[data-test=calendar-item][data-id="spl4060-short"]', { timeout: 10000 }).catch(() => null)
  await new Promise((r) => setTimeout(r, 300))
  await shot(p, `week-${theme}`)

  /* (b) */
  const w = await window8(p)
  ok(`(b) ${theme}: the week grid shows 8 hours at once`, Boolean(w && w.hours >= 7.8 && w.hours <= 8.3), w)
  ok(`(b) ${theme}: it opens on 09:00`, Boolean(w && Math.abs(w.top - 540) <= 5), w)

  /* (a) */
  const s = await measure(p, 'spl4060-short')
  ok(`(a) ${theme}: a 30-min event shows its title inside its block`, Boolean(s?.titleIn && s.h >= 32), s)
  ok(`(a) ${theme}: its title is >= 4.5:1 on the block`, Boolean(s && s.contrast >= 4.5), s)
  const plain = await measure(p, 'spl4060-a')
  ok(`(a) ${theme}: an event with no colour is >= 4.5:1 too`, Boolean(plain && plain.contrast >= 4.5), plain)
  const b = await measure(p, 'spl4060-b')
  ok(`(a) ${theme}: two overlapping events sit side by side, each titled`, Boolean(plain && b && (plain.right <= b.left + 1 || b.right <= plain.left + 1) && plain.titleIn && b.titleIn), { a: plain, b })
  const page = await p.evaluate(() => ({ pageBg: getComputedStyle(document.body).backgroundColor }))
  ok(`(a) ${theme}: a block is not the page colour`, Boolean(s && s.bg !== page.pageBg), { block: s?.bg, page: page.pageBg })

  /* (c) */
  const bar = await p.evaluate(() => ({
    header: Boolean(document.querySelector('[data-test=calendar-page] .feed-header')),
    heading: document.querySelector('[data-test=calendar-heading]')?.getBoundingClientRect().height || 0,
  }))
  ok(`(c) ${theme}: no header bar above the calendar`, !bar.header && bar.heading <= 1, bar)

  /* (d) the group: vertical, at the grid's left, the views then the period */
  const g = await p.evaluate(() => {
    const el = document.querySelector('[data-test=calendar-view-tabs]')
    const grid = document.querySelector('[data-test=calendar-week]')
    const list = el?.querySelector('[role=tablist]')
    const has = (t) => Boolean(el?.querySelector(`[data-test=${t}]`))
    const y = (t) => el?.querySelector(`[data-test=${t}]`)?.getBoundingClientRect().top ?? -1
    const r = el?.getBoundingClientRect()
    return {
      vertical: list?.getAttribute('aria-orientation') === 'vertical',
      left: Boolean(r && grid && r.right <= grid.getBoundingClientRect().left + 1 && r.width <= 120),
      tabs: [...(list?.querySelectorAll('[role=tab]') || [])].map((x) => x.getAttribute('data-test')),
      selected: list?.querySelector('[aria-selected=true]')?.getAttribute('data-test') || '',
      hours: has('calendar-hours-toggle'),
      nav: ['calendar-today', 'calendar-prev', 'calendar-next', 'calendar-range', 'calendar-menu'].filter(has),
      order: y('calendar-view-month') < y('calendar-hours-toggle') && y('calendar-hours-toggle') < y('calendar-today'),
    }
  })
  ok(`(d) ${theme}: a vertical tab group at the grid's left edge`, g.vertical && g.left, g)
  ok(`(d) ${theme}: it holds Day, 3 days, Week, Month (Week selected) and Hours`, g.tabs.join() === 'calendar-view-day,calendar-view-3day,calendar-view-week,calendar-view-month' && g.selected === 'calendar-view-week' && g.hours, g)
  ok(`(d) ${theme}: Today, previous, next, the title and the menu sit under them`, g.nav.length === 5 && g.order, g)
  const plus = await p.evaluate(() => {
    const b = document.querySelector('[data-test=calendar-new]')?.getBoundingClientRect()
    const grid = document.querySelector('[data-test=calendar-week]')?.getBoundingClientRect()
    return b && grid ? { right: Math.round(grid.right - b.right), bottom: Math.round(grid.bottom - b.bottom), round: getComputedStyle(document.querySelector('[data-test=calendar-new]')).borderRadius } : null
  })
  ok(`(d) ${theme}: the + is round at the grid's bottom right`, Boolean(plus && plus.right >= 0 && plus.right <= 40 && plus.bottom >= 0 && plus.bottom <= 40 && plus.round === '50%'), plus)

  /* each view on today's period */
  await p.click(`[data-test=calendar-next]`).catch(() => {})
  await p.click(tab('day')).catch(() => {})
  ok(`(d) ${theme}: Day opens today`, await waitView(p, 'day') && (await cols(p)).join() === today, await cols(p))
  const wd = await window8(p)
  ok(`(b) ${theme}: Day shows 8 hours from 09:00 too`, Boolean(wd && wd.hours >= 7.8 && wd.hours <= 8.3 && Math.abs(wd.top - 540) <= 5), wd)
  await shot(p, `day-${theme}`)
  await p.click(tab('3day')).catch(() => {})
  ok(`(d) ${theme}: 3 days is yesterday, today, tomorrow`, await waitView(p, '3day') && (await cols(p)).join() === [calAddDays(today, -1), today, calAddDays(today, 1)].join(), await cols(p))
  await shot(p, `3day-${theme}`)
  const later = calAddDays(today, 10)
  await p.$eval(`[data-test=calendar-day][data-day="${later}"]`, (el) => el.scrollIntoView({ block: 'center' })).catch(() => {})
  await p.click(`[data-test=calendar-day][data-day="${later}"]`).catch(() => {})
  await p.waitForFunction((d) => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-day') === d, { timeout: 8000 }, later).catch(() => {})
  ok(`(d) ${theme}: a day picked in the strip is the middle of 3 days`, (await cols(p)).join() === [calAddDays(later, -1), later, calAddDays(later, 1)].join() && (await view(p)) === '3day', await cols(p))
  await p.click(tab('month')).catch(() => {})
  const month = await waitView(p, 'month') && await p.$eval('[data-test=calendar-month-grid]', (el, d) => ({ cells: el.querySelectorAll('[data-test=calendar-month-cell]').length, today: Boolean(el.querySelector(`[data-test=calendar-month-cell][data-day="${d}"][aria-current=date]`)) }), today).catch((e) => String(e))
  ok(`(d) ${theme}: Month opens this month (42 days, today marked)`, Boolean(month && month.cells === 42 && month.today), month)
  ok(`(d) ${theme}: the month shows today's events`, Boolean(await p.$('[data-test=calendar-month-grid] [data-test=calendar-item][data-id="spl4060-short"]')))
  await shot(p, `month-${theme}`)
  await p.click(`[data-test=calendar-month-cell][data-day="${today}"] [data-test=calendar-month-day]`).catch(() => {})
  ok(`(d) ${theme}: a day number in the month opens that day`, await waitView(p, 'day') && (await cols(p)).join() === today, await cols(p))
  await p.click(tab('week')).catch(() => {})
  ok(`(d) ${theme}: Week opens this week`, await waitView(p, 'week') && (await cols(p))[0] === calWeekStart(today), await cols(p))

  /* Hours opens and closes the hours panel */
  const panel = async () => Boolean(await p.$('[data-test=hours-panel]'))
  const was = await panel()
  await p.click('[data-test=calendar-hours-toggle]').catch(() => {})
  await new Promise((r) => setTimeout(r, 400))
  const now = await panel()
  await p.click('[data-test=calendar-hours-toggle]').catch(() => {})
  await new Promise((r) => setTimeout(r, 400))
  ok(`(d) ${theme}: Hours toggles the hours panel`, was !== now && (await panel()) === was, { was, now })
  ok(`${theme}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) await run(browser, server.base, theme)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-desk-views: ${failed} FAILED` : `calendar-desk-views: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
