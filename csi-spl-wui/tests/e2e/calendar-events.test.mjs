// spec 089 T008 v1 (owner msgs 12938ef0 + 72db6282): any member adds a
// calendar event, workspace by default, private on request.
//
// AC-03: New event, or a click on a day, opens the event dialog; Save
//        creates the event and it shows in the week.
// AC-09 (UI): the event is workspace unless the Private switch is on; on, it is
//        stored private. The switch shows only to the event's creator: an
//        agent's event (the mock's c-007 maintenance) opens with no switch.
// AC-05: a click on an event opens the same dialog to edit or delete it; an
//        issue deadline does not open it.
// t1 9dec05c3 (owner msg cbfaaefc): Copy link in the pop-over, the edit
//        dialog and an event's right-click menu copies
//        <origin>/calendar?d=<day>&event=<id> and says "Link copied"; that
//        link opens the event. A link to an event the reader may not see
//        opens the calendar on its day saying "not available to you", with
//        no dialog, no pop-over and never the title (desktop and phone).
// SPL-2034 (design B, t1 edc177bc): an issue with a deadline links to the
//        calendar and back. Its detail has "Show in calendar" (a real link,
//        red once the deadline passed, 48 px); it opens the week with the
//        deadline's read-only pop-over open (status, assignee, Open issue);
//        Open issue opens that issue; Back returns to the week with the
//        pop-over closed. A phone opens Day with the peek, the stored view
//        untouched, and Back closes the peek before it leaves. A link to an
//        issue the reader cannot read says "not available" with Open issue
//        disabled. CONTROL: no deadline, no button; a stored event's
//        pop-over has no Open issue. Before SPL-2034 there is no
//        [data-test=issues-show-in-calendar] and a deadline opens nothing,
//        so these checks FAIL.
// The dialog fits 1440 px with no sideways scroll (a phone adds in
// CalendarPhoneSheet since spec 106 T011: calendar-phone-sheet); the calendar code
// stays in its own chunk (calendar.test.mjs AC-02 holds the 155 KB check).
// The mock workspace (viewer HUM-1) keeps its writes in localStorage
// (src/utils/calendar-mock.mjs), in the wire format of spec 6.1.
//
// Control: before T008 there is no [data-test=calendar-new] and a click on
// an event opens nothing, so every check below FAILS. Before Copy link there
// is no [data-test=calendar-popover-copy-link], so its checks FAIL.
//
// Run:
//   pnpm run test:e2e calendar-events
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-events
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { E2E_TODAY, pinClock } from './lib/clock.mjs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calWeekDays } from '../../src/utils/calendar-year.mjs'

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

const today = E2E_TODAY
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
  const pub = document.querySelector('[data-test=calendar-event-public]')
  return {
    mode: form?.getAttribute('data-mode') || '',
    date: document.querySelector('[data-test=calendar-event-date]')?.value || '',
    title: document.querySelector('[data-test=calendar-event-title]')?.value || '',
    focused: document.activeElement?.getAttribute('data-test') || '',
    switch: sw ? (sw.checked ? 'on' : 'off') : 'none',
    pub: pub ? (pub.checked ? 'on' : 'off') : 'none',
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
/* the clipboard as the page wrote it: writeText is caught, never the OS's */
const catchClipboard = (p) => p.evaluate(() => {
  window.__copied = ''
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async (t) => { window.__copied = t } } })
})
const copiedText = (p) => p.evaluate(() => window.__copied || '')
const keyed = (p, sel) => p.waitForFunction((q) => document.querySelector(q)?.getAttribute('data-key') === 'calendar_event.link_copied', { timeout: 5000 }, sel).then(() => true, () => false)

/* SPL-2034: issue deadline <-> calendar, both ways */
const POP = '[data-test=calendar-event-popover]'
const routerPush = (pg, to) => pg.evaluate((u) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(u), to)
const urlIs = (pg, path, issue) => pg.waitForFunction((pa, is) => location.pathname.endsWith(pa) && (new URLSearchParams(location.search).get('issue') || '') === is,
  { timeout: 10000 }, path, issue).then(() => true, () => false)
