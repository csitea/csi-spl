// SPL-5430 (spec 153 3.29; owner HUM-10, t1 5804c44c, msg b65c7989: "The
// visual layout of the topics in the monitoring should be quite similar to
// the visual layout of the lanes, and it should behave the same way,
// including the refresh button"). In a REAL browser, mock bundle, at 1440
// and 390. The mock 'topics' fleet: three topics: the mock topic (c-085,
// c-733; Mock workspace, #monitoring), 0b0c0d0e-... (a-277, agy; Other
// workspace) and the no-topic row (m-039; Mock workspace).
//
//   T1  the sheet is the Lanes one: SheetHead names + a filter row on a
//       desktop; the phone bar (Sort, Filters) and cards on a phone
//   T2  Refresh where Lanes has it: last on the tabs' row on a desktop, the
//       bottom centre (PhoneDockButton) on a phone; it reads again
//   T3  a URL with a sort and filters: those set, those rows
//   T4  Refresh and reload keep the list and the address
//   T5  a filter change rewrites the address, no history entry added
//   T6  a sort click sorts; Clear filters drops the filter parameters
//   T7  nothing scrolls sideways; no page error
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e monitoring-topics-like-lanes
//   SHOT_DIR=<dir> also writes a screenshot of Topics and Lanes per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { tapScrim } from './lib/sheet-scrim.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { LANES_MOCK_KEY, LANES_MOCK_TOPIC } from '../../src/utils/monitoring-lanes.mjs'

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

const VIEWPORTS = [
  { tag: '1440', vp: { width: 1440, height: 900 } },
  { tag: '390', vp: { width: 390, height: 844, isMobile: true, hasTouch: true } },
]
const PATH = '/monitoring/topics'
const OTHER = '0b0c0d0e-1111-4222-8333-444455556666'
const SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'member@example.com', t: 'mock' })
const SEED = { 'spool.mock.session': SESSION, [TOKENS_MOCK_OPERATOR_KEY]: '1', [LANES_MOCK_KEY]: 'topics' }

async function open(browser, vp, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v) } catch { /* about:blank */ }
  }, SEED)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return { p, ctx, errors }
}

const order = (p) => p.$$eval('[data-test=topics-row]', (els) => els.map((e) => e.getAttribute('data-topic') || '-').join(',')).catch(() => '')
const rowsAre = (p, want) => p.waitForFunction((w) => document.querySelector('[data-test=topics-table]')
  && [...document.querySelectorAll('[data-test=topics-row]')].map((e) => e.getAttribute('data-topic') || '-').join(',') === w, { timeout: 15000 }, want).then(() => true, () => false)
const params = (p) => p.evaluate(() => Object.fromEntries(new URL(window.location.href).searchParams))
const urlIs = (p, want) => p.waitForFunction((w) => JSON.stringify([...new URL(window.location.href).searchParams].sort()) === w, { timeout: 8000 },
  JSON.stringify(Object.entries(want).sort())).then(() => true, () => false)
const histLen = (p) => p.evaluate(() => history.length)
const phoneOf = (vp) => vp.width <= 820
/* a phone's filters live in the Filters sheet: open it around `fn` (the scrim closes it) */
async function inFilters(p, vp, fn) {
  if (!phoneOf(vp)) return fn()
  await p.click('[data-test=topics-filters-open]')
  await p.waitForSelector('[data-test=topics-filters]', { visible: true, timeout: 8000 })
  try { return await fn() } finally { await tapScrim(p, 'topics') }
}
/* a sort click: the name on a desktop, its row in the Sort sheet on a phone */
async function sortBy(p, vp, col) {
  if (!phoneOf(vp)) return p.click(`[data-test=topics-sort-${col}]`)
  await p.click('[data-test=topics-sort-open]')
  await p.waitForSelector(`[data-test=topics-sort-sheet] [data-test=topics-sort-${col}]`, { visible: true, timeout: 8000 })
  await p.click(`[data-test=topics-sort-sheet] [data-test=topics-sort-${col}]`)
  await tapScrim(p, 'topics')
}
/** Refresh: where it sits (in the tabs' row or not) and a click that waits for the read to end. */
async function refresh(p) {
  const inRow = await p.$eval('[data-test=topics-refresh]', (b) => Boolean(b.closest('#monitoring-head-actions'))).catch(() => null)
  await p.click('[data-test=topics-refresh]')
  await p.waitForFunction(() => document.querySelector('[data-test=topics-refresh]')?.getAttribute('aria-busy') === 'false', { timeout: 8000 }).catch(() => null)
  return inRow
}

