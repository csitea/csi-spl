// spec 106 T009: the phone calendar's event peek (CalendarPhonePeek.vue).
//
// At 360x780 and 390x844, dark and light (level 3), from T006's Week view:
//   FR-008  one tap on an event opens its peek: role=dialog aria-modal=true,
//           focus on its heading, the colour dot (ringed: --cal-dot-ring),
//           the title, the time, the location; the sheet is as tall as its
//           content (a short event < 45 % of the screen, a 200-character
//           title still fits), its bottom row Edit / Duplicate / Delete
//   H3      no sideways scroll with a 200-character unbroken title and a
//           120-character location in the peek (S4-5)
//   H7      every peek control >= 44x44 and <= 48 px tall at level 3
//   4.5     Delete in 2 taps (event, Delete), no question; the Undo bar is
//           role=status, still there 10.5 s later while focused (WCAG
//           2.2.1); AC-05 Undo brings the event back with the same id
// Once (390, dark):
//   4.5     a repeating event asks This / Following / All first; Cancel
//           keeps it; This deletes it with Undo
//   S4-6    an event in another zone shows that zone's clock beside the
//           viewer's ("Asia/Tokyo 18:00" for 09:00Z in a UTC browser)
//   private badge and guests; an issue deadline has no actions
//   Escape and the close button close it; Edit opens T008's sheet on the
//   event (data-mode=edit)
//   Duplicate (097 G11) opens the sheet as a NEW event (data-mode=copy, full
//   height) filled from the source: title, date, start / end, all-day, time
//   zone, location, reminders, colour, private, description; Save adds a
//   second event with a new id and leaves the source as it was
//   /calendar?event=<id> (a reminder's Open, 089 T006) opens that event's
//   peek (spec 106 T011)
//   t1 650cec31: Edit, then a tap on the title with a 300 px keyboard over
//   the page (the visual viewport shrinks, the layout one does not): the
//   title stays on screen and focused while it is typed into, deleted from
//   and the page resized; Save shows the new title. Control: before the fix
//   the lifted full-height sheet slid its title off the top (top -229).
//
// Controls: before T009 there is no [data-test=calpeek], so every check
// FAILs; in-run, a planted 2000 px scroller in the peek must trip H3, and
// the copy check must FAIL on a plain new event's sheet (the + button) -
// what Duplicate opened before the sheet had a copy mode. Escape waits for
// the heading's focus (it lands a frame after the peek renders; the hosted
// runner pressed Escape on the tapped row, c-736): a peek without its Escape
// handler still FAILs "Escape closes the peek" (mutant, 94/96).
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-peek
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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-peek-${name}.png`) })
}

const today = calIsoDay(Date.now())
const ROOT = '[data-test=calendar-phone]'
const PEEK = '[data-test=calpeek]'
const at = (hhmm) => `${today}T${hhmm}:00Z`
const LONG_ID = '00000000-0000-4000-8000-000000000901'
const REPEAT_ID = '00000000-0000-4000-8000-000000000902'
const ZONE_ID = '00000000-0000-4000-8000-000000000903'
const PLAIN_ID = '00000000-0000-4000-8000-000000000904'
const SAME_ID = '00000000-0000-4000-8000-000000000905'
const DUP_ID = '00000000-0000-4000-8000-000000000906'
/* events the mock workspace keeps in this browser (calendar-mock ADDED_KEY) */
const SEEDED = [
  { id: LONG_ID, title: 'x'.repeat(200), location: 'L'.repeat(120), starts_at: at('11:00'), ends_at: at('12:00'), color: 'banana', audience: 'private', guests: [{ type: 'human', id: 'HUM-2', response: '' }] },
  { id: REPEAT_ID, title: 'Weekly sync', starts_at: at('12:00'), ends_at: at('12:30'), rrule: 'FREQ=WEEKLY' },
  { id: ZONE_ID, title: 'Tokyo call', starts_at: at('09:00'), ends_at: at('09:30'), time_zone: 'Asia/Tokyo' },
  { id: PLAIN_ID, title: 'Lunch', starts_at: at('13:00'), ends_at: at('14:00'), color: 'sage' },
  { id: SAME_ID, title: 'Same clock', starts_at: at('15:00'), ends_at: at('15:30'), time_zone: 'Etc/GMT' },
  /* every field Duplicate copies, none of them a new event's default */
  { id: DUP_ID, title: 'Dup source', starts_at: at('16:00'), ends_at: at('17:30'), time_zone: 'Asia/Tokyo', location: 'Room 7', color: 'grape', audience: 'private', description: 'Agenda: copy me', reminders: [{ amount: 2, unit: 'hours' }] },
]
/* the source's fields as the sheet shows them (Tokyo wall time of 16:00Z..17:30Z) */
const DUP_FORM = { mode: 'copy', full: 'true', title: 'Dup source', date: calIsoDay(Date.parse(at('16:00')) + 9 * 3600000), start: '01:00', end: '02:30', allDay: false, zone: 'Asia/Tokyo', location: 'Room 7', reminders: '2 hours', color: 'grape', private: true, description: 'Agenda: copy me' }

/** a fresh page: the theme, level 3, Week, the seeded events */
async function open(browser, vp, { theme = 'dark', path = '/calendar', keyboard = false } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.emulateTimezone('UTC')
  /* a phone keyboard that overlays the page: window.__keyboard(h) shrinks
     the visual viewport by h px, the layout viewport keeps its height */
  if (keyboard) {
    await p.evaluateOnNewDocument(() => {
      const vv = new EventTarget()
      let kb = 0
      for (const [k, get] of Object.entries({ height: () => window.innerHeight - kb, width: () => window.innerWidth, offsetTop: () => 0, offsetLeft: () => 0, pageTop: () => 0, pageLeft: () => 0, scale: () => 1 })) {
        Object.defineProperty(vv, k, { get })
      }
      Object.defineProperty(window, 'visualViewport', { get: () => vv, configurable: true })
      window.__keyboard = (h) => { kb = h; vv.dispatchEvent(new Event('resize')) }
    })
  }
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calpeek-seeded')) return
      sessionStorage.setItem('calpeek-seeded', '1')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', '3')
      localStorage.setItem('spool-calendar-phone-view', 'week')
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(s.seeded))
    } catch { /* about:blank */ }
  }, { theme, seeded: SEEDED })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  await p.waitForSelector(ROOT, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 10000 }, ROOT).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const row = (id) => `${ROOT} [data-test=calphone-page][data-dir="0"] [data-test=calweek-event][data-id="${id}"]`
async function tap(p, sel) {
  const el = await p.$(sel)
  if (!el) return false
  await el.tap()
  return true
}
const peekShown = (p, id) => p.waitForFunction((s, i) => document.querySelector(s)?.getAttribute('data-id') === i, { timeout: 8000 }, PEEK, id).then(() => true, () => false)
const peekGone = (p) => p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, PEEK).then(() => true, () => false)
/* the heading takes focus one frame after the peek renders (nextTick, then
   requestAnimationFrame): a key sent before that lands on the tapped row */
const headFocused = (p) => p.waitForFunction((s) => document.activeElement === document.querySelector(`${s} [data-test=calpeek-title]`), { timeout: 5000 }, PEEK).then(() => true, () => false)
const rowThere = (p, id, want) => p.waitForFunction((s, w) => Boolean(document.querySelector(s)) === w, { timeout: 8000 }, row(id), want).then(() => true, () => false)

/* the peek as the checks read it */
async function peekBox(p) {
  return p.evaluate((s) => {
    const el = document.querySelector(s)
    if (!el) return null
    const b = el.getBoundingClientRect()
    const btns = [...el.querySelectorAll('button')].filter((x) => x.offsetParent !== null).map((x) => {
      const r = x.getBoundingClientRect()
      return { id: x.getAttribute('data-test'), w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10 }
    })
    const wide = []
    for (const x of [el, ...el.querySelectorAll('*')]) {
      const ox = getComputedStyle(x).overflowX
      if ((ox === 'auto' || ox === 'scroll') && x.scrollWidth > x.clientWidth + 1) wide.push(x.className || x.tagName)
      if (x.scrollLeft !== 0) wide.push(`scrollLeft ${x.className || x.tagName}`)
      if (x.getBoundingClientRect().right > window.innerWidth + 1) wide.push(`past the edge ${x.className || x.tagName}`)
    }
    const dot = el.querySelector('[data-test=calpeek-dot]')
    return {
      role: el.getAttribute('role'),
      modal: el.getAttribute('aria-modal'),
      focusHead: document.activeElement === el.querySelector('[data-test=calpeek-title]'),
      active: document.activeElement?.getAttribute('data-test') || document.activeElement?.tagName || '',
      title: el.querySelector('[data-test=calpeek-title]')?.textContent?.trim() || '',
      when: el.querySelector('[data-test=calpeek-when]')?.textContent?.trim() || '',
      location: el.querySelector('[data-test=calpeek-location]')?.textContent?.trim() || '',
      privateBadge: Boolean(el.querySelector('[data-test=calpeek-private]')),
      guests: el.querySelector('[data-test=calpeek-guests]')?.textContent || '',
      actions: [...el.querySelectorAll('[data-test=calpeek-actions] button')].map((x) => x.getAttribute('data-test')),
      dotRing: dot ? getComputedStyle(dot).boxShadow : '',
      h: b.height,
      vh: window.innerHeight,
      btns,
      doc: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      wide,
    }
  }, PEEK)
}
const flat = (b) => Boolean(b) && b.doc <= 1 && b.wide.length === 0

/* the add / edit sheet's fields as the copy check reads them */
const sheetForm = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-test=calphone-sheet]')
  if (!el) return null
  const q = (t) => el.querySelector(`[data-test=${t}]`)
  return {
    mode: el.getAttribute('data-mode'),
    full: el.getAttribute('data-full'),
    title: q('calphone-sheet-title')?.value ?? '',
    date: q('calphone-sheet-date-input')?.value ?? '',
    start: q('calphone-sheet-start-input')?.value ?? '',
    end: q('calphone-sheet-end-input')?.value ?? '',
    allDay: Boolean(q('calphone-sheet-all-day-input')?.checked),
    zone: q('calphone-sheet-time-zone')?.value ?? '',
    location: q('calphone-sheet-location')?.value ?? '',
    reminders: [...el.querySelectorAll('[data-test=calphone-sheet-reminder]')].map((r) => `${r.querySelector('[data-test=calphone-sheet-reminder-amount]')?.value} ${r.querySelector('[data-test=calphone-sheet-reminder-unit]')?.value}`).join(),
    color: el.querySelector('[data-test=calphone-sheet-color] input:checked')?.value ?? '',
    private: Boolean(q('calphone-sheet-private')?.checked),
    description: q('calphone-sheet-description')?.value ?? '',
  }
})
const copied = (f) => Boolean(f) && Object.entries(DUP_FORM).every(([k, v]) => f[k] === v)
const sheetGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=calphone-sheet]')?.checkVisibility?.(), { timeout: 5000 }).then(() => true, () => false)
/* the mock workspace's kept events titled `title` */
const kept = (p, title) => p.evaluate((t) => JSON.parse(localStorage.getItem('spool.mock.calendar-added') || '[]').filter((e) => e.title === t), title)

const undoBar = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-testid=calendar-undo]')
  return el ? { role: el.getAttribute('role'), id: el.getAttribute('data-id') } : null
})

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }]
try {
  for (const vp of PHONES) {
    for (const theme of ['dark', 'light']) {
      const tag = `${vp.width} ${theme}`
      console.log(`-- ${tag}`)
      const { p, ctx } = await open(browser, vp, { theme })
      ok(`${tag}: the phone shell renders`, Boolean(await p.$(ROOT)))

      /* FR-008: one tap */
      ok(`${tag}: the long event is listed`, await rowThere(p, LONG_ID, true))
      await tap(p, row(LONG_ID))
      ok(`${tag}: one tap opens the peek`, await peekShown(p, LONG_ID))
      await sleep(150)
      const b = await peekBox(p)
      ok(`${tag}: role=dialog aria-modal=true, focus on the heading`, Boolean(b && b.role === 'dialog' && b.modal === 'true' && b.focusHead), b && { role: b.role, modal: b.modal, focusHead: b.focusHead, active: b.active })
      ok(`${tag}: the full title, the time, the location`, Boolean(b && b.title.length === 200 && /\d{2}:\d{2}/.test(b.when) && b.location.length === 120), b && { title: b.title.length, when: b.when, location: b.location.length })
      ok(`${tag}: the private badge and the guests`, Boolean(b && b.privateBadge && b.guests.includes('HUM-2')))
      ok(`${tag}: Edit / Duplicate / Delete`, Boolean(b && b.actions.join() === 'calpeek-edit,calpeek-duplicate,calpeek-delete'), b?.actions)
      ok(`${tag}: a 200-character title still fits the screen`, Boolean(b && b.h > 100 && b.h <= b.vh - 48), b && { h: b.h, vh: b.vh })
      ok(`${tag}: the dot draws --cal-dot-ring`, Boolean(b && (theme === 'light' ? b.dotRing !== 'none' && !b.dotRing.startsWith('rgba(0, 0, 0, 0)') : true)), b?.dotRing)
      ok(`H3 ${tag}: no sideways scroll with a 200-character title and a 120-character location`, flat(b), b && { doc: b.doc, wide: b.wide })
      const small = (b?.btns || []).filter((c) => c.w < 43.5 || c.h < 43.5 || c.h > 48.5)
      ok(`H7 ${tag}: every peek control 44..48 px tall, >= 44 wide`, Boolean(b && b.btns.length >= 4 && small.length === 0), small.length ? small : b?.btns.length)
      if (vp.width === 390) await shot(p, `${vp.width}-${theme}-open`)

      /* control: a planted 2000 px scroller in the peek trips the H3 detector */
      await p.evaluate((s) => {
        const d = document.createElement('div')
        d.id = 'calpeek-plant'
        d.style.cssText = 'overflow-x:auto;width:100px'
        d.innerHTML = '<div style="width:2000px;height:4px"></div>'
        document.querySelector(s)?.appendChild(d)
      }, PEEK)
      ok(`control ${tag}: a planted wide scroller trips H3`, !flat(await peekBox(p)))
      await p.evaluate(() => document.getElementById('calpeek-plant')?.remove())

      /* 4.5: delete in 2 taps, Undo restores the same id */
      await tap(p, `${PEEK} [data-test=calpeek-delete]`)
      ok(`${tag}: Delete closes the peek at once (no question)`, await peekGone(p))
      ok(`${tag}: the event leaves the list`, await rowThere(p, LONG_ID, false))
      const u = await undoBar(p)
      ok(`${tag}: the Undo bar, role=status`, Boolean(u && u.role === 'status' && u.id === LONG_ID), u)
      if (vp.width === 390) await shot(p, `${vp.width}-${theme}-undo`)
      if (vp.width === 390 && theme === 'dark') {
        await p.focus('[data-testid=calendar-undo-undo]')
        await sleep(10500)
        ok(`${tag}: focused, the Undo bar outlasts its 10 s (WCAG 2.2.1)`, Boolean(await undoBar(p)))
      }
      await tap(p, '[data-testid=calendar-undo-undo]')
      ok(`AC-05 ${tag}: Undo brings the event back with the same id`, await rowThere(p, LONG_ID, true))
      await ctx.close()
    }
  }

  /* ---- once: scope, zone, closing, Edit, a read-only item ---- */
  {
    const { p, ctx } = await open(browser, { width: 390, height: 844 })
    console.log('-- 390 dark: once')

    await tap(p, row(REPEAT_ID))
    ok('repeat: the peek opens', await peekShown(p, REPEAT_ID))
    await tap(p, `${PEEK} [data-test=calpeek-delete]`)
    const scope = await p.$$eval(`${PEEK} [data-test=calpeek-scope] button`, (els) => els.map((x) => x.getAttribute('data-test'))).catch(() => [])
    ok('repeat: Delete asks This / Following / All first', scope.join() === 'calpeek-scope-this,calpeek-scope-following,calpeek-scope-all,calpeek-scope-cancel', scope)
    await shot(p, '390-dark-scope')
    await tap(p, `${PEEK} [data-test=calpeek-scope-cancel]`)
    ok('repeat: Cancel keeps the event and the peek', Boolean(await p.$(`${PEEK} [data-test=calpeek-delete]`)) && Boolean(await p.$(row(REPEAT_ID))))
    await tap(p, `${PEEK} [data-test=calpeek-delete]`)
    await tap(p, `${PEEK} [data-test=calpeek-scope-this]`)
    ok('repeat: This deletes it', (await peekGone(p)) && (await rowThere(p, REPEAT_ID, false)))
    ok('repeat: with the Undo bar', (await undoBar(p))?.id === REPEAT_ID)
    await tap(p, '[data-testid=calendar-undo-close]')

    await tap(p, row(ZONE_ID))
    await peekShown(p, ZONE_ID)
    const zone = await p.$eval(`${PEEK} [data-test=calpeek-when]`, (el) => el.textContent.trim()).catch(() => '')
    ok('S4-6: the own zone beside the viewer clock', zone.includes('09:00') && zone.includes('(Asia/Tokyo 18:00)'), zone)
    /* the hosted runner sent Escape before the focus landed (c-736): wait
       for it - a peek that never focuses its heading still FAILs here */
    ok('the peek focuses its heading before Escape', await headFocused(p))
    await p.keyboard.press('Escape')
    ok('Escape closes the peek', await peekGone(p))

    await tap(p, row(PLAIN_ID))
    /* the Lunch peek itself, not a Tokyo peek left open */
    const plainShown = await peekShown(p, PLAIN_ID)
    const plain = await p.$eval(`${PEEK} [data-test=calpeek-when]`, (el) => el.textContent.trim()).catch(() => '')
    ok('S4-6: a UTC event shows no second zone', plainShown && /\d{2}:\d{2}/.test(plain) && !plain.includes('('), plain)
    await tap(p, `${PEEK} [data-test=calpeek-close]`)
    await peekGone(p)
    await tap(p, row(SAME_ID))
    await peekShown(p, SAME_ID)
    const same = await p.$eval(`${PEEK} [data-test=calpeek-when]`, (el) => el.textContent.trim()).catch(() => '')
    ok('S4-6: a zone with the viewer\'s own clock (Etc/GMT in a UTC browser) shows no second zone', same.includes('15:00') && !same.includes('('), same)
    const pb = await peekBox(p)
    ok('a short event: the peek is as tall as its content (< 45 % of the screen)', Boolean(pb && pb.h > 100 && pb.h < pb.vh * 0.45), pb && { h: pb.h, vh: pb.vh })
    await shot(p, '390-dark-short')
    await tap(p, `${PEEK} [data-test=calpeek-close]`)
    ok('the close button closes the peek', await peekGone(p))

    await tap(p, row(PLAIN_ID))
    await peekShown(p, PLAIN_ID)
    await tap(p, `${PEEK} [data-test=calpeek-edit]`)
    const mode = await p.waitForSelector('[data-test=calphone-sheet]', { visible: true, timeout: 8000 }).then((h) => h.evaluate((el) => el.getAttribute('data-mode')), () => '')
    ok('Edit closes the peek and opens T008\'s sheet on the event', (await peekGone(p)) && mode === 'edit', mode)
    await p.keyboard.press('Escape')
    await sheetGone(p)

    /* Duplicate: a new event filled from the source; Save keeps both */
    await tap(p, row(DUP_ID))
    ok('duplicate: the peek opens', await peekShown(p, DUP_ID))
    await tap(p, `${PEEK} [data-test=calpeek-duplicate]`)
    await p.waitForSelector('[data-test=calphone-sheet]', { visible: true, timeout: 8000 }).catch(() => null)
    await sleep(150)
    const dup = await sheetForm(p)
    ok('duplicate: the peek closes and the sheet opens a new event, full height', (await peekGone(p)) && dup?.mode === 'copy' && dup?.full === 'true', dup && { mode: dup.mode, full: dup.full })
    ok('duplicate: the sheet shows the source\'s fields', copied(dup), dup)
    await shot(p, '390-dark-duplicate')
    const before = await kept(p, 'Dup source')
    await tap(p, '[data-test=calphone-sheet-save]')
    ok('duplicate: Save closes the sheet', await sheetGone(p))
    await p.waitForFunction((t) => JSON.parse(localStorage.getItem('spool.mock.calendar-added') || '[]').filter((e) => e.title === t).length === 2, { timeout: 5000 }, 'Dup source').catch(() => {})
    const after = await kept(p, 'Dup source')
    const src = after.find((e) => e.id === DUP_ID)
    const made = after.find((e) => e.id !== DUP_ID)
    const rems = (e) => (e.reminders || []).map((x) => `${x.amount} ${x.unit}`).join()
    const alike = (a, b) => Boolean(a && b) && ['title', 'starts_at', 'ends_at', 'all_day', 'time_zone', 'location', 'color', 'audience', 'description'].every((k) => Date.parse(a[k]) === Date.parse(b[k]) || a[k] === b[k]) && rems(a) === rems(b)
    ok('duplicate: two events, the new one with its own id', before.length === 1 && after.length === 2 && Boolean(made?.id), after.map((e) => e.id))
    ok('duplicate: the source is unchanged', JSON.stringify(src) === JSON.stringify(before[0]), src)
    ok('duplicate: the new event carries the source\'s fields', alike(made, src), made)
    ok('duplicate: both are listed', (await rowThere(p, DUP_ID, true)) && (await rowThere(p, made?.id || '-', true)))

    /* control: a plain new event (the + button) is not a copy */
    await tap(p, `${ROOT} [data-test=calphone-add]`)
    await p.waitForSelector('[data-test=calphone-sheet]', { visible: true, timeout: 8000 }).catch(() => null)
    await sleep(150)
    const fresh = await sheetForm(p)
    ok('control: the copy check FAILs on a plain new event\'s sheet', Boolean(fresh) && fresh.mode === 'create' && !copied(fresh), fresh && { mode: fresh.mode, title: fresh.title })
    await tap(p, '[data-test=calphone-sheet-cancel]')
    await sheetGone(p)

    /* an issue deadline (two days on) is read-only: the shell turns to its week first if needed */
    const issue = row('SPL-12')
    if (!(await p.$(issue))) {
      await p.click(`${ROOT} [data-test=calphone-next]`)
      await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 8000 }, ROOT).catch(() => {})
    }
    await rowThere(p, 'SPL-12', true)
    await tap(p, issue)
    ok('an issue deadline peeks', await peekShown(p, 'SPL-12'))
    ok('an issue deadline has no Edit / Duplicate / Delete', !(await p.$(`${PEEK} [data-test=calpeek-actions]`)))
    await ctx.close()
  }

  /* T011, moved from 089's phone main view: a reminder's Open lands on
     /calendar?event=<id>, which opens that event's peek */
  {
    const { p, ctx } = await open(browser, PHONES[1], { path: `/calendar?event=${PLAIN_ID}` })
    ok('?event=<id> (a reminder\'s Open) opens that event\'s peek', await peekShown(p, PLAIN_ID))
    await ctx.close()
  }

  /* t1 650cec31: the title of a saved event stays editable with the phone's
     keyboard up - it never slides off screen or loses focus until Save */
  {
    const vp = { width: 390, height: 844 }
    const { p, ctx } = await open(browser, vp, { keyboard: true })
    const TITLE = '[data-test=calphone-sheet] [data-test=calphone-sheet-title]'
    /* the title on screen above the keyboard, the one hit at its centre, focused */
    const field = (tag) => p.evaluate((sel, tag) => {
      const el = document.querySelector(sel)
      if (!el) return { tag, gone: true }
      const b = el.getBoundingClientRect()
      const vh = window.visualViewport.height
      const hit = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2)
      return { tag, top: Math.round(b.top), bottom: Math.round(b.bottom), vh, onScreen: b.top >= 0 && b.bottom <= vh, hit: hit === el, focused: document.activeElement === el, value: el.value }
    }, TITLE, tag)
    const editable = (f) => !f.gone && f.onScreen && f.hit && f.focused
    await tap(p, row(PLAIN_ID))
    await peekShown(p, PLAIN_ID)
    await tap(p, `${PEEK} [data-test=calpeek-edit]`)
    await p.waitForSelector('[data-test=calphone-sheet]', { visible: true, timeout: 8000 }).catch(() => null)
    await sleep(300)
    await tap(p, TITLE)
    await p.evaluate(() => window.__keyboard(300))
    await sleep(200)
    const up = await field('keyboard up')
    ok('650cec31: a tap on the title, the keyboard up - the title stays on screen and focused', editable(up), up)
    await p.keyboard.press('End')
    await p.keyboard.type(' movedX')
    const typed = await field('typed')
    ok('650cec31: typing keeps the title open', editable(typed) && typed.value === 'Lunch movedX', typed)
    await p.keyboard.press('Backspace')
    const deleted = await field('deleted')
    ok('650cec31: deleting keeps the title open', editable(deleted) && deleted.value === 'Lunch moved', deleted)
    /* the keyboard resizes the page too (a browser that resizes content) */
    await setPageViewport(p, { ...vp, height: vp.height - 300, hasTouch: true })
    await p.evaluate(() => window.__keyboard(0))
    await sleep(300)
    const resized = await field('page resized')
    ok('650cec31: a keyboard resize keeps the title open', editable(resized) && resized.value === 'Lunch moved', resized)
    await tap(p, '[data-test=calphone-sheet-save]')
    ok('650cec31: Save closes the sheet', await sheetGone(p))
    await p.waitForFunction((s) => document.querySelector(s)?.textContent?.includes('Lunch moved'), { timeout: 5000 }, row(PLAIN_ID)).catch(() => {})
    const shown = await p.$eval(row(PLAIN_ID), (el) => el.textContent.trim()).catch(() => '')
    const stored = (await kept(p, 'Lunch moved')).find((e) => e.id === PLAIN_ID)
    ok('650cec31: the saved event shows its new title', shown.includes('Lunch moved') && Boolean(stored), { shown, stored: stored?.title })
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-peek: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
