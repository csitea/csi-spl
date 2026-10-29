// SPL-3250 (owner HUM-10, t1 463d7692, msgs 24316f72 + ac1c95f9): "the event
// log section should be come just one tab of the monitoring section", "on
// both mobile and the desktop". It replaces SPL-3212's events-tab-auto test,
// whose Events rail tab is gone.
//
// The mock bundle, signed in with 12 events, phone 360x800 (touch) and
// desktop 1440x900, each:
//   1 the rail has no Events entry (and still has Monitoring)
//   2 Monitoring shows an Events tab; it opens /monitoring/events
//   3 the tab shows the event log (its first row, no link) and Clear log
//     POSTs /clear and empties it
//   4 the deep link /events lands on /monitoring/events, and /events#<id>
//     keeps the hash: that row is the focused one
//   5 no sideways scroll; the Monitoring tabs and Clear log are >= 44 px tall
//     on the phone
//   6 SPL-3366: each column sorts and filters, on the phone and on the desktop.
//     A filter that matches nothing keeps the controls. /events#5 stays visible
//     when the filter would hide that row.
//   7 spec 162 C1: event 12's request (POST /v1/x) and code (bad_request, then
//     TypeError) show, in the desktop columns and with the phone card labels;
//     C3: When reads YYYY-MM-DD HH:MM:SS+HH:MM, its hover the Z instant
//   8 spec 162 C5: Clear log asks first; Cancel keeps every row and sends no
//     POST, OK clears (control C6: an onClear without the confirm POSTs at
//     the first tap and fails here)
//   9 spec 162 C24: check 3 rows, shift-click the row 5 below the third -> 8
//     checked, the bar replaces Clear log; the selection survives a sort and
//     a filter; Delete selected asks first (Cancel sends nothing), OK POSTs
//     /delete with exactly those 8 ids and they leave, the other 4 stay
//     (control C25: a Delete selected that sends the page's ids removes the
//     unchecked rows and fails here)
// Control: the bundle of origin/master a1d2ced73 fails 1, 2, 3 and 4 on both
// viewports (an Events rail tab, no Events tab in Monitoring, /events stays).
//
// Run:
//   node tests/e2e/events-monitoring-tab.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/events-monitoring-tab.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// The signed-in mock owner (specs/054) and 12 events, as events-clear-log-mobile.
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
// SPL-3366: same 12 rows and the same timestamps, with distinct source,
// status, message and route so a column sort and a column filter can be told
// apart. id 5 stays, for the hash focus.
const SOURCES = ['wui', 'api', 'hub']
const STATUSES = [500, 404, 200, 0]
const ROUTES = ['/events', '/lobby', '/issues', '/monitoring/events']
const EVENTS = Array.from({ length: 12 }, (_, i) => {
  const id = 12 - i
  const row = {
    id, error_id: `e-${id}`, at: '2026-10-24T08:00:00Z', received_at: '2026-10-24T08:00:01Z',
    source: SOURCES[id % 3], status: STATUSES[id % 4], message: `event ${id}`, route: ROUTES[id % 4],
  }
  // spec 162 C1: the newest row carries the request and the code
  return id === 12 ? { ...row, method: 'POST', origin: 'https://example.com', path: '/v1/x', code: 'bad_request', name: 'TypeError' } : row
})
function answer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && req.method() === 'GET') {
    return json(200, {
      v: 1, p: 'password', sub: 'person@example.com', email: 'person@example.com', name: 'FirstName LastName',
      hum: 'HUM-4', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  if (path === 'events') return json(200, { events: EVENTS, next_before: 0 })
  return json(404, { error: 'not_found' })
}

let clears = 0
/* spec 162 C24: the ids of every POST /api/v1/auth/events/delete */
const deletes = []
async function open(browser, base, vp, path) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((session) => {
    try { localStorage.setItem('spool.mock.session', session) } catch { /* first document */ }
  }, MOCK_SESSION)
  await p.setViewport({ width: vp.w, height: vp.h, isMobile: vp.mobile, hasTouch: vp.mobile, deviceScaleFactor: 1 })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (req.method() === 'POST' && new URL(req.url()).pathname === '/api/v1/auth/events/clear') {
      clears++
      req.respond(json(200, { ok: true })).catch(() => {})
      return
    }
    if (req.method() === 'POST' && new URL(req.url()).pathname === '/api/v1/auth/events/delete') {
      let ids = []
      try { ids = JSON.parse(req.postData() || '{}').ids || [] } catch { /* recorded as none */ }
      deletes.push(ids)
      req.respond(json(200, { deleted: ids.length })).catch(() => {})
      return
    }
    const a = answer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  await p.goto(base + path, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true, timeout: 15000 })
  await sleep(1200)
  return p
}

