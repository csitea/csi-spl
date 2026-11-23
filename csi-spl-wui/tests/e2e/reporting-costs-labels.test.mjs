// SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806,
// 2026-11-11): Reporting -> Costs is four labels, Total, Persons, Cloud and
// Tokens, in a real browser against the mock bundle, at 1440x900 and
// 390x844:
//   - the bar is the project's cost, then exactly the four labels; the pages before them land on their label, the query kept
//     (/reporting/costs/spend -> total, /human -> persons, /price -> tokens,
//     /monitoring/costs -> total, /reporting/costs -> the project's cost
//     (spec 123 P05, SPL-6117 Q-9 A: the first label), /reporting/tokens ->
//     tokens, /reporting/costs/paid -> /expenses/ai), never a 404;
//   - each label: its name, then straight after it the pie, each legend row
//     showing the item's value AND its percentage on screen (no hover), the
//     shares summing to 100 %;
//   - the table per month: a column-name click sorts (aria-sort, ▲ / ▼),
//     a second click flips, Enter on the focused name sorts too;
//   - the period dropdown: the year to date and the last 12 months; the
//     year to date draws one column per month from January and a Total
//     column that is their sum;
//   - Cloud drills a project to its services and, for a month, a service
//     to its days; Persons lists the hr entries, an unpriced one a dash;
//     Tokens links Price per token to Expenses -> AI costs; a customer
//     workspace reads its own Tokens and is told Persons has no split;
//   - SPL-5546: Persons reads its hand-entered rows in the interface
//     language (/bg/... the bg label), a row with no label its master text,
//     the row keys unchanged;
//   - SPL-6203 (spec 123 16.6.4, row L6): Expenses marks each label row
//     machine translated and not yet reviewed, reviewed, or corrected by
//     hand, a stale hand row, the languages still waiting; a hand edit
//     flips a machine row's mark; a removed row says it is made again;
//   - SPL-6300: the start and end month pickers, both months included:
//     the current month by default (no query); a start pick writes
//     ?from=&to=, draws a column per month and a Total that is their sum;
//     the link alone reproduces the view on another label; the page bar
//     carries the range; the project's cost reads it as "<from> – <to>";
//     a preset pick drops the range;
//   - the currency switch writes ?currency= and the cells follow; no
//     sideways page scroll; without costs.read the 403 line.
//
// CONTROL: on master before SPL-6300 there is no costs-range-from picker,
// so every "range:" check FAILS there.
// CONTROL: on master before SPL-5312 the bar is Spend, AI tokens, Human
// (Cloud, Price for an operator admin) and /reporting/costs/total is no page,
// so every label check here FAILS there. SPL-6203: on master before it the
// card draws no cost-label-mark, so every expensesMarks check FAILS there.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e reporting-costs-labels
//   SHOT_DIR=<dir> keeps a screenshot per label and size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { COSTS_MOCK_KEY } from '../../src/utils/tenant-costs.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { COST_ENTRIES_MOCK_KEY } from '../../src/utils/cost-entries.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MOCK_ME_KEY = 'spool.mock.me'
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** A fresh signed-in mock page: `me` the opt-in mock role, `scenario` the mock month, `operator` an operator admin. */
async function costsPage(browser, base, { width, height }, { me = null, scenario = '', operator = false } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((meKey, m, costsKey, sc, opKey, op) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    if (m) localStorage.setItem(meKey, JSON.stringify(m)); else localStorage.removeItem(meKey)
    if (sc) localStorage.setItem(costsKey, sc); else localStorage.removeItem(costsKey)
    if (op) localStorage.setItem(opKey, '1'); else localStorage.removeItem(opKey)
  }, MOCK_ME_KEY, me, COSTS_MOCK_KEY, scenario, TOKENS_MOCK_OPERATOR_KEY, operator)
  return { ctx, p }
}

