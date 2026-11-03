// SPL-4729 (spec 153 3.15; owner HUM-10, t1 0a730c21, msg ea87c5c1: "the full
// state of the lanes listing must be shareable via a link - aka once the lanes
// have been sorted and filtered"). In a REAL browser, mock bundle, at 1440 and
// 390. The mock fleet: c-085 (box-a, claude, Mock workspace, 4 min), a-277
// (box-b, agy, Other workspace, 25 min), m-039 (box-b, mistral, Mock
// workspace, 50 min).
//
//   1  a URL with every parameter: those controls set, only m-039
//   2  the address still names every parameter once the answer is in
//   3  reload keeps it; the minute's Refresh keeps it
//   4  a filter change and a sort click rewrite the URL, no history entry added
//   5  typing in the text filter follows each keystroke, spaces kept
//   6  Clear filters drops the filter parameters
//   7  bad values: ignored, no page error, the URL drops them, ?lane= kept
//   8  a link to one lane still selects it, filtered
//   9  the same kind of link opened by a member (workspace route, no box):
//      the box is set back to All, never a false empty list
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e monitoring-lanes-url
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

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
const PATH = '/monitoring/lanes'
const WHOLE = { sort: 'agent', dir: 'desc', box: 'box-b', vendor: 'mistral', state: 'live', age: '1h', workspace: 'mock', text: 'm-0' }
const FULL = PATH + '?' + new URLSearchParams(WHOLE).toString()
const SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'member@example.com', t: 'mock' })
const OPERATOR = { [TOKENS_MOCK_OPERATOR_KEY]: '1' }
/* a workspace admin who is no operator admin: the workspace route (3.6) */
const MEMBER = { 'spool.mock.me': JSON.stringify({ role: 'admin', permissions: ['topics.read'] }) }

async function open(browser, vp, path, seed) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v) } catch { /* about:blank */ }
  }, { 'spool.mock.session': SESSION, ...seed })
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return { p, ctx, errors }
}

const order = (p) => p.$$eval('[data-test=lanes-row]', (els) => els.map((e) => e.getAttribute('data-agent')).join(',')).catch(() => '')
const rowsAre = (p, want) => p.waitForFunction((w) => document.querySelector('[data-test=lanes-table]')
  && [...document.querySelectorAll('[data-test=lanes-row]')].map((e) => e.getAttribute('data-agent')).join(',') === w, { timeout: 15000 }, want).then(() => true, () => false)
const params = (p) => p.evaluate(() => Object.fromEntries(new URL(window.location.href).searchParams))
const sameParams = (a, b) => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b).sort())
const urlIs = (p, want) => p.waitForFunction((w) => JSON.stringify([...new URL(window.location.href).searchParams].sort()) === w, { timeout: 8000 },
  JSON.stringify(Object.entries(want).sort())).then(() => true, () => false)
const histLen = (p) => p.evaluate(() => history.length)
const controls = (p) => p.evaluate(() => {
  const val = (t) => document.querySelector(`[data-test=${t}]`)?.value ?? null
  return {
    box: val('lanes-filter-box'), vendor: val('lanes-filter-vendor'), state: val('lanes-filter-state'), age: val('lanes-filter-age'),
    workspace: val('lanes-filter-workspace'), text: val('lanes-filter-text'),
    sort: [...document.querySelectorAll('[data-test=lanes-table] th[aria-sort]')].filter((th) => th.getAttribute('aria-sort') !== 'none')
      .map((th) => th.querySelector('[data-test^=lanes-sort-]')?.getAttribute('data-test').slice('lanes-sort-'.length) + ':' + th.getAttribute('aria-sort')).join(),
  }
})