const tapHeight = (pg, sel) => pg.$eval(sel, (el) => Math.round(el.getBoundingClientRect().height)).catch(() => 0)
async function setDeadline(pg, local) {
  await pg.$eval('[data-test=issues-deadline]', (el) => { el.focus(); el.select() })
  await pg.type('[data-test=issues-deadline]', local)
  await pg.keyboard.press('Enter')
}
async function deadlineLinks(br) {
  console.log('-- SPL-2034 issue deadline <-> calendar')
  const r = await br.newPage()
  await pinClock(r)
  await setPageViewport(r, { width: 1440, height: 900 })
  await r.goto(`${server.base}/issues?issue=SPL-1`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await r.waitForSelector('[data-test=issues-deadline]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
  ok('SPL-2034 CONTROL no deadline, no Show in calendar', !(await r.$('[data-test=issues-show-in-calendar]')))
  await setDeadline(r, `${today} 09:00`)
  const BTN = '[data-test=issues-show-in-calendar]'
  const past = await r.waitForSelector(`${BTN}[data-overdue=true]`, { visible: true, timeout: 10000 }).then(() => true, () => false)
  ok('SPL-2034 a passed deadline shows Show in calendar, tinted red', past)
  await setDeadline(r, `${today} 15:00`)
  const fresh = await r.waitForFunction((b) => { const el = document.querySelector(b); return el && !el.hasAttribute('data-overdue') }, { timeout: 10000 }, BTN).then(() => true, () => false)
  ok('SPL-2034 a coming deadline: the button, no tint', fresh, await r.$eval('[data-test=issues-deadline]', (el) => el.value).catch(() => ''))
  const href = await r.$eval(BTN, (el) => el.getAttribute('href')).catch(() => '')
  ok('SPL-2034 it is a real link to the deadline day with issue=', href.endsWith(`/calendar?d=${today}&issue=SPL-1`), href)
  ok('SPL-2034 the button is a 48 px target', (await tapHeight(r, BTN)) >= 48, await tapHeight(r, BTN))
  await shot(r, 'issue-show-in-calendar-1440')
  await r.click(BTN)
  const pop = await r.waitForSelector(`${POP}[data-id="SPL-1"]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
  ok('SPL-2034 the calendar opens with the deadline pop-over open', pop)
  const got = await r.evaluate(() => ({
    status: document.querySelector('[data-test=calendar-popover-status]')?.getAttribute('data-status') || '',
    assignee: document.querySelector('[data-test=calendar-popover-assignee]')?.textContent?.trim() || '',
    edit: Boolean(document.querySelector('[data-test=calendar-popover-edit], [data-test=calendar-popover-duplicate]')),
    open: Boolean(document.querySelector('[data-test=calendar-popover-open-issue]')),
    url: location.pathname + location.search,
  }))
  /* the mock's epic SPL-1: status wip, nobody assigned */
  ok('SPL-2034 the pop-over paints status and assignee from the item, no Edit', got.status === 'wip' && got.assignee === '–' && !got.edit && got.open, got)
  ok('SPL-2034 the URL keeps d= and issue=', got.url.endsWith(`/calendar?d=${today}&issue=SPL-1`), got)
  const inView = await r.evaluate(() => {
    const el = document.querySelector('[data-test=calendar-item][data-id="SPL-1"]')
    const box = document.querySelector('[data-test=calendar-week]')?.getBoundingClientRect()
    const b = el?.getBoundingClientRect()
    return Boolean(b && box && b.top >= box.top - 1 && b.bottom <= box.bottom + 1)
  })
  ok('SPL-2034 the deadline is scrolled into view', inView)
  await shot(r, 'deadline-popover-1440')
  await r.click('[data-test=calendar-popover-open-issue]')
  ok('SPL-2034 Open issue opens that issue', await urlIs(r, '/issues', 'SPL-1') &&
    await r.waitForSelector('[data-test=issues-deadline]', { visible: true, timeout: 10000 }).then(() => true, () => false))
  await r.goBack()
  ok('SPL-2034 Back returns to the week, issue= dropped', await urlIs(r, '/calendar', ''))
  await r.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: 10000 }).catch(() => {})
  await new Promise((res) => setTimeout(res, 400))
  ok('SPL-2034 ... with the pop-over closed', !(await r.$(POP)))
  await r.goBack()
  ok('SPL-2034 Back again returns to the open issue', await urlIs(r, '/issues', 'SPL-1'))
  await r.close()

  /* a link to an issue the reader cannot read */
  const n = await br.newPage()
  await pinClock(n)
  await setPageViewport(n, { width: 1440, height: 900 })
  await n.goto(`${server.base}/calendar?d=${today}&issue=SPL-999`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const na = await n.waitForFunction(() => document.querySelector('[data-test=calendar-notice]')?.getAttribute('data-key') === 'calendar_event.not_available', { timeout: 10000 }).then(() => true, () => false)
  const dis = await n.$eval('[data-test=calendar-notice-open-issue]', (el) => el.disabled && Boolean(el.title)).catch(() => false)
  ok('SPL-2034 an unreadable issue\'s link says not available, Open issue disabled with a tooltip', na && dis && !(await n.$(POP)), { na, dis })
  await n.close()

  /* phone: Day with the peek; Back closes the peek first */
  const vp = { width: 390, height: 844, hasTouch: true }
  const u = await br.newPage()
  await pinClock(u)
  await setPageViewport(u, vp)
  await u.goto(`${server.base}/issues`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(u, vp)
  /* the mock's seeded deadline, SPL-12: two days on at 17:00Z (the page runs UTC) */
  const day = calAddDays(today, 2)
  await routerPush(u, `/calendar?d=${day}&issue=SPL-12`)
  const peek = await u.waitForSelector('[data-test=calpeek][data-id="SPL-12"]', { visible: true, timeout: 15000 }).then(() => true, () => false)
  const ph = await u.evaluate(() => ({
    view: document.querySelector('[data-test=calendar-phone]')?.getAttribute('data-view') || '',
    stored: localStorage.getItem('spool-calendar-phone-view'),
    status: document.querySelector('[data-test=calpeek-status]')?.getAttribute('data-status') || '',
    assignee: document.querySelector('[data-test=calpeek-assignee]')?.textContent?.trim() || '',
    del: Boolean(document.querySelector('[data-test=calpeek-delete], [data-test=calpeek-edit]')),
  }))
  ok('SPL-2034 390px: the link opens Day with the deadline peek', peek && ph.view === 'day', ph)
  ok('SPL-2034 390px: the stored view is untouched', ph.stored === null, ph)
  ok('SPL-2034 390px: status and assignee, no Edit or Delete', ph.status === 'todo' && ph.assignee === 'HUM-1' && !ph.del, ph)
  ok('SPL-2034 390px: Open issue is a 48 px target', (await tapHeight(u, '[data-test=calpeek-open-issue]')) >= 48, await tapHeight(u, '[data-test=calpeek-open-issue]'))
  await shot(u, 'deadline-peek-390')
  await u.goBack()
  const shut = await u.waitForFunction(() => !document.querySelector('[data-test=calpeek]'), { timeout: 5000 }).then(() => true, () => false)
  ok('SPL-2034 390px: Back closes the peek first, the calendar stays', shut && await urlIs(u, '/calendar', ''))
  await u.goBack()
  ok('SPL-2034 390px: the next Back leaves the calendar', await urlIs(u, '/issues', ''))
  await u.close()
}

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1440x900')
  const p = await browser.newPage()
  await pinClock(p)
  await open(p, { width: 1440, height: 900 })

  /* AC-03 + AC-09: New event -> workspace */
  const btn = await p.$('[data-test=calendar-new]')
  ok('AC-03: the bar carries a New event button', Boolean(btn))
  if (btn) await btn.click()
  ok('AC-03: New event opens the dialog', await dialog(p))
  let s = await state(p)
  ok('a create dialog on the shown day, the title focused', s.mode === 'create' && s.date === today && s.focused === 'calendar-event-title', s)
  ok('AC-09: the creator sees the Private switch, off (workspace is the default)', s.switch === 'off', s)
  ok('a new event has no Delete', !s.del, s)
  ok('rdb 0158: the Public switch is there, off (never the default)', s.pub === 'off', s)
  await typeTitle(p, 'E2E public')
  await shot(p, 'dialog-1440')
  ok('the dialog fits 1440 px with no sideways scroll', await noSideways(p))
  await p.click('[data-test=calendar-event-save]')
  ok('Save closes the dialog', await closed(p))
  ok('AC-03: the event shows in the week', await waitItem(p, 'E2E public'))
  let it = await item(p, 'E2E public')
  ok('AC-09: created without the switch it is workspace', it?.audience === 'workspace' && !it.badge && (await stored(p, 'E2E public')) === 'workspace', it)

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
  /* t1 9dec05c3: Copy link in the edit dialog */
  const dbm = await item(p, 'Database maintenance')
  const want = `${new URL(server.base).origin}/calendar?d=${dbm?.day}&event=${encodeURIComponent(dbm?.id || '')}`
  await catchClipboard(p)
  await p.click('[data-test=calendar-event-copy-link]')
  ok('Copy link: the dialog says "Link copied"', await keyed(p, '[data-test=calendar-event-copy-link]'))
  ok('Copy link: the dialog copies the event link', (await copiedText(p)) === want, { got: await copiedText(p), want })
  await p.keyboard.press('Escape')
  ok('Escape closes it', await closed(p))

  /* t1 9dec05c3: Copy link in the pop-over */
  await catchClipboard(p)
  await p.evaluate((t) => {
    [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t)?.click()
  }, 'Database maintenance')
  const peekCopy = await p.waitForSelector('[data-test=calendar-popover-copy-link]', { visible: true, timeout: 4000 }).catch(() => null)
  ok('Copy link: the pop-over carries it', Boolean(peekCopy))
  if (peekCopy) await peekCopy.click()
  ok('Copy link: the pop-over says "Link copied"', await keyed(p, '[data-test=calendar-popover-copied]'))
  ok('Copy link: the pop-over copies the event link', (await copiedText(p)) === want, { got: await copiedText(p), want })
  ok('SPL-2034 CONTROL a stored event\'s pop-over has no Open issue', !(await p.$('[data-test=calendar-popover-open-issue]')))
  await shot(p, 'popover-copy-link-1440')
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=calendar-event-popover]'), { timeout: 5000 }).catch(() => {})

  /* t1 9dec05c3: Copy link in an event's right-click menu */
  await catchClipboard(p)
  const li = await p.evaluateHandle((t) => [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => e.querySelector('.cal-week__title')?.textContent === t), 'Database maintenance')
  const libox = await li.asElement()?.boundingBox()
  if (libox) await p.mouse.click(libox.x + libox.width / 2, libox.y + Math.min(8, libox.height / 2), { button: 'right' })
  const entry = await p.waitForSelector('[data-testid=calendar-item-menu-copy_link]', { visible: true, timeout: 4000 }).catch(() => null)
  ok('Copy link: a right-click on an event offers it', Boolean(entry))
  if (entry) await entry.click()
  ok('Copy link: the menu answers "Link copied"', await keyed(p, '[data-test=calendar-notice]'))
  ok('Copy link: the menu copies the event link', (await copiedText(p)) === want, { got: await copiedText(p), want })
  ok('CONTROL Copy link opened no dialog', !(await p.$(DIALOG)))

  /* the copied link opens the event */
  const q = await browser.newPage()
  await pinClock(q)
  await setPageViewport(q, { width: 1440, height: 900 })
  await q.goto(want.replace(new URL(want).origin, server.base), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('Copy link: the copied link opens that event', await dialog(q) && (await state(q)).title === 'Database maintenance', await state(q))
  await q.close()

  /* t1 9dec05c3 part 3: an event the reader may not see */
  const UNSEEN = '0badbeef-0000-4000-8000-000000000999'
  for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844, hasTouch: true }]) {
    const u = await browser.newPage()
    await pinClock(u)
    await setPageViewport(u, vp)
    await u.goto(`${server.base}/calendar?d=${dbm?.day}&event=${UNSEEN}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(u, vp)
    const said = await u.waitForFunction(() => document.querySelector('[data-test=calendar-notice]')?.getAttribute('data-key') === 'calendar_event.not_available', { timeout: 10000 }).then(() => true, () => false)
    const seen = await u.evaluate(() => ({
      day: document.querySelector('[data-test=calendar-phone]')?.getAttribute('data-day') || [...document.querySelectorAll('[data-test=calendar-week-day]')].map((e) => e.getAttribute('data-day')).join(','),
      dialog: Boolean(document.querySelector('[data-test=calendar-event-form], [data-test=calendar-event-popover], [data-test=calpeek]')),
      notice: document.querySelector('[data-test=calendar-notice]')?.textContent?.trim() || '',
    }))
    ok(`${vp.width}px: an unseen event's link says "not available to you"`, said && seen.notice === 'This event is not available to you.', seen)
    ok(`${vp.width}px: it opens the calendar on the link's day, nothing opened`, seen.day.includes(dbm?.day || '-') && !seen.dialog, seen)
    await shot(u, `unseen-${vp.width}`)
    await u.close()
  }
  /* CONTROL a seen event's link says nothing */
  const v = await browser.newPage()
  await pinClock(v)
  await setPageViewport(v, { width: 1440, height: 900 })
  await v.goto(want.replace(new URL(want).origin, server.base), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await dialog(v)
  await new Promise((r) => setTimeout(r, 600))
  ok('CONTROL a link to an event the reader sees says nothing', !(await v.$('[data-test=calendar-notice]')))
  await v.close()

  /* AC-05: the creator edits theirs back to workspace */
  await p.click('[data-test=calendar-today]')
  await waitItem(p, 'E2E private')
  await clickItem(p, 'E2E private')
  await dialog(p)
  s = await state(p)
  ok('the creator\'s own event opens with the switch on', s.mode === 'edit' && s.switch === 'on' && s.del, s)
  await p.click('[data-test=calendar-event-private]')
  await p.click('[data-test=calendar-event-save]')
  await closed(p)
  ok('AC-05: switched off and saved, it is workspace again', await waitItem(p, 'E2E private', 'workspace'), await item(p, 'E2E private'))

  /* rdb 0158: edit -> Public; Public on turns Private off, saved it is
     `public` (the rename, rdb 0159..0161) */
  await clickItem(p, 'E2E private')
  await dialog(p)
  s = await state(p)
  ok('rdb 0158: a workspace event opens with Public off', s.mode === 'edit' && s.pub === 'off', s)
  await p.click('[data-test=calendar-event-private]')
  await p.click('[data-test=calendar-event-public]')
  s = await state(p)
  ok('rdb 0158: Public on turns Private off', s.pub === 'on' && s.switch === 'off', s)
  await p.click('[data-test=calendar-event-save]')
  await closed(p)
  ok('rdb 0158: saved with Public on, it is public', await waitItem(p, 'E2E private', 'public') && (await stored(p, 'E2E private')) === 'public', await item(p, 'E2E private'))

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

  await deadlineLinks(browser)

} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-events: ${failed} FAILED` : `calendar-events: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