const open = async (p, base, path) => {
  await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=reporting-tabs], [data-test=expenses-page]', { visible: true, timeout: 20000 }).catch(() => null)
}
const where = (p) => { const u = new URL(p.url()); return u.pathname.replace(/\/$/, '') + u.search }
const waitWhere = (p, want) => p.waitForFunction((w) => location.pathname.replace(/\/$/, '') + location.search === w, { timeout: 15000 }, want).then(() => true, () => false)
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const labelIds = (p) => p.$$eval('[data-test^=costs-page-]', (els) => els.map((e) => e.getAttribute('data-test').slice('costs-page-'.length)))
const rowKeys = (p) => p.$$eval('[data-test=cmt-row]', (els) => els.map((e) => e.getAttribute('data-key')))
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const shot = async (p, name, size) => { if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/costs-${name}-${size.width}.png`, fullPage: true }) }
/** the label's table rendered (the loading line gone) */
const ready = (p) => p.waitForFunction(() => document.querySelectorAll('[data-test=costs-page]').length === 1 && document.querySelector('[data-test=costs-month-table]') && !document.querySelector('[data-test=costs-loading]'), { timeout: 20000 }).then(() => true, () => false)
/** a link's click, as the browser dispatches it, once the async pie no longer shifts the layout */
const follow = async (p, sel) => { await new Promise((r) => setTimeout(r, 300)); await act(`follow ${sel}`, () => p.$eval(sel, (a) => a.click())) }
/** a click as a reader makes it: scrolled to the middle first, so the phone's
 *  docked bottom bar never takes it (SPL-6300: the range pickers made the
 *  header a row taller, putting the sort button under that bar at 390 px) */
const clickSeen = async (p, sel) => { await p.$eval(sel, (e) => e.scrollIntoView({ block: 'center' })); await p.click(sel) }
/** an interaction on an element that may be missing: a FAIL naming it, never a throw that ends the run (c-974 review N5) */
const act = (what, fn) => Promise.resolve().then(fn).then(() => true, (e) => { ok(`can ${what}`, false, String(e && e.message || e).slice(0, 160)); return false })

async function redirects(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size)
  const cases = [
    ['/reporting/costs?month=2026-09', '/reporting/costs/project?month=2026-09'],
    ['/reporting/costs/spend?month=2026-09&currency=EUR', '/reporting/costs/total?month=2026-09&currency=EUR'],
    ['/reporting/costs/human', '/reporting/costs/persons'],
    ['/reporting/costs/price', '/reporting/costs/tokens'],
    ['/monitoring/costs?month=2026-09', '/reporting/costs/total?month=2026-09'],
    ['/reporting/tokens', '/reporting/costs/tokens'],
    ['/reporting/costs/paid', '/expenses/ai'],
  ]
  for (const [from, to] of cases) {
    await open(p, base, from)
    ok(`redirect ${from} -> ${to}`, await waitWhere(p, to), where(p))
  }
  await open(p, base, '/reporting/costs/total')
  await p.waitForFunction(() => document.querySelectorAll('[data-test^=costs-page-]').length === 5, { timeout: 15000 }).catch(() => null)
  ok('bar: exactly Project cost, Total, Persons, Cloud, Tokens for a member; Total active', (await labelIds(p)).join(',') === 'project,total,persons,cloud,tokens'
    && (await p.$eval('[data-test=costs-page-total]', (e) => e.getAttribute('aria-current')).catch(() => '')) === 'page', await labelIds(p))
  ok('bar: the label names', (await p.$$eval('[data-test^=costs-page-]', (els) => els.map((e) => e.textContent.trim()))).join(',') === 'Project cost,Total,Persons,Cloud,Tokens')
  await ctx.close()
}

/** the pie straight after the label, each item's value and % on screen */
async function pieAfterLabel(p, label) {
  const sec = label.toLowerCase()
  /* the leaving page stays in the DOM during the page transition: read the active label's own section */
  await waitFor(p, `[data-test=costs-page][data-section=${sec}] [data-test=costs-pie-legend-row]`)
  const shape = await p.evaluate((sec) => {
    const h = document.querySelector(`[data-test=costs-page][data-section=${sec}] [data-test=costs-label-title]`)
    const next = h && h.nextElementSibling
    return { title: h ? h.textContent.trim() : '', next: next ? next.getAttribute('data-test') : '' }
  }, sec)
  ok(`${label}: the pie comes straight after the label's name`, shape.title === label && shape.next === 'costs-pie', shape)
  const legend = await p.$$eval(`[data-test=costs-page][data-section=${sec}] [data-test=costs-pie-legend-row]`, (els) => els.map((e) => {
    const v = e.querySelector('[data-test=costs-pie-value]')
    const c = e.querySelector('[data-test=costs-pie-pct]')
    const seen = (x) => Boolean(x) && x.getBoundingClientRect().width > 0 && getComputedStyle(x).visibility !== 'hidden'
    return { v: v ? v.textContent.trim() : '', pct: c ? c.textContent.trim() : '', shown: seen(v) && seen(c) }
  }))
  ok(`${label}: each legend row shows the value and the % on screen`, legend.length > 0 && legend.every((r) => /^[^\d]*[\d,.]+/.test(r.v) && /^\d+(\.\d)? %$/.test(r.pct) && r.shown), legend)
  const sum = Math.round(legend.reduce((s, r) => s + parseFloat(r.pct), 0) * 10) / 10
  ok(`${label}: the shares sum to 100 %`, Math.abs(sum - 100) <= 0.3, sum)
}

