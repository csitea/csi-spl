// Spec 123 section 13, row P05 (SPL-6117; owner HUM-10, t1 e2c0e6b4, msgs
// 3a190b70 and 143a0a1c "the importance is to be able to see the monthly and
// yearly costs"): Reporting -> Costs -> The project's cost,
// /reporting/costs/project, in a real browser against the mock bundle, at
// 1400x900 and 390x844:
//   - the two first figures, this month so far and this year to date: each
//     equals the sum of its parts drawn under it, and the year equals the sum
//     of every month of the year (the closed months and the month so far);
//   - a part the hub does not know (Human before P02: null) is a dash in the
//     figures and the table, never 0.00, and says "not tracked yet";
//   - the table: one row per part, its share and completeness words, the
//     "Total, priced" row equal to the figure of its period (?month=ytd: the
//     year); each part's row links its section, each section the page that
//     holds its detail, under the current four labels and Expenses;
//   - a customer workspace draws two parts, AI tokens and Human (Q-8 A);
//   - the Human mask (13.6): hours.read sees "money: time accountant only",
//     any other role "not shown to your role", and no total holds it;
//   - the header's currency (?currency=EUR) changes the figures; no sideways
//     page scroll; without costs.read the 403 line;
//   - the Costs bar: the project's cost first and active on its page, then
//     Total, Persons, Cloud, Tokens; /reporting/costs lands on it, the
//     query kept (owner Q-9 A, t1 e2c0e6b4, msg 3a795cdb).
//
// CONTROL (red): a null part drawn as 0.00 fails "a dash, never 0.00"; a year
// figure read without its closed months (the month answer drawn as the year)
// fails "the year equals the sum of its months".
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e reporting-costs-project
//   SHOT_DIR=<dir> keeps a screenshot per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { COSTS_MOCK_KEY } from '../../src/utils/tenant-costs.mjs'
import { mockCostProject } from '../../src/utils/cost-project.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MOCK_ME_KEY = 'spool.mock.me'
const DASH = '—'
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

/** A fresh signed-in mock page: `me` the opt-in mock role, `scenario` the mock costs. */
async function costsPage(browser, base, { width, height }, { me = null, scenario = '' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((meKey, m, costsKey, sc) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    if (m) localStorage.setItem(meKey, JSON.stringify(m)); else localStorage.removeItem(meKey)
    if (sc) localStorage.setItem(costsKey, sc); else localStorage.removeItem(costsKey)
  }, MOCK_ME_KEY, me, COSTS_MOCK_KEY, scenario)
  return { ctx, p }
}

