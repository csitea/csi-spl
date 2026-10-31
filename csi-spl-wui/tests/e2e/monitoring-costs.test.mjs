// Spec 123 5 + 8 (SPL-2056, owner HUM-10, t1 dbf2f39b): Costs, now
// Reporting -> Costs (spec 143 S1, SPL-3798; Monitoring has no Costs tab,
// SPL-3986), in a real browser, against the mock bundle (dev has no cost
// rows), at 1400x900 and 390x844:
//   - the Reporting Costs tab shows for a member with costs.read (the mock's default me is
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
//   - spec 143 3.3.1 (SPL-3891): a customer workspace's Spend names its
//     ai_share rows "AI subscriptions (your share)" and says from which day
//     its share is counted (mock 'share'), or that none is yet, today's
//     tokens showing tomorrow (mock 'share_none', a customer workspace's answer of
//     2026-10-27); no ai_paid row, no plan.
//   - spec 140 (SPL-2322): Monitoring -> Tokens. For an operator admin (mock
//     opt-in) the Costs page carries the Tokens card (today's fleet tokens
//     and cost) linking to the Tokens tab: the KPI strip, the kinds (qwen
//     "Not metered" with dashes, never 0; an unpriced kind "not priced"),
//     the lanes sorted by rate as numbers, the kind filter, the burn badges,
//     the stale marker (amber after 45 s, red after 90 s, cleared by
//     Refresh), the empty state. For anyone else: no card, no tab, and the
//     direct URL is the 403 sentence. No Tokens code in the initial download.
//   - spec 140 3.8 (SPL-2567): the Tokens tab's Paid card for an operator
//     admin: empty -> the form refuses a 0 price and an end before the start
//     -> add one item -> it shows, the effective price for its vendor ->
//     edit -> the hub's refusal text shows as it came -> delete -> empty.
//     Anyone else: no Paid card.
//   - spec 153 3.1 (SPL-3157), cases C1-C5: the tab bar sits on the
//     heading's row, inside the header (C1), its first label 20 px after
//     "Monitoring" on the same line (C2), the active underline on the
//     header's bottom border (C2b); at 320 px in nl (the longest labels)
//     one row, the bar scrolls inside itself with no scrollbar, the page
//     never sideways (C3; a phone shows no heading, CLE-77886, so the bar
//     is the row and never grows taller than a tab); the end X stays the
//     header's last element under close_buttons 'windows' (C4), the start
//     X before the heading and no end X under the default 'mac' (C4b).
//     C5 is every other case here finding the bar by data-test.
//   - SPL-3887: the Lanes table sorts by a column-name click (the Issues
//     sheet's SheetSortButton: ▲, ▼, the hub order) and filters by box,
//     vendor, state, age and text; Clear filters shows every lane again.
//   - spec 153 3.2 (SPL-3215, row B4): C3b, C3 again at 360 px with the
//     fifth tab (Lanes) as an operator admin; C17, Monitoring -> Lanes on
//     the mock fleet of 3 lanes: a row's discussion links /t/<uuid>, a
//     foreign topic and no topic link nothing, the issue keys link
//     /issues?issue=<KEY>; anyone else: no tab, the direct URL is the 403
//     sentence. No Lanes code in the initial download.
//
//   - spec 143 costs-redesign.md slice S1 (SPL-3798): the costs page is
//     Reporting -> Costs -> Spend now (/reporting/costs/spend); the Reporting
//     tab shows with costs.read only; the page bar (Spend, Tokens; Price per
//     token and Paid items for an operator admin), the header's month and
//     currency in the query, kept across the pages; the redirects
//     /monitoring/costs?month=2026-09 -> /reporting/costs/spend?month=2026-09,
//     /reporting/tokens -> /reporting/costs/tokens, /reporting/costs -> Spend.
//   - SPL-4187 (spec 123 5.5): the three sections. The bar is Spend, AI
//     tokens, Human for a member; Spend, Cloud, AI tokens, Human, Price,
//     Paid for an operator admin. Cloud drills down GCP project -> service
//     -> day (?project=, &kind=), each level's total the row it came from,
//     the crumbs and the back button walk up; anyone else opening Cloud
//     gets the operators-only line. AI tokens lists the month's token
//     parts; Human says "not tracked yet" naming spec 107 T071..T077.
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
import { PAID_MOCK_REFUSE_KEY } from '../../src/utils/monitoring-paid.mjs'
import { LANES_MOCK_TOPIC } from '../../src/utils/monitoring-lanes.mjs'

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
const LANES_MARKERS = /"lanes-page"|"lanes-row"|"spool\.mock\.fleet_lanes"/
const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const tabIds = (p) => p.$$eval('[data-test^=monitoring-tab-]', (els) => els.map((e) => e.getAttribute('data-test').slice('monitoring-tab-'.length)))

/** A fresh signed-in mock page at this size; `me` = the opt-in mock role + permissions, `scenario` = the mock month; `prefs`: PUT /preferences answered as the hub would, bodies kept in `p.saved`; `operator` = an operator admin, `tokens` = the mock fleet ('' busy, 'empty'). */
async function costsPage(browser, base, { width, height }, { me = null, scenario = '', prefs = false, operator = false, tokens = '', closeButtons = null } = {}) {
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
  await p.evaluate((meKey, m, costsKey, sc, cb) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock', ...(cb ? { close_buttons: cb } : {}) }))
    if (m) localStorage.setItem(meKey, JSON.stringify(m)); else localStorage.removeItem(meKey)
    if (sc) localStorage.setItem(costsKey, sc); else localStorage.removeItem(costsKey)
  }, MOCK_ME_KEY, me, COSTS_MOCK_KEY, scenario, closeButtons)
  await p.evaluate((opKey, op, tkKey, tk) => {
    if (op) localStorage.setItem(opKey, '1'); else localStorage.removeItem(opKey)
    if (tk) localStorage.setItem(tkKey, tk); else localStorage.removeItem(tkKey)
  }, TOKENS_MOCK_OPERATOR_KEY, operator, TOKENS_MOCK_KEY, tokens)
  return { ctx, p }
}

async function open(p, base, path) {
  const res = await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const bar = /^\/(?:[a-z]{2}\/)?reporting\//.test(path) ? 'reporting-tabs' : 'monitoring-tabs'
  await p.waitForSelector(`[data-test=${bar}]`, { visible: true, timeout: 20000 }).catch(() => null)
  return res
}
const SPEND = '/reporting/costs/spend'
const reportingTabIds = (p) => p.$$eval('[data-test^=reporting-tab-]', (els) => els.map((e) => e.getAttribute('data-test').slice('reporting-tab-'.length)))
const costsPageIds = (p) => p.$$eval('[data-test^=costs-page-]', (els) => els.map((e) => e.getAttribute('data-test').slice('costs-page-'.length)))
const where = (p) => { const u = new URL(p.url()); return u.pathname.replace(/\/$/, '') + u.search }
const waitWhere = (p, want) => p.waitForFunction((w) => location.pathname.replace(/\/$/, '') + location.search === w, { timeout: 15000 }, want).then(() => true, () => false)