async function totalLabel(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size, { operator: true, scenario: 'entries' })
  await open(p, base, '/reporting/costs/total?month=2026-09')
  ok('Total: the table renders', await ready(p))
  await pieAfterLabel(p, 'Total')
  ok('Total: Persons, Cloud, Tokens, Other', (await rowKeys(p)).join(',') === 'persons,cloud,tokens,other', await rowKeys(p))
  ok('Total: an earlier month is not "so far"', (await count(p, '[data-test=costs-so-far]')) === 0)
  ok('Total: n of N per source for a single month', (await count(p, '[data-test=costs-coverage-row]')) === 3)
  await shot(p, 'total', size)
  /* the sort: name A-Z, then Z-A; aria-sort on the column */
  await act('click [data-test=cmt-sort-name]', () => clickSeen(p, '[data-test=cmt-sort-name]'))
  const sortedName = await p.waitForFunction(() => [...document.querySelectorAll('[data-test=cmt-row]')].map((e) => e.getAttribute('data-key')).join(',') === 'cloud,other,persons,tokens', { timeout: 5000 }).then(() => true, () => false)
  ok('sort: a name click sorts A-Z, ▲, aria-sort ascending', sortedName && (await p.$eval('[data-test=cmt-col-name]', (th) => th.getAttribute('aria-sort') + ':' + th.textContent.trim())) === 'ascending:Item▲', await rowKeys(p))
  await act('click [data-test=cmt-sort-name]', () => clickSeen(p, '[data-test=cmt-sort-name]'))
  ok('sort: a second click flips it, ▼', (await rowKeys(p)).join(',') === 'tokens,persons,other,cloud'
    && (await p.$eval('[data-test=cmt-col-name]', (th) => th.getAttribute('aria-sort'))) === 'descending', await rowKeys(p))
  /* keyboard: Enter on the focused share column sorts by it, highest first */
  await act('focus [data-test=cmt-sort-pct]', () => p.focus('[data-test=cmt-sort-pct]'))
  await p.keyboard.press('Enter')
  ok('sort: Enter on a focused column name sorts by it, highest share first', (await rowKeys(p))[0] === 'persons'
    && (await p.$eval('[data-test=cmt-col-pct]', (th) => th.getAttribute('aria-sort'))) === 'descending', await rowKeys(p))
  ok('Total: no sideways page scroll', (await sideways(p)) <= 0, await sideways(p))
  await ctx.close()
}

