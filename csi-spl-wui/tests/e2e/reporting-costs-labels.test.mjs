// SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806,
// 2026-11-11): Reporting -> Costs is four labels, Total, Persons, Cloud and
// Tokens, in a real browser against the mock bundle, at 1440x900 and
// 390x844:
//   - the bar is exactly the four labels, for a member and an operator
//     admin; the pages before them land on their label, the query kept
//     (/reporting/costs/spend -> total, /human -> persons, /price -> tokens,
//     /reporting/costs, /monitoring/costs -> total, /reporting/tokens ->
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
//   - the currency switch writes ?currency= and the cells follow; no
//     sideways page scroll; without costs.read the 403 line.
//
// CONTROL: on master before SPL-5312 the bar is Spend, AI tokens, Human
// (Cloud, Price for an operator admin) and /reporting/costs/total is no page,
// so every label check here FAILS there.
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
const follow = async (p, sel) => { await new Promise((r) => setTimeout(r, 300)); await p.$eval(sel, (a) => a.click()) }

async function redirects(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size)
  const cases = [
    ['/reporting/costs?month=2026-09', '/reporting/costs/total?month=2026-09'],
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
  await p.waitForFunction(() => document.querySelectorAll('[data-test^=costs-page-]').length === 4, { timeout: 15000 }).catch(() => null)
  ok('bar: exactly Total, Persons, Cloud, Tokens for a member; Total active', (await labelIds(p)).join(',') === 'total,persons,cloud,tokens'
    && (await p.$eval('[data-test=costs-page-total]', (e) => e.getAttribute('aria-current')).catch(() => '')) === 'page', await labelIds(p))
  ok('bar: the label names', (await p.$$eval('[data-test^=costs-page-]', (els) => els.map((e) => e.textContent.trim()))).join(',') === 'Total,Persons,Cloud,Tokens')
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
  await p.click('[data-test=cmt-sort-name]')
  const sortedName = await p.waitForFunction(() => [...document.querySelectorAll('[data-test=cmt-row]')].map((e) => e.getAttribute('data-key')).join(',') === 'cloud,other,persons,tokens', { timeout: 5000 }).then(() => true, () => false)
  ok('sort: a name click sorts A-Z, ▲, aria-sort ascending', sortedName && (await p.$eval('[data-test=cmt-col-name]', (th) => th.getAttribute('aria-sort') + ':' + th.textContent.trim())) === 'ascending:Item▲', await rowKeys(p))
  await p.click('[data-test=cmt-sort-name]')
  ok('sort: a second click flips it, ▼', (await rowKeys(p)).join(',') === 'tokens,persons,other,cloud'
    && (await p.$eval('[data-test=cmt-col-name]', (th) => th.getAttribute('aria-sort'))) === 'descending', await rowKeys(p))
  /* keyboard: Enter on the focused share column sorts by it, highest first */
  await p.focus('[data-test=cmt-sort-pct]')
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
  ok('period: the year to date, then the current month "so far" and the 11 before it', opts.length === 13 && opts[0][0] === 'ytd' && opts[0][1] === `Year to date (${year})`
    && opts[1][0] === cur && /so far/.test(opts[1][1]), opts.map((o) => o[0]))
  ok('period: the current month is picked and marked "so far"', (await p.$eval('[data-test=costs-header-month]', (e) => e.value)) === cur && await waitFor(p, '[data-test=costs-so-far]'))
  await p.select('[data-test=costs-header-month]', 'ytd')
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
  await p.click('[data-test=costs-header-cur-EUR]')
  ok('currency: EUR writes ?currency=EUR, the period kept', await waitWhere(p, '/reporting/costs/total?month=ytd&currency=EUR'), where(p))
  const eur = await p.waitForFunction(() => /^€/.test(document.querySelector('[data-test=cmt-foot-total], [data-test=cmt-foot-cell]')?.textContent.trim() || ''), { timeout: 15000 }).then(() => true, () => false)
  ok('currency: the totals are in EUR', eur, await text(p, '[data-test=cmt-foot]'))
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

  await p.click('[data-test=costs-page-persons]')
  ok('Persons: the label keeps the month', await waitWhere(p, '/reporting/costs/persons?month=2026-09'), where(p))
  await ready(p)
  await pieAfterLabel(p, 'Persons')
  ok('Persons: one row per hr entry', (await rowKeys(p)).join(',') === 'hr:Design contract,hr:Support contract', await rowKeys(p))
  const chf = await p.$eval('[data-test=cmt-row][data-key="hr:Support contract"] [data-test=cmt-cell]', (c) => ({ text: c.textContent.trim(), none: c.getAttribute('data-none'), title: c.getAttribute('title') || '' })).catch(() => ({}))
  ok('Persons: an entry with no rate is a dash saying so, never $0', chf.text === '—' && chf.none === '1' && /^No USD rate/.test(chf.title), chf)
  await shot(p, 'persons', size)

  await p.click('[data-test=costs-page-tokens]')
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

async function workspaceAndForbidden(browser, base, size) {
  {
    /* a customer workspace (mock 'share', last month): its own Tokens; Persons and Cloud say they have no split */
    const { ctx, p } = await costsPage(browser, base, size, { scenario: 'share' })
    const last = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() - 1, 1)).toISOString().slice(0, 7)
    await open(p, base, '/reporting/costs/tokens?month=' + last)
    await ready(p)
    ok('workspace: Tokens lists its share per agent type', (await rowKeys(p)).filter((k) => k.startsWith('ai_share|')).length === 2, await rowKeys(p))
    ok('workspace: the scope line says this workspace', (await text(p, '[data-test=costs-scope]')) === 'This workspace')
    await p.click('[data-test=costs-page-persons]')
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
    await redirects(browser, server.base, size)
    await totalLabel(browser, server.base, size)
    await period(browser, server.base, size)
    await cloudPersonsTokens(browser, server.base, size)
    await workspaceAndForbidden(browser, server.base, size)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `reporting-costs-labels: ${failed} FAILED` : `reporting-costs-labels: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
