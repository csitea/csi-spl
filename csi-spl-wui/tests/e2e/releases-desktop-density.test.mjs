// SPL-4900 (owner HUM-10, t1 4d1e60b5, msgs 402cb8df and b164e955: "too much
// empty space") made the desktop a grid of commit cards; SPL-6397 (owner
// HUM-10, t1 70e18a3d, msgs 8684ee68 and 9e3495df: "a single column list
// ... but a stylie one", "on the Desktop version") takes it back to ONE
// styled column. On /reporting/releases against the mock bundle, at
// 2560x1600 (the owner's desktop), 1440x900 and 390x844:
//   D1 desktop: every commit of every day starts at the same left x and
//      has the same width (one column); the column is centred and at most
//      72rem wide; within a row the times share one left x and the
//      subjects share another (the time column);
//   D2 desktop: the filter bar (range, kinds, areas, search) takes at most
//      2 rows at 2560 and 3 at 1440 (it was 4), so the first commit sits higher;
//   D3 every width: no card's text runs past its border, the body does not
//      scroll sideways;
//   D4 390: the phone layout stays: one column, the filter groups stacked;
//   D5 an opened commit's notes span the whole row of its day.
// Each size prints its measure (columns, filter rows, commits above the
// fold, the first commit's top), so a before/after reads off the log.
// CONTROL: origin/master 6d81d4447 (the SPL-4900 grid) fails D1 at 2560
// and 1440 (several left x per day).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e releases-desktop-density
//   SHOT_DIR=<dir> keeps a screenshot per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

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

const SIZES = [
  { width: 2560, height: 1600, touch: false, desktop: true, maxFilterRows: 2 },
  { width: 1440, height: 900, touch: false, desktop: true, maxFilterRows: 3 },
  { width: 390, height: 844, touch: true },
]

async function page(browser, base, { width, height, touch }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.setItem('spool.mock.me', JSON.stringify({ role: 'admin', permissions: [] }))
  })
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=releases-commit]', { visible: true, timeout: 20000 })
  return { ctx, p }
}

/** The page's layout, read in the browser: rows group boxes whose tops
 *  start below the previous row's bottom. */
