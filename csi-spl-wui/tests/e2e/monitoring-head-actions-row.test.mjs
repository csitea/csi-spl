// Spec 153 3.16 (SPL-4730; owner HUM-10, t1 3238db2c, msg 2dd25d62: "the
// refresh and clear filters buttons shoud be on the ame row as the tabs , but
// on the right side"): on Monitoring -> Lanes, Topics and Tokens, Refresh, its
// age and (Lanes, Topics) Clear filters sit in #monitoring-head-actions, on
// the tabs' row, after the last tab and at the row's right end.
//
// The mock bundle as an operator admin, at 1440x900, 390x844, 360x800 and 320x640
// (touch below 800), for each tab:
//   1 the controls are inside #monitoring-head-actions
//   2 they and the tab bar share a row: each control's vertical middle lies
//     inside the bar's box
//   3 they start right of the bar (and of its last tab when it shows) and
//     end at the row's right side (the header's content edge, or the close X
//     after them on a desktop)
//   4 no page scroll; on a touch screen every control is >= 44 px tall
//   5 Refresh still works (the age goes back to 0..2 s); Clear filters is
//     disabled with no filter, a filter enables it, a click clears it
//   6 moving to the next tab leaves none of the controls behind
//   7 (SPL-4842; owner HUM-10, t1 2b0b6fbe, msg 36c3e4a5: "The refresh button
//     seems to be off on mobile on the lanes.") on a touch screen Refresh is
//     whole in the viewport, overlaps neither the tab bar nor its age, takes
//     a tap at its middle, and clears the row's top edge and bottom line by
//     ROW_GAP px (it filled the row: flush on the line above the tabs and
//     standing over them); the age keeps "<n> s" on one line, also in a
//     narrower font (the owner's phone wrapped "Updated 3 | s ago")
// Plus the states without a list: first load (Refresh, no age, no Clear
// filters), an empty answer (no Clear filters), forbidden (Refresh only), and
// no empty row left where .ln-head was.
// Control: the bundle with the controls back in .ln-head / .tp-head /
// .tk-head (origin/master dd281db78) FAILS 1, 2 and 3 on every tab and size;
// the bundle of origin/master c7b791726 (before SPL-4842) FAILS 7's row gap
// and narrow-font age on every tab at every phone size.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-head-actions-row
//   SHOT_DIR=<dir> keeps a screenshot per tab and size.
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { TOKENS_MOCK_KEY, TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { LANES_MOCK_KEY } from '../../src/utils/monitoring-lanes.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
if (SHOT_DIR) mkdirSync(SHOT_DIR, { recursive: true })
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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

const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }, { width: 360, height: 800 }, { width: 320, height: 640 }]
const TAP = 44
/* 7: the least space between a phone's actions and the tab row's edges */
const ROW_GAP = 4
/* the tab bar's least width on a phone: one tab and the start of the next
   (Agents is 70 px); the bar scrolls inside itself, the open tab in view */
const TABS_MIN = 110
/* each tab, its controls (data-test, in row order) and the one it moves to next */
const TABS = [
  { id: 'lanes', ready: 'lanes-row', controls: ['lanes-refresh', 'lanes-age', 'lanes-filter-clear'], next: 'topics' },
  { id: 'topics', ready: 'topics-row', controls: ['topics-refresh', 'topics-age', 'topics-filter-clear'], next: 'tokens' },
  { id: 'tokens', ready: 'tokens-agent-row', controls: ['tokens-refresh', 'tokens-age'], next: 'lanes' },
]
const ALL_CONTROLS = TABS.flatMap((t) => t.controls)

const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const waitFor = (p, sel, timeout = 20000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true, () => false)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** A fresh signed-in mock page; `operator` = an operator admin, `lanes` = the mock lanes scenario. */
async function monitoringPage(browser, base, { width, height }, { operator = true, lanes = 'topics' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const touch = width < 800
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch, deviceScaleFactor: 1 })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((opKey, op, lnKey, ln, tkKey) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem('spool.mock.me')
    if (op) localStorage.setItem(opKey, '1'); else localStorage.removeItem(opKey)
    if (ln) localStorage.setItem(lnKey, ln); else localStorage.removeItem(lnKey)
    localStorage.removeItem(tkKey)
  }, TOKENS_MOCK_OPERATOR_KEY, operator, LANES_MOCK_KEY, lanes, TOKENS_MOCK_KEY)
  return { ctx, p, touch }
}