/** costs-redesign.md slice S1 (SPL-3798): the redirects, the page bar and the header. CONTROL: on master before S1 /monitoring/costs is the page itself, so the redirect checks FAIL there. */
async function costsS1(browser, base, size) {
  {
    const { ctx, p } = await costsPage(browser, base, size)
    await open(p, base, '/monitoring/costs?month=2026-09')
    ok('S1 redirect: /monitoring/costs?month=2026-09 -> /reporting/costs/spend?month=2026-09', await waitWhere(p, SPEND + '?month=2026-09'), where(p))
    ok('S1 redirect: the Spend page renders the month asked for, not "so far"', await waitFor(p, '[data-test=costs-table]') && (await count(p, '[data-test=costs-so-far]')) === 0)
    const months = await p.$$eval('[data-test=costs-header-month] option', (els) => els.map((e) => e.value))
    const cur = new Date().toISOString().slice(0, 7)
    ok('S1 header: months from the current one back to 2026-10, the URL month kept, none in the future', months[0] === cur && months.includes('2026-09')
      && months.filter((m) => m !== '2026-09').every((m) => m >= '2026-10' && m <= cur), months)
    ok('S1 header: the picker shows the URL month', (await p.$eval('[data-test=costs-header-month]', (e) => e.value).catch(() => '')) === '2026-09')
    ok('S1 tab: Reporting -> Costs is the active tab', (await p.$eval('[data-test=reporting-tab-costs]', (e) => e.getAttribute('aria-current')).catch(() => '')) === 'page')
    ok('S1 bar: Spend, AI tokens and Human for a non-operator, Spend active', (await costsPageIds(p)).join(',') === 'spend,tokens,human'
      && (await p.$eval('[data-test=costs-page-spend]', (e) => e.getAttribute('aria-current')).catch(() => '')) === 'page', await costsPageIds(p))
    const curs = await p.$$eval('[data-test^=costs-header-cur-]', (els) => els.map((e) => [e.textContent.trim(), e.getAttribute('aria-checked')]))
    ok('S1 header: USD (picked, the default) or EUR', JSON.stringify(curs) === JSON.stringify([['USD', 'true'], ['EUR', 'false']]), curs)
    await p.click('[data-test=costs-header-cur-EUR]')
    ok('S1 header: picking EUR writes ?currency=EUR, the month kept', await waitWhere(p, SPEND + '?month=2026-09&currency=EUR'), where(p))
    await p.click('[data-test=costs-page-tokens]')
    ok('S1 bar: Tokens keeps the month and the currency', await waitWhere(p, '/reporting/costs/tokens?month=2026-09&currency=EUR'), where(p))
    ok('SPL-4187 AI tokens: the month\'s token parts, no shell', await waitFor(p, '[data-test=costs-tokens-table]')
      && (await count(p, '[data-test=costs-tokens-row]')) >= 1 && (await count(p, '[data-test=costs-shell-coming]')) === 0, await count(p, '[data-test=costs-tokens-row]'))
    await p.goBack()
    ok('S1 back: Spend again, the same query', await waitWhere(p, SPEND + '?month=2026-09&currency=EUR'), where(p))
    if (size.width < 600) ok('S1: no sideways scroll on a phone', (await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)) <= 0)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-costs-spend-${size.width}.png`, fullPage: true })
    await open(p, base, '/reporting/tokens')
    ok('S1 redirect: /reporting/tokens -> /reporting/costs/tokens', await waitWhere(p, '/reporting/costs/tokens'), where(p))
    await open(p, base, '/reporting/costs?month=2026-09')
    ok('S1 redirect: /reporting/costs -> Spend, the query kept', await waitWhere(p, SPEND + '?month=2026-09'), where(p))
    await open(p, base, '/monitoring/tokens')
    ok('S1: /monitoring/tokens stays', (await waitFor(p, '[data-test=tokens-forbidden]')) && where(p) === '/monitoring/tokens', where(p))
    await ctx.close()
  }
  {
    const { ctx, p } = await costsPage(browser, base, size, { operator: true })
    await open(p, base, SPEND)
    await p.waitForFunction(() => document.querySelectorAll('[data-test^=costs-page-]').length === 6, { timeout: 15000 }).catch(() => null)
    ok('S1 bar: an operator admin sees all six pages', (await costsPageIds(p)).join(',') === 'spend,cloud,tokens,human,price,paid', await costsPageIds(p))
    for (const id of ['price', 'paid']) {
      await p.click(`[data-test=costs-page-${id}]`)
      ok(`S1 ${id}: the shell for an operator admin`, await waitFor(p, `[data-test=costs-shell-${id}] [data-test=costs-shell-coming]`))
    }
    await ctx.close()
  }
  {
    /* CONTROL: a non-operator opening Paid items directly gets the operators-only line, no shell */
    const { ctx, p } = await costsPage(browser, base, size)
    await open(p, base, '/reporting/costs/paid')
    ok('S1 control: Paid items direct URL, not an operator admin: operators only', await waitFor(p, '[data-test=costs-shell-paid] [data-test=reporting-operators-only]')
      && (await count(p, '[data-test=costs-shell-coming]')) === 0)
    await ctx.close()
  }
}

/** SPL-4187: the three sections. CONTROL: on master before it there is no Cloud or Human page, so every check here FAILS there. */
async function costsSections(browser, base, size) {
  {
    const { ctx, p } = await costsPage(browser, base, size, { operator: true })
    const root = '/reporting/costs/cloud?month=2026-09'
    await open(p, base, root)
    const keys = () => p.$$eval('[data-test=cloud-row]', (els) => els.map((e) => e.getAttribute('data-key')))
    await p.waitForSelector('[data-test=cloud-row]', { visible: true, timeout: 20000 }).catch(() => null)
    ok('Cloud level 1: one row per GCP project, the most expensive first', (await keys()).join(',') === 'project-prd,project-all,project-dev', await keys())
    ok('Cloud level 1: the money in the header\'s currency (USD)', (await text(p, '[data-test=cloud-currency]')) === 'USD')
    const prdAmount = await text(p, '[data-test=cloud-row][data-key=project-prd] [data-test=cloud-amount]')
    await p.click('[data-test=cloud-row][data-key=project-prd] [data-test=cloud-drill]')
    ok('Cloud level 2: a project\'s services, in the query', await waitWhere(p, '/reporting/costs/cloud?month=2026-09&project=project-prd'), where(p))
    await p.waitForFunction(() => document.querySelector('[data-test=costs-cloud]')?.getAttribute('data-level') === 'service', { timeout: 15000 }).catch(() => null)
    ok('Cloud level 2: cloud_sql, cloud_run, network; the total is the project row', (await keys()).join(',') === 'cloud_sql,cloud_run,network'
      && (await text(p, '[data-test=cloud-total-amount]')) === prdAmount, [await keys(), prdAmount, await text(p, '[data-test=cloud-total-amount]')])
    const sqlAmount = await text(p, '[data-test=cloud-row][data-key=cloud_sql] [data-test=cloud-amount]')
    await p.click('[data-test=cloud-row][data-key=cloud_sql] [data-test=cloud-drill]')
    ok('Cloud level 3: the service per day, in the query', await waitWhere(p, '/reporting/costs/cloud?month=2026-09&project=project-prd&kind=cloud_sql'), where(p))
    await p.waitForFunction(() => document.querySelector('[data-test=costs-cloud]')?.getAttribute('data-level') === 'day' && document.querySelectorAll('[data-test=cloud-row]').length > 0, { timeout: 15000 }).catch(() => null)
    const days = await keys()
    ok('Cloud level 3: the 30 days of September, oldest first; the total is the service row', days.length === 30 && days[0] === '2026-09-01' && days[29] === '2026-09-30'
      && (await text(p, '[data-test=cloud-total-amount]')) === sqlAmount, [days.length, sqlAmount, await text(p, '[data-test=cloud-total-amount]')])
    if (size.width < 600) ok('Cloud: no sideways scroll on a phone', (await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)) <= 0)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-costs-cloud-day-${size.width}.png`, fullPage: true })
    await p.click('[data-test=cloud-crumb-project]')
    ok('Cloud crumbs: the project crumb walks up to the services', await waitWhere(p, '/reporting/costs/cloud?month=2026-09&project=project-prd'), where(p))
    await p.goBack()
    ok('Cloud back: the day level again', await waitWhere(p, '/reporting/costs/cloud?month=2026-09&project=project-prd&kind=cloud_sql'), where(p))
    await p.click('[data-test=cloud-crumb-all]')
    ok('Cloud crumbs: All projects is level 1, the month kept', await waitWhere(p, root), where(p))
    await p.click('[data-test=costs-page-human]')
    ok('Human: "not tracked yet", naming spec 107 T071..T077', await waitFor(p, '[data-test=costs-human-not-tracked]')
      && (await text(p, '[data-test=costs-human-not-tracked]')).includes('T071..T077'), await text(p, '[data-test=costs-human-not-tracked]'))
    await ctx.close()
  }
  {
    /* CONTROL: a member opening Cloud directly gets the operators-only line, no table */
    const { ctx, p } = await costsPage(browser, base, size)
    await open(p, base, '/reporting/costs/cloud')
    ok('Cloud control: a direct URL, not an operator admin: operators only, no table', await waitFor(p, '[data-test=costs-cloud] [data-test=reporting-operators-only]')
      && (await count(p, '[data-test=cloud-table]')) === 0)
    await ctx.close()
  }
}

