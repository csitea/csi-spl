// spec 097 T014 (G6..G9, G11; spec 5.1.2, 5.1.6, 5.1.9): the event dialog's
// time zone, location, reminders and colour, and the pop-over's Duplicate.
//
// 1440 px: a new event takes the viewer's zone; "+ Add reminder" adds rows up
//   to 5; a fraction or 0 cannot be typed into an amount; Save stores the
//   location, colour, zone and reminders as typed (the mock keeps the wire
//   format); the event shows its colour; a click shows the pop-over with the
//   location; Edit reloads the reminders as typed; Duplicate opens a NEW
//   event filled from it, and Save makes a second event.
// The phone part (097 5.1.6, the dialog full screen at 360 / 390) went with
//   089 T009's phone calendar in spec 106 T011: a phone adds and edits in
//   CalendarPhoneSheet (calendar-phone-sheet, every field >= 44 px) and
//   duplicates from CalendarPhonePeek (calendar-phone-peek).
//
// Control: before T014 there is no [data-test=calendar-event-time-zone] and
// a click on an event opens the dialog, not a pop-over, so these FAIL.
//
// Run:
//   pnpm run test:e2e calendar-event-fields
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-event-fields
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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-event-fields-${name}.png`) })
}

const today = calIsoDay(Date.now())
const ADDED = 'spool.mock.calendar-added'
const DIALOG = '[data-test=calendar-event-form]'
const POPOVER = '[data-test=calendar-event-popover]'
const STAMP = '2026-01-01T00:00:00Z'
const event = (id, title, fields = {}) => ({
  id, source: 'event', title, description: '', kind: 'other', starts_at: `${today}T10:00:00Z`, ends_at: `${today}T11:00:00Z`,
  all_day: false, audience: 'public', mentions: [], creator_type: 'human', creator_id: 'HUM-1', remind_at: '', topic_id: '',
  release_version: '', issue_key: '', created_at: STAMP, updated_at: STAMP,
  time_zone: 'UTC', location: '', color: '', reminders: [], ...fields,
})

async function open(p, vp, events) {
  await p.emulateTimezone('Europe/Helsinki')
  await setPageViewport(p, vp)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((k, v) => { localStorage.setItem(k, v); localStorage.removeItem('spool.mock.calendar-hidden') }, ADDED, JSON.stringify(events || []))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  await sleep(150)
}
const visible = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 10000 }).then(() => true, () => false)
const gone = (p, sel) => p.waitForFunction((s) => !document.querySelector(s), { timeout: 10000 }, sel).then(() => true, () => false)
const stored = (p, title) => p.evaluate((k, t) => {
  try { return JSON.parse(localStorage.getItem(k) || '[]').filter((e) => e.title === t) } catch { return [] }
}, ADDED, title)
const clickItem = (p, title) => p.evaluate((t) => {
  [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)?.click()
}, title)
const waitItems = (p, title, n) => p.waitForFunction((t, want) => [...document.querySelectorAll('[data-test=calendar-item]')]
  .filter((e) => e.querySelector('.cal-week__title')?.textContent === t).length === want, { timeout: 10000 }, title, n).then(() => true, () => false)
const form = (p) => p.evaluate((s) => ({
  mode: document.querySelector(s)?.getAttribute('data-mode') || '',
  title: document.querySelector('[data-test=calendar-event-title]')?.value || '',
  zone: document.querySelector('[data-test=calendar-event-time-zone]')?.value || '',
  location: document.querySelector('[data-test=calendar-event-location]')?.value || '',
  color: document.querySelector('[data-test=calendar-event-color] input:checked')?.value ?? null,
  reminders: [...document.querySelectorAll('[data-test=calendar-event-reminder]')].map((r) => `${r.querySelector('input').value} ${r.querySelector('select').value}`),
  add: Boolean(document.querySelector('[data-test=calendar-event-reminder-add]')),
}), DIALOG)
async function typeInto(p, sel, text) {
  await p.$eval(sel, (el) => { el.focus(); el.select() })
  await p.keyboard.press('Backspace')
  await p.type(sel, text)
}
const nth = (i) => `[data-test=calendar-event-reminder]:nth-of-type(${i + 1}) [data-test=calendar-event-reminder-amount]`

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1440x900')
  const p = await browser.newPage()
  await open(p, { width: 1440, height: 900 })
  await p.click('[data-test=calendar-new]')
  ok('New event opens the dialog', await visible(p, DIALOG))
  let f = await form(p)
  ok('a new event takes the viewer\'s zone, no reminder, the default colour', f.zone === 'Europe/Helsinki' && f.reminders.length === 0 && f.color === '', f)
  await typeInto(p, '[data-test=calendar-event-title]', 'T014 fields')
  await typeInto(p, '[data-test=calendar-event-location]', 'Room 4')
  for (let i = 0; i < 5; i++) await p.click('[data-test=calendar-event-reminder-add]')
  f = await form(p)
  ok('+ Add reminder adds rows up to 5, then hides', f.reminders.length === 5 && !f.add, f)
  await typeInto(p, nth(0), '1.5')
  await typeInto(p, nth(1), '0')
  f = await form(p)
  ok('a fraction or 0 cannot be typed: 1.5 is 15, 0 is empty', f.reminders[0] === '15 minutes' && f.reminders[1] === ' minutes', f.reminders)
  ok('an empty amount says so inline', Boolean(await p.$('[data-test=calendar-event-reminder-error]')))
  await typeInto(p, nth(1), '1')
  await p.select('[data-test=calendar-event-reminder]:nth-of-type(2) select', 'days')
  await typeInto(p, nth(2), '29')
  await p.select('[data-test=calendar-event-reminder]:nth-of-type(3) select', 'days')
  ok('29 days is over 4 weeks, said inline', await p.evaluate(() => document.querySelectorAll('[data-test=calendar-event-reminder-error]').length === 1))
  for (let i = 0; i < 3; i++) await p.click('[data-test=calendar-event-reminder]:nth-of-type(3) [data-test=calendar-event-reminder-remove]')
  ok('remove drops a row and Add comes back', (await form(p)).reminders.length === 2 && (await form(p)).add)
  await p.click('[data-test=calendar-event-color][data-color=sage]')
  await p.select('[data-test=calendar-event-time-zone]', 'America/New_York')
  await shot(p, 'dialog-1440')
  await p.click('[data-test=calendar-event-save]')
  ok('Save closes the dialog', await gone(p, DIALOG))
  ok('the event shows in the week', await waitItems(p, 'T014 fields', 1))
  let saved = (await stored(p, 'T014 fields'))[0] || {}
  ok('stored as typed: zone, location, colour, reminders', saved.time_zone === 'America/New_York' && saved.location === 'Room 4' && saved.color === 'sage'
    && JSON.stringify(saved.reminders) === JSON.stringify([{ amount: 15, unit: 'minutes', method: 'popup' }, { amount: 1, unit: 'days', method: 'popup' }]), saved)
  ok('09:00 New York is 13:00Z', Date.parse(saved.starts_at) === Date.parse(`${today}T13:00:00Z`), saved.starts_at)
  ok('the event shows its colour', await p.evaluate(() => document.querySelector('[data-test=calendar-item][data-color=sage]') !== null))

  await clickItem(p, 'T014 fields')
  ok('a click shows the pop-over, not the dialog', await visible(p, POPOVER) && !(await p.$(DIALOG)))
  ok('the pop-over shows the location', await p.evaluate(() => document.querySelector('[data-test=calendar-popover-location]')?.textContent?.trim() === 'Room 4'))
  await shot(p, 'popover-1440')
  await p.click('[data-test=calendar-popover-edit]')
  ok('Edit opens the dialog', await visible(p, DIALOG))
  f = await form(p)
  ok('it reloads every field as typed', f.mode === 'edit' && f.zone === 'America/New_York' && f.location === 'Room 4' && f.color === 'sage'
    && f.reminders.join(',') === '15 minutes,1 days', f)
  await p.keyboard.press('Escape')
  await gone(p, DIALOG)

  await clickItem(p, 'T014 fields')
  await visible(p, POPOVER)
  await p.click('[data-test=calendar-popover-duplicate]')
  ok('Duplicate opens a new event', await visible(p, DIALOG) && !(await p.$(POPOVER)))
  f = await form(p)
  ok('filled from the source, with no Delete', f.mode === 'copy' && f.title === 'T014 fields' && f.location === 'Room 4' && f.color === 'sage'
    && f.zone === 'America/New_York' && f.reminders.join(',') === '15 minutes,1 days' && !(await p.$('[data-test=calendar-event-delete]')), f)
  await p.click('[data-test=calendar-event-save]')
  await gone(p, DIALOG)
  ok('Save makes a second event, the source untouched', await waitItems(p, 'T014 fields', 2))
  const both = await stored(p, 'T014 fields')
  ok('two ids, the same fields', both.length === 2 && both[0].id !== both[1].id && both.every((e) => e.location === 'Room 4' && e.color === 'sage'), both.map((e) => e.id))
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-event-fields: ${failed} FAILED` : `calendar-event-fields: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
