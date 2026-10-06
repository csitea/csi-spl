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
// 360x780 and 390x844, a finger (phone acceptance, spec 5.1.1):
//   - a tap opens the event; a swipe without a hold moves nothing
//   - a hold of 250 ms or more, then a drag, moves the event; the page does
//     not scroll meanwhile
//   - the held event shows a bottom resize handle of at least 44 x 44 px
//     that drags a new end
//   - a hold and a drag on an empty slot opens a new event for that span
//   - the Week list moves a held event to another day
//   - the edit_conflict notice is in view, not cut at the sides
//   - the document never scrolls sideways
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
const scroller = (p) => p.evaluate(() => ({ top: document.querySelector('[data-test=calendar-week]')?.scrollTop ?? -1, win: window.scrollY }))
/* the scroller once a fling has stopped: the same for half a second, and a
   touch during a fling only stops it (a phone does the same) */
async function settled(p) {
  let last = await scroller(p)
  let same = 0
  for (let i = 0; i < 60 && same < 5; i++) {
    await sleep(100)
    const now = await scroller(p)
    same = now.top === last.top ? same + 1 : 0
    last = now
  }
  return last
}
const dialog = (p) => p.waitForSelector(DIALOG, { visible: true, timeout: 8000 }).then(() => true, () => false)
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