/* what the reader sees */
const seen = (p) => p.evaluate(() => {
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0 && r.top < innerHeight && r.bottom > 0
  }
  const h = (sel) => [...document.querySelectorAll(sel)].filter(vis).map((e) => Math.round(e.getBoundingClientRect().height))
  const row = document.querySelector('[data-test=events-row]')
  const se = document.scrollingElement || document.documentElement
  return {
    path: location.pathname,
    hash: location.hash,
    railEvents: Boolean(document.querySelector('[data-testid=sidebar-tab-events]')),
    railMonitoring: vis(document.querySelector('[data-testid=sidebar-tab-monitoring]')),
    tab: vis(document.querySelector('[data-test=monitoring-tab-events]')),
    tabActive: document.querySelector('[data-test=monitoring-tab-events]')?.getAttribute('aria-current') === 'page',
    row: vis(row),
    rows: document.querySelectorAll('[data-test=events-row]').length,
    focus: document.querySelector('.events-row--focus')?.id || '',
    empty: vis(document.querySelector('[data-test=events-empty]')),
    clear: vis(document.querySelector('[data-test=events-clear]')),
    logs: document.querySelectorAll('[data-test=events-page]').length,
    sideways: se.scrollWidth - innerWidth,
    tabH: h('.monitoring-tab'),
    clearH: h('[data-test=events-clear]'),
  }
})

async function settle(p, sel = '[data-test=events-row]') {
  await p.waitForSelector(sel, { visible: true, timeout: 10000 }).catch(() => {})
  await sleep(400)
  return seen(p)
}
const click = (p, sel) => p.$eval(sel, (e) => e.click())
const shot = async (p, name) => { if (OUT) await p.screenshot({ path: join(OUT, `${name}.png`) }) }

async function check(browser, base, vp, name) {
  const phone = vp.mobile
  let p = await open(browser, base, vp, '/')
  try {
    const s0 = await seen(p)
    ok(`${name}: 1 the rail has no Events entry, Monitoring is there`, !s0.railEvents && s0.railMonitoring, s0)
    await click(p, '[data-testid=sidebar-tab-monitoring]')
    const s1 = await settle(p, '[data-test=monitoring-tab-events]')
    ok(`${name}: 2 Monitoring shows an Events tab`, s1.tab && s1.path.startsWith('/monitoring'), s1)
    await click(p, '[data-test=monitoring-tab-events]')
    const s2 = await settle(p)
    await shot(p, `${name}-tab`)
    ok(`${name}: 2 the Events tab opens /monitoring/events, selected`, s2.path.endsWith('/monitoring/events') && s2.tabActive, s2)
    ok(`${name}: 3 the tab shows the event log and Clear log, one log`, s2.row && s2.rows === 12 && s2.clear && s2.logs === 1, s2)
    ok(`${name}: 5 no sideways scroll`, s2.sideways <= 0, s2)
    if (phone) ok(`${name}: 5 tap targets: Monitoring tabs and Clear log >= 44 px`, s2.tabH.length > 0 && s2.tabH.every((x) => x >= 44) && s2.clearH.every((x) => x >= 44), { tabH: s2.tabH, clearH: s2.clearH })
    await checkRow(p, phone, name)
    const before = clears
    await click(p, '[data-test=events-clear]')
    const asked = await confirmShown(p)
    ok(`${name}: 8 Clear log asks first and sends no POST`, asked && clears === before, { asked, clears: clears - before })
    await click(p, '[data-testid=events-clear-confirm-cancel]')
    await sleep(400)
    const sc = await seen(p)
    const gone = !(await p.$('[data-testid=events-clear-confirm-confirm]'))
    ok(`${name}: 8 Cancel keeps every row and sends no POST`, gone && sc.rows === 12 && clears === before, { gone, rows: sc.rows, clears: clears - before })
    await click(p, '[data-test=events-clear]')
    await confirmShown(p)
    await click(p, '[data-testid=events-clear-confirm-confirm]')
    const s3 = await settle(p, '[data-test=events-empty]')
    const closed = !(await p.$('[data-testid=events-clear-confirm-confirm]'))
    ok(`${name}: 3 OK POSTs /clear and empties the log`, clears === before + 1 && s3.rows === 0 && s3.empty && closed, { clears: clears - before, closed, s3 })
  } catch (e) {
    ok(`${name}: tab ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events')
  try {
    const s = await settle(p)
    await shot(p, `${name}-deep-link`)
    ok(`${name}: 4 /events lands on Monitoring -> Events with the log`, s.path.endsWith('/monitoring/events') && s.tabActive && s.row, s)
    ok(`${name}: 5 no sideways scroll on the deep link`, s.sideways <= 0, s)
  } catch (e) {
    ok(`${name}: deep link ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events#5')
  try {
    const s = await settle(p, '.events-row--focus')
    ok(`${name}: 4 /events#5 keeps the hash, row 5 focused`, s.path.endsWith('/monitoring/events') && s.hash === '#5' && s.focus === '5', s)
  } catch (e) {
    ok(`${name}: hash link ran`, false, String(e.message || e))
  } finally {
    await p.close()
  }
  await checkSheet(browser, base, vp, name)
  await checkSelect(browser, base, vp, name)
}

/* spec 162 C24 + C25: what is checked, and what the bar shows */
const picked = (p) => p.evaluate(() => ({
  checked: [...document.querySelectorAll('[data-test=events-row]')]
    .filter((r) => r.querySelector('[data-test=events-row-check]')?.checked).map((r) => r.id),
  count: document.querySelector('[data-test=events-bulk-bar]')?.getAttribute('data-count') || '',
  clear: Boolean(document.querySelector('[data-test=events-clear]')),
}))
/* a click on row <id>'s box, with or without shift */
const tickRow = (p, id, shift = false) => p.evaluate((rid, sh) => {
  const box = document.getElementById(rid)?.querySelector('[data-test=events-row-check]')
  if (!box) throw new Error('no box on row ' + rid)
  box.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, shiftKey: sh }))
}, String(id), shift)