const titles = (p, sel) => p.$$eval(sel, (els) => els.map((e) => ({ src: e.closest('tr')?.getAttribute('data-source') || '', text: e.textContent.trim(), title: e.getAttribute('title') || '', none: e.getAttribute('data-none') })))
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const DAY = '\\d{4}-\\d{2}-\\d{2}'
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
/** Set a form field as a person would (an input event Vue's v-model reads); works for date inputs in any locale. */
const setField = (p, sel, value) => p.$eval(sel, (e, v) => {
  e.value = v
  e.dispatchEvent(new Event(e.tagName === 'SELECT' ? 'change' : 'input', { bubbles: true }))
}, value)
const isoDay = (offset) => new Date(Date.now() + offset * 86400000).toISOString().slice(0, 10)
const waitText = (p, sel, want) => p.waitForFunction((s, w) => (document.querySelector(s)?.textContent || '').replace(/\s+/g, ' ').trim() === w, { timeout: 10000 }, sel, want).then(() => true, () => false)

/** SPL-2567: the Paid card's whole round on the Tokens tab: empty, add, edit, a refusal, delete, empty. */
async function paidRound(p, base, size) {
  await open(p, base, '/monitoring/tokens')
  ok('paid: the Paid card shows for an operator admin', await waitFor(p, '[data-test=paid-card]'))
  ok('paid: no item yet', await waitFor(p, '[data-test=paid-empty]'))
  ok('paid: the effective table lists five kinds', await waitFor(p, '[data-test=paid-effective]') && (await count(p, '[data-test=paid-effective-row]')) === 5)
  const claudeStatus = () => p.$eval('[data-test=paid-effective-row][data-vendor=claude]', (e) => e.getAttribute('data-status')).catch(() => '')
  ok('paid: claude has the list price only', (await claudeStatus()) === 'list_only', await claudeStatus())
  await p.click('[data-test=paid-add]')
  ok('paid: Add opens the form', await waitFor(p, '[data-test=paid-form]'))
  await setField(p, '[data-test=paid-f-plan]', 'E2E fixture')
  await setField(p, '[data-test=paid-f-amount]', '0')
  await p.click('[data-test=paid-save]')
  ok('paid: a 0 price is refused before sending', await waitText(p, '[data-test=paid-form-error]', 'The price must be a number above 0.'), await text(p, '[data-test=paid-form-error]'))
  await setField(p, '[data-test=paid-f-amount]', '300')
  await setField(p, '[data-test=paid-f-start]', isoDay(-10))
  await setField(p, '[data-test=paid-f-end]', isoDay(-10))
  await p.click('[data-test=paid-save]')
  ok('paid: an end not after the start is refused', await waitText(p, '[data-test=paid-form-error]', 'The first day not paid must come after the first day paid.'), await text(p, '[data-test=paid-form-error]'))
  await setField(p, '[data-test=paid-f-end]', isoDay(20))
  await p.click('[data-test=paid-save]')
  ok('paid: the added item shows', await waitFor(p, '[data-test=paid-item-row]') && (await count(p, '[data-test=paid-item-row]')) === 1)
  ok('paid: the form closes on save', (await count(p, '[data-test=paid-form]')) === 0)
  ok('paid: its plan and price', (await text(p, '[data-test=paid-item-plan]')) === 'E2E fixture' && (await text(p, '[data-test=paid-item-amount]')) === '$300.00', [await text(p, '[data-test=paid-item-plan]'), await text(p, '[data-test=paid-item-amount]')])
  await p.waitForFunction(() => document.querySelector('[data-test=paid-effective-row][data-vendor=claude]')?.getAttribute('data-status') === 'effective', { timeout: 10000 }).catch(() => null)
  const eff = await text(p, '[data-test=paid-effective-row][data-vendor=claude] [data-test=paid-eff-value]')
  ok('paid: claude now has an effective price per 1M tokens', (await claudeStatus()) === 'effective' && /^\$\d+\.\d{2,4}$/.test(eff), [await claudeStatus(), eff])
  ok('paid: 10 of its 30 days in the range: $100.00 paid', (await text(p, '[data-test=paid-effective-row][data-vendor=claude] [data-test=paid-eff-paid]')) === '$100.00')
  ok('paid: grok (no price held) says "not priced" for its list price, never $0.00', (await text(p, '[data-test=paid-effective-row][data-vendor=grok] [data-test=paid-eff-list]')) === 'not priced')
    await p.click('[data-test=paid-edit]')
  ok('paid: Edit opens the form with the item', await waitFor(p, '[data-test=paid-form]') && (await p.$eval('[data-test=paid-f-plan]', (e) => e.value)) === 'E2E fixture')
  await setField(p, '[data-test=paid-f-plan]', 'E2E fixture edited')
  await setField(p, '[data-test=paid-f-amount]', '150')
  await p.click('[data-test=paid-save]')
  ok('paid: the edit shows', await waitText(p, '[data-test=paid-item-plan]', 'E2E fixture edited') && (await text(p, '[data-test=paid-item-amount]')) === '$150.00', await text(p, '[data-test=paid-item-amount]'))
  await p.evaluate((k) => localStorage.setItem(k, 'currency must be USD or one the hub holds an exchange rate for'), PAID_MOCK_REFUSE_KEY)
  await p.click('[data-test=paid-edit]')
  await waitFor(p, '[data-test=paid-form]')
  await p.click('[data-test=paid-save]')
  ok('paid: the hub refusal shows its own text', await waitText(p, '[data-test=paid-form-refused]', 'The hub refused it: currency must be USD or one the hub holds an exchange rate for'), await text(p, '[data-test=paid-form-refused]'))
  await p.click('[data-test=paid-cancel]')
  /* agy is paid but logs no tokens: the hub's not_metered, shown as such with its daily share */
  await p.click('[data-test=paid-add]')
  await waitFor(p, '[data-test=paid-form]')
  await setField(p, '[data-test=paid-f-vendor]', 'agy')
  await setField(p, '[data-test=paid-f-plan]', 'E2E fixture agy')
  await setField(p, '[data-test=paid-f-amount]', '30')
  await setField(p, '[data-test=paid-f-start]', isoDay(-30))
  await setField(p, '[data-test=paid-f-end]', isoDay(0))
  await p.click('[data-test=paid-save]')
  ok('paid: a second item shows', await p.waitForFunction(() => document.querySelectorAll('[data-test=paid-item-row]').length === 2, { timeout: 10000 }).then(() => true, () => false))
  await p.waitForFunction(() => document.querySelector('[data-test=paid-effective-row][data-vendor=agy]')?.getAttribute('data-status') === 'not_metered', { timeout: 10000 }).catch(() => null)
  ok('paid: agy paid but unmetered says "Not metered", its daily share $1.00', (await text(p, '[data-test=paid-effective-row][data-vendor=agy] [data-test=paid-eff-value]')) === 'Not metered'
    && (await text(p, '[data-test=paid-effective-row][data-vendor=agy] [data-test=paid-eff-day]')) === '$1.00', await text(p, '[data-test=paid-effective-row][data-vendor=agy]'))
  if (size.width < 600) ok('paid: no sideways scroll on a phone', (await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)) <= 0)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-tokens-paid-${size.width}.png`, fullPage: true })
  for (let i = 0; i < 2; i++) {
    const left = await count(p, '[data-test=paid-item-row]')
    await p.click('[data-test=paid-delete]')
    ok('paid: Delete asks first', await waitFor(p, '[data-test=paid-delete-yes]'))
    await p.click('[data-test=paid-delete-yes]')
    await p.waitForFunction((n) => document.querySelectorAll('[data-test=paid-item-row]').length < n, { timeout: 10000 }, left).catch(() => null)
  }
  ok('paid: deleted, the card is empty again', await waitFor(p, '[data-test=paid-empty]') && (await count(p, '[data-test=paid-item-row]')) === 0)
  ok('paid: claude is back to the list price only', await p.waitForFunction(() => document.querySelector('[data-test=paid-effective-row][data-vendor=claude]')?.getAttribute('data-status') === 'list_only', { timeout: 10000 }).then(() => true, () => false))
}

/** Spec 153 3.1: where the heading, the bar, its first label, the active tab and the close X are drawn. Text edges come from a Range over the text, not the boxes. */
const tabRowGeometry = (p) => p.evaluate(() => {
  const header = document.querySelector('[data-test=monitoring-page] > header')
  const h2 = document.querySelector('[data-test=monitoring-heading]')
  const nav = document.querySelector('[data-test=monitoring-tabs]')
  const first = nav?.querySelector('a')
  const active = nav?.querySelector('[aria-current=page]')
  const textRect = (el) => { const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect() }
  if (!header || !h2 || !nav || !first) return null
  const head = textRect(h2)
  const label = textRect(first)
  const kids = [...header.children]
  const tabs = [...nav.querySelectorAll('a')].map((a) => a.getBoundingClientRect())
  const at = (sel) => kids.findIndex((e) => e.matches(sel))
  return {
    inHeader: nav.closest('header') === header,
    gap: Math.round((label.left - head.right) * 10) / 10,
    topDiff: Math.round(Math.abs(label.top - head.top) * 10) / 10,
    activeBottom: active ? Math.round((active.getBoundingClientRect().bottom - header.getBoundingClientRect().bottom) * 10) / 10 : null,
    activeToBar: active ? Math.round((active.getBoundingClientRect().bottom - nav.getBoundingClientRect().bottom) * 10) / 10 : null,
    h2Shown: getComputedStyle(h2).display !== 'none',
    /* SPL-3397: the selected folder tab stands taller, so one row is one BOTTOM line */
    tabBottoms: Math.round((Math.max(...tabs.map((r) => r.bottom)) - Math.min(...tabs.map((r) => r.bottom))) * 10) / 10,
    barOverTab: Math.round(nav.getBoundingClientRect().height - Math.max(...tabs.map((r) => r.height))),
    pageWide: document.documentElement.scrollWidth - window.innerWidth,
    navOverflows: nav.scrollWidth > nav.clientWidth,
    navScrollbar: nav.offsetHeight - nav.clientHeight,
    navRightGap: Math.round(header.getBoundingClientRect().right - parseFloat(getComputedStyle(header).paddingRight) - nav.getBoundingClientRect().right),
    last: header.lastElementChild?.getAttribute('data-close-side') || header.lastElementChild?.tagName.toLowerCase(),
    start: at('[data-close-side=start]'), h2: at('h2'), end: at('[data-close-side=end]'),
  }
})

/** Spec 153 3.1 cases C1-C4b: the tab bar on the heading's row. CONTROL: on master before SPL-3157 the bar is a sibling below the header, so C1, C2 and C2b FAIL there, and C3's scroll inside the bar. */
async function tabRow(browser, base) {
  for (const [label, size, path, opts] of [
    ['desktop 1280 mac', { width: 1280, height: 900 }, '/monitoring/agents', {}],
    ['desktop 1280 windows', { width: 1280, height: 900 }, '/monitoring/agents', { closeButtons: 'windows' }],
    ['phone 320 nl', { width: 320, height: 800 }, '/nl/monitoring/agents', {}],
    /* C3b (spec 153, SPL-3215): C3 again with the tabs of an operator admin (six since SPL-3250's Events), Lanes last */
    ['phone 360 nl operator', { width: 360, height: 800 }, '/nl/monitoring/agents', { operator: true }],
  ]) {
    const { ctx, p } = await costsPage(browser, base, size, opts)
    await open(p, base, path)
    const want = opts.operator ? 5 : 3
    await p.waitForFunction((n) => document.querySelectorAll('[data-test^=monitoring-tab-]').length >= n, { timeout: 15000 }, want).catch(() => null)
    const g = await tabRowGeometry(p)
    const phone = size.width < 600
    if (opts.operator) {
      const ids = await tabIds(p)
      ok(`C3b ${label}: five tabs, Lanes last, no Costs (SPL-3986)`, ids.join(',') === 'agents,boxes,events,tokens,lanes', ids)
    }
    ok(`C1 ${label}: the tab bar is inside the header`, Boolean(g && g.inHeader), g)
    if (phone) {
      ok(`C3 ${label}: no heading on a phone section page (CLE-77886)`, Boolean(g && !g.h2Shown), g)
      ok(`C3 ${label}: the tabs on one row`, Boolean(g && g.tabBottoms <= 1), g && g.tabBottoms)
      ok(`C3 ${label}: the tabs overflow the row (the case is real)`, Boolean(g && g.navOverflows), g)
      ok(`C3 ${label}: the bar scrolls inside itself, never taller than a tab`, Boolean(g && g.navOverflows && g.barOverTab === 0), g && g.barOverTab)
      ok(`C3 ${label}: the active underline on the bar's bottom line`, Boolean(g && g.activeToBar !== null && Math.abs(g.activeToBar) <= 1), g && g.activeToBar)
      ok(`C3 ${label}: no sideways page scroll`, Boolean(g && g.pageWide <= 0), g && g.pageWide)
      ok(`C3 ${label}: no scrollbar drawn under the tabs`, Boolean(g && g.navScrollbar === 0), g && g.navScrollbar)
    } else {
      ok(`C2 ${label}: the first label on the heading's line`, Boolean(g && g.topDiff <= 4), g && g.topDiff)
      ok(`C2 ${label}: the first label 20 px +-2 after the heading text`, Boolean(g && Math.abs(g.gap - 20) <= 2), g && g.gap)
      ok(`C2b ${label}: the active tab's bottom on the header's bottom (+-1 px)`, Boolean(g && g.activeBottom !== null && Math.abs(g.activeBottom) <= 1), g && g.activeBottom)
      if (opts.closeButtons === 'windows') {
        ok(`C4 ${label}: the end close X is the header's last element`, Boolean(g && g.last === 'end' && g.end > g.h2), g)
      } else {
        ok(`C4b ${label}: the start X before the heading, no end X`, Boolean(g && g.start >= 0 && g.start < g.h2 && g.end === -1), g)
        ok(`C4b ${label}: the bar runs to the row's end`, Boolean(g && g.navRightGap <= 1), g && g.navRightGap)
      }
    }
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-tab-row-${label.replace(/ /g, '-')}.png` })
    await ctx.close()
  }
}

/** SPL-3887 (owner HUM-10, t1 31f6f470, msgs 1eedefed and 08b25696): the Lanes table sorts by a column-name click and filters by box, vendor, state, age and text, the Issues sheet's controls. CONTROL: on master the names are plain text and no filter row exists, so every check here FAILS there. */
async function lanesSortFilter(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size, { operator: true })
  await open(p, base, '/monitoring/lanes')
  const order = () => p.$$eval('[data-test=lanes-row]', (els) => els.map((e) => e.getAttribute('data-agent')).join(','))
  const until = (want) => p.waitForFunction((w) => [...document.querySelectorAll('[data-test=lanes-row]')].map((e) => e.getAttribute('data-agent')).join(',') === w, { timeout: 5000 }, want).then(() => true, () => false)
  ok('3887 lanes: three rows in the hub order', await until('c-085,a-277,m-039'), await order())
  const names = await p.$$eval('[data-test=lanes-table] thead tr:first-child th', (els) => els.map((th) => (th.querySelector('button.issues-sort-h') ? 'b' : '-')).join(''))
  ok('3887 lanes: every column name is the Issues sheet\'s sort button', names === 'bbbbbbbbb', names)
  const aria = () => p.$eval('[data-test=lanes-sort-agent]', (b) => b.closest('th').getAttribute('aria-sort') + ':' + b.querySelector('.issues-sort-mark').textContent)
  await p.click('[data-test=lanes-sort-agent]')
  ok('3887 lanes: a name click sorts ascending, ▲', (await until('a-277,c-085,m-039')) && (await aria()) === 'ascending:▲', [await order(), await aria()])
  await p.click('[data-test=lanes-sort-agent]')
  ok('3887 lanes: a second click sorts descending, ▼', (await until('m-039,c-085,a-277')) && (await aria()) === 'descending:▼', [await order(), await aria()])
  await p.click('[data-test=lanes-sort-agent]')
  ok('3887 lanes: a third click is the hub order again, no mark', (await until('c-085,a-277,m-039')) && (await aria()) === 'none:', [await order(), await aria()])
  await p.click('[data-test=lanes-sort-updated]')
  ok('3887 lanes: Updated ascending = oldest write first', await until('m-039,a-277,c-085'), await order())
  await p.click('[data-test=lanes-sort-updated]')
  await p.click('[data-test=lanes-sort-updated]')
  await p.select('[data-test=lanes-filter-vendor]', 'agy')
  ok('3887 lanes: the vendor filter keeps the agy lane', await until('a-277'), await order())
  ok('3887 lanes: the line says how many of all show', (await text(p, '[data-test=lanes-shown]')) === '1 of 3 lanes', await text(p, '[data-test=lanes-shown]'))
  await p.select('[data-test=lanes-filter-vendor]', '')
  await p.select('[data-test=lanes-filter-box]', 'box-b')
  ok('3887 lanes: the box filter keeps the box-b lanes', await until('a-277,m-039'), await order())
  await p.select('[data-test=lanes-filter-box]', '')
  const states = await p.$$eval('[data-test=lanes-filter-state] option', (os) => os.map((o) => o.value).join(','))
  ok('3887 lanes: the state filter offers the answer\'s states', states === ',live', states)
  await p.select('[data-test=lanes-filter-state]', 'live')
  ok('3887 lanes: the state filter keeps the live lanes', await until('c-085,a-277,m-039'), await order())
  await p.select('[data-test=lanes-filter-state]', '')
  await p.select('[data-test=lanes-filter-age]', '1h')
  ok('3887 lanes: within 1 h keeps the lanes written 4, 25 and 50 min ago', await until('c-085,a-277,m-039'), await order())
  await p.select('[data-test=lanes-filter-age]', 'older')
  ok('3887 lanes: over 24 h keeps none, and the table says so', (await until('')) && (await waitFor(p, '[data-test=lanes-no-match]')), await order())
  await p.select('[data-test=lanes-filter-age]', '')
  await p.type('[data-test=lanes-filter-text]', 'spl-3215')
  ok('3887 lanes: the text filter finds an issue key, any case', await until('c-085'), await order())
  await p.click('[data-test=lanes-filter-clear]')
  ok('3887 lanes: Clear filters shows every lane again', (await until('c-085,a-277,m-039')) && (await p.$eval('[data-test=lanes-filter-text]', (e) => e.value)) === '', await order())
  const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('3887 lanes: the filter row adds no sideways page scroll', wide <= 0, wide)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lanes-sort-filter-${size.width}.png`, fullPage: true })
  await ctx.close()
}