async function period(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size)
  await open(p, base, '/reporting/costs/total')
  await ready(p)
  const opts = await p.$$eval('[data-test=costs-header-month] option', (els) => els.map((e) => [e.value, e.textContent.trim()]))
  const now = new Date()
  const cur = now.toISOString().slice(0, 7)
  const year = cur.slice(0, 4)
  ok('period: the year to date, the last 12 months, then the current month "so far" and the 11 before it', opts.length === 14 && opts[0][0] === 'ytd' && opts[0][1] === `Year to date (${year})`
    && opts[1][0] === 'l12m' && opts[1][1] === 'Last 12 months'
    && opts[2][0] === cur && /so far/.test(opts[2][1]), opts.map((o) => o[0]))
  ok('period: the current month is picked and marked "so far"', (await p.$eval('[data-test=costs-header-month]', (e) => e.value)) === cur && await waitFor(p, '[data-test=costs-so-far]'))
  await act('select [data-test=costs-header-month] l12m', () => p.select('[data-test=costs-header-month]', 'l12m'))
  ok('period: picking the last 12 months writes ?month=l12m', await waitWhere(p, '/reporting/costs/total?month=l12m'), where(p))
  await act('select [data-test=costs-header-month]', () => p.select('[data-test=costs-header-month]', 'ytd'))
  ok('period: picking the year to date writes ?month=ytd', await waitWhere(p, '/reporting/costs/total?month=ytd'), where(p))
  const n = now.getUTCMonth() + 1
  const heads = () => p.$$eval('[data-test=costs-month-table] thead th', (els) => els.map((e) => e.getAttribute('data-test').slice('cmt-col-'.length)))
  const want = ['name', ...Array.from({ length: n }, (_, i) => String(i)), ...(n > 1 ? ['total'] : []), 'pct'].join(',')
  const got = await p.waitForFunction((w) => [...document.querySelectorAll('[data-test=costs-month-table] thead th')].map((e) => e.getAttribute('data-test').slice(8)).join(',') === w
    && !document.querySelector('[data-test=costs-loading]'), { timeout: 20000 }, want).then(() => true, () => false)
  ok(`period: the year to date draws ${n} month columns from January${n > 1 ? ' and a Total' : ''}`, got, await heads())
  const months = await p.$$eval('[data-test=costs-month-table] thead th', (els) => els.slice(1, 3).map((e) => e.textContent.trim()))
  ok('period: the first month column is January', months[0] === `${year}-01`, months)
  if (n > 1) {
    const cloud = await p.$eval('[data-test=cmt-row][data-key=cloud]', (r) => ({
      cells: [...r.querySelectorAll('[data-test=cmt-cell]')].map((c) => Number(c.textContent.replace(/[^\d.]/g, ''))),
      total: Number(r.querySelector('[data-test=cmt-total]').textContent.replace(/[^\d.]/g, '')),
    })).catch(() => ({ cells: [], total: -1 }))
    const sum = Math.round(cloud.cells.reduce((s, x) => s + x, 0) * 100) / 100
    ok('period: a row\'s Total is the sum of its months', cloud.cells.length === n && Math.abs(sum - cloud.total) <= 0.02 * n, cloud)
  }
  if (size.width < 600) ok('period: the year to date on a phone adds no sideways page scroll (the table scrolls inside itself)', (await sideways(p)) <= 0, await sideways(p))
  await shot(p, 'total-ytd', size)
  /* the currency */
  await act('click [data-test=costs-header-cur-EUR]', () => p.click('[data-test=costs-header-cur-EUR]'))
  ok('currency: EUR writes ?currency=EUR, the period kept', await waitWhere(p, '/reporting/costs/total?month=ytd&currency=EUR'), where(p))
  const eur = await p.waitForFunction(() => /^€/.test(document.querySelector('[data-test=cmt-foot-total], [data-test=cmt-foot-cell]')?.textContent.trim() || ''), { timeout: 15000 }).then(() => true, () => false)
  ok('currency: the totals are in EUR', eur, await text(p, '[data-test=cmt-foot]'))
  await ctx.close()
}

