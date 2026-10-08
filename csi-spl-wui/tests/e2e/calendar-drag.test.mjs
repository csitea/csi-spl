// spec 097 T013 (G1, spec 5.1.1): drag to move, drag the bottom edge to
// resize, drag on empty time to create, every save under If-Match.
//
// 1440x900, a mouse:
//   - the week is a time grid; an event drags to another day and time and
//     keeps its length; its bottom edge drags to a new end
//   - a drag on empty time opens the new-event dialog for that span
//   - a click (no drag) still opens the event
//   - TWO TABS drag the same event: the second tab read it before the first
//     saved, so its PATCH carries a stale If-Match; it gets 409
//     edit_conflict, says so in the view and shows the first tab's change;
//     the stored event is the first tab's
// The phone (<= 820 px) part ran on 089 T009's Day / Week here; spec 106
// T011 retired that layout. Phone hold-drag and edit_conflict are checked
// on the new Day view in calendar-phone-day.test.mjs.
// The mock workspace keeps its events in localStorage, which both tabs share
// (src/utils/calendar-mock.mjs); its PATCH checks If-Match as the hub does.
// Times are UTC: every page runs in the UTC zone.
//
// Control: before T013 there is no [data-test=calendar-grid], a drag moves
// nothing and a stale save is not refused, so the checks below FAIL.
//
// Run:
//   pnpm run test:e2e calendar-drag
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-drag
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay, calWeekDays } from '../../src/utils/calendar-year.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-drag-${name}.png`) })
}

const today = calIsoDay(Date.now())
const week = calWeekDays(today)
const other = week.find((d) => d !== today) || today
const ADDED = 'spool.mock.calendar-added'
const DIALOG = '[data-test=calendar-event-form]'
const STAMP = '2026-01-01T00:00:00Z'
const event = (id, title, day, from, to) => ({
  id, source: 'event', title, description: '', kind: 'other', starts_at: `${day}T${from}:00Z`, ends_at: `${day}T${to}:00Z`,
  all_day: false, audience: 'public', mentions: [], creator_type: 'human', creator_id: 'HUM-1', remind_at: '', topic_id: '',
  release_version: '', issue_key: '', created_at: STAMP, updated_at: STAMP,
})

async function open(p, vp, events) {
  await p.emulateTimezone('UTC')
  await setPageViewport(p, vp)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  if (events) {
    await p.evaluate((k, v) => { localStorage.setItem(k, v); localStorage.removeItem('spool.mock.calendar-hidden') }, ADDED, JSON.stringify(events))
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  }
  await applyViewport(p, vp)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  await sleep(150)
}

/* an item's box, times and day, by title */
const item = (p, title) => p.evaluate((t) => {
  const el = [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)
  if (!el) return null
  const r = el.getBoundingClientRect()
  return {
    id: el.getAttribute('data-id'), starts: el.getAttribute('data-starts'), ends: el.getAttribute('data-ends'),
    day: el.closest('[data-test=calendar-week-day]')?.getAttribute('data-day'),
    x: r.left, y: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2,
  }
}, title)
const stored = (p, id) => p.evaluate((k, i) => {
  try { return (JSON.parse(localStorage.getItem(k) || '[]').find((e) => e.id === i)) || null } catch { return null }
}, ADDED, id)
const waitStarts = (p, title, want) => p.waitForFunction((t, w) => {
  const el = [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)
  return el && Date.parse(el.getAttribute('data-starts')) === Date.parse(w)
}, { timeout: 8000 }, title, want).then(() => true, () => false)
/* the y of minute `min` on `day`'s grid, and its x middle */
const gridAt = (p, day, min) => p.evaluate((d, m) => {
  const g = document.querySelector(`[data-grid-day="${d}"]`)
  if (!g) return null
  const r = g.getBoundingClientRect()
  return { x: r.left + r.width / 2, y: r.top + (m / 1440) * r.height, hourPx: r.height / 24 }
}, day, min)
const dialog = (p) => p.waitForSelector(DIALOG, { visible: true, timeout: 8000 }).then(() => true, () => false)
/* 097 T014: a click shows the event's pop-over; its Edit opens the dialog */
async function viaPopover(p) {
  const edit = await p.waitForSelector('[data-test=calendar-popover-edit]', { visible: true, timeout: 8000 }).catch(() => null)
  if (!edit) return false
  await edit.click()
  return dialog(p)
}
const form = (p) => p.evaluate(() => ({
  mode: document.querySelector('[data-test=calendar-event-form]')?.getAttribute('data-mode') || '',
  date: document.querySelector('[data-test=calendar-event-date]')?.value || '',
  start: document.querySelector('[data-test=calendar-event-start]')?.value || '',
  end: document.querySelector('[data-test=calendar-event-end]')?.value || '',
}))
async function closeDialog(p) {
  await p.keyboard.press('Escape')
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 8000 }, DIALOG).catch(() => {})
}
const xScroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)

async function mouseDrag(p, from, to) {
  await p.mouse.move(from.x, from.y)
  await p.mouse.down()
  const steps = 8
  for (let i = 1; i <= steps; i++) await p.mouse.move(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps)
  await p.mouse.up()
  await sleep(250)
}

