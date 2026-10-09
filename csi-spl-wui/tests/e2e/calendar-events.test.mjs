// spec 089 T008 v1 (owner msgs 12938ef0 + 72db6282): any member adds a
// calendar event, public by default, private on request.
//
// AC-03: New event, or a click on a day, opens the event dialog; Save
//        creates the event and it shows in the week.
// AC-09 (UI): the event is public unless the Private switch is on; on, it is
//        stored private. The switch shows only to the event's creator: an
//        agent's event (the mock's c-007 maintenance) opens with no switch.
// AC-05: a click on an event opens the same dialog to edit or delete it; an
//        issue deadline does not open it.
// The dialog fits 1440 px with no sideways scroll (a phone adds in
// CalendarPhoneSheet since spec 106 T011: calendar-phone-sheet); the calendar code
// stays in its own chunk (calendar.test.mjs AC-02 holds the 155 KB check).
// The mock workspace (viewer HUM-1) keeps its writes in localStorage
// (src/utils/calendar-mock.mjs), in the wire format of spec 6.1.
//
// Control: before T008 there is no [data-test=calendar-new] and a click on
// an event opens nothing, so every check below FAILS.
//
// Run:
//   pnpm run test:e2e calendar-events
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-events
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calIsoDay, calWeekDays } from '../../src/utils/calendar-year.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-events-${name}.png`) })
}

const today = calIsoDay(Date.now())
const DIALOG = '[data-test=calendar-event-form]'

async function open(p, vp) {
  await setPageViewport(p, vp)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}