/** SPL-6300: the start month and the end month, both included, in the URL. */
async function monthRange(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size)
  await open(p, base, '/reporting/costs/total')
  await ready(p)
  const now = new Date()
  const cur = now.toISOString().slice(0, 7)
  const from = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 2, 1)).toISOString().slice(0, 7)
  const val = (sel) => p.$eval(sel, (e) => e.value).catch(() => '')
  ok('range: both pickers show the current month by default', await val('[data-test=costs-range-from]') === cur && await val('[data-test=costs-range-to]') === cur,
    [await val('[data-test=costs-range-from]'), await val('[data-test=costs-range-to]')])
  await act('select [data-test=costs-range-from]', () => p.select('[data-test=costs-range-from]', from))
  const path = `/reporting/costs/total?from=${from}&to=${cur}`
  ok('range: a start pick writes ?from=&to=', await waitWhere(p, path), where(p))
  const want = 'name,0,1,2,total,pct'
  const cols = await p.waitForFunction((w) => [...document.querySelectorAll('[data-test=costs-month-table] thead th')].map((e) => e.getAttribute('data-test').slice(8)).join(',') === w
    && !document.querySelector('[data-test=costs-loading]'), { timeout: 20000 }, want).then(() => true, () => false)
  ok('range: three month columns and a Total', cols, await p.$$eval('[data-test=costs-month-table] thead th', (els) => els.map((e) => e.getAttribute('data-test'))).catch(() => []))
  const heads = await p.$$eval('[data-test=costs-month-table] thead th', (els) => els.slice(1, 4).map((e) => e.textContent.trim())).catch(() => [])
  ok('range: the columns are the start month to the end month', heads[0] === from && heads[2] === cur, heads)
  const cloud = await p.$eval('[data-test=cmt-row][data-key=cloud]', (r) => ({
    cells: [...r.querySelectorAll('[data-test=cmt-cell]')].map((c) => Number(c.textContent.replace(/[^\d.]/g, ''))),
    total: Number(r.querySelector('[data-test=cmt-total]').textContent.replace(/[^\d.]/g, '')),
  })).catch(() => ({ cells: [], total: -1 }))
  const sum = Math.round(cloud.cells.reduce((a, x) => a + x, 0) * 100) / 100
  ok('range: a row\'s Total is the sum of its months', cloud.cells.length === 3 && cloud.total > 0 && Math.abs(sum - cloud.total) <= 0.06, cloud)
  ok('range: the period list names the range', (await text(p, '[data-test=costs-period-range]')) === `${from} – ${cur}`, await text(p, '[data-test=costs-period-range]'))
  if (size.width < 600) ok('range: the pickers on a phone add no sideways page scroll', (await sideways(p)) <= 0, await sideways(p))
  await shot(p, 'total-range', size)
  await follow(p, '[data-test=costs-page-tokens]')
  ok('range: the page bar carries the range', await waitWhere(p, `/reporting/costs/tokens?from=${from}&to=${cur}`), where(p))
  /* the link alone reproduces the view */
  await open(p, base, `/reporting/costs/cloud?from=${from}&to=${cur}`)
  await ready(p)
  const again = await p.waitForFunction((w) => [...document.querySelectorAll('[data-test=costs-month-table] thead th')].map((e) => e.getAttribute('data-test').slice(8)).join(',') === w, { timeout: 20000 }, want).then(() => true, () => false)
  ok('range: the link alone draws the range on Cloud, the pickers set', again && await val('[data-test=costs-range-from]') === from && await val('[data-test=costs-range-to]') === cur, where(p))
  await open(p, base, `/reporting/costs/project?from=${from}&to=${cur}`)
  const cap = await p.waitForFunction((w) => (document.querySelector('[data-test=project-table] caption')?.textContent || '').includes(w), { timeout: 20000 }, `${from} – ${cur}`).then(() => true, () => false)
  ok('range: the project\'s cost reads the range', cap, await text(p, '[data-test=project-table] caption'))
  await act('select [data-test=costs-header-month] ytd', () => p.select('[data-test=costs-header-month]', 'ytd'))
  ok('range: a preset pick drops the range', await waitWhere(p, '/reporting/costs/project?month=ytd'), where(p))
  await ctx.close()
}