const iso = (day, hhmm) => `${day}T${hhmm}:00Z`
const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1440x900, mouse')
  const ctx = await browser.createBrowserContext()
  const a = await ctx.newPage()
  const seed = [event('00000000-0000-4000-8000-0000000d0001', 'Drag me', today, '10:00', '11:00')]
  await open(a, { width: 1440, height: 900 }, seed)
  ok('the week is a time grid: seven day grids', (await a.$$('[data-test=calendar-grid]')).length === 7)
  let it = await item(a, 'Drag me')
  ok('the event sits on its day', it?.day === today, it)

  /* move: grab its middle (10:30) and drop at 14:30 on another day -> 14:00-15:00 */
  let to = await gridAt(a, other, 14 * 60 + 30)
  if (it && to) await mouseDrag(a, { x: it.cx, y: it.cy }, to)
  ok('a drag moves it to the other day at 14:00', await waitStarts(a, 'Drag me', iso(other, '14:00')), await item(a, 'Drag me'))
  it = await item(a, 'Drag me')
  ok('it keeps its length (one hour)', it && Date.parse(it.ends) - Date.parse(it.starts) === 3600000 && it.day === other, it)
  ok('the move is stored', Date.parse((await stored(a, seed[0].id))?.starts_at) === Date.parse(iso(other, '14:00')), await stored(a, seed[0].id))
  ok('a drag opens no dialog', !(await a.$(DIALOG)))

  /* resize: its bottom edge to 16:30 */
  it = await item(a, 'Drag me')
  to = await gridAt(a, other, 16 * 60 + 30)
  if (it && to) await mouseDrag(a, { x: it.cx, y: it.y + it.h - 2 }, { x: it.cx, y: to.y })
  await sleep(300)
  it = await item(a, 'Drag me')
  ok('the bottom edge drags a new end: 14:00-16:30', it && Date.parse(it.ends) === Date.parse(iso(other, '16:30')) && Date.parse(it.starts) === Date.parse(iso(other, '14:00')), it)
  ok('the new end is stored', Date.parse((await stored(a, seed[0].id))?.ends_at) === Date.parse(iso(other, '16:30')))

  /* create: drag on empty time 18:00 -> 19:30 */
  const c0 = await gridAt(a, today, 18 * 60 + 5)
  const c1 = await gridAt(a, today, 19 * 60 + 30)
  if (c0 && c1) await mouseDrag(a, c0, c1)
  ok('a drag on empty time opens the new-event dialog', await dialog(a))
  let f = await form(a)
  ok('for that day and span (18:00-19:30)', f.mode === 'create' && f.date === today && f.start === '18:00' && f.end === '19:30', f)
  await shot(a, '1440-create')
  await closeDialog(a)

  /* a click is still a click */
  it = await item(a, 'Drag me')
  if (it) await a.mouse.click(it.cx, it.y + 8)
  ok('a click without a drag opens the event', await viaPopover(a) && (await form(a)).mode === 'edit')
  await closeDialog(a)
  await shot(a, '1440-week')
  ok('1440: no sideways scroll', (await xScroll(a)) <= 1, await xScroll(a))

  /* two tabs: B reads the event, A moves it, then B drags its stale copy */
  const b = await ctx.newPage()
  await open(b, { width: 1440, height: 900 })
  const before = await item(b, 'Drag me')
  ok('tab B shows the event as stored', Date.parse(before?.starts) === Date.parse(iso(other, '14:00')), before)
  await a.bringToFront()
  it = await item(a, 'Drag me')
  /* grabbed 6 px (7.5 min) below its top, dropped at 09:07 -> 09:00 */
  to = await gridAt(a, other, 9 * 60 + 7)
  if (it && to) await mouseDrag(a, { x: it.cx, y: it.y + 6 }, to)
  ok('tab A moves it to 09:00', await waitStarts(a, 'Drag me', iso(other, '09:00')), await item(a, 'Drag me'))
  await b.bringToFront()
  it = await item(b, 'Drag me')
  ok('CONTROL tab B still shows its stale copy (14:00)', Date.parse(it?.starts) === Date.parse(iso(other, '14:00')), it)
  to = await gridAt(b, other, 20 * 60 + 15)
  if (it && to) await mouseDrag(b, { x: it.cx, y: it.y + 6 }, to)
  const note = await b.waitForSelector('[data-test=calendar-notice]', { visible: true, timeout: 8000 }).then(() => b.$eval('[data-test=calendar-notice]', (el) => ({ key: el.getAttribute('data-key'), text: el.textContent?.trim() })), () => null)
  ok('tab B: edit_conflict is said in the view', note?.key === 'calendar_event.drag_conflict' && Boolean(note.text), note)
  ok('tab B: it now shows tab A\'s change (09:00)', await waitStarts(b, 'Drag me', iso(other, '09:00')), await item(b, 'Drag me'))
  ok('the stored event is tab A\'s, not overwritten', Date.parse((await stored(b, seed[0].id))?.starts_at) === Date.parse(iso(other, '09:00')), await stored(b, seed[0].id))
  await shot(b, '1440-conflict')
  await ctx.close()

} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-drag: ${failed} FAILED` : `calendar-drag: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
