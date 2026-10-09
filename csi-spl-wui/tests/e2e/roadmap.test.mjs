// Spec 112 WUI-1 (5, 5.3 (b), 9): the roadmap page, spec rows, on the mock
// bundle with a fixture roadmap.json (served in place of the build's copy):
//   - one row per spec row of the file, no-tasks rows included;
//   - ?when=week|month filters by the tasks.md change day, from the toggle
//     and from the URL. CONTROL: the toggle changes the visible row count;
//   - desktop (a table) and <= 820 px (each row a card), dark and light, no
//     sideways scroll; /roadmap#spec-NNN marks that row;
//   - roadmap.json is FETCHED: no JS the page loads carries its text, and the
//     initial download of 200.html carries no roadmap code. CONTROL: an
//     `import` of roadmap.json in the page inlines the rule text into a chunk
//     and turns that check red.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e roadmap
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

/* The fixture: the action's shape (do_spl_spec_progress --json). One row
   changed now (this week and month), one 40 days ago (neither), one with no
   tasks.md, one without boxes and an old day, one planned with no day. */
const DAY = 86400000
const RULE = 'spec 112 5.1: [~] is open; pct = floor(100 x / (x+p+o))'
const FIXTURE = {
  sha: '0123456789abcdef0123456789abcdef01234567',
  rule: RULE,
  totals: { specs: 5, done: 1, 'in-progress': 1, planned: 1, 'no-boxes': 1, 'no-tasks': 1 },
  specs: [
    { id: '001-fixture-done', title: 'Fixture: done', state: 'done', x: 4, p: 0, o: 0, pct: 100, tasks_changed: new Date(Date.now() - 40 * DAY).toISOString() },
    { id: '002-fixture-progress', title: 'Fixture: in progress, changed now', state: 'in-progress', x: 2, p: 1, o: 1, pct: 50, tasks_changed: new Date().toISOString() },
    { id: '003-fixture-planned', title: 'Fixture: planned', state: 'planned', x: 0, p: 0, o: 3, pct: 0, tasks_changed: '' },
    { id: '004-fixture-table', title: 'Fixture: a task table', state: 'no-boxes', x: 0, p: 0, o: 0, pct: null, tasks_changed: new Date(Date.now() - 400 * DAY).toISOString() },
    { id: '005-fixture-none', title: 'Fixture: no tasks.md', state: 'no-tasks', x: 0, p: 0, o: 0, pct: null, tasks_changed: '' },
  ],
}
const ROADMAP_MARKERS = /"roadmap-page"|"roadmap-spec-table"/

/** A page whose /roadmap.json is the fixture; the path of every JS it loads is kept. */
async function roadmapPage(browser, { width, height, theme }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* none */ } }, theme)
  const seen = { json: 0, js: new Set() }
  await p.setRequestInterception(true)
  p.on('request', (r) => {
    if (new URL(r.url()).pathname === '/roadmap.json') {
      seen.json++
      return r.respond({ status: 200, contentType: 'application/json', body: JSON.stringify(FIXTURE) })
    }
    return r.continue()
  })
  p.on('response', (res) => {
    const u = new URL(res.url())
    if (u.pathname.startsWith('/_nuxt/') && u.pathname.endsWith('.js')) seen.js.add(u.pathname)
  })
  return { ctx, p, seen }
}

const rowCount = (p) => p.$$eval('[data-test=roadmap-spec-row]', (els) => els.length)
async function waitRows(p, n) {
  return p.waitForFunction((want) => document.querySelectorAll('[data-test=roadmap-spec-row]').length === want
    || (want === 0 && document.querySelector('[data-test=roadmap-empty]')), { timeout: 15000 }, n).then(() => true, () => false)
}