async function cloudPersonsTokens(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size, { operator: true, scenario: 'entries' })
  await open(p, base, '/reporting/costs/cloud?month=2026-09')
  await ready(p)
  await pieAfterLabel(p, 'Cloud')
  ok('Cloud: the projects and the entries, the most expensive first', (await rowKeys(p)).join(',') === 'project-prd,entry:Workspace suite,project-all,project-dev,entry:Domain suite', await rowKeys(p))
  await shot(p, 'cloud', size)
  await follow(p, '[data-test=cmt-row][data-key=project-prd] [data-test=cmt-drill]')
  ok('Cloud: a project opens its services, in the query', await waitWhere(p, '/reporting/costs/cloud?month=2026-09&project=project-prd'), where(p))
  await p.waitForFunction(() => document.querySelector('[data-test=costs-page]')?.getAttribute('data-level') === 'service' && !document.querySelector('[data-test=costs-loading]'), { timeout: 15000 }).catch(() => null)
  ok('Cloud: cloud_sql, cloud_run, network', (await rowKeys(p)).join(',') === 'cloud_sql,cloud_run,network', await rowKeys(p))
  await follow(p, '[data-test=cmt-row][data-key=cloud_sql] [data-test=cmt-drill]')
  const days = await p.waitForFunction(() => document.querySelector('[data-test=costs-page]')?.getAttribute('data-level') === 'day' && document.querySelectorAll('[data-test=cmt-row]').length === 30, { timeout: 15000 }).then(() => true, () => false)
  ok('Cloud: a service opens its 30 days of September', days && (await rowKeys(p))[0] === '2026-09-01', (await rowKeys(p)).length)
  await follow(p, '[data-test=cloud-crumb-all]')
  ok('Cloud: All projects walks back up, the month kept', await waitWhere(p, '/reporting/costs/cloud?month=2026-09'), where(p))

  await act('click [data-test=costs-page-persons]', () => p.click('[data-test=costs-page-persons]'))
  ok('Persons: the label keeps the month', await waitWhere(p, '/reporting/costs/persons?month=2026-09'), where(p))
  await ready(p)
  await pieAfterLabel(p, 'Persons')
  ok('Persons: one row per hr entry', (await rowKeys(p)).join(',') === 'hr:Design contract,hr:Support contract', await rowKeys(p))
  const chf = await p.$eval('[data-test=cmt-row][data-key="hr:Support contract"] [data-test=cmt-cell]', (c) => ({ text: c.textContent.trim(), none: c.getAttribute('data-none'), title: c.getAttribute('title') || '' })).catch(() => ({}))
  ok('Persons: an entry with no rate is a dash saying so, never $0', chf.text === '—' && chf.none === '1' && /^No USD rate/.test(chf.title), chf)
  await shot(p, 'persons', size)

  await act('click [data-test=costs-page-tokens]', () => p.click('[data-test=costs-page-tokens]'))
  await ready(p)
  await pieAfterLabel(p, 'Tokens')
  ok('Tokens: the paid invoice and the burn, its tokens and list price under its name', (await count(p, '[data-test=cmt-row]')) === 2
    && /2\.6B tokens · list price \$1,200\.00, not paid/.test(await text(p, '[data-test=cmt-row][data-key="fleet_tokens|llm-vendor|tokens"]')))
  ok('Tokens: Price per token links Expenses -> AI costs', /\/expenses\/ai$/.test(await p.$eval('[data-test=costs-price-link] a', (a) => a.getAttribute('href')).catch(() => '')))
  ok('Tokens: the estate\'s burn per workspace', (await count(p, '[data-test=costs-workspace-row]')) === 3)
  ok('Tokens: no sideways page scroll', (await sideways(p)) <= 0, await sideways(p))
  await shot(p, 'tokens', size)
  await ctx.close()
}

