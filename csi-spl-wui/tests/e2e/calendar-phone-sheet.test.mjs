// spec 106 T008: the phone calendar's add / edit sheet (CalendarPhoneSheet.vue).
//
// At 360x780, 390x844 and 820x1180, dark and light, font levels 1, 3 and 5,
// on both screens the sheet opens (quick, then More = full height):
//   H3  no sideways scroll: documentElement scrollWidth - clientWidth <= 1,
//       nothing in the sheet wider than its box, scrollLeft == 0
//   H7  every control and field >= 44x44; at level 3 the header controls
//       and chips <= 48 px tall
//   H8  the sheet's header is one row (<= 48 px at level 3 under the grab
//       bar), and the shell's view behind it is >= 82 % of the page
// Once per width (level 3, dark):
//   S2-1 Save is visible and clickable with a 300 px virtual keyboard up
//       (the keyboard covers the bottom 300 px; and with the page resized
//       by it), so + and Save add an event in 2 taps after typing
//   S4-2 role=dialog aria-modal, the title focused, focus back on the +
//   ISO date and the 24-hour clock on the chips (21:30, not 9:30 PM)
//   FR-007 More shows 097's fields in 097's order; drag-down closes only
//       from the header, or from the body at scrollTop 0; overscroll
//       contained; Back closes the sheet and keeps the calendar
//   AC-04 a new event at a tapped 14:00 is stored 14:00-15:00 on that day
//   edit in 3 taps: (event, Edit,) Save - the edit opens full height on the
//       event; Delete at the bottom start, its confirm does not move Save
//   reduced motion: no sheet slide
// The tapped hour (T007's Day) and Edit (T009's peek) open the sheet through
// the shell's inject('calphone-sheet'); until those land, this test calls
// that same opener, found on the CalendarPhone instance.
//
// Controls: before T008 the + opens no [data-test=calphone-sheet], so every
// check FAILs; in-run, a planted 2000 px scroller in the sheet must trip the
// H3 detector and a planted 30 px button the H7 one.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-sheet
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calIsoDay } from '../../src/utils/calendar-year.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-sheet-${name}.png`) })
}

const ZONE = 'Europe/Helsinki'
const today = calIsoDay(Date.now())
const ROOT = '[data-test=calendar-phone]'
const SHEET = '[data-test=calphone-sheet]'
const ADDED_KEY = 'spool.mock.calendar-added'
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/

/** a fresh page: the theme and the font level in localStorage first */
async function open(browser, vp, { theme = 'dark', level = 3 } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.emulateTimezone(ZONE)
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calphone-seeded')) return
      sessionStorage.setItem('calphone-seeded', '1')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
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

const sheetUp = (p) => p.waitForSelector(SHEET, { visible: true, timeout: 8000 }).then(() => sleep(300)).then(() => true, () => false)
const sheetGone = (p) => p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, SHEET).then(() => true, () => false)
const attr = (p, sel, n) => p.$eval(sel, (el, a) => el.getAttribute(a), n).catch(() => null)
const level = (p) => p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '')
const added = (p) => p.evaluate((k) => { try { return JSON.parse(localStorage.getItem(k) || '[]') } catch { return [] } }, ADDED_KEY)

/** + : the add sheet at the next full hour */
async function tapAdd(p) {
  await p.click(`${ROOT} [data-test=calphone-add]`)
  return sheetUp(p)
}

/* the shell's opener, as T007 (a tapped hour) and T009 (Edit) call it:
   inject('calphone-sheet') on the CalendarPhone instance, reached from the
   app's root vnode (the production build keeps no devtools hook) */
async function openVia(p, arg) {
  const found = await p.evaluate((a) => {
    const seen = new Set()
    const stack = [document.querySelector('#__nuxt')?._vnode]
    while (stack.length) {
      const v = stack.pop()
      if (!v || typeof v !== 'object' || seen.has(v)) continue
      seen.add(v)
      const c = v.component
      if (c) {
        if (c.provides && Object.hasOwn(c.provides, 'calphone-sheet')) {
          c.provides['calphone-sheet'](a)
          return true
        }
        stack.push(c.subTree)
      }
      if (v.suspense) stack.push(v.suspense.activeBranch)
      if (Array.isArray(v.children)) stack.push(...v.children)
    }
    return false
  }, arg)
  return found && sheetUp(p)
}

