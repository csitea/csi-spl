// SPL-5235 (spec 153 3.25; owner HUM-10, t1 389ad5fd, msg e3fad8e4: "The
// lanes view on mobile should be improved similarly to how the releases
// listing was improved on mobile: maximum utilization of space"). In a REAL
// browser, mock bundle. On a phone each lane is a dense card across the
// whole width; the desktop keeps its table. The mock fleet: c-085, a-277,
// m-039 (monitoring-lanes-url.test.mjs).
//
//   P1  320 / 360 / 390: nothing scrolls sideways, the page nor the list
//   P2  a card spans the list's width and holds at most 3 lines
//   P6  a lane with 4 issue keys (mock 'keys', c-404) is still 3 lines,
//       nothing sideways, every key in the cell's title (W1)
//   P3  every cell of the row is on the card, inside it, none hidden
//   P4  the agent opens the LaneDialog
//   P5  a sort click and a filter still apply (SPL-5276: through the Event
//       log's phone bar, its Sort and Filters sheets)
//   D1  1440: the table is a table, one row per lane, a cell per column
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e monitoring-lanes-phone
//   SHOT_DIR=<dir> also writes a screenshot per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { tapScrim } from './lib/sheet-scrim.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { LANE_COLUMNS, LANES_MOCK_KEY } from '../../src/utils/monitoring-lanes.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined || pass ? '' : ' ' + JSON.stringify(ev)}`)
}

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

const PHONES = [320, 360, 390].map((w) => ({ tag: String(w), vp: { width: w, height: 844, isMobile: true, hasTouch: true } }))
const DESKTOP = { tag: '1440', vp: { width: 1440, height: 900 } }
const PATH = '/monitoring/lanes'
const SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'member@example.com', t: 'mock' })
const SEED = { 'spool.mock.session': SESSION, [TOKENS_MOCK_OPERATOR_KEY]: '1' }
/* the row's cells, one per LANE_COLUMNS entry, by their data-test */
const CELLS = ['lanes-agent', 'lanes-box', 'lanes-priority', 'lanes-vendor', 'lanes-state', 'lanes-scope', 'lanes-topic', 'lanes-issues', 'lanes-origin', 'lanes-updated', 'lanes-active', 'lanes-workspace']

async function open(browser, vp, path, seed = SEED) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v) } catch { /* about:blank */ }
  }, seed)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=lanes-row]', { timeout: 15000 })
  return { p, ctx, errors }
}

const order = (p) => p.$$eval('[data-test=lanes-row]', (els) => els.map((e) => e.getAttribute('data-agent')).join(','))
const rowsAre = (p, want) => p.waitForFunction((w) => [...document.querySelectorAll('[data-test=lanes-row]')].map((e) => e.getAttribute('data-agent')).join(',') === w,
  { timeout: 8000 }, want).then(() => true, () => false)

/** sideways overflow of the page and of the list, and each card's measure */
const measure = (p) => p.evaluate((cells) => {
  const doc = document.scrollingElement || document.documentElement
  const wrap = document.querySelector('.ln-table-wrap')
  const list = wrap.getBoundingClientRect()
  const cards = [...document.querySelectorAll('[data-test=lanes-row]')].map((row) => {
    const r = row.getBoundingClientRect()
    const shown = cells.filter((c) => row.querySelector(`[data-test=${c}]`))
    /* a cell's text box is inside the card; an empty cell (no origin issue) is hidden by design */
    const out = shown.filter((c) => {
      const el = row.querySelector(`[data-test=${c}]`)
      if (!el.textContent.trim()) return false
      const b = el.getBoundingClientRect()
      return b.width === 0 || b.left < r.left - 0.5 || b.right > r.right + 0.5
    })
    /* a line per text line of the card: every line box of every cell, a new line 8 px below the last */
    const tops = shown.map((c) => row.querySelector(`[data-test=${c}]`)).filter((el) => el.textContent.trim()).flatMap((el) => {
      const range = document.createRange()
      range.selectNodeContents(el)
      return [...range.getClientRects()].map((b) => b.top)
    }).sort((a, b) => a - b)
    const lines = tops.reduce((n, top, i) => (i === 0 || top - tops[i - 1] > 8 ? n + 1 : n), 0)
    return { agent: row.getAttribute('data-agent'), width: r.width, missing: cells.filter((c) => !shown.includes(c)), out, lines }
  })
  return { page: [doc.scrollWidth, doc.clientWidth], list: [wrap.scrollWidth, wrap.clientWidth], listWidth: list.width, main: document.querySelector('[data-test=lanes-page]').getBoundingClientRect().width, cards }
}, CELLS)