const dialog = (p) => p.waitForSelector(DIALOG, { visible: true, timeout: 10000 }).then(() => true, () => false)
const closed = (p) => p.waitForFunction((s) => !document.querySelector(s), { timeout: 10000 }, DIALOG).then(() => true, () => false)
const state = (p) => p.evaluate((s) => {
  const form = document.querySelector(s)
  const sw = document.querySelector('[data-test=calendar-event-private]')
  const web = document.querySelector('[data-test=calendar-event-web]')
  return {
    mode: form?.getAttribute('data-mode') || '',
    date: document.querySelector('[data-test=calendar-event-date]')?.value || '',
    title: document.querySelector('[data-test=calendar-event-title]')?.value || '',
    focused: document.activeElement?.getAttribute('data-test') || '',
    switch: sw ? (sw.checked ? 'on' : 'off') : 'none',
    web: web ? (web.checked ? 'on' : 'off') : 'none',
    del: Boolean(document.querySelector('[data-test=calendar-event-delete]')),
  }
}, DIALOG)
const item = (p, title) => p.evaluate((t) => {
  const li = [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)
  return li ? { id: li.getAttribute('data-id'), audience: li.getAttribute('data-audience'), badge: Boolean(li.querySelector('[data-test=calendar-item-private]')), day: li.closest('[data-test=calendar-week-day]')?.getAttribute('data-day') } : null
}, title)
const waitItem = (p, title, pred) => p.waitForFunction((t, want) => {
  const li = [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)
  if (want === 'gone') return !li
  return li && (!want || li.getAttribute('data-audience') === want)
}, { timeout: 10000 }, title, pred || '').then(() => true, () => false)
const stored = (p, title) => p.evaluate((t) => {
  try {
    return (JSON.parse(localStorage.getItem('spool.mock.calendar-added') || '[]').find((e) => e.title === t) || {}).audience || ''
  } catch { return '' }
}, title)
/* 097 T014: a click shows the event's pop-over; its Edit opens the dialog */
async function clickItem(p, title) {
  await p.evaluate((t) => {
    [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)?.click()
  }, title)
  const edit = await p.waitForSelector('[data-test=calendar-popover-edit]', { visible: true, timeout: 4000 }).catch(() => null)
  if (edit) await edit.click()
}
/* the mock's seeded events sit two days on: on a weekend that is next week */
async function showing(p, title) {
  if (await item(p, title)) return true
  await p.click('[data-test=calendar-next]')
  return waitItem(p, title)
}
async function typeTitle(p, text) {
  await p.click('[data-test=calendar-event-title]', { clickCount: 3 })
  await p.type('[data-test=calendar-event-title]', text)
}
const noSideways = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1440x900')
  const p = await browser.newPage()
  await open(p, { width: 1440, height: 900 })

  /* AC-03 + AC-09: New event -> public */
  const btn = await p.$('[data-test=calendar-new]')
  ok('AC-03: the bar carries a New event button', Boolean(btn))
  if (btn) await btn.click()
  ok('AC-03: New event opens the dialog', await dialog(p))
  let s = await state(p)
  ok('a create dialog on the shown day, the title focused', s.mode === 'create' && s.date === today && s.focused === 'calendar-event-title', s)
  ok('AC-09: the creator sees the Private switch, off (public is the default)', s.switch === 'off', s)
  ok('a new event has no Delete', !s.del, s)
  ok('rdb 0158: the Web switch is there, off (never the default)', s.web === 'off', s)
  await typeTitle(p, 'E2E public')
  await shot(p, 'dialog-1440')
  ok('the dialog fits 1440 px with no sideways scroll', await noSideways(p))
  await p.click('[data-test=calendar-event-save]')
  ok('Save closes the dialog', await closed(p))
  ok('AC-03: the event shows in the week', await waitItem(p, 'E2E public'))
  let it = await item(p, 'E2E public')
  ok('AC-09: created without the switch it is public', it?.audience === 'public' && !it.badge && (await stored(p, 'E2E public')) === 'public', it)

  /* a click on a day -> a dialog for that day; Private on -> stored private */
  const days = calWeekDays(today)
  const other = days.find((d) => d !== today) || today
  const col = await p.$(`[data-test=calendar-week-day][data-day="${other}"]`)
  const box = col ? await col.boundingBox() : null
  /* 097 T013: the day is a 24-hour grid in its own scroller: click its visible bottom */
  const seen = await p.$eval('[data-test=calendar-week]', (el) => Math.min(el.getBoundingClientRect().bottom, window.innerHeight))
  if (box) await p.mouse.click(box.x + box.width / 2, Math.min(box.y + box.height, seen) - 12)
  ok('a click on an empty day opens the dialog', await dialog(p))
  s = await state(p)
  ok('the dialog is for the clicked day', s.mode === 'create' && s.date === other, { s, other })
  await typeTitle(p, 'E2E private')
  await p.click('[data-test=calendar-event-private]')
  ok('the switch turns on', (await state(p)).switch === 'on')
  await p.click('[data-test=calendar-event-save]')
  await closed(p)
  ok('the private event shows on its day', await waitItem(p, 'E2E private', 'private'))
  it = await item(p, 'E2E private')
  ok('AC-09: Private on -> stored private, marked in the week', it?.audience === 'private' && it.badge && it.day === other && (await stored(p, 'E2E private')) === 'private', it)

  /* AC-09: a non-creator sees no switch (c-007's event) */
  ok('the agent\'s seeded event is on screen', await showing(p, 'Database maintenance'))
  await clickItem(p, 'Database maintenance')
  ok('AC-05: a click on an event opens it', await dialog(p))
  s = await state(p)
  ok('AC-09: an event another made opens with no Private switch', s.mode === 'edit' && s.title === 'Database maintenance' && s.switch === 'none', s)
  await shot(p, 'dialog-edit-other-1440')
  await p.keyboard.press('Escape')
  ok('Escape closes it', await closed(p))

  /* AC-05: the creator edits theirs back to public */
  await p.click('[data-test=calendar-today]')
  await waitItem(p, 'E2E private')
  await clickItem(p, 'E2E private')
  await dialog(p)
  s = await state(p)
  ok('the creator\'s own event opens with the switch on', s.mode === 'edit' && s.switch === 'on' && s.del, s)
  await p.click('[data-test=calendar-event-private]')
  await p.click('[data-test=calendar-event-save]')
  await closed(p)
  ok('AC-05: switched off and saved, it is public again', await waitItem(p, 'E2E private', 'public'), await item(p, 'E2E private'))

  /* rdb 0158: edit -> Web; Web on turns Private off, saved it is `web` */
  await clickItem(p, 'E2E private')
  await dialog(p)
  s = await state(p)
  ok('rdb 0158: a public event opens with Web off', s.mode === 'edit' && s.web === 'off', s)
  await p.click('[data-test=calendar-event-private]')
  await p.click('[data-test=calendar-event-web]')
  s = await state(p)
  ok('rdb 0158: Web on turns Private off', s.web === 'on' && s.switch === 'off', s)
  await p.click('[data-test=calendar-event-save]')
  await closed(p)
  ok('rdb 0158: saved with Web on, it is web', await waitItem(p, 'E2E private', 'web') && (await stored(p, 'E2E private')) === 'web', await item(p, 'E2E private'))

  /* AC-05: delete asks once, then deletes */
  await clickItem(p, 'E2E public')
  await dialog(p)
  await p.click('[data-test=calendar-event-delete]')
  const asked = await p.$eval('[data-test=calendar-event-delete]', (el) => el.getAttribute('data-confirm')).catch(() => '')
  ok('the first Delete asks', asked === 'true', asked)
  await p.click('[data-test=calendar-event-delete]')
  await closed(p)
  ok('AC-05: the second deletes it from the week', await waitItem(p, 'E2E public', 'gone'))

  /* an issue deadline is not edited here */
  await showing(p, 'Issue deadline')
  await clickItem(p, 'Issue deadline')
  await new Promise((r) => setTimeout(r, 400))
  ok('CONTROL a click on an issue deadline opens no dialog', !(await p.$(DIALOG)))
  await p.close()

} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-events: ${failed} FAILED` : `calendar-events: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
