// SPL-6438 (spec 143 taxes-tab.md sections 5 and 6; owner HUM-10, csitea
// topic dc7c9c9a, msg fc8f964e: "Every person of csitea; agents never"):
// Reporting -> Costs -> Taxes in a real browser against the mock bundle, at
// 1400x900 and 390x844:
//   - a person of the tax workspace (spool.mock.tax_workspace = here) gets
//     the Taxes label last on the Costs bar; it opens /reporting/costs/taxes,
//     which draws the three blocks (due with one overdue row, this week, the
//     year's documents) and no Costs header (period, currency);
//   - the category filter narrows the documents table;
//   - a reader of another workspace (the key unset) gets no Taxes label, and
//     /reporting/costs/taxes there shows the neutral line and no row;
//   - an agent seat of the tax workspace gets no label and no row;
//   - no sideways page scroll.
// CONTROL (red, reasoned, not run as an e2e): drop `taxOnly` from the Taxes
// page in reporting-costs.mjs and "another workspace's bar has no Taxes
// label" fails; the unit test reporting-costs.test.mjs holds the same rule.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e reporting-costs-taxes
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { MOCK_TAX_WORKSPACE_KEY } from '../../src/utils/reporting-tax.mjs'

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

/** A fresh signed-in mock page; `here` plays the tax workspace, `me` a mock role. */
async function page(browser, base, { width, height }, { here = false, me = null } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((meKey, m, taxKey, h) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    if (m) localStorage.setItem(meKey, JSON.stringify(m)); else localStorage.removeItem(meKey)
    if (h) localStorage.setItem(taxKey, 'here'); else localStorage.removeItem(taxKey)
  }, MOCK_ME_KEY, me, MOCK_TAX_WORKSPACE_KEY, here)
  return { ctx, p }
}

const open = (p, base, path) => p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const labelIds = (p) => p.$$eval('[data-test^=costs-page-]', (els) => els.map((e) => e.getAttribute('data-test').slice('costs-page-'.length)))
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const where = (p) => new URL(p.url()).pathname.replace(/\/$/, '')
/* the probe answers after mount: give the bar a moment to settle */
const settled = (p) => p.waitForFunction(() => document.querySelectorAll('[data-test^=costs-page-]').length >= 5, { timeout: 20000 }).then(() => new Promise((r) => setTimeout(r, 800)))

async function taxReader(browser, base, size) {
  const { ctx, p } = await page(browser, base, size, { here: true })
  await open(p, base, '/reporting/costs/total')
  ok('tax workspace: the Taxes label shows, last on the bar', await waitFor(p, '[data-test=costs-page-taxes]') && (await labelIds(p)).at(-1) === 'taxes', await labelIds(p))
  await p.$eval('[data-test=costs-page-taxes]', (e) => e.scrollIntoView({ block: 'center', inline: 'center' }))
  await p.click('[data-test=costs-page-taxes]')
  ok('tax workspace: the label opens /reporting/costs/taxes', await p.waitForFunction(() => location.pathname.replace(/\/$/, '').endsWith('/reporting/costs/taxes'), { timeout: 15000 }).then(() => true, () => false), where(p))
  ok('tax workspace: the three blocks render', (await waitFor(p, '[data-test=taxes-due]')) && (await waitFor(p, '[data-test=taxes-week]')) && (await waitFor(p, '[data-test=taxes-docs]')))
  ok('tax workspace: the label is active', (await p.$eval('[data-test=costs-page-taxes]', (e) => e.getAttribute('aria-current')).catch(() => '')) === 'page')
  ok('tax workspace: no Costs header (period, currency) on Taxes', (await count(p, '[data-test=costs-header]')) === 0)
  const due = await count(p, '[data-test=taxes-due-row]')
  ok('due: rows, one overdue marked', due >= 2 && (await count(p, '[data-test=taxes-overdue]')) === 1, due)
  ok('this week: new and changed rows, one open question', (await count(p, '[data-test=taxes-week-row]')) === 3 && (await count(p, '[data-test=taxes-open-row]')) === 1)
  const all = await count(p, '[data-test=taxes-doc]')
  await p.select('[data-test=taxes-filter-category]', 'msgs')
  await p.waitForFunction(() => [...document.querySelectorAll('[data-test=taxes-doc]')].every((e) => e.getAttribute('data-category') === 'msgs'), { timeout: 10000 }).catch(() => {})
  const msgs = await count(p, '[data-test=taxes-doc]')
  ok('the category filter narrows the documents', all >= 5 && msgs >= 1 && msgs < all, [all, msgs])
  ok('no raw key on the page', !(await p.evaluate(() => /reporting\.(taxes|costs)\./.test(document.body.innerText))))
  ok('no sideways page scroll', (await sideways(p)) <= 0, await sideways(p))
  await ctx.close()
}

async function otherWorkspace(browser, base, size) {
  const { ctx, p } = await page(browser, base, size)
  await open(p, base, '/reporting/costs/total')
  await settled(p)
  ok('another workspace\'s bar has no Taxes label', !(await labelIds(p)).includes('taxes'), await labelIds(p))
  await open(p, base, '/reporting/costs/taxes')
  ok('another workspace: /reporting/costs/taxes shows the neutral line, no row', (await waitFor(p, '[data-test=taxes-absent]')) && (await count(p, '[data-test=taxes-doc]')) === 0)
  await ctx.close()
}

async function agentSeat(browser, base, size) {
  const { ctx, p } = await page(browser, base, size, { here: true, me: { role: 'pure_agent', permissions: ['costs.read'] } })
  await open(p, base, '/reporting/costs/taxes')
  ok('an agent seat: the neutral line, no row', (await waitFor(p, '[data-test=taxes-absent]')) && (await count(p, '[data-test=taxes-doc]')) === 0)
  ok('an agent seat: no Taxes label', (await count(p, '[data-test=costs-page-taxes]')) === 0)
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of [{ width: 1400, height: 900 }, { width: 390, height: 844 }]) {
    console.log(`-- ${size.width}x${size.height}`)
    for (const section of [taxReader, otherWorkspace, agentSeat]) {
      await section(browser, server.base, size).catch((e) => ok(`${section.name} ran to its end`, false, String(e && e.message || e).slice(0, 160)))
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `reporting-costs-taxes: ${failed} FAILED` : `reporting-costs-taxes: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