/* SPL-5546 (owner HUM-10, csitea 720fa031: "the labels in this view should be in the language of the interface") */
async function personsLanguage(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size, { operator: true, scenario: 'entries' })
  const names = () => p.$$eval('[data-test=cmt-row] .cmt-name > span:first-child, [data-test=cmt-row] .cmt-name > a', (els) => els.map((e) => e.textContent.trim()))
  await open(p, base, '/reporting/costs/persons?month=2026-09')
  await ready(p)
  ok('Persons in English: the master text', (await names(p)).join('|') === 'Design contract|Support contract', await names(p))
  await shot(p, 'persons-en', size)
  await open(p, base, '/bg/reporting/costs/persons?month=2026-09')
  await ready(p)
  const bg = await p.waitForFunction(() => [...document.querySelectorAll('[data-test=cmt-row] .cmt-name > span:first-child')].some((e) => e.textContent.trim() === 'Договор за дизайн'), { timeout: 15000 }).then(() => true, () => false)
  ok('Persons in Bulgarian: the bg label; a row with none keeps the master text', bg && (await names(p)).join('|') === 'Договор за дизайн|Support contract', await names(p))
  ok('Persons in Bulgarian: the row keys stay the master text', (await rowKeys(p)).join(',') === 'hr:Design contract,hr:Support contract', await rowKeys(p))
  ok('Persons in Bulgarian: the pie legend reads the bg label', (await text(p, '[data-test=costs-page]')).includes('Договор за дизайн'))
  await shot(p, 'persons-bg', size)
  await ctx.close()
}

/* SPL-6203 (spec 123 16.6.4; owner answer 2 d: readers see the machine draft at once, marked unreviewed) */
const MARKS_ENTRY = {
  id: 'mock-cost-marks', type: 'cloud', label: 'Hosting plan', amount: 12, currency: 'USD', period: '2026-09', note: '',
  labels: { bg: 'Хостинг план', fi: 'Hosting-paketti', sv: 'Värdplan' }, label_origins: { bg: 'machine', fi: 'reviewed', sv: 'hand' }, stale_locales: ['sv'],
}
async function expensesMarks(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size, { operator: true })
  await p.evaluate((k, e) => localStorage.setItem(k, JSON.stringify([e])), COST_ENTRIES_MOCK_KEY, MARKS_ENTRY)
  await open(p, base, '/expenses/cloud')
  ok('marks: the entry is listed', await waitFor(p, '[data-test=cost-labels-toggle]'))
  await act('open [data-test=cost-labels-toggle]', () => p.$eval('[data-test=cost-labels-toggle]', (e) => e.click()))
  await waitFor(p, '[data-test=cost-label-row]')
  const marks = () => p.$$eval('[data-test=cost-label-row]', (els) => els.map((r) => [r.querySelector('[data-test=cost-label-locale]').value,
    r.querySelector('[data-test=cost-label-mark]')?.getAttribute('data-mark') || '', r.querySelector('[data-test=cost-label-mark]')?.textContent.trim() || '', Boolean(r.querySelector('[data-test=cost-label-stale]'))]))
  const got = await marks()
  ok('marks: a machine row reads "machine translated, not yet reviewed", a reviewed one "reviewed", a hand one "corrected by hand"', JSON.stringify(got.map((m) => m.slice(0, 3))) === JSON.stringify([
    ['bg', 'machine', 'Machine translated, not yet reviewed'], ['fi', 'reviewed', 'Reviewed'], ['sv', 'hand', 'Corrected by hand']]), got)
  ok('marks: only the stale hand row is marked stale', got.map((m) => m[3]).join(',') === 'false,false,true'
    && (await text(p, '[data-test=cost-label-stale]')) === 'Made from an older master text: check it', got)
  const waiting = await text(p, '[data-test=cost-labels-waiting]')
  ok('marks: the languages still waiting are named, never the master or a language with a row', /^Still waiting for a translation: /.test(waiting) && waiting.includes('Nederlands')
    && !/English|Suomi|Svenska|Български/.test(waiting), waiting)
  await shot(p, 'expenses-marks-machine', size)
  /* a hand edit of the machine row: saved, it reads "corrected by hand" */
  await act('edit the bg row', () => p.$eval('[data-test=cost-label-row] [data-test=cost-label-text]', (e) => { e.value = 'Хостинг пакет'; e.dispatchEvent(new Event('input', { bubbles: true })) }))
  ok('marks: an edit not saved yet shows no mark', (await marks())[0][1] === '', await marks())
  await act('save', () => p.$eval('[data-test=cost-label-save]', (e) => e.click()))
  const flipped = await p.waitForFunction(() => document.querySelector('[data-test=cost-label-row] [data-test=cost-label-mark]')?.getAttribute('data-mark') === 'hand', { timeout: 10000 }).then(() => true, () => false)
  const stored = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '[]')[0]?.label_origins || {}, COST_ENTRIES_MOCK_KEY)
  ok('marks: a hand edit flips the machine row to "corrected by hand"; the others keep theirs', flipped && (await marks())[0][2] === 'Corrected by hand'
    && JSON.stringify(stored) === JSON.stringify({ bg: 'hand', fi: 'reviewed', sv: 'hand' }), [await marks(), stored])
  await shot(p, 'expenses-marks-hand', size)
  /* a removed row: the card says the next fill makes it again by machine */
  ok('marks: nothing removed, no removed line', (await count(p, '[data-test=cost-labels-removed]')) === 0)
  await act('remove the fi row', () => p.$$eval('[data-test=cost-label-row]', (els) => els[1].querySelector('[data-test=cost-label-remove]').click()))
  await waitFor(p, '[data-test=cost-labels-removed]')
  const removed = await text(p, '[data-test=cost-labels-removed]')
  ok('marks: removing a row says it is translated again by machine', removed === 'Removed: Suomi. Saving deletes them, and the next run translates them again by machine.', removed)
  ok('marks: no sideways page scroll', (await sideways(p)) <= 0, await sideways(p))
  await shot(p, 'expenses-marks-removed', size)
  await ctx.close()
}

