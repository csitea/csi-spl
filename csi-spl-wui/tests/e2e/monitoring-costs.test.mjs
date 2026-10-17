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
//   - spec 123 5.4 (SPL-2199): the second-currency column, EUR unless
//     picked, each cell's title the rate and its date; Settings ->
//     Appearance "Second currency" saves the pick (PUT /preferences, answered
//     here as the hub would) and the column follows it; a part with no rate
//     shows the dash saying so (mock scenario 'norate').
//   - spec 140 (SPL-2322): Monitoring -> Tokens. For an operator admin (mock
//     opt-in) the Costs page carries the Tokens card (today's fleet tokens
//     and cost) linking to the Tokens tab: the KPI strip, the kinds (agy
//     "Not metered" with dashes, never 0; an unpriced kind "not priced"),
//     the lanes sorted by rate as numbers, the kind filter, the burn badges,
//     the stale marker (amber after 45 s, red after 90 s, cleared by
//     Refresh), the empty state. For anyone else: no card, no tab, and the
//     direct URL is the 403 sentence. No Tokens code in the initial download.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-costs
//   SHOT_DIR=<dir> keeps a screenshot per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { COSTS_MOCK_KEY } from '../../src/utils/tenant-costs.mjs'
import { TOKENS_MOCK_KEY, TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

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
const TOKENS_MARKERS = /"tokens-page"|"costs-tokens-card"|"spool\.mock\.fleet_tokens"/
const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const tabIds = (p) => p.$$eval('[data-test^=monitoring-tab-]', (els) => els.map((e) => e.getAttribute('data-test').slice('monitoring-tab-'.length)))

/** A fresh signed-in mock page at this size; `me` = the opt-in mock role + permissions, `scenario` = the mock month; `prefs`: PUT /preferences answered as the hub would, bodies kept in `p.saved`; `operator` = an operator admin, `tokens` = the mock fleet ('' busy, 'empty'). */
async function costsPage(browser, base, { width, height }, { me = null, scenario = '', prefs = false, operator = false, tokens = '' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const saved = []
  if (prefs) await p.setRequestInterception(true)
  if (prefs) p.on('request', (r) => {
    if (r.isInterceptResolutionHandled()) return
    if (r.method() === 'PUT' && /\/preferences$/.test(new URL(r.url()).pathname)) {
      saved.push(r.postData() || '')
      return r.respond({ status: 200, contentType: 'application/json', body: r.postData() || '{}' })
    }
    return r.continue()
  })
  p.saved = saved
  await p.setViewport({ width, height })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((meKey, m, costsKey, sc) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    if (m) localStorage.setItem(meKey, JSON.stringify(m)); else localStorage.removeItem(meKey)
    if (sc) localStorage.setItem(costsKey, sc); else localStorage.removeItem(costsKey)
  }, MOCK_ME_KEY, me, COSTS_MOCK_KEY, scenario)
  await p.evaluate((opKey, op, tkKey, tk) => {
    if (op) localStorage.setItem(opKey, '1'); else localStorage.removeItem(opKey)
    if (tk) localStorage.setItem(tkKey, tk); else localStorage.removeItem(tkKey)
  }, TOKENS_MOCK_OPERATOR_KEY, operator, TOKENS_MOCK_KEY, tokens)
  return { ctx, p }
}

async function open(p, base, path) {
  const res = await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=monitoring-tabs]', { visible: true, timeout: 20000 }).catch(() => null)
  return res
}