let server
const browser = await launch()
try {
  server = await startServer()
  for (const { tag, vp } of PHONES) {
    const { p, ctx, errors } = await open(browser, vp, PATH)
    const m = await measure(p)
    ok(`P1 ${tag}: the page does not scroll sideways`, m.page[0] <= m.page[1], m.page)
    ok(`P1b ${tag}: the list does not scroll sideways`, m.list[0] <= m.list[1], m.list)
    ok(`P2 ${tag}: each card spans the list's width`, m.cards.length === 3 && m.cards.every((c) => Math.abs(c.width - m.listWidth) <= 1), { listWidth: m.listWidth, cards: m.cards.map((c) => c.width) })
    ok(`P2b ${tag}: each card is at most 3 lines`, m.cards.every((c) => c.lines <= 3), m.cards.map((c) => [c.agent, c.lines]))
    ok(`P3 ${tag}: every cell of the row is on its card, inside it`, m.cards.every((c) => c.missing.length === 0 && c.out.length === 0), m.cards.map((c) => [c.agent, c.missing, c.out]))
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lanes-phone-${tag}.png`, fullPage: true })

    await p.click('[data-test=lanes-row][data-agent="a-277"] [data-test=lanes-open]')
    const dialog = await p.waitForSelector('[role=dialog]', { timeout: 8000 }).then(() => true, () => false)
    ok(`P4 ${tag}: the card's agent opens the LaneDialog`, dialog)
    await p.keyboard.press('Escape')
    await p.waitForFunction(() => !document.querySelector('[role=dialog]'), { timeout: 5000 }).catch(() => {})

    const before = await order(p)
    await p.click('[data-test=lanes-sort-open]')
    await p.waitForSelector('[data-test=lanes-sort-sheet] [data-test=lanes-sort-agent]', { visible: true, timeout: 8000 })
    await p.click('[data-test=lanes-sort-sheet] [data-test=lanes-sort-agent]')
    await tapScrim(p, 'lanes')
    const asc = before.split(',').sort().join(',')
    ok(`P5 ${tag}: a sort click orders the cards`, await rowsAre(p, asc), { before, after: await order(p) })
    await p.click('[data-test=lanes-filters-open]')
    await p.waitForSelector('[data-test=lanes-filters] [data-test=lanes-filter-vendor]', { visible: true, timeout: 8000 })
    await p.select('[data-test=lanes-filters] [data-test=lanes-filter-vendor]', 'mistral')
    await tapScrim(p, 'lanes')
    ok(`P5b ${tag}: a filter leaves its cards only`, await rowsAre(p, 'm-039'), await order(p))
    ok(`P5c ${tag}: no page error`, errors.length === 0, errors)
    await ctx.close()

    const k = await open(browser, vp, PATH, { ...SEED, [LANES_MOCK_KEY]: 'keys' })
    const mk = await measure(k.p)
    const c404 = mk.cards.find((c) => c.agent === 'c-404')
    ok(`P6 ${tag}: a card with 4 issue keys is at most 3 lines`, !!c404 && mk.cards.every((c) => c.lines <= 3), mk.cards.map((c) => [c.agent, c.lines]))
    ok(`P6b ${tag}: with 4 keys nothing scrolls sideways, every cell inside its card`, mk.page[0] <= mk.page[1] && mk.list[0] <= mk.list[1] && mk.cards.every((c) => c.missing.length === 0 && c.out.length === 0), { page: mk.page, list: mk.list, out: mk.cards.map((c) => [c.agent, c.out]) })
    const title = await k.p.$eval('[data-test=lanes-row][data-agent="c-404"] [data-test=lanes-issues]', (el) => el.getAttribute('title') || '')
    ok(`P6c ${tag}: the issue cell's title names every key`, ['SPL-4041', 'SPL-4042', 'SPL-4043', 'SPL-4044'].every((key) => title.includes(key)), title)
    if (process.env.SHOT_DIR) await k.p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lanes-phone-keys-${tag}.png`, fullPage: true })
    await k.ctx.close()
  }

  const { p, ctx } = await open(browser, DESKTOP.vp, PATH)
  const d = await p.evaluate(() => {
    const table = document.querySelector('[data-test=lanes-table]')
    const row = document.querySelector('[data-test=lanes-row]')
    return { table: getComputedStyle(table).display, row: getComputedStyle(row).display, cells: row.children.length, heads: document.querySelectorAll('[data-test=lanes-table] thead tr:first-child th').length }
  })
  ok('D1 1440: the desktop keeps its table, a cell per column', d.table === 'table' && d.row === 'table-row' && d.cells === LANE_COLUMNS.length && d.heads === LANE_COLUMNS.length, d)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lanes-phone-1440.png`, fullPage: true })
  await ctx.close()
} finally {
  await browser.close()
  if (server) await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