const server = await startServer()
const browser = await launch()
try {
  /* the 200.html initial download: no roadmap code (spec 112 9) */
  const html = await (await fetch(server.base + '/200.html')).text()
  const initial = [...new Set([
    ...[...html.matchAll(/<script\b[^>]*\bsrc="(\/_nuxt\/[A-Za-z0-9._-]+\.js)"/g)].map((m) => m[1]),
    ...[...html.matchAll(/<link\b[^>]*>/g)].map((m) => m[0]).filter((tag) => /\brel="modulepreload"/.test(tag))
      .map((tag) => (tag.match(/\bhref="(\/_nuxt\/[A-Za-z0-9._-]+\.js)"/) || [])[1]).filter(Boolean),
  ])]
  const withRoadmap = []
  for (const src of initial) {
    const body = await (await fetch(server.base + src)).text()
    if (ROADMAP_MARKERS.test(body) || body.includes('[~] is open')) withRoadmap.push(src)
  }
  ok('200.html names its initial chunks', initial.length > 0, initial.length)
  ok('no roadmap code or data in the initial download', withRoadmap.length === 0, withRoadmap)

  const bgs = {}
  const week = FIXTURE.specs.filter((s) => s.id.startsWith('002')).length
  for (const [label, size, theme] of [['desktop dark', { width: 1280, height: 800 }, 'dark'], ['phone light', { width: 390, height: 844 }, 'light']]) {
    console.log(`-- ${label}`)
    const { ctx, p, seen } = await roadmapPage(browser, { ...size, theme })
    const res = await p.goto(server.base + '/roadmap', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok('/roadmap answers 200', Boolean(res && res.status() === 200), res && res.status())
    const table = await p.waitForSelector('[data-test=roadmap-spec-table]', { visible: true, timeout: 20000 }).catch(() => null)
    ok('the spec-row table shows', Boolean(table))
    const all = await rowCount(p)
    ok('one row per spec row of roadmap.json', all === FIXTURE.specs.length, all)
    const none = await p.$eval('[data-spec="005-fixture-none"] [data-test=roadmap-spec-state]', (el) => el.textContent.trim()).catch(() => '')
    ok('the no-tasks row is there, labelled', none.length > 0 && none !== 'roadmap.state.no_tasks', none)
    const partial = await p.$eval('[data-spec="002-fixture-progress"]', (el) => ({
      counts: el.querySelector('[data-test=roadmap-spec-counts]')?.textContent.replace(/\s+/g, ' ').trim(),
      pct: el.querySelector('[data-test=roadmap-spec-pct]')?.textContent.trim(),
    })).catch(() => null)
    ok('a row shows its [x] / [~] / [ ] counts and pct', partial?.counts === '2 / 1 / 1' && partial?.pct === '50%', partial)
    ok('roadmap.json was fetched', seen.json >= 1, seen.json)

    /* the toggle (CONTROL: it changes the visible row count) */
    await p.click('[data-test=roadmap-when-week]')
    const wk = await waitRows(p, week)
    const weekRows = await rowCount(p)
    ok('this week: only the row changed now', wk && weekRows === week, weekRows)
    ok('the filter is in the URL', new URL(p.url()).searchParams.get('when') === 'week', p.url())
    ok('CONTROL: the toggle changes the visible row count', weekRows !== all, { all, week: weekRows })
    await p.click('[data-test=roadmap-when-all]')
    ok('All shows every row again', await waitRows(p, all))

    /* the URL alone reproduces the filter */
    await p.goto(server.base + '/roadmap?when=month#spec-002', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=roadmap-spec-table]', { visible: true, timeout: 20000 }).catch(() => null)
    const monthRows = await rowCount(p)
    ok('?when=month from the URL filters', monthRows >= week && monthRows < all, monthRows)
    const pressed = await p.$eval('[data-test=roadmap-when-month]', (el) => el.getAttribute('aria-pressed')).catch(() => '')
    ok('the month toggle reads pressed', pressed === 'true', pressed)
    const focus = await p.$eval('#spec-002', (el) => el.classList.contains('roadmap-row--focus')).catch(() => false)
    ok('#spec-002 marks that row', focus)

    const display = await p.$eval('[data-test=roadmap-spec-row]', (el) => getComputedStyle(el).display).catch(() => '')
    if (size.width <= 820) ok('<= 820 px: each row is a card', display === 'block', display)
    else ok('desktop: rows are table rows', display === 'table-row', display)
    const wide = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok('no sideways scroll', wide <= 0, wide)
    bgs[theme] = await p.evaluate(() => getComputedStyle(document.body).backgroundColor).catch(() => '')
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/roadmap-${theme}-${size.width}.png`, fullPage: false })

    /* fetched, never imported: no JS the page loaded carries the file's text */
    const carrying = []
    for (const src of seen.js) {
      const body = await (await fetch(server.base + src)).text()
      if (body.includes('[~] is open')) carrying.push(src)
    }
    ok('no loaded chunk carries roadmap.json (it is fetched)', seen.js.size > 0 && carrying.length === 0, { loaded: seen.js.size, carrying })
    await ctx.close()
  }
  ok('dark and light differ', Boolean(bgs.dark && bgs.light && bgs.dark !== bgs.light), bgs)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `roadmap: ${failed} FAILED` : `roadmap: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