/* a finger: down, hold `hold` ms, move to `to` in steps, up */
async function touchDrag(cdp, from, to, hold) {
  const pt = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(from.x, from.y) })
  await sleep(hold)
  const steps = 10
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(300)
}
async function tap(cdp, at) {
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: Math.round(at.x), y: Math.round(at.y), id: 1 }] })
  await sleep(40)
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(300)
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
  ok('a click without a drag opens the event', await dialog(a) && (await form(a)).mode === 'edit')
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

  for (const vp of [{ width: 360, height: 780 }, { width: 390, height: 844 }]) {
    const w = vp.width
    console.log(`-- ${w}x${vp.height}, touch`)
    const pctx = await browser.createBrowserContext()
    const p = await pctx.newPage()
    const id = `00000000-0000-4000-8000-0000000d0${w}`
    await open(p, { ...vp, isMobile: true, hasTouch: true }, [event(id, 'Hold me', today, '10:00', '11:00')])
    const cdp = await p.createCDPSession()
    ok(`${w}: the Day view is a time grid`, (await p.$$('[data-test=calendar-grid]')).length === 1)

    /* a tap opens the event */
    it = await item(p, 'Hold me')
    if (it) await tap(cdp, { x: it.cx, y: it.y + 10 })
    ok(`${w}: a tap opens the event`, await dialog(p) && (await form(p)).mode === 'edit')
    await closeDialog(p)

    /* a swipe without a hold moves nothing */
    it = await item(p, 'Hold me')
    const s0 = await scroller(p)
    if (it) await touchDrag(cdp, { x: it.cx, y: it.y + 10 }, { x: it.cx, y: it.y + 10 - 120 }, 0)
    const s1 = await settled(p)
    it = await item(p, 'Hold me')
    ok(`${w}: a swipe without a hold moves no event`, Date.parse(it?.starts) === Date.parse(iso(today, '10:00')) && !(await p.$(DIALOG)), it)
    ok(`${w}: the swipe scrolls the day`, s1.top !== s0.top, { s0, s1 })

    /* hold 300 ms, drag one hour down. The swipe may have carried the event
       under the sticky day head: bring it back to the middle first, as a
       person would (wf 10 red on d1693452: the hold landed on the head) */
    await p.evaluate((t) => [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)?.scrollIntoView({ block: 'center' }), 'Hold me')
    await settled(p)
    it = await item(p, 'Hold me')
    let g = await gridAt(p, today, 0)
    const sBefore = await scroller(p)
    if (it && g) await touchDrag(cdp, { x: it.cx, y: it.y + 10 }, { x: it.cx, y: it.y + 10 + g.hourPx }, 300)
    const sAfter = await scroller(p)
    ok(`${w}: hold >= 250 ms then drag moves it one hour (11:00)`, await waitStarts(p, 'Hold me', iso(today, '11:00')), await item(p, 'Hold me'))
    ok(`${w}: the page and the day did not scroll during the drag`, sAfter.top === sBefore.top && sAfter.win === sBefore.win, { sBefore, sAfter })
    ok(`${w}: the move is stored`, Date.parse((await stored(p, id))?.starts_at) === Date.parse(iso(today, '11:00')))

    /* the held event shows its resize handle: >= 44 x 44, drags a new end */
    const handle = await p.$eval('[data-test=calendar-item-resize]', (el) => {
      const r = el.getBoundingClientRect()
      return { w: Math.round(r.width), h: Math.round(r.height), x: r.left + r.width / 2, y: r.top + r.height / 2 }
    }).catch(() => null)
    ok(`${w}: the held event shows a resize handle >= 44 x 44 px`, Boolean(handle && handle.w >= 44 && handle.h >= 44), handle)
    await shot(p, `${w}-held`)
    g = await gridAt(p, today, 0)
    if (handle && g) await touchDrag(cdp, handle, { x: handle.x, y: handle.y + g.hourPx / 2 }, 0)
    it = await item(p, 'Hold me')
    ok(`${w}: the handle drags a new end (11:00-12:30)`, Date.parse(it?.ends) === Date.parse(iso(today, '12:30')) && Date.parse(it?.starts) === Date.parse(iso(today, '11:00')), it)

    /* hold on an empty slot (15:00) and drag to 16:30: a new event for that span */
    const e0 = await gridAt(p, today, 15 * 60 + 5)
    const e1 = await gridAt(p, today, 16 * 60 + 30)
    await p.evaluate((y) => { const s = document.querySelector('[data-test=calendar-week]'); const r = s.getBoundingClientRect(); s.scrollTop += y - r.top - r.height / 3 }, e0?.y ?? 0)
    const e0b = await gridAt(p, today, 15 * 60 + 5)
    const e1b = await gridAt(p, today, 16 * 60 + 30)
    if (e0 && e1 && e0b && e1b) await touchDrag(cdp, e0b, e1b, 300)
    ok(`${w}: a hold and a drag on an empty slot opens a new event`, await dialog(p))
    f = await form(p)
    ok(`${w}: for that span (15:00-16:30)`, f.mode === 'create' && f.date === today && f.start === '15:00' && f.end === '16:30', f)
    await shot(p, `${w}-create`)
    await closeDialog(p)
    ok(`${w}: no sideways scroll in Day`, (await xScroll(p)) <= 1, await xScroll(p))

    /* the Week list: a held event moves to the next day, its clock stays */
    await p.click('[data-test=calendar-view-week]')
    await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-view') === 'week', { timeout: 5000 }).catch(() => {})
    await sleep(200)
    const next = week[week.indexOf(today) + 1] || week[week.indexOf(today) - 1]
    await p.$eval(`[data-test=calendar-week-day][data-day="${today}"]`, (el) => el.scrollIntoView({ block: 'start' }))
    it = await item(p, 'Hold me')
    const target = await p.$eval(`[data-test=calendar-week-day][data-day="${next}"]`, (el) => { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + Math.min(r.height / 2, 30) } }).catch(() => null)
    if (it && target) await touchDrag(cdp, { x: it.cx, y: it.cy }, target, 300)
    it = await item(p, 'Hold me')
    ok(`${w}: in the Week list a held event moves to ${next}, 11:00 kept`, it?.day === next && Date.parse(it.starts) === Date.parse(iso(next, '11:00')), it)
    ok(`${w}: the Week move is stored`, Date.parse((await stored(p, id))?.starts_at) === Date.parse(iso(next, '11:00')), await stored(p, id))
    ok(`${w}: no sideways scroll in Week`, (await xScroll(p)) <= 1, await xScroll(p))
    await shot(p, `${w}-week`)

    /* a stale tab: edit_conflict shows in view, not clipped */
    await p.click('[data-test=calendar-view-day]')
    await p.evaluate((k, i, d) => {
      const list = JSON.parse(localStorage.getItem(k) || '[]')
      const ev = list.find((e) => e.id === i)
      Object.assign(ev, { starts_at: `${d}T10:00:00Z`, ends_at: `${d}T11:00:00Z`, updated_at: new Date().toISOString() })
      localStorage.setItem(k, JSON.stringify(list))
    }, ADDED, id, next)
    await p.click(next > today ? '[data-test=calendar-next]' : '[data-test=calendar-prev]')
    await p.waitForFunction((d) => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-day') === d, { timeout: 5000 }, next).catch(() => {})
    await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: 5000 }).catch(() => {})
    await sleep(200)
    /* the view read 10:00; another tab saves 13:00 behind its back */
    await p.evaluate((k, i, d) => {
      const list = JSON.parse(localStorage.getItem(k) || '[]')
      Object.assign(list.find((e) => e.id === i), { starts_at: `${d}T13:00:00Z`, ends_at: `${d}T14:00:00Z`, updated_at: new Date(Date.now() + 1000).toISOString() })
      localStorage.setItem(k, JSON.stringify(list))
    }, ADDED, id, next)
    it = await item(p, 'Hold me')
    g = await gridAt(p, next, 0)
    if (it && g) await touchDrag(cdp, { x: it.cx, y: it.y + 10 }, { x: it.cx, y: it.y + 10 + g.hourPx }, 300)
    const toast = await p.waitForSelector('[data-test=calendar-notice]', { visible: true, timeout: 8000 }).then(() => p.$eval('[data-test=calendar-notice]', (el) => {
      const r = el.getBoundingClientRect()
      return { key: el.getAttribute('data-key'), left: r.left, right: r.right, top: r.top, bottom: r.bottom, iw: window.innerWidth, ih: window.innerHeight, sw: el.scrollWidth, cw: el.clientWidth }
    }), () => null)
    ok(`${w}: edit_conflict shows in view, not cut at the sides`, Boolean(toast && toast.key === 'calendar_event.drag_conflict' && toast.left >= 0 && toast.right <= toast.iw && toast.top >= 0 && toast.bottom <= toast.ih && toast.sw <= toast.cw + 1), toast)
    ok(`${w}: the other tab's change is shown (13:00)`, await waitStarts(p, 'Hold me', iso(next, '13:00')), await item(p, 'Hold me'))
    ok(`${w}: no sideways scroll with the notice`, (await xScroll(p)) <= 1, await xScroll(p))
    await shot(p, `${w}-conflict`)
    await pctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-drag: ${failed} FAILED` : `calendar-drag: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