async function checkSelect(browser, base, vp, name) {
  const phone = vp.mobile
  const p = await open(browser, base, vp, '/monitoring/events')
  try {
    await settle(p)
    for (const id of [12, 11, 10]) { await tickRow(p, id); await sleep(150) }
    await tickRow(p, 5, true)
    await p.waitForSelector('[data-test=events-bulk-bar]', { visible: true, timeout: 8000 })
    await sleep(300)
    const want = ['12', '11', '10', '9', '8', '7', '6', '5']
    const s1 = await picked(p)
    await shot(p, `${name}-select`)
    ok(`${name}: 9 three checks and a shift-click 5 below the third -> 8 checked`, s1.checked.join(',') === want.join(',') && s1.count === '8', s1)
    ok(`${name}: 9 the bar takes Clear log's place`, !s1.clear, s1)
    await openSortSheet(p, phone)
    await clickSortMessage(p)
    if (phone) { await click(p, '[data-test=events-sheet-scrim]'); await sleep(200) }
    await openFilterSheet(p, phone)
    await setField(p, '[data-test=events-filter-source]', 'api')
    if (phone) { await click(p, '[data-test=events-sheet-scrim]'); await sleep(200) }
    const sf = await picked(p)
    ok(`${name}: 9 the selection survives a sort and a filter`, sf.count === '8', sf)
    /* the head's Clear filters gives way to the bar on the desktop: empty the field */
    await openFilterSheet(p, phone)
    await setField(p, '[data-test=events-filter-source]', '')
    if (phone) { await click(p, '[data-test=events-sheet-scrim]'); await sleep(200) }
    await sleep(300)
    const before = deletes.length
    await click(p, '[data-test=events-bulk-delete]')
    const asked = Boolean(await p.waitForSelector('[data-testid=events-delete-confirm-confirm]', { visible: true, timeout: 5000 }).catch(() => null))
    ok(`${name}: 9 Delete selected asks first and sends no POST`, asked && deletes.length === before, { asked, posts: deletes.length - before })
    await click(p, '[data-testid=events-delete-confirm-cancel]')
    await sleep(400)
    const sc = await seen(p)
    ok(`${name}: 9 Cancel keeps every row and sends no POST`, sc.rows === 12 && deletes.length === before, { rows: sc.rows, posts: deletes.length - before })
    await click(p, '[data-test=events-bulk-delete]')
    await p.waitForSelector('[data-testid=events-delete-confirm-confirm]', { visible: true, timeout: 5000 })
    await click(p, '[data-testid=events-delete-confirm-confirm]')
    await p.waitForFunction(() => document.querySelectorAll('[data-test=events-row]').length < 12, { timeout: 8000 }).catch(() => {})
    await sleep(400)
    const sent = (deletes[before] || []).map(String).sort()
    const left = await rowIds(p)
    const s2 = await picked(p)
    ok(`${name}: 9 OK POSTs /delete once with exactly the 8 checked ids`, deletes.length === before + 1 && sent.join(',') === [...want].sort().join(','), { posts: deletes.length - before, sent })
    ok(`${name}: 9 those 8 leave, the 4 unchecked stay, nothing stays checked`, [...left].sort().join(',') === '1,2,3,4' && s2.count === '' && s2.clear, { left, s2 })
  } catch (e) {
    ok(`${name}: select and delete ran`, false, String(e && e.message || e))
  } finally {
    await p.close()
  }
}