/** The row's geometry: the tab bar, its last tab, the actions box, each control, what follows the box, the header's content edge, the page's sideways scroll. */
const geometry = (p, controls) => p.evaluate((ids) => {
  const box = (e) => { if (!e) return null; const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, h: r.height, w: r.width } }
  const nav = document.querySelector('[data-test=monitoring-tabs]')
  const tabs = nav ? [...nav.querySelectorAll('.monitoring-tab')] : []
  const actions = document.getElementById('monitoring-head-actions')
  const header = actions ? actions.closest('header') : null
  /* the slot ends the tab row's wrapper; the end close X, when shown, follows the wrapper */
  const after = actions ? (actions.nextElementSibling || actions.parentElement.nextElementSibling) : null
  const afterBox = after && after.getBoundingClientRect().width > 0 ? box(after) : null
  /* the row: the header on a desktop, the tab row's own box on a phone (the header dissolves there) */
  const wrap = actions ? actions.parentElement : null
  const row = wrap && getComputedStyle(wrap).display !== 'contents' ? wrap : header
  const hs = header ? getComputedStyle(header) : null
  const rs = row ? getComputedStyle(row) : null
  const rowContentEdge = row ? row.getBoundingClientRect().right - parseFloat(rs.paddingRight) - parseFloat(rs.borderRightWidth) : 0
  const doc = document.documentElement
  return {
    nav: box(nav),
    lastTab: box(tabs[tabs.length - 1]),
    activeTab: box(nav && nav.querySelector('.monitoring-tab--active')),
    navScroll: nav ? [nav.scrollLeft, nav.scrollWidth - nav.clientWidth] : null,
    actions: box(actions),
    afterBox,
    headerDisplay: hs ? hs.display : '',
    rowEdge: afterBox ? afterBox.l : rowContentEdge,
    controls: ids.map((id) => {
      const e = document.querySelector(`[data-test=${id}]`)
      return { id, in: Boolean(e && actions && actions.contains(e)), box: box(e) }
    }),
    xScroll: Math.max(0, doc.scrollWidth - doc.clientWidth),
  }
}, controls)

/** Checks 1..4 of one tab at one size. */
function checkRow(tag, g, touch) {
  const missing = g.controls.filter((c) => !c.box || c.box.w === 0).map((c) => c.id)
  ok(`${tag}: every control shows`, missing.length === 0, missing)
  ok(`${tag}: 1 the controls are in #monitoring-head-actions`, g.controls.every((c) => c.in), g.controls.filter((c) => !c.in).map((c) => c.id))
  const off = g.controls.filter((c) => c.box && g.nav && !((c.box.t + c.box.b) / 2 >= g.nav.t && (c.box.t + c.box.b) / 2 <= g.nav.b)).map((c) => c.id)
  ok(`${tag}: 2 the controls and the tabs share a row`, g.nav && off.length === 0, { off, nav: g.nav && [Math.round(g.nav.t), Math.round(g.nav.b)] })
  const startX = g.nav ? Math.min(g.nav.r, g.lastTab ? g.lastTab.r : g.nav.r) : Infinity
  const left = Math.min(...g.controls.filter((c) => c.box).map((c) => c.box.l))
  ok(`${tag}: 3 the controls start right of the last tab`, g.nav && left >= startX - 0.5, { left: Math.round(left), tabsEnd: Math.round(startX) })
  ok(`${tag}: 3 the controls end at the row's right side`, g.actions && g.rowEdge - g.actions.r >= -0.5 && g.rowEdge - g.actions.r <= 16, { end: g.actions && Math.round(g.actions.r), rowEdge: Math.round(g.rowEdge) })
  ok(`${tag}: 4 no page scroll`, g.xScroll === 0, g.xScroll)
  if (touch) {
    const short = g.controls.filter((c) => c.id.endsWith('-refresh') || c.id.endsWith('-clear')).filter((c) => !c.box || c.box.h < TAP || c.box.w < TAP).map((c) => [c.id, c.box && Math.round(c.box.w), c.box && Math.round(c.box.h)])
    ok(`${tag}: 4 every button is >= ${TAP} x ${TAP} px`, short.length === 0, short)
    ok(`${tag}: 4 the tab bar keeps >= ${TABS_MIN} px for its tabs`, g.nav && g.nav.w >= TABS_MIN, g.nav && Math.round(g.nav.w))
    /* < 1 px: scrollWidth is whole pixels, so the last tab may overrun by a sub-pixel at the scroll end */
    ok(`${tag}: 4 the open tab is in view inside the bar`, g.nav && g.activeTab && g.activeTab.l >= g.nav.l - 1 && g.activeTab.r <= g.nav.r + 1, { nav: g.nav && [g.nav.l, g.nav.r], tab: g.activeTab && [g.activeTab.l, g.activeTab.r], scroll: g.navScroll })
  }
}