async function workspaceAndForbidden(browser, base, size) {
  {
    /* a customer workspace (mock 'share', last month): its own Tokens; Persons and Cloud say they have no split */
    const { ctx, p } = await costsPage(browser, base, size, { scenario: 'share' })
    const last = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() - 1, 1)).toISOString().slice(0, 7)
    await open(p, base, '/reporting/costs/tokens?month=' + last)
    await ready(p)
    ok('workspace: Tokens lists its share per agent type', (await rowKeys(p)).filter((k) => k.startsWith('ai_share|')).length === 2, await rowKeys(p))
    ok('workspace: the scope line says this workspace', (await text(p, '[data-test=costs-scope]')) === 'This workspace')
    await act('click [data-test=costs-page-persons]', () => p.click('[data-test=costs-page-persons]'))
    await ready(p)
    ok('workspace: Persons says it has no costs of its own yet, no rows', await waitFor(p, '[data-test=costs-no-split]') && (await count(p, '[data-test=cmt-row]')) === 0)
    await ctx.close()
  }
  {
    const { ctx, p } = await costsPage(browser, base, size, { me: { role: 'developer', permissions: ['members.invite'] } })
    await open(p, base, '/reporting/costs/total')
    ok('without costs.read: the 403 line naming costs.read, no table', await waitFor(p, '[data-test=costs-forbidden]')
      && (await text(p, '[data-test=costs-forbidden]')).includes('costs.read') && (await count(p, '[data-test=costs-month-table]')) === 0)
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    console.log(`-- ${size.width}x${size.height}`)
    for (const section of [redirects, totalLabel, period, monthRange, cloudPersonsTokens, personsLanguage, expensesMarks, workspaceAndForbidden]) {
      // a section that still throws is one FAIL, and the sections after it run (N5)
      await section(browser, server.base, size).catch((e) => ok(`${section.name} ran to its end`, false, String(e && e.message || e).slice(0, 160)))
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `reporting-costs-labels: ${failed} FAILED` : `reporting-costs-labels: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
