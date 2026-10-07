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
//
// Controls: before T009 there is no [data-test=calpeek], so every check
// FAILs; in-run, a planted 2000 px scroller in the peek must trip H3.
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
/* events the mock workspace keeps in this browser (calendar-mock ADDED_KEY) */
const SEEDED = [
  { id: LONG_ID, title: 'x'.repeat(200), location: 'L'.repeat(120), starts_at: at('11:00'), ends_at: at('12:00'), color: 'banana', audience: 'private', guests: [{ type: 'human', id: 'HUM-2', response: '' }] },
  { id: REPEAT_ID, title: 'Weekly sync', starts_at: at('12:00'), ends_at: at('12:30'), rrule: 'FREQ=WEEKLY' },
  { id: ZONE_ID, title: 'Tokyo call', starts_at: at('09:00'), ends_at: at('09:30'), time_zone: 'Asia/Tokyo' },
  { id: PLAIN_ID, title: 'Lunch', starts_at: at('13:00'), ends_at: at('14:00'), color: 'sage' },
]

/** a fresh page: the opt-in, the theme, level 3, Week, the seeded events */
async function open(browser, vp, { theme = 'dark' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.emulateTimezone('UTC')
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calpeek-seeded')) return
      sessionStorage.setItem('calpeek-seeded', '1')
      localStorage.setItem('spool-calendar-phone', '1')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', '3')
      localStorage.setItem('spool-calendar-phone-view', 'week')
      localStorage.setItem('spool.mock.calendar-added', JSON.stringify(s.seeded))
    } catch { /* about:blank */ }
  }, { theme, seeded: SEEDED })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
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
    await p.keyboard.press('Escape')
    ok('Escape closes the peek', await peekGone(p))

    await tap(p, row(PLAIN_ID))
    await peekShown(p, PLAIN_ID)
    const plain = await p.$eval(`${PEEK} [data-test=calpeek-when]`, (el) => el.textContent.trim()).catch(() => '')
    ok('S4-6: a UTC event shows no second zone', !plain.includes('('), plain)
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
    await p.waitForFunction(() => !document.querySelector('[data-test=calphone-sheet]')?.checkVisibility?.(), { timeout: 5000 }).catch(() => {})

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
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-peek: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
