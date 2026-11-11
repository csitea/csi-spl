// SPL-5276 (spec 153 3.26; owner HUM-10, t1 e1e97af9, msgs 7ccb6bfa and
// 2dedcc73: "Sorting and filtering in lanes should behave exactly as sorting
// and filtering for the event log", "the refresh button should be in the
// same place where the clear lock button is"). In a REAL browser, mock
// bundle, at 1440x900 and 390x844 (touch), the Event log (reference) and
// Monitoring -> Lanes, the same steps on both:
//
//   S1 desktop: every column name is the same sort button (.sheet-sort-h)
//      and the row under the names holds one filter per column
//   S2 desktop: three clicks on a name go none -> ascending ▲ ->
//      descending ▼ -> none, the same on both pages, and reorder the rows
//   S3 desktop: no Clear filters with no filter; a filter narrows the rows
//      and shows Clear filters just before the last action; its click
//      brings every row back and it goes
//   S4 phone: the same bar ("Sorted: ..."), a Sort sheet with a row per
//      column whose tap cycles as a name click, a Filters sheet with a
//      filter per column and Clear filters, the Filters dot while one is on
//   R1 desktop: Refresh is the last action of the tabs' row, its right edge
//      where the Event log's Clear log ends
//   R2 phone: Refresh is fixed at the bottom centre, where Clear log is
//      (same bottom, both centred, >= 44 px tall)
//
// Control: the bundle of origin/master c10b3ce97 FAILS S1 (Lanes' names are
// the Issues sheet's button, filters under 6 of 12 columns), S3 (Clear
// filters always on the row), S4 (no phone bar on Lanes), R1 (Refresh first)
// and R2 (Refresh in the row).
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e monitoring-lanes-like-events
//   SHOT_DIR=<dir> also writes a screenshot per page and size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { LANE_COLUMNS, LANES_MOCK_KEY } from '../../src/utils/monitoring-lanes.mjs'
import { EVENT_COLUMNS } from '../../src/utils/event-sheet.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
if (SHOT_DIR) mkdirSync(SHOT_DIR, { recursive: true })
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined || pass ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const SIZES = [
  { tag: '1440', width: 1440, height: 900, touch: false },
  { tag: '390', width: 390, height: 844, touch: true },
]
const SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })

/* the Event log: the auth calls answered in the page, 12 events (as events-monitoring-tab) */
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
const EVENTS = Array.from({ length: 12 }, (_, i) => {
  const id = 12 - i
  return { id, error_id: `e-${id}`, at: `2026-10-24T08:${String(id).padStart(2, '0')}:00Z`, source: ['wui', 'api', 'hub'][id % 3], status: [500, 404, 200, 0][id % 4], message: `event ${id}`, route: '/r' + (id % 4) }
})
function authAnswer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && req.method() === 'GET') {
    return json(200, { v: 1, p: 'password', sub: 'person@example.com', email: 'person@example.com', name: 'FirstName LastName', hum: 'HUM-4', t: 't1',
      iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false, active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }] })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  if (path === 'events') return json(200, { events: EVENTS, next_before: 0 })
  return json(404, { error: 'not_found' })
}

async function newPage(browser, size) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: size.width, height: size.height, isMobile: size.touch, hasTouch: size.touch, deviceScaleFactor: 1 })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  return { ctx, p, errors }
}