/** 7: on a touch screen, Refresh in the row: whole, apart, tappable, off the row's edges; "<n> s" unbroken. */
async function checkPhone(p, tag, tab) {
  const g = await p.evaluate((rid, aid) => {
    const box = (e) => { if (!e) return null; const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom } }
    const btn = document.querySelector(`[data-test=${rid}]`)
    const b = box(btn)
    const hit = b ? document.elementFromPoint((b.l + b.r) / 2, (b.t + b.b) / 2) : null
    return {
      vw: document.documentElement.clientWidth,
      btn: b,
      row: box(document.querySelector('[data-test=monitoring-tabrow]')),
      nav: box(document.querySelector('[data-test=monitoring-tabs]')),
      age: box(document.querySelector(`[data-test=${aid}]`)),
      hit: Boolean(hit && btn.contains(hit)),
    }
  }, `${tab.id}-refresh`, `${tab.id}-age`)
  const apart = (a, b) => !a || !b || a.r <= b.l + 0.5 || b.r <= a.l + 0.5 || a.b <= b.t + 0.5 || b.b <= a.t + 0.5
  const b = g.btn
  ok(`${tag}: 7 Refresh is whole in the viewport`, b && b.l >= 0 && b.r <= g.vw && b.t >= 0, { btn: b && [Math.round(b.l), Math.round(b.r)], vw: g.vw })
  ok(`${tag}: 7 Refresh overlaps neither the tab bar nor its age`, b && apart(b, g.nav) && apart(b, g.age), { btn: b && [Math.round(b.l), Math.round(b.r)], nav: g.nav && Math.round(g.nav.r), age: g.age && Math.round(g.age.l) })
  ok(`${tag}: 7 a tap at Refresh's middle reaches it`, g.hit)
  ok(`${tag}: 7 Refresh clears the row's top edge and bottom line by >= ${ROW_GAP} px`, b && g.row && b.t - g.row.t >= ROW_GAP - 0.5 && g.row.b - b.b >= ROW_GAP - 0.5, { top: b && g.row && Math.round(b.t - g.row.t), bottom: b && g.row && Math.round(g.row.b - b.b) })
  /* the age's lines; "narrow" stands in for the owner's phone font (Roboto), narrower than the pinned DejaVu Sans */
  for (const narrow of [false, true]) {
    const lines = await p.$eval(`[data-test=${tab.id}-age]`, (e, n) => {
      e.style.letterSpacing = n ? '-0.04em' : ''
      const tn = [...e.childNodes].find((x) => x.nodeType === 3 && /\d/.test(x.textContent))
      const by = {}
      const r = document.createRange()
      for (let i = 0; tn && i < tn.length; i++) {
        r.setStart(tn, i); r.setEnd(tn, i + 1)
        const rc = r.getClientRects()[0]
        if (rc) by[Math.round(rc.top)] = (by[Math.round(rc.top)] || '') + tn.textContent[i]
      }
      e.style.letterSpacing = ''
      return Object.values(by).map((x) => x.trim())
    }, narrow).catch(() => [])
    ok(`${tag}: 7 the age keeps "<n> s" on one line${narrow ? ' (narrower font)' : ''}`, lines.some((l) => /\d+ s\b/.test(l)), lines)
  }
}

/** 5: Refresh resets the age; Clear filters off, on with a filter, clears it. */
async function checkWorks(p, tag, tab) {
  await sleep(3200)
  const before = await text(p, `[data-test=${tab.id}-age]`)
  await p.click(`[data-test=${tab.id}-refresh]`)
  const reset = await p.waitForFunction((sel) => /\b[0-2] s\b/.test(document.querySelector(sel)?.textContent || ''), { timeout: 8000 }, `[data-test=${tab.id}-age]`).then(() => true, () => false)
  ok(`${tag}: 5 Refresh reads again (the age back to 0..2 s)`, reset, [before, await text(p, `[data-test=${tab.id}-age]`)])
  if (!tab.controls.includes(`${tab.id}-filter-clear`)) return
  const clear = `[data-test=${tab.id}-filter-clear]`
  const disabled = () => p.$eval(clear, (b) => b.disabled).catch(() => null)
  ok(`${tag}: 5 Clear filters is disabled with no filter`, (await disabled()) === true)
  const rows = await count(p, `[data-test=${tab.ready}]`)
  await p.select(`[data-test=${tab.id}-filter-box]`, 'box-b')
  const narrowed = await p.waitForFunction((s, n) => document.querySelectorAll(s).length < n, { timeout: 5000 }, `[data-test=${tab.ready}]`, rows).then(() => true, () => false)
  ok(`${tag}: 5 a filter enables Clear filters`, narrowed && (await disabled()) === false, { rows, now: await count(p, `[data-test=${tab.ready}]`) })
  await p.click(clear)
  const back = await p.waitForFunction((s, n) => document.querySelectorAll(s).length === n, { timeout: 5000 }, `[data-test=${tab.ready}]`, rows).then(() => true, () => false)
  ok(`${tag}: 5 Clear filters brings every row back, and is disabled again`, back && (await disabled()) === true && (await count(p, `[data-test=${tab.id}-shown]`)) === 0)
}

