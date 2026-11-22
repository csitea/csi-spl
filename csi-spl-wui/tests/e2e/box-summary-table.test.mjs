// Spec 071 7.4.1 + 7.8 "summary table" (SPL-6239 row T9; owner HUM-10, t1
// 78f0138c, msg f87c349b): Monitoring > Boxes opens with one table, one row
// per box of this workspace, the 7.4.1 columns in order, every reading from
// the box's newest sample. The mock tenant: box-desk has two samples (the
// older first, no disks), box-a and box-b none.
//
//   S1 one row per box of this workspace, in the cards' order
//   S2 the columns of 7.4.1, in order
//   S3 box-desk reads its NEWEST sample: RAM used 38% (12 of 32 GiB used),
//      20 GiB free, /var 95% (df Use%), load 1.25 / 8, 1 live agent, an age
//   S4 a box with no sample reads boxes.now_none, never a 0
//   S5 the list's filter filters the table too
//   S6 without audit.read: the Box column only
//   S7 at 375 px: Box, RAM used, Fullest disk, Sample age; no sideways scroll
//
// Red control: build each row from the box's first sample instead of the
// newest (box-summary.mjs): S3 fails (25%, no disk).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e box-summary-table
// The test drives Chrome through puppeteer-core, as every e2e here does
// (spec 7.8 says Playwright; the suite has none).
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

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

const COLS = ['box', 'ram-pct', 'ram-free', 'disk', 'load', 'agents', 'age', 'state']

/** The table as the reader sees it: visible header columns and each row's visible cells. */
const readTable = (p) => p.evaluate(() => {
  const shown = (e) => getComputedStyle(e).display !== 'none'
  const table = document.querySelector('[data-test=box-summary]')
  if (!table) return null
  return {
    cols: Array.from(table.querySelectorAll('thead th')).filter(shown).map((th) => th.getAttribute('data-col')),
    rows: Array.from(table.querySelectorAll('[data-test=box-summary-row]')).map((tr) => ({
      box: tr.getAttribute('data-box'),
      title: tr.getAttribute('title') || '',
      cells: Object.fromEntries(Array.from(tr.querySelectorAll('td')).filter(shown).map((td) => [td.getAttribute('data-col'), (td.textContent || '').trim()])),
      ageTitle: tr.querySelector('td[data-col=age]')?.getAttribute('title') || '',
    })),
  }
})

const cardIds = (p) => p.evaluate(() => Array.from(document.querySelectorAll('[data-test=monitoring-box]:not([data-workspace])')).map((b) => b.getAttribute('data-box')))
const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)

async function open(vp, me) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message || e)))
  await setPageViewport(p, vp)
  await p.evaluateOnNewDocument((m) => {
    try { if (m) localStorage.setItem('spool.mock.me', JSON.stringify(m)); else localStorage.removeItem('spool.mock.me') } catch { /* private mode */ }
  }, me)
  await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=box-summary-row]', { timeout: NAV_TIMEOUT })
  return { p, errors }
}

async function desktop() {
  console.log('-- 1440x900: the table over the cards')
  const { p, errors } = await open({ width: 1440, height: 900 }, null)
  await p.waitForFunction(() => document.querySelector('[data-test=box-summary-row][data-box=box-desk] td[data-col=age]'), { timeout: NAV_TIMEOUT })
  const tab = await readTable(p)
  const cards = await cardIds(p)
  const ids = tab.rows.map((r) => r.box)
  ok('S1 one row per box of this workspace, in the cards\' order', ids.length >= 3 && JSON.stringify(ids) === JSON.stringify(cards), { ids, cards })
  ok('S2 the columns of 7.4.1, in order', JSON.stringify(tab.cols) === JSON.stringify(COLS), tab.cols)
  const desk = tab.rows.find((r) => r.box === 'box-desk')
  const c = desk ? desk.cells : {}
  ok('S3 box-desk reads its newest sample', c['ram-pct'] === '38%' && c['ram-free'] === '20 GiB' && c.disk === '/var 95%'
    && c.load === '1.25 / 8' && c.agents === '1' && /ago$/.test(c.age || '') && /^2026-09-18/.test(desk.ageTitle), desk)
  const bare = tab.rows.find((r) => r.box === 'box-a')
  ok('S4 a box with no sample reads "No current sample yet.", never 0', Boolean(bare) && bare.cells.none === 'No current sample yet.'
    && !Object.values(bare.cells).some((v) => /^0/.test(v)), bare)
  await p.type('[data-test=boxes-filter]', 'desk')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=box-summary-row]').length === 1, { timeout: 15000 }).catch(() => null)
  const filtered = (await readTable(p)).rows.map((r) => r.box)
  ok('S5 the filter filters the table too', JSON.stringify(filtered) === '["box-desk"]', filtered)
  ok('S1-S5 no page errors', errors.length === 0, errors)
  await p.close()
}

async function noAudit() {
  console.log('-- 1440x900 without audit.read')
  const { p, errors } = await open({ width: 1440, height: 900 }, { role: 'developer', permissions: ['messages.read'] })
  const tab = await readTable(p)
  ok('S6 without audit.read: the Box column only', JSON.stringify(tab.cols) === '["box"]'
    && tab.rows.length >= 3 && tab.rows.every((r) => Object.keys(r.cells).join() === 'box'), tab)
  ok('S6 no page errors', errors.length === 0, errors)
  await p.close()
}

async function phone() {
  console.log('-- 375x812 phone')
  const { p, errors } = await open({ width: 375, height: 812 }, null)
  await p.waitForFunction(() => document.querySelector('[data-test=box-summary-row][data-box=box-desk] td[data-col=age]'), { timeout: NAV_TIMEOUT })
  const tab = await readTable(p)
  const desk = tab.rows.find((r) => r.box === 'box-desk')
  ok('S7 phone: Box, RAM used, Fullest disk, Sample age', JSON.stringify(tab.cols) === '["box","ram-pct","disk","age"]', tab.cols)
  ok('S7 phone: the dropped columns are in the row\'s title', Boolean(desk) && desk.title.includes('20 GiB') && desk.title.includes('1.25 / 8'), desk && desk.title)
  ok('S7 phone: no sideways scroll', await noXScroll(p))
  ok('S7 no page errors', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await desktop()
  await noAudit()
  await phone()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