async function confirmShown(p) {
  return Boolean(await p.waitForSelector('[data-testid=events-clear-confirm-confirm]', { visible: true, timeout: 5000 }).catch(() => null))
}

/* spec 162 C1 + C3: what event 12's cells read, and the label each card shows */
async function checkRow(p, phone, name) {
  const r = await p.evaluate(() => {
    const row = document.getElementById('12')
    const cell = (sel) => row?.querySelector(sel)
    const label = (el) => (el ? getComputedStyle(el, '::before').content.replace(/^"|"$/g, '') : '')
    const req = cell('[data-test=events-request]')
    const code = cell('[data-test=events-code]')
    const when = cell('[data-test=events-when]')
    return {
      request: (req?.textContent || '').trim(),
      codes: [...(code?.querySelectorAll('code') || [])].map((e) => (e.textContent || '').trim()),
      codeLines: [...(code?.querySelectorAll('code') || [])].map((e) => Math.round(e.getBoundingClientRect().top)),
      reqLabel: label(req),
      codeLabel: label(code),
      reqVisible: Boolean(req && req.getBoundingClientRect().width > 0),
      when: (when?.textContent || '').trim(),
      hover: when?.getAttribute('title') || '',
      head: [...document.querySelectorAll('[data-test=events-table] thead tr:first-child th')].map((e) => (e.textContent || '').trim().replace(/[▲▼]/g, '')),
    }
  })
  ok(`${name}: 7 the request cell reads POST /v1/x`, r.reqVisible && r.request === 'POST /v1/x', r)
  ok(`${name}: 7 the code cell reads bad_request, then TypeError below`, r.codes.join('|') === 'bad_request|TypeError' && r.codeLines[1] > r.codeLines[0], r)
  if (phone) ok(`${name}: 7 the phone card labels Request and Code`, r.reqLabel === 'Request' && r.codeLabel === 'Code', r)
  /* spec 162 B7: the box column comes first */
  else ok(`${name}: 7 the desktop head has Request and Code after Status`, r.head.slice(4, 7).join('|') === 'Status|Request|Code', r.head)
  ok(`${name}: 7 When reads ISO 8601 with seconds and offset, the hover the Z instant`,
    /^2026-10-24 \d{2}:00:00[+-]\d{2}:\d{2}$/.test(r.when) && r.hover === '2026-10-24T08:00:00Z', { when: r.when, hover: r.hover })
}

const firstMessage = (p) => p.$eval('[data-test=events-row] [data-test=events-message]', (e) => (e.textContent || '').trim())
const rowIds = (p) => p.$$eval('[data-test=events-row]', (els) => els.map((e) => e.id))

async function setField(p, sel, value) {
  await p.waitForSelector(sel, { visible: true, timeout: 8000 })
  await p.$eval(sel, (el, v) => {
    const proto = el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype
    const desc = Object.getOwnPropertyDescriptor(proto, 'value')
    if (!desc || !desc.set) throw new Error('no value setter')
    desc.set.call(el, v)
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  }, value)
  await sleep(250)
}

async function openSortSheet(p, phone) {
  if (!phone) return
  await click(p, '[data-test=events-sort-open]')
  await p.waitForSelector('[data-test=events-sort-sheet]', { visible: true, timeout: 8000 })
  await sleep(200)
}

async function openFilterSheet(p, phone) {
  if (!phone) return
  await click(p, '[data-test=events-filters-open]')
  await p.waitForSelector('[data-test=events-filters]', { visible: true, timeout: 8000 })
  await sleep(200)
}

async function clickSortMessage(p) {
  await click(p, '[data-test=events-sort-message]')
  await sleep(250)
}

/* SPL-3366: a fresh page, after steps 1-5, so Clear log's empty log stays
   the proof it was. Phone and desktop mount one set of controls each. */
