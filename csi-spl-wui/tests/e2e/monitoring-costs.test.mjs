// Spec 123 5 + 8 (SPL-2056, owner HUM-10, t1 dbf2f39b): Monitoring -> Costs
// in a real browser, against the mock bundle (dev has no cost rows), at
// 1400x900 and 390x844:
//   - the tab shows for a member with costs.read (the mock's default me is
//     unrestricted, and an opt-in me holding costs.read) and not otherwise;
//     a direct URL without it shows the 403 state naming costs.read;
//   - the table (one row per part, a total row) and the pie render from the
//     mock month, the current month is marked "so far", an earlier month
//     is not;
//   - the empty state (today's prd: counts only, no GCP): each source named,
//     no pie (never a 0 pie);
//   - no sideways scroll; the initial download of 200.html carries no costs
//     code (the chunk rule, ci_initial_gzip_kb).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-costs
//   SHOT_DIR=<dir> keeps a screenshot per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { COSTS_MOCK_KEY } from '../../src/utils/tenant-costs.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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

const MOCK_ME_KEY = 'spool.mock.me'
const COSTS_MARKERS = /"costs-page"|"costs-pie"|"spool\.mock\.costs"/
const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const tabIds = (p) => p.$$eval('[data-test^=monitoring-tab-]', (els) => els.map((e) => e.getAttribute('data-test').slice('monitoring-tab-'.length)))

/** A fresh signed-in mock page at this size; `me` = the opt-in mock role + permissions, `scenario` = the mock month. */
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

async function open(p, base, path) {
  const res = await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=monitoring-tabs]', { visible: true, timeout: 20000 }).catch(() => null)
  return res
}

const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)