function measure() {
  const rect = (e) => e.getBoundingClientRect()
  const rowsOf = (els) => {
    const rs = els.map(rect).filter((r) => r.width > 0).sort((a, b) => a.top - b.top)
    let n = 0, bottom = -Infinity
    for (const r of rs) { if (r.top >= bottom - 2) { n++; bottom = r.bottom } else bottom = Math.max(bottom, r.bottom) }
    return n
  }
  // The day with the most commits: the mock days count back from now, so
  // just after 00:00 UTC the first day holds one commit and one column.
  const days = [...document.querySelectorAll('[data-test=releases-day]')]
  const cellsOf = (d) => [...d.querySelectorAll('[data-test=releases-commit]')]
  const cells = days.map(cellsOf).sort((a, b) => b.length - a.length)[0] || []
  const every = days.flatMap(cellsOf)
  const lefts = [...new Set(cells.map((c) => Math.round(rect(c).left)))]
  const widths = [...new Set(cells.map((c) => Math.round(rect(c).width)))]
  const leftsAll = [...new Set(every.map((c) => Math.round(rect(c).left)))]
  const widthsAll = [...new Set(every.map((c) => Math.round(rect(c).width)))]
  const xOf = (sel) => [...new Set(every.map((c) => c.querySelector(sel)).filter(Boolean).map((e) => Math.round(rect(e).left)))]
  const list = document.querySelector('[data-test=releases-days]')
  const host = list?.parentElement
  const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
  const lr = list ? rect(list) : null
  const hr = host ? rect(host) : null
  const groups = ['releases-range', 'releases-kinds', 'releases-areas', 'releases-search']
    .map((id) => document.querySelector(`[data-test=${id}]`)).filter(Boolean)
  const all = [...document.querySelectorAll('[data-test=releases-commit]')]
  const body = document.querySelector('.reporting-body') || document.scrollingElement
  return {
    cols: lefts.length,
    widths,
    leftsAll,
    widthsAll,
    timeX: xOf('[data-test=releases-commit-time]'),
    subjectX: xOf('[data-test=releases-commit-subject]'),
    listWidth: lr ? Math.round(lr.width) : null,
    maxWidth: Math.round(72 * rem),
    gutters: lr && hr ? [Math.round(lr.left - hr.left), Math.round(hr.right - lr.right)] : null,
    filterRows: rowsOf(groups),
    filterGroups: groups.length,
    aboveFold: all.filter((c) => rect(c).bottom <= innerHeight).length,
    firstTop: all.length ? Math.round(rect(all[0]).top) : null,
    overflow: all.filter((c) => c.scrollWidth > c.clientWidth + 1).map((c) => c.getAttribute('data-sha')).slice(0, 3),
    bodyWide: body.scrollWidth - body.clientWidth,
    docWide: document.documentElement.scrollWidth - innerWidth,
  }
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const size of SIZES) {
    const tag = `${size.width}px`
    const { ctx, p } = await page(browser, server.base, size)
    const m = await p.evaluate(measure)
    console.log(`  measure ${tag}: ${JSON.stringify(m)}`)
    if (size.desktop) {
      ok(`D1 ${tag}: every commit starts at one left x (one column)`, m.leftsAll.length === 1, m.leftsAll)
      ok(`D1 ${tag}: every commit has one width`, m.widthsAll.length === 1, m.widthsAll)
      ok(`D1 ${tag}: the column is at most 72rem wide`, m.listWidth !== null && m.listWidth <= m.maxWidth + 1, [m.listWidth, m.maxWidth])
      ok(`D1 ${tag}: the column is centred`, m.gutters !== null && Math.abs(m.gutters[0] - m.gutters[1]) <= 2, m.gutters)
      ok(`D1 ${tag}: the times and the subjects each share one left x`, m.timeX.length === 1 && m.subjectX.length === 1 && m.subjectX[0] > m.timeX[0], [m.timeX, m.subjectX])
      ok(`D2 ${tag}: the filter bar takes <= ${size.maxFilterRows} rows`, m.filterGroups === 4 && m.filterRows <= size.maxFilterRows, m.filterRows)
    } else {
      ok(`D4 ${tag}: one column of commits`, m.cols === 1, m.cols)
      ok(`D4 ${tag}: the filter groups stay stacked`, m.filterGroups === 4 && m.filterRows === 4, m.filterRows)
    }
    ok(`D3 ${tag}: no commit's text runs past its border`, m.overflow.length === 0, m.overflow)
    ok(`D3 ${tag}: no sideways scroll`, m.bodyWide <= 0 && m.docWide <= 0, [m.bodyWide, m.docWide])
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/releases-density-${size.width}.png` })
    if (size.desktop) {
      const sel = '[data-test=releases-day] [data-test=releases-commit-toggle]'
      if (await p.$(sel)) {
        await p.click(sel)
        await p.waitForSelector('[data-test=releases-commit-notes]', { visible: true, timeout: 5000 }).catch(() => {})
        const span = await p.evaluate(() => {
          const notes = document.querySelector('[data-test=releases-commit-notes]')
          const row = notes?.closest('[data-test=releases-commit]')
          const grid = row?.parentElement
          if (!row || !grid) return null
          return { row: Math.round(row.getBoundingClientRect().width), grid: Math.round(grid.getBoundingClientRect().width) }
        })
        ok(`D5 ${tag}: an opened commit's notes span its day's row`, span !== null && span.row >= span.grid - 2, span)
      } else ok(`D5 ${tag}: a commit with notes to open`, false)
    }
    await ctx.close()
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nreleases-desktop-density: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length || !results.length ? 1 : 0))