/** Spec 153 C17 (SPL-3215): the Lanes tab on the mock fleet of 3 lanes, an operator admin; CONTROL anyone else. CONTROL: on master the page is absent, so every check here FAILS there. */
async function lanesTab(browser, base, size) {
  {
    const { ctx, p } = await costsPage(browser, base, size, { operator: true })
    const res = await open(p, base, '/monitoring/lanes')
    ok('lanes: /monitoring/lanes answers 200', Boolean(res && res.status() === 200), res && res.status())
    const rows = await p.waitForFunction(() => document.querySelectorAll('[data-test=lanes-row]').length === 3, { timeout: 20000 }).then(() => true, () => false)
    ok('C17 lanes: three rows, newest write first', rows && (await p.$$eval('[data-test=lanes-row]', (els) => els.map((e) => e.getAttribute('data-agent')).join(','))) === 'c-085,a-277,m-039')
    /* spec 153 3.8 (SPL-3818), C43: the workspace is the last column, on every size */
    const lastCol = await p.evaluate(() => {
      const ths = [...document.querySelectorAll('[data-test=lanes-table] thead tr:first-child th')]
      const cells = [...document.querySelectorAll('[data-test=lanes-row]')].map((tr) => tr.lastElementChild)
      return { head: ths.length ? ths[ths.length - 1].getAttribute('data-test') : '', cells: cells.map((c) => c && c.getAttribute('data-test') + '=' + c.textContent.trim()) }
    })
    ok('C43 lanes: the workspace is the right-most column', lastCol.head === 'lanes-col-workspace'
      && lastCol.cells.join('|') === 'lanes-workspace=Mock workspace|lanes-workspace=Other workspace|lanes-workspace=Mock workspace', lastCol)
    const row = (agent, sel) => p.$$eval(`[data-test=lanes-row][data-agent="${agent}"] ${sel}`, (els) => els.map((e) => ({ href: e.getAttribute('href') || '', text: e.textContent.trim() })))
    const topic = await row('c-085', '[data-test=lanes-topic-link]')
    ok('C17 lanes: the discussion link is /t/<uuid>', topic.length === 1 && topic[0].href === '/t/' + LANES_MOCK_TOPIC, topic)
    const issues = await row('c-085', '[data-test=lanes-issue-link]')
    ok('C17 lanes: the issue keys link /issues?issue=<KEY>', issues.map((i) => i.href).join(' ') === '/issues?issue=SPL-3075 /issues?issue=SPL-3215', issues)
    ok('C17 lanes: the agent shows as id@box', (await text(p, '[data-test=lanes-row][data-agent="c-085"] [data-test=lanes-agent]')) === 'c-085@box-a')
    /* C27 (spec 153 3.6, row B6, SPL-3229): an operator admin's tab still reads the fleet route: every lane, with its box */
    ok('C27 lanes: the operator admin reads the fleet route, the other workspace\'s lane and the box names included', (await text(p, '[data-test=lanes-row][data-agent="a-277"] [data-test=lanes-agent]')) === 'a-277@box-b')
    ok('C17 control: another workspace\'s topic links nothing, its id shown as text', (await row('a-277', '[data-test=lanes-topic-link]')).length === 0
      && (await text(p, '[data-test=lanes-row][data-agent="a-277"] [data-test=lanes-topic]')) === '0b0c0d0e-1111-4222-8333-444455556666')
    ok('C17 control: a key with no status (another prefix) is text, not a link', (await row('a-277', '[data-test=lanes-issue-link]')).length === 0
      && (await text(p, '[data-test=lanes-row][data-agent="a-277"] [data-test=lanes-issues]')) === 'SPL-3216')
    ok('C17 control: no topic and no issue show a dash', (await text(p, '[data-test=lanes-row][data-agent="m-039"] [data-test=lanes-topic]')) === '\u2014'
      && (await text(p, '[data-test=lanes-row][data-agent="m-039"] [data-test=lanes-issues]')) === '\u2014')
    ok('lanes: written 4 min ago, tokens 1 min ago', (await text(p, '[data-test=lanes-row][data-agent="c-085"] [data-test=lanes-updated]')) === '4 min ago'
      && (await text(p, '[data-test=lanes-row][data-agent="c-085"] [data-test=lanes-active]')) === '1 min ago')
    const scope = await p.$eval('[data-test=lanes-row][data-agent="c-085"] [data-test=lanes-scope]', (e) => ({ title: e.getAttribute('title') || '', ws: getComputedStyle(e).whiteSpace })).catch(() => null)
    ok('lanes: a long scope stays on one line, its full text in the title', Boolean(scope && scope.ws === 'nowrap' && scope.title.startsWith('Spec 153 build row B4')), scope)
    ok('lanes: the age of the answer shows', /^Updated \d+ s ago$/.test(await text(p, '[data-test=lanes-age]')), await text(p, '[data-test=lanes-age]'))
    const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok('lanes: no sideways page scroll', wide <= 0, wide)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lanes-${size.width}.png`, fullPage: true })
    await ctx.close()
  }
  {
    const { ctx, p } = await costsPage(browser, base, size, { operator: true })
    await p.evaluate(() => localStorage.setItem('spool.mock.fleet_lanes', 'empty'))
    await open(p, base, '/monitoring/lanes')
    ok('lanes empty: the one line "No active lanes"', await waitFor(p, '[data-test=lanes-empty]') && (await text(p, '[data-test=lanes-empty]')) === 'No active lanes')
    await ctx.close()
  }
  {
    /* spec 153 3.6 (row B6, SPL-3229): a workspace admin who is no operator admin sees the tab and its own lanes only */
    const { ctx, p } = await costsPage(browser, base, size, { me: { role: 'admin', permissions: ['topics.read'] } })
    await open(p, base, '/monitoring/agents')
    await p.waitForFunction(() => document.querySelectorAll('[data-test^=monitoring-tab-]').length >= 2, { timeout: 15000 }).catch(() => null)
    const ids = await tabIds(p)
    ok('C26 twin lanes: a workspace admin sees the Lanes tab, not Tokens', ids.includes('lanes') && !ids.includes('tokens'), ids)
    await open(p, base, '/monitoring/lanes')
    const one = await p.waitForFunction(() => document.querySelectorAll('[data-test=lanes-row]').length === 1, { timeout: 20000 }).then(() => true, () => false)
    ok('3.6 lanes: the workspace\'s own lane only (its topic), no box name', one
      && (await text(p, '[data-test=lanes-row] [data-test=lanes-agent]')) === 'c-085', await count(p, '[data-test=lanes-row]'))
    ok('C43 lanes: inside the workspace too, the workspace is the right-most column', (await p.evaluate(() =>
      [...document.querySelectorAll('[data-test=lanes-row]')].map((tr) => tr.lastElementChild && tr.lastElementChild.textContent.trim()).join('|'))) === 'Mock workspace')
    await ctx.close()
  }
  {
    const { ctx, p } = await costsPage(browser, base, size)
    await open(p, base, '/monitoring/agents')
    await p.waitForFunction(() => document.querySelectorAll('[data-test^=monitoring-tab-]').length >= 2, { timeout: 15000 }).catch(() => null)
    ok('lanes control: no Lanes tab for anyone but an operator admin or a workspace admin', !(await tabIds(p)).includes('lanes'), await tabIds(p))
    await open(p, base, '/monitoring/lanes')
    ok('lanes control: the direct URL shows the 403 sentence', await waitFor(p, '[data-test=lanes-forbidden]'))
    ok('lanes control: no table', (await count(p, '[data-test=lanes-row]')) === 0)
    await ctx.close()
  }
}

/** SPL-4453 (rows 5 and 9 of SPL-4422): a plain member opens each admin or operator Monitoring page by URL; the page decides
 *  from /v1/view/me and sends no read the hub refuses (globalThis.SPOOL_MOCK_403 stays empty), and shows its no-access line.
 *  The mock hub writes the list where it refuses (act-as-mock.mjs mockRefused), not the page.
 *  CONTROL: the pages before SPL-4453 (7adacb96e) read first and each refused read lands in the list. */
const MEMBER_ME = { role: 'member', permissions: ['topics.read', 'notes.send'] }
async function memberGates(browser, base, size) {
  const { ctx, p } = await costsPage(browser, base, size, { me: MEMBER_ME })
  const refused = () => p.evaluate(() => globalThis.SPOOL_MOCK_403 || [])
  for (const [path, line] of [
    ['/monitoring/lanes', 'lanes-forbidden'],
    ['/monitoring/tokens', 'tokens-forbidden'],
    ['/monitoring/file-streams', 'fs-forbidden'],
    ['/monitoring/agents/CLE-07@box-a', 'agent-lanes-forbidden'],
  ]) {
    await open(p, base, path)
    const shown = await waitFor(p, `[data-test=${line}]`)
    await new Promise((r) => setTimeout(r, 500))
    const got = await refused()
    ok(`SPL-4453 member ${path}: 0 refused reads`, got.length === 0, got)
    ok(`SPL-4453 member ${path}: the no-access line`, shown)
  }
  await ctx.close()
}

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
  const withLanes = []
  for (const src of initial) {
    const js = await (await fetch(server.base + src)).text()
    if (COSTS_MARKERS.test(js)) withCosts.push(src)
    if (TOKENS_MARKERS.test(js)) withTokens.push(src)
    if (LANES_MARKERS.test(js)) withLanes.push(src)
  }
  ok('200.html names its initial chunks', initial.length > 0, initial.length)
  ok('no costs page, pie or tenant-costs code in the initial download', withCosts.length === 0, withCosts)
  ok('no Tokens page, card or monitoring-tokens code in the initial download', withTokens.length === 0, withTokens)
  ok('no Lanes page or monitoring-lanes code in the initial download (C20)', withLanes.length === 0, withLanes)

  console.log('-- spec 153 tab row')
  await tabRow(browser, server.base)

  for (const [label, size] of [['desktop', { width: 1400, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    console.log(`-- ${label} ${size.width}x${size.height}`)
    await lanesTab(browser, server.base, size)
    await memberGates(browser, server.base, size)
    await lanesSortFilter(browser, server.base, size)
    await costsS1(browser, server.base, size)
    await costsSections(browser, server.base, size)

    /* a full month, the mock's default me (unrestricted) */
    {
      const { ctx, p } = await costsPage(browser, server.base, size)
      const res = await open(p, server.base, SPEND)
      ok('/reporting/costs/spend answers 200', Boolean(res && res.status() === 200), res && res.status())
      await p.waitForFunction(() => document.querySelector('[data-test=reporting-tab-costs]'), { timeout: 15000 }).catch(() => null)
      const tabs = await reportingTabIds(p)
      ok('the Costs tab shows (unrestricted me)', tabs.includes('costs'), tabs)
      const active = await p.$eval('[data-test=reporting-tab-costs]', (e) => e.getAttribute('aria-current')).catch(() => '')
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
      /* spec 140 3.10 (SPL-3565): the list-price total, and the estate's every-workspace token table */
      const listTot = await text(p, '[data-test=costs-total-list]')
      ok('3.10 the total row sums the list price', listTot === '$2,650.00', listTot)
      ok('3.10 the estate lists every workspace\'s burn (3 rows)', (await count(p, '[data-test=costs-workspace-row]')) === 3, await count(p, '[data-test=costs-workspace-row]'))
      const alpha = await text(p, '[data-test=costs-workspace-row][data-workspace="ws-alpha"][data-vendor="claude"] td:last-child')
      ok('3.10 a workspace row shows its list price', alpha === '$13.89', alpha)
      const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      ok('no sideways scroll', wide <= 0, wide)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-costs-${size.width}.png`, fullPage: true })

      /* an earlier month: ended, so no "so far" mark (CONTROL: the mark follows the status); S1: the month is the header's, in the URL */
      await go(p, SPEND + '?month=2026-09')
      const months = ['', '2026-09']
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
      await open(p, server.base, SPEND)
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
      await go(p, SPEND)
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
      await go(p, SPEND)
      const eurBack = await p.waitForFunction(() => (document.querySelector('[data-test=costs-second-head]') || {}).textContent?.trim() === 'EUR (day rate)', { timeout: 15000 }).then(() => true, () => false)
      ok('setting: the column is back to EUR', eurBack, await text(p, '[data-test=costs-second-head]'))
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-costs-second-${size.width}.png`, fullPage: true })
      await ctx.close()
    }

    /* a part with no rate: the dash and a title saying so, never a guess; the total too */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { scenario: 'norate' })
      await open(p, server.base, SPEND)
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
      await open(p, server.base, SPEND)
      ok('empty: the table renders', await waitFor(p, '[data-test=costs-table]'))
      ok('empty: no pie, its note instead', (await count(p, '[data-test=costs-pie-svg]')) === 0 && await waitFor(p, '[data-test=costs-no-pie]'))
      const empties = await p.$$eval('[data-test=costs-empty-source]', (els) => els.map((e) => e.textContent.trim()))
      ok('empty: "no cost data yet" for GCP, fleet tokens and agent hours', empties.length === 3 && empties[0] === 'No cost data yet for GCP', empties)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-costs-empty-${size.width}.png`, fullPage: true })
      await ctx.close()
    }

    /* spec 143 3.3.1 (SPL-3891): a customer workspace's share of the AI subscriptions */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { scenario: 'share' })
      await open(p, server.base, SPEND)
      ok('share: the table renders', await waitFor(p, '[data-test=costs-table]'))
      const rows = await p.$$eval('[data-test=costs-row][data-source=ai_share] .costs-part', (els) => els.map((e) => e.textContent.trim()))
      ok('share: one row per agent type, named as the workspace\'s share', rows.join('|') === 'AI subscriptions (your share) · agy|AI subscriptions (your share) · claude', rows)
      ok('share: no ai_paid row (the estate\'s plans)', (await count(p, '[data-test=costs-row][data-source=ai_paid]')) === 0)
      const note = await text(p, '[data-test=costs-ai-share-note]')
      ok('share: the line names the first counted day', /^Your share of the AI subscriptions counts each ended day from \d{4}-\d{2}-03:/.test(note), note)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/costs-ai-share-${size.width}.png`, fullPage: true })
      await ctx.close()
    }
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { scenario: 'share_none' })
      await open(p, server.base, SPEND)
      ok('share_none: the table renders', await waitFor(p, '[data-test=costs-table]'))
      ok('share_none: no ai_share row yet', (await count(p, '[data-test=costs-row][data-source=ai_share]')) === 0)
      const note = await p.$eval('[data-test=costs-ai-share-note]', (e) => ({ key: e.getAttribute('data-key'), text: e.textContent.trim() })).catch(() => ({}))
      ok('share_none: the line says no share yet, today\'s tokens tomorrow', note.key === 'ai_share_none' && note.text.includes('so today\'s tokens show tomorrow'), note)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/costs-ai-share-none-${size.width}.png`, fullPage: true })
      await ctx.close()
    }
    /* CONTROL: the estate's mock month carries no share line */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, {})
      await open(p, server.base, SPEND)
      ok('share control: the estate has no share line', await waitFor(p, '[data-test=costs-table]') && (await count(p, '[data-test=costs-ai-share-note]')) === 0)
      await ctx.close()
    }

    /* a member without costs.read: no tab, and the direct URL is the 403 state */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { me: { role: 'developer', permissions: ['members.invite'] } })
      await open(p, server.base, '/reporting/releases')
      await p.waitForFunction(() => document.querySelectorAll('[data-test^=reporting-tab-]').length >= 1, { timeout: 15000 }).catch(() => null)
      await new Promise((r) => setTimeout(r, 500))
      const tabs = await reportingTabIds(p)
      ok('without costs.read: no Reporting Costs tab', tabs.length >= 1 && !tabs.includes('costs'), tabs)
      await open(p, server.base, SPEND)
      ok('without costs.read: the direct URL shows the 403 state', await waitFor(p, '[data-test=costs-forbidden]'))
      const why = await text(p, '[data-test=costs-forbidden]')
      ok('the 403 state names costs.read', why.includes('costs.read'), why)
      ok('without costs.read: no table', (await count(p, '[data-test=costs-table]')) === 0)
      await ctx.close()
    }

    /* spec 140 (SPL-2322): an operator admin, the busy mock fleet */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { operator: true })
      await open(p, server.base, SPEND)
      ok('tokens: the Costs page carries the Tokens card for an operator admin', await waitFor(p, '[data-test=costs-tokens-card]'))
      const card = await text(p, '[data-test=costs-tokens-card-body]')
      ok('tokens: the card says today\'s fleet tokens and cost', card === '19.35M tokens used · $42.15', card)
      ok('tokens: the card names the unmetered and unpriced lanes', (await text(p, '[data-test=costs-tokens-card-note]')).includes('1 not metered · 2 not priced'))
      const kinds = await p.$$eval('[data-test=costs-tokens-card-vendor]', (els) => els.map((e) => [e.getAttribute('data-vendor'), e.querySelector('[data-test=costs-tokens-card-vendor-body]').textContent.trim()]))
      ok('tokens: the card has a line per kind; grok has its tokens and "not priced", never $0.00 (SPL-2461)',
        kinds.map((k) => k[0]).join(',') === 'claude,mistral,grok' && (kinds.find((k) => k[0] === 'grok') || [])[1] === '900K tokens used · not priced', kinds)
      await p.click('[data-test=costs-tokens-card]')
      ok('tokens: the card opens the Tokens tab', await waitFor(p, '[data-test=tokens-page]'), p.url())
      ok('tokens: the URL is /monitoring/tokens', new URL(p.url()).pathname.replace(/\/$/, '') === '/monitoring/tokens', p.url())
      const tabs = await tabIds(p)
      ok('tokens: the Tokens tab shows beside Agents and Boxes, active', tabs.includes('tokens') && tabs.includes('agents') && tabs.includes('boxes')
        && await p.$eval('[data-test=monitoring-tab-tokens]', (e) => e.getAttribute('aria-current')).catch(() => '') === 'page', tabs)
      ok('tokens: the KPI strip renders', await waitFor(p, '[data-test=tokens-kpis]'))
      const kpi = { rate: await text(p, '[data-test=tokens-kpi-rate-value]'), today: await text(p, '[data-test=tokens-kpi-today-value]'), cost: await text(p, '[data-test=tokens-kpi-cost-value]') }
      ok('tokens: KPIs formatted (113.3K/min, 19.35M, $42.15)', kpi.rate === '113.3K/min' && kpi.today === '19.35M' && kpi.cost === '$42.15', kpi)
      const vendors = await p.$$eval('[data-test=tokens-vendor-row]', (els) => els.map((e) => ({ v: e.getAttribute('data-vendor'), s: e.getAttribute('data-status'),
        today: e.querySelector('[data-test=tokens-vendor-today]').textContent.trim(), cost: e.querySelector('[data-test=tokens-vendor-cost]').textContent.trim(),
        nm: Boolean(e.querySelector('[data-test=tokens-not-metered]')), np: Boolean(e.querySelector('[data-test=tokens-not-priced]')),
        burn: (e.querySelector('[data-test=tokens-burn-badge]') || { getAttribute: () => '' }).getAttribute('data-level') })))
      ok('tokens: five kinds in the hub order', vendors.map((v) => v.v).join(',') === 'claude,mistral,grok,agy,qwen', vendors.map((v) => v.v))
      const agy = vendors.find((v) => v.v === 'agy') || {}
      ok('tokens: agy is "Not metered" with dashes, never 0 tokens or $0.00', agy.nm && agy.s === 'unmetered' && agy.today === '\u2014' && agy.cost === '\u2014', agy)
      const mis = vendors.find((v) => v.v === 'mistral') || {}
      ok('tokens: a kind with an unpriced lane says "not priced", never $0.00', mis.np && mis.cost === 'not priced', mis)
      const grk = vendors.find((v) => v.v === 'grok') || {}
      ok('tokens: grok is metered with its tokens and "not priced" (SPL-2461)', grk.s === 'metered' && grk.today === '900K' && grk.np && grk.cost === 'not priced', grk)
      ok('tokens: claude surges (fresh 74.6K/min > 60K)', (vendors.find((v) => v.v === 'claude') || {}).burn === 'surge', vendors[0])
      const agents = () => p.$$eval('[data-test=tokens-agent-row]', (els) => els.map((e) => e.getAttribute('data-agent')))
      ok('tokens: lanes sorted by rate, highest first, agy last', (await agents()).join(',') === 'c-101,c-102,m-201,c-103,g-401,c-104,a-301', await agents())
      const lane = await p.$$eval('[data-test=tokens-agent-row]', (els) => els.map((e) => ({ a: e.getAttribute('data-agent'), s: e.getAttribute('data-status'),
        burn: (e.querySelector('[data-test=tokens-burn-badge]') || { getAttribute: () => '' }).getAttribute('data-level'),
        today: e.querySelector('[data-test=tokens-agent-today]').textContent.trim(), cost: e.querySelector('[data-test=tokens-agent-cost]').textContent.trim() })))
      const by = (id) => lane.find((l) => l.a === id) || {}
      ok('tokens: c-101 surges, c-102 has no badge', by('c-101').burn === 'surge' && by('c-102').burn === '', [by('c-101'), by('c-102')])
      ok('tokens: the agy lane is Not metered with dashes', by('a-301').s === 'not_metered' && by('a-301').today === '\u2014' && by('a-301').cost === '\u2014', by('a-301'))
      ok('tokens: the unpriced lane says "not priced"', by('m-201').cost === 'not priced', by('m-201'))
      ok('tokens: the grok lane g-401 shows its tokens, "not priced"', by('g-401').today === '900K' && by('g-401').cost === 'not priced', by('g-401'))
      ok('tokens: Active and Idle lanes', by('c-101').s === 'active' && by('c-104').s === 'idle', [by('c-101').s, by('c-104').s])
      if (size.width > 600) {
        await p.click('[data-test=tokens-sort-rate]')
        ok('tokens: the rate header sorts ascending as numbers, agy still last', (await agents()).join(',') === 'c-104,g-401,c-103,m-201,c-102,c-101,a-301', await agents())
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
      ok('tokens: the rows stay while stale', (await count(p, '[data-test=tokens-agent-row]')) === 7)
      await p.click('[data-test=tokens-refresh]')
      const cleared = await p.waitForFunction(() => !document.querySelector('[data-test=tokens-stale-red]') && document.querySelector('[data-test=tokens-age]')?.getAttribute('data-stale') === 'ok', { timeout: 10000 }).then(() => true, () => false)
      ok('tokens: Refresh clears the stale mark', cleared)
      await ctx.close()
    }

    /* the empty fleet: no lane yet, an honest sentence, qwen still not metered */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { operator: true, tokens: 'empty' })
      await open(p, server.base, '/monitoring/tokens')
      ok('tokens empty: the empty sentence', await waitFor(p, '[data-test=tokens-agents-empty]'))
      ok('tokens empty: qwen still "Not metered"', (await count(p, '[data-test=tokens-vendor-row][data-vendor=qwen] [data-test=tokens-not-metered]')) === 1)
      await ctx.close()
    }

    /* SPL-2567: the Paid card's round, an operator admin */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { operator: true })
      await paidRound(p, server.base, size)
      await ctx.close()
    }

    /* CONTROL: not an operator admin: no card, no tab, the direct URL is the 403 sentence */
    {
      const { ctx, p } = await costsPage(browser, server.base, size)
      await open(p, server.base, SPEND)
      await waitFor(p, '[data-test=costs-table]')
      ok('tokens control: no Tokens card on Costs', (await count(p, '[data-test=costs-tokens-card]')) === 0)
      ok('tokens control: no Tokens tab', !(await tabIds(p)).includes('tokens'), await tabIds(p))
      await open(p, server.base, '/monitoring/tokens')
      ok('tokens control: the direct URL shows the 403 sentence', await waitFor(p, '[data-test=tokens-forbidden]'))
      ok('tokens control: no table', (await count(p, '[data-test=tokens-agent-row]')) === 0 && (await count(p, '[data-test=tokens-kpis]')) === 0)
      ok('paid control: no Paid card for anyone but an operator admin', (await count(p, '[data-test=paid-card]')) === 0)
      await ctx.close()
    }

    /* CONTROL: the same opt-in me holding costs.read gets the tab */
    {
      const { ctx, p } = await costsPage(browser, server.base, size, { me: { role: 'biz_owner', permissions: ['costs.read'] } })
      await open(p, server.base, '/reporting/releases')
      const shown = await waitFor(p, '[data-test=reporting-tab-costs]')
      ok('with costs.read: the Reporting Costs tab shows', shown, await reportingTabIds(p))
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
