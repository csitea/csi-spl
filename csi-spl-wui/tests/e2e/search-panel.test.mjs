// SPL-6675 (owners HUM-10 t1 bcfd15e1 msgs b996a06b aa7dd3cf 2f0259cc 6cb72656
// 86f0ab8f 22c8a872; HUM-5 topic ea3ea4a3; spec 197 v1.2): the search results
// are their OWN slide-in panel, no results page. In a real browser on the mock
// tenant, desktop 1440:
//  - an Omnibox search opens the panel beside the rail and the page stays;
//    the sidebar's own list hides, its width untouched; the panel is wider
//    (48 %, >= 380 px) and resizable on its own key;
//  - type:calendar lists real entries only (the mock "Week 48" marker is out),
//    nearest upcoming first;
//  - a click PREVIEWS: the calendar opens on the right at that entry, alone
//    (no months strip, no dialog), the list stays; a second click changes only
//    the right; ArrowDown previews the next hit;
//  - Shift+O / Enter open for real: the panel closes, the months strip and
//    the entry's dialog are there; the X and Esc close it the same way;
//  - a message hit opened for real lands as "Open in channels view" does:
//    the Channels list left, the topic open;
//  - an old /search?q= link opens the panel; there is no results page.
// RED CONTROL: on the base (992866d69) step 1 fails - the search went to the
// /search page and its hits sat in the sidebar's own panel.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/search-panel.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const BOX = '[data-test=top-bar-omnibox] textarea'
const PANEL = '[data-testid=search-panel]'
const LIST = `${PANEL} [data-testid=left-list][data-mode=search]`
const CAL_HIT = `${LIST} [data-testid=left-entry][data-type=calendars]`
const MSG_HIT = `${LIST} [data-testid=left-entry][data-type=messages]`
const SIDE_BODY = '[data-testid=sidebar-body]'
const MODAL = '[aria-modal="true"]'
/* calendar-mock.mjs: Release today 09:00-10:00 UTC, Database maintenance +2 d, Planning +30 d; the Week 48 marker today */
const ID = (n) => `00000000-0000-4000-8000-00000000010${n}`
const MARKER = '00000000-0000-4000-8000-000000000199'
const REPLY = '55555555-5555-4555-8555-555555555555'
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const today10 = Date.parse(new Date().toISOString().slice(0, 10) + 'T10:00:00Z')
const ORDER = Date.now() <= today10 ? [ID(1), ID(2), ID(3)] : [ID(2), ID(3), ID(1)]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const server = await startServer()
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: { width: 1440, height: 900 },
  args: CHROME_LAUNCH_ARGS,
})

/** wait until fn() is truthy (or the cap), return its last value */
async function until(fn, ms = 6000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(100)
  }
  return v
}