async function openEvents(browser, base, size) {
  const o = await newPage(browser, size)
  await o.p.evaluateOnNewDocument((s) => { try { localStorage.setItem('spool.mock.session', s) } catch { /* first document */ } }, SESSION)
  await o.p.setRequestInterception(true)
  o.p.on('request', (req) => {
    const a = authAnswer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  await o.p.goto(base + '/monitoring/events', { waitUntil: 'networkidle2' })
  await o.p.waitForSelector('[data-test=events-row]', { visible: true, timeout: 20000 })
  return { ...o, prefix: 'events', row: 'events-row', columns: EVENT_COLUMNS.map((c) => c.col), text: 'message', textValue: 'event 1', choice: 'source', choiceValue: 'api' }
}

async function openLanes(browser, base, size) {
  const o = await newPage(browser, size)
  await o.p.evaluateOnNewDocument((s, op, ln) => {
    try {
      localStorage.setItem('spool.mock.session', s)
      localStorage.removeItem('spool.mock.me')
      localStorage.setItem(op, '1')
      localStorage.removeItem(ln)
    } catch { /* first document */ }
  }, SESSION, TOKENS_MOCK_OPERATOR_KEY, LANES_MOCK_KEY)
  await o.p.goto(base + '/monitoring/lanes', { waitUntil: 'networkidle2' })
  await o.p.waitForSelector('[data-test=lanes-row]', { visible: true, timeout: 20000 })
  return { ...o, prefix: 'lanes', row: 'lanes-row', columns: LANE_COLUMNS, text: 'scope', textValue: 'locale', choice: 'vendor', choiceValue: 'agy' }
}

const rowCount = (o) => o.p.$$eval(`[data-test=${o.row}]`, (els) => els.length)
const rowKeys = (o) => o.p.$$eval(`[data-test=${o.row}]`, (els) => els.map((e) => e.id || e.getAttribute('data-agent')).join(','))
const until = (o, fn, arg) => o.p.waitForFunction(fn, { timeout: 6000 }, arg).then(() => true, () => false)

async function setFilter(o, col, value) {
  const sel = `[data-test=${o.prefix}-filter-${col}]`
  const tag = await o.p.$eval(sel, (e) => e.tagName).catch(() => '')
  if (!tag) { ok(`${o.prefix}: the ${col} filter exists`, false); return }
  if (tag === 'SELECT') await o.p.select(sel, value)
  else await o.p.$eval(sel, (e, v) => { e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })) }, value)
}

/** S1-S3 on a desktop: names, the filter row, the sort cycle, Clear filters. */
async function desktopSheet(o, tag) {
  const head = await o.p.evaluate((pre) => {
    const rows = [...document.querySelectorAll(`[data-test=${pre}-table] thead tr`)]
    const names = rows[0] ? [...rows[0].querySelectorAll('th')].map((th) => th.querySelector(`button[data-test^=${pre}-sort-]`)?.getAttribute('data-test') || '') : []
    const filters = rows[1] ? [...rows[1].querySelectorAll(`[data-test^=${pre}-filter-]`)].map((e) => e.getAttribute('data-test')) : []
    return { names: names.filter(Boolean), filters }
  }, o.prefix)
  ok(`S1 ${tag}: every column name is its sort button`, head.names.join() === o.columns.map((c) => `${o.prefix}-sort-${c}`).join(), head.names)
  ok(`S1 ${tag}: one filter under each column`, head.filters.join() === o.columns.map((c) => `${o.prefix}-filter-${c}`).join(), head.filters)

  const state = () => o.p.$eval(`[data-test=${o.prefix}-sort-${o.text}]`, (b) => b.closest('th').getAttribute('aria-sort') + ':' + (b.querySelector('[aria-hidden]')?.textContent || ''))
  const before = await rowKeys(o)
  const seen = [await state()]
  for (let i = 0; i < 3; i++) {
    await o.p.click(`[data-test=${o.prefix}-sort-${o.text}]`)
    await sleep(150)
    seen.push(await state())
    if (i === 0) ok(`S2 ${tag}: the first click reorders the rows`, (await rowKeys(o)) !== before || (await rowCount(o)) < 2, [before, await rowKeys(o)])
  }
  ok(`S2 ${tag}: a name cycles none -> ▲ -> ▼ -> none`, seen.join('|') === 'none:|ascending:▲|descending:▼|none:', seen)
  ok(`S2 ${tag}: the third click is the list's own order again`, (await rowKeys(o)) === before, [before, await rowKeys(o)])

  const clear = `#monitoring-head-actions [data-test=${o.prefix}-filter-clear]`
  ok(`S3 ${tag}: no Clear filters with no filter`, (await o.p.$(clear)) === null)
  const all = await rowCount(o)
  await setFilter(o, o.choice, o.choiceValue)
  const fewer = await until(o, ([s, n]) => document.querySelectorAll(s).length < n, [`[data-test=${o.row}]`, all])
  const order = await o.p.$$eval('#monitoring-head-actions > [data-test]', (els) => els.map((e) => e.getAttribute('data-test')))
  const ci = order.indexOf(`${o.prefix}-filter-clear`)
  ok(`S3 ${tag}: a choice filter narrows the rows and shows Clear filters before the last action`, fewer && ci >= 0 && ci === order.length - 2, order)
  await setFilter(o, o.text, o.textValue)
  await sleep(150)
  const both = await rowCount(o)
  await o.p.click(clear).catch(() => ok(`${tag}: Clear filters is there to click`, false))
  const back = await until(o, ([s, n]) => document.querySelectorAll(s).length === n, [`[data-test=${o.row}]`, all])
  ok(`S3 ${tag}: Clear filters brings every row back and goes`, back && (await o.p.$(clear)) === null, { all, both, now: await rowCount(o) })
  return { seen, order }
}

