// Spec 140, tokens tab panel plan v1.1 row 08 (SPL-2489, parent SPL-2476):
// Monitoring -> Tokens on a phone, in a real browser against the mock bundle
// (the mock fleet: 7 lanes, 5 kinds), in English and Finnish:
//   - no sideways scroll at 412x915 and 360x800: the document, the page,
//     every table wrap (plan 2.2: 49 px on the vendor table before row 01)
//     and every KPI tile (row 04 found "19,35 milj." past its tile in fi);
//   - the phone cards: an agent lane card <= 80 px and the 7 cards <= 580 px
//     (plan 5.1, row 07), the KPI strip <= 115 px (5.4, row 04), an active
//     kind's card <= 65 px and agy + qwen folded to one line each (5.5, row 05);
//   - the phone sort select (5.2, row 06): visible with the header row
//     hidden, and picking an option re-orders the lanes;
//   - the desktop (1280x800) table still works: the header row shows, the
//     select does not, a header click sorts as numbers and the select
//     follows it, no sideways scroll.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-tokens
//   SHOT_DIR=<dir> keeps a screenshot per locale and size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
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

/* plan v1.1 5.1, 5.4, 5.5: the phone budgets, px */
const AGENT_CARD_MAX = 80
const AGENT_CARDS_MAX = 580
const KPI_STRIP_MAX = 115
const VENDOR_CARD_MAX = 65
const PHONES = [{ width: 412, height: 915 }, { width: 360, height: 800 }]
const DESKTOP = { width: 1280, height: 800 }
const LOCALES = [{ code: 'en', prefix: '' }, { code: 'fi', prefix: '/fi' }]

/* the mock fleet's lanes in each order (src/utils/monitoring-tokens.mjs mockFleetTokens), agy last */
const BY_RATE = 'c-101,c-102,m-201,c-103,g-401,c-104,a-301'
const BY_RATE_ASC = 'c-104,g-401,c-103,m-201,c-102,c-101,a-301'
const BY_TODAY = 'c-101,c-102,m-201,c-103,g-401,c-104,a-301'
const BY_ID = 'a-301,c-101,c-102,c-103,c-104,g-401,m-201'

const visible = (p, sel) => p.$eval(sel, (e) => {
  const s = getComputedStyle(e)
  const r = e.getBoundingClientRect()
  return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0
}).catch(() => false)
const agents = (p) => p.$$eval('[data-test=tokens-agent-row]', (els) => els.map((e) => e.getAttribute('data-agent')).join(','))
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
/* a pick in a <select> as a person makes it: the value, then the change event Vue listens to */
const pick = (p, sel, value) => p.select(sel, value).then(() => true, () => false)

/** A fresh signed-in mock operator admin on /monitoring/tokens in this locale at this size. */
async function tokensPage(browser, base, { width, height }, prefix) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: width < 800, hasTouch: width < 800 })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((opKey, tkKey) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem('spool.mock.me')
    localStorage.setItem(opKey, '1')
    localStorage.removeItem(tkKey)
  }, TOKENS_MOCK_OPERATOR_KEY, TOKENS_MOCK_KEY)
  await p.goto(base + prefix + '/monitoring/tokens', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const ready = await waitFor(p, '[data-test=tokens-agent-row]')
  return { ctx, p, ready }
}

/** Every box that scrolls or spills sideways, px past its own width: the document, the page, each table wrap, each KPI tile and figure. */
const overflow = (p) => p.evaluate(() => {
  const past = (e) => Math.max(0, e.scrollWidth - e.clientWidth)
  const out = { document: past(document.documentElement) }
  const page = document.querySelector('[data-test=tokens-page]')
  out.page = page ? past(page) : -1
  document.querySelectorAll('[data-test=tokens-page] .tk-table-wrap').forEach((e, i) => { out['table' + i] = past(e) })
  document.querySelectorAll('[data-test=tokens-kpis] .tk-kpi').forEach((tile) => {
    const id = tile.getAttribute('data-test')
    const box = tile.getBoundingClientRect()
    out[id] = past(tile)
    /* a figure that spills past its tile without making the tile scroll; a
       subtitle clipped with an ellipsis (overflow hidden) spills nothing */
    tile.querySelectorAll('.tk-kpi-value, .tk-kpi-sub').forEach((v, j) => {
      const r = v.getBoundingClientRect()
      const clipped = getComputedStyle(v).overflowX !== 'visible'
      out[`${id}.${j}`] = Math.max(0, Math.round(Math.max(r.right - box.right, box.left - r.left, clipped ? 0 : v.scrollWidth - v.clientWidth)))
    })
  })
  return out
})
/** The deepest boxes inside the page that end past its right edge, for the evidence line. */
const spills = (p) => p.evaluate(() => {
  const page = document.querySelector('[data-test=tokens-page]')
  if (!page) return []
  const edge = page.getBoundingClientRect().right
  return [...page.querySelectorAll('*')].filter((e) => e.getBoundingClientRect().right > edge + 0.5 && ![...e.children].some((c) => c.getBoundingClientRect().right > edge + 0.5))
    .slice(0, 5).map((e) => `${e.tagName.toLowerCase()}.${[...e.classList].join('.')} +${Math.round(e.getBoundingClientRect().right - edge)}px "${e.textContent.trim().slice(0, 30)}"`)
})
const worst = (o) => Math.max(...Object.values(o))