try {
  const errors = []
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* opaque origin on the very first document */ }
  })
  const path = () => new URL(p.url()).pathname
  const param = (k) => new URL(p.url()).searchParams.get(k)
  const shown = (sel) => p.$eval(sel, (el) => el.getClientRects().length > 0 && getComputedStyle(el).display !== 'none').catch(() => false)
  const keys = (sel) => p.$$eval(sel, (els) => els.map((e) => String(e.getAttribute('data-key') || '').replace(/^calendars:/, '')))
  const sidebarW = () => p.$eval('.spool-shell', (el) => getComputedStyle(el).getPropertyValue('--sidebar-w').trim())
  const search = async (line, from = '/channel/lobby') => {
    if (from) {
      await p.goto(server.base + from, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
      await sleep(300)
    }
    await p.click(BOX)
    await p.type(BOX, line)
    await p.$eval('[data-test=omnibox-search]', (el) => el.click())
    await until(() => p.$(`${PANEL} [data-testid=left-entry], ${PANEL} [data-test=side-search-empty]`))
  }

  /* 1 the panel, not a page */
  await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(SIDE_BODY, { visible: true, timeout: NAV_TIMEOUT })
  const w0 = await sidebarW()
  await search('/s type:cal', '')
  ok('1 an Omnibox search opens the panel and the page stays (no /search page)', await shown(PANEL) && path().endsWith('/channel/lobby') && !(await p.$('[data-test=search-page]')), { url: p.url() })
  ok('2 the sidebar\'s own list hides, its width untouched', !(await shown(SIDE_BODY)) && (await sidebarW()) === w0, { w0, w: await sidebarW() })
  const pw = await p.$eval(PANEL, (el) => el.getBoundingClientRect().width).catch(() => 0)
  ok('3 the panel is its own, wider column: ~48 % of 1440, >= 380 px', pw >= 380 && Math.abs(pw - 691) <= 2, { pw })

  /* 4 calendar hits: real entries, nearest upcoming first */
  const got = await keys(CAL_HIT)
  ok('4 type:calendar: real entries only, nearest upcoming first (no Week 48)', JSON.stringify(got) === JSON.stringify(ORDER) && !got.includes(MARKER), { got, want: ORDER })

  /* 5 a click previews: the entry on the right, alone; the list stays */
  await p.click(`${CAL_HIT}[data-key="calendars:${ORDER[0]}"]`)
  await until(async () => path().endsWith('/calendar') && param('event') === ORDER[0])
  const found0 = await until(() => p.$(`[data-test=calendar-item][data-id="${ORDER[0]}"][data-found=true]`))
  ok('5 a click previews: the calendar at that entry, marked; the list stays', param('event') === ORDER[0] && Boolean(found0) && await shown(PANEL) && (await keys(CAL_HIT)).length === ORDER.length, { url: p.url() })
  ok('6 the preview is the item alone: no months strip, no dialog', !(await p.$('.calendar-body__strip')) && Boolean(await p.$('.calendar-body[data-alone="1"]')) && !(await p.$(MODAL)))

  /* 7 the next click swaps only the right */
  await p.click(`${CAL_HIT}[data-key="calendars:${ORDER[1]}"]`)
  await until(() => param('event') === ORDER[1])
  ok('7 a second click changes only the right side', param('event') === ORDER[1] && await shown(PANEL) && (await keys(CAL_HIT)).length === ORDER.length && !(await p.$(MODAL)), { url: p.url() })

  /* 8 ArrowDown previews the next hit */
  await p.$eval(LIST, (el) => el.focus())
  await p.keyboard.press('ArrowDown')
  await until(() => param('event') === ORDER[2])
  ok('8 ArrowDown cycles: the next hit previews on the right', param('event') === ORDER[2] && await shown(PANEL), { url: p.url() })

  /* 9 Shift+O opens for real */
  await p.$eval(LIST, (el) => el.focus())
  await p.keyboard.down('Shift')
  await p.keyboard.press('O')
  await p.keyboard.up('Shift')
  await until(async () => !(await p.$(PANEL)))
  const strip = await until(() => p.$('.calendar-body__strip'))
  const dialog = await until(() => p.$(MODAL))
  ok('9 Shift+O opens for real: the panel closes, the months strip and the entry\'s dialog come', !(await p.$(PANEL)) && Boolean(strip) && Boolean(dialog) && param('event') === ORDER[2], { url: p.url() })

  /* 10 Enter opens for real too */
  await search('/s type:cal')
  await p.click(`${CAL_HIT}[data-key="calendars:${ORDER[1]}"]`)
  await until(() => param('event') === ORDER[1])
  await p.$eval(LIST, (el) => el.focus())
  await p.keyboard.press('Enter')
  await until(async () => !(await p.$(PANEL)))
  ok('10 Enter opens for real: the panel closes, the calendar is whole', !(await p.$(PANEL)) && Boolean(await until(() => p.$('.calendar-body__strip'))) && param('event') === ORDER[1], { url: p.url() })

  /* 11 the X and Esc close and bring the section's list back */
  await search('/s type:cal')
  await p.click(`${PANEL} [data-testid=side-search-close]`)
  await until(async () => !(await p.$(PANEL)))
  ok('11 the X closes the search: the Channels list is back at its own width', !(await p.$(PANEL)) && await shown(SIDE_BODY) && path().endsWith('/channel/lobby') && (await sidebarW()) === w0)
  await search('/s type:cal')
  await p.$eval(LIST, (el) => el.focus())
  await p.keyboard.press('Escape')
  await until(async () => !(await p.$(PANEL)))
  ok('12 Esc closes it the same way', !(await p.$(PANEL)) && await shown(SIDE_BODY))

  /* 13 the panel's own width */
  await search('/s type:cal')
  const div = await p.$('[data-testid=pane-divider-search]')
  if (div) {
    await div.focus()
    for (let i = 0; i < 3; i++) await p.keyboard.press('ArrowRight')
  }
  const stored = await p.evaluate(() => localStorage.getItem('spool.us-pane-w'))
  const pw2 = await p.$eval(PANEL, (el) => el.getBoundingClientRect().width).catch(() => 0)
  ok('13 the divider resizes the panel alone, kept under spool.us-pane-w', Boolean(div) && pw2 > pw && Number(stored) === Math.round(pw2) && (await sidebarW()) === w0, { pw, pw2, stored })
  await p.evaluate(() => localStorage.removeItem('spool.us-pane-w'))

  /* 14 a message hit: preview keeps the list; Enter = Open in channels view.
     mock-data.mjs: "Scaffold is up. Tests green." is a reply (555…) in the
     topic bbbb…; a topic's own opening card would stop at the topic level */
  await search('/s green')
  const reply = await p.$(`${MSG_HIT}[data-msg-id="${REPLY}"]`)
  if (reply) await reply.click()
  await until(() => param('topic') === TOPIC)
  ok('14 a message hit previews in its channel at its topic; the list stays', Boolean(reply) && /\/channel\/lobby$/.test(path()) && param('topic') === TOPIC && await shown(PANEL) && !(await shown(SIDE_BODY)), { url: p.url() })
  await p.$eval(LIST, (el) => el.focus())
  await p.keyboard.press('Enter')
  await until(async () => !(await p.$(PANEL)))
  const chanRow = await until(() => p.$('[data-testid=sidebar-panel-channels]'))
  const replyShown = await until(() => p.$(`aside.live-pane [data-msg-id="${REPLY}"]`))
  ok('15 Enter on it opens it as "Open in channels view": Channels left, its topic open at the reply', !(await p.$(PANEL)) && Boolean(chanRow) && await shown(SIDE_BODY) && param('topic') === TOPIC && Boolean(replyShown), { url: p.url() })

  /* 16 an old /search link opens the panel; no results page */
  await p.goto(server.base + '/search?q=' + encodeURIComponent('type:cal'), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await until(() => p.$(CAL_HIT))
  ok('16 an old /search?q= link opens the panel on home; no results page', !path().endsWith('/search') && Boolean(await p.$(CAL_HIT)) && !(await p.$('[data-test=search-page]')), { url: p.url() })

  ok('17 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((x) => !x.ok).length
console.log(`search-panel: ${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