/** 6: on the next tab no control of this one stays. */
async function checkLeave(p, tag, tab) {
  await p.click(`[data-test=monitoring-tab-${tab.next}]`)
  await waitFor(p, `[data-test=${tab.next}-page]`)
  await sleep(300)
  const own = TABS.find((t) => t.id === tab.next).controls
  const left = await p.$$eval('#monitoring-head-actions [data-test]', (els, keep) => els.map((e) => e.getAttribute('data-test')).filter((id) => !keep.includes(id)), own).catch(() => ['?'])
  const stray = []
  for (const id of tab.controls) if ((await count(p, `[data-test=${id}]`)) > 0) stray.push(id)
  ok(`${tag}: 6 on ${tab.next} none of its controls stays`, stray.length === 0 && left.filter((id) => ALL_CONTROLS.includes(id)).length === 0, { stray, left })
}

async function oneTab(browser, base, size, tab) {
  const tag = `${tab.id} ${size.width}x${size.height}`
  const { ctx, p, touch } = await monitoringPage(browser, base, size)
  try {
    await p.goto(base + `/monitoring/${tab.id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok(`${tag}: the tab renders its rows`, await waitFor(p, `[data-test=${tab.ready}]`))
    await waitFor(p, `[data-test=${tab.id}-age]`)
    checkRow(tag, await geometry(p, tab.controls), touch)
    if (touch) await checkPhone(p, tag, tab)
    const head = { lanes: '.ln-head', topics: '.tp-head', tokens: '.tk-head' }[tab.id]
    const empty = await p.$$eval(head, (els) => els.filter((e) => e.children.length === 0 || e.getBoundingClientRect().height === 0).length).catch(() => -1)
    ok(`${tag}: no empty row is left where the controls were`, empty === 0, empty)
    if (SHOT_DIR) await p.screenshot({ path: join(SHOT_DIR, `${tab.id}-${size.width}.png`) })
    await checkWorks(p, tag, tab)
    await checkLeave(p, tag, tab)
  } finally { await ctx.close() }
}

/** The states without a list: first load, empty, forbidden. */
async function states(browser, base, size) {
  const tag = `${size.width}x${size.height}`
  {
    const { ctx, p } = await monitoringPage(browser, base, size, { lanes: 'empty' })
    await p.goto(base + '/monitoring/lanes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const empty = await waitFor(p, '[data-test=lanes-empty]')
    ok(`lanes ${tag} empty: Refresh and the age on the row, no Clear filters, no .ln-head row`, empty
      && (await count(p, '#monitoring-head-actions [data-test=lanes-refresh]')) === 1 && (await count(p, '#monitoring-head-actions [data-test=lanes-age]')) === 1
      && (await count(p, '[data-test=lanes-filter-clear]')) === 0 && (await count(p, '.ln-head')) === 0)
    await ctx.close()
  }
  {
    const { ctx, p } = await monitoringPage(browser, base, size, { operator: false, lanes: '' })
    await p.goto(base + '/monitoring/lanes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const forbidden = await waitFor(p, '[data-test=lanes-forbidden]')
    ok(`lanes ${tag} forbidden: the sentence, Refresh on the row, no age, no Clear filters`, forbidden
      && (await count(p, '#monitoring-head-actions [data-test=lanes-refresh]')) === 1
      && (await count(p, '[data-test=lanes-age]')) === 0 && (await count(p, '[data-test=lanes-filter-clear]')) === 0)
    await ctx.close()
  }
  {
    /* first load: the controls come with the client, Refresh before any answer */
    const { ctx, p } = await monitoringPage(browser, base, size)
    await p.goto(base + '/monitoring/lanes', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    const refresh = await waitFor(p, '#monitoring-head-actions [data-test=lanes-refresh]')
    const age = await count(p, '[data-test=lanes-age]')
    const rows = await count(p, '[data-test=lanes-row]')
    ok(`lanes ${tag} first load: Refresh on the row; the age only with the answer`, refresh && (age === 0 || rows > 0), { age, rows })
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    for (const tab of TABS) await oneTab(browser, server.base, size, tab)
    await states(browser, server.base, size)
  }
} finally {
  await browser.close()
  await server.stop?.()
}
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