const titles = (p, sel) => p.$$eval(sel, (els) => els.map((e) => ({ src: e.closest('tr')?.getAttribute('data-source') || '', text: e.textContent.trim(), title: e.getAttribute('title') || '', none: e.getAttribute('data-none') })))
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const DAY = '\\d{4}-\\d{2}-\\d{2}'
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
  const withTokens = []
  for (const src of initial) {
    const js = await (await fetch(server.base + src)).text()
    if (COSTS_MARKERS.test(js)) withCosts.push(src)
    if (TOKENS_MARKERS.test(js)) withTokens.push(src)
  }
  ok('200.html names its initial chunks', initial.length > 0, initial.length)
  ok('no costs page, pie or tenant-costs code in the initial download', withCosts.length === 0, withCosts)
  ok('no Tokens page, card or monitoring-tokens code in the initial download', withTokens.length === 0, withTokens)

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

      /* spec 123 5.4: the second-currency column, EUR unless picked (the ended month: rate dates fixed) */
      const ended = months[1]
      const last = new Date(Date.UTC(+ended.slice(0, 4), +ended.slice(5, 7), 0)).toISOString().slice(0, 10)
      const head = await text(p, '[data-test=costs-second-head]')
      ok('second currency: the header names EUR (never picked)', head === 'EUR (day rate)', head)
      const cells = await titles(p, '[data-test=costs-second]')
      ok('second currency: one cell per part', cells.length === 9, cells.length)
      const inv = cells.find((c) => c.src === 'hand') || {}
      ok('second currency: the invoice row converted at its day rate, the rate and its date in the title',
        inv.text === '€184.00' && inv.title === `1 USD = 0.92 EUR, rate of ${last}`, inv)
      const gcp = cells.find((c) => c.src === 'gcp') || {}
      ok('second currency: a GCP row, each day at its own rate, the first and last rate dates in the title',
        gcp.text === '€58.42' && gcp.title === `Each day at its own rate, ${ended}-01 to ${last}. Latest: 1 USD = 0.92 EUR (${last})`, gcp)
      ok('second currency: no row is a dash (every day has a rate)', cells.every((c) => c.none === '0'), cells.map((c) => c.none))
      const tot = await text(p, '[data-test=costs-total-second]')
      ok('second currency: the total in EUR', tot === '€338.93', tot)
      const wide2 = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      ok('second currency: still no sideways scroll', wide2 <= 0, wide2)
      await ctx.close()
    }

    /* the personal setting: Settings -> Appearance -> Second currency, then the column follows it */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { prefs: true })
      await open(p, server.base, '/monitoring/costs')
      ok('setting: the table renders', await waitFor(p, '[data-test=costs-table]'))
      await go(p, '/settings/appearance')
      ok('setting: the Second currency picker shows', await waitFor(p, '[data-test=second-currency-select]'))
      await p.waitForFunction(() => document.querySelectorAll('[data-test=second-currency-select] option').length > 1, { timeout: 15000 }).catch(() => null)
      const opts = await p.$$eval('[data-test=second-currency-select] option', (os) => os.map((o) => ({ v: o.value, t: o.textContent.trim() })))
      ok('setting: filled from /v1/tenant/fx/currencies, EUR the default', opts.map((o) => o.v).join(',') === 'BGN,EUR,GBP,JPY,SEK'
        && (opts.find((o) => o.v === 'EUR') || {}).t === 'EUR (default)', opts)
      const picked0 = await p.$eval('[data-test=second-currency-select]', (e) => e.value).catch(() => '')
      ok('setting: EUR is picked while never picked', picked0 === 'EUR', picked0)
      await p.select('[data-test=second-currency-select]', 'SEK').catch(() => null)
      for (let i = 0; i < 50 && p.saved.length === 0; i++) await new Promise((r) => setTimeout(r, 100))
      ok('setting: the pick is saved through the hub setting (PUT /preferences second_currency)', p.saved.at(-1) === JSON.stringify({ second_currency: 'SEK' }), p.saved)
      await go(p, '/monitoring/costs')
      const sek = await p.waitForFunction(() => (document.querySelector('[data-test=costs-second-head]') || {}).textContent?.trim() === 'SEK (day rate)', { timeout: 15000 }).then(() => true, () => false)
      ok('setting: the column now names SEK', sek, await text(p, '[data-test=costs-second-head]'))
      const totSek = await text(p, '[data-test=costs-total-second]')
      ok('setting: the total converted at the SEK rate', /^SEK\s?3,868\.20$/.test(totSek), totSek)
      const sekCell = (await titles(p, '[data-test=costs-second]')).find((c) => c.src === 'hand') || {}
      ok('setting: the rate title names SEK', new RegExp(`^1 USD = 10\\.5 SEK, rate of ${DAY}$`).test(sekCell.title), sekCell)
      const usdNow = await text(p, '[data-test=costs-total-usd]')
      ok('setting: the USD column unchanged', usdNow === '$368.40', usdNow)
      /* CONTROL: back to the default sends null (the hub's EUR) and the column follows */
      await go(p, '/settings/appearance')
      await waitFor(p, '[data-test=second-currency-select]')
      await p.select('[data-test=second-currency-select]', 'EUR').catch(() => null)
      for (let i = 0; i < 50 && p.saved.length < 2; i++) await new Promise((r) => setTimeout(r, 100))
      ok('setting: picking the default clears it (second_currency null)', p.saved.at(-1) === JSON.stringify({ second_currency: null }), p.saved)
      await go(p, '/monitoring/costs')
      const eurBack = await p.waitForFunction(() => (document.querySelector('[data-test=costs-second-head]') || {}).textContent?.trim() === 'EUR (day rate)', { timeout: 15000 }).then(() => true, () => false)
      ok('setting: the column is back to EUR', eurBack, await text(p, '[data-test=costs-second-head]'))
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-costs-second-${size.width}.png`, fullPage: true })
      await ctx.close()
    }

    /* a part with no rate: the dash and a title saying so, never a guess; the total too */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { scenario: 'norate' })
      await open(p, server.base, '/monitoring/costs')
      ok('norate: the table renders', await waitFor(p, '[data-test=costs-table]'))
      const cells = await titles(p, '[data-test=costs-second]')
      const inv = cells.find((c) => c.src === 'hand') || {}
      ok('norate: the invoice row is a dash saying there is no rate', inv.text === '\u2014' && inv.none === '1'
        && inv.title === 'No EUR rate on or before a cost day, so no amount', inv)
      ok('norate: the other rows keep their amounts', cells.filter((c) => c.src !== 'hand').every((c) => c.none === '0' && c.text.startsWith('€')), cells)
      const tot = await p.$eval('[data-test=costs-total-second]', (e) => ({ text: e.textContent.trim(), title: e.getAttribute('title') || '' })).catch(() => ({}))
      ok('norate: the total is a dash too', tot.text === '\u2014' && /^No EUR rate/.test(tot.title), tot)
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

    /* spec 140 (SPL-2322): an operator admin, the busy mock fleet */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { operator: true })
      await open(p, server.base, '/monitoring/costs')
      ok('tokens: the Costs page carries the Tokens card for an operator admin', await waitFor(p, '[data-test=costs-tokens-card]'))
      const card = await text(p, '[data-test=costs-tokens-card-body]')
      ok('tokens: the card says today\'s fleet tokens and cost', card === '18.45M tokens used · $42.15', card)
      ok('tokens: the card names the unmetered and unpriced lanes', (await text(p, '[data-test=costs-tokens-card-note]')).includes('1 not metered · 1 not priced'))
      await p.click('[data-test=costs-tokens-card]')
      ok('tokens: the card opens the Tokens tab', await waitFor(p, '[data-test=tokens-page]'), p.url())
      ok('tokens: the URL is /monitoring/tokens', new URL(p.url()).pathname.replace(/\/$/, '') === '/monitoring/tokens', p.url())
      const tabs = await tabIds(p)
      ok('tokens: the Tokens tab shows beside Agents and Boxes, active', tabs.includes('tokens') && tabs.includes('agents') && tabs.includes('boxes')
        && await p.$eval('[data-test=monitoring-tab-tokens]', (e) => e.getAttribute('aria-current')).catch(() => '') === 'page', tabs)
      ok('tokens: the KPI strip renders', await waitFor(p, '[data-test=tokens-kpis]'))
      const kpi = { rate: await text(p, '[data-test=tokens-kpi-rate-value]'), today: await text(p, '[data-test=tokens-kpi-today-value]'), cost: await text(p, '[data-test=tokens-kpi-cost-value]') }
      ok('tokens: KPIs formatted (113.3K/min, 18.45M, $42.15)', kpi.rate === '113.3K/min' && kpi.today === '18.45M' && kpi.cost === '$42.15', kpi)
      const vendors = await p.$$eval('[data-test=tokens-vendor-row]', (els) => els.map((e) => ({ v: e.getAttribute('data-vendor'), s: e.getAttribute('data-status'),
        today: e.querySelector('[data-test=tokens-vendor-today]').textContent.trim(), cost: e.querySelector('[data-test=tokens-vendor-cost]').textContent.trim(),
        nm: Boolean(e.querySelector('[data-test=tokens-not-metered]')), np: Boolean(e.querySelector('[data-test=tokens-not-priced]')),
        burn: (e.querySelector('[data-test=tokens-burn-badge]') || { getAttribute: () => '' }).getAttribute('data-level') })))
      ok('tokens: five kinds in the hub order', vendors.map((v) => v.v).join(',') === 'claude,mistral,grok,agy,qwen', vendors.map((v) => v.v))
      const agy = vendors.find((v) => v.v === 'agy') || {}
      ok('tokens: agy is "Not metered" with dashes, never 0 tokens or $0.00', agy.nm && agy.s === 'unmetered' && agy.today === '\u2014' && agy.cost === '\u2014', agy)
      const mis = vendors.find((v) => v.v === 'mistral') || {}
      ok('tokens: a kind with an unpriced lane says "not priced", never $0.00', mis.np && mis.cost === 'not priced', mis)
      ok('tokens: claude surges (fresh 74.6K/min > 60K)', (vendors.find((v) => v.v === 'claude') || {}).burn === 'surge', vendors[0])
      const agents = () => p.$$eval('[data-test=tokens-agent-row]', (els) => els.map((e) => e.getAttribute('data-agent')))
      ok('tokens: lanes sorted by rate, highest first, agy last', (await agents()).join(',') === 'c-101,c-102,m-201,c-103,c-104,a-301', await agents())
      const lane = await p.$$eval('[data-test=tokens-agent-row]', (els) => els.map((e) => ({ a: e.getAttribute('data-agent'), s: e.getAttribute('data-status'),
        burn: (e.querySelector('[data-test=tokens-burn-badge]') || { getAttribute: () => '' }).getAttribute('data-level'),
        today: e.querySelector('[data-test=tokens-agent-today]').textContent.trim(), cost: e.querySelector('[data-test=tokens-agent-cost]').textContent.trim() })))
      const by = (id) => lane.find((l) => l.a === id) || {}
      ok('tokens: c-101 surges, c-102 has no badge', by('c-101').burn === 'surge' && by('c-102').burn === '', [by('c-101'), by('c-102')])
      ok('tokens: the agy lane is Not metered with dashes', by('a-301').s === 'not_metered' && by('a-301').today === '\u2014' && by('a-301').cost === '\u2014', by('a-301'))
      ok('tokens: the unpriced lane says "not priced"', by('m-201').cost === 'not priced', by('m-201'))
      ok('tokens: Active and Idle lanes', by('c-101').s === 'active' && by('c-104').s === 'idle', [by('c-101').s, by('c-104').s])
      if (size.width > 600) {
        await p.click('[data-test=tokens-sort-rate]')
        ok('tokens: the rate header sorts ascending as numbers, agy still last', (await agents()).join(',') === 'c-104,c-103,m-201,c-102,c-101,a-301', await agents())
      } else {
        /* a phone: each lane is a card, no header row (as the Costs table); the default order is the rate */
        ok('tokens: a phone shows the lanes as cards, no header row', await p.$eval('[data-test=tokens-agents] thead', (e) => getComputedStyle(e).display).catch(() => '') === 'none')
      }
      await p.select('[data-test=tokens-agent-filter]', 'agy')
      ok('tokens: the kind filter keeps only agy', (await agents()).join(',') === 'a-301', await agents())
      await p.select('[data-test=tokens-agent-filter]', '')
      const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      ok('tokens: no sideways scroll', wide <= 0, wide)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-tokens-${size.width}.png`, fullPage: true })
      /* the stale marker (4.3): the page clock jumps ahead, no poll answers in between */
      ok('tokens: fresh data has no stale mark', (await p.$eval('[data-test=tokens-age]', (e) => e.getAttribute('data-stale')).catch(() => '')) === 'ok')
      await p.evaluate(() => { const real = Date.now.bind(Date); window.__tkShift = 50000; Date.now = () => real() + window.__tkShift })
      ok('tokens: past 45 s the amber dot shows', await waitFor(p, '[data-test=tokens-stale-amber]'))
      ok('tokens: no red badge yet', (await count(p, '[data-test=tokens-stale-red]')) === 0)
      await p.evaluate(() => { window.__tkShift = 100000 })
      ok('tokens: past 90 s the red "Data stale" badge shows', await waitFor(p, '[data-test=tokens-stale-red]'), await text(p, '[data-test=tokens-stale-red]'))
      ok('tokens: the rows stay while stale', (await count(p, '[data-test=tokens-agent-row]')) === 6)
      await p.click('[data-test=tokens-refresh]')
      const cleared = await p.waitForFunction(() => !document.querySelector('[data-test=tokens-stale-red]') && document.querySelector('[data-test=tokens-age]')?.getAttribute('data-stale') === 'ok', { timeout: 10000 }).then(() => true, () => false)
      ok('tokens: Refresh clears the stale mark', cleared)
      await ctx.close()
    }

    /* the empty fleet: no lane yet, an honest sentence, agy still not metered */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { operator: true, tokens: 'empty' })
      await open(p, server.base, '/monitoring/tokens')
      ok('tokens empty: the empty sentence', await waitFor(p, '[data-test=tokens-agents-empty]'))
      ok('tokens empty: agy still "Not metered"', (await count(p, '[data-test=tokens-vendor-row][data-vendor=agy] [data-test=tokens-not-metered]')) === 1)
      await ctx.close()
    }

    /* CONTROL: not an operator admin: no card, no tab, the direct URL is the 403 sentence */
    {
      const { ctx, p } = await costsPage(browser, server.base, size)
      await open(p, server.base, '/monitoring/costs')
      await waitFor(p, '[data-test=costs-table]')
      ok('tokens control: no Tokens card on Costs', (await count(p, '[data-test=costs-tokens-card]')) === 0)
      ok('tokens control: no Tokens tab', !(await tabIds(p)).includes('tokens'), await tabIds(p))
      await open(p, server.base, '/monitoring/tokens')
      ok('tokens control: the direct URL shows the 403 sentence', await waitFor(p, '[data-test=tokens-forbidden]'))
      ok('tokens control: no table', (await count(p, '[data-test=tokens-agent-row]')) === 0 && (await count(p, '[data-test=tokens-kpis]')) === 0)
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