/** S4 on a phone: the bar, the Sort sheet, the Filters sheet. */
/* open a sheet; a tap that lands while the last sheet's Back step is still
   in flight is closed by it, so tap again (a person sees it and taps again) */
async function openSheet(o, button, sheet) {
  for (let i = 0; i < 3; i++) {
    await o.p.click(button)
    if (await o.p.waitForSelector(sheet, { visible: true, timeout: 2500 }).then(() => true, () => false)) {
      await sleep(400)
      if (await o.p.$(sheet)) return true
    }
  }
  return false
}

async function phoneSheet(o, tag) {
  const bar = await o.p.$eval(`[data-test=${o.prefix}-sorted-by]`, (e) => e.textContent.trim()).catch(() => '')
  ok(`S4 ${tag}: the bar says how the list is sorted`, /^Sorted: /.test(bar), bar)
  const sortSheet = await openSheet(o, `[data-test=${o.prefix}-sort-open]`, `[data-test=${o.prefix}-sort-sheet]`)
  const opts = await o.p.$$eval(`[data-test=${o.prefix}-sort-sheet] button[data-test^=${o.prefix}-sort-]`, (els) => els.map((e) => e.getAttribute('data-test'))).catch(() => [])
  ok(`S4 ${tag}: the Sort sheet has a row per column`, sortSheet && opts.join() === o.columns.map((c) => `${o.prefix}-sort-${c}`).join(), opts)
  const opt = `[data-test=${o.prefix}-sort-sheet] [data-test=${o.prefix}-sort-${o.text}]`
  const marks = []
  for (let i = 0; i < 3; i++) {
    await o.p.click(opt)
    await sleep(150)
    marks.push(await o.p.$eval(opt, (b) => b.getAttribute('aria-pressed') + ':' + b.lastElementChild.textContent.trim()))
  }
  ok(`S4 ${tag}: a row's tap cycles ▲ -> ▼ -> none`, marks.join('|') === 'true:▲|true:▼|false:', marks)
  await o.p.click(`[data-test=${o.prefix}-sheet-scrim]`)
  await sleep(400) /* the sheet's Back step settles before the next tap */
  await openSheet(o, `[data-test=${o.prefix}-filters-open]`, `[data-test=${o.prefix}-filters]`)
  const fields = await o.p.$$eval(`[data-test=${o.prefix}-filters] [data-test^=${o.prefix}-filter-]:not(button)`, (els) => els.map((e) => e.getAttribute('data-test'))).catch(() => [])
  ok(`S4 ${tag}: the Filters sheet has a filter per column and Clear filters`, fields.join() === o.columns.map((c) => `${o.prefix}-filter-${c}`).join()
    && (await o.p.$(`[data-test=${o.prefix}-filters] [data-test=${o.prefix}-filter-clear]`)) !== null, fields)
  const all = await rowCount(o)
  await setFilter(o, o.choice, o.choiceValue)
  await o.p.click(`[data-test=${o.prefix}-sheet-scrim]`)
  await sleep(400) /* the sheet's Back step settles before the next tap */
  const fewer = await until(o, ([s, n]) => document.querySelectorAll(s).length < n, [`[data-test=${o.row}]`, all])
  const dot = await o.p.$eval(`[data-test=${o.prefix}-filters-open]`, (b) => b.getAttribute('data-active')).catch(() => '')
  ok(`S4 ${tag}: a filter narrows the rows and lights the Filters dot`, fewer && dot === 'true', { all, now: await rowCount(o), dot })
  if (SHOT_DIR) await o.p.screenshot({ path: join(SHOT_DIR, `${o.prefix}-filtered-${tag}.png`) })
  await openSheet(o, `[data-test=${o.prefix}-filters-open]`, `[data-test=${o.prefix}-filters] [data-test=${o.prefix}-filter-clear]`)
  await o.p.click(`[data-test=${o.prefix}-filters] [data-test=${o.prefix}-filter-clear]`)
  await o.p.click(`[data-test=${o.prefix}-sheet-scrim]`)
  await sleep(400) /* the sheet's Back step settles before the next tap */
  ok(`S4 ${tag}: Clear filters in the sheet brings every row back`, await until(o, ([s, n]) => document.querySelectorAll(s).length === n, [`[data-test=${o.row}]`, all]))
}