const server = await startServer()
const browser = await launch()
try {
  for (const { tag, vp } of VIEWPORTS) {
    const a = await open(browser, vp, FULL, OPERATOR)
    const { p } = a
    const one = await rowsAre(p, 'm-039')
    const c = await controls(p)
    const want = { box: 'box-b', vendor: 'mistral', state: 'live', age: '1h', workspace: 'mock', text: 'm-0', sort: 'agent:descending' }
    ok(`1 ${tag}: every parameter: those controls set, only m-039`, one && JSON.stringify(c) === JSON.stringify(want), { rows: await order(p), c })
    ok(`2 ${tag}: the address still names every parameter`, await urlIs(p, WHOLE), await params(p))
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    ok(`3 ${tag}: reload keeps it`, (await rowsAre(p, 'm-039')) && sameParams(await params(p), WHOLE), await params(p))
    await p.click('[data-test=lanes-refresh]')
    await p.waitForFunction(() => document.querySelector('[data-test=lanes-refresh]')?.getAttribute('aria-busy') === 'false', { timeout: 8000 }).catch(() => null)
    ok(`3b ${tag}: Refresh keeps the list and the address`, (await rowsAre(p, 'm-039')) && sameParams(await params(p), WHOLE), await params(p))

    const h0 = await histLen(p)
    await p.select('[data-test=lanes-filter-vendor]', '')
    await p.select('[data-test=lanes-filter-workspace]', '')
    await p.$eval('[data-test=lanes-filter-text]', (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
    const rest = { sort: 'agent', dir: 'desc', box: 'box-b', state: 'live', age: '1h' }
    const moved = await urlIs(p, rest)
    ok(`4 ${tag}: filter changes rewrite the URL and the rows (box-b, agent descending)`, moved && (await rowsAre(p, 'm-039,a-277')), { q: await params(p), rows: await order(p) })
    await p.click('[data-test=lanes-sort-agent]')
    const unsorted = { box: 'box-b', state: 'live', age: '1h' }
    ok(`4b ${tag}: the third sort click is the hub order and drops sort and dir`, (await urlIs(p, unsorted)) && (await rowsAre(p, 'a-277,m-039')), { q: await params(p), rows: await order(p) })
    ok(`4c ${tag}: no history entry added by any of it`, (await histLen(p)) === h0, [h0, await histLen(p)])

    await p.type('[data-test=lanes-filter-text]', 'agy rev')
    ok(`5 ${tag}: typing follows each keystroke into ?text=, spaces kept`, (await urlIs(p, { ...unsorted, text: 'agy rev' })) && (await rowsAre(p, 'a-277'))
      && (await p.$eval('[data-test=lanes-filter-text]', (e) => e.value)) === 'agy rev', { q: await params(p), rows: await order(p) })
    ok(`5b ${tag}: still no history entry`, (await histLen(p)) === h0, [h0, await histLen(p)])

    await p.click('[data-test=lanes-filter-clear]')
    ok(`6 ${tag}: Clear filters drops the filter parameters, every lane shows`, (await urlIs(p, {})) && (await rowsAre(p, 'c-085,a-277,m-039')), { q: await params(p), rows: await order(p) })
    await a.ctx.close()
    ok(`1-6 ${tag}: no page error`, a.errors.length === 0, a.errors)

    const bad = await open(browser, vp, PATH + '?sort=zzz&dir=up&age=2h&box=%3Cx%3E&vendor=nope&workspace=w9&state=gone&lane=c-085%40box-a', OPERATOR)
    const all = await rowsAre(bad.p, 'c-085,a-277,m-039')
    ok(`7 ${tag}: bad values are ignored, every lane shows, ?lane= kept and selected`, all && (await urlIs(bad.p, { lane: 'c-085@box-a' }))
      && (await bad.p.$eval('[data-test=lanes-row][data-selected="1"]', (e) => e.getAttribute('data-agent')).catch(() => '')) === 'c-085', { q: await params(bad.p), rows: await order(bad.p) })
    ok(`7b ${tag}: no page error, no error line`, bad.errors.length === 0 && !(await bad.p.$('[data-test=lanes-error]')), bad.errors)
    await bad.ctx.close()

    const deep = await open(browser, vp, PATH + '?lane=a-277%40box-b&box=box-b&sort=agent&dir=asc', OPERATOR)
    ok(`8 ${tag}: a link to one lane, filtered and sorted: that lane selected`, (await rowsAre(deep.p, 'a-277,m-039'))
      && (await deep.p.$eval('[data-test=lanes-row][data-selected="1"]', (e) => e.getAttribute('data-agent')).catch(() => '')) === 'a-277'
      && (await urlIs(deep.p, { lane: 'a-277@box-b', box: 'box-b', sort: 'agent', dir: 'asc' })), { q: await params(deep.p), rows: await order(deep.p) })
    await deep.ctx.close()

    const mem = await open(browser, vp, PATH + '?box=box-a&vendor=claude&workspace=mock&sort=agent&dir=asc', MEMBER)
    const shown = await rowsAre(mem.p, 'c-085')
    ok(`9 ${tag}: an operator's link with a box, opened by a member: their lane, not a false empty list`, shown && !(await mem.p.$('[data-test=lanes-no-match]')), { rows: await order(mem.p) })
    ok(`9b ${tag}: the box is set back to All and dropped from the URL, the rest kept`, (await urlIs(mem.p, { vendor: 'claude', workspace: 'mock', sort: 'agent', dir: 'asc' }))
      && (await mem.p.$eval('[data-test=lanes-filter-box]', (e) => e.value)) === '', await params(mem.p))
    if (process.env.SHOT_DIR) await mem.p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lanes-url-member-${tag}.png`, fullPage: true })
    await mem.ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