async function checkSheet(browser, base, vp, name) {
  const phone = vp.mobile
  let p = await open(browser, base, vp, '/monitoring/events')
  try {
    const s0 = await settle(p)
    const m0 = await firstMessage(p)
    ok(`${name}: sort default first row is event 12`, s0.rows === 12 && m0 === 'event 12', { rows: s0.rows, m0 })
    ok(`${name}: sort page has no sideways scroll`, s0.sideways <= 0, s0)
    if (phone) {
      const bar = await p.$eval('[data-test=events-sorted-by]', (e) => e.getAttribute('data-sort') || '')
      const h = await p.$eval('[data-test=events-sort-open]', (e) => Math.round(e.getBoundingClientRect().height))
      const hf = await p.$eval('[data-test=events-filters-open]', (e) => Math.round(e.getBoundingClientRect().height))
      ok(`${name}: phone sort starts at When newest, buttons >= 44 px`, bar === '' && h >= 44 && hf >= 44, { bar, h, hf })
    } else {
      const aria = await p.$eval('[data-test=events-sort-message]', (e) => e.closest('th')?.getAttribute('aria-sort') || '')
      ok(`${name}: desktop message header aria-sort is none`, aria === 'none', { aria })
    }
    await openSortSheet(p, phone)
    await clickSortMessage(p)
    const m1 = await firstMessage(p)
    ok(`${name}: message sort ascending starts at event 1`, m1 === 'event 1', { m1 })
    if (phone) {
      const ds = await p.$eval('[data-test=events-sorted-by]', (e) => e.getAttribute('data-sort') || '')
      const sheet = await p.$('[data-test=events-sort-sheet]')
      ok(`${name}: phone sort sheet stays open on message`, Boolean(sheet) && ds === 'message', { ds })
    } else {
      const aria = await p.$eval('[data-test=events-sort-message]', (e) => e.closest('th')?.getAttribute('aria-sort') || '')
      ok(`${name}: desktop message header aria-sort is ascending`, aria === 'ascending', { aria })
    }
    await clickSortMessage(p)
    const m2 = await firstMessage(p)
    ok(`${name}: message sort descending starts at event 9`, m2 === 'event 9', { m2 })
    if (!phone) {
      const aria = await p.$eval('[data-test=events-sort-message]', (e) => e.closest('th')?.getAttribute('aria-sort') || '')
      ok(`${name}: desktop message header aria-sort is descending`, aria === 'descending', { aria })
    }
    await clickSortMessage(p)
    const m3 = await firstMessage(p)
    ok(`${name}: a third message sort returns to event 12`, m3 === 'event 12', { m3 })
    if (phone) {
      await click(p, '[data-test=events-sheet-scrim]')
      await sleep(200)
      const gone = await p.$('[data-test=events-sort-sheet]')
      ok(`${name}: phone sort sheet closes from the scrim`, !gone)
    }
    await openFilterSheet(p, phone)
    await setField(p, '[data-test=events-filter-message]', 'zzz-no-such')
    await p.waitForSelector('[data-test=events-no-match]', { visible: true, timeout: 8000 })
    const sn = await seen(p)
    const filterThere = Boolean(await p.$('[data-test=events-filter-message]'))
    ok(`${name}: a filter with no match keeps the controls and Clear log`, sn.rows === 0 && !sn.empty && sn.clear && filterThere, sn)
    await click(p, '[data-test=events-filter-clear]')
    await sleep(300)
    const sc = await seen(p)
    ok(`${name}: Clear filters restores every row`, sc.rows === 12 && !sc.empty, sc)
    await setField(p, '[data-test=events-filter-source]', 'api')
    const ss = await seen(p)
    ok(`${name}: source api leaves four rows`, ss.rows === 4, ss)
    await click(p, '[data-test=events-filter-clear]')
    await sleep(300)
    await setField(p, '[data-test=events-filter-status]', '0')
    const st = await seen(p)
    ok(`${name}: status 0 leaves three rows`, st.rows === 3, st)
    const side = await seen(p)
    ok(`${name}: filtered page has no sideways scroll`, side.sideways <= 0, side)
  } catch (e) {
    ok(`${name}: sort and filter ran`, false, String(e && e.message || e))
  } finally {
    await p.close()
  }
  p = await open(browser, base, vp, '/events#5')
  try {
    await settle(p, '.events-row--focus')
    await openFilterSheet(p, phone)
    await setField(p, '[data-test=events-filter-message]', 'event 12')
    await sleep(200)
    const ids = await rowIds(p)
    const s = await seen(p)
    ok(`${name}: a hash row stays when the filter would hide it`,
      s.path.endsWith('/monitoring/events') && s.hash === '#5' && s.focus === '5' && s.rows === 2 && ids.includes('12') && ids.includes('5'),
      { path: s.path, hash: s.hash, focus: s.focus, rows: s.rows, ids })
  } catch (e) {
    ok(`${name}: hash filter ran`, false, String(e && e.message || e))
  } finally {
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  await check(browser, server.base, { w: 360, h: 800, mobile: true }, 'phone-360')
  await check(browser, server.base, { w: 1440, h: 900, mobile: false }, 'desktop-1440')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