/* H3: the document and everything in the sheet */
async function sideways(p) {
  return p.evaluate((s) => {
    const root = document.querySelector(s)
    const wide = []
    for (const el of root ? [root, ...root.querySelectorAll('*')] : []) {
      const ox = getComputedStyle(el).overflowX
      if ((ox === 'auto' || ox === 'scroll' || ox === 'hidden') && el.scrollWidth > el.clientWidth + 1 && el.tagName !== 'SELECT' && el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA' && !el.matches('.calsheet__btn, .calsheet__heading')) wide.push(el.className || el.tagName)
      if (el.scrollLeft !== 0) wide.push(`scrollLeft ${el.className || el.tagName}`)
      const b = el.getBoundingClientRect()
      if (b.width && (b.right > window.innerWidth + 1 || b.left < -1)) wide.push(`out ${el.className || el.tagName}`)
    }
    return { doc: document.documentElement.scrollWidth - document.documentElement.clientWidth, docLeft: document.scrollingElement?.scrollLeft || 0, wide: wide.slice(0, 6) }
  }, SHEET)
}
const flatOk = (s) => s.doc <= 1 && s.docLeft === 0 && s.wide.length === 0

/* the boxes H7 / H8 read */
async function boxes(p) {
  return p.evaluate((s, r) => {
    const box = (el) => {
      if (!el) return null
      const b = el.getBoundingClientRect()
      return { x: Math.round(b.left), y: Math.round(b.top), w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }
    }
    const sheet = document.querySelector(s)
    const id = (el) => el.getAttribute('data-test') || el.className || el.tagName
    const sel = 'button, select, textarea, input:not([type=checkbox]):not([type=radio]):not(.calsheet__native), .calsheet__chip, .calsheet__switch, .calsheet__swatch'
    const targets = sheet ? [...sheet.querySelectorAll(sel)].filter((el) => el.offsetParent !== null).map((el) => ({ id: id(el), ...box(el) })) : []
    const head = [...(sheet?.querySelectorAll('[data-test=calphone-sheet-head] button, .calsheet__chip, .calsheet__switch, [data-test=calphone-sheet-more]') || [])]
      .filter((el) => el.offsetParent !== null).map((el) => ({ id: id(el), ...box(el) }))
    const bar = sheet?.querySelector('.calsheet__bar')
    const kids = bar ? [...bar.children].map((el) => box(el)) : []
    const dock = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h')) || 0
    const pg = box(document.querySelector('[data-test=calendar-page]'))
    if (pg) pg.h = Math.min(pg.y + pg.h, window.innerHeight - dock) - pg.y
    return {
      sheet: box(sheet),
      bar: box(bar),
      barRows: kids.length ? Math.max(...kids.map((k) => k.y + k.h / 2)) - Math.min(...kids.map((k) => k.y + k.h / 2)) : -1,
      targets,
      head,
      save: box(sheet?.querySelector('[data-test=calphone-sheet-save]')),
      page: pg,
      view: box(document.querySelector(`${r} [data-test=calphone-view]`)),
    }
  }, SHEET, ROOT)
}
const tapSize = (c) => c.w >= 43.5 && c.h >= 43.5

async function layoutChecks(p, tag, vp, lvl) {
  const s = await sideways(p)
  ok(`H3 ${tag}: no sideways scroll`, flatOk(s), s)
  const b = await boxes(p)
  const small = b.targets.filter((c) => !tapSize(c))
  ok(`H7 ${tag}: every control and field >= 44x44`, small.length === 0 && b.targets.length >= 6, small.length ? small : b.targets.length)
  ok(`H8 ${tag}: the sheet header is one row`, b.barRows >= 0 && b.barRows <= 4, b.barRows)
  ok(`H3 ${tag}: the sheet fits the width`, Boolean(b.sheet && b.sheet.w <= vp.width + 0.5), b.sheet)
  if (lvl === 3) {
    const tall = b.head.filter((c) => c.h > 48.5)
    ok(`H7 ${tag}: header controls and chips <= 48 px tall at level 3`, tall.length === 0 && b.head.length >= 4, tall.length ? tall : b.head.length)
    ok(`H8 ${tag}: the sheet header <= 48 px`, Boolean(b.bar && b.bar.h <= 48.5), b.bar)
    const share = b.page && b.view ? b.view.h / b.page.h : 0
    ok(`H8 ${tag}: the view behind the sheet is >= 82 % of the page`, share >= 0.82, { share: Math.round(share * 1000) / 10 })
  }
  return b
}

/* a finger: down at `from`, moves to `to`, up */
async function touchDrag(p, from, to, steps = 10) {
  const cdp = await p.createCDPSession()
  const pt = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(from.x, from.y) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(300)
}

/* the wall clock of an instant in a zone, `YYYY-MM-DD HH:MM` */
function wallIn(iso, zone) {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
  const o = Object.fromEntries(f.formatToParts(new Date(iso)).map((x) => [x.type, x.value]))
  return `${o.year}-${o.month}-${o.day} ${o.hour}:${o.minute}`
}

/* set a native date / time input as the phone's picker would */
async function setNative(p, testid, value) {
  await p.$eval(`${SHEET} [data-test=${testid}]`, (el, v) => {
    el.value = v
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  }, value)
  await sleep(100)
}

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }, { width: 820, height: 1180 }]
try {
  /* ---- the matrix: H3 / H7 / H8 on the quick and the full sheet ---- */
  for (const vp of PHONES) {
    for (const theme of ['dark', 'light']) {
      for (const lvl of [1, 3, 5]) {
        const tag = `${vp.width} ${theme} L${lvl}`
        console.log(`-- ${tag}`)
        const { p, ctx } = await open(browser, vp, { theme, level: lvl })
        ok(`${tag}: + opens the sheet`, await tapAdd(p))
        ok(`${tag}: it opens quick (half height)`, (await attr(p, SHEET, 'data-full')) === 'false')
        await layoutChecks(p, `${tag} quick`, vp, lvl)
        if (vp.width === 390 && lvl === 3) await shot(p, `${vp.width}-${theme}-quick`)
        await p.click(`${SHEET} [data-test=calphone-sheet-more]`)
        ok(`${tag}: More grows it to full height`, await p.waitForFunction((s) => document.querySelector(s)?.getAttribute('data-full') === 'true', { timeout: 3000 }, SHEET).then(() => true, () => false))
        await sleep(200)
        await layoutChecks(p, `${tag} full`, vp, lvl)
        if (vp.width === 390 && lvl === 3) await shot(p, `${vp.width}-${theme}-full`)
        await ctx.close()
      }
    }
  }

  /* ---- the interactions, once per width (level 3, dark) ---- */
  for (const vp of PHONES) {
    const w = vp.width
    console.log(`-- ${w}x${vp.height} interactions`)
    const { p, ctx } = await open(browser, vp)

    /* S4-2: a modal dialog, the title focused */
    ok(`${w}: + opens the sheet`, await tapAdd(p))
    const a11y = await p.evaluate((s) => {
      const el = document.querySelector(s)
      const head = document.getElementById(el?.getAttribute('aria-labelledby') || '')
      return { role: el?.getAttribute('role'), modal: el?.getAttribute('aria-modal'), label: head?.textContent?.trim() || '', focus: document.activeElement?.getAttribute('data-test') || '' }
    }, SHEET)
    ok(`S4-2 ${w}: role=dialog aria-modal, labelled, the title focused`, a11y.role === 'dialog' && a11y.modal === 'true' && a11y.label !== '' && a11y.focus === 'calphone-sheet-title', a11y)
    const contain = await p.evaluate((s) => [s, `${s} [data-test=calphone-sheet-body]`].map((q) => getComputedStyle(document.querySelector(q)).overscrollBehaviorY), SHEET)
    ok(`FR-007 ${w}: overscroll contained on the sheet and its body`, contain.every((x) => x === 'contain'), contain)

    /* ISO date, 24-hour clock; the preset is the next full hour, one hour long */
    const chips = await p.evaluate((s) => ['date', 'start', 'end'].map((k) => document.querySelector(`${s} [data-test=calphone-sheet-${k}]`)?.textContent?.trim() || ''), SHEET)
    const hour = Number(chips[1].slice(0, 2))
    ok(`${w}: the chips read an ISO date and a 24-hour clock`, ISO_DAY.test(chips[0]) && HHMM.test(chips[1]) && HHMM.test(chips[2]) && chips[1].endsWith(':00'), chips)
    ok(`${w}: + presets the next full hour, one hour long`, chips[2] === `${String((hour + 1) % 24).padStart(2, '0')}:00`, chips)
    await setNative(p, 'calphone-sheet-start-input', '21:30')
    const late = await p.$eval(`${SHEET} [data-test=calphone-sheet-start]`, (el) => el.textContent.trim())
    ok(`${w}: 21:30 shows as 21:30, not 9:30 PM`, late === '21:30', late)
    await setNative(p, 'calphone-sheet-start-input', `${String(hour).padStart(2, '0')}:00`)

    /* S2-1: a 300 px keyboard covers the bottom - Save stays above it */
    await p.type(`${SHEET} [data-test=calphone-sheet-title]`, `Dentist ${w}`)
    let b = await boxes(p)
    ok(`S2-1 ${w}: Save sits above a 300 px keyboard`, Boolean(b.save && b.save.y + b.save.h <= vp.height - 300), { save: b.save, kbTop: vp.height - 300 })
    await setPageViewport(p, { ...vp, height: vp.height - 300, hasTouch: true })
    await sleep(300)
    b = await boxes(p)
    const hit = await p.evaluate((s) => {
      const el = document.querySelector(`${s} [data-test=calphone-sheet-save]`)
      const r = el.getBoundingClientRect()
      const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
      return { inView: r.top >= 0 && r.bottom <= window.innerHeight, hit: Boolean(at && el.contains(at)), disabled: el.disabled }
    }, SHEET)
    ok(`S2-1 ${w}: with the page resized by the keyboard, Save is on screen and clickable`, hit.inView && hit.hit && !hit.disabled, hit)
    const before = (await added(p)).length
    await p.click(`${SHEET} [data-test=calphone-sheet-save]`)
    ok(`S2-1 ${w}: add in 2 taps after typing (+, Save)`, await sheetGone(p))
    const list = await added(p)
    const dentist = list.find((e) => e.title === `Dentist ${w}`)
    ok(`${w}: the event is stored at the preset hour`, list.length === before + 1 && Boolean(dentist) && wallIn(dentist.starts_at, ZONE).endsWith(` ${String(hour).padStart(2, '0')}:00`), dentist && { starts: dentist.starts_at, wall: wallIn(dentist.starts_at, ZONE) })
    const focusBack = await p.evaluate(() => document.activeElement?.getAttribute('data-test') || '')
    ok(`S4-2 ${w}: focus returns to the +`, focusBack === 'calphone-add', focusBack)
    await setPageViewport(p, { ...vp, hasTouch: true })
    await sleep(300)

    /* AC-04: the tapped 14:00 */
    ok(`AC-04 ${w}: a tapped 14:00 opens the sheet`, await openVia(p, { day: today, hour: 14 }))
    const at14 = await p.evaluate((s) => ['date', 'start', 'end'].map((k) => document.querySelector(`${s} [data-test=calphone-sheet-${k}]`)?.textContent?.trim() || ''), SHEET)
    ok(`AC-04 ${w}: the chips read that day, 14:00 - 15:00`, at14[0] === today && at14[1] === '14:00' && at14[2] === '15:00', at14)
    await p.type(`${SHEET} [data-test=calphone-sheet-title]`, `AC-04 ${w}`)
    await p.click(`${SHEET} [data-test=calphone-sheet-save]`)
    await sheetGone(p)
    const ac = (await added(p)).find((e) => e.title === `AC-04 ${w}`)
    ok(`AC-04 ${w}: stored at 14:00-15:00 on that day`, Boolean(ac) && wallIn(ac.starts_at, ac.time_zone) === `${today} 14:00` && wallIn(ac.ends_at, ac.time_zone) === `${today} 15:00` && ac.time_zone === ZONE, ac && { s: ac.starts_at, e: ac.ends_at, zone: ac.time_zone })

    /* edit: full height on the event, Save is the one tap after Edit */
    ok(`${w}: Edit opens the sheet on the event`, Boolean(ac) && await openVia(p, { event: ac }))
    const ed = await p.evaluate((s) => {
      const el = document.querySelector(s)
      return { mode: el?.getAttribute('data-mode'), full: el?.getAttribute('data-full'), title: el?.querySelector('[data-test=calphone-sheet-title]')?.value, focus: document.activeElement?.tagName }
    }, SHEET)
    ok(`${w}: the edit is full height, on the event, the heading focused`, ed.mode === 'edit' && ed.full === 'true' && ed.title === `AC-04 ${w}` && ed.focus === 'H2', ed)
    await p.$eval(`${SHEET} [data-test=calphone-sheet-body]`, (el) => { el.scrollTop = el.scrollHeight })
    const del = await p.evaluate((s) => {
      const r = (q) => { const b = document.querySelector(`${s} ${q}`)?.getBoundingClientRect(); return b ? { x: Math.round(b.left), y: Math.round(b.top), r: Math.round(b.right) } : null }
      return { del: r('[data-test=calphone-sheet-delete]'), save: r('[data-test=calphone-sheet-save]'), desc: r('[data-test=calphone-sheet-description]') }
    }, SHEET)
    ok(`${w}: Delete at the bottom start, below every field`, Boolean(del.del && del.save && del.desc) && del.del.x < w / 2 && del.del.y > del.desc.y, del)
    await p.click(`${SHEET} [data-test=calphone-sheet-delete]`)
    const del2 = await p.evaluate((s) => {
      const b = document.querySelector(`${s} [data-test=calphone-sheet-save]`).getBoundingClientRect()
      return { confirm: document.querySelector(`${s} [data-test=calphone-sheet-delete]`)?.getAttribute('data-confirm'), save: { x: Math.round(b.left), y: Math.round(b.top), r: Math.round(b.right) } }
    }, SHEET)
    ok(`${w}: the delete confirm does not move Save`, del2.confirm === 'true' && JSON.stringify(del2.save) === JSON.stringify(del.save), { before: del.save, after: del2 })
    await p.$eval(`${SHEET} [data-test=calphone-sheet-title]`, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
    await p.type(`${SHEET} [data-test=calphone-sheet-title]`, `Edited ${w}`)
    await p.click(`${SHEET} [data-test=calphone-sheet-save]`)
    ok(`${w}: edit in 3 taps (event, Edit, Save)`, await sheetGone(p))
    const edited = (await added(p)).find((e) => e.id === ac?.id)
    ok(`${w}: the edit is stored on the same event, its time kept`, edited?.title === `Edited ${w}` && edited?.starts_at === ac?.starts_at, edited && { title: edited.title, s: edited.starts_at })

    /* FR-007: More shows 097's fields in 097's order */
    await tapAdd(p)
    await p.click(`${SHEET} [data-test=calphone-sheet-more]`)
    await sleep(200)
    const order = await p.evaluate((s) => {
      const keys = ['time-zone', 'location', 'reminders', 'colors', 'audience', 'description']
      return keys.map((k) => ({ k, y: document.querySelector(`${s} [data-test=calphone-sheet-${k}]`)?.getBoundingClientRect().top ?? null }))
    }, SHEET)
    ok(`FR-007 ${w}: time zone, location, reminders, colour, private, description in that order`, order.every((o, i) => o.y !== null && (i === 0 || o.y > order[i - 1].y)), order)

    /* drag-down: not from a scrolled body; from the body at the top, and from the header */
    /* a long description makes the body scroll at every height */
    await p.$eval(`${SHEET} [data-test=calphone-sheet-description]`, (el) => { el.style.height = '1200px' })
    const body = await p.$eval(`${SHEET} [data-test=calphone-sheet-body]`, (el) => { el.scrollTop = 120; const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + 60, top: el.scrollTop } })
    await touchDrag(p, { x: body.x, y: body.y }, { x: body.x, y: body.y + 200 })
    ok(`9.4 #4 ${w}: a drag down in a scrolled body does not close the sheet`, body.top === 120 && Boolean(await p.$(SHEET)), body.top)
    await p.$eval(`${SHEET} [data-test=calphone-sheet-body]`, (el) => { el.scrollTop = 0 })
    await touchDrag(p, { x: body.x, y: body.y }, { x: body.x, y: body.y + 260 })
    ok(`9.4 #4 ${w}: a drag down from the body at scrollTop 0 closes it`, await sheetGone(p))
    await tapAdd(p)
    const head = await p.$eval(`${SHEET} [data-test=calphone-sheet-grab]`, (el) => { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + 4 } })
    await touchDrag(p, head, { x: head.x + 20, y: head.y + 40 }, 4)
    ok(`9.4 #4 ${w}: a short drag on the grab bar leaves it open`, Boolean(await p.$(SHEET)))
    await touchDrag(p, head, { x: head.x, y: head.y + 260 })
    ok(`9.4 #4 ${w}: a drag down from the grab bar closes it`, await sheetGone(p))

    /* Back closes the sheet, the calendar stays; Cancel stores nothing */
    await tapAdd(p)
    await p.type(`${SHEET} [data-test=calphone-sheet-title]`, 'not kept')
    await p.goBack()
    ok(`${w}: Back closes the sheet`, await sheetGone(p))
    await sleep(300)
    ok(`${w}: and the calendar stays (level 2)`, Boolean(await p.$(ROOT)) && (await level(p)) === '2', await level(p))
    await tapAdd(p)
    await p.type(`${SHEET} [data-test=calphone-sheet-title]`, 'not kept')
    await p.click(`${SHEET} [data-test=calphone-sheet-cancel]`)
    ok(`${w}: Cancel closes it`, await sheetGone(p))
    ok(`${w}: nothing was stored by Back or Cancel`, !(await added(p)).some((e) => e.title === 'not kept'))

    /* controls: the detectors have teeth */
    if (w === 390) {
      await tapAdd(p)
      await p.evaluate((s) => {
        const wide = document.createElement('div')
        wide.style.cssText = 'overflow-x:auto;width:100px'
        wide.innerHTML = '<div style="width:2000px;height:4px"></div>'
        document.querySelector(`${s} [data-test=calphone-sheet-body]`).appendChild(wide)
        const b = document.createElement('button')
        b.style.cssText = 'width:30px;height:30px;min-width:0;min-height:0;padding:0'
        document.querySelector(`${s} [data-test=calphone-sheet-body]`).appendChild(b)
      }, SHEET)
      ok('control: a planted 2000 px scroller trips H3', !flatOk(await sideways(p)))
      ok('control: a planted 30 px button trips H7', (await boxes(p)).targets.some((c) => !tapSize(c)))
    }
    await ctx.close()

    /* reduced motion: no sheet slide */
    {
      const { p: q, ctx: c2 } = await open(browser, vp)
      await q.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
      await tapAdd(q)
      const anim = await q.$eval(SHEET, (el) => getComputedStyle(el).animationName)
      ok(`H6 ${w}: reduced motion - the sheet does not slide`, anim === 'none', anim)
      await c2.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-sheet: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
