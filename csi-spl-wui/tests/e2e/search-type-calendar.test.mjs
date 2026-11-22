// SPL-6251, spec 100 section 15: `/s type:cal <word>` in the Omnibox reaches
// the search whole, the left list shows the mock tenant's calendar entry, and
// the hit opens it in the calendar (?d=<start day>&event=<id>). Mock tenant,
// real browser.
// CONTROL: a word no entry holds and type:event (the event log) list none.
// Red control: before SPL-6251 step 2 fails, SEARCH_GROUPS had no calendars.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/search-type-calendar.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const BOX = '[data-test=top-bar-omnibox] textarea'
const HIT = '[data-testid=sidebar-panel-search] [data-testid=left-list][data-mode=search] [data-testid=left-entry][data-type=calendars]'
/* calendar-mock.mjs: "Database maintenance", two days from today, 10:00 UTC */
const ID = '00000000-0000-4000-8000-000000000102'
const DAY = new Date(Date.now() + 2 * 86400000).toISOString().slice(0, 10)

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
try {
  const errors = []
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* opaque origin on the very first document */ }
  })
  const search = async (line) => {
    await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    await p.click(BOX)
    await p.type(BOX, line)
    await p.$eval('[data-test=omnibox-search]', (el) => el.click())
    await sleep(800)
    return { q: new URL(p.url()).searchParams.get('q'), hits: (await p.$$(HIT)).length }
  }

  let r = await search('/s type:cal maintenance')
  ok('1 the /s line reaches the search whole', r.q === 'type:cal maintenance', r)
  ok('2 the calendar entry is listed', r.hits === 1, r)
  const label = await p.$eval(HIT, (e) => e.textContent).catch(() => '')
  ok('3 the hit names the entry', label.includes('Database maintenance'), { label })
  await p.$eval(HIT, (e) => e.click()).catch(() => null)
  await sleep(800)
  const u = new URL(p.url())
  ok('4 the hit opens the entry in the calendar', u.pathname.endsWith('/calendar') && u.searchParams.get('event') === ID && u.searchParams.get('d') === DAY, { url: p.url() })
  r = await search('/s type:calendar nomatchword')
  ok('5 CONTROL: a word no entry holds lists none', r.hits === 0 && r.q === 'type:calendar nomatchword', r)
  r = await search('/s type:event maintenance')
  ok('6 CONTROL: type:event is the event log, no calendar entry', r.hits === 0, r)
  ok('7 no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((x) => !x.ok).length
console.log(`search-type-calendar: ${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