/** T1, T2, T7: the Lanes layout at this size, on Topics and on Lanes alike. */
async function layout(browser, tag, vp) {
  const phone = phoneOf(vp)
  for (const page of ['topics', 'lanes']) {
    const a = await open(browser, vp, '/monitoring/' + page)
    const { p } = a
    await p.waitForSelector(`[data-test=${page}-row]`, { timeout: 15000 }).catch(() => null)
    await p.waitForSelector(`[data-test=${page}-age]`, { timeout: 15000 }).catch(() => null)
    const g = await p.evaluate((id) => {
      const q = (t) => document.querySelector(`[data-test=${t}]`)
      const refreshBtn = q(id + '-refresh')
      const r = refreshBtn ? refreshBtn.getBoundingClientRect() : null
      return {
        sortButtons: document.querySelectorAll(`[data-test=${id}-table] thead button.sheet-sort-h`).length,
        filterRow: Boolean(q(id + '-filters')),
        bar: Boolean(q(id + '-mbar')),
        refreshInRow: Boolean(refreshBtn && refreshBtn.closest('#monitoring-head-actions')),
        refreshLast: (() => { const els = [...document.querySelectorAll('#monitoring-head-actions [data-test]')]; return els.length > 0 && els[els.length - 1] === refreshBtn })(),
        refreshCentre: r ? Math.abs((r.left + r.right) / 2 - document.documentElement.clientWidth / 2) : null,
        clear: Boolean(q(id + '-filter-clear')),
        rowDisplay: q(id + '-row') ? getComputedStyle(q(id + '-row')).display : '',
        xScroll: Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth),
      }
    }, page)
    const want = phone
      ? g.sortButtons === 0 && !g.filterRow && g.bar && !g.refreshInRow && g.refreshCentre !== null && g.refreshCentre < 2 && g.rowDisplay === 'flex'
      : g.sortButtons === 6 + (page === 'lanes' ? 6 : 0) && g.filterRow && !g.bar && g.refreshInRow && g.refreshLast && g.rowDisplay === 'table-row'
    ok(`T1/T2 ${tag} ${page}: the Lanes layout (${phone ? 'phone bar, cards, Refresh at the bottom centre' : 'sort names, filter row, Refresh last on the tabs\' row'})`, want, g)
    ok(`T1 ${tag} ${page}: no Clear filters with no filter`, !g.clear, g)
    ok(`T7 ${tag} ${page}: nothing scrolls sideways`, g.xScroll === 0, g.xScroll)
    if (page === 'topics') {
      const before = await p.$eval('[data-test=topics-age]', (e) => e.textContent).catch(() => '')
      await new Promise((r) => setTimeout(r, 2200))
      await refresh(p)
      const reset = await p.waitForFunction(() => /\b[0-1] s\b/.test(document.querySelector('[data-test=topics-age]')?.textContent || ''), { timeout: 8000 }).then(() => true, () => false)
      ok(`T2 ${tag} topics: Refresh reads again (the age back to 0..1 s)`, reset, [before, await p.$eval('[data-test=topics-age]', (e) => e.textContent).catch(() => '')])
    }
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-${page}-like-lanes-${tag}.png`, fullPage: true })
    await a.ctx.close()
    ok(`T7 ${tag} ${page}: no page error`, a.errors.length === 0, a.errors)
  }
}

/** T3..T6: the address, Refresh, reload, a filter change, a sort and Clear filters. */
async function behaviour(browser, tag, vp) {
  const WHOLE = { sort: 'lanes', dir: 'desc', lanes: 'claude', workspace: 'mock' }
  const a = await open(browser, vp, PATH + '?' + new URLSearchParams(WHOLE).toString())
  const { p } = a
  const set = await inFilters(p, vp, () => p.evaluate(() => ({
    lanes: document.querySelector('[data-test=topics-filter-lanes]')?.value ?? null,
    workspace: document.querySelector('[data-test=topics-filter-workspace]')?.value ?? null,
  })))
  ok(`T3 ${tag}: a URL with a sort and filters: those set, the one topic with claude lanes`, (await rowsAre(p, LANES_MOCK_TOPIC)) && set.lanes === 'claude' && set.workspace === 'mock', { rows: await order(p), set })
  ok(`T3 ${tag}: the address still names them`, await urlIs(p, WHOLE), await params(p))
  const inRow = await refresh(p)
  ok(`T4 ${tag}: Refresh (${phoneOf(vp) ? 'bottom centre' : 'tabs\' row'}) keeps the list and the address`, inRow === !phoneOf(vp) && (await rowsAre(p, LANES_MOCK_TOPIC)) && (await urlIs(p, WHOLE)), { inRow, q: await params(p) })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  ok(`T4 ${tag}: reload keeps it`, (await rowsAre(p, LANES_MOCK_TOPIC)) && (await urlIs(p, WHOLE)), await params(p))

  const h0 = await histLen(p)
  await inFilters(p, vp, async () => {
    await p.$eval('[data-test=topics-filter-lanes]', (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
    await p.select('[data-test=topics-filter-workspace]', '')
    await p.select('[data-test=topics-filter-active]', '1h')
  })
  const rest = { sort: 'lanes', dir: 'desc', active: '1h' }
  ok(`T5 ${tag}: a filter change rewrites the address and the rows (within 1 h: all three)`, (await urlIs(p, rest)) && (await order(p)).split(',').length === 3 && (await order(p)).startsWith(LANES_MOCK_TOPIC), { q: await params(p), rows: await order(p) })
  ok(`T5 ${tag}: the shown line counts them`, (await p.$eval('[data-test=topics-shown]', (e) => e.textContent.trim()).catch(() => '')) === '3 of 3 topics')
  const inRow2 = await refresh(p)
  ok(`T4 ${tag}: a filter survives Refresh`, inRow2 === !phoneOf(vp) && (await urlIs(p, rest)) && (await inFilters(p, vp, () => p.$eval('[data-test=topics-filter-active]', (e) => e.value))) === '1h', await params(p))
  await inFilters(p, vp, () => p.select('[data-test=topics-filter-workspace]', 'w2'))
  ok(`T5 ${tag}: the workspace filter keeps Other workspace's topic`, (await rowsAre(p, OTHER)) && (await urlIs(p, { ...rest, workspace: 'w2' })), { q: await params(p), rows: await order(p) })
  ok(`T5 ${tag}: no history entry added by any of it`, (await histLen(p)) === h0, [h0, await histLen(p)])

  if (phoneOf(vp)) await inFilters(p, vp, () => p.click('[data-test=topics-filter-clear]'))
  else await p.click('[data-test=topics-filter-clear]')
  ok(`T6 ${tag}: Clear filters drops the filter parameters, every topic shows`, (await urlIs(p, { sort: 'lanes', dir: 'desc' })) && (await order(p)).split(',').length === 3, { q: await params(p), rows: await order(p) })
  await sortBy(p, vp, 'lanes')
  ok(`T6 ${tag}: the third sort click is newest activity first and drops sort and dir`, (await urlIs(p, {})) && (await rowsAre(p, [LANES_MOCK_TOPIC, OTHER, '-'].join(','))), { q: await params(p), rows: await order(p) })
  await sortBy(p, vp, 'topic')
  const sorted = phoneOf(vp)
    ? await p.$eval('[data-test=topics-sorted-by]', (e) => e.getAttribute('data-sort')).catch(() => '')
    : await p.$eval('[data-test=topics-sort-topic]', (b) => b.closest('th').getAttribute('aria-sort')).catch(() => '')
  ok(`T6 ${tag}: a sort click on Discussion sorts by it`, (await urlIs(p, { sort: 'topic', dir: 'asc' })) && sorted === (phoneOf(vp) ? 'topic' : 'ascending'), { q: await params(p), sorted })
  await a.ctx.close()
  ok(`T3-T6 ${tag}: no page error`, a.errors.length === 0, a.errors)
}

const server = await startServer()
const browser = await launch()
try {
  for (const { tag, vp } of VIEWPORTS) {
    await layout(browser, tag, vp)
    await behaviour(browser, tag, vp)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