const server = await startServer()
const browser = await launch()
try {
  /* the chunk rule: the 200.html initial download carries no costs code */
  const html = await (await fetch(server.base + '/200.html')).text()
  const initial = [...new Set([
    ...[...html.matchAll(/<script\b[^>]*\bsrc="(\/_nuxt\/[A-Za-z0-9._-]+\.js)"/g)].map((m) => m[1]),
    ...[...html.matchAll(/<link\b[^>]*>/g)].map((m) => m[0]).filter((tag) => /\brel="modulepreload"/.test(tag))
      .map((tag) => (tag.match(/\bhref="(\/_nuxt\/[A-Za-z0-9._-]+\.js)"/) || [])[1]).filter(Boolean),
  ])]
  const withCosts = []
  for (const src of initial) {
    if (COSTS_MARKERS.test(await (await fetch(server.base + src)).text())) withCosts.push(src)
  }
  ok('200.html names its initial chunks', initial.length > 0, initial.length)
  ok('no costs page, pie or tenant-costs code in the initial download', withCosts.length === 0, withCosts)

  for (const [label, size] of [['desktop', { width: 1400, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    console.log(`-- ${label} ${size.width}x${size.height}`)

    /* a full month, the mock's default me (unrestricted) */
    {
      const { ctx, p } = await costsPage(browser, server.base, size)
      const res = await open(p, server.base, '/monitoring/costs')
      ok('/monitoring/costs answers 200', Boolean(res && res.status() === 200), res && res.status())
      const tabs = await tabIds(p)
      ok('the Costs tab shows (unrestricted me)', tabs.includes('costs'), tabs)
      const active = await p.$eval('[data-test=monitoring-tab-costs]', (e) => e.getAttribute('aria-current')).catch(() => '')
      ok('Costs is the active tab', active === 'page', active)
      ok('the table renders', await waitFor(p, '[data-test=costs-table]'))
      ok('one row per part (9) and a not-tracked row', (await count(p, '[data-test=costs-row]')) === 9
        && (await count(p, '[data-test=costs-not-tracked]')) === 1, await count(p, '[data-test=costs-row]'))
      const usd = await text(p, '[data-test=costs-total-usd]')
      const eur = await text(p, '[data-test=costs-total-eur]')
      ok('the total row in USD and EUR', usd === '$368.40' && eur === '€338.93', { usd, eur })
      ok('the by-hand mark on the invoice row', (await count(p, '[data-test=costs-hand]')) === 1)
      ok('the pie renders', await waitFor(p, '[data-test=costs-pie-svg]'))
      const slices = await p.$$eval('[data-test=costs-pie-slice]', (els) => els.map((e) => ({ k: e.getAttribute('data-key'), pct: Number(e.getAttribute('data-pct')) })))
      ok('5 slices over 1 % plus one "other"', slices.length === 6 && slices.at(-1).k === 'other', slices.map((s) => s.k))
      const sum = Math.round(slices.reduce((s, x) => s + x.pct, 0) * 10) / 10
      ok('the slices sum to 100 %', Math.abs(sum - 100) <= 0.2, sum)
      ok('the legend labels every slice', (await count(p, '[data-test=costs-pie-legend-row]')) === slices.length)
      const soFar = await text(p, '[data-test=costs-so-far]')
      ok('the current month is marked "so far"', /^So far: \d+ of \d+ days$/.test(soFar), soFar)
      ok('n of N per source (3 sources)', (await count(p, '[data-test=costs-coverage-row]')) === 3)
      const empties = await p.$$eval('[data-test=costs-empty-source]', (els) => els.map((e) => e.getAttribute('data-source')))
      ok('count-only sources are named, GCP has money', empties.join(',') === 'fleet_tokens,agent_hours', empties)
      const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      ok('no sideways scroll', wide <= 0, wide)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-costs-${size.width}.png`, fullPage: true })

      /* an earlier month: ended, so no "so far" mark (CONTROL: the mark follows the status) */
      const months = await p.$$eval('[data-test=costs-month] option', (els) => els.map((e) => e.value))
      ok('12 months, the current one first, none in the future', months.length === 12 && months[0] >= months[1], months.slice(0, 2))
      await p.select('[data-test=costs-month]', months[1])
      const gone = await p.waitForFunction(() => !document.querySelector('[data-test=costs-so-far]') && document.querySelector('[data-test=costs-table]'), { timeout: 15000 }).then(() => true, () => false)
      ok('an earlier month is not "so far"', gone)
      await ctx.close()
    }

    /* today's prd: counts only, no GCP rows */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { scenario: 'empty' })
      await open(p, server.base, '/monitoring/costs')
      ok('empty: the table renders', await waitFor(p, '[data-test=costs-table]'))
      ok('empty: no pie, its note instead', (await count(p, '[data-test=costs-pie-svg]')) === 0 && await waitFor(p, '[data-test=costs-no-pie]'))
      const empties = await p.$$eval('[data-test=costs-empty-source]', (els) => els.map((e) => e.textContent.trim()))
      ok('empty: "no cost data yet" for GCP, fleet tokens and agent hours', empties.length === 3 && empties[0] === 'No cost data yet for GCP', empties)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-costs-empty-${size.width}.png`, fullPage: true })
      await ctx.close()
    }

    /* a member without costs.read: no tab, and the direct URL is the 403 state */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { me: { role: 'developer', permissions: ['members.invite'] } })
      await open(p, server.base, '/monitoring/agents')
      await p.waitForFunction(() => document.querySelectorAll('[data-test^=monitoring-tab-]').length >= 2, { timeout: 15000 }).catch(() => null)
      const tabs = await tabIds(p)
      ok('without costs.read: no Costs tab', tabs.length >= 2 && !tabs.includes('costs'), tabs)
      await open(p, server.base, '/monitoring/costs')
      ok('without costs.read: the direct URL shows the 403 state', await waitFor(p, '[data-test=costs-forbidden]'))
      const why = await text(p, '[data-test=costs-forbidden]')
      ok('the 403 state names costs.read', why.includes('costs.read'), why)
      ok('without costs.read: no table', (await count(p, '[data-test=costs-table]')) === 0)
      await ctx.close()
    }

    /* CONTROL: the same opt-in me holding costs.read gets the tab */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { me: { role: 'biz_owner', permissions: ['costs.read'] } })
      await open(p, server.base, '/monitoring/agents')
      const shown = await waitFor(p, '[data-test=monitoring-tab-costs]')
      ok('with costs.read: the Costs tab shows', shown, await tabIds(p))
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `monitoring-costs: ${failed} FAILED` : `monitoring-costs: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