const open = (p, base, path) => p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const shot = async (p, name, size) => { if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/project-${name}-${size.width}.png`, fullPage: true }) }
const ready = (p) => p.waitForFunction(() => document.querySelector('[data-test=project-table]') && !document.querySelector('[data-test=costs-loading]'), { timeout: 20000 }).then(() => true, () => false)
const where = (p) => { const u = new URL(p.url()); return u.pathname.replace(/\/$/, '') + u.search }

/** a figure: its total micros, and each part drawn under it (micros '' = not known, its text) */
const figure = (p, id) => p.$eval(`[data-test=project-figure-${id}]`, (f) => ({
  micros: f.getAttribute('data-micros'),
  parts: [...f.querySelectorAll('[data-test=project-figure-part]')].map((li) => ({
    part: li.getAttribute('data-part'), micros: li.getAttribute('data-micros'), text: li.lastElementChild.textContent.trim(),
  })),
})).catch(() => null)
const rows = (p) => p.$$eval('[data-test=project-row]', (els) => els.map((r) => ({
  part: r.getAttribute('data-part'), micros: r.getAttribute('data-micros'),
  amount: r.querySelector('[data-test=project-amount]').textContent.trim(),
  share: r.querySelector('[data-test=project-share]').textContent.trim(),
  done: r.querySelector('[data-test=project-done]').textContent.trim(),
  link: r.querySelector('[data-test=project-row-link]').getAttribute('href'),
})))
const partsSum = (f) => f.parts.reduce((a, x) => (x.micros === '' ? a : a + Number(x.micros)), 0)

/** what the mock hub answers for every month of this year, summed: the year figure's truth */
function yearOfMonths(currency, scenario = '') {
  const now = new Date()
  const key = currency === 'USD' ? 'usd_micros' : 'second_micros'
  let sum = 0
  for (let m = 1; m <= now.getUTCMonth() + 1; m++) {
    const month = now.getUTCFullYear() + '-' + String(m).padStart(2, '0')
    sum += mockCostProject({ month }, { now, scenario, currency: 'EUR' }).total.priced[key]
  }
  return sum
}

async function estate(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size)
  await open(p, base, '/reporting/costs/project')
  ok('the page draws its two figures and its table', await ready(p) && (await count(p, '[data-test^=project-figure-]')) >= 2)
  await shot(p, 'estate', size)
  const month = await figure(p, 'month')
  const year = await figure(p, 'year')
  ok('this month so far equals the sum of its parts', !!month && Number(month.micros) === partsSum(month), month)
  ok('this year to date equals the sum of its parts', !!year && Number(year.micros) === partsSum(year), year)
  const want = yearOfMonths('USD')
  ok('the year equals the sum of its months, the closed ones included', !!year && Number(year.micros) === want, { drawn: year?.micros, want })
  if (new Date().getUTCMonth() > 0) ok('past January the year is more than the month', !!year && !!month && Number(year.micros) > Number(month.micros))
  const human = [...(month?.parts || []), ...(year?.parts || [])].filter((x) => x.part === 'human')
  ok('Human, not known yet, is a dash in both figures, never 0.00', human.length === 2 && human.every((x) => x.micros === '' && x.text === DASH), human)
  const r = await rows(p)
  ok('the estate table has the four parts in order', r.map((x) => x.part).join(',') === 'cloud,owned_hardware,ai_tokens,human', r.map((x) => x.part))
  const hu = r.find((x) => x.part === 'human')
  ok('Human in the table: a dash, never 0.00, and "not tracked yet"', !!hu && hu.amount === DASH && hu.share === DASH && !/0[.,]00/.test(hu.amount) && hu.done === 'not tracked yet', hu)
  const total = await p.$eval('[data-test=project-total]', (e) => e.getAttribute('data-micros')).catch(() => '')
  ok('"Total, priced" equals the month figure and the sum of the rows', total === month?.micros && Number(total) === r.reduce((a, x) => (x.micros === '' ? a : a + Number(x.micros)), 0), { total })
  ok('the shares of the priced parts sum to 100 %', Math.abs(r.filter((x) => x.share !== DASH).reduce((a, x) => a + parseFloat(x.share), 0) - 100) < 0.5, r.map((x) => x.share))
  ok('each row links its own section', r.every((x) => x.link === '#project-part-' + x.part) && (await count(p, '[data-test=project-section]')) === 4)
  const links = await p.$$eval('[data-test=project-section]', (els) => els.map((s) => [s.getAttribute('data-part'), new URL(s.querySelector('[data-test=project-section-link]').href).pathname]))
  ok('each section links its current page (four labels, Expenses)', JSON.stringify(links) === JSON.stringify([['cloud', '/reporting/costs/cloud'], ['owned_hardware', '/expenses/ai'], ['ai_tokens', '/reporting/costs/tokens'], ['human', '/reporting/costs/persons']]), links)
  ok('no sideways page scroll', (await sideways(p)) <= 0, await sideways(p))
  await open(p, base, '/reporting/costs/project?month=ytd')
  await ready(p)
  const ytd = await p.$eval('[data-test=project-total]', (e) => e.getAttribute('data-micros')).catch(() => '')
  ok('the year to date table totals the year figure', ytd === String(want), { ytd, want })
  await open(p, base, '/reporting/costs/project?currency=EUR')
  await ready(p)
  const eur = await figure(p, 'year')
  ok('in EUR the year is the sum of its months in EUR', !!eur && Number(eur.micros) === yearOfMonths('EUR') && Number(eur.micros) === partsSum(eur), eur?.micros)
  await ctx.close()
}

async function workspaceAndMask(browser, base, size) {
  {
    const { ctx, p } = await costsPage(browser, base, size, { scenario: 'share' })
    await open(p, base, '/reporting/costs/project')
    await ready(p)
    const r = await rows(p)
    ok('a customer workspace: two parts, AI tokens and Human', r.map((x) => x.part).join(',') === 'ai_tokens,human', r.map((x) => x.part))
    ok('a customer workspace: the scope line says this workspace', (await text(p, '[data-test=costs-scope]')) === 'This workspace')
    ok('a customer workspace: no sideways page scroll', (await sideways(p)) <= 0)
    await ctx.close()
  }
  for (const [perms, want, mask] of [[['costs.read', 'hours.read'], 'money: time accountant only', 'money'], [['costs.read'], 'not shown to your role', 'whole']]) {
    const { ctx, p } = await costsPage(browser, base, size, { scenario: 'human', me: { role: 'admin', permissions: perms } })
    await open(p, base, '/reporting/costs/project')
    await ready(p)
    const r = await rows(p)
    const hu = r.find((x) => x.part === 'human')
    const total = await p.$eval('[data-test=project-total]', (e) => e.getAttribute('data-micros')).catch(() => '')
    ok(`mask ${mask}: Human is a dash and says "${want}"`, !!hu && hu.amount === DASH && hu.done.includes(want), hu)
    ok(`mask ${mask}: the total holds no Human money`, Number(total) === r.filter((x) => x.part !== 'human').reduce((a, x) => a + Number(x.micros), 0), { total })
    ok(`mask ${mask}: the page names the mask`, (await p.$eval('[data-test=project-mask-note]', (e) => e.getAttribute('data-mask')).catch(() => '')) === mask)
    await ctx.close()
  }
  {
    const { ctx, p } = await costsPage(browser, base, size, { me: { role: 'developer', permissions: ['members.invite'] } })
    await open(p, base, '/reporting/costs/project')
    ok('without costs.read: the 403 line naming costs.read, no table', await waitFor(p, '[data-test=costs-forbidden]')
      && (await text(p, '[data-test=costs-forbidden]')).includes('costs.read') && (await count(p, '[data-test=project-table]')) === 0)
    await ctx.close()
  }
}

async function barFirst(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size)
  await open(p, base, '/reporting/costs/project')
  await ready(p)
  const ids = await p.$$eval('[data-test^=costs-page-]', (els) => els.map((e) => e.getAttribute('data-test').slice('costs-page-'.length)))
  ok('the Costs bar: the project\'s cost first, then the four labels (Q-9 A)', ids.join(',') === 'project,total,persons,cloud,tokens', ids)
  ok('the project\'s label is active on its page', (await p.$eval('[data-test=costs-page-project]', (e) => e.getAttribute('aria-current')).catch(() => '')) === 'page')
  ok('the project page stays on its own path (no redirect)', where(p) === '/reporting/costs/project', where(p))
  await open(p, base, '/reporting/costs?month=ytd')
  const landed = await p.waitForFunction(() => location.pathname.replace(/\/$/, '') === '/reporting/costs/project' && location.search === '?month=ytd', { timeout: 15000 }).then(() => true, () => false)
  ok('/reporting/costs lands on the project\'s cost (the default), the query kept', landed, where(p))
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of [{ width: 1400, height: 900 }, { width: 390, height: 844 }]) {
    console.log(`-- ${size.width}x${size.height}`)
    for (const section of [estate, workspaceAndMask, barFirst]) {
      await section(browser, server.base, size).catch((e) => ok(`${section.name} ran to its end`, false, String(e && e.message || e).slice(0, 160)))
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `reporting-costs-project: ${failed} FAILED` : `reporting-costs-project: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