const heights = (p) => p.evaluate(() => {
  const h = (e) => Math.round(e.getBoundingClientRect().height)
  const cards = [...document.querySelectorAll('[data-test=tokens-agent-row]')]
  const top = cards.length ? cards[0].getBoundingClientRect().top : 0
  const bottom = cards.length ? cards[cards.length - 1].getBoundingClientRect().bottom : 0
  const kpis = document.querySelector('[data-test=tokens-kpis]')
  const vendors = [...document.querySelectorAll('[data-test=tokens-vendor-row]')].map((e) => ({ v: e.getAttribute('data-vendor'), h: h(e), fold: e.classList.contains('tk-vfold') }))
  return { cards: cards.map(h), cardsTotal: Math.round(bottom - top), kpis: kpis ? h(kpis) : -1, vendors }
})

const server = await startServer()
const browser = await launch()
try {
  for (const loc of LOCALES) {
    for (const size of PHONES) {
      const tag = `${loc.code} ${size.width}x${size.height}`
      const { ctx, p, ready } = await tokensPage(browser, server.base, size, loc.prefix)
      ok(`${tag}: the Tokens tab renders the lanes`, ready)
      ok(`${tag}: the page is in ${loc.code}`, (await p.evaluate(() => document.documentElement.lang)).startsWith(loc.code), await p.evaluate(() => document.documentElement.lang))

      const over = await overflow(p)
      ok(`${tag}: 0 px sideways overflow (document, page, tables, KPI tiles)`, worst(over) === 0, worst(over) === 0 ? over : { ...over, spills: await spills(p) })

      const hs = await heights(p)
      ok(`${tag}: each lane card <= ${AGENT_CARD_MAX} px`, hs.cards.length === 7 && Math.max(...hs.cards) <= AGENT_CARD_MAX, hs.cards)
      ok(`${tag}: the 7 lane cards <= ${AGENT_CARDS_MAX} px`, hs.cardsTotal > 0 && hs.cardsTotal <= AGENT_CARDS_MAX, hs.cardsTotal)
      ok(`${tag}: the KPI strip <= ${KPI_STRIP_MAX} px`, hs.kpis > 0 && hs.kpis <= KPI_STRIP_MAX, hs.kpis)
      const active = hs.vendors.filter((v) => !v.fold)
      const folded = hs.vendors.filter((v) => v.fold).map((v) => v.v).sort().join(',')
      ok(`${tag}: each active kind's card <= ${VENDOR_CARD_MAX} px`, active.length === 3 && Math.max(...active.map((v) => v.h)) <= VENDOR_CARD_MAX, active)
      ok(`${tag}: agy and qwen fold to one line each`, folded === 'agy,qwen', hs.vendors)

      ok(`${tag}: no header row on a phone`, !(await visible(p, '[data-test=tokens-agents] thead')))
      ok(`${tag}: the sort select shows`, await visible(p, '[data-test=tokens-agent-sort]'))
      const first = await p.$eval('[data-test=tokens-agent-sort]', (e) => e.value).catch(() => '')
      ok(`${tag}: the select starts on the burn rate, the lanes in that order`, first === 'rate:desc' && (await agents(p)) === BY_RATE, [first, await agents(p)])
      ok(`${tag}: "Today's tokens" re-orders the lanes`, (await pick(p, '[data-test=tokens-agent-sort]', 'todayTokens:desc')) && (await agents(p)) === BY_TODAY, await agents(p))
      ok(`${tag}: "Agent ID" re-orders the lanes A to Z`, (await pick(p, '[data-test=tokens-agent-sort]', 'agentId:asc')) && (await agents(p)) === BY_ID, await agents(p))
      const options = await p.$$eval('[data-test=tokens-agent-sort] option', (els) => els.map((e) => e.textContent.trim())).catch(() => [])
      ok(`${tag}: the select offers the 6 sort keys, each a label`, options.length === 6 && options.every((o) => o && !o.startsWith('monitoring.')), options)
      const after = await overflow(p)
      ok(`${tag}: still 0 px sideways overflow after a re-sort`, worst(after) === 0, after)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-tokens-${loc.code}-${size.width}.png`, fullPage: true })
      await ctx.close()
    }

    /* the desktop table is unchanged: header clicks sort as numbers, the select (hidden) follows them */
    {
      const tag = `${loc.code} ${DESKTOP.width}x${DESKTOP.height}`
      const { ctx, p, ready } = await tokensPage(browser, server.base, DESKTOP, loc.prefix)
      ok(`${tag}: the Tokens tab renders the lanes`, ready)
      ok(`${tag}: the header row shows`, await visible(p, '[data-test=tokens-agents] thead'))
      ok(`${tag}: the phone sort select is hidden`, !(await visible(p, '[data-test=tokens-agent-sort]')))
      ok(`${tag}: the lanes start by rate, highest first`, (await agents(p)) === BY_RATE, await agents(p))
      await p.click('[data-test=tokens-sort-rate]')
      ok(`${tag}: the rate header sorts ascending as numbers, agy still last`, (await agents(p)) === BY_RATE_ASC, await agents(p))
      await p.click('[data-test=tokens-sort-agentId]')
      ok(`${tag}: the agent header sorts A to Z`, (await agents(p)) === BY_ID, await agents(p))
      ok(`${tag}: the sort select follows the header`, (await p.$eval('[data-test=tokens-agent-sort]', (e) => e.value).catch(() => '')) === 'agentId:asc')
      const rowH = await p.$$eval('[data-test=tokens-agent-row]', (els) => els.map((e) => [getComputedStyle(e).display, Math.round(e.getBoundingClientRect().height)]))
      ok(`${tag}: lanes are table rows, not cards`, rowH.length === 7 && rowH.every(([d]) => d === 'table-row'), rowH)
      const over = await overflow(p)
      ok(`${tag}: 0 px sideways overflow`, worst(over) === 0, over)
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-tokens-${loc.code}-${DESKTOP.width}.png`, fullPage: true })
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `monitoring-tokens: ${failed} FAILED` : `monitoring-tokens: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