/** The box of the action at Clear log's place: Clear log on the Event log, Refresh on Lanes. */
const actionBox = (o, test) => o.p.evaluate((t) => {
  const e = [...document.querySelectorAll(`[data-test=${t}]`)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return null
  const r = e.getBoundingClientRect()
  const actions = document.getElementById('monitoring-head-actions')
  const kids = actions ? [...actions.children].filter((k) => k.getBoundingClientRect().width > 0) : []
  return { l: r.left, r: r.right, t: r.top, b: r.bottom, h: r.height, vw: document.documentElement.clientWidth, vh: window.innerHeight,
    fixed: getComputedStyle(e).position === 'fixed', inRow: Boolean(actions && actions.contains(e)), last: kids[kids.length - 1] === e }
}, test)

/* a step that cannot run (a control missing) is a FAIL, never a crash that hides the others */
const step = (name, fn) => fn().catch((e) => { ok(`${name}: ran to the end`, false, String(e && e.message).slice(0, 160)); return { seen: [], order: [] } })

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const ev = await openEvents(browser, server.base, size)
    const ln = await openLanes(browser, server.base, size)
    if (SHOT_DIR) {
      await ev.p.screenshot({ path: join(SHOT_DIR, `events-${size.tag}.png`) })
      await ln.p.screenshot({ path: join(SHOT_DIR, `lanes-${size.tag}.png`) })
    }
    const clearLog = await actionBox(ev, 'events-clear')
    const refresh = await actionBox(ln, 'lanes-refresh')
    if (!size.touch) {
      ok(`R1 ${size.tag}: Clear log is the last action of the row (the reference)`, clearLog && clearLog.inRow && clearLog.last, clearLog)
      ok(`R1 ${size.tag}: Refresh is the last action of the row, its right edge where Clear log ends`, refresh && refresh.inRow && refresh.last
        && clearLog && Math.abs(refresh.r - clearLog.r) <= 2, { refresh, clearLog })
      const e = await step(`events ${size.tag}`, () => desktopSheet(ev, `events ${size.tag}`))
      const l = await step(`lanes ${size.tag}`, () => desktopSheet(ln, `lanes ${size.tag}`))
      ok(`S2 ${size.tag}: both pages cycle alike`, e.seen.join() === l.seen.join(), [e.seen, l.seen])
    } else {
      ok(`R2 ${size.tag}: Clear log is fixed at the bottom centre (the reference)`, clearLog && clearLog.fixed && !clearLog.inRow, clearLog)
      const mid = (b) => (b.l + b.r) / 2
      ok(`R2 ${size.tag}: Refresh is fixed where Clear log is: bottom centre, out of the row, >= 44 px`, refresh && refresh.fixed && !refresh.inRow && refresh.h >= 44
        && clearLog && Math.abs(refresh.b - clearLog.b) <= 1 && Math.abs(mid(refresh) - refresh.vw / 2) <= 1 && Math.abs(mid(clearLog) - clearLog.vw / 2) <= 1, { refresh, clearLog })
      ok(`R2 ${size.tag}: a tap at Refresh's middle reaches it`, await ln.p.evaluate(() => {
        const b = [...document.querySelectorAll('[data-test=lanes-refresh]')].find((x) => x.getBoundingClientRect().width > 0)
        if (!b) return false
        const r = b.getBoundingClientRect()
        const hit = document.elementFromPoint((r.left + r.right) / 2, (r.top + r.bottom) / 2)
        return Boolean(hit && b.contains(hit))
      }))
      await step(`events ${size.tag}`, () => phoneSheet(ev, `events ${size.tag}`))
      await step(`lanes ${size.tag}`, () => phoneSheet(ln, `lanes ${size.tag}`))
    }
    const wide = await ln.p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(`${size.tag}: Lanes has no sideways page scroll`, wide <= 0, wide)
    ok(`${size.tag}: no page error on either page`, ev.errors.length === 0 && ln.errors.length === 0, [ev.errors, ln.errors])
    await ev.ctx.close()
    await ln.ctx.close()
  }
} finally {
  await browser.close()
  await server.stop?.()
}
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
