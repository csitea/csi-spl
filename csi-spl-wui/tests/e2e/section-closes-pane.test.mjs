// Spec 078 AC3 (FR-004, owner b6f35bf4, 193d95f7): on desktop, entering a
// section page or /search closes the right pane, whichever section it holds.
// Runs against the lde mock (no hub).
//
// Desktop 1440x900, a topic open on /channel/lobby, then a forward (non-Back)
// navigation to each of People, Search (/search?q=x), Docs and Boxes:
//   1  the channel topic pane closes on each
//   2  the live pane closes the same way
//   3  the operator console, opened from its rail button, closes too (spec Q3)
//   4  control: /channel/lobby -> /lobby (not a section page) keeps the pane
//
// Sections are opened through the page's own pinia stores and the route
// changes through the router's push, which is what the rail's links call;
// a full load would reset the stores and prove nothing.
//
// Run:
//   pnpm test:e2e section-closes-pane
//   BASE_URL=<generated bundle> pnpm test:e2e section-closes-pane   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { OPERATOR_MOCK_KEY } from '../../src/utils/operator-console.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const TASK_A = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const SECTIONS = ['/people', '/search?q=x', '/docs', '/boxes']

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

/** Open a topic section through its store, as its click handler does. */
const openSection = (p, which) => p.evaluate(({ which, id }) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  if (which === 'live') void pinia._s.get('live-pane').open(id)
  if (which === 'channel') pinia._s.get('topic').openTopic(id)
}, { which, id: TASK_A })

/** What the shell holds: the section on screen and each store's own flag. */
const pane = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  return {
    dom: document.querySelectorAll('[data-test=topic-section]').length,
    live: Boolean(pinia._s.get('live-pane').taskId),
    channel: Boolean(pinia._s.get('topic').open),
    operator: Boolean(pinia._s.get('operator-pane').open),
    path: location.pathname + location.search,
  }
})
const anyOpen = (s) => s.live || s.channel || s.operator

/** A forward SPA navigation, the call the rail's links make. */
async function push(p, to) {
  await p.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), to)
  await sleep(700)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  /* the mock plays the operator admin only on this opt-in (operator-console e2e) */
  await p.evaluate((k) => localStorage.setItem(k, '1'), OPERATOR_MOCK_KEY)
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(1200)

  /* ---- 1. the channel topic pane, then each section ---------------------- */
  for (const to of SECTIONS) {
    await push(p, '/channel/lobby')
    await openSection(p, 'channel')
    const opened = await until(p, () => document.querySelectorAll('[data-test=topic-section]').length === 1)
    ok(`1 a topic is open on /channel/lobby before ${to}`, opened, await pane(p))
    await push(p, to)
    const closed = await until(p, () => !document.querySelector('[data-test=topic-section]'))
    const s = await pane(p)
    ok(`1 ... ${to} closes the right pane`, closed && !anyOpen(s), s)
    await shot(p, `1-${to.replace(/\W+/g, '-')}`)
  }

  /* ---- 2. the live pane closes the same way ------------------------------ */
  await push(p, '/channel/lobby')
  await openSection(p, 'live')
  ok('2 the live pane is open on /channel/lobby', await until(p, () => Boolean(document.querySelector('[data-test=topic-section]'))), await pane(p))
  await push(p, '/people')
  ok('2 ... /people closes the live pane', await until(p, () => !document.querySelector('[data-test=topic-section]')) && !anyOpen(await pane(p)), await pane(p))

  /* ---- 3. the operator console closes too (spec Q3) ---------------------- */
  await push(p, '/channel/lobby')
  await p.waitForSelector('[data-testid=operator-console-open]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-testid=operator-console-open]')
  await until(p, () => Boolean(document.querySelector('[data-section=operator]')))
  ok('3 the operator console is open', (await pane(p)).operator && (await pane(p)).dom === 1, await pane(p))
  await push(p, '/boxes')
  ok('3 ... /boxes closes the operator console', !anyOpen(await pane(p)), await pane(p))

  /* ---- 4. control: a page that is not a section keeps the pane ----------- */
  await push(p, '/channel/lobby')
  await openSection(p, 'live')
  await until(p, () => Boolean(document.querySelector('[data-test=topic-section]')))
  await push(p, '/lobby')
  const kept = await pane(p)
  ok('4 control: /channel/lobby -> /lobby keeps the live pane', kept.live && kept.dom === 1, kept)
  await shot(p, '4-control-kept')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsection-closes-pane: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
